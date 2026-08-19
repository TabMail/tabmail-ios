# MIS-IOS-016 — shipped a test whose PRECONDITION never occurs, so it reported green forever without ever exercising the thing it names

**Class:** testing / verification-gate integrity
**Severity:** high (a green suite certified a path that was never executed; three separate instances
found on one day, one of which had already survived a documented "fix")
**First seen:** 2026-08-13 · **Recurrences:** 2 · **Status:** Active
**Related:** `MIS-014` (a test that BLESSES the bug — asserts the wrong value) · `MIS-015`
(mechanism-pinning instead of invariant) · `MIS-IOS-014` (a red-first proof that could not run red) ·
`MIS-IOS-006` (a number reported but not measured) · **Rule owner:** `../CLAUDE.md` § Testing Rules

## The tell

I am reading a test that passes. Its name states a real invariant. Its assertions are correct — I can
check each one and each one is right. **The setup builds a scenario, and I have not verified that the
scenario actually arises.**

The specific comfort is *"the assertions are correct"*. They are. That is not the question. The
question is **whether the state the assertions describe is ever entered**, and an assertion evaluated
against a state that never occurs passes for the same reason `∀x ∈ ∅` is true.

In one line: **I can name what the test asserts, but I have not named the observable that proves the
setup took effect.** If asked "what would I see in the log if the precondition silently didn't
happen?" I would have to go look — which means I never checked.

⚠️ **This is distinct from `MIS-014`.** A blessing test asserts the *wrong thing* and goes red when
you fix the bug. A **vacuous** test asserts the *right thing* about a state that never exists — it
stays green through the bug **and** through the fix, so it never signals at all. It cannot be found by
"does this test fail on the pre-fix code", because it fails on nothing.

## What actually happened — three instances in one day, three different mechanisms, plus a fourth in 2026-08

**1. `InboxEndToEndInvariantTests.scrubOnlyWakeStillConverges` — the precondition never fires.**
`E2EWorld.apply(.silentStateChangePush)` re-stages with the **same folder and spec** as `.pushArrives`,
differing only in `processedAt`, which `NSEDataBridge.StagedMessage.toInboxRow` **does not project**.
So `stagedSetChangedSinceLastPost` compares an identical row set against `lastPostedStagedRows`,
`.messagesStaged` is suppressed, `wireStagedRowViewGlue` never runs, and **the phantom row is never
inserted**. The eviction assertion then passes because there was nothing to evict, and the preceding
`waitUntil(5)` — `while !cond() && Date() < end` — **never suspends**, because its condition is true on
entry.

Measured, not inferred: `prevCount=0` in **50/50** runs (40 single-test + 10 suite iterations),
including every green one. This test has **never once** exercised the eviction path it is named for.

⚠️ **A fast `waitUntil` return was read as evidence the eviction happened.** It is evidence of the
opposite. That inference appeared in the register and had to be retracted.

**2. `ImageFailureBannerStateTests.aDocumentChangeClearsBothHalves` — the assertion is self-satisfying.**
It asserts `x.documentChanged(); x == ImageFailureBannerState()` against an implementation that is
literally `self = ImageFailureBannerState()`. It **cannot fail for any implementation containing that
line**, and it stayed green through two real defects in the wiring its suite header claims to pin.

**3. `EmailRenderSecurityCanaryTests.terminationRecoveryAndAppearanceReload` — a wall-clock sleep
standing in for a barrier.** It installs its probe after a bare `try? await Task.sleep(for:
.seconds(3))`. Under load the initial load slipped past 3 s, so the probe counted it plus the recovery
reload: 8 navigation callbacks instead of 4. **The same byte-identical binary both passed and failed.**

