#!/bin/sh
# A cmd: backend for an agent working interactively, in a session of its own
# (Muse, or Claude Code, or codex, with full permissions on a machine of its
# own). Each request goes in the inbox; the agent takes it with
# `pantheon-inbox wait` and answers with `pantheon-inbox reply` or, for a
# patch, edits the fresh checkout and says `pantheon-inbox done`. An answer
# not given in time is a model error: the node goes on without it.
#
#   pantheon node HOME --backend cmd:/path/to/scripts/bidder-inbox.sh
#
# PANTHEON_INBOX is the inbox (default /var/lib/pantheon-inbox): a directory
# the node's user and the agent's user can both write.
set -u
INBOX=${PANTHEON_INBOX:-/var/lib/pantheon-inbox}
[ -d "$INBOX" ] && [ -w "$INBOX" ] || { echo "!bidder-inbox: no inbox the node can write at $INBOX (set PANTHEON_INBOX)"; exit 0; }
id=$(date +%s)-$(od -An -N4 -tx1 /dev/urandom | tr -d ' \n')
r=$INBOX/$id
mkdir "$r" && chmod 2770 "$r" || { echo "!bidder-inbox: can't make $r"; exit 0; }
# on the way out: the request, and the checkout made removable by the node
# (what the agent made in it is the agent's user's, and a build is close to a GB)
free() { rm -rf "$r"; [ -n "${PANTHEON_WORKTREE:-}" ] && sudo -n -u "${BIDDER_USER:-bidder}" chmod -R a+rwX "$PANTHEON_WORKTREE" 2>/dev/null; true; }
trap free EXIT
cat > "$r/.prompt"

if [ -n "${PANTHEON_WORKTREE:-}" ]; then
  chmod -R a+rwX "$PANTHEON_WORKTREE"
  echo patch > "$r/kind"; printf '%s\n' "$PANTHEON_WORKTREE" > "$r/worktree"
  budget=1700
  if [ -n "${INBOX_URL:-}" ]; then
    # the agent works from elsewhere, over scripts/inbox-http.py
    cat >> "$r/.prompt" <<I

You have tools. Get the repository at the market's head: GET $INBOX_URL/v1/checkout/$id.tar.gz (a directory named checkout/). Make it a git repository before you change anything (git init -q && git add -A && git commit -qm head), so you can diff against it. Make the change by editing the files there, instead of writing edits in a reply. Keep it to what the task asks. If you have soma, check your work with \`soma build\` on the project's main file (main.soma, or the file you changed) and run the tests if there are any; if you don't, your node's CI builds it and a rejection says why.
Ignore the reply format above: when you're done, \`git add -A\` and POST $INBOX_URL/v1/done/$id with {"note": "a short note on what you changed", "diff": "<the output of git diff --cached>"}.
I
  else
  cat >> "$r/.prompt" <<I

You have tools, and $PANTHEON_WORKTREE is a checkout of the repository at the market's head. Make the change by editing the files there, instead of writing edits in a reply. Keep it to what the task asks. If there is a soma.toml, check your work with \`soma build\` on the project's main file (main.soma, or the file you changed), and run the tests if there are any. Don't commit, don't push, and don't touch anything outside that directory.
Ignore the reply format above: when you're done, run \`pantheon-inbox done $id "a short note on what you changed"\`.
I
  fi
else
  echo answer > "$r/kind"
  budget=570
fi
echo $(( $(date +%s) + budget )) > "$r/deadline"
mv "$r/.prompt" "$r/prompt.txt"

end=$(( $(date +%s) + budget ))
while [ "$(date +%s)" -lt "$end" ]; do
  # the agent said its provider's usage limit is hit: the node holds requests
  if [ -f "$INBOX/limited" ]; then
    said=$(head -c 400 "$INBOX/limited"); rm -f "$INBOX/limited"
    echo "!usage limit reached, as the interactive agent reports: $said"; exit 0
  fi
  if [ -f "$r/reply.txt" ]; then cat "$r/reply.txt"; exit 0; fi
  if [ -f "$r/done" ]; then "$PANTHEON_BIN" edits "$PANTHEON_WORKTREE" "$(head -n 1 "$r/done")"; exit $?; fi
  sleep 2
done
: > "$r/expired"
echo "!the interactive agent didn't answer request $id within ${budget}s (is its session running? pantheon-inbox list)"
