# IOS-OUTBOX-011

- Register classification: `accepted`
- New post-freeze record (2026-11-25) added through the amendment surface; no row in the
  hash-pinned archive and therefore no original row hash.

## Status

📋 **ACCEPTED LIMITATION (2026-11-25, #1490).** With two replies to one original waiting to go out,
undoing the first leaves the original with no reply arrow until the second is sent. Recoverable by
itself; registered rather than mechanised.

## The behaviour

Each queued reply records what its Send changed on the original (`outboxMessage.originalChangesAtQueue`,
`IOS-OUTBOX-003` as amended 2026-11-25), and an unsent removal (`cancelHeldOutboxRow`: Undo, Undo to
Drafts, the Outbox discard) undoes exactly that record. The first reply marks the original replied and
clears its Reply tag; the second finds it already marked and records nothing. Undoing the first
therefore takes the mark and the tag clear back while the second is still waiting: the original shows
its Reply tag and no reply arrow.

The removal deliberately reads no other outbox row: a check for "another live reply to this original"
would put a scan in the synchronous Undo write, which runs inside the hold's deadline
(`discardOutboxMessageConfirmed`, IOS-OUTBOX-006).

## Other sends to the same original (2026-11-25, review of #1490)

The other order is not a gap. A send of the same kind that went out (the user replies again after a
reply failed, and discards the failed one afterwards) stands for the mark: its completion
(`deleteCompletedSendAtomic`) takes off every other same-kind send's record for that original what it
applied itself: a reply's `clearedReplyTag` always, and `setMark` when it admits the original. So the
discard, or the Undo of a send still held, leaves the original as the completion left it: replied, its
tag cleared.

A reply the user sends from another client while TabMail's reply waits is not one either. The revert of
a reply that set the mark asks whether a reply to the original is stored in a Sent folder of the account
(`ReplyParentResolver.hasStoredReply`) and keeps the mark and the cleared tag when it is. If the
removal comes before that copy syncs, `ReplyParentResolver` marks the original and clears the tag when
it does. Graph stores no In-Reply-To, so on Outlook neither step finds the reply; there a reply from
another client reaches the original only through the server's last-verb properties (memory 151).

**Accepted, as in 1.11.6:** a forward sent from another client while TabMail's forward waits leaves the
original with no forwarded mark when TabMail's is removed unsent. No other client's forward is visible
on Gmail, which 1.11.6 showed the same way; on IMAP the server's `$Forwarded`, when the other client
set it, comes back at the next full pass (`SyncEngineFullSync` merges it).

## When it happens

Rare: two replies (separate drafts) to the same original queued inside one undo window, or while
offline, and the first one undone or discarded.

## Recoverability

Recovers by itself: when the second reply goes out, its completion marks the original replied, queues
the server's mark and clears the Reply tag (`deleteCompletedSendAtomic`). Undoing the second instead
leaves the original exactly as it was before both. Nothing is lost.

## Subsystem and search terms

Outbox; reply; two pending replies; second reply; undo; Undo to Drafts; Outbox discard;
`cancelHeldOutboxRow`; `revertQueuedOriginalChanges`; `markOriginalAtQueue`; `originalChangesAtQueue`;
`setMark`; reply arrow missing; `isReplied`; `deleteCompletedSendAtomic`; `IOS-OUTBOX-003`;
IOS-OUTBOX-006; failed send discarded after a re-send; reply from another client; Gmail web reply; `ReplyParentResolver.hasStoredReply`; `messageHeader_inReplyTo`; forward from another client; `$Forwarded`; #1490.
