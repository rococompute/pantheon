#!/bin/bash
# scripts/publish.sh: the market's head reaches the remote's default branch, by
# fast-forward, or by a merge when a person committed there too; a conflict
# parks it on pantheon/unmerged and says so. A stand-in for GitHub, no network.
set -u
cd "$(dirname "$0")/.."
T=$(mktemp -d); trap 'rm -rf "$T"' EXIT
fail() { echo "FAIL publish: $*"; exit 1; }
g() { git -c user.name=t -c user.email=t@t "$@"; }
pub() { sh scripts/publish.sh "$@"; }
# the remote, and two nodes' copies of the governed repository (HOME/repos/NAME)
git init -q --bare -b main "$T/remote.git"
g init -q -b main "$T/seed"; printf 'one\n' > "$T/seed/a.txt"; g -C "$T/seed" add -A; g -C "$T/seed" commit -qm genesis
mkdir -p "$T/n1/repos" "$T/n2/repos"
for n in n1 n2; do g clone -q "$T/seed" "$T/$n/repos/calc"; done
merge() { for n in n1 n2; do ( cd "$T/$n/repos/calc" && printf '%s\n' "$2" > "$1" && g add -A && GIT_AUTHOR_DATE="2026-01-01T00:00:00Z" GIT_COMMITTER_DATE="2026-01-01T00:00:00Z" g commit -qm "Merge bid for $1" ); done; }
remote_main() { git -C "$T/remote.git" rev-parse main; }
head1() { git -C "$T/n1/repos/calc" rev-parse HEAD; }

pub "$T/n1/repos/calc" "$T/remote.git" main > "$T/out" || fail "a first publish failed: $(cat "$T/out")"
[ "$(remote_main)" = "$(head1)" ] || fail "main didn't start at the market's head"
merge b.txt two
pub "$T/n1/repos/calc" "$T/remote.git" > "$T/out" || fail "publishing to the default branch failed: $(cat "$T/out")"
grep -q "fast-forwarded" "$T/out" && [ "$(remote_main)" = "$(head1)" ] || fail "main didn't fast-forward: $(cat "$T/out")"
pub "$T/n2/repos/calc" "$T/remote.git" > "$T/out" || fail "a second node's publish failed: $(cat "$T/out")"
grep -q "already has" "$T/out" || fail "a second node's publish wasn't a no-op: $(cat "$T/out")"
[ -d "$T/n1/publish/calc.git" ] || fail "no scratch repository beside the node's repos"
[ -z "$(git -C "$T/n1/repos/calc" status --short)" ] && [ "$(git -C "$T/n1/repos/calc" for-each-ref | wc -l)" -le 3 ] || fail "publish touched the node's own copy"

# a person commits to main during the chain; the market merges on
g clone -q "$T/remote.git" "$T/person"
( cd "$T/person" && printf 'docs\n' > NOTES.md && g add -A && g commit -qm "a person's commit" && git push -q origin main )
merge c.txt three
pub "$T/n1/repos/calc" "$T/remote.git" > "$T/out" || fail "publishing over a person's commit failed: $(cat "$T/out")"
grep -q "merged the market's head" "$T/out" || fail "no merge over a person's commit: $(cat "$T/out")"
m=$(remote_main)
git -C "$T/remote.git" merge-base --is-ancestor "$(head1)" "$m" || fail "main doesn't have the market's head"
git -C "$T/remote.git" cat-file -e "$m:NOTES.md" && git -C "$T/remote.git" cat-file -e "$m:c.txt" || fail "the merge lost one side"
pub "$T/n2/repos/calc" "$T/remote.git" > "$T/out" && grep -q "already has" "$T/out" || fail "publishing the same head twice made another merge"
[ "$(remote_main)" = "$m" ] || fail "main moved without a new merge"

# a person's commit that conflicts with the market's next merge
( cd "$T/person" && git pull -q && printf 'theirs\n' > a.txt && g commit -qam "a conflicting commit" && git push -q origin main )
merge a.txt ours
before=$(remote_main)
pub "$T/n1/repos/calc" "$T/remote.git" > "$T/out" 2>&1; s=$?
[ $s -eq 2 ] || fail "a conflict didn't exit 2 ($s): $(cat "$T/out")"
grep -q "pantheon/unmerged" "$T/out" || fail "a conflict didn't say where the head went: $(cat "$T/out")"
[ "$(remote_main)" = "$before" ] || fail "a conflict moved main"
[ "$(git -C "$T/remote.git" rev-parse pantheon/unmerged)" = "$(head1)" ] || fail "pantheon/unmerged isn't the market's head"

# a remote named by a relative path, as network.json's urls are, through mirror.sh
git init -q --bare -b main "$T/rel.git"; git -C "$T/seed" push -q "$T/rel.git" main
git -C "$T/n2/repos/calc" remote set-url origin ../../../rel.git
sh scripts/mirror.sh "$T/n2" > "$T/out" 2>&1 || fail "mirror.sh with a relative origin failed: $(cat "$T/out")"
[ "$(git -C "$T/rel.git" rev-parse main)" = "$(git -C "$T/n2/repos/calc" rev-parse HEAD)" ] || fail "mirror.sh didn't publish to the relative origin's main"
echo "ok publish: fast-forward, a merge over a person's commit, no double merges, a conflict parked on pantheon/unmerged, relative remotes"
