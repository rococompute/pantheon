(* The shell: the host's side of a Pantheon node and of the commands. Soma
   decides everything (node.soma, node_kernel.soma, cli.soma); this
   carries out the kernel's primitives (sockets and named files), the
   clock, and the host's work: model processes, git, CI and checks, the
   inbox and reply files, the service's socket. The node's tables, peer
   links, timers and signatures are the kernel's (docs/SHELL-IN-SOMA.md,
   "One kernel, two runners"). *)

let fail fmt = Printf.ksprintf (fun s -> prerr_endline ("error: " ^ s); exit 1) fmt
let say fmt = Printf.ksprintf (fun s -> Printf.printf "%s %s\n%!" (string_of_float (Unix.gettimeofday ())) s) fmt

(* ---------- hashing and signatures ---------- *)

let hex s = Cryptokit.transform_string (Cryptokit.Hexa.encode ()) s
let unhex s = Cryptokit.transform_string (Cryptokit.Hexa.decode ()) s
let sha256_raw s = Cryptokit.hash_string (Cryptokit.Hash.sha256 ()) s
let sha256 s = hex (sha256_raw s)

(* length-prefixed, so ["ab"; "c"] and ["a"; "bc"] differ *)
let hash_list l = sha256 (String.concat "" (List.map (fun x -> string_of_int (String.length x) ^ ":" ^ x) l))

(* Signatures are Soma's (nodeio.soma's nio_sign and nio_verify,
   Soma.Crypto). The binary runs nio_sign as this, the same function
   (PKCS#1 v1.5 with SHA-256 is deterministic: the same bytes) in C, about
   ten times faster than Soma's extracted RSA (main.soma), as it runs
   sha256. A key's numbers come as their bytes, most significant first. *)
let digest_info = unhex "3031300d060960864801650304020105000420"

let emsa bits msg =
  let k = bits / 8 in
  let t = digest_info ^ sha256_raw msg in
  "\x00\x01" ^ String.make (k - String.length t - 3) '\xff' ^ "\x00" ^ t

let rsa_sign_bytes bytes n e p q dp dq qinv msg =
  let s (l : int list) = let a = Array.of_list l in String.init (Array.length a) (fun i -> Char.chr (a.(i) land 255)) in
  let key = { Cryptokit.RSA.size = bytes * 8; n = s n; e = s e; d = ""; p = s p; q = s q; dp = s dp; dq = s dq; qinv = s qinv } in
  hex (Cryptokit.RSA.sign_CRT key (emsa key.size msg))


let rng = lazy (Cryptokit.Random.device_rng "/dev/urandom")
let random_hex n = hex (Cryptokit.Random.string (Lazy.force rng) n)

let strings_json l = `List (List.map (fun s -> `String s) l)

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
(* Atomic, synced writes: consensus.state's text (node.soma's snapshot_text)
   is on disk, whole, before any vote it holds is sent. *)
let write_file_synced path text =
  let tmp = path ^ ".tmp" in
  let oc = open_out_bin tmp in
  Fun.protect ~finally:(fun () -> close_out oc) (fun () ->
      output_string oc text;
      flush oc;
      Unix.fsync (Unix.descr_of_out_channel oc));
  Unix.rename tmp path;
  let fd = Unix.openfile (Filename.dirname path) [Unix.O_RDONLY] 0 in
  Fun.protect ~finally:(fun () -> Unix.close fd) (fun () -> Unix.fsync fd)

