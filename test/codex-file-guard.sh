#!/bin/sh
# Actual file I/O, including a FIFO with no writer; no running node.
set -eu
cd "$(dirname "$0")/.."
codex_guard_dir=$(mktemp -d "${TMPDIR:-/tmp}/pantheon-codex-guard.XXXXXX")
trap 'rm -rf "$codex_guard_dir"' EXIT HUP INT TERM
export CODEX_GUARD_FIFO="$codex_guard_dir/blocked reply"
export CODEX_GUARD_FILE="$codex_guard_dir/regular reply"
export CODEX_GUARD_EMPTY="$codex_guard_dir/empty reply"
export CODEX_GUARD_MISSING="$codex_guard_dir/missing reply"
mkfifo "$CODEX_GUARD_FIFO"
printf '%s' 'file bytes' > "$CODEX_GUARD_FILE"
: > "$CODEX_GUARD_EMPTY"
if ! timeout 120 soma run test/codex_file_guard.soma > "$codex_guard_dir/out" 2> "$codex_guard_dir/err"; then
  cat "$codex_guard_dir/err" "$codex_guard_dir/out"
  exit 1
fi
cat "$codex_guard_dir/out"
! grep -q '^FAIL ' "$codex_guard_dir/out"
[ "$(grep -c '^ok ' "$codex_guard_dir/out")" -eq 12 ]
[ ! -e "$CODEX_GUARD_FIFO" ]
[ ! -e "$CODEX_GUARD_FILE" ]
[ ! -e "$CODEX_GUARD_EMPTY" ]
[ ! -e "$CODEX_GUARD_MISSING" ]
echo 'PASS Codex reply-file guard and cleanup'
