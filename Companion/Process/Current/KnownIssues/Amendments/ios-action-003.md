# IOS-ACTION-003

> **Post-freeze record.** Added 2026-09-06 through the amendment surface in
> `Scripts/compact_known_issues.rb`. It has no row in the hash-pinned archive and is not regenerated
> from it.
>
> **This record AMENDS [`IOS-ACTION-001`](../ios-action-001.md).** That row is a hash-pinned closed
> decision about ONE frozen migration and cannot be edited (Data Integrity rule 5 freezes `v74`'s
> name and body, and the register row carries the pre-split source hash). Its **scope** sentence —
> "an owner-approved **one-time** upgrade boundary" — is what changes here: the predicate-free purge
> is now a **recurring launch rule**, not a single historical migration. Everything IOS-ACTION-001
> says about `v74` itself, and its whole cost/recoverability argument, stands unmodified and is the
> basis this record reuses.

- Register classification: `accepted`.
- Relates to: [`ios-action-001.md`](../ios-action-001.md) (the one-time `v74` precedent this
  generalises), [`ios-action-002.md`](../ios-action-002.md) (the epoch-reset drop, a *runtime* exit
  and therefore a different class), `Companion/Rules/Active/never-drop-user-intention.md`
  (2026-09-06 amendment), `Companion/Decisions/V3/Active/adr-ios-071.md`.

## Status

✅ **ACCEPTED (2026-09-06, owner-approved)** — every app-release change retires the action queue.

