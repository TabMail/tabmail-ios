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
IOS-OUTBOX-006; #1490.