(* a file's bytes, or "" when there is none: Soma splits logs and goal files
   (node.soma's log_lines) *)
let file_text p = if Sys.file_exists p then read_file p else ""

(* A .plan's open items are computed in Soma ([plan_open] in util.soma), and
   so are the prompts that quote them (node.soma's perform_llm). *)

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

(* ---------- the edits machinery's file work ----------
   cli.soma decides (edits_prog, checkout_edits_prog, check_tree_prog):
   these look at, write and remove a path in a checkout. *)

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

(* a path, its last part not followed: its kind and whether its owner may
   run it *)
let path_stat f =
  match Unix.lstat f with
  | st ->
      let kind = match st.st_kind with Unix.S_REG -> "file" | Unix.S_DIR -> "dir" | Unix.S_LNK -> "symlink" | _ -> "other" in
      [ kind; string_of_bool (st.st_perm land 0o100 <> 0) ]
  | exception _ -> [ "none"; "false" ]

(* a path in a checkout, as an edit sees it *)
let path_probe dir p =
  let f = Filename.concat dir p in
  try
    if not (no_symlink dir p) then "symlink"
    else if Sys.file_exists f && Sys.is_directory f then "dir"
    else if Sys.file_exists f then "file"
    else "none"
  with _ -> "symlink"

let path_write dir p text =
  let f = Filename.concat dir p in
  try mkdir_p (Filename.dirname f); write_keep_mode f text; "" with e -> Printexc.to_string e

let path_remove dir p = try Sys.remove (Filename.concat dir p); "" with e -> Printexc.to_string e

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

let chain_len = 100_000

let repo_dir home name = Filename.concat (Filename.concat home "repos") name

(* ---------- the node ----------
   The node's kernel is Soma (node_kernel.soma): its tables, peer links,
   signatures, files and select are kept and decided there, the same for
   the binary and the unikernel. The shell carries out the kernel's
   primitives on the host (net_* and file_*: Sandbox's, on sockets and
   files) and the host's processes, which a unikernel asks its service
   for: git and paths in the checkouts (what a merge or a model call asks
   of them is the kernel's node_host.soma, as are the model's limit and
   the inbox's poll), and jobs: model calls, checks, CI (nodeio.soma's
   service_op). *)

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

(* test programs print their checks with these *)
let print_lines xs = List.iter print_endline xs
let print_text s = print_string s
let argv () = Array.to_list Sys.argv |> List.tl

type job = { jid : string; jfd : Unix.file_descr; jpid : int;
             jdone : string -> unit; jstarted : float; jlimit : float; jclean : unit -> unit }

(* a connection the kernel names: one a peer opened (read as it comes), or
   one the kernel dialed (written through a buffer the select drains; a
   peer's address is resolved at each dial, so a replaced machine with the
   same VPN name is found again) *)
type link = { lid : string; lfd : Unix.file_descr; dialed : bool; mutable connecting : bool; obuf : Buffer.t }

(* the primitives' state: the node's home, where its named files are, the
   listener and the connections *)
type net = { home : string; mutable listener : Unix.file_descr option; mutable links : link list; mutable counter : int }

let net_listen n address port =
  match resolve (address ^ ":" ^ port) with
  | None -> (false, (0., [ "can't resolve " ^ address ]))
  | Some a ->
      let fd = Unix.socket ~cloexec:true PF_INET SOCK_STREAM 0 in
      (try
         Unix.setsockopt fd SO_REUSEADDR true;
         Unix.bind fd a;
         Unix.listen fd 16;
         n.listener <- Some fd;
         (true, (0., []))
       with e -> (try Unix.close fd with _ -> ()); (false, (0., [ Printexc.to_string e ])))

let net_name n = n.counter <- n.counter + 1; string_of_int n.counter
let net_find n id = List.find_opt (fun l -> l.lid = id) n.links
let net_drop n l = (try Unix.close l.lfd with _ -> ()); n.links <- List.filter (fun x -> x != l) n.links

(* a dial doesn't wait for the other side: a link still connecting is
   written once the select says it can be *)
let net_connect n host port =
  match resolve (host ^ ":" ^ port) with
  | None -> (false, (0., []))
  | Some a ->
      let fd = Unix.socket ~cloexec:true PF_INET SOCK_STREAM 0 in
      Unix.set_nonblock fd;
      let add connecting =
        let id = net_name n in
        n.links <- { lid = id; lfd = fd; dialed = true; connecting; obuf = Buffer.create 4096 } :: n.links;
        (true, (0., [ id ])) in
      (try Unix.connect fd a; add false with
       | Unix.Unix_error ((EINPROGRESS | EWOULDBLOCK | EAGAIN), _, _) -> add true
       | _ -> Unix.close fd; (false, (0., [])))

(* a dialed link's bytes wait in its buffer (64 MiB at most: a peer that
   reads nothing doesn't take the node's memory) *)
let net_send n id data =
  match net_find n id with
  | Some l when l.dialed -> if Buffer.length l.obuf < 64 * 1024 * 1024 then Buffer.add_string l.obuf data; (true, (0., []))
  | Some l -> (try ignore (Unix.write_substring l.lfd data 0 (String.length data)); (true, (0., [])) with _ -> (false, (0., [])))
  | None -> (false, (0., []))

(* One select: new connections, what peers' connections sent and their
   ends, dialed links connected or written to, waiting [ms] at most; a
   job's output wakes it too (the host's events read it). A failed select
   (a descriptor past FD_SETSIZE, EBADF) waits a moment and goes round
   again rather than ending the node. *)
let net_mailbox n job_fds ms =
  let wait = float_of_string ms /. 1000. in
  let reads = (match n.listener with Some l -> [ l ] | None -> [])
              @ List.filter_map (fun l -> if l.dialed then None else Some l.lfd) n.links @ job_fds in
  let writes = List.filter_map (fun l -> if l.dialed && (l.connecting || Buffer.length l.obuf > 0) then Some l.lfd else None) n.links in
  let r, w, _ = try Unix.select reads writes [] wait with
    | Unix.Unix_error (EINTR, _, _) -> ([], [], [])
    | Unix.Unix_error (e, _, _) -> say "select failed (%s): %d connections" (Unix.error_message e) (List.length n.links); Unix.sleepf 0.2; ([], [], []) in
  let evs = ref [] in
  let add e = evs := e :: !evs in
  (match n.listener with
   | Some lfd when List.mem lfd r ->
       (match Unix.accept ~cloexec:true lfd with
        | exception Unix.Unix_error _ -> ()   (* out of descriptors, or the peer gave up *)
        | c, addr ->
            Unix.set_nonblock c;
            let host = match addr with Unix.ADDR_INET (a, _) -> Unix.string_of_inet_addr a | _ -> "" in
            let id = net_name n in
            n.links <- { lid = id; lfd = c; dialed = false; connecting = false; obuf = Buffer.create 16 } :: n.links;
            add [ "opened"; id; host ])
   | _ -> ());
  let buf = Bytes.create 65536 in
  List.iter (fun l ->
      if l.dialed then begin
        if List.mem l.lfd w then
          if l.connecting then begin
            l.connecting <- false;
            match Unix.getsockopt_error l.lfd with None -> () | Some _ -> net_drop n l; add [ "closed"; l.lid ]
          end else begin
            let s = Buffer.contents l.obuf in
            match Unix.write_substring l.lfd s 0 (String.length s) with
            | k -> Buffer.clear l.obuf; Buffer.add_string l.obuf (String.sub s k (String.length s - k))
            | exception Unix.Unix_error ((EAGAIN | EWOULDBLOCK), _, _) -> ()
            | exception _ -> net_drop n l; add [ "closed"; l.lid ]
          end
      end
      else if List.mem l.lfd r then
        match Unix.read l.lfd buf 0 65536 with
        | 0 -> net_drop n l; add [ "closed"; l.lid ]
        | k -> add [ "bytes"; l.lid; Bytes.sub_string buf 0 k ]
        | exception Unix.Unix_error ((EAGAIN | EWOULDBLOCK), _, _) -> ()
        | exception _ -> net_drop n l; add [ "closed"; l.lid ])
    n.links;
  List.rev !evs

(* appended in one write, then to disk: a block or a signed vote survives
   a crash whole *)
let append_synced p s =
  let fd = Unix.openfile p [ Unix.O_WRONLY; Unix.O_APPEND; Unix.O_CREAT ] 0o644 in
  Fun.protect ~finally:(fun () -> Unix.close fd) (fun () ->
      let b = Bytes.of_string s in
      let k = Unix.write fd b 0 (Bytes.length b) in
      if k <> Bytes.length b then failwith (p ^ ": short write");
      Unix.fsync fd)

let net_file n name = Filename.concat n.home name

(* The node's handle: node_open builds the host's runtime and the
   primitives' state, and node_io reaches them by this name. *)
type node_handle = { h_net : net;
                     h_job_fds : unit -> Unix.file_descr list;
                     h_events : unit -> string list list;
                     h_job_complete : string -> string -> string list list;
                     h_job_flood : string -> unit;
                     h_ci_launch : string -> string -> string -> string -> string list list;
                     h_llm_start : string -> string -> string -> string -> string list -> string list -> string list -> string list -> string list option;
                     h_jobs : unit -> (string * (float * (float * bool))) list;
                     h_job_expire : string -> unit;
                     h_run_check : string -> string -> string -> string list -> unit }
let node_handles : (string, node_handle) Hashtbl.t = Hashtbl.create 4
let node_counter = ref 0
let lookup_handle id = try Hashtbl.find node_handles id with Not_found -> fail "unknown node handle %s" id
let fs_dir_entries path = if Sys.file_exists path then Array.to_list (Sys.readdir path) else []
let fs_read_text path = try Some (read_file path) with _ -> None

let node_env_entries () = Array.to_list (Unix.environment ())
let node_float_of_digits s = float_of_string s
let node_float_text f = Printf.sprintf "%.0f" f
(* lists of lists on one wire (nodeio.soma's nio_frame_lists / nio_lists) *)
let frame_lists ls = List.concat_map (fun l -> List.concat_map (fun v -> [ "field"; v ]) l @ [ "alternate" ]) ls
let unframe_lists parts =
  let rec go cur acc = function
    | "field" :: v :: rest -> go (v :: cur) acc rest
    | "alternate" :: rest -> go [] (List.rev cur :: acc) rest
    | [] -> List.rev acc
    | _ -> fail "malformed list frame"
  in
  go [] [] parts

(* The kernel's primitives and the host's work, one operation at a time in
   its wire form (nodeio.soma's io_wire; this match is its io_of_wire for
   them). The answer is nodeio.soma's nanswer: (carried out, or the
   boolean read, (a number, data)). *)
let node_io_handle h op =
  match op with
  | [ "net_listen"; address; port ] -> net_listen h.h_net address port
  | [ "net_mailbox"; ms ] -> (true, (0., frame_lists (net_mailbox h.h_net (h.h_job_fds ()) ms)))
  | [ "net_connect"; host; port; _ ] -> net_connect h.h_net host port
  | [ "net_send"; conn; data ] -> net_send h.h_net conn data
  | [ "net_close"; conn ] -> (match net_find h.h_net conn with Some l -> net_drop h.h_net l | None -> ()); (true, (0., []))
  | [ "file_read"; name ] ->
      (match fs_read_text (net_file h.h_net name) with Some t -> (true, (0., [ t ])) | None -> (false, (0., [])))
  | [ "file_write"; name; durable; text ] ->
      (if durable = "true" then write_file_synced else write_file) (net_file h.h_net name) text; (true, (0., []))
  | [ "file_append"; name; text ] -> append_synced (net_file h.h_net name) text; (true, (0., []))
  | [ "events"; _ ] -> (true, (0., frame_lists (h.h_events ())))
  | "check" :: req :: r :: head :: edits -> h.h_run_check req r head edits; (true, (0., []))
  | [ "job_flood"; jid ] -> h.h_job_flood jid; (true, (0., []))
  | [ "job_expire"; jid ] -> h.h_job_expire jid; (true, (0., []))
  | [ "jobs" ] ->
      (true, (0., frame_lists (List.map (fun (id, (started, (limit, stopped))) ->
         [ id; Printf.sprintf "%.17g" started; Printf.sprintf "%.17g" limit; string_of_bool stopped ]) (h.h_jobs ()))))
  | "llm_start" :: req :: kind :: raw :: prompt :: parts ->
      let rec unpack rev = function
        | "alternate" :: rest -> (List.rev rev, rest)
        | "field" :: value :: rest -> unpack (value :: rev) rest
        | _ -> fail "malformed llm_start operation"
      in
      let ctx, parts = unpack [] parts in
      let clean, parts = unpack [] parts in
      let launch, env = unpack [] parts in
      (match h.h_llm_start req kind raw prompt ctx clean launch env with
       | Some ev -> (true, (0., ev))
       | None -> (false, (0., [])))
  | [ "job_complete"; job; result ] -> (true, (0., frame_lists (h.h_job_complete job result)))
  | [ "ci_launch"; req; out; tree; ci ] -> (true, (0., frame_lists (h.h_ci_launch req out tree ci)))
  | _ -> fail "unknown node operation %s" (String.concat " " op)
let frame s =
  let n = String.length s in
  String.init 4 (fun i -> Char.chr ((n lsr (8 * (3 - i))) land 255)) ^ s
let frame_length s at = (Char.code s.[at] lsl 24) lor (Char.code s.[at + 1] lsl 16) lor (Char.code s.[at + 2] lsl 8) lor Char.code s.[at + 3]
let unframes s =
  let rec go at acc =
    if at + 4 > String.length s then List.rev acc
    else
      let n = frame_length s at in
      if at + 4 + n > String.length s then List.rev acc else go (at + 4 + n) (String.sub s (at + 4) n :: acc)
  in
  go 0 []
type serve_client = { sid : string; sfd : Unix.file_descr; sbuf : Buffer.t }
let serve_listener = ref None
let serve_clients : serve_client list ref = ref []
let serve_counter = ref 0
let serve_listen address port =
  match resolve (address ^ ":" ^ port) with
  | None -> false
  | Some a ->
      (try
         let fd = Unix.socket ~cloexec:true Unix.PF_INET Unix.SOCK_STREAM 0 in
         Unix.setsockopt fd Unix.SO_REUSEADDR true;
         Unix.bind fd a; Unix.listen fd 8; serve_listener := Some fd; true
       with _ -> false)
let serve_drop c = (try Unix.close c.sfd with _ -> ()); serve_clients := List.filter (fun x -> x.sid <> c.sid) !serve_clients
(* a whole request a client sent, taken out of its buffer *)
let serve_take () =
  List.find_map (fun c ->
      let s = Buffer.contents c.sbuf in
      if String.length s < 4 then None
      else
        let n = frame_length s 0 in
        if String.length s < 4 + n then None
        else begin
          Buffer.clear c.sbuf; Buffer.add_string c.sbuf (String.sub s (4 + n) (String.length s - 4 - n));
          Some (c.sid :: unframes (String.sub s 4 n))
        end)
    !serve_clients
let serve_next wait =
  match serve_take () with
  | Some r -> Some r
  | None ->
      let fds = (match !serve_listener with Some l -> [ l ] | None -> []) @ List.map (fun c -> c.sfd) !serve_clients in
      let r, _, _ = try Unix.select fds [] [] wait with Unix.Unix_error _ -> ([], [], []) in
      let buf = Bytes.create 65536 in
      List.iter (fun fd ->
          if Some fd = !serve_listener then
            (match Unix.accept ~cloexec:true fd with
             | c, _ -> incr serve_counter;
                 serve_clients := { sid = string_of_int !serve_counter; sfd = c; sbuf = Buffer.create 4096 } :: !serve_clients
             | exception Unix.Unix_error _ -> ())
          else
            match List.find_opt (fun c -> c.sfd = fd) !serve_clients with
            | None -> ()
            | Some c ->
                (match Unix.read fd buf 0 65536 with
                 | 0 -> serve_drop c
                 | n -> Buffer.add_subbytes c.sbuf buf 0 n
                 | exception _ -> serve_drop c))
        r;
      serve_take ()
let serve_reply sid fields =
  match List.find_opt (fun c -> c.sid = sid) !serve_clients with
  | None -> ()
  | Some c ->
      let data = frame (String.concat "" (List.map frame fields)) in
      let rec put at = if at < String.length data then put (at + Unix.write_substring c.sfd data at (String.length data - at)) in
      (try put 0 with _ -> serve_drop c)
(* Path-only operations need no node: a test runs them with no handle. *)
let node_io id op =
  match op with
  | [ "read_text"; path ] -> (match fs_read_text path with Some c -> (true, (0., [ c ])) | None -> (false, (0., [])))
  | [ "discard_file"; path ] -> (try Sys.remove path with _ -> ()); (true, (0., []))
  | [ "dir_entries"; path ] -> (true, (0., fs_dir_entries path))
  | [ "remove_file"; path ] -> Sys.remove path; (true, (0., []))
  | [ "fail"; message ] -> fail "%s" message
  | [ "clock" ] -> (true, (Unix.gettimeofday (), []))
  | [ "log"; text ] -> say "%s" text; (true, (0., []))
  | [ "local_time"; stamp ] ->
      let tm = Unix.localtime (node_float_of_digits stamp) in
      (true, (0., [ Printf.sprintf "%02d:%02d" tm.Unix.tm_hour tm.Unix.tm_min ]))
  | [ "token" ] -> (true, (0., [ random_hex 8 ]))
  | [ "self_exe" ] -> (true, (0., [ self_exe ]))
  | [ "serve_listen"; address; port ] -> (serve_listen address port, (0., []))
  | [ "serve_next"; wait ] ->
      (match serve_next (float_of_string wait) with Some r -> (true, (0., r)) | None -> (false, (0., [])))
  | "serve_reply" :: sid :: fields -> serve_reply sid fields; (true, (0., []))
  | [ "env_entries" ] -> (true, (0., Array.to_list (Unix.environment ())))
  (* the commands' I/O (cli.soma) *)
  | [ "say"; text ] -> say "%s" text; (true, (0., []))
  | [ "print"; text ] -> print_string text; flush stdout; (true, (0., []))
  | [ "exit"; code ] -> exit (int_of_string code)
  | [ "file_exists"; path ] -> (Sys.file_exists path, (0., []))
  | [ "write_file"; path; text ] -> write_file path text; (true, (0., []))
  | [ "chmod"; path; mode ] -> ((try Unix.chmod path (int_of_string ("0o" ^ mode)); true with _ -> false), (0., []))
  | [ "make_dirs"; path ] -> mkdir_p path; (true, (0., []))
  | [ "cwd" ] -> (true, (0., [ Sys.getcwd () ]))
  | [ "new_key"; bits ] ->
      let k = Cryptokit.RSA.new_key ~rng:(Lazy.force rng) ~e:65537 (int_of_string bits) in
      (true, (0., string_of_int k.size :: List.map hex [ k.n; k.e; k.d; k.p; k.q; k.dp; k.dq; k.qinv ]))
  | [ "random_hex"; count ] -> (true, (0., [ random_hex (int_of_string count) ]))
  | "git" :: dir :: args -> let ok, out = git dir args in (ok, (0., [ out ]))
  | [ "clone"; url; dir; commit ] -> (clone url dir commit, (0., []))
  | "spawn_node" :: log :: args ->
      let fd = Unix.openfile log [ O_WRONLY; O_CREAT; O_APPEND ] 0o644 in
      let pid = Unix.create_process self_exe (Array.of_list (self_exe :: args)) Unix.stdin fd fd in
      Unix.close fd;
      (true, (0., [ string_of_int pid ]))
  | "await_nodes" :: pids ->
      let pids = List.map int_of_string pids in
      let stop _ = List.iter (fun p -> try Unix.kill p Sys.sigterm with _ -> ()) pids; exit 0 in
      Sys.set_signal Sys.sigint (Sys.Signal_handle stop);
      Sys.set_signal Sys.sigterm (Sys.Signal_handle stop);
      List.iter (fun p -> ignore (Unix.waitpid [] p)) pids;
      (true, (0., []))
  | [ "path_stat"; path ] -> (true, (0., path_stat path))
  | [ "path_probe"; dir; path ] -> (true, (0., [ path_probe dir path ]))
  | [ "path_write"; dir; path; text ] -> (true, (0., [ path_write dir path text ]))
  | [ "path_remove"; dir; path ] -> (true, (0., [ path_remove dir path ]))
  | [ "temp_dir"; prefix ] -> (true, (0., [ Filename.temp_dir prefix "" ]))
  | [ "remove_tree"; path ] -> remove_tree_later path; (true, (0., []))
  | "git_env" :: dir :: stdin :: rest ->
      (* its standard input ("": none), the environment's entries framed
         ("field" VALUE...), "alternate", then git's arguments as they are *)
      let rec split acc = function
        | "field" :: v :: rest -> split (v :: acc) rest
        | "alternate" :: args -> Some (List.rev acc, args)
        | _ -> None in
      (match split [] rest with
       | Some (extra, args) ->
           let ok, out = git ~extra ?stdin:(if stdin = "" then None else Some stdin) dir args in (ok, (0., [ out ]))
       | None -> (false, (0., [ "git_env came malformed" ])))
  | _ -> node_io_handle (lookup_handle id) op
let rec forever f s = forever f (f s)

(* The host's runtime and the primitives' state, from what cli.soma's
   node_setup read, checked and decided: the settings, this node's key,
   its excluded repositories, those it can't check, CI commands by
   repository, the agents, the repositories, those still at genesis, then
   the boot events (the kernel's: node_kernel.soma's kernel_world). *)
let node_open config =
  Sys.set_signal Sys.sigpipe Sys.Signal_ignore;
  let settings, ci_repo_l =
    match unframe_lists config with
    | s :: _ :: _ :: _ :: cr :: _ -> (s, cr)
    | _ -> fail "the node's setup came back malformed" in
  let home, ci_s, ci_memory_s, ci_image_s, ci_sandbox_s =
    match settings with
    | [ home; _; _; _; _; _; _; ci; mem; img; sbx; _ ] -> (home, ci, mem, img, sbx)
    | _ -> fail "the node's setup came back malformed" in
  let rec pairs = function a :: b :: r -> (a, b) :: pairs r | _ -> [] in
  let ci_cmd = ref ci_s and ci_repo = ref (pairs ci_repo_l) and ci_image = ref ci_image_s
  and ci_sandbox = ref ci_sandbox_s and ci_memory = ref ci_memory_s in
  (* the host's events: its jobs' output and ends, and their callbacks' *)
  let queue = Queue.create () in
  let push ev = Queue.add ev queue in
  let drain () = let evs = ref [] in while not (Queue.is_empty queue) do evs := Queue.pop queue :: !evs done; List.rev !evs in
  let jobs : job list ref = ref [] in
  let job_counter = ref 0 in
  let finished_jobs : (string, job) Hashtbl.t = Hashtbl.create 8 in
  let rdir n = repo_dir home n in
  let ci_for r = try List.assoc r !ci_repo with Not_found -> !ci_cmd in
  (* jobs Soma stopped for running past their time limit (job_should_expire) *)
  let overtime = Hashtbl.create 8 in
  (* jobs stopped for printing more than any reply can be. Soma's job_feed
     decides; the IoJobFlood operation marks the job and signals it once. The node
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
  (* a model call: a scratch directory, no keys in reach; built-in backends
     have no tools, and a cmd: backend asked for a patch gets a fresh
     checkout (node_host.soma's). The model's budget, its limit and the
     requests held for it are the kernel's (node_host.soma). *)
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
    (* Soma checks eligibility before requesting this process. *)
    start_job self_exe [ "check"; rdir r; head; ef; out ] ~stdin_text:"" ~env:(Unix.environment ())
      ~on_done:(fun t ->
        (* a failure, the trimmed tree, or a CI run: node.soma's check_apply_events *)
        push [ "check_apply_out"; id; out; ci; t ])
      ~clean:(fun () -> (try Sys.remove ef with _ -> ()); if ci = "" then rm_out ())
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
  (* the jobs' output and ends since the last look, without waiting *)
  let collect_events () =
    let fds = List.map (fun j -> j.jfd) !jobs in
    let r = if fds = [] then [] else
      (let r, _, _ = try Unix.select fds [] [] 0. with Unix.Unix_error _ -> ([], [], []) in r) in
    let buf = Bytes.create 65536 in
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
        let tag, value = match status with
          | Unix.WEXITED c -> ("exit", string_of_int c)
          | Unix.WSIGNALED sg -> ("signal", string_of_int sg)
          | Unix.WSTOPPED sg -> ("stop", string_of_int sg) in
        let timeout = match Hashtbl.find_opt overtime j.jpid with Some limit -> node_float_text limit | None -> "" in
        let flood = if Hashtbl.mem flooded j.jpid then "1" else "0" in
        Hashtbl.remove overtime j.jpid; Hashtbl.remove flooded j.jpid;
        Hashtbl.replace finished_jobs j.jid j;
        push [ "job_finished"; j.jid; tag; value; timeout; flood ])
      (List.rev !finished);
    drain ()
  in
  let handle_id = string_of_int !node_counter in
  incr node_counter;
  Hashtbl.replace node_handles handle_id
    { h_net = { home; listener = None; links = []; counter = 0 };
      h_job_fds = (fun () -> List.map (fun j -> j.jfd) !jobs);
      h_events = collect_events;
      h_job_complete = (fun jid result ->
        match Hashtbl.find_opt finished_jobs jid with
        | None -> []
        | Some j ->
            Hashtbl.remove finished_jobs jid;
            j.jdone result;
            j.jclean ();
            drain ());
      h_ci_launch = launch_ci;
      h_job_flood = (fun jid ->
        match List.find_opt (fun j -> j.jid = jid) !jobs with
        | Some j when not (Hashtbl.mem flooded j.jpid) ->
            Hashtbl.replace flooded j.jpid (); Hashtbl.replace cut j.jpid ();
            (try Unix.kill j.jpid Sys.sigkill with _ -> ())
        | _ -> ());
      h_llm_start = call_model;
      h_jobs = (fun () -> List.map (fun j -> (j.jid, (j.jstarted, (j.jlimit, Hashtbl.mem overtime j.jpid)))) !jobs);
      h_job_expire = expire_job;
      h_run_check = run_check };
  handle_id
