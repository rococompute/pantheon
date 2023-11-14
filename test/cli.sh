#!/bin/bash
# CLI boundary regression: command selection, exact argv, and exit statuses.
# Run against main.exe built by soma build main.soma. Needs git and jq.
set -u
cd "$(dirname "$0")/.."
BIN=$PWD/main.exe
[ -x "$BIN" ] || { echo 'no main.exe: run soma build main.soma'; exit 1; }
T=$(mktemp -d "${TMPDIR:-/tmp}/pantheon-cli.XXXXXX")
trap 'rm -rf "$T"' EXIT
fails=0
fail() { echo "FAIL $*"; fails=$((fails + 1)); }
ok() { echo "ok $*"; }
expect() {
  local want=$1 desc=$2 got
  shift 2
  "$BIN" "$@" > "$T/out" 2> "$T/err"; got=$?
  if [ "$got" -eq "$want" ]; then ok "$desc (exit $got)";
  else fail "$desc: wanted exit $want, got $got: $(cat "$T/out" "$T/err")"; fi
}
# Usage historically succeeds, including wrong arities. Preserve that contract.
expect 0 'missing command'
cp "$T/out" "$T/usage"
for args in unknown genesis status tx node up edits apply-edits check; do
  expect 0 "usage for $args" "$args"
  cmp -s "$T/usage" "$T/out" || fail "usage differs for $args"
done
expect 0 'unknown command with arguments' unknown '' 'two words'
cmp -s "$T/usage" "$T/out" || fail 'unknown-command usage differs'
expect 0 'genesis extra argument' genesis home network extra
cmp -s "$T/usage" "$T/out" || fail 'wrong-arity genesis reached implementation'
expect 0 'plan extra argument' plan file extra
cmp -s "$T/usage" "$T/out" || fail 'wrong-arity plan reached implementation'
expect 0 'status extra argument' status home extra
cmp -s "$T/usage" "$T/out" || fail 'wrong-arity status reached implementation'
expect 0 'tx requires at least one field' tx home
cmp -s "$T/usage" "$T/out" || fail 'empty tx reached implementation'
expect 1 'init without arguments reaches its own parser' init
expect 1 'keygen without arguments reaches its own parser' keygen

mkdir "$T/repo with spaces"
git -C "$T/repo with spaces" init -q
printf 'before\n' > "$T/repo with spaces/file name"
git -C "$T/repo with spaces" add .
git -C "$T/repo with spaces" -c user.name=t -c user.email=t@t -c commit.gpgsign=false commit -qm base
head=$(git -C "$T/repo with spaces" rev-parse 'HEAD^{tree}')
expect 0 'init flags and spaced paths' init "$T/network home" --repo "repo=$T/repo with spaces" --base-port 39810 --block-ms 321 --param 'label=two words'
jq -e '.block_ms == 321 and .params.label == "two words" and .agents[0].addr == "127.0.0.1:39810"' "$T/network home/claude/genesis.json" >/dev/null || fail 'init arguments changed'
expect 1 'init rejects trailing argument' init "$T/unused" --repo "repo=$T/repo with spaces" 'unexpected argument'
grep -Fq 'unknown init argument unexpected argument' "$T/err" || fail 'init lost trailing argument'
expect 0 'keygen flags and values' keygen "$T/key home" --addr 'host name:39820' --name 'agent name'
jq -e '.name == "agent name" and .addr == "host name:39820"' "$T/key home/public.json" >/dev/null || fail 'keygen arguments changed'
expect 1 'keygen failure status' keygen "$T/key home" --name x --addr x:1
mkdir "$T/genesis home"
expect 0 'genesis paths' genesis "$T/genesis home" "$T/network home/network"
cmp -s "$T/genesis home/genesis.json" "$T/network home/claude/genesis.json" || fail 'genesis paths changed'
expect 1 'genesis failure status' genesis "$T/genesis home" "$T/missing network"

printf '2026-11-09\nfirst item\n+ completed\nsecond item\n' > "$T/a plan"
printf 'first item\nsecond item\n' > "$T/expected"
expect 0 'explicit plan path' plan "$T/a plan"
cmp -s "$T/expected" "$T/out" || fail 'explicit plan output'
(cd "$T" && cp 'a plan' .plan && "$BIN" plan) > "$T/default"
cmp -s "$T/expected" "$T/default" || fail 'default plan output'
expect 1 'missing plan status' plan "$T/missing plan"
printf 'status with spaces\nand a newline\n' > "$T/genesis home/status.txt"
expect 0 'status home' status "$T/genesis home"
cmp -s "$T/genesis home/status.txt" "$T/out" || fail 'status output changed'
expect 1 'missing status' status "$T/missing home"
expect 0 'tx preserves empty and multiline fields' tx "$T/tx home" post 'repo name' '' $'line one\nline two' '--flag'
jq -e '. == ["post", "repo name", "", "line one\nline two", "--flag"]' "$T/tx home/inbox/"*.json >/dev/null || fail 'tx fields changed'

printf 'after\n' > "$T/repo with spaces/file name"
expect 0 'edits note arguments' edits "$T/repo with spaces" 'two words' '' '--note' $'next\nline'
jq -e '.note == "two words  --note next\nline" and .edits[0].path == "file name"' "$T/out" >/dev/null || fail 'edits argv changed'
jq '[.edits[] | .path, .old, .new]' "$T/out" > "$T/edits file.json"
git clone -q "$T/repo with spaces" "$T/apply home"
expect 0 'apply-edits paths' apply-edits "$T/apply home" "$T/edits file.json"
cmp -s "$T/apply home/file name" "$T/repo with spaces/file name" || fail 'apply-edits content'
expect 0 'check arguments' check "$T/repo with spaces" "$head" "$T/edits file.json" "$T/check output"
git -C "$T/apply home" add .
[ "$(cat "$T/out")" = "$(git -C "$T/apply home" write-tree)" ] || fail 'check tree output'
printf '["../escape", "", "x"]\n' > "$T/bad edits"
expect 1 'apply-edits rejection status' apply-edits "$T/apply home" "$T/bad edits"
expect 1 'check bid rejection status' check "$T/repo with spaces" "$head" "$T/bad edits" "$T/rejected output"
expect 3 'check node failure status' check "$T/repo with spaces" wrong-head "$T/edits file.json" "$T/node output"
# Reach node parsing without binding sockets; up must forward its tail to all
# children, including a value containing spaces and a distinct backend map.
expect 1 'node flags preserved' node "$T/network home/claude" --perspective 'two words' '--unknown flag'
grep -Fq 'unknown node flag --unknown flag' "$T/err" || fail 'node flags changed'
expect 0 'up forwards flags to children' up "$T/network home" --backends claude=scripted,codex=scripted,grok=scripted,muse=scripted --perspective 'two words' '--unknown flag'
for a in claude codex grok muse; do
  grep -Fq 'unknown node flag --unknown flag' "$T/network home/$a/node.log" || fail "up lost flags for $a"
done
expect 1 'up backend parsing status' up "$T/network home" --backends 'invalid backend'
grep -Fq -- '--backends wants agent=backend,...' "$T/err" || fail 'up backend argument changed'
[ "$fails" -eq 0 ] && echo PASS || { echo "$fails failed"; exit 1; }
