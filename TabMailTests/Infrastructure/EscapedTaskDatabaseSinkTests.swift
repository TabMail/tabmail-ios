/* This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at https://mozilla.org/MPL/2.0/. */

import Foundation
import GRDB
import Synchronization
import Testing
@testable import TabMail

/// Pins the invariant that a `Task` which escapes a database test cannot take
/// down the test process.
///
/// The system property under test is **not** "a sink object exists". It is:
/// *after any database test's standard capture / install / restore cycle,
/// `AppDatabase.shared` still holds a usable database, so a fire-and-forget
/// production task that resumes after teardown reads `AppDatabase.rawPool`
/// instead of tripping its force-unwrap.* When that property was violated the
/// process died with `EXC_BREAKPOINT`, and xcodebuild silently dropped every
/// test that had not run yet while still printing a green total and exiting 0.
///
/// Both tests recreate the precondition honestly — `AppDatabase.shared` nil,
/// which is exactly what an early test observes because the host app publishes
/// its database from a `Task.detached` — and then replay a database test through
/// the same entry point every annotated suite goes through
/// (`ProcessGlobalTestState.withLock`, the implementation behind
/// `.processGlobalState`). Neither test names the sink, so any other remedy that
/// upholds the same property would keep them green.
@Suite("Escaped task vs. AppDatabase teardown", .serialized, .processGlobalState)
struct EscapedTaskDatabaseSinkTests {
    /// Opens exactly once and resumes everyone parked on it. Lets the escaped
    /// task be created *inside* the simulated test body — where production
    /// creates it — while guaranteeing it only touches the database *after*
    /// teardown, with no sleeps and no timing guesses.
    private actor Gate {
        private var isOpen = false
        private var waiters: [CheckedContinuation<Void, Never>] = []

        func open() {
            isOpen = true
            let parked = waiters
            waiters = []
            for waiter in parked { waiter.resume() }
        }

        func wait() async {
            if isOpen { return }
            await withCheckedContinuation { waiters.append($0) }
        }
    }

    /// Records that the escaped task really did read the database, so a green
    /// result can never be vacuous. An actor rather than a `Mutex` because a
    /// non-copyable `Mutex` local cannot be captured by `Task.detached`'s
    /// `sending` closure.
    private actor Probe {
        private(set) var reachedTheDatabase = false

        func recordReachedTheDatabase() { reachedTheDatabase = true }
    }

    /// Builds a throwaway fixture database of the kind every DB test installs.
    private func makeFixture() throws -> (database: AppDatabase, pool: DatabasePool, dir: URL) {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        var config = Configuration()
        config.foreignKeysEnabled = true
        let pool = try DatabasePool(
            path: dir.appendingPathComponent("fixture.sqlite").path,
            configuration: config
        )
        return (try AppDatabase(dbPool: pool), pool, dir)
    }

    @Test("A production task that escapes a database test and reaches AppDatabase.rawPool after that test's teardown must not terminate the test process")
    func escapedTaskReachingTheDatabaseAfterTeardownDoesNotKillTheProcess() async throws {
        let publishedBeforeTest = AppDatabase.shared.withLock { $0 }
        defer {
            // Restore only a real prior database. If nothing was published yet,
            // leaving whatever is published now in place is the correct end
            // state — re-arming nil is the very defect under test.
            if let publishedBeforeTest {
                AppDatabase.shared.withLock { $0 = publishedBeforeTest }
            }
        }

        let fixture = try makeFixture()
        defer {
            TestDatabaseTeardown.closeThenUnlinkNow(pool: fixture.pool, directory: fixture.dir)
        }

        let startGate = Gate()
        let finishGate = Gate()
        let probe = Probe()

        // Arrange: the process state that produces the crash — the host app's
        // asynchronous publish has not landed, so a database test starting now
        // observes nil.
        AppDatabase.shared.withLock { $0 = nil }

        // Act: replay a database test verbatim. Enter the scope every annotated
        // suite enters, swap in the fixture the way ~100 `makeTestDB` helpers do,
        // spawn the fire-and-forget task production spawns from inside a test's
        // call stack (`queueSend` → `Task { drainOutbox() }`, `DraftStore.save`
        // → `Task { redriveDurableQueue() }`), and tear down with the canonical
        // `$0 = previous` restore used at 300+ sites.
        try await ProcessGlobalTestState.withLock {
            let previous = AppDatabase.shared.withLock { current -> AppDatabase? in
                let prev = current
                current = fixture.database
                return prev
            }

            Task.detached {
                await startGate.wait()
                _ = AppDatabase.rawPool
                await probe.recordReachedTheDatabase()
                await finishGate.open()
            }

            AppDatabase.shared.withLock { $0 = previous }
        }

        // The escaped task resumes here: after teardown, outside the trait's
        // scope — precisely where `.processGlobalState` cannot protect anything.
        await startGate.open()
        await finishGate.wait()

        // Reaching this line at all is the assertion: a trap inside the escaped
        // task would have killed the process instead of failing this test.
        // (Both values are read out first — a non-copyable `Mutex` cannot be
        // evaluated inside an `#expect` expansion.)
        let didReachTheDatabase = await probe.reachedTheDatabase
        let publishedAfterTeardown = AppDatabase.shared.withLock { $0 }
        #expect(
            didReachTheDatabase,
            "the escaped task must actually have read AppDatabase.rawPool — otherwise this test passes vacuously"
        )
        #expect(
            publishedAfterTeardown != nil,
            "teardown must not leave AppDatabase.shared nil: a late escaped task would trip rawPool's force-unwrap and kill the test process"
        )
    }

    @Test("A database test entering the process-global scope can never capture a nil `previous`, so its teardown can never re-arm a nil AppDatabase.shared")
    func capturedPreviousIsNeverNil() async throws {
        let publishedBeforeTest = AppDatabase.shared.withLock { $0 }
        defer {
            if let publishedBeforeTest {
                AppDatabase.shared.withLock { $0 = publishedBeforeTest }
            }
        }

        let fixture = try makeFixture()
        defer {
            TestDatabaseTeardown.closeThenUnlinkNow(pool: fixture.pool, directory: fixture.dir)
        }

        AppDatabase.shared.withLock { $0 = nil }

        let capturedPreviousWasNil = Mutex<Bool>(true)
        try await ProcessGlobalTestState.withLock {
            let previous = AppDatabase.shared.withLock { current -> AppDatabase? in
                let prev = current
                current = fixture.database
                return prev
            }
            let wasNil = previous == nil
            capturedPreviousWasNil.withLock { $0 = wasNil }
            AppDatabase.shared.withLock { $0 = previous }
        }

        let previousWasNil = capturedPreviousWasNil.withLock { $0 }
        #expect(
            !previousWasNil,
            "a database test captured nil as `previous`; restoring it re-arms a nil AppDatabase.shared that any escaped production task turns into a process kill"
        )
    }
}
