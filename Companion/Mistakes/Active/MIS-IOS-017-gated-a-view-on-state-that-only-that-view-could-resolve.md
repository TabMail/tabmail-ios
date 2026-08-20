# MIS-IOS-017 — gated a view on async state that only that same view's lifecycle could resolve, so the unresolved state erased its own resolver

**Class:** UI / lifecycle · shipped-release regression
**Severity:** critical (user-visible feature invisible in a LIVE App Store release, `v1.7.11`;
**15 green tests over the exact broken function** certified it — see the census below)
**First seen:** 2026-08-19 · **Recurrences:** 1 · **Status:** Active
**Related:** `PROJECT_MEMORY.md` topic *Stuck-`isLoading` rule — async view loads must defer-clear
their spinner flag, and `.task` must NOT hang on the conditional it flips* (the same class, one
release earlier, on `AccountDashboardView` / `RootView`) · `MIS-014` (a test that BLESSES the bug) ·
`MIS-IOS-016` (a test whose precondition never occurs) · **Rule owner:** `CLAUDE.md` § Development Rules

## The tell

I am adding an **async gate** to a view: a `Bool?` that starts `nil`, a `.task` that resolves it from
the database, and a render branch for each state. I write the unresolved arm first, and I reach for
**"render nothing until we know"** — it is the tasteful choice, it avoids a flash of the wrong UI, and
it feels strictly safer than guessing.

The specific comfort is *"`nil` is the conservative state — showing nothing can't be wrong."*

**Showing nothing IS the wrong thing when the thing you are hiding is the host of the task that
resolves the gate.** The question I did not ask: *which view runs the resolver, and is that view still
in the tree in the state I just wrote?*

In one line: **I made "we don't know yet" render an `EmptyView`, and `EmptyView` has no lifecycle — so
"we don't know yet" became permanent.**

## What actually happened

`7a31f1d22` ("Restore bounded queue behavior", shipped in `v1.7.11`, absent from the good `v1.7.9`)
added a bounded-window gate to `SummaryBubbleView`:

