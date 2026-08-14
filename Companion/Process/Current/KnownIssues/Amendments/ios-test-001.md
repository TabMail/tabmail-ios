# IOS-TEST-001 — `scrubOnlyWakeStillConverges`: ROOT-CAUSED. A vacuous scenario plus an unsynchronised assertion, not an order-dependent production defect

**Status:** 🔓 OPEN (2026-08-13) — **root cause established; the fix is to the TEST, and the production
code is correct.** Kept open because the test still needs repairing in two independent places, and
because a 2026-07-30 countermeasure recorded in the test file has been **falsified** by this recurrence.

⚠️ **The 2026-08-13 registration below was wrong in its central framing and is preserved rather than
edited.** It called this "order- or shared-state-dependent" and set up a subset bisection to find the
interfering suite. **Nothing was polluted and there is no interfering suite.** Do not restart that
investigation.

## Root cause (2026-08-13, Agent G, log-diff against both runs)

**The production path is IDENTICAL in the passing and failing runs.** For the scrub wake under test,
both logs emit:

```
[NSEDataBridge] mergeNSEStagingData: START
[NSEDataBridge] mergeNSEStagingData: found 1 staged message(s) (1 with AI)
[NSEDataBridge] mergeNSEStagingData: DONE in 1ms/2ms (didMutate=false)
```

`NSEDataBridge.performMerge`'s `else if scrubbedStaleStagedRows` branch **posted the signal in both
runs**. The only difference is *where* the `.inboxDataDidChange`-driven `[MoveTrace] reloadMessages`
pair lands relative to the `#expect`.

**Mechanism.** `performMerge` posts inside `Task { @MainActor in … }`; `E2EWorld`'s observer appends
inside a **second** `Task { @MainActor in … }`. So `world.capturedSignals` is populated only after
**two** main-actor job drains, and the test provides **zero** synchronisation for them. Whether the
main run loop drains during `PriorityGate.privileged`'s tail hops (`exitPrivileged`, `shared.end()`)
and `NSEMergeCoordinator.merge`'s actor hops decides the outcome. **Red is the structural default;
green is the accident.**

### The scenario is VACUOUS — the phantom is never inserted

`E2EWorld.apply(.silentStateChangePush)` re-stages via `stageTerminalRow` with the **same folder
(`inboxPath`) and the same `spec`** as `.pushArrives`. The only differing column is `processedAt`,
which `NSEDataBridge.StagedMessage.toInboxRow` **does not project**. Therefore:

- `NSEDataBridge.stagedSetChangedSinceLastPost` compares an identical single-row set against
  `NSEDataBridge.lastPostedStagedRows` (set by the `pushArrives` merge) → `false`
- ⇒ `.messagesStaged` is **suppressed** ⇒ `wireStagedRowViewGlue` never fires ⇒ **no phantom row**

`NSEDataBridge.resetStageMemoForTesting` resets `stageMemo`, **not** `lastPostedStagedRows`. The
comment on `InboxEndToEndInvariantTests.resetGlobals` reasons only about *cross-test* content-match
and never considers the **intra-test** re-stage.

**Log-independent proof the phantom was absent in the failing run:** `E2EWorld`'s observers are
registered in `E2EWorld.init`, i.e. **before** `wireStagedRowViewGlue`, so the world's append job is
always enqueued ahead of the glue's insert job. `captured=[]` therefore proves the glue never ran.

✅ **MEASURED, not inferred — 50/50 (2026-08-13).** Across E1 (40 single-test iterations) and E2 (10
suite iterations), the reload following the scrub wake reports **`prevCount=0` in every single run**:
the phantom is never on screen, in either configuration, including every **green** run. E1 also
counted 80 merges (2 per iteration) with 40 `didMutate=false` scrub wakes. **This test has never once
exercised F1's eviction path**, and that is true independently of the flake.

⚠️ **Census-scoping hazard, recorded because it nearly produced a false contradiction.** The first
E2 vacuity census used `grep -A2 didMutate=false` over the whole log and returned a mixed
`prevCount` distribution (70/150/47/20) that appeared to refute the E1 result. It did not — the
census had swept the `didMutate=false` merges of **all 18 tests in the suite**, not the target's.
Re-scoped with `awk` to the target test's own region it is 10/10. **A census over a multi-test log
must be scoped to the test region before its numbers mean anything.**

