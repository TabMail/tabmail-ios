/* This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at https://mozilla.org/MPL/2.0/. */

import Foundation
import GRDB
import Synchronization
import Testing
@testable import TabMail

/// A Google or Microsoft sign-in the provider has revoked (password change,
/// revocation, admin policy), as the user and the mail queues see it (#534):
///
/// - the account shows the same "sign in again" warning the calendar already
///   raised (`authFailedAccounts`, which `RootView`, `SettingsView` and
///   `AccountDetailView` render);
/// - a queued action and a send are kept while the sign-in is refused, however
///   many drains run, and go out once the user signs in again, which also clears
///   the warning;
/// - a token endpoint that could not answer (offline, 5xx, a body without an
///   OAuth `error` code, `temporarily_unavailable`) raises no warning;
/// - a refusal of a sign-in the user has already replaced raises no warning.
///
/// Gmail and Outlook take their tokens through the one accessor
/// `AccountManager.makeOAuthAccessor` builds, so both are driven end to end
/// through a real provider. IMAP accounts sign in with a password and have no
/// OAuth grant.
@Suite("A revoked mail sign-in", .serialized, .processGlobalState, .timeLimit(.minutes(2)))
struct RevokedMailGrantSignalTests {

    // MARK: - Harness

    private struct Fixture {
        let pool: DatabasePool
        let directory: URL
        let previous: AppDatabase?
        let account: Account
    }

    private static let inbox = "INBOX"

    /// A temporary database installed as `AppDatabase.shared`, holding one account
    /// and its Inbox. No Sent folder: a send the server accepts is finalized at once.
    private func fixture(_ provider: AccountProvider) throws -> Fixture {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        var configuration = Configuration()
        configuration.foreignKeysEnabled = true
        let pool = try DatabasePool(
            path: directory.appendingPathComponent("test.sqlite").path,
            configuration: configuration)
        let appDatabase = try AppDatabase(dbPool: pool)
        let previous = AppDatabase.shared.withLock { current -> AppDatabase? in
            let old = current
            current = appDatabase
            return old
        }
        let account = Account(
            emailAddress: "revoked-\(UUID().uuidString)@example.com", displayName: "Revoked", provider: provider)
        try pool.writeWithoutTransaction { db in
            try account.insert(db)
            try Folder(name: Self.inbox, path: Self.inbox, role: .inbox, accountId: account.id).insert(db)
        }
        return Fixture(pool: pool, directory: directory, previous: previous, account: account)
    }

    private func withFixture(
        _ provider: AccountProvider, _ body: (Fixture, FakeHTTP.Scenario) async throws -> Void
    ) async throws {
        let fixture = try fixture(provider)
        let http = FakeHTTP.Scenario()
        do {
            try await body(fixture, http)
        } catch {
            await finish(fixture, http)
            throw error
        }
        await finish(fixture, http)
    }

    private func finish(_ fixture: Fixture, _ http: FakeHTTP.Scenario) async {
        await AccountManager.shared.disconnectAccount(fixture.account)
        await AccountManager.shared.unregisterProviderForTesting(accountId: fixture.account.id)
        await AccountManager.shared.clearAuthFailed(fixture.account.id)
        try? ProviderCredentialStore.shared.remove(accountId: fixture.account.id)
        http.close()
        InstalledTestDatabaseLifetime.finish(
            previous: fixture.previous, pool: fixture.pool, directory: fixture.directory)
    }

    /// A stored sign-in whose access token has expired, so the next request must
    /// refresh it.
    private static let expiredSignIn = ProviderCredentialStore.Tokens(
        accessToken: "expired-access", refreshToken: "revoked-refresh",
        expiresAt: Date().addingTimeInterval(-120))

    /// The tokens a new sign-in returns.
    private static func newSignIn() -> OAuthTokens {
        OAuthTokens(accessToken: "new-access", refreshToken: "new-refresh",
                    expiresAt: Date().addingTimeInterval(3600), idToken: nil)
    }

