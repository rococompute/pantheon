#!/bin/bash
# The edit engine on its own: a checkout's changes become edits
# (`pantheon edits`), the edits replayed on a fresh clone (`pantheon
# apply-edits`) give the same tree, and the unsafe cases are refused.
#
#   test/edits.sh
#
# Needs main.exe (soma build main.soma), git and jq.
set -u
cd "$(dirname "$0")/.."
BIN=$PWD/main.exe
[ -x "$BIN" ] || { echo "no main.exe: run soma build main.soma"; exit 1; }
T=$(mktemp -d "${TMPDIR:-/tmp}/pantheon-edits.XXXXXX")
trap 'rm -rf "$T"' EXIT
fails=0
fail() { echo "FAIL $*"; fails=$((fails + 1)); }
ok() { echo "ok $*"; }
g() { git -c user.name=t -c user.email=t@t -c commit.gpgsign=false "$@"; }
tree_of() { (cd "$1" && git add -A -f >/dev/null && git write-tree); }

# a repository with a bit of everything
mkdir "$T/origin" && cd "$T/origin" && g init -q .
printf 'one\ntwo\nthree\nfour\nfive\nsix\nseven\neight\n' > a.txt
printf 'gone soon\n' > b.txt
printf 'will be emptied\n' > c.txt
printf '#!/bin/sh\necho hi\n' > run.sh && chmod +x run.sh
for i in 1 2 3; do printf 'same\nsame\nsame\nsame\nsame\n'; done > dup.txt
mkdir -p sub && printf 'deep\n' > sub/d.txt
g add -A && g commit -qm base
cd - >/dev/null

# a "model" changes things in its checkout
g clone -q "$T/origin" "$T/work"
cd "$T/work"
sed -i.bak 's/^three$/THREE/; s/^seven$/SEVEN/' a.txt && rm a.txt.bak
rm b.txt
: > c.txt
sed -i.bak 's/echo hi/echo hello/' run.sh && rm run.sh.bak
awk 'NR==8{print "different"; next} {print}' dup.txt > dup.new && mv dup.new dup.txt
printf 'brand new\n' > new.txt
printf 'bin\000ary' > blob.bin
printf 'deeper\n' > sub/d.txt
cd - >/dev/null

"$BIN" edits "$T/work" "a test patch" > "$T/reply.json" || fail "pantheon edits exited non-zero"
jq -e '.edits | length > 0' "$T/reply.json" >/dev/null || fail "no edits in the reply"
jq -e '.note | test("blob.bin")' "$T/reply.json" >/dev/null && ok "binary file reported as skipped" || fail "binary file not reported"
# a.txt: two hunks, each a real replace edit, not a whole-file write
n=$(jq '[.edits[] | select(.path == "a.txt" and .old != "")] | length' "$T/reply.json")
[ "$n" -ge 1 ] && ok "a.txt as $n replace edit(s)" || fail "a.txt wasn't turned into replace edits"
jq -e '.edits[] | select(.path == "b.txt" and .old == "" and .new == "")' "$T/reply.json" >/dev/null && ok "deletion" || fail "b.txt deletion missing"
jq -e '.edits[] | select(.path == "c.txt" and .old != "" and .new == "")' "$T/reply.json" >/dev/null && ok "emptied file as a replace, not a delete" || fail "c.txt emptying wrong"

# replay on a fresh clone: same tree, except the skipped binary
g clone -q "$T/origin" "$T/replay"
jq '[.edits[] | .path, .old, .new]' "$T/reply.json" > "$T/flat.json"
"$BIN" apply-edits "$T/replay" "$T/flat.json" >/dev/null || fail "apply-edits failed"
rm -f "$T/work/blob.bin"
[ "$(tree_of "$T/replay")" = "$(tree_of "$T/work")" ] && ok "replayed edits give the same tree" || fail "trees differ after replay"
[ -x "$T/replay/run.sh" ] && ok "executable bit kept" || fail "run.sh lost its executable bit"

# what the repository ignores (a build's output) is no part of a patch
g clone -q "$T/origin" "$T/built"
printf '_build/\n' > "$T/built/.gitignore" && (cd "$T/built" && g add .gitignore && g commit -qm ignore)
mkdir -p "$T/built/_build" && printf 'output\n' > "$T/built/_build/out.txt" && printf 'changed\n' >> "$T/built/sub/d.txt"
"$BIN" edits "$T/built" "built" > "$T/built.json" || fail "pantheon edits failed on a built checkout"
jq -e '[.edits[].path] == ["sub/d.txt"]' "$T/built.json" >/dev/null && ok "ignored build output left out" \
  || fail "edits of a built checkout: $(jq -c '[.edits[].path]' "$T/built.json")"

# refusals
g clone -q "$T/origin" "$T/bad"
ln -s /tmp "$T/bad/link"
echo '["link/escape.txt", "", "x"]' > "$T/e1.json"
"$BIN" apply-edits "$T/bad" "$T/e1.json" >/dev/null 2>&1 && fail "wrote through a symlink" || ok "symlink refused"
echo '[".git/hooks/post-commit", "", "#!/bin/sh\necho owned"]' > "$T/e2.json"
"$BIN" apply-edits "$T/bad" "$T/e2.json" >/dev/null 2>&1 && fail "wrote into .git" || ok ".git refused"
echo '["sub/.GIT/config", "", "x"]' > "$T/e3.json"
"$BIN" apply-edits "$T/bad" "$T/e3.json" >/dev/null 2>&1 && fail "wrote into a nested .GIT" || ok "nested .GIT refused"
echo '["../outside.txt", "", "x"]' > "$T/e4.json"
"$BIN" apply-edits "$T/bad" "$T/e4.json" >/dev/null 2>&1 && fail "wrote outside with .." || ok ".. refused"
echo '["dup.txt", "same\n", "other\n"]' > "$T/e5.json"
"$BIN" apply-edits "$T/bad" "$T/e5.json" >/dev/null 2>&1 && fail "applied an ambiguous edit" || ok "ambiguous old text refused"
echo '["a.txt", "not there\n", "x"]' > "$T/e6.json"
"$BIN" apply-edits "$T/bad" "$T/e6.json" >/dev/null 2>&1 && fail "applied an edit whose old text is missing" || ok "missing old text refused"

