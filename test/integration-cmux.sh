#!/bin/sh
# integrations/cmux/pantheon-cmux against a stub of cmux's CLI (no cmux, no
# Mac needed): up makes one workspace with the market's plan on the left (the
# goal, a .plan with its marks, the bids) beside the watchdog, and a
# pane per agent on the right (its diplomat, then its node), or with --layout
# grid a pane per agent; a diplomat's tab and inbox are wired
# to its node's backend; the watchdog's tab, and no status tab; it
# refuses a second up and a network whose nodes run outside it; the
# workspace is named for the market, and no node lines go in its sidebar; the watchdog nudges a diplomat idle with unanswered work for two
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
export STUB_DIR="$t" CMUX="$t/bin/cmux" PANTHEON=/bin/true DIPLOMAT_CLI="echo diplomat" PANTHEON_RUNS="$t/runs"

# a network: four agents with a key and a genesis
for a in claude codex grok muse; do mkdir -p "$t/net/$a"; echo '{}' > "$t/net/$a/key.json"; echo '{}' > "$t/net/$a/genesis.json"; done
printf -- '- add a sub command\n2. add a mul command\n3. Add an `abs` command, with a new test file tests/test_abs.sh.\n4. Add a `sqrt` command.\n5. Add a `cube` command.\nKeep it small.\n' > "$t/goal.txt"
# a repository's .plan in a node's checkout (not a git repository here: read as the file is)
mkdir -p "$t/net/claude/repos/calc"
printf '# a note\n\n2026-11-15\n* add a sub command\nadd a mul command\nadd a div command\nadd a cube command\n- add a pow command\n' > "$t/net/claude/repos/calc/.plan"
printf 'height 7  term 1  leader codex\ntask 1 [closed] calc: - add a sub command\ntask 2 [open] calc: - add a mul command\ntask 3 [closed] calc: add a mod command\ntask 4 [open] calc: add a neg command\ntask 8 [open] calc: Audit <script>display</script>\n\nKeep this multiline task specification.\n</details> is task text.\nbid 1 [merged] task 1 by grok \nbid 2 [pending stale] task 2 by muse \nbid 3 [rejected] task 3 by codex it breaks <test.sh>\nbid 4 [cleared] task 2 by codex its edits no longer apply\ntask 5 [closed] calc: Step 3 of 4: Add an `abs` command to calc.sh, with a new test file tests/test_abs.sh. (step 1 is done)\nbid 5 [merged] task 5 by grok \ntask 6 [open] calc: Goal step 4: implement square roots\nbid 6 [pending] task 6 by muse \ntask 7 [open] calc: add a cube command\nbid 7 [merged] task 7 by codex \ntitle 1 Adds a sub case to calc.sh\nverdict 1 Fulfills goal step 1: calc can subtract\nnote 1 sub & its test\ntitle 2 Adds mul\nnote 2 a mul case\nverdict 3 Breaks the existing tests\nnote 3 mod\nnote 4 old mul\n' > "$t/net/claude/status.txt"
pc=$here/integrations/cmux/pantheon-cmux