**4. `StoreKitSubscriptionManagementPresentationTests.theTwoFailureShapesDoNotMatchEachOther` — the
assertion is guaranteed by the TYPE SYSTEM (2026-08-18, issue #45, commit `0cd3465`).** It built a
`.noWindowScene` and a `.failed(_)`, then asserted each matched its own case and neither matched the
other's. No implementation of `SubscriptionManagementPresentation` that **compiles** can make that
false — distinct enum cases are distinct by construction — so it could not go red for any production
change whatsoever, and it stayed green under the very `didPresent` inversion its sibling caught (the
authoring commit even recorded that as a *feature*). The **discriminating tell here is the comment,
not the setup**: it claimed to pin "the asymmetry the plan picker and account dashboard rely on",
which lives in those views' `Task` closures and is not reachable from an enum-case check at all. The
disposition was deletion plus a real pin elsewhere — the composed-closure coordinator test
`DeletionCoordinatorGuardTests.unpresentedSubscriptionSheetsBlockDeletion` — exactly what
`IOS-TEST-004` prescribes for a vacuous test. **Generalised tell: when a test asserts only relations
the compiler already enforces (case distinctness, exhaustiveness, a `let`'s immutability), ask what
production edit would turn it red; if the honest answer is "none that compiles", it is not a test.**

## Why the usual defences did not catch it

- **Every assertion is individually correct.** Review that checks assertions finds nothing. The defect
  is in the *quantifier over states*, not in the predicate — the same shape as `MIS-IOS-008`.
- **Red-first cannot find it.** A vacuous test does not fail on pre-fix code. Instance 1 stays green
  even if you delete the production branch it names.
- **The suite is green, and green is the state where nobody looks.** Instance 1 sat green in ~9,000
  tests; instance 2 stayed green through both defects it was written to catch.
- 🚨 **A recorded countermeasure had already been applied to instance 1 and FAILED.** The test file's
  own 2026-07-30 header note records the **identical** `captured=[]` symptom, attributes it to a fifth
  concurrent suite, declares `.processGlobalState` "the fix", and **forbids "adding a wait"**. The
  trait is applied and the symptom recurred. Worse, the forbidden remedy is the repo's own idiom —
  `IOS-TEST-009`'s `EscapedDrainTransport.awaitPendingQueueSettled`, a bound-wait on the **witness**.
  **A countermeasure recorded without a mechanism that explains the symptom is a guess, and it
  actively blocked the fix for two weeks.**

## The rule

**A test must observe that its precondition took effect, not merely perform the setup that is supposed
to cause it.** Name the observable — a count, a log line, a state read — that distinguishes "the
scenario arose and the assertion held" from "the scenario never arose".

Concretely, for each of the three mechanisms:

1. **Precondition never fires** — assert the setup's *effect* before asserting the invariant. Here:
   assert the phantom **exists** before asserting it was evicted.
2. **Self-satisfying assertion** — if the assertion is the implementation restated, it pins nothing.
   Test at a seam where the value and the wiring can disagree.
3. **Wall-clock sleep as a barrier** — a `sleep` is never a barrier. Bound-wait on the **witness**: the
   property under test, not a proxy for it, and not a duration.

**A `waitUntil`-style helper that returns fast is not evidence of convergence** unless its condition
was false on entry. If a test's correctness depends on that helper having suspended, it must assert it
suspended.

## Mechanical check

```bash
# Setup verbs with no observable asserted between setup and the invariant assertion.
rg -n 'apply\(\.|stage[A-Z]|seed[A-Z]|inject[A-Z]' TabMailTests/ -A12 | rg -n 'expect\(' 

# A sleep used where a barrier belongs — every hit is a suspect.
rg -n 'Task\.sleep' TabMailTests/ | rg -v 'awaitPendingQueueSettled|waitUntil'

# Assertions that restate their implementation: compare against a freshly-constructed default.
rg -n '== *[A-Z][A-Za-z]*\(\)' TabMailTests/

# A waitUntil whose condition may be true on entry.
rg -n -B4 'waitUntil\(' TabMailTests/
```

⚠️ **Scope a census over a multi-test log to the test's own region before believing its numbers.** A
`grep -A2` over a whole suite log swept 18 tests' merges instead of one and produced a distribution
that appeared to refute the vacuity finding; re-scoped with `awk` it was 10/10. Same shape as the
census trap this repo already records — a census inherits its search shape.

---

## Pre-compaction index line (verbatim, 2026-08-13, pass 4)

Routed out of the always-loaded `tabmail-ios/MISTAKES.md` by the `companion-compact` skill, which
was reporting that file 62% over its 12,000 B budget. Kept **byte-for-byte**, inside a fenced block
so its index-relative link is not re-resolved from this directory, because the index line had
accumulated recurrence detail that exists nowhere else in this file.

```text
- **[MIS-IOS-016](Companion/Mistakes/Active/MIS-IOS-016-shipped-a-test-whose-precondition-never-occurs.md)** — shipped a test whose **PRECONDITION never occurs**, so it reported green forever without ever exercising the path it names. ⚠️ **Distinct from `MIS-014`:** a blessing test asserts the wrong thing and goes red when you fix the bug; a **VACUOUS** test asserts the right thing about a state that never exists, so it stays green through the bug AND the fix and **cannot be found by red-first** — it fails on nothing. Three instances in one day, three mechanisms: (1) `scrubOnlyWakeStillConverges` — `.silentStateChangePush` re-stages a row differing only in `processedAt`, which `toInboxRow` does not project, so `.messagesStaged` is suppressed and **the phantom is never inserted** (`prevCount=0` measured **50/50**, green runs included); ⚠️ **a fast `waitUntil` return was read as proof the eviction happened — it proves the opposite**, its condition was true on entry; (2) `aDocumentChangeClearsBothHalves` — asserts `x == ImageFailureBannerState()` against an implementation that IS `self = ImageFailureBannerState()`, so it cannot fail; (3) `terminationRecoveryAndAppearanceReload` — a bare `Task.sleep(3s)` as a load barrier, **same byte-identical binary passed and failed**. 🚨 **A recorded countermeasure had already FAILED on (1):** the file's 2026-07-30 note blames a fifth suite, declares `.processGlobalState` "the fix", and **forbids "adding a wait"** — the trait is applied, the symptom recurred, and the forbidden remedy is the repo's own `IOS-TEST-009` bound-wait-on-the-witness idiom. **A countermeasure recorded without a mechanism that explains the symptom is a guess, and this one blocked the fix for two weeks.** ***Tell: I can name what the test asserts, but not the observable proving the SETUP took effect — "the assertions are correct" is true and is not the question.*** Rule: assert the setup's EFFECT before the invariant; a `sleep` is never a barrier — bound-wait on the witness. (×1)
```
