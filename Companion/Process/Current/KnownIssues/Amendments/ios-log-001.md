# IOS-LOG-001

> **Post-freeze amendment to a BASE-register record.** Added 2026-09-10 through the amendment
> surface described in `Scripts/compact_known_issues.rb`. The base record's own bytes are
> hash-pinned and are **not** edited by this file: `Companion/Process/Current/KnownIssues/ios-log-001.md`
> keeps its original row, its original SHA-256 and its 2026-08-13 amendment block.

- Register classification: **superseded by owner decision, 2026-09-10 — the sweep this row
  recorded as "deliberately not opened" is DONE.** GitHub `TabMail/tabmail-ios#72`; the owner asked
  for the diagnostics to be folded into the debug-gated persisted log, and chose ALL prints (gated
  and ungated) over the ungated-only scope.
- Amends: this row's status, its closure elements (b) and (e), and its `TabMail/Views/` +
  `TabMail/Services/` corpora — which the sweep covers together with the rest of the `TabMail/`
  target this row never measured (`Providers/`, `ViewModels/`, `App/`, …).

## What changed

Every console `print(` in the `TabMail/` target now goes through ONE façade,
`BackgroundSyncLogger.logDebug(_ message: @autoclosure () -> String)`, on the new debug-gated
`AppLogChannel.debug` (tag `DEBUG`) — gate, then render, then whole-line `escapedForLogLine`, then
console echo, then `AppLogStore.append` — except for three shapes that stay a bare `print`:

| shape | sites | treatment |
|---|---|---|
| ungated, outside any database context | 1,374 | → `logDebug` |
| already gated (`if`/`guard`/`#if DEBUG`), outside any database context | 593 | → `logDebug`, inside its existing gate |
| ungated, inside a database write context (write / migration closure, or a func handed a `Database`) | 80 | console only: `if DebugModeManager.isLoggingEnabled() {` on its own line |
| gated only in a branch condition (`if x, <gate> {`, `if <gate>, x {`, `} else if <gate> {`), inside a database context | 6 | console only: 5 gates moved into the arm body after checking each arm only logs; `SyncEngineDeltaSync`'s drafts-folder arm keeps its condition and gains the canonical gate inside |
| already canonically gated, inside a database context | 28 | unchanged |
| `🚨 UNGATED BY DECISION` (`AccountOperationExecutor`, each with an always-on `logError` sibling) | 3 | unchanged |

Measured by a brace- and string-aware classifier over base `53003bcd6` (not committed). ⚠️ These
integers are a lead pinned to that base, not a bound (`MIS-044`); the enforcement is the test below.

**Corrected before merge (2026-09-10, correctness review).** The classifier matched a `Database`
parameter but not `GRDB.Database`, so `NSEDataBridge.insertNewHeaderFromStaging`'s `Created header`
line, which runs inside `inSavepoint` within `dbPool.write`, was first routed to `logDebug`. It is
now console-only. The classifier also read `SyncEngineDeltaSync`'s comma-list gate as ungated, and
the five gates moved out of branch conditions came from its "already gated" row. So the first
draft's 1,375 / 80 / 33 are the 1,374 / 80 / 6 / 28 above, where 80 is 79 truly ungated plus
`NSEDataBridge`. Root `MIS-007`, instance 88.

