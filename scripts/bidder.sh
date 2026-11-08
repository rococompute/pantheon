#!/bin/sh
# A cmd: backend for a model with tools: Claude Code, codex, or Grok Build.
#
#   pantheon node HOME --backend cmd:/path/to/scripts/bidder-claude.sh
#   pantheon node HOME --backend cmd:/path/to/scripts/bidder-codex.sh
#   pantheon node HOME --backend cmd:/path/to/scripts/bidder-grok.sh
#
# BIDDER_WRITABLE: directories, space-separated, that a model's own sandbox
# (codex's) should let it write besides the checkout: opam's log and locks
# when Soma is another user's, say. Unix permissions still decide what it can.
#
# Grok Build uses GROK_BUILD_MODEL if it's set, and may call the Cursor CLI
# (cursor-agent) as a tool when it's installed.
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
# Grok Build reads its prompt from a file, as the bidder user
[ -n "${BIDDER_USER:-}" ] && chmod 644 "$prompt"
grok_model() { [ -n "${GROK_BUILD_MODEL:-}" ] && printf '%s\n' --model "$GROK_BUILD_MODEL"; true; }

as_bidder() {
  if [ -n "${BIDDER_USER:-}" ]; then sudo -n -u "$BIDDER_USER" -H "$@"; else "$@"; fi
}

if [ -z "${PANTHEON_WORKTREE:-}" ]; then
  case $MODEL in
    claude) as_bidder claude -p --tools "" --strict-mcp-config --no-session-persistence --setting-sources "" --output-format text < "$prompt" ;;
    codex)
      outd=$(mktemp -d); chmod 777 "$outd"; out=$outd/reply.txt
      as_bidder codex exec --skip-git-repo-check --ephemeral --disable apps --sandbox read-only -c 'approval_policy="never"' -c 'mcp_servers={}' -o "$out" - < "$prompt" >/dev/null
      cat "$out" 2>/dev/null; rm -rf "$outd" ;;
    # Grok Build: --tools "" leaves every tool on, and its coding system prompt
    # explores before answering, so both go
    grok) as_bidder grok --prompt-file "$prompt" $(grok_model) --no-subagents --output-format plain \
            --disallowed-tools "run_terminal_cmd,read_file,grep,list_dir,write,search_replace,web_search,web_fetch,task,Agent" \
            --system-prompt-override "You answer the user directly from what the prompt gives you. You have no tools and nothing else to look at. Reply with exactly what the prompt asks for: one JSON object and nothing else." ;;
    *) echo "bidder.sh: unknown BIDDER_MODEL $MODEL (claude, codex or grok)" >&2; exit 1 ;;
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
    outd=$(mktemp -d); chmod 777 "$outd"; out=$outd/reply.txt
    extra=""; for d in ${BIDDER_WRITABLE:-}; do extra="$extra --add-dir $d"; done
    as_bidder codex exec --skip-git-repo-check --ephemeral --disable apps --sandbox workspace-write -C "$PANTHEON_WORKTREE" $extra \
      -c 'approval_policy="never"' -c 'mcp_servers={}' -o "$out" - < "$prompt" >/dev/null
    note=$(sed '/^[[:space:]]*$/d' "$out" 2>/dev/null | tail -n 1); rm -rf "$outd" ;;
  grok)
    echo 'Run shell commands one at a time, not chained with ; && or ||: only these run, `soma build`, `soma run`, `soma explore`, `sh test.sh`, `sh tests/...`, `sh test/...`, `git diff`, `git status`, `ls`, and `cursor-agent`. Read and edit files with your file tools.' >> "$prompt"
    if as_bidder sh -c 'command -v cursor-agent' >/dev/null 2>&1; then
      echo 'The Cursor CLI is here too: `cursor-agent -p --output-format text "..."` hands a subtask to Cursor'"'"'s agent, in this directory.' >> "$prompt"
    fi
    note=$(as_bidder grok --prompt-file "$prompt" --cwd "$PANTHEON_WORKTREE" $(grok_model) --no-subagents --disable-web-search \
      --allow "Read(./**)" --allow "Edit(./**)" --allow "Glob" --allow "Bash(soma build:*)" --allow "Bash(soma run:*)" --allow "Bash(soma explore:*)" \
      --allow "Bash(sh test.sh:*)" --allow "Bash(sh tests/:*)" --allow "Bash(sh test/:*)" --allow "Bash(git diff:*)" --allow "Bash(git status)" \
      --allow "Bash(ls:*)" --allow "Bash(cursor-agent:*)" --permission-mode dontAsk --output-format plain | sed '/^[[:space:]]*$/d' | tail -n 1) ;;
  *) echo "bidder.sh: unknown BIDDER_MODEL $MODEL (claude, codex or grok)" >&2; exit 1 ;;
esac
exec "$PANTHEON_BIN" edits . "$note"
