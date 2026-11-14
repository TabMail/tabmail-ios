# IOS-CATCHUP-003

- Register classification: `accepted`
- New post-freeze record (2026-11-13) added through the amendment surface; no row in the
  hash-pinned archive and therefore no original row hash.

## Status

📋 **ACCEPTED LIMITATION (2026-11-13, #750).** Registered with the rule that keeps a slow
older-mail read from undoing a newer user action (ADR-IOS-107, ADR-IOS-111). The apply is shared,
so it holds for every provider's check: Outlook, Gmail and IMAP.

## The behaviour

`SyncEngine.runCatchUp` notes when a slice's read begins (`readStartedAt`, on the wall clock
`CatchUpWallClock`) just before it asks the provider. `AccountManager` keeps an in-memory log of
when each user action completed (`recordActionCompleted`, `actionCompletedAt`). The log holds no
message content and is pruned after `SyncConfig.catchUpCompletionLogRetentionSeconds` (1 hour).

The apply then works like this:

- It skips the read or flag update of any message whose action completed at or after the read
  began. That message keeps the user's value.
- When the read began 1 hour or more before the apply, a log entry that matters may already be
  pruned. The apply then skips **every** read and flag update in that result. It still applies the
  result's removals and loads and writes the folder's state, so the check never stalls on one
  slice.

*Amended later the same day (2026-11-13):* loads follow the same rule. On Gmail and Outlook (the
providers whose check loads missing mail), the insert skips a loaded message the user's own newer
action stands on (`SyncEngine.catchUpReadPredatesAction`, read inside each insert chunk's
transaction), so a message moved out of the folder after the read began is not put back. A read 1
hour or more old inserts **no** load at all. "and loads" in the bullet above is superseded and kept as
written; the removals and the state still apply. A skipped load is not a failure and marks nothing:
if the server still lists the message in the folder, the next listing finds it missing again and
loads it.

The skipped flag corrections (and, since the amendment above, the skipped loads) wait for the folder's next listing. On Outlook and Gmail that is the
next lapse (see `IOS-CATCHUP-001`); on IMAP it is the daily full check
(`SyncConfig.catchUpFullCheckIntervalSeconds`).

## When it happens

It needs a read and its apply more than an hour apart. The realistic cause is iOS suspending the
app in the middle of a slice and resuming it later. Even then, it only matters for a message whose
read or flag state differs from the server and which only the listing would have corrected.

## Recoverability

Nothing is lost and no newer user value is overwritten. That is the point of the rule. A later
change to the message on the server is reported by the change feed, and the next listing applies
the server's current state.

## Subsystem and search terms

Older-mail check; catch-up; flag heal; read state; over-age read; slow read; app suspended;
`readStartedAt`; `CatchUpWallClock`; `actionCompletedAt`; `recordActionCompleted`;
`catchUpCompletionLogRetentionSeconds`; completion log; 1 hour; `applyCatchUpResult`;
`applyCatchUpTransaction`; Outlook; Gmail; IMAP; ADR-IOS-107; ADR-IOS-111; ADR-IOS-051; #750;
IOS-CATCHUP-001
