/* This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at https://mozilla.org/MPL/2.0/. */

import Testing
import Foundation
import GRDB
import Synchronization
@testable import TabMail

/// A mail server that refuses an encrypted connection (it offers no STARTTLS on
/// a port where TabMail requires it, `MailTransportPolicy`) must not make the
/// backfill walk reconnect at network rate.
///
/// - The walk's first read of a folder it has not started yet (no walk
///   position: after Settings > Smart Reindex, or a folder never walked) is
///   refused there every time; a walk that picked the same folder straight back
///   after each refusal opened a new connection per iteration, and a call with
///   no deadline (the foreground worker's) never returned.
/// - A folder with a walk position but no UIDVALIDITY stamp passes the
///   walk-start gate, and every range's SEARCH is refused; workers that set
///   each refused range aside and walked on opened about one refused
///   connection per round of workers (they share each refused attempt), down
///   to UID 1, on every call.
///
/// The property: the walk's connections to such a server are bounded by its
/// own retry pace and its workers, never by the folder's size.
///
/// Timing test: run this suite on its own. `.serialized, .processGlobalState`:
/// replaces `AppDatabase.shared` and binds a listening socket via
/// `FakeIMAPServer`.
@Suite("Backfill walk: a server that refuses encryption is not reconnected at network rate",
       .serialized, .processGlobalState)
struct BackfillEncryptionRefusalTests {

    /// How long the walk keeps running after its first connection before the
    /// connections are counted. A walk that reconnects at network rate opens
    /// many in this time against a loopback server.
    private static let observeSeconds = 1.0
    /// How long the test waits for the walk's first connection.
    private static let firstConnectionBoundSeconds = 10.0
    /// How long the walk may take to end once cancelled.
    private static let endBoundSeconds = 10.0
    /// How long a resumed walk of a refused folder may take to end on its own.
    private static let resumedEndBoundSeconds = 30.0
    /// The largest walk chunk (`BackfillProfile.backfillChunkSize`).
    private static let largestChunk = 1000
    /// How many rounds of workers beyond the fixed walk's bound the walk
    /// position holds, at the largest chunk.
    private static let roundsMargin = 4

    /// The resumed folder's walk position for `workers` workers. Workers that
    /// walk on after a refusal share each refused connection attempt, so the
    /// unfixed walk opens about one connection per ROUND of workers
    /// (ranges / workers), not one per range. This position holds at least
    /// `roundsMargin` × (1 + workers) rounds at the largest chunk, so even with
    /// every attempt shared the unfixed walk opens several times the fixed
    /// walk's bound (1 + workers).
    private static func resumedCursor(workers: Int) -> Int {
        largestChunk * workers * (1 + workers) * roundsMargin
    }

    /// Set once by the waiter in `ends(_:within:)`.
    private final class Flag: Sendable {
        private let state = Mutex(false)
        func set() { state.withLock { $0 = true } }
        var isSet: Bool { state.withLock { $0 } }
    }

    /// Whether `call` ended within `bound` seconds. An unstructured waiter sets
    /// a flag that this polls, so a call that never ends returns false here
    /// instead of hanging the test (awaiting `Task.value` ignores the waiter's
    /// own cancellation).
    private static func ends(_ call: Task<Bool, Never>, within bound: TimeInterval) async -> Bool {
        let ended = Flag()
        Task { _ = await call.value; ended.set() }
        let start = ContinuousClock.now
        while !ended.isSet, ContinuousClock.now - start < .seconds(bound) {
            try? await Task.sleep(for: .milliseconds(10))
        }
        return ended.isSet
    }

    private static func signedIn(_ commands: [String]) -> Bool {
        commands.contains { $0.uppercased().contains("LOGIN") || $0.uppercased().contains("AUTHENTICATE") }
    }

    /// An IMAP provider for `server` with no test override: the transport comes
    /// from the port, as in production, and the fake offers no STARTTLS (its
    /// default capabilities have none) on a port that is not 993.
    private static func provider(for server: FakeIMAPServer) -> IMAPProvider {
        IMAPProvider(
            host: "127.0.0.1", port: server.port, username: server.username, password: server.password,
            smtpHost: "127.0.0.1", smtpPort: MailTransportPolicy.smtpImplicitTLSPort)
    }

