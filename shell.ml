(* The shell: the host's side of a Pantheon node and of the commands. Soma
   decides everything (node.soma, node_kernel.soma, node_host.soma,
   cli.soma); this carries out the kernel's primitives (sockets and named
   files), the clock, and the host's: git, paths, temporary files,
   processes, the inbox and reply files, the service's socket. The node's
   tables, peer links, timers and signatures are the kernel's, and so are
   its jobs, a merge's git and the model's limit (docs/SHELL-IN-SOMA.md,
   "One kernel, two runners" and "The host's work"). *)

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

(* a process the kernel started (node_host.soma keeps its job): its name,
   the pipe its output comes on, its pid *)
type job = { jid : string; jfd : Unix.file_descr; jpid : int }

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

(* ---------- processes ----------
   The kernel's jobs (node_host.soma) are processes here: started from a
   scratch directory the kernel made, reading their standard input from a
   file (so no pipe can fill up while their output is read), their output
   read as it comes and their end reported, and killed when the kernel
   says. What a job is for, its time limit, what goes with it and what its
   end becomes are the kernel's. *)
let procs : job list ref = ref []
let proc_counter = ref 0
(* processes killed: they end at the next look, without waiting for the
   pipe to close (a check's shell killed, the `yes` it ran may still hold
   it open and write, which would hold the job, and CI's turn, forever) *)
let proc_cut : (int, unit) Hashtbl.t = Hashtbl.create 8
let proc_fds () = List.map (fun j -> j.jfd) !procs

let proc_start prog stdin cwd env args =
  let inp = Filename.temp_file "pantheon-in" ".txt" in
  write_file inp stdin;
  let ifd = Unix.openfile inp [ O_RDONLY ] 0 in
  (try Sys.remove inp with _ -> ());
  let r, w = Unix.pipe ~cloexec:true () in
  let devnull = Unix.openfile "/dev/null" [ O_WRONLY ] 0 in
  let old = Sys.getcwd () in
  match Sys.chdir cwd; Unix.create_process_env prog (Array.of_list (prog :: args)) (Array.of_list env) ifd w devnull with
  | exception e ->
      (try Sys.chdir old with _ -> ());
      List.iter (fun fd -> try Unix.close fd with _ -> ()) [ r; w; ifd; devnull ];
      (false, (0., [ Printexc.to_string e ]))
  | pid ->
      Sys.chdir old;
      Unix.close w; Unix.close ifd; Unix.close devnull;
      let jid = string_of_int !proc_counter in
      incr proc_counter;
      procs := { jid; jfd = r; jpid = pid } :: !procs;
      (true, (0., [ jid ]))

let proc_kill jid =
  match List.find_opt (fun j -> j.jid = jid) !procs with
  | Some j -> Hashtbl.replace proc_cut j.jpid (); (try Unix.kill j.jpid Sys.sigkill with _ -> ())
  | None -> ()

(* the processes' output and ends since the last look, without waiting:
   ["job_bytes", JOB, CHUNK] and ["job_ended", JOB, HOW, VALUE] (how:
   exit, signal or stop, the wait status's facts) *)
let proc_events () =
  let fds = proc_fds () in
  let r = if fds = [] then [] else
    (let r, _, _ = try Unix.select fds [] [] 0. with Unix.Unix_error _ -> ([], [], []) in r) in
  let buf = Bytes.create 65536 in
  let evs = ref [] and finished = ref [] in
  procs := List.filter (fun j ->
      if Hashtbl.mem proc_cut j.jpid then begin
        Hashtbl.remove proc_cut j.jpid;
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
        | n -> evs := [ "job_bytes"; j.jid; Bytes.sub_string buf 0 n ] :: !evs; true
        | exception _ -> true)
    !procs;
  List.iter (fun (j, status) ->
      let tag, value = match status with
        | Unix.WEXITED c -> ("exit", string_of_int c)
        | Unix.WSIGNALED sg -> ("signal", string_of_int sg)
        | Unix.WSTOPPED sg -> ("stop", string_of_int sg) in
      evs := [ "job_ended"; j.jid; tag; value ] :: !evs)
    (List.rev !finished);
  List.rev !evs

(* a new temporary file with [text] in it, private as temp_file makes it *)
let temp_file prefix suffix text =
  let f = Filename.temp_file prefix suffix in
  Out_channel.with_open_bin f (fun oc -> output_string oc text);
  f

(* The node's handle: node_open builds the host's runtime and the
   primitives' state, and node_io reaches them by this name. *)
(* The node's handle: node_open builds the primitives' state (the
   network's), and node_io reaches it by this name. *)
type node_handle = { h_net : net }
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
  | [ "net_mailbox"; ms ] -> (true, (0., frame_lists (net_mailbox h.h_net (proc_fds ()) ms)))
  | [ "net_connect"; host; port; _ ] -> net_connect h.h_net host port
  | [ "net_send"; conn; data ] -> net_send h.h_net conn data
  | [ "net_close"; conn ] -> (match net_find h.h_net conn with Some l -> net_drop h.h_net l | None -> ()); (true, (0., []))
  | [ "file_read"; name ] ->
      (match fs_read_text (net_file h.h_net name) with Some t -> (true, (0., [ t ])) | None -> (false, (0., [])))
  | [ "file_write"; name; durable; text ] ->
      (if durable = "true" then write_file_synced else write_file) (net_file h.h_net name) text; (true, (0., []))
  | [ "file_append"; name; text ] -> append_synced (net_file h.h_net name) text; (true, (0., []))
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
  | "proc_start" :: prog :: stdin :: cwd :: rest ->
      (* the environment's entries framed ("field" VALUE...), "alternate",
         then the program's arguments as they are *)
      let rec split acc = function
        | "field" :: v :: rest -> split (v :: acc) rest
        | "alternate" :: args -> Some (List.rev acc, args)
        | _ -> None in
      (match split [] rest with
       | Some (env, args) -> proc_start prog stdin cwd env args
       | None -> (false, (0., [ "proc_start came malformed" ])))
  | [ "proc_kill"; jid ] -> proc_kill jid; (true, (0., []))
  | [ "events"; _ ] -> (true, (0., frame_lists (proc_events ())))
  | "run" :: prog :: args -> let ok, out = capture prog args in (ok, (0., [ out ]))
  | [ "temp_file"; prefix; suffix; text ] -> (true, (0., [ temp_file prefix suffix text ]))
  | _ -> node_io_handle (lookup_handle id) op
let rec forever f s = forever f (f s)

(* The host's runtime and the primitives' state, from what cli.soma's
   node_setup read, checked and decided: the settings, this node's key,
   its excluded repositories, those it can't check, CI commands by
   repository, the agents, the repositories, those still at genesis, then
   the boot events (the kernel's: node_kernel.soma's kernel_world). *)
let node_open config =
  Sys.set_signal Sys.sigpipe Sys.Signal_ignore;
  let home =
    match unframe_lists config with
    | (home :: _) :: _ -> home
    | _ -> fail "the node's setup came back malformed" in
  let handle_id = string_of_int !node_counter in
  incr node_counter;
  Hashtbl.replace node_handles handle_id { h_net = { home; listener = None; links = []; counter = 0 } };
  handle_id
