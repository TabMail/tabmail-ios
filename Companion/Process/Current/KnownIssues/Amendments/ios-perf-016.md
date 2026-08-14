# IOS-PERF-016

- Register classification: `open`
- New post-freeze record (2026-08-13) added through the amendment surface; no row in the
  hash-pinned archive and therefore no original row hash.

## Status

🔓 **OPEN (2026-08-13)** — `UndoService.push` performs **ungated, main-actor, N+1 database reads plus an
unbounded `PendingOperation` fetch, in production, feeding nothing but `print()`.** It runs on every
archive, delete and move — the most-travelled gesture path in the app. Found by the whole-SQL-surface
audit (its finding 8) and independently confirmed by reading. **Development rule 12 violation.**

## Subsystem and search terms

`UndoService.push`; `UndoableAction`; `undoStack`; `[UndoStack] PUSH`; `[UndoStack] DB state after push`;
`[UndoStack] PendingOps after push`; ungated `print`; development rule 12; debug gating;
`DebugModeManager.isLoggingEnabled`; main-actor `dbPool.read`; N+1 per message; unbounded `fetchAll`;
`PendingOperation.filter(accountId).fetchAll`; diagnostic work not gated with its log;
`logStuckOpDiagnostic` prior art; gate the WHOLE body not just the emission; swipe-to-archive hitch;
`SyncConfig.undoStackMaxSize`

## Full detail

**The shape.** `UndoService.push` — invoked whenever a destructive action is pushed onto the undo stack,
i.e. on **every archive, delete and move** — ends by spawning:

```swift
Task { @MainActor in
    for msgId in msgIds {
        let rows = try? dbPool.read { db in
            try MessageHeader
                .filter(Column("messageId") == msgId && Column("accountId") == action.accountId)
                .fetchAll(db)
        }
        …
        print("[UndoStack] DB state after push — msgId=\(msgId) rows=[…]")
    }
    let pendingOps = try? dbPool.read { db in
        try PendingOperation
            .filter(Column("accountId") == action.accountId)
            .fetchAll(db)
    }
    …
    print("[UndoStack] PendingOps after push — […]")
}
```

**Three separate costs, none of them gated:**

1. **N+1 main-actor pool acquisitions** — one `dbPool.read` per member of the action. A bulk archive of
   200 messages issues 200 of them.
2. **An unbounded `fetchAll`** over every `PendingOperation` row for the account. No `LIMIT`, no
   predicate beyond `accountId`. This is materialising the entire queue into memory to render a log
   line.
3. **Eager argument construction on the synchronous path**, before the `Task` — three `.map`s over
   `action.messages` (`msgIds`, `msgFolderIds`, `msgCompositeIds`) and a large interpolated string,
   built unconditionally for the `[UndoStack] PUSH` line.

**In a production build every one of those `print`s goes nowhere.** The work is performed to render
output that cannot be read. `UndoService.swift` has **11 `print(` sites against 5
`DebugModeManager.isLoggingEnabled` references**, so the gating in this file is partial rather than
absent — which is why this survived: the file *looks* gated.

⚠️ **This is NOT the index-defeating sorter class**, despite arriving from the same audit. There is no
`ORDER BY`, nothing defeats a `LIMIT`, and the per-message query is index-assisted. Filing it beside
`IOS-PERF-009`/`IOS-SEARCH-004` because an audit found them together would be the mis-classification
the register exists to prevent. It is a **rule-12 diagnostic-work violation** that happens to be
expensive, and it is a member of `IOS-PERF-010`'s blocked-main-thread-reader class by virtue of being
synchronous `dbPool.read` reachable from `@MainActor`.

## The fix is one line, and its template is one file away

`AccountManagerQueue.logStuckOpDiagnostic` already solves exactly this, and **its comment states the
principle this site violates**:

> Log-only helper: gate the WHOLE body, not just the emission. Every `queueLog` below is individually
> gated too, but this guard is what skips the scoped DB read the dump exists to render — a read that in
> a shipping build could only ever feed a log nobody can see.

Applying the same `guard DebugModeManager.isLoggingEnabled() else { return }` to the `Task` body — and
moving the three `.map`s inside a gate — removes all three costs with **zero observable production
behaviour change**, because the only thing downstream of them is invisible output.

⚠️ **Gate the `Task`, not each `print` inside it.** Gating only the emissions leaves the reads. That is
precisely the distinction `logStuckOpDiagnostic`'s comment was written to record, and the audit's
finding 9 confirmed that helper gets it right.

## Attribution class

Latent performance/hygiene defect, found by audit and confirmed by reading. No field report. Not
introduced by any recent change.

## ⚠️ For whoever takes it — the class is bigger than this row

The same audit reported `SearchIndex.swift` carrying **~35–38 further ungated `print(` sites**, several
interpolating whole bind-argument arrays. That sweep is tracked separately. **Do not close this row on
the strength of fixing `UndoService` alone**, and when sweeping, enumerate by **state** — every
diagnostic site whose *work* is ungated — rather than by grepping for `print(`, which finds emissions
and misses the reads that feed them.

## Related

- `IOS-PERF-010` — the blocked-main-thread-reader class this is a member of.
- `IOS-PERF-013` — the other queue-side finding from the same audit pass.
- `AccountManagerQueue.logStuckOpDiagnostic` — the in-tree template for the fix, and the source of the
  gate-the-whole-body rule.
