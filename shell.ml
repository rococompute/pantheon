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

(* a path a merge may write: also checked by the market, checked again here *)
let safe_path p =
  p <> "" && p.[0] <> '/' && not (List.mem ".." (String.split_on_char '/' p)) && not (String.contains p '\\')

(* ---------- hash chains for the leader draw ---------- *)

let chain_len = 100_000
let rec iterate n x = if n = 0 then x else iterate (n - 1) (sha256 x)

(* ---------- init ---------- *)

let agents_default = [ "claude"; "codex"; "grok"; "muse" ]

let cmd_init args =
  let dir = ref "" and seed = ref "" and port = ref 26700 and params = ref [] and block_ms = ref 500 in
  let rec go = function
    | "--seed-dir" :: d :: r -> seed := d; go r
    | "--base-port" :: p :: r -> port := int_of_string p; go r
    | "--block-ms" :: p :: r -> block_ms := int_of_string p; go r
    | "--param" :: kv :: r ->
        (match String.index_opt kv '=' with
         | Some i -> params := (String.sub kv 0 i, String.sub kv (i + 1) (String.length kv - i - 1)) :: !params
         | None -> fail "--param wants name=value, got %s" kv);
        go r
    | d :: r when !dir = "" -> dir := d; go r
    | x :: _ -> fail "unknown init argument %s" x
    | [] -> ()
  in
  go args;
  if !dir = "" then fail "usage: pantheon init DIR [--seed-dir D] [--base-port P] [--block-ms N] [--param name=value]...";
  if Sys.file_exists (Filename.concat !dir "claude/genesis.json") then
    fail "%s already holds a network, keys included. To discard it, stop its nodes and remove the directory; to keep it, pick another DIR" !dir;
  let files = ref [] in
  let rec walk rel =
    let full = if rel = "" then !seed else Filename.concat !seed rel in
    if Sys.is_directory full then
      Array.iter (fun e -> if e.[0] <> '.' then walk (if rel = "" then e else rel ^ "/" ^ e)) (Sys.readdir full)
    else files := (rel, `String (read_file full)) :: !files
  in
  if !seed <> "" then walk "";
  let made =
    List.mapi (fun i name ->
        say "making keys for %s" name;
        let key = Cryptokit.RSA.new_key ~rng:(Lazy.force rng) 2048 in
        let secret = random_hex 32 in
        (name, i, key, secret, iterate chain_len secret))
      agents_default
  in
  let genesis =
    `Assoc [ ("chain_id", `String ("pantheon-" ^ random_hex 4));
             ("block_ms", `Int !block_ms);
             ("agents", `List (List.map (fun (n, i, k, _, tip) ->
                  `Assoc [ ("name", `String n); ("addr", `String (Printf.sprintf "127.0.0.1:%d" (!port + i)));
                           ("pubkey", key_to_json k ~priv:false); ("tip", `String tip) ]) made));
             ("params", `Assoc (List.rev_map (fun (k, v) -> (k, `String v)) !params));
             ("files", `Assoc (List.sort compare !files)) ] in
  List.iter (fun (n, _, k, secret, _) ->
      let home = Filename.concat !dir n in
      mkdir_p home;
      Yojson.Safe.to_file (Filename.concat home "genesis.json") genesis;
      Yojson.Safe.to_file (Filename.concat home "key.json") (`Assoc [ ("agent", `String n); ("key", key_to_json k ~priv:true) ]);
      Yojson.Safe.to_file (Filename.concat home "chain.json") (`Assoc [ ("secret", `String secret) ]);
      Unix.chmod (Filename.concat home "key.json") 0o600;
      Unix.chmod (Filename.concat home "chain.json") 0o600)
    made;
  say "made a 4-agent network in %s. Run it with: %s up %s" !dir Sys.argv.(0) !dir

(* ---------- the node ---------- *)

type peer = { name : string; addr : Unix.sockaddr; mutable out : Unix.file_descr option; mutable connecting : bool;
              obuf : Buffer.t; mutable next_try : float }

type conn = { fd : Unix.file_descr; ibuf : Buffer.t }

type job = { jfd : Unix.file_descr; jpid : int; jbuf : Buffer.t; jdone : string -> unit; jstarted : float; jclean : unit -> unit }

let addr_of s =
  match String.rindex_opt s ':' with
  | Some i ->
      let host = String.sub s 0 i and port = int_of_string (String.sub s (i + 1) (String.length s - i - 1)) in
      let ip = try Unix.inet_addr_of_string host with _ -> (Unix.gethostbyname host).h_addr_list.(0) in
      Unix.ADDR_INET (ip, port)
  | None -> fail "bad address %s" s

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
          agents_default
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
         \  pantheon init DIR [--seed-dir D] [--base-port P] [--block-ms N] [--param name=value]...\n\
         \  pantheon up DIR [--backends claude=claude,codex=codex,grok=grok,muse=scripted] [node flags]\n\
         \  pantheon node HOME [--backend B] [--behavior honest|deny|silent] [--goal FILE] [--deny PATH]\n\
         \                     [--ci CMD] [--ci-image IMAGE] [--bid-window N] [--perspective TEXT] [--max-llm-calls N]\n\
         \  pantheon status HOME\n\
         \  pantheon tx HOME post \"spec\"     (or any market transaction's fields)\n\n\
         Backends: scripted, claude, codex, grok (XAI_API_KEY), cmd:PROGRAM (prompt on stdin, reply on stdout).\n"

and node init step home flags =
  Sys.set_signal Sys.sigpipe Sys.Signal_ignore;
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
  let backend = ref "scripted" and agent_events = ref [] and ci_cmd = ref "" and ci_image = ref "alpine:3.20" in
  let max_calls = ref 100 and calls = ref 0 in
  let rec go = function
    | "--backend" :: b :: r -> backend := b; go r
    | "--behavior" :: b :: r -> agent_events := !agent_events @ [ [ "agent"; "behavior"; b ] ]; go r
    | "--goal" :: f :: r -> agent_events := !agent_events @ List.map (fun l -> [ "agent"; "goal"; l ]) (lines f); go r
    | "--deny" :: p :: r -> agent_events := !agent_events @ [ [ "agent"; "deny"; p ] ]; go r
    | "--bid-window" :: n :: r -> agent_events := !agent_events @ [ [ "agent"; "bid_window"; n ] ]; go r
    | "--perspective" :: t :: r -> agent_events := !agent_events @ [ [ "agent"; "perspective"; t ] ]; go r
    | "--ci" :: c :: r -> ci_cmd := c; agent_events := !agent_events @ [ [ "agent"; "ci"; "true" ] ]; go r
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
  let signed : (string, string) Hashtbl.t = Hashtbl.create 64 in
  List.iter (fun l -> match String.split_on_char ' ' l with [ k; v ] -> Hashtbl.replace signed k v | _ -> ()) (lines signed_path);
  let blocks_path = Filename.concat home "blocks.log" in
  let repo = Filename.concat home "repo" in
  mkdir_p repo;
  let peers =
    List.filter_map (fun n ->
        if n = me then None
        else Some { name = n; addr = addr_of (addr_of_agent n); out = None; connecting = false; obuf = Buffer.create 4096; next_try = 0. })
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
  (* never sign two different votes for one height, round and kind, even
     across a restart: that is the one thing an honest validator can't do *)
  let guard fields =
    match fields with
    | k :: h :: r :: _ :: vid :: _ when k <> "done" ->
        let slot = String.concat "/" [ k; h; r ] in
        (match Hashtbl.find_opt signed slot with
         | Some v when v <> vid && byz = "" -> say "refusing to sign a second %s at %s: already signed %s" k slot v; false
         | Some _ -> true
         | None -> Hashtbl.replace signed slot vid; append_line signed_path (slot ^ " " ^ vid); true)
    | _ -> true
  in
  let start_job prog args ~stdin_text ~env ~on_done ~clean =
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
      jobs := { jfd = r; jpid = pid; jbuf = Buffer.create 4096; jdone = on_done; jstarted = Unix.gettimeofday ();
                jclean = (fun () -> (try Sys.remove inp with _ -> ()); (try ignore (Sys.command ("rm -rf " ^ Filename.quote cwd)) with _ -> ()); clean ()) } :: !jobs
    end
  in
  let model_env () =
    Unix.environment () |> Array.to_list |> List.filter (fun kv -> not (String.length kv > 9 && String.sub kv 0 9 = "PANTHEON_")) |> Array.of_list
  in
  (* a model call: tools off, a scratch directory, no keys in reach *)
  let call_model id prompt =
    let prompt = replace_all prompt "{{F}}" (random_hex 8) in
    let reply text =
      if String.length text > 0 && text.[0] = '!' then push [ "llm_error"; id; String.sub text 1 (String.length text - 1) ]
      else
        match json_in_reply text with
        | Some j -> push ("llm_reply" :: id :: flatten_reply j)
        | None -> push [ "llm_error"; id; "the reply had no JSON object" ]
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
        start_job (String.sub b 4 (String.length b - 4)) [] ~stdin_text:prompt ~env:(model_env ()) ~on_done:reply ~clean:ignore
    | b -> push [ "llm_error"; id; "unknown backend " ^ b ]
  in
  (* CI: the head's files with the bid's writes over them, in a container with
     no network, a read-only root and nobody's uid *)
  let run_ci id writes =
    let dir = Filename.temp_dir "pantheon-ci" "" in
    ignore (Sys.command (Printf.sprintf "cp -R %s/. %s/ 2>/dev/null" (Filename.quote repo) (Filename.quote dir)));
    let rec put = function
      | p :: c :: r -> if safe_path p then (mkdir_p (Filename.dirname (Filename.concat dir p)); write_file (Filename.concat dir p) c); put r
      | _ -> ()
    in
    put writes;
    ignore (Sys.command ("chmod -R a+rX " ^ Filename.quote dir));
    let name = "pantheon-ci-" ^ random_hex 6 in
    start_job "docker" [ "run"; "--rm"; "--name"; name; "--network=none"; "--read-only"; "--tmpfs"; "/tmp"; "--cap-drop=ALL";
                         "--security-opt=no-new-privileges"; "--pids-limit=256"; "--memory=1g"; "--user=65534:65534";
                         "-v"; dir ^ ":/work:ro"; "-w"; "/work"; !ci_image; "sh"; "-c"; !ci_cmd ]
      ~stdin_text:"" ~env:(Unix.environment ())
      ~on_done:(fun t -> push [ "ci_result"; id; "ok"; (if String.length t > 0 && t.[0] = '!' then "false" else "true") ])
      ~clean:(fun () -> ignore (Sys.command ("docker rm -f " ^ name ^ " >/dev/null 2>&1; rm -rf " ^ Filename.quote dir)))
  in
  let handle out =
    match out with
    | "broadcast" :: fields ->
        if guard fields then begin
          (match fields with _ :: h :: _ -> mine := (int_of_string h, fields) :: !mine | _ -> ());
          send_consensus fields
        end
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
    | "status" :: ls -> write_file (Filename.concat home "status.txt") (String.concat "\n" ls ^ "\n")
    | [ "write"; p; content ] ->
        if safe_path p then (mkdir_p (Filename.dirname (Filename.concat repo p)); write_file (Filename.concat repo p) content)
    | [ "log"; text ] -> say "%s" text
    | "submit" :: nonce :: fields ->
        let raw = encode_tx key me nonce fields in
        my_txs := (Unix.gettimeofday (), raw) :: !my_txs;
        say "sending %s" (String.concat " " (List.map (fun f -> if String.length f > 60 then String.sub f 0 60 ^ "..." else f) fields));
        push [ "tx"; raw ];
        broadcast_fields [ "tx"; raw ]
    | [ "llm"; id; prompt ] ->
        incr calls;
        if !calls > !max_calls then push [ "llm_error"; id; Printf.sprintf "model call budget of %d used up: restart with a higher --max-llm-calls" !max_calls ]
        else (say "asking %s (request %s, call %d of %d)" !backend id !calls !max_calls; call_model id prompt)
    | "ci" :: id :: writes -> if !ci_cmd = "" then push [ "ci_result"; id; "ok"; "true" ] else run_ci id writes
    | [ "reveal"; t ] ->
        let t = int_of_string t in
        if t < chain_len then push [ "local_tx"; "reveal"; iterate (chain_len - t) secret ]
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
  List.iter (fun (p, c) -> feed [ "file"; p; to_string c ]; if safe_path p && not (Sys.file_exists (Filename.concat repo p)) then
                 (mkdir_p (Filename.dirname (Filename.concat repo p)); write_file (Filename.concat repo p) (to_string c)))
    (to_assoc (member "files" gen));
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
  let me_addr = addr_of (addr_of_agent me) in
  let listener = Unix.socket ~cloexec:true PF_INET SOCK_STREAM 0 in
  Unix.setsockopt listener SO_REUSEADDR true;
  (match me_addr with Unix.ADDR_INET (_, port) -> Unix.bind listener (Unix.ADDR_INET (Unix.inet_addr_any, port)) | a -> Unix.bind listener a);
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
          let fd = Unix.socket ~cloexec:true PF_INET SOCK_STREAM 0 in
          Unix.set_nonblock fd;
          (try Unix.connect fd p.addr; p.out <- Some fd
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
    List.iter (fun j -> if now -. j.jstarted > 600. then (try Unix.kill j.jpid Sys.sigkill with _ -> ())) !jobs;
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
    jobs := List.filter (fun j ->
        if not (List.mem j.jfd r) then true
        else
          match Unix.read j.jfd buf 0 65536 with
          | 0 ->
              Unix.close j.jfd;
              let _, status = Unix.waitpid [] j.jpid in
              let out = Buffer.contents j.jbuf in
              (* the reply first: codex's is a file that cleaning removes *)
              (match status with
               | Unix.WEXITED 0 -> j.jdone (if out = "" then "pending" else out)
               | _ -> j.jdone ("!process failed: " ^ String.sub out 0 (min 300 (String.length out))));
              j.jclean ();
              false
          | n -> Buffer.add_subbytes j.jbuf buf 0 n; true
          | exception _ -> true)
      !jobs;
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
