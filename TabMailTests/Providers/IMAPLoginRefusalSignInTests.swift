/* This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at https://mozilla.org/MPL/2.0/. */

import Foundation
import SwiftMail
import Testing
@testable import TabMail

/// A refused IMAP login, as the user sees it: the "sign in again" warning
/// (`authFailedAccounts`) is raised only when the server refused the credentials,
/// decided by the RFC 5530 response code, and is cleared by the next accepted
/// login. A temporary refusal (`UNAVAILABLE`, `INUSE`, `SERVERBUG`, `LIMIT`)
/// raises nothing and reaches the caller as `ProviderTemporaryRefusal`, which
/// the sync paths treat as transient (no banner, no failed-sync mark).
///
/// Driven through the real `IMAPProvider` against `FakeIMAPServer`, with the
/// reporter the account factory injects
/// (`AccountManager.makeSignInOutcomeReporter`).
@Suite("IMAP login refusal and the sign-in warning", .serialized, .processGlobalState, .timeLimit(.minutes(2)))
struct IMAPLoginRefusalSignInTests {

    private static let temporaryCodes = ["UNAVAILABLE", "INUSE", "SERVERBUG", "LIMIT"]
    private static let credentialCodes = ["AUTHENTICATIONFAILED", "AUTHORIZATIONFAILED", "EXPIRED", "CONTACTADMIN"]

    /// One fake server and one provider wired to the production reporter for a
    /// fresh account id; the warning for that id is cleared afterwards.
    private func withProvider(
        _ body: (FakeIMAPServer, IMAPProvider, String) async throws -> Void
    ) async throws {
        let server = FakeIMAPServer(mailboxes: ["INBOX": []])
        try server.start()
        defer { server.stop() }
        let accountId = "login-refusal-\(UUID().uuidString)"
        let provider = IMAPProvider(
            host: "127.0.0.1", port: server.port,
            username: server.username, password: server.password,
            smtpHost: "127.0.0.1", smtpPort: 587, useTLS: false,
            signInOutcome: AccountManager.shared.makeSignInOutcomeReporter(accountId: accountId))
        do {
            try await body(server, provider, accountId)
        } catch {
            try? await provider.disconnect()
            await AccountManager.shared.clearAuthFailed(accountId)
            throw error
        }
        try? await provider.disconnect()
        await AccountManager.shared.clearAuthFailed(accountId)
    }

    private func isMarked(_ accountId: String) async -> Bool {
        await AccountManager.shared.authFailedAccounts.contains(accountId)
    }

    @Test("a temporary refusal then a successful retry: no warning, no banner, transient error",
          arguments: IMAPLoginRefusalSignInTests.temporaryCodes)
    func temporaryRefusalThenRetry(code: String) async throws {
        try await withProvider { server, provider, accountId in
            server.failNextCommand(containing: "LOGIN", message: "[\(code)] Service temporarily unavailable")
            var thrown: (any Error)?
            do { try await provider.connect() } catch { thrown = error }
            let error = try #require(thrown, "the injected LOGIN refusal did not reach the caller")
            #expect(error is ProviderTemporaryRefusal, "\(error)")
            #expect(SyncEngine.isTransientError(error))
            #expect(InboxErrorBanner.text(for: error) == nil)
            #expect(await !isMarked(accountId))

            try await provider.connect()
            #expect(await !isMarked(accountId))
            #expect(server.consumedInjectedFailureCount() == 1)
        }
    }

    @Test("a credentials refusal raises the warning; each refusal code that is not temporary does",
          arguments: IMAPLoginRefusalSignInTests.credentialCodes.map { "[\($0)] " } + [""])
    func credentialRefusalMarks(prefix: String) async throws {
        try await withProvider { server, provider, accountId in
            server.failNextCommand(containing: "LOGIN", message: "\(prefix)Login refused")
            var thrown: (any Error)?
            do { try await provider.connect() } catch { thrown = error }
            let error = try #require(thrown, "the injected LOGIN refusal did not reach the caller")
            #expect(!(error is ProviderTemporaryRefusal), "\(error)")
            #expect(!SyncEngine.isTransientError(error))
            #expect(await isMarked(accountId), "refusal '\(prefix)' did not raise the warning")
        }
    }

    @Test("a refusal mid-session raises the warning; the next accepted login clears it")
    func midSessionRefusalThenRecovery() async throws {
        try await withProvider { server, provider, accountId in
            try await provider.connect()
            #expect(await !isMarked(accountId))

            await provider.markDirty()
            server.failNextCommand(containing: "LOGIN", message: "[AUTHENTICATIONFAILED] Invalid credentials")
            var thrown: (any Error)?
            do { try await provider.connect() } catch { thrown = error }
            #expect(thrown != nil, "the dirty provider did not log in again")
            #expect(await isMarked(accountId))

            try await provider.connect()
            #expect(await !isMarked(accountId), "an accepted login did not clear the warning")
        }
    }

    @Test("the temporary set is read from the leading response code only, never the server's prose")
    func classificationIsStructural() {
        for code in Self.temporaryCodes {
            #expect(IMAPProvider.isTemporaryLoginRefusal(reason: "no([\(code)] try later)"))
        }
        for code in Self.credentialCodes {
            #expect(!IMAPProvider.isTemporaryLoginRefusal(reason: "no([\(code)] no)"))
        }
        #expect(!IMAPProvider.isTemporaryLoginRefusal(reason: "no(Server UNAVAILABLE, see [UNAVAILABLE])"))
        #expect(!IMAPProvider.isTemporaryLoginRefusal(reason: "no(login failed)"))
    }
}
