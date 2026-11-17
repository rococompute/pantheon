# Market prompts

The market's model-facing prose lives in named Soma string bindings, separate
from the agent state machine and host I/O. Long values are lists of readable
string fragments joined by `prompt_text`; joining inserts no whitespace.

| File | Named text |
| --- | --- |
| `common.soma` | Identity, untrusted-data policy/fences, task and edit labels |
| `draft.soma` | Task selection, parallel work, task-writing instructions and JSON format |
| `patch.soma` | Bidder instructions, previous rejections, context and edit format |
| `pick.soma` | Leader review/merge criteria, completion/closure and reply format |
| `attest.soma` | Merge attestation and plan-mark instructions |
| `context.soma` | Repository/plan/file context labels and missing/truncated data messages |

`core/agent.soma` assembles the four roles from these bindings and market data.
`runtime/node.soma` supplies repository content and expands `{{F}}`, `{{REPOS}}`,
`{{PLAN}}` and `{{REPO}}`. Keep the fence boundaries, defanging, replacement order
and JSON fields intact when editing wording. Repository and peer content remains
untrusted data; moving the strings does not change that boundary.

Diplomat session instructions already have their own templates:
`integrations/cmux/diplomat.md`, `deploy/host/diplomat.md` and the provider files
under `deploy/host/delegate/`. The standalone launcher points its session at the
inbox's instructions endpoint.

These are compiled templates. Rebuild Pantheon to use an edit; an already-running
node and an already-posted task retain their previous text. Changing prompt source
does not rewrite active tasks, restart diplomats or discard outstanding bids.

Checks:

```sh
sh test/prompt-assembly.sh
sh test/llm-soma-prompt.sh
soma run test/prompt_dump.soma
```

The dump uses fixed fixture data, not a live network or credentials. Full role
fingerprints guard wording and assembly together. The initial extraction was also
compared against complete pre-refactor dumps, byte for byte. The old fingerprints
were already stale before extraction and were refreshed from that captured text.
