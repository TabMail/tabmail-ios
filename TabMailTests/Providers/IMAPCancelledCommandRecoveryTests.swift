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

    // MARK: - An abort reaching each lane

    /// The lane a holder runs on while a keepalive NOOP is cancelled ahead of it.
    enum Lane: String, CaseIterable, Sendable {
        case folder       // withFolderConnection
        case actionSelect // withActionConnectionSelection (SELECT leg)
        case actionStatus // withActionConnectionNoSelect
    }

    /// A keepalive NOOP is on the wire when a holder checks the same connection out
    /// and queues its first command behind it; the keepalive task is then cancelled.
    /// SwiftMail closes the transport and fails the queued command with
    /// `IMAPConnectionAbortedError`. What the holder's caller sees must be a
    /// connection loss (no banner), and the lane's next operation must succeed.
    ///
    /// Red-first (2026-11-15): with the new SwiftMail pin and the base app code, each
    /// lane surfaced the raw abort, which `InboxErrorBanner.text(for:)` turns into the
    /// generic banner.
    @Test("an abort queued behind a cancelled keepalive NOOP surfaces as a quiet connection loss on every lane", arguments: Lane.allCases)
    func abortBehindCancelledKeepaliveIsQuiet(_ lane: Lane) async throws {
        let server = FakeIMAPServer(
            username: "abort-\(lane.rawValue)-\(UUID().uuidString.lowercased())",
            mailboxes: ["INBOX": [Self.message(uid: 5, id: "abort-probe@example.com")]]
        )
        try server.start()
        defer { server.stop() }
        let provider = Self.provider(for: server)
        defer { Self.awaitDisconnect(provider) }

        // Pin the connection the lane uses.
        switch lane {
        case .folder:
            _ = try await provider.fetchMessages(folder: "INBOX", limit: 1, offset: 0)
        case .actionSelect, .actionStatus:
            try await provider.connect()
            // One completed action op stamps the lane as recently used, so the
            // holder's acquire skips its own liveness NOOP and goes straight to
            // its command.
            _ = try await provider.folderStatus(path: "INBOX")
        }

        // Hold the keepalive's NOOP reply so the holder's command queues behind it.
        let noopsBefore = Self.count("NOOP", in: server)
        server.stallNextCommand(containing: "NOOP", seconds: 5)
        let keepalive = Task { await provider.keepAlivePinnedConnectionsForTesting() }
        #expect(await Self.waitFor { Self.count("NOOP", in: server) > noopsBefore }, "setup: the keepalive NOOP never reached the server")

        let holder = Task { () -> Error? in
            do {
                switch lane {
                case .folder:
                    _ = try await provider.listFlagsInUIDRange(folder: "INBOX", from: 1, to: 100)
                case .actionSelect:
                    _ = try await provider.search(query: "probe", folder: "INBOX")
                case .actionStatus:
                    _ = try await provider.folderStatus(path: "INBOX")
                }
                return nil
            } catch {
                return error
            }
        }
        // The holder has checked the connection out and its command is queued in
        // SwiftMail behind the NOOP (nothing new can reach the server meanwhile).
        try await Task.sleep(for: .milliseconds(300))
        keepalive.cancel()
        _ = await keepalive.value

        let surfaced = await holder.value
        guard let surfaced else {
            Issue.record("setup: the holder's command was not queued behind the NOOP (it succeeded); commands: \(server.recordedCommands().suffix(8))")
            return
        }
        #expect(!(surfaced is IMAPConnectionAbortedError), "the raw SwiftMail abort crossed the provider boundary")
        #expect(SyncEngine.isConnectionError(surfaced), "an abort must read as a connection loss, got \(surfaced)")
        #expect(InboxErrorBanner.text(for: surfaced) == nil, "an abort raised an error banner: \(surfaced)")

        // The lane recovers on its next use.
        switch lane {
        case .folder:
            let flags = try await provider.listFlagsInUIDRange(folder: "INBOX", from: 1, to: 100)
            #expect(flags.flags.keys.contains(5))
        case .actionSelect:
            _ = try await provider.search(query: "probe", folder: "INBOX")
        case .actionStatus:
            _ = try await provider.folderStatus(path: "INBOX")
        }
    }

    private static func count(_ fragment: String, in server: FakeIMAPServer) -> Int {
        server.recordedCommands().filter { $0.uppercased().contains(fragment) }.count
    }

    private static func waitFor(_ condition: () -> Bool) async -> Bool {
        let deadline = Date().addingTimeInterval(5)
        while !condition() {
            if Date() >= deadline { return false }
            try? await Task.sleep(for: .milliseconds(10))
        }
        return true
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
