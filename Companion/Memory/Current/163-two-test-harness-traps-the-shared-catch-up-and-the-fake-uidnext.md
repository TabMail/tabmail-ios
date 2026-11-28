# 163 — Two test-harness traps: the shared engine's catch-up, and the fake server's UIDNEXT

**Status:** Current (2026-11-25). Applies to every test that runs the catch-up or deletes a message on
`FakeIMAPServer`. Found when four new tests of a no-`COPYUID` move failed in their setup, never reaching
the property they assert.

## 1. `AccountManager.shared.syncEngine.runCatchUpRun` does nothing for a test account

`SyncEngine.runCatchUpRun` starts with `guard let queue = workQueues[account.id] else { return false }`.
`AccountManager.registerProviderForTesting` fills the account manager's own `workQueues`, not the shared sync
engine's, so on the shared engine the run returns `false` at once: no slice, no listing, nothing loaded. A test
that then asserts "the catch-up loaded the copies the window does not reach" fails, and the failure reads like
a production gap.

**Do:** run the catch-up on an engine registered with the account, as `IMAPMoveIntoTrackedFolderTests` does:

```swift
let engine = SyncEngine()
await engine.register(accountId: accountId, provider: provider,
                      workQueue: ProviderWorkQueue(provider: provider, maxConcurrency: SyncConfig.imapMaxConnectionCeiling))
let ran = await engine.runCatchUpRun(account: account, run: .snapshot(deadline: Date().addingTimeInterval(30)))
#expect(ran)  // a run that made no progress loaded nothing
```

## 2. Without its QRESYNC model, deleting the top message lowers the fake's UIDNEXT

`FakeIMAPServer`'s SELECT reports `UIDNEXT` as the highest live UID plus one unless the mailbox runs the
QRESYNC model (`modelsModSeqs`, where `maxUID` only grows). So `setMessages` that removes the mailbox's highest
UID makes the next SELECT report a LOWER `UIDNEXT`, which no real server does (RFC 3501 §2.3.1.1: UIDNEXT
never decreases within an epoch). The window listing's stale sweep judges only UIDs below the listing's own
`UIDNEXT` (`SyncEngine.selectStaleHeaders`, #755), so the deleted message's local row is rightly kept and a
test expecting it gone fails.

**Do:** when a test deletes the top message, also add a later arrival above it in the same `setMessages`
(or run the mailbox with the QRESYNC capabilities), so the fake's `UIDNEXT` stays above the deleted UID.

## Related

The drain side has its own trap, recorded in History/097: a `queue*` or `move` call ends with its own
`Task { await drainPendingQueue() }`, and a test's own drain call made while that one runs only sets
`needsRedrain`. The mirror case appears here: a test that wants exactly ONE attempt (a lost reply, then a sync,
then the retry) must not call the drain at all, because the merged redrain retries at once. It waits for the
move's own drain to try the op (`everAttempted`, status back to `queued`, `pendingQueueIsQuiescentForTesting`).
