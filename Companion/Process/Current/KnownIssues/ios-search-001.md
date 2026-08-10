# IOS-SEARCH-001

> Routed from `KNOWN_ISSUES.md` line 153 during the 2026-08-09 hierarchy split. The exact pre-split source is hash-pinned in [`known-issues-pre-hierarchy-2026-08-09.txt`](../../History/KnownIssues/known-issues-pre-hierarchy-2026-08-09.txt) (`SHA-256 513497704ad37e977e2fb86e4623e956e6f1ca99844122948ff74995dfa9a309`).

- Register classification: `attribution-first`
- Original row SHA-256: `a59f1f58dc1814d60580872e8a5e85b15bfa9d304668cc9be1922d92037285fb`

## Status

Pre-existing **C3**; shipped verbatim in v1.6.38; ✅ **FIXED by `766badea2`**

## Subsystem and search terms

Search; `SearchView.openResult(_:)`; cached local result; headerId; UIDVALIDITY reset; `markReadOnOpenIfNeeded`; wrong-message mutation

## Full detail

`SearchView.openResult(_:)` takes `if let headerId = result.headerId { navigationPath.append(headerId); return }` — it navigates on a cached composite address with **no re-resolution and no identity validation**; only the *remote* branch re-resolves. After a correct UIDVALIDITY reset re-seats that `(accountId, folderPath, uid)` address, tapping a stale local search result opens message **Y** while the user believes they tapped **X**, and `MessageDetailViewModel.markReadOnOpenIfNeeded()` then registers a durable read mutation on Y. Audit round 1 fixed only the remote sibling, which is why the two branches now differ.

✅ **FIXED by `766badea2`, "Prove search-result identity before a local tap opens and marks read".** **The invariant that now holds:** a local search result opens a message **only when the RFC 822 Message-ID of the row now at the captured address still equals the one captured when that result was rendered**; on disagreement — or a vanished row — it navigates nowhere and raises *"Result no longer available"*. No durable read mutation can therefore land on a message the user was not shown. `SearchResult` carries `capturedRfc822MessageId`, taken from the header row the local search ALREADY reads, so the witness costs **zero** extra I/O; `resolveLocalResultHeaderId` re-reads the row at the captured address inside one `dbPool.read` and compares through `MessageIdentity.comparableRfc822Identity`, the tree's single identity-COMPARISON normalizer — no second normalizer and no new witness were minted. ⚠️ **THE FIX THIS ROW IMPLIED WAS A NULL FIX, AND WAS NOT TAKEN.** Contrasting the local branch (*"no re-resolution"*) with the remote one (*"re-resolves"*) is misleading: `resolveRemoteResultHeaderId` filters on `messageId && accountId (+ folderPath)` and returns the matched row's `.id`, **which IS that same composite address** — it establishes EXISTENCE, not IDENTITY, and against a re-seated address it returns exactly the wrong row. Routing the local branch through it would have looked like a C3 closure while closing nothing. What was missing was a CONTENT witness, which is what landed. **Not an ADR-IOS-068/D4 violation:** D4 forbids an RFC 822 Message-ID SELECTING or AUTHORIZING a mutation target; here the target is still selected by the durable composite address exactly as before, and the RFC id can only REFUSE it, never widen it or nominate a different one — the same content-witness use `AIWriteTarget.resolveCurrentHeader` arm 6, `MessageAICache`, the FTS/body stores and threading already make. **A1:** shipped `07a4bb703` carries the local branch verbatim, so the release did not solve this and the fix is authored under A1 step 3 ("nonexistent").
