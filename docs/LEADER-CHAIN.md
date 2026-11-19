# Leader handoff chain

Leader work survives the turn that started it. A review, a queued check, its
result, or an investigation finding can be useful to a replacement session or
another leader. Pantheon records these as `leader-note` transactions, ordered
and authenticated by the existing market consensus. Each entry hashes its
predecessor, sequence, committed height and term, author, and payload. Records
append; there is no edit, replacement, or pruning operation.

This is a separate logical journal, not a second election or voting network.
The signed transactions in `blocks.log` remain authoritative. Its in-memory
index is rebuilt by replay, including observations from authors who no longer
lead. The market keeps the full hash-linked head/count and only the newest
twelve entries per configured repository in memory. This preserves the exact
global and per-repository prompt windows without retaining the entire archive
in RAM. `leader-note` admission requires an existing repository, so arbitrary
repository names cannot create more windows. Journal traffic does not reset
the leader's inactivity timer.

Each node also projects that history into `HOME/leader-chain.git`, on branch
`leader-chain`. Every record has a Git commit and a create-only
`refs/pantheon/entries/HASH` ref. Commit messages contain the JSON record.
Fixed Git metadata produces identical histories on replicas. Replaying an
entry verifies the existing commit and does not append it twice. Forks or
rewrites are refused; a persistence failure stops the node so restart can
retry from the committed block history.

## Reading and contributing

```sh
pantheon leader-chain HOME
git -C HOME/leader-chain.git log leader-chain
pantheon leader-note HOME wallet HEAD 'Reproduction: ...; remaining work: ...'
```

`leader-chain` prints JSONL in commit order. `leader-note` resolves the named
commit in `HOME/repos/wallet`, attaches its tree and commit ID, and queues the
signed observation. It is not committed until consensus includes it. The
author must be on the current roster and within the repository's scope.

Leader pick replies can supply `handoff`: useful findings, checks, blockers,
and remaining work. Their selection and findings are journaled automatically.
Pick requests retain their original base and term even if the reply arrives
later. Draft and pick prompts include the most recent twelve relevant records,
fenced as authored observations. The full history remains available through
the CLI and Git branch.
The cmux event bridge also notifies the current leader when this journal
advances, so late results can reach a busy session through its agent hooks.

## Check evidence and candidate snapshots

Checks automatically record `check-start`, followed by `check-pass` or
`check-fail`. Entries include the author, originating term/request, repository,
bid, exact base tree, result tree, and retained candidate commit when available.
CI results also include the command, runner/image and memory settings, plus a
bounded output tail, including successful timing output. A start without a
result is incomplete, never an implied pass.
Reused results name their original `verified_request` and `check_key`, rather
than claiming a new CI execution. Commit IDs and check fingerprints are kept
as metadata; free-form findings and diagnostic text are redacted separately.

Before CI, the check pins its candidate in the checking node's governed Git
repository:

```text
HOME/repos/REPO
  refs/pantheon/checks/BASE_COMMIT/CANDIDATE_TREE -> CANDIDATE_COMMIT
```

The candidate commit's parent is the exact accepted commit used by the check;
its tree is the exact input to CI. The create-only ref survives temporary
checkout deletion and Git garbage collection, without moving accepted HEAD.
Repeated checks of the same candidate produce the same commit. A failed CI
run still leaves its candidate available for investigation. An apply failure
has no candidate and is recorded against its original base instead.

Candidate refs live in the checking author's repository. Other machines may
fetch them from that repository, or reconstruct the candidate from the signed
bid and recorded base; the journal does not itself transfer Git objects.
The cmux run's final bundles include these refs and each node's journal bundle.

An old leader's check may finish several terms later. Its result is recorded
with the old base and originating request. The callback rechecks leadership
before queuing another merge check or trying to merge/reject. A stale pick
reply likewise contributes its findings without exercising the former
leader's authority.

## What a record establishes

A passing check is an author's observation about a particular candidate and
check context. It is not a committed merge, an attestation, or permission to
skip another node's validation. Mutable runner paths/image tags are recorded
as configured; they are not claimed to fingerprint every external dependency.
The next leader must compare the recorded base and candidate with the current
head and retain the normal review, local check and attestation requirements.
The journal does not add a cross-node CI trust cache. A change of head never
silently upgrades old evidence into a check of the new combined tree.

Within a running node, a successful native CI check can be reused across terms.
The key binds the repository, base tree, exact edits, command, memory settings,
runner bytes (or Docker image ID), and configured runner/image. A hit also
verifies the current base and retained candidate tree. Only native successful
CI completions populate this private, bounded cache; authored journal claims
cannot populate it. Failures are not cached. Review requests are scoped to the
leader's term, so a returning leader can revisit a pending selection and use
its own completed check even while other CI jobs remain queued.

The cache lasts for the node process, across diplomat session restarts and
leadership changes. A node restart clears it and revalidates the environment;
the journal and Git snapshots survive. External toolchains are assumed fixed
during a node process; restart nodes when changing them. Independent attestors
continue to run their own validation and make a fresh approval decision.

Verification: `sh test/leader-journal.sh`, `sh test/leader-history.sh`,
`sh test/leader-handoff.sh`, and the
existing check-result, check-apply, completion and multi-node tests.