**Why a database context stays console-only:** `logDebug` appends to a file that no SQLite
`ROLLBACK` retracts, so a line emitted inside a write can claim a write that never committed (root
rule 12's 2026-09-05 addendum; `ios-queue-008.md`, 2026-09-05). A gated console `print` cannot
outlive the rollback in any artifact.

## The closure elements this falsifies

- **(b) "The app persists none of it"** — now FALSE for an unlocked allowed user
  (`DebugModeManager.isEmailAllowed`: the `tabmail.ai` domain plus one team address). Those lines
  are written to `tabmail.log` and leave the device when that user shares App Logs. For every other
  user the gate is closed: the autoclosure is never evaluated, nothing is printed, nothing is
  written — strictly narrower than the ungated `stdout` exposure this row accepted. The
  persisted-channel half belongs to `IOS-LOG-002`, whose 2026-09-10 amendment records it.
- **(e) "a large, entirely mechanical, wholly unreviewed diff"** — the owner accepted the diff
  size explicitly (2026-09-10).

## Enforcement

`DiagnosticPrintGateTests.everyAppTargetSinkIsGated` scans every Swift file under `TabMail/` with
`RenderPathLogSinkTests.lex` — canonical gate spellings only, fail-closed — and fails on any
`print(`, `NSLog(` or `os_log(` (bare, or `Swift.` / `Foundation.` qualified) that is neither
lexically gated nor one of EXACTLY three `🚨 UNGATED BY DECISION` sinks, each pinned by file and
message prefix. The always-on façade files (`BackgroundSyncLogger.swift`, `AuthDiagnostics.swift`)
are its only exclusions.

`DiagnosticPrintGateTests.noDebugLogLineInsideADatabaseWriteContext` fails on any `logDebug` call
lexically inside a database write context, which is one of three shapes:
- a trailing closure handed to a write callee, whatever it calls its parameter (`db`, `conn`,
  `dbConn`, `$0`, `_`). The callees are GRDB's write entry points plus every function the target
  declares with a `(Database) … ->` parameter (`retryWrite`, `registerTimedMigration`,
  `enqueueDurableWrite`, …), derived from the source;
- a closure whose parameter is `db` or typed `Database` / `GRDB.Database`, its return type on one
  line or several;
- a `func` / `init` with a parameter of type `Database` or `GRDB.Database`.

A trailing closure handed to a read (`read`, `asyncRead`, `ValueObservation.tracking`, …) is
excluded. It sees over 500 such contexts in the target, and it was RED on the `NSEDataBridge` line
before the fix. It is lexical, with two limits:
- A closure passed inside parentheses has no callee for the scan. `write({ conn in … })` is seen
  only if its parameter is `db` or typed `Database`, and `read({ db in … })` counts as a write
  context, so a `logDebug` added there fails the test although a read cannot roll back.
- It does not follow calls: a helper with no `Database` parameter that logs, called from inside a
  write, is not seen. A census of small same-file `logDebug` helpers called from those contexts
  found none.

**Corrected before merge, second review round (2026-09-11).** The first version of that test
recognised a write closure only by a parameter named `db` or typed `Database`, with its return type
on one line. Twenty write closures in the target spell it otherwise: `conn` / `dbConn` in the demo
seeders, `$0` in `DraftStore` and the outbox previews, and a `db -> (…) in` return type across lines
in `AccountManagerActions`. None held a `logDebug`, so the test was green for the wrong reason. It now
also keys on the callee. A callee NAME pattern (`write|transaction|…`) was tried and rejected: at the
tip it matched SwiftUI `.transaction {}`, the intention queue's `enqueueWrite* { () async in }`, type
annotations and a `for` loop over `transactionMetrics`. Root `MIS-007`, instance 89.

**Narrowed before merge, third review round (2026-09-11).** The callee rule finds a callee only for a
trailing closure, but this section said every closure handed to a write callee was seen and every
read excluded. The limit is now stated above. GRDB's `writeInTransaction` and `writePublisher` were
added to the write entry points; the target uses neither. Root `MIS-007`, instance 90.

## NOT closed by this — the residual, stated by property

- **Work computed BEFORE the call still runs with the gate closed.** The autoclosure defers the
  interpolation, not a `let` above it. `AccountManagerState.setSyncPhase` / `clearSyncPhases` /
  `lastSyncCompletedAt` — the site #72 measured at ~2 lines/second on the main actor — were rewritten
  so their `split` and `String(describing:)` render inside the autoclosure. A lexical census of
  `let`/`var` bindings whose every later use in the enclosing scope sits inside a `logDebug`
  argument found **224** candidates at the transform (mostly timing values and `if let` decode
  bindings); the rest are unchanged. The census over-counts (an `if let` binding also guards its
  body) and is not asserted exhaustive.
- **The NSE and `Shared/` are unchanged, because the two processes persist to different files.** The
  main app writes `tabmail.log` (`AppLogStore`, 32 MB cap). The notification service extension writes
  `nse.log` (`NSELog` → `NSELogStore`, App Group container, 3 MB cap, its own
  `nse.debugLoggingEnabled` gate). Every rewritten site is in `TabMail/`, runs only in the app and
  writes only `tabmail.log`; nothing here writes `nse.log`. The `TabMailNotificationService/` target
  has no bare `print`, `NSLog` or `os_log`. `Shared/` compiles into BOTH targets, so it can reach
  neither `BackgroundSyncLogger.logDebug` (app only) nor `NSELog` (NSE only). ⚠️ `NSELogStore` IS
  reachable from `Shared/`, and calling it there would put app-process lines into `nse.log`: folding
  `Shared/` needs a per-process sink, not a direct call. Its 32 prints were already `#if DEBUG` (32 of
  32) and are unchanged. (This bullet first said only that `Shared/` compiles into the NSE; corrected
  before merge, 2026-09-11, after the owner noted the two files.)

## Search terms

`logDebug`; `AppLogChannel.debug`; `DEBUG` tag; #72; ungated print sweep; `DiagnosticPrintGateTests`;
console-only gate inside a database write; `🚨 UNGATED BY DECISION`; autoclosure defers
interpolation not a preceding `let`; `setSyncPhase`
