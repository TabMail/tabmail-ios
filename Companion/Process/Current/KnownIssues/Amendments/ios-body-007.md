# IOS-BODY-007

- Register classification: `accepted`
- New post-freeze record (2026-11-24) added through the amendment surface; no row in the
  hash-pinned archive and therefore no original row hash.

## Status

📋 **ACCEPTED LIMITATION (2026-11-24, #1400).** The cost of reading the body queues' waiting rows a
window at a time. Recoverable; registered rather than mechanised.

## The behaviour

Each body queue's refill (`ActiveBodyQueue.admissionSQL` for the inbox, `BackfillBodyQueue.admissionSQL`
for every other folder) reads the newest `SyncConfig.bodyFetchRepopulateLimit` rows that still wait for a
body, through `messageHeader_bodyRepopulateV2` in `date` order, and stops there. Before #1400 a refill
read and held every waiting row, most of the mailbox during a first backfill. A row leaves the read once
its body is stored, confirmed empty or quarantined, so the refill after a window completes admits the
next newest window, and successive refills still reach every waiting row.

There are two refills. A full refill (`repopulateFromDatabase`) runs at launch, on a return to the app,
in the background processing job and at sync recovery. The drain-time refill (`repopulateOnDrain`) runs
when the last batch ends with the queue empty, before that batch gives up its count, so the queue does
not look idle while rows wait (`isIdle`, `awaitDrain`). The window moves only as its rows leave the read.
Three cases slow or stop it:

1. **A row of an account with no provider.** The dispatch finds no provider for the account and hands
   the row back to pending (`releaseInFlightOnly`): it spends no retry and never completes. An account
   has no provider when it has no host or no password (`createIMAPProvider` throws), or before its first
   connection. One such row anywhere in the window keeps the queue from emptying, so the drain-time
   refill never runs; the window then moves only at full refills, each admitting newer waiting rows into
   the slots the completed rows freed. A refused sign-in is NOT this case: the account keeps its
   provider, and its rows fail as in case 2.
2. **Rows whose fetch fails every time** (for example an account whose sign-in is refused). Each row
   uses up its retries (`SyncConfig.maxQueueRetries`) and leaves the queue.
   - `ActiveBodyQueue` remembers it for the rest of that drain (`retryExhaustedThisDrain`), so its
     drain-time refill admits nothing from the same window; the next full refill clears that set and
     gives the rows one more budget, and the same window again.
   - `BackfillBodyQueue` keeps no such set: its drain-time refill re-admits the same failing window with
     a fresh retry budget at every drain, paced only by the inter-batch delay
     (`BackfillProfile.interCycleActiveDelay`). This loop predates #1400; before it, the refill re-admitted
     every waiting row, so the older rows were tried in the same loop. With the window, the loop repeats
     the same rows while the older ones wait. Whether this queue should keep a per-drain exhausted set
     too is #1455.
3. **Rows a fetch finished without storing a body.** When the search-index write is skipped or the
   completion flag write fails (`BodyFetchProcessor.flushBatch`), the row finishes as done
   (`shouldRetry = false`) but keeps `bodyComplete = 0`, and sits in the queue's completion dedup
   (`recentlyCompleted`, `SyncConfig.recentlyCompletedTTLSeconds`). While such rows fill the window, the drain-time
   refill admits nothing new; a full refill after the TTL fetches them again.

Rows the window does not reach keep their state honestly (`bodyComplete = 0`); nothing is marked
fetched.

## When it happens

Rare for case 2 and case 3: they need rows whose bodies cannot be fetched or stored holding the whole
window, the newest `SyncConfig.bodyFetchRepopulateLimit` waiting rows of that queue's scope, while other
waiting rows are older. A typical case is a first backfill of two accounts, one of which then has its
password changed. A window with any fetchable rows keeps moving: its fetchable rows complete, and a later
refill admits older rows in their place.

Case 1 needs an account with no host or password (a broken account), or a refill that runs before the
account's first connection. While it lasts, the other accounts' older rows in that queue's scope move
one window per full refill instead of continuously.

Not affected: mail sync hands to the queues directly (new inbox mail, and the rows the backfill walk
loads), which does not go through the refill; a message the user opens, whose body the reader fetches on
demand; and the other queue's scope. Inbox rows the notification extension merged without a body DO
rely on the active queue's refill: one with an old date sits behind the window while
`SyncConfig.bodyFetchRepopulateLimit` or more newer inbox rows wait; opening it fetches its body.

## Recoverability

Recoverable by one ordinary gesture or by itself: signing the account in again, or entering its
password, lets its rows fetch and leave the read, and removing the account deletes them; a server that
recovers does the same at the next full refill, and every return to the app runs a full refill. The
older rows are then admitted window by window. No user content is lost or marked fetched, and an opened
message still loads its body.

## Subsystem and search terms

`ActiveBodyQueue`; `BackfillBodyQueue`; `admissionSQL`; `admissionItems`; `repopulateFromDatabase`;
`repopulateOnDrain`; `finishBatch`; `SyncConfig.bodyFetchRepopulateLimit`;
`messageHeader_bodyRepopulateV2`; body queue refill window; newest window; drain-time refill; full
refill; `ORDER BY date DESC LIMIT`; body backfill stalls behind a failing account; no provider; no
password; sign-in refused; `releaseInFlightOnly`; `retryExhaustedThisDrain`; `recentlyCompleted`;
`interCycleActiveDelay`; #1455; notification extension merge without a body; ADR-IOS-027 (ever-rolling FIFO
queues, boot-time recovery); ADR-IOS-078 (the AI window, which this does not change); #1400.
