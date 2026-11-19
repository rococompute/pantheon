#!/bin/sh
# The market's and the shell's path policy on .git components: every ASCII
# case spelling, at exact component boundaries and at any depth, plus the
# paths each policy deliberately treats differently and the market/execution
# decisions that use them. The Soma entry point is written to a temporary
# name because a hyphen is not a Soma identifier.
set -eu
cd "$(dirname "$0")/.."
SOMA=${SOMA:-soma}
t=$(mktemp -d "${TMPDIR:-/tmp}/pantheon-audit-path-case.XXXXXX")
tmp=audit_path_case_$$.soma
trap 'rm -f "$tmp"; rm -rf "$t"' EXIT HUP INT TERM
cat > "$tmp" <<'SOMA'
(** The market's and the shell's path policy on .git components, in every
    ASCII case, at exact component boundaries, and the paths each deliberately
    treats differently. Run with test/audit-path-case.sh. *)
Import core.util core.market app.cli.
From Stdlib Require Import Ascii.
Require Soma.Host.

check (label : string) (b : bool) : string := append (if b then "ok " else "FAIL ") label.

git_cases : list string :=
  [".git", ".Git", ".gIt", ".giT", ".GIt", ".GiT", ".gIT", ".GIT"].

git_positions (v : string) : list string :=
  [v,
   append v "/config",
   append "src/" (append v "/config"),
   append "src/" v,
   append "src/a/" (append v "/b/c")].

git_case_check (v : string) : string :=
  check (append (append "rejects " v) " in every component position")
    (forallb (fun p => negb (safe_path p) && negb (shell_safe_path p)) (git_positions v)).

allowed (p : string) : string :=
  check (append "allows " p) (safe_path p && shell_safe_path p).

rejected (p : string) : string :=
  check (append "rejects " p) (negb (safe_path p) && negb (shell_safe_path p)).

boundary_checks : list string :=
  [allowed "README.md",
   allowed "src/main.soma",
   allowed "a/b/c.txt",
   allowed ".plan",
   allowed ".gitignore",
   allowed "src/.gitignore",
   allowed ".github/workflows/ci.yml",
   allowed "docs/.gitlab-ci.yml",
   allowed "src/.Gitignore",
   allowed "src/.GITx/y",
   allowed "foo.git/config",
   allowed "src/.gitx/config",
   allowed "src/x.git/y",
   allowed "a/.git.git/b",
   allowed ".git_",
   allowed "git",
   allowed ".gi",
   allowed "a.git",
   allowed "a/.git-foo",
   rejected ".git",
   rejected "a/.git",
   rejected "a/.git/b",
   rejected "a/b/.GIT/c",
   rejected "a/.Git/b/.gIT/c",
   rejected ".gitattributes",
   rejected "a/.GitModules",
   rejected "a/.gitmodules"].

nul_path : string := SCons (ascii_of_nat 0) "a".

difference_checks : list string :=
  [check "safe_path rejects embedded .. while the shell permits it"
     (negb (safe_path "src/a..b") && shell_safe_path "src/a..b"),
   check "safe_path permits NUL while the shell rejects it"
     (safe_path nul_path && negb (shell_safe_path nul_path)),
   check "both reject .. as a component" (negb (safe_path "a/../b") && negb (shell_safe_path "a/../b")),
   check "both reject a backslash" (negb (safe_path "a\\b") && negb (shell_safe_path "a\\b")),
   check "both reject an empty path" (negb (safe_path "") && negb (shell_safe_path "")),
   check "both reject an absolute path" (negb (safe_path "/a") && negb (shell_safe_path "/a")),
   check "both reject an empty component" (negb (safe_path "a//b") && negb (shell_safe_path "a//b")),
   check "both reject a dot component" (negb (safe_path "a/./b") && negb (shell_safe_path "a/./b")),
   check "both reject git metadata in any case" (negb (safe_path "a/.GitModules") && negb (shell_safe_path "a/.GitModules"))].

market : obj :=
  let m := new_market ["a", "b", "c", "d"] in
  let m := setf m "leader" "a" in
  let m := setf m "h" 10 in
  let m := setf m "repos" ([("calc", "t0")] : list (string * string)) in
  let m := setf m "awaiting" false in
  m.

