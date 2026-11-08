#!/bin/bash
# The inbox over HTTPS (scripts/inbox-http.py), end to end: the node's side is
# the real scripts/bidder-inbox.sh, the agent's is curl, as a cloud agent's is.
# Needs main.exe (soma build main.soma), python3, curl, jq.
set -u
cd "$(dirname "$0")/.."
BIN=$PWD/main.exe
[ -x "$BIN" ] || { echo "no main.exe: run soma build main.soma"; exit 1; }
T=$(mktemp -d); trap 'kill $srv 2>/dev/null; rm -rf "$T"' EXIT
fail() { echo "FAIL inbox-http: $*"; exit 1; }
mkdir -p "$T/inbox" "$T/other"
port=$((28200 + RANDOM % 500))
tok=$(python3 scripts/inbox-http.py token "$T/config.json" claude "$T/inbox")
tok2=$(python3 scripts/inbox-http.py token "$T/config.json" codex "$T/other")
jq --arg l "127.0.0.1:$port" --arg u "http://127.0.0.1:$port" '.listen = $l | .url = $u' "$T/config.json" > "$T/c" && mv "$T/c" "$T/config.json"
python3 scripts/inbox-http.py serve "$T/config.json" 2> "$T/server.log" & srv=$!
U=http://127.0.0.1:$port
for _ in $(seq 50); do curl -sf "$U/health" >/dev/null && break; sleep 0.1; done
api() { curl -s -H "Authorization: Bearer $tok" "$@"; }

# no token, a wrong token
[ "$(curl -s -o /dev/null -w '%{http_code}' "$U/v1/wait")" = 401 ] || fail "a request without a token wasn't refused"
[ "$(curl -s -o /dev/null -w '%{http_code}' -H 'Authorization: Bearer nope' "$U/v1/wait")" = 401 ] || fail "a wrong token wasn't refused"
api "$U/v1/instructions" | grep -q "You are claude" || fail "the instructions don't name the agent"

# an answer: the node asks, the agent replies, the node gets the reply
echo 'Attest: reply {"approve": true, "reason": "..."}' | PANTHEON_INBOX=$T/inbox sh scripts/bidder-inbox.sh > "$T/answer.out" & node=$!
w=$(api "$U/v1/wait?seconds=10"); id=$(echo "$w" | jq -r .id)
[ "$(echo "$w" | jq -r .kind)" = answer ] || fail "wait gave $w"
[ "$(api "$U/v1/wait?seconds=1" | jq -r .id)" = null ] || fail "a taken request was given out again"
[ "$(api -o /dev/null -w '%{http_code}' --data-binary 'not json' "$U/v1/reply/$id")" = 400 ] || fail "a reply that isn't JSON was taken"
api --data-binary '{"approve": true, "reason": "fine"}' "$U/v1/reply/$id" | jq -e .ok >/dev/null || fail "the reply wasn't taken"
wait $node; grep -q '"approve": true' "$T/answer.out" || fail "the node didn't get the reply: $(cat "$T/answer.out")"

# another agent's token can't see or answer claude's requests
echo 'Draft: reply {}' | PANTHEON_INBOX=$T/inbox sh scripts/bidder-inbox.sh > /dev/null & node=$!
sleep 1; id=$(api "$U/v1/list" | jq -r '.requests[0].id')
as2() { curl -s -H "Authorization: Bearer $tok2" "$@"; }
[ "$(as2 "$U/v1/list" | jq '.requests | length')" = 0 ] || fail "codex's token lists claude's requests"
[ "$(as2 -o /dev/null -w '%{http_code}' --data-binary '{"task": "x"}' "$U/v1/reply/$id")" = 404 ] || fail "codex's token answered claude's request"
api --data-binary '{"task": "x"}' "$U/v1/reply/$id" >/dev/null; wait $node

# a patch: the checkout over HTTP, a diff back, the node's edits from it
wt=$T/wt; git init -q "$wt"; printf 'one\n' > "$wt/a.txt"; mkdir "$wt/d"; printf 'x\n' > "$wt/d/b.txt"
git -C "$wt" add -A; git -C "$wt" -c user.name=t -c user.email=t@t commit -qm head
echo 'Write a patch' | PANTHEON_INBOX=$T/inbox INBOX_URL=$U PANTHEON_WORKTREE=$wt PANTHEON_BIN=$BIN sh scripts/bidder-inbox.sh > "$T/patch.out" & node=$!
w=$(api "$U/v1/wait?seconds=10"); id=$(echo "$w" | jq -r .id)
[ "$(echo "$w" | jq -r .kind)" = patch ] || fail "wait gave $w"
echo "$w" | jq -r .prompt | grep -q "/v1/done/$id" || fail "the patch prompt doesn't say how to hand in over HTTP"
api -o "$T/co.tgz" "$U/v1/checkout/$id.tar.gz"; mkdir "$T/agent"; tar -xzf "$T/co.tgz" -C "$T/agent"
[ "$(cat "$T/agent/checkout/d/b.txt")" = x ] || fail "the checkout is wrong"
[ ! -e "$T/agent/checkout/.git" ] || fail "the checkout carried the node's .git"
( cd "$T/agent/checkout" && git init -q && git add -A && git -c user.name=t -c user.email=t@t commit -qm head \
  && printf 'two\n' > a.txt && printf 'new\n' > c.txt && git add -A && git diff --cached > ../change.diff )
bad=$(jq -n --rawfile d "$T/agent/change.diff" '{note: "x", diff: ($d | sub("one"; "zero"))}')
[ "$(echo "$bad" | api -o /dev/null -w '%{http_code}' --data-binary @- "$U/v1/done/$id")" = 400 ] || fail "a diff that doesn't apply was taken"
jq -n --rawfile d "$T/agent/change.diff" '{note: "a.txt says two; c.txt", diff: $d}' | api --data-binary @- "$U/v1/done/$id" | jq -e .ok >/dev/null \
  || fail "the diff wasn't taken"
wait $node
jq -e '.note == "a.txt says two; c.txt" and ([.edits[].path] | sort) == ["a.txt", "c.txt"]' "$T/patch.out" >/dev/null \
  || fail "the node's edits are wrong: $(cat "$T/patch.out")"

# a usage limit reaches the node
echo 'Draft' | PANTHEON_INBOX=$T/inbox sh scripts/bidder-inbox.sh > "$T/limit.out" & node=$!
api --data-binary 'Usage limit reached, resets in 2h' "$U/v1/limited" | jq -e .ok >/dev/null || fail "limited wasn't taken"
wait $node; grep -q '^!usage limit reached.*resets in 2h' "$T/limit.out" || fail "the node didn't hear the limit: $(cat "$T/limit.out")"

echo "ok inbox-http: answers, a patch by diff, a limit, and tokens kept apart, over HTTP"