# the plan layout (the default)
( cd "$t" && sh "$pc" up net --diplomats "claude" --backends codex=cmd:/x/bid.sh -- --goal goal.txt --bid-window 8 ) > "$t/out" || fail "up"
grep -q 'is up in a cmux workspace named for its market' "$t/out" || fail "up's summary: $(cat "$t/out")"
grep -q "the market's plan on the left" "$t/out" || fail "up names its layout: $(cat "$t/out")"
n=$(grep -c '^new-workspace' "$t/ledger" || true); [ "$n" = 1 ] || fail "one workspace, not $n"
n=$(grep -c '^new-split' "$t/ledger" || true); [ "$n" = 3 ] || fail "the plan layout splits a pane for each agent after the first: $n splits"
grep -q -- "^new-workspace --name Market --description" "$t/ledger" || fail "the workspace named Market: $(grep new-workspace "$t/ledger")"
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
grep -q "rename-tab .* watchdog" "$t/ledger" || fail "the watchdog's tab"
! grep -q "rename-tab .* status" "$t/ledger" || fail "no status tab"
n=$(grep -c '^new-surface' "$t/ledger" || true); [ "$n" = 2 ] || fail "2 tabs (claude's node, watchdog), not $n"
# the left half is the network's: the plan and the watchdog; the right
# half a pane per agent: claude's diplomat with its node's tab, and the other
# three agents' nodes (no diplomat: their node is their agent's tab)
python3 - "$t/cmux.json" "$t/net/.cmux" <<'PY' || fail "the halves"
import json, sys
st = json.load(open(sys.argv[1])); d = sys.argv[2]; net = d.rsplit("/.cmux", 1)[0]
panes = [p["cmds"] for p in st["panes"]]
assert len(panes) == 5, panes
left = panes[0]
assert left[0] == "markdown " + d + "/plan.md" and left[1].endswith(" watchdog '" + net + "'") and len(left) == 2, left
agents = {p[0]: p for p in panes[1:]}
assert agents["sh '" + d + "/claude/session.sh'"] == ["sh '" + d + "/claude/session.sh'", "sh '" + d + "/claude/node.sh'"], agents
for a in ("codex", "grok", "muse"):
    assert agents["sh '" + d + "/" + a + "/node.sh'"] == ["sh '" + d + "/" + a + "/node.sh'"], (a, agents)