    @Test("A walk with no deadline connects once to a server that offers no STARTTLS, then does not reconnect at once")
    func refusedServerIsNotReconnectedAtNetworkRate() async throws {
        let (pool, dir, previous) = try FolderEpochTestFixture.makeAppDB()
        defer { AppDatabase.shared.withLock { $0 = previous }; TestDatabaseTeardown.retire(pool: pool, directory: dir) }

        let server = FakeIMAPServer(mailboxes: ["INBOX": []])
        try server.start()
        defer { server.stop() }

        let accountId = "walk-encryption-refused"
        let account = try FolderEpochTestFixture.makeAccount(id: accountId, provider: .imap, pool: pool)
        try await pool.write { db in
            // A folder the walk has not started: no walk position, no epoch.
            var folder = Folder(name: "INBOX", path: "INBOX", role: .inbox, accountId: accountId)
            folder.backfillComplete = false
            folder.backfillUidCursor = nil
            try folder.insert(db)
        }
        let imap = Self.provider(for: server)
        defer { Task { try? await imap.disconnect() } }
        let engine = SyncEngine()
        await engine.register(
            accountId: accountId, provider: imap,
            workQueue: ProviderWorkQueue(provider: imap, maxConcurrency: SyncConfig.imapMaxConnectionCeiling))

        // No deadline, as the foreground worker calls it.
        let call = Task { await engine.runBackfillWalk(account: account) }
        var waited = 0.0
        while server.acceptedConnectionCount() == 0, waited < Self.firstConnectionBoundSeconds {
            try await Task.sleep(for: .milliseconds(10))
            waited += 0.01
        }
        let first = server.acceptedConnectionCount()
        try await Task.sleep(for: .seconds(Self.observeSeconds))
        let connections = server.acceptedConnectionCount()
        call.cancel()
        let ended = await Self.ends(call, within: Self.endBoundSeconds)

        #expect(first >= 1, "the walk never reached the server")
        #expect(connections == 1, "the walk opened \(connections) connections in \(Self.observeSeconds) s")
        #expect(ended, "the walk did not end after it was cancelled")
        let commands = server.recordedCommands()
        #expect(!Self.signedIn(commands), "\(commands)")
        let read = try FolderEpochTestFixture.readFolder(accountId: accountId, path: "INBOX", pool: pool)
        let row = try #require(read)
        #expect(!row.backfillComplete, "a refused folder was marked complete")
    }

    @Test("A resumed walk with no UIDVALIDITY stamp stops each worker at its first refusal, not one connection per range")
    func refusedServerIsNotAskedOncePerRange() async throws {
        let (pool, dir, previous) = try FolderEpochTestFixture.makeAppDB()
        defer { AppDatabase.shared.withLock { $0 = previous }; TestDatabaseTeardown.retire(pool: pool, directory: dir) }

        let server = FakeIMAPServer(mailboxes: ["INBOX": []])
        try server.start()
        defer { server.stop() }

        let accountId = "walk-encryption-refused-resumed"
        let account = try FolderEpochTestFixture.makeAccount(id: accountId, provider: .imap, pool: pool)
        let imap = Self.provider(for: server)
        defer { Task { try? await imap.disconnect() } }
        // The walk runs this many workers; each may meet the refusal once.
        let workers = await imap.poolMaxConnections()
        let startCursor = Self.resumedCursor(workers: workers)
        try await pool.write { db in
            // A folder with a walk position and no UIDVALIDITY stamp: the
            // walk-start gate lets it through even though the walk-start read
            // is refused, so the workers ask the server range by range.
            var folder = Folder(name: "INBOX", path: "INBOX", role: .inbox, accountId: accountId)
            folder.backfillComplete = false
            folder.backfillUidCursor = startCursor
            folder.lastKnownUidValidity = nil
            try folder.insert(db)
        }
        let engine = SyncEngine()
        await engine.register(
            accountId: accountId, provider: imap,
            workQueue: ProviderWorkQueue(provider: imap, maxConcurrency: SyncConfig.imapMaxConnectionCeiling))

        // No deadline: the walk declines the folder for the call and ends by itself.
        let call = Task { await engine.runBackfillWalk(account: account) }
        let ended = await Self.ends(call, within: Self.resumedEndBoundSeconds)
        let connections = server.acceptedConnectionCount()
        if !ended {
            // Let a cancelled walk end before the database is restored.
            call.cancel()
            _ = await Self.ends(call, within: Self.endBoundSeconds)
        }

        #expect(ended, "the walk did not end within \(Self.resumedEndBoundSeconds) s")
        #expect(connections >= 1, "the walk never reached the server")
        // The walk-start read, then at most one refused SEARCH per worker.
        #expect(connections <= 1 + workers,
                "the walk opened \(connections) connections with \(workers) workers over \(startCursor) UIDs")
        let commands = server.recordedCommands()
        #expect(!Self.signedIn(commands), "\(commands)")
        let read = try FolderEpochTestFixture.readFolder(accountId: accountId, path: "INBOX", pool: pool)
        let row = try #require(read)
        #expect(!row.backfillComplete, "a refused folder was marked complete")
        #expect(row.backfillUidCursor == startCursor, "the walk position moved past ranges the server never answered")
    }
}
