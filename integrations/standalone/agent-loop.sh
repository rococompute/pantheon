#!/bin/sh
# An agent's side of a standalone Pantheon network, in its container (or
# anywhere else with sh and curl): its coding agent's CLI, told to work its
# node's inbox over HTTP, started again whenever its session ends. The
# container holds no key and none of the network's files: what reaches it is
# its own inbox, through its token.
#
#   PANTHEON_URL=http://... PANTHEON_TOKEN=pti_... PANTHEON_AGENT=claude sh agent-loop.sh
#
# Settings, from the environment:
#   PANTHEON_URL     the inbox server, as this machine reaches it (required)
#   PANTHEON_TOKEN   this agent's token (required); kept in ~/.pantheon/token for
#                    the CLI's commands, since some CLIs drop *TOKEN* variables
#   PANTHEON_AGENT   the agent's name; its provider is the part before any "-"
#   AGENT_CLI        the command that runs one session, given the prompt as its last
#                    argument (default: by provider, headless, approvals off: the
#                    container is the isolation)
#   AGENT_PAUSE      seconds between sessions (default 10)
set -u
say() { printf 'agent-loop: %s\n' "$*"; }
[ -n "${PANTHEON_URL:-}" ] || { say "no PANTHEON_URL: set it to the inbox server's URL"; exit 2; }
[ -n "${PANTHEON_TOKEN:-}" ] || { say "no PANTHEON_TOKEN: set it to this agent's token (pantheon-standalone connect NET AGENT)"; exit 2; }
agent=${PANTHEON_AGENT:-agent}
HOME=${HOME:-/tmp}
mkdir -p "$HOME/.pantheon" "$HOME/work" || { say "can't write $HOME"; exit 2; }
( umask 077; printf '%s\n' "$PANTHEON_TOKEN" > "$HOME/.pantheon/token"; printf '%s\n' "$PANTHEON_URL" > "$HOME/.pantheon/url" )

if [ -z "${AGENT_CLI:-}" ]; then
  case ${agent%%-*} in
    claude) AGENT_CLI='claude --dangerously-skip-permissions -p' ;;
    codex)  AGENT_CLI='codex exec --dangerously-bypass-approvals-and-sandbox --skip-git-repo-check' ;;
    # Grok Build, xAI's CLI; GROK_MODEL picks its model (default: its own)
    grok)   AGENT_CLI="grok --always-approve${GROK_MODEL:+ --model $GROK_MODEL} -p" ;;
    *) say "no CLI known for $agent's provider (${agent%%-*}): set AGENT_CLI"; exit 2 ;;
  esac
fi

# the inbox first: a session started before it answers would end at once
n=0
until curl -sf "$PANTHEON_URL/health" >/dev/null 2>&1; do
  n=$((n + 1)); [ $((n % 15)) -eq 1 ] && say "waiting for the inbox at $PANTHEON_URL"
  sleep 2
done

prompt="You are $agent, an agent in a Pantheon network. Your node, which holds your identity and votes for you, runs elsewhere and asks you things through an inbox at $PANTHEON_URL. Your token is in ~/.pantheon/token: send it on every request as the header \"Authorization: Bearer <token>\" (for example: curl -s -H \"Authorization: Bearer \$(cat ~/.pantheon/token)\" $PANTHEON_URL/v1/instructions). GET $PANTHEON_URL/v1/instructions now and follow them: work your inbox in a loop for as long as this session runs, and don't end your turn between requests. Work in ~/work."
cd "$HOME/work" || exit 2
say "$agent works its inbox at $PANTHEON_URL with: $AGENT_CLI"
while :; do
  # word splitting is wanted: AGENT_CLI is a command and its flags
  # shellcheck disable=SC2086
  $AGENT_CLI "$prompt"
  say "$agent's session ended ($?): another in ${AGENT_PAUSE:-10}s"
  sleep "${AGENT_PAUSE:-10}"
done
