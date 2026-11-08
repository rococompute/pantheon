(* The shell: everything Pantheon does that isn't a decision. Soma's node.soma
   decides; this runs it. Sockets, timers, keys and signatures, the block log,
   model processes and the command line are here, and nothing else is.

   Every peer message and every transaction is signed with RSA (PKCS#1 v1.5,
   SHA-256: what cryptokit, in Soma's OCaml switch, can do). *)

let fail fmt = Printf.ksprintf (fun s -> prerr_endline ("error: " ^ s); exit 1) fmt
let say fmt = Printf.ksprintf (fun s -> Printf.printf "%s %s\n%!" (string_of_float (Unix.gettimeofday ())) s) fmt

(* ---------- hashing and signatures ---------- *)

let hex s = Cryptokit.transform_string (Cryptokit.Hexa.encode ()) s
let unhex s = Cryptokit.transform_string (Cryptokit.Hexa.decode ()) s
let sha256_raw s = Cryptokit.hash_string (Cryptokit.Hash.sha256 ()) s
let sha256 s = hex (sha256_raw s)

(* length-prefixed, so ["ab"; "c"] and ["a"; "bc"] differ *)
let hash_list l = sha256 (String.concat "" (List.map (fun x -> string_of_int (String.length x) ^ ":" ^ x) l))

let digest_info = unhex "3031300d060960864801650304020105000420"

let emsa bits msg =
  let k = bits / 8 in
  let t = digest_info ^ sha256_raw msg in
  "\x00\x01" ^ String.make (k - String.length t - 3) '\xff' ^ "\x00" ^ t

let sign (key : Cryptokit.RSA.key) msg = hex (Cryptokit.RSA.sign_CRT key (emsa key.size msg))

let verify (key : Cryptokit.RSA.key) msg sg =
  try
    let raw = unhex sg in
    String.length raw = key.size / 8 && Cryptokit.RSA.unwrap_signature key raw = emsa key.size msg
  with _ -> false

let key_to_json (k : Cryptokit.RSA.key) ~priv =
  let f s = `String (hex s) in
  `Assoc ([ ("size", `Int k.size); ("n", f k.n); ("e", f k.e) ]
          @ if priv then [ ("d", f k.d); ("p", f k.p); ("q", f k.q); ("dp", f k.dp); ("dq", f k.dq); ("qinv", f k.qinv) ] else [])

let key_of_json j : Cryptokit.RSA.key =
  let open Yojson.Safe.Util in
  let g k = match member k j with `String s -> unhex s | _ -> "" in
  { size = to_int (member "size" j); n = g "n"; e = g "e"; d = g "d"; p = g "p"; q = g "q"; dp = g "dp"; dq = g "dq"; qinv = g "qinv" }

let replace_all s sub by =
  let b = Buffer.create (String.length s) and n = String.length sub in
  let i = ref 0 in
  while !i < String.length s do
    if !i + n <= String.length s && String.sub s !i n = sub then (Buffer.add_string b by; i := !i + n)
    else (Buffer.add_char b s.[!i]; incr i)
  done;
  Buffer.contents b

let rng = lazy (Cryptokit.Random.device_rng "/dev/urandom")
let random_hex n = hex (Cryptokit.Random.string (Lazy.force rng) n)

(* ---------- genesis, read by decode_tx: the same on every node ---------- *)

let chain_id = ref ""
let pubkeys : (string, Cryptokit.RSA.key) Hashtbl.t = Hashtbl.create 8
let max_tx_bytes = 256 * 1024

let strings_json l = `List (List.map (fun s -> `String s) l)
let json_strings = function `List l -> List.map (function `String s -> s | _ -> raise Exit) l | _ -> raise Exit

let tx_bytes agent nonce fields =
  String.concat "\x00" [ "tx"; !chain_id; agent; nonce; Yojson.Safe.to_string (strings_json fields) ]

let all_digits s = s <> "" && String.length s < 18 && String.for_all (fun c -> c >= '0' && c <= '9') s

let decode_tx raw =
  if String.length raw > max_tx_bytes then []
  else
    try
      let j = Yojson.Safe.from_string raw in
      let open Yojson.Safe.Util in
      let agent = to_string (member "agent" j) and nonce = to_string (member "nonce" j) in
      let fields = json_strings (member "fields" j) and sg = to_string (member "sig" j) in
      match Hashtbl.find_opt pubkeys agent with
      | Some key when all_digits nonce && verify key (tx_bytes agent nonce fields) sg -> agent :: nonce :: fields
      | _ -> []
    with _ -> []

let encode_tx key agent nonce fields =
  Yojson.Safe.to_string
    (`Assoc [ ("agent", `String agent); ("nonce", `String nonce); ("fields", strings_json fields);
              ("sig", `String (sign key (tx_bytes agent nonce fields))) ])

(* ---------- files ---------- *)

let read_file p = In_channel.with_open_bin p In_channel.input_all
let write_file p s =
  let tmp = p ^ ".tmp" in
  Out_channel.with_open_bin tmp (fun oc -> output_string oc s);
  Unix.rename tmp p
let rec mkdir_p d = if d <> "" && d <> "." && d <> "/" && not (Sys.file_exists d) then (mkdir_p (Filename.dirname d); Unix.mkdir d 0o755)
let append_line p s = Out_channel.with_open_gen [ Open_append; Open_creat; Open_binary ] 0o644 p (fun oc -> output_string oc (s ^ "\n"); flush oc)
let read_json p = try Yojson.Safe.from_file p with _ -> fail "cannot read %s: is this a home made by `pantheon init`?" p
let lines p = if Sys.file_exists p then String.split_on_char '\n' (read_file p) |> List.filter (( <> ) "") else []

(* a path an edit may touch: also checked by the market, checked again here.
   Nothing in a .git directory: writing there means running code. *)
let safe_path p =
  p <> "" && p.[0] <> '/' && not (String.contains p '\\') && not (String.contains p '\000')
  && List.for_all (fun x -> x <> "" && x <> "." && x <> ".." && String.lowercase_ascii x <> ".git") (String.split_on_char '/' p)

(* ---------- processes and git ---------- *)

(* run a program; its stdout, and whether it succeeded *)
let capture ?(env = Unix.environment ()) prog args =
  let r, w = Unix.pipe ~cloexec:true () in
  let devnull = Unix.openfile "/dev/null" [ O_RDWR; O_CLOEXEC ] 0 in
  match Unix.create_process_env prog (Array.of_list (prog :: args)) env devnull w devnull with
  | exception e -> Unix.close r; Unix.close w; Unix.close devnull; (false, Printexc.to_string e)
  | pid ->
      Unix.close w; Unix.close devnull;
      let ic = Unix.in_channel_of_descr r in
      let out = In_channel.input_all ic in
      close_in ic;
      let _, st = Unix.waitpid [] pid in
      (st = Unix.WEXITED 0, out)

(* git for a checkout Pantheon owns: no user or system config, no hooks, no
   signing, so every node does exactly the same thing *)
let git_env extra =
  Array.of_list
    ([ "GIT_CONFIG_NOSYSTEM=1"; "GIT_CONFIG_GLOBAL=/dev/null"; "GIT_TERMINAL_PROMPT=0" ] @ extra
     @ List.filter (fun kv -> not (String.length kv > 4 && String.sub kv 0 4 = "GIT_")) (Array.to_list (Unix.environment ())))

let git ?(extra = []) dir args =
  capture ~env:(git_env extra) "git"
    ("-C" :: dir :: "-c" :: "core.hooksPath=/dev/null" :: "-c" :: "commit.gpgsign=false" :: "-c" :: "core.autocrlf=false"
     :: "-c" :: "core.fileMode=true" :: "-c" :: "core.symlinks=true" :: args)

let git_out dir args = String.trim (snd (git dir args))
let git_ok ?(extra = []) dir args = fst (git ~extra dir args)

(* a clone from anywhere git can fetch: here the user's own git config
   applies, for credentials to a private repository *)
let clone url dir commit =
  let ok, _ = capture ~env:(Array.append [| "GIT_TERMINAL_PROMPT=0" |] (Unix.environment ())) "git" [ "clone"; "--quiet"; url; dir ] in
  ok && git_ok dir [ "checkout"; "-q"; "--detach"; commit ]

(* ---------- edits ---------- *)

let matches_at s i sub =
  let k = String.length sub in
  let rec f j = j = k || (s.[i + j] = sub.[j] && f (j + 1)) in
  i + k <= String.length s && f 0

(* where sub occurs in s: the first two places at most *)
let positions s sub =
  let n = String.length s and k = String.length sub in
  let rec go i acc = if List.length acc >= 2 || i + k > n then List.rev acc else go (i + 1) (if matches_at s i sub then i :: acc else acc) in
  if k = 0 then [] else go 0 []

let contains s sub = positions s sub <> []

let replace_at s i old by = String.sub s 0 i ^ by ^ String.sub s (i + String.length old) (String.length s - i - String.length old)