posted : obj :=
  let '(m, _, _) := apply market "a" ["post", "calc", "a task"] in m.

first_bidder : string :=
  match task_by posted 1 with
  | Some t => match bidders_for posted t with a :: _ => a | [] => "" end
  | None => ""
  end.

bid_why (p : string) : string :=
  let '(m, _, why) := apply posted first_bidder ["bid", "1", "0", "a bid", p, "", "new"] in why.

post_why (p : string) : string :=
  let '(m, _, why) := apply market "a" ["post", "calc", "a task", p] in why.

bid_agrees (p : string) : string :=
  check (append "market bid follows safe_path for " p)
    (if safe_path p then seq (bid_why p) "" else seq (bid_why p) "unsafe path").

post_agrees (p : string) : string :=
  check (append "market post context follows safe_path for " p)
    (if safe_path p then seq (post_why p) "" else seq (post_why p) "context is up to 8 safe paths").

market_paths : list string :=
  git_cases
  ++ [append ".Git" "/config", "src/.gIt/b", ".gitignore", "src/main.soma",
      "docs/.github/x.md", "foo.git/x", "a/.gitx/y", ".git_", "a.git",
      ".gitattributes", "a/.GitModules", "a/../b", "src/a..b", "a//b", "/a", ""].

execution_checks : list string :=
  [check "execution rejects every .git case spelling"
     (forallb (fun v => match edit_plan_of (append v "/f") "" "x" "none" with
                        | EditFail why => seq why (append "unsafe path " (append v "/f"))
                        | _ => false
                        end) git_cases),
   check "execution writes an ordinary path"
     (match edit_plan_of ".gitignore" "" "x" "none" with
      | EditWrite p t => seq p ".gitignore" && seq t "x"
      | _ => false
      end)].

checks : list string :=
  map git_case_check git_cases
  ++ boundary_checks
  ++ difference_checks
  ++ map bid_agrees market_paths
  ++ map post_agrees market_paths
  ++ execution_checks.

main := Host.print_lines
  (checks ++ [append "ok " (append (show (length checks)) " path-policy checks")]).
SOMA
if ! timeout 600 "$SOMA" run "$tmp" > "$t/out" 2> "$t/err"; then
  cat "$t/err" "$t/out"
  exit 1
fi
cat "$t/out"
if grep -q '^FAIL ' "$t/out"; then exit 1; fi
grep -q '^ok 94 path-policy checks$' "$t/out" || { echo 'FAIL the path-policy checks did not all run'; exit 1; }

# The real check command, when the tree has been built: a mixed-case .git
# component is a bid failure, and an ordinary name that contains ".git" is
# written. This is the execution side of the same policy the market uses.
if [ -x ./main.exe ]; then
  exec=$t/exec
  mkdir -p "$exec/src"
  (cd "$exec/src" && git init -q . && printf 'base\n' > README.md && git add README.md \
    && git -c user.name=t -c user.email=t@t -c commit.gpgsign=false commit -qm base) \
    || { echo 'FAIL could not make the execution fixture'; exit 1; }
  tree=$(git -C "$exec/src" rev-parse 'HEAD^{tree}')
  printf '[".Git/foo","","x"]' > "$exec/git.json"
  printf '[".gitignore","","x"]' > "$exec/ok.json"
  status=0
  ./main.exe check "$exec/src" "$tree" "$exec/git.json" "$exec/git-out" > "$exec/git-say" 2>&1 || status=$?
  [ "$status" -eq 1 ] && grep -q '^unsafe path \.Git/foo$' "$exec/git-say" \
    || { cat "$exec/git-say"; echo 'FAIL the real check accepted .Git/foo'; exit 1; }
  status=0
  ./main.exe check "$exec/src" "$tree" "$exec/ok.json" "$exec/ok-out" > "$exec/ok-say" 2>&1 || status=$?
  [ "$status" -eq 0 ] && grep -q '^[0-9a-f]\{40\}$' "$exec/ok-say" \
    || { cat "$exec/ok-say"; echo 'FAIL the real check rejected .gitignore'; exit 1; }
  echo 'ok the real check rejects .Git/foo and writes .gitignore'
else
  echo 'ok the real check was not run (no main.exe)'
fi
echo 'PASS every ASCII case spelling of a .git component is unsafe in the market, the shell and execution'
