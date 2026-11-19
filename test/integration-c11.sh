#!/bin/sh
# integrations/c11/pantheon-c11 against a stub of c11's CLI (no c11, no Mac
# needed). What the plan, the watchdog's counting and the record do is
# pantheon-cmux's, tested by test/integration-cmux.sh; this tests c11's
# adapter (integrations/c11/mux.sh): up makes one c11 workspace (the plan's
# markdown area on the left beside the watchdog, an area per agent), keeps its
# state in NET/.c11, opens the diplomat's panel to c11 mail; the watchdog
# reads c11's fleet and feed, nudges an idle diplomat with mail and notifies
# you once of an open ask; the events relay sends c11 mail; down closes it.
set -eu
here=$(cd "$(dirname "$0")/.." && pwd)
t=$(mktemp -d)
watcher=""
trap '[ -z "$watcher" ] || kill -TERM "$watcher" 2>/dev/null || true; rm -rf "$t"' EXIT HUP INT TERM
fail() { echo "FAIL: $*"; tail -20 "$t/ledger" 2>/dev/null; exit 1; }
mkdir -p "$t/bin"

# a c11 that keeps its workspace and areas in a JSON file, records each call,
# and reports the lifecycle ($t/state) and open ask ($t/ask) the test sets
cat > "$t/bin/c11" <<'STUB'
#!/usr/bin/env python3
import json, os, sys
t = os.environ["STUB_DIR"]; db = t + "/c11.json"
args = sys.argv[1:]
st = json.load(open(db)) if os.path.exists(db) else {"ws": [], "areas": [], "n": 0}
def save(): json.dump(st, open(db, "w"))
def opt(name): return args[args.index(name) + 1] if name in args else None
def uuid():
    st["n"] += 1; return "%08x-0000-0000-0000-000000000000" % st["n"]
i = 0
while i < len(args) and args[i] in ("--json", "--id-format"):
    i += 2 if args[i] == "--id-format" else 1
cmd = args[i] if i < len(args) else ""
open(t + "/ledger", "a").write(" ".join(args[i:]) + "\n")
def area(cmds):
    p = uuid(); a = {"id": uuid(), "panel_ids": [p], "panel_refs": [], "cmds": cmds}; return a, p
watched = open(t + "/watched").read().strip() if os.path.exists(t + "/watched") else ""
if cmd == "ping": print("PONG")
elif cmd == "list-workspaces":
    print(json.dumps({"workspaces": [{"ref": w["ref"], "id": w["id"]} for w in st["ws"]]}))
elif cmd == "new-workspace":
    w = {"ref": "workspace:%d" % (len(st["ws"]) + 1), "id": uuid()}
    st["ws"].append(w); a, p = area([opt("--command")]); st["areas"].append(a); save()
    print("OK %s (%s) input=queued" % (w["ref"], w["id"]))
elif cmd == "list-areas":
    print(json.dumps({"areas": [{k: a[k] for k in ("id", "panel_ids", "panel_refs")} for a in st["areas"]]}))
elif cmd == "new-split":
    a, p = area([opt("--command")]); st["areas"].append(a); save()
    print("OK panel:9 (%s) workspace:1 (%s) input=queued" % (p, st["ws"][0]["id"]))
elif cmd == "new-area":
    a, p = area([opt("--type") + " " + (opt("--url") or opt("--file") or "")]); st["areas"].insert(0, a); save()
    print("OK panel:9 (%s) area:9 (%s) workspace:1 (%s)" % (p, a["id"], st["ws"][0]["id"]))
elif cmd == "new-panel":
    p = uuid()
    for a in st["areas"]:
        if a["id"] == opt("--area"): a["panel_ids"].append(p); a["cmds"].append(opt("--command"))
    save(); print("OK panel:9 (%s) area:1 workspace:1 input=queued" % p)
elif cmd == "fleet":
    state = open(t + "/state").read().strip() if os.path.exists(t + "/state") else ""
    ended = None if os.path.exists(t + "/no-turn") else "2026-11-18T00:00:00Z"
    print(json.dumps({"panels": [{"panel_id": watched, "lifecycle": state or None, "last_turn_end": ended}] if watched else []}))
elif cmd == "feed":
    ask = os.path.exists(t + "/ask")
    print(json.dumps({"rows": [{"panel_id": watched, "kind": "question", "state": "open", "blocking": True}] if ask else []}))
