# MIS-IOS-033 — assumed a row written to the database is on screen in the chat, and ended the Sent bubble before the chat showed the email

**Recurrences:** 1
**Status:** Active
**First recorded:** 2026-11-07

## The tell

> *"The copy is in the database, so it is in the chat."* A fix ends or hides a placeholder (a
> Sending/Sent bubble, a spinner, an optimistic row) at the moment the real row is WRITTEN, and the
> argument for "no gap" is that the write happened, not that the view reloaded.

## What actually happened

A review found that a Sent bubble could outlive its email when the provider files the sent email
under a Message-ID of its own (Outlook keeps none of ours), because the bubble ends only when the
chat shows an email carrying our Message-ID. The first fix ended the bubble when the outbox row was
filed, since the optimistic Sent copy is inserted before the row is deleted.

The chat thread does not observe the database. It reloads its emails on `.nseMergeDidCommit`, which
the Sent folder sync posts after it commits, some time after filing. Ending the bubble at filing
left a window where neither the bubble nor the email was on screen.
`ChatSendingBubbleTests.sendingBubbleHandsOver` and `ChatThreadViewLifecycleTests.sentReplyTakesTheTurn`
caught it. The kept fix ends the bubble when no email of the account carries its Message-ID any
more, which is what the Sent sync's replacement produces, and otherwise keeps the hand-over to the
chat's own member change.

## The rule

Before ending a placeholder at a database write, find what makes the VIEW reload (an observation,
a notification, a member change) and end it there, or prove the view observes the same write. The
hand-over is "the view shows the real thing", never "the real thing exists". A hand-over test that
checks only the store passes through the gap; assert what the view's own reload produces.
