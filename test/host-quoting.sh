#!/bin/sh
# scripts/host.sh with a hostile branch name and remote (docs/SECURITY-REVIEW-2.md
# P-11): a branch that isn't a plain ref name stops it before it writes
# anything, and a remote with shell and Python metacharacters reaches the
# diplomat's inbox wrapper and instructions as it is, running nothing.
set -eu
here=$(cd "$(dirname "$0")/.." && pwd)
t=$(mktemp -d); trap 'rm -rf "$t"' EXIT
fail() { echo "FAIL: $*"; exit 1; }
ok() { echo "ok $*"; }

for b in 'x;touch pwn' 'a b' '$(touch pwn)' "it's" '-x' 'a..b' 'a`id`'; do
  ( cd "$t" && PANTHEON_HOST="$t/h" BRANCH="$b" REMOTE= sh "$here/scripts/host.sh" instructions ) >"$t/out" 2>&1 \
    && fail "BRANCH '$b' was accepted"
  grep -q 'not a plain git branch name' "$t/out" || fail "BRANCH '$b': $(cat "$t/out")"
  [ ! -e "$t/pwn" ] && [ ! -e "$t/h/desk" ] || fail "BRANCH '$b' ran or wrote something"
done
ok "a branch that isn't a plain ref name is refused before anything is written"

for b in master main release/1.2 feat_x-y; do
  PANTHEON_HOST="$t/ok" BRANCH="$b" REMOTE= sh "$here/scripts/host.sh" instructions >/dev/null 2>&1 || fail "BRANCH $b refused"
done
ok "plain branch names pass"

# a remote that would run code if pasted into the shell wrapper or Python
r="/nowhere/x';touch \"$t/pwn\";'\$(touch $t/pwn)\"\"\")+open('$t/pwn','w')#"
PANTHEON_HOST="$t/h2" BRANCH=master REMOTE="$r" sh "$here/scripts/host.sh" instructions >/dev/null 2>&1 || fail "instructions failed"
w="$t/h2/desk/claude/pantheon-inbox"
[ -x "$w" ] || fail "no wrapper"
sh -n "$w" || fail "the wrapper doesn't parse"
# run the wrapper with its exec replaced by printing what it was given
sed 's/^  exec .*/  sh -c '"'"'printf "%s\\n" "$PANTHEON_REMOTE" "$PANTHEON_BRANCH"'"'"'/' "$w" > "$t/w2"
got=$(sh "$t/w2" | head -1)
[ "$got" = "$r" ] || fail "the wrapper gave PANTHEON_REMOTE as '$got'"
[ ! -e "$t/pwn" ] || fail "the remote's text ran"
grep -qF "$r" "$t/h2/diplomats/claude.md" || fail "the remote isn't in the instructions as it is"
ok "a remote with metacharacters reaches the wrapper and instructions unchanged, running nothing"
echo PASS