PY
# the plan: goal, the .plan's marks, the tasks
pm=$t/net/.cmux/plan.md
head -1 "$pm" | grep -q '^## Market (codex leader)$' || fail "plan opens on its goal, headed by its leader, with no title or chain line: $(cat "$pm")"
# each item leads with its icon: its task merged and closed, open with bids, or none
grep -q '^✅ add a sub command$' "$pm" || fail "goal's done item: $(cat "$pm")"
grep -q '^⏳ add a mul command$' "$pm" || fail "goal's numbered item being bid on: $(cat "$pm")"
grep -q '^✅ Add an `abs` command, with a new test file tests/test_abs.sh.$' "$pm" || fail "an item a task paraphrases (to calc.sh put in): $(cat "$pm")"
grep -q '^⏳ Add a `sqrt` command.$' "$pm" || fail "a numbered item a task names by its step at its start"
grep -q '^✅ Add a `cube` command.$' "$pm" || fail "an item done once a bid for it merged, its task still open"
grep -q '^Keep it small.$' "$pm" || fail "goal's prose line, as it is"
grep -q '^## Goals$' "$pm" || fail "Goals heading"
! grep -q '^## Plan:' "$pm" || fail "repository name in Goals heading"
grep -q '^### 2026-11-15' "$pm" || fail "plan's day"
grep -q '^🌳 add a sub command$' "$pm" || fail "plan's done item"
grep -q '^🌱 add a mul command$' "$pm" || fail "plan's item being bid on"
grep -q '^🫘 add a div command$' "$pm" || fail "plan's item not picked up: $(cat "$pm")"
# a finished market's goal is headed Done
cp "$t/net/claude/status.txt" "$t/status.keep"; echo 'finished: every agent, as leader, found no more tasks' >> "$t/net/claude/status.txt"
( sed -n "/^ITEMS_AWK='/,/^}'\$/p; /^GOAL_AWK='/,/^}'\$/p; /^BIDS_AWK='/,/^}'\$/p" "$pc"; sed -n '/^market_title()/,/^}/p; /^render_plan()/,/^}/p; /^agents_of()/,/^}/p' "$pc" ) > "$t/fn0.sh"
( NET=$t/net ST=$t/net/.cmux; . "$t/fn0.sh"; render_plan )
head -1 "$pm" | grep -q '^## Done$' || fail "a finished market's goal headed Done: $(head -3 "$pm")"
! grep -q 'Finished' "$pm" || fail "a finished market's plan has no Finished line"
# The market keeps its opening summary visible and folds the rest before Plan.
python3 - "$pm" <<'PYGOAL' || fail "goal summary and details"
import sys
text = open(sys.argv[1]).read()
goal = text[:text.index("## Goals")]
summary, details = goal.split("<details>", 1)
assert "✅ add a sub command" in summary
assert "add a mul command" not in summary
assert "<summary>Details</summary>" in details
assert "⏳ add a mul command" in details and "Keep it small." in details
assert details.rstrip().endswith("</details>")
PYGOAL
# Prose keeps its complete opening paragraph; a short goal needs no empty fold.
cp "$t/goal.txt" "$t/goal.keep"
printf '\nBuild a compact project.\nA wrapped summary line.\n\nDetailed rules.\n\nMore rules.\n' > "$t/goal.txt"
( NET=$t/net ST=$t/net/.cmux; . "$t/fn0.sh"; render_plan )
python3 - "$pm" <<'PYGOAL' || fail "prose summary"
import sys
text = open(sys.argv[1]).read().split("## Goals", 1)[0]
summary, details = text.split("<details>", 1)
assert "Build a compact project.\nA wrapped summary line." in summary
assert "Detailed rules." in details and "More rules." in details
PYGOAL
printf 'Only the summary.\n\n' > "$t/goal.txt"
( NET=$t/net ST=$t/net/.cmux; . "$t/fn0.sh"; render_plan )
python3 - "$pm" <<'PYGOAL' || fail "short goal has no empty details"
import sys
text = open(sys.argv[1]).read().split("## Goals", 1)[0]
assert "Only the summary." in text and "<details>" not in text
PYGOAL
cp "$t/goal.keep" "$t/goal.txt"
( NET=$t/net ST=$t/net/.cmux; . "$t/fn0.sh"; render_plan )
# while a leader is drawn, Market alone
sed '1s/leader codex/leader (drawing)/' "$t/status.keep" > "$t/net/claude/status.txt"; ( NET=$t/net ST=$t/net/.cmux; . "$t/fn0.sh"; render_plan )
head -1 "$pm" | grep -q '^## Market$' || fail "goal headed Market while a leader is drawn: $(head -1 "$pm")"
cp "$t/status.keep" "$t/net/claude/status.txt"; ( NET=$t/net ST=$t/net/.cmux; . "$t/fn0.sh"; render_plan )
head -1 "$pm" | grep -q '^## Market (codex leader)$' || fail "goal headed by its leader again"
grep -q '^~~add a pow command~~$' "$pm" || fail "plan's dropped item"
! grep -q 'a note' "$pm" || fail "plan shows a # note"
# Internal task records stay hidden; the plan still reflects their progress.
! grep -q '^## Tasks$' "$pm" || fail "internal tasks section is visible"
! grep -q 'Task 8 —' "$pm" || fail "internal task row is visible"
! grep -q 'Keep this multiline task specification' "$pm" || fail "internal task body leaked"
grep -q '^🪴 add a cube command$' "$pm" || fail "merged partial work is not a plan checkmark"
# The bids: each a details block, its icon and title in the summary
grep -q '^## Contributions$' "$pm" || fail "the bids headed Contributions"
grep -q '^<summary>📈 Fulfills goal step 1: calc can subtract</summary>$' "$pm" || fail "a merged bid, under the leader's title: $(cat "$pm")"
grep -q '^\*\*Adds a sub case to calc.sh\*\*$' "$pm" && grep -q '^sub &amp; its test$' "$pm" || fail "a merged bid's own title and its note, escaped, inside"
grep -q '^<summary>🎫 Adds mul</summary>$' "$pm" || fail "a pending bid, under its bidder's title"
grep -q '^<summary>📉 Breaks the existing tests</summary>$' "$pm" && grep -q '^_Rejected: it breaks &lt;test.sh&gt;_$' "$pm" || fail "a rejected bid, under the leader's title, its reason inside"
grep -q '^<summary>🪦 old mul</summary>$' "$pm" || fail "a cleared bid, under its note"
[ "$(grep -c '^<details>$' "$pm")" = 8 ] && [ "$(grep -c '^</details>$' "$pm")" = 8 ] || fail "a details block for the goal and each bid"
# unchanged, it isn't rewritten (the view doesn't redraw for nothing)
touch -t 202001010000 "$pm"
( sed -n "/^ITEMS_AWK='/,/^}'\$/p; /^GOAL_AWK='/,/^}'\$/p; /^BIDS_AWK='/,/^}'\$/p" "$pc"; sed -n '/^market_title()/,/^}/p; /^render_plan()/,/^}/p' "$pc"; sed -n '/^agents_of()/,/^}/p' "$pc" ) > "$t/fn.sh"
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
# the run's record, outside NET: made by up, never a key
rec=$(cat "$t/net/.cmux/record"); case $rec in "$t/runs/net-"*) ;; *) fail "the record under PANTHEON_RUNS: $rec" ;; esac
[ -f "$rec/run.txt" ] && [ -f "$rec/claude/status.txt" ] && [ -f "$rec/claude/genesis.json" ] && [ -f "$rec/goal.txt" ] || fail "up records the run: $(ls -R "$rec")"
grep -q "its record .* is kept in $rec" "$t/out" || fail "up says where the record is"
[ -z "$(find "$t/runs" -name key.json)" ] || fail "a key in the record"

