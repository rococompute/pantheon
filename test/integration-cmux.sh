#!/bin/sh
# integrations/cmux/pantheon-cmux against a stub of cmux's CLI (no cmux, no
# Mac needed): up makes one workspace with the market's plan on the left (the
# goal, a .plan with its marks, the tasks) beside status and the watchdog, and a
# pane per agent on the right (its diplomat, then its node), or with --layout
# grid a pane per agent; a diplomat's tab and inbox are wired
# to its node's backend; the status and watchdog tabs; it
# refuses a second up and a network whose nodes run outside it; the sidebar's
# line is read from status.txt; the watchdog nudges a diplomat idle for two
# passes, and leaves alone one that waits on a person (notified once) or is
# limited; down closes the workspace.
set -eu
here=$(cd "$(dirname "$0")/.." && pwd)
t=$(mktemp -d)
trap 'rm -rf "$t"' EXIT HUP INT TERM
fail() { echo "FAIL: $*"; cat "$t/ledger" 2>/dev/null | tail -20; exit 1; }
mkdir -p "$t/bin"

# a cmux that remembers its workspace and panes in a JSON file, records each
# call, and reports the agent state the test sets in $t/state
cat > "$t/bin/cmux" <<'STUB'
#!/usr/bin/env python3
import json, os, sys
t = os.environ["STUB_DIR"]; db = t + "/cmux.json"
args = [a for a in sys.argv[1:]]
st = json.load(open(db)) if os.path.exists(db) else {"ws": [], "panes": [], "n": 0}
def save(): json.dump(st, open(db, "w"))
def opt(name):
    return args[args.index(name) + 1] if name in args else None
def uuid():
    st["n"] += 1; return "%08X-0000-0000-0000-000000000000" % st["n"]
i = 0
while i < len(args) and args[i] in ("--json", "--id-format"):
    i += 2 if args[i] == "--id-format" else 1
cmd = args[i] if i < len(args) else ""
open(t + "/ledger", "a").write(" ".join(args[i:]) + "\n")
if cmd == "list-workspaces":
    print(json.dumps({"workspaces": [{"ref": w["ref"], "id": w["id"]} for w in st["ws"]]}))
elif cmd == "new-workspace":
    w = {"ref": "workspace:%d" % (len(st["ws"]) + 1), "id": uuid(), "name": opt("--name")}
    s = uuid(); st["ws"].append(w); st["panes"].append({"id": uuid(), "surface_ids": [s], "cmds": [opt("--command")]})
    save(); print("OK " + w["ref"])
elif cmd == "list-panes":
    print(json.dumps({"panes": [{"id": p["id"], "surface_ids": p["surface_ids"], "surface_refs": []} for p in st["panes"]]}))
elif cmd == "new-split":
    s = uuid(); st["panes"].append({"id": uuid(), "surface_ids": [s], "cmds": [opt("--command")]}); save()
    print("OK surface:9 (%s) workspace:1 (%s)" % (s, st["ws"][0]["id"]))
elif cmd == "markdown":
    # a pane of its own, as cmux's viewer is, on the left
    s = uuid(); p = uuid(); st["panes"].insert(0, {"id": p, "surface_ids": [s], "cmds": ["markdown " + args[i + 2]]}); save()
    print("OK surface=surface:9 (%s) pane=pane:9 (%s) path=%s" % (s, p, args[i + 2]))
elif cmd == "new-surface":
    s = uuid()
    for p in st["panes"]:
        if p["id"] == opt("--pane"): p["surface_ids"].append(s); p["cmds"].append(opt("--command"))
    save(); print("OK surface:9 (%s) pane:1 workspace:1" % s)
elif cmd == "current":
    state = open(t + "/state").read().strip() if os.path.exists(t + "/state") else ""
    sid = open(t + "/watched").read().strip() if os.path.exists(t + "/watched") else ""
    agents = [{"state": state}] if state else []
    print(json.dumps({"items": [{"evidence": [{"reference": "local/terminal/" + sid}], "agents": agents}]}))
