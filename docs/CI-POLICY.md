# CI assumption guard and semantic follow-up

`deploy/ci-command.py` is a trusted **lexical guard**. It rejects recognized new
assumption declarations and explicit primitive/tactic escapes, after subtracting
identical existing escape statements. It does not establish that arbitrary Soma
extensions, imported modules, notation or proof automation introduce no axioms.
The trusted compiler and the normal CI checks still run after this guard.

The guard distinguishes declaration names and explicit typed declaration
parameters from uses. For example, `Definition error := 1.` and
`Definition f (cast : nat) := cast.` and Soma's normal short spelling
`f (cast : nat) := cast.` are ordinary definitions. A parameter is
visible after its type, in later parameter types and in the declaration body.
The short spelling must have a top-level `:=` assignment; `unk : nat` is a
primitive expression, and `let` assignments inside a result type do not establish
a declaration by themselves. Its scope stops at the end of that declaration statement; it never becomes a
file-wide exemption. `Definition f (cast : cast nat Type 1) := cast.` is still
rejected because the parameter is not in scope in its own type.

Qualified references remain guarded: a parameter named `cast` cannot exempt
`Corelib.Gradual.Gradual.cast`. Known tactic escapes such as `admit` are guarded
regardless of term parameters, so a parameter cannot hide `ltac:(admit)`.

This bounded change deliberately leaves conservative false positives:

- Local `fun`, `forall`, `let`, pattern and tactic bindings are not a term parser.
- Parameter scope is not carried into separately terminated proof commands.
- A separately declared ordinary global `cast` may still be flagged at a use.
- Implicit/generalized/untyped binders and custom extension syntax are not inferred.
- Recursive/mutual declarations and commands containing `with`/`where` stay guarded;
  one declaration's parameters must not leak into a sibling declaration or notation.
- Names matching known tactic escapes may still be refused at ordinary term uses.

Renaming an ordinary local identifier avoids those false positives. Expanding a
set of ignored names across the whole file would hide actual escapes after a
local scope ends and is intentionally avoided.

## Concrete semantic manifest experiment

`prototypes/ci-semantic-assumptions.py --soma /trusted/bin/soma entry.soma ...`
exports JSON from the existing checked `soma hash` result, using its internal
`SOMA_HASH_FIELDS=1` tab-separated fields (also used by `soma diff`). It is **not an enforcing
replacement** and does not execute from deployed CI. It records each declaration's
contract/witness and its transitive assumptions; `.exp` is checked with its `.soma`.
The existing fields are unversioned; the prototype rejects unexpected records
rather than guessing.

Real compiler probes demonstrate the distinction a lexical guard cannot make:
a local parameter `cast` has no assumptions; a qualified primitive still assumes
`Corelib.Gradual.Gradual.cast`; `raise : nat` assumes the primitive `err`; a new
`Conjecture hole : False` assumes `hole` itself. The alias `raise` demonstrates why
adding contextual spelling rules cannot prove semantic completeness.

An enforcing design needs these compiler/tooling contracts first:

1. A versioned compiler manifest with documented coverage for **all** declarations,
   including unused axioms, all imported modules and checked `.exp` declarations.
   Source/extension/dependency digests must identify exactly the checked input.
   Discarded bare expressions also need explicit accounting: current `soma hash`
   reports declarations, so it does not report a bare `unk : nat` expression.
2. Canonical assumption identities including qualified name and contract hash.
   A same-name changed axiom must not inherit trust from an old baseline. Existing
   approved assumptions form an explicit operator-controlled allowance; changing
   their type creates a different assumption. New uses of an approved axiom are a
   separate operator policy, not an accidental baseline-subtraction rule.
3. Explicit accounting for gradual primitive uses, unsafe casts, admitted proofs
   and extension/native trust boundaries. Kernel assumption dependencies alone do
   not report every unsafe operation performed by an external OCaml module.
4. Trusted entry-point discovery and dependency closure, external to bidder files.
   The compiler executable, package resolution and extensions must be trusted or
   confined: checking hostile extensions can itself execute code.
5. A baseline manifest produced by that same trusted compiler/schema, bound to the
   exact accepted commit and deployment policy. Unknown schema, missing files,
   compiler failure or partial output must fail closed.
6. Regressions for unused Conjectures, aliases/notational expansion, imports,
   deleted/reintroduced assumptions, changed contracts and ordinary shadows.

Only then should semantic allowances replace the lexical guard. Hashes and the
prototype's explicit source list alone do not establish this coverage or trust.
