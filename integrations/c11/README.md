# c11: a Pantheon network as a c11 workspace

`pantheon-c11` runs a network (a directory made by `pantheon init`) as one
[c11](https://github.com/stage-11-agentics/c11) workspace on a Mac. It is
[`../cmux/pantheon-cmux`](../cmux/README.md) with c11's adapter,
[`mux.sh`](mux.sh), in place of its calls to cmux. The commands, the layout,
the plan view, the watchdog, the run record and the event relay are the same,
and the cmux README describes them. This page covers only what differs.

```
pantheon-c11 up NET [--diplomats "A B"] [--backends A=B,...] [--layout plan|grid] [-- NODE ARGS...]
pantheon-c11 watchdog NET [--check|--once]
pantheon-c11 down NET
```

**Run it from a c11 terminal.** By default c11's socket admits only processes
that c11 started, so from cmux, Terminal or a cron job every call fails with
"Access denied". `pantheon-c11` checks this first (`c11 ping`) and says so.

## Try it

From a c11 terminal, in this checkout, start with scripted nodes:

```bash
mkdir -p .calc && cp -R examples/calc/. .calc/ && git -C .calc init -q && git -C .calc add -A && git -C .calc -c user.name=you -c user.email=you@example.com commit -qm calc
./main.exe init .net --repo calc=.calc --block-ms 300 --param term_blocks=40 --param max_merges=1 --param finish=1
integrations/c11/pantheon-c11 up .net -- --goal examples/calc/SCRIPTED_GOAL.md --bid-window 8
```

To make an agent a diplomat, add `--diplomats claude` (before `--`) and give
it the model goal: `-- --goal examples/calc/GOAL.md --deny test.sh --ci "sh test.sh"`.
Close it all with `integrations/c11/pantheon-c11 down .net`.

Keep `NET` inside a folder Claude Code already trusts, such as this checkout. A
diplomat's session starts in `NET/.c11/AGENT/desk`, and in a folder Claude
Code hasn't trusted it opens on the trust prompt before its first turn, even
with `--dangerously-skip-permissions`. The watchdog reports that as waiting on
you and sends a notification; choose "Yes, I trust this folder" in the
diplomat's panel.

## What differs from cmux

| | cmux | c11 |
|---|---|---|
| State | `NET/.cmux` | `NET/.c11` (and `plan.html`, `plan-surface`: the page and its panel) |
| Places | panes and tabs | areas and panels (`c11 tree --workspace W` shows them) |
| Plan view | `cmux markdown open` on `plan.md` | a page, `plan.html`, in a browser area. c11's markdown viewer shows raw HTML as text (markdown-it with `html: false`, then DOMPurify), so the plan's `<details>` blocks wouldn't fold there. `plan-html.py` writes the page from `plan.md` whenever the watchdog rewrites the plan, and the watchdog reloads the panel (`c11 browser --panel P reload`). The goal's checklist (each step with its status, ✅ ⏳ 🟡) is always in view above its fold, and only the goal's remaining text is folded under Details. The page keeps its open folds and its scroll across reloads (in `sessionStorage`). `plan.md` stays, for the run record. |
| Session state | `cmux current --json` | `c11 fleet --json` (`working`, `waiting`, `idle`, `cold`). An open blocking ask in `c11 feed list`, or a dialog on the panel's screen (`c11 input-state`), counts as waiting on you. Any other ended turn counts as idle. |
| Nudges, event notices | `cmux agent message`, delivered at the next hook step, even mid-turn | c11 mail from `Pantheon` (`c11 mailbox send --to id:PANEL`). `up` sets the diplomat panel's `mailbox.delivery=stdin`, so c11 rings it when the session is idle. Claude Code gets the notice inline as a `<c11-msg>` block. Other CLIs get the line `c11 mail waiting: run c11 mailbox recv --ack`. |
| Mail size | none | at most 4096 bytes per message, so the relay sends long event batches in parts |

Event notices are not delivered mid-turn. A diplomat that works its inbox in
one long turn reads them when it is next idle, or when it runs
`c11 mailbox recv --ack` itself, as its instructions suggest. Its inbox carries
the requests either way: notices only tell it about closed tasks and merges
sooner.

c11's size-aware splits keep areas usable. In a narrow window the agents'
grid stacks into one column instead of two rows (c11 prints a `note:` when it
does).

## Settings

- `C11`: the c11 CLI. The default is the one that came with this c11
  terminal (`C11_BUNDLED_CLI_PATH`), then `c11` on PATH, then the one inside
  c11.app. It is never `cmux`: c11's cask links a `cmux` shim to c11's CLI, and
  cmux's CLI doesn't take c11's flags.
- c11's CLI prefers `CMUX_SOCKET_PATH` over its own discovery, so a shell
  that came from cmux would talk to cmux's socket. The adapter sets
  `C11_SOCKET` from `C11_SOCKET_PATH` to prevent that. Without an explicit
  C11 socket or C11 socket-path hint, it clears inherited `CMUX_SOCKET_PATH`
  and `CMUX_SOCKET` so C11 can discover its own socket.
- Everything else (`PANTHEON`, `DIPLOMAT_CLI`, `GROK_MODEL`, `PANTHEON_RUNS`,
  `PANTHEON_EVENTS`) is as for cmux.

## Tests

`sh test/integration-c11.sh` tests the adapter against a stub of c11's CLI:
the workspace and its areas, the diplomat's mail settings, the watchdog's
reading of fleet, feed and input state, its mail and notices, the relay's
mail, and `down`. `sh test/integration-cmux.sh` covers the logic they share.

## Adding another multiplexer

Every call that `pantheon-cmux` makes to its multiplexer goes through a
`mux_*` function (`mux_new_workspace`, `mux_split`, `mux_new_tab`,
`mux_markdown`, `mux_state`, `mux_message` and the others, listed together near
its top). Copy `mux.sh`, write those functions for the new tool, and add an
entry script like `pantheon-c11` that sets `PANTHEON_MUX` to the folder's name.

## Checkpoint status

The adapter, shared cmux refactor, plan renderer and stub regressions are
committed as a checkpoint. Current changes have not been validated against a
live C11 workspace. See [HANDOFF.md](HANDOFF.md) for results and remaining work.
