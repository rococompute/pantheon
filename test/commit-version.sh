#!/bin/sh
# The Pantheon-Version line of a merge commit, with no git and no node.
set -eu
cd "$(dirname "$0")/.."
commit_version_dir=$(mktemp -d "${TMPDIR:-/tmp}/pantheon-commit-version.XXXXXX")
trap 'rm -rf "$commit_version_dir"' EXIT
if ! soma run test/commit_version.soma > "$commit_version_dir/out" 2> "$commit_version_dir/err"; then
  cat "$commit_version_dir/err" "$commit_version_dir/out"
  exit 1
fi
cat "$commit_version_dir/out"
if grep -q '^FAIL ' "$commit_version_dir/out"; then exit 1; fi
[ "$(grep -c '^ok ' "$commit_version_dir/out")" -eq 7 ]
echo 'PASS commit version'
