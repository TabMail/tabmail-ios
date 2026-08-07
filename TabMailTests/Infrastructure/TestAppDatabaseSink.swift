/* This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at https://mozilla.org/MPL/2.0/. */

import Foundation
import GRDB
@testable import TabMail

/// A process-lifetime, inert `AppDatabase` that keeps `AppDatabase.shared` from
/// ever being observed nil inside the test process.
///
/// **The defect this closes.** Production spawns fire-and-forget tasks that
/// OUTLIVE the test that triggered them — `AccountManager.queueSend` →
/// `Task { drainOutbox() }`, `AccountManager.retryOutboxMessage` →
/// `Task { drainOutbox() }`, `DraftStore.save` → `Task { redriveDurableQueue() }`.
/// Every DB test tears down with `AppDatabase.shared.withLock { $0 = previous }`
/// (300+ sites across 85 files), and `previous` is **nil** for any test that
/// captured it before the host app's *asynchronous* publish (`TabMailApp`
/// publishes from a `Task.detached`). The escaped task then reaches
/// `AppDatabase.rawPool` → `shared.withLock { $0!.dbPool }` → the force-unwrap
/// traps and **the whole test process dies** (`EXC_BREAKPOINT`).
///
/// `.processGlobalState` cannot prevent it: the escaped task runs AFTER the
/// trait's lock is released.
///
/// **Why it matters beyond the crash.** When it fires, xcodebuild prints
/// "Restarting after unexpected exit … totals from previous launches" and the
/// tests that never got to run vanish SILENTLY while the run still reports a
/// green total and exits 0. A commit gate reading that total then verifies far
/// less than it claims.
///
/// **The fix is to make the nil unreachable, not to make the trap survivable.**
/// `AppDatabase.rawPool`'s `$0!` is a deliberate launch invariant — a nil DB at
/// app launch must trap rather than limp along — and is left untouched. Instead
/// the sink is published before any annotated suite's body runs
/// (`ProcessGlobalTestState.withLock`), so the value every test captures as
/// `previous` is non-nil and the canonical `$0 = previous` teardown can never
/// re-introduce nil.
enum TestAppDatabaseSink {
    /// A real, fully migrated, permanently EMPTY on-disk database living in its
    /// own uniquely named temp directory.
    ///
    /// Real (not in-memory, not a stub) because an escaped `drainOutbox()` /
    /// `redriveDurableQueue()` will issue actual queries against it; a fully
    /// migrated schema lets those complete as no-ops instead of throwing.
    /// Never handed to a test as a fixture, kept installed until process exit,
    /// and named distinctly so it cannot be mistaken for any test's own database.
    /// Its exact pool and directory are registered once for close-before-unlink
    /// cleanup at process exit.
    ///
    /// `try!`: a fresh temp SQLite file that fails to open or migrate is a
    /// broken test host, not a condition to paper over — trap loudly at the
    /// point of failure rather than silently reverting to the nil that this
    /// type exists to eliminate.
    static let database: AppDatabase = {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent(
                "TabMailTestAppDatabaseSink-\(UUID().uuidString)",
                isDirectory: true
            )
        try! FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        var config = Configuration()
        config.foreignKeysEnabled = true
        let pool = try! DatabasePool(
            path: dir.appendingPathComponent("sink.sqlite").path,
            configuration: config
        )
        let database = try! AppDatabase(dbPool: pool)
        TestDatabaseTeardown.registerForProcessExit(pool: pool, directory: dir)
        return database
    }()

    /// Publishes the sink if and only if nothing else is published.
    ///
    /// Idempotent and atomic (the check and the store share one `Mutex`
    /// critical section), so it never displaces a test fixture or the host
    /// app's real database. The early return keeps the lazy `database` from
    /// being opened at all on the overwhelmingly common path where a database
    /// is already published.
    static func installIfNeeded() {
        TestDatabaseTeardown.prepareProcess()
        if AppDatabase.shared.withLock({ $0 }) != nil { return }
        let sink = database
        AppDatabase.shared.withLock { current in
            if current == nil { current = sink }
        }
    }
}
