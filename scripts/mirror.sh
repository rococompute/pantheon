#!/bin/sh
# Push what the market merged to GitHub (or any git remote), on a branch of
# its own, never the default branch: people merge from there by pull request.
#
#   scripts/mirror.sh HOME [BRANCH] [--every SECONDS]
#
# Each governed repository in HOME/repos is pushed to the URL it was cloned
# from, as BRANCH (default pantheon/merged). Merges are committed the same way
# on every node, so any node can push and two nodes pushing never conflict.
# Only fast-forwards: if the branch moved some other way, this says so and
# stops. Pushing uses this machine's git credentials: give it a deploy key that
# can write that branch only, if your host supports that.
set -u
home=${1:?usage: scripts/mirror.sh HOME [BRANCH] [--every SECONDS]}
branch=${2:-pantheon/merged}
case $branch in --every) branch=pantheon/merged; every=${3:-60} ;; *) every=""; [ "${3:-}" = "--every" ] && every=${4:-60} ;; esac
push_all() {
  status=0
  for r in "$home"/repos/*/; do
    r=${r%/}
    name=$(basename "$r")
    out=$(git -C "$r" push --quiet origin "HEAD:refs/heads/$branch" 2>&1) || {
      echo "mirror: pushing $name to $branch failed: $out" >&2; status=1; continue; }
    echo "mirror: $name at $(git -C "$r" rev-parse --short HEAD) pushed to $branch"
  done
  return $status
}
if [ -n "$every" ]; then while true; do push_all; sleep "$every"; done; else push_all; fi
