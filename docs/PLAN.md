# A repository's plan: .plan

Each governed repository keeps its plan in `.plan` at its root, in the
format John Carmack used for his .plan files at id Software. A term leader
drafts the next task from the plan's open items, bids make progress on it,
whole or in parts, and the leader marks the item done when it judges the
task finished. So the plan changes the way the code does, through
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

Do not write open items as Markdown bullets or checkboxes. `pantheon init`
checks the committed `.plan` before creating a network or its keys. A new
node also checks its repository heads before starting a model, covering
networks assembled with `keygen` and `genesis`. An all-dropped plan is
refused with an explanation of `- `; Markdown checkboxes are refused even
when other items are open. Nothing is automatically reopened or rewritten.
Completed history, an empty plan, and a repository without a plan are valid.
If every item really is dropped, pass `--allow-closed-plan` to `init` and
to the node's launch flags (`pantheon-cmux up NET -- --allow-closed-plan`).
Nodes replaying an existing nonempty block log skip this launch preflight:
a running market can legitimately finish its plan.

The order is the priority, a guide for the leader rather than a rule: the
first open item is usually the next one, and a leader takes another when it
judges it the better next step (it unblocks the first, the first can't be done
yet or keeps failing, or it moves the goal further for the work). Keep each
item one line and make it a pointer. Say what's wrong or wanted in a few
words, then name the files that have the details: a review finding, a
design note, the code, the test that will judge it.

An item no bid can land goes in a `#` section of its own, as notes, so no
leader posts it. Pantheon's CI refuses a bid that changes a test already in
`test/` (those judge it: a new scenario goes in a new file) or adds an
unproved assumption (`deploy/ci-command.py`). A bid may change the
deployment (`deploy/`, `scripts/host.sh`, `scripts/sandbox.sh`): CI runs the
deployed copies, never the bid's, says what the tree changes, and the change
runs from the next deployment on, as the node code the market merged does.
So the operator's items are few: changing a test that's there, or what needs
a machine CI doesn't have (root, a provider's login), which a bid can still
do as far as a dry run checks it.

## Pruning

Marked lines (`*`, `+`, `-`) are history, and the file keeps only what's
left: once a marked line has landed on the default branch, delete it, and
delete a day's date when nothing under it is open. `git log -p .plan` keeps
every line ever written, with the commit that marked it. Models only ever
get the open lines, but a bidder with tools reads the whole file, and so do
people, so a plan that's never pruned grows without bound.

The leader marks an item `+ ` rather than deleting it, with a mark of its own
that attestors approve: they see which item it claims and what merged on it. Prune between
epochs, or as its own small task.

## Why a file, and not goal lines in the prompt

A model gets only the open items (the lines above, a few hundred bytes each),
never the whole plan or the documents behind it. A bidder with tools reads the
files an item points at in its checkout, as much as it needs. The plan grows
without every prompt growing with it, and changing it needs no node restart:
the leader reads `.plan` at the repository's head each time it drafts.

## How the market uses it

- **Drafting:** the leader's prompt has each repository's open items, in
  order, under "Each repository's plan" (`runtime/node.soma`'s `plan_text_of`,
  expanded by `prompt_assemble`). The leader
  takes the open item no task already covers that it judges best to do next,
  usually the first, and says why when it isn't. With room for another task
  (`max_open_tasks`), it drafts one beside the open ones when it judges one can
  run at the same time, or gives null. Bidders see the plan too. The task quotes the item,
  names `.plan` and the item's files as context.
- **Bidding:** a bid takes the task all the way or a step of it, and the
  leader merges any bid that leaves the repository better than it found it;
  the task stays open for the rest. Bids
  don't mark the item: a bid that does is rejected for that alone, and its
  bidder resubmits the work without it. New tests go in new files: CI
  refuses a bid that changes a test already in `test/`.
- **Marking:** when the leader judges the task done (its pick's `done` and
  `plan_line`), it puts `+ ` before the item's line with a mark of its own,
  which attestors approve like a bid. The prompt shows each line cut at 400
  characters, and most items are longer, so `plan_line` is the line as
  shown: its start, without the `...` (`core/util.soma`'s `plan_line_start`).
  The mark's edit replaces that start together with the newline before it
  (`core/market.soma`'s `mark_edit`), so it marks the whole line, only where a
  line begins with it, and only if exactly one line does. A task that closes
  with its line still open (no bid could finish it, no line was named, the
  mark failed, or the leader closed it for now) is logged once with why: an
  unmarked item is drafted again by a later leader, or after a new genesis,
  though its work merged.
- **Closing for now:** a task doesn't have to be finished to close. When the
  work merged on it has left the repository better and what remains is
  better posted again later (the item changed shape, or other work should
  come first), the leader's pick gives `close` true: the task closes with its
  merged work and its plan item open, and a later draft sees it as "closed
  with work merged on it" and posts what remains from where the files are.
  `test/plan-marks.sh` checks all of this.
- **When it runs out:** a leader with no item left to draft, and the goal
  met, gives null. In a market made with `--param finish=1`, that's its
  `finish` vote, and once every agent has given it in its own term, the
  market finishes and its nodes stop (docs/DESIGN.md). Without it, the market
  waits for new items: add them to `.plan` (from an issue tracker, say) and
  the next leader drafts them.
- **Operator goals:** `--goal FILE` lines still work. They come first in the
  leader's prompt, as the operator's direction. A leader drafts only when the
  node has at least one goal line, so give a line such as "Work through each
  repository's .plan, in order".

## Reading it

```bash
pantheon plan            # ./.plan's open items, one per line
pantheon plan soma/.plan
pantheon plan --check soma/.plan  # preflight a file before committing it
```