elif cmd == "input-state":
    print(json.dumps({"input_state": "dialog" if os.path.exists(t + "/dialog") else "empty"}))
elif cmd == "close-workspace" and os.path.exists(t + "/viewing"):
    print("Error: workspace_switch_blocked: Agents cannot change the operator's workspace.", file=sys.stderr); sys.exit(1)
elif cmd == "close-workspace":
    st["ws"] = []; st["areas"] = []; save(); print("OK")
else:
    print("OK")
STUB
chmod +x "$t/bin/c11"
export PYTHONDONTWRITEBYTECODE=1 PANTHEON_EVENTS=0 C11_SOCKET_PATH=/nonexistent CMUX_SOCKET_PATH=/cmux.sock
# Exercise CLI paths that an unquoted expansion would glob to a decoy.
cp "$t/bin/c11" "$t/bin/c11 [live]"
printf '#!/bin/sh\nexit 99\n' > "$t/bin/c11 l"; chmod +x "$t/bin/c11 l"
export STUB_DIR="$t" C11="$t/bin/c11 [live]" PANTHEON=/bin/true DIPLOMAT_CLI="echo diplomat" PANTHEON_RUNS="$t/runs"
unset C11_SOCKET 2>/dev/null || true

for a in claude codex grok muse; do mkdir -p "$t/net/$a"; echo '{}' > "$t/net/$a/key.json"; echo '{}' > "$t/net/$a/genesis.json"; done
printf -- '- add a sub command\n' > "$t/goal.txt"
printf 'height 7  term 1  leader codex\n' > "$t/net/claude/status.txt"
pc=$here/integrations/c11/pantheon-c11
d=$t/net/.c11

( cd "$t" && sh "$pc" up net --diplomats claude -- --goal goal.txt ) > "$t/out" || fail "up: $(cat "$t/out")"
grep -q '^pantheon-c11: .* is up in a c11 workspace' "$t/out" || fail "up's summary: $(cat "$t/out")"
[ -d "$d" ] && [ ! -e "$t/net/.cmux" ] || fail "state in NET/.c11, not NET/.cmux"
grep -q "^new-workspace --title Market --cwd $t/net --command sh '$d/claude/session.sh'" "$t/ledger" || fail "the workspace, named Market, its first panel claude's diplomat"
grep -q "^set-workspace-description - add a sub command --workspace " "$t/ledger" || fail "the goal as its description"
grep -q "^new-area --type browser --url file://$d/plan.html --direction left" "$t/ledger" || fail "the plan's page in a browser area on the left"
[ -s "$d/plan.html" ] && [ "$(cat "$d/plan-surface")" ] || fail "up writes plan.html and keeps its panel"
n=$(grep -c '^new-split' "$t/ledger" || true); [ "$n" = 3 ] || fail "an area for each agent after the first: $n splits"
grep -q "^new-split .* --panel .* --command sh '$d/codex/node.sh'" "$t/ledger" || fail "codex's area runs its node"
for a in claude codex grok muse; do grep -q "^rename-panel .* $a\$" "$t/ledger" || fail "$a's panel"; done
grep -q "^rename-panel .* claude node\$" "$t/ledger" && grep -q "^rename-panel .* watchdog\$" "$t/ledger" || fail "claude's node panel and the watchdog's"
grep -q "^set-metadata --workspace .* --panel $(cat "$d/claude/surface") --key mailbox.delivery --value stdin" "$t/ledger" || fail "the diplomat takes c11 mail"
python3 - "$t/c11.json" "$d" "$pc" <<'PY' || fail "the areas"
import json, sys
st = json.load(open(sys.argv[1])); d, pc = sys.argv[2], sys.argv[3]; net = d.rsplit("/.c11", 1)[0]
areas = [a["cmds"] for a in st["areas"]]
assert len(areas) == 5, areas
assert areas[0] == ["browser file://" + d + "/plan.html", "sh '" + pc + "' watchdog '" + net + "'"], areas[0]
assert ["sh '" + d + "/claude/session.sh'", "sh '" + d + "/claude/node.sh'"] in areas, areas
PY
grep -q "in this c11 pane" "$d/claude/desk/instructions.md" && grep -q "arrive as c11 mail" "$d/claude/desk/instructions.md" \
  && grep -q "$d/claude/inbox/ID/prompt.txt" "$d/claude/desk/instructions.md" || fail "instructions for c11"
