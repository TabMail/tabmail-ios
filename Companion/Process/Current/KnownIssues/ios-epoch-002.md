# IOS-EPOCH-002

> Routed from `KNOWN_ISSUES.md` line 1064 during the 2026-08-09 hierarchy split. The exact pre-split source is hash-pinned in [`known-issues-pre-hierarchy-2026-08-09.txt`](../../History/KnownIssues/known-issues-pre-hierarchy-2026-08-09.txt) (`SHA-256 513497704ad37e977e2fb86e4623e956e6f1ca99844122948ff74995dfa9a309`).

- Register classification: `closed-decision`
- Original row SHA-256: `1edfb6012b17c03bcfac1a8a79bea66ca6d859a5dc8fd27e7305d5b19fe057ba`

## Status

✅ **CLOSED AS A DECISION (2026-08-05, round-8 Q12)** — the **merge-refused / delete-allowed asymmetry** on a server that never reports UIDVALIDITY. Both halves are individually correct and were **justified separately and never stated against each other**; this row is that statement, not a new finding

## Subsystem and search terms

IMAP; UIDVALIDITY; `providerAddressOwnershipProven`; `sourceBoundEpoch`; `SyncEngineFullSync`; `canonicalizeLocalRows`; merge refusal; `selectStaleHeaders`; stale deletion; nonconforming server; RFC 3501 6.3.1; `IOS-EPOCH-001`; C3; misattribution

## Full detail

**The asymmetry, by symbol.** `providerAddressOwnershipProven`'s `.uid` arm opens `guard let sourceBoundEpoch, sourceBoundEpoch > 0 else { return false }`. On a server that never reports UIDVALIDITY that guard is false forever, so **every** row-merge in **every** folder is refused for the account's whole lifetime. Meanwhile `selectStaleHeaders` — the channel that decides which local rows are stale and get **deleted** — takes `candidates`, `fetched`, `coverage` and `windowMode` and **no epoch parameter at all**: it is not gated on the same proof, so the deletion half keeps running at full strength while the merge half is permanently closed.

**Refusing is CORRECT and must not be "fixed".** Admitting a nil or zero epoch as ownership proof re-opens, for **every** provider rather than for this one nonconforming server, precisely the misattribution the guard exists to stop: a local row that answers for a UID it no longer denotes gets merged into, and a later mutation lands on the wrong message (C3). The fail-closed direction is the only safe one, and this row does not ask for it to change.

**So what is the finding?** Only that the two halves have never been read together. Each was adjudicated on its own merits in a different round, and neither cell mentions the other — so a reader of either one cannot see that on this server class the system is in a **strictly asymmetric** state: it will delete local rows it believes stale but will never repair or merge one, which biases the account toward re-fetching rather than reconciling. That is stable and self-correcting through re-fetch, not divergent; it is recorded so the next person to touch either half knows the other exists.

**Reachability.** RFC 3501 §6.3.1 requires a `UIDVALIDITY` response on `SELECT`/`EXAMINE`, so a server that never sends one is **nonconforming**. The population is therefore small and self-selected, which is the frequency argument THE MANTRA asks for before invoking it.

**Why it is not covered by an existing row.** `IOS-EPOCH-001` registers the **gesture** half — a durable action refused while `Folder.lastKnownUidValidity` is nil. It says nothing about the **sync-merge** half, and nothing at all about the deletion channel continuing. Reading `IOS-EPOCH-001` as covering this is the specific mistake this row prevents.

**The NON-RECOVERING case (`MIS-IOS-008`).** There is none on the merge side: a refused merge leaves the local row untouched and the server copy is re-fetched, so ordinary sync reaches a correct state. The deletion side is bounded by `selectStaleHeaders`' own `!remoteIds.contains(...)` terms — a message the fetch returned is never stale. **What would make it non-recovering, and is the thing to check if this is ever revisited:** any change that lets the deletion channel act on a message the current fetch DID return, or any widening of `providerAddressOwnershipProven` to accept an unproven epoch. Either turns a stable asymmetry into a wrong-message outcome.
