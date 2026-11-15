# IOS-GRAPH-006

- Register classification: `accepted`
- New post-freeze record (2026-11-15) added through the amendment surface; no row in the
  hash-pinned archive and therefore no original row hash.

## Status

📋 **ACCEPTED LIMITATION (2026-11-15, #915).** Ruled by the coordinator: ADR-IOS-068 D4 stays, so
the mark is never re-targeted by Message-ID.

## Subsystem and search terms

Outbox; reply; reply-all; forward; Outlook; Microsoft Graph; `Integer 0x1081`
(PidTagLastVerbExecuted); `SystemTime 0x1082`; `Integer 0x1080` (PidTagIconIndex); `ExchangeProvider.performMessageAction`;
`patchEachMessage`; `.markReplied`; `.markForwarded`; `deleteCompletedSendAtomic`;
`readdressQueuedOperations`; moved original; 404; authoritative no-op; `internetMessageId`; D4

## The behaviour

After a reply, reply-all or forward is sent, `deleteCompletedSendAtomic` queues a durable
`.markReplied` / `.markForwarded` op naming the original's Graph id, and the Exchange provider
PATCHes the original's last verb (102 / 103 / 104) and its time. A Graph id changes when the
message moves.

- **A move made in TabMail is covered.** `MessageHeaderRekey.finishMove` re-keys the header and
  `readdressQueuedOperations` rewrites every queued op naming the old id, so the mark follows the
  message, whichever of the move and the mark drains first.
- **A move made elsewhere is not.** If Outlook on the web, another client or a server rule moves
  (or deletes) the original after the mark was queued and before it drains, the PATCH names a dead
  id, Graph answers 404, and `patchEachMessage` takes the existing authoritative no-op exit. The
  Outlook mark is lost for that message. The local `isReplied` / `isForwarded` stays set, so
  TabMail itself still shows the reply.
- Also covered by the same exit: a Graph move whose response carried no new id (the header is
  repaired by sync; the queued mark is not).

## Why accepted, not fixed

The only way to find the moved message is a search by `internetMessageId`, which ADR-IOS-068 D4
forbids as a mutation target (alias copies share one Message-ID). The loss is cosmetic (the arrow
and "You replied on ..." in Outlook clients), the user's mail is sent, nothing wrong is written to
another message, and no intention other than the mark is affected. Window: from send completion to
the mark's drain, normally seconds while online.

## Recoverability

None automatic for the Outlook arrow; replying again from Outlook sets it. Graph immutable ids
(#117) would close the window structurally.
