#!/bin/sh
# A model reply's brace offsets, found in Soma, on fixed inputs. No running node.
set -eu
cd "$(dirname "$0")/.."
reply_braces_dir=$(mktemp -d "${TMPDIR:-/tmp}/pantheon-reply-braces.XXXXXX")
trap 'rm -rf "$reply_braces_dir"' EXIT HUP INT TERM
if ! soma run test/reply_braces.soma > "$reply_braces_dir/out" 2> "$reply_braces_dir/err"; then
  cat "$reply_braces_dir/err" "$reply_braces_dir/out"
  exit 1
fi
cat "$reply_braces_dir/out"
if grep -q '^FAIL ' "$reply_braces_dir/out"; then exit 1; fi
[ "$(grep -c '^ok ' "$reply_braces_dir/out")" -eq 13 ]
echo 'PASS Soma reply brace offsets'
