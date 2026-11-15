(* The shell: the host's side of a Pantheon node and of the commands. Soma
   decides everything (node.soma, node_kernel.soma, node_host.soma,
   node_net.soma, node_git.soma, cli.soma); this carries out primitives,
   one operation at a time in node_io's wire form (nodeio.soma's io_wire),
   and decides nothing:

   - the binary runner's (node_net.soma, node_git.soma): descriptors by
     name, the node's files written whole or appended, processes started,
     waited for and killed, a program run to its end with the environment
     it is given, the clock and the log;
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

(* appended in one write, then to disk: a block or a signed vote survives a
   crash whole *)
let append_synced p s =
  let fd = Unix.openfile p [ Unix.O_WRONLY; Unix.O_APPEND; Unix.O_CREAT ] 0o644 in
  Fun.protect ~finally:(fun () -> Unix.close fd) (fun () ->
      let b = Bytes.of_string s in
      if Unix.write fd b 0 (Bytes.length b) <> Bytes.length b then failwith (p ^ ": short write");
      Unix.fsync fd)

(* one call on the host's files, its failure as not found with why
   (node_file.soma writes files whole and makes directories with these) *)
let tried f = try f (); ans_ok with e -> (false, (0., [ Printexc.to_string e ]))

(* [s] put in [p], created or emptied first; [sync]: on disk before the
   answer *)
let file_put p s sync =
  tried (fun () ->
      Out_channel.with_open_gen [ Open_wronly; Open_creat; Open_trunc; Open_binary ] 0o666 p (fun oc ->
          output_string oc s;
          if sync then (flush oc; Unix.fsync (Unix.descr_of_out_channel oc))))

let sync_dir d =
  tried (fun () ->
      let fd = Unix.openfile d [ Unix.O_RDONLY ] 0 in
      Fun.protect ~finally:(fun () -> Unix.close fd) (fun () -> Unix.fsync fd))

(* PROG started on its own and not waited for: forked twice, so its parent
   is the system's and nothing is left to reap; its input, output and
   errors /dev/null (node_file.soma removes a tree in the background with
   this) *)
let start_detached prog args =
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
  | exception e -> (false, (0., [ Printexc.to_string e ]))

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
   merge's file work, node_path.soma's probe for symlinks on the way):
   these look at, write and remove one path. *)

(* a path, its last part not followed: its kind and whether its owner may
   run it *)
let path_stat f =
  match Unix.lstat f with
  | st ->
      let kind = match st.st_kind with Unix.S_REG -> "file" | Unix.S_DIR -> "dir" | Unix.S_LNK -> "symlink" | _ -> "other" in
      [ kind; string_of_bool (st.st_perm land 0o100 <> 0) ]
  | exception _ -> [ "none"; "false" ]


(* ---------- programs ---------- *)

(* a program's standard input: /dev/null for "", else [text] in a temporary
   file, opened and then removed (so no pipe can fill up while its output
   is read) *)
let stdin_fd text =
  if text = "" then Unix.openfile "/dev/null" [ O_RDONLY; O_CLOEXEC ] 0
  else begin
    let f = Filename.temp_file "pantheon-in" ".txt" in
    Out_channel.with_open_bin f (fun oc -> output_string oc text);
    let fd = Unix.openfile f [ O_RDONLY; O_CLOEXEC ] 0 in
    (try Sys.remove f with _ -> ());
    fd
  end

let close_all = List.iter (fun fd -> try Unix.close fd with _ -> ())

(* PROG started (from [cwd], if given) with [env] and [stdin], its output on
   a pipe and its errors discarded: its pid and the pipe, or why not *)
let start ?cwd prog stdin env args =
  let ifd = stdin_fd stdin in
  let r, w = Unix.pipe ~cloexec:true () in
  let devnull = Unix.openfile "/dev/null" [ O_WRONLY; O_CLOEXEC ] 0 in
  let old = Sys.getcwd () in
  let back () = if cwd <> None then (try Sys.chdir old with _ -> ()) in
  match Option.iter Sys.chdir cwd; Unix.create_process_env prog (Array.of_list (prog :: args)) env ifd w devnull with
  | exception e -> back (); close_all [ r; w; ifd; devnull ]; Error (Printexc.to_string e)
  | pid -> back (); close_all [ w; ifd; devnull ]; Ok (pid, r)

(* run a program to its end with exactly [env]: whether it succeeded, and
   its output (node_git.soma makes git's and the commands' environments) *)
let capture env stdin prog args =
  match start prog stdin env args with
  | Error e -> (false, e)
  | Ok (pid, r) ->
      let ic = Unix.in_channel_of_descr r in
      let out = In_channel.input_all ic in
      close_in ic;
      let _, st = Unix.waitpid [] pid in
      (st = Unix.WEXITED 0, out)

(* the host's descriptors by name: sockets, and the pipes processes write
   their output on *)
let socks : (string, Unix.file_descr) Hashtbl.t = Hashtbl.create 64
let sock_counter = ref 0
let sock_add fd = incr sock_counter; let id = string_of_int !sock_counter in Hashtbl.replace socks id fd; id
let sock_find id = Hashtbl.find_opt socks id

