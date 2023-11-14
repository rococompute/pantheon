(* The shell: everything Pantheon does that isn't a decision. Soma's node.soma
   decides; this runs it. Sockets, timers, keys and signatures, the block log,
   model processes and command implementations are here. Soma selects commands.

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

let rng = lazy (Cryptokit.Random.device_rng "/dev/urandom")
let random_hex n = hex (Cryptokit.Random.string (Lazy.force rng) n)

(* ---------- genesis, read by decode_tx: the same on every node ---------- *)

let chain_id = ref ""
let pubkeys : (string, Cryptokit.RSA.key) Hashtbl.t = Hashtbl.create 8
let max_tx_bytes = 256 * 1024
(* the most a job (a model's reply, a CI check) may print: well past any
   reply a transaction can carry. Soma reads the cap as a decimal string
   ([node_job_output_limit]); it is not a nat. *)
let max_job_output = 16 * max_tx_bytes

let strings_json l = `List (List.map (fun s -> `String s) l)
let json_strings = function `List l -> List.map (function `String s -> s | _ -> raise Exit) l | _ -> raise Exit

let tx_bytes agent nonce fields =
  String.concat "\x00" [ "tx"; !chain_id; agent; nonce; Yojson.Safe.to_string (strings_json fields) ]


(* A signed transaction's signature I/O: market.soma reads JSON tokens
   and decides the caps, bounded scan, members, nonce and verdict. *)
let tx_verify agent nonce fields sg =
  match Hashtbl.find_opt pubkeys agent with
  | Some key -> (try verify key (tx_bytes agent nonce fields) sg with _ -> false)
  | None -> false
let tx_byte_cap () = string_of_int max_tx_bytes
let tx_item_cap () = string_of_int max_int

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
(* The node's own binary, as an absolute path, fixed when the program starts
   and before anything changes directory (docs/SECURITY-REVIEW-2.md P-10):
   started as ./main.exe, a check or a model's PANTHEON_BIN run from a
   scratch directory would otherwise miss it. The path it was invoked as when
   that names a file (has a /), else what the system says it is. *)
let self_exe =
  let e = if Array.length Sys.argv > 0 && String.contains Sys.argv.(0) '/' then Sys.argv.(0) else Sys.executable_name in
  if Filename.is_relative e then Filename.concat (Sys.getcwd ()) e else e

let rec mkdir_p d = if d <> "" && d <> "." && d <> "/" && not (Sys.file_exists d) then (mkdir_p (Filename.dirname d); Unix.mkdir d 0o755)
(* A checkout removed in the background: one with a build in it is close to
   a GB, and removing it in the main loop stalled consensus for minutes *)
let remove_tree_later path = ignore (Sys.command ("rm -rf " ^ Filename.quote path ^ " >/dev/null 2>&1 &"))
let append_line p s = Out_channel.with_open_gen [ Open_append; Open_creat; Open_binary ] 0o644 p (fun oc -> output_string oc (s ^ "\n"); flush oc)
(* one write, then to disk: for what must survive a crash whole (a signed vote) *)
let append_line_synced p s =
  let fd = Unix.openfile p [ Unix.O_WRONLY; Unix.O_APPEND; Unix.O_CREAT ] 0o644 in
  Fun.protect ~finally:(fun () -> Unix.close fd) (fun () ->
      let b = Bytes.of_string (s ^ "\n") in
      let n = Unix.write fd b 0 (Bytes.length b) in
      if n <> Bytes.length b then failwith "signed.log: short write";
      Unix.fsync fd)
(* Atomic, synced consensus snapshots. A malformed snapshot aborts startup. *)
let save_consensus path state =
  let tmp = path ^ ".tmp" in
  let oc = open_out_bin tmp in
  Fun.protect ~finally:(fun () -> close_out oc) (fun () ->
      Marshal.to_channel oc state [];
      flush oc;
      Unix.fsync (Unix.descr_of_out_channel oc));
  Unix.rename tmp path;
  let fd = Unix.openfile (Filename.dirname path) [Unix.O_RDONLY] 0 in
  Fun.protect ~finally:(fun () -> Unix.close fd) (fun () -> Unix.fsync fd)

let load_consensus path =
  let ic = open_in_bin path in
  Fun.protect ~finally:(fun () -> close_in ic) (fun () -> Marshal.from_channel ic)

