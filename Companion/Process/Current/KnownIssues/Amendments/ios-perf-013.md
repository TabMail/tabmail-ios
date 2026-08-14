# IOS-PERF-013

- Register classification: `resolved`
- New post-freeze record (2026-08-13) added through the amendment surface; no row in the
  hash-pinned archive and therefore no original row hash.

## Status

✅ **RESOLVED (2026-08-13, `f60f41391`)** — a drain resolved **each queued member with its own
statement**, and in the shipped statistics regime every one of those statements degraded to an
account-wide walk. **12,229 ms for a 200-member archive, versus <1 ms after.** Found by the
whole-SQL-surface audit and confirmed by measurement under both stat regimes.

## Subsystem and search terms

`AccountManager.executeSingleOp`; `retirePartiallyCompletedOp`; `headerIdentitiesForQueuedMembers`;
queued-member identity resolution; per-member `fetchOne`; N+1 statement per member; MULTI-INDEX OR;
`messageId = ? OR rfc822MessageId = ?`; `messageHeader_accountId_messageId`;
`messageHeader_rfc822MessageId`; `INDEXED BY`; stale `sqlite_stat1`; account walk; bulk archive;
`SyncConfig.sqlChunkSize`; `IN`-list chunking; drain identity; `ChatStore.findByStableIdSQL`;
walk position; tail-drawn probe

## Full detail

**The shape.** `AccountManager.executeSingleOp` step 1 and `retirePartiallyCompletedOp` each resolved a
queued member with its own statement:

```sql
WHERE (messageId = ? OR rfc822MessageId = ?) AND accountId = ?
```

With **stale `sqlite_stat1` — which is the shipped regime**, SQLite cannot form a MULTI-INDEX OR and
falls back to:

```
SEARCH messageHeader USING INDEX messageHeader_accountId_messageId (accountId=?)
```

That is an **account walk per member**. Measured on 260k rows, 189,800 in-account, members drawn from
the tail: **12,229 ms for 200 members**. After the fix: **<1 ms**.

## The fix

Two set-based `IN`-list arms, chunked at `SyncConfig.sqlChunkSize`. **No new index, no migration.**

`INDEXED BY messageHeader_rfc822MessageId` on the rfc822 arm is **load-bearing and deliberately
fail-safe**: without it that arm walks in the stale regime (69 ms), and if a future migration drops the
index the statement **throws** rather than silently degrading to a walk. Both callers already treat a
throw as "no identities collected", so the failure mode is a refusal rather than a slow success. Same
pattern as `ChatStore.findByStableIdSQL`.

## ⚠️ NOT a C3 exposure — and the sibling pick was ALREADY non-deterministic

`messageId` is a **per-folder UID** that repeats across folders, so the old `fetchOne`-over-`OR`
returned whichever row its plan reached first — and that differed **between stat regimes**. The
pre-fix behaviour was therefore already non-deterministic; the fix does not introduce ambiguity, it
removes it. The pick is now deterministic: arm A over arm B, then `ORDER BY isInInbox DESC, id ASC`.

Stating this explicitly because "a set-based rewrite changed which row we pick" reads like a
wrong-message hazard until you check what the previous behaviour actually was.

## Measurement caveat that cost a round

See `IOS-PERF-012`'s **walk-position** axis. The same 200-member resolution measures **0.105 ms each**
with head-drawn members and **12,229 ms** with tail-drawn ones — a ~580× spread with no change to
schema, statement or stat regime. A head-drawn probe makes this defect look absent. **Draw from the
tail**, and state which end the sample came from.

## Related

- `IOS-PERF-012` — the stat-regime trap and the walk-position axis; read before re-measuring anything here.
- `IOS-PERF-016` — the other queue-adjacent finding from the same audit pass.
- `IOS-PERF-010` — the blocked-main-thread-reader class.
- `IOS-SEARCH-004` / `53d17514e` — the sibling index-defeat finding from the same audit.
