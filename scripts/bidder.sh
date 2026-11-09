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
# attesting) is answered with tools off, as the built-in backends do, except
# by Grok Build, which reads it from a file with read-only tools (below).
# PANTHEON_REPOS: the node's HOME/repos, so Grok Build can read the code a bid
# changes; GROK_ANSWER_FLAGS: its flags for answers (default --reasoning-effort
# low: at its default effort a pick took over 10 minutes, at low 8).
#
# The model can read what the node's user can read. To keep it away from the
# node's keys, run it as another user: set BIDDER_USER (needs passwordless sudo
# to that user, and that user's own model login). See docs/SAFETY.md.
set -u
MODEL=${BIDDER_MODEL:-claude}
prompt=$(mktemp)
err=$(mktemp)
trap 'rm -f "$prompt" "$err"' EXIT
cat > "$prompt"
# The model's CLI writes its errors to stderr, and the node doesn't keep a
# backend's stderr: a usage limit or a lapsed login read as an empty reply,
# which the node counts as a failure and asks again, though asking again can't
# help. When the model gives no answer, what its CLI said is the reply instead,
# as a failure (exit 1), so the node can tell a limit and hold its calls.
# Whatever came on stdout goes last: Claude Code's limit message ends with
# its reset time, which the node reads from the end.
gave_up() {
  [ -s "$err" ] || return 0
  printf 'the %s CLI gave no answer. It said: %s %s\n' "$MODEL" "$(tail -c 600 "$err" | tr '\n' ' ')" "$(printf '%s' "${1:-}" | tr '\n' ' ')"
  exit 1
}
# Grok Build reads its prompt from a file, as the bidder user
[ -n "${BIDDER_USER:-}" ] && chmod 644 "$prompt"
grok_model() { [ -n "${GROK_BUILD_MODEL:-}" ] && printf '%s\n' --model "$GROK_BUILD_MODEL"; true; }

as_bidder() {
  if [ -n "${BIDDER_USER:-}" ]; then sudo -n -u "$BIDDER_USER" -H "$@"; else "$@"; fi
}

