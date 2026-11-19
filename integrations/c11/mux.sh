# c11's adapter for integrations/cmux/pantheon-cmux, which sources this when
# PANTHEON_MUX=c11 (integrations/c11/pantheon-c11 sets it). It replaces the
# mux_* calls: c11's workspaces, areas (cmux's panes) and panels (cmux's
# tabs); agent state from `c11 fleet` and `c11 feed`; messages to a diplomat
# as c11 mail, rung into its session when it's idle.
#
# Settings, from the environment:
#   C11   the c11 CLI (default: the one that came with this c11 terminal, else c11
#         on PATH, else the one inside c11.app). Never `cmux`: c11's cask links
#         a cmux shim, and cmux's CLI doesn't take c11's flags.

MUX=c11 MUX_STATE=.c11 prog=pantheon-c11
self=$here/integrations/c11/pantheon-c11

mux_setup() {
  if [ -z "${C11_BIN:-}" ]; then
    if [ -n "${C11:-}" ]; then C11_BIN=$C11
    elif [ -n "${C11_BUNDLED_CLI_PATH:-}" ] && [ -x "$C11_BUNDLED_CLI_PATH" ]; then C11_BIN=$C11_BUNDLED_CLI_PATH
    elif command -v c11 >/dev/null 2>&1; then C11_BIN=c11
    else C11_BIN=/Applications/c11.app/Contents/Resources/bin/c11
    fi
  fi
  # c11's CLI takes C11_SOCKET, then CMUX_SOCKET_PATH: a shell that came from
  # cmux would otherwise send it to cmux's socket. Pin c11's own.
  if [ -z "${C11_SOCKET:-}" ]; then
    if [ -n "${C11_SOCKET_PATH:-}" ]; then export C11_SOCKET="$C11_SOCKET_PATH";
    else unset CMUX_SOCKET_PATH CMUX_SOCKET; fi
  fi
  export C11_QUIET_DISCOVERY=1
}
c1() { "$C11_BIN" "$@"; }
mux_need() {
  command -v "$C11_BIN" >/dev/null 2>&1 || [ -x "$C11_BIN" ] \
    || die "no c11 CLI at $C11_BIN: install c11 (brew install --cask c11), or set C11 to its CLI"
  c1 ping >/dev/null 2>&1 || die "c11 doesn't answer: run this from a c11 terminal (by default c11's socket admits only processes started inside c11), with c11.app open"
}
mux_alive() { c1 --json --id-format uuids list-workspaces 2>/dev/null | grep -qi "$1"; }
mux_new_workspace() {
  out=$(c1 --id-format both new-workspace --title "$1" --cwd "$3" --command "$4") || die "c11 couldn't make the workspace: $out"
  nw=$(printf '%s' "$out" | first_uuid)
  [ -n "$nw" ] || die "c11 made a workspace but didn't say its id: $out"
  c1 set-workspace-description "$2" --workspace "$nw" >/dev/null 2>&1 || true
  printf '%s' "$nw"
}
# areas as JSON, for PY on stdin with its arguments
areas_py() { a_w=$1 a_py=$2; shift 2; c1 --json --id-format both list-areas --workspace "$a_w" | python3 -c "$a_py" "$@"; }
mux_first_surface() {
  areas_py "$1" 'import json,sys; print(json.load(sys.stdin)["areas"][0]["panel_ids"][0])'
}
mux_pane_of() {
  areas_py "$1" '
import json, sys
s = sys.argv[1].lower()
for a in json.load(sys.stdin)["areas"]:
    if s in [x.lower() for x in a.get("panel_ids", []) + a.get("panel_refs", [])]:
        print(a["id"]); break' "$2"
}
mux_split() { c1 --id-format both new-split "$1" --workspace "$2" --panel "$3" --command "$4" | first_uuid; }
mux_new_tab() { c1 --id-format both new-panel --area "$1" --workspace "$2" --command "$3" | first_uuid; }
mux_rename_tab() { c1 rename-panel --workspace "$1" --panel "$2" "$3" >/dev/null; }
mux_reorder() {
  c1 reorder-panel --workspace "$1" --panel "$2" --index "$3" >/dev/null 2>&1 || true
  [ "${4:-}" != true ] || c1 focus-panel --workspace "$1" --panel "$2" >/dev/null 2>&1 || true
}
# The plan's view is a page in a browser area, not a markdown area: c11's
# markdown viewer shows raw HTML as text, so the plan's <details> blocks
# wouldn't fold. plan-html.py writes plan.html from plan.md, and the watchdog
# reloads the page whenever the plan changes (mux_plan_changed); the page keeps
# its open folds and scroll. new-area splits the workspace's focused area,
# which is S's while it's the only one. Its output: "OK panel:N (UUID)
# area:N (UUID) workspace:N (UUID)".
plan_html() { python3 "$here/integrations/c11/plan-html.py" "${1%.md}.md" "${1%.md}.html"; }
mux_markdown() {
  plan_html "$1" || return 0
  url=$(python3 -c 'import pathlib, sys; print(pathlib.Path(sys.argv[1]).as_uri())' "${1%.md}.html")
  mo=$(c1 --id-format both new-area --type browser --url "$url" --direction left --workspace "$2" --title plan) || return 0
  ids=$(printf '%s' "$mo" | grep -o '([0-9A-Fa-f-]\{36\})' | tr -d '()')
  printf '%s\n' "$ids" | sed -n 1p > "$(dirname "$1")/plan-surface"
  printf '%s %s' "$(printf '%s\n' "$ids" | sed -n 2p)" "$(printf '%s\n' "$ids" | sed -n 1p)"
}
mux_plan_changed() {
  plan_html "$ST/plan.md" || return 0
  ps_=$(cat "$ST/plan-surface" 2>/dev/null) || return 0
  # Browser commands target the globally unique panel UUID; unlike terminal
  # commands, the browser CLI does not accept --workspace for reload.
  [ -z "$ps_" ] || c1 browser --panel "$ps_" reload >/dev/null 2>&1 || true
}
mux_rename_ws() { c1 rename-workspace --workspace "$1" "$2" >/dev/null 2>&1; }
mux_notify() { c1 notify --title "$3" --body "$4" --workspace "$1" ${2:+--panel "$2"} >/dev/null 2>&1 || true; }
# A diplomat takes c11 mail as a new turn when it's idle (c11 rings only an
# agent's own interactive terminal, and only at its prompt).
mux_diplomat_tab() {
  c1 set-metadata --workspace "$1" --panel "$2" --key mailbox.delivery --value stdin --type string >/dev/null 2>&1 || true
}
# The session's state, as pantheon-cmux reads cmux's: c11's lifecycle is working,
# waiting (it wants attention), idle, cold or null. Waiting with an open
# blocking ask (a question, a plan, a permission) is a person's call:
# needs_input. So is a dialog on its screen, which c11's lifecycle can call
# working: Claude Code's folder-trust prompt, before its first turn, is one.
# Otherwise a turn that ended is idle, however c11 marks it.
mux_state() {
  f_=$(c1 --json fleet 2>/dev/null || echo '{}')
  a_=$(c1 --json feed list --scope attention 2>/dev/null || echo '{}')
  i_=$(c1 --json input-state --workspace "$(workspace)" --panel "$1" 2>/dev/null || echo '{}')
  F_=$f_ A_=$a_ I_=$i_ python3 -c '
import json, os, sys
s = sys.argv[1].lower()
def load(k):
    try: return json.loads(os.environ[k])
    except ValueError: return {}
life = None
for p in load("F_").get("panels", []):
    if (p.get("panel_id") or "").lower() == s:
        life = p.get("lifecycle")
        # c11 can mark a session waiting from its launch until its first turn
        # ends, even while it works (Codex does): until a turn has ended,
        # an ended turn is unknown, not idle.
        if life in ("waiting", "idle", "cold") and not p.get("last_turn_end"): life = None
        break
else:
    print("none"); sys.exit()
asks = [r for r in load("A_").get("rows", [])
        if (r.get("panel_id") or "").lower() == s and r.get("state") == "open" and r.get("blocking") is not False]
if asks or load("I_").get("input_state") == "dialog": print("needs_input")
elif life == "working": print("working")
elif life in ("waiting", "idle", "cold"): print("idle")
else: print("none")' "$1"
}
mux_message() { c1 mailbox send --to "id:$1" --from Pantheon --topic pantheon.watchdog --body "$2" >/dev/null; }
# c11 won't let an agent close the workspace the operator is looking at
# (workspace_switch_blocked): that would switch their view.
mux_close() {
  cl_=$(c1 close-workspace --workspace "$1" 2>&1) && return 0
  case $cl_ in
    *workspace_switch_blocked*) say "c11 won't close the workspace you're looking at: switch to another one and run down again, or close it yourself" >&2 ;;
    *) printf '%s\n' "$cl_" >&2 ;;
  esac
  return 1
}
mux_events() {
  exec python3 "$here/integrations/cmux/events.py" "$NET" --state "$MUX_STATE" --c11 "$C11_BIN" --parent "$$"
}
MUX_NOTICES='Pantheon event notices arrive as c11 mail from Pantheon when your session is idle: a `<c11-msg from=Pantheon ...>` block, or the line `c11 mail waiting: run c11 mailbox recv --ack` (run exactly that to read it). During a long turn, `c11 mailbox recv --ack` between requests reads any that are waiting.'
