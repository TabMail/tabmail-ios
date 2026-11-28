/* This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at https://mozilla.org/MPL/2.0/. */

import Foundation
import GRDB
import SwiftMail
import Synchronization
import Testing
@testable import TabMail

/// A Google or Microsoft sign-in the provider has revoked (password change,
/// revocation, admin revocation), as the user and the mail queues see it (#534):
///
/// - the account shows the same "sign in again" warning the calendar already
///   raised (`authFailedAccounts`, which `RootView`, `SettingsView` and
///   `AccountDetailView` render);
/// - a queued action and a send are kept while the sign-in is refused, however
///   many drains run, and go out once the user signs in again, which also clears
///   the warning;
/// - a token endpoint that asks for another sign-in step or consent, or reports
///   an admin restriction, warns the same way (#659); a calendar change queued
///   meanwhile waits, and goes through once a token is issued again;
/// - a token endpoint that could not answer (offline, 5xx, a body without an
///   OAuth `error` code, `temporarily_unavailable`) raises no warning;
/// - a refusal of a sign-in the user has already replaced, or of a removed
///   account, raises no warning, whichever queue the refusal reaches.
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

    /// Each provider with a refused grant, and with the code it returns when the
    /// sign-in needs the user (#659): Google's admin restriction, Microsoft's
    /// further sign-in step.
    static let refusedMailSignIns: [(AccountProvider, String)] = [
        (.gmail, "invalid_grant"), (.outlook, "invalid_grant"),
        (.gmail, "admin_policy_enforced"), (.outlook, "interaction_required"),
    ]

    @Test("A refused sign-in shows the warning, keeps the queued action and the send, and both go out after signing in again",
          arguments: refusedMailSignIns)
    func revokedSignInWarnsAndKeepsTheWork(kind: AccountProvider, code: String) async throws {
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
                throw OAuthError.tokenExchangeFailed(code)
            }
            let provider: any EmailProvider = kind == .outlook
                ? ExchangeProvider(userEmail: f.account.emailAddress, accessToken: accessor, session: http.session)
                : GmailProvider(userEmail: f.account.emailAddress, accessToken: accessor, session: http.session)

            // The user's gesture, made before the sign-in was refused.
            let header = try seedHeader(f, providerId: providerId)
            await AccountManager.shared.markRead([header])
            try #require(await waitForQuietQueue(), "the gesture's own drain never returned")
            let queued = try queuedOperations(f)
            #expect(queued.count == 1, "the gesture was not queued")
            guard queued.count == 1 else { return }

            // Each queue on its own, from an account with no warning, gets more
            // drains than any retry limit, all against a refused sign-in, and must
            // raise the warning itself: first the queued action, then the send.
            await AccountManager.shared.registerProviderForTesting(accountId: f.account.id, provider: provider)
            let drains = max(SyncConfig.pendingOperationServerRefusalRetryLimit, 3) + 1
            try #require(await warningReaches(false, for: f.account.id), "fixture check: the warning was up before any drain")
            for _ in 0..<drains {
                try #require(await waitForQuietQueue(), "an earlier drain still owns the queue")
                await AccountManager.shared.drainPendingQueue()
            }
            try #require(await waitForQuietQueue(), "the last drain never returned")
            let refusalsOfTheAction = refusals.withLock { $0 }
            #expect(refusalsOfTheAction > 0, "\(kind): the queued action never asked the refused sign-in for a token")
            #expect(await warningReaches(true, for: f.account.id),
                    "\(kind) \(code): the queued action's refusal did not tell the user to sign in again")

            await AccountManager.shared.clearAuthFailed(f.account.id)
            try #require(await warningReaches(false, for: f.account.id), "fixture check: the warning stayed after it was cleared")
            let draft = DraftMessage(to: ["recipient@example.com"], subject: "Revoked send", body: "Body of the send")
            var message = OutboxMessage(accountId: f.account.id, draft: draft)
            message.holdUntil = Date().addingTimeInterval(-60)
            let seeded = message
            try await f.pool.write { db in try seeded.insert(db) }
            for _ in 0..<drains {
                try #require(await OutboxDrainLatch.waitForClear(), "an earlier drain still owns the outbox")
                await AccountManager.shared.drainOutbox()
            }
            try #require(await OutboxDrainLatch.waitForClear(), "the last send drain never let the outbox go")
            let refusalsOfTheSend = refusals.withLock { $0 } - refusalsOfTheAction
            #expect(refusalsOfTheSend > 0, "\(kind): the send never asked the refused sign-in for a token")
            #expect(await warningReaches(true, for: f.account.id),
                    "\(kind) \(code): the send's refusal did not tell the user to sign in again")

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
            #expect(held.outboxStatus == .failed,
                    "\(kind): the send did not become failed (visible, with Retry) after three refused drains")
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
                #expect(current?.outboxStatus == .failed,
                        "\(kind): the failed send changed state before the user pressed Retry")
                #expect(AccountManager.shared.retryOutboxMessage(seeded.id))
                // Retry starts its own drain in an unawaited task. When that drain
                // takes the outbox first, this call returns at once
                // (`isDrainingOutbox`) while the send is still on its way, so the
                // row is read only once no drain owns the outbox.
                await AccountManager.shared.drainOutbox()
                try #require(await OutboxDrainLatch.waitForClear(),
                             "\(kind): the drain after Retry never let the outbox go")
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
        RefreshFailure(testDescription: "an unknown code that contains a known one") {
            OAuthError.tokenExchangeFailed("not_interaction_required")
        },
        RefreshFailure(testDescription: "offline") { URLError(.notConnectedToInternet) },
        RefreshFailure(testDescription: "timed out") { URLError(.timedOut) },
        RefreshFailure(testDescription: "an HTML error page") {
            DecodingError.dataCorrupted(.init(codingPath: [], debugDescription: "not JSON"))
        },
    ]

    /// The codes with which the token endpoint itself refuses the grant.
    static let refused = ["invalid_grant", "invalid_client", "unauthorized_client", " INVALID_GRANT\n"]

    /// The codes with which the token endpoint asks for something only the user, or
    /// their admin, can do: another sign-in step or consent (Microsoft), a Workspace
    /// admin restriction (Google). Signing in again is how the user takes the step
    /// or gives the consent, and how access comes back once an admin acts, so they
    /// warn the same way (#659).
    static let needsTheUser = [
        "interaction_required", "consent_required", "admin_policy_enforced", " Interaction_Required\n",
    ]

    /// Every code after which the user is told to sign in again.
    static let warns = refused + needsTheUser

    private func refreshThroughTheAccessor(
        _ failure: @escaping @Sendable () -> any Error
    ) async throws -> (accountId: String, error: (any Error)?) {
        let harness = CredentialTestHarness(), store = harness.provider
        let accountId = "revoked-signal-" + UUID().uuidString
        try store.install(accountId: accountId, tokens: CredentialTestHarness.tokens())
        let accessor = await AccountManager.shared.makeOAuthAccessor(
            accountId: accountId, email: "user@example.com",
            store: store, refreshCoordinator: OAuthRefreshCoordinator(store: store)
        ) { _ in throw failure() }
        do {
            _ = try await accessor(true)
            return (accountId, nil)
        } catch {
            return (accountId, error)
        }
    }

    /// The OAuth code a caught error carries, if it is the token endpoint's refusal.
    private static func tokenExchangeCode(_ error: (any Error)?) -> String? {
        guard case OAuthError.tokenExchangeFailed(let code)? = error else { return nil }
        return code
    }

    @Test("A token endpoint that could not answer does not tell the user to sign in again", arguments: indeterminate)
    func indeterminateFailureRaisesNoWarning(_ failure: RefreshFailure) async throws {
        let (accountId, error) = try await refreshThroughTheAccessor(failure.make)
        #expect(error != nil, "the failed refresh returned a token")
        // The caller receives the refresher's own error, unchanged: this also
        // proves the refresher ran and its failure reached the accessor.
        #expect(error.map { String(reflecting: $0) } == String(reflecting: failure.make()),
                "\(failure.testDescription): the accessor did not rethrow the refresher's error unchanged")
        #expect(await warningReaches(false, for: accountId),
                "\(failure.testDescription): a transient failure told the user their sign-in is broken")
        await AccountManager.shared.clearAuthFailed(accountId)
    }

    @Test("A refused grant, or a sign-in that needs the user, tells the user to sign in again",
          arguments: warns)
    func refusedGrantRaisesTheWarning(_ code: String) async throws {
        let (accountId, error) = try await refreshThroughTheAccessor { OAuthError.tokenExchangeFailed(code) }
        #expect(error != nil, "the refused refresh returned a token")
        #expect(Self.tokenExchangeCode(error) == code,
                "\(code): the accessor did not rethrow the refusal unchanged")
        // The warning is raised before the refusal is rethrown, so it is already
        // set when the caller sees the error.
        #expect(await AccountManager.shared.authFailedAccounts.contains(accountId),
                "\(code): the warning was not raised before the refusal reached the caller")
        #expect(await warningReaches(true, for: accountId), "\(code): the user was not told to sign in again")
        await AccountManager.shared.clearAuthFailed(accountId)
    }

    /// A token endpoint's answer as the provider sends it, and the code a refresh
    /// reads from it.
    struct TokenAnswer: Sendable, CustomTestStringConvertible {
        let testDescription: String
        let kind: AccountProvider
        let body: String
        let code: String
        let warns: Bool
    }

    /// The code is the answer's top-level `error` field; the same word anywhere
    /// else in the answer says nothing.
    static let tokenAnswers: [TokenAnswer] = [
        TokenAnswer(
            testDescription: "Google admin restriction", kind: .gmail,
            body: #"{"error":"admin_policy_enforced","error_description":"Access is restricted by the administrator."}"#,
            code: "admin_policy_enforced", warns: true),
        TokenAnswer(
            testDescription: "Microsoft further sign-in step", kind: .outlook,
            body: #"{"error":"interaction_required","error_description":"Another sign-in step is required.","error_codes":[50076],"suberror":"basic_action"}"#,
            code: "interaction_required", warns: true),
        TokenAnswer(
            testDescription: "a known code only in the description", kind: .outlook,
            body: #"{"error":"invalid_request","error_description":"interaction_required"}"#,
            code: "invalid_request", warns: false),
        TokenAnswer(
            testDescription: "known codes only in fields the client does not read", kind: .gmail,
            body: #"{"error_description":"admin_policy_enforced","suberror":"consent_required"}"#,
            code: "unknown", warns: false),
    ]

    /// The refresh a resource request's 401 forces, through the app's own token
    /// request and the endpoint's answer as sent, so the warning rests on the code
    /// the real decoder reads.
    @Test("The token endpoint's answer warns only on its top-level code", arguments: tokenAnswers)
    func tokenEndpointAnswerWarnsOnItsCode(_ answer: TokenAnswer) async throws {
        let harness = CredentialTestHarness(), store = harness.provider
        let accountId = "revoked-answer-" + UUID().uuidString
        let stored = CredentialTestHarness.tokens()
        try store.install(accountId: accountId, tokens: stored)
        let http = FakeHTTP.Scenario()
        defer { http.close() }
        http.register(path: "token", method: "POST", response: .json(raw: answer.body, statusCode: 400))
        let service = await OAuthService(tokenSession: http.session)
        let kind = answer.kind
        let accessor = await AccountManager.shared.makeOAuthAccessor(
            accountId: accountId, email: "user@example.com",
            store: store, refreshCoordinator: OAuthRefreshCoordinator(store: store)
        ) { refreshToken in
            if kind == .outlook { return try await service.refreshMicrosoftToken(refreshToken: refreshToken) }
            return try await service.refreshGoogleToken(refreshToken: refreshToken)
        }
        var caught: (any Error)?
        do { _ = try await accessor(true) } catch { caught = error }

        let code = Self.tokenExchangeCode(caught)
        #expect(code == answer.code, "\(answer.testDescription): the refresh did not read the answer's top-level code")
        #expect(await warningReaches(answer.warns, for: accountId),
                "\(answer.testDescription): the warning does not follow the answer's top-level code")
        await AccountManager.shared.clearAuthFailed(accountId)

        let posts = http.recordedCalls().filter { $0.method == "POST" }
        let postedTo = posts.map { $0.url }
        #expect(posts.count == 1, "\(answer.testDescription): token requests: \(postedTo)")
        guard posts.count == 1 else { return }
        let endpoint = kind == .outlook
            ? "https://login.microsoftonline.com/common/oauth2/v2.0/token"
            : "https://oauth2.googleapis.com/token"
        #expect(posts[0].url == endpoint)
        let fields = FormDecoding.fields(posts[0].body.flatMap { String(data: $0, encoding: .utf8) } ?? "")
        let presented = fields["refresh_token"]
        let expected = stored.refreshToken.map { [$0] }
        #expect(presented == expected, "\(answer.testDescription): the refresh did not present the stored sign-in")
    }

    @Test("A refusal of a sign-in the user has already replaced does not warn about the new one",
          arguments: warns)
    func refusalOfAReplacedSignInRaisesNoWarning(_ code: String) async throws {
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
            throw OAuthError.tokenExchangeFailed(code)
        }
        let refresh = Task { try await accessor(true) }
        await started.wait()
        // The user signs in again while the old sign-in's refresh is on the wire.
        try store.install(accountId: accountId, tokens: .init(
            accessToken: "new-access", refreshToken: "new-refresh", expiresAt: Date().addingTimeInterval(3600)))
        await release.signal()
        let result = await refresh.result
        #expect(Self.tokenExchangeCode(result.failure) == code,
                "\(code): the old sign-in's refusal did not reach the caller unchanged")

        #expect(await warningReaches(false, for: accountId),
                "\(code): the old sign-in's refusal told the user to sign in again after they had")
        await AccountManager.shared.clearAuthFailed(accountId)
    }

    @Test("A refusal that lands after the account was removed does not warn", arguments: warns)
    func refusalAfterRemovalRaisesNoWarning(_ code: String) async throws {
        let harness = CredentialTestHarness(), store = harness.provider
        var account = Account(
            emailAddress: "removed-\(UUID().uuidString)@example.com", displayName: "Removed", provider: .gmail)
        account.id = "revoked-removed-" + UUID().uuidString
        let accountId = account.id
        try store.install(accountId: accountId, tokens: CredentialTestHarness.tokens())
        let started = CredentialTestLatch(), release = CredentialTestLatch()
        let accessor = await AccountManager.shared.makeOAuthAccessor(
            accountId: accountId, email: account.emailAddress,
            store: store, refreshCoordinator: OAuthRefreshCoordinator(store: store)
        ) { _ in
            await started.signal()
            await release.wait()
            throw OAuthError.tokenExchangeFailed(code)
        }
        let refresh = Task { try await accessor(true) }
        await started.wait()
        // The user removes the account while the refresh is on the wire. The
        // credential in this store stays, so only the removal can stop the warning.
        await AccountManager.shared.disconnectAccount(account, deletingCredentials: [])
        #expect(AccountManager.shared.isRuntimeRemoved(accountId))
        #expect(store.activation(accountId: accountId) != nil, "the credential the test relies on is gone")
        await release.signal()
        let result = await refresh.result
        #expect(Self.tokenExchangeCode(result.failure) == code,
                "\(code): the removed account's refusal did not reach the caller unchanged")

        #expect(await warningReaches(false, for: accountId),
                "\(code): a removed account was told to sign in again")
        await AccountManager.shared.clearAuthFailed(accountId)
    }

    @Test("A refusal warns only for the sign-in its refresh began with, on an account still there")
    func refusalWarnsOnlyForTheInstalledSignIn() async throws {
        let harness = CredentialTestHarness(), store = harness.provider
        let accountId = "revoked-generation-" + UUID().uuidString
        let old = try store.install(accountId: accountId, tokens: CredentialTestHarness.tokens()).generation
        let current = try store.install(accountId: accountId, tokens: .init(
            accessToken: "new-access", refreshToken: "new-refresh", expiresAt: Date().addingTimeInterval(3600))).generation
        #expect(old != current, "fixture check: the new sign-in kept the old one's generation")

        await AccountManager.shared.markAuthFailed(accountId, refusedSignIn: old, store: store)
        #expect(await warningReaches(false, for: accountId), "a refusal of the replaced sign-in warned")
        await AccountManager.shared.markAuthFailed(accountId, refusedSignIn: current, store: store)
        #expect(await warningReaches(true, for: accountId), "a refusal of the installed sign-in did not warn")
        await AccountManager.shared.clearAuthFailed(accountId)

        var removed = Account(
            emailAddress: "removed-\(UUID().uuidString)@example.com", displayName: "Removed", provider: .gmail)
        removed.id = "revoked-generation-removed-" + UUID().uuidString
        let removedId = removed.id
        let generation = try store.install(accountId: removedId, tokens: CredentialTestHarness.tokens()).generation
        await AccountManager.shared.disconnectAccount(removed, deletingCredentials: [])
        #expect(store.activation(accountId: removedId)?.generation == generation,
                "fixture check: the credential the test relies on is gone")
        await AccountManager.shared.markAuthFailed(removedId, refusedSignIn: generation, store: store)
        #expect(await warningReaches(false, for: removedId), "a removed account was told to sign in again")
        await AccountManager.shared.clearAuthFailed(removedId)
    }

    /// The text from `start` up to, not including, the first `end` after it.
    private static func slice(of source: String, from start: String, to end: String) -> String? {
        guard let lower = source.range(of: start),
              let upper = source.range(of: end, range: lower.upperBound..<source.endIndex) else { return nil }
        return String(source[lower.lowerBound..<upper.lowerBound])
    }

    /// A check made before the hop to the account actor could pass, a new sign-in
    /// then be installed and its warning cleared, and the insert put the warning
    /// back. The tests above settle the sign-in before the refusal is released, and
    /// no schedule a test can set up lands in that gap, so the source is read: the
    /// accessor's refusal branch makes no check of its own and calls only the
    /// guarded writer, whose check and insert are one actor method with no
    /// suspension point between them.
    @Test("The refusal's check and the warning's insert run in one turn of the account actor")
    func refusalCheckAndInsertShareOneActorTurn() throws {
        let source = try AppLogStoreTests.projectFile("TabMail/Services/Account/AccountManager.swift")

        let accessorText = Self.slice(of: source, from: "func makeOAuthAccessor(", to: "\n    }\n")
        let accessor = try #require(accessorText, "makeOAuthAccessor was not found")
        let branchText = Self.slice(of: accessor, from: "} catch {", to: "throw error")
        let branch = try #require(branchText, "the accessor's refusal branch was not found")
        #expect(branch.contains("await self.markAuthFailed(accountId, refusedSignIn: generation, store: store)"),
                "the refusal branch does not call the guarded writer")
        #expect(!branch.contains("isRuntimeRemoved"), "the refusal branch checks the removal before the hop")
        #expect(!branch.contains("activation("), "the refusal branch checks the sign-in before the hop")
        #expect(!branch.contains("markAuthFailed(accountId)"), "the refusal branch calls the unguarded writer")

        let signature = "func markAuthFailed(_ accountId: String, refusedSignIn generation: String, store: ProviderCredentialStore) {"
        #expect(!source.contains("nonisolated " + signature), "the guarded writer does not run on the actor")
        let writerText = Self.slice(of: source, from: signature, to: "\n    }\n")
        let writer = try #require(writerText, "the guarded writer was not found")
        #expect(writer.contains("!isRuntimeRemoved(accountId)"), "the guarded writer does not check the removal")
        #expect(writer.contains("store.activation(accountId: accountId)?.generation == generation"),
                "the guarded writer does not check the installed sign-in")
        #expect(writer.contains("authFailedAccounts.insert(accountId)"), "the guarded writer does not raise the warning")
        #expect(!writer.contains("await"), "the guarded writer can suspend between its check and its insert")
    }

    // MARK: - The calendar queue

    /// One calendar change queued for an Outlook account whose token comes from the
    /// real accessor over a test credential store holding an expired sign-in, so
    /// the first request refreshes it with `refresher`. The change goes to the fake
    /// Graph calendar through the real `ExchangeCalendarProvider` and the real
    /// queue (`AccountManager.drainCalendarQueue`).
    private func withCalendarChange(
        refresher: @escaping @Sendable (_ refreshToken: String) async throws -> OAuthTokens,
        _ body: (_ accountId: String, _ store: ProviderCredentialStore, _ op: PendingCalendarOperation,
                 _ db: CalendarQueueTestDatabase, _ graph: FakeGraphCalendar) async throws -> Void
    ) async throws {
        let harness = CredentialTestHarness(), store = harness.provider
        let accountId = "revoked-calendar-" + UUID().uuidString
        try store.install(accountId: accountId, tokens: CredentialTestHarness.tokens())
        let graph = FakeGraphCalendar([])
        let http = FakeHTTP.Scenario()
        graph.install(on: http)
        let accessor = await AccountManager.shared.makeOAuthAccessor(
            accountId: accountId, email: "cal@example.com",
            store: store, refreshCoordinator: OAuthRefreshCoordinator(store: store), refresher: refresher)
        let provider = ExchangeCalendarProvider(mailbox: "cal@example.com", accessToken: accessor, session: http.session)
        let db = try CalendarQueueTestDatabase(accountId: accountId)
        await AccountManager.shared.registerCalendarProviderForTesting(accountId: accountId, provider: provider)
        let start = GraphFixture.onDevice(days: 2, hour: 10)
        let zone = TimeZone.current.identifier
        let op = PendingCalendarOperation(
            operationType: .create, accountId: accountId, eventId: "precreated659", calendarId: "primary",
            arguments: [
                "title": .string("Planning"),
                "start_iso": .string(GraphFixture.wall(start, in: zone)),
                "end_iso": .string(GraphFixture.wall(start.addingTimeInterval(3_600), in: zone)),
            ], eventTitle: "Planning")
        var failure: (any Error)?
        do {
            try await db.pool.write { db in try op.insert(db) }
            try await body(accountId, store, op, db, graph)
        } catch {
            failure = error
        }
        await AccountManager.shared.clearAuthFailed(accountId)
        await AccountManager.shared.unregisterCalendarProviderForTesting(accountId: accountId)
        // A refused grant retires the change and loads it into the shared list of
        // late calendar failures; empty that list while this database is still the
        // installed one, so the failure does not outlive the test.
        try? await db.pool.write { db in _ = try PendingCalendarOperation.deleteAll(db) }
        await LateCalendarFailureStore.shared.reload()
        http.close()
        db.finish()
        withExtendedLifetime(harness) {}
        if let failure { throw failure }
    }

    @Test("A calendar change waits while its sign-in needs the user, and goes through once a token is issued again",
          arguments: needsTheUser)
    func calendarChangeWaitsForTheUser(_ code: String) async throws {
        let refusing = Mutex(true), refusals = Mutex(0)
        try await withCalendarChange(refresher: { _ in
            if refusing.withLock({ $0 }) {
                refusals.withLock { $0 += 1 }
                throw OAuthError.tokenExchangeFailed(code)
            }
            return Self.newSignIn()
        }) { accountId, _, op, db, graph in
            // Two drains while the token is refused: the change is retried, never given up.
            for attempt in 1...2 {
                let before = refusals.withLock { $0 }
                await AccountManager.shared.drainCalendarQueue()
                let after = refusals.withLock { $0 }
                #expect(after > before, "\(code), drain \(attempt): the change did not ask for a token")
                let row = try await db.pool.read { db in try PendingCalendarOperation.fetchOne(db, key: op.id) }
                #expect(row?.status == PendingStatus.queued.rawValue,
                        "\(code), drain \(attempt): the change left the queue (\(String(describing: row?.status)), \(row?.failureReason ?? "no reason"))")
                #expect(row?.failureKind == nil,
                        "\(code), drain \(attempt): it was recorded as a failure of kind \(String(describing: row?.failureKind))")
                #expect(row?.failureReason == nil,
                        "\(code), drain \(attempt): it was given a failure reason: \(row?.failureReason ?? "")")
            }
            #expect(await warningReaches(true, for: accountId), "\(code): the user was not told to sign in again")
            #expect(graph.writes.isEmpty, "\(code): a write went out without a token: \(graph.writes)")

            // A token is issued again (the user took the step, or an admin lifted the restriction).
            refusing.withLock { $0 = false }
            await AccountManager.shared.drainCalendarQueue()
            let rows = try await db.pool.read { db in try PendingCalendarOperation.fetchAll(db) }
            #expect(rows.isEmpty,
                    "\(code): the change did not leave the queue once a token was issued: \(rows.map { "\($0.status) \($0.failureReason ?? "")" })")
            let made = graph.created
            let subject = made.first?["subject"] as? String
            #expect(made.count == 1 && subject == "Planning", "\(code): the change was not made exactly once: \(graph.writes)")
        }
    }

    @Test("A refusal of a replaced sign-in that reaches the calendar queue does not warn about the new one",
          arguments: warns)
    func calendarRefusalOfAReplacedSignInRaisesNoWarning(_ code: String) async throws {
        let started = CredentialTestLatch(), release = CredentialTestLatch()
        try await withCalendarChange(refresher: { _ in
            await started.signal()
            await release.wait()
            throw OAuthError.tokenExchangeFailed(code)
        }) { accountId, store, _, _, graph in
            let drain = Task { await AccountManager.shared.drainCalendarQueue() }
            await started.wait()
            // The user signs in again while the old sign-in's refresh is on the wire.
            try store.install(accountId: accountId, tokens: .init(
                accessToken: "new-access", refreshToken: "new-refresh", expiresAt: Date().addingTimeInterval(3600)))
            await release.signal()
            await drain.value
            #expect(graph.writes.isEmpty, "\(code): fixture check: the refused attempt reached the server: \(graph.writes)")
            #expect(await warningReaches(false, for: accountId),
                    "\(code): the old sign-in's refusal, through the calendar queue, told the user to sign in again after they had")
        }
    }

    // MARK: - Password (IMAP and iCloud) sign-ins

    /// IMAP and iCloud accounts never reach the OAuth accessor. Their sign-in
    /// warning is raised by the provider's login-refusal reporter, which reads
    /// the refusal's response code, never by matching error text. The server
    /// answers below go over the wire to a real `IMAPProvider`.
    @Test("A temporary IMAP login refusal does not tell the user to sign in again, a refused password does")
    func temporaryIMAPLoginRefusalIsNotAnAuthFailure() async throws {
        let server = FakeIMAPServer(mailboxes: ["INBOX": []])
        try server.start()
        defer { server.stop() }
        let accountId = "revoked-imap-\(UUID().uuidString)"
        let provider = IMAPProvider(
            host: "127.0.0.1", port: server.port,
            username: server.username, password: server.password,
            smtpHost: "127.0.0.1", smtpPort: 587, useTLS: false,
            signInOutcome: AccountManager.shared.makeSignInOutcomeReporter(accountId: accountId))
        func isMarked() async -> Bool { await AccountManager.shared.authFailedAccounts.contains(accountId) }

        server.failNextCommand(containing: "LOGIN", message: "[UNAVAILABLE] Service temporarily unavailable")
        do { try await provider.connect() } catch {}
        #expect(await !isMarked(), "a server that was briefly unavailable told the user their password is wrong")

        await provider.markDirty()
        server.failNextCommand(containing: "LOGIN", message: "[AUTHENTICATIONFAILED] Invalid credentials (Failure)")
        do { try await provider.connect() } catch {}
        #expect(await isMarked(), "a refused password raised no warning")

        try? await provider.disconnect()
        await AccountManager.shared.clearAuthFailed(accountId)
    }
}

private extension Result {
    var failure: Failure? {
        if case .failure(let error) = self { return error }
        return nil
    }
}
