# A staging key that names an ADDRESS must re-prove IDENTITY before it reuses payload

**Status:** Current · **Date:** 2026-08-04 · **Register row:** `IOS-NSE-005` (BLOCKING, C3
misattribution) · **Related:** ADR-IOS-061 (UIDVALIDITY reset closure), ADR-IOS-037 (NSE/main-app AI
lease), `IOS-NSE-001`, `IOS-EPOCH-001` / `IOS-AI-003` (the nil-folder-epoch population),
`MIS-005`, `MIS-IOS-004`, `MIS-024`, `MIS-018`

---

## The shape, stated so it transfers

`nse_processed_message`'s primary key is `"<accountId>:<messageId>"` — and on IMAP `messageId` is
the **UID**, which is an ADDRESS in a numbering space, not an identity. A UIDVALIDITY turnover
reissues that address to a different message. Any writer that finds a row at such a key and reuses
what is already on it is asserting "same key ⇒ same message", which is false exactly when it matters
most.

`NSEStagingDB.stageHeader` did that. Its `ON CONFLICT(id) DO UPDATE SET` list overwrites the
IDENTITY columns (`rfc822MessageId`, `observedUidValidity`, `subject`, `senderEmail`, `date`, …) and
deliberately RETAINS the body/AI payload (`htmlContent`, `textContent`, `attachmentsJSON`, `icsText`,
`hasUnresolvedCIDs`, `summaryBlurb`, `summaryTodos`, `actionTag`, `reminderDate`, `reminderTime`,
`reminderContent`, `aiCompleted`, `notified`, `processedAt`). **Retention is CORRECT for the case it
was written for** — a re-push of the SAME message, where recomputing body and AI is pure waste, and
the `AIOwnershipLease.ensureRow` placeholder that must survive to be filled in. The defect is that
"same id" was taken as "same message" *when the row already carried the `rfc822MessageId` that would
settle it*.

Its own comment had already identified the hazard for the EPOCH — *"keeping a PREVIOUS run's epoch
beside a re-read UID is precisely what would misattribute the row"* — and then left the PAYLOAD
retained on the reasoning it had just rejected.

## Why it was not merely a display splice

The end state, verified rather than inferred, on an IMAP INBOX whose `Folder.lastKnownUidValidity`
is nil:

- `NSEStagingDB.getCachedResult` selects `WHERE id = ? AND aiCompleted = 1` — **no RFC term, no
  epoch term** — so `NotificationService`'s step-5.5 staging probe HITS the predecessor's payload,
  fills the successor's notification with the predecessor's summary/action/reminder, delivers, and
  **returns before its own terminal write**. This half needs no nil epoch and is reachable on ANY
  IMAP account. It also makes the durable half's precondition deterministic rather than accidental,
  because run 2 never reaches `persistProcessedMessage`.
- The next merge takes the NEW-HEADER arm: there is no durable row at the address, so
  `DurableIdentityLookup.find` returns nil and `NSEDataBridge.insertNewHeaderFromStaging` runs —
  which does **not** call `nseMergeIdentityConfirmed` (its only two production call sites are both
  EXISTING-durable-row arms). The successor's header lands with the predecessor's
  `summaryBlurb`/`summaryTodos`/reminder/`actionTag`; a `MessageBody` under the successor's key holds
  the predecessor's body; `flushNSEBatchToFTS` indexes the predecessor's text and sets
  `bodyComplete = 1`; `messageAICache` is poisoned under the **successor's RFC key** (so it survives
  every later UID re-key and is a permanent HIT); and `queueSetTagPendingOp` queues an IMAP keyword
  write putting the predecessor's action tag **on the wire against the successor** — C3.
- Nothing recovers it: sync sees a correct-looking header, the body queue selects
  `bodyComplete = 0`, and `BodyFetchProcessor` inserts with `onConflict: .ignore`.

## The four defenses, and which one was false

Three genuinely hold and must not be re-opened: IMAP staging only ever SELECTs INBOX (no
cross-folder UID collision); on a SETTLED folder `uidValidityStagingRowStatus`'s `isOldEpoch` skips
AND deletes the re-headed row; and the reset reaction's step-4
`NSEDataBridge.purgeStagedStateForFolder` really does precede its step-5 stamp. What they leave open
is the **nil-folder-epoch** population — `isOldEpoch` needs BOTH epochs present, and the sole
detector for a folder that never earned an epoch is
`verifyAndBootstrapPrePopulatedFolderEpoch`, whose `.unobservable` legs leave it nil permanently.

The fourth defense was **FALSE and is retracted**: *"the re-headed row keeps its predecessor's
`processedAt` and ages out on the 60 s clock"*. `mergeNSEStagingData`'s step-1 read is
`SELECT * FROM nse_processed_message WHERE populated = 1` with **no `processedAt` predicate at all**.
`abandonedCutoff` appears only at the POST-COMMIT deletion decision and in the `populated = 0` orphan
reap. **It is a DELETION predicate, not an ADMISSION predicate** — it stops the row being merged
TWICE, never ONCE. (`MIS-024` instance 5: a mechanism that is real, correct and called, but whose
call site is downstream of the damage. The temporal hand-offs — *ages out*, *gets reaped*, *expires*,
*is reconciled later* — always require establishing the call site's POSITION by reading the statement
order.)

