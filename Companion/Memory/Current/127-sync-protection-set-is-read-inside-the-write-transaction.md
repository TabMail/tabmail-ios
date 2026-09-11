# The `recentlyCompleted` sync protection set is read INSIDE the sync write transaction, never before the listing fetch

**Status:** Current · **Fixed:** 2026-09-11 (branch `agent/ios-queue-weak-connectivity`) · **Supersedes the residual of issue #106 (`80b54993e`, v1.7.16).**

## The symptom, and what it is NOT

Owner report, 2026-09-11: on a weak connection, an archived message "comes back" in the Inbox with no
snippet, as if the optimistic move had been cancelled. **It is not the action queue dropping the op.**
The 2026-09-07..10 device log (`tabmail_logs 4.txt`) has zero moves with a charged `retryCount`, no
retirement, no cap hit; the one `Operation timed out` was `retryLater(chargeRetry: false)` and re-ran.
Transport errors do not charge the cap (`SyncEngine.isConnectionError` exemption in
`AccountOperationExecutor`), and the drain refuses to start offline.

The reproduction (UID 74740, IMAP INBOX→Archive, 07:37:26Z): `executed … move … outcome=completed`,
the row re-keyed to Archive, and **in the same second** `fullSync upsert[INBOX] — inserted 1 header(s):
…:INBOX:74740` — a header-only, snippet-less ghost of the source address, deleted 29 s later by
`ActiveBody` `CONFIRMED GONE` (`[Gone] Deleted header … reason=activeBody miss>=5`).

## Why the v1.7.16 fix did not close it

`80b54993e` moved the `AccountManager.recentlyCompleted` read from once-per-run to once-per-folder,
immediately before `runSyncMessages`. But `runSyncMessages` then performs the NETWORK listing fetch
(`fetchMessagesWithObservedEpoch`) and only afterwards runs the write transaction that consults the
snapshot. A move that completes during the fetch is invisible to both guards: no longer pending, and its
protection entry postdates the snapshot. The window is one folder's fetch round trip — milliseconds on
wifi, seconds on a weak link. A weak link hurts twice: ghost cleanup needs a server probe
(`BackfillBodyQueue.confirmGoneAtThreshold` → `currentUIDs` SEARCH), and a failed probe is
`.cannotConfirm` = keep retrying, so the ghost lingers exactly when the network is bad.

## The fix — same shape as the pending-op guard

Pending ops were already re-read INSIDE the write transaction (`PendingOperation.fetchAll(db)`, the
"pending ops inside txn" TOCTOU rule). The protection set now follows the same rule:

- `AccountManager.recentlyCompleted` is backed by a `Mutex<[String: Date]>` (`import Synchronization`,
  per `resilience.md` rule 5), not actor state, so a synchronous write closure can read it.
- `AccountManager.liveRecentlyCompleted()` — `nonisolated`, expiry-filtered at read — is called inside
  the write transaction by `runSyncMessages` (full sync), both delta-sync merge writes (Gmail, Exchange)
  and `deleteServerConfirmedDeletions` (deletion reconcile). The `recentlyCompleted:` parameter of
  `runSyncMessages` is gone; the pre-fetch `pruneRecentlyCompleted()` + snapshot dance at every call
  site is gone.
- Why this closes the window: `recordRecentlyCompleted` runs BEFORE the op's retirement transaction
  commits, and every sync write is serialised behind that transaction on the same writer, so a read
  taken inside the sync transaction sees either the pending op or the protection entry — never neither.

Tests: `FullSyncRecentlyCompletedFreshnessTests.completionDuringTheFolderFetchIsHonoured()` pins the
invariant at the tighter boundary (completion recorded during the folder's OWN listing fetch must be
honoured by that folder's write); red on the pre-fix read (see the PR for the red evidence).
`StaleProtectionTests` now records on the live store instead of injecting a map.

## How to apply

When the owner reports "archive undone, no snippet", grep the log for
`fullSync upsert[<src>] — inserted … :<src>:<uid>` within seconds of `executed … move … outcome=completed`
for the same UID before suspecting the queue. Any NEW sync consumer of the protection set must call
`liveRecentlyCompleted()` inside its write transaction; a value captured before a network await is the
#106 defect again.