# no second up, and none while its nodes run elsewhere
if ( cd "$t" && sh "$pc" up net ) > "$t/out2" 2>&1; then fail "a second up"; fi
grep -q "is up already" "$t/out2" || fail "a second up's refusal: $(cat "$t/out2")"


# Idle alone is not a stall: an empty inbox must never wake a diplomat.
cp "$t/net/.cmux/claude/surface" "$t/watched"
echo idle > "$t/state"; : > "$t/ledger"
echo 99 > "$t/net/.cmux/claude/watchdog"
for pass in 1 2 3; do sh "$pc" watchdog "$t/net" --once > /dev/null; done
! grep -q '^paste' "$t/ledger" || fail "nudged an idle diplomat with no request"
[ ! -e "$t/net/.cmux/claude/watchdog" ] || fail "empty inbox retained an old idle count"

# Only live unanswered requests count; malformed/expired/already-answered
# request directories can remain briefly while the backend cleans them up.
inbox=$t/net/.cmux/claude/inbox
request() {
  mkdir -p "$inbox/$1"
  echo $(( $(date +%s) + 3600 )) > "$inbox/$1/deadline"
  echo fixture > "$inbox/$1/prompt.txt"
}
request 1794000000-abcd; echo 1 > "$inbox/1794000000-abcd/deadline"
request 1794000001-abcd; : > "$inbox/1794000001-abcd/reply.txt"
request 1794000002-abcd; : > "$inbox/1794000002-abcd/done"
request 1794000003-abcd; : > "$inbox/1794000003-abcd/expired"
request 1794000004-abcd; echo invalid > "$inbox/1794000004-abcd/deadline"
for pass in 1 2; do sh "$pc" watchdog "$t/net" --once > /dev/null; done
! grep -q '^paste' "$t/ledger" || fail "nudged for a resolved or invalid request"

request 1794000005-abcd
sh "$pc" watchdog "$t/net" --once > /dev/null
! grep -q '^paste' "$t/ledger" || fail "nudged after one idle pass"
sh "$pc" watchdog "$t/net" --once > "$t/wd"
grep -q "^paste .*--submit Your inbox still has an unanswered request (1794000005-abcd)" "$t/ledger" || fail "no nudge for a persistent unanswered request"
grep -q "nudged it back" "$t/wd" || fail "the nudge isn't reported"

# A new request starts its own grace period, regardless of the old counter.
: > "$inbox/1794000005-abcd/reply.txt"
request 1794000006-abcd
: > "$t/ledger"
sh "$pc" watchdog "$t/net" --once > /dev/null
! grep -q '^paste' "$t/ledger" || fail "a new request inherited the old idle count"
sh "$pc" watchdog "$t/net" --once > /dev/null
grep -q '^paste' "$t/ledger" || fail "the new unanswered request never got a nudge"

