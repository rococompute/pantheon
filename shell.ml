(* The shell: the host's side of a Pantheon node and of the commands. Soma
   decides everything (node.soma, node_kernel.soma, node_host.soma,
   node_net.soma, node_git.soma, cli.soma); this carries out primitives,
   each a function shell.definition names (host_*, which node_shell.soma's
   host_prim calls for each operation), and decides nothing:

   - the binary runner's (node_net.soma, node_git.soma): descriptors by
     name, the node's files written whole or appended, processes started,
     waited for and killed, the clock and the log;
   - the host's (nodeio.soma's service_op: what a unikernel asks its
     service for): paths, temporary files and the environment;
   - the commands' I/O.

   The node's tables, peer links, timers and signatures are the kernel's,
   and so are its jobs, a merge's git and the model's limit; the network's
   links, buffers and frames, the process table and git's environment and
   flags are the runner's (docs/SHELL-IN-SOMA.md, "One kernel, two
   runners", "The host's work", "The binary's network" and "Git and
   programs"). Every answer is nodeio.soma's nanswer: (carried out, or the
   boolean read, (a number, data)). *)

let fail fmt = Printf.ksprintf (fun s -> prerr_endline ("error: " ^ s); exit 1) fmt
let say fmt = Printf.ksprintf (fun s -> Printf.printf "%s %s\n%!" (string_of_float (Unix.gettimeofday ())) s) fmt

(* nanswer's shapes (nodeio.soma's ans_ok, ans_flag, ans_data) *)
let ans_ok = (true, (0., []))
let ans_flag b = (b, (0., []))
let ans_data l = (true, (0., l))
let ans_found = function Some x -> ans_data [ x ] | None -> ans_flag false
(* not carried out, and why *)
let ans_why why = (false, (0., [ why ]))
let ans_exn e = ans_why (Printexc.to_string e)
(* one call on the host, its data, or its failure as not found with why *)
let attempt f = try ans_data (f ()) with e -> ans_exn e