! grep -q '{{\|cmux' "$d/claude/desk/instructions.md" || fail "instructions left a placeholder or name cmux"
if ( cd "$t" && sh "$pc" up net ) > "$t/out2" 2>&1; then fail "a second up"; fi
grep -q "pantheon-c11 down" "$t/out2" || fail "a second up's refusal: $(cat "$t/out2")"

# Start the real relay through the watchdog with the spaced/glob-shaped CLI.
# Its exec must retain the watchdog as parent, rather than exiting immediately.
printf 'pool 0\n' >> "$t/net/claude/status.txt"
PANTHEON_EVENTS=1 sh "$pc" watchdog "$t/net" > "$t/relay-watchdog.log" 2>&1 & watcher=$!
tries=0
while [ ! -s "$d/events/socket" ] && [ "$tries" -lt 50 ]; do
  sleep 0.1; tries=$((tries + 1))
done
[ -s "$d/events/socket" ] || fail "relay did not start: $(cat "$d/events/relay.log")"
kill -0 "$watcher" 2>/dev/null || fail "watchdog exited"
# A ready inbox request must go through the native startup argument path.
request=$d/claude/inbox/1794000004-abcd; mkdir -p "$request"
echo $(( $(date +%s) + 3600 )) > "$request/deadline"
echo answer > "$request/kind"; echo prompt > "$request/prompt.txt"
tries=0
while ! grep -q 'pantheon.events --body' "$t/ledger" && [ "$tries" -lt 60 ]; do
  sleep 0.1; tries=$((tries + 1))
done
grep -q 'pantheon.events --body' "$t/ledger" || fail "relay with spaced CLI did not deliver: $(cat "$d/events/relay.log")"
kill -TERM "$watcher"; wait "$watcher" || true; watcher=""
[ ! -e "$d/events/socket" ] || fail "relay socket left after watchdog exit"
rm -rf "$request"

# the watchdog: idle with a live unanswered request for two passes -> mail
cp "$d/claude/surface" "$t/watched"
inbox=$d/claude/inbox; mkdir -p "$inbox/1794000005-abcd"
echo $(( $(date +%s) + 3600 )) > "$inbox/1794000005-abcd/deadline"; echo x > "$inbox/1794000005-abcd/prompt.txt"
for s in idle cold waiting; do
  echo "$s" > "$t/state"; rm -f "$d/claude/watchdog"*; : > "$t/ledger"
  sh "$pc" watchdog "$t/net" --once > /dev/null; sh "$pc" watchdog "$t/net" --once > "$t/wd"
  grep -q "^mailbox send --to id:$(cat "$t/watched") --from Pantheon --topic pantheon.watchdog --body Your inbox still has an unanswered request (1794000005-abcd)" "$t/ledger" \
    || fail "c11's $s: no mail for a persistent request"
done
echo working > "$t/state"; : > "$t/ledger"; sh "$pc" watchdog "$t/net" --once > /dev/null
! grep -q '^mailbox send' "$t/ledger" || fail "mailed a working diplomat"
# c11 marks Codex waiting from launch until its first turn ends, while it works
echo waiting > "$t/state"; : > "$t/no-turn"; rm -f "$d/claude/watchdog"*; : > "$t/ledger"
sh "$pc" watchdog "$t/net" --once > /dev/null; sh "$pc" watchdog "$t/net" --once > /dev/null
! grep -q '^mailbox send' "$t/ledger" || fail "mailed a diplomat that hasn't ended a turn"
sh "$pc" watchdog "$t/net" --check | grep -q 'watchdog: claude none' || fail "--check: no ended turn is none"
rm "$t/no-turn"
echo waiting > "$t/state"; : > "$t/ask"; : > "$t/ledger"
sh "$pc" watchdog "$t/net" --once > /dev/null; sh "$pc" watchdog "$t/net" --once > /dev/null
[ "$(grep -c '^notify' "$t/ledger" || true)" = 1 ] && ! grep -q '^mailbox send' "$t/ledger" || fail "an open ask: one notice, no mail"
grep -q "^notify --title Pantheon: claude .* --panel $(cat "$t/watched")" "$t/ledger" || fail "the notice names the diplomat's panel"
sh "$pc" watchdog "$t/net" --check | grep -q 'watchdog: claude needs_input' || fail "--check: needs_input"
rm "$t/ask"
# a dialog on its screen (Claude Code's folder-trust prompt) while c11 says working
echo working > "$t/state"; : > "$t/dialog"; rm -f "$d/claude/watchdog.asked"
sh "$pc" watchdog "$t/net" --check | grep -q 'watchdog: claude needs_input' || fail "--check: a dialog is needs_input"
rm "$t/dialog"; : > "$t/watched"
sh "$pc" watchdog "$t/net" --check | grep -q 'watchdog: claude none' || fail "--check: a panel c11 doesn't list"