- `@State private var recentInboxEligible: Bool?` — starts `nil`.
- `displayMode(…)` mapped **`nil` → `.hidden`** ("Until the fast local query resolves, render nothing
  rather than flashing a spinner that cannot complete").
- `.hidden` rendered `EmptyView()` inside a **`Group`**.
- The `.task(id: message.id)` that resolves `recentInboxEligible` was attached **to that same
  `Group`**.

`Group` is a **transparent pass-through**: its modifiers are applied to each of its members, so the
task was attached to `EmptyView`. `EmptyView` contributes no node to the render tree and therefore has
**no appearance lifecycle** — the task never ran, `recentInboxEligible` stayed `nil` forever, and the
AI summary bubble was invisible for **every message in every folder, inbox included**, for the whole
life of the release.

The gate was self-sealing in both directions. Even granting a first run, the resolver's own first
statement is `recentInboxEligible = nil`; because `Group` distributes the modifier to whichever arm is
rendered, every resolved flip (`.empty` → `.suppressed`) swaps the member, cancels the task, restarts
it, and resets the state — the oscillation documented in the `Stuck-isLoading` topic, whose fix
sentence *"`Group` does NOT stabilize — it's a transparent pass-through"* was already in the companion
tree when this code was written.

## Why the suite did not catch it — a blessing test plus a defaulted seam

`SummaryBubbleViewTests` had **15 tests over this exact function** — every one of them a direct
`displayMode` call — and all passed. Of the 15, **12 omit the `recentInboxEligible` argument**, 2 pass
`false`, and 1 passes `nil`.

1. **A blessing test pinned the defect.** The single test that passed `nil` —
   `unresolvedWindowStateIsHidden`, *"unknown recent-window state does not flash a loading bubble"* —
   asserted `displayMode(recentInboxEligible: nil) == .hidden`. That is the bug, written down as the
   specification (`MIS-014`).
2. **A default parameter hid it from the other twelve.** The seam was declared
   `recentInboxEligible: Bool? = true`, and 12 of the 15 tests omit the argument. Production does
   reach `true` — the window query returns it for an eligible message, and the resolver's error path
   assigns it — but production never *begins* there: it always begins at `nil`. So the state the app
   always starts in was covered only by the test that blessed it. (The remaining 2 pass `false` and
   pin the resolved policy; they are correct and unchanged.)

**A default argument on a test seam is a silent claim that the default is the ordinary case.** Here it
claimed a state the app never starts in. **Of the 12 tests that omitted the argument, exactly 5 would
have gone red on `nil` had the default matched production** — the 4 in-Inbox content/empty cases plus
the in-Inbox database fixture. The other 7 assert `.hidden` for non-Inbox or demo-suppressed inputs and
stay correct under the defect, so they could never have detected it.

⚠️ **Both numbers in this paragraph were wrong in earlier drafts** — first "14 detectors", then "12".
The right question is not *how many tests omitted the argument* but *how many would have FAILED*, which
is a different predicate over the same set and has to be evaluated per test (`MIS-007`).

⚠️ **Count discipline, learned while writing this entry.** The first draft said "17 tests / 14 omit".
17 is the count *after* this fix added its own tests — the census had counted its own recording
(`MIS-033`). The shipped numbers are 15 / 12, measured with `grep -c` against
`git show <shipped-ref>:TabMailTests/Views/SummaryBubbleViewTests.swift`, not against the working tree.

⚠️ **A third count in this entry was wrong, and it was the easiest one to believe: the severity line
originally read "a 9,197-test green suite certified it".** That whole-suite figure appears in **no
test log in this investigation** — grepping every run log for it returns nothing. It was a
plausible-looking number carried in from memory, and it survived two rounds of cross-model review
because a suite-wide total reads as background colour rather than as a claim. The measured figures
are 9,240 with this fix and therefore 9,237 before it (this commit adds exactly 3 tests: 15 → 18 in
this file). **The rule: a number is a claim. If it did not come from a command run in THIS
investigation, either re-measure it or delete it** — and prefer the number that carries the argument
(here, the 15 tests over the broken function) over the impressive one that does not.

## The countermeasure

1. **A lifecycle modifier must hang on a view that renders in every state the gate can produce.** Never
   on `Group` (transparent), never on an arm that can be `EmptyView`. Use a real container (`VStack` /
   `ZStack`) *outside* the switch, so its identity survives the branch flips the task itself causes.
2. **"Unresolved" must never map to "render nothing"** when the resolver is hosted by the thing being
   rendered. Map unresolved to the pre-gate outcome and let the gate *downgrade* once it answers; a
   gate is then a refinement, not a precondition.
3. **A test seam's default must equal the production initial value.** The rule is not "no defaults" —
   it is "no default that differs from what production starts with". If production starts at `nil`,
   the parameter defaults to `nil` — then every existing test exercises the real starting state, and
   this whole class fails loudly on the first run. (Applied in the fix: the default was changed
   `true` → `nil`, which alone turns the pre-existing suite red on the pre-fix code.)
   ⚠️ **Changing a default DELETES the coverage the old default was silently providing.** Every test
   that omits the argument silently moves from pinning the old value to pinning the new one, so the
   old column loses its assertions in the same edit that fixes the seam — invisibly, with the suite
   still green. Re-pin the vacated column explicitly and in the same commit
   (`resolvedEligibleKeepsPreGateOutcomes` does that for `true` here). Found by cross-model review of
   this very fix, not by the suite.
4. **Before shipping an async render gate, state where the resolver runs when the gate is closed.** If
   the answer is "in the view the closed gate removes", it is this mistake.

---

## Pre-compaction index line (verbatim, 2026-08-20, pass 5)

Routed out of the always-loaded `tabmail-ios/MISTAKES.md` by the `companion-compact` skill, which
was reporting that file 19% over its 12,000 B budget. Kept **byte-for-byte**, inside a fenced
block so its index-relative link is not re-resolved from this directory, because the index
line had accumulated recurrence detail that exists nowhere else in this file.

```text
- **[MIS-IOS-017](Companion/Mistakes/Active/MIS-IOS-017-gated-a-view-on-state-that-only-that-view-could-resolve.md)** — gated a view on async state whose **only resolver was that same view's lifecycle**: `recentInboxEligible: Bool?` started `nil`, `nil` rendered `.hidden` → `EmptyView`, and the resolving `.task` hung on the **transparent `Group`** wrapping it, so it was attached to `EmptyView` — which has no lifecycle. The AI summary bubble was invisible for **every message, inbox included, in the LIVE `v1.7.11`** (`7a31f1d22`; `v1.7.9` fine). 🚨 **The suite had 15 tests on that exact function and all passed**: the 1 that passed `nil` BLESSED the defect (`nil → .hidden`, `MIS-014`) and 12 omitted the argument, whose seam default was `= true` — **a state production never starts in** (the other 2 pass `false` and are correct). ***Tell: "`nil` is the conservative state — showing nothing can't be wrong", without asking which view runs the resolver once nothing is shown.*** **Unresolved must render the pre-gate outcome; a seam default must equal the production initial value.** ⚠️ this entry's own first draft said 17/14 — it counted the tests the fix added (`MIS-033`). (×1)
```
