#!/bin/bash
# Focused disk restart regression using the actual extracted node and shell.
set -eu
cd "$(dirname "$0")/.."
soma build main.soma
cache=${XDG_CACHE_HOME:-$HOME/.cache}/soma/ocaml/build
build=
for d in "$cache"/main-*; do
  if [ -f "$d/shell.ml" ] && cmp -s shell.ml <(tail -n +2 "$d/shell.ml" 2>/dev/null) && grep -q 'let restore_cons' "$d/prog.ml"; then build=$d; fi
done
[ -n "$build" ] || { echo 'cannot find extracted main build'; exit 1; }
t=$(mktemp -d)
trap 'rm -rf "$t"' EXIT
cp "$build"/*.ml "$build/dune" "$build/dune-project" "$t/"
cat > "$t/soma_main.ml" <<'ML'
open Prog
let () =
  let path = Sys.argv.(1) in
  let c = { (new_consensus "a" ["a";"b";"c";"d"] 1) with
    round = 2; step = 2; lockr = 3; lockv = ["A"];
    validr = 3; validv = ["A"] } in
  let n = { empty_node with cons = c } in
  Shell.write_file ~sync:true path (snapshot_text n.cons);
  let load p = match snapshot_of (In_channel.with_open_bin p In_channel.input_all) with Some c -> c | None -> failwith "malformed" in
  let restarted = restore_cons empty_node (load path) in
  let restarted, _ = step0 restarted ["start"] in
  let c = restarted.cons in
  assert (c.lockr = 3 && c.lockv = ["A"]);
  assert (c.validr = 3 && c.validv = ["A"] && c.round = 2 && c.step = 2);
  let c = { c with round = 3; step = 0 } in
  let p = { kd = Proposal; frm = proposer c c.height c.round;
    mh = c.height; mr = c.round; vr = 0;
    vid = Shell.hash_list ["B"]; value = ["B"] } in
  let c = { c with log = [p] } in
  (match r_fresh c (fun _ -> true) with
   | Some (_, outs) ->
       assert (List.exists (function
         | "broadcast" :: "prevote" :: _h :: _r :: _vr :: id :: _ -> id = ""
         | _ -> false) outs)
   | None -> assert false);
  let oc = open_out_bin path in output_string oc "broken"; close_out oc;
  assert (try ignore (load path); false with _ -> true);
  print_endline "ok restart: lock and valid value survive disk load; conflicting proposal prevotes nil"
ML
# soma build finds its own switch; dune needs telling
[ -n "${SOMA_OCAML_SWITCH:-}" ] || { [ -d "$cache/../_opam" ] && SOMA_OCAML_SWITCH=$(cd "$cache/.." && pwd); }
if [ -n "${SOMA_OCAML_SWITCH:-}" ]; then
  export PATH="$SOMA_OCAML_SWITCH/_opam/bin:$PATH"
  export OCAMLPATH="$SOMA_OCAML_SWITCH/_opam/lib${OCAMLPATH:+:$OCAMLPATH}"
fi
(cd "$t" && dune build soma_main.exe && _build/default/soma_main.exe "$t/consensus.state")
