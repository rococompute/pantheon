#!/bin/sh
set -eu
cd "$(dirname "$0")/.."
out=$(mktemp)
failed=$(mktemp)
fixture_dir=$(mktemp -d)
trap 'rm -f "$out" "$failed"; rm -rf "$fixture_dir"' EXIT HUP INT TERM
"${SOMA:-soma}" run test/audit_service_cleanup.soma > "$out" 2>&1 || { cat "$out"; exit 1; }
cat "$out"
! grep -q '^FAIL ' "$out"
test "$(grep -c '^ok ' "$out")" -eq 39

# Build the actual generated Host ML+C with ordinary tools, then run it
# directly with an empty PATH. No rm exists and no later PATH entry can
# mask exec failure; compiler/tool startup keeps its normal environment.
mkdir "$fixture_dir/empty"
"${SOMA:-soma}" extract test/audit_service_cleanup.soma -o "$fixture_dir/app" > "$fixture_dir/build.log" 2>&1 || { cat "$fixture_dir/build.log"; exit 1; }
test_cache_base=${XDG_CACHE_HOME:-"$HOME/.cache"}
test_switch=${SOMA_OCAML_SWITCH:-"$test_cache_base/soma/ocaml"}
(cd "$fixture_dir/app" && opam exec --switch="$test_switch" -- dune build --profile release --root . soma_main.exe) >> "$fixture_dir/build.log" 2>&1 || { cat "$fixture_dir/build.log"; exit 1; }
TMPDIR="$fixture_dir" PATH="$fixture_dir/empty" "$fixture_dir/app/_build/default/soma_main.exe" missing-rm > "$failed" 2>&1 || { cat "$failed"; exit 1; }
cat "$failed"
! grep -q '^FAIL ' "$failed"
test "$(grep -c '^ok ' "$failed")" -eq 12