**AMENDED 2026-11-12 (owner ruling, GitHub #531):** the boundary now re-queues unsent draft saves in
the same transaction; see "Draft saves re-queued" below. The 2026-09-06 draft acceptance is kept as
history.

**AMENDED 2026-11-14 (owner ruling, GitHub #876):** the boundary now puts the retired actions' message
ids on the re-read lists of a change-tracked account's folders (or arms the catch-up); see "Retired
actions read again" below. The "full sync restores the server's state" sentence is kept as history.

## Subsystem and search terms

Action queue; `pendingOperation`; app upgrade; app version; release boundary; `appReleaseStamp`;
`retirePreviousReleaseActionQueue`; `currentAppRelease`; migration `v89`; blanket purge; lifecycle
carve-out; full sync due; `lastFullSyncAt`; re-read list; recheck; `recheckRetiredActions`; tracked folder;
catch-up armed; undecodable row; #876

## Full detail

`AppDatabase.retirePreviousReleaseActionQueue` runs inside `AppDatabase.init`, on the raw
`DatabasePool`, before `AppDatabase.shared` is published and therefore before anything in the process
can admit or claim work. If the release recorded in `appReleaseStamp` (migration `v89`) differs from
the running bundle's `CFBundleShortVersionString (CFBundleVersion)`, then in **one transaction**:
every `pendingOperation` row is deleted **without being decoded**, every account is marked
full-sync-due (`Account.lastFullSyncAt = NULL`), and the new release is recorded. Either all three
commit or none does; a failure propagates out of `init`, leaves initialization incomplete, and the
next launch retries the whole thing. A **missing** stamp counts as a boundary — first adoption cannot
know which release queued the rows it finds. An **unchanged** release does not purge: this is not a
per-launch, per-foreground, per-login or per-retry clear, and ordinary crash recovery
(`recoverPreviousSessionResidue`) is unchanged.

**Why this is not a fifth exit.** The four exits in `never-drop-user-intention.md` answer *"may the
drain retire THIS operation, on THIS attempt, given what the provider said?"*. This boundary answers
nothing about any operation: it consults no evidence, no epoch, no identity and no provider result,
it destroys the queue as a whole, it runs outside the drain, and it is explicitly owner-approved —
all three carve-out properties. A runtime retirement dressed in this language would still owe one of
the four exits.

**Accepted cost.** A user who updates the app while work is queued may have to repeat a gesture. The
queue normally drains in seconds, so the reachable set is small; the full sync that the same
transaction schedules restores the server's own state for any optimistic local change the retired
operation would have carried. **Recoverability:** every retired op's target is still visible after
that sync, so the gesture is re-issuable — the same argument IOS-ACTION-001 established for `v74`,
re-checked against the recurring case.

**Scope limit, unchanged from the carve-out.** Authored `Draft` and `outboxMessage` rows, mail,
bodies, attachments and FTS content are untouched; `pendingOperation` owns no authored bytes and
nothing cascades from it. A retired `.saveDraft` loses only the automatic server-push intention — the
local `Draft` keeps its content and reopening/editing/saving admits fresh work. **No draft sweeper
and no automatic re-admission are added**, and sync alone does not upload content that never reached
the server; a never-uploaded draft stays a draft until the user saves it again.

**Reachability, fixed 2026-11-09 (GitHub #519).** "Saving again" needs the draft to still open, and
it opens only from its `draft-…` placeholder header. That header used to lose its protection with the
retired operation, so the full sync the boundary schedules deleted it (the whole-folder branch on any
provider, the date window on Gmail and Outlook) and the draft could no longer be opened. The full
sync's stale rule now never deletes the placeholder of a local `Draft` that has no server copy
(`SyncEngine.neverUploadedDraftPlaceholderIds`, consulted by `runSyncMessages`); the placeholder of a
draft that is gone (sent, deleted, evicted) or has a server copy is removed as before. On Gmail the
open route also had to change: it sent every Drafts row to the Gmail draft lookup, which refuses a
placeholder id, so `ServerDraftComposeLoader.resolveOpenAuthority` now sends a placeholder id to its
local owner on every provider. The boundary itself is unchanged.

**Testing consequence, recorded 2026-11-14 (GitHub #883).** Since #519, "the save landed" and "the
save's op is gone" are different states. A save that lands as `.created` leaves the draft a
`serverDraftId` (`DraftStore.applyPushCompletion`; a Gmail answer with no message id still names the
resource), while an op that disappeared with no `serverDraftId` is the never-uploaded state this rule
protects. A test that means a landed save must land it through `DraftStore.pushDraftToServer`, not by
deleting the op: `DraftPlaceholderStaleWindowTests` did the latter and went red at #519's fix,
although the Gmail path was right. (The one landed save that leaves no `serverDraftId` is IMAP's
`.unaddressable`, an APPEND without APPENDUID; this rule also keeps that draft's placeholder, which
#883 did not examine.)

**Why a blanket purge rather than a version-aware migration.** The same reason IOS-ACTION-001 gives
for `v74`: deciding per row would mean decoding each one and validating its address space against
whatever keying the previous release used — the "reconstruct an address the system was already told
and discarded" pattern `MIS-IOS-003` and `CLAUDE.md`'s *THE ADDRESS PROBLEM* forbid. The boundary
deliberately holds no per-operation version field, no ordering backfill and no replay history.

**Draft saves re-queued, 2026-11-12 (owner ruling, GitHub #531).** The owner reversed the "no draft
sweeper and no automatic re-admission" acceptance above: a retired `.saveDraft` left a draft that never
reached the server or other devices until the user edited it again, and nothing told the user. In the
same transaction that deletes the queue, `retirePreviousReleaseActionQueue` now admits a fresh
`.saveDraft` (`PendingOperation.draftSave`, the row `queueDraftSave` admits) for every `Draft` whose
`serverPushStatus` is `NULL`, `dirty` or `pushing`, with a non-empty `instanceEpoch`, an existing
account and no owning `outboxMessage`. It reads `Draft` state, never the retired rows, so the boundary
still decodes nothing it deletes. A pushed draft is not re-sent; every other action is still retired
and keeps the accepted cost above. Tests: `AppReleaseBoundaryTests.boundaryReQueuesOnlyUnsentDrafts`,
`NeverDropExitClosureTests.anAppUpdateReQueuesAnUnsentDraftSave` (IntentionLedger, FakeIMAPServer).

**Retired actions read again, 2026-11-14 (owner ruling, GitHub #876).** The "Accepted cost" paragraph
above says the full sync the boundary schedules restores the server's state for any optimistic local
change a retired operation would have carried. That stopped being true for folders the change reader
tracks: a tracked folder gets no window listing (ADR-IOS-111 decision 4), so a message archived just
before an update stayed in the Archive locally while the server still had it in the Inbox. It first
applies at the update after the one that introduced tracking (no folder is tracked before its first
listing). In the same transaction, BEFORE the delete, `SyncEngine.recheckRetiredActions`
(`TabMail/Services/Sync/SyncEngineRetiredActionRecheck.swift`) now reads each retired row's RAW
columns only (account, folder path(s), kind, message ids; no model decode, so nothing it reads can
throw and stop `AppDatabase.init`), and for every account that holds a change bookmark
(`Account.lastHistoryId`):
- a move (archive, delete, move) or a read/flag change (read, unread, flag, unflag): its ids go on the
  re-read list (`Folder.changeState.recheck`) of the folder it was queued on and, for a move, of its
  destination too, whatever that folder's tracking or synced state. Every reader reads every listed
  folder's list (ADR-IOS-111, amendment 2026-11-14 "every listed folder is read; an explicit re-read
  answer applies whatever the window"): Gmail reads all lists and answers every folder by the
  message's labels; Outlook reads a synced folder's list after its delta, also during its baseline,
  and on a `.all` pass reads the list of a folder outside the synced set (a custom, non-favourite
  folder) on its own, by id, with no bookmark or coverage change. The apply takes a record that
  answers a listed id whatever the folder's held range, also during a baseline. So an older message
  (outside every listing window) gets its server state back in every folder the action named: its read
  state and flag, and its place (the optimistic row in the destination is removed, the message comes
  back to the source). The full sync's window listing would not do it: its stale sweep is
  date-bounded on Gmail and Outlook, and it never lists a folder outside the synced set;
  *Superseded (same day, twice):* (1) "but ONLY of a folder whose change state is tracked. An untracked
  folder gets nothing: the full sync window-lists every untracked syncable folder, and a folder
  outside the syncable set (an Outlook custom, non-favourite folder) is listed when it is opened. An id
  put on such a folder's list would never be read by a per-folder reader, would stick, and would take
  part of every pass's re-read budget for good"; (2) the text that replaced it:
  > - a move (archive, delete, move) or a read/flag change (read, unread, flag, unflag): its ids go on the
  >   re-read list (`Folder.changeState.recheck`) of the folder it was queued on and, for a move, of its
  >   destination too (Outlook re-reads folder by folder; Gmail places a re-read message by its labels in
  >   every folder), but ONLY of a folder the change reader reads: one in the syncable set
  >   (`SyncEngine.isSyncable`, main roles and favourites, the folders `ChangeFolder.isSynced` marks),
  >   tracked or not. Outlook reads every synced folder's list, also while that folder is still in its
  >   baseline; Gmail reads every list. An untracked syncable folder is NOT left to the full sync: on Gmail
  >   and Outlook its window listing's stale sweep is date-bounded, so an older message's optimistic row
  >   would survive it (an old message archived just before the update would show in both the Inbox and
  >   the Archive until the Archive's catch-up ran). A folder outside the syncable set (a custom,
  >   non-favourite folder) gets nothing: a per-folder reader never reads its list, so an id there would
  >   stick and take part of every pass's re-read budget for good. Such a folder is corrected when it is
  >   opened, within that listing's window only; an older message's optimistic row there stays until the
  >   user acts on it (accepted, below);
  Both were wrong in part: an id there would stick only on Outlook (Gmail reads every list), and an
  Outlook folder whose read is a baseline gated a re-read answer by its held range, so an older message
  moved out of it never came back. Neither gap is accepted any more; both are corrected as above;
- a draft delete arms its folder's catch-up (`markCatchUpLapse`, folder found by the recorded path),
  which loads the server draft back so the delete can be redone; its address is a draft resource
  (Gmail) and never goes on a list. Without this the server draft stayed on the server and other
  devices while the phone never showed it again;
- *(2026-11-15, #903: every retired id is kept in every folder and no catch-up is armed for them;
  the passes drain the list within the per-pass budget, and the apply cuts only a pass's own
  additions, ADR-IOS-111 amendment 2026-11-15. The rest of this item is history.)* Over
  `SyncConfig.changeRecheckLimit`, a folder the catch-up checks (`SyncEngine.isSyncable`) keeps
  its first ids and its catch-up is armed; a folder the catch-up never checks (a custom folder that is
  not a favourite) keeps every id, read in turn within the per-pass budget, since nothing else would
  repair a dropped one. The change apply does the same (ADR-IOS-111, amendment 2026-11-14 "every
  listed folder is read", rule 3). *Superseded 2026-11-14 (review round 4):* "each list stays within
  `SyncConfig.changeRecheckLimit`; overflow arms the folder's catch-up, as the change apply does";
- a row whose kind or ids do not read (an older release's kind, ids that are not a JSON list) arms its
  folder's catch-up, or every folder's of its account when the folder cannot be resolved by
  `(accountId, folderPath)`; the same for a move, read/flag or (since #903) user-label row whose folder no longer exists. Such a
  row is never skipped silently;
- tags (local-only on Gmail and Outlook, ADR-IOS-036) and draft saves (re-queued above): nothing.
Nothing is re-sent or replayed, and no row's meaning decides anything about any operation: the
boundary is still not an exit. Accounts with no change bookmark (IMAP today) are unchanged: the
boundary's full sync lists every folder. Once IMAP folders are tracked, the IMAP reader must honour
the re-read list for these ids too. *Amended 2026-11-16 (#751, IMAP folders tracked):* an account whose
ids are mailbox-local and that holds a bookmark on any folder takes the exit rule for a retired move
(source and destination drop their bookmark, one self-heal owed, no ids listed), a draft delete or an
undecodable row (its folder, or every folder of the account when it does not resolve); its read/flag
and user-label rows list their ids on their own folder, also when a retired move drops it (the
listing never replaces a held row's user labels; the folder's baseline read answers the list) (ADR-IOS-111, amendment 2026-11-14, #876).

**Not corrected, accepted (2026-11-14): a retired user-label change or replied/forwarded mark in a
tracked folder.** Neither repair path writes these into a stored row: the change apply's merge
(`mergeChangeRecord`) writes the read state, the flag, the server tag, identity and references only,
and the catch-up (`applyCatchUpTransaction`) writes the read state and the flag, removes and loads.
So these kinds are not listed (a re-read would settle the id with nothing corrected) and no catch-up
is armed for them. Example: on Gmail the user adds label L and updates before the action reaches the
server; the phone keeps showing L, which the server never got, until the message is next stored again
(a move, a Settings reset). Recoverable by one ordinary gesture (remove or re-add the label). The
merge's missing label and answered-state reconciliation for stored rows is an older, separate gap in
the change apply and is tracked on its own; once it is fixed, these kinds belong on the list.

**Corrected (2026-11-14, #903): a retired user-label change in a tracked folder.** Since #882 the
merge replaces a stored row's user labels from a record that knows them (Gmail label, Outlook
category), so `addUserLabel`/`removeUserLabel` joined `SyncEngine.retiredActionKindsReadAgain`: their
ids go on the re-read list of the folder they were queued on, and the next read shows the server's
label set again (the retired op no longer shields it). The paragraph above stays as history for the
label kinds; replied/forwarded marks are still not corrected (the merge does not write them).
Tests: `ReleaseBoundaryRecheckTests` (Gmail and Outlook, add and remove).

**Corrected (2026-11-14, master-agent ruling: a stuck state, not an edge): an older message in a
folder outside the synced set.** Such a folder is now listed and its list is read (above). *Superseded
same day:* "Not corrected, accepted (2026-11-14): an older message in a folder outside the syncable
set. A retired move into (or out of) a custom, non-favourite folder lists nothing there, because no
per-folder reader reads that folder's list. Opening the folder lists it, but its stale sweep is
date-bounded on Gmail and Outlook, so the optimistic row of a message older than that window stays in
that folder until the user acts on it; the synced side of the move is still read again. This predates
#876 (the boundary's full sync never listed such a folder) and is recoverable by one ordinary gesture
(move the message again)."

**Address.** The ids listed are the queue's own: the provider's id for the message in the folder the
action was queued on. A move that drained re-addresses the queued rows after it to the destination id
the server named (`MessageHeaderRekey.readdressQueuedOperations`), so a queued row names the message
as the server knows it at that point of the queue; an unsent Outlook move still names the original id,
which is where the server still has the message. The local row's own address after an optimistic move
(the source id under the destination folder, on Outlook) is never used as a key. A re-read answers
for exactly that id: found in the folder (a record), elsewhere or gone (a removal there). Folders are
resolved by the path the row recorded, never by role (ADR-IOS-059). Undo is a reverse move, so a
retired undo is an ordinary retired move.

**Accepted window (Outlook, the IOS-GRAPH-005 crash window, #116/#117):** an attempted Outlook move
whose 2xx the server applied but whose retirement the app never committed (process death inside that
one write) still names the dead source id, because Graph ids change on move. Its re-read answers 404
in both folders, so the optimistic destination row is removed, and the message under its new id comes
back only through the destination folder's change read (the delta reports it as moved in). Recoverable
by sync, but for that row the listed id is not one the server can answer for as the message.

User-visible: after the update, an email whose queued action was cleared shows its server state again
(for example, an email archived just before the update is back in the inbox). Tests:
`ReleaseBoundaryRecheckTests` (Gmail archive and mark-read, Outlook move, kinds left out, draft delete,
every kind read again, no-bookmark account untouched, unreadable kind or ids, an unknown kind alone,
a folder that is gone, a draft delete whose Drafts folder is gone, every named folder listed, no
duplicate ids, overflow, rollback on a throw; end to end with OLDER messages: an Outlook Inbox whose
read is a baseline, the baseline gate holding for an unlisted id, Gmail custom labels (move, read,
flag), a Gmail synced but untracked Inbox, an Outlook custom non-favourite folder (read change, move
back), an Outlook untracked synced source; Outlook read change; more ids than the list limit in a
custom folder all kept and read across passes, the apply's overflow cut only where the catch-up
checks, an unreadable role keeping every id, a favourite custom folder cut with its catch-up
armed, the custom folder's read changing no coverage, an Inbox-only pass leaving its list, a failing
custom read holding back nothing else, the custom read within the request allowance);
`ChangeSeamFenceTests.retiredActionRecheckIsProviderBlind`.
