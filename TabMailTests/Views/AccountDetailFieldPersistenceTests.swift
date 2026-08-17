/* This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at https://mozilla.org/MPL/2.0/. */

import Foundation
import GRDB
import Synchronization
import Testing
@testable import TabMail

/// Pins the user-visible contract for editable account fields:
///
/// - typing changes presentation immediately;
/// - persistence never blocks the MainActor behind the single GRDB writer;
/// - rapid edits reach disk in accepted order, so the last value wins; and
/// - only a failure of the latest value for that field is shown to the user.
@Suite("Account field persistence is ordered and non-blocking", .serialized, .processGlobalState)
@MainActor
struct AccountDetailFieldPersistenceTests {
    private struct Environment {
        let pool: DatabasePool
        let database: PrioritizedDatabase
        let directory: URL
        let accountId: String
        let previousDatabase: AppDatabase?
    }

    @MainActor
    private final class Heartbeat {
        private(set) var ticks = 0
        private var task: Task<Void, Never>?

        func start() {
            task = Task { @MainActor in
                while !Task.isCancelled {
                    ticks += 1
                    try? await Task.sleep(for: .milliseconds(20))
                }
            }
        }

        func stop() {
            task?.cancel()
            task = nil
        }
    }

    private actor Gate {
        private var isOpen = false
        private var waiters: [CheckedContinuation<Void, Never>] = []

        func wait() async {
            guard !isOpen else { return }
            await withCheckedContinuation { waiter in
                waiters.append(waiter)
            }
        }

        func open() {
            guard !isOpen else { return }
            isOpen = true
            let parked = waiters
            waiters.removeAll()
            for waiter in parked { waiter.resume() }
        }
    }

    private enum ProbeError: Error {
        case refused
    }

    /// Represents one disposable AccountDetailView lifetime. The production
    /// persistence owner is intentionally injected rather than owned here.
    @MainActor
    private struct AccountDetailLifetime {
        let persistence: AccountFieldPersistenceStore

        func setDisplayName(_ value: String, environment: Environment) -> Task<Void, Never> {
            persistence.accept(
                accountId: environment.accountId,
                field: .displayName,
                value: .text(value),
                persist: {
                    try await AccountFieldPersistenceStore.persist(
                        accountId: environment.accountId,
                        field: .displayName,
                        value: .text(value),
                        database: environment.database
                    )
                }
            )
        }
    }

    private func makeEnvironment() throws -> Environment {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("account-field-persistence-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)

        var configuration = Configuration()
        configuration.foreignKeysEnabled = true
        configuration.journalMode = .wal
        configuration.busyMode = .timeout(5)
        let pool = try DatabasePool(
            path: directory.appendingPathComponent("test.sqlite").path,
            configuration: configuration
        )
        try AppDatabase.runMigrations(on: pool)
        let appDatabase = try AppDatabase(dbPool: pool)
        let previousDatabase = AppDatabase.shared.withLock { current -> AppDatabase? in
            let previous = current
            current = appDatabase
            return previous
        }

        var account = Account(
            emailAddress: "user@example.com",
            displayName: "Original",
            provider: .gmail
        )
        account.id = "acc1"
        try pool.write { db in try account.insert(db) }

        return Environment(
            pool: pool,
            database: PrioritizedDatabase(pool: pool),
            directory: directory,
            accountId: account.id,
            previousDatabase: previousDatabase
        )
    }

    private func finish(_ environment: Environment) {
        AppDatabase.shared.withLock { $0 = environment.previousDatabase }
        TestDatabaseTeardown.retire(pool: environment.pool, directory: environment.directory)
    }

    /// Holds the sole writer on a dedicated GCD thread. The continuation resumes
    /// only after GRDB has entered the write closure, so the account-field write
    /// must genuinely wait for that same serialized writer.
    private func holdWriter(_ pool: DatabasePool, for interval: TimeInterval) async {
        await withCheckedContinuation { (acquired: CheckedContinuation<Void, Never>) in
            DispatchQueue.global(qos: .utility).async {
                try? pool.write { _ in
                    acquired.resume()
                    Thread.sleep(forTimeInterval: interval)
                }
            }
        }
    }

    /// Deterministically holds the sole writer until the caller signals release.
    private func holdWriter(_ pool: DatabasePool, until release: DispatchSemaphore) async {
        await withCheckedContinuation { (acquired: CheckedContinuation<Void, Never>) in
            DispatchQueue.global(qos: .utility).async {
                try? pool.write { _ in
                    acquired.resume()
                    release.wait()
                }
            }
        }
    }

    @Test("Rapid edits update immediately, suspend behind the writer, and persist last-write-wins")
    func rapidEditsStayResponsiveAndOrdered() async throws {
        let environment = try makeEnvironment()
        defer { finish(environment) }

        let heartbeat = Heartbeat()
        heartbeat.start()
        try await Task.sleep(for: .milliseconds(80))
        await holdWriter(environment.pool, for: 0.35)

        let persistence = AccountFieldPersistenceStore()
        var displayedName = "Original"
        var latestTask: Task<Void, Never>?
        let ticksBefore = heartbeat.ticks
        let start = CFAbsoluteTimeGetCurrent()

        for value in ["A", "Al", "Alice"] {
            displayedName = value
            latestTask = persistence.accept(
                accountId: environment.accountId,
                field: .displayName,
                value: .text(value),
                persist: {
                    try await AccountFieldPersistenceStore.persist(
                        accountId: environment.accountId,
                        field: .displayName,
                        value: .text(value),
                        database: environment.database
                    )
                }
            )
        }

        // No await has occurred since the three applies: the rendered state is
        // already the last keystroke even though the writer is still occupied.
        #expect(displayedName == "Alice")

        await latestTask?.value
        let wallMs = Int((CFAbsoluteTimeGetCurrent() - start) * 1000)
        let ticksDuring = heartbeat.ticks - ticksBefore
        heartbeat.stop()

        let storedName = try await environment.pool.read { db in
            try Account.fetchOne(db, key: environment.accountId)?.displayName
        }
        print("[AccountFieldPersistence] wall=\(wallMs)ms ticks=\(ticksDuring) stored=\(storedName ?? "nil")")

        #expect(wallMs >= 250, "test did not create a real serialized-writer wait")
        #expect(
            ticksDuring >= 8,
            "main actor was starved during a \(wallMs)ms writer wait (\(ticksDuring) ticks)"
        )
        #expect(storedName == "Alice")
    }

