# IOS-LOG-002

> **Post-freeze amendment to a BASE-register record.** Added 2026-09-04 through the amendment
> surface described in `Scripts/compact_known_issues.rb`. The base record's own bytes are
> hash-pinned and are **not** edited by this file:
> `Companion/Process/Current/KnownIssues/ios-log-002.md` keeps its original row, its original
> SHA-256, and the 2026-08-25 consolidation amendment block already wrapped inside it. This file
> only **adds** the facts that the 2026-09-04 `.queue` channel falsified.

- Register classification: **UNCHANGED — still `closed-decision`.** Nothing here re-opens the row.
  Classes B (the account holder's own address) and C (user-authored folder names) stay deferred on
  exactly the two-sided trade the base record argues, and this amendment does not license sweeping
  them.
- Amends: the 2026-08-25 consolidation amendment block inside
  `Companion/Process/Current/KnownIssues/ios-log-002.md` — specifically its channel ARITHMETIC and
  its pointer sentence — plus the sibling topic
  `Companion/Memory/Current/122-one-log-file-per-process.md`.

## What changed

`AppLogChannel` gained a **sixteenth** case on 2026-09-04, for `IOS-QUEUE-008`:

- **`case queue`, tag `QUEUE`**, written by exactly one façade,
  `BackgroundSyncLogger.logQueue(_ message: @autoclosure () -> String)`.
- It carries the action-queue drain's lane composition and per-op wire order TOGETHER with the
  sync side's `[MoveTrace]` move-convergence lines. One channel for both halves on purpose: the
  question those lines exist to answer — "did the undo inverse and the re-delete serialize, or did
  they race, and which one reached the wire last" — can only be answered from a SINGLE ordered
  artifact. Split across two channels, the interleaving is exactly the fact that is lost.
- Its three call sites (`AccountManagerQueue.queueLog`, `SyncEngineDeltaSync.deltaMoveTraceLog`,
  and the full-sync inserted-id line) previously wrote the **always-on `.sync`** channel or bare
  `print`. Moving them off `.sync` is the point: `.sync` has ~137 call sites and evicts the shared
  tail, and these traces are only wanted when someone is actively reconstructing a race.

## The arithmetic this falsifies, stated as the new number rather than by deletion

| Claim, and where it is written | Was | Is |
|---|---|---|
| "one App Logs share now exports all **fifteen** main-app channels" — the base file's 2026-08-25 amendment block, exposure bullet (d) | fifteen | **sixteen** |
| "the gating split is **FIVE always-on to TEN debug-gated**" — topic 122 | 5 / 10 | **5 / 11** |
| "a new channel is an `AppLogChannel` case rather than a **sixteenth file**" — the base file's pointer sentence | *(still true, and now easy to misread)* | see below |

⚠️ **The pointer sentence is still CORRECT but is now a reading hazard.** "Rather than a sixteenth
file" counts the fifteen replaced log FILES, a **closed historical set that does not grow when a
channel is added**. It does not count channels, and after 2026-09-04 there IS a sixteenth *channel*.
The two integers were equal for exactly as long as no channel had been added since consolidation,
which is precisely why they are easy to conflate. Do not "correct" that sentence to seventeen.

## The exposure sentence, restated honestly

Exposure (d) in the base record is **unchanged in kind and once again broader in per-action
payload**: one App Logs share now exports sixteen channels rather than fifteen. The added channel
carries `PendingOperation.folderPath` (an IMAP mailbox name is server- or user-authored), folder
display names, and header/provider ids — i.e. it is a **class C** surface, the same class the base
record already defers. It does **not** add a class A (message content) or class B (account address)
surface, and it does not carry secrets.

## Why this does not re-open the row

Two properties make the addition strictly narrower than the deferred corpus the row is about:

1. **It is debug-gated, not always-on.** `BackgroundSyncLogger.logQueue` guards on
   `DebugModeManager.isLoggingEnabled()` before it evaluates its `@autoclosure`, so on a build
   where debug logging is locked nothing is rendered, printed or appended. The base record's
   Channel 2 concern is about ungated-at-the-write persistence; this channel is gated at the write.
   ⚠️ The gate is a **RUNTIME unlock** (a `UserDefaults` flag plus an allowed-user check), **NOT a
   build configuration** — these lines are live on device and TestFlight for an allowed user, which
   is the entire point of gating them this way rather than with `#if DEBUG`. Never describe this
   channel as "a no-op in a shipping build".
2. **It cannot forge another channel's entry.** `logQueue` passes its FULLY RENDERED line through
   `DebugModeManager.escapedForLogLine` once, before both the console echo and the append — the
   `logChatError` precedent. So a mailbox named `"INBOX\n[x] [AUTH] …"` cannot synthesise an AUTH
   entry, cannot truncate a real entry on a channel-filtered read, and cannot survive
   `clear(channel: .queue)`. Pinned by `AppLogStoreTests` ("A newline in a logQueue line cannot
   forge another channel's entry").
   ⚠️ This does **not** upgrade the base record's forgery note into an unqualified absolute. That
   note's own correction stands: whole-line escaping is closed **for `logChatError` and now for
   `logQueue`**, never as "no user-authored text can forge a channel" — the other fourteen channels
   still leave escaping to their call sites.

## Registry obligation for the next channel

`AppLogStoreTests.debugGatedWriters` is the registry four gating tests iterate; a new debug-gated
channel that is not added there is silently untested by all four. `.queue` was registered with its
`backgroundSyncLoggerFunction` name (`"logQueue"`) in the same commit. Do the same for the
seventeenth.

## Search terms

`AppLogChannel.queue`; `QUEUE` tag; `BackgroundSyncLogger.logQueue`; sixteenth channel; sixteen
channels; five always-on eleven debug-gated; `debugGatedWriters`; `escapedForLogLine`; whole-line
escaping; channel forgery; `IOS-QUEUE-008`; `[MoveTrace]`; `queueLog`; `deltaMoveTraceLog`;
`upsertInsertedIdSummary`; runtime unlock not build configuration; `DebugModeManager.isLoggingEnabled`

## 2026-09-05 — one of `.queue`'s three writers is gone; the channel is not

`SyncEngineDeltaSync.deltaMoveTraceLog` — named above under "What changed" as one of the `.queue`
channel's three call sites — was **removed 2026-09-05** together with all six
`[MoveTrace] deltaSync` lines it carried (PR #113, round 6b; owner decision, deletion-first). The
row above is superseded on that point only and is kept as history: `.queue`'s writers are now
**two**, `AccountManagerQueue.queueLog` and the full-sync upsert line, both still routed through
`BackgroundSyncLogger.logQueue`.

Nothing else in this record changes. `AppLogChannel` still has **sixteen** cases and the gating
split is still **5 always-on / 11 debug-gated** — a channel is not deleted when a writer is; `.queue`
still carries the drain's lane composition and the full-sync move-convergence line in ONE ordered
artifact, which is the property the record exists to defend. The exposure restatement (class C:
`folderPath`, folder display names, header/provider ids), the runtime-unlock warning, the whole-line
escaping note, and the `debugGatedWriters` registry obligation all stand unchanged.

Why the writer went: `logQueue` → `AppLogStore.append` enqueues file I/O on an independent serial
queue that no SQLite `ROLLBACK` retracts, and all six of those lines were emitted from INSIDE the
delta arm's `dbPool.write` closure — so a rolled-back batch still left a durable line claiming it had
inserted, removed or skipped a message. A debug instrument may miss a line; it must not lie. Detail:
`ios-queue-008.md`'s 2026-09-05 section, which also carries the standing in-write-emission census.

Search terms for this amendment: `deltaMoveTraceLog` removed 2026-09-05; two `.queue` writers not
three; in-write emission survives rollback; deletion-first; PR #113 round 6b.

## 2026-09-05 — the upsert line's two replaced-row `inserted` contributions now have witnesses

`SyncEngineFullSyncUpsertDiagnosticTests.fullSyncUpsertNamesTheDraftDedupReplacementUnderInserted`
and `SyncEngineFullSyncUpsertDiagnosticTests.fullSyncUpsertNamesThePreSyncReplacementUnderInserted`
pin the invariant that the `[MoveTrace] fullSync upsert[<folder>]` line names, under `inserted`,
every row full sync CREATED — including the canonical row that replaced a DraftDedup placeholder and
the canonical row that replaced a drifted pre-sync inbox row — never reports either under
`reclaimed`, and names the deleted old ids nowhere. Each case is RED when its own
`insertedIds.append(header.id)` is deleted, and the DraftDedup case is RED again when that append is
rerouted to `reclaimedIds`; until 2026-09-05 either edit passed every test in the tree.
