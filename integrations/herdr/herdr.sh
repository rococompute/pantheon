# herdr's part of scripts/host.sh: the diplomats' sessions, one herdr tab
# per agent, and the watchdog that nudges a session that stopped working its
# inbox. scripts/host.sh sources this file, so these functions use its
# settings and helpers (AGENTS, NET, P, DIPS, kind, own_session, vm, say,
# die, ...); run them through it: scripts/host.sh diplomats, scripts/host.sh
# watchdog. See integrations/herdr/README.md for what this is and its limits.

# start: AGENT KIND EXECUTABLE ARGS..., in a herdr tab of its own
cmd_diplomats() {
  command -v herdr >/dev/null || die "no herdr: install it (herdr.dev)"
  [ "${HERDR_ENV:-}" = 1 ] || die "run this from a pane in herdr (start herdr on this host, then run it there)"
  [ -d "$NET" ] || die "no network yet: scripts/host.sh network, then start"
  # tabs in the workspace this runs from
  ws=${HERDR_WORKSPACE_ID:?run this from a pane in herdr}
  root=$(herdr tab create --workspace "$ws" --label status --cwd "$P" --no-focus | jq -r .result.root_pane.pane_id)
  herdr pane run "$root" "while :; do clear; $here/scripts/host.sh status; sleep 20; done" >/dev/null
  for a in $AGENTS; do
    if in_vm_agents "$a"; then
      p=$(herdr tab create --workspace "$ws" --label "$a (vm)" --cwd "$P" --no-focus | jq -r .result.root_pane.pane_id)
      case $(kind "$a") in
        muse) herdr pane run "$p" "$(command -v limactl) shell --workdir / $(vm "$a") sh -c 'exec sh \"\$HOME/pantheon/start.sh\"'" >/dev/null ;;
      esac
      say "$a: in its VM, tab \"$a (vm)\""; continue
    fi
    # An unprovisioned diplomat must never fall back to the operator,
    # who may own node keys and push credentials. Other isolated sessions
    # can still start while this account awaits provisioning.
    if ! own_session "$a"; then
      say "$a: no isolated session; run scripts/host.sh users, services and sessions before starting it"
      continue
    fi
    case $(kind "$a") in
      claude) kind=claude exe=claude args="--dangerously-skip-permissions" ;;
      codex)  kind=codex exe=codex args="--dangerously-bypass-approvals-and-sandbox" ;;
      grok)   kind=cursor exe=cursor-agent args="--yolo --trust --model $GROK_MODEL" ;;
      *) say "$a: no diplomat for it here"; continue ;;
    esac
    if own_session "$a"; then
      # as its own user (scripts/host.sh sessions): its login, desk and
      # instructions are its own, and nothing of the operator's environment
      # reaches it; it shares only its inbox with the nodes
      u=pantheon-$a
      sudo -n -iu "$u" command -v "$exe" >/dev/null 2>&1 \
        || { say "$a: $u has no $exe: install it where $u finds it, log it in (scripts/host.sh login $a), then run this again"; continue; }
      p=$(herdr tab create --workspace "$ws" --label "$a" --cwd / --no-focus | jq -r .result.root_pane.pane_id)
      # the pane's shell becomes the diplomat's login shell (its .profile: its desk, its wrappers first)
      herdr pane run "$p" "exec sudo -iu $u" >/dev/null
      # shellcheck disable=SC2086
      herdr agent start "$a" --kind "$kind" --pane "$p" --timeout 60000 -- $args >/dev/null \
        || { say "$a: $exe didn't come up ready as $u (logged in? scripts/host.sh login $a; herdr pane read $p)"; continue; }
      herdr agent prompt "$a" "Read $DIPS/$a/instructions.md: it is your job, as $a's diplomat in a Pantheon network. Follow it now." >/dev/null
      say "$a: started as $u in tab \"$a\""
      continue
    fi
    die "$a lost its isolated session configuration: run scripts/host.sh sessions before diplomats"
  done
  say "in this workspace ($ws): a tab per agent, and one for status"
}