### The collision window is not push-to-push — it is bounded only by the next app launch

Raised by the owner, 2026-08-04, and it is the fact that sets this defect's true exposure. The
retraction above says the 60 s clock does not gate admission. The consequence goes further and is
worth stating on its own, because "60 seconds" is the number a reader carries away and it implies a
short-lived row:

**Every `DELETE FROM nse_processed_message` that can remove a `populated = 1` row lives in
`NSEDataBridge` — the MAIN APP** (`:592` folder purge, `:1148`, `:1410`, `:2392`, `:2423`, and the
`:2496` orphan reap which only targets `populated = 0`). The single NSE-side delete is the identity
clear this fix adds. Merging runs when the app runs. **So a staged row has no TTL: it lives until the
user next launches TabMail.** A device that receives pushes for a week without the app being opened
holds week-old rows at UID-keyed addresses.

The trigger is therefore *staged-row lifetime ∩ UIDVALIDITY turnover*, not *inter-push interval ∩
turnover*. A turnover rate of "once a year" does not make the collision once-a-year rare when one of
the two intervals is unbounded. Do not describe this class of defect as rare without establishing
BOTH intervals — `staleStagingWindowSeconds = 60` reads like the first one and is not.

**What this does NOT change, and why the fix still holds across an unbounded window:** door (b) (epoch
disagreement) is unavailable on nil-epoch folders, so it cannot be what carries a year-long window.
Door (a) (RFC disagreement) can, and it is structurally reliable on IMAP for a reason independent of
staging: `NotificationService.swift:513-514` resolves the push **by** Message-ID
(`fetchIMAPMessage(accountId:rfc822MessageId: headId, …)` → `searchMessageId` → UID). The RFC id is
the INPUT to the fetch, not a field parsed from its result, so it cannot be absent on that path. The
residual unreachable-today hole is a stage carrying neither identity, which RETAINS by design (anchor
test `unanswerableIdentityRetainsRatherThanClears`, because clearing on absence of evidence destroys a
live `AIOwnershipLease` claim). It would become reachable only if an IMAP push were ever resolved by
something other than Message-ID.

**And the epoch half of the owner's question, answered from source:** the NSE already observes and
persists its own epoch, with the same 0 → nil normalisation the main app uses —
`NSEIMAPConnection.swift:110-114` (`observedUidValidity = value != 0 ? Int(value) : nil`, whose own
comment cites `IMAPProvider.selectMailboxTracked` as the convention it is matching), stored in
`nse_processed_message.observedUidValidity` via the `ALTER TABLE` at `NSEStagingDB.swift:83-85`. That
was `IOS-NSE-001`. There is nothing further to persist NSE-side; the gap was never observation, it was
that `stageHeader` did not CONSULT what had been observed.

## The fix, and why it is one line of policy rather than machinery

`stageHeader` now reads the stored `(rfc822MessageId, observedUidValidity)` inside its existing write
transaction and, on POSITIVE disagreement, DELETEs the row so its own statement lands as a plain
INSERT — every column it does not write returns to its schema default. The two doors are
`NSEDataBridge.nseMergeIdentityConfirmed`'s, with the same precedence:

- **(a) RFC door — first and unconditional.** Both sides' `MessageIdentity.comparableRfc822Identity`
  present and unequal ⇒ different, never overridden by an epoch agreement.
- **(b) Epoch door — only when (a) could not adjudicate.** Both `observedUidValidity`s present and
  unequal ⇒ different.

**Door (a) is available exactly where door (b) is not**: the IMAP NSE resolves its push by
Message-ID (`NSEIMAPConnection.fetchIMAPMessage(rfc822MessageId:)` → `searchMessageId` → UID), so
both sides carry an RFC even on the nil-epoch folder that defeats the epoch door. Gmail/Graph leave
the epoch nil always and confirm through (a).

`nseMergeIdentityConfirmed`'s epoch door additionally requires `!folderQuarantined`; that guard is
deliberately NOT carried, and the reason is stated at the code (`MIS-018`): there the comparison is a
live NSE observation against the DURABLE `Folder.lastKnownUidValidity`, which lags mid-reset, so a
disagreement can mean "our stamp has not caught up". Here BOTH values are live SELECT observations
the NSE made itself of the same folder — no third party's staleness can manufacture a disagreement.

**One write closes both halves**, and the ordering that makes that true is load-bearing:
`stageHeader` runs strictly BEFORE the peer probe and before `getCachedResult` in
`NotificationService.process`, so a cleared `aiCompleted` makes the step-5.5 probe MISS and run 2
does its own AI. Do not move that call later in the run.

## The three traps — each a mirror image (`MIS-005`), and why none was taken

