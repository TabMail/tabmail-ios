<!-- COMPANION-CURRENT-NOTE-BEGIN -->
**Amended after this fragment was pinned (2026-11-08, #426).** Where the text below and the pinned body differ, this text wins:

**Update 2026-11-08 (#426, ADR-IOS-103):** `performHTTPRequestWithRetry` now waits for a response's `Retry-After` (delta-seconds) when it has one, and returns the refusal without retrying once a wait would take the call's waits past `HTTPConfig.retryWaitBudgetSeconds`; the 1s/2s/4s back-off in the body below applies only without the header.
<!-- COMPANION-CURRENT-NOTE-END -->

### Benign Sync Log Noise — DraftUpsertSkip + Gmail 429 (diagnosed 2026-06-09)
- `[Sync] DraftUpsertSkip: preserving local content for … (folder=sent/drafts)` fires for EVERY existing row in drafts/sent on every full sync, for ALL providers (IMAP UIDs, Graph AQMk… ids, Gmail hex ids). It is the intentional guard at `SyncEngineFullSync.swift:691` against the "time snaps back" bug (server drafts.list/summary cache lags a local push, so existing-row metadata is never overwritten in those folders). High volume ≠ problem.
- `[Gmail] Rate limited (429) … "Too many concurrent requests for user"` comes from the UNBOUNDED `withThrowingTaskGroup` header fetch (`GmailProvider.swift:149` — one `messages.get?format=metadata` task per ref). `performHTTPRequestWithRetry` (HTTPClient.swift) retries 3× with 1s/2s/4s backoff; observed hits all recover on attempt 1. If retries DID exhaust, `request()` throws → the throwing task group aborts the whole folder fetch → that folder's sync cycle fails and retries next poll. A partial header list can never reach the stale-delete path, so 429s cannot cause message deletion.
