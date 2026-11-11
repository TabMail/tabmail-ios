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

    // MARK: - Factory wiring and Update Password

    /// An IMAP account pointing at `server`, with its stored password in the
    /// Keychain, built through the real factory. Cleans up the Keychain entry,
    /// the registered provider and the warning.
    private func withFactoryAccount(
        _ body: (FakeIMAPServer, Account) async throws -> Void
    ) async throws {
        let server = FakeIMAPServer(mailboxes: ["INBOX": []])
        try server.start()
        defer { server.stop() }
        var account = Account(emailAddress: "factory-\(UUID().uuidString.prefix(8))@example.com",
                              displayName: "Factory", provider: .imap)
        account.imapHost = "127.0.0.1"
        account.imapPort = server.port
        account.imapUsername = server.username
        let manager = AccountManager.shared
        manager.setIMAPUseTLSOverrideForTesting(false)
        try KeychainHelper.save(server.password, for: KeychainHelper.passwordKey(accountId: account.id))
        func finish() async {
            if let live = await manager.provider(for: account) { try? await live.disconnect() }
            await manager.unregisterProviderForTesting(accountId: account.id)
            await manager.syncEngine.remove(accountId: account.id)
            await manager.clearAuthFailed(account.id)
            KeychainHelper.delete(key: KeychainHelper.passwordKey(accountId: account.id))
            manager.setIMAPUseTLSOverrideForTesting(nil)
        }
        do {
            try await body(server, account)
        } catch {
            await finish()
            throw error
        }
        await finish()
    }

    /// `withFactoryAccount`, with the account's row stored in an installed test
    /// database, as `updatePassword` reads it when it starts.
    private func withStoredFactoryAccount(
        _ body: (FakeIMAPServer, Account) async throws -> Void
    ) async throws {
        let (pool, dir, previous) = try FolderEpochTestFixture.makeAppDB()
        defer { InstalledTestDatabaseLifetime.finish(previous: previous, pool: pool, directory: dir) }
        try await withFactoryAccount { server, account in
            try await pool.write { db in try account.insert(db) }
            try await body(server, account)
        }
    }

    @Test("the factory injects the reporter into the live provider, and not into a password probe")
    func factoryInjectsReporterIntoLiveProviderOnly() async throws {
        try await withFactoryAccount { server, account in
            let manager = AccountManager.shared
            let live = try await manager.createIMAPProvider(for: account)
            #expect(live.hasSignInOutcomeReporter, "the live provider was built without the sign-in reporter")
            let probe = try await manager.createIMAPProvider(for: account, passwordOverride: "probe-password")
            #expect(!probe.hasSignInOutcomeReporter, "a password probe was built with the account's reporter")

            // And the live provider's reporter is the account's: a refusal marks it.
            server.failNextCommand(containing: "LOGIN", message: "[AUTHENTICATIONFAILED] Invalid credentials")
            var thrown: (any Error)?
            do { try await live.connect() } catch { thrown = error }
            #expect(thrown != nil)
            #expect(await isMarked(account.id))
            try? await live.disconnect()
        }
    }

    @Test("Update Password with a refused password never marks the account")
    func refusedProbeNeverMarks() async throws {
        try await withStoredFactoryAccount { server, account in
            let manager = AccountManager.shared
            server.failNextCommand(containing: "LOGIN", message: "[AUTHENTICATIONFAILED] Invalid credentials")
            var thrown: (any Error)?
            do { try await manager.updatePassword("mistyped", for: account) } catch { thrown = error }
            let error = try #require(thrown, "the refused probe did not reach the caller")
            #expect(AccountReauthAlert.passwordUpdateLine(for: error, host: "127.0.0.1") == AccountReauthAlert.passwordLine,
                    "a refused password did not get the password line: \(error)")
            #expect(await !isMarked(account.id), "a refused password probe marked a working account")
        }
    }

    @Test("after Update Password the live provider reports: a refusal marks, a later login clears")
    func updatedPasswordProviderReportsWithoutRelaunch() async throws {
        try await withStoredFactoryAccount { server, account in
            let manager = AccountManager.shared
            try await manager.updatePassword(server.password, for: account)
            let live = try #require(await manager.provider(for: account) as? IMAPProvider)
            #expect(live.hasSignInOutcomeReporter)

            await live.markDirty()
            server.failNextCommand(containing: "LOGIN", message: "[AUTHENTICATIONFAILED] Invalid credentials")
            var thrown: (any Error)?
            do { try await live.connect() } catch { thrown = error }
            #expect(thrown != nil)
            #expect(await isMarked(account.id), "the provider made live by Update Password did not report a refusal")

            try await live.connect()
            #expect(await !isMarked(account.id), "an accepted login did not clear the warning")
        }
    }

    @Test("a late refusal from the provider Update Password replaced never marks the account")
    func replacedProviderLateRefusalNeverMarks() async throws {
        try await withStoredFactoryAccount { server, account in
            let manager = AccountManager.shared
            let old = try await manager.createIMAPProvider(for: account)
            await manager.registerProviderForTesting(accountId: account.id, provider: old)
            #expect(old.hasSignInOutcomeReporter)

            try await manager.updatePassword(server.password, for: account)
            #expect(!old.hasSignInOutcomeReporter, "the replaced provider kept the account's reporter")

            // The replaced provider still holds the old password; its login is refused.
            server.failNextCommand(containing: "LOGIN", message: "[AUTHENTICATIONFAILED] Invalid credentials")
            var thrown: (any Error)?
            do { try await old.connect() } catch { thrown = error }
            #expect(thrown != nil, "the replaced provider did not attempt a login")
            #expect(await !isMarked(account.id), "a late refusal from the replaced provider marked the account")
            try? await old.disconnect()
        }
    }

    /// Set the generic banner, as an earlier failed refresh would have.
    @MainActor
    private static func raiseBanner() {
        AccountManagerState.shared.syncErrorBanner = InboxErrorBanner.genericMessage
    }

    /// Run a user refresh of `inbox` and read the generic banner afterwards.
    @MainActor
    private static func refreshAndReadBanner(_ inbox: Folder) async -> String? {
        await InboxViewModel(folders: [inbox]).refreshSync()
        return AccountManagerState.shared.syncErrorBanner
    }

    @Test("a refresh whose only error is a sign-in refusal raises no generic banner, and the sign-in banner shows from the first refusal")
    func refreshSignInRefusalShowsOnlyTheSignInBanner() async throws {
        let (pool, dir, previous) = try FolderEpochTestFixture.makeAppDB()
        let saved = await MainActor.run { () -> (String?, Date?, Bool) in
            let state = AccountManagerState.shared
            let saved = (state.syncErrorBanner, state.lastSyncCompletedAt, state.lastSyncFailed)
            state.syncErrorBanner = nil
            return saved
        }
        func restore() async {
            await MainActor.run {
                let state = AccountManagerState.shared
                state.syncErrorBanner = saved.0
                state.lastSyncCompletedAt = saved.1
                state.lastSyncFailed = saved.2
            }
            InstalledTestDatabaseLifetime.finish(previous: previous, pool: pool, directory: dir)
        }
        do {
            try await withFactoryAccount { server, account in
                try await pool.write { db in try account.insert(db) }
                try FolderEpochTestFixture.insertFolder(accountId: account.id, path: "INBOX", role: .inbox, pool: pool)
                let inbox = try #require(try FolderEpochTestFixture.readFolder(accountId: account.id, path: "INBOX", pool: pool))
                #expect(await !isMarked(account.id), "the account was marked before its first refusal")

                server.failNextCommand(containing: "LOGIN", message: "[AUTHENTICATIONFAILED] Invalid credentials")
                let banner = await Self.refreshAndReadBanner(inbox)

                #expect(banner == nil, "a sign-in refusal raised the generic banner")
                let failed = await AccountManager.shared.authFailedAccounts

                // A failed refresh never clears: with the banner already up, a second
                // sign-in refusal leaves it there.
                await Self.raiseBanner()
                server.failNextCommand(containing: "LOGIN", message: "[AUTHENTICATIONFAILED] Invalid credentials")
                let after = await Self.refreshAndReadBanner(inbox)
                #expect(after == InboxErrorBanner.genericMessage, "a failed sign-in refresh cleared the banner")
                let shown = await MainActor.run { SignInAgainBanner.accounts(failed: failed, in: [account]).map(\.id) }
                #expect(shown == [account.id],
                        "the first refusal did not show the sign-in banner")
            }
        } catch {
            await restore()
            throw error
        }
        await restore()
    }
}