(* no part of the path is a symlink: a write can't leave the checkout *)
let no_symlink dir p =
  let rec go cur = function
    | [] -> true
    | x :: r ->
        let c = Filename.concat cur x in
        (match (Unix.lstat c).st_kind with Unix.S_LNK -> false | _ -> go c r | exception Unix.Unix_error _ -> true)
  in
  go dir (String.split_on_char '/' p)

let write_keep_mode f s =
  let mode = try Some (Unix.stat f).st_perm with _ -> None in
  let tmp = f ^ ".pantheon-tmp" in
  Out_channel.with_open_bin tmp (fun oc -> output_string oc s);
  (match mode with Some m -> Unix.chmod tmp m | None -> ());
  Unix.rename tmp f

let rec triples_of = function p :: o :: n :: r -> (p, o, n) :: triples_of r | _ -> []

(* Apply edits, in order, to the files under dir. An edit replaces the one
   place its old text appears; with old "" it writes the whole file, and with
   new "" too it deletes the file. *)
let apply_edits dir edits =
  let rec go = function
    | [] -> Ok ()
    | (p, o, n) :: rest ->
        let f = Filename.concat dir p in
        if not (safe_path p) then Error ("unsafe path " ^ p)
        else if not (no_symlink dir p) then Error (p ^ " goes through a symlink")
        else if Sys.file_exists f && Sys.is_directory f then Error (p ^ " is a directory")
        else if o = "" && n = "" then (if Sys.file_exists f then (Sys.remove f; go rest) else Error (p ^ ": nothing to delete"))
        else if o = "" then (mkdir_p (Filename.dirname f); write_keep_mode f n; go rest)
        else if not (Sys.file_exists f) then Error (p ^ ": no such file to edit")
        else
          let c = read_file f in
          match positions c o with
          | [ i ] -> write_keep_mode f (replace_at c i o n); go rest
          | [] -> Error (p ^ ": the old text isn't in the file")
          | _ -> Error (p ^ ": the old text appears more than once, so give more of it")
  in
  try go edits with e -> Error (Printexc.to_string e)

(* A modified file as edits, one per hunk of git's diff, when replaying them
   on the old content gives the new; otherwise one whole-file write. *)
let hunk_edits dir p before now =
  let whole = [ (p, "", now) ] in
  let ok, d = git dir [ "diff"; "--cached"; "-U3"; "--no-color"; "--no-ext-diff"; "HEAD"; "--"; p ] in
  if not ok then whole
  else begin
    let hunks = ref [] and cur = ref None and bad = ref false in
    let close () = match !cur with Some (o, n) -> hunks := (String.concat "" (List.rev o), String.concat "" (List.rev n)) :: !hunks; cur := None | None -> () in
    List.iter (fun l ->
        if String.length l >= 2 && String.sub l 0 2 = "@@" then (close (); cur := Some ([], []))
        else
          match !cur with
          | None -> ()
          | Some (o, n) ->
              if l <> "" then
                let t = String.sub l 1 (String.length l - 1) ^ "\n" in
                match l.[0] with
                | ' ' -> cur := Some (t :: o, t :: n)
                | '-' -> cur := Some (t :: o, n)
                | '+' -> cur := Some (o, t :: n)
                | '\\' -> bad := true
                | _ -> ())
      (String.split_on_char '\n' d);
    close ();
    let es = List.rev_map (fun (o, n) -> (p, o, n)) !hunks in
    if !bad || es = [] || List.exists (fun (_, o, _) -> o = "") es then whole
    else
      let step acc (_, o, n) = match acc with Some c -> (match positions c o with [ i ] -> Some (replace_at c i o n) | _ -> None) | None -> None in
      if List.fold_left step (Some before) es = Some now then es else whole
  end

(* What changed in a checkout since its HEAD, as edits. Binary files, and
   new empty ones, can't be said as edits: they're listed as skipped. What
   the repository ignores (a build's output, from the model's soma build) is
   no part of it. Applying edits (check_tree, merges) still takes every path
   the edits name, ignored or not, so the tree doesn't hang on .gitignore. *)
let edits_of_checkout dir =
  if not (git_ok dir [ "add"; "-A" ]) then Error (dir ^ " is not a git checkout")
  else
    let ok, out = git dir [ "diff"; "--cached"; "--no-renames"; "--name-status"; "-z"; "HEAD" ] in
    if not ok then Error "git diff failed"
    else
      let rec pairs = function st :: p :: r -> (st, p) :: pairs r | _ -> [] in
      let skipped = ref [] in
      let edits =
        List.concat_map (fun (st, p) ->
            let f = Filename.concat dir p in
            match st.[0] with
            | 'D' -> [ (p, "", "") ]
            | ('A' | 'M') when not (safe_path p) -> skipped := p :: !skipped; []
            | 'A' | 'M' ->
                let now = read_file f in
                if String.contains now '\000' then (skipped := p :: !skipped; [])
                else if st.[0] = 'A' then (if now = "" then (skipped := p :: !skipped; []) else [ (p, "", now) ])
                else
                  let before = snd (git dir [ "show"; "HEAD:" ^ p ]) in
                  if now = "" then [ (p, before, "") ] else hunk_edits dir p before now
            | _ -> skipped := p :: !skipped; [])
          (pairs (List.filter (( <> ) "") (String.split_on_char '\000' out)))
      in
      Ok (edits, List.rev !skipped)

let edits_json edits note =
  `Assoc [ ("edits", `List (List.map (fun (p, o, n) -> `Assoc [ ("path", `String p); ("old", `String o); ("new", `String n) ]) edits));
           ("note", `String note) ]

(* the tree a bid's edits give on a checkout's HEAD, in a fresh clone *)
let check_tree repo head_tree edits out =
  let commit = git_out repo [ "rev-parse"; "HEAD" ] and tree = git_out repo [ "rev-parse"; "HEAD^{tree}" ] in
  if tree <> head_tree then Error (Printf.sprintf "node problem: this node's checkout %s is at tree %s, not the market's head %s" repo tree head_tree)
  else if not (fst (capture "git" [ "clone"; "--quiet"; "--shared"; "--no-checkout"; repo; out ])) then Error "node problem: cloning the checkout failed"
  else if not (git_ok out [ "checkout"; "-q"; "--detach"; commit ]) then Error "node problem: checking out the head failed"
  else
    match apply_edits out edits with
    | Error e -> Error e
    | Ok () -> if git_ok out [ "add"; "-A"; "-f" ] then Ok (git_out out [ "write-tree" ]) else Error "node problem: git add failed"

(* ---------- hash chains for the leader draw ---------- *)

let chain_len = 100_000
let rec iterate n x = if n = 0 then x else iterate (n - 1) (sha256 x)

(* ---------- keys, genesis, networks ---------- *)

let agents_default = [ "claude"; "codex"; "grok"; "muse" ]

let kv_arg flag kv =
  match String.index_opt kv '=' with
  | Some i -> (String.sub kv 0 i, String.sub kv (i + 1) (String.length kv - i - 1))
  | None -> fail "%s wants name=value, got %s" flag kv

(* An agent's keys, made on its own machine: key.json and chain.json stay
   there; public.json is what the network needs. *)
let make_keys home name addr =
  if Sys.file_exists (Filename.concat home "key.json") then
    fail "%s already has keys. They are this agent's identity: keep them. To start over, remove the directory first" home;
  mkdir_p home;
  Unix.chmod home 0o700;
  let key = Cryptokit.RSA.new_key ~rng:(Lazy.force rng) 2048 and secret = random_hex 32 in
  let priv f j = Yojson.Safe.to_file (Filename.concat home f) j; Unix.chmod (Filename.concat home f) 0o600 in
  priv "key.json" (`Assoc [ ("agent", `String name); ("key", key_to_json key ~priv:true) ]);
  priv "chain.json" (`Assoc [ ("secret", `String secret) ]);
  let pub = Filename.concat home "public.json" in
  Yojson.Safe.to_file pub
    (`Assoc [ ("name", `String name); ("addr", `String addr); ("pubkey", key_to_json key ~priv:false); ("tip", `String (iterate chain_len secret)) ]);
  pub

let cmd_keygen args =
  let home = ref "" and name = ref "" and addr = ref "" in
  let rec go = function
    | "--name" :: n :: r -> name := n; go r
    | "--addr" :: a :: r -> addr := a; go r
    | h :: r when !home = "" -> home := h; go r
    | x :: _ -> fail "unknown keygen argument %s" x
    | [] -> ()
  in
  go args;
  if !home = "" || !name = "" || !addr = "" then fail "usage: pantheon keygen HOME --name NAME --addr HOST:PORT (HOST: a name or address the other agents reach over the VPN)";
  let pub = make_keys !home !name !addr in
  say "wrote %s. Add it to the network as NETWORK/parts/%s.json (a pull request is a good way), then, once every agent's part is in, run: pantheon genesis %s NETWORK" pub !name !home

(* relative repository URLs are relative to the network directory *)
let repo_url net url =
  if contains url "://" || (url <> "" && url.[0] = '/') || (String.length url > 4 && String.sub url 0 4 = "git@") then url
  else Filename.concat net url

let repo_dir home name = Filename.concat (Filename.concat home "repos") name

(* A checkout of a governed repository at its genesis commit, or a check that
   the one already there descends from it. *)
let ensure_repo home name url commit =
  let dir = repo_dir home name in
  if not (Sys.file_exists (Filename.concat dir ".git")) then begin
    mkdir_p (Filename.dirname dir);
    if not (clone url dir commit) then fail "couldn't clone %s from %s at %s: check the URL, and that this machine can fetch it" name url commit
  end
  else if not (git_ok dir [ "merge-base"; "--is-ancestor"; commit; "HEAD" ]) then
    fail "%s holds a checkout of %s that doesn't descend from its genesis commit %s: move it aside and run again" dir name commit;
  dir

(* genesis.json, from NETWORK/network.json and NETWORK/parts/*.json: every
   agent builds the same bytes from the same files, so they compare one hash *)
let build_genesis home net =
  let open Yojson.Safe.Util in
  let netj = read_json (Filename.concat net "network.json") in
  let pdir = Filename.concat net "parts" in
  let files = if Sys.file_exists pdir then Sys.readdir pdir |> Array.to_list |> List.filter (fun f -> Filename.check_suffix f ".json") |> List.sort compare else [] in
  if List.length files < 4 then fail "%s has %d parts; a network needs 4 (n = 3f + 1 with f = 1). Each agent runs `pantheon keygen` and adds its public.json there" pdir (List.length files);
  let parts = List.map (fun f -> let j = read_json (Filename.concat pdir f) in
                          let n = to_string (member "name" j) in
                          if n ^ ".json" <> f then fail "%s/%s is named %s inside: rename the file to %s.json" pdir f n n;
                          `Assoc [ ("name", member "name" j); ("addr", member "addr" j); ("pubkey", member "pubkey" j); ("tip", member "tip" j) ]) files in
  let repos = List.map (fun r ->
      let name = to_string (member "name" r) and url = to_string (member "url" r) and commit = to_string (member "commit" r) in
      if not (safe_path name) || String.contains name '/' then fail "bad repository name %s" name;
      let dir = ensure_repo home name (repo_url net url) commit in
      let tree = git_out dir [ "rev-parse"; commit ^ "^{tree}" ] in
      `Assoc [ ("name", `String name); ("url", `String url); ("commit", `String commit); ("tree", `String tree) ])
      (to_list (member "repos" netj)) in
  let body = [ ("block_ms", (match member "block_ms" netj with `Int i -> `Int i | _ -> `Int 1000)); ("agents", `List parts);
               ("params", (match member "params" netj with `Assoc kv -> `Assoc kv | _ -> `Assoc [])); ("repos", `List repos) ] in
  let id = "pantheon-" ^ String.sub (sha256 (Yojson.Safe.to_string (`Assoc body))) 0 16 in
  let text = Yojson.Safe.to_string (`Assoc (("chain_id", `String id) :: body)) in
  let gp = Filename.concat home "genesis.json" in
  (match Sys.file_exists (Filename.concat home "key.json") with
   | true ->
       let k = read_json (Filename.concat home "key.json") in
       let me = to_string (member "agent" k) and n = to_string (member "n" (member "key" k)) in
       if not (List.exists (fun p -> to_string (member "name" p) = me && to_string (member "n" (member "pubkey" p)) = n) parts) then
         fail "%s's key isn't in %s: add this agent's public.json as parts/%s.json" me pdir me
   | false -> ());
  if Sys.file_exists gp && read_file gp <> text && Sys.file_exists (Filename.concat home "blocks.log") then
    fail "%s already runs a different chain (it has blocks). A new genesis is a new chain: use a new home, or remove blocks.log and signed.log on purpose" home;
  write_file gp text;
  say "wrote %s: chain %s, genesis hash %s. Every agent should get the same hash" gp id (sha256 text)

