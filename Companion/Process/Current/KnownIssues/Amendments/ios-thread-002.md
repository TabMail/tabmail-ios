# IOS-THREAD-002

- Register classification: `accepted`
- New post-freeze record (2026-11-26) added through the amendment surface; no row in the
  hash-pinned archive and therefore no original row hash.

## Status

📋 **ACCEPTED LIMITATION (2026-11-26, #1555).** A forward now starts its own thread on the device
(ADR-IOS-043 amendment, #1555), but which emails count as forwards, and the order emails are stored
in, are best effort. In the cases below a forward still shows with the email it forwards (as before
#1555), an email shows apart from the thread it belongs to, or a row moves once when it is stored.
Display and grouping only.

## Subsystem and search terms

Threading; forward split; `ThreadUtils.assignComputedThreadId`; `ThreadUtils.hasForwardPrefix`;
`sentAsForward`; `OutboxMessage.isForward`; `ThreadUtils.findAdoptableThreadId`; nearest ancestor;
reverse probe; lateral probe; `messageReference`; `ThreadDetection.excludeAcrossForwards`;
`computedThreadId`; `ThreadGroupBuilder`; staged row; `InboxListComposer.adoptThreadId`;
notification tap; `seedFromStagedPublish`; Outlook `conversationId`; `GraphParse.parseMessage`;
`Fwd:`; `Fw:`; localized forward prefix; rewritten subject; first sync; older mail; UIDVALIDITY
reset; account reset; another device; #1555; IOS-THREAD-001; IOS-OUTBOX-008.

## The behaviour

An email's thread (`computedThreadId`) is set once, when it is stored, and is not set again. A forward
is an email TabMail sent as a forward (the send records it when it stores its Sent row), or a stored
email whose subject starts with `Fwd:` or `Fw:` (any case, after leading whitespace). The forward looks
up only its own Message-ID; every other email joins the nearest stored email its headers name, and,
failing that, a stored email that names it (the reverse and lateral probes, unchanged).

1. **A forward from someone else, or from another app, whose subject does not start with `Fwd:` or
   `Fw:`** (the sender rewrote it, or wrote a localized prefix such as `WG:`, `TR:`, `RV:` or `VS:`)
   is read as an ordinary email and joins its source's thread, as before #1555.
2. **A reply whose subject starts with `Fwd:` or `Fw:` with no `Re:` before it** is read as a forward
   and starts a thread of its own, apart from the thread it replies to.
3. **Order of storing.** An email stored after a newer email of its own chain (older mail loaded after
   newer mail, as on an account's first sync or when the user scrolls to older mail) can be put in
   one thread with a forward through the reverse and lateral probes: a forward's source stored after
   the forward, with no stored ancestor or copy of its own, joins the forward's thread through the
   forward's References (or In-Reply-To, which Thunderbird writes on a forward); a forward stored
   after a reply to it joins that reply's thread, which is the source's when the reply was stored
   before the forward. Either way the two show together, as before #1555.
4. **Outlook accounts: a forward stands alone.** The Microsoft Graph sync reads no In-Reply-To or
   References (`GraphParse.parseMessage`), so an Outlook email joins a thread only by another copy of
   itself or by Outlook's conversation id, which a forward never takes. A forward on an Outlook
   account therefore never groups with its replies, received or sent: they group by Outlook's
   conversation id, apart from the forward (before #1555 the forward took that id and grouped with
   them).
5. **A forward sent from TabMail whose subject the user rewrote** is split only when TabMail's send
   stores its Sent row, since only the send knows it is a forward. When the row is stored by the sync
   instead, it joins its source through its References: the sync stored the Sent copy before the
   send's row (the send then keeps the sync's row), the row is stored again after a UIDVALIDITY or
   account reset, or the forward was sent by TabMail on another device. And even when it is split,
   the conversation view's related emails (`ThreadDetection.findRelatedMessages`) read forwards by
   subject only, so for it they still reach across: the source's conversation view lists the forward
   and its replies, and the forward's lists the source's thread.
6. **An email opened from its notification before it is stored** (a staged row) has no thread yet,
   so its conversation view leaves nothing out across forwards, as before #1555, until it is opened
   again after the merge.
7. **A staged reply to a forward can move once.** The inbox's instant render of a staged row (one
   the notification delivered, before the merge stores it) puts it with the first on-screen email
   that shares its provider thread id or a References id, not the nearest one. On Gmail a reply to a
   forward the user sent carries the source's conversation id, so it shows with the source until
   the merge stores it with the forward, and then moves (ADR-IOS-055: the reconcile corrects a staged
   guess). A staged reply to a staged forward does the same: a staged forward adopts no thread.
8. **Forwards stored before #1555** keep the thread they were given, their source's (no migration).

## When it happens

Cases 1 and 2 depend on what other people's mail apps write. Case 3 needs the older email stored
after the newer one. Case 4 is every forward on an Outlook account. Case 5 needs a rewritten subject
on a forward. Cases 6 and 7 need a notification that arrives before the merge. Case 8 is every
forward already on the device.

## Recoverability

Display and grouping only. The thread decides what the inbox groups and what a gesture on a thread
acts on, which is the group the user sees; no email is lost, mis-addressed or hidden, and every one
still opens, replies and forwards on its own. Cases 6 and 7 correct themselves when the merge stores
the email (case 6 when the view is opened again). The others are not repaired later: an email keeps
the thread it was stored with until it is stored again (a reset of the account or its folder). As
with IOS-THREAD-001, a repair of stored rows would need a new migration and a walk of every stored
email, which this display limit does not warrant.
