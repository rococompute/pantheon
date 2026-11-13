#!/bin/sh
# A node as a MirageOS unikernel (U-1): `pantheon image` writes a node's
# setup into a Soma program (node_sandbox.soma's run_node_image), soma build
# makes the image, and solo5-hvt boots it with a storage device. Checked:
# it starts, its event loop runs (round timeouts sign votes into
# signed.log, the status file is written, the consensus snapshot saved),
# and booted again on the same disk it reads them back, and its votes are
# the same, as the binary's restart is. Its peers are absent: a unikernel
# node in a network of binaries is the next step.
#
# Needs Soma's MirageOS switch (SOMA_MIRAGE_SWITCH, default hvf) with
# solo5-hvt, as Soma's dev/mirage-check.sh does; without it the test says
# so and passes.
set -eu
cd "$(dirname "$0")/.."
SWITCH=${SOMA_MIRAGE_SWITCH:-hvf}
if ! opam exec --switch="$SWITCH" -- sh -c 'command -v solo5-hvt' >/dev/null 2>&1; then
  echo "SKIP no solo5-hvt in opam switch $SWITCH (Soma's MirageOS switch)"; exit 0
fi
BIN=$PWD/main.exe
[ -x "$BIN" ] || { echo "no main.exe: run soma build main.soma"; exit 1; }
t=$(mktemp -d "${TMPDIR:-/tmp}/pantheon-node-image.XXXXXX")
# the image's source goes in the checkout, so its imports resolve
src=test/node_image_$$.soma
trap 'rm -rf "$t" "$src" "test/node_image_$$.hvt"' EXIT HUP INT TERM
mkdir -p "$t/src" && cp -R examples/calc/. "$t/src/"
(cd "$t/src" && git init -q . && git add -A && git -c user.name=t -c user.email=t@t -c commit.gpgsign=false commit -qm genesis)
"$BIN" init "$t/net" --repo "calc=$t/src" --base-port 39960 --block-ms 200 > "$t/init.log" 2>&1 || { cat "$t/init.log"; exit 1; }
"$BIN" image "$t/net/claude" "$src" > "$t/image.log" 2>&1 || { cat "$t/image.log"; echo 'FAIL pantheon image'; exit 1; }
grep -q 'node_config' "$src" || { echo 'FAIL no config in the image source'; exit 1; }
if ! SOMA_MIRAGE_SWITCH="$SWITCH" soma build "$src" > "$t/build.log" 2>&1; then tail -30 "$t/build.log"; echo 'FAIL the image does not build'; exit 1; fi
hvt=test/node_image_$$.hvt
[ -f "$hvt" ] || { tail -20 "$t/build.log"; echo "FAIL no $hvt"; exit 1; }
echo 'ok pantheon image wrote the node, and soma build made its MirageOS image'

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

boot() {
  # the node never ends: it is stopped after $1 seconds
  timeout "$1" opam exec --switch="$SWITCH" -- solo5-hvt --mem=512 --block:storage="$t/disk.img" -- "$hvt" > "$t/boot$2.log" 2>&1 || true
}
truncate -s 64M "$t/disk.img"
boot 25 1
grep -qi 'error\|exception\|malformed\|did not start' "$t/boot1.log" && { tail -20 "$t/boot1.log"; echo 'FAIL the node did not run'; exit 1; }
files=$(python3 "$t/files.py" "$t/disk.img")
for f in status.txt signed.log consensus.state; do
  case " $files " in *" $f "*) ;; *) tail -20 "$t/boot1.log"; echo "FAIL no $f on the disk (has: $files)"; exit 1;; esac
done
python3 "$t/files.py" "$t/disk.img" status.txt > "$t/status1"
grep -q '^height ' "$t/status1" || { cat "$t/status1"; echo 'FAIL the status has no height'; exit 1; }
# node.soma's snapshot_text: framed fields, the first its header
python3 "$t/files.py" "$t/disk.img" consensus.state | head -c 40 | grep -q 'pantheon-consensus 1' || { echo 'FAIL the snapshot is not node.soma'"'"'s snapshot_text'; exit 1; }
python3 "$t/files.py" "$t/disk.img" signed.log > "$t/signed1"
[ -s "$t/signed1" ] || { echo 'FAIL no vote signed'; exit 1; }
echo "ok booted: the status is written, $(wc -l < "$t/signed1" | tr -d ' ') votes signed into signed.log, the snapshot saved"

boot 15 2
grep -qi 'error\|exception\|malformed\|did not start' "$t/boot2.log" && { tail -20 "$t/boot2.log"; echo 'FAIL the node did not start again'; exit 1; }
python3 "$t/files.py" "$t/disk.img" signed.log > "$t/signed2"
# what was signed before the restart is kept, byte for byte, and added to
head -c "$(wc -c < "$t/signed1")" "$t/signed2" | cmp -s - "$t/signed1" || { echo 'FAIL signed.log changed across the restart'; exit 1; }
echo 'ok booted again on the same disk: signed.log read back and kept'
echo 'PASS a node booted as a MirageOS unikernel, and booted again'