**Three consequences:**

1. **`waitUntil(5)` returning "fast" is NOT evidence of convergence.** Its loop is
   `while !cond() && Date() < end`, so it only suspends if the condition is false on entry — and the
   condition (phantom gone) was **already true**, because the phantom was never created. The original
   registration read the fast return as proof the eviction happened. It proves nothing.
2. **The eviction assertion is vacuous.** This test does not exercise F1's eviction at all.
3. **The surviving assertion is a coin flip**, per the mechanism above.

### Why isolation passes — and why the intuition is backwards

The isolated process is **slower**, not cleaner: `archivedThenRestagedNeverReappears` took 1.134 s
alone vs 0.295 s in the suite; the target 0.427 s vs 0.280 s. The cold run gives the main queue time
to drain; the warm full-suite process does not. **This inverts the usual "more load ⇒ more flake"
intuition**, and it is why the +17 tests / +1 suite delta from the render session is a red herring.

*Labelled as the best-supported explanation for the bias, not as established fact.*

## The render session is exonerated — on a STRUCTURAL property, not symbol content-matching

The original entry ruled it out by checking whether *changed lines* mention `NotificationCenter`,
`inboxDataDidChange`, `messagesStaged`, `SyncEngine` or `InboxViewModel`. **That method cannot refute
order- or shared-state dependence**, which is content-independent: adding a suite perturbs execution
order without naming a single symbol. The same invalid method was used to exclude the queue
workstream.

The valid argument: `ImageLoadFailureBannerTests.swift` contains suite type
`ImageFailureBannerStateTests` (7 tests) — synchronous, value-type-only over
`ImageFailureBannerState`, **no `@MainActor`, no `async`, no `.serialized`/`.processGlobalState`, no
globals, no notifications**. It cannot perturb what it never touches. ⚠️ Note the **file-name ≠
type-name** trap when filtering by suite.

> **Current correction (2026-08-13):** the later product decision removed the banner state and
> replaced that suite with `ImageLoadFailureNoticePolicyTests` (3 synchronous value tests over
> `ImageLoadFailureReportDisposition`). The historical structural exoneration above remains valid;
> the current suite is narrower still and likewise owns no actors, globals, or notifications.

More fundamentally: since both runs executed the identical production path and posted the signal,
**there is no dirtied state for any suite to have left**, so the attribution question is malformed.

## ⚠️ FALSIFIED COUNTERMEASURE — this is a RECURRENCE, not a first occurrence

`InboxEndToEndInvariantTests.swift`'s own header note (2026-07-30) records the **identical**
`captured=[]` symptom, attributes it to a fifth concurrent suite, declares `.processGlobalState` **the
fix**, and **forbids "adding a wait"**. The trait is applied and the symptom recurred — so that
countermeasure does not work, and the prohibition points away from the actual remedy.

**The forbidden remedy is the repo's own recorded idiom:** `IOS-TEST-009`'s
`EscapedDrainTransport.awaitPendingQueueSettled` — a **bound-wait on the witness**. Here the witness
is `capturedSignals` (the property under test), not the eviction. That does **not** weaken the
assertion: delete the `else if scrubbedStaleStagedRows` branch and a bounded wait still expires red.

## Two independent repairs are needed — fixing only one leaves the test lying

1. **Synchronise the assertion** — bound-wait on `capturedSignals`.
   ⚠️ **Hazard:** `E2EWorld`'s observers use `object: nil`, so a concurrent suite's
   `.inboxDataDidChange` can satisfy the capture **spuriously**. The capture must be scoped.
2. **Restore the scenario's premise** — the re-stage must differ in a **projected** field, or
   `lastPostedStagedRows` needs a test seam. Without this, the eviction half stays vacuous and a
   green run still proves nothing.

## Verification plan — E1 is decisive; subset bisection is now the FALLBACK

**E1 (decisive, cheap).** Repeat the single test alone until failure:

