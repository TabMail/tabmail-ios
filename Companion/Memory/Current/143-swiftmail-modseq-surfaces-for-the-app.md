# What SwiftMail offers the app for CONDSTORE (MODSEQ), and what it does not

**Learned 2026-11-10 while building the catch-up of older mail (ADR-IOS-107).** Read this before
designing anything that compares, stores or searches by an IMAP mod-sequence.

## The facts, against the pinned fork (f4191156)

- **STATUS is the only `Int` modseq.** `MailboxStatus.highestModSequence: Int?` is set only when the
  server advertises `CONDSTORE`. SwiftMail adds the `HIGHESTMODSEQ` STATUS attribute only then
  (`IMAPServer+Mailbox`, `IMAPNamedConnection+Mailbox`). `IMAPProvider.fetchFolders` copies it to
  `FolderInfo.highestModSeq`. The full sync's folder upsert and delta sync write it to
  `Folder.lastKnownHighestModSeq`.
  *Correction (2026-11-22, tabmail-ios #755):* the last sentence is superseded and kept. Since
  ADR-IOS-111's amendment 2026-11-18 (#755), item 1, only `SyncEngine.writeListingCounters` (the window
  listing, from its own SELECT) writes `Folder.lastKnownHighestModSeq`; resets clear it through
  `SyncEngine.invalidateListingCounters`. STATUS is a trigger and writes no counter.
- **The SELECT modseq is a NIOIMAPCore type.** `Mailbox.Selection.highestModSequence` is
  `ModificationSequenceValue?` from NIOIMAPCore. The app imports only `SwiftMail`, which does not
  re-export NIOIMAPCore (no `@_exported`), and `project.yml` links only the SwiftMail product.
  Reading it as a number means importing a transitive module, so don't.
- **`SearchCriteria.modSeq` takes NIOIMAPCore's `SearchModificationSequence`.** `UID SEARCH MODSEQ n`
  therefore has the same import problem.
- **There was no `CHANGEDSINCE` FETCH modifier** in the fork (superseded: the fork now has
  `fetchFlagsChangedSince`; see the 2026-11-19 note below).
- **`.uidFlagsOnly`** is `[.flags]`, about 50 bytes per message, with a suggested chunk of 5000.
  `fetchMessageInfos(uidRange: ClosedRange<UID>, options:)` issues ONE
  `UID FETCH lo:hi (UID FLAGS)`.

## What the catch-up did with this

The catch-up's stamps are STATUS values taken earlier in the same pass. The per-range SELECT
supplies only the epoch (UIDVALIDITY).

Correction (2026-11-22, tabmail-ios #755): the first sentence above is superseded and kept. A listing's
first stamp is not a STATUS value. A tracked folder (a change bookmark of the folder's epoch, on a folder
not owed a check) stamps the bookmark's MODSEQ; every other folder stamps its stored HIGHESTMODSEQ
(`Folder.lastKnownHighestModSeq`, written only by the window listing, `SyncEngine.writeListingCounters`).
See ADR-IOS-111, amendment 2026-11-19 (#755) "CONDSTORE without QRESYNC", item 8.

## Test harness

`FakeIMAPServer` answers `HIGHESTMODSEQ` in STATUS only when constructed with `CONDSTORE` among
its capabilities (`highestModSeqByMailbox`). The counter rises whenever the mailbox's UIDs or flags
changed since the previous STATUS, so every mutation path raises it without a per-site hook.

The fake's `UID SEARCH` still answers with every UID in the mailbox unless a `Message-ID` header
criterion is present. The `UID SEARCH UID <set>` absence proof only computes
`candidates − found`, so a superset answer is still correct for it.

Amendment (2026-11-20, tabmail-ios #1076): the paragraph above is superseded. The fake's `UID SEARCH`
now answers only within every `UID <set>` key in the request, resolved against its mailbox snapshot, ANDed
with a `HEADER Message-ID` probe and the opt-in SINCE/BEFORE keys (RFC 3501 sections 6.4.4, 6.4.8). The one
seam is the opt-out `FakeIMAPServer.ignoreSearchUIDSetCriterion()`, used only by the `IMAPChangeReaderTests`
over-broad fixture that tests the client refusing a superset answer.

**2026-11-19 (#755): `CHANGEDSINCE` is now used.** On a CONDSTORE session without QRESYNC the change
reader sends `UID FETCH lo:N1-1 (UID FLAGS) (CHANGEDSINCE m)` through
`IMAPChangeCommands.flagsChangedSince` (the fork's `fetchFlagsChangedSince`), and `SELECT … (CONDSTORE)`
through `selectCondStore` when the server has no ENABLE. The fake answers CHANGEDSINCE by per-message
mod-sequence and counts it (`changedSinceFetchCount`). Design: ADR-IOS-111 amendment "CONDSTORE without QRESYNC".
