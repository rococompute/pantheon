#!/bin/sh
# Runs every tests/test_*.sh. CI runs this file, and wrapper policy stops bids from editing it.
set -e
for t in tests/test_*.sh; do
  sh "$t" || { echo "FAILED: $t"; exit 1; }
  echo "ok: $t"
done
