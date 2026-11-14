#!/bin/sh
# A unikernel node with its service (U-1): the image runs no processes and
# has no checkouts, so `pantheon service HOME HOST:PORT` does that for it
# on the host, with the node's own runtime, and the image asks it for git,
# model calls, CI and checks, their jobs and the events they give
# (nodeio.soma's service_op, node.soma's service_tick_prog). Three binary
# nodes and the image, all up, with a fake model (a cmd: backend, as
# test/e2e.sh's model scenario has): it drafts tasks, writes patches in
# the checkout it's given with `pantheon edits`, reviews bids and approves.
# The market merges work, and the image takes part: its model calls ran
# on the service (muse's copy of the model logs them), its bids and
# attests are in the blocks (an attest follows a check, a job on the
# service too), and its service's checkout is at the binaries' commit.
#
# Needs what test/node-image.sh needs; without it, it says so and passes.
set -eu
cd "$(dirname "$0")/.."
SWITCH=${SOMA_MIRAGE_SWITCH:-hvf}
if ! opam exec --switch="$SWITCH" -- sh -c 'command -v solo5-hvt && command -v solo5-vmnet' >/dev/null 2>&1; then
  echo "SKIP no solo5-hvt and solo5-vmnet in opam switch $SWITCH (Soma's MirageOS switch)"; exit 0
fi
BIN=$PWD/main.exe
[ -x "$BIN" ] || { echo "no main.exe: run soma build main.soma"; exit 1; }
t=$(mktemp -d "${TMPDIR:-/tmp}/pantheon-node-image-service.XXXXXX")
src=test/node_image_service_$$.soma
hvt=test/node_image_service_$$.hvt
pids=""
cleanup() {
  for p in $pids; do kill "$p" 2>/dev/null || true; done
  pkill -f "solo5-hvt .*$hvt" 2>/dev/null || true
  if [ -n "${KEEP:-}" ]; then echo "kept $t"; rm -f "$src" "$hvt"; else rm -rf "$t" "$src" "$hvt"; fi
}
trap cleanup EXIT HUP INT TERM

gw=$(ifconfig 2>/dev/null | awk '/^bridge/ {b=1; next} /^[a-z]/ {b=0} b && /inet / {print $2}' | grep -v '^127\.' | head -1)
gw=${gw:-192.168.105.1}
ip=${gw%.*}.234
port=39980
service=$gw:39990

mkdir -p "$t/src" "$t/net/parts" && cp -R examples/calc/. "$t/src/"
(cd "$t/src" && git init -q . && git add -A && git -c user.name=t -c user.email=t@t -c commit.gpgsign=false commit -qm genesis)
commit=$(git -C "$t/src" rev-parse HEAD)
printf '{"block_ms":200,"params":{"term_blocks":"30","max_merges":"1","bid_cooldown":"2"},"repos":[{"name":"calc","url":"%s","commit":"%s"}]}\n' "$t/src" "$commit" > "$t/net/network.json"
printf -- '- add a hello command\n' > "$t/goal.txt"
# the fake model: a reply for each kind of prompt; a bidder edits the
# checkout its job runs in and replies with its edits
cat > "$t/model.sh" <<'F'
#!/bin/sh
p=$(cat)
[ -n "${MODEL_LOG:-}" ] && echo "$(printf '%s' "$p" | head -c 60 | tr '\n' ' ')" >> "$MODEL_LOG"
case "$p" in
  *"choosing the next task"*) echo '{"task": "add a hello command", "repo": "calc", "context": ["calc.sh"]}' ;;
  *"writing a patch"*)
    cd "$PANTHEON_WORKTREE" || exit 1
    n=$(ls hello*.sh 2>/dev/null | wc -l | tr -d ' ')
    printf 'echo hello %s\n' "$n" > "hello$n.sh"
    "$PANTHEON_BIN" edits . "hello command $n" ;;
  *"reviewing the bids"*)
    n=$(printf '%s' "$p" | sed -n 's/^Bid \([0-9]*\) by.*/\1/p' | head -1)
    echo "{\"merge\": ${n:-0}, \"reject\": [], \"done\": false}" ;;
  *"proposed merge is safe"*) echo '{"approve": true, "reason": "fine"}' ;;
esac
F
# muse's copy says where it ran: the image runs no processes, so its
# model calls are the service's
sed 's|^p=$(cat)$|p=$(cat); MODEL_LOG='"$t"'/muse-model.log|' "$t/model.sh" > "$t/model-muse.sh"
chmod +x "$t/model.sh" "$t/model-muse.sh"
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
flags="--goal $t/goal.txt --bid-window 6"

