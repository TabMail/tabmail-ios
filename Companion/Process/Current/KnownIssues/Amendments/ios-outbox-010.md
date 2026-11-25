# IOS-OUTBOX-010

- Register classification: `accepted`
- New post-freeze record (2026-11-25) added through the amendment surface; no row in the
  hash-pinned archive and therefore no original row hash.

## Status

📋 **ACCEPTED LIMITATION (2026-11-25, #1490).** While a reply is held, a change pass can bring the
server's Reply tag back onto the original until the reply goes out. Recoverable by itself; registered
rather than mechanised.

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
during the hold; `setTag(none)`; undo window; held send; `IOS-OUTBOX-003`; #1490.
