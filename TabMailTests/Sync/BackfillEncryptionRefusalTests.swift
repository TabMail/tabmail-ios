/* This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at https://mozilla.org/MPL/2.0/. */

import Testing
import Foundation
import GRDB
@testable import TabMail

/// A mail server that refuses an encrypted connection (it offers no STARTTLS on
/// a port where TabMail requires it, `MailTransportPolicy`) must not make the
/// backfill walk reconnect at network rate. The walk's first read of a folder
/// it has not started yet (no walk position: after Settings > Smart Reindex, or
/// a folder never walked) is refused there every time; a walk that picked the
/// same folder straight back after each refusal opened a new connection per
/// iteration, and a call with no deadline (the foreground worker's) never
/// returned.
///
/// The property: after the walk's first connection, a full observation window
/// passes with no second one.
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

    /// Whether `call` ended within `bound` seconds.
    private static func ends(_ call: Task<Bool, Never>, within bound: TimeInterval) async -> Bool {
        await withTaskGroup(of: Bool.self) { group in
            group.addTask { _ = await call.value; return true }
            group.addTask {
                try? await Task.sleep(for: .seconds(bound))
                return false
            }
            let first = await group.next() ?? false
            group.cancelAll()
            for await _ in group {}
            return first
        }
    }

    @Test("A walk with no deadline connects once to a server that offers no STARTTLS, then does not reconnect at once")
    func refusedServerIsNotReconnectedAtNetworkRate() async throws {
        let (pool, dir, previous) = try FolderEpochTestFixture.makeAppDB()
        defer { AppDatabase.shared.withLock { $0 = previous }; TestDatabaseTeardown.retire(pool: pool, directory: dir) }

        // Offers no STARTTLS (the default capabilities have none) on a port that
        // is not 993, so the real transport policy requires STARTTLS there.
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
        // No test override: the transport comes from the port, as in production.
        let imap = IMAPProvider(
            host: "127.0.0.1", port: server.port, username: server.username, password: server.password,
            smtpHost: "127.0.0.1", smtpPort: MailTransportPolicy.smtpImplicitTLSPort)
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
        let signedIn = commands.contains { $0.uppercased().contains("LOGIN") || $0.uppercased().contains("AUTHENTICATE") }
        #expect(!signedIn, "\(commands)")
        let read = try FolderEpochTestFixture.readFolder(accountId: accountId, path: "INBOX", pool: pool)
        let row = try #require(read)
        #expect(!row.backfillComplete, "a refused folder was marked complete")
    }
}