```
xcodebuild test-without-building -project TabMail.xcodeproj -scheme TabMail \
  -destination 'id=E390B52E-FAD7-4CD7-BD60-328CD0BF7D65' -derivedDataPath /tmp/tabmail-dd \
  -only-testing:'TabMailTests/InboxEndToEndInvariantTests/scrubOnlyWakeStillConverges()' \
  -test-iterations 40 -run-tests-until-failure > E1.log 2>&1
```

⚠️ The `()` is **mandatory** — a bare test name runs **zero tests and exits 0**. Verify by count, not
by shell status: `grep -c '◇ Test "scrubOnlyWakeStillConverges' E1.log` ≈ 40, and every
`Test run with …` line must read `1 test`, never `0 tests`. ⚠️ **Do not grep for the bare substring
`0 tests` — `"40 tests"` contains it.** Anchor the check.

### ✅ RESULTS (2026-08-13)

| run | scope | result |
|---|---|---|
| **E1** | single test alone, 40 iterations | **40/40 green.** `40 tests in 40 suites passed`, 17.907 s. #1 = 1.028 s cold, #2–#40 = 0.409–0.617 s |
| **E2** | whole suite, 10 iterations | **10/10 green.** `180 tests in 10 suites passed`, 187.571 s |
| Agent E, independently | **full suite** | **9053 / 1224, 0 failures**, 340.209 s |
| **B0** | **full suite** | **9053 / 1224 green**, 377.304 s, 1 known issue. Target passed in **0.292 s** |

**Final tally: full suite — 1 red in ≥3 runs (01:39, Agent E, B0). Suite alone — 0/10. Single test
alone — 0/40.**

⚠️ **"Red is the structural default" is REFUTED** — it was this investigation's own prediction and it
did not survive. Recorded because a model that survives only by not being tested is worse than none.

⚠️ **E1 and E2 are weaker evidence than they look, and this cuts against their design.** The refined
model was that the red path needs the **main thread occupied during the merge's tail** (the
`PriorityGate.privileged` → `DatabaseWriteQueue.exitPrivileged` → `NSEMergeCoordinator` hops between
the post `Task`'s enqueue and the test continuation's enqueue). Run alone there is no other source of
main-actor work, so **E1/E2 are configurations in which the failure arguably cannot occur at all** —
they bound the alone-rate at 0/50 and say little about the full-suite rate. **But that refinement is
itself unconfirmed: B0 IS the parallel configuration and went green.**

🚫 **RETRACTED — a duration signal that was reported here and is now known FALSE.** An earlier version
of this entry recorded that the red instance ran in **0.280 s**, "faster than every green instance
observed (≈0.42 s)", and that the 01:39 run was ~7.6% slower overall. **B0 killed both halves.** Its
**green** instance ran in **0.292 s**, so the 0.280-vs-0.42 gap was a *full-suite-versus-alone
configuration* difference, **not** a red/green signal; and B0 ran **slower overall** than the red run
(377.3 s vs 366.0 s, on a slightly larger suite) and was still green, so whole-run duration does not
predict the outcome either. **Do not carry the duration datum forward, and do not build a model on
it.**

**The frequency and the missing ingredient are NOT established, and must not be manufactured.** One
red in ≥3 full-suite runs is the entire rate evidence, and duration no longer discriminates.

**Subset bisection is ABANDONED, not deferred.** Three green full-suite runs removed its premise.

---

<details>
<summary>Superseded registration (2026-08-13), preserved byte-for-byte</summary>

**Status:** 🔓 OPEN (2026-08-13) — **a real gate defect, not a flake to be re-run away.** It makes the
full suite red, which means every subsequent "the suite is green" claim is either false or is quietly
tolerating a known failure. That is the expensive part, independent of whether a user is affected.

## The observation, both directions

| run | scope | result |
|---|---|---|
| full suite, `p4_test.log`, 2026-08-13 01:39 | 9042 tests in 1222 suites | **✘ failed** |
| suite alone, `-only-testing:TabMailTests/InboxEndToEndInvariantTests` | 18 tests in 1 suite | **✔ passed**, 0 `✘`, 0 issues |

Same commit, same simulator (`iPhone 17 Pro`, id `E390B52E-…`), same shared derivedData.

