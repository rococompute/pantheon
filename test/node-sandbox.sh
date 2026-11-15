#!/bin/sh
# The node's I/O interpreted by a unikernel (U-1): runtime/nodeio.soma's pure part
# (the lines blocks.log and signed.log get, Yojson's bytes; the tables the
# operations keep) by soma run, and runtime/node_sandbox.soma's Sandbox interpreter
# running a node program, by soma build --no-image: the MirageOS project
# is generated and type-checked, no image is booted (Soma's CI has no
# solo5; dev/mirage-check.sh in Soma boots images on a Mac).
set -eu
cd "$(dirname "$0")/.."
t=$(mktemp -d "${TMPDIR:-/tmp}/pantheon-node-sandbox.XXXXXX")
trap 'rm -rf "$t"' EXIT HUP INT TERM
if ! soma run test/nio_tables.soma > "$t/out" 2> "$t/err"; then cat "$t/err" "$t/out"; exit 1; fi
cat "$t/out"
if grep -q '^FAIL ' "$t/out"; then exit 1; fi
[ "$(grep -c '^ok ' "$t/out")" -eq 38 ] || { echo "FAIL expected 38 checks"; exit 1; }
if ! soma build --no-image test/node_sandbox_check.soma > "$t/build" 2>&1; then
  cat "$t/build"; echo "FAIL the unikernel interpreter doesn't build"; exit 1
fi
# a build with nothing to do says so: the check it ran last time stands
grep -q 'Mirage: checked .* (no image)\|: unchanged since its last build' "$t/build" || { cat "$t/build"; echo "FAIL no Mirage check"; exit 1; }
echo 'ok a node program run by the Sandbox interpreter type-checks as a MirageOS project'
echo 'PASS the node interface, interpreted by a unikernel'
