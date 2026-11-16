# An agent's container for a standalone Pantheon network: its coding agent's
# CLI and what it needs to work its inbox over HTTP (curl, git, jq). No
# Pantheon, no Soma, no key: the node runs elsewhere (a binary or a unikernel
# on the host), and the agent reaches only its inbox, with its token.
#
#   docker build -t pantheon-agent integrations/standalone
#   (or: integrations/standalone/pantheon-standalone build-agent)
#
# CLIS picks the npm packages (default: Claude Code and codex); GROK=1 adds
# Grok Build, xAI's CLI, by its installer (for a grok agent):
#   docker build --build-arg GROK=1 -t pantheon-agent integrations/standalone
# Logins live in
# the agent's home volume (pantheon-standalone login NET AGENT), or come as
# environment variables (pantheon-standalone up ... --pass-env ANTHROPIC_API_KEY).
FROM node:22-bookworm-slim
RUN apt-get update -q && apt-get install -y -q --no-install-recommends git curl jq ca-certificates \
 && rm -rf /var/lib/apt/lists/*
ARG CLIS="@anthropic-ai/claude-code @openai/codex"
RUN npm install -g $CLIS && npm cache clean --force
# Grok Build installs into its user's home, which is a volume at run time:
# so into /opt/grok, linked onto the PATH
ARG GROK=
RUN if [ -n "$GROK" ]; then HOME=/opt/grok sh -c 'curl -fsSL https://x.ai/cli/install.sh | bash' \
      && ln -s /opt/grok/.grok/bin/grok /usr/local/bin/grok && chmod -R a+rX /opt/grok && grok --version; fi
# the agent's own user; its home is a volume, so a login outlives the container
RUN useradd -m -u 1001 agent && mkdir -p /home/agent/.pantheon /home/agent/work && chown -R agent:agent /home/agent
COPY agent-loop.sh /opt/pantheon/agent-loop
USER agent
# the root is read-only when pantheon-standalone runs it: no self-updates
ENV HOME=/home/agent DISABLE_AUTOUPDATER=1 CI=1
WORKDIR /home/agent
CMD ["sh", "/opt/pantheon/agent-loop"]
