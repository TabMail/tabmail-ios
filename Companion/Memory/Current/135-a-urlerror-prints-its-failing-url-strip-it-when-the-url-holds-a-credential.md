# A URLError prints its failing URL: strip it when the URL holds a credential

**Since:** 2026-10-22 (#217 tier-1 review round 4, R1).

## The fact

A `URLError` from a real `URLSession` request carries `NSURLErrorFailingURLErrorKey` (and the
deprecated string key) in its userInfo: the full URL, query string included. `"\(error)"` prints the
userInfo, so any log line that interpolates the error writes the URL. `localizedDescription` does
not include it.

The queue's generic failure log (`AccountOperationExecutor.executeSingleOp`, `"[Queue] Failed …:
\(error)"`) and `AccountManager.logStuckOpDiagnostic` (`error=\(error)`) both interpolate raw
errors into `BackgroundSyncLogger.logQueue`, which persists to the exportable debug log. A provider
that propagates a transport error from a request whose URL holds a credential therefore writes
that credential to disk and off the device when the user shares the log.

## Where it applies

- **Graph upload sessions** (`ExchangeProvider.addDraftAttachment`, #217): the session URL carries a
  pre-authenticated `authtoken`. The chunk PUT catches `URLError` and rethrows `URLError(error.code)`,
  which keeps the code the retry classification reads and drops the userInfo.
- **Device sync WebSocket** (`DeviceSyncService.redactedTransportError`, live credential leaked this
  way, observed 2026-06-09): a log-side redaction, because those errors are logged, not propagated.

Choose by where the error goes: one that is thrown into shared code is redacted at the throw, since
the code that logs it cannot know which URL was secret; one that is only logged locally may be
redacted at the log line.

## Testing it

`FakeHTTP`'s `transportError` attaches `NSURLErrorFailingURLErrorKey`, as the real loader does
(URLSession passes a `URLProtocol`'s error through unchanged, so without it no fake transport error
carries a URL and a leak test cannot go red). `DraftCopyReadTests.failedUploadDoesNotCarryTheSessionToken`
asserts the rendered error lacks the token and is still a `.timedOut` `URLError`.
