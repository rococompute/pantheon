(* The shell: the host's side of a Pantheon node and of the commands. Soma
   decides everything (node.soma, node_kernel.soma, node_host.soma,
   cli.soma); this carries out primitives, one operation at a time in
   node_io's wire form (nodeio.soma's io_wire), and decides nothing:

   - the kernel's (net_* and file_*: Sandbox's, on sockets and the node's
     named files), with the clock and the log;
   - the host's (nodeio.soma's service_op: what a unikernel asks its
     service for): git, paths, temporary files, programs and processes;
   - the service's socket and the commands' I/O.

   The node's tables, peer links, timers and signatures are the kernel's,
   and so are its jobs, a merge's git and the model's limit
   (docs/SHELL-IN-SOMA.md, "One kernel, two runners" and "The host's
   work"). Every answer is nodeio.soma's nanswer: (carried out, or the
   boolean read, (a number, data)). *)

let fail fmt = Printf.ksprintf (fun s -> prerr_endline ("error: " ^ s); exit 1) fmt
let say fmt = Printf.ksprintf (fun s -> Printf.printf "%s %s\n%!" (string_of_float (Unix.gettimeofday ())) s) fmt

(* nanswer's shapes (nodeio.soma's ans_ok, ans_flag, ans_data) *)
let ans_ok = (true, (0., []))
let ans_flag b = (b, (0., []))
let ans_data l = (true, (0., l))
let ans_found = function Some x -> ans_data [ x ] | None -> ans_flag false

(* ---------- hashing and signatures ----------
   Soma's (util.soma's sha256 and hash_list, nodeio.soma's nio_sign, through
   Soma.Crypto); the binary runs these, the same functions, in C (main.soma's
   Extract Constant): about ten times faster than the extracted ones. *)

let hex s = Cryptokit.transform_string (Cryptokit.Hexa.encode ()) s
let unhex s = Cryptokit.transform_string (Cryptokit.Hexa.decode ()) s
let sha256_raw s = Cryptokit.hash_string (Cryptokit.Hash.sha256 ()) s
let sha256 s = hex (sha256_raw s)

(* length-prefixed, so ["ab"; "c"] and ["a"; "bc"] differ *)
let hash_list l = sha256 (String.concat "" (List.map (fun x -> string_of_int (String.length x) ^ ":" ^ x) l))