    @discardableResult
    private func seedHeader(_ fixture: Fixture, providerId: String) throws -> MessageHeader {
        let header = MessageHeader(
            messageId: providerId,
            subject: "revoked \(providerId)",
            from: "Sender",
            fromAddress: "sender@example.com",
            to: fixture.account.emailAddress,
            date: Date(),
            snippet: "revoked body",
            folderId: MessageIdentity.folderId(accountId: fixture.account.id, folderPath: Self.inbox),
            accountId: fixture.account.id,
            folderPath: Self.inbox,
            isInInbox: true)
        try fixture.pool.writeWithoutTransaction { db in try header.insert(db) }
        return header
    }

    private func queuedOperations(_ fixture: Fixture) throws -> [PendingOperation] {
        try fixture.pool.read { db in try PendingOperation.fetchAll(db) }
    }

    private static let pollAttempts = 200
    private static let pollInterval = Duration.milliseconds(10)

    /// Wait, bounded, until no drain owns the queue.
    private func waitForQuietQueue() async -> Bool {
        for _ in 0..<Self.pollAttempts {
            if await AccountManager.shared.pendingQueueIsQuiescentForTesting() { return true }
            try? await Task.sleep(for: Self.pollInterval)
        }
        return await AccountManager.shared.pendingQueueIsQuiescentForTesting()
    }

    /// Whether the warning for `accountId` reaches `shown`, bounded: the actor's
    /// set, and the main-actor mirror the views read, which follows it
    /// asynchronously. The set itself is written before the failed refresh is
    /// rethrown, so a warning that was never raised is already settled.
    private func warningReaches(_ shown: Bool, for accountId: String) async -> Bool {
        for _ in 0..<Self.pollAttempts {
            let source = await AccountManager.shared.authFailedAccounts.contains(accountId)
            let mirror = await MainActor.run { AccountManagerState.shared.authFailedAccounts.contains(accountId) }
            if source == shown && mirror == shown { return true }
            try? await Task.sleep(for: Self.pollInterval)
        }
        return false
    }

    private struct Routes {
        let actionPath: String
        let actionMethod: String
        let actionResponse: FakeHTTP.CannedResponse
        let sendPath: String
        let sendResponse: FakeHTTP.CannedResponse
        let profilePath: String
    }