# The watchdog. An agent's session sometimes ends its turn (a summary, as if
# the job were done) while its node keeps sending requests: nothing answers
# them until someone looks. Every minute this looks at each agent's session in
# herdr; one idle two checks running gets a nudge back to its loop, and again
# every five minutes while it stays idle. An agent whose node holds requests
# for a usage limit is left alone (it's right to stop), and so is one blocked
# on a question (that needs a person).
write_watchdog_unit() {
  mkdir -p "$UNITS"
  cat > "$UNITS/pantheon-watchdog.service" <<U
[Unit]
Description=Pantheon watchdog: nudges an agent whose session stopped working its inbox
[Service]
ExecStart=$here/scripts/host.sh watchdog-loop
Restart=on-failure
RestartSec=30
[Install]
WantedBy=default.target
U
}

cmd_watchdog() {
  command -v herdr >/dev/null || die "no herdr: the watchdog watches the agents' sessions in herdr"
  # --check: what it sees now, nudging no one
  if [ "${1:-}" = --check ]; then for a in $AGENTS; do dry=1 watch_agent "$a"; done; return 0; fi
  write_watchdog_unit; systemctl --user daemon-reload
  systemctl --user enable -q pantheon-watchdog.service; systemctl --user restart pantheon-watchdog.service
  say "watchdog started; its nudges: journalctl --user -u pantheon-watchdog"
}

# the pane of AGENT's tab "AGENT (vm)", in any workspace
vm_pane() {
  for w in $(herdr workspace list 2>/dev/null | jq -r '.result.workspaces[].workspace_id'); do
    t=$(herdr tab list --workspace "$w" | jq -r --arg l "$1 (vm)" '.result.tabs[] | select(.label == $l) | .tab_id' | head -1)
    [ -n "$t" ] || continue
    herdr pane list --workspace "$w" | jq -r --arg t "$t" '.result.panes[] | select(.tab_id == $t) | .pane_id' | head -1
    return 0
  done
  return 1
}

watch_agent() {
  a=$1 st=$P/watchdog; mkdir -p "$st"
  if grep -q '^LIMIT' "$NET/$a/status.txt" 2>/dev/null; then rm -f "$st/$a"; return 0; fi
  if in_vm_agents "$a"; then
    # while Muse runs a command or thinks, its screen says "esc to interrupt"
    p=$(vm_pane "$a") || return 0
    if herdr pane read "$p" --source visible 2>/dev/null | grep -q "esc to interrupt"; then idle=0; else idle=1; fi
    file="~/pantheon/instructions.md"
  else
    case $(herdr agent list 2>/dev/null | jq -r --arg a "$a" '.result.agents[] | select(.name == $a) | .agent_status') in
      idle|done) idle=1 ;; *) idle=0 ;;   # working, blocked (a person's call), or no session
    esac
    if own_session "$a"; then file=$DIPS/$a/instructions.md; else file=$P/diplomats/$a.md; fi
  fi
  [ -z "${dry:-}" ] || { say "watchdog: $a $([ "$idle" = 1 ] && echo idle || echo busy)"; return 0; }
  [ "$idle" = 1 ] || { rm -f "$st/$a"; return 0; }
  n=$(( $(cat "$st/$a" 2>/dev/null || echo 0) + 1 )); echo "$n" > "$st/$a"
  [ "$n" -ge 2 ] && [ $(( (n - 2) % 5 )) -eq 0 ] || return 0
  msg="You stopped working your inbox, and your node keeps sending requests that nothing answers. Keep at it for as long as this session runs: wait, answer, repeat, and don't end your turn between requests (your instructions: $file). If your provider says you've hit a usage limit, report it with limited as they say, then stop. Start now."
  if in_vm_agents "$a"; then
    herdr pane send-text "$p" "$msg" >/dev/null && sleep 1 && herdr pane send-keys "$p" Enter >/dev/null
    # Muse sometimes keeps the text in its input after the first Enter
    sleep 3; herdr pane read "$p" | grep -q '^❯ You stopped working' && herdr pane send-keys "$p" Enter >/dev/null
  else
    herdr agent prompt "$a" "$msg" >/dev/null
  fi
  say "watchdog: $a's session had stopped (idle for $n checks): nudged it back to its inbox"
}

cmd_watchdog_loop() { while :; do for a in $AGENTS; do watch_agent "$a" || true; done; sleep 60; done; }
