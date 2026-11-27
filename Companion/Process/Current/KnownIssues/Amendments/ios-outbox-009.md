# IOS-OUTBOX-009

- Register classification: `accepted`
- New post-freeze record (2026-11-25) added through the amendment surface; no row in the
  hash-pinned archive and therefore no original row hash.

## Status

📋 **ACCEPTED LIMITATION (2026-11-25, #1492).** Not measured: what Apple Mail and Outlook write on a
forward (whether they set `In-Reply-To`, and which subject prefix they use in each language). The
forward detection of #1492 was built and tested against Thunderbird's headers only.

## Subsystem and search terms

Sync; Sent folder; reply detection; forward detection; `ReplyParentResolver.markParentsReplied`;
`ThreadUtils.hasForwardPrefix`; `ThreadUtils.forwardPrefixes`; Apple Mail; Outlook; Outlook for Mac;
Outlook on the web; `In-Reply-To` on a forward; forward prefix; `FW:`; localized forward prefix;
unmeasured; #1492; IOS-OUTBOX-008.

## The behaviour

Sync reads a Sent copy that names a stored message in `In-Reply-To` as a reply, unless its subject
starts with `Fwd:` or `Fw:`, which makes it a forward (#1492, IOS-OUTBOX-008). What a forward from
Apple Mail or Outlook does therefore depends on headers nobody has measured:

- **No `In-Reply-To` on the forward:** the copy marks nothing; the original shows neither mark from it.
- **`In-Reply-To`, subject `Fwd:` or `FW:`:** the original is marked forwarded, as intended.
- **`In-Reply-To`, another prefix** (a localized one, or the user's edit): the original is marked
  replied, IOS-OUTBOX-008.

An Outlook (Microsoft Graph) account's sync reads no `In-Reply-To` at all (`GraphParse.parseMessage`
sets it nil), so on that account no Sent copy marks anything, whichever app sent it.
*(Amended 2026-11-27, #1559: an Outlook account's sync now reads `In-Reply-To` (extended property
`String 0x1042`), so its Sent copies follow the three cases above as on Gmail and IMAP, and an
Outlook account is no longer immune to the third.)*

## When it happens

Whenever a user forwards from Apple Mail or Outlook with an IMAP or Gmail account TabMail also syncs
(since #1559, 2026-11-27, with an Outlook account too).
Which of the three cases it is, is what a measurement would show; only the third gives a wrong mark.

## Recoverability

As IOS-OUTBOX-008 for the third case: tagging the message Reply again restores the tag; the replied
mark stays on the right message. The first case leaves the original unmarked, which is how it was
before #1492. A measurement that finds a localized forward prefix with `In-Reply-To` would add that
prefix to `ThreadUtils.forwardPrefixes` (one list, read by both the strip and the forward check).
