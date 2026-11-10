#!/bin/sh
# The Docker CI path (docs/SECURITY-REVIEW-2.md P-3): a Soma build with an
# OCaml module, run the way the node runs a check (read-only root, nobody's
# uid, no network) through this checkout's deploy/pantheon-ci.sh, passes
# without asking opam what the switch has, and opam's log goes to /tmp.
#
#   test/docker-ci.sh                 needs the CI image pantheon:dev (deploy/Dockerfile)
#   DOCKER="sudo docker" test/docker-ci.sh
#
# It skips when there's no Docker or no image. SOMA_EXAMPLE is Soma's
# examples/example_projects/ocaml_succ (default: next to this checkout, or
# in the image's Soma).
set -eu
here=$(cd "$(dirname "$0")/.." && pwd)
D=${DOCKER:-docker}
IMAGE=${CI_IMAGE:-pantheon:dev}
$D image inspect "$IMAGE" >/dev/null 2>&1 || { echo "SKIP: no $IMAGE in $D"; exit 0; }
t=$(mktemp -d /tmp/pantheon-checkXXXXXX); trap 'rm -rf "$t"' EXIT
fail() { echo "FAIL: $*"; exit 1; }
ex=${SOMA_EXAMPLE:-$here/../soma/examples/example_projects/ocaml_succ}
if [ -d "$ex" ]; then cp -R "$ex/." "$t/"
else $D run --rm --entrypoint sh "$IMAGE" -c 'tar -C /home/pantheon/soma/examples/example_projects/ocaml_succ -c .' | tar -x -C "$t"; fi
[ -f "$t/main.soma" ] || fail "no ocaml_succ example"
chmod -R a+rX "$t"
# an opam on the PATH that says when it's asked to list, then does it
cmd='mkdir -p /tmp/bin && printf "#!/bin/sh\necho \"\$*\" >> /tmp/opam-calls\nexec /usr/bin/opam \"\$@\"\n" > /tmp/bin/opam && chmod +x /tmp/bin/opam && export PATH=/tmp/bin:$PATH && soma build main.soma && ./main.exe && echo "listed: $(grep -c "^list" /tmp/opam-calls 2>/dev/null || echo 0)" && echo "logs: $(ls -d $OPAMLOGS 2>/dev/null)"'
out=$($D run --rm --name "pantheon-ci-$(od -An -N4 -tx1 /dev/urandom | tr -d ' \n')" --network=none --read-only --tmpfs /tmp:exec,size=1536m \
  --cap-drop=ALL --security-opt=no-new-privileges --pids-limit=512 --memory=1536m --memory-swap=1536m --user=65534:65534 \
  -e HOME=/tmp -v "$t:/work:ro" -v "$here/deploy/pantheon-ci.sh:/usr/local/bin/pantheon-ci:ro" -w /work "$IMAGE" \
  sh -c "pantheon-ci '$cmd'" 2>&1) || fail "the check failed: $(echo "$out" | tail -5)"
echo "$out" | grep -qx '1 42' || fail "the program didn't run: $(echo "$out" | tail -5)"
echo "ok a Soma build with an OCaml module passes in the read-only CI container"
echo "$out" | grep -qx 'listed: 0' || fail "soma asked opam what the switch has: $(echo "$out" | grep listed)"
echo "ok it used the image's record of the switch, without asking opam"
echo "$out" | grep -qx 'logs: /tmp/opam-logs' || fail "opam's log isn't in /tmp: $(echo "$out" | grep logs)"
echo "ok opam's log is in /tmp"
echo PASS