(* ---------- processes ----------
   The jobs are node_net.soma's (their names, the kills, what the output
   and ends become): a process here is started with its output on a pipe
   named among the sockets, waited for, killed. *)

(* PROG run from [cwd] with [env], [stdin] its standard input from a file:
   [its pid, its output's pipe], or not found and why *)
let spawn prog stdin cwd env args =
  match start ~cwd prog stdin (Array.of_list env) args with
  | Ok (pid, r) -> ans_data [ string_of_int pid; sock_add r ]
  | Error e -> (false, (0., [ e ]))

(* a process's end, waited for: [how, value] (exit, signal or stop, the wait
   status's facts), or not found and why *)
let rec wait_pid pid =
  match snd (Unix.waitpid [] pid) with
  | Unix.WEXITED c -> ans_data [ "exit"; string_of_int c ]
  | Unix.WSIGNALED sg -> ans_data [ "signal"; string_of_int sg ]
  | Unix.WSTOPPED sg -> ans_data [ "stop"; string_of_int sg ]
  | exception Unix.Unix_error (EINTR, _, _) -> wait_pid pid
  | exception e -> (false, (0., [ Printexc.to_string e ]))

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

(* the named descriptors ready to read and to write, within [ms], framed.
   Interrupted: none ready; failed (a descriptor past FD_SETSIZE, EBADF):
   not found, and why *)
let sock_select ms reads writes =
  let named ids = List.filter_map (fun id -> Option.map (fun fd -> (id, fd)) (sock_find id)) ids in
  let r = named reads and w = named writes in
  match Unix.select (List.map snd r) (List.map snd w) [] (float_of_string ms /. 1000.) with
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
       | exception Unix.Unix_error ((EAGAIN | EWOULDBLOCK | EINTR), _, _) -> ans_data [ "again" ]
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
  | [ "new_key"; bits ] -> ans_data (new_key (int_of_string bits))
  | [ "random_hex"; count ] -> ans_data [ random_hex (int_of_string count) ]
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
  (* the binary runner's (node_net.soma, node_git.soma): descriptors, the
     node's files (a file written whole is the commands' too), processes
     and programs run to their end *)
  | [ "sock_listen"; host; port; backlog ] -> sock_listen host port (int_of_string backlog)
  | [ "sock_dial"; host; port ] -> sock_dial host port
  | "sock_select" :: ms :: rest ->
      (match fields_then_args rest with
       | Some (reads, writes) -> sock_select ms reads writes
       | None -> (false, (0., [ "sock_select came malformed" ])))
  | [ "sock_accept"; id; nonblock ] -> sock_accept id (nonblock = "true")
  | [ "sock_read"; id ] -> sock_read id
  | [ "sock_write"; id; data ] -> sock_write id data
  | [ "sock_error"; id ] -> sock_error id
  | [ "sock_close"; id ] -> sock_close id; ans_ok
  | [ "append_synced"; path; text ] -> append_synced path text; ans_ok
  | [ "file_put"; path; text; sync ] -> file_put path text (sync = "true")
  | [ "file_mode"; path ] -> (match Unix.stat path with st -> ans_data [ Printf.sprintf "%o" st.st_perm ] | exception _ -> ans_flag false)
  | [ "rename"; src; dst ] -> tried (fun () -> Unix.rename src dst)
  | [ "sync_dir"; dir ] -> sync_dir dir
  | [ "make_dir"; path ] -> tried (fun () -> Unix.mkdir path 0o755)
  | [ "remove_file"; path ] -> tried (fun () -> Sys.remove path)
  | "start_detached" :: prog :: args -> start_detached prog args
  | [ "temp_new"; prefix; suffix ] -> (match Filename.temp_file prefix suffix with f -> ans_data [ f ] | exception e -> (false, (0., [ Printexc.to_string e ])))
  | [ "no_sigpipe" ] -> Sys.set_signal Sys.sigpipe Sys.Signal_ignore; ans_ok
  | "spawn" :: prog :: stdin :: cwd :: rest ->
      (match fields_then_args rest with
       | Some (env, args) -> spawn prog stdin cwd env args
       | None -> (false, (0., [ "spawn came malformed" ])))
  | [ "wait_pid"; pid ] -> wait_pid (int_of_string pid)
  | [ "kill_pid"; pid ] -> (try Unix.kill (int_of_string pid) Sys.sigkill with _ -> ()); ans_ok
  | "exec" :: prog :: stdin :: rest ->
      (match fields_then_args rest with
       | Some (env, args) -> run_out (capture (Array.of_list env) stdin prog args)
       | None -> (false, (0., [ "exec came malformed" ])))
  (* the host's (nodeio.soma's service_op) *)
  | [ "path_stat"; path ] -> ans_data (path_stat path)
  | [ "temp_dir"; prefix ] -> ans_data [ Filename.temp_dir prefix "" ]
  | [ "read_text"; path ] -> ans_found (read_text path)
  | [ "dir_entries"; path ] -> ans_data (if Sys.file_exists path then Array.to_list (Sys.readdir path) else [])
  | [ "self_exe" ] -> ans_data [ self_exe ]
  | [ "env_entries" ] -> ans_data (Array.to_list (Unix.environment ()))
  | _ -> fail "unknown node operation %s" (String.concat " " op)