1. **An age predicate on `mergeNSEStagingData`'s step-1 read is a MESSAGE-DROPPER.** Adding
   `processedAt >= abandonedCutoff` to `SELECT … WHERE populated = 1` looks like the natural fix and
   converts a misattribution into a **silently dropped staged message** — a legitimately slow but
   perfectly valid row (a long AI wake, a cold launch after a night of pushes) excluded from the
   merge and then deleted by the very reap the predicate borrowed its constant from. That is a
   dropped user intention, also in the non-recoverable set. **The step-1 read is untouched.**
2. **Clearing on ANY conflict destroys the feature retention exists for.** A duplicate push would
   discard body and AI a previous run already paid for, and an RFC-less message could never
   accumulate payload across wakes, and the `AIOwnershipLease` placeholder (`populated = 0`, both
   identity columns NULL) would be deleted out from under a live claim. The gate is **positive
   evidence of a DIFFERENT message, never absence of evidence that it is the same one** —
   `MIS-IOS-004`'s "could not determine ≠ authoritative" in its other direction. Nil on either side
   of both doors RETAINS.
3. **No generation counter, shadow table, lease or run token.** That is the compensating-mechanism
   shape A3 / `MIS-003` forbids: the identity needed to decide this was already on the row.

## Reference-branch finding (rule R0/A1)

**AUTHORED, not restored.** `v2final` (`e28dd4edb`) has `stageHeader` with the identical `ON
CONFLICT` list, the identical retention and the identical doc comment — it **shares the defect**.
Shipped `07a4bb703` shares it too and is **strictly weaker**: `observedUidValidity` does not exist at
that tag, so door (b) is not even available there, and its `getCachedResult` is byte-identical to
v3's. There was no guard to port. The reference is a floor, not a ceiling (A1 corollary 3).

## Test-reachability note (durable, and it cost real time to establish)

`TabMailTests` could not reach ANY NSE-target symbol: its sources were `TabMailTests` only. Every
pre-existing NSE staging test therefore **hand-mirrors the production SQL**
(`NSEGradualMergeTests.stageHeaderRow`, `StagedSnapshotParityTests`, and `NSEDataBridgeTests`'
`cacheProbeIgnoresIncomplete`, which re-types `getCachedResult`'s SELECT). **A mirrored row cannot
red-prove a fix that lives inside `stageHeader`, because the fix is upstream of the row** — so making
the real writer drivable was required, not gold-plating.

`project.yml` now compiles five NSE-only files (`NSEStagingDB`, `NSEMessageMetadata`, `NSEConfig`,
`NSELog`, `SharedNSEData`) into `TabMailTests` as well as the extension. They exist in no other
target, so there is no duplicate symbol with `TabMail`. The three that name `Shared` types —
`NSEStagingDB` (`RenderedBody`, `MessageIdentity`), `NSELog` (`NSELogStore`, `NSEProviderSupport`)
and `SharedNSEData` (`NSEBadge`, `NSELogStore`), all internal to the main-app module — reach them
through `#if TABMAIL_TESTS @testable import TabMail`, where `TABMAIL_TESTS` is set only on that
target's `SWIFT_ACTIVE_COMPILATION_CONDITIONS`. ⚠️ **Deliberately NOT `canImport(TabMail)`** — its
value in an app-extension target depends on the module search paths and is not something production
source should bet on.

⚠️ **The census that picks those files inherits the shape of the search that produced it, and mine
inherited the wrong one.** I enumerated *the files I had edited* (`NSEStagingDB`, `NSELog`) instead
of *the files in the new sources list that name a main-app-module type* — and wrote the wrong noun
into the `project.yml` comment, where it read as deliberate. `SharedNSEData.swift` is completely
unmodified (`import Foundation` only) and still names `NSEBadge` and `NSELogStore`, so the shared
build broke for **every** agent in the tree until a peer diagnosed it. **Adding a file to a target is
not an edit to that file, and the correct predicate is a property of the file's CONTENT, never of
its git status.** The mechanical form: for each added file, extract the referenced type names, then
subtract what the added set itself declares; whatever remains must resolve from a module the target
actually imports. Two classes fall out — types from the main-app module (need the guarded import) and
types from NSE files that were NOT added (need adding, or the reference is a comment/string literal:
`NSELog`'s `"ai.tabmail.ios.NotificationService"` subsystem string is exactly that false positive).

Rejected alternatives, so nobody re-derives them: moving the files into `Shared/` drags NSE logging
and config into the main app (`NSELog`'s subsystem is the extension's bundle id); adding
`- path: Shared` to `TabMailTests` duplicates `RenderedBody`/`NSELogStore`/`MessageIdentity` and
breaks the existing tests that use the main-app copies.

Also: `AppDatabase.createNSEStagingDB` deliberately does NOT own the `observedUidValidity` column —
only `NSEStagingDB.ensureObservedUidValidityColumn` (called from `open()`, which needs an App Group
container) adds it. A test that builds a staging file must ALTER it in, as
`NSEStaleStagedRowInvalidationTests` already does.
