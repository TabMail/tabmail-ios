# MIS-IOS-032 — drove the real send path against a mock whose Sent folder lists nothing, and the send's own Sent sync deleted the copy under test

**Recurrences:** 1
**Status:** Active
**First recorded:** 2026-11-07

## The tell

> *"The send is awaited, so everything it does is done before my next line."* A test sends through
> `sendClaimedOutboxMessageForTesting` (or any real send path) with a `MockEmailProvider` and then
> reads the Sent folder's rows, and the mock's `fetchMessagesResult` is empty.

## What actually happened

`ChatSendingBubbleTests` sent a queued reply through the real send path with a fresh
`MockEmailProvider`. After the append, `finalizeOutboxMessage` starts the account's Sent folder sync
in a `Task` nobody awaits. The mock's Sent folder listed nothing, so that sync treated the optimistic
Sent copy (`sent-<outboxId>`) as gone from the server and deleted it, at a time of its own choosing.
Two tests read that copy afterwards: one expected the summary made at Send on it, the other expected
the chat's Sending bubble to end when the copy reached the chat. Both passed in the PR's own run and
in a 1,787-test tip run before, then failed in the next tip run and on the first of 15 repetitions;
the failure message, once it printed the rows, showed `Sent copies: []`.

The first guess was host load (the tip run had ~22 GB of swap); the repetition with the suite alone
disproved it.

## The rule

A test that sends through the real send path gives its mock a Sent folder that lists the sent email
(its `sentMessageId`, a server id, the same parent), as a server does after the append, plus any other
Sent row the test reads. The post-send sync then replaces the optimistic copy with the server's, which
restores the AI cache, and the test holds whichever copy is there. Do not await or suppress that sync
in the test instead: production runs it, and the copy it produces is the one users see. Print the rows
in the failure message of any Sent-folder assertion, so a race shows as data rather than a bare false.
