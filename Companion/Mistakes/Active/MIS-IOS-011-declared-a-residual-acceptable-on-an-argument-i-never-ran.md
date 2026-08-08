# MIS-IOS-011 — declared a residual "accepted, recoverable" on a safety argument I never actually ran

**Class:** design-process | review
**Severity:** high (would have shipped an unbounded wrong-content display, inside the very fix that
existed to prevent wrong content)
**First seen:** 2026-08 · **Recurrences:** 1 · **Status:** Active
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
