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

run_runtime_case() {
  mode=$1
  runtime_path=$2
  wanted=$3
  printf 'case %s\n' "$mode"
  TMPDIR="$fixture_dir" PATH="$runtime_path" "$fixture_dir/app/_build/default/soma_main.exe" "$mode" > "$out" 2>&1 || { cat "$out"; exit 1; }
  cat "$out"
  ! grep -q '^FAIL ' "$out"
  test "$(grep -c '^ok ' "$out")" -eq "$wanted"
}
# These are valid programs that really start, then exit 1 or receive SIGKILL.
mkdir "$fixture_dir/fail-bin" "$fixture_dir/kill-bin"
printf '#!/bin/sh\nexit 1\n' > "$fixture_dir/fail-bin/rm"
printf '#!/bin/sh\nexec /bin/sleep 2\n' > "$fixture_dir/kill-bin/rm"
chmod 700 "$fixture_dir/fail-bin/rm" "$fixture_dir/kill-bin/rm"
run_runtime_case modern-exit1 "$fixture_dir/fail-bin:$PATH" 12
run_runtime_case modern-kill "$fixture_dir/kill-bin:$PATH" 12
run_runtime_case modern-success "$PATH" 12
run_runtime_case pair-exit1 "$fixture_dir/fail-bin:$PATH" 12
run_runtime_case pair-kill "$fixture_dir/kill-bin:$PATH" 12
run_runtime_case pair-success "$PATH" 12
mkdir "$fixture_dir/partial-bin"
cat > "$fixture_dir/partial-bin/rm" <<'PARTIAL_RM'
#!/bin/sh
if [ -f "$PANTHEON_AUDIT_PARTIAL_STATE" ]; then exec /bin/rm "$@"; fi
: > "$PANTHEON_AUDIT_PARTIAL_STATE"
/bin/rm -rf -- "$4"
exit 1
PARTIAL_RM
chmod 700 "$fixture_dir/partial-bin/rm"
export PANTHEON_AUDIT_PARTIAL_STATE="$fixture_dir/partial-once"
run_runtime_case pair-partial "$fixture_dir/partial-bin:$PATH" 12
run_runtime_case discard "$PATH" 16
"${SOMA:-soma}" run test/audit_service_cleanup_lifetime.soma > "$out" 2>&1 || { cat "$out"; exit 1; }
cat "$out"
! grep -q '^FAIL ' "$out"
test "$(grep -c '^ok ' "$out")" -eq 36

"${SOMA:-soma}" run test/audit_inbox_cleanup.soma > "$out" 2>&1 || { cat "$out"; exit 1; }
cat "$out"
! grep -q '^FAIL ' "$out"
test "$(grep -c '^ok ' "$out")" -eq 9
