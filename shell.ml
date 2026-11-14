(* The shell: the host's side of a Pantheon node and of the commands. Soma
   decides everything (node.soma, node_kernel.soma, node_host.soma,
   cli.soma); this carries out primitives, one operation at a time in
   node_io's wire form (nodeio.soma's io_wire), and decides nothing:

   - the binary runner's (node_net.soma): sockets by name and the node's
     files written whole or appended, with the clock and the log;
   - the host's (nodeio.soma's service_op: what a unikernel asks its
     service for): git, paths, temporary files, programs and processes;
   - the commands' I/O.

   The node's tables, peer links, timers and signatures are the kernel's,
   and so are its jobs, a merge's git and the model's limit, and the
   network's links, buffers and frames are node_net.soma's
   (docs/SHELL-IN-SOMA.md, "One kernel, two runners", "The host's work"
   and "The binary's network"). Every answer is nodeio.soma's nanswer: (carried out, or the
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

let read_text p = try Some (In_channel.with_open_bin p In_channel.input_all) with _ -> None

(* whole, through a temporary file renamed into place, keeping the file's
   mode; [sync]: on disk, file and directory, before the rename is relied on
   (consensus.state's text, node.soma's snapshot_text, before any vote it
   holds is sent) *)
let write_file ?(sync = false) p s =
  let tmp = p ^ ".pantheon-tmp" in
  let mode = try Some (Unix.stat p).st_perm with _ -> None in
  Out_channel.with_open_bin tmp (fun oc ->
      output_string oc s;
      if sync then (flush oc; Unix.fsync (Unix.descr_of_out_channel oc)));
  Option.iter (Unix.chmod tmp) mode;
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

(* "" when it worked, else what went wrong *)
let attempt f = try f (); "" with e -> Printexc.to_string e

let path_write dir p text =
  let f = Filename.concat dir p in
  attempt (fun () -> mkdir_p (Filename.dirname f); write_file f text)

let path_remove dir p = attempt (fun () -> Sys.remove (Filename.concat dir p))

(* ---------- programs and git ---------- *)

(* a program's standard input: [text] in a temporary file, opened and then
   removed (so no pipe can fill up while its output is read) *)
let stdin_fd text =
  let f = temp_file "pantheon-in" ".txt" text in
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

(* lists of lists on one wire (nodeio.soma's nio_frame_lists), and a
   wire's fields, then the rest as it is (nodeio.soma's resend_parts) *)
let frame_lists ls = List.concat_map (fun l -> List.concat_map (fun v -> [ "field"; v ]) l @ [ "alternate" ]) ls
let fields_then_args parts =
  let rec go acc = function
    | "field" :: v :: rest -> go (v :: acc) rest
    | "alternate" :: args -> Some (List.rev acc, args)
    | _ -> None in
  go [] parts

