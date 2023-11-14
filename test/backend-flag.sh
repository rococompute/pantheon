#!/bin/sh
set -eu
cd "$(dirname "$0")/.."
out=$(soma run test/backend_flag.soma)
printf '%s\n' "$out"
if printf '%s\n' "$out" | grep -q '^FAIL '; then exit 1; fi
[ "$(printf '%s\n' "$out" | grep -c '^ok ')" -eq 6 ]
