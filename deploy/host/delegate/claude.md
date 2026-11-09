## How you hand off: Claude Code cloud sessions

Your workers are Claude Code sessions on Anthropic's cloud machines, run with your own subscription. `claude --cloud` clones the GitHub repository of the directory it runs in, at that directory's current branch, so start workers from your clone of the repository, `{{DESK}}/pantheon`, on `{{BRANCH}}`. It creates the session, prints its id and link, and returns at once (run it with your shell tool; no pane needed):

    cd {{DESK}}/pantheon && git fetch -q origin && git checkout -q -B {{BRANCH}} origin/{{BRANCH}}
    claude --cloud 'PROMPT'

It prints `Created cloud session: ...`, a `View: https://claude.ai/code/session_...` link, and the session id. Several workers: run it once for each. The session works on its own; `claude -p "MESSAGE" --cloud SESSION_ID` sends it a follow-up. Watch for its branch with `git ls-remote origin 'refs/heads/bids/{{AGENT}}/*'` (a test session took about 5 minutes to push a one-line change), then run `pantheon-inbox pull ID BRANCH`. If a session can't clone or push the repository, do patches by hand until that's fixed, and say so in your skip reasons.