(* PKCS#1 v1.5 with SHA-256 (deterministic: the same bytes as Soma's). A
   key's numbers come as their bytes, most significant first. *)
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

let new_key bits =
  let k = Cryptokit.RSA.new_key ~rng:(Lazy.force rng) ~e:65537 bits in
  string_of_int k.size :: List.map hex [ k.n; k.e; k.d; k.p; k.q; k.dp; k.dq; k.qinv ]

(* ---------- files ---------- *)

let read_file p = In_channel.with_open_bin p In_channel.input_all
let read_text p = try Some (read_file p) with _ -> None

(* whole, through a temporary file renamed into place; [sync]: on disk,
   file and directory, before the rename is relied on (consensus.state's
   text, node.soma's snapshot_text, before any vote it holds is sent) *)
let write_file ?(sync = false) p s =
  let tmp = p ^ ".tmp" in
  Out_channel.with_open_bin tmp (fun oc ->
      output_string oc s;
      if sync then (flush oc; Unix.fsync (Unix.descr_of_out_channel oc)));
  Unix.rename tmp p;
  if sync then begin
    let fd = Unix.openfile (Filename.dirname p) [ Unix.O_RDONLY ] 0 in
    Fun.protect ~finally:(fun () -> Unix.close fd) (fun () -> Unix.fsync fd)
  end

(* appended in one write, then to disk: a block or a signed vote survives a
   crash whole *)
let append_synced p s =
  let fd = Unix.openfile p [ Unix.O_WRONLY; Unix.O_APPEND; Unix.O_CREAT ] 0o644 in
  Fun.protect ~finally:(fun () -> Unix.close fd) (fun () ->
      let b = Bytes.of_string s in
      if Unix.write fd b 0 (Bytes.length b) <> Bytes.length b then failwith (p ^ ": short write");
      Unix.fsync fd)

(* a new temporary file with [text] in it, private as temp_file makes it *)
let temp_file prefix suffix text =
  let f = Filename.temp_file prefix suffix in
  Out_channel.with_open_bin f (fun oc -> output_string oc text);
  f

let rec mkdir_p d = if d <> "" && d <> "." && d <> "/" && not (Sys.file_exists d) then (mkdir_p (Filename.dirname d); Unix.mkdir d 0o755)

(* A tree removed in the background: a checkout with a build in it is close
   to a GB, and removing it in the main loop stalled consensus for minutes *)
let remove_tree_later path = ignore (Sys.command ("rm -rf " ^ Filename.quote path ^ " >/dev/null 2>&1 &"))

(* The node's own binary, as an absolute path, fixed when the program starts
   and before anything changes directory (docs/SECURITY-REVIEW-2.md P-10):
   started as ./main.exe, a check or a model's PANTHEON_BIN run from a
   scratch directory would otherwise miss it. The path it was invoked as when
   that names a file (has a /), else what the system says it is. *)
let self_exe =
  let e = if Array.length Sys.argv > 0 && String.contains Sys.argv.(0) '/' then Sys.argv.(0) else Sys.executable_name in
  if Filename.is_relative e then Filename.concat (Sys.getcwd ()) e else e

(* ---------- paths in a checkout ----------
   cli.soma and node_host.soma decide (edits_prog, check_tree_prog, a
   merge's file work): these look at, write and remove one path. *)

(* a path, its last part not followed: its kind and whether its owner may
   run it *)
let path_stat f =
  match Unix.lstat f with
  | st ->
      let kind = match st.st_kind with Unix.S_REG -> "file" | Unix.S_DIR -> "dir" | Unix.S_LNK -> "symlink" | _ -> "other" in
      [ kind; string_of_bool (st.st_perm land 0o100 <> 0) ]
  | exception _ -> [ "none"; "false" ]

(* no part of the path is a symlink: a write can't leave the checkout *)
let no_symlink dir p =
  let rec go cur = function
    | [] -> true
    | x :: r ->
        let c = Filename.concat cur x in
        (match (Unix.lstat c).st_kind with Unix.S_LNK -> false | _ -> go c r | exception Unix.Unix_error _ -> true)
  in
  go dir (String.split_on_char '/' p)

(* a path in a checkout, as an edit sees it *)
let path_probe dir p =
  let f = Filename.concat dir p in
  try
    if not (no_symlink dir p) then "symlink"
    else if Sys.file_exists f && Sys.is_directory f then "dir"
    else if Sys.file_exists f then "file"
    else "none"
  with _ -> "symlink"

(* "" when it worked, else what went wrong; a write keeps the file's mode *)
let attempt f = try f (); "" with e -> Printexc.to_string e

let path_write dir p text =
  let f = Filename.concat dir p in
  attempt (fun () ->
      mkdir_p (Filename.dirname f);
      let mode = try Some (Unix.stat f).st_perm with _ -> None in
      let tmp = f ^ ".pantheon-tmp" in
      Out_channel.with_open_bin tmp (fun oc -> output_string oc text);
      Option.iter (Unix.chmod tmp) mode;
      Unix.rename tmp f)

let path_remove dir p = attempt (fun () -> Sys.remove (Filename.concat dir p))

(* ---------- programs and git ---------- *)

(* a program's standard input: [text] in a temporary file, opened and then
   removed (so no pipe can fill up while its output is read) *)
let stdin_fd text =
  let f = Filename.temp_file "pantheon-in" ".txt" in
  Out_channel.with_open_bin f (fun oc -> output_string oc text);
  let fd = Unix.openfile f [ O_RDONLY; O_CLOEXEC ] 0 in
  (try Sys.remove f with _ -> ());
  fd

let close_all = List.iter (fun fd -> try Unix.close fd with _ -> ())

(* run a program to its end: whether it succeeded, and its output. With
   [stdin], it reads that text instead of /dev/null *)
let capture ?(env = Unix.environment ()) ?stdin prog args =
  let r, w = Unix.pipe ~cloexec:true () in
  let devnull = Unix.openfile "/dev/null" [ O_RDWR; O_CLOEXEC ] 0 in
  let inp = match stdin with None -> devnull | Some text -> stdin_fd text in
  let opened = if inp == devnull then [ devnull ] else [ devnull; inp ] in
  match Unix.create_process_env prog (Array.of_list (prog :: args)) env inp w devnull with
  | exception e -> close_all (r :: w :: opened); (false, Printexc.to_string e)
  | pid ->
      close_all (w :: opened);
      let ic = Unix.in_channel_of_descr r in
      let out = In_channel.input_all ic in
      close_in ic;
      let _, st = Unix.waitpid [] pid in
      (st = Unix.WEXITED 0, out)

(* git for a checkout Pantheon owns: no user or system config, no hooks, no
   signing, so every node does exactly the same thing; [extra] environment
   entries first *)
let git ?(extra = []) ?stdin dir args =
  let env =
    extra @ [ "GIT_CONFIG_NOSYSTEM=1"; "GIT_CONFIG_GLOBAL=/dev/null"; "GIT_TERMINAL_PROMPT=0" ]
    @ List.filter (fun kv -> not (String.starts_with ~prefix:"GIT_" kv)) (Array.to_list (Unix.environment ())) in
  capture ~env:(Array.of_list env) ?stdin "git"
    ("-C" :: dir :: "-c" :: "core.hooksPath=/dev/null" :: "-c" :: "commit.gpgsign=false" :: "-c" :: "core.autocrlf=false"
     :: "-c" :: "core.fileMode=true" :: "-c" :: "core.symlinks=true" :: args)

(* a clone from anywhere git can fetch: here the user's own git config
   applies, for credentials to a private repository *)
let clone url dir commit =
  fst (capture ~env:(Array.append [| "GIT_TERMINAL_PROMPT=0" |] (Unix.environment ())) "git" [ "clone"; "--quiet"; url; dir ])
  && fst (git dir [ "checkout"; "-q"; "--detach"; commit ])

(* ---------- processes ----------
   The kernel's jobs (node_host.soma) are processes here: started from a
   scratch directory the kernel made, their output read as it comes and
   their end reported, killed when the kernel says. What a job is for, its
   time limit, what goes with it and what its end becomes are the kernel's. *)

(* a process the kernel started: its name, the pipe its output comes on,
   its pid *)
type proc = { jid : string; jfd : Unix.file_descr; jpid : int }

let procs : proc list ref = ref []
let proc_counter = ref 0
(* processes killed: they end at the next look, without waiting for the
   pipe to close (a check's shell killed, the `yes` it ran may still hold
   it open and write, which would hold the job, and CI's turn, forever) *)
let proc_cut : (int, unit) Hashtbl.t = Hashtbl.create 8
let proc_fds () = List.map (fun j -> j.jfd) !procs

let proc_start prog stdin cwd env args =
  let ifd = stdin_fd stdin in
  let r, w = Unix.pipe ~cloexec:true () in
  let devnull = Unix.openfile "/dev/null" [ O_WRONLY ] 0 in
  let old = Sys.getcwd () in
  match Sys.chdir cwd; Unix.create_process_env prog (Array.of_list (prog :: args)) (Array.of_list env) ifd w devnull with
  | exception e ->
      (try Sys.chdir old with _ -> ());
      close_all [ r; w; ifd; devnull ];
      (false, (0., [ Printexc.to_string e ]))
  | pid ->
      Sys.chdir old;
      close_all [ w; ifd; devnull ];
      let jid = string_of_int !proc_counter in
      incr proc_counter;
      procs := { jid; jfd = r; jpid = pid } :: !procs;
      ans_data [ jid ]

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
  let finish j = close_all [ j.jfd ]; finished := (j, snd (Unix.waitpid [] j.jpid)) :: !finished; false in
  procs := List.filter (fun j ->
      if Hashtbl.mem proc_cut j.jpid then (Hashtbl.remove proc_cut j.jpid; finish j)
      else if not (List.mem j.jfd r) then true
      else
        match Unix.read j.jfd buf 0 65536 with
        | 0 -> finish j
        | n -> evs := [ "job_bytes"; j.jid; Bytes.sub_string buf 0 n ] :: !evs; true
        | exception _ -> true)
    !procs;
  List.iter (fun (j, status) ->
      let tag, value = match status with
        | Unix.WEXITED c -> ("exit", c)
        | Unix.WSIGNALED sg -> ("signal", sg)
        | Unix.WSTOPPED sg -> ("stop", sg) in
      evs := [ "job_ended"; j.jid; tag; string_of_int value ] :: !evs)
    (List.rev !finished);
  List.rev !evs

(* ---------- the network ----------
   The kernel's primitives (node_kernel.soma), as Sandbox has them: a
   listener, connections a peer opened (read as they come) and connections
   the kernel dialed (written through a buffer the select drains; a peer's
   address is resolved at each dial, so a replaced machine with the same
   VPN name is found again). Admission, line caps and buffered bytes are
   the kernel's. *)

let resolve host port =
  match Unix.getaddrinfo host port [ Unix.AI_FAMILY Unix.PF_INET; Unix.AI_SOCKTYPE Unix.SOCK_STREAM ] with
  | a :: _ -> Some a.Unix.ai_addr
  | [] | (exception _) -> None

(* a listening socket on HOST:PORT, or why not *)
let listen_on host port backlog =
  match resolve host port with
  | None -> Error ("can't resolve " ^ host)
  | Some a ->
      let fd = Unix.socket ~cloexec:true PF_INET SOCK_STREAM 0 in
      (try Unix.setsockopt fd SO_REUSEADDR true; Unix.bind fd a; Unix.listen fd backlog; Ok fd
       with e -> close_all [ fd ]; Error (Printexc.to_string e))

type link = { lid : string; lfd : Unix.file_descr; dialed : bool; mutable connecting : bool; obuf : Buffer.t }

(* the primitives' state: the node's home, where its named files are, the
   listener and the connections *)
type net = { home : string; mutable listener : Unix.file_descr option; mutable links : link list; mutable counter : int }

let net_name n = n.counter <- n.counter + 1; string_of_int n.counter
let net_find n id = List.find_opt (fun l -> l.lid = id) n.links
let net_drop n l = close_all [ l.lfd ]; n.links <- List.filter (fun x -> x != l) n.links
let net_add n fd ~dialed ~connecting = let id = net_name n in
  n.links <- { lid = id; lfd = fd; dialed; connecting; obuf = Buffer.create (if dialed then 4096 else 16) } :: n.links; id

let net_listen n host port =
  match listen_on host port 16 with
  | Ok fd -> n.listener <- Some fd; ans_ok
  | Error why -> (false, (0., [ why ]))

(* a dial doesn't wait for the other side: a link still connecting is
   written once the select says it can be *)
let net_connect n host port =
  match resolve host port with
  | None -> ans_flag false
  | Some a ->
      let fd = Unix.socket ~cloexec:true PF_INET SOCK_STREAM 0 in
      Unix.set_nonblock fd;
      (match Unix.connect fd a with
       | () -> ans_data [ net_add n fd ~dialed:true ~connecting:false ]
       | exception Unix.Unix_error ((EINPROGRESS | EWOULDBLOCK | EAGAIN), _, _) -> ans_data [ net_add n fd ~dialed:true ~connecting:true ]
       | exception _ -> close_all [ fd ]; ans_flag false)

(* only a dialed link is written to (the kernel sends on its links to its
   peers); its bytes wait in its buffer, 64 MiB at most: a peer that reads
   nothing doesn't take the node's memory *)
let net_send n id data =
  match net_find n id with
  | Some l when l.dialed -> if Buffer.length l.obuf < 64 * 1024 * 1024 then Buffer.add_string l.obuf data; ans_ok
  | _ -> ans_flag false

(* One select: new connections, what peers' connections sent and their
   ends, dialed links connected or written to, waiting [ms] at most; a
   process's output wakes it too (the host's events read it). A failed
   select (a descriptor past FD_SETSIZE, EBADF) waits a moment and goes
   round again rather than ending the node. *)
let net_mailbox n ms =
  let reads = Option.to_list n.listener @ List.filter_map (fun l -> if l.dialed then None else Some l.lfd) n.links @ proc_fds () in
  let writes = List.filter_map (fun l -> if l.dialed && (l.connecting || Buffer.length l.obuf > 0) then Some l.lfd else None) n.links in
  let r, w, _ = try Unix.select reads writes [] (float_of_string ms /. 1000.) with
    | Unix.Unix_error (EINTR, _, _) -> ([], [], [])
    | Unix.Unix_error (e, _, _) -> say "select failed (%s): %d connections" (Unix.error_message e) (List.length n.links); Unix.sleepf 0.2; ([], [], []) in
  let evs = ref [] in
  let add e = evs := e :: !evs in
  let close l = net_drop n l; add [ "closed"; l.lid ] in
  (match n.listener with
   | Some lfd when List.mem lfd r ->
       (match Unix.accept ~cloexec:true lfd with
        | exception Unix.Unix_error _ -> ()   (* out of descriptors, or the peer gave up *)
        | c, addr ->
            Unix.set_nonblock c;
            let host = match addr with Unix.ADDR_INET (a, _) -> Unix.string_of_inet_addr a | _ -> "" in
            add [ "opened"; net_add n c ~dialed:false ~connecting:false; host ])
   | _ -> ());
  let buf = Bytes.create 65536 in
  List.iter (fun l ->
      if l.dialed then begin
        if List.mem l.lfd w then
          if l.connecting then (l.connecting <- false; if Unix.getsockopt_error l.lfd <> None then close l)
          else
            let s = Buffer.contents l.obuf in
            match Unix.write_substring l.lfd s 0 (String.length s) with
            | k -> Buffer.clear l.obuf; Buffer.add_string l.obuf (String.sub s k (String.length s - k))
            | exception Unix.Unix_error ((EAGAIN | EWOULDBLOCK), _, _) -> ()
            | exception _ -> close l
      end
      else if List.mem l.lfd r then
        match Unix.read l.lfd buf 0 65536 with
        | 0 -> close l
        | k -> add [ "bytes"; l.lid; Bytes.sub_string buf 0 k ]
        | exception Unix.Unix_error ((EAGAIN | EWOULDBLOCK), _, _) -> ()
        | exception _ -> close l)
    n.links;
  List.rev !evs

(* lists of lists on one wire (nodeio.soma's nio_frame_lists / nio_lists),
   and a wire's environment entries, then the arguments as they are *)
let frame_lists ls = List.concat_map (fun l -> List.concat_map (fun v -> [ "field"; v ]) l @ [ "alternate" ]) ls
let unframe_lists parts =
  let rec go cur acc = function
    | "field" :: v :: rest -> go (v :: cur) acc rest
    | "alternate" :: rest -> go [] (List.rev cur :: acc) rest
    | [] -> List.rev acc
    | _ -> fail "malformed list frame"
  in
  go [] [] parts
let fields_then_args parts =
  let rec go acc = function
    | "field" :: v :: rest -> go (v :: acc) rest
    | "alternate" :: args -> Some (List.rev acc, args)
    | _ -> None in
  go [] parts

(* ---------- the node's service ----------
   Its socket (node.soma's service_tick_prog decides): whole requests from
   its clients, a frame of frames each (Sandbox's frame: four bytes of
   length, then the bytes), and answers framed the same way. *)

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
let serve_listen host port =
  match listen_on host port 8 with Ok fd -> serve_listener := Some fd; true | Error _ -> false
let serve_drop c = close_all [ c.sfd ]; serve_clients := List.filter (fun x -> x.sid <> c.sid) !serve_clients
(* a whole request a client sent, taken out of its buffer *)
let serve_take () =
  List.find_map (fun c ->
      let s = Buffer.contents c.sbuf in
      if String.length s < 4 || String.length s < 4 + frame_length s 0 then None
      else begin
        let n = frame_length s 0 in
        Buffer.clear c.sbuf; Buffer.add_string c.sbuf (String.sub s (4 + n) (String.length s - 4 - n));
        Some (c.sid :: unframes (String.sub s 4 n))
      end)
    !serve_clients
let serve_next wait =
  match serve_take () with
  | Some r -> Some r
  | None ->
      let fds = Option.to_list !serve_listener @ List.map (fun c -> c.sfd) !serve_clients in
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

(* ---------- node_io ---------- *)

(* test programs print their checks with these *)
let print_lines xs = List.iter print_endline xs
let print_text s = print_string s
let argv () = Array.to_list Sys.argv |> List.tl
let rec forever f s = forever f (f s)

(* A node's handle names its primitives' state (the network's, from its
   home): node_open builds it, the net_* and file_* operations reach it. *)
let nets : (string, net) Hashtbl.t = Hashtbl.create 4
let net_counter = ref 0

let node_io_net n op =
  let file name = Filename.concat n.home name in
  match op with
  | [ "net_listen"; host; port ] -> net_listen n host port
  | [ "net_mailbox"; ms ] -> ans_data (frame_lists (net_mailbox n ms))
  | [ "net_connect"; host; port; _ ] -> net_connect n host port
  | [ "net_send"; conn; data ] -> net_send n conn data
  | [ "net_close"; conn ] -> Option.iter (net_drop n) (net_find n conn); ans_ok
  | [ "file_read"; name ] -> ans_found (read_text (file name))
  | [ "file_write"; name; durable; text ] -> write_file ~sync:(durable = "true") (file name) text; ans_ok
  | [ "file_append"; name; text ] -> append_synced (file name) text; ans_ok
  | _ -> fail "unknown node operation %s" (String.concat " " op)

(* One operation in its wire form (this match is nodeio.soma's io_of_wire
   for the shell's); those after the host's need a node's handle. *)
let node_io id op =
  let run_out (ok, out) = (ok, (0., [ out ])) in
  match op with
  (* the clock, the log, the commands' I/O (cli.soma) *)
  | [ "clock" ] -> (true, (Unix.gettimeofday (), []))
  | [ ("log" | "say"); text ] -> say "%s" text; ans_ok
  | [ "local_time"; stamp ] ->
      let tm = Unix.localtime (float_of_string stamp) in
      ans_data [ Printf.sprintf "%02d:%02d" tm.Unix.tm_hour tm.Unix.tm_min ]
  | [ "fail"; message ] -> fail "%s" message
  | [ "print"; text ] -> print_string text; flush stdout; ans_ok
  | [ "exit"; code ] -> exit (int_of_string code)
  | [ "cwd" ] -> ans_data [ Sys.getcwd () ]
  | [ "file_exists"; path ] -> ans_flag (Sys.file_exists path)
  | [ "write_file"; path; text ] -> write_file path text; ans_ok
  | [ "chmod"; path; mode ] -> ans_flag (try Unix.chmod path (int_of_string ("0o" ^ mode)); true with _ -> false)
  | [ "make_dirs"; path ] -> mkdir_p path; ans_ok
  | [ "new_key"; bits ] -> ans_data (new_key (int_of_string bits))
  | [ "random_hex"; count ] -> ans_data [ random_hex (int_of_string count) ]
  | [ "clone"; url; dir; commit ] -> ans_flag (clone url dir commit)
  | "spawn_node" :: log :: args ->
      let fd = Unix.openfile log [ O_WRONLY; O_CREAT; O_APPEND ] 0o644 in
      let pid = Unix.create_process self_exe (Array.of_list (self_exe :: args)) Unix.stdin fd fd in
      Unix.close fd;
      ans_data [ string_of_int pid ]
  | "await_nodes" :: pids ->
      let pids = List.map int_of_string pids in
      let stop _ = List.iter (fun p -> try Unix.kill p Sys.sigterm with _ -> ()) pids; exit 0 in
      Sys.set_signal Sys.sigint (Sys.Signal_handle stop);
      Sys.set_signal Sys.sigterm (Sys.Signal_handle stop);
      List.iter (fun p -> ignore (Unix.waitpid [] p)) pids;
      ans_ok
  (* the service's socket *)
  | [ "serve_listen"; host; port ] -> ans_flag (serve_listen host port)
  | [ "serve_next"; wait ] -> (match serve_next (float_of_string wait) with Some r -> ans_data r | None -> ans_flag false)
  | "serve_reply" :: sid :: fields -> serve_reply sid fields; ans_ok
  (* the host's (nodeio.soma's service_op) *)
  | "git" :: dir :: args -> run_out (git dir args)
  | "git_env" :: dir :: stdin :: rest ->
      (match fields_then_args rest with
       | Some (extra, args) -> run_out (git ~extra ?stdin:(if stdin = "" then None else Some stdin) dir args)
       | None -> (false, (0., [ "git_env came malformed" ])))
  | [ "path_stat"; path ] -> ans_data (path_stat path)
  | [ "path_probe"; dir; path ] -> ans_data [ path_probe dir path ]
  | [ "path_write"; dir; path; text ] -> ans_data [ path_write dir path text ]
  | [ "path_remove"; dir; path ] -> ans_data [ path_remove dir path ]
  | [ "temp_dir"; prefix ] -> ans_data [ Filename.temp_dir prefix "" ]
  | [ "temp_file"; prefix; suffix; text ] -> ans_data [ temp_file prefix suffix text ]
  | [ "remove_tree"; path ] -> remove_tree_later path; ans_ok
  | [ "read_text"; path ] -> ans_found (read_text path)
  | [ "discard_file"; path ] -> (try Sys.remove path with _ -> ()); ans_ok
  | [ "dir_entries"; path ] -> ans_data (if Sys.file_exists path then Array.to_list (Sys.readdir path) else [])
  | [ "self_exe" ] -> ans_data [ self_exe ]
  | [ "env_entries" ] -> ans_data (Array.to_list (Unix.environment ()))
  | [ "token" ] -> ans_data [ random_hex 8 ]
  | "run" :: prog :: args -> run_out (capture prog args)
  | "proc_start" :: prog :: stdin :: cwd :: rest ->
      (match fields_then_args rest with
       | Some (env, args) -> proc_start prog stdin cwd env args
       | None -> (false, (0., [ "proc_start came malformed" ])))
  | [ "proc_kill"; jid ] -> proc_kill jid; ans_ok
  | [ "events"; _ ] -> ans_data (frame_lists (proc_events ()))
  | _ -> node_io_net (try Hashtbl.find nets id with Not_found -> fail "unknown node handle %s" id) op

(* A node's handle, from what cli.soma's node_setup read, checked and
   decided (framed; node_kernel.soma's kernel_world reads the rest): the
   shell needs only the home, where the node's named files are. *)
let node_open config =
  Sys.set_signal Sys.sigpipe Sys.Signal_ignore;
  let home = match unframe_lists config with (home :: _) :: _ -> home | _ -> fail "the node's setup came back malformed" in
  let id = string_of_int !net_counter in
  incr net_counter;
  Hashtbl.replace nets id { home; listener = None; links = []; counter = 0 };
  id
