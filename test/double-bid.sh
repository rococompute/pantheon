#!/bin/bash
# D-5: an agent never puts more than one bid on a task.
#
# Drives the Soma agent through the two failure paths and the retry:
# a bid duty reissued while a bid is in flight, a late patch reply for a
# task that already has a pending bid (on the chain or in flight), and a
# refused or expired in-flight bid that frees the agent to bid again.
#
#   test/double-bid.sh
#
# Needs soma.
set -u
cd "$(dirname "$0")/.."
T=$(mktemp -d "${TMPDIR:-/tmp}/pantheon-double-bid.XXXXXX")
trap 'rm -rf "$T"' EXIT
fails=0
fail() { echo "FAIL $*"; fails=$((fails + 1)); }
ok() { echo "ok $*"; }

if ! soma run test/double_bid.soma > "$T/out" 2> "$T/err"; then
  fail "double-bid program failed: $(cat "$T/err" "$T/out")"
else
  cat "$T/out"
  if grep -q '^FAIL' "$T/out"; then
    fail "a double-bid assertion failed"
  else
    for need in \
      "duty asks when nothing is waiting" \
      "duty reissued while a bid is in flight asks nothing" \
      "late reply dropped for a task with a pending bid" \
      "late reply dropped while a bid is in flight" \
      "an answered late reply is not enqueued" \
      "one bid per agent on the task" \
      "one bid from each agent on the task" \
      "a duty reissued while that bid is in flight sends nothing" \
      "a refused bid frees the agent to bid again" \
      "an expired in flight bid can be sent again" \
      "after the bid is refused the agent sends one more"
    do
      grep -q "^ok $need$" "$T/out" || fail "missing: $need"
    done
    ok "double-bid assertions"
  fi
fi

[ "$fails" -eq 0 ] && echo PASS || { echo "$fails failed"; exit 1; }
