/* This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at https://mozilla.org/MPL/2.0/. */

import UIKit
import GRDB
import Synchronization

/// Guards against RUNNINGBOARD `0xdead10cc` kills (app suspended while holding
/// a SQLite file lock) by posting GRDB's `Database.suspendNotification` just
/// before the process is actually suspended, and `Database.resumeNotification`
/// whenever execution legitimately resumes (foreground return, silent push,
/// BGTask launch).
///
/// All long-lived stores (`AppDatabase`, `SearchIndex`, `MemoryIndex`,
/// `BodyAssetStore`, NSE staging queues) opt in via
/// `Configuration.observesSuspensionNotifications = true`. While suspended,
/// GRDB releases/refuses locks: lock-acquiring accesses throw a
/// `DatabaseError` with code `SQLITE_ABORT` or `SQLITE_INTERRUPT` — EXCEPT
/// reads on WAL databases, which keep working. Every store in this app is
/// crash-tolerant by design (idempotent maintenance, self-healing queues,
/// persist-then-retry user intention), so an aborted transaction at the
/// suspension instant is strictly better than the previous behavior: the
/// whole process being SIGKILLed mid-write. See ADR-IOS-041.
///
/// Timing is the load-bearing detail: the suspend signal is NOT posted at
/// `didEnterBackground`. It is posted from the **expiration handler** of a
/// `beginBackgroundTask` assertion taken at backgrounding. iOS expires all of
/// an app's background task assertions together when the app-wide background
/// budget runs out — i.e. our handler fires at the same deadline as the
/// existing `backfill-grace` / `ai-job-*` assertions, just before real
/// suspension. So all in-flight work keeps its full grace window and behavior
/// only changes in the final instant, where today the app would be killed.
@MainActor
final class DatabaseSuspension {
    static let shared = DatabaseSuspension()

    /// Active "db-quiesce" background task assertion. `.invalid` = no window armed.
    private var quiesceTask: UIBackgroundTaskIdentifier = .invalid

    /// Count of in-flight background work units (silent push, BGAppRefresh,
    /// BGProcessing). While > 0, completion of one unit does not arm the
    /// quiesce window — the last one out arms it.
    private var backgroundWorkCount = 0

    /// Thread-safe mirror of "is the app foreground/active?", maintained by the
    /// main-actor lifecycle observers. Read from the **off-main** BGTask
    /// expiration handlers (`postSuspendImmediately`), which must not touch
    /// main-thread-only `UIApplication.applicationState`. 0xdead10cc only
    /// threatens a backgrounded app, so the suspend backstop is gated on this.
    /// `nonisolated` (a `Sendable` `Mutex`) so the off-main expiration handler
    /// can read it without hopping to the main actor.
    private nonisolated static let appActive = Mutex<Bool>(true)

    private init() {}

    /// Install app lifecycle observers. Call once from
    /// `application(_:didFinishLaunchingWithOptions:)`.
    func start() {
        // Seed the foreground flag from the actual launch state. A BGTask can
        // cold-launch a terminated app into `.background`; a normal launch is
        // `.inactive` transitioning to `.active`. Treat anything but `.background`
        // as active — `didBecomeActive`/`didEnterBackground` keep it accurate after.
        Self.appActive.withLock { $0 = UIApplication.shared.applicationState != .background }
        let nc = NotificationCenter.default
        nc.addObserver(
            forName: UIApplication.didEnterBackgroundNotification,
            object: nil, queue: .main
        ) { _ in
            MainActor.assumeIsolated {
                DatabaseSuspension.shared.appDidEnterBackground()
            }
        }
        nc.addObserver(
            forName: UIApplication.willEnterForegroundNotification,
            object: nil, queue: .main
        ) { _ in
            MainActor.assumeIsolated {
                DatabaseSuspension.shared.appWillEnterForeground()
            }
        }
        // Safety net: resume on activation too. A suspend posted during a
        // transition (or a BGTask that expired just as the app came forward)
        // could otherwise strand the database — `willEnterForeground` only fires
        // on a background→foreground transition, but `didBecomeActive` fires on
        // every activation (incl. returning from a brief interruption).
        nc.addObserver(
            forName: UIApplication.didBecomeActiveNotification,
            object: nil, queue: .main
        ) { _ in
            MainActor.assumeIsolated {
                DatabaseSuspension.shared.appDidBecomeActive()
            }
        }
    }

    // MARK: - App lifecycle

    private func appDidEnterBackground() {
        Self.appActive.withLock { $0 = false }
        // If background work (push/BGTask) is in flight, its endBackgroundWork
        // will arm the window when the last unit finishes.
        guard backgroundWorkCount == 0 else { return }
        armQuiesceWindow()
    }

