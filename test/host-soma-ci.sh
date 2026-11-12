#!/bin/sh
# Soma's CI on a host (scripts/host.sh): a node whose scope has Soma (no
# "soma" in EXCLUDE) gets --ci-repo soma with Soma's build, the misc tests a
# bid adds or changes (by hash against SOMA_DIR's commit) and the host's
# Pantheon built with the bid's Soma, read at /pantheon in ci-sandbox; a host
# that excludes Soma gets none, and its check refuses a Soma checkout. A
# check picks Soma's CI for a Soma checkout and Pantheon's otherwise.
# No node, no sandbox: the functions, from scripts/host.sh as it is.
set -eu
here=$(cd "$(dirname "$0")/.." && pwd)
t=$(mktemp -d); trap 'rm -rf "$t"' EXIT
fail() { echo "FAIL: $*"; exit 1; }
ok() { echo "ok $*"; }

sed -n '/^soma_ci_cmd() {/,/^}/p; /^soma_ci_flag() {/p; /^ci_for_checkout() {/p; /^excludes_soma() {/p; /^q() {/p' "$here/scripts/host.sh" > "$t/fns.sh"
for f in soma_ci_cmd soma_ci_flag ci_for_checkout excludes_soma; do grep -q "^$f()" "$t/fns.sh" || fail "scripts/host.sh has no $f"; done
die() { echo "die: $*" >&2; exit 1; }
. "$t/fns.sh"

# a Soma checkout with one misc test, as SOMA_DIR
SOMA=$t/soma; mkdir -p "$SOMA/test-suite/misc"
echo 'echo hi' > "$SOMA/test-suite/misc/soma_hi.sh"; echo x > "$SOMA/GRADUAL.md"
git -C "$SOMA" init -q; git -C "$SOMA" add -A
git -C "$SOMA" -c user.name=t -c user.email=t@t -c commit.gpgsign=false commit -qm s
h=$(git -C "$SOMA" rev-parse HEAD:test-suite/misc/soma_hi.sh)

c=$(soma_ci_cmd)
case $c in *"SOMA_MISC_BASELINE='test-suite/misc/soma_hi.sh:$h "*) ;; *) fail "no baseline for the misc test: $c" ;; esac
for w in 'dune build -j 2 soma-runtime.install soma-core.install' 'sh /pantheon/scripts/soma-misc-tests --changed' 'cp -R /pantheon/. /tmp/downstream' 'soma build main.soma'; do
  case $c in *"$w"*) ;; *) fail "Soma's CI lacks: $w" ;; esac
done
ok "Soma's CI builds Soma, runs the misc tests a bid changes, then builds the host's Pantheon from /pantheon"

[ -f "$here/scripts/soma-misc-tests" ] || fail "no scripts/soma-misc-tests for /pantheon/scripts/soma-misc-tests"
grep -q -- '--ro-bind-try "$pantheon" /pantheon' "$here/deploy/host/ci-sandbox" || fail "ci-sandbox doesn't bind CI_PANTHEON at /pantheon"
grep -q 'Environment=CI_PANTHEON=' "$here/scripts/host.sh" || fail "the node units don't set CI_PANTHEON"
ok "ci-sandbox reads CI_PANTHEON at /pantheon, and the node units set it"

governs_soma() { true; }
EXCLUDE=""
f=$(soma_ci_flag)
case $f in "--ci-repo soma '"*) ;; *) fail "a host with Soma in scope gets no --ci-repo soma: $f" ;; esac
EXCLUDE="soma"
[ -z "$(soma_ci_flag)" ] || fail "a host that excludes Soma got Soma's CI"
EXCLUDE=""; governs_soma() { false; }
[ -z "$(soma_ci_flag)" ] || fail "a network without Soma got Soma's CI"
ok "only a host whose scope has Soma, in a network that governs it, runs Soma's CI"

governs_soma() { true; }
rm "$SOMA/test-suite/misc/soma_hi.sh"; git -C "$SOMA" rm -q test-suite/misc/soma_hi.sh
git -C "$SOMA" -c user.name=t -c user.email=t@t -c commit.gpgsign=false commit -qm none
soma_ci_flag >/dev/null 2>"$t/err" && fail "Soma's CI with no misc tests to compare against passed"
grep -q 'soma_\*.sh' "$t/err" || fail "no misc tests: $(cat "$t/err")"
ok "no misc tests to compare against stops start, with why"

git -C "$SOMA" checkout -q HEAD~1
CI_CMD='pantheon ci'
mkdir -p "$t/p"; echo x > "$t/p/main.soma"
[ "$(ci_for_checkout "$t/p")" = 'pantheon ci' ] || fail "a Pantheon checkout got $(ci_for_checkout "$t/p")"
case $(ci_for_checkout "$SOMA") in *'soma-misc-tests'*) ;; *) fail "a Soma checkout didn't get Soma's CI" ;; esac
ok "a check runs Soma's CI on a Soma checkout and Pantheon's on Pantheon's"

# host.sh check on a Soma checkout, on a host that excludes Soma: refused
out=$(PANTHEON_HOST="$t/h" EXCLUDE=soma REMOTE= BRANCH=master sh "$here/scripts/host.sh" check "$SOMA" 2>&1) && fail "check ran on Soma's checkout with Soma excluded"
case $out in *"outside this host's scope"*) ;; *) fail "check with Soma excluded: $out" ;; esac
ok "a host that excludes Soma refuses to check a Soma checkout"