if [ -z "${PANTHEON_WORKTREE:-}" ]; then
  case $MODEL in
    claude) reply=$(as_bidder claude -p --tools "" --strict-mcp-config --no-session-persistence --setting-sources "" --output-format text < "$prompt" 2>"$err") ;;
    codex)
      outd=$(mktemp -d); chmod 777 "$outd"; out=$outd/reply.txt
      as_bidder codex exec --skip-git-repo-check --ephemeral --disable apps --sandbox read-only -c 'approval_policy="never"' -c 'mcp_servers={}' -o "$out" - < "$prompt" >/dev/null 2>"$err"
      reply=$(cat "$out" 2>/dev/null); rm -rf "$outd" ;;
    # Grok Build is a coding agent: on a long request (a pick or an attest
    # with diffs in it) it goes to read the code first, and with its tools
    # off it waits on a tool it can't call and prints nothing until the node
    # stops it. So it gets files instead: the request in request.md, and each
    # governed repository at the market's head under repos/ (from
    # PANTHEON_REPOS, the node's HOME/repos), with read-only tools.
    grok)
      qd=$(mktemp -d); trap 'rm -rf "$prompt" "$err" "$qd"' EXIT
      cp "$prompt" "$qd/request.md"
      for r in ${PANTHEON_REPOS:+"$PANTHEON_REPOS"/*}; do
        [ -d "$r" ] || continue
        mkdir -p "$qd/repos/$(basename "$r")" && git -C "$r" archive HEAD | tar -x -C "$qd/repos/$(basename "$r")" 2>/dev/null
      done
      chmod -R a+rX "$qd"
      ask=$qd/ask.md
      { echo 'You are answering one request from your Pantheon node. It is in request.md in the current directory: read all of it first.'
        [ -d "$qd/repos" ] && echo 'repos/ holds each repository at the market'"'"'s head (repos/NAME), read-only, if you want to check the code a bid changes.'
        echo 'Reply with exactly the JSON object request.md asks for, and nothing else: no plan, no commentary. You cannot change anything here.'; } > "$ask"
      for try in 1 2 3; do
        reply=$(as_bidder grok --prompt-file "$ask" --cwd "$qd" $(grok_model) ${GROK_ANSWER_FLAGS---reasoning-effort low} --no-subagents --disable-web-search --output-format plain \
          --tools "read_file,grep,list_dir" --permission-mode dontAsk --allow "Read(./**)" --allow "Glob" 2>"$err")
        case $reply in *'{'*'}'*) break ;; esac
        # nothing at all, with an error: the service refused, and asking again won't change that
        [ -z "$reply" ] && [ -s "$err" ] && break
        printf '\nYour last reply had no JSON object. Reply now with only the JSON object request.md asks for.\n' >> "$ask"
      done ;;
    *) echo "bidder.sh: unknown BIDDER_MODEL $MODEL (claude, codex or grok)" >&2; exit 1 ;;
  esac
  case $reply in *'{'*'}'*) ;; *) gave_up "$reply" ;; esac
  printf '%s\n' "$reply"
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
    echo 'Run shell commands one at a time, not chained with ; && or || and not piped: only these run, `soma build`, `soma run`, `soma explore`, `sh test.sh`, `sh tests/...`, `sh test/...`, `git diff`, `git status`, `ls`, and, in a checkout of Soma itself, `soma-dev-build` (builds it) and `./_build/install/default/bin/soma ...` (the Soma you built). A command run another way is refused, and your work goes in unchecked. Read and edit files with your file tools.' >> "$prompt"
    note=$(as_bidder claude -p --tools "Read,Edit,Write,Glob,Bash" \
      --allowedTools "Read(./**)" "Edit(./**)" "Glob" "Bash(soma build:*)" "Bash(soma run:*)" "Bash(soma explore:*)" \
                     "Bash(sh test.sh:*)" "Bash(sh tests/:*)" "Bash(sh test/:*)" "Bash(git diff:*)" "Bash(git status)" "Bash(ls:*)" \
                     "Bash(soma-dev-build)" "Bash(./_build/install/default/bin/soma:*)" \
      --permission-mode dontAsk --strict-mcp-config --no-session-persistence --setting-sources "" --output-format text < "$prompt" 2>"$err" | tail -n 1) ;;
  codex)
    outd=$(mktemp -d); chmod 777 "$outd"; out=$outd/reply.txt
    extra=""; for d in ${BIDDER_WRITABLE:-}; do extra="$extra --add-dir $d"; done
    as_bidder codex exec --skip-git-repo-check --ephemeral --disable apps --sandbox workspace-write -C "$PANTHEON_WORKTREE" $extra \
      -c 'approval_policy="never"' -c 'mcp_servers={}' -o "$out" - < "$prompt" >/dev/null 2>"$err"
    note=$(sed '/^[[:space:]]*$/d' "$out" 2>/dev/null | tail -n 1); rm -rf "$outd"
    # codex sometimes ends with the reply format's JSON: its note, then
    case $note in '{'*) note=$(printf '%s' "$note" | jq -r '.note // empty' 2>/dev/null || printf '%s' "$note") ;; esac ;;
  grok)
    echo 'Run shell commands one at a time, not chained with ; && or ||: only these run, `soma build`, `soma run`, `soma explore`, `sh test.sh`, `sh tests/...`, `sh test/...`, `git diff`, `git status`, `ls`, and `cursor-agent`. Read and edit files with your file tools.' >> "$prompt"
    if as_bidder sh -c 'command -v cursor-agent' >/dev/null 2>&1; then
      echo 'The Cursor CLI is here too: `cursor-agent -p --output-format text "..."` hands a subtask to Cursor'"'"'s agent, in this directory.' >> "$prompt"
    fi
    # only the tools a patch needs: Grok Build's others (monitor, tasks, ...)
    # ask for an approval a headless run can't give, and it stops there
    # Its allow rules match unreliably (a plain `git status` was refused) and a
    # headless run stops at the first refusal, so when the model is a user of
    # its own (BIDDER_USER: it can't touch the node), it may run anything in
    # the checkout; otherwise only the commands above.
    if [ -n "${BIDDER_USER:-}" ]; then
      set -- --yolo --deny "Bash(git commit*)" --deny "Bash(git push*)"
    else
      set -- --permission-mode dontAsk
      for r in "Read(./**)" "Edit(./**)" "Glob" "Bash(soma build:*)" "Bash(soma run:*)" "Bash(soma explore:*)" "Bash(sh test.sh:*)" \
               "Bash(sh tests/:*)" "Bash(sh test/:*)" "Bash(git diff:*)" "Bash(git status)" "Bash(ls:*)" "Bash(cursor-agent:*)"; do set -- "$@" --allow "$r"; done
    fi
    note=$(as_bidder grok --prompt-file "$prompt" --cwd "$PANTHEON_WORKTREE" $(grok_model) --no-subagents --disable-web-search \
      --tools "read_file,grep,list_dir,search_replace,write,run_terminal_cmd" "$@" --output-format plain 2>"$err" | sed '/^[[:space:]]*$/d' | tail -n 1) ;;
  *) echo "bidder.sh: unknown BIDDER_MODEL $MODEL (claude, codex or grok)" >&2; exit 1 ;;
esac
# what the model made in the checkout (a build's output) is the bidder's: let
# the node remove the checkout afterwards, or each patch leaks it (a Soma
# build is close to a GB)
[ -n "${BIDDER_USER:-}" ] && as_bidder chmod -R a+rwX . 2>/dev/null
# no change and no note: the model never ran (a limit, a lapsed login)
# (git on the node's repository for the checkout, never the checkout's own
# .git, which the model could have pointed at a config that runs commands)
[ -z "$note" ] && [ -z "$(GIT_DIR=${PANTHEON_GITDIR:-.git} GIT_WORK_TREE=. git -c core.fsmonitor=false status --porcelain 2>/dev/null)" ] && gave_up
exec "$PANTHEON_BIN" edits . "$note"
