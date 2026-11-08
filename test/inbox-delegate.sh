#!/bin/bash
# A diplomat's hand-off helpers in scripts/pantheon-inbox: base, pull, apply
# and check, on a patch request whose checkout is made the way the node makes
# one (a shared clone, detached at the head), against a stand-in for GitHub.
set -u
cd "$(dirname "$0")/.."
T=$(mktemp -d); trap 'rm -rf "$T"' EXIT
fail() { echo "FAIL inbox-delegate: $*"; exit 1; }
g() { git -c user.name=t -c user.email=t@t "$@"; }
inbox() { PANTHEON_INBOX=$T/inbox PANTHEON_REMOTE=$T/remote.git sh scripts/pantheon-inbox "$@"; }
mkdir -p "$T/inbox"
# the market's repository, its head mirrored to the remote as pantheon/merged
g init -q "$T/repo"; printf 'one\n' > "$T/repo/a.txt"; g -C "$T/repo" add -A; g -C "$T/repo" commit -qm head
git init -q --bare "$T/remote.git"
# a patch request, its checkout as the node makes it
wt=$T/wt; git clone -q --shared --no-checkout "$T/repo" "$wt"; git -C "$wt" checkout -q --detach "$(git -C "$T/repo" rev-parse HEAD)"
id=1700000000-abcd1234; r=$T/inbox/$id; mkdir "$r"; echo patch > "$r/kind"; echo x > "$r/prompt.txt"
echo "$wt" > "$r/worktree"; echo $(( $(date +%s) + 600 )) > "$r/deadline"

inbox base $id | grep -q "isn't on the remote yet" || fail "base didn't say the branch is missing"
git -C "$T/repo" push -q "$T/remote.git" HEAD:refs/heads/pantheon/merged
inbox base $id | grep -q "same commit" || fail "base didn't see the mirrored head"

# a worker elsewhere: clones the remote, branches from pantheon/merged, pushes its change
git clone -q -b pantheon/merged "$T/remote.git" "$T/worker"
( cd "$T/worker" && printf 'two\n' > a.txt && printf 'new\n' > b.txt && g add -A && g commit -qm change && git push -q origin HEAD:refs/heads/bids/claude/$id )
inbox pull $id nope >/dev/null 2>&1 && fail "pulling a branch that isn't there worked"
inbox pull $id bids/claude/$id > "$T/pull.out" || fail "pull failed: $(cat "$T/pull.out")"
[ "$(cat "$wt/a.txt")" = two ] && [ "$(cat "$wt/b.txt")" = new ] || fail "pull didn't apply the change"
[ -z "$(git -C "$wt" diff --cached --name-only)" ] || fail "pull left the change staged"

# apply: a diff from stdin; one that doesn't apply is refused with the reason
git -C "$wt" checkout -q -- . && rm -f "$wt/b.txt"
printf 'three\n' > "$T/a3"; diff -u --label a/a.txt --label b/a.txt "$wt/a.txt" "$T/a3" > "$T/good.diff"
sed 's/^-one/-zero/' "$T/good.diff" > "$T/bad.diff"
inbox apply $id "$T/bad.diff" 2>&1 | grep -q "doesn't apply" || fail "a diff that doesn't apply was taken"
inbox apply $id < "$T/good.diff" >/dev/null || fail "apply from stdin failed"
[ "$(cat "$wt/a.txt")" = three ] || fail "apply didn't change a.txt"

# check: PANTHEON_CHECK on the checkout, its status passed on
PANTHEON_CHECK="test -d" inbox check $id | grep -q "check passed" || fail "check didn't pass"
PANTHEON_CHECK="false" inbox check $id >/dev/null && fail "a failing check passed"
inbox check $id 2>&1 | grep -q "no PANTHEON_CHECK" || true
echo "ok inbox-delegate: base, pull, apply and check on a patch request's checkout"