# the events relay delivers c11 mail
python3 - "$here/integrations/cmux/events.py" "$t/net" "$t/bin/c11" "$d/claude/surface" <<'PY' || fail "events as c11 mail"
import importlib.util, sys, time
spec = importlib.util.spec_from_file_location("events", sys.argv[1]); ev = importlib.util.module_from_spec(spec); spec.loader.exec_module(ev)
b = ev.Bridge(sys.argv[2], "/nonexistent-cmux", state=".c11", c11=sys.argv[3])
b.state["outbox"]["claude"] = [{"type": "task.closed", "task": str(n), "seq": n} for n in range(1, 200)]
b.deliver()
assert len(b.state["outbox"]["claude"]) < 199, "nothing delivered"
PY
grep -q "^mailbox send --to id:$(cat "$d/claude/surface") --from Pantheon --topic pantheon.events --body Pantheon event update: Task #1 closed." "$t/ledger" || fail "the relay's mail"
python3 -c 'import sys; assert all(len(l.encode()) < 4200 for l in open(sys.argv[1]) if "pantheon.events" in l)' "$t/ledger" || fail "a mail body over c11's limit"

# the plan as a page: its folds as <details>, everything else escaped
printf '## Market (codex leader)\n\nAdd a `sub` command & **keep** it _small_ <script>x</script>\n\n<details>\n<summary>Details</summary>\n\nstep two\n\n</details>\n\n<details>\n<summary><s>add a pow command</s></summary>\n\n~~add a pow command~~\n\n</details>\n\n<details>\n<summary>📉 (codex) Breaks &lt;tests&gt;</summary>\n\n_Rejected: it breaks &lt;test.sh&gt;_\n\n</details>\n' > "$t/plan.md"
python3 "$here/integrations/c11/plan-html.py" "$t/plan.md" "$t/plan.html" || fail "plan-html.py"
ph=$t/plan.html
grep -q '<title>Market (codex leader)</title>' "$ph" && grep -q '<h2>Market (codex leader)</h2>' "$ph" || fail "the page's title and heading"
[ "$(grep -c '^<details>$' "$ph")" = 3 ] && [ "$(grep -c '^</details>$' "$ph")" = 3 ] && grep -q '^<summary>Details</summary>$' "$ph" || fail "the folds as details blocks: $(cat "$ph")"
grep -q '<code>sub</code> command &amp; <strong>keep</strong> it <em>small</em> &lt;script&gt;x&lt;/script&gt;' "$ph" || fail "inline markdown, and the rest escaped: $(grep sub "$ph")"
grep -q '^<summary><s>add a pow command</s></summary>$' "$ph" && grep -q '<del>add a pow command</del>' "$ph" || fail "struck through"
grep -q '^<summary>📉 (codex) Breaks &lt;tests&gt;</summary>$' "$ph" && grep -q '<em>Rejected: it breaks &lt;test.sh&gt;</em>' "$ph" || fail "escaped text kept, not escaped twice"
! grep -q '&amp;lt;' "$ph" || fail "an entity escaped twice"
[ "$(grep -c '<script' "$ph")" = 1 ] || fail "a script other than the page's own"
# the goal's checklist in view, above its fold; the rest of the goal stays folded
printf '## Market\n\nExtend calc.sh in two steps:\n\n<details>\n<summary>Details</summary>\n\n✅ Add a `sub` command.\n\n\n⏳ Add a `mul` command.\n\nKeep existing behavior.\n\n</details>\n\n## Contributions\n\n<details>\n<summary>Details</summary>\n\n🟡 not a goal step\n\n</details>\n' > "$t/goal.md"
python3 "$here/integrations/c11/plan-html.py" "$t/goal.md" "$t/goal.html" || fail "plan-html.py on a goal"
python3 - "$t/goal.html" <<'PYG' || fail "the goal's checklist above its fold: $(sed -n '/<body>/,/<script>/p' "$t/goal.html")"
import sys
page = open(sys.argv[1]).read()
goal, rest = page.split("<h2>Contributions</h2>", 1)
steps, fold = goal.split("<details>", 1)
assert '<ul class="goals">' in steps and "<li>✅ Add a <code>sub</code> command.</li>" in steps and "<li>⏳ Add a <code>mul</code> command.</li>" in steps
assert "Keep existing behavior." in fold and "Add a" not in fold
assert "<p>🟡 not a goal step</p>" in rest, "only the goal's fold is lifted"
PYG
printf '## Market\n\nTwo steps:\n\n<details>\n<summary>Details</summary>\n\n🟡 Add a `sub` command.\n\n</details>\n' > "$t/goal.md"
python3 "$here/integrations/c11/plan-html.py" "$t/goal.md" "$t/goal.html"
grep -q '<li>🟡 Add a <code>sub</code> command.</li>' "$t/goal.html" && ! grep -q '^<details>$' "$t/goal.html" || fail "a fold left empty goes"

