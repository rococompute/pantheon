# A repository's plan: .plan

Each governed repository keeps its plan in `.plan` at its root, in the
format John Carmack used for his .plan files at id Software. A term leader
drafts the next task from the plan's open items, and the bid that does the
task marks its item done. So the plan changes the way the code does, through
the market, and anyone who opens the repository's default branch sees what's
next and what's done.

## The format

One item per line, under the day it was written. A line that is only a date
starts a day. The marks:

| Line | Means |
|---|---|
| `2026-11-09` | a new day's section |
| `P-2: the node's git runs a filter ... (docs/SECURITY-REVIEW-2.md P-2)` | open: not done yet |
| `* page flip fixed` | done that day |
| `+ P-2: the node's git ...` | an older item, done later (marked in place) |
| `- an idea we decided against` | dropped |
| `# a note` | a note about the file, not an item |

`*` and `+` are Carmack's. He wrote what he did each day as `*` lines and
what came up but wasn't done as plain lines, then went back and marked those
`+` as he got to them. `-` (dropped) is Pantheon's addition.

The order is the priority: the first open item is the next one. Keep each
item one line and make it a pointer. Say what's wrong or wanted in a few
words, then name the files that have the details: a review finding, a
design note, the code, the test that will judge it.

## Pruning

Marked lines (`*`, `+`, `-`) are history, and the file keeps only what's
left: once a marked line has landed on the default branch, delete it, and
delete a day's date when nothing under it is open. `git log -p .plan` keeps
every line ever written, with the commit that marked it. Models only ever
get the open lines, but a bidder with tools reads the whole file, and so do
people, so a plan that's never pruned grows without bound.

A bid still marks its item `+ ` rather than deleting it: an attestor sees
which item the bid claims, and the leader sees it done. Prune between
epochs, or as its own small task.

## Why a file, and not goal lines in the prompt

A model gets only the open items (the lines above, a few hundred bytes each),
never the whole plan or the documents behind it. A bidder with tools reads the
files an item points at in its checkout, as much as it needs. The plan grows
without every prompt growing with it, and changing it needs no node restart:
the leader reads `.plan` at the repository's head each time it drafts.

## How the market uses it

- **Drafting:** the leader's prompt has each repository's open items, in
  order, under "Each repository's plan" (shell.ml `plan_text`). The leader
  takes the first open item no task already covers. The task quotes the item,
  names `.plan` and the item's files as context, and includes marking the
  item done.
- **Bidding:** the bid does the work and puts `+ ` before the item's line in
  `.plan`.
- **Attesting:** an attestor sees that change in the bid's edits, like any
  other.
- **Operator goals:** `--goal FILE` lines still work. They come first in the
  leader's prompt, as the operator's direction. A leader drafts only when the
  node has at least one goal line, so give a line such as "Work through each
  repository's .plan, in order".

## Reading it

```bash
pantheon plan            # ./.plan's open items, one per line
pantheon plan soma/.plan
```
