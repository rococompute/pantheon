#!/bin/bash
# Scopes and leader-alone merges: test/scopes.soma's market and agent checks,
# then genesis: a part's "exclude" lands in genesis.json, naming only the
# network's repositories, never leaving a repository with no one whose scope
# has it, and a part without one leaves genesis as it was.
#
#   test/scopes.sh
#
# Needs soma, main.exe (soma build main.soma), git and jq.
set -u
cd "$(dirname "$0")/.."
BIN=$PWD/main.exe
[ -x "$BIN" ] || { echo "no main.exe: run soma build main.soma"; exit 1; }
T=$(mktemp -d "${TMPDIR:-/tmp}/pantheon-scopes.XXXXXX")
trap 'rm -rf "$T"' EXIT
fails=0
fail() { echo "FAIL $*"; fails=$((fails + 1)); }
ok() { echo "ok $*"; }

if ! soma run test/scopes.soma > "$T/out" 2> "$T/err"; then
  echo "FAIL scopes program failed: $(cat "$T/err" "$T/out")"; exit 1
fi
cat "$T/out"
n=$(grep -c '^ok ' "$T/out")
if grep -q '^FAIL' "$T/out" || [ "$n" -lt 21 ]; then fail "scopes program ($n of 21 ok)"; fi

# a network with two repositories, calc and lib
for r in calc lib; do
  mkdir -p "$T/src/$r"
  (cd "$T/src/$r" && git init -q . && echo "$r" > f && git add f \
    && git -c user.name=t -c user.email=t@t -c commit.gpgsign=false commit -qm "$r")
done
c() { git -C "$T/src/$1" rev-parse HEAD; }
mkdir -p "$T/net/parts"
printf '{"repos": [{"name": "calc", "url": "%s", "commit": "%s"}, {"name": "lib", "url": "%s", "commit": "%s"}]}\n' \
  "$T/src/calc" "$(c calc)" "$T/src/lib" "$(c lib)" > "$T/net/network.json"
i=0
for a in a b c d; do
  "$BIN" keygen "$T/key-$a" --name "$a" --addr "127.0.0.1:$((39300 + i))" >/dev/null || fail "keygen $a failed"
  cp "$T/key-$a/public.json" "$T/net/parts/$a.json"
  i=$((i + 1))
done
gen() { rm -rf "$T/home"; mkdir -p "$T/home"; "$BIN" genesis "$T/home" "$T/net" > "$T/genesis.log" 2>&1; }
part() { jq "$2" "$T/key-$1/public.json" > "$T/net/parts/$1.json"; }

gen && plain=$(jq -c '.agents' "$T/home/genesis.json") || fail "genesis without exclude: $(cat "$T/genesis.log")"
jq -e '[.agents[] | has("exclude")] | any | not' "$T/home/genesis.json" >/dev/null \
  && ok "parts without exclude leave genesis's agents as they were" || fail "an agent has exclude it never asked for"

part c '. + {exclude: ["lib"]}'; part d '. + {exclude: ["lib"]}'
gen && jq -e '[.agents[] | select(.exclude == ["lib"]) | .name] == ["c", "d"]' "$T/home/genesis.json" >/dev/null \
  && ok "a part's exclude lands in genesis" || fail "exclude not in genesis: $(cat "$T/genesis.log")"

part d '. + {exclude: ["nope"]}'
gen && fail "an exclude naming no repository was taken" \
  || { grep -q "isn't one of the network's repositories" "$T/genesis.log" && ok "an exclude naming no repository is refused" || fail "wrong error: $(cat "$T/genesis.log")"; }

for a in a b c d; do part $a '. + {exclude: ["lib"]}'; done
gen && fail "every part excluding lib was taken" \
  || { grep -q "no agent could merge there" "$T/genesis.log" && ok "no repository is left outside every scope" || fail "wrong error: $(cat "$T/genesis.log")"; }

part a '. + {exclude: "lib"}'
gen && fail "an exclude that isn't a list was taken" \
  || { grep -q "exclude is a list" "$T/genesis.log" && ok "exclude must be a list" || fail "wrong error: $(cat "$T/genesis.log")"; }

[ "$fails" -eq 0 ] && echo PASS || { echo "FAIL ($fails)"; exit 1; }