    @Test("Ordered queue suppresses stale failures but reports the latest failed value")
    func latestFailureIsHonest() async {
        let persistence = AccountFieldPersistenceStore()
        let gate = Gate()
        let events = Mutex<[String]>([])
        var displayedName = "Original"

        displayedName = "A"
        _ = persistence.accept(
            accountId: "acc1",
            field: .displayName,
            value: .text("A"),
            persist: {
                events.withLock { $0.append("A:start") }
                await gate.wait()
                events.withLock { $0.append("A:failed") }
                throw ProbeError.refused
            }
        )
        displayedName = "Al"
        let second = persistence.accept(
            accountId: "acc1",
            field: .displayName,
            value: .text("Al"),
            persist: {
                events.withLock { $0.append("Al:start") }
                events.withLock { $0.append("Al:succeeded") }
            }
        )

        #expect(displayedName == "Al")
        await gate.open()
        await second.value

        #expect(events.withLock { $0 } == ["A:start", "A:failed", "Al:start", "Al:succeeded"])
        #expect(
            persistence.failures(accountId: "acc1").isEmpty,
            "the failed A value was already superseded by Al"
        )

        displayedName = "Alice"
        let latest = persistence.accept(
            accountId: "acc1",
            field: .displayName,
            value: .text("Alice"),
            persist: { throw ProbeError.refused }
        )
        #expect(displayedName == "Alice")
        await latest.value