    private static func routes(_ kind: AccountProvider, providerId: String) -> Routes {
        kind == .outlook
            ? Routes(actionPath: "/messages/\(providerId)", actionMethod: "PATCH",
                     actionResponse: GraphThrottlingTests.emptyObject,
                     sendPath: "/sendMail", sendResponse: GraphThrottlingTests.accepted,
                     profilePath: "/v1.0/me")
            : Routes(actionPath: "/messages/\(providerId)/modify", actionMethod: "POST",
                     actionResponse: .json(raw: #"{"id":"\#(providerId)","labelIds":["INBOX"]}"#),
                     sendPath: "/messages/send", sendResponse: GraphThrottlingTests.emptyObject,
                     profilePath: "/profile")
    }

    // MARK: - The warning, the queue and the outbox

    @Test("A revoked sign-in shows the warning, keeps the queued action and the send, and both go out after signing in again",
          arguments: [AccountProvider.gmail, .outlook])
    func revokedSignInWarnsAndKeepsTheWork(kind: AccountProvider) async throws {
        try await withFixture(kind) { f, http in
            let providerId = "revoked-\(kind)-message"
            let routes = Self.routes(kind, providerId: providerId)
            http.register(path: routes.actionPath, method: routes.actionMethod, response: routes.actionResponse)
            http.register(path: routes.sendPath, method: "POST", response: routes.sendResponse)
            http.register(path: routes.profilePath, method: "GET", response: GraphThrottlingTests.emptyObject)
            let reachedTheServer = { (path: String) in
                http.recordedCalls().filter { $0.url.contains(path) }.count
            }

            try ProviderCredentialStore.shared.install(accountId: f.account.id, tokens: Self.expiredSignIn)
            let refusals = Mutex(0)
            let accessor = await AccountManager.shared.makeOAuthAccessor(
                accountId: f.account.id, email: f.account.emailAddress,
                refreshCoordinator: OAuthRefreshCoordinator()
            ) { _ in
                refusals.withLock { $0 += 1 }
                throw OAuthError.tokenExchangeFailed("invalid_grant")
            }
            let provider: any EmailProvider = kind == .outlook
                ? ExchangeProvider(userEmail: f.account.emailAddress, accessToken: accessor, session: http.session)
                : GmailProvider(userEmail: f.account.emailAddress, accessToken: accessor, session: http.session)

            // The user's gesture and send, made before the sign-in was refused.
            let header = try seedHeader(f, providerId: providerId)
            await AccountManager.shared.markRead([header])
            try #require(await waitForQuietQueue(), "the gesture's own drain never returned")
            let queued = try queuedOperations(f)
            #expect(queued.count == 1, "the gesture was not queued")
            guard queued.count == 1 else { return }
            let draft = DraftMessage(to: ["recipient@example.com"], subject: "Revoked send", body: "Body of the send")
            var message = OutboxMessage(accountId: f.account.id, draft: draft)
            message.holdUntil = Date().addingTimeInterval(-60)
            let seeded = message
            try await f.pool.write { db in try seeded.insert(db) }

            // More drains than any retry limit, all against a refused sign-in.
            await AccountManager.shared.registerProviderForTesting(accountId: f.account.id, provider: provider)
            let drains = max(SyncConfig.pendingOperationServerRefusalRetryLimit, 3) + 1
            for _ in 0..<drains {
                try #require(await waitForQuietQueue(), "an earlier drain still owns the queue")
                await AccountManager.shared.drainPendingQueue()
                await AccountManager.shared.drainOutbox()
            }
            try #require(await waitForQuietQueue(), "the last drain never returned")

            #expect(refusals.withLock { $0 } > 0, "the refused sign-in was never asked for a token")
            #expect(await warningReaches(true, for: f.account.id),
                    "\(kind): the user was not told to sign in again")

            let kept = try queuedOperations(f)
            #expect(kept.count == 1, "\(kind): the user's mark-read was dropped while the sign-in was refused")
            guard kept.count == 1 else { return }
            #expect(kept[0].id == queued[0].id)
            #expect(kept[0].type == .markRead)
            #expect(kept[0].messageIds == queued[0].messageIds)
            #expect(kept[0].status == PendingStatus.queued.rawValue)
            let held = try await f.pool.read { db in try OutboxMessage.fetchOne(db, key: seeded.id) }
            #expect(held != nil, "\(kind): the send was dropped while the sign-in was refused")
            guard let held else { return }
            #expect(held.sentAt == nil)
            #expect(held.to == draft.to && held.subject == draft.subject && held.body == draft.body,
                    "\(kind): the kept send lost its content")
            #expect(reachedTheServer(routes.actionPath) == 0, "\(kind): an action went out without a token")
            #expect(reachedTheServer(routes.sendPath) == 0, "\(kind): a send went out without a token")

            // The user signs in again from the warning.
            try await AuthedHTTP.$sessionOverride.withValue(http.session) {
                if kind == .outlook {
                    try await AccountManager.shared.reauthenticateMicrosoft(
                        for: f.account, authenticate: { Self.newSignIn() })
                } else {
                    try await AccountManager.shared.reauthenticateGmail(
                        for: f.account, authenticate: { Self.newSignIn() })
                }
                #expect(await warningReaches(false, for: f.account.id),
                        "\(kind): the warning stayed after signing in again")

                try #require(await waitForQuietQueue(), "a drain still owns the queue after signing in")
                await AccountManager.shared.drainPendingQueue()
                try #require(await waitForQuietQueue(), "the drain after signing in never returned")
                #expect(try queuedOperations(f).isEmpty, "\(kind): the kept mark-read did not go out after signing in")
                #expect(reachedTheServer(routes.actionPath) == 1)

                // A send that used up its automatic retries waits for the Outbox's Retry.
                let current = try await f.pool.read { db in try OutboxMessage.fetchOne(db, key: seeded.id) }
                if current?.outboxStatus == .failed {
                    #expect(AccountManager.shared.retryOutboxMessage(seeded.id))
                }
                await AccountManager.shared.drainOutbox()
                let sent = try await f.pool.read { db in try OutboxMessage.fetchOne(db, key: seeded.id) }
                #expect(sent == nil, "\(kind): the kept send did not go out after signing in")
                #expect(reachedTheServer(routes.sendPath) == 1)
            }
        }
    }

    // MARK: - What the token endpoint answered

    /// A refresh failure and a label for it.
    struct RefreshFailure: Sendable, CustomTestStringConvertible {
        let testDescription: String
        let make: @Sendable () -> any Error
    }

    /// Answers that say nothing about the grant: the endpoint was unreachable, or
    /// answered without one of the grant-level codes.
    static let indeterminate: [RefreshFailure] = [
        RefreshFailure(testDescription: "temporarily_unavailable") { OAuthError.tokenExchangeFailed("temporarily_unavailable") },
        RefreshFailure(testDescription: "server_error") { OAuthError.tokenExchangeFailed("server_error") },
        RefreshFailure(testDescription: "no error code in the body") { OAuthError.tokenExchangeFailed("unknown") },
        RefreshFailure(testDescription: "invalid_scope (our request, not the grant)") { OAuthError.tokenExchangeFailed("invalid_scope") },
        RefreshFailure(testDescription: "offline") { URLError(.notConnectedToInternet) },
        RefreshFailure(testDescription: "timed out") { URLError(.timedOut) },
        RefreshFailure(testDescription: "an HTML error page") {
            DecodingError.dataCorrupted(.init(codingPath: [], debugDescription: "not JSON"))
        },
    ]

    /// The codes with which the token endpoint itself refuses the grant.
    static let refused = ["invalid_grant", "invalid_client", "unauthorized_client", " INVALID_GRANT\n"]

    private func refreshThroughTheAccessor(
        _ failure: @escaping @Sendable () -> any Error
    ) async throws -> (accountId: String, threw: Bool) {
        let harness = CredentialTestHarness(), store = harness.provider
        let accountId = "revoked-signal-" + UUID().uuidString
        try store.install(accountId: accountId, tokens: CredentialTestHarness.tokens())
        let accessor = await AccountManager.shared.makeOAuthAccessor(
            accountId: accountId, email: "user@example.com",
            store: store, refreshCoordinator: OAuthRefreshCoordinator(store: store)
        ) { _ in throw failure() }
        let threw: Bool
        do {
            _ = try await accessor(true)
            threw = false
        } catch {
            threw = true
        }
        return (accountId, threw)
    }

    @Test("A token endpoint that could not answer does not tell the user to sign in again", arguments: indeterminate)
    func indeterminateFailureRaisesNoWarning(_ failure: RefreshFailure) async throws {
        let (accountId, threw) = try await refreshThroughTheAccessor(failure.make)
        #expect(threw, "the failed refresh returned a token")
        #expect(await warningReaches(false, for: accountId),
                "\(failure.testDescription): a transient failure told the user their sign-in is broken")
        await AccountManager.shared.clearAuthFailed(accountId)
    }

    @Test("A grant the token endpoint refuses tells the user to sign in again", arguments: refused)
    func refusedGrantRaisesTheWarning(_ code: String) async throws {
        let (accountId, threw) = try await refreshThroughTheAccessor { OAuthError.tokenExchangeFailed(code) }
        #expect(threw, "the refused refresh returned a token")
        #expect(await warningReaches(true, for: accountId), "\(code): the user was not told to sign in again")
        await AccountManager.shared.clearAuthFailed(accountId)
    }

    @Test("A refusal of a sign-in the user has already replaced does not warn about the new one")
    func refusalOfAReplacedSignInRaisesNoWarning() async throws {
        let harness = CredentialTestHarness(), store = harness.provider
        let accountId = "revoked-replaced-" + UUID().uuidString
        try store.install(accountId: accountId, tokens: CredentialTestHarness.tokens())
        let started = CredentialTestLatch(), release = CredentialTestLatch()
        let accessor = await AccountManager.shared.makeOAuthAccessor(
            accountId: accountId, email: "user@example.com",
            store: store, refreshCoordinator: OAuthRefreshCoordinator(store: store)
        ) { _ in
            await started.signal()
            await release.wait()
            throw OAuthError.tokenExchangeFailed("invalid_grant")
        }
        let refresh = Task { try await accessor(true) }
        await started.wait()
        // The user signs in again while the old sign-in's refresh is on the wire.
        try store.install(accountId: accountId, tokens: .init(
            accessToken: "new-access", refreshToken: "new-refresh", expiresAt: Date().addingTimeInterval(3600)))
        await release.signal()
        await #expect(throws: (any Error).self) { try await refresh.value }

        #expect(await warningReaches(false, for: accountId),
                "the old sign-in's refusal told the user to sign in again after they had")
        await AccountManager.shared.clearAuthFailed(accountId)
    }
}
