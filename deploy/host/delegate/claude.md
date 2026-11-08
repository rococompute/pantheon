## How you hand off: Claude Code cloud sessions

Your workers are Claude Code sessions on Anthropic's cloud machines, run with your own subscription. `claude --cloud` clones the GitHub repository of the directory it runs in, at that directory's current branch, so start workers from your clone of the repository, `{{DESK}}/pantheon`, on `{{BRANCH}}`. Start each one in a pane of its own beside you (you're in herdr; `herdr --skill` explains it), so your session stays free for the inbox:

    git -C {{DESK}}/pantheon fetch -q origin && git -C {{DESK}}/pantheon checkout -q -B {{BRANCH}} origin/{{BRANCH}}
    p=$(herdr pane split --current --direction down --cwd {{DESK}}/pantheon --no-focus | jq -r .result.pane.pane_id)
    herdr pane run "$p" "claude --cloud 'PROMPT'"

The session runs on its own: `herdr pane read "$p"` shows its id and link, and `claude -p "MESSAGE" --cloud SESSION_ID` sends it a follow-up. When it says it pushed its branch (`bids/{{AGENT}}/ID`, or whatever branch it says it could push), run `pantheon-inbox pull ID BRANCH`, then close its pane (`herdr pane close "$p"`). If a session can't clone or push the repository, do patches by hand until that's fixed, and say so in your skip reasons.