# Muse-style background waits remain live even when cmux says idle.
# The real wait command's lease lifecycle is covered by test/inbox-wait.sh.
echo $(( $(date +%s) + 3600 )) > "$inbox/.waiting.$$"
: > "$t/ledger"
for pass in 1 2 3; do sh "$pc" watchdog "$t/net" --once > /dev/null; done
! grep -q '^paste' "$t/ledger" || fail "nudged a live background wait"
[ ! -e "$t/net/.cmux/claude/watchdog" ] || fail "background wait retained an idle count"
sh "$pc" watchdog "$t/net" --check | grep -q 'idle (waiting for inbox)' || fail "--check does not explain the background wait"
# A dead PID or expired lease cannot suppress recovery.
rm "$inbox/.waiting.$$"
echo $(( $(date +%s) + 3600 )) > "$inbox/.waiting.99999999"
echo 1 > "$inbox/.waiting.$$"
for pass in 1 2; do sh "$pc" watchdog "$t/net" --once > /dev/null; done
grep -q '^paste' "$t/ledger" || fail "stale wait leases suppressed a needed nudge"
rm "$inbox/.waiting.99999999" "$inbox/.waiting.$$"

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
# each term's leader, from the history line: said once, and kept in leaders.log
rm -f "$t/net/.cmux/leaders.log"
printf 'height 50  term 2  leader grok\nhistory  codex grok\n' > "$t/net/claude/status.txt"
sh "$pc" watchdog "$t/net" --once > "$t/wd"
grep -q '^pantheon-cmux: term 1: codex leads (seen at h50)$' "$t/wd" && grep -q '^pantheon-cmux: term 2: grok leads (seen at h50)$' "$t/wd" || fail "the watchdog says each term's leader: $(cat "$t/wd")"
printf 'height 61  term 4  leader claude\nhistory  codex grok muse claude\n' > "$t/net/claude/status.txt"
sh "$pc" watchdog "$t/net" --once > "$t/wd"
! grep -q 'term [12]:' "$t/wd" || fail "a leader said twice: $(cat "$t/wd")"
grep -q 'term 3: muse leads (seen at h61)' "$t/wd" && grep -q 'term 4: claude leads (seen at h61)' "$t/wd" || fail "a term shorter than a pass is said too: $(cat "$t/wd")"
[ "$(cut -d' ' -f1-3 "$t/net/.cmux/leaders.log" | tr '\n' ,)" = "1 codex 50,2 grok 50,3 muse 61,4 claude 61," ] || fail "leaders.log: $(cat "$t/net/.cmux/leaders.log")"
# the history line holds the last 8 terms' leaders: numbered back from the term
printf 'height 140  term 12  leader (drawing)\nhistory  grok muse claude codex grok muse claude codex\n' > "$t/net/claude/status.txt"
sh "$pc" watchdog "$t/net" --once > "$t/wd"
[ "$(grep -c 'leads' "$t/wd")" = 8 ] && grep -q 'term 5: grok leads (seen at h140)' "$t/wd" && grep -q 'term 12: codex leads' "$t/wd" || fail "terms numbered back from the term: $(cat "$t/wd")"
# a finished market: an idle diplomat is done, so no nudge, and the loop ends
printf 'height 44  term 3  leader \nfinished: every agent, as leader, found no more tasks\n' > "$t/net/claude/status.txt"; : > "$t/ledger"
sh "$pc" watchdog "$t/net" --once > /dev/null; sh "$pc" watchdog "$t/net" --once > /dev/null; sh "$pc" watchdog "$t/net" --once > /dev/null
! grep -q '^paste' "$t/ledger" || fail "nudged a diplomat of a finished market"
sh "$pc" watchdog "$t/net" --check | grep -q "watchdog: claude finished" || fail "--check names a finished market's diplomat"
timeout 20 sh "$pc" watchdog "$t/net" > "$t/wd" 2>&1 || fail "the watchdog's loop didn't end for a finished market"
grep -q "the market finished" "$t/wd" || fail "the watchdog says why it stops: $(cat "$t/wd")"
# the watchdog keeps the workspace's name, the plan and the finish notice, and
# puts no node lines in the sidebar
grep -q "^rename-workspace --workspace .* Done$" "$t/ledger" || fail "the watchdog names the workspace Done: $(grep rename-workspace "$t/ledger")"
! grep -q '^set-status' "$t/ledger" || fail "the watchdog put a line in the sidebar"
head -1 "$t/net/.cmux/plan.md" | grep -q '^## Done$' || fail "the watchdog renders the plan: $(head -1 "$t/net/.cmux/plan.md")"
[ -e "$t/net/.cmux/finished" ] && [ -e "$t/net/.cmux/claude/inbox/finished" ] && grep -q '^notify --title Pantheon: the market finished' "$t/ledger" || fail "the watchdog tells the diplomats and you the market finished"
printf 'height 45  term 4  leader muse\n' > "$t/net/claude/status.txt"; rm -f "$t/net/.cmux/finished"; : > "$t/ledger"
( timeout 3 sh "$pc" watchdog "$t/net" > /dev/null 2>&1 || true )
[ "$(grep -c '^rename-workspace --workspace .* Market (muse leader)$' "$t/ledger")" = 1 ] || fail "the watchdog names the workspace for its leader, once: $(grep rename-workspace "$t/ledger")"
# a finishing market whose leaders begin to say there are no more tasks: the count
title() { ( NET=$t/net ST=$t/net/.cmux; . "$t/fn0.sh"; market_title ); }
printf 'height 46  term 5  leader grok\nno more tasks: 1 of 4, say muse\n' > "$t/net/claude/status.txt"
[ "$(title)" = "Market (grok leader, 1/4 to done)" ] || fail "the title with a leader and the count: $(title)"
printf 'height 47  term 5  leader (drawing)\nno more tasks: 2 of 4, say muse grok\n' > "$t/net/claude/status.txt"
[ "$(title)" = "Market (2/4 to done)" ] || fail "the title while a leader is drawn, with the count: $(title)"
( NET=$t/net ST=$t/net/.cmux; . "$t/fn0.sh"; render_plan ); head -1 "$t/net/.cmux/plan.md" | grep -q '^## Market (2/4 to done)$' || fail "the plan headed with the count: $(head -1 "$t/net/.cmux/plan.md")"
printf 'height 43  term 2  leader grok\n' > "$t/net/claude/status.txt"

