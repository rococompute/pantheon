#!/bin/bash
# Regression for Pantheon's command-line fallback (app/cli.soma).
# No arguments and help print the usage on stdout and exit 0. An unknown
# command, or a known command with an argument list no command takes, says
# what is wrong on stderr and exits 1. Valid commands keep their own status.
# Needs main.exe built by `soma build main.soma`.
set -u
cd "$(dirname "$0")/.." || exit 1
BIN=${PANTHEON_BIN:-$PWD/main.exe}
[ -x "$BIN" ] || { echo 'no main.exe: run soma build main.soma'; exit 1; }
T=$(mktemp -d "${TMPDIR:-/tmp}/pantheon-cli-exit.XXXXXX") || exit 1
trap 'rm -rf "$T"' EXIT HUP INT TERM
fails=0
fail() { echo "FAIL $*"; fails=$((fails + 1)); }
ok() { echo "ok $*"; }
run() { "$BIN" "$@" >"$T/out" 2>"$T/err"; status=$?; }

# an invocation the fallback must refuse: exit 1, a diagnostic on stderr,
# and no usage on stdout
refused() {
  local desc=$1 needle=$2
  shift 2
  run "$@"
  if [ "$status" -eq 1 ]; then ok "$desc (exit 1)";
  else fail "$desc: wanted exit 1, got $status: $(cat "$T/out" "$T/err")"; fi
  [ -s "$T/err" ] || fail "$desc: no diagnostic on stderr"
  [ ! -s "$T/out" ] || fail "$desc: wrote to stdout: $(cat "$T/out")"
  grep -Fq "$needle" "$T/err" || fail "$desc: stderr lacks '$needle': $(cat "$T/err")"
  grep -Fq 'pantheon help' "$T/err" || fail "$desc: stderr does not point at pantheon help: $(cat "$T/err")"
}

# no command is the help path: usage on stdout, exit 0, stderr empty
run
[ "$status" -eq 0 ] || fail "no arguments: wanted exit 0, got $status: $(cat "$T/out" "$T/err")"
[ ! -s "$T/err" ] || fail "no arguments: stderr is not empty: $(cat "$T/err")"
grep -Fq 'pantheon: a private BFT labor market' "$T/out" || fail 'no arguments: no usage on stdout'
grep -Fq 'pantheon help' "$T/out" || fail 'no arguments: usage does not list pantheon help'
cp "$T/out" "$T/usage"

# help, --help and -h are the same intentional success
for arg in help --help -h; do
  run "$arg"
  [ "$status" -eq 0 ] || fail "$arg: wanted exit 0, got $status: $(cat "$T/out" "$T/err")"
  [ ! -s "$T/err" ] || fail "$arg: stderr is not empty: $(cat "$T/err")"
  cmp -s "$T/usage" "$T/out" || fail "$arg: usage differs from the no-argument usage"
done
run help status
[ "$status" -eq 0 ] || fail "help with a topic: wanted exit 0, got $status"
cmp -s "$T/usage" "$T/out" || fail 'help with a topic: usage differs'

# an unknown command is an error, even when it carries arguments
refused 'unknown command' 'unknown command "bogus"' bogus
refused 'unknown command with arguments' 'unknown command "bogus"' bogus home extra
refused 'empty command' 'unknown command ""' ''

# a known command with an argument list no dispatch case takes is an error
for cmd in genesis status tx node service apply-edits check leader-chain leader-note image edits up; do
  refused "$cmd with no arguments" "pantheon $cmd: wrong arguments" "$cmd"
done
refused 'plan with an extra argument' 'pantheon plan: wrong arguments' plan file extra
refused 'status with an extra argument' 'pantheon status: wrong arguments' status home extra
grep -Fq '["home", "extra"]' "$T/err" || fail 'status diagnostic does not show the arguments it got'
refused 'genesis with an extra argument' 'pantheon genesis: wrong arguments' genesis home net extra
refused 'tx without a field' 'pantheon tx: wrong arguments' tx home

# valid commands still run, and a command's own failure is still its own
printf '2026-11-09\nfirst item\n+ done\nsecond item\n' > "$T/a plan"
printf 'first item\nsecond item\n' > "$T/expected"
run plan "$T/a plan"
[ "$status" -eq 0 ] || fail "valid plan: wanted exit 0, got $status: $(cat "$T/out" "$T/err")"
cmp -s "$T/expected" "$T/out" || fail 'valid plan: output changed'
printf '2026-11-09\nfirst item\n' > "$T/check.plan"
run plan --check "$T/check.plan"
[ "$status" -eq 0 ] || fail "valid plan --check: wanted exit 0, got $status: $(cat "$T/out" "$T/err")"
grep -Fq 'plan preflight passed' "$T/out" || fail 'valid plan --check: output changed'
mkdir "$T/home"
printf 'status with spaces\nand a newline\n' > "$T/home/status.txt"
run status "$T/home"
[ "$status" -eq 0 ] || fail "valid status: wanted exit 0, got $status: $(cat "$T/out" "$T/err")"
cmp -s "$T/home/status.txt" "$T/out" || fail 'valid status: output changed'
run tx "$T/tx home" post 'repo name' '' $'line one\nline two'
[ "$status" -eq 0 ] || fail "valid tx: wanted exit 0, got $status: $(cat "$T/out" "$T/err")"
[ -n "$(find "$T/tx home/inbox" -name '*.json' -print -quit)" ] || fail 'valid tx: no inbox file'
grep -Fq 'line one\nline two' "$T/tx home/inbox/"*.json || fail 'valid tx: fields changed'

# a valid argument list still reaches the command, whose own failure is 1
run genesis "$T/missing home" "$T/missing net"
[ "$status" -eq 1 ] || fail "genesis with a missing network: wanted exit 1, got $status"
grep -Fq 'cannot read' "$T/err" || fail 'genesis with a missing network: lost its own diagnostic'
run status "$T/missing home"
[ "$status" -eq 1 ] || fail "status with a missing home: wanted exit 1, got $status"
grep -Fq 'no status in' "$T/err" || fail 'status with a missing home: lost its own diagnostic'

# init and keygen parse their own arguments and already fail with 1
run init
[ "$status" -eq 1 ] || fail "init without arguments: wanted exit 1, got $status"
grep -Fq 'usage: pantheon init' "$T/err" || fail 'init without arguments: lost its usage'
run keygen
[ "$status" -eq 1 ] || fail "keygen without arguments: wanted exit 1, got $status"
grep -Fq 'usage: pantheon keygen' "$T/err" || fail 'keygen without arguments: lost its usage'

[ "$fails" -eq 0 ] && echo PASS || { echo "$fails failed"; exit 1; }
