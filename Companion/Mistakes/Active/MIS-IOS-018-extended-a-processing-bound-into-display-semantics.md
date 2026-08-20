# MIS-IOS-018 — extended a processing bound into display semantics, so policy about which rows get WORKED decided which rows get SHOWN

**Class:** design process / scope — layer conflation
**Severity:** major (user-visible in a LIVE App Store release, `v1.7.11`: a suppression notice
replaced summary bubbles that already had content; the owner had to reverse it by directive)
**First seen:** 2026-08-19 (act committed 2026-08-17 in `7a31f1d22`) · **Recurrences:** 1 · **Status:** Active
**Related:** `MIS-IOS-017` (the lifecycle defect *inside* the same display gate — a different class:
that one is about WHERE the gate's resolver lived, this one is about the gate EXISTING) ·
`IOS-AI-004` (the processing bound that was correct all along) · ADR-IOS-078 (the reversal) ·
`MIS-014` (two of the gate's tests blessed the suppression as specification)

## The tell

I am implementing a **processing policy** — an admission bound, a queue cap, a budget — and to make
the policy *legible to the user* I reach for the **view**: hide, replace, or annotate the UI for
items the policy excludes. It feels like completeness ("the user should know why there's no
spinner"), and the display change rides along in the same commit as the queue change, reviewed as
one unit under the queue's framing.

The specific comfort is *"the display should be honest about what the queue will do."* But the
policy names a **POPULATION** (which rows get worked), and I have quietly let it also name a
**PRESENTATION** (which rows get shown) — two different contracts with two different owners. The
question I did not ask: **does this display branch ever fire for an artifact that already exists?**

## What actually happened

`7a31f1d22` ("Restore bounded queue behavior", shipped in `v1.7.11`) implemented the owner-directed
IOS-AI-004 bounded-processing rollback — the newest `SyncConfig.maxRecentEmails` Inbox rows are the
only AI-eligible population. Correct, and still standing.
⚠️ **NARROWED 2026-08-20 (iOS #66).** That sentence was written on 2026-08-19 and was already stale
the same day: ADR-IOS-078's **pathway regating** (owner directive, same decision train) rescoped the
window to **SYNC-ORIGIN admission and the repopulation sweep only**. Manual open, push/NSE merge and
moved-into-inbox are window-**EXEMPT** (`AIJob.windowExempt`), so "the only AI-eligible population"
is no longer true of *processing* either — what still stands, and what this file is about, is that
the bound is a PROCESSING bound and never a DISPLAY one. The display half of this record was updated
on 2026-08-19; this processing sentence was not, which is exactly the shape `MIS-019` instance 40
records (a retraction swept only the diff's file set). ⛔ Do not read this paragraph as licence to
re-gate an exempt producer to "restore" a global bound — that would undo the owner directive.
In the same commit, `SummaryBubbleView`
gained a `recentInboxWindowContains` query and a "AI work is suppressed for older messages in large
inboxes" notice. The notice branch ran **before** the content check, so it replaced the bubble even
when `summaryBlurb` already held a finished summary — derived content the user already had was
withheld to explain a policy about content that would never be derived.

The owner ruled the whole display half an error (2026-08-19): *"there is no reason whatsoever to
gate AI that already exists … if an AI summary exists, there's never a reason to gate it."* Total
cost: the gate shipped in `v1.7.11` (its lifecycle defect, `MIS-IOS-017`, made it hide the bubble
for every message); hotfix PR #59 made the erroneous gate work as written; a third PR (ADR-IOS-078)
then removed it as designed-in-error. Three changes to land at "display shows what exists."

Two of the gate's own tests (`oldInboxMessageRendersSuppression`,
`oldInboxMessageDoesNotRenderCachedSummary`) asserted the suppression — including suppression of
EXISTING content — as the specification, so the suite defended the error (`MIS-014`); both are
deleted, not repaired, which is the strongest evidence the defect was specification-level.

## The countermeasure

1. **A processing bound's consumer list is a layer census.** When a policy seam is created
   (`recentInboxWindowContains`), enumerate its consumers by layer: producers, executors, admission
   — yes by construction; **display — never by default.** A display consumer of a processing seam
   is its own product decision and needs the owner's explicit yes, in its own words, not bundled
   approval inside a queue change.
2. **Existence beats eligibility.** A derived artifact that already exists is display-eligible
   regardless of any processing policy: check "does the artifact exist?" BEFORE any policy branch
   in every display decision. (Applied: `SummaryBubbleView.displayMode` returns `.content` for any
   existing summary before every eligibility branch; nothing downstream of the content check can
   hide existing AI. The one state checked before content is demo-with-AI-declined — a CONSENT
   surface, deliberately not an eligibility policy; ADR-IOS-078 records that precedence. "Policy
   branch" here means eligibility/scheduling policy, never a consent gate.)
3. **The bundling is the trap.** The display gate entered inside a 40-file queue rollback and was
   reviewed under that framing. A view-layer diff inside a policy commit deserves the question:
   *would this change stand on its own if proposed separately?* Here it would not have.

---

## Pre-compaction index line (verbatim, 2026-08-20, pass 5)

Routed out of the always-loaded `tabmail-ios/MISTAKES.md` by the `companion-compact` skill, which
was reporting that file 19% over its 12,000 B budget. Kept **byte-for-byte**, inside a fenced
block so its index-relative link is not re-resolved from this directory, because the index
line had accumulated recurrence detail that exists nowhere else in this file.

```text
- **[MIS-IOS-018](Companion/Mistakes/Active/MIS-IOS-018-extended-a-processing-bound-into-display-semantics.md)** — a PROCESSING bound (newest-100 AI window, `recentInboxWindowContains`) leaked into DISPLAY: a suppression notice replaced summary bubbles whose content already EXISTED (`7a31f1d22`/`v1.7.11`; reversed by ADR-IOS-078). **Existence beats eligibility — check "does the artifact exist?" BEFORE any policy branch in a display decision.** ***Tell: making a queue policy "legible" by hiding/replacing UI in the same commit.*** (×1)
```
