# An enum with no silent case does NOT prevent a silent path — Swift exhaustiveness forces a case to EXIST, not to DO anything

**Status:** Current. Landed 2026-08-04 on `v3` (agent S, round 2), alongside the
`IOS-SEARCH-003` witness fix. Class: **a structural-guarantee claim that the language does
not actually make**, used as the stated reason not to test a path.

---

## The class, stated once

**"The type system makes this impossible" is a claim about the compiler, and it must be
checked against what the compiler actually enforces — not against what the type was designed
to express.** An exhaustive `switch` over an enum guarantees that every case is *mentioned*.
It guarantees nothing whatsoever about what the body of that case *does*. `case x: break`
compiles, adds no case, removes no case, and produces exactly the behaviour the enum was
introduced to abolish.

The danger is not the wrong belief on its own. It is that the belief was **load-bearing**:
it was written down as the reason a path needed no test, so it converted an untested path
into a *deliberately* untested path, and every later reader inherited the conclusion without
re-deriving the premise.

---

## The instance

`SearchView.ResultTapOutcome` was introduced to kill an invisible dead tap: `openResult`'s
remote branch used to answer a `nil` resolve by simply returning, so tapping a search result
for a message not on this device did nothing at all — indistinguishable from a broken app.

The enum's own doc comment claimed:

> 🚨 THERE IS DELIBERATELY NO SILENT CASE, and that absence is the invariant this type exists
> to hold … A future re-implementation may change how the outcome is DECIDED; it cannot
> reintroduce silence without adding a case here.

The same claim appeared **twice more**, in the test file that was relying on it:

> `SearchView.ResultTapOutcome` has no silent case at all — a future refactor cannot
> reintroduce silence without adding one.

> These assert the OUTCOME of a tap, which is the property; `ResultTapOutcome` carries no
> silent case, so the invariant is structural rather than asserted.

Three statements of one false proposition, and the third one draws the operational
conclusion: *the invariant is structural rather than asserted*, i.e. **no test needed**.

### The disproof, run rather than argued

Replace the consumer's branch with:

```swift
case .explainRemoteResultNotOnThisDevice:
    break
```

It compiles. No case was added or removed. The dead silent tap is fully restored. And every
test in `SearchResultTapOutcomeTests` stays **GREEN**, because every one of them asserts what
`tapOutcome` *returns* — the classifier — and none asserts what the view *does* with that
answer.

**Classifier and consequence are different propositions.** The system property is *the user
sees something*; `outcome == .explainRemoteResultNotOnThisDevice` is one hop short of it. A
suite can be complete, well-named and entirely green while covering only the weaker one.

---

## The tell

> *"The type system / exhaustiveness / the compiler makes this impossible, so it doesn't need
> a test."*

Whenever that sentence is the justification for **not** writing a test, write the regression
out in full and try to compile it. If it compiles, the guarantee was imagined. In this case
the counter-example is four characters long.

A weaker, honest version of the same sentence is fine and worth keeping: *"exhaustiveness
means a NEW case cannot be silently ignored at this site"* — that IS true, and it is a much
smaller claim than the one that was written.

---

## What replaced it

The branching moved out of the view and into a value:

- `SearchView.TapEffect` — `navigate` / `explainStaleLocalResult` /
  `explainRemoteResultNotOnThisDevice`, plus `isVisible`.
- `SearchView.effect(of: ResultTapOutcome) -> TapEffect` — pure, `nonisolated static`.
- `openResult` applies the value by **unconditional assignment** and re-decides nothing, so
  there is no branch left in it to `break` out of.

`SearchTapEffectWiringTests` then asserts the END STATE of every outcome, including the
falses, and iterates a roster kept honest **by a compile error**: `discriminator(of:)`
switches the enum exhaustively, so adding a case stops compiling until the roster is updated
(MIS-007 — a hand-written census silently stops being complete the day the thing it counts
grows).

### The boundary, stated because the claim being replaced was an unfalsifiable absolute

The final hop — `openResult` assigning the three fields onto `@State` — is **still not
covered by a unit test**; it needs a hosted SwiftUI view. What changed is the *shape* of a
possible regression: it must now be a visible deletion of an assignment rather than an empty
case body. **That is a reduction in exposure, not a proof, and describing it as structural
would repeat the exact error this file records.**

---

## Sibling instance found in the same pass

The same "proved a property of a function nobody was proven to call" shape:
`SearchDeletedResiduePresentationTests` proved `presentableRemoteResults` drops a `\Deleted`
residue, but nothing asserted `searchAccount` **calls** it — the filter sat on the tail of a
`@MainActor` method building two `Task`s and a timeout, so no test reached it and deleting
the call would have left the suite green. Closed by `SearchView.remoteResults(accountId:
accountEmail:folderPath:fetch:)`, which injects the fetch so the real return path is
exercised. The residual hop (`searchAccount` calls `remoteResults`) is a single `return
await` with no branch, and is **still unpinned** — recorded here rather than glossed.

---

## Related

- Global `CLAUDE.md` Testing rule 12 — every audit-found bug becomes a test pinning the
  INVARIANT, not the fix's mechanism.
- `MISTAKES.md` MIS-014 — tests that BLESS the bug. A blessing test was also found in this
  same file during round 1 (`aResolvableRemoteResultOpensWithoutAnUnprovenWitness`) and
  rewritten; it would have stayed green through its own fix.
- `MISTAKES.md` MIS-019 — absolutes need the negative case. All three false statements above
  were absolutes with no stated negative case.
- `KNOWN_ISSUES.md` `IOS-SEARCH-003` — the round-1 witness fix this landed beside.
