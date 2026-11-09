#!/bin/sh
# Exercise the actual self-contained command used by both deployments.
set -eu
here=$(cd "$(dirname "$0")/.." && pwd)
t=$(mktemp -d)
trap 'rm -rf "$t"' EXIT HUP INT TERM
mkdir -p "$t/head/test" "$t/head/deploy"
printf 'p := 1.\n' > "$t/head/main.soma"
printf 'Lemma good : True. Proof. exact I. Qed.\n' > "$t/head/main.proof"
printf '#!/bin/sh\ntest -f main.soma\n' > "$t/head/test/check.sh"
cp "$here/deploy/ci-command.py" "$t/head/deploy/ci-command.py"
python3 "$here/deploy/ci-command.py" "$t/head" 'sh test/check.sh' > "$t/command"
run() { (cd "$t/bid" && sh "$t/command"); }
reset() { rm -rf "$t/bid"; cp -R "$t/head" "$t/bid"; }
refuse() { if run > "$t/output" 2>&1; then echo "FAIL accepted $1"; exit 1; fi; grep -q 'CI policy:' "$t/output"; echo "ok refuses $1"; }
for assumption in 'Lemma hole : False. Admitted.' 'Axiom hole : False.' 'hole : False := unk.'; do
  reset
  case "$assumption" in Lemma*) file=main.proof ;; *) file=main.soma ;; esac
  printf '%s\n' "$assumption" >> "$t/bid/$file"
  refuse "$assumption"
done
reset
printf '#!/bin/sh\nexit 0\n' > "$t/bid/test/check.sh"
refuse 'weakened test'
reset
printf 'exit 0\n' > "$t/bid/deploy/ci-command.py"
printf 'hole := unk.\n' >> "$t/bid/main.soma"
refuse 'replaced policy'
reset
printf 'q := 2. (* Admitted, Axiom and unk in a comment are harmless. *)\n' >> "$t/bid/main.soma"
run
echo 'ok accepts honest change'
# Existing escape hatches do not license a new assumption of the same count.
printf 'old := unk.\n' >> "$t/head/main.soma"
python3 "$here/deploy/ci-command.py" "$t/head" 'sh test/check.sh' > "$t/command"
reset
run
sed 's/old := unk/new := unk/' "$t/bid/main.soma" > "$t/main.soma.new" && mv "$t/main.soma.new" "$t/bid/main.soma"  # not sed -i: BSD's differs
refuse 'traded existing assumption'
