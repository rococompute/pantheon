#!/bin/sh
# What CI judges a bid against, as scripts/sandbox.sh start sets it up: the
# tree each VM's node was built from (its ~/pantheon/.commit), not the
# operator's checkout, which may be ahead of the market's repository. A test
# changed in the checkout but not in the market would otherwise fail every
# Pantheon bid with "changed a test already there". The test list comes from
# that tree too: deploy/ci-pantheon, or, in a tree from before that file, the
# default its scripts/sandbox.sh wrote out. No VM: in_vm is a stand-in.
set -eu
here=$(cd "$(dirname "$0")/.." && pwd) root=$here
t=$(mktemp -d); trap 'rm -rf "$t"' EXIT
fail() { echo "FAIL: $*"; exit 1; }
ok() { echo "ok $*"; }

# the functions under test, from scripts/sandbox.sh as it is
sed -n '/^ci_tests() {/,/^}/p; /^built_tree() {/,/^}/p' "$here/scripts/sandbox.sh" > "$t/fns.sh"
grep -q '^built_tree()' "$t/fns.sh" && grep -q '^ci_tests()' "$t/fns.sh" || fail "scripts/sandbox.sh has no ci_tests or built_tree"
. "$t/fns.sh"

# a checkout: commit A (what the node was built from, an old-style
# sandbox.sh with its default inline), then B (the checkout's head) changing
# a test and adding deploy/ci-pantheon
r=$t/repo; mkdir -p "$r/test" "$r/scripts" "$r/deploy"
g() { git -C "$r" -c user.name=t -c user.email=t@t -c commit.gpgsign=false "$@"; }
g init -q
echo 'echo built' > "$r/test/x.sh"
cat > "$r/scripts/sandbox.sh" <<'EOF'
    pantheon_ci=$(python3 "$here/deploy/ci-command.py" "$here" "${PANTHEON_CI:-timeout 120 soma build main.soma && sh test/x.sh}")
EOF
g add -A; g commit -qm A; a=$(g rev-parse HEAD)
echo 'echo ahead' > "$r/test/x.sh"
echo 'sh test/x.sh && sh test/y.sh' > "$r/deploy/ci-pantheon"
g add -A; g commit -qm B; b=$(g rev-parse HEAD)

here=$r trees=$t/trees
mkdir -p "$trees"
commit=$a
in_vm() { [ -n "$commit" ] && echo "$commit"; }

tree=$(built_tree vm-a) || fail "built_tree failed for a built commit"
[ "$(cat "$tree/test/x.sh")" = "echo built" ] || fail "the tree isn't the node's build: $(cat "$tree/test/x.sh")"
ok "the tree CI judges by is the node's build, not the checkout's head"

[ "$(ci_tests "$tree")" = "timeout 120 soma build main.soma && sh test/x.sh" ] || fail "old-style default: $(ci_tests "$tree")"
ok "a tree from before deploy/ci-pantheon gives the default its sandbox.sh wrote out"

commit=$b
tree_b=$(built_tree vm-b) || fail "built_tree failed for B"
[ "$(ci_tests "$tree_b")" = "sh test/x.sh && sh test/y.sh" ] || fail "deploy/ci-pantheon: $(ci_tests "$tree_b")"
ok "a tree with deploy/ci-pantheon gives that file's command"

commit=""
built_tree vm-none >/dev/null 2>"$t/err" && fail "a node with no .commit passed"
grep -q 'scripts/sandbox.sh update' "$t/err" || fail "no .commit: $(cat "$t/err")"
commit=0123456789abcdef0123456789abcdef01234567
built_tree vm-gone >/dev/null 2>"$t/err" && fail "a commit missing from the checkout passed"
grep -q "isn't in" "$t/err" || fail "missing commit: $(cat "$t/err")"
ok "a node with no recorded commit, or one the checkout lacks, stops start with what to do"

# the policy's baseline from the node's tree pins the node's test
python3 "$root/deploy/ci-command.py" "$tree" true > "$t/cmd"
built_hash=$(git -C "$r" show "$a:test/x.sh" | python3 -c 'import hashlib,sys; print(hashlib.sha256(sys.stdin.buffer.read()).hexdigest())')
grep -q "\"test/x.sh\":\"$built_hash\"" "$t/cmd" || fail "the baseline doesn't pin the built test/x.sh"
ok "the policy's baseline pins the node's tests"

# one list for both scripts: neither keeps its own copy of the default
here=$root
[ -s "$here/deploy/ci-pantheon" ] || fail "no deploy/ci-pantheon"
grep -q 'PANTHEON_CI:-timeout' "$here/scripts/sandbox.sh" "$here/scripts/host.sh" && fail "a script still has the CI list inline"
ok "scripts/sandbox.sh and scripts/host.sh read the CI list from deploy/ci-pantheon"