**It is NOT a timeout flake.** It failed after **0.280 s** on a real assertion, at
`InboxEndToEndInvariantTests.swift:600` (cited by line only because this entry is about a specific
observed run; the symbol is `scrubOnlyWakeStillConverges`):

```
Expectation failed:
  (world.capturedSignals.contains("inboxDataDidChange") → false)
    || (world.capturedSignals.contains("messagesStaged") → false)
```

I8 signal-liveness: a scrub-only merge wake evicted the phantom row but posted **neither** signal.
Note the preceding `waitUntil(5)` returned fast rather than timing out, so the eviction itself
happened — it is specifically the *signal* that was absent.

## What this rules OUT, with evidence

**Not the email-render security workstream** (`458863e86`, `c026f96d5`, `7dff5a582`, `c150c995d`,
`0fc20ef3c`). Mechanically checked: across `AutoSizingHTMLView.swift`, `RenderNavigationPolicy.swift`,
`ImageLoadFailureBanner.swift` and its preview, there are **zero changed lines** matching
`NotificationCenter`, `inboxDataDidChange`, `messagesStaged`, `postSignal`, `AccountManager`,
`SyncEngine`, `staging`, `PendingOperation` or `InboxViewModel`. The `DebugModeManager.swift` change
is **comment-only** — verified by filtering the diff to non-comment `+`/`-` lines, which returns
nothing.

**Not newly introduced by either concurrent session.** The test dates from `0ea8b5dcb` (2026-07-10)
and its file has not changed since `33b4d3cf6` (2026-08-06).

**A tempting attribution was CHECKED AND REFUTED.** The obvious hypothesis was the other session's
concurrent queue work, since `AccountManagerQueue.swift` was dirty in the tree during the failing run
and `1eb41702e` landed from it. But neither that commit's diff nor the uncommitted
`AccountManagerQueue.swift` diff references `inboxDataDidChange` or `messagesStaged` **at all**. The
hypothesis is recorded here *because it was refuted*, so nobody re-derives it and stops there.

## What this does NOT rule out — read this before closing the entry

**Passing in isolation does not prove the production code is correct.** It proves the failure is
*order- or shared-state-dependent*. Both of these remain live and are NOT distinguished by the
evidence above:

1. **Test-infrastructure pollution** — another suite leaves a `MainActor` singleton, a
   `NotificationCenter` observer, or the process-global lock in a state that suppresses the post.
   Swift Testing's `.serialized` **does not cross suite boundaries**, so suite-level isolation is not
   guaranteed by it.
2. **A genuine production defect that only manifests under that dirtied state** — i.e. the signal
   post is conditional on something a real device could also fail to satisfy.

**Do not close this as "flaky" on the strength of the isolated pass.** Distinguishing (1) from (2) is
the actual work, and the isolated pass is the *start* of that investigation, not its conclusion.

## Suggested next step, deliberately not taken here

Bisect the interference by running the E2E suite together with progressively larger subsets of the
other suites, rather than by re-running it alone. Three suites entered the target during the failing
run that are candidates for the interference (one from the render workstream, two untracked from the
other session) — but *any* suite could be the source, so a subset bisection is the honest method and
a guess at the culprit is not.

## Why it is registered rather than fixed

The failure is in inbox/staging/merge, a different subsystem and a different session's active
workstream, and the standing directive on the render workstream is *"no behaviour changes, just
security"*. Fixing an inbox signal path from inside a render-hardening pass would be exactly the
out-of-scope change that directive exists to prevent.

</details>

## Attribution class

Not sender-reachable, not user-facing. **No production defect.** The cost is entirely to the
**verification gate**: a vacuous assertion that reports green, plus an unsynchronised one that reports
red, in the same test.

## Relates

`ADR-IOS-055`–`058` (inbox unified read-model and its signals); the process-global test lock added by
`838f24cdd`; `IOS-TEST-009` (`awaitPendingQueueSettled`, the bound-wait-on-the-witness idiom this test
was forbidden from using); and the vacuous-test class shared with the render workstream's
`ImageFailureBannerStateTests.aDocumentChangeClearsBothHalves`.
