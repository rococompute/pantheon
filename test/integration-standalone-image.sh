#!/bin/sh
# integrations/standalone/pantheon-standalone with a unikernel node: init
# --image muse puts muse on the vmnet network; up builds its image (its
# source and image the owner's alone: they hold its key), starts its service
# and boots it under solo5-vmnet with egress to the host only (--allow,
# so no internet), beside three binary nodes. Muse's
# agent runs in a "container" (test/integration-standalone.sh's stub of
# docker) and answers over HTTP; its node asks through the service, which
# runs muse's inbox backend on the host. The market merges, with muse's bids
# or attests in the blocks; status reads muse's chain from its disk; down
# stops the image, its service, the nodes and the container.
#
# Needs what test/node-image.sh needs (Soma's MirageOS switch with solo5-hvt
# and solo5-vmnet, macOS 26 or later); without it, it says so and passes.
set -eu
cd "$(dirname "$0")/.."
here=$PWD
SWITCH=${SOMA_MIRAGE_SWITCH:-hvf}
if ! opam exec --switch="$SWITCH" -- sh -c 'command -v solo5-hvt && command -v solo5-vmnet' >/dev/null 2>&1; then
  echo "SKIP no solo5-hvt and solo5-vmnet in opam switch $SWITCH (Soma's MirageOS switch)"; exit 0
fi
# macOS's shared vmnet network, as pantheon-standalone finds it
gw=${PANTHEON_VMNET_GATEWAY:-$(defaults read /Library/Preferences/SystemConfiguration/com.apple.vmnet Shared_Net_Address 2>/dev/null || true)}
[ -n "$gw" ] || gw=$(ifconfig 2>/dev/null | awk '/^bridge/ {b=1; next} /^[a-z]/ {b=0} b && /inet / {print $2}' | grep -v '^127\.' | head -1)
gw=${gw:-192.168.64.1}
BIN=$here/main.exe
[ -x "$BIN" ] || { echo "no main.exe: run soma build main.soma"; exit 1; }
S=$here/integrations/standalone/pantheon-standalone
t=$(mktemp -d "${TMPDIR:-/tmp}/pantheon-standalone-image.XXXXXX")
NET=$t/net
cleanup() {
  [ -d "$NET/.standalone" ] && PANTHEON=$BIN DOCKER=$t/bin/docker STUB_DIR=$t "$S" down "$NET" >/dev/null 2>&1 || true
  rm -f "$here"/integrations/standalone/images/standalone_"$id"_muse.*
  if [ -n "${KEEP:-}" ]; then echo "kept $t"; else rm -rf "$t"; fi
}
id=""
trap cleanup EXIT HUP INT TERM
fail() { echo "FAIL: $*"; for f in "$NET/.standalone/muse/boot.log" "$NET/.standalone/muse/service.log" "$NET/claude/node.log"; do [ -f "$f" ] && { echo "--- $f"; grep -v 'Solo5\|^ \|___' "$f" | tail -12; }; done; exit 1; }
mkdir -p "$t/bin"
# the stub of docker and the fake agent, as test/integration-standalone.sh has them
sed -n "/^cat > \"\$t\/bin\/docker\" <<'STUB'$/,/^STUB$/p" test/integration-standalone.sh | sed '1d;$d' > "$t/bin/docker"
sed -n "/^cat > \"\$t\/agent-cli\" <<'F'$/,/^F$/p" test/integration-standalone.sh | sed '1d;$d' > "$t/agent-cli"
chmod +x "$t/bin/docker" "$t/agent-cli"
[ -s "$t/bin/docker" ] && [ -s "$t/agent-cli" ] || fail "couldn't take the stub and the fake agent from test/integration-standalone.sh"
# the binaries' model: test/node-image-service.sh's, a reply for each kind of prompt
cat > "$t/model.sh" <<'F'
#!/bin/sh
p=$(cat)
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
chmod +x "$t/model.sh"

mkdir -p "$t/src" && cp -R examples/calc/. "$t/src/"
(cd "$t/src" && git init -q . && git add -A && git -c user.name=t -c user.email=t@t -c commit.gpgsign=false commit -qm genesis)
printf -- '- add a hello command\n' > "$t/goal.txt"
port=$((39700 + $$ % 50 * 5))
inbox=$((38800 + $$ % 400))
export PANTHEON=$BIN DOCKER=$t/bin/docker STUB_DIR=$t DIPLOMAT_CLI=$t/agent-cli AGENT_PAUSE=1

