#!/bin/sh
# Publish what the market merged to GitHub (or any git remote): each governed
# repository's default branch, so the market's work is where everyone looks.
#
#   scripts/mirror.sh HOME [BRANCH] [--every SECONDS]
#
# Each governed repository in HOME/repos goes to the URL it was cloned from,
# by scripts/publish.sh: a fast-forward of the default branch (or BRANCH), or
# a merge commit when people committed there too. Merges are committed the
# same way on every node, so any node can publish and two never conflict.
# Pushing uses this machine's git credentials.
#
# To keep a person between the market and the default branch instead, name a
# side branch (BRANCH pantheon/merged) and protect the default one.
set -u
here=$(cd "$(dirname "$0")" && pwd)
home=${1:?usage: scripts/mirror.sh HOME [BRANCH] [--every SECONDS]}
branch=${2:-}
case $branch in --every) branch=""; every=${3:-60} ;; *) every=""; [ "${3:-}" = "--every" ] && every=${4:-60} ;; esac
push_all() {
  status=0
  for r in "$home"/repos/*/; do
    r=${r%/}
    url=$(git -C "$r" remote get-url origin 2>/dev/null) || { echo "mirror: $(basename "$r") has no origin to publish to" >&2; status=1; continue; }
    PUBLISH_DIR=$home/publish "$here/publish.sh" "$r" "$url" $branch || status=1
  done
  return $status
}
if [ -n "$every" ]; then while true; do push_all; sleep "$every"; done; else push_all; fi
