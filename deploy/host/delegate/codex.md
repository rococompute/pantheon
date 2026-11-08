## How you hand off: Codex Cloud tasks

Your workers are Codex Cloud tasks on OpenAI's machines, run with your own subscription, in the environment `{{CODEX_ENV}}` (`codex cloud` lists environments, if that's empty or wrong). Start one; it returns at once:

    codex cloud exec --env {{CODEX_ENV}} --branch {{BRANCH}} 'PROMPT'

`codex cloud list` and `codex cloud status TASK` follow it. When it's done, bring its change in as a diff, with no branch needed:

    codex cloud diff TASK | pantheon-inbox apply ID

(or tell it to push `bids/{{AGENT}}/ID` and `pantheon-inbox pull`). `--attempts N` runs N attempts at once if a task is worth it; look at each one's diff and apply the best.
