# IOS-OUTBOX-012

- Register classification: `accepted`
- New post-freeze record (2026-11-25) added through the amendment surface; no row in the
  hash-pinned archive and therefore no original row hash.

## Status

📋 **ACCEPTED LIMITATION (2026-11-25, #1479).** An original moved in another client while its reply or
forward is held is not found by the send. ADR-IOS-068 D4 stays: the Message-ID never selects the
original. Registered beside `IOS-GRAPH-006`, the same rule for the same mark.

## The behaviour

A queued reply or forward names its original by header id (`outboxMessage.originalMessageHeaderId`).
The completion (`deleteCompletedSendAtomic`) and an unsent removal (`cancelHeldOutboxRow` →
`revertQueuedOriginalChanges`) read the original by that key.

- **A move made in TabMail is covered (#1479).** When the move lands, `MessageHeaderRekey.finishMove`
  re-keys the row to the address the server proved and carries the queued send's pointer with it, in
  the same transaction, as it re-addresses queued operations. The completion marks the moved original and queues the server's mark at its
  new address; an Undo takes Send's marks back from it.
- **A move made elsewhere is not.** Sync never carries the pointer: its own re-key (the UID remap in
  `SyncEngineFullSync`) rests on Message-ID evidence. If another client, another device or a server
  rule moves the original while the send is held, sync removes the old row and stores the moved
  message as a new row, and only its Message-ID ties that row to the queued send. So the
  completion writes no mark and queues no server mark, and an unsent removal changes nothing. Send's
  marks were on the removed row; the new row holds the server's state, and nothing on it needs taking
  back.
- **A move that lands on a row sync already stored** (sync read the destination between the server's
  move and its retirement): the re-key's collision arm drops the moved row, with Send's marks, and
  keeps the stored one. That row is not the row Send marked, and this move did not prove its numbering,
  so the pointer is not carried and the send finds no original, as above.

What the user then sees on the moved message:
- **A reply on Gmail or IMAP:** once the Sent copy syncs, `ReplyParentResolver` marks it replied on this
  device and clears its Reply tag, as it does for any Sent message naming it in In-Reply-To. The
  server's replied mark stays unset.
- **A reply on Outlook:** no replied arrow. Its sync reads no In-Reply-To, so the Sent copy marks
  nothing.
- **A forward:** no forwarded arrow. A forward's Sent copy names no original in In-Reply-To (#1483).

## When it happens

Rare: the original must be moved outside this app inside the hold (seconds), or while an offline send
waits to go out.

## Why accepted, not fixed

The only way to find the moved message is its Message-ID. ADR-IOS-068 D4 forbids the Message-ID as a
way to choose a message to change: alias copies share one Message-ID, and finding exactly one row
proves only that one row carries it, not that it is the original. The loss is cosmetic: the mail is
sent, nothing wrong is written to another message, and no intention other than the mark is affected.

## Recoverability

None automatic for the arrow, except the reply's local arrow on Gmail and IMAP described above.
Replying again sets it.

## Tests

`SendReplyMarksTests/originalMovedElsewhereWhileTheSendIsHeld` (reply and forward; completion and
Undo: nothing is queued and the stored copy is unchanged) and
`SendReplyMarksTests/syncRekeyDoesNotCarryTheSend` (sync's own re-key leaves the send naming the old
id, and its completion queues nothing) and `SendReplyMarksTests/originalArchivedOntoAStoredCopy` (the
collision arm: the send is not carried, and the stored row is unchanged). The covered TabMail move:
`SendReplyMarksTests/originalArchivedWhileTheSendIsHeld`.

## Subsystem and search terms

Outbox; reply; forward; moved original; archived original; `originalMessageHeaderId`;
`MessageHeaderRekey.finishMove`; `readdressQueuedOperations`; re-key; UID remap; collision arm; `deleteCompletedSendAtomic`; `cancelHeldOutboxRow`;
`revertQueuedOriginalChanges`; `resolveOriginalMessage`; `ReplyParentResolver`; Message-ID; RFC 822;
ADR-IOS-068 D4; `IOS-GRAPH-006`; `IOS-OUTBOX-003`; #1479.