elif cmd == "close-workspace":
    st["ws"] = []; st["panes"] = []; save(); print("OK")
else:
    print("OK")
STUB
chmod +x "$t/bin/cmux"
export STUB_DIR="$t" CMUX="$t/bin/cmux" PANTHEON=/bin/true DIPLOMAT_CLI="echo diplomat"

# a network: four agents with a key and a genesis
for a in claude codex grok muse; do mkdir -p "$t/net/$a"; echo '{}' > "$t/net/$a/key.json"; echo '{}' > "$t/net/$a/genesis.json"; done
printf -- '- add a sub command\n' > "$t/goal.txt"
# a repository's .plan in a node's checkout (not a git repository here: read as the file is)
mkdir -p "$t/net/claude/repos/calc"
printf '# a note\n\n2026-11-15\n* add a sub command\nadd a mul command\n- add a pow command\n' > "$t/net/claude/repos/calc/.plan"
printf 'height 7  term 1  leader codex\ntask 1 [closed] calc: - add a sub command\ntask 2 [open] calc: - add a mul command\n' > "$t/net/claude/status.txt"
pc=$here/integrations/cmux/pantheon-cmux

# the plan layout (the default)
( cd "$t" && sh "$pc" up net --diplomats "claude" --backends codex=cmd:/x/bid.sh -- --goal goal.txt --bid-window 8 ) > "$t/out" || fail "up"
grep -q 'is up in cmux workspace "pantheon: net"' "$t/out" || fail "up's summary: $(cat "$t/out")"
grep -q "the market's plan on the left" "$t/out" || fail "up names its layout: $(cat "$t/out")"
n=$(grep -c '^new-workspace' "$t/ledger" || true); [ "$n" = 1 ] || fail "one workspace, not $n"
n=$(grep -c '^new-split' "$t/ledger" || true); [ "$n" = 3 ] || fail "the plan layout splits a pane for each agent after the first: $n splits"
grep -q -- "--name pantheon: net" "$t/ledger" || fail "the workspace's name"
grep -q -- "--description - add a sub command" "$t/ledger" || fail "the goal's first line as its description"
grep -q "^new-workspace .*--command sh '$t/net/.cmux/claude/session.sh'" "$t/ledger" || fail "the first tab is claude's diplomat"
grep -q "^markdown open $t/net/.cmux/plan.md --workspace .* --direction left" "$t/ledger" || fail "the plan's view on the left"
for a in claude codex grok muse; do
  grep -q "rename-tab .* $a\$" "$t/ledger" || fail "$a's tab"
  [ -x "$t/net/.cmux/$a/node.sh" ] || fail "$a's node script"
done
grep -q "^new-split .*--command sh '$t/net/.cmux/codex/node.sh'" "$t/ledger" || fail "codex's pane runs its node"
grep -q "rename-tab .* claude node" "$t/ledger" || fail "claude's node tab"
! grep -q "codex node" "$t/ledger" || fail "codex's node is its agent's tab"
grep -q "rename-tab .* status" "$t/ledger" && grep -q "rename-tab .* watchdog" "$t/ledger" || fail "status and watchdog tabs"
n=$(grep -c '^new-surface' "$t/ledger" || true); [ "$n" = 3 ] || fail "3 tabs (claude's node, status, watchdog), not $n"
# the left half is the network's: the plan, status and the watchdog; the right
# half a pane per agent: claude's diplomat with its node's tab, and the other
# three agents' nodes (no diplomat: their node is their agent's tab)
python3 - "$t/cmux.json" "$t/net/.cmux" <<'PY' || fail "the halves"
import json, sys
st = json.load(open(sys.argv[1])); d = sys.argv[2]; net = d.rsplit("/.cmux", 1)[0]
panes = [p["cmds"] for p in st["panes"]]
assert len(panes) == 5, panes
left = panes[0]
assert left[0] == "markdown " + d + "/plan.md" and left[1].endswith(" status '" + net + "'") and " watchdog " in left[2] and len(left) == 3, left
agents = {p[0]: p for p in panes[1:]}
assert agents["sh '" + d + "/claude/session.sh'"] == ["sh '" + d + "/claude/session.sh'", "sh '" + d + "/claude/node.sh'"], agents
for a in ("codex", "grok", "muse"):
    assert agents["sh '" + d + "/" + a + "/node.sh'"] == ["sh '" + d + "/" + a + "/node.sh'"], (a, agents)
