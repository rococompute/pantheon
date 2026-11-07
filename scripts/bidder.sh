#!/bin/sh
# A cmd: backend for a model with tools: Claude Code or codex.
#
#   pantheon node HOME --backend cmd:/path/to/scripts/bidder-claude.sh
#   pantheon node HOME --backend cmd:/path/to/scripts/bidder-codex.sh
#
# For a patch request the node gives it a fresh checkout of the task's
# repository at the market's head, in $PANTHEON_WORKTREE. The model edits files
# there, runs `soma build` and the tests, and this script replies with what
# changed, as edits (`pantheon edits`). Nothing is committed or pushed: the
# market decides what merges. Any other request (drafting a task, picking a bid,
# attesting) is answered with tools off, as the built-in backends do.
#
# The model can read what the node's user can read. To keep it away from the
# node's keys, run it as another user: set BIDDER_USER (needs passwordless sudo
# to that user, and that user's own model login). See docs/SAFETY.md.
set -u
MODEL=${BIDDER_MODEL:-claude}
prompt=$(mktemp)
trap 'rm -f "$prompt"' EXIT
cat > "$prompt"

as_bidder() {
  if [ -n "${BIDDER_USER:-}" ]; then sudo -n -u "$BIDDER_USER" -H "$@"; else "$@"; fi
}

if [ -z "${PANTHEON_WORKTREE:-}" ]; then
  case $MODEL in
    claude) as_bidder claude -p --tools "" --strict-mcp-config --no-session-persistence --setting-sources "" --output-format text < "$prompt" ;;
    codex)
      out=$(mktemp)
      as_bidder codex exec --skip-git-repo-check --ephemeral --disable apps --sandbox read-only -c 'approval_policy="never"' -c 'mcp_servers={}' -o "$out" - < "$prompt" >/dev/null
      cat "$out"; rm -f "$out" ;;
    *) echo "bidder.sh: unknown BIDDER_MODEL $MODEL (claude or codex)" >&2; exit 1 ;;
  esac
  exit
fi

cd "$PANTHEON_WORKTREE" || exit 1
[ -n "${BIDDER_USER:-}" ] && chmod -R a+rwX .
cat >> "$prompt" <<'I'

You have tools, and the current directory is a checkout of the repository at the market's head. Make the change by editing the files here, instead of writing edits in the reply. Keep it to what the task asks. If there is a soma.toml, check your work with `soma build` on the project's main file (main.soma, or the file you changed), and run the tests if there are any. Don't commit, don't push, and don't touch anything outside this directory.
Ignore the reply format above. When you're done, end with one line: a short note on what you changed.
I

case $MODEL in
  claude)
    note=$(as_bidder claude -p --tools "Read,Edit,Write,Glob,Bash" \
      --allowedTools "Read(./**)" "Edit(./**)" "Glob" "Bash(soma build:*)" "Bash(soma run:*)" "Bash(soma explore:*)" \
                     "Bash(sh test.sh:*)" "Bash(sh tests/:*)" "Bash(sh test/:*)" "Bash(git diff:*)" "Bash(git status)" "Bash(ls:*)" \
      --permission-mode dontAsk --strict-mcp-config --no-session-persistence --setting-sources "" --output-format text < "$prompt" | tail -n 1) ;;
  codex)
    out=$(mktemp)
    as_bidder codex exec --skip-git-repo-check --ephemeral --disable apps --sandbox workspace-write -C "$PANTHEON_WORKTREE" \
      -c 'approval_policy="never"' -c 'mcp_servers={}' -o "$out" - < "$prompt" >/dev/null
    note=$(tail -n 1 "$out"); rm -f "$out" ;;
  *) echo "bidder.sh: unknown BIDDER_MODEL $MODEL (claude or codex)" >&2; exit 1 ;;
esac
exec "$PANTHEON_BIN" edits . "$note"
