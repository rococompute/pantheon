#!/bin/bash
# Genesis validation on its own: at least one part, unique names and
# unique public keys, and valid four-, five- and seven-part geneses build.
#
#   test/genesis.sh
#
# Needs main.exe (soma build main.soma) and jq.
set -u
cd "$(dirname "$0")/.."
BIN=$PWD/main.exe
[ -x "$BIN" ] || { echo "no main.exe: run soma build main.soma"; exit 1; }
T=$(mktemp -d "${TMPDIR:-/tmp}/pantheon-genesis.XXXXXX")
trap 'rm -rf "$T"' EXIT
fails=0
fail() { echo "FAIL $*"; fails=$((fails + 1)); }
ok() { echo "ok $*"; }

mkdir -p "$T/net/parts" "$T/home"
printf '{"repos": []}\n' > "$T/net/network.json"

i=0
for a in a b c d e f g; do
  "$BIN" keygen "$T/key-$a" --name "$a" --addr "127.0.0.1:$((39100 + i))" >/dev/null \
    || fail "keygen $a failed"
  i=$((i + 1))
done

copy4() {
  rm -f "$T/net/parts"/*.json
  for a in a b c d; do cp "$T/key-$a/public.json" "$T/net/parts/$a.json"; done
}

expect_refused() {
  desc=$1 pattern=$2
  if "$BIN" genesis "$T/home" "$T/net" > "$T/genesis.log" 2>&1; then
    fail "$desc: genesis succeeded"
  elif grep -q "$pattern" "$T/genesis.log"; then
    ok "$desc refused"
  else
    fail "$desc: wrong error: $(cat "$T/genesis.log")"
  fi
}

# a valid four-part genesis still builds, with four agents in it
copy4
"$BIN" genesis "$T/home" "$T/net" > "$T/genesis.log" 2>&1 \
  && jq -e '.agents | length == 4' "$T/home/genesis.json" >/dev/null \
  && ok "valid four-part genesis builds" || fail "valid genesis failed: $(cat "$T/genesis.log")"

# five parts: more than 3f + 1 is safe too
copy4
cp "$T/key-e/public.json" "$T/net/parts/e.json"
rm -rf "$T/home"; mkdir -p "$T/home"
"$BIN" genesis "$T/home" "$T/net" > "$T/genesis.log" 2>&1 \
  && jq -e '.agents | length == 5' "$T/home/genesis.json" >/dev/null \
  && ok "valid five-part genesis builds" || fail "five-part genesis failed: $(cat "$T/genesis.log")"
rm -rf "$T/home"; mkdir -p "$T/home"

# A single part is a monopoly; two and three are oligopolies.
for n in 1 2 3; do
  copy4
  rm "$T/net/parts/d.json"
  [ "$n" -ge 3 ] || rm "$T/net/parts/c.json"
  [ "$n" -ge 2 ] || rm "$T/net/parts/b.json"
  rm -rf "$T/home"; mkdir -p "$T/home"
  "$BIN" genesis "$T/home" "$T/net" > "$T/genesis.log" 2>&1 \
    && jq -e ".agents | length == $n" "$T/home/genesis.json" >/dev/null \
    && ok "valid $n-part genesis builds" || fail "$n-part genesis failed: $(cat "$T/genesis.log")"
done
rm "$T/net/parts/a.json" "$T/net/parts/b.json" "$T/net/parts/c.json"
expect_refused "zero parts" 'genesis must have at least 1 part, got 0'

# seven parts (n = 3f + 1 with f = 2): a genesis with seven agents
copy4
for a in e f g; do cp "$T/key-$a/public.json" "$T/net/parts/$a.json"; done
rm -rf "$T/home"; mkdir -p "$T/home"
"$BIN" genesis "$T/home" "$T/net" > "$T/genesis.log" 2>&1 \
  && jq -e '.agents | length == 7' "$T/home/genesis.json" >/dev/null \
  && ok "valid seven-part genesis builds" || fail "seven-part genesis failed: $(cat "$T/genesis.log")"
rm -rf "$T/home"; mkdir -p "$T/home"

# a repeated name (d.json now claims to be a)
copy4
cp "$T/key-a/public.json" "$T/net/parts/d.json"
expect_refused "duplicate name" 'duplicate part name'

# a repeated public key (d keeps its name, but carries a's key)
copy4
jq --argjson k "$(jq '.pubkey' "$T/net/parts/a.json")" '.pubkey = $k' "$T/net/parts/d.json" > "$T/d.json" \
  && mv "$T/d.json" "$T/net/parts/d.json"
expect_refused "duplicate public key" 'duplicate public key'

[ $fails -eq 0 ] && echo PASS || { echo "$fails failed"; exit 1; }
