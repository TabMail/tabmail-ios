# MIS-IOS-011 — declared a residual "accepted, recoverable" on a safety argument I never actually ran

**Class:** design-process | review
**Severity:** high (would have shipped an unbounded wrong-content display, inside the very fix that
existed to prevent wrong content)
**First seen:** 2026-08 · **Recurrences:** 2 · **Status:** Active
**Related:** `MIS-IOS-008` (verified the recovery path, not the states where it cannot run),
`MIS-IOS-010` (a clause doing two safety jobs is a claim, not an observation) ·
**Rule owner:** `CLAUDE.md` § THE MANTRA

## The tell

I reached for THE MANTRA's *"recoverable ⇒ fail closed, register it, move on"* exit and wrote the
registration comment **in the same motion as deciding it qualified**. The giveaway is that the
comment contains its own justification — *"nothing references those files, and a later successful
fetch regenerates the HTML from its own assets"* — stated as fact, in a confident cadence, about a
mechanism I had not opened. I had grepped enough to find the write site (`BodyAssetStore
.makeInlineImageWriter`) and then stopped, because the finding was already filed under a category
whose exit I knew.

Watch for: writing "accepted residual" **before** having written down the concrete sequence of
inputs that reaches the bad state. THE MANTRA's test is mechanically checkable — *does a sync, a
retry, or one gesture reach a correct state?* If I cannot name the recovering event, I have not run
the test, I have invoked its name.

The second tell is social: the owner asked *"is accepted residual safe though?"* — a one-line
challenge with no new evidence in it. It was answerable only by doing the work I had skipped, and
the work took four minutes.

## What actually happened

During the `BodyAddressGate` audit (2026-08-07/08), a codex finding reported that the render phase
persists inline images to disk **before** the gate can refuse the body write. I confirmed the
mechanism — `renderBody` builds `BodyAssetStore.makeInlineImageWriter(forContentKey: contentKey)`,
keyed by the **victim** row's content key — and then classified it as an accepted residual on the
grounds that the refusal blocks the `MessageBody` row and the FTS entry, so nothing would reference
the orphaned files.

The case I never worked: a later **legitimate** fetch of the victim renders HTML referencing a CID
whose identifier collides with one the stranger already wrote, **and** that single attachment
re-fetch fails transiently while the rest of the render succeeds. The victim's HTML then points at
the stranger's image file. That is a wrong-content display inside the message — and nothing undoes
it while that attachment fetch keeps failing, so it fails the recoverability test outright. It does
not belong in the residual bucket at all.

It is also the *same defect class the fix exists to prevent*, one layer down: I had reasoned about
the `MessageBody` row and the FTS row as if they were the only durable outputs of a body fetch. The
asset files are a third durable output and I never enumerated them.

## The fix

Refuse **before rendering**, on both render paths (`BodyFetchProcessor.fetch` and
`renderFetched`), so the bytes are never written. The write-time refusal stays and remains the
authoritative one — the pre-render pass cannot see a move that lands during the fetch. Preventing
the write is strictly cheaper than reasoning about the collision, which is the general shape of the
right answer whenever the "residual" is a durable side effect rather than a transient state.

Releasing the assets at refusal time was considered and rejected: a refusal can fire on a row that
already holds a good body (the provenance case), so releasing would destroy that body's images in
order to clean up orphans.

## Countermeasure

**Before writing "accepted residual" / "recoverable" / "fail closed and let it be", write the
recovering event by name first — the specific sync pass, retry, or gesture, and the state it
restores. If that sentence cannot be written without hedging, the classification is unearned.**

And when a finding says *X is persisted before the guard runs*, enumerate **every durable output**
of the guarded operation before classifying — rows, index entries, and files on disk. A guard that
covers two of three durable outputs is not a guard, and the missing one is invisible precisely
because the other two are the ones the code reads back.

---

## Recurrence ×2 — 2026-08-26, the scheduled-task removal branch (ADR-IOS-079 §5)

**Same tell, different surface, and this time the recovering event was even written down by name.**
The branch that deletes iOS scheduled-task support removed `KBTaskParser`, so `ReminderBuilder`
stopped contributing `t:` hashes to the `freshHashes` set it hands
`DisabledRemindersStore.gcStaleEntries`. The store's contract is that an **absent entry means
ENABLED**, and GC deletes any entry that is not fresh and is older than 90 days — so every synced
`t:` disable would be collected, permanently, by the platform that can no longer compute the
namespace.

