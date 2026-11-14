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

(* ---------- the commands ----------
   init, keygen, genesis, up, status, tx, plan, edits, apply-edits and check
   are cli.soma's node programs; their I/O is node_io's path-only arms.
   cli_open hands the edits machinery Soma's helpers, as node_open does. *)
let cli_helpers_ref : helpers option ref = ref None
let cli_helpers () = match !cli_helpers_ref with Some h -> h | None -> fail "the edits operations need cli_open first"
let cli_open packed = cli_helpers_ref := Some (unpack_helpers packed); "cli"

(* the draw's hash chain is this long (cli.soma's chain_len makes the tip) *)
let chain_len = 100_000

let repo_dir home name = Filename.concat (Filename.concat home "repos") name

(* ---------- the node ----------
   The node's kernel is Soma (node_kernel.soma): its tables, peer links,
   signatures, files and select are kept and decided there, the same for
   the binary and the unikernel. The shell carries out the kernel's
   primitives on the host (net_* and file_*: Sandbox's, on sockets and
   files) and the host's work, which a unikernel asks its service for:
   jobs (model calls, checks, CI), git in the checkouts, the model's limit
   and the inbox (nodeio.soma's service_op). *)

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
                     h_llm_budget : unit -> string * string;
                     h_llm_hold : string -> string -> string -> string list -> unit;
                     h_llm_start : string -> string -> string -> string -> string list -> string list -> string list -> string list -> string list option;
                     h_tool_checkout : string -> (string * string) * bool;
                     h_limit_set : float -> string -> float -> unit;
                     h_limit_clear : float -> unit;
                     h_repo_names : unit -> string list;
                     h_ls_files : string -> string;
                     h_head_file : string -> string -> string option;
                     h_inbox_state : unit -> float * string;
                     h_inbox_stamp : float -> unit;
                     h_jobs : unit -> (string * (float * (float * bool))) list;
                     h_job_expire : string -> unit;
                     h_checkout_heads : unit -> (string * string) list;
                     h_limit_info : unit -> float * (string * (string * string));
                     h_release_state : unit -> float * bool;
                     h_held_requests : unit -> (((string * string) * string) * string list) list;
                     h_held_store : (((string * string) * string) * string list) list -> bool -> unit;
                     h_run_check : string -> string -> string -> string list -> unit;
                     h_merge_reset : string -> unit;
                     h_merge_probe : string -> string -> string;
                     h_merge_read : string -> string -> string option;
                     h_merge_write : string -> string -> string -> string;
                     h_merge_remove : string -> string -> string;
                     h_merge_commit : string -> string -> string -> string -> string -> string -> string -> (string * string) option }
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
  | [ "checkout_heads" ] -> (true, (0., List.concat_map (fun (r, v) -> [ r; v ]) (h.h_checkout_heads ())))
  | [ "limit_info" ] ->
      let until, (backend, (held, reason)) = h.h_limit_info () in (true, (until, [ backend; held; reason ]))
  | [ "llm_budget" ] -> let calls, max = h.h_llm_budget () in (true, (0., [ calls; max ]))
  | "llm_hold" :: req :: kind :: prompt :: ctx -> h.h_llm_hold req kind prompt ctx; (true, (0., []))
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
  | [ "tool_checkout"; r ] ->
      let (wt, gd), ok = h.h_tool_checkout r in (true, (0., [ wt; gd; string_of_bool ok ]))
  | [ "repo_names" ] -> (true, (0., h.h_repo_names ()))
  | [ "ls_files"; r ] -> (true, (0., [ h.h_ls_files r ]))
  | [ "head_file"; r; p ] ->
      (match h.h_head_file r p with Some c -> (true, (0., [ c ])) | None -> (false, (0., [])))
  | [ "merge_reset"; r ] -> h.h_merge_reset r; (true, (0., []))
  | [ "merge_probe"; r; p ] -> (true, (0., [ h.h_merge_probe r p ]))
  | [ "merge_read"; r; p ] ->
      (match h.h_merge_read r p with Some c -> (true, (0., [ c ])) | None -> (false, (0., [])))
  | [ "merge_write"; r; p; text ] -> (true, (0., [ h.h_merge_write r p text ]))
  | [ "merge_remove"; r; p ] -> (true, (0., [ h.h_merge_remove r p ]))
  | [ "merge_commit"; r; v; tree; bid; task; bidder; spec ] ->
      (match h.h_merge_commit r v tree bid task bidder spec with
       | Some (got, short) -> (true, (0., [ got; short ]))
       | None -> (false, (0., [])))
  | [ "limit_set"; until; reason; backoff ] ->
      h.h_limit_set (float_of_string until) reason (float_of_string backoff); (true, (0., []))
  | [ "limit_clear"; backoff ] -> h.h_limit_clear (float_of_string backoff); (true, (0., []))
  | [ "release_state" ] -> let backoff, probing = h.h_release_state () in (true, (backoff, [ string_of_bool probing ]))
  | [ "held_requests" ] ->
      (true, (0., frame_lists (List.map (fun (((id, kind), prompt), ctx) -> id :: kind :: prompt :: ctx) (h.h_held_requests ()))))
  | "held_store" :: probing :: parts ->
      let requests = List.filter_map (function
        | id :: kind :: prompt :: ctx -> Some (((id, kind), prompt), ctx) | _ -> None) (unframe_lists parts) in
      h.h_held_store requests (probing = "true"); (true, (0., []))
  | [ "job_complete"; job; result ] -> (true, (0., frame_lists (h.h_job_complete job result)))
  | [ "ci_launch"; req; out; tree; ci ] -> (true, (0., frame_lists (h.h_ci_launch req out tree ci)))
  | [ "inbox_state" ] -> let last, dir = h.h_inbox_state () in (true, (last, [ dir ]))
  | [ "inbox_stamp"; stamp ] -> h.h_inbox_stamp (float_of_string stamp); (true, (0., []))
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
  | [ "checkout_edits"; dir ] ->
      (match edits_of_checkout (cli_helpers ()) dir with
       | Error e -> (false, (0., [ e ]))
       | Ok (es, skipped) -> (true, (0., frame_lists (skipped :: List.map (fun (p, o, n) -> [ p; o; n ]) es))))
  | "apply_edits" :: dir :: edits ->
      (match apply_edits (cli_helpers ()) dir (triples_of edits) with Ok () -> (true, (0., [])) | Error e -> (false, (0., [ e ])))
  | "check_tree" :: repo :: head :: out :: edits ->
      (match check_tree (cli_helpers ()) repo head (triples_of edits) out with
       | Ok t -> (true, (0., [ t ]))
       | Error (`Bid, e) -> (false, (0., [ "bid"; e ]))
       | Error (`Node, e) -> (false, (0., [ "node"; e ])))
  | _ -> node_io_handle (lookup_handle id) op
let rec forever f s = forever f (f s)

(* The host's runtime and the primitives' state, from what cli.soma's
   node_setup read, checked and decided: the settings, this node's key,
   its excluded repositories, those it can't check, CI commands by
   repository, the agents, the repositories, those still at genesis, then
   the boot events (the kernel's: node_kernel.soma's kernel_world). *)
let node_open packed config =
  let helpers = unpack_helpers packed in
  Sys.set_signal Sys.sigpipe Sys.Signal_ignore;
  let settings, ci_repo_l, repos_l =
    match unframe_lists config with
    | s :: _ :: _ :: _ :: cr :: _ :: rp :: _ -> (s, cr, rp)
    | _ -> fail "the node's setup came back malformed" in
  let home, backend_s, ci_s, ci_memory_s, ci_image_s, ci_sandbox_s, max_calls_s =
    match settings with
    | [ home; _; _; _; _; b; _; ci; mem; img; sbx; mc ] -> (home, b, ci, mem, img, sbx, mc)
    | _ -> fail "the node's setup came back malformed" in
  let rec pairs = function a :: b :: r -> (a, b) :: pairs r | _ -> [] in
  let backend = ref backend_s and ci_cmd = ref ci_s and ci_repo = ref (pairs ci_repo_l) and ci_image = ref ci_image_s
  and ci_sandbox = ref ci_sandbox_s and ci_memory = ref ci_memory_s in
  let max_calls = ref (int_of_string max_calls_s) and calls = ref 0 in
  (* the host's events: its jobs' output and ends, and their callbacks' *)
  let queue = Queue.create () in
  let push ev = Queue.add ev queue in
  let drain () = let evs = ref [] in while not (Queue.is_empty queue) do evs := Queue.pop queue :: !evs done; List.rev !evs in
  let jobs : job list ref = ref [] in
  let job_counter = ref 0 in
  let finished_jobs : (string, job) Hashtbl.t = Hashtbl.create 8 in
  (* the governed repositories, checked out and checked by node_setup *)
  let repos = List.map fst (pairs repos_l) in
  let rdir n = repo_dir home n in
  let ci_for r = try List.assoc r !ci_repo with Not_found -> !ci_cmd in
  let last_inbox = ref 0. in
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
  let hold id kind prompt0 ctx = held := (((id, kind), prompt0), ctx) :: !held in
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
      h_repo_names = (fun () -> repos);
      h_ls_files = (fun r -> git_out (rdir r) [ "ls-files" ]);
      h_head_file = (fun r p -> let ok, c = git (rdir r) [ "show"; "HEAD:" ^ p ] in if ok then Some c else None);
      h_inbox_state = (fun () -> (!last_inbox, Filename.concat home "inbox"));
      h_inbox_stamp = (fun now -> last_inbox := now);
      h_jobs = (fun () -> List.map (fun j -> (j.jid, (j.jstarted, (j.jlimit, Hashtbl.mem overtime j.jpid)))) !jobs);
      h_job_expire = expire_job;
      h_checkout_heads = (fun () -> List.map (fun n -> (n, git_out (rdir n) [ "rev-parse"; "--short"; "HEAD" ])) repos);
      h_limit_info = (fun () -> (!limited_until, (!backend, (string_of_int (List.length !held), !limit_reason))));
      (* Storage only: Soma chooses the queue, flag and oldest-first events. *)
      h_release_state = (fun () -> (!limit_backoff, !probing));
      h_held_requests = (fun () -> !held);
      h_held_store = (fun requests probe -> held := requests; probing := probe);
      h_run_check = run_check;
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
      h_merge_commit = merge_commit };
  handle_id
