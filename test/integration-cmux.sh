#!/bin/sh
# integrations/cmux/pantheon-cmux against a stub of cmux's CLI (no cmux, no
# Mac needed): up makes one workspace with a pane per agent, a diplomat's tab
# and inbox wired to its node's backend, the status and watchdog tabs; it
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
pc=$here/integrations/cmux/pantheon-cmux

( cd "$t" && sh "$pc" up net --diplomats "claude" --backends codex=cmd:/x/bid.sh -- --goal goal.txt --bid-window 8 ) > "$t/out" || fail "up"
grep -q 'is up in cmux workspace "pantheon: net"' "$t/out" || fail "up's summary: $(cat "$t/out")"
n=$(grep -c '^new-workspace' "$t/ledger" || true); [ "$n" = 1 ] || fail "one workspace, not $n"
n=$(grep -c '^new-split' "$t/ledger" || true); [ "$n" = 3 ] || fail "a pane per agent: 3 splits, not $n"
grep -q -- "--name pantheon: net" "$t/ledger" || fail "the workspace's name"
grep -q -- "--description - add a sub command" "$t/ledger" || fail "the goal's first line as its description"
for a in claude codex grok muse; do
  grep -q "rename-tab .* $a node" "$t/ledger" || fail "$a's node tab"
  [ -x "$t/net/.cmux/$a/node.sh" ] || fail "$a's node script"
done
grep -q "rename-tab .* claude diplomat" "$t/ledger" || fail "claude's diplomat tab"
! grep -q "codex diplomat" "$t/ledger" || fail "codex has no diplomat"
grep -q "rename-tab .* status" "$t/ledger" && grep -q "rename-tab .* watchdog" "$t/ledger" || fail "status and watchdog tabs"
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
echo "PASS pantheon-cmux: a network as a cmux workspace, its sidebar, watchdog and down"
