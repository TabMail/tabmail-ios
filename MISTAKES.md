# TabMail iOS — Mistakes Index

> **Compact index. One line per mistake.** Detail lives in `Companion/Mistakes/Active/`. Search this
> file and the tree with `rg -ni` before planning, reviewing, or fixing; read every match **in full**.
> Cross-cutting mistakes (design process, review discipline, agent ops, testing, secrets) are in
> [`../MISTAKES.md`](../MISTAKES.md) — read that one too; most iOS defects are instances of its classes.

**When you are about to:** write a migration → MIS-IOS-001 · **look up a table's columns, keys or
FKs → MIS-IOS-007** · touch sync/stale/cursor → MIS-IOS-002 ·
touch the action queue, moves, or undo → MIS-IOS-003, MIS-IOS-004 · regenerate the project →
MIS-IOS-005 · record a test baseline → MIS-IOS-006 · **write the word "recoverable" about an edge you
just made fail closed → MIS-IOS-008** · **edit anything under `Companion/` → MIS-IOS-009** ·
**write `hasSuffix`/`contains`/`split` on a filename, path component, MIME parameter or wire field →
MIS-IOS-013. · **make a guard read a transient in-memory global, or quote a log to settle an ordering → MIS-IOS-015.**
· **gate a view on async state, hang `.task`/`.onAppear` on a `Group` or on a conditional the task
flips, or give a test seam a default that differs from production's initial value → MIS-IOS-017.**
· **make a processing/queue policy visible by hiding or replacing UI in the same change → MIS-IOS-018.**
· **write `AppLogStore.append(` anywhere but `BackgroundSyncLogger`/`DeviceSyncLogger`/`AuthDiagnostics`, or reuse an existing channel's tag "so the lines interleave" → MIS-IOS-019.**
· **fix a finding phrased "at symbol X", or reach for the retained shape when a reviewer wrote a "deletion-first answer" → MIS-IOS-020.**

## Data integrity — the irreversible ones

- **[MIS-IOS-001](Companion/Mistakes/Active/MIS-IOS-001-appended-to-an-already-applied-migration.md)** — edited a migration that had already run on my own simulator; append = silently skipped, rename = launch crash. "Uncommitted" ≠ "unapplied". (×2)
- **[MIS-IOS-002](Companion/Mistakes/Active/MIS-IOS-002-date-window-for-imap-sync.md)** — windowed an IMAP sync query by DATE (a UID is archive-time, not message-date) → multi-month Archive data loss (ADR-IOS-042, `4145d2a`, `v59`); display ordering exempt. ×2: `fetched.count < limit` read a parse-survivor count as coverage — **a count that gates a deletion must be SERVER-reported.** (×2)
- **[MIS-IOS-004](Companion/Mistakes/Active/MIS-IOS-004-conflated-unknown-with-authoritative-stale.md)** — treated "could not determine" as "the provider says done" and dropped a user intention — **the single most repeated defect in this codebase's history.** Recurs outside the queue (`UID(0)` → `backfillComplete`; a Graph 404; `moveFailedAfterPossiblePartialCompletion`, #115). **Any terminal, non-revisiting state is a queue exit in other clothes.** (×many)