    private func appWillEnterForeground() {
        Self.appActive.withLock { $0 = true }
        cancelQuiesceWindow()
        resumeDatabases(reason: "foreground")
    }

    private func appDidBecomeActive() {
        Self.appActive.withLock { $0 = true }
        cancelQuiesceWindow()
        resumeDatabases(reason: "didBecomeActive")
    }

    // MARK: - Background work units (silent push, BGTasks)

    /// Mark the start of system-granted background execution. Resumes the
    /// databases (the app may have been suspended-in-place since the last
    /// quiesce) and cancels any pending quiesce window.
    func beginBackgroundWork(_ label: String) {
        backgroundWorkCount += 1
        cancelQuiesceWindow()
        resumeDatabases(reason: label)
    }

    /// Mark the end of a background work unit. When the last unit finishes
    /// and the app is still backgrounded, arms the quiesce window so the
    /// databases get suspended before the process does.
    func endBackgroundWork(_ label: String) {
        backgroundWorkCount = max(0, backgroundWorkCount - 1)
        guard backgroundWorkCount == 0 else { return }
        if UIApplication.shared.applicationState == .background {
            armQuiesceWindow()
        }
    }

    /// Thread-safe immediate suspend for BGTask expiration handlers, which run
    /// off the main actor and must take effect before the process freezes.
    /// `NotificationCenter.post` is synchronous and thread-safe; GRDB observes
    /// it internally. Main-actor bookkeeping follows asynchronously (it only
    /// affects the redundant-post optimization, and posts are idempotent).
    nonisolated static func postSuspendImmediately(reason: String) {
        // 0xdead10cc only threatens a BACKGROUNDED app — iOS freezes the process
        // (possibly mid-SQLite-lock) only when it is not active. A BGTask can run
        // or EXPIRE while the app is in the foreground (user reopened it; debug
        // simulate; foreground-scheduled task). Suspending then would STRAND the
        // database: resume fires only on a foreground TRANSITION (willEnterForeground
        // / didBecomeActive) or the next beginBackgroundWork — none of which happen
        // if the app never left the foreground — so every later write throws
        // "Database is suspended" (ADR-IOS-041). Skip the backstop when active.
        guard !appActive.withLock({ $0 }) else {
            BackgroundSyncLogger.log("DatabaseSuspension SUSPEND skipped (\(reason)) — app is active")
            return
        }
        BackgroundSyncLogger.log("DatabaseSuspension SUSPEND (\(reason))")
        NotificationCenter.default.post(name: Database.suspendNotification, object: nil)
        Task { @MainActor in
            DatabaseSuspension.shared.cancelQuiesceWindow()
        }
    }

    // MARK: - Quiesce window

    private func armQuiesceWindow() {
        guard quiesceTask == .invalid else { return }
        quiesceTask = UIApplication.shared.beginBackgroundTask(withName: "db-quiesce") {
            // Expiration handler — iOS is about to suspend the app.
            MainActor.assumeIsolated {
                DatabaseSuspension.shared.suspendNow(reason: "quiesce window expired")
            }
        }
        if quiesceTask == .invalid {
            // No background time available — suspend right away rather than
            // risk holding a lock into suspension.
            suspendNow(reason: "no background time granted")
        }
    }

    private func cancelQuiesceWindow() {
        guard quiesceTask != .invalid else { return }
        UIApplication.shared.endBackgroundTask(quiesceTask)
        quiesceTask = .invalid
    }

    private func suspendNow(reason: String) {
        BackgroundSyncLogger.log("DatabaseSuspension SUSPEND (\(reason))")
        NotificationCenter.default.post(name: Database.suspendNotification, object: nil)
        cancelQuiesceWindow()
    }

    private func resumeDatabases(reason: String) {
        // Unconditional post — GRDB's resume is an idempotent flag flip, and
        // skipping based on local bookkeeping could lose a race with
        // postSuspendImmediately (leaving databases suspended while running).
        BackgroundSyncLogger.log("DatabaseSuspension RESUME (\(reason))")
        NotificationCenter.default.post(name: Database.resumeNotification, object: nil)
    }
}

extension Error {
    /// True when this is a GRDB write aborted by database suspension
    /// (ADR-IOS-041) — a `DatabaseError` with `SQLITE_ABORT` / `SQLITE_INTERRUPT`
    /// ("Database is suspended"). Such an abort is EXPECTED at the
    /// background-suspension instant and benign: the operation retries on the
    /// next wake (every store is crash-tolerant/idempotent by design). Catch
    /// handlers in background-reachable write paths use this to AVOID logging it
    /// as a failure — it is not one. Genuine write failures still log normally.
    var isDatabaseSuspensionAbort: Bool {
        (self as? DatabaseError)?.isInterruptionError ?? false
    }
}