# the checkout is the model's: a symlink in it must not bring what it points at
# into the bid (a node's key), whether the model made it or a diff did
printf 'PRIVATE-KEY-DATA\n' > "$T/secret"
g clone -q "$T/origin" "$T/link"
ln -s "$T/secret" "$T/link/notes.txt"; ln -sf "$T/secret" "$T/link/sub/d.txt"
"$BIN" edits "$T/link" "links" > "$T/link.json" || fail "pantheon edits failed on a checkout with symlinks"
grep -q PRIVATE-KEY-DATA "$T/link.json" && fail "a symlink's target went into the edits" || ok "symlinks don't bring their targets into a bid"
jq -e '.note | test("notes.txt")' "$T/link.json" >/dev/null && ok "a symlink is reported as skipped" || fail "a symlink wasn't reported: $(cat "$T/link.json")"

# ... nor can its .git run commands as the node: with PANTHEON_GITDIR (the
# node keeps the repository outside the checkout), the checkout's own .git and
# its config (core.fsmonitor, a clean filter) are never read
g clone -q --separate-git-dir="$T/hostile.git" "$T/origin" "$T/hostile"
rm "$T/hostile/.git"; g init -q "$T/hostile-own" && mv "$T/hostile-own/.git" "$T/hostile/.git"
git -C "$T/hostile" config core.fsmonitor "touch $T/pwned-fsmonitor; false"
git -C "$T/hostile" config filter.x.clean "touch $T/pwned-filter; cat"
printf '* filter=x\n' > "$T/hostile/.git/info/attributes"
printf 'changed\n' >> "$T/hostile/a.txt"
PANTHEON_GITDIR="$T/hostile.git" "$BIN" edits "$T/hostile" "hostile" > "$T/hostile.json" || fail "pantheon edits failed with PANTHEON_GITDIR"
[ ! -e "$T/pwned-fsmonitor" ] && [ ! -e "$T/pwned-filter" ] && ok "a checkout's .git config runs nothing" || fail "a checkout's .git config ran a command"
jq -e '[.edits[].path] == ["a.txt"]' "$T/hostile.json" >/dev/null && ok "edits come from the node's repository" || fail "edits with PANTHEON_GITDIR: $(cat "$T/hostile.json")"

# ... nor can PANTHEON_GITDIR itself: when node and model are one user the
# model can write that repository's config too. A clean filter and an
# fsmonitor there (routed to by .gitattributes in the worktree) must never
# run when the snapshot reads the checkout, and edits are still read.
g clone -q --separate-git-dir="$T/hostile2.git" "$T/origin" "$T/hostile2"
git --git-dir="$T/hostile2.git" config filter.x.clean "touch $T/pwned-gitdir-filter; cat"
git --git-dir="$T/hostile2.git" config core.fsmonitor "touch $T/pwned-gitdir-fsmonitor; false"
git --git-dir="$T/hostile2.git" config core.hooksPath "$T/hostile2-hooks"
printf '* filter=x\n' > "$T/hostile2/.gitattributes"
printf 'changed\n' >> "$T/hostile2/a.txt"
PANTHEON_GITDIR="$T/hostile2.git" "$BIN" edits "$T/hostile2" "hostile2" > "$T/hostile2.json" || fail "pantheon edits failed with a hostile PANTHEON_GITDIR"
[ ! -e "$T/pwned-gitdir-filter" ] && [ ! -e "$T/pwned-gitdir-fsmonitor" ] && ok "a hostile PANTHEON_GITDIR config runs nothing" || fail "a hostile PANTHEON_GITDIR config ran a command"
jq -e '[.edits[].path] | index("a.txt")' "$T/hostile2.json" >/dev/null && ok "edits still come from a hostile PANTHEON_GITDIR" || fail "edits with a hostile PANTHEON_GITDIR: $(cat "$T/hostile2.json")"

# the node started as ./main.exe still finds its own binary once the
# directory has changed (docs/SECURITY-REVIEW-2.md P-10): the path it gives
# for itself, the one `up`, checks and PANTHEON_BIN use, works from elsewhere
(cd "$(dirname "$BIN")" && ./main.exe init "$T/selfnet" --repo origin="$T/origin") > "$T/init.out" 2>&1 || fail "./main.exe init failed: $(tail -3 "$T/init.out")"
self=$(sed -n 's/.*Run it with: \(.*\) up .*/\1/p' "$T/init.out")
(cd "$T/selfnet" && [ -x "$self" ] && "$self" plan "$T/no-such-plan" 2>&1 | grep -q 'no .*no-such-plan here') \
  && ok "./main.exe gives itself as a path that works from another directory ($self)" \
  || fail "./main.exe names itself as '$self', which isn't there from another directory"

[ $fails -eq 0 ] && echo PASS || { echo "$fails failed"; exit 1; }
