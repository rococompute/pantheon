## How you hand off: Claude Code cloud sessions

Your workers are Claude Code sessions on Anthropic's cloud machines, run with your own subscription. Start one in a pane of its own beside you (you're in herdr; `herdr --skill` explains it), so your session stays free for the inbox:

    p=$(herdr pane split --current --direction down --no-focus | jq -r .result.pane.pane_id)
    herdr pane run "$p" "claude --cloud 'PROMPT'"

The cloud session works on its own; follow it with `herdr pane read "$p"`, or at claude.ai/code. When it says it pushed `bids/{{AGENT}}/ID`, `pantheon-inbox pull ID bids/{{AGENT}}/ID`, and close its pane (`herdr pane close "$p"`). If cloud sessions can't reach the repository, say so in the inbox's next skip reason and do patches by hand until someone fixes it.