"$BIN" image "$t/muse" "$src" --service "$service" $flags --backend "cmd:$t/model-muse.sh" > "$t/image.log" 2>&1 || { cat "$t/image.log"; echo 'FAIL pantheon image'; exit 1; }
grep -q "run_node_image_at node_config \"$service\"" "$src" || { echo 'FAIL the image source names no service'; exit 1; }
if ! SOMA_MIRAGE_SWITCH="$SWITCH" soma build "$src" > "$t/build.log" 2>&1; then tail -30 "$t/build.log"; echo 'FAIL the image does not build'; exit 1; fi
[ -f "$hvt" ] || { tail -20 "$t/build.log"; echo "FAIL no $hvt"; exit 1; }
echo "ok pantheon image wrote muse's node with its service at $service, and soma build made the image"

# the service: muse's runtime on the host (its peer listener on localhost,
# which no peer dials: the image is muse on the network)
"$BIN" service "$t/muse" "$service" --listen 127.0.0.1 $flags --backend "cmd:$t/model-muse.sh" > "$t/service.log" 2>&1 &
pids="$pids $!"
n=0
until grep -q 'service listening on' "$t/service.log"; do
  sleep 1; n=$((n + 1)); [ $n -lt 15 ] || { cat "$t/service.log"; echo 'FAIL the service did not start'; exit 1; }
done
echo "ok the service listens at $service"

truncate -s 64M "$t/disk.img"
opam exec --switch="$SWITCH" -- solo5-vmnet -- solo5-hvt --mem=512 --block:storage="$t/disk.img" -- \
  "$hvt" --ipv4="$ip/24" --ipv4-gateway="$gw" > "$t/boot.log" 2>&1 &
pids="$pids $!"
n=0
until grep -q 'muse listening; port' "$t/boot.log"; do
  sleep 1; n=$((n + 1)); [ $n -lt 30 ] || { tail -20 "$t/boot.log"; echo 'FAIL the image did not start'; exit 1; }
done
for a in claude codex grok; do
  "$BIN" node "$t/$a" --listen "$gw" $flags --backend "cmd:$t/model.sh" > "$t/$a/node.log" 2>&1 &
  pids="$pids $!"
done

merged() { n=$(grep -c '\[merged\]' "$t/$1/status.txt" 2>/dev/null); echo "${n:-0}"; }
# txs the image signed, of a kind, in claude's blocks
signed_by_muse() { grep -o "{\\\\\"agent\\\\\":\\\\\"muse\\\\\",[^}]*\\\\\"fields\\\\\":\[\\\\\"$1\\\\\"" "$t/claude/blocks.log" 2>/dev/null | wc -l | tr -d ' '; }
n=0
until [ "$(merged claude)" -ge 3 ] && [ "$(signed_by_muse bid)" -ge 1 ] && [ "$(signed_by_muse attest)" -ge 1 ]; do
  sleep 1; n=$((n + 1))
  if [ $n -ge 240 ]; then
    echo "--- muse (image)"; grep -hv 'Solo5\|INFO\|^ \|___\|alive' "$t/boot.log" | tail -15
    echo "--- service"; tail -8 "$t/service.log"
    echo "--- claude"; tail -8 "$t/claude/node.log"; cat "$t/claude/status.txt"
    echo "FAIL in 240 s: claude has $(merged claude) merges, the image signed $(signed_by_muse bid) bids and $(signed_by_muse attest) attests"; exit 1
  fi
done
calls=$(wc -l < "$t/muse-model.log" 2>/dev/null | tr -d ' ')
[ "${calls:-0}" -ge 2 ] || { echo "FAIL muse's model ran ${calls:-0} times on the service"; exit 1; }
echo "ok the market merged $(merged claude) times in $n s, with $(signed_by_muse bid) bids and $(signed_by_muse attest) attests from the image, and its model ran $calls times on the service"

# the service's checkout, where the image's merges went, is the binaries'
# (merges commit the same way everywhere; one may be a merge ahead)
want=$(git -C "$t/claude/repos/calc" rev-parse HEAD)
n=0
until got=$(git -C "$t/muse/repos/calc" rev-parse HEAD); [ "$got" = "$want" ] || [ "$(git -C "$t/claude/repos/calc" rev-parse -q --verify "$want^1")" = "$got" ] || [ "$(git -C "$t/muse/repos/calc" rev-parse -q --verify "$got^1")" = "$want" ]; do
  sleep 1; n=$((n + 1)); [ $n -lt 30 ] || { echo "FAIL the service's checkout is at $got, claude's at $want"; exit 1; }
done
[ "$(git -C "$t/muse/repos/calc" rev-list --count HEAD)" -ge 3 ] || { echo 'FAIL no merges in the service checkout'; exit 1; }
echo "ok the image's merges are in its service's checkout: calc at $(git -C "$t/muse/repos/calc" rev-parse --short HEAD), as claude's"
echo 'PASS a unikernel node bid, checked and merged through its service'