The ADR clause registered this as safe in one sentence: *"its local 90-day GC may drop one; because
merges never delete on absence, the desktop keeps its own entry and re-seeds iOS on the next
broadcast. The user's choice is not lost."*

That reads like the countermeasure was followed — the recovering event **is** named (a desktop
broadcast). It is the same failure anyway, because naming a recovering event and checking that it
can RUN are different acts (`MIS-IOS-008`). Device Sync is a **peer-only relay with no server-side
retention**. If the desktop that made the choice is gone — reinstall, dead machine, new laptop —
the phone is the surviving copy, there is no peer left to re-seed from, and a replacement desktop
recovers the synced `[Task]` line with its disable silently reverted. The task then executes.

**What generalises beyond this instance:** a *removal* branch is a first-class producer of this
mistake. Deleting a producer does not only delete its outputs — it silently changes the meaning of
every consumer that reads *absence* of those outputs. Enumerate what still consumes the deleted
producer's namespace before writing the acceptance clause, and for a convergence/re-seed argument
ask **"does the peer I am relying on still exist in the scenario I am accepting?"** rather than
"does the merge rule preserve it?".

**Fix:** `gcStaleEntries` skips `t:`-prefixed hashes unconditionally — the invariant is *GC only
collects hash namespaces this device can re-derive*. Deliberately wasteful (iOS retains them
forever) rather than a conditional policy that would try to decide when a `t:` entry is really
stale using information this platform does not have.
Pinned two-sided by `DisabledRemindersCRDTTests.nonDerivableTaskHashesSurviveGC`.

---

## Pre-compaction index line (verbatim, 2026-08-13, pass 4)

Routed out of the always-loaded `tabmail-ios/MISTAKES.md` by the `companion-compact` skill, which
was reporting that file 62% over its 12,000 B budget. Kept **byte-for-byte**, inside a fenced block
so its index-relative link is not re-resolved from this directory, because the index line had
accumulated recurrence detail that exists nowhere else in this file.

```text
- **[MIS-IOS-011](Companion/Mistakes/Active/MIS-IOS-011-declared-a-residual-acceptable-on-an-argument-i-never-ran.md)** — classified a codex finding as an **accepted residual** under THE MANTRA's *recoverable ⇒ fail closed* exit and wrote the registration comment **in the same motion as deciding it qualified**, with the justification stated as fact about a mechanism I had not opened. The render phase persists inline images via `BodyAssetStore.makeInlineImageWriter` keyed by the **victim's** content key, *before* `BodyAddressGate` can refuse the body write; the case I never worked is a later legitimate fetch whose HTML references a **colliding CID** while that one attachment re-fetch fails — the victim's message then renders the **stranger's image**, and nothing undoes it while the fetch keeps failing. Not recoverable, so not a residual. Root shape: I treated the `MessageBody` row and the FTS entry as the only durable outputs of a body fetch; **asset files on disk are a third**, invisible because they are the one output the code never reads back. Fixed by refusing **before render** on both render paths (the write-time refusal stays authoritative — pre-render cannot see a move landing during the fetch). ***Tell: writing "accepted residual" before having written down the concrete inputs that reach the bad state — THE MANTRA's test is mechanically checkable, so if I cannot NAME the recovering event, I invoked the rule's name instead of running it.*** (×1)
```

---

## Pre-compaction index line (verbatim, 2026-08-20, pass 5)

Routed out of the always-loaded `tabmail-ios/MISTAKES.md` by the `companion-compact` skill, which
was reporting that file 19% over its 12,000 B budget. Kept **byte-for-byte**, inside a fenced
block so its index-relative link is not re-resolved from this directory, because the index
line had accumulated recurrence detail that exists nowhere else in this file.

```text
- **[MIS-IOS-011](Companion/Mistakes/Active/MIS-IOS-011-declared-a-residual-acceptable-on-an-argument-i-never-ran.md)** — classified a finding as an **accepted residual** under THE MANTRA and wrote the registration comment **in the same motion as deciding it qualified**, justified by a fact about a mechanism I had never opened. The render phase persists inline images keyed by the **victim's** content key *before* `BodyAddressGate` can refuse the body write, so a later fetch with a **colliding CID** renders the **stranger's image** — not recoverable, so not a residual. Root shape: **asset files on disk are a THIRD durable output of a body fetch**, invisible because the code never reads them back. ***Tell: writing "accepted residual" before writing down the concrete inputs that reach the bad state.*** (×1)
```
