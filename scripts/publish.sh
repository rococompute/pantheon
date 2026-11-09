#!/bin/sh
# Publish what the market merged to a governed repository's default branch,
# where people and agents look first, so the market's work is never stranded
# on a side branch.
#
#   scripts/publish.sh REPO REMOTE [BRANCH]
#
# REPO is a node's copy of a governed repository: its HEAD is the market's
# head (every node commits merges the same way, so any node's copy will do).
# REMOTE is where to publish (a GitHub URL, or a path). BRANCH defaults to
# REMOTE's default branch (what HEAD names there).
#
#   - BRANCH already contains the market's head: nothing to do.
#   - BRANCH is behind it: BRANCH fast-forwards to it.
#   - BRANCH has commits the market doesn't (a person committed there during
#     the chain): a merge commit joins the two, and BRANCH moves to it.
#   - The two conflict: the market's head goes to pantheon/unmerged instead,
#     and this exits 2 saying so. Merge that branch by hand; the next
#     publish after that goes on as above.
#
# The merge is made in a bare scratch repository (PUBLISH_DIR, default
# REPO/../../publish), never in REPO: a node's own copy only ever holds what
# the market committed.
set -u
say() { echo "publish: $*"; }
die() { echo "publish: $*" >&2; exit 1; }
[ $# -ge 2 ] || die "usage: scripts/publish.sh REPO REMOTE [BRANCH]"
repo=$(cd "$1" 2>/dev/null && pwd) || die "no repository at $1"
remote=$2 branch=${3:-}
name=$(basename "$repo")
# a relative path (as in a network.json that names ../src/calc) is relative to REPO
case $remote in /*|*:*) ;; *) remote=$(cd "$repo" && cd "$remote" 2>/dev/null && pwd) || die "no repository at $2 (from $repo)" ;; esac
if [ -z "$branch" ]; then
  branch=$(git ls-remote --symref "$remote" HEAD 2>/dev/null | sed -n 's|^ref: refs/heads/\(.*\)	HEAD$|\1|p')
  [ -n "$branch" ] || die "can't tell $remote's default branch (can this machine read it?): name the branch: scripts/publish.sh REPO REMOTE BRANCH"
fi
scratch=${PUBLISH_DIR:-$(cd "$repo/../.." && pwd)/publish}/$name.git
[ -d "$scratch" ] || git init -q --bare "$scratch" || die "can't make $scratch"
g() { git -C "$scratch" "$@"; }
head=$(git -C "$repo" rev-parse HEAD) || die "$repo has no commits"
short=$(git -C "$repo" rev-parse --short HEAD)
g fetch -q "$repo" "+HEAD:refs/market/head" || die "can't read the market's head from $repo"
push() { # COMMIT WHAT
  out=$(g push -q "$remote" "$1:refs/heads/$branch" 2>&1) && return 0
  case $out in
    *"non-fast-forward"*|*"fetch first"*|*rejected*) say "$branch on $remote moved while publishing; the next publish tries again: $out" ;;
    *) say "can't push to $remote: $out. This machine needs a key that can write $branch there (gh auth login with SSH adds this machine's key; or a deploy key with write access)" ;;
  esac
  exit 1
}
if ! out=$(g fetch -q "$remote" "+refs/heads/$branch:refs/remote/default" 2>&1); then
  g ls-remote "$remote" >/dev/null 2>&1 || die "can't read $remote: $out"
  # the branch isn't there yet: start it at the market's head
  push "$head"; say "$name: $branch on $remote starts at the market's head, $short"; exit 0
fi
d=$(g rev-parse refs/remote/default)
if g merge-base --is-ancestor "$head" "$d"; then
  [ -n "${QUIET:-}" ] || say "$name: $branch on $remote already has the market's head, $short"; exit 0
fi
if g merge-base --is-ancestor "$d" "$head"; then
  push "$head"; say "$name: $branch on $remote fast-forwarded to the market's head, $short"; exit 0
fi
# merge-tree exits 1 on a conflict (git 2.38 or later)
if mt=$(g merge-tree --write-tree "$d" "$head" 2>/dev/null); then
  tree=$(printf '%s\n' "$mt" | head -1)
  msg=$(printf "Merge the market's head into %s\n\n%s\n\nPantheon-Head: %s\n" "$branch" "$(g log -1 --format=%s "$head")" "$head")
  c=$(printf '%s\n' "$msg" | g -c user.name="Pantheon mirror" -c user.email="pantheon-mirror@localhost" commit-tree "$tree" -p "$d" -p "$head") || die "can't write the merge commit"
  push "$c"; say "$name: $branch on $remote had commits the market doesn't; merged the market's head, $short, into it"; exit 0
fi
out=$(g push -q --force "$remote" "$head:refs/heads/pantheon/unmerged" 2>&1) || die "the market's head conflicts with $branch on $remote, and pushing it to pantheon/unmerged failed too: $out"
echo "publish: $name: the market's head ($short) conflicts with $branch on $remote, which has commits the market doesn't. It's on pantheon/unmerged: merge that into $branch by hand (git merge origin/pantheon/unmerged), and publishing goes on from there." >&2
exit 2
