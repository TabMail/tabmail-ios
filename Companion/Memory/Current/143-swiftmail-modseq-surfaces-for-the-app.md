# What SwiftMail offers the app for CONDSTORE (MODSEQ), and what it does not

**Learned 2026-11-10 while building the catch-up of older mail (ADR-IOS-107).** Read this before
designing anything that compares, stores or searches by an IMAP mod-sequence.

## The facts, against the pinned fork (f4191156)

- **STATUS is the only `Int` modseq.** `MailboxStatus.highestModSequence: Int?` is set only when the
  server advertises `CONDSTORE`. SwiftMail adds the `HIGHESTMODSEQ` STATUS attribute only then
  (`IMAPServer+Mailbox`, `IMAPNamedConnection+Mailbox`). `IMAPProvider.fetchFolders` copies it to
  `FolderInfo.highestModSeq`. The full sync's folder upsert and delta sync write it to
  `Folder.lastKnownHighestModSeq`.
- **The SELECT modseq is a NIOIMAPCore type.** `Mailbox.Selection.highestModSequence` is
  `ModificationSequenceValue?` from NIOIMAPCore. The app imports only `SwiftMail`, which does not
  re-export NIOIMAPCore (no `@_exported`), and `project.yml` links only the SwiftMail product.
  Reading it as a number means importing a transitive module, so don't.
- **`SearchCriteria.modSeq` takes NIOIMAPCore's `SearchModificationSequence`.** `UID SEARCH MODSEQ n`
  therefore has the same import problem.
- **There is no `CHANGEDSINCE` FETCH modifier** in the fork.
- **`.uidFlagsOnly`** is `[.flags]`, about 50 bytes per message, with a suggested chunk of 5000.
  `fetchMessageInfos(uidRange: ClosedRange<UID>, options:)` issues ONE
  `UID FETCH lo:hi (UID FLAGS)`.

## What the catch-up did with this

The catch-up's stamps are STATUS values taken earlier in the same pass. The per-range SELECT
supplies only the epoch (UIDVALIDITY).

## Test harness

`FakeIMAPServer` answers `HIGHESTMODSEQ` in STATUS only when constructed with `CONDSTORE` among
its capabilities (`highestModSeqByMailbox`). The counter rises whenever the mailbox's UIDs or flags
changed since the previous STATUS, so every mutation path raises it without a per-site hook.

The fake's `UID SEARCH` still answers with every UID in the mailbox unless a `Message-ID` header
criterion is present. The `UID SEARCH UID <set>` absence proof only computes
`candidates − found`, so a superset answer is still correct for it.