# down: the record is finished, and kept when NET is gone
echo '{"h":9,"txs":[]}' > "$t/net/codex/blocks.log"
sh "$pc" down "$t/net" > "$t/out3"
cmp -s "$t/net/codex/blocks.log" "$rec/codex/blocks.log" || fail "down records the last blocks"
grep -q "its record .* is kept in $rec" "$t/out3" || fail "down says where the record is: $(cat "$t/out3")"
[ -z "$(find "$t/runs" -name key.json)" ] || fail "a key in the record after down"
grep -q "^close-workspace --force --workspace " "$t/ledger" || fail "down closes the workspace"
[ ! -e "$t/net/.cmux/workspace" ] || fail "down forgets the workspace"

# the grid layout: a pane per agent, each node's tab and a diplomat's
: > "$t/ledger"
( cd "$t" && sh "$pc" up net --layout grid --diplomats "claude" -- --goal goal.txt ) > "$t/out" || fail "up --layout grid"
n=$(grep -c '^new-split' "$t/ledger" || true); [ "$n" = 3 ] || fail "a pane per agent: 3 splits, not $n"
! grep -q '^markdown' "$t/ledger" || fail "the grid has no plan's view"
for a in claude codex grok muse; do grep -q "rename-tab .* $a node" "$t/ledger" || fail "$a's node tab (grid)"; done
grep -q "rename-tab .* claude diplomat" "$t/ledger" || fail "claude's diplomat tab (grid)"
grep -q "rename-tab .* watchdog" "$t/ledger" && ! grep -q "rename-tab .* status" "$t/ledger" || fail "the grid's watchdog tab, and no status tab"
if sh "$pc" up "$t/net" --layout tiles > "$t/out4" 2>&1; then fail "--layout tiles"; fi
grep -q -- "--layout tiles: plan" "$t/out4" || fail "--layout tiles refused: $(cat "$t/out4")"
sh "$pc" down "$t/net" > /dev/null
echo "PASS pantheon-cmux: a network as a cmux workspace (the plan beside a pane per agent, or a grid), its name, watchdog and down"
