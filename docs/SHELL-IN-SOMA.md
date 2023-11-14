# Moving the shell into Soma

Pantheon's decisions are Soma (`node.soma` and what it imports), but the
program around them is `shell.ml`, about 1,600 lines of hand-written OCaml
that `shell.definition` declares to Soma as four assumptions (`sha256`,
`hash_list`, `decode_tx`, `run`). The goal: as much of `shell.ml` as can be
is Soma, extracted with the rest, and OCaml is left only as thin bindings to
the libraries that do I/O: Unix (files, processes, sockets, time),
cryptokit (RSA, SHA-256) and yojson. Each binding is declared in a
`.definition` file, as `examples/example_projects/async_tasks` declares
Async's functions (GRADUAL.md, "OCaml modules").

What it buys: every line that moves is checked by Soma's kernel and can be
explored and proved about, and `soma explore main.soma` lists only the
bindings as assumptions, not a 1,600-line shell.

## In pieces, one task each

`shell.ml`'s sections, roughly from least to most I/O:

1. Pure helpers: `hex`, `replace_all`, JSON flattening (`flatten_reply`,
   `json_in_reply`), `plan_open`, `safe_path`, the edit matching in "edits"
   (`positions`, `apply_edits`' logic), `chain_len`/`iterate`.
2. The command line: parsing `pantheon init/keygen/genesis/status/tx/plan`
   and their messages, calling bindings for files and keys.
3. Genesis and keys: `build_genesis`, `make_keys`, `decode_tx`/`encode_tx`
   over RSA and SHA-256 bindings.
4. The node loop: `run`/`node`, sockets, timers, jobs and git, last.

Each task moves one piece, keeps the same behaviour, and leaves the rest
where it is. A piece that would need a binding Soma can't express yet is
worth a note in this file rather than a workaround.

## Done so far

- `plan_open` (piece 1, in part): now `plan_open` in `util.soma`, with its
  string helpers (`trim`, `split_lines`, `is_date_line`, `marked_line`,
  `truncate_line`). `shell.ml`'s OCaml version is deleted; `run` takes the
  Soma function as an extra argument (declared in `shell.definition`,
  passed in `main.soma`) and hands it to `node`, so the `pantheon plan`
  command and the node loop's plan prompts both use the Soma version.
  Still in `shell.ml` from piece 1, next in roughly this order:
  the edit matching (`matches_at`, `positions`,
  `replace_at`, and `apply_edits`' pure logic), `safe_path`'s OCaml copy
  (Soma already has one in `util.soma`), the JSON helpers
  (`flatten_reply`, `json_in_reply`, `shallow_json`), and
  `chain_len`/`iterate` (over the `sha256` binding).

- `replace_all`: now in `util.soma`, with `drop_str` and a bounded scan.
  The OCaml implementation is deleted; `main.soma` passes the Soma helper
  through `shell.definition`'s `run` argument to the node's prompt expansion.
  Replacement remains literal, left-to-right and non-overlapping; inserted
  text is not scanned again. All shell patterns are nonempty (an empty
  pattern now leaves the text alone, rather than looping forever).
  Next: edit matching (`matches_at`, `positions`, `replace_at`, and
  `apply_edits`' pure logic). I/O stays in the shell.

- Edit matching: `positions` (the first two places at most), `replace_at`
  and `edit_once` (the text with its one occurrence of the old text
  replaced, `None` when it's missing or ambiguous) are in `util.soma`.
  `shell.ml`'s `matches_at`, `positions` and `replace_at` are deleted.
  `run` gets Soma's `edit_once` and `contains` as two more arguments and
  stores them in two refs at its start, so `apply_edits`, `hunk_edits`,
  `repo_url`, `check_tree` and the node loop use them without threading
  them through every caller. `apply_edits` tells "isn't in the file" from
  "appears more than once" with `contains`. Nat doesn't cross the binding
  boundary (extracted code's `nat` is abstract to `shell.ml`), so the
  bindings take `option string` and `bool`, not positions.
  Next: `safe_path`'s OCaml copy (use `util.soma`'s, checking the two agree
  on `test/edits.sh`'s cases first), then the JSON helpers
  (`flatten_reply`, `json_in_reply`, `shallow_json`), then
  `chain_len`/`iterate`. I/O stays in the shell.

## How a bid is judged

- `soma build main.soma` builds, and `test/edits.sh` and `test/e2e.sh` pass
  unchanged: the scenarios are the specification. The market's CI doesn't
  run `test/e2e.sh` yet (D-1 in `.plan`), so a bidder runs it in its
  checkout before bidding, and says so; an attestor with tools runs it too.
- `soma explore main.soma` lists no new escape hatch the move didn't need,
  and the moved code adds no `Admitted` or axiom (the CI policy refuses them).
- Numbers that may be large are `N` or OCaml ints by extraction, not unary
  `nat` (main.soma already extracts `nat` to OCaml ints).