(* A whole network on one machine, for trying Pantheon and for tests. *)
let cmd_init args =
  let dir = ref "" and repos = ref [] and port = ref 26700 and params = ref [] and block_ms = ref 500 in
  let rec go = function
    | "--repo" :: kv :: r -> repos := !repos @ [ kv_arg "--repo" kv ]; go r
    | "--base-port" :: p :: r -> port := int_of_string p; go r
    | "--block-ms" :: p :: r -> block_ms := int_of_string p; go r
    | "--param" :: kv :: r -> params := !params @ [ kv_arg "--param" kv ]; go r
    | d :: r when !dir = "" -> dir := d; go r
    | x :: _ -> fail "unknown init argument %s" x
    | [] -> ()
  in
  go args;
  if !dir = "" || !repos = [] then fail "usage: pantheon init DIR --repo NAME=GIT-CHECKOUT [--repo ...] [--base-port P] [--block-ms N] [--param name=value]...";
  if Sys.file_exists (Filename.concat !dir "network") then
    fail "%s already holds a network, keys included. To discard it, stop its nodes and remove the directory; to keep it, pick another DIR" !dir;
  let net = Filename.concat !dir "network" in
  mkdir_p (Filename.concat net "parts");
  let abs p = if Filename.is_relative p then Filename.concat (Sys.getcwd ()) p else p in
  let repos = List.map (fun (n, path) ->
      let path = abs path in
      let commit = git_out path [ "rev-parse"; "HEAD" ] in
      if commit = "" then fail "%s is not a git checkout with a commit" path;
      `Assoc [ ("name", `String n); ("url", `String path); ("commit", `String commit) ]) !repos in
  Yojson.Safe.to_file (Filename.concat net "network.json")
    (`Assoc [ ("block_ms", `Int !block_ms); ("params", `Assoc (List.map (fun (k, v) -> (k, `String v)) !params)); ("repos", `List repos) ]);
  List.iteri (fun i n ->
      say "making keys for %s" n;
      let pub = make_keys (Filename.concat !dir n) n (Printf.sprintf "127.0.0.1:%d" (!port + i)) in
      write_file (Filename.concat (Filename.concat net "parts") (n ^ ".json")) (read_file pub))
    agents_default;
  List.iter (fun n -> build_genesis (Filename.concat !dir n) net) agents_default;
  say "made a 4-agent network in %s. Run it with: %s up %s" !dir Sys.argv.(0) !dir

(* ---------- the node ---------- *)

(* a peer's address is resolved at each connection attempt, so a replaced
   machine with the same VPN name is found again *)
type peer = { name : string; addr : string; mutable out : Unix.file_descr option; mutable connecting : bool;
              obuf : Buffer.t; mutable next_try : float }

type conn = { fd : Unix.file_descr; ibuf : Buffer.t }

type job = { jfd : Unix.file_descr; jpid : int; jbuf : Buffer.t; jdone : string -> unit; jstarted : float; jlimit : float; jclean : unit -> unit }

let split_addr s =
  match String.rindex_opt s ':' with
  | Some i -> (String.sub s 0 i, String.sub s (i + 1) (String.length s - i - 1))
  | None -> fail "bad address %s: want HOST:PORT" s

let resolve s =
  let host, port = split_addr s in
  match Unix.getaddrinfo host port [ Unix.AI_FAMILY Unix.PF_INET; Unix.AI_SOCKTYPE Unix.SOCK_STREAM ] with
  | a :: _ -> Some a.Unix.ai_addr
  | [] -> None
  | exception _ -> None

(* JSON reply -> flat [key; value; ...], arrays as indices: files.0.path *)
let flatten_reply j =
  let out = ref [] in
  let rec go prefix = function
    | `Assoc kv -> List.iter (fun (k, v) -> go (if prefix = "" then k else prefix ^ "." ^ k) v) kv
    | `List l -> List.iteri (fun i v -> go (prefix ^ "." ^ string_of_int i) v) l
    | `String s -> out := s :: prefix :: !out
    | `Bool b -> out := string_of_bool b :: prefix :: !out
    | `Null -> out := "null" :: prefix :: !out
    | `Int i -> out := string_of_int i :: prefix :: !out
    | `Intlit s -> out := s :: prefix :: !out
    | `Float f -> out := Printf.sprintf "%.0f" f :: prefix :: !out
    | _ -> ()
  in
  go "" j;
  List.rev !out

let json_in_reply text =
  match String.index_opt text '{', String.rindex_opt text '}' with
  | Some a, Some b when b > a -> (try Some (Yojson.Safe.from_string (String.sub text a (b - a + 1))) with _ -> None)
  | _ -> None

let rec run init step =
  let argv = Array.to_list Sys.argv |> List.tl in
  match argv with
  | "init" :: rest -> cmd_init rest
  | "keygen" :: rest -> cmd_keygen rest
  | [ "genesis"; home; net ] -> build_genesis home net
  | "edits" :: dir :: rest ->
      (* for a model with tools: what it changed in its checkout, as the reply a patch request wants *)
      (match edits_of_checkout dir with
       | Error e -> fail "%s" e
       | Ok (es, skipped) ->
           let note = String.concat " " rest ^ (if skipped = [] then "" else " (skipped, can't be edits: " ^ String.concat ", " skipped ^ ")") in
           print_endline (Yojson.Safe.to_string (edits_json es (String.trim note))))
  | [ "apply-edits"; dir; file ] ->
      (match apply_edits dir (triples_of (json_strings (Yojson.Safe.from_file file))) with
       | Ok () -> say "applied"
       | Error e -> fail "%s" e)
  | [ "check"; repo; head; file; out ] ->
      (match check_tree repo head (triples_of (json_strings (Yojson.Safe.from_file file))) out with
       | Ok t -> print_string t
       | Error e -> print_string e; exit 1)
  | [ "status"; home ] ->
      let p = Filename.concat home "status.txt" in
      if Sys.file_exists p then print_string (read_file p)
      else fail "no status in %s yet: is its node running? Start it with `pantheon node %s` or `pantheon up DIR`" home home
  | "tx" :: home :: fields when fields <> [] ->
      let d = Filename.concat home "inbox" in
      mkdir_p d;
      write_file (Filename.concat d (Printf.sprintf "%.6f.json" (Unix.gettimeofday ()))) (Yojson.Safe.to_string (strings_json fields));
      say "queued for %s's agent: %s (it signs and sends it next; see `pantheon status %s`)" (Filename.basename home) (String.concat " " fields) home
  | "up" :: dir :: rest ->
      let self = Sys.executable_name in
      let backends = ref [] and pass = ref [] in
      let rec go = function
        | "--backends" :: b :: r ->
            backends := List.map (fun kv -> match String.split_on_char '=' kv with [ a; b ] -> (a, b) | _ -> fail "--backends wants agent=backend,...") (String.split_on_char ',' b);
            go r
        | x :: r -> pass := !pass @ [ x ]; go r
        | [] -> ()
      in
      go rest;
      let pids =
        List.map (fun a ->
            let home = Filename.concat dir a in
            if not (Sys.file_exists (Filename.concat home "genesis.json")) then fail "%s has no network: run `pantheon init %s` first" dir dir;
            let log = Unix.openfile (Filename.concat home "node.log") [ O_WRONLY; O_CREAT; O_APPEND ] 0o644 in
            let b = try List.assoc a !backends with Not_found -> "scripted" in
            let args = Array.of_list ([ self; "node"; home; "--backend"; b ] @ !pass) in
            Unix.create_process self args Unix.stdin log log)
          (Sys.readdir dir |> Array.to_list |> List.sort compare |> List.filter (fun a -> Sys.file_exists (Filename.concat (Filename.concat dir a) "key.json")))
      in
      say "running 4 nodes; logs in %s/<agent>/node.log; watch with: %s status %s/claude" dir self dir;
      let stop _ = List.iter (fun p -> try Unix.kill p Sys.sigterm with _ -> ()) pids; exit 0 in
      Sys.set_signal Sys.sigint (Sys.Signal_handle stop);
      Sys.set_signal Sys.sigterm (Sys.Signal_handle stop);
      List.iter (fun p -> ignore (Unix.waitpid [] p)) pids
  | "node" :: home :: flags -> node init step home flags
  | _ ->
      print_string
        "pantheon: a private BFT labor market where LLM agents take turns as term leader.\n\n\
         \  One machine:\n\
         \  pantheon init DIR --repo NAME=GIT-CHECKOUT [--repo ...] [--base-port P] [--block-ms N] [--param name=value]...\n\
         \  pantheon up DIR [--backends claude=claude,codex=codex,grok=grok,muse=scripted] [node flags]\n\n\
         \  One machine per agent (see docs/NETWORK.md):\n\
         \  pantheon keygen HOME --name NAME --addr HOST:PORT     then add HOME/public.json to NETWORK/parts/\n\
         \  pantheon genesis HOME NETWORK                         once all 4 parts are in\n\n\
         \  pantheon node HOME [--backend B] [--behavior honest|deny|silent] [--goal FILE] [--deny PATH] [--listen HOST]\n\
         \                     [--ci CMD] [--ci-repo NAME CMD] [--ci-image IMAGE] [--ci-memory 8g] [--bid-window N] [--perspective TEXT] [--max-llm-calls N]\n\
         \  pantheon status HOME\n\
         \  pantheon tx HOME post REPO \"spec\" [CONTEXT-PATH...]   (or any market transaction's fields)\n\
         \  pantheon edits CHECKOUT [NOTE]     a checkout's changes as a patch reply (for models with tools)\n\
         \  pantheon apply-edits DIR EDITS.json\n\n\
         Backends: scripted, claude, codex, grok (XAI_API_KEY), cmd:PROGRAM (prompt on stdin, JSON reply on stdout;\n\
         a patch request also gets a scratch checkout in $PANTHEON_WORKTREE: see scripts/bidder.sh).\n"

and node init step home flags =
  Sys.set_signal Sys.sigpipe Sys.Signal_ignore;
  (* jobs run from scratch directories: every path the node hands out is absolute *)
  let home = if Filename.is_relative home then Filename.concat (Sys.getcwd ()) home else home in
  (* the home holds this agent's keys: nobody else reads it, models included *)
  (try Unix.chmod home 0o700 with _ -> ());
  let open Yojson.Safe.Util in
  let gen = read_json (Filename.concat home "genesis.json") in
  let keyf = read_json (Filename.concat home "key.json") in
  let me = to_string (member "agent" keyf) and key = key_of_json (member "key" keyf) in
  let secret = to_string (member "secret" (read_json (Filename.concat home "chain.json"))) in
  chain_id := to_string (member "chain_id" gen);
  let agents = to_list (member "agents" gen) in
  let names = List.map (fun a -> to_string (member "name" a)) agents in
  List.iter (fun a -> Hashtbl.replace pubkeys (to_string (member "name" a)) (key_of_json (member "pubkey" a))) agents;
  let addr_of_agent n = to_string (member "addr" (List.find (fun a -> to_string (member "name" a) = n) agents)) in
  let byz = try Sys.getenv "PANTHEON_BYZ" with Not_found -> "" in
  if byz <> "" then say "FAULT INJECTION: this node misbehaves on purpose (%s)" byz;
  (* flags: agent settings, given to Soma as events *)
  let backend = ref "scripted" and agent_events = ref [] and ci_cmd = ref "" and ci_repo = ref [] and ci_image = ref "alpine:3.20" in
  let listen = ref "0.0.0.0" and ci_memory = ref "8g" in
  let max_calls = ref 100 and calls = ref 0 in
  let rec go = function
    | "--backend" :: b :: r -> backend := b; go r
    | "--behavior" :: b :: r -> agent_events := !agent_events @ [ [ "agent"; "behavior"; b ] ]; go r
    | "--goal" :: f :: r -> agent_events := !agent_events @ List.map (fun l -> [ "agent"; "goal"; l ]) (lines f); go r
    | "--deny" :: p :: r -> agent_events := !agent_events @ [ [ "agent"; "deny"; p ] ]; go r
    | "--bid-window" :: n :: r -> agent_events := !agent_events @ [ [ "agent"; "bid_window"; n ] ]; go r
    | "--perspective" :: t :: r -> agent_events := !agent_events @ [ [ "agent"; "perspective"; t ] ]; go r
    | "--ci" :: c :: r -> ci_cmd := c; go r
    | "--ci-repo" :: n :: c :: r -> ci_repo := (n, c) :: !ci_repo; go r
    | "--listen" :: h :: r -> listen := h; go r
    | "--ci-memory" :: m :: r -> ci_memory := m; go r
    | "--ci-image" :: i :: r -> ci_image := i; go r
    | "--max-llm-calls" :: n :: r -> max_calls := int_of_string n; go r
    | x :: _ -> fail "unknown node flag %s" x
    | [] -> ()
  in
  go flags;
  let scripted = !backend = "scripted" || String.length !backend > 9 && String.sub !backend 0 9 = "scripted:" in
  if scripted && String.length !backend > 9 then agent_events := !agent_events @ [ [ "agent"; "behavior"; String.sub !backend 9 (String.length !backend - 9) ] ];
  let backend_kind = if scripted then "scripted" else "llm" in
  (* state *)
  let st = ref init in
  let queue = Queue.create () in
  let push ev = Queue.add ev queue in
  let height = ref 0 in
  let mine : (int * string list) list ref = ref [] in
  let my_txs : (float * string) list ref = ref [] in
  let blocks : (int, string list) Hashtbl.t = Hashtbl.create 64 in
  let served : (string * int, float) Hashtbl.t = Hashtbl.create 64 in
  let timers : (float * string list) list ref = ref [] in
  let jobs : job list ref = ref [] in
  let signed_path = Filename.concat home "signed.log" in
  (* slot -> (value id, the whole vote): "SLOT VID [VOTE-AS-JSON]" per line *)
  let signed : (string, string * string list option) Hashtbl.t = Hashtbl.create 64 in
  List.iter (fun l ->
      match String.index_opt l ' ' with
      | None -> ()
      | Some i ->
          let k = String.sub l 0 i and rest = String.sub l (i + 1) (String.length l - i - 1) in
          (match String.index_opt rest ' ' with
           | None -> Hashtbl.replace signed k (rest, None)
           | Some j ->
               let v = String.sub rest 0 j and js = String.sub rest (j + 1) (String.length rest - j - 1) in
               Hashtbl.replace signed k (v, (try Some (json_strings (Yojson.Safe.from_string js)) with _ -> None))))
    (lines signed_path);
  let blocks_path = Filename.concat home "blocks.log" in
  (* the governed repositories: a checkout each, at genesis or later *)
  let repos = List.map (fun r -> (to_string (member "name" r), to_string (member "url" r), to_string (member "commit" r), to_string (member "tree" r)))
                (try to_list (member "repos" gen) with _ -> []) in
  let net_dir = Filename.concat home "network" in
  List.iter (fun (n, url, commit, tree) ->
      let dir = ensure_repo home n (repo_url net_dir url) commit in
      if git_out dir [ "rev-parse"; commit ^ "^{tree}" ] <> tree then fail "genesis says repository %s's commit %s has tree %s; this clone disagrees" n commit tree)
    repos;
  let rdir n = repo_dir home n in
  (* the version of the last merge applied to a checkout: the merges
     replayed from blocks.log at startup are already in it *)
  let applied_of n =
    let body = snd (git (rdir n) [ "log"; "-1"; "--format=%B" ]) in
    List.fold_left (fun acc l -> match String.split_on_char ' ' l with [ "Pantheon-Version:"; v ] -> (try int_of_string v with _ -> acc) | _ -> acc) 0
      (String.split_on_char '\n' body)
  in
  let applied = Hashtbl.create 4 in
  List.iter (fun (n, _, _, _) -> Hashtbl.replace applied n (applied_of n)) repos;
  let diverged = ref [] in
  let ci_for r = try List.assoc r !ci_repo with Not_found -> !ci_cmd in
  let peers =
    List.filter_map (fun n ->
        if n = me then None
        else Some { name = n; addr = addr_of_agent n; out = None; connecting = false; obuf = Buffer.create 4096; next_try = 0. })
      names
  in
  let conns : conn list ref = ref [] in
  let msg_bytes from fields = String.concat "\x00" [ "msg"; !chain_id; from; Yojson.Safe.to_string (strings_json fields) ] in
  let wire fields =
    let sg = if byz = "bad-sig" then String.make 512 '0' else sign key (msg_bytes me fields) in
    Yojson.Safe.to_string (`Assoc [ ("from", `String me); ("fields", strings_json fields); ("sig", `String sg) ]) ^ "\n"
  in
  let send_to p line = if p.out <> None && Buffer.length p.obuf < 64 * 1024 * 1024 then Buffer.add_string p.obuf line in
  let broadcast_fields fields =
    if byz = "silent" then ()
    else
      let line = wire fields in
      List.iter (fun p -> send_to p line) peers
  in
  (* Byzantine variants of our own messages, for fault-injection tests *)
  let send_consensus fields =
    match byz, fields with
    | "equivocate", "proposal" :: h :: r :: vr :: _ :: _ ->
        let alt = [ "proposal"; h; r; vr; hash_list [ "equivocation"; h; r ]; "equivocation"; h; r ] in
        List.iteri (fun i p -> send_to p (wire (if i = 0 then fields else alt))) peers
    | "double-vote", k :: h :: r :: vr :: _ :: rest when k = "prevote" || k = "precommit" ->
        List.iteri (fun i p -> send_to p (wire (if i = 0 then fields else k :: h :: r :: vr :: "" :: rest))) peers
    | _ -> broadcast_fields fields
  in
  (* Never sign two different votes for one height, round and kind, even
     across a restart: that is the one thing an honest validator can't do.
     Asked to, it sends the vote it signed before instead: staying silent
     would hide that it's behind, and the others only send a node the blocks
     it missed when they hear from it. *)
  let guard fields =
    match fields with
    | k :: h :: r :: _ :: vid :: _ when k <> "done" ->
        let slot = String.concat "/" [ k; h; r ] in
        (match Hashtbl.find_opt signed slot with
         | Some (v, before) when v <> vid && byz = "" ->
             (match before with
              | Some f -> say "already signed a %s at %s: sending that one again" k slot; Some f
              | None -> say "refusing to sign a second %s at %s: already signed %s" k slot v; None)
         | Some _ -> Some fields
         | None ->
             Hashtbl.replace signed slot (vid, Some fields);
             append_line signed_path (slot ^ " " ^ vid ^ " " ^ Yojson.Safe.to_string (strings_json fields));
             Some fields)
    | _ -> Some fields
  in
  (* jobs the node stopped for running past their time limit *)
  let overtime = Hashtbl.create 8 in
  let start_job ?(limit = 600.) prog args ~stdin_text ~env ~on_done ~clean =
    let inp = Filename.temp_file "pantheon-in" ".txt" in
    write_file inp stdin_text;
    let ifd = Unix.openfile inp [ O_RDONLY ] 0 in
    let r, w = Unix.pipe ~cloexec:true () in
    let devnull = Unix.openfile "/dev/null" [ O_WRONLY ] 0 in
    let cwd = Filename.temp_dir "pantheon-llm" "" in
    let pid =
      try
        let old = Sys.getcwd () in
        Sys.chdir cwd;
        let pid = Unix.create_process_env prog (Array.of_list (prog :: args)) env ifd w devnull in
        Sys.chdir old;
        pid
      with e -> Unix.close r; Unix.close w; Unix.close ifd; Unix.close devnull; on_done ("!" ^ Printexc.to_string e); -1
    in
    if pid > 0 then begin
      Unix.close w; Unix.close ifd; Unix.close devnull;
      jobs := { jfd = r; jpid = pid; jbuf = Buffer.create 4096; jdone = on_done; jstarted = Unix.gettimeofday (); jlimit = limit;
                jclean = (fun () -> (try Sys.remove inp with _ -> ()); (try ignore (Sys.command ("rm -rf " ^ Filename.quote cwd)) with _ -> ()); clean ()) } :: !jobs
    end
  in
  let model_env () =
    Unix.environment () |> Array.to_list |> List.filter (fun kv -> not (String.length kv > 9 && String.sub kv 0 9 = "PANTHEON_")) |> Array.of_list
  in
  (* What a prompt asks for from the checkouts. The fence token is fresh and
     random, and Soma's fences defang "{{", so nothing quoted can close one. *)
  let fence_text token label body = Printf.sprintf "<<<UNTRUSTED %s %s>>>\n%s\n<<<END UNTRUSTED %s>>>\n" token label body token in
  let listing n cap =
    let fs = List.filter (( <> ) "") (String.split_on_char '\n' (git_out (rdir n) [ "ls-files" ])) in
    let shown = List.filteri (fun i _ -> i < cap) fs in
    String.concat "\n" shown ^ (if List.length fs > cap then Printf.sprintf "\n(and %d more)" (List.length fs - cap) else "")
  in
  let repos_text token = String.concat "" (List.map (fun (n, _, _, _) -> fence_text token ("files in " ^ n) (listing n 200)) repos) in
  let repo_text token r paths =
    if not (List.exists (fun (n, _, _, _) -> n = r) repos) then "(no repository " ^ r ^ ")\n"
    else
      let budget = ref (200 * 1024) in
      fence_text token ("files in " ^ r) (listing r 300)
      ^ String.concat "" (List.map (fun p ->
            if not (safe_path p) then ""
            else
              let ok, c = git (rdir r) [ "show"; "HEAD:" ^ p ] in
              let c = if not ok then "(no such file at the head)" else c in
              let c = if String.length c > min !budget (64 * 1024) then String.sub c 0 (min !budget (64 * 1024)) ^ "\n(cut here: the file goes on)" else c in
              budget := max 0 (!budget - String.length c);
              fence_text token ("file " ^ p) c) paths)
  in
  (* a model call: a scratch directory, no keys in reach; built-in backends
     have no tools, and a cmd: backend asked for a patch gets a fresh checkout *)
  (* A model's subscription or rate limit: its calls are held, not failed, until
     the limit should have reset (the time it gives, or a backoff from 15
     minutes, doubling to 2 hours), then asked again. Failing them would spend
     the agent's tries on calls bound to fail. *)
  let limited_until = ref 0. and limit_reason = ref "" and limit_backoff = ref 900. and held = ref [] and probing = ref false in
  let limit_words = [ "usage limit"; "rate limit"; "rate-limit"; "ratelimit"; "limit reached"; "limit exceeded"; "quota";
                      "too many requests"; "429"; "hit your limit"; "out of credits"; "credit balance"; "resource_exhausted" ] in
  let is_limit text = let t = String.lowercase_ascii text in List.exists (fun w -> contains t w) limit_words in
  (* seconds until the limit resets, if the message says *)
  let reset_in text =
    let t = String.lowercase_ascii text and now = Unix.gettimeofday () in
    let num_after i = let j = ref i in while !j < String.length t && t.[!j] >= '0' && t.[!j] <= '9' do incr j done;
                      if !j > i then Some (float_of_string (String.sub t i (!j - i)), !j) else None in
    let rec find_from k sub = if k + String.length sub > String.length t then None
                              else if String.sub t k (String.length sub) = sub then Some (k + String.length sub) else find_from (k + 1) sub in
    let unit_secs j = let rest = String.sub t j (min 12 (String.length t - j)) |> String.trim in
                      if String.length rest > 0 && rest.[0] = 'h' then 3600. else if String.length rest > 0 && rest.[0] = 's' then 1. else 60. in
    (* "...|1736000000": Claude Code's limit message ends with the reset time *)
    match String.rindex_opt t '|' with
    | Some i when (match num_after (i + 1) with Some (e, j) -> j = String.length (String.trim t) && e > now | None -> false) ->
        (match num_after (i + 1) with Some (e, _) -> Some (e -. now) | None -> None)
    | _ ->
        let after phrase = match find_from 0 phrase with
          | Some k -> let k = ref k in while !k < String.length t && t.[!k] = ' ' do incr k done;
                      (match num_after !k with Some (n, j) -> Some (n *. unit_secs j) | None -> None)
          | None -> None in
        match after "try again in" with Some x -> Some x | None -> after "resets in" in
  let note_limit text =
    let wait = match reset_in text with Some x when x > 0. -> x +. 10. | _ -> !limit_backoff in
    limit_backoff := min 7200. (!limit_backoff *. 2.);
    limited_until := Unix.gettimeofday () +. wait;
    limit_reason := String.sub text 0 (min 160 (String.length text));
    probing := false;
    say "LIMIT: %s says it has hit its limit, so its model calls are held for %.0f minutes: %s" !backend (wait /. 60.) !limit_reason in
  let hold f = held := f :: !held in
  let rec call_model id kind prompt0 ctx =
    let prompt = prompt0 in
    let token = random_hex 8 in
    let prompt = replace_all prompt "{{F}}" token in
    let prompt = if contains prompt "{{REPOS}}" then replace_all prompt "{{REPOS}}" (repos_text token) else prompt in
    let prompt = match ctx with r :: paths when contains prompt "{{REPO}}" -> replace_all prompt "{{REPO}}" (repo_text token r paths) | _ -> prompt in
    let reply text =
      let failed = String.length text > 0 && text.[0] = '!' in
      if (failed || json_in_reply text = None) && is_limit text then begin
        note_limit (if failed then String.sub text 1 (String.length text - 1) else text);
        hold (fun () -> call_model id kind prompt0 ctx)
      end
      else if failed then (limit_backoff := 900.; probing := false; push [ "llm_error"; id; String.sub text 1 (String.length text - 1) ])
      else begin
      limit_backoff := 900.; probing := false;
        match json_in_reply text with
        | Some j -> push ("llm_reply" :: id :: flatten_reply j)
        | None ->
            (* what came back instead, on one line, so the log shows why *)
            let t = String.trim (String.map (fun c -> if c = '\n' || c = '\r' then ' ' else c) text) in
            push [ "llm_error"; id;
                   if t = "" then "the reply was empty"
                   else Printf.sprintf "the reply had no JSON object: %s%s" (String.sub t 0 (min 200 (String.length t))) (if String.length t > 200 then "..." else "") ]
      end
    in
    match !backend with
    | "claude" ->
        start_job "claude" [ "-p"; "--tools"; ""; "--strict-mcp-config"; "--no-session-persistence"; "--setting-sources"; ""; "--output-format"; "text" ]
          ~stdin_text:prompt ~env:(model_env ()) ~on_done:reply ~clean:ignore
    | "codex" ->
        let out = Filename.temp_file "pantheon-codex" ".txt" in
        start_job "codex" [ "exec"; "--skip-git-repo-check"; "--ephemeral"; "--sandbox"; "read-only"; "--disable"; "shell_tool";
                            "--disable"; "unified_exec"; "--disable"; "apps"; "--disable"; "browser_use";
                            "-c"; "approval_policy=\"never\""; "-c"; "mcp_servers={}"; "-o"; out; "-" ]
          ~stdin_text:prompt ~env:(model_env ())
          ~on_done:(fun t -> if String.length t > 0 && t.[0] = '!' then reply t else reply (try read_file out with _ -> "!codex wrote no reply"))
          ~clean:(fun () -> try Sys.remove out with _ -> ())
    | "grok" ->
        let k = try Sys.getenv "XAI_API_KEY" with Not_found -> "" in
        if k = "" then push [ "llm_error"; id; "backend grok needs XAI_API_KEY" ]
        else begin
          let hdr = Filename.temp_file "pantheon-h" ".txt" in
          write_file hdr ("Authorization: Bearer " ^ k ^ "\nContent-Type: application/json\n");
          let body = Yojson.Safe.to_string (`Assoc [ ("model", `String (try Sys.getenv "GROK_MODEL" with Not_found -> "grok-4.7"));
                                                     ("messages", `List [ `Assoc [ ("role", `String "user"); ("content", `String prompt) ] ]) ]) in
          start_job "curl" [ "-s"; "-m"; "600"; "-H"; "@" ^ hdr; "-d"; "@-"; "https://api.x.ai/v1/chat/completions" ]
            ~stdin_text:body ~env:(Unix.environment ())
            ~on_done:(fun t ->
              try reply (Yojson.Safe.Util.(to_string (member "content" (member "message" (List.hd (to_list (member "choices" (Yojson.Safe.from_string t))))))))
              with _ -> push [ "llm_error"; id; "grok: " ^ String.sub t 0 (min 300 (String.length t)) ])
            ~clean:(fun () -> try Sys.remove hdr with _ -> ())
        end
    | b when String.length b > 4 && String.sub b 0 4 = "cmd:" ->
        let extra, clean, limit =
          match kind, ctx with
          | "patch", r :: _ when List.exists (fun (n, _, _, _) -> n = r) repos ->
              let wt = Filename.temp_dir "pantheon-work" "" in
              let commit = git_out (rdir r) [ "rev-parse"; "HEAD" ] in
              if fst (capture "git" [ "clone"; "--quiet"; "--shared"; "--no-checkout"; rdir r; wt ]) && git_ok wt [ "checkout"; "-q"; "--detach"; commit ] then
                ([ "PANTHEON_WORKTREE=" ^ wt; "PANTHEON_REPO=" ^ r; "PANTHEON_BIN=" ^ Sys.executable_name ],
                 (fun () -> ignore (Sys.command ("rm -rf " ^ Filename.quote wt))), 1800.)
              else ([], (fun () -> ignore (Sys.command ("rm -rf " ^ Filename.quote wt))), 600.)
          | _ -> ([], ignore, 600.)
        in
        start_job ~limit (String.sub b 4 (String.length b - 4)) [] ~stdin_text:prompt ~env:(Array.append (Array.of_list extra) (model_env ())) ~on_done:reply ~clean
    | b -> push [ "llm_error"; id; "unknown backend " ^ b ]
  in
  (* One CI job at a time on this node, the rest waiting their turn: two at
     once (a leader's merge check beside an attest) can take more memory than
     the machine has, and a build killed for memory reads as the bid's fault. *)
  let ci_busy = ref false and ci_waiting = Queue.create () in
  let ci_next () = match Queue.take_opt ci_waiting with Some f -> f () | None -> ci_busy := false in
  let with_ci f = if !ci_busy then Queue.add f ci_waiting else (ci_busy := true; f ()) in
  (* A check for an attestor: the bid's edits on the head, in a fresh clone,
     give a tree; then the repository's CI, if this node has one, runs on it in
     a container with no network, a read-only root and nobody's uid. *)
  let run_check id r head edits =
    let out = Filename.temp_dir "pantheon-check" "" in
    let ef = Filename.temp_file "pantheon-edits" ".json" in
    write_file ef (Yojson.Safe.to_string (strings_json edits));
    let ci = ci_for r in
    let rm_out () = ignore (Sys.command ("rm -rf " ^ Filename.quote out)) in
    (* ok is true, false (the bid's fault), or error (this node's: the agent
       abstains rather than blame the bid) *)
    let result ok tree why = push [ "check_result"; id; "ok"; (if ok then "true" else if contains why "node problem:" then "error" else "false"); "tree"; tree; "why"; why ] in
    start_job Sys.executable_name [ "check"; rdir r; head; ef; out ] ~stdin_text:"" ~env:(Unix.environment ())
      ~on_done:(fun t ->
        if String.length t > 0 && t.[0] = '!' then (say "check of request %s failed: %s" id t; result false "" t)
        else
          let tree = if byz = "bad-tree" then (say "FAULT INJECTION: naming a wrong tree"; sha256 ("lie" ^ id)) |> fun x -> String.sub x 0 40 else String.trim t in
          if ci = "" then result true tree ""
          else begin
            ignore (Sys.command ("chmod -R a+rX " ^ Filename.quote out));
            let name = "pantheon-ci-" ^ random_hex 6 in
            with_ci @@ fun () ->
            start_job ~limit:3600. "docker"
              [ "run"; "--rm"; "--name"; name; "--network=none"; "--read-only"; "--tmpfs"; "/tmp:exec,size=" ^ !ci_memory; "--cap-drop=ALL";
                "--security-opt=no-new-privileges"; "--pids-limit=512"; "--memory=" ^ !ci_memory; "--memory-swap=" ^ !ci_memory;
                "--user=65534:65534"; "-e"; "HOME=/tmp";
                (* its errors too, as start_job keeps only stdout; and a build the
                   kernel killed for the container's memory (oom_kill in its cgroup)
                   ends as 137, the way docker ends the container itself *)
                "-v"; out ^ ":/work:ro"; "-w"; "/work"; !ci_image; "sh"; "-c";
                "(" ^ ci ^ ") 2>&1; r=$?; if [ $r -ne 0 ] && grep -qs 'oom_kill [1-9]' /sys/fs/cgroup/memory.events; then exit 137; fi; exit $r" ]
              ~stdin_text:"" ~env:(Unix.environment ())
              ~on_done:(fun t ->
                let ok = not (String.length t > 0 && t.[0] = '!') in
                say "CI for request %s: %s" id (if ok then "passed" else "failed");
                (* docker itself failing is this node's problem, not the bid's *)
                let docker_down = (not ok) && (contains t "Cannot connect to the Docker daemon" || contains t "Unable to find image") in
                if not ok then say "CI for request %s said: %s" id (String.map (fun c -> if c = '\n' then ' ' else c) t);
                (* over budget is the bid's fault, but say which budget: docker ends
                   a container that passes its memory with 137, timeout with 124 *)
                let why =
                  if ok then ""
                  else if docker_down then "node problem: docker: " ^ t
                  else if contains t "(exit 137)" then "CI went over its memory budget (" ^ !ci_memory ^ ", no swap): the build needs less memory than that to merge"
                  else if contains t "(exit 124)" then "CI went over its time budget: the build has to finish within the limit its CI command gives"
                  else "CI failed" in
                result ok tree why;
                ci_next ())
              ~clean:(fun () -> ignore (Sys.command ("docker rm -f " ^ name ^ " >/dev/null 2>&1")); rm_out ())
          end)
      ~clean:(fun () -> (try Sys.remove ef with _ -> ()); if ci = "" then rm_out ())
  in
  (* A decided merge: the same edits on this node's checkout, committed the
     same way on every node, so every node gets the same commit. A checkout
     that doesn't reach the attested tree has diverged: that's loud, and it
     stops taking merges. *)
  let apply_merge r v tree bid task bidder spec edits =
    if not (Hashtbl.mem applied r) then say "a merge for repository %s, which this node doesn't have" r
    else if v <= Hashtbl.find applied r then ()
    else if List.mem_assoc r !diverged then ()
    else begin
      let dir = rdir r in
      let diverge why = say "DIVERGED: repository %s, merge %d: %s. Stopped taking merges for it." r v why; diverged := (r, Printf.sprintf "%d: %s" v why) :: !diverged in
      ignore (git dir [ "reset"; "-q"; "--hard"; "HEAD" ]);
      ignore (git dir [ "clean"; "-q"; "-f"; "-d"; "-x" ]);
      match apply_edits dir edits with
      | Error e -> diverge e
      | Ok () ->
          let date = Printf.sprintf "@%d +0000" (1_700_000_000 + v) in
          let who = [ "GIT_AUTHOR_NAME=Pantheon"; "GIT_AUTHOR_EMAIL=pantheon@localhost"; "GIT_COMMITTER_NAME=Pantheon";
                      "GIT_COMMITTER_EMAIL=pantheon@localhost"; "GIT_AUTHOR_DATE=" ^ date; "GIT_COMMITTER_DATE=" ^ date ] in
          let msg = Printf.sprintf "Merge bid %s for task %s by %s\n\n%s\n\nPantheon-Version: %d\nPantheon-Bid: %s\nPantheon-Tree: %s\n" bid task bidder spec v bid tree in
          ignore (git dir [ "add"; "-A"; "-f" ]);
          if not (git_ok ~extra:who dir [ "commit"; "-q"; "--allow-empty"; "--no-verify"; "--cleanup=verbatim"; "-m"; msg ]) then diverge "git commit failed"
          else
            let got = git_out dir [ "rev-parse"; "HEAD^{tree}" ] in
            if got <> tree then diverge (Printf.sprintf "got tree %s, attested %s" got tree)
            else (Hashtbl.replace applied r v; say "merged bid %s into %s: %s" bid r (git_out dir [ "rev-parse"; "--short"; "HEAD" ]))
    end
  in
  let handle out =
    match out with
    | "broadcast" :: fields ->
        (match guard fields with
         | Some f ->
             (match f with _ :: h :: _ -> mine := (int_of_string h, f) :: !mine | _ -> ());
             send_consensus f
         | None -> ())
    | [ "height"; h ] ->
        height := int_of_string h;
        mine := List.filter (fun (mh, _) -> mh >= !height) !mine
    | [ "timer"; name; h; r; ms ] -> timers := (Unix.gettimeofday () +. float_of_string ms /. 1000., [ "timeout"; name; h; r ]) :: !timers
    | "decided" :: h :: txs ->
        let h = int_of_string h in
        if not (Hashtbl.mem blocks h) then begin
          Hashtbl.replace blocks h txs;
          append_line blocks_path (Yojson.Safe.to_string (`Assoc [ ("h", `Int h); ("txs", strings_json txs) ]))
        end
    | [ "behind"; who; h ] ->
        let h = int_of_string h and now = Unix.gettimeofday () in
        (match Hashtbl.find_opt served (who, h) with
         | Some t when now -. t < 2. -> ()
         | _ ->
             Hashtbl.replace served (who, h) now;
             List.iter (fun p ->
                 if p.name = who then
                   for k = h to min (!height - 1) (h + 50) do
                     match Hashtbl.find_opt blocks k with
                     | Some txs when byz <> "silent" -> send_to p (wire ("done" :: string_of_int k :: "0" :: "0" :: hash_list txs :: txs))
                     | _ -> ()
                   done)
               peers)
    | "status" :: ls ->
        let heads = List.map (fun (n, _, _, _) -> Printf.sprintf "checkout %s %s" n (git_out (rdir n) [ "rev-parse"; "--short"; "HEAD" ])) repos in
        let bad = List.map (fun (r, why) -> Printf.sprintf "DIVERGED %s at merge %s" r why) !diverged in
        let lim = if Unix.gettimeofday () < !limited_until then
            [ Printf.sprintf "LIMIT %s until %s, %d model requests held: %s" !backend
                (let tm = Unix.localtime !limited_until in Printf.sprintf "%02d:%02d" tm.Unix.tm_hour tm.Unix.tm_min)
                (List.length !held) !limit_reason ] else [] in
        write_file (Filename.concat home "status.txt") (String.concat "\n" (ls @ heads @ bad @ lim) ^ "\n")
    | "merge" :: r :: v :: tree :: bid :: task :: bidder :: spec :: edits ->
        apply_merge r (int_of_string v) tree bid task bidder spec (triples_of edits)
    | [ "log"; text ] -> say "%s" text
    | "submit" :: nonce :: fields ->
        let raw = encode_tx key me nonce fields in
        my_txs := (Unix.gettimeofday (), raw) :: !my_txs;
        say "sending %s" (String.concat " " (List.map (fun f -> if String.length f > 60 then String.sub f 0 60 ^ "..." else f) fields));
        push [ "tx"; raw ];
        broadcast_fields [ "tx"; raw ]
    | "llm" :: id :: kind :: prompt :: ctx ->
        incr calls;
        if !calls > !max_calls then push [ "llm_error"; id; Printf.sprintf "model call budget of %d used up: restart with a higher --max-llm-calls" !max_calls ]
        else if Unix.gettimeofday () < !limited_until then begin
          say "holding request %s (a %s): %s is limited for %.0f more minutes" id kind !backend ((!limited_until -. Unix.gettimeofday ()) /. 60.);
          hold (fun () -> call_model id kind prompt ctx)
        end
        else (say "asking %s for a %s (request %s, call %d of %d)" !backend kind id !calls !max_calls; call_model id kind prompt ctx)
    | "check" :: id :: r :: head :: edits -> run_check id r head edits
    | [ "reveal"; t ] ->
        let t = int_of_string t in
        if byz = "withhold" && t mod 2 = 1 then say "FAULT INJECTION: holding back my link for draw %d" t
        else if t < chain_len then push [ "local_tx"; "reveal"; iterate (chain_len - t) secret ]
    | _ -> ()
  in
  let debug = (try Sys.getenv "PANTHEON_DEBUG" with Not_found -> "") <> "" in
  let brief l = String.concat " " (List.map (fun f -> if String.length f > 16 then String.sub f 0 16 else f) (List.filteri (fun i _ -> i < 7) l)) in
  let feed ev =
    if debug then say "event: %s" (brief ev);
    let s, outs = step !st ev in
    if debug then List.iter (fun o -> say "  out: %s" (brief o)) outs;
    st := s;
    List.iter handle outs
  in
  let drain () = while not (Queue.is_empty queue) do feed (Queue.pop queue) done in
  (* genesis, then what's on disk *)
  feed ("agents" :: names);
  List.iter (fun a -> feed [ "tip"; to_string (member "name" a); to_string (member "tip" a) ]) agents;
  feed [ "param"; "block_ms"; string_of_int (to_int (member "block_ms" gen)) ];
  List.iter (fun (k, v) -> feed [ "param"; k; to_string v ]) (to_assoc (member "params" gen));
  List.iter (fun (n, _, _, tree) -> feed [ "repo"; n; tree ]) repos;
  feed [ "me"; me ];
  feed [ "agent"; "backend"; backend_kind ];
  List.iter feed !agent_events;
  let replayed = ref 0 in
  List.iter (fun l ->
      try
        let j = Yojson.Safe.from_string l in
        let h = to_int (member "h" j) and txs = json_strings (member "txs" j) in
        if h = !replayed + 1 then (Hashtbl.replace blocks h txs; feed ("replay" :: string_of_int h :: txs); replayed := h)
      with _ -> ())
    (lines blocks_path);
  if !replayed > 0 then say "replayed %d blocks from disk" !replayed;
  feed [ "start" ];
  drain ();
  (* sockets *)
  let _, my_port = split_addr (addr_of_agent me) in
  let listener = Unix.socket ~cloexec:true PF_INET SOCK_STREAM 0 in
  Unix.setsockopt listener SO_REUSEADDR true;
  (match resolve (!listen ^ ":" ^ my_port) with
   | Some a -> (try Unix.bind listener a with e -> fail "can't listen on %s:%s (%s): is another node running here?" !listen my_port (Printexc.to_string e))
   | None -> fail "can't resolve --listen %s" !listen);
  Unix.listen listener 16;
  say "%s listening; peers %s; backend %s" me (String.concat ", " (List.map (fun p -> p.name) peers)) !backend;
  let last_rebroadcast = ref 0. and last_inbox = ref 0. in
  let close_peer p = (match p.out with Some fd -> (try Unix.close fd with _ -> ()) | None -> ()); p.out <- None; p.connecting <- false; Buffer.clear p.obuf in
  let on_line line =
    try
      let j = Yojson.Safe.from_string line in
      let from = to_string (member "from" j) and fields = json_strings (member "fields" j) and sg = to_string (member "sig" j) in
      match Hashtbl.find_opt pubkeys from with
      | Some k when from <> me && verify k (msg_bytes from fields) sg ->
          (match fields with [ "tx"; raw ] -> push [ "tx"; raw ] | _ -> push ("msg" :: from :: fields))
      | _ -> ()
    with _ -> ()
  in
  while true do
    let now = Unix.gettimeofday () in
    (* connect to peers we have no link to *)
    List.iter (fun p ->
        if p.out = None && now >= p.next_try then begin
          p.next_try <- now +. 1.;
          match resolve p.addr with
          | None -> ()
          | Some a ->
              let fd = Unix.socket ~cloexec:true PF_INET SOCK_STREAM 0 in
              Unix.set_nonblock fd;
              (try Unix.connect fd a; p.out <- Some fd
               with Unix.Unix_error ((EINPROGRESS | EWOULDBLOCK | EAGAIN), _, _) -> p.out <- Some fd; p.connecting <- true
                  | _ -> Unix.close fd)
        end)
      peers;
    (* every 2s, resend this height's messages and our recent transactions:
       links drop, and the protocol needs every message to arrive eventually *)
    if now -. !last_rebroadcast > 2. then begin
      last_rebroadcast := now;
      List.iter (fun (_, f) -> send_consensus f) (List.rev !mine);
      my_txs := List.filter (fun (t, _) -> now -. t < 120.) !my_txs;
      List.iter (fun (_, raw) -> broadcast_fields [ "tx"; raw ]) !my_txs
    end;
    (* after a limit's wait, one held request first: only when it comes back
       without the limit (which resets the backoff) do the rest go *)
    if !held <> [] && now >= !limited_until && not !probing then begin
      let hs = List.rev !held in
      if !limit_backoff > 900. then begin
        say "the limit's wait is over: asking %s one held request first (%d held)" !backend (List.length hs);
        held := List.rev (List.tl hs); probing := true; (List.hd hs) ()
      end else begin
        say "%s answers again: asking its %d held requests" !backend (List.length hs);
        held := []; List.iter (fun f -> f ()) hs
      end
    end;
    if now -. !last_inbox > 1. then begin
      last_inbox := now;
      let d = Filename.concat home "inbox" in
      if Sys.file_exists d then
        Array.iter (fun f ->
            let p = Filename.concat d f in
            if Filename.check_suffix f ".json" then begin
              (try push ("local_tx" :: json_strings (Yojson.Safe.from_file p)) with _ -> say "ignoring malformed %s" p);
              Sys.remove p
            end)
          (Sys.readdir d)
    end;
    (* timers due *)
    let due, later = List.partition (fun (t, _) -> t <= now) !timers in
    timers := later;
    List.iter (fun (_, ev) -> push ev) (List.sort compare due);
    (* model calls that ran too long *)
    List.iter (fun j -> if now -. j.jstarted > j.jlimit && not (Hashtbl.mem overtime j.jpid) then begin
        Hashtbl.replace overtime j.jpid j.jlimit; (try Unix.kill j.jpid Sys.sigkill with _ -> ()) end) !jobs;
    drain ();
    let wait = List.fold_left (fun m (t, _) -> min m (t -. now)) 0.2 !timers |> max 0. in
    let reads = listener :: List.map (fun c -> c.fd) !conns @ List.map (fun j -> j.jfd) !jobs in
    let writes = List.filter_map (fun p -> match p.out with Some fd when p.connecting || Buffer.length p.obuf > 0 -> Some fd | _ -> None) peers in
    let r, w, _ = try Unix.select reads writes [] wait with Unix.Unix_error (EINTR, _, _) -> ([], [], []) in
    List.iter (fun fd ->
        if fd = listener then begin
          let c, _ = Unix.accept ~cloexec:true listener in
          Unix.set_nonblock c;
          conns := { fd = c; ibuf = Buffer.create 4096 } :: !conns
        end)
      r;
    let buf = Bytes.create 65536 in
    conns := List.filter (fun c ->
        if not (List.mem c.fd r) then true
        else
          match Unix.read c.fd buf 0 65536 with
          | 0 -> Unix.close c.fd; false
          | n ->
              Buffer.add_subbytes c.ibuf buf 0 n;
              let s = Buffer.contents c.ibuf in
              let parts = String.split_on_char '\n' s in
              let rec take = function [ rest ] -> rest | l :: more -> on_line l; take more | [] -> "" in
              let rest = take parts in
              Buffer.clear c.ibuf;
              if String.length rest > 2 * max_tx_bytes * 60 then (Unix.close c.fd; false) else (Buffer.add_string c.ibuf rest; true)
          | exception Unix.Unix_error ((EAGAIN | EWOULDBLOCK), _, _) -> true
          | exception _ -> (try Unix.close c.fd with _ -> ()); false)
      !conns;
    (* finished jobs are taken off the list before their callbacks run: a
       callback may start the next job *)
    let finished = ref [] in
    jobs := List.filter (fun j ->
        if not (List.mem j.jfd r) then true
        else
          match Unix.read j.jfd buf 0 65536 with
          | 0 ->
              Unix.close j.jfd;
              let _, status = Unix.waitpid [] j.jpid in
              finished := (j, status) :: !finished;
              false
          | n -> Buffer.add_subbytes j.jbuf buf 0 n; true
          | exception _ -> true)
      !jobs;
    List.iter (fun (j, status) ->
        let out = Buffer.contents j.jbuf in
        (* the reply first: codex's is a file that cleaning removes *)
        (match status with
         | Unix.WEXITED 0 -> j.jdone (if out = "" then "pending" else out)
         | _ -> let n = String.length out in
                (* how it ended: CI tells an exceeded budget (137, 124) from a broken build by it *)
                (* OCaml numbers signals its own way (SIGKILL is -7): say their names *)
                let signame sg = if sg = Sys.sigkill then "SIGKILL" else if sg = Sys.sigterm then "SIGTERM"
                                 else if sg = Sys.sigsegv then "SIGSEGV" else if sg = Sys.sigabrt then "SIGABRT"
                                 else if sg = Sys.sigint then "SIGINT" else Printf.sprintf "signal %d" sg in
                let how = match status with
                  | Unix.WEXITED c -> Printf.sprintf "exit %d" c
                  | Unix.WSIGNALED _ when Hashtbl.mem overtime j.jpid ->
                      Printf.sprintf "it ran past its time limit of %.0f s, so the node stopped it" (Hashtbl.find overtime j.jpid)
                  | Unix.WSIGNALED sg -> "killed by " ^ signame sg
                  | Unix.WSTOPPED sg -> "stopped by " ^ signame sg in
                Hashtbl.remove overtime j.jpid;
                j.jdone (Printf.sprintf "!process failed (%s): %s" how (if n > 3000 then "..." ^ String.sub out (n - 3000) 3000 else out)));
        j.jclean ())
      (List.rev !finished);
    List.iter (fun p ->
        match p.out with
        | Some fd when List.mem fd w ->
            if p.connecting then begin
              p.connecting <- false;
              match Unix.getsockopt_error fd with None -> () | Some _ -> close_peer p
            end
            else begin
              let s = Buffer.contents p.obuf in
              match Unix.write_substring fd s 0 (String.length s) with
              | n -> Buffer.clear p.obuf; Buffer.add_string p.obuf (String.sub s n (String.length s - n))
              | exception Unix.Unix_error ((EAGAIN | EWOULDBLOCK), _, _) -> ()
              | exception _ -> close_peer p
            end
        | _ -> ())
      peers
  done
