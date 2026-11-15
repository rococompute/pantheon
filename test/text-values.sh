#!/bin/sh
# core/util.soma's floats as text (Printf "%.17g", "%.0f", float_of_string) and
# JSON tokens (yojson's), against what the binary's OCaml gave for each
# case in test/text_values.soma.
set -eu
cd "$(dirname "$0")/.."
t=$(mktemp -d "${TMPDIR:-/tmp}/pantheon-text-values.XXXXXX")
trap 'rm -rf "$t"' EXIT HUP INT TERM
if ! timeout 300 soma run test/text_values.soma > "$t/out" 2> "$t/err"; then cat "$t/err" "$t/out"; exit 1; fi
cat "$t/out"
if grep -q '^FAIL' "$t/out"; then exit 1; fi
grep -q '^ok 610 floats, 248 JSON cases$' "$t/out" || { echo 'FAIL the cases did not all run'; exit 1; }
echo 'PASS floats and JSON as the binary read and printed them'