- **[MIS-IOS-021](Companion/Mistakes/Active/MIS-IOS-021-unified-two-look-alike-classifiers-and-widened-the-narrower-gate.md)** — de-duplicated two look-alike "is this message gone?" classifiers and made a DEAD branch live: `isConfirmedGoneError`'s **410** was unreachable inside `isMessageNotFoundError`'s 404-only gate, so a bare 410 began retiring ops. **A helper's effective acceptance set is its own ∩ every guard its callers sit behind.** (×1)
- **[MIS-IOS-007](Companion/Mistakes/Active/MIS-IOS-007-read-the-first-create-table-as-the-effective-schema.md)** — read the FIRST `create(table:)` as the effective schema; `v2_dropMessageHeaderFolderFK` had already removed `messageHeader.folderId`'s FK, so a "no Folder ⇒ no headers, cascade" argument was false and nearly became a doc comment. Grep returns the OLDEST definition first. (×1)
- **[MIS-IOS-008](Companion/Mistakes/Active/MIS-IOS-008-verified-the-recovery-path-not-the-states-where-it-cannot-run.md)** — called a state "recoverable" after finding a mechanism, without proving it can RUN there (`IOS-AI-003`/`004`; ×5 `IOS-QUEUE-008`'s "one ordinary gesture" re-entered the race it cured). **Name which intention the fallback completes.** (×5)
- **[MIS-IOS-013](Companion/Mistakes/Active/MIS-IOS-013-asked-a-byte-level-question-with-a-grapheme-level-string-api.md)** — asked a filesystem / MIME-parameter / wire-field question with **grapheme**-wise `String` APIs (`hasSuffix` `contains` `split`) — a combining **scalar** picks the cluster; invisible to ASCII fixtures, and ×5 was in the ORACLE (an `fi` LIGATURE). **Compare over `unicodeScalars`.** (×5)

## Design process — iOS instances

- **[MIS-IOS-003](Companion/Mistakes/Active/MIS-IOS-003-reconstructed-an-address-the-wire-already-gave-us.md)** — built machinery to rebuild the destination address `COPYUID` already returned; the defect was **granularity**, and undo is JUST a reverse move. ×5–×6 discarded Graph's `/move` id, then re-keyed the header but not the `PendingOperation`s. **Enumerate every HOLDER of an invalidated address.** (×6)

- **[MIS-IOS-015](Companion/Mistakes/Active/MIS-IOS-015-made-a-guard-depend-on-a-transient-globals-lifetime-across-an-async-hop.md)** — made a fail-open guard read a **transient in-memory global** across an async hop (`InboxView`'s `.messageDismissedFromDetail`, `.receive(on: DispatchQueue.main)`), so losing the race produced the very dismissal it existed to prevent. ***Tell: quoting a LOG to settle an ordering.*** (×1)
- **[MIS-IOS-016](Companion/Mistakes/Active/MIS-IOS-016-shipped-a-test-whose-precondition-never-occurs.md)** — shipped a test whose **PRECONDITION never occurs**. **Distinct from `MIS-014`**: a **VACUOUS** test stays green through bug AND fix, so **red-first cannot find it**; and a fast `waitUntil` proves its condition was true on ENTRY. (×2)

- **[MIS-IOS-017](Companion/Mistakes/Active/MIS-IOS-017-gated-a-view-on-state-that-only-that-view-could-resolve.md)** — gated a view on async state whose **only resolver was that view's own lifecycle** (`recentInboxEligible: Bool?`; the `.task` hung on a **transparent `Group`**) — the AI summary bubble was invisible in LIVE `v1.7.11`. **Unresolved must render the pre-gate outcome; a seam default must equal production's initial value.** (×1)
- **[MIS-IOS-018](Companion/Mistakes/Active/MIS-IOS-018-extended-a-processing-bound-into-display-semantics.md)** — a PROCESSING bound (`recentInboxWindowContains`) leaked into DISPLAY: a suppression notice replaced summary bubbles whose content already EXISTED (`v1.7.11`; reversed by ADR-IOS-078). **Existence beats eligibility.** (×1)
- **[MIS-IOS-019](Companion/Mistakes/Active/MIS-IOS-019-added-persistent-log-writers-outside-the-facade-its-registry-test-was-built-to-see.md)** — added debug-gated `AppLogStore.append(…, channel: .sync)` writers OUTSIDE `BackgroundSyncLogger`, so the always-on `.sync` tag carried writers `everyChannelIsClassifiedExactlyOnce` could not see. **A new stream = new `AppLogChannel` case + tag + ONE facade + a `debugGatedWriters` row.** (×1)
- **[MIS-IOS-020](Companion/Mistakes/Active/MIS-IOS-020-fixed-the-one-site-the-finding-named-and-built-the-retained-shape.md)** — fixed the ONE symbol a finding named (`R4-RS-1`, `ef81ee3e5`) and never censused the class; round 5 found the identical rollback-survives-the-line mechanism at **eleven** more sites. **Census the MECHANISM, not the symbol; price DELETION first.** (×1)
- **[MIS-IOS-022](Companion/Mistakes/Active/MIS-IOS-022-replaced-a-splitting-mechanism-and-left-its-loop-under-the-old-aggregate-deadline.md)** — deleted the queue's batch-**splitting** arm and left the per-member loop under the same 15 s `withTimeout` it had been escaping, so `requeueOrRetain` repeats the same prefix and the last member is **never sent** — **starvation = the wedge corollary**. ⛔ ×2: `ProviderMemberLoopBudget`'s elapsed-time margin starved identically. **Settle ONE member per attempt.** (×2)
- **[MIS-IOS-023](Companion/Mistakes/Active/MIS-IOS-023-wrote-a-new-call-over-the-one-the-path-already-owed.md)** — **wrote a new call over the one that path already owed, and the diff GREW so nothing looked lost**: the promoted `retirePartiallyCompletedOp` never called `recordMembersThatEnteredInbox`, with **NO call-site count drop (5 base, 5 candidate)**. **A count census reads CLEAN when a NEW path is promoted without acquiring the call its predecessors owed.** (×2)

## Build & test ops

- **[MIS-IOS-005](Companion/Mistakes/Active/MIS-IOS-005-bare-xcodegen-broke-nse-signing.md)** — ran bare `xcodegen generate`; literal `${DEVELOPMENT_TEAM}` → NSE never launches → smart push silently dies while background push still works. (×2)
- **[MIS-IOS-006](Companion/Mistakes/Active/MIS-IOS-006-stale-test-bundle-reported-a-wrong-count.md)** — recorded a baseline from a stale `.xctest`; a new file is not in the target until `./Scripts/xcodegen.sh` runs, and a peer build holding `build.db` makes `test-without-building` measure the PREVIOUS bundle. **Verify new tests by NAME; gate on `TEST BUILD SUCCEEDED`.** (×6)
- **[MIS-IOS-014](Companion/Mistakes/Active/MIS-IOS-014-wrote-a-red-first-proof-that-could-not-run-red.md)** — wrote a red-first proof that **could not run red**: a fixture SIZED in situ went NEGATIVE once the inverted code bisected to 0, and `String(repeating:count:)` **TRAPS**, burying 101 real failures. **`Fatal error`, or >1 `Test run with` line, = not evidence.** (×1)

## Companion tree — the proof that stopped running

- **[MIS-IOS-009](Companion/Mistakes/Active/MIS-IOS-009-amended-a-hash-pinned-fragment-and-killed-the-verifier.md)** — edited a hash-pinned or byte-frozen GENERATED fragment in place, killed its verifier, and hid every later check behind the `abort`. ⚠️ **TWO pinning conventions:** `{Memory,Decisions}/manifest.tsv` hash the **stripped** body — NEVER re-pin; `ported-manifest.tsv` / `amendments-manifest.tsv` / `Decisions/V3/manifest.tsv` hash the **raw** file — MUST re-pin. ⚠️ a GLOB in a comment aborts it too. **Run verifiers UNPIPED — `ruby … | tail` masks rc in zsh.** (×9)
- **[MIS-IOS-010](Companion/Mistakes/Active/MIS-IOS-010-bulk-write-selected-on-a-column-value-that-was-itself-a-guard.md)** — wrote a bulk `UPDATE … WHERE observedUidValidity IS NULL`; `optimisticMoveToFolder` writes that NULL **deliberately** mid-move, so it selected exactly the rows the sentinel protected: **C3**. **Grep every WRITER of every WHERE column.** (×1)

- **[MIS-IOS-011](Companion/Mistakes/Active/MIS-IOS-011-declared-a-residual-acceptable-on-an-argument-i-never-ran.md)** — called a finding an **accepted residual** under THE MANTRA on a mechanism I never opened: inline images persist under the **victim's** content key before `BodyAddressGate` refuses the write. **Assets on disk are a THIRD durable output of a body fetch; ask whether the named recovering peer EXISTS** (×2, ADR-IOS-079 §5). (×2)
- **[MIS-IOS-012](Companion/Mistakes/Active/MIS-IOS-012-guarded-one-reader-on-a-caller-census-whose-grep-shape-hid-half-the-callers.md)** — made `AccountManager.fetchAttachment` throw, then censused callers with a grep encoding the call's TYPOGRAPHY; the unseen `ComposeView.carryForwardAttachments` swallowed it into a `print` and forwards silently lost attachments. **Enumerate by the BARE SYMBOL, then read every catch.** (×1)

---

Recording obligation, entry format, and the `Retired/` rule: [`../Companion/Mistakes/README.md`](../Companion/Mistakes/README.md).
Increment `Recurrences` on an existing entry before creating a new one.
