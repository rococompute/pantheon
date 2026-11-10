#!/bin/sh
# deploy/host/ci-sandbox, on Linux with bwrap and a user systemd (it skips
# elsewhere): a check sees only the /etc files a build reads (P-12), never the
# host-wide CI lock's descriptor (P-15), and dies with ci-sandbox when the
# node kills it, freeing the lock; one check at a time.
set -eu
here=$(cd "$(dirname "$0")/.." && pwd)
sb=$here/deploy/host/ci-sandbox
for c in bwrap setpriv systemd-run flock; do
  command -v "$c" >/dev/null || { echo "SKIP: no $c (ci-sandbox is for a Linux host)"; exit 0; }
done
systemctl --user is-system-running >/dev/null 2>&1 || [ "$(systemctl --user is-system-running 2>/dev/null)" = degraded ] \
  || { echo "SKIP: no user systemd"; exit 0; }
t=$(mktemp -d); trap 'rm -rf "$t"' EXIT
fail() { echo "FAIL: $*"; exit 1; }
ok() { echo "ok $*"; }
# what ci-sandbox wants of a host, as stand-ins: Soma's soma, opam, the switch
mkdir -p "$t/soma/_build/install/default/bin" "$t/opam/log" "$t/switch" "$t/work"
printf '#!/bin/sh\necho soma\n' > "$t/soma/_build/install/default/bin/soma"; chmod +x "$t/soma/_build/install/default/bin/soma"
echo hi > "$t/work/f"
run() { HOME=$t/home SOMA_DIR=$t/soma CI_LOCK=$t/lock sh "$sb" 256m "$t/work" "$1"; }
mkdir -p "$t/home/.cache/soma"; ln -s "$t/opam" "$t/home/.opam"; ln -s "$t/switch" "$t/home/.cache/soma/ocaml"

out=$(run 'cat f; ls /etc | tr "\n" " "; test -e /etc/shadow && echo SHADOW; test -e /etc/hostname && echo HOSTNAME; true')
case $out in hi*) ;; *) fail "the check didn't run on the checkout: $out" ;; esac
case $out in *passwd*) ;; *) fail "no /etc/passwd in the check: $out" ;; esac
case $out in *SHADOW*|*HOSTNAME*) fail "the host's /etc is in the check: $out" ;; esac
ok "a check sees only the /etc files a build reads ($(echo "$out" | sed -n 2p | cut -c1-80))"

out=$(run 'if [ -e /proc/self/fd/9 ]; then echo HAS9; else echo NO9; fi; flock -u 9 2>&1 || true')
case $out in NO9*) ;; *) fail "the check has the lock's descriptor: $out" ;; esac
ok "a check doesn't get the CI lock's descriptor"

run 'sleep 3' >/dev/null & first=$!
sleep 1
flock -n "$t/lock" true 2>/dev/null && fail "the lock isn't held while a check runs"
start=$(date +%s); run 'true' >/dev/null; waited=$(( $(date +%s) - start ))
wait $first
[ "$waited" -ge 1 ] || fail "a second check didn't wait for the first (waited ${waited}s)"
ok "one check at a time: the second waited ${waited}s"

marker=$((300 + $$ % 600))
# started directly, so $! is ci-sandbox itself, as the node starts it
HOME=$t/home SOMA_DIR=$t/soma CI_LOCK=$t/lock sh "$sb" 256m "$t/work" "sleep $marker" >/dev/null & pid=$!
sleep 2
pgrep -f "sleep $marker" >/dev/null || fail "the check didn't start"
kill -9 $pid; wait $pid 2>/dev/null || true
sleep 2
pgrep -f "sleep $marker" >/dev/null && { pkill -f "sleep $marker"; fail "the check outlived ci-sandbox's SIGKILL"; }
flock -n "$t/lock" true || fail "the lock stayed held after the kill"
ok "a check killed through ci-sandbox dies, and the lock is free"

out=$(run 'exit 3' 2>&1) && fail "a failing check passed" || r=$?
[ "$r" = 3 ] || fail "a check's exit status 3 came back as $r"
ok "a check's exit status comes back"
echo PASS
