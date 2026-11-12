#!/bin/sh
set -eu
cd "$(dirname "$0")/.."
job_buffer_out=$(soma run test/job_buffer_state.soma)
printf '%s\n' "$job_buffer_out"
! printf '%s\n' "$job_buffer_out" | grep -q '^FAIL '
[ "$(printf '%s\n' "$job_buffer_out" | grep -c '^ok ')" -eq 7 ]