        #expect(
            persistence.failures(accountId: "acc1").map(\.field) == [.displayName],
            "the latest failed value must produce the visible retry state"
        )
    }

    @Test("Two view lifetimes share one blocked-writer ordering owner")
    func navigationLifetimeDoesNotResetAcceptedOrder() async throws {
        let environment = try makeEnvironment()
        defer { finish(environment) }

        let persistence = AccountFieldPersistenceStore()
        let releaseWriter = DispatchSemaphore(value: 0)
        await holdWriter(environment.pool, until: releaseWriter)

        // First AccountDetailView lifetime accepts a value and disappears while
        // its write is still blocked. The NavigationStore-owned persistence
        // object survives that disposable view.
        let first: Task<Void, Never>
        do {
            let firstLifetime = AccountDetailLifetime(persistence: persistence)
            first = firstLifetime.setDisplayName("First", environment: environment)
        }

        // A newly-created view accepts the later value through the SAME owner.
        let second: Task<Void, Never>
        do {
            let secondLifetime = AccountDetailLifetime(persistence: persistence)
            second = secondLifetime.setDisplayName("Second", environment: environment)
        }

        releaseWriter.signal()
        await first.value
        await second.value

        let storedName = try await environment.pool.read { db in
            try Account.fetchOne(db, key: environment.accountId)?.displayName
        }
        #expect(storedName == "Second")
    }

    @Test("Navigation refresh preserves pending value and reconciles after commit")
    func refreshKeepsCausalOverlayUntilDiskObservation() async throws {
        let environment = try makeEnvironment()
        defer { finish(environment) }

        let navigationStore = NavigationStore()
        await navigationStore.refresh()
        #expect(navigationStore.accounts.first?.displayName == "Original")

        navigationStore.accounts[0].displayName = "Optimistic"
        let writeStarted = Gate()
        let releaseWrite = Gate()
        let write = navigationStore.accountFieldPersistence.accept(
            accountId: environment.accountId,
            field: .displayName,
            value: .text("Optimistic"),
            persist: {
                await writeStarted.open()
                await releaseWrite.wait()
                try await AccountFieldPersistenceStore.persist(
                    accountId: environment.accountId,
                    field: .displayName,
                    value: .text("Optimistic"),
                    database: environment.database
                )
            }
        )
        await writeStarted.wait()

        // The database still says Original. A real NavigationStore refresh must
        // not overwrite the accepted presentation while persistence is pending.
        await navigationStore.refresh()
        #expect(navigationStore.accounts.first?.displayName == "Optimistic")
        #expect(navigationStore.accountFieldPersistence.hasOutstandingValues)

        await releaseWrite.open()
        await write.value

        // Even after commit, a stale snapshot remains overlaid until a refresh
        // positively observes the committed value. This call observes it.
        await navigationStore.refresh()
        #expect(navigationStore.accounts.first?.displayName == "Optimistic")
        #expect(!navigationStore.accountFieldPersistence.hasOutstandingValues)

        // Once reconciled, later database truth is no longer pinned by an old edit.
        try await environment.pool.write { db in
            try db.execute(
                sql: "UPDATE account SET displayName = ? WHERE id = ?",
                arguments: ["Remote", environment.accountId]
            )
        }
        await navigationStore.refresh()
        #expect(navigationStore.accounts.first?.displayName == "Remote")
    }

    @Test("Failures remain per account and field, and each retry clears only on success")
    func fieldFailuresAreStableAndIndependentlyRetryable() async {
        let persistence = AccountFieldPersistenceStore()
        let nameAttempts = Mutex(0)
        let emailAttempts = Mutex(0)

        let name = persistence.accept(
            accountId: "acc1",
            field: .displayName,
            value: .text("Alice"),
            persist: {
                let attempt = nameAttempts.withLock { count in
                    count += 1
                    return count
                }
                if attempt == 1 { throw ProbeError.refused }
            }
        )
        let email = persistence.accept(
            accountId: "acc1",
            field: .emailAddress,
            value: .text("alice@example.com"),
            persist: {
                let attempt = emailAttempts.withLock { count in
                    count += 1
                    return count
                }
                if attempt == 1 { throw ProbeError.refused }
            }
        )
        await name.value
        await email.value

        #expect(persistence.failures(accountId: "acc1").map(\.field) == [.displayName, .emailAddress])

        guard let nameFailure = persistence.failures(accountId: "acc1").first(where: {
            $0.field == .displayName
        }), let nameRetry = persistence.retry(nameFailure.key) else {
            Issue.record("display-name failure was not retryable")
            return
        }
        #expect(
            persistence.failures(accountId: "acc1").first(where: { $0.field == .displayName })?.isRetrying == true
        )
        await nameRetry.value
        #expect(persistence.failures(accountId: "acc1").map(\.field) == [.emailAddress])

        guard let emailFailure = persistence.failures(accountId: "acc1").first,
              let emailRetry = persistence.retry(emailFailure.key) else {
            Issue.record("email failure was not retryable")
            return
        }
        await emailRetry.value
        #expect(persistence.failures(accountId: "acc1").isEmpty)
    }

    @Test("Editable field mapping persists display name, email, username, signature, and placement")
    func representativeCallersWriteTheirOwnedColumns() async throws {
        let environment = try makeEnvironment()
        defer { finish(environment) }

        guard let original = try await environment.pool.read({ db in
            try Account.fetchOne(db, key: environment.accountId)
        }) else {
            Issue.record("seed account disappeared")
            return
        }

        let persistence = AccountFieldPersistenceStore()
        let changes: [(AccountEditableField, AccountEditableValue)] = [
            (.displayName, .text("Alice")),
            (.emailAddress, .text("alice@example.com")),
            (.imapUsername, .text("imap-user")),
            (.signature, .text("Regards")),
            (.signatureBelowQuote, .boolean(true)),
        ]
        var latest: Task<Void, Never>?
        for (field, value) in changes {
            latest = persistence.accept(
                accountId: environment.accountId,
                field: field,
                value: value,
                persist: {
                    try await AccountFieldPersistenceStore.persist(
                        accountId: environment.accountId,
                        field: field,
                        value: value,
                        database: environment.database
                    )
                }
            )
        }
        await latest?.value

        // A stale refresh projects every accepted caller value, including the
        // optional text fields and the Boolean signature-placement field.
        guard let projected = persistence.applyingOverlay(to: [original]).first else {
            Issue.record("projected account disappeared")
            return
        }
        #expect(projected.displayName == "Alice")
        #expect(projected.emailAddress == "alice@example.com")
        #expect(projected.imapUsername == "imap-user")
        #expect(projected.signature == "Regards")
        #expect(projected.signatureBelowQuote)
        #expect(persistence.hasOutstandingValues)

        guard let stored = try await environment.pool.read({ db in
            try Account.fetchOne(db, key: environment.accountId)
        }) else {
            Issue.record("seed account disappeared")
            return
        }
        #expect(stored.displayName == "Alice")
        #expect(stored.emailAddress == "alice@example.com")
        #expect(stored.imapUsername == "imap-user")
        #expect(stored.signature == "Regards")
        #expect(stored.signatureBelowQuote)
        _ = persistence.applyingOverlay(to: [stored])
        #expect(!persistence.hasOutstandingValues)
        #expect(AccountEditableField.allCases.map(\.displayLabel) == [
            "Name", "Email", "Signature placement", "IMAP username", "Signature",
        ])
    }
}
