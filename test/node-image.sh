#!/bin/sh
# A node as a MirageOS unikernel among binaries (U-1). `pantheon image`
# writes a node's setup into a Soma program (node_sandbox.soma's
# run_node_image), soma build makes the image, and solo5-vmnet boots it on
# the Mac's vmnet network with a storage device, at the address its genesis
# gives it. Two binary nodes run beside it and the fourth agent is down, so
# a block needs the image's votes (3 of 4): the chain moving shows the
# image votes, and its blocks.log, read from its disk, agrees with the
# binaries'. Then the image is stopped (the chain stops), and booted again
# on the same disk with the fourth agent up: the chain moves on, the image
# read its votes back (signed.log kept, byte for byte), and its disk gets
# the same blocks as the binaries'.
#
# Needs Soma's MirageOS switch (SOMA_MIRAGE_SWITCH, default hvf) with
# solo5-hvt and solo5-vmnet (macOS 26 or later), as Soma's
# dev/mirage-check.sh does; without them the test says so and passes.
set -eu
cd "$(dirname "$0")/.."
SWITCH=${SOMA_MIRAGE_SWITCH:-hvf}
if ! opam exec --switch="$SWITCH" -- sh -c 'command -v solo5-hvt && command -v solo5-vmnet' >/dev/null 2>&1; then
  echo "SKIP no solo5-hvt and solo5-vmnet in opam switch $SWITCH (Soma's MirageOS switch)"; exit 0
fi
BIN=$PWD/main.exe
[ -x "$BIN" ] || { echo "no main.exe: run soma build main.soma"; exit 1; }
t=$(mktemp -d "${TMPDIR:-/tmp}/pantheon-node-image.XXXXXX")
# the image's source goes in the checkout, so its imports resolve
src=test/node_image_$$.soma
hvt=test/node_image_$$.hvt
pids=""
cleanup() {
  for p in $pids; do kill "$p" 2>/dev/null || true; done
  pkill -f "solo5-hvt .*$hvt" 2>/dev/null || true
  if [ -n "${KEEP:-}" ]; then echo "kept $t"; rm -f "$src" "$hvt"; else rm -rf "$t" "$src" "$hvt"; fi
}
trap cleanup EXIT HUP INT TERM

# the host's address on the vmnet network (a bridge with an address),
# where the binaries listen; the image's is another on it
gw=$(ifconfig 2>/dev/null | awk '/^bridge/ {b=1; next} /^[a-z]/ {b=0} b && /inet / {print $2}' | grep -v '^127\.' | head -1)
gw=${gw:-192.168.105.1}
ip=${gw%.*}.233
port=39960

# a network of four, made the way agents on separate machines make one:
# keys with their addresses, the parts, a genesis for each
mkdir -p "$t/src" "$t/net/parts" && cp -R examples/calc/. "$t/src/"
(cd "$t/src" && git init -q . && git add -A && git -c user.name=t -c user.email=t@t -c commit.gpgsign=false commit -qm genesis)
commit=$(git -C "$t/src" rev-parse HEAD)
printf '{"block_ms":200,"params":{},"repos":[{"name":"calc","url":"%s","commit":"%s"}]}\n' "$t/src" "$commit" > "$t/net/network.json"
i=0
for a in claude codex grok muse; do
  addr=$gw:$((port + i))
  [ "$a" = muse ] && addr=$ip:$((port + i))
  "$BIN" keygen "$t/$a" --name "$a" --addr "$addr" >> "$t/init.log" 2>&1 || { cat "$t/init.log"; exit 1; }
  cp "$t/$a/public.json" "$t/net/parts/$a.json"
  i=$((i + 1))
done
for a in claude codex grok muse; do
  "$BIN" genesis "$t/$a" "$t/net" >> "$t/init.log" 2>&1 || { cat "$t/init.log"; echo 'FAIL genesis'; exit 1; }
done

"$BIN" image "$t/muse" "$src" > "$t/image.log" 2>&1 || { cat "$t/image.log"; echo 'FAIL pantheon image'; exit 1; }
grep -q 'node_config' "$src" || { echo 'FAIL no config in the image source'; exit 1; }
if ! SOMA_MIRAGE_SWITCH="$SWITCH" soma build "$src" > "$t/build.log" 2>&1; then tail -30 "$t/build.log"; echo 'FAIL the image does not build'; exit 1; fi
[ -f "$hvt" ] || { tail -20 "$t/build.log"; echo "FAIL no $hvt"; exit 1; }
echo "ok pantheon image wrote muse's node, and soma build made its MirageOS image"