PY
# the plan: goal, the .plan's marks, the tasks
pm=$t/net/.cmux/plan.md
grep -q '^# The market: net' "$pm" || fail "plan's title: $(cat "$pm")"
grep -q '^\*\*h7 t1 · leader codex\*\*' "$pm" || fail "plan's chain line: $(cat "$pm")"
grep -q '^## Goal' "$pm" && grep -q '^- add a sub command' "$pm" || fail "plan's goal"
grep -q '^## Plan: calc' "$pm" || fail "plan's repository"
grep -q '^### 2026-11-15' "$pm" || fail "plan's day"
grep -q '^- \[x\] add a sub command' "$pm" || fail "plan's done item"
grep -q '^- \[ \] add a mul command' "$pm" || fail "plan's open item"
grep -q '^- ~~add a pow command~~' "$pm" || fail "plan's dropped item"
! grep -q 'a note' "$pm" || fail "plan shows a # note"
grep -q '^- \*\*#2\*\* `open` calc: - add a mul command' "$pm" || fail "plan's tasks: $(cat "$pm")"
# unchanged, it isn't rewritten (the view doesn't redraw for nothing)
touch -t 202001010000 "$pm"
( sed -n '/^status_of()/,/^}/p; /^render_plan()/,/^}/p' "$pc"; sed -n '/^agents_of()/,/^}/p' "$pc" ) > "$t/fn.sh"
( NET=$t/net ST=$t/net/.cmux; . "$t/fn.sh"; render_plan )
[ -z "$(find "$pm" -newer "$t/goal.txt")" ] || fail "an unchanged plan was rewritten"
# the node scripts: run from where up ran, each with its backend and the node arguments
grep -q "^cd '$t'" "$t/net/.cmux/claude/node.sh" || fail "a node runs from where up ran"
grep -q -- "--backend 'cmd:$t/net/.cmux/claude/backend.sh' '--goal' 'goal.txt' '--bid-window' '8'" "$t/net/.cmux/claude/node.sh" || fail "claude's node uses its diplomat's backend"
grep -q -- "--backend 'cmd:/x/bid.sh'" "$t/net/.cmux/codex/node.sh" || fail "codex's backend from --backends"
grep -q -- "--backend 'scripted'" "$t/net/.cmux/grok/node.sh" || fail "grok's backend: scripted"
# the diplomat: inbox, wrapper and backend on one inbox, instructions rendered
grep -q "PANTHEON_INBOX='$t/net/.cmux/claude/inbox'" "$t/net/.cmux/claude/backend.sh" || fail "backend's inbox"
grep -q "PANTHEON_INBOX='$t/net/.cmux/claude/inbox'" "$t/net/.cmux/claude/desk/pantheon-inbox" || fail "wrapper's inbox"
grep -q "You are claude," "$t/net/.cmux/claude/desk/instructions.md" || fail "instructions rendered"
! grep -q '{{' "$t/net/.cmux/claude/desk/instructions.md" || fail "instructions left a placeholder"
grep -q "^exec echo diplomat '" "$t/net/.cmux/claude/session.sh" || fail "the session starts DIPLOMAT_CLI with the prompt"
[ -s "$t/net/.cmux/claude/surface" ] || fail "the diplomat's tab recorded"

