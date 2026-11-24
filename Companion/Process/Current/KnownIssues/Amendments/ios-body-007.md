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

The window moves only when its rows leave the read. While every row of the newest window keeps failing,
the older waiting rows of that queue's scope are not admitted:

1. **Rows of an account with no provider stay pending.** When an account's sign-in is refused, or no
   connection to it can be made, the dispatch has no provider for it and releases its items back to
   pending (`releaseInFlightOnly`). They neither complete nor use up their retries, so the queue never
   drains and its drain-time refill never runs. A later full refill (launch, foreground, sync recovery)
   reads the same newest window, whose rows the queue already holds.
2. **Rows whose fetch fails every time.** They use up their retries and are kept out of the drain-time
   refill for the rest of that drain (`retryExhaustedThisDrain`), so the drain-time refill reads the same
   window and admits nothing. The next full refill gives them one more budget, and the same window again.

Rows the window does not reach keep their state honestly (`bodyComplete = 0`); nothing is marked
fetched.

## When it happens

Rare: it needs one account (or folder) whose bodies cannot be fetched holding the whole window, the
newest `SyncConfig.bodyFetchRepopulateLimit` waiting rows of that queue's scope, while other waiting rows
are older. A typical case is a first backfill of two accounts, one of which then has its password
changed. A window with any fetchable rows keeps moving: its fetchable rows complete, and a later refill
admits older rows in their place.

Not affected: mail sync hands to the queues directly (new inbox mail, and the rows the backfill walk
loads), which does not go through the refill; a message the user opens, whose body the reader fetches on
demand; and the other queue's scope.

## Recoverability

Recoverable by one ordinary gesture or by itself: signing the account in again lets its rows fetch and
leave the read, and removing the account deletes them; a server that recovers does the same at the next
full refill. The older rows are then admitted window by window. No user content is lost or marked
fetched, and an opened message still loads its body.

## Subsystem and search terms

`ActiveBodyQueue`; `BackfillBodyQueue`; `admissionSQL`; `admissionItems`; `repopulateFromDatabase`;
`repopulateOnDrain`; `SyncConfig.bodyFetchRepopulateLimit`; `messageHeader_bodyRepopulateV2`; body
queue refill window; newest window; `ORDER BY date DESC LIMIT`; body backfill stalls behind a failing
account; sign-in refused; no provider; `releaseInFlightOnly`; `retryExhaustedThisDrain`; ADR-IOS-027
(ever-rolling FIFO queues, boot-time recovery); ADR-IOS-078 (the AI window, which this does not change);
#1400.
