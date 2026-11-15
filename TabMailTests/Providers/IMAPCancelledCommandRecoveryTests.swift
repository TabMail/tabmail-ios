/* This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at https://mozilla.org/MPL/2.0/. */

import Testing
import Foundation
import SwiftMail
@testable import TabMail

/// SwiftMail closes the transport of a command whose task is cancelled: the
/// cancelled caller gets `CancellationError`, and any command queued behind it on
/// the same server gets `IMAPConnectionAbortedError`. What the user must see is a
/// quiet reconnect: the next operation on that folder succeeds, and an abort never
/// reaches the sync engine as anything but a connection loss (no error banner).
@Suite("IMAP cancelled command recovery", .serialized)
struct IMAPCancelledCommandRecoveryTests {

    // MARK: - Provider boundary

    /// Red-first (2026-11-15): before the boundary mapping, an abort reached the
    /// sync engine raw and `SyncEngine.isConnectionError` answered false for it,
    /// so it was classified as a user-facing failure instead of a reconnect.
    @Test("an aborted SwiftMail command reaches the sync engine as a connection loss")
    func abortIsAConnectionLossAtTheBoundary() {
        let surfaced = IMAPProvider.providerError(from: IMAPConnectionAbortedError())
        #expect(SyncEngine.isConnectionError(surfaced))
        guard case ProviderError.notConnected = surfaced else {
            Issue.record("expected ProviderError.notConnected, got \(surfaced)")
            return
        }
        #expect(IMAPProvider.pooledConnectionUnusable(after: IMAPConnectionAbortedError()))
    }

    @Test("other errors cross the boundary unchanged; a cancellation does not drop the pooled connection")
    func otherErrorsAreUnchanged() {
        let cancellation = CancellationError()
        #expect(IMAPProvider.providerError(from: cancellation) is CancellationError)
        #expect(IMAPProvider.pooledConnectionUnusable(after: cancellation) == false)

        let selectFailure = IMAPError.selectFailed("NO no such mailbox")
        let surfaced = IMAPProvider.providerError(from: selectFailure)
        #expect("\(surfaced)" == "\(selectFailure)")
    }

    // MARK: - End to end against the fake server

    @Test("a folder fetch cancelled mid-command is followed by a quiet, successful fetch on the same folder; another account is unaffected")
    func cancelledFolderFetchRecoversQuietly() async throws {
        let server = FakeIMAPServer(
            username: "cancel-\(UUID().uuidString.lowercased())",
            mailboxes: ["INBOX": [Self.message(uid: 7, id: "cancel-probe@example.com")]]
        )
        try server.start()
        defer { server.stop() }
        let other = FakeIMAPServer(
            username: "other-\(UUID().uuidString.lowercased())",
            mailboxes: ["INBOX": [Self.message(uid: 9, id: "other-probe@example.com")]]
        )
        try other.start()
        defer { other.stop() }

        let provider = Self.provider(for: server)
        defer { Self.awaitDisconnect(provider) }
        let otherProvider = Self.provider(for: other)
        defer { Self.awaitDisconnect(otherProvider) }

        // Pin INBOX's folder connection with an ordinary pass.
        _ = try await provider.fetchMessages(folder: "INBOX", limit: 1, offset: 0)
        _ = try await otherProvider.fetchMessages(folder: "INBOX", limit: 1, offset: 0)
        #expect(await provider.hasFolderConnectionForTesting(folder: "INBOX"))

        // Hold the next FETCH reply so the cancel lands while the command runs.
        let fetchesBefore = server.recordedCommands().filter { $0.uppercased().contains("FETCH") }.count
        server.stallNextCommand(containing: "FETCH", seconds: 5)
        let cancelled = Task { try await provider.listFlagsInUIDRange(folder: "INBOX", from: 1, to: 100) }
        let deadline = Date().addingTimeInterval(5)
        while server.recordedCommands().filter({ $0.uppercased().contains("FETCH") }).count == fetchesBefore,
              Date() < deadline {
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(server.recordedCommands().filter { $0.uppercased().contains("FETCH") }.count > fetchesBefore,
                "setup: the FETCH never reached the server")
        cancelled.cancel()
        _ = try? await cancelled.value

        // The next operation on the folder must succeed with no error at all,
        // well before the stalled reply would have been sent.
        let started = Date()
        let flags = try await provider.listFlagsInUIDRange(folder: "INBOX", from: 1, to: 100)
        #expect(flags.flags.keys.contains(7))
        #expect(Date().timeIntervalSince(started) < 4, "the folder lane waited for the stalled reply instead of recovering")

        // The other account's pool is untouched by this account's cancel.
        let otherFlags = try await otherProvider.listFlagsInUIDRange(folder: "INBOX", from: 1, to: 100)
        #expect(otherFlags.flags.keys.contains(9))
    }

    // MARK: - Helpers

    private static func provider(for server: FakeIMAPServer) -> IMAPProvider {
        IMAPProvider(
            host: "127.0.0.1",
            port: server.port,
            username: server.username,
            password: server.password,
            smtpHost: "127.0.0.1",
            smtpPort: 587,
            useTLS: false
        )
    }

    private static func awaitDisconnect(_ provider: IMAPProvider) {
        let done = DispatchSemaphore(value: 0)
        Task { try? await provider.disconnect(); done.signal() }
        done.wait()
    }

    private static func message(uid: Int, id: String) -> FakeIMAPServer.Message {
        FakeIMAPServer.makeMessage(uid: uid, rfc822Text: """
            From: Test Sender <sender@example.com>\r
            To: Recipient <recipient@example.com>\r
            Subject: cancel-recovery-fixture\r
            Date: \(Self.dateFormatter.string(from: Date()))\r
            Message-ID: <\(id)>\r
            Content-Type: text/plain; charset=utf-8\r
            \r
            cancel recovery probe body.\r

            """)
    }

    private static let dateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "EEE, dd MMM yyyy HH:mm:ss Z"
        return formatter
    }()
}
