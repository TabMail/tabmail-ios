# IOS-OUTBOX-008

- Register classification: `accepted`
- New post-freeze record (2026-11-25) added through the amendment surface; no row in the
  hash-pinned archive and therefore no original row hash.

## Status

📋 **ACCEPTED LIMITATION (2026-11-25, #1492).** A forward sent from another mail app that names its
original in `In-Reply-To`, and whose subject does not start with `Fwd:` or `Fw:`, marks the original
replied. The subject is the only signal sync reads; the residual is registered, not mechanised.

## Subsystem and search terms

Sync; Sent folder; reply detection; forward detection; `ReplyParentResolver.markParentsReplied`;
`markInsertedParentsOfStoredReplies`; `SentCopy`; `ThreadUtils.hasForwardPrefix`;
`ThreadUtils.forwardPrefixes`; `In-Reply-To` on a forward; Thunderbird; subject edited; forward prefix
removed; localized forward prefix; `WG:`; `TR:`; `RV:`; `VS:`; `isReplied`; `isForwarded`; Reply tag
cleared; `setTag`; #1492; #1483 (TabMail's own forwards carry no `In-Reply-To`); IOS-OUTBOX-003;
IOS-OUTBOX-009.

## The behaviour

When sync stores a message in a Sent folder whose `In-Reply-To` names a stored message, the resolver
reads it as the user's answer from another app: the named message is marked replied, its Reply tag is
cleared, and the clear is queued to the server (`setTag`). The same marking runs from the other side
when the original is stored after the copy (`markInsertedParentsOfStoredReplies`).

Some apps set `In-Reply-To` on a forward as well. Thunderbird takes it from the last `References` id for
every compose kind (comm-central `MimeMessage.sys.mjs`, `_gatherMimeHeaders`). Since #1492 the resolver
reads a copy whose subject starts with a forward prefix (`Fwd:` or `Fw:`, any case, after leading
whitespace; `ThreadUtils.hasForwardPrefix`) as a forward: the original is marked forwarded, never
replied, and keeps its Reply tag.

A forward is still read as a reply when its copy names the original in `In-Reply-To` and its subject
does not start with `Fwd:` or `Fw:`:

1. **The user edited the subject** and removed the prefix before sending.
2. **The app writes another forward prefix**: a localized one (`WG:` German, `TR:` French, `RV:`
   Spanish, and others), or `VS:`, which Norwegian and Danish use for a forward and Finnish uses for a
   reply. The forward list holds `Fwd:` and `Fw:` only; the subject strip
   (`ThreadUtils.normalizeSubject`) removes `Vs:` as before.

The original then shows the replied mark, and its Reply tag is cleared on every device. Sync merges the
replied mark set-only (a later pass never clears it), so the mark stays.

Related cases, same cause (the subject is the only signal):

- **The converse:** a reply whose subject starts with `Fwd:` or `Fw:` (the user edited it, or an app
  wrote no `Re:`) marks its original forwarded and leaves its Reply tag. Clearing the tag is one gesture.
  The unsent-removal revert (#1490) reads the same rule (`ReplyParentResolver.SentCopy.isForward`): such
  a copy in Sent does not count as a stored reply, so removing TabMail's reply unsent takes its marks back.
- **Originals marked before #1492:** an original a forward copy already marked replied keeps that mark
  and its cleared tag; no data is rewritten for it (a harmless leftover). A later listing of the copy
  adds the forwarded mark.
- **The v53 historic backfill** (`ReplyParentResolver.runHistoricBackfill`, a released migration that
  cannot change) marks replied every original a stored Sent message names in `In-Reply-To`, forwards
  included. It ran once, on databases upgrading through v53.

## When it happens

Rare. It needs another app that sets `In-Reply-To` on a forward (Thunderbird does; Apple Mail and
Outlook are not measured, IOS-OUTBOX-009) and then either a hand-edited subject or a forward prefix
outside the list. TabMail's own forwards carry no `In-Reply-To` (#1483), so they are not affected.

## Recoverability

The Reply tag comes back with one ordinary gesture: tagging the message Reply again. The replied mark
stays; it is a display mark on the right message (no wrong-message mutation, nothing deleted or sent),
and the forward itself is in the Sent folder as sent.