(* ---------- keys and random bytes ----------
   Hashes and signatures are Soma's (util.soma, nodeio.soma, Soma.Crypto);
   a new key and random bytes come from the system's randomness. *)

let hex s = Cryptokit.transform_string (Cryptokit.Hexa.encode ()) s
let rng = lazy (Cryptokit.Random.device_rng "/dev/urandom")
let random_hex n = hex (Cryptokit.Random.string (Lazy.force rng) n)

let new_key bits =
  let k = Cryptokit.RSA.new_key ~rng:(Lazy.force rng) ~e:65537 bits in
  string_of_int k.size :: List.map hex [ k.n; k.e; k.d; k.p; k.q; k.dp; k.dq; k.qinv ]

(* ---------- the clock, the log, the commands' I/O ---------- *)

let host_clock () = (true, (Unix.gettimeofday (), []))
let host_log text = say "%s" text; ans_ok
let host_local_time stamp =
  let tm = Unix.localtime (float_of_string stamp) in
  ans_data [ Printf.sprintf "%02d:%02d" tm.Unix.tm_hour tm.Unix.tm_min ]
let host_fail message = fail "%s" message
let host_print text = print_string text; flush stdout; ans_ok
let host_exit code = exit (int_of_string code)
let host_cwd () = ans_data [ Sys.getcwd () ]
let host_new_key bits = ans_data (new_key (int_of_string bits))
let host_random_hex count = ans_data [ random_hex (int_of_string count) ]
(* test programs print their checks with this *)
let print_lines xs = List.iter print_endline xs
let argv () = Array.to_list Sys.argv |> List.tl
let rec forever f s = forever f (f s)

(* ---------- files ---------- *)

let host_read_text p = ans_found (try Some (In_channel.with_open_bin p In_channel.input_all) with _ -> None)
let host_file_exists p = ans_flag (Sys.file_exists p)
let host_dir_entries p = ans_data (if Sys.file_exists p then Array.to_list (Sys.readdir p) else [])
let host_chmod p mode = ans_flag (try Unix.chmod p (int_of_string ("0o" ^ mode)); true with _ -> false)

(* appended in one write, then to disk: a block or a signed vote survives a
   crash whole *)
let host_append_synced p s =
  let fd = Unix.openfile p [ Unix.O_WRONLY; Unix.O_APPEND; Unix.O_CREAT ] 0o644 in
  Fun.protect ~finally:(fun () -> Unix.close fd) (fun () ->
      let b = Bytes.of_string s in
      if Unix.write fd b 0 (Bytes.length b) <> Bytes.length b then failwith (p ^ ": short write");
      Unix.fsync fd);
  ans_ok

(* one call on the host's files (node_file.soma writes files whole and
   makes directories with these) *)
let tried f = attempt (fun () -> f (); [])

(* [s] put in [p], created or emptied first; [sync] "true": on disk before
   the answer *)
let host_file_put p s sync =
  tried (fun () ->
      Out_channel.with_open_gen [ Open_wronly; Open_creat; Open_trunc; Open_binary ] 0o666 p (fun oc ->
          output_string oc s;
          if sync = "true" then (flush oc; Unix.fsync (Unix.descr_of_out_channel oc))))

let host_sync_dir d =
  tried (fun () ->
      let fd = Unix.openfile d [ Unix.O_RDONLY ] 0 in
      Fun.protect ~finally:(fun () -> Unix.close fd) (fun () -> Unix.fsync fd))

let host_file_mode p = attempt (fun () -> [ Printf.sprintf "%o" (Unix.stat p).st_perm ])
let host_rename src dst = tried (fun () -> Unix.rename src dst)
let host_make_dir p = tried (fun () -> Unix.mkdir p 0o755)
let host_remove_file p = tried (fun () -> Sys.remove p)
let host_temp_new prefix suffix = attempt (fun () -> [ Filename.temp_file prefix suffix ])
let host_temp_dir prefix = ans_data [ Filename.temp_dir prefix "" ]

(* PROG started on its own and not waited for: forked twice, so its parent
   is the system's and nothing is left to reap; its input, output and
   errors /dev/null (node_file.soma removes a tree in the background with
   this) *)
let host_start_detached prog args =
  match Unix.fork () with
  | 0 ->
      (try
         if Unix.fork () = 0 then begin
           ignore (Unix.setsid ());
           let null = Unix.openfile "/dev/null" [ O_RDWR; O_CLOEXEC ] 0 in
           List.iter (Unix.dup2 null) [ Unix.stdin; Unix.stdout; Unix.stderr ];
           Unix.execvp prog (Array.of_list (prog :: args))
         end
       with _ -> ());
      Unix._exit 0
  | pid ->
      let rec reap () = try ignore (Unix.waitpid [] pid) with Unix.Unix_error (EINTR, _, _) -> reap () in
      reap (); ans_ok
  | exception e -> ans_exn e

(* The node's own binary, as an absolute path, fixed when the program starts
   and before anything changes directory (docs/SECURITY-REVIEW-2.md P-10):
   started as ./main.exe, a check or a model's PANTHEON_BIN run from a
   scratch directory would otherwise miss it. The path it was invoked as when
   that names a file (has a /), else what the system says it is. *)
let self_exe =
  let e = if Array.length Sys.argv > 0 && String.contains Sys.argv.(0) '/' then Sys.argv.(0) else Sys.executable_name in
  if Filename.is_relative e then Filename.concat (Sys.getcwd ()) e else e
let host_self_exe () = ans_data [ self_exe ]
let host_env_entries () = ans_data (Array.to_list (Unix.environment ()))

(* ---------- paths in a checkout ----------
   cli.soma and node_host.soma decide (edits_prog, check_tree_prog, a
   merge's file work, node_path.soma's probe for symlinks on the way):
   this looks at one path, its last part not followed: its kind and
   whether its owner may run it. *)

let host_path_stat f =
  ans_data
    (match Unix.lstat f with
     | st ->
         let kind = match st.st_kind with Unix.S_REG -> "file" | Unix.S_DIR -> "dir" | Unix.S_LNK -> "symlink" | _ -> "other" in
         [ kind; string_of_bool (st.st_perm land 0o100 <> 0) ]
     | exception _ -> [ "none"; "false" ])

(* the host's descriptors by name: sockets, and the pipes processes write
   their output on *)
let socks : (string, Unix.file_descr) Hashtbl.t = Hashtbl.create 64
let sock_counter = ref 0
let sock_add fd = incr sock_counter; let id = string_of_int !sock_counter in Hashtbl.replace socks id fd; id
(* [f] of the descriptor named [id], or [none] when there's no such one *)
let with_sock id none f = match Hashtbl.find_opt socks id with Some fd -> f fd | None -> none
let close_all = List.iter (fun fd -> try Unix.close fd with _ -> ())

(* ---------- processes ----------
   The jobs are node_net.soma's (their names, the kills, what the output
   and ends become): a process here is started with its output on a pipe
   named among the sockets, waited for, killed. *)

(* PROG run from [cwd] ("": where the binary is) with [env], its standard
   input the file [stdin] ("": /dev/null), its output on a pipe and its
   errors discarded: [its pid, its output's pipe], or not found and why
   (node_git.soma's spawn_fed makes and removes the input's file) *)
let host_spawn prog stdin cwd env args =
  match Unix.openfile (if stdin = "" then "/dev/null" else stdin) [ O_RDONLY; O_CLOEXEC ] 0 with
  | exception e -> ans_exn e
  | ifd ->
      let r, w = Unix.pipe ~cloexec:true () in
      let devnull = Unix.openfile "/dev/null" [ O_WRONLY; O_CLOEXEC ] 0 in
      let old = Sys.getcwd () in
      let back () = if cwd <> "" then (try Sys.chdir old with _ -> ()) in
      match if cwd <> "" then Sys.chdir cwd; Unix.create_process_env prog (Array.of_list (prog :: args)) (Array.of_list env) ifd w devnull with
      | exception e -> back (); close_all [ r; w; ifd; devnull ]; ans_exn e
      | pid -> back (); close_all [ w; ifd; devnull ]; ans_data [ string_of_int pid; sock_add r ]

(* a process's end, waited for: [how, value] (exit, signal or stop, the wait
   status's facts), or not found and why *)
let host_wait_pid pid =
  let rec wait pid =
    match snd (Unix.waitpid [] pid) with
    | Unix.WEXITED c -> ans_data [ "exit"; string_of_int c ]
    | Unix.WSIGNALED sg -> ans_data [ "signal"; string_of_int sg ]
    | Unix.WSTOPPED sg -> ans_data [ "stop"; string_of_int sg ]
    | exception Unix.Unix_error (EINTR, _, _) -> wait pid
    | exception e -> ans_exn e in
  wait (int_of_string pid)

let host_kill_pid pid = (try Unix.kill (int_of_string pid) Sys.sigkill with _ -> ()); ans_ok
let host_no_sigpipe () = Sys.set_signal Sys.sigpipe Sys.Signal_ignore; ans_ok

(* PROG started with its output and errors appended to LOG, its input the
   binary's: [its pid] (pantheon up's nodes) *)
let host_start_logged prog log args =
  attempt (fun () ->
      let fd = Unix.openfile log [ O_WRONLY; O_CREAT; O_APPEND; O_CLOEXEC ] 0o644 in
      Fun.protect ~finally:(fun () -> Unix.close fd) (fun () ->
          [ string_of_int (Unix.create_process prog (Array.of_list (prog :: args)) Unix.stdin fd fd) ]))

(* from now on, an interrupt or a terminate terminates [pids] and ends the
   binary with 0 *)
let host_stop_on_signal pids =
  attempt (fun () ->
      let pids = List.map int_of_string pids in
      let stop _ = List.iter (fun p -> try Unix.kill p Sys.sigterm with _ -> ()) pids; exit 0 in
      List.iter (fun sg -> Sys.set_signal sg (Sys.Signal_handle stop)) [ Sys.sigint; Sys.sigterm ];
      [])

(* ---------- sockets ----------
   The host's sockets, by name (node_net.soma keeps the node's listener,
   links and buffers, and the service's clients, and decides what each
   select's answer becomes): listen, dial without waiting, one select,
   accept, read, write, a dial's outcome, close. *)

(* a TCP socket for HOST:PORT and its address, or None when it doesn't
   resolve *)
let inet_socket host port =
  match Unix.getaddrinfo host port [ Unix.AI_FAMILY Unix.PF_INET; Unix.AI_SOCKTYPE Unix.SOCK_STREAM ] with
  | a :: _ -> Some (Unix.socket ~cloexec:true PF_INET SOCK_STREAM 0, a.Unix.ai_addr)
  | [] | (exception _) -> None

(* a listening socket on HOST:PORT: [its name], or not found and why *)
let host_sock_listen host port backlog =
  match inet_socket host port with
  | None -> ans_why ("can't resolve " ^ host)
  | Some (fd, a) ->
      (try Unix.setsockopt fd SO_REUSEADDR true; Unix.bind fd a; Unix.listen fd (int_of_string backlog); ans_data [ sock_add fd ]
       with e -> close_all [ fd ]; ans_exn e)

(* a dial that doesn't wait: [its name, "connected" or "connecting"] *)
let host_sock_dial host port =
  match inet_socket host port with
  | None -> ans_flag false
  | Some (fd, a) ->
      Unix.set_nonblock fd;
      (match Unix.connect fd a with
       | () -> ans_data [ sock_add fd; "connected" ]
       | exception Unix.Unix_error ((EINPROGRESS | EWOULDBLOCK | EAGAIN), _, _) -> ans_data [ sock_add fd; "connecting" ]
       | exception _ -> close_all [ fd ]; ans_flag false)

(* the named descriptors ready to read and to write, within [ms], framed
   (nodeio.soma's nio_frame_lists). Interrupted: none ready; failed (a
   descriptor past FD_SETSIZE, EBADF): not found, and why *)
let host_sock_select ms reads writes =
  let named ids = List.concat_map (fun id -> with_sock id [] (fun fd -> [ (id, fd) ])) ids in
  let r = named reads and w = named writes in
  let framed ls = ans_data (List.concat_map (fun l -> List.concat_map (fun v -> [ "field"; v ]) l @ [ "alternate" ]) ls) in
  match Unix.select (List.map snd r) (List.map snd w) [] (float_of_string ms /. 1000.) with
  | rr, ww, _ ->
      let ready l got = List.filter_map (fun (id, fd) -> if List.mem fd got then Some id else None) l in
      framed [ ready r rr; ready w ww ]
  | exception Unix.Unix_error (EINTR, _, _) -> framed [ []; [] ]
  | exception Unix.Unix_error (e, _, _) -> ans_why (Unix.error_message e)

(* a connection the listener has: [its name, the peer's address] *)
let host_sock_accept id nonblock =
  with_sock id (ans_flag false) (fun fd ->
      match Unix.accept ~cloexec:true fd with
      | c, addr ->
          if nonblock = "true" then Unix.set_nonblock c;
          ans_data [ sock_add c; (match addr with Unix.ADDR_INET (a, _) -> Unix.string_of_inet_addr a | _ -> "") ]
      | exception Unix.Unix_error _ -> ans_flag false (* out of descriptors, or the peer gave up *))

(* ["bytes", DATA] (64 KiB at most), ["again"] (nothing yet), or ["closed"] *)
let sock_buf = Bytes.create 65536
let host_sock_read id =
  with_sock id (ans_data [ "closed" ]) (fun fd ->
      match Unix.read fd sock_buf 0 65536 with
      | 0 -> ans_data [ "closed" ]
      | k -> ans_data [ "bytes"; Bytes.sub_string sock_buf 0 k ]
      | exception Unix.Unix_error ((EAGAIN | EWOULDBLOCK | EINTR), _, _) -> ans_data [ "again" ]
      | exception _ -> ans_data [ "closed" ])

(* ["wrote", COUNT], ["again"] (the socket's buffer is full), or ["failed"] *)
let host_sock_write id data =
  with_sock id (ans_data [ "failed" ]) (fun fd ->
      match Unix.write_substring fd data 0 (String.length data) with
      | k -> ans_data [ "wrote"; string_of_int k ]
      | exception Unix.Unix_error ((EAGAIN | EWOULDBLOCK), _, _) -> ans_data [ "again" ]
      | exception _ -> ans_data [ "failed" ])

(* found when a dial failed *)
let host_sock_error id = ans_flag (with_sock id true (fun fd -> Unix.getsockopt_error fd <> None))

let host_sock_close id = with_sock id () (fun fd -> close_all [ fd ]; Hashtbl.remove socks id); ans_ok
