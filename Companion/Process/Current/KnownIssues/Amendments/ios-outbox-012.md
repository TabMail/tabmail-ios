# IOS-OUTBOX-012

- Register classification: `accepted`
- New post-freeze record (2026-11-25) added through the amendment surface; no row in the
  hash-pinned archive and therefore no original row hash.

## Status

📋 **ACCEPTED LIMITATION (2026-11-25, #1479).** An original moved in another client while its reply or
forward is held is not found by the send. Neither is one moved in TabMail whose move was not re-keyed
when it landed (a Gmail move; an IMAP or Graph move without proven destination evidence), once sync
re-keys it. ADR-IOS-068 D4 stays: the Message-ID never selects the original. Registered beside
`IOS-GRAPH-006`, the same rule for the same mark.

⚠️ **Corrected 2026-11-25 (review of #1479):** this record first said every move made in TabMail is
covered. Only a move the drain re-keys when it lands is; see the second bullet below.

📌 **Narrowed 2026-11-25 (#1500, same release): a Gmail move is covered.** The listing of the
destination re-keys a Gmail row on Gmail's own id (`SyncEngine.canonicalizeLocalRows`), a re-key the
provider's id proves, and that re-key now carries the queued send's pointer in the same write. So a
Gmail original archived while its reply or forward waits is found by the completion and by an unsent
removal, before and after that re-key. What stays accepted (2026-11-25): an IMAP or Graph move without
proven destination evidence, once sync re-keys the row on Message-ID evidence (the UID remap, the body
backfill's re-key), and a move made in another client. The status paragraph above, written for #1479,
counted the Gmail move among the uncovered ones; the second bullet below now separates it.

## The behaviour

A queued reply or forward names its original by header id (`outboxMessage.originalMessageHeaderId`).
The completion (`deleteCompletedSendAtomic`) and an unsent removal (`cancelHeldOutboxRow` →
`revertQueuedOriginalChanges`) read the original by that key.

- **A move made in TabMail and re-keyed when it lands is covered (#1479).** When the move lands with
  the address the server proved (IMAP's `COPYUID`, the Graph move response),
  `MessageHeaderRekey.finishMove` re-keys the row and carries the queued send's pointer with it, in
  the same transaction, as it re-addresses queued operations. The completion marks the moved original and queues the server's mark at its
  new address; an Undo takes Send's marks back from it. Only a send already queued at the landing is
  carried: a reply or forward composed on the message before the move landed and sent after it names
  the old id, so Send and the completion find no original and it gets no arrow (rare: the landing
  takes seconds online; nothing else changes).
- **A Gmail move is covered through sync's re-key (#1500).** A Gmail move does not change the
  message's address, so `finishMove` re-keys nothing; the row keeps its Inbox-shaped key until a
  listing of the destination runs `canonicalizeLocalRows` (`SyncEngineFullSync`), which re-keys it on
  the provider's own id and, in the same write, carries the queued send's pointer to the new key. The
  provider's id proves that re-key, so ADR-IOS-068 D4 is not engaged. The re-key is skipped when
  another row already holds the destination key; the row then keeps its key, and so does the pointer.
- **Any other move made in TabMail that is not re-keyed when it lands is covered only until sync
  re-keys the row.** An IMAP move with no admissible `COPYUID` or with a positive epoch disagreement,
  and a Graph move whose response withheld the new id, leave the row at its source key until the
  destination listing's UID remap re-keys it, on Message-ID evidence; so can the body backfill's
  re-key (`BackfillBodyQueue.rekeyRemappedHeader`), when the row's body fetch keeps missing, to the UID
  its Message-ID now has. These re-keys go through `MessageHeaderRekey.apply`, which carries no
  pointer. (Until #1500 this bullet also held the Gmail move, through `canonicalizeLocalRows`.)
  Until then the send finds its original; from then on:
  - the completion finds nothing: no server mark and no tag clear. On Gmail nothing is lost on the
    server (Gmail keeps no replied flag), and the Sent copy marks the original on this device
    (`ReplyParentResolver`);
  - an unsent removal (Undo, Undo to Drafts, the Outbox discard) finds nothing either, so Send's marks
    stay on the re-keyed row. Sync never clears a replied or forwarded mark (`SyncEngineFullSync` keeps
    the stored mark when the server reports none), so the message keeps a reply or forward arrow for a
    send that never went out. The Gmail case is fixed (above); these IMAP and Graph cases are
    accepted (2026-11-25) and stay open as #1500.
- **A move made elsewhere is not covered.** Sync never carries the pointer (above). If another client, another device or a server
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
waits to go out. Or it is moved in TabMail without a re-key at landing (an IMAP move without an
admissible `COPYUID`, a Graph move whose response withheld the new id; no longer a Gmail move, #1500)
while the send waits or has failed, long enough for a listing of the destination, and the send is then
removed unsent (the arrow that stays) or goes out (no server mark).

## Why accepted, not fixed

The only way to find the moved message is its Message-ID. ADR-IOS-068 D4 forbids the Message-ID as a
way to choose a message to change: alias copies share one Message-ID, and finding exactly one row
proves only that one row carries it, not that it is the original. The loss is cosmetic: the mail is
sent, nothing wrong is written to another message, and no intention other than the mark is affected.

## Recoverability

None automatic for the arrow, except the reply's local arrow on Gmail and IMAP described above.
Replying again sets it. An arrow an unsent removal left after sync's re-key does not clear by itself,
and no gesture clears it.

## Tests

`SendReplyMarksTests/originalMovedElsewhereWhileTheSendIsHeld` (reply and forward; completion and
Undo: nothing is queued and the stored copy is unchanged) and
`SendReplyMarksTests/syncRekeyDoesNotCarryTheSend` (sync's own re-key leaves the send naming the old
id; its completion queues nothing, and its Undo leaves Send's marks on the re-keyed row) and `SendReplyMarksTests/originalArchivedOntoAStoredCopy` (the
collision arm: the send is not carried, and the stored row is unchanged). The covered TabMail move:
`SendReplyMarksTests/originalArchivedWhileTheSendIsHeld`, `landedMoveCarriesEverySendToTheOriginal`
(every send to the moved original, whatever its state, and no send to another message) and
`graphMoveCarriesTheSendFromTheRowsKey` (an account-scoped landing follows the row's own key). The
covered Gmail move (#1500): `SendReplyMarksTests/gmailAllMailRekeyCarriesTheSend` (reply and forward;
completion, Undo and the discard after a failure, after the All Mail listing's re-key; a send to
another message keeps its original) and `gmailSkippedRekeyKeepsTheSend` (the skipped re-key leaves the
send naming the row that kept its key, and the row holding the destination key is unchanged).

## Subsystem and search terms

Outbox; reply; forward; moved original; archived original; `originalMessageHeaderId`;
`MessageHeaderRekey.finishMove`; `readdressQueuedOperations`; re-key; UID remap; `BackfillBodyQueue.rekeyRemappedHeader`; compose sent after the move landed; collision arm;
`canonicalizeLocalRows`; `MessageHeaderRekey.apply`; Gmail archive; All Mail; All Mail listing re-key
carries the send; skipped re-key; no `COPYUID`; reply arrow that stays; #1500; `deleteCompletedSendAtomic`; `cancelHeldOutboxRow`;
`revertQueuedOriginalChanges`; `resolveOriginalMessage`; `ReplyParentResolver`; Message-ID; RFC 822;
ADR-IOS-068 D4; `IOS-GRAPH-006`; `IOS-OUTBOX-003`; #1479.