# Malformed/untrusted input remains readable and cannot alias formatter tokens.
python3 - "$here/integrations/c11/plan-html.py" <<'PYHTML' || fail "untrusted plan input"
import importlib.util, sys
spec = importlib.util.spec_from_file_location("plan_html", sys.argv[1])
m = importlib.util.module_from_spec(spec); spec.loader.exec_module(m)
assert "<code>**literal**</code>" in m.inline("`**literal**` and **bold**")
assert "<strong>bold</strong>" in m.inline("`**literal**` and **bold**")
assert m.inline("\0" + "999" + "\0") == "\ufffd999\ufffd"
assert m.inline("**build `calc.sh`**") == "<strong>build <code>calc.sh</code></strong>"
assert "<details>" in m.body("<details>\n<summary>Details</summary>\nunfinished")
assert "<img" not in m.body('<img src=x onerror="bad()">')
assert "🌱" in m.body("## Goals\n\n<details>\n<summary>🌱 working</summary>\n\ntext\n</details>")
PYHTML

# the watchdog's pass rewrites the page and reloads its panel when the plan changed
: > "$t/ledger"
( here=$here ST=$d C11_BIN=$t/bin/c11; workspace() { cat "$ST/workspace"; }; die() { :; }; first_uuid() { :; }; . "$here/integrations/c11/mux.sh"; mux_plan_changed )
grep -q "^browser --workspace $(cat "$d/workspace") --panel $(cat "$d/plan-surface") reload" "$t/ledger" || fail "the page reloaded: $(cat "$t/ledger")"

# No own-socket hint: discovery must not inherit either cmux socket alias.
( here=$here; die() { exit 1; }; . "$here/integrations/c11/mux.sh"
  unset C11_SOCKET C11_SOCKET_PATH
  CMUX_SOCKET_PATH=/wrong/cmux.sock CMUX_SOCKET=/wrong/alias.sock
  mux_setup
  [ -z "${CMUX_SOCKET_PATH:-}" ] && [ -z "${CMUX_SOCKET:-}" ]
) || fail "c11 inherited a cmux socket"
# c11's socket, not one inherited from cmux
grep -q 'C11_SOCKET=.*C11_SOCKET_PATH' "$here/integrations/c11/mux.sh" || fail "mux.sh pins c11's socket"
: > "$t/viewing"
sh "$pc" down "$t/net" > "$t/down" 2>&1 || fail "down when you're looking at the workspace"
grep -q "won't close the workspace you're looking at" "$t/down" && [ -s "$d/workspace" ] || fail "down keeps the workspace it couldn't close, and says why: $(cat "$t/down")"
rm "$t/viewing"
sh "$pc" down "$t/net" > /dev/null
grep -q "^close-workspace --workspace " "$t/ledger" || fail "down closes the workspace"
[ ! -e "$d/workspace" ] || fail "down forgets the workspace"
echo "PASS pantheon-c11: a network as a c11 workspace (plan area, an area per agent, diplomat mail), its watchdog, events and down"