let read_json p = try Yojson.Safe.from_file p with _ -> fail "cannot read %s: is this a home made by `pantheon init`?" p
(* a file's bytes, or "" when there is none: Soma splits logs and goal files
   (node.soma's log_lines) *)
let file_text p = if Sys.file_exists p then read_file p else ""

(* A .plan's open items are computed in Soma ([plan_open] in util.soma), and
   so are the prompts that quote them (node.soma's perform_llm). *)

(* Soma's record crosses the binding as a product, then is named here.
   Callers carry it explicitly; no command installs global callbacks. *)
type helpers = {
  edit_once : string -> string -> string -> string option;
  contains : string -> string -> bool;
  safe_path : string -> bool;
}
let unpack_helpers ((edit_once, contains), safe_path) =
  { edit_once; contains; safe_path }
let safe_path h p = h.safe_path p
let edit_once h s old by = h.edit_once s old by
(* Soma takes the pattern first; shell callers take the text first. *)
let contains h s sub = h.contains sub s

(* ---------- processes and git ---------- *)

(* run a program; its stdout, and whether it succeeded. With [stdin], the
   program reads that text on its standard input (from a temporary file, so
   no pipe can fill up while its output is read) instead of /dev/null *)
let capture ?(env = Unix.environment ()) ?stdin prog args =
  let r, w = Unix.pipe ~cloexec:true () in
  let devnull = Unix.openfile "/dev/null" [ O_RDWR; O_CLOEXEC ] 0 in
  let inp, cleanup =
    match stdin with
    | None -> (devnull, fun () -> ())
    | Some text ->
        let f = Filename.temp_file "pantheon-stdin" ".txt" in
        Out_channel.with_open_bin f (fun oc -> output_string oc text);
        let fd = Unix.openfile f [ O_RDONLY; O_CLOEXEC ] 0 in
        (fd, fun () -> Unix.close fd; (try Sys.remove f with _ -> ()))
  in
  match Unix.create_process_env prog (Array.of_list (prog :: args)) env inp w devnull with
  | exception e -> Unix.close r; Unix.close w; Unix.close devnull; cleanup (); (false, Printexc.to_string e)
  | pid ->
      Unix.close w; Unix.close devnull; cleanup ();
      let ic = Unix.in_channel_of_descr r in
      let out = In_channel.input_all ic in
      close_in ic;
      let _, st = Unix.waitpid [] pid in
      (st = Unix.WEXITED 0, out)

(* git for a checkout Pantheon owns: no user or system config, no hooks, no
   signing, so every node does exactly the same thing *)
let git_env extra =
  Array.of_list
    (extra @ [ "GIT_CONFIG_NOSYSTEM=1"; "GIT_CONFIG_GLOBAL=/dev/null"; "GIT_TERMINAL_PROMPT=0" ]
     @ List.filter (fun kv -> not (String.length kv > 4 && String.sub kv 0 4 = "GIT_")) (Array.to_list (Unix.environment ())))

let git ?(extra = []) ?stdin dir args =
  capture ~env:(git_env extra) ?stdin "git"
    ("-C" :: dir :: "-c" :: "core.hooksPath=/dev/null" :: "-c" :: "commit.gpgsign=false" :: "-c" :: "core.autocrlf=false"
     :: "-c" :: "core.fileMode=true" :: "-c" :: "core.symlinks=true" :: args)

let git_out dir args = String.trim (snd (git dir args))
let git_ok ?(extra = []) ?stdin dir args = fst (git ~extra ?stdin dir args)

(* text with every control character but tab and newline made a space: what
   the market's plain_text accepts (docs/SECURITY-REVIEW-2.md P-17) *)
let plain_text s = String.map (fun c -> if (c < ' ' && c <> '\t' && c <> '\n') || c = '\127' then ' ' else c) s

(* a clone from anywhere git can fetch: here the user's own git config
   applies, for credentials to a private repository *)
let clone url dir commit =
  let ok, _ = capture ~env:(Array.append [| "GIT_TERMINAL_PROMPT=0" |] (Unix.environment ())) "git" [ "clone"; "--quiet"; url; dir ] in
  ok && git_ok dir [ "checkout"; "-q"; "--detach"; commit ]

(* ---------- edits ---------- *)

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
let apply_edits helpers dir edits =
  let rec go = function
    | [] -> Ok ()
    | (p, o, n) :: rest ->
        let f = Filename.concat dir p in
        if not (safe_path helpers p) then Error ("unsafe path " ^ p)
        else if not (no_symlink dir p) then Error (p ^ " goes through a symlink")
        else if Sys.file_exists f && Sys.is_directory f then Error (p ^ " is a directory")
        else if o = "" && n = "" then (if Sys.file_exists f then (Sys.remove f; go rest) else Error (p ^ ": nothing to delete"))
        else if o = "" then (mkdir_p (Filename.dirname f); write_keep_mode f n; go rest)
        else if not (Sys.file_exists f) then Error (p ^ ": no such file to edit")
        else
          let c = read_file f in
          match edit_once helpers c o n with
          | Some t -> write_keep_mode f t; go rest
          | None when not (contains helpers c o) -> Error (p ^ ": the old text isn't in the file")
          | None -> Error (p ^ ": the old text appears more than once, so give more of it")
  in
  try go edits with e -> Error (Printexc.to_string e)

(* A modified file as edits, one per hunk of git's diff, when replaying them
   on the old content gives the new; otherwise one whole-file write. *)
let hunk_edits helpers g p before now =
  let whole = [ (p, "", now) ] in
  let ok, d = g [ "diff"; "--cached"; "-U3"; "--no-color"; "--no-ext-diff"; "--no-textconv"; "HEAD"; "--"; p ] in
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
      let step acc (_, o, n) = match acc with Some c -> edit_once helpers c o n | None -> None in
      if List.fold_left step (Some before) es = Some now then es else whole
  end

(* What changed in a checkout since its HEAD, as edits. Binary files, and
   new empty ones, can't be said as edits: they're listed as skipped. What
   the repository ignores (a build's output, from the model's soma build) is
   no part of it. Applying edits (check_tree, merges) still takes every path
   the edits name, ignored or not, so the tree doesn't hang on .gitignore.

   The checkout is the model's to write, so nothing in it is trusted:
   - only regular files count: a symlink (mode 120000) would otherwise make
     the node read whatever it points at (a key, a login) into a signed bid;
   - the snapshot is built in a node-owned temporary repository whose
     config (and global/system config) is an empty file the node wrote:
     the checkout's .git and PANTHEON_GITDIR are only read, as plain files,
     for their HEAD and their object store (through alternates), so no
     config they hold is ever used -- no clean/smudge filters, fsmonitor,
     textconv or external diff can run. Each worktree file is hashed with
     [git hash-object -w --no-filters] into that snapshot, and changed
     files are staged there with [update-index --cacheinfo], never with
     [git add] on a repository the model can configure. *)
let edits_of_checkout helpers dir =
  let abs_dir = if Filename.is_relative dir then Filename.concat (Sys.getcwd ()) dir else dir in
  let read_opt p = try Some (read_file p) with _ -> None in
  let has_prefix s pre = String.length s >= String.length pre && String.sub s 0 (String.length pre) = pre in
  let resolve_rel base p = if Filename.is_relative p then Filename.concat base p else p in
  let is_hex s =
    s <> "" && String.for_all (fun c -> (c >= '0' && c <= '9') || (c >= 'a' && c <= 'f') || (c >= 'A' && c <= 'F')) s
  in
  (* the repository that holds HEAD and the objects: the checkout's .git
     (a directory, or a gitdir: file), or PANTHEON_GITDIR when the node
     kept the repository outside the checkout *)
  let orig_gitdir =
    match Sys.getenv_opt "PANTHEON_GITDIR" with
    | Some g when g <> "" -> resolve_rel abs_dir g
    | _ ->
        let dot = Filename.concat abs_dir ".git" in
        (match (try Some (Unix.stat dot).st_kind with _ -> None) with
         | Some Unix.S_DIR -> dot
         | _ ->
             (match read_opt dot with
              | Some c ->
                  let t = String.trim c in
                  if has_prefix t "gitdir:" then resolve_rel abs_dir (String.trim (String.sub t 7 (String.length t - 7))) else dot
              | None -> dot))
  in
  let common_gitdir =
    match read_opt (Filename.concat orig_gitdir "commondir") with
    | Some c -> resolve_rel orig_gitdir (String.trim c)
    | None -> orig_gitdir
  in
  (* HEAD's commit, from the ref files alone: no git command runs on
     this repository, so nothing its config names can run either *)
  let head_commit =
    let from_ref refname =
      match List.find_map read_opt [ Filename.concat orig_gitdir refname; Filename.concat common_gitdir refname ] with
      | Some c when is_hex (String.trim c) -> Some (String.trim c)
      | _ ->
          (match List.find_map read_opt [ Filename.concat orig_gitdir "packed-refs"; Filename.concat common_gitdir "packed-refs" ] with
           | None -> None
           | Some content ->
               List.find_map
                 (fun line ->
                   let line = String.trim line in
                   if line = "" || line.[0] = '#' || line.[0] = '^' then None
                   else
                     match String.index_opt line ' ' with
                     | Some i when String.sub line (i + 1) (String.length line - i - 1) = refname && is_hex (String.sub line 0 i) ->
                         Some (String.sub line 0 i)
                     | _ -> None)
                 (String.split_on_char '\n' content))
    in
    match read_opt (Filename.concat orig_gitdir "HEAD") with
    | None -> None
    | Some c ->
        let t = String.trim c in
        if has_prefix t "ref:" then from_ref (String.trim (String.sub t 4 (String.length t - 4)))
        else if is_hex t then Some t
        else None
  in
  match head_commit with
  | None -> Error (dir ^ " is not a git checkout")
  | Some head_commit ->
      let snapshot = Filename.temp_dir "pantheon-snapshot" "" in
      let result =
        try
          let snap_git = Filename.concat snapshot "gitdir" in
          mkdir_p (Filename.concat (Filename.concat snap_git "objects") "info");
          mkdir_p (Filename.concat snap_git "refs");
          write_file (Filename.concat snap_git "config") "";
          write_file (Filename.concat snap_git "HEAD") (head_commit ^ "\n");
          write_file (Filename.concat (Filename.concat (Filename.concat snap_git "objects") "info") "alternates")
            (Filename.concat common_gitdir "objects" ^ "\n");
          let empty_config = Filename.concat snapshot "gitconfig" in
          write_file empty_config "";
          let sgit args =
            git ~extra:[ "GIT_CONFIG_GLOBAL=" ^ empty_config; "GIT_CONFIG_SYSTEM=" ^ empty_config;
                         "GIT_INDEX_FILE=" ^ Filename.concat snap_git "index" ]
              abs_dir
              ("-c" :: "core.fsmonitor=false" :: ("--git-dir=" ^ snap_git) :: ("--work-tree=" ^ abs_dir) :: args)
          in
          let blob spec = let ok, c = sgit [ "cat-file"; "blob"; spec ] in if ok then Some c else None in
          let ok, out = sgit [ "ls-tree"; "-r"; "-z"; "HEAD" ] in
          if not ok then Error (dir ^ " is not a git checkout")
          else
            let head_tbl = Hashtbl.create 64 in
            let head_paths =
              List.filter_map
                (fun entry ->
                  match String.index_opt entry '\t' with
                  | Some tab ->
                      let meta = String.split_on_char ' ' (String.sub entry 0 tab) in
                      let p = String.sub entry (tab + 1) (String.length entry - tab - 1) in
                      (match meta with mode :: _ :: sha :: _ -> Hashtbl.replace head_tbl p (mode, sha) | _ -> ());
                      Some p
                  | None -> None)
                (List.filter (( <> ) "") (String.split_on_char '\000' out))
            in
            let ok, out = sgit [ "ls-files"; "--others"; "--exclude-standard"; "-z" ] in
            if not ok then Error "git ls-files failed"
            else
              let paths =
                List.sort_uniq String.compare (List.filter (( <> ) "") (String.split_on_char '\000' out) @ head_paths)
              in
              let skipped = ref [] and edits = ref [] in
              List.iter
                (fun p ->
                  if List.exists (fun x -> String.lowercase_ascii x = ".git") (String.split_on_char '/' p) then ()
                  else if not (safe_path helpers p) then skipped := p :: !skipped
                  else
                    let f = Filename.concat abs_dir p in
                    let head_entry = Hashtbl.find_opt head_tbl p in
                    match (try Some (Unix.lstat f) with _ -> None) with
                    | None -> (match head_entry with Some _ -> edits := !edits @ [ (p, "", "") ] | None -> ())
                    | Some st when st.st_kind <> Unix.S_REG -> skipped := p :: !skipped
                    | Some st when not (no_symlink abs_dir p) -> skipped := p :: !skipped
                    | Some st ->
                        let mode = if st.st_perm land 0o100 <> 0 then "100755" else "100644" in
                        let ok, hout = sgit [ "hash-object"; "-w"; "--no-filters"; "--"; p ] in
                        let hash = String.trim hout in
                        if not ok || not (is_hex hash) then skipped := p :: !skipped
                        else
                          (match head_entry with
                           | None ->
                               let now = read_file f in
                               if String.contains now '\000' || now = "" then skipped := p :: !skipped
                               else edits := !edits @ [ (p, "", now) ]
                           | Some (hmode, _) when hmode <> "100644" && hmode <> "100755" -> skipped := p :: !skipped
                           | Some (hmode, hsha) when hash = hsha && mode = hmode -> ()
                           | Some (_, hsha) ->
                               let now = read_file f in
                               if String.contains now '\000' then skipped := p :: !skipped
                               else if hash = hsha then edits := !edits @ [ (p, "", now) ]
                               else if now = "" then
                                 edits := !edits @ [ (p, Option.value ~default:"" (blob ("HEAD:" ^ p)), "") ]
                               else if fst (sgit [ "update-index"; "--add"; "--cacheinfo"; mode; hash; p ]) then
                                 edits := !edits @ hunk_edits helpers sgit p (Option.value ~default:"" (blob ("HEAD:" ^ p))) now
                               else edits := !edits @ [ (p, "", now) ]))
                paths;
              Ok (!edits, List.rev !skipped)
        with e -> Error (Printexc.to_string e)
      in
      remove_tree_later snapshot;
      result

let edits_json edits note =
  `Assoc [ ("edits", `List (List.map (fun (p, o, n) -> `Assoc [ ("path", `String p); ("old", `String o); ("new", `String n) ]) edits));
           ("note", `String note) ]

(* the tree a bid's edits give on a checkout's HEAD, in a fresh clone. An
   error says whose it is: `Node (this node's checkout or git) or `Bid (the
   edits don't apply), decided here, never read back from the message *)
let check_tree helpers repo head_tree edits out =
  let commit = git_out repo [ "rev-parse"; "HEAD" ] and tree = git_out repo [ "rev-parse"; "HEAD^{tree}" ] in
  if tree <> head_tree then Error (`Node, Printf.sprintf "node problem: this node's checkout %s is at tree %s, not the market's head %s" repo tree head_tree)
  else if not (fst (capture "git" [ "clone"; "--quiet"; "--shared"; "--no-checkout"; repo; out ])) then Error (`Node, "node problem: cloning the checkout failed")
  else if not (git_ok out [ "checkout"; "-q"; "--detach"; commit ]) then Error (`Node, "node problem: checking out the head failed")
  else
    match apply_edits helpers out edits with
    | Error e -> Error (`Bid, e)
    | Ok () -> if git_ok out [ "add"; "-A"; "-f" ] then Ok (git_out out [ "write-tree" ]) else Error (`Node, "node problem: git add failed")

(* how `pantheon check` says the failure is the edits' (they don't apply):
   any other failing exit is this node's *)
let check_bid_failed = 1

(* how a CI command, wrapped by the node, says the bid's CI failed. Any other
   failing exit of the runner (docker's own 125-127, ci-sandbox's 2 and 3,
   bwrap or systemd-run failing) is the runner's, so this node's. The bid's
   exits are remapped to this inside the runner, except 124 and 137 (its
   time and memory budgets, also the bid's) (docs/SECURITY-REVIEW-2.md P-6) *)
let ci_bid_failed = 86
(* "( " with a space: where sh is bash (Fedora), "((" starts arithmetic *)
let ci_wrap ci =
  "( " ^ ci ^ "\n) 2>&1; r=$?; if [ $r -ne 0 ] && grep -qs 'oom_kill [1-9]' /sys/fs/cgroup/memory.events; then exit 137; fi; "
  ^ "case $r in 0|124|137) exit $r;; esac; exit " ^ string_of_int ci_bid_failed

(* how a job ended ("!process failed (HOW): ") and its exit code are read in
   Soma (node.soma's ci_job_how and ci_exit_code), never here *)

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
let repo_url helpers net url =
  if contains helpers url "://" || (url <> "" && url.[0] = '/') || (String.length url > 4 && String.sub url 0 4 = "git@") then url
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
let build_genesis helpers home net =
  let open Yojson.Safe.Util in
  let netj = read_json (Filename.concat net "network.json") in
  let pdir = Filename.concat net "parts" in
  let files = if Sys.file_exists pdir then Sys.readdir pdir |> Array.to_list |> List.filter (fun f -> Filename.check_suffix f ".json") |> List.sort compare else [] in
  (* at least four agents: n >= 3f + 1 tolerates f = (n - 1) / 3 faulty
     ones, consensus's quorum being n - f; 4, 7 and 10 are the n that need
     the fewest votes for their f, and any n of 4 or more is safe *)
  let n = List.length files in
  if n < 4 then
    fail "genesis must have at least 4 parts, got %d (%s has %d parts; n agents tolerate (n - 1) / 3 faulty ones, so four is the fewest that tolerate one. Each agent runs `pantheon keygen` and adds its public.json there)"
      n pdir n;
  let raw_parts = List.map (fun f -> (f, read_json (Filename.concat pdir f))) files in
  let seen_names = ref [] in
  List.iter (fun (_, j) ->
      let n = to_string (member "name" j) in
      if List.mem n !seen_names then fail "duplicate part name %s in genesis parts in %s: each agent must add exactly one part under its own name" n pdir;
      seen_names := n :: !seen_names) raw_parts;
  let seen_keys = ref [] in
  List.iter (fun (_, j) ->
      let n = to_string (member "name" j) in
      let k = match member "pubkey" j with
        | `Assoc kv -> Yojson.Safe.to_string (`Assoc (List.sort (fun (a, _) (b, _) -> String.compare a b) kv))
        | other -> Yojson.Safe.to_string other in
      (match List.assoc_opt k !seen_keys with
       | Some other -> fail "duplicate public key in genesis parts in %s: %s and %s share the same public key; each part must carry its own agent's key" pdir other n
       | None -> ());
      seen_keys := (k, n) :: !seen_keys) raw_parts;
  let parts = List.map (fun (f, j) ->
                          let n = to_string (member "name" j) in
                          if n ^ ".json" <> f then fail "%s/%s is named %s inside: rename the file to %s.json" pdir f n n;
                          let ex = match member "exclude" j with `List l -> List.map to_string l | `Null -> [] | _ -> fail "%s/%s: exclude is a list of repository names" pdir f in
                          `Assoc ([ ("name", member "name" j); ("addr", member "addr" j); ("pubkey", member "pubkey" j); ("tip", member "tip" j) ]
                                  @ (if ex = [] then [] else [ ("exclude", `List (List.map (fun r -> `String r) ex)) ]))) raw_parts in
  let repos = List.map (fun r ->
      let name = to_string (member "name" r) and url = to_string (member "url" r) and commit = to_string (member "commit" r) in
      if not (safe_path helpers name) || String.contains name '/' then fail "bad repository name %s" name;
      let dir = ensure_repo home name (repo_url helpers net url) commit in
      let tree = git_out dir [ "rev-parse"; commit ^ "^{tree}" ] in
      `Assoc [ ("name", `String name); ("url", `String url); ("commit", `String commit); ("tree", `String tree) ])
      (to_list (member "repos" netj)) in
  (* a part's exclude names repositories outside that agent's scope: each is
     one of the network's, and every repository keeps someone whose scope has
     it, or no one could merge there *)
  let rnames = List.map (fun r -> to_string (member "name" r)) repos in
  let excl p = match member "exclude" p with `List l -> List.map to_string l | _ -> [] in
  List.iter (fun p -> List.iter (fun r -> if not (List.mem r rnames) then
      fail "%s/%s.json excludes %s, which isn't one of the network's repositories (%s)" pdir (to_string (member "name" p)) r (String.concat ", " rnames)) (excl p)) parts;
  List.iter (fun r -> if List.for_all (fun p -> List.mem r (excl p)) parts then
      fail "every part in %s excludes repository %s: no agent could merge there; drop it from network.json or from one part's exclude" pdir r) rnames;
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
let cmd_init packed args =
  let helpers = unpack_helpers packed in
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
  List.iter (fun n -> build_genesis helpers (Filename.concat !dir n) net) agents_default;
  say "made a 4-agent network in %s. Run it with: %s up %s" !dir self_exe !dir

let cmd_genesis packed home net =
  let helpers = unpack_helpers packed in
  build_genesis helpers home net

(* ---------- the node ---------- *)

(* a peer's address is resolved at each connection attempt, so a replaced
   machine with the same VPN name is found again *)
type peer = { name : string; addr : string; mutable out : Unix.file_descr option; mutable connecting : bool;
              obuf : Buffer.t; mutable next_try : float }

type conn = { cid : int; fd : Unix.file_descr; host : string; mutable last : float }

(* inbound connections: peers are a handful, so these are generous *)
let max_conns = 64
let max_conns_per_host = 16
(* a line's longest: a proposal of max_block_txs transactions, quoted *)
let max_line = 2 * max_tx_bytes * 60

type job = { jid : string; jfd : Unix.file_descr; jpid : int;
             jdone : string -> unit; jstarted : float; jlimit : float; jclean : unit -> unit }

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

let cmd_edits packed dir rest =
  let helpers = unpack_helpers packed in
      (* for a model with tools: what it changed in its checkout, as the reply a patch request wants *)
      (match edits_of_checkout helpers dir with
       | Error e -> fail "%s" e
       | Ok (es, skipped) ->
           let note = String.concat " " rest ^ (if skipped = [] then "" else " (skipped, can't be edits: " ^ String.concat ", " skipped ^ ")") in
           print_endline (Yojson.Safe.to_string (edits_json es (String.trim note))))

let cmd_apply_edits packed dir file =
  let helpers = unpack_helpers packed in
      (match apply_edits helpers dir (triples_of (json_strings (Yojson.Safe.from_file file))) with
       | Ok () -> say "applied"
       | Error e -> fail "%s" e)

let cmd_check packed repo head file out =
  let helpers = unpack_helpers packed in
      (match check_tree helpers repo head (triples_of (json_strings (Yojson.Safe.from_file file))) out with
       | Ok t -> print_string t
       | Error (`Bid, e) -> print_string e; exit check_bid_failed
       | Error (`Node, e) -> print_string e; exit 3)

let cmd_status home =
      let p = Filename.concat home "status.txt" in
      if Sys.file_exists p then print_string (read_file p)
      else fail "no status in %s yet: is its node running? Start it with `pantheon node %s` or `pantheon up DIR`" home home

let cmd_tx home fields =
      let d = Filename.concat home "inbox" in
      mkdir_p d;
      write_file (Filename.concat d (Printf.sprintf "%.6f.json" (Unix.gettimeofday ()))) (Yojson.Safe.to_string (strings_json fields));
      say "queued for %s's agent: %s (it signs and sends it next; see `pantheon status %s`)" (Filename.basename home) (String.concat " " fields) home

let cmd_up dir rest =
      let self = self_exe in
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

let read_plan f =
  if not (Sys.file_exists f) then fail "no %s here: a repository's plan is .plan at its root (docs/PLAN.md)" f;
  read_file f

let print_lines xs = List.iter print_endline xs
let print_text s = print_string s
let argv () = Array.to_list Sys.argv |> List.tl

(* The Soma node loop's handle: node_open registers the closures its setup
   built, and the loop drives them by this name (docs/SHELL-IN-SOMA.md 2). *)
type node_handle = { h_events : float -> string list list;
                     h_job_complete : string -> string -> string list list;
                     h_job_flood : string -> unit;
                     h_ci_launch : string -> string -> string -> string -> string list list;
                     h_llm_budget : unit -> string * string;
                     h_llm_hold : string -> string -> string -> string list -> unit;
                     h_llm_start : string -> string -> string -> string -> string list -> string list -> string list -> string list -> string list option;
                     h_tool_checkout : string -> (string * string) * bool;
                     h_limit_set : float -> string -> float -> unit;
                     h_limit_clear : float -> unit;
                     h_repo_names : unit -> string list;
                     h_ls_files : string -> string;
                     h_head_file : string -> string -> string option;
                     h_conn_admit : string -> string -> string -> unit;
                     h_conns : unit -> (string * float) list;
                     h_conn_close : string -> unit;
                     h_line_limit : unit -> string;
                     h_poll_prep : unit -> unit;
                     h_inbox_state : unit -> float * string;
                     h_inbox_stamp : float -> unit;
                     h_turn_now : unit -> float;
                     h_timers : unit -> (float * string list) list;
                     h_set_timers : (float * string list) list -> unit;
                     h_jobs : unit -> (string * (float * (float * bool))) list;
                     h_job_expire : string -> unit;
                     h_queue_empty : unit -> bool;
                     h_save : Obj.t -> unit; h_refuse : string -> unit; h_boot : string list list; h_snapshot : Obj.t option; h_replayed : unit -> string;
                     h_remember_block : string -> string list -> bool;
                     h_timer : string -> string list -> unit; h_log : string -> unit;
                     h_push : string list -> unit; h_draw : string * (string * string);
                     h_block : string -> string list option;
                     h_store : string -> string list -> unit;
                     h_height : string -> unit;
                     h_current_height : unit -> string;
                     h_last_served : string -> string -> float option;
                     h_mark_served : string -> string -> float -> unit;
                     h_peer_exists : string -> bool;
                     h_peer_send : string -> string list -> unit;
                     h_checkout_heads : unit -> (string * string) list;
                     h_divergences : unit -> (string * string) list;
                     h_limit_info : unit -> float * (string * (string * string));
                     h_release_state : unit -> float * bool;
                     h_release_one : unit -> (((string * string) * string) * string list) option;
                     h_release_all : unit -> (((string * string) * string) * string list) list;
                     h_write_status : string -> unit;
                     h_encode_tx : string -> string list -> string;
                     h_track_tx : string -> unit;
                     h_nonce_flooded : unit -> bool;
                     h_mark_nonce_flood : unit -> unit;
                     h_send_all : string list -> unit;
                     h_signed_vote : string -> string option;
                     h_signed_body : string -> string list option;
                     h_signed_text : string;
                     h_signed_restore : string -> string -> string list -> unit;
                     h_remember_vote : string -> string -> string list -> unit;
                     h_remember_broadcast : string -> string -> string list -> string list -> unit;
                     h_peer_count : unit -> string;
                     h_send_peer : string -> string list -> unit;
                     h_run_check : string -> string -> string -> string list -> unit;
                     h_identity : string;
                     h_seen_refused : string -> bool;
                     h_verify_line : string -> string -> string list -> bool;
                     h_merge_applied : string -> string option;
                     h_merge_diverged : string -> bool;
                     h_merge_reset : string -> unit;
                     h_merge_probe : string -> string -> string;
                     h_merge_read : string -> string -> string option;
                     h_merge_write : string -> string -> string -> string;
                     h_merge_remove : string -> string -> string;
                     h_merge_commit : string -> string -> string -> string -> string -> string -> string -> (string * string) option;
                     h_merge_set_applied : string -> string -> unit;
                     h_merge_note_diverged : string -> string -> unit }
let node_handles : (string, node_handle) Hashtbl.t = Hashtbl.create 4
let node_counter = ref 0
let lookup_handle id = try Hashtbl.find node_handles id with Not_found -> fail "unknown node handle %s" id
let events id wait = (lookup_handle id).h_events wait
let node_poll_prep id = (lookup_handle id).h_poll_prep (); true
let node_inbox_state id = (lookup_handle id).h_inbox_state ()
let node_inbox_stamp id now = (lookup_handle id).h_inbox_stamp now; true
let fs_dir_entries path = if Sys.file_exists path then Array.to_list (Sys.readdir path) else []
let fs_read_text path = try Some (read_file path) with _ -> None
let fs_remove path = Sys.remove path; true
let node_turn_now id = (lookup_handle id).h_turn_now ()
let node_timers id = (lookup_handle id).h_timers ()
let node_set_timers id ts = (lookup_handle id).h_set_timers ts; true
let node_jobs id = (lookup_handle id).h_jobs ()
let node_job_expire id jid = (lookup_handle id).h_job_expire jid; true
let node_queue_empty id = (lookup_handle id).h_queue_empty ()
let node_job_complete id job result = (lookup_handle id).h_job_complete job result
let node_job_flood id jid = (lookup_handle id).h_job_flood jid; true
let node_plain_text s = plain_text s
let node_ci_launch id req out tree ci = (lookup_handle id).h_ci_launch req out tree ci
(* a model call's I/O: node.soma's perform_llm decides and builds the prompt *)
let node_llm_budget id = (lookup_handle id).h_llm_budget ()
let node_llm_hold id req kind prompt ctx = (lookup_handle id).h_llm_hold req kind prompt ctx; true
let node_llm_start id req kind raw prompt ctx clean launch env = (lookup_handle id).h_llm_start req kind raw prompt ctx clean launch env
let node_tool_checkout id r = (lookup_handle id).h_tool_checkout r
let node_self_exe () = self_exe
let node_json_string s = Yojson.Safe.to_string (`String s)
let node_reply_finish path text = (try Sys.remove path with _ -> ()); text
let node_env_entries () = Array.to_list (Unix.environment ())
(* a model's output: node.soma's reply_fields decides what it becomes.
   These bindings only report the cap and yojson's value as tokens. Where
   the braces are (reply_open_at, reply_close_at), the slice, the guards
   and the key paths are Soma. *)
let node_job_output_limit () = string_of_int max_job_output
(* "A" count key value...; "L" count value...; "S" text; "B" true/false;
   "U"; "I" digits (an int or an intlit); "F" printed with %.0f. *)
let json_tokens j =
  let out = ref [] in
  let stack : ([ `E of string | `V of Yojson.Safe.t ]) Stack.t = Stack.create () in
  Stack.push (`V j) stack;
  while not (Stack.is_empty stack) do
    match Stack.pop stack with
    | `E s -> out := s :: !out
    | `V (`Assoc kv) ->
        List.iter (fun (k, v) -> Stack.push (`V v) stack; Stack.push (`E k) stack) (List.rev kv);
        Stack.push (`E (string_of_int (List.length kv))) stack;
        Stack.push (`E "A") stack
    | `V (`List l) ->
        List.iter (fun v -> Stack.push (`V v) stack) (List.rev l);
        Stack.push (`E (string_of_int (List.length l))) stack;
        Stack.push (`E "L") stack
    | `V (`String s) -> Stack.push (`E s) stack; Stack.push (`E "S") stack
    | `V (`Bool b) -> Stack.push (`E (string_of_bool b)) stack; Stack.push (`E "B") stack
    | `V `Null -> Stack.push (`E "U") stack
    | `V (`Int i) -> Stack.push (`E (string_of_int i)) stack; Stack.push (`E "I") stack
    | `V (`Intlit s) -> Stack.push (`E s) stack; Stack.push (`E "I") stack
    | `V (`Float f) -> Stack.push (`E (Printf.sprintf "%.0f" f)) stack; Stack.push (`E "F") stack
  done;
  List.rev !out
let node_json_tokens raw = try Some (json_tokens (Yojson.Safe.from_string raw)) with _ -> None
let node_float_of_digits s = float_of_string s
let node_limit_set id until reason backoff = (lookup_handle id).h_limit_set until reason backoff; true
let node_limit_clear id backoff = (lookup_handle id).h_limit_clear backoff; true
let node_repo_names id = (lookup_handle id).h_repo_names ()
let node_ls_files id r = (lookup_handle id).h_ls_files r
let node_head_file id r p = (lookup_handle id).h_head_file r p
let node_token () = random_hex 8
let node_float_text f = Printf.sprintf "%.0f" f
let save_snapshot id snap = (lookup_handle id).h_save (Obj.repr snap); true
let note_refused id raw = (lookup_handle id).h_refuse raw; true
let boot_events id = (lookup_handle id).h_boot
let boot_snapshot id = Option.map Obj.obj (lookup_handle id).h_snapshot
let replay_count id = (lookup_handle id).h_replayed ()
let node_remember_block id h txs = (lookup_handle id).h_remember_block h txs
(* The node's operations (node.soma's node_op, U-1), one at a time in their
   wire form (node.soma's io_wire; this match is its io_of_wire): the only
   place the node logs, sets a timer, queues an event, sends on a peer
   link, stores a block, sets the height, writes the status file, logs a
   signed vote, tracks its own transaction, marks the nonce flood, starts
   a CI check, records a merge applied or diverged, or reads the clock. Effects return (true, 0.); "clock" returns
   (true, Unix.gettimeofday ()). A unikernel would interpret the same
   operations through Sandbox. *)
let node_io id op =
  let h = lookup_handle id in
  match op with
  | [ "log"; text ] -> h.h_log text; (true, 0.)
  | "timer" :: ms :: ev -> h.h_timer ms ev; (true, 0.)
  | "push" :: ev -> h.h_push ev; (true, 0.)
  | "send_all" :: fields -> h.h_send_all fields; (true, 0.)
  | "send_peer" :: index :: fields -> h.h_send_peer index fields; (true, 0.)
  | "peer_send" :: who :: fields -> h.h_peer_send who fields; (true, 0.)
  | "store" :: height :: txs -> h.h_store height txs; (true, 0.)
  | [ "set_height"; height ] -> h.h_height height; (true, 0.)
  | [ "write_status"; text ] -> h.h_write_status text; (true, 0.)
  | "sign_vote" :: slot :: vid :: fields -> h.h_remember_vote slot vid fields; (true, 0.)
  | [ "track_tx"; raw ] -> h.h_track_tx raw; (true, 0.)
  | [ "mark_nonce_flood" ] -> h.h_mark_nonce_flood (); (true, 0.)
  | "check" :: req :: r :: head :: edits -> h.h_run_check req r head edits; (true, 0.)
  | [ "merge_applied"; r; v ] -> h.h_merge_set_applied r v; (true, 0.)
  | [ "merge_diverged"; r; entry ] -> h.h_merge_note_diverged r entry; (true, 0.)
  | [ "clock" ] -> (true, Unix.gettimeofday ())
  | _ -> fail "unknown node operation %s" (String.concat " " op)
let node_conn_admit id oid mode target = (lookup_handle id).h_conn_admit oid mode target; true
let node_conns id = (lookup_handle id).h_conns ()
let node_conn_close id cid = (lookup_handle id).h_conn_close cid; true
let node_line_limit id = (lookup_handle id).h_line_limit ()
let node_draw id = (lookup_handle id).h_draw
let node_block id height = (lookup_handle id).h_block height
(* Reads/writes and authenticated socket sends; catch-up policy is Soma.
   The clock is the "clock" arm of node_io. *)
let node_current_height id = (lookup_handle id).h_current_height ()
let node_last_served id who h = (lookup_handle id).h_last_served who h
let node_mark_served id who h now = (lookup_handle id).h_mark_served who h now; true
let node_peer_exists id who = (lookup_handle id).h_peer_exists who
let node_checkout_heads id = (lookup_handle id).h_checkout_heads ()
let node_divergences id = (lookup_handle id).h_divergences ()
let node_limit_info id = (lookup_handle id).h_limit_info ()
let node_release_state id = (lookup_handle id).h_release_state ()
let node_release_one id = (lookup_handle id).h_release_one ()
let node_release_all id = (lookup_handle id).h_release_all ()
let node_local_time until =
  let tm = Unix.localtime until in Printf.sprintf "%02d:%02d" tm.Unix.tm_hour tm.Unix.tm_min
let node_encode_tx id nonce fields = (lookup_handle id).h_encode_tx nonce fields
let node_nonce_flooded id = (lookup_handle id).h_nonce_flooded ()
let node_signed_vote id slot = (lookup_handle id).h_signed_vote slot
let node_signed_body id slot = (lookup_handle id).h_signed_body slot
(* signed.log's bytes, raw, and noting one vote Soma read from them (without
   appending it again); Soma's log_lines splits them and signed_log_entry
   parses each line *)
let node_signed_text id = (lookup_handle id).h_signed_text
let node_signed_restore id slot vid fields = (lookup_handle id).h_signed_restore slot vid fields; true
(* a startup Soma refuses: the message on stderr, exit 1, as `fail` *)
let node_fail msg : bool = fail "%s" msg
let node_remember_broadcast id height kind fields alt = (lookup_handle id).h_remember_broadcast height kind fields alt; true
let node_peer_count id = (lookup_handle id).h_peer_count ()
(* Node metadata for peer lines. Soma gates the parse, reads the members
   from node_json_tokens' tokens (node.soma's node_line_parts), and decides
   whether to verify and which event the fields carry. *)
let node_line_item_cap () = string_of_int max_int
let node_identity id = (lookup_handle id).h_identity
let node_seen_refused id raw = (lookup_handle id).h_seen_refused raw
let node_verify_line id from sg fields = (lookup_handle id).h_verify_line from sg fields
(* a decided merge's I/O: node.soma's perform_merge decides *)
let node_merge_applied id r = (lookup_handle id).h_merge_applied r
let node_merge_diverged id r = (lookup_handle id).h_merge_diverged r
let node_merge_reset id r = (lookup_handle id).h_merge_reset r; true
let node_merge_probe id r p = (lookup_handle id).h_merge_probe r p
let node_merge_read id r p = (lookup_handle id).h_merge_read r p
let node_merge_write id r p text = (lookup_handle id).h_merge_write r p text
let node_merge_remove id r p = (lookup_handle id).h_merge_remove r p
let node_merge_commit id r v tree bid task bidder spec = (lookup_handle id).h_merge_commit r v tree bid task bidder spec
let rec forever f s = forever f (f s)

let node_open packed home flags =
  let helpers = unpack_helpers packed in
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
  (* repositories outside this agent's scope, from its genesis part *)
  let my_excluded = List.concat_map (fun a -> if to_string (member "name" a) = me then
                                       (match member "exclude" a with `List l -> List.map to_string l | _ -> []) else []) agents in
  List.iter (fun a -> Hashtbl.replace pubkeys (to_string (member "name" a)) (key_of_json (member "pubkey" a))) agents;
  let addr_of_agent n = to_string (member "addr" (List.find (fun a -> to_string (member "name" a) = n) agents)) in
  let byz = try Sys.getenv "PANTHEON_BYZ" with Not_found -> "" in
  if byz <> "" then say "FAULT INJECTION: this node misbehaves on purpose (%s)" byz;
  let nonce_flood_sent = ref false in
  (* flags: agent settings, given to Soma as events *)
  let backend = ref "scripted" and agent_events = ref [] and ci_cmd = ref "" and ci_repo = ref [] and ci_image = ref "alpine:3.20" and ci_sandbox = ref "" in
  let listen = ref "0.0.0.0" and ci_memory = ref "8g" and no_check = ref [] in
  let max_calls = ref 100 and calls = ref 0 in
  let rec go = function
    | "--backend" :: b :: r -> backend := b; go r
    | "--behavior" :: b :: r -> agent_events := !agent_events @ [ [ "agent"; "behavior"; b ] ]; go r
    | "--goal" :: f :: r -> agent_events := !agent_events @ [ [ "goal_text"; file_text f ] ]; go r
    | "--deny" :: p :: r -> agent_events := !agent_events @ [ [ "agent"; "deny"; p ] ]; go r
    | "--bid-window" :: n :: r -> agent_events := !agent_events @ [ [ "agent"; "bid_window"; n ] ]; go r
    | "--perspective" :: t :: r -> agent_events := !agent_events @ [ [ "agent"; "perspective"; t ] ]; go r
    | "--ci" :: c :: r -> ci_cmd := c; go r
    | "--ci-repo" :: n :: c :: r -> ci_repo := (n, c) :: !ci_repo; go r
    (* a repository this node can't build (Soma's CI on a small host): its
       checks end as this node's problem, so the agent abstains on that
       repository's bids rather than say yes after only applying the edits *)
    | "--no-check" :: n :: r -> no_check := n :: !no_check; go r
    | "--listen" :: h :: r -> listen := h; go r
    | "--ci-memory" :: m :: r -> ci_memory := m; go r
    | "--ci-image" :: i :: r -> ci_image := i; go r
    (* CI without Docker: PROGRAM MEMORY CHECKOUT CMD runs CMD on a copy of the
       read-only CHECKOUT, with no network, within MEMORY (deploy/host/ci-sandbox) *)
    | "--ci-sandbox" :: p :: r -> ci_sandbox := p; go r
    | "--max-llm-calls" :: n :: r -> max_calls := int_of_string n; go r
    | x :: _ -> fail "unknown node flag %s" x
    | [] -> ()
  in
  go flags;
  (* Soma reads the raw --backend string (backend_kind_name, backend_behavior_event) *)
  agent_events := !agent_events @ [ [ "backend_behavior_of"; !backend ] ];
  (* state *)
  let queue = Queue.create () in
  let push ev = Queue.add ev queue in
  let height = ref 0 in
  let mine : (int * (string * string list * string list)) list ref = ref [] in
  let my_txs : (float * string) list ref = ref [] in
  let blocks : (int, string list) Hashtbl.t = Hashtbl.create 64 in
  let served : (string * int, float) Hashtbl.t = Hashtbl.create 64 in
  let timers : (float * string list) list ref = ref [] in
  let jobs : job list ref = ref [] in
  let job_counter = ref 0 in
  let finished_jobs : (string, job) Hashtbl.t = Hashtbl.create 8 in
  let signed_path = Filename.concat home "signed.log" in
  (* slot -> (value id, the whole vote): "SLOT VID [VOTE-AS-JSON]" per line *)
  (* filled from signed.log's lines by Soma (node.soma's restore_signed,
     through signed_log_entry) before replay: the shell only reads the lines *)
  let signed : (string, string * string list option) Hashtbl.t = Hashtbl.create 64 in
  let signed_text = file_text signed_path in
  let blocks_path = Filename.concat home "blocks.log" in
  (* the governed repositories: a checkout each, at genesis or later *)
  let repos = List.map (fun r -> (to_string (member "name" r), to_string (member "url" r), to_string (member "commit" r), to_string (member "tree" r)))
                (try to_list (member "repos" gen) with _ -> []) in
  let net_dir = Filename.concat home "network" in
  List.iter (fun (n, url, commit, tree) ->
      let dir = ensure_repo home n (repo_url helpers net_dir url) commit in
      if git_out dir [ "rev-parse"; commit ^ "^{tree}" ] <> tree then fail "genesis says repository %s's commit %s has tree %s; this clone disagrees" n commit tree)
    repos;
  let rdir n = repo_dir home n in
  (* the version of the last merge applied to a checkout: the merges
     replayed from blocks.log at startup are already in it *)
  let genesis_commit n = match List.find_opt (fun (m, _, _, _) -> m = n) repos with Some (_, _, c, _) -> c | None -> "" in
  (* Genesis stays 0. Soma reads Pantheon-Version out of any later commit. *)
  let applied_body n =
    if git_out (rdir n) [ "rev-parse"; "HEAD" ] = git_out (rdir n) [ "rev-parse"; genesis_commit n ] then None
    else Some (snd (git (rdir n) [ "log"; "-1"; "--format=%B" ]))
  in
  let applied = Hashtbl.create 4 in
  let pending_applied = ref [] in
  List.iter (fun (n, _, _, _) -> match applied_body n with None -> Hashtbl.replace applied n 0 | Some body -> pending_applied := (n, body) :: !pending_applied) repos;
  let diverged = ref [] in
  let ci_for r = try List.assoc r !ci_repo with Not_found -> !ci_cmd in
  let peers =
    List.filter_map (fun n ->
        if n = me then None
        else Some { name = n; addr = addr_of_agent n; out = None; connecting = false; obuf = Buffer.create 4096; next_try = 0. })
      names
  in
  let conns : conn list ref = ref [] in
  let conn_counter = ref 0 in
  let pending_conns : (int * Unix.file_descr * string) list ref = ref [] in
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
  (* Resend exactly the messages Soma recorded. The choice of message,
     including equivocation and silence, was made when they were recorded. *)
  let resend_recorded kind fields alt =
    match kind with
    | "each" -> List.iteri (fun i p -> send_to p (wire (if i = 0 then fields else alt))) peers
    | "all" -> let line = wire fields in List.iter (fun p -> send_to p line) peers
    | _ -> ()
  in
  (* jobs Soma stopped for running past their time limit (job_should_expire) *)
  let overtime = Hashtbl.create 8 in
  (* jobs stopped for printing more than any reply can be. Soma's job_feed
     decides; node_job_flood marks the job and signals it once. The node
     holds a job's output in memory, and a check that prints forever (a
     bid's test running `yes`) would otherwise take the node down with it *)
  let flooded = Hashtbl.create 8 in
  let cut = Hashtbl.create 8 in
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
      let jid = string_of_int !job_counter in
      incr job_counter;
      jobs := { jid; jfd = r; jpid = pid; jdone = on_done; jstarted = Unix.gettimeofday (); jlimit = limit;
                jclean = (fun () -> (try Sys.remove inp with _ -> ()); (try remove_tree_later cwd with _ -> ()); clean ()) } :: !jobs
    end
  in
  (* What a prompt asks for from the checkouts is assembled in Soma
     (node.soma's perform_llm): the shell lists files and reads them at a
     checkout's head. *)
  (* a model call: a scratch directory, no keys in reach; built-in backends
     have no tools, and a cmd: backend asked for a patch gets a fresh checkout *)
  (* A model's subscription or rate limit: its calls are held, not failed, until
     the limit should have reset (the time it gives, or a backoff from 15
     minutes, doubling to 2 hours), then asked again. Failing them would spend
     the agent's tries on calls bound to fail. *)
  (* What a model's output becomes (held for a limit, an error, a reply),
     how long a limit holds and the backoff are decided in Soma (node.soma's
     reply_events); the shell keeps their state. *)
  let limited_until = ref 0. and limit_reason = ref "" and limit_backoff = ref 900. and held = ref [] and probing = ref false in
  (* a held request, raw: Soma assembles its prompt again when it's asked *)
  let hold id kind prompt0 ctx = held := (id, kind, prompt0, ctx) :: !held in
  (* the model process for a prompt Soma assembled from prompt0. Its output
     comes back raw as an llm_output event, or at once when the process
     couldn't start *)
  let call_model id kind prompt0 prompt ctx clean launch env =
    let starting = ref true and immediate = ref None in
    let deliver ev = if !starting then immediate := Some ev else push ev in
    let reply text = deliver ("llm_output" :: id :: kind :: prompt0 :: text :: ctx) in
    (match launch with
     | prog :: limit_s :: "codex" :: args ->
         let out = Filename.temp_file "pantheon-codex" ".txt" in
         start_job ~limit:(float_of_string limit_s) prog
           (List.map (fun a -> if a = "@OUT@" then out else a) args) ~stdin_text:prompt ~env:(Array.of_list env)
           ~on_done:(fun t -> deliver ("codex_file" :: id :: kind :: prompt0 :: t :: out :: ctx))
           ~clean:ignore
     (* Soma's grok_request made the header text and the body (the prompt) *)
     | prog :: limit_s :: "grok" :: hdr_text :: args ->
         let hdr = Filename.temp_file "pantheon-h" ".txt" in
         write_file hdr hdr_text;
         start_job ~limit:(float_of_string limit_s) prog
           (List.map (fun a -> if a = "@HDR@" then "@" ^ hdr else a) args) ~stdin_text:prompt ~env:(Array.of_list env)
           ~on_done:reply (* Soma's model_reply_events takes the content out *)
           ~clean:(fun () -> try Sys.remove hdr with _ -> ())
     (* cmd: too, its limit, environment and paths to remove chosen by Soma's tool_job_of *)
     | prog :: limit_s :: _ :: args ->
         start_job ~limit:(float_of_string limit_s) prog args ~stdin_text:prompt ~env:(Array.of_list env) ~on_done:reply
           ~clean:(fun () -> List.iter remove_tree_later clean)
     | _ -> ());
    starting := false;
    !immediate
  in
  (* One CI job at a time on this node, the rest waiting their turn: two at
     once (a leader's merge check beside an attest) can take more memory than
     the machine has, and a build killed for memory reads as the bid's fault. *)
  let ci_busy = ref false and ci_waiting = Queue.create () in
  let ci_next () = match Queue.take_opt ci_waiting with Some f -> f () | None -> ci_busy := false in
  let with_ci f = if !ci_busy then Queue.add f ci_waiting else (ci_busy := true; f ()) in
  (* CI for a tree Soma already accepted (node.soma's check_apply_events).
     The checkout's .git goes: a --shared clone's objects live in this
     node's own repository (through alternates), which isn't in CI's
     sandbox, so git there saw a broken repository ("bad object HEAD") and
     its errors led the reason of a rejection. The tree is already computed. *)
  let launch_ci id out tree ci =
    ignore (Sys.command ("rm -rf " ^ Filename.quote (Filename.concat out ".git")));
    ignore (Sys.command ("chmod -R a+rX " ^ Filename.quote out));
    let name = "pantheon-ci-" ^ random_hex 6 in
    with_ci (fun () ->
      let prog, args =
        if !ci_sandbox <> "" then (!ci_sandbox, [ !ci_memory; out; ci_wrap ci ]) else
        ("docker", [ "run"; "--rm"; "--name"; name; "--network=none"; "--read-only"; "--tmpfs"; "/tmp:exec,size=" ^ !ci_memory; "--cap-drop=ALL";
          "--security-opt=no-new-privileges"; "--pids-limit=512"; "--memory=" ^ !ci_memory; "--memory-swap=" ^ !ci_memory;
          "--user=65534:65534"; "-e"; "HOME=/tmp";
          (* its errors too, as start_job keeps only stdout; and a build the
             kernel killed for the container's memory (oom_kill in its cgroup)
             ends as 137, the way docker ends the container itself *)
          "-v"; out ^ ":/work:ro"; "-w"; "/work"; !ci_image; "sh"; "-c"; ci_wrap ci ]) in
      start_job ~limit:3600. prog args
        ~stdin_text:"" ~env:(Unix.environment ())
        ~on_done:(fun t ->
          (* what the check's outcome is (passed, the bid's failure or
             this node's problem, and why) is node.soma's ci_outcome,
             from the node's own signals only (docs/SECURITY-REVIEW-2.md P-6) *)
          push [ "ci_done"; id; tree; !ci_memory; (if !ci_sandbox <> "" then "sandbox" else "docker"); t ];
          ci_next ())
        ~clean:(fun () -> if !ci_sandbox = "" then ignore (Sys.command ("docker rm -f " ^ name ^ " >/dev/null 2>&1")); remove_tree_later out));
    let evs = ref [] in
    while not (Queue.is_empty queue) do evs := Queue.pop queue :: !evs done;
    List.rev !evs
  in
  (* A check for an attestor: the bid's edits on the head, in a fresh clone,
     give a tree; then the repository's CI, if this node has one, runs on it in
     a container with no network, a read-only root and nobody's uid. *)
  (* a check's result event is node.soma's check_result_event *)
  let run_check id r head edits =
    let out = Filename.temp_dir "pantheon-check" "" in
    let ef = Filename.temp_file "pantheon-edits" ".json" in
    write_file ef (Yojson.Safe.to_string (strings_json edits));
    let ci = ci_for r in
    let rm_out () = remove_tree_later out in
    (* ok is true, false (the bid's fault), or error (this node's: the agent
       abstains rather than blame the bid). stage is where a failure happened:
       apply (no tree yet), ci (a tree, then CI), or node (this node's own
       problem, which ok=error already sends the agent to abstain on) *)
    (* why carries the bid's own output (its CI's): no control character of
       it goes on to a rejection's reason *)
    (* whose a failure is comes from stage alone, which the node decides from
       its own signals (exit codes, a job that never started), never from
       what the check or the bid's CI printed (docs/SECURITY-REVIEW-2.md P-6) *)
    (* a repository this node doesn't check: node.soma makes it a result
       that is this node's own (check_unchecked) *)
    if List.mem r !no_check || List.mem r my_excluded then (rm_out (); (try Sys.remove ef with _ -> ()); push [ "check_unchecked"; id; "this node doesn't check " ^ r ^ (if List.mem r my_excluded then " (outside its scope: its genesis part excludes it)" else " (--no-check " ^ r ^ ")") ]) else
    start_job self_exe [ "check"; rdir r; head; ef; out ] ~stdin_text:"" ~env:(Unix.environment ())
      ~on_done:(fun t ->
        (* a failure, the trimmed tree, or a CI run: node.soma's check_apply_events *)
        push [ "check_apply_out"; id; out; ci; t ])
      ~clean:(fun () -> (try Sys.remove ef with _ -> ()); if ci = "" then rm_out ())
  in
  (* A decided merge's commit, the same on every node (fixed author and
     date), so every node gets the same commit: its tree and short id, or
     none when git commit failed. node.soma's perform_merge decides the rest. *)
  let merge_commit r v tree bid task bidder spec =
    let dir = rdir r and v = int_of_string v in
    let date = Printf.sprintf "@%d +0000" (1_700_000_000 + v) in
    let who = [ "GIT_AUTHOR_NAME=Pantheon"; "GIT_AUTHOR_EMAIL=pantheon@localhost"; "GIT_COMMITTER_NAME=Pantheon";
                "GIT_COMMITTER_EMAIL=pantheon@localhost"; "GIT_AUTHOR_DATE=" ^ date; "GIT_COMMITTER_DATE=" ^ date ] in
    let msg = Printf.sprintf "Merge bid %s for task %s by %s\n\n%s\n\nPantheon-Version: %d\nPantheon-Bid: %s\nPantheon-Tree: %s\n" bid task bidder spec v bid tree in
    ignore (git dir [ "add"; "-A"; "-f" ]);
    (* the message on stdin, not as an argument: the spec in it is the
       leader's text, and an argument can't carry every string whole
       (docs/SECURITY-REVIEW-2.md P-17) *)
    if not (git_ok ~extra:who ~stdin:msg dir [ "commit"; "-q"; "--allow-empty"; "--no-verify"; "--cleanup=verbatim"; "-F"; "-" ]) then None
    else Some (git_out dir [ "rev-parse"; "HEAD^{tree}" ], git_out dir [ "rev-parse"; "--short"; "HEAD" ])
  in
  let debug = (try Sys.getenv "PANTHEON_DEBUG" with Not_found -> "") <> "" in
  let brief l = String.concat " " (List.map (fun f -> if String.length f > 16 then String.sub f 0 16 else f) (List.filteri (fun i _ -> i < 7) l)) in
  let checkpoint_path = Filename.concat home "consensus.state" in
  let saved = ref None in
  (* Transactions the core refused since the last decided block. Until a block
     changes the market, the pool only grows, so each stays refused: a peer
     resending them (docs/SECURITY-REVIEW-2.md P-5) costs a table lookup, not
     a signature check and a pass through the core. The core gives a refused
     transaction's state back unchanged, which is how the shell can tell. *)
  let refused = Hashtbl.create 1024 in
  (* Setup returns data. Soma runs these events and their outputs, so
     startup and replay use exactly the same output interpreter as the loop. *)
  let boot_rev = ref [] in
  let feed ev = boot_rev := ev :: !boot_rev in
  (* genesis, then what's on disk *)
  (* the roster, tips, block_ms, params, repositories and excludes are
     node.soma's genesis_events, from the file's text *)
  feed [ "genesis"; read_file (Filename.concat home "genesis.json") ];
  feed [ "me"; me ];
  feed [ "backend_kind_of"; !backend ];
  List.iter feed !agent_events;
  List.iter (fun (n, body) -> feed ["applied_body"; n; body]) (List.rev !pending_applied);
  let replayed = ref 0 in
  (* the file's bytes: node.soma's log_lines splits them into block_log lines *)
  feed ["block_log_text"; file_text blocks_path];
  let boot_saved = if Sys.file_exists checkpoint_path then
      Some (Obj.repr (load_consensus checkpoint_path)) else None in
  (* votes with no consensus.state: Soma refuses to start (node.soma's
     signed_needs_snapshot), after it has read signed.log *)
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
  (* One clock reading for dial, resend, the inbox, Soma's deadlines and the
     select wait. [prep_turn] samples it; Soma reads it back; select consumes it. *)
  let turn_now = ref 0. in
  let have_turn_now = ref false in
  let sample_turn () =
    let now = Unix.gettimeofday () in
    turn_now := now;
    have_turn_now := true;
    now
  in
  let turn_clock () = if !have_turn_now then !turn_now else sample_turn () in
  let prep_turn () =
    let now = sample_turn () in
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
      List.iter (fun (_, (kind, fields, alt)) -> resend_recorded kind fields alt) (List.rev !mine);
      my_txs := List.filter (fun (t, _) -> now -. t < 120.) !my_txs;
      List.iter (fun (_, raw) -> broadcast_fields [ "tx"; raw ]) !my_txs
    end
  in
  (* Soma names the job. The limit stored here is the one the finish report uses. *)
  let expire_job jid =
    match List.find_opt (fun j -> j.jid = jid) !jobs with
    | Some j when not (Hashtbl.mem overtime j.jpid) ->
        Hashtbl.replace overtime j.jpid j.jlimit;
        Hashtbl.replace cut j.jpid ();
        (try Unix.kill j.jpid Sys.sigkill with _ -> ())
    | _ -> ()
  in
  let collect_events wait =
    (* Same reading as the deadlines: a peer's last activity, for eviction. *)
    let now = if !have_turn_now then !turn_now else Unix.gettimeofday () in
    have_turn_now := false;
    let reads = listener :: List.map (fun c -> c.fd) !conns @ List.map (fun j -> j.jfd) !jobs in
    let writes = List.filter_map (fun p -> match p.out with Some fd when p.connecting || Buffer.length p.obuf > 0 -> Some fd | _ -> None) peers in
    (* a failed select (a descriptor past FD_SETSIZE, EBADF) waits a moment
       and goes round again rather than ending the node *)
    let r, w, _ = try Unix.select reads writes [] wait with
      | Unix.Unix_error (EINTR, _, _) -> ([], [], [])
      | Unix.Unix_error (e, _, _) -> say "select failed (%s): %d connections" (Unix.error_message e) (List.length !conns); Unix.sleepf 0.2; ([], [], []) in
    List.iter (fun fd ->
        if fd = listener then
          match Unix.accept ~cloexec:true listener with
          | exception Unix.Unix_error _ -> ()   (* out of descriptors, or the peer gave up *)
          | c, addr ->
              let host = match addr with Unix.ADDR_INET (a, _) -> Unix.string_of_inet_addr a | _ -> "" in
              (* a few connections per address and a few dozen in all, so a
                 peer with no key can't use up the node's descriptors; when
                 full, the one quiet longest makes room (a real peer
                 reconnects) *)
              let oid = !conn_counter in
              incr conn_counter;
              pending_conns := (oid, c, host) :: !pending_conns;
              (* the hosts of the connections held now: Soma counts them
                 (node.soma's conn_offer_counts) and decides *)
              push ("conn_offer" :: string_of_int oid :: host :: List.map (fun x -> x.host) !conns))
      r;
    let buf = Bytes.create 65536 in
    conns := List.filter (fun c ->
        if not (List.mem c.fd r) then true
        else
          match Unix.read c.fd buf 0 65536 with
          | 0 -> Unix.close c.fd; push [ "peer_closed"; string_of_int c.cid ]; false
          | n ->
              c.last <- now;
              (* Soma splits these bytes into lines (feed_chunks in
                 node.soma, through this peer_bytes event); the shell
                 only reads the bytes from the descriptor *)
              push [ "peer_bytes"; string_of_int c.cid; Bytes.sub_string buf 0 n ]; true
          | exception Unix.Unix_error ((EAGAIN | EWOULDBLOCK), _, _) -> true
          | exception _ -> (try Unix.close c.fd with _ -> ()); push [ "peer_closed"; string_of_int c.cid ]; false)
      !conns;
    (* finished jobs are taken off the list before their callbacks run: a
       callback may start the next job *)
    let finished = ref [] in
    jobs := List.filter (fun j ->
        (* a job the node stopped (too long, too much output) ends now: its
           children may still hold the pipe open (a check's shell killed, the
           `yes` it ran still writing), and waiting for the pipe to close would
           hold the job, and the CI turn, forever *)
        if Hashtbl.mem cut j.jpid then begin
          Hashtbl.remove cut j.jpid;
          (try Unix.close j.jfd with _ -> ());
          let _, status = Unix.waitpid [] j.jpid in
          finished := (j, status) :: !finished;
          false
        end
        else if not (List.mem j.jfd r) then true
        else
          match Unix.read j.jfd buf 0 65536 with
          | 0 ->
              Unix.close j.jfd;
              let _, status = Unix.waitpid [] j.jpid in
              finished := (j, status) :: !finished;
              false
          | n ->
              (* Soma appends this chunk and applies the output cap
                 (job_feed in node.soma). The shell only reads the bytes. *)
              push [ "job_bytes"; j.jid; Bytes.sub_string buf 0 n ];
              true
          | exception _ -> true)
      !jobs;
    List.iter (fun (j, status) ->
        (* Report native wait facts. Soma chooses success/failure and the
           exact output; the callback and cleanup wait for node_job_complete. *)
        let signal_name sg =
          if sg = Sys.sigkill then "SIGKILL" else if sg = Sys.sigterm then "SIGTERM"
          else if sg = Sys.sigsegv then "SIGSEGV" else if sg = Sys.sigabrt then "SIGABRT"
          else if sg = Sys.sigint then "SIGINT" else Printf.sprintf "signal %d" sg in
        let tag, value = match status with
          | Unix.WEXITED c -> ("exit", string_of_int c)
          | Unix.WSIGNALED sg -> ("signal", signal_name sg)
          | Unix.WSTOPPED sg -> ("stop", signal_name sg) in
        let timeout = match Hashtbl.find_opt overtime j.jpid with Some limit -> node_float_text limit | None -> "" in
        let flood = if Hashtbl.mem flooded j.jpid then "1" else "0" in
        Hashtbl.remove overtime j.jpid; Hashtbl.remove flooded j.jpid;
        Hashtbl.replace finished_jobs j.jid j;
        push [ "job_finished"; j.jid; tag; value; timeout; flood ])
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
      peers;
    let evs = ref [] in
    while not (Queue.is_empty queue) do evs := Queue.pop queue :: !evs done;
    if debug then List.iter (fun ev -> say "event: %s" (brief ev)) (List.rev !evs);
    List.rev !evs
  in
  let handle_id = string_of_int !node_counter in
  incr node_counter;
  Hashtbl.replace node_handles handle_id
    { h_events = collect_events;
      h_job_complete = (fun jid result ->
        match Hashtbl.find_opt finished_jobs jid with
        | None -> []
        | Some j ->
            Hashtbl.remove finished_jobs jid;
            j.jdone result;
            j.jclean ();
            let evs = ref [] in
            while not (Queue.is_empty queue) do evs := Queue.pop queue :: !evs done;
            List.rev !evs);
      h_ci_launch = launch_ci;
      h_job_flood = (fun jid ->
        match List.find_opt (fun j -> j.jid = jid) !jobs with
        | Some j when not (Hashtbl.mem flooded j.jpid) ->
            Hashtbl.replace flooded j.jpid (); Hashtbl.replace cut j.jpid ();
            (try Unix.kill j.jpid Sys.sigkill with _ -> ())
        | _ -> ());
      h_llm_budget = (fun () -> incr calls; (string_of_int !calls, string_of_int !max_calls));
      h_llm_hold = hold;
      h_llm_start = call_model;
      (* a cmd: patch's fresh checkout, its git directory outside the worktree *)
      h_tool_checkout = (fun r ->
        let wt = Filename.temp_dir "pantheon-work" "" in
        let gd = wt ^ ".git" and commit = git_out (rdir r) [ "rev-parse"; "HEAD" ] in
        ((wt, gd), fst (capture "git" [ "clone"; "--quiet"; "--shared"; "--no-checkout"; "--separate-git-dir=" ^ gd; rdir r; wt ])
                   && git_ok wt [ "checkout"; "-q"; "--detach"; commit ]));
      h_limit_set = (fun until reason backoff ->
        limited_until := until; limit_reason := reason; limit_backoff := backoff; probing := false);
      h_limit_clear = (fun backoff -> limit_backoff := backoff; probing := false);
      h_repo_names = (fun () -> List.map (fun (n, _, _, _) -> n) repos);
      h_ls_files = (fun r -> git_out (rdir r) [ "ls-files" ]);
      h_head_file = (fun r p -> let ok, c = git (rdir r) [ "show"; "HEAD:" ^ p ] in if ok then Some c else None);
      h_save = (fun snap -> let c = Obj.obj snap in
                match !saved with Some p when p == c || p = c -> () | _ -> save_consensus checkpoint_path c; saved := Some c);
      h_refuse = (fun raw -> if Hashtbl.length refused < 10000 then Hashtbl.replace refused raw ());
      h_boot = List.rev !boot_rev; h_snapshot = boot_saved;
      h_replayed = (fun () -> string_of_int !replayed);
      h_remember_block = (fun hs txs -> match int_of_string_opt hs with None -> false | Some n -> Hashtbl.replace blocks n txs; replayed := n; true);
      h_conn_admit = (fun oid mode target ->
        match List.find_opt (fun (i, _, _) -> string_of_int i = oid) !pending_conns with
        | None -> ()
        | Some (_, c, host) ->
            pending_conns := List.filter (fun (i, _, _) -> string_of_int i <> oid) !pending_conns;
            (match mode with
             | "refuse" -> (try Unix.close c with _ -> ())
             | _ ->
                 if mode = "evict" then
                   (match List.find_opt (fun x -> string_of_int x.cid = target) !conns with
                    | Some old -> (try Unix.close old.fd with _ -> ()); conns := List.filter (fun x -> x != old) !conns
                    | None -> ());
                 Unix.set_nonblock c;
                 let cid = !conn_counter in
                 incr conn_counter;
                 conns := { cid; fd = c; host; last = Unix.gettimeofday () } :: !conns));
      h_conns = (fun () -> List.map (fun x -> (string_of_int x.cid, x.last)) !conns);
      h_conn_close = (fun cid ->
        match List.find_opt (fun x -> string_of_int x.cid = cid) !conns with
        | Some x -> (try Unix.close x.fd with _ -> ()); conns := List.filter (fun y -> y != x) !conns
        | None -> ());
      h_line_limit = (fun () -> string_of_int max_line);
      h_poll_prep = prep_turn;
      h_inbox_state = (fun () -> (!last_inbox, Filename.concat home "inbox"));
      h_inbox_stamp = (fun now -> last_inbox := now);
      h_turn_now = turn_clock;
      h_timers = (fun () -> !timers);
      h_set_timers = (fun ts -> timers := ts);
      h_jobs = (fun () -> List.map (fun j -> (j.jid, (j.jstarted, (j.jlimit, Hashtbl.mem overtime j.jpid)))) !jobs);
      h_job_expire = expire_job;
      h_queue_empty = (fun () -> Queue.is_empty queue);
      h_timer = (fun ms ev -> timers := (Unix.gettimeofday () +. float_of_string ms /. 1000., ev) :: !timers);
      h_log = (fun text -> say "%s" text); h_push = push;
      h_draw = (byz, (string_of_int chain_len, secret));
      h_block = (fun h -> Hashtbl.find_opt blocks (int_of_string h));
      h_store = (fun h txs -> let h = int_of_string h in
        Hashtbl.replace blocks h txs;
        append_line_synced blocks_path (Yojson.Safe.to_string (`Assoc [ ("h", `Int h); ("txs", strings_json txs) ])));
      h_height = (fun h -> let h = int_of_string h in
        height := h;
        mine := List.filter (fun (mh, _) -> mh >= h) !mine);
      h_current_height = (fun () -> string_of_int !height);
      h_last_served = (fun who h -> Hashtbl.find_opt served (who, int_of_string h));
      h_mark_served = (fun who h now -> Hashtbl.replace served (who, int_of_string h) now);
      h_peer_exists = (fun who -> List.exists (fun p -> p.name = who) peers);
      h_peer_send = (fun who fields -> List.iter (fun p -> if p.name = who then send_to p (wire fields)) peers);
      h_checkout_heads = (fun () -> List.map (fun (n, _, _, _) -> (n, git_out (rdir n) [ "rev-parse"; "--short"; "HEAD" ])) repos);
      h_divergences = (fun () -> !diverged);
      h_limit_info = (fun () -> (!limited_until, (!backend, (string_of_int (List.length !held), !limit_reason))));
      (* Raw held requests, oldest first; Soma constructs their events. *)
      h_release_state = (fun () -> (!limit_backoff, !probing));
      h_release_one = (fun () ->
        match List.rev !held with
        | (id, kind, prompt, ctx) :: rest -> held := List.rev rest; probing := true; Some (((id, kind), prompt), ctx)
        | [] -> None);
      h_release_all = (fun () ->
        let hs = List.rev !held in
        held := [];
        List.map (fun (id, kind, prompt, ctx) -> (((id, kind), prompt), ctx)) hs);
      h_write_status = (fun text -> write_file (Filename.concat home "status.txt") text);
      h_encode_tx = encode_tx key me;
      h_track_tx = (fun raw -> my_txs := (Unix.gettimeofday (), raw) :: !my_txs);
      h_nonce_flooded = (fun () -> !nonce_flood_sent);
      h_mark_nonce_flood = (fun () -> nonce_flood_sent := true);
      h_send_all = (fun fields -> let line = wire fields in List.iter (fun p -> send_to p line) peers);
      h_signed_vote = (fun slot -> Option.map fst (Hashtbl.find_opt signed slot));
      h_signed_body = (fun slot -> match Hashtbl.find_opt signed slot with Some (_, body) -> body | None -> None);
      h_signed_text = signed_text;
      h_signed_restore = (fun slot vid fields -> Hashtbl.replace signed slot (vid, Some fields));
      h_remember_vote = (fun slot vid fields ->
        Hashtbl.replace signed slot (vid, Some fields);
        append_line_synced signed_path (slot ^ " " ^ vid ^ " " ^ Yojson.Safe.to_string (strings_json fields)));
      h_remember_broadcast = (fun height kind fields alt ->
        mine := (int_of_string height, (kind, fields, alt)) :: !mine);
      h_peer_count = (fun () -> string_of_int (List.length peers));
      h_send_peer = (fun index fields ->
        match List.nth_opt peers (int_of_string index) with
        | Some p -> send_to p (wire fields)
        | None -> ());
      h_identity = me;
      h_seen_refused = (fun raw -> Hashtbl.mem refused raw);
      h_verify_line = (fun from sg fields ->
        match Hashtbl.find_opt pubkeys from with
        | Some k -> verify k (msg_bytes from fields) sg
        | None -> false);
      h_run_check = run_check;
      h_merge_applied = (fun r -> Option.map string_of_int (Hashtbl.find_opt applied r));
      h_merge_diverged = (fun r -> List.mem_assoc r !diverged);
      h_merge_reset = (fun r ->
        let dir = rdir r in
        ignore (git dir [ "reset"; "-q"; "--hard"; "HEAD" ]);
        ignore (git dir [ "clean"; "-q"; "-f"; "-d"; "-x" ]));
      h_merge_probe = (fun r p ->
        let dir = rdir r in
        let f = Filename.concat dir p in
        try
          if not (no_symlink dir p) then "symlink"
          else if Sys.file_exists f && Sys.is_directory f then "dir"
          else if Sys.file_exists f then "file"
          else "none"
        with _ -> "symlink");
      h_merge_read = (fun r p -> try Some (read_file (Filename.concat (rdir r) p)) with _ -> None);
      h_merge_write = (fun r p text ->
        let f = Filename.concat (rdir r) p in
        try mkdir_p (Filename.dirname f); write_keep_mode f text; "" with e -> Printexc.to_string e);
      h_merge_remove = (fun r p -> try Sys.remove (Filename.concat (rdir r) p); "" with e -> Printexc.to_string e);
      h_merge_commit = merge_commit;
      h_merge_set_applied = (fun r v -> Hashtbl.replace applied r (int_of_string v));
      h_merge_note_diverged = (fun r entry -> diverged := (r, entry) :: !diverged) };
  handle_id