"$S" init "$NET" --repo calc="$t/src" --image muse --base-port "$port" --block-ms 200 \
  --param term_blocks=30 --param max_merges=1 --param bid_cooldown=2 > "$t/init.out" 2>&1 || { cat "$t/init.out"; fail "init"; }
grep -q "\"${gw%.*}\.203:$((port + 3))\"" "$NET/muse/genesis.json" \
  || fail "muse's genesis address isn't on the vmnet network: $(grep -o '"addr":"[^"]*"' "$NET/muse/genesis.json")"
grep -q "\"$gw:$port\"" "$NET/muse/genesis.json" || fail "claude's address isn't the host's on the vmnet network"
echo "ok init put muse on the vmnet network and the binaries at the host's address there"
id=$(printf '%s' "$(cd "$NET" && pwd)" | cksum | awk '{print $1}')

m=cmd:$t/model.sh
if ! "$S" up "$NET" --docker muse --backends "claude=$m,codex=$m,grok=$m" --inbox "127.0.0.1:$inbox" \
  --docker-url "http://127.0.0.1:$inbox" --pass-env AGENT_PAUSE -- --goal "$t/goal.txt" --bid-window 6 > "$t/up.out" 2>&1; then
  cat "$t/up.out"; fail "up"
fi
grep -i 'unikernel' "$t/up.out" || true
src=$here/integrations/standalone/images/standalone_${id}_muse.soma
[ "$(ls -l "$src" | cut -c1-10)" = "-rw-------" ] || fail "muse's image source (it holds its key) isn't private: $(ls -l "$src")"
[ "$(ls -l "${src%.soma}.hvt" | cut -c1-10)" = "-rw-------" ] || fail "muse's image isn't private"
pgrep -f "solo5-vmnet --allow=$gw/32 -- .*standalone_${id}_muse" >/dev/null || fail "muse's unikernel runs without its egress policy: $(pgrep -fl "solo5-vmnet.*standalone_${id}_muse")"
echo "ok up booted muse as a unikernel with egress to the host only; its source and image are private"

merged() { n=$(grep -c '\[merged\]' "$NET/claude/status.txt" 2>/dev/null); echo "${n:-0}"; }
signed_by_muse() { grep -o "{\\\\\"agent\\\\\":\\\\\"muse\\\\\",[^}]*\\\\\"fields\\\\\":\[\\\\\"$1\\\\\"" "$NET/claude/blocks.log" 2>/dev/null | wc -l | tr -d ' '; }
n=0
until [ "$(merged)" -ge 2 ] && [ "$(( $(signed_by_muse bid) + $(signed_by_muse attest) ))" -ge 1 ]; do
  sleep 1; n=$((n + 1))
  [ $n -lt 300 ] || fail "in 300 s: $(merged) merges, muse signed $(signed_by_muse bid) bids and $(signed_by_muse attest) attests"
done
echo "ok the market merged $(merged) times in $n s, with $(signed_by_muse bid) bids and $(signed_by_muse attest) attests from the unikernel, its agent in a container"
grep -q . "$t"/home-pantheon-*-muse/agent.log || fail "muse's container got no request"

"$S" status "$NET" > "$t/status.out"
grep -q 'muse .*h[0-9].*unikernel, up.*agent in container' "$t/status.out" || { cat "$t/status.out"; fail "status doesn't read muse's chain from its disk"; }
echo "ok status reads muse's chain from its disk"

"$S" down "$NET" > "$t/down.out" 2>&1 || { cat "$t/down.out"; fail "down"; }
sleep 1
pgrep -f "solo5-hvt .*standalone_${id}_muse" >/dev/null && fail "the unikernel outlived down"
pgrep -f -- "service $NET/" >/dev/null && fail "the service outlived down"
pgrep -f -- "node $NET/" >/dev/null && fail "a node outlived down"
echo "ok down stopped the unikernel, its service, the nodes and the container"
echo 'PASS pantheon-standalone: a unikernel node among binaries, its agent in a container'