# no second up, and none while its nodes run elsewhere
if ( cd "$t" && sh "$pc" up net ) > "$t/out2" 2>&1; then fail "a second up"; fi
grep -q "is up already" "$t/out2" || fail "a second up's refusal: $(cat "$t/out2")"

# the sidebar's line
printf 'height 42  term 2  leader grok\nversion 1\n' > "$t/net/claude/status.txt"
line=$(sed -n '/^status_of()/,/^}/p' "$pc" > "$t/fn.sh"; NET=$t/net; . "$t/fn.sh"; status_of claude)
[ "$line" = "h42 t2 · leader grok" ] || fail "sidebar line: $line"

# the watchdog: idle twice gets a nudge; a person's call gets one notice
cp "$t/net/.cmux/claude/surface" "$t/watched"
echo idle > "$t/state"; : > "$t/ledger"
sh "$pc" watchdog "$t/net" --once > /dev/null
! grep -q '^paste' "$t/ledger" || fail "nudged after one idle pass"
sh "$pc" watchdog "$t/net" --once > "$t/wd"
grep -q "^paste .*--submit You stopped working your inbox" "$t/ledger" || fail "no nudge after two idle passes"
grep -q "nudged it back" "$t/wd" || fail "the nudge isn't reported"
echo working > "$t/state"; : > "$t/ledger"; sh "$pc" watchdog "$t/net" --once > /dev/null
! grep -q '^paste' "$t/ledger" || fail "nudged a working session"
echo needs_input > "$t/state"
sh "$pc" watchdog "$t/net" --once > /dev/null; sh "$pc" watchdog "$t/net" --once > /dev/null
n=$(grep -c '^notify' "$t/ledger" || true); [ "$n" = 1 ] || fail "a session waiting on a person: one notice, not $n"
! grep -q '^paste' "$t/ledger" || fail "nudged a session waiting on a person"
echo idle > "$t/state"; echo 'LIMIT until 5pm' >> "$t/net/claude/status.txt"; : > "$t/ledger"
sh "$pc" watchdog "$t/net" --once > /dev/null; sh "$pc" watchdog "$t/net" --once > /dev/null
! grep -q '^paste' "$t/ledger" || fail "nudged a limited agent"
sh "$pc" watchdog "$t/net" --check | grep -q "watchdog: claude limited" || fail "--check names a limited agent"
printf 'height 43  term 2  leader grok\n' > "$t/net/claude/status.txt"
sh "$pc" watchdog "$t/net" --check | grep -q "watchdog: claude idle" || fail "--check names the state"

# down
sh "$pc" down "$t/net" > "$t/out3"
grep -q "^close-workspace --force --workspace " "$t/ledger" || fail "down closes the workspace"
[ ! -e "$t/net/.cmux/workspace" ] || fail "down forgets the workspace"

# the grid layout: a pane per agent, each node's tab and a diplomat's
: > "$t/ledger"
( cd "$t" && sh "$pc" up net --layout grid --diplomats "claude" -- --goal goal.txt ) > "$t/out" || fail "up --layout grid"
n=$(grep -c '^new-split' "$t/ledger" || true); [ "$n" = 3 ] || fail "a pane per agent: 3 splits, not $n"
! grep -q '^markdown' "$t/ledger" || fail "the grid has no plan's view"
for a in claude codex grok muse; do grep -q "rename-tab .* $a node" "$t/ledger" || fail "$a's node tab (grid)"; done
grep -q "rename-tab .* claude diplomat" "$t/ledger" || fail "claude's diplomat tab (grid)"
if sh "$pc" up "$t/net" --layout tiles > "$t/out4" 2>&1; then fail "--layout tiles"; fi
grep -q -- "--layout tiles: plan" "$t/out4" || fail "--layout tiles refused: $(cat "$t/out4")"
sh "$pc" down "$t/net" > /dev/null
echo "PASS pantheon-cmux: a network as a cmux workspace (the plan beside a pane per agent, or a grid), its sidebar, watchdog and down"