(* ---------- sockets ----------
   The host's sockets, by name (node_net.soma keeps the node's listener,
   links and buffers, and the service's clients, and decides what each
   select's answer becomes): listen, dial without waiting, one select,
   accept, read, write, a dial's outcome, close. *)

let resolve host port =
  match Unix.getaddrinfo host port [ Unix.AI_FAMILY Unix.PF_INET; Unix.AI_SOCKTYPE Unix.SOCK_STREAM ] with
  | a :: _ -> Some a.Unix.ai_addr
  | [] | (exception _) -> None

let socks : (string, Unix.file_descr) Hashtbl.t = Hashtbl.create 64
let sock_counter = ref 0
let sock_add fd = incr sock_counter; let id = string_of_int !sock_counter in Hashtbl.replace socks id fd; id
let sock_find id = Hashtbl.find_opt socks id

(* a listening socket on HOST:PORT: [its name], or not found and why *)
let sock_listen host port backlog =
  match resolve host port with
  | None -> (false, (0., [ "can't resolve " ^ host ]))
  | Some a ->
      let fd = Unix.socket ~cloexec:true PF_INET SOCK_STREAM 0 in
      (try Unix.setsockopt fd SO_REUSEADDR true; Unix.bind fd a; Unix.listen fd backlog; ans_data [ sock_add fd ]
       with e -> close_all [ fd ]; (false, (0., [ Printexc.to_string e ])))

(* a dial that doesn't wait: [its name, "connected" or "connecting"] *)
let sock_dial host port =
  match resolve host port with
  | None -> ans_flag false
  | Some a ->
      let fd = Unix.socket ~cloexec:true PF_INET SOCK_STREAM 0 in
      Unix.set_nonblock fd;
      (match Unix.connect fd a with
       | () -> ans_data [ sock_add fd; "connected" ]
       | exception Unix.Unix_error ((EINPROGRESS | EWOULDBLOCK | EAGAIN), _, _) -> ans_data [ sock_add fd; "connecting" ]
       | exception _ -> close_all [ fd ]; ans_flag false)

(* the named sockets ready to read and to write, within [ms], framed; with
   [procs], a process's output wakes it too. Interrupted: none ready; failed
   (a descriptor past FD_SETSIZE, EBADF): not found, and why *)
let sock_select ms procs reads writes =
  let named ids = List.filter_map (fun id -> Option.map (fun fd -> (id, fd)) (sock_find id)) ids in
  let r = named reads and w = named writes in
  let extra = if procs then proc_fds () else [] in
  match Unix.select (List.map snd r @ extra) (List.map snd w) [] (float_of_string ms /. 1000.) with
  | rr, ww, _ ->
      let ready l got = List.filter_map (fun (id, fd) -> if List.mem fd got then Some id else None) l in
      ans_data (frame_lists [ ready r rr; ready w ww ])
  | exception Unix.Unix_error (EINTR, _, _) -> ans_data (frame_lists [ []; [] ])
  | exception Unix.Unix_error (e, _, _) -> (false, (0., [ Unix.error_message e ]))

(* a connection the listener has: [its name, the peer's address] *)
let sock_accept id nonblock =
  match Option.map (Unix.accept ~cloexec:true) (sock_find id) with
  | Some (c, addr) ->
      if nonblock then Unix.set_nonblock c;
      ans_data [ sock_add c; (match addr with Unix.ADDR_INET (a, _) -> Unix.string_of_inet_addr a | _ -> "") ]
  | None | (exception Unix.Unix_error _) -> ans_flag false   (* out of descriptors, or the peer gave up *)

(* ["bytes", DATA] (64 KiB at most), ["again"] (nothing yet), or ["closed"] *)
let sock_buf = Bytes.create 65536
let sock_read id =
  match sock_find id with
  | None -> ans_data [ "closed" ]
  | Some fd ->
      (match Unix.read fd sock_buf 0 65536 with
       | 0 -> ans_data [ "closed" ]
       | k -> ans_data [ "bytes"; Bytes.sub_string sock_buf 0 k ]
       | exception Unix.Unix_error ((EAGAIN | EWOULDBLOCK), _, _) -> ans_data [ "again" ]
       | exception _ -> ans_data [ "closed" ])

(* ["wrote", COUNT], ["again"] (the socket's buffer is full), or ["failed"] *)
let sock_write id data =
  match sock_find id with
  | None -> ans_data [ "failed" ]
  | Some fd ->
      (match Unix.write_substring fd data 0 (String.length data) with
       | k -> ans_data [ "wrote"; string_of_int k ]
       | exception Unix.Unix_error ((EAGAIN | EWOULDBLOCK), _, _) -> ans_data [ "again" ]
       | exception _ -> ans_data [ "failed" ])

(* found when a dial failed *)
let sock_error id = ans_flag (match sock_find id with Some fd -> Unix.getsockopt_error fd <> None | None -> true)

let sock_close id = Option.iter (fun fd -> close_all [ fd ]; Hashtbl.remove socks id) (sock_find id)

(* ---------- node_io ---------- *)

(* test programs print their checks with this *)
let print_lines xs = List.iter print_endline xs
let argv () = Array.to_list Sys.argv |> List.tl
let rec forever f s = forever f (f s)

(* One operation in its wire form (this match is nodeio.soma's io_of_wire
   for the shell's) *)
let node_io op =
  let run_out (ok, out) = (ok, (0., [ out ])) in
  match op with
  (* the clock, the log, the commands' I/O (cli.soma) *)
  | [ "clock" ] -> (true, (Unix.gettimeofday (), []))
  | [ "log"; text ] -> say "%s" text; ans_ok
  | [ "local_time"; stamp ] ->
      let tm = Unix.localtime (float_of_string stamp) in
      ans_data [ Printf.sprintf "%02d:%02d" tm.Unix.tm_hour tm.Unix.tm_min ]
  | [ "fail"; message ] -> fail "%s" message
  | [ "print"; text ] -> print_string text; flush stdout; ans_ok
  | [ "exit"; code ] -> exit (int_of_string code)
  | [ "cwd" ] -> ans_data [ Sys.getcwd () ]
  | [ "file_exists"; path ] -> ans_flag (Sys.file_exists path)
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
  (* the binary runner's (node_net.soma): sockets and the node's files (a
     file written whole is the commands' too) *)
  | [ "sock_listen"; host; port; backlog ] -> sock_listen host port (int_of_string backlog)
  | [ "sock_dial"; host; port ] -> sock_dial host port
  | "sock_select" :: ms :: procs :: rest ->
      (match fields_then_args rest with
       | Some (reads, writes) -> sock_select ms (procs = "true") reads writes
       | None -> (false, (0., [ "sock_select came malformed" ])))
  | [ "sock_accept"; id; nonblock ] -> sock_accept id (nonblock = "true")
  | [ "sock_read"; id ] -> sock_read id
  | [ "sock_write"; id; data ] -> sock_write id data
  | [ "sock_error"; id ] -> sock_error id
  | [ "sock_close"; id ] -> sock_close id; ans_ok
  | [ "save"; path; durable; text ] -> write_file ~sync:(durable = "true") path text; ans_ok
  | [ "append_synced"; path; text ] -> append_synced path text; ans_ok
  | [ "no_sigpipe" ] -> Sys.set_signal Sys.sigpipe Sys.Signal_ignore; ans_ok
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
  | "run" :: prog :: args -> run_out (capture prog args)
  | "proc_start" :: prog :: stdin :: cwd :: rest ->
      (match fields_then_args rest with
       | Some (env, args) -> proc_start prog stdin cwd env args
       | None -> (false, (0., [ "proc_start came malformed" ])))
  | [ "proc_kill"; jid ] -> proc_kill jid; ans_ok
  | [ "events"; _ ] -> ans_data (frame_lists (proc_events ()))
  | _ -> fail "unknown node operation %s" (String.concat " " op)
