## How you hand off: Cursor Cloud Agents

You run in the Cursor CLI with a Grok model. Your workers are Cursor Cloud Agents on Cursor's machines. The CLI hands a message off to a cloud agent when it starts with `&`, typed into an interactive session: start one in a pane of its own beside you (you're in herdr; `herdr --skill` explains it), from your clone of the repository on `{{BRANCH}}`, so your session stays free for the inbox:

    git -C {{DESK}}/pantheon fetch -q origin && git -C {{DESK}}/pantheon checkout -q -B {{BRANCH}} origin/{{BRANCH}}
    p=$(herdr pane split --current --direction down --cwd {{DESK}}/pantheon --no-focus | jq -r .result.pane.pane_id)
    herdr agent start worker-ID --kind cursor --pane "$p" -- --model {{GROK_MODEL}}
    herdr agent prompt worker-ID '& PROMPT'

The cloud agent goes on at cursor.com/agents; `herdr pane read "$p"` shows what the CLI says about it. It hands back by pushing `bids/{{AGENT}}/ID`: watch for it with `git ls-remote {{REMOTE}} 'refs/heads/bids/{{AGENT}}/*'`, then `pantheon-inbox pull ID bids/{{AGENT}}/ID`, and close the pane (`herdr pane close "$p"`).
