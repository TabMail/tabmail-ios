# IOS-OUTBOX-010

- Register classification: `accepted`
- New post-freeze record (2026-11-25) added through the amendment surface; no row in the
  hash-pinned archive and therefore no original row hash.

## Status

📋 **ACCEPTED LIMITATION (2026-11-25, #1490).** While a reply is held, a change pass can bring the
server's Reply tag back onto the original until the reply goes out. Recoverable by itself; registered
rather than mechanised.

⚠️ **Corrected 2026-11-25 (review of #1490): reachable only where a provider reports a tag, today the
demo account.** No real provider reports an action tag: `IMAPProvider.mapMessageInfo` sets none, and the
Gmail and Exchange parses pass `actionTag: nil`. `SyncEngineChangesApply` writes a tag only when the
change record carries one (`record.serverTag`), so the write-back below happens only with
`DemoProvider`. The `.setTag` ops the completion and an Undo queue are the op every tag change queues:
action tags are local-only (ADR-IOS-036), their drain applies nothing on a server
(`AccountOperationExecutor`), and until it runs the op shields the row from the server's read and flag
state. Where the text below says the server is told or cleared, read: the op is queued.

**Also recorded here: an AI tag written during the hold.** The AI's action write (`ActiveAIQueue`)
during the hold sees Send's replied mark and assigns `none`. When the original had no Reply tag before
Send, Send recorded no tag change, so an Undo leaves that `none` on an original that is no longer
replied. Rare (the AI runs when a message arrives, before the user replies to it), and one gesture sets
the tag.

## The behaviour

Send clears a reply's `reply` action tag on this device at once (`AccountManager.markOriginalAtQueue`,
`IOS-OUTBOX-003` as amended 2026-11-25) and queues nothing to the server: the server is told when the
reply has gone out (`deleteCompletedSendAtomic` queues `setTag(none)`), so an Undo has nothing to take
back there. During the hold the server therefore still holds the Reply tag (for example written by the
Thunderbird add-on, or by this device earlier).

When a change pass reads the original during the hold (any change to it on the server, such as its read
state), `SyncEngineChangesApply` writes the server's tag over the local one, so the Reply tag shows
again. That pass's reply detection runs only when the server newly reports the message replied, so it
does not clear it. The completion then clears it (its `actionTag == .reply` branch, which queues
`setTag(none)`), and so does a full pass during the hold (`SyncEngineFullSync`'s reply detection sees
the replied mark Send wrote and queues `setTag(none)` at once).

An Undo in that state leaves the Reply tag, which is what the user had before Send, and takes back only
the replied mark. When a full pass cleared it during the hold, the tag is none with Send's stamp again,
so the Undo restores Reply and queues `setTag(reply)` after that pass's clear.

## When it happens

Rare: it needs a server-side Reply tag on the original, a change to that message on the server, and a
change pass that reads it inside the hold (seconds), or while an offline reply waits to go out.

## Recoverability

Recovers by itself: the reply's completion clears the tag locally and on the server, and a full pass
clears it before that. Nothing is lost; the user sees a Reply tag for a message they have replied to
until the send goes out.

## Subsystem and search terms

Outbox; reply; Reply tag; `actionTag`; `markOriginalAtQueue`; `revertQueuedOriginalChanges`;
`isStillQueuedTagClear`; `originalChangesAtQueue`; `clearedReplyTag`; `actionTagSetAt`;
`SyncEngineChangesApply`; `SyncEngineFullSync`; ReplyDetect; reply detection; server tag written back
during the hold; `setTag(none)`; undo window; held send; `serverTag`; `DemoProvider`; demo account; local-only tag; ADR-IOS-036; `ActiveAIQueue`; AI tag during the hold; `IOS-OUTBOX-003`; #1490.
