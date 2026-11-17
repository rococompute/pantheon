#!/bin/bash
# Catch the wallet dogfood's Markdown .plan before launching model work.
# Requires main.exe built from main.soma and git. No provider or cmux.
set -eu
cd "$(dirname "$0")/.."
BIN=$PWD/main.exe
T=$(mktemp -d "${TMPDIR:-/tmp}/pantheon-plan-preflight.XXXXXX")
trap 'rm -rf "$T"' EXIT
fail() { echo "FAIL $*"; cat "$T/out" "$T/err" 2>/dev/null || true; exit 1; }
expect() {
  local want=$1 what=$2 got=0
  shift 2
  "$BIN" "$@" > "$T/out" 2> "$T/err" || got=$?
  [ "$got" -eq "$want" ] || fail "$what: wanted $want, got $got"
  echo "ok $what"
}
printf '# note\n2026-11-16\n- first item\n\t- second item\n' > "$T/dropped"
expect 1 'Markdown bullets cannot silently drop the entire plan' plan --check "$T/dropped"
grep -Fq "'- ' means dropped work" "$T/err" || fail 'actionable dropped-item error'
expect 0 'intentional all-dropped history has an explicit override' plan --check --allow-closed-plan "$T/dropped"
printf 'first item\n+ completed item\n* done today\n- deliberately dropped\n' > "$T/valid"
expect 0 'open work and legitimate historical marks are preserved' plan --check "$T/valid"
expect 0 'plan listing keeps its existing format' plan "$T/valid"
[ "$(cat "$T/out")" = 'first item' ] || fail 'changed plan semantics'
printf '+ completed item\n* done today\n- deliberately dropped\n' > "$T/complete"
expect 0 'completed plans remain valid' plan --check "$T/complete"
printf '# a note\n2026-11-16\n\n' > "$T/empty"
expect 0 'plans without items remain valid' plan --check "$T/empty"
expect 1 'missing explicit input is an error' plan --check "$T/missing"
for mark in '- [ ]' '* [ ]' '+ [x]' '[ ]' '[X]'; do
  printf 'open item\n%s another item\n' "$mark" > "$T/checkbox"
  expect 1 "reject Markdown checkbox $mark beside open work" plan --check "$T/checkbox"
  expect 1 "closed-plan override cannot reinterpret checkbox $mark" plan --check --allow-closed-plan "$T/checkbox"
done

repo="$T/repo with spaces"
mkdir "$repo"
git -C "$repo" init -q
cp "$T/dropped" "$repo/.plan"
git -C "$repo" add .plan
git -C "$repo" -c user.name=test -c user.email=test@example.com -c commit.gpgsign=false commit -qm 'dropped plan'
# A dirty correction must not hide a malformed committed plan: that is
# what genesis would clone. Check before leaving a partial network/keys.
cp "$T/valid" "$repo/.plan"
expect 1 'init checks the committed plan, not a dirty correction' init "$T/refused" --repo "wallet=$repo"
[ ! -e "$T/refused" ] || fail 'refused init left partial network or keys'
expect 0 'init can deliberately seed a closed plan' init "$T/network" --repo "wallet=$repo" --allow-closed-plan --base-port 39910
expect 1 'fresh node setup also catches keygen/genesis launches' image "$T/network/claude" "$T/refused.soma"
[ ! -e "$T/refused.soma" ] || fail 'refused setup emitted an image'
expect 0 'node setup accepts the explicit closed-plan override' image "$T/network/claude" "$T/allowed.soma" --allow-closed-plan
# The clone's uncommitted correction must not hide its committed plan.
cp "$T/valid" "$T/network/claude/repos/wallet/.plan"
expect 1 'node setup also checks HEAD rather than dirty files' image "$T/network/claude" "$T/refused.soma"
# A resumed chain can legitimately have closed every item. Image setup
# does not replay the log; use a nonempty block record to exercise that gate.
printf '{"h":1,"txs":[]}\n' > "$T/network/claude/blocks.log"
expect 0 'resuming an existing chain does not require the override' image "$T/network/claude" "$T/resumed.soma"
echo PASS