# the named files on Soma's storage device (toplevel/somaStorage.ml's
# SOMAKV01 banks: the valid header with the newest generation)
cat > "$t/files.py" <<'PY'
import hashlib, struct, sys
d = open(sys.argv[1], 'rb').read()
sector = 512
bank = min(len(d) // sector // 2, 16 * 1024 * 1024 // sector)
best = None
for i in (0, 1):
    h = d[i * bank * sector:(i * bank + 1) * sector]
    if h[:8] != b'SOMAKV01' or hashlib.md5(h[:40]).digest() != h[40:56]:
        continue
    gen, n = struct.unpack('>QQ', h[8:24])
    body = d[(i * bank + 1) * sector:(i * bank + 1) * sector + n]
    if hashlib.md5(body).digest() != h[24:40]:
        continue
    if best is None or gen > best[0]:
        best = (gen, body)
files = {}
if best:
    body = best[1]
    count = struct.unpack('>I', body[:4])[0]
    pos = 4
    def take():
        global pos
        k = struct.unpack('>I', body[pos:pos + 4])[0]
        pos += 4
        s = body[pos:pos + k]
        pos += k
        return s
    for _ in range(count):
        name = take().decode()
        files[name] = take()
name = sys.argv[2] if len(sys.argv) > 2 else None
if name is None:
    print(' '.join(sorted(files)))
else:
    sys.stdout.buffer.write(files.get(name, b''))
PY

truncate -s 64M "$t/disk.img"
boot() {
  opam exec --switch="$SWITCH" -- solo5-vmnet -- solo5-hvt --mem=512 --block:storage="$t/disk.img" -- \
    "$hvt" --ipv4="$ip/24" --ipv4-gateway="$gw" > "$t/boot$1.log" 2>&1 &
  image=$!
  pids="$pids $image"
  n=0
  until grep -q 'muse listening on port' "$t/boot$1.log"; do
    sleep 1; n=$((n + 1))
    [ $n -lt 30 ] || { tail -20 "$t/boot$1.log"; echo "FAIL the image did not start"; exit 1; }
  done
}
stop_image() {
  kill "$image" 2>/dev/null || true
  pkill -f "solo5-hvt .*$hvt" 2>/dev/null || true
  n=0
  while pgrep -f "solo5-hvt .*$hvt" >/dev/null; do sleep 1; n=$((n + 1)); [ $n -lt 10 ] || break; done
}
height() { sed -n 's/^height \([0-9]*\).*/\1/p' "$t/$1/status.txt" 2>/dev/null | head -1; }
# wait_height AGENT H SECONDS: the agent's status reaches height H
wait_height() {
  n=0
  until h=$(height "$1"); [ -n "$h" ] && [ "$h" -ge "$2" ]; do
    sleep 1; n=$((n + 1))
    if [ $n -ge "$3" ]; then
      echo "--- muse (image)"; grep -hv 'Solo5\|INFO\|^ \|___' "$t"/boot*.log | tail -15
      echo "--- claude"; tail -8 "$t/claude/node.log"
      echo "FAIL $1 did not reach height $2 in $3 s (it is at ${h:-nothing})"; exit 1
    fi
  done
  waited=$n
}

boot 1
for a in claude codex; do
  "$BIN" node "$t/$a" --listen "$gw" --max-llm-calls 0 > "$t/$a/node.log" 2>&1 &
  pids="$pids $!"
done
wait_height claude 3 120
echo "ok the chain moved with the image voting: claude at height $(height claude) in $waited s, with codex and muse (grok is down)"

stop_image
files=$(python3 "$t/files.py" "$t/disk.img")
for f in status.txt signed.log blocks.log consensus.state; do
  case " $files " in *" $f "*) ;; *) tail -20 "$t/boot1.log"; echo "FAIL no $f on the image's disk (has: $files)"; exit 1;; esac
done
python3 "$t/files.py" "$t/disk.img" blocks.log > "$t/muse-blocks"
python3 "$t/files.py" "$t/disk.img" signed.log > "$t/signed1"
k=$(wc -l < "$t/muse-blocks" | tr -d ' ')
[ "$k" -ge 2 ] || { echo "FAIL the image stored $k blocks"; exit 1; }
head -n "$k" "$t/claude/blocks.log" | cmp -s - "$t/muse-blocks" || { echo 'FAIL the image and claude disagree on a block'; exit 1; }
[ -s "$t/signed1" ] || { echo 'FAIL the image signed no vote'; exit 1; }
echo "ok its disk holds $k blocks, the same as claude's, and $(wc -l < "$t/signed1" | tr -d ' ') signed votes"

# with the image down, 2 of 4 can't decide: the chain waits for it
before=$(height claude)
sleep 3
[ "$(height claude)" = "$before" ] || { echo 'FAIL the chain moved without the image'; exit 1; }
# Booted again with grok up too. Not with grok still down: the image may
# have saved a precommit to its snapshot and been stopped before sending
# it; booted again, it decides that height from the snapshot's votes and
# moves on, and catch-up takes f + 1 matching blocks (consensus.soma), which
# one node ahead can't give two behind: with exactly a quorum up, the chain
# would stop. That is the binary's protocol, not the image's.
boot 2
"$BIN" node "$t/grok" --listen "$gw" --max-llm-calls 0 > "$t/grok/node.log" 2>&1 &
pids="$pids $!"
wait_height claude $((before + 2)) 120
python3 "$t/files.py" "$t/disk.img" signed.log > "$t/signed2"
head -c "$(wc -c < "$t/signed1")" "$t/signed2" | cmp -s - "$t/signed1" || { echo 'FAIL signed.log changed across the restart'; exit 1; }
# the image keeps up: its disk gets the blocks claude has, the same ones
n=0
until python3 "$t/files.py" "$t/disk.img" blocks.log > "$t/muse-blocks2"; k2=$(wc -l < "$t/muse-blocks2" | tr -d ' '); [ "$k2" -ge $((before + 1)) ]; do
  sleep 1; n=$((n + 1)); [ $n -lt 60 ] || { echo "FAIL the image's disk has $k2 blocks after its restart, claude has $(height claude)"; exit 1; }
done
head -n "$k2" "$t/claude/blocks.log" | cmp -s - "$t/muse-blocks2" || { echo 'FAIL the image and claude disagree on a block after the restart'; exit 1; }
echo "ok booted again on the same disk: signed.log kept, the chain moved on from $before to $(height claude) in $waited s, and the image has $k2 of its blocks"
echo 'PASS a node ran as a MirageOS unikernel among binaries, and booted again'
