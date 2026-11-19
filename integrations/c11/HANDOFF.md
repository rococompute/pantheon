# C11 integration checkpoint

The human requested a checkpoint commit so a C11-focused agent can continue.
This branch is not merged. Baseline: Pantheon master at 8a026306d91c.

## What is here

- `pantheon-c11` selects the C11 adapter for the shared `pantheon-cmux` runner.
- The shared runner routes workspace/area/panel operations through `mux_*`.
  C11 state is separate in `NET/.c11`; cmux keeps `NET/.cmux`.
- C11 fleet, attention feed and input-state map to watchdog states. Dialogs
  and blocking asks require a person; ended turns can receive mailbox nudges.
- C11 mail carries committed events, with byte-bounded batches. Oversized
  single events remain queued instead of being acknowledged after truncation.
- A local HTML plan page renders the current Markdown subset and details,
  keeps folds/scroll across reloads, and escapes untrusted content. It lifts
  the goal checklist from the market-description fold while leaving repo Goals
  and Contributions folds intact.
- The relay is exec'd in its background subshell with quoted arguments;
  tests cover a CLI path containing spaces and glob characters.
- UUID parsing accepts both cases. Cross-workspace input-state/browser calls
  include the workspace. C11 socket selection avoids inherited cmux sockets.
- cmux CLI selection prefers its explicit/bundled CLI over PATH: this Mac's
  `/opt/homebrew/bin/cmux` is actually C11's compatibility shim. That shim
  rejected cmux's `close-workspace --force` during wallet-run cleanup.

## Automated validation completed

Run from the repository root:

```sh
sh test/integration-c11.sh
sh test/integration-cmux.sh
python3 test/cmux-events.py
```

All three passed at checkpoint; the event suite has 12 tests. The C11 stub
suite covers layout, lower-case UUIDs, plan rendering/escaping, lifecycle
handling, mailbox settings, relay delivery with a spaced/glob-shaped CLI,
relay shutdown, socket routing, and protected-workspace close behavior.
These tests are not evidence of native C11 behavior.

## Remaining native validation

Run from a terminal that C11 itself started. The C11 app was opened, but this
chat's process is outside its allowed ancestry: a direct socket ping returned
`ERROR: Access denied — only processes started inside c11 can connect`.
The installed CLI reported `Failed to configure socket timeout` externally.
Do not weaken the app's access policy to work around this.

1. Start with the scripted calculator recipe in README.md, without model CLIs.
2. Check real CLI result shapes/UUID ordering and cross-workspace routing;
   confirm the plan/browser area, agent areas, node tabs and watchdog tab.
3. Verify HTML reloads, folds and scroll in the actual browser panel.
4. Use a stub diplomat before a paid model. Check fleet/feed/input-state
   semantics and real mailbox acceptance/delivery, including a blocking dialog.
5. Exercise down from another workspace; if C11 protects the currently viewed
   workspace, retain its handle and report how to close it, while stopping nodes.
6. Confirm default cmux still works with C11's PATH shim installed. Consider
   CI coverage for the integration tests before merging.

There is an optional local smoke helper outside the repository at
`../.c11-integration-checks/live-smoke.py`. It prepares an
isolated calculator/network, uses a stub diplomat and scripted nodes, writes
results there, and calls down. It has not been run live. The C11 README and
checked-in tests are the portable handoff; the local helper is supplementary.


## Completion-pass observation

The shared observer now serves event relay, plan/title, readiness and leader
history. It checks matching public genesis, selects the highest recent complete
status, and reports stale/unavailable/conflicting observations without inventing
market transitions. Reader-owned files and status-pinned Git trees keep plan
rendering consistent. Its source/availability diagnostics are in
`NET/.c11/events/state.json`, as for cmux.

A sanctioned native UI attempt during the completion pass failed before any
interaction: `computer-use daemon failed to start: Computer Use onboarding is
still in progress. Finish setup in cmux, then retry.` No C11 workspace was
created, and its process-ancestry socket policy was not bypassed. Native layout,
mailbox delivery and browser behavior therefore still need the live check.
