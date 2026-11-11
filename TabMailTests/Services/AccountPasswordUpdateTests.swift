/* This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at https://mozilla.org/MPL/2.0/. */

import Foundation
import GRDB
import Synchronization
import Testing
@testable import TabMail

/// Update Password, for every account that signs in with a password, as the user
/// sees it: what is saved to the Keychain, which providers become live, and the
/// "sign in again" mark. Driven through `AccountManager.updatePassword` against
/// `FakeIMAPServer` (mail) and a `FakeHTTP` CalDAV server that accepts one
/// password (calendar).
///
/// - iCloud (mail and calendar on one app-specific password): both must accept
///   the new password; then both are saved. Any failure saves nothing.
/// - Plain IMAP with a calendar that had the same password: the calendar follows
///   only if it accepts; otherwise the mail alone is updated.
/// - Calendar only: the calendar step alone.
/// - An account removed or changed while the prompt was open: nothing is saved,
///   and the alert says so.
@Suite("Update Password for every password account", .serialized, .processGlobalState, .timeLimit(.minutes(2)))
struct AccountPasswordUpdateTests {

    private static let oldPassword = "fixture-old"
    private static let newPassword = "fixture-new"
    private static let otherPassword = "fixture-other"
    private static let calendarUser = "calendar-user@example.com"
    private static let calendarServerURL = "https://caldav.example.com"
    private static let calendarHomePath = "/calendars/fixture/"

    // MARK: - Fake CalDAV server

    /// A CalDAV server that serves discovery to requests carrying one accepted
    /// password (HTTP Basic) and answers 401 to every other. It can instead fail
    /// every request without refusing the password (`failEveryRequest`), or hold
    /// its next request until the test releases it (`stallNextRequest`).
    final class FakeCalendarServer: Sendable {
        /// A failure that is not a refusal of the password.
        enum Failure: Sendable {
            case serverError
            case transportError
        }

        /// One held request: `entered` yields once the request arrives; the
        /// response is produced only after `release()`.
        final class Stall: Sendable {
            let entered: AsyncStream<Void>
            private let enteredContinuation: AsyncStream<Void>.Continuation
            private let gate = DispatchSemaphore(value: 0)

            init() {
                (entered, enteredContinuation) = AsyncStream.makeStream()
            }

            fileprivate func arrive() {
                enteredContinuation.yield()
                enteredContinuation.finish()
            }

            fileprivate func waitForRelease() { gate.wait() }

            func release() { gate.signal() }
        }

        /// What the request handler reads. A class of its own so the handler can
        /// hold it without holding the server.
        private final class State: Sendable {
            let acceptedHeader: Mutex<String>
            let failure = Mutex<Failure?>(nil)
            let nextStall = Mutex<Stall?>(nil)
            init(_ header: String) { acceptedHeader = Mutex(header) }
        }

        let http = FakeHTTP.Scenario()
        private let state: State

        init(username: String, accepting password: String) {
            let state = State(Self.authorization(username: username, password: password))
            self.state = state
            let principalXML = Self.principalXML
            let homeXML = Self.homeXML
            http.register(path: "/", method: "PROPFIND") { request in
                let response: FakeHTTP.CannedResponse
                switch state.failure.withLock({ $0 }) {
                case .serverError:
                    response = .status(500)
                case .transportError:
                    response = .transportError(.networkConnectionLost)
                case nil:
                    if request.header("Authorization") == state.acceptedHeader.withLock({ $0 }) {
                        let xml = request.url.path.hasPrefix("/principals/") ? homeXML : principalXML
                        response = .raw(statusCode: 207, headers: ["Content-Type": "application/xml; charset=utf-8"],
                                        body: Data(xml.utf8))
                    } else {
                        response = .status(401)
                    }
                }
                guard let stall = state.nextStall.withLock({ held -> Stall? in
                    defer { held = nil }
                    return held
                }) else { return response }
                stall.arrive()
                return .parked {
                    stall.waitForRelease()
                    return response
                }
            }
        }

        func accept(username: String, password: String) {
            state.acceptedHeader.withLock { $0 = Self.authorization(username: username, password: password) }
        }

        func failEveryRequest(_ failure: Failure) {
            state.failure.withLock { $0 = failure }
        }

        func stallNextRequest() -> Stall {
            let stall = Stall()
            state.nextStall.withLock { $0 = stall }
            return stall
        }

        var requestCount: Int { http.recordedCalls().count }

        private static func authorization(username: String, password: String) -> String {
            "Basic " + Data("\(username):\(password)".utf8).base64EncodedString()
        }

        private static let principalXML = """
            <?xml version="1.0" encoding="utf-8"?>
            <d:multistatus xmlns:d="DAV:">
              <d:response>
                <d:href>/</d:href>
                <d:propstat>
                  <d:prop><d:current-user-principal><d:href>/principals/fixture/</d:href></d:current-user-principal></d:prop>
                  <d:status>HTTP/1.1 200 OK</d:status>
                </d:propstat>
              </d:response>
            </d:multistatus>
            """

        private static let homeXML = """
            <?xml version="1.0" encoding="utf-8"?>
            <d:multistatus xmlns:d="DAV:" xmlns:c="urn:ietf:params:xml:ns:caldav">
              <d:response>
                <d:href>/principals/fixture/</d:href>
                <d:propstat>
                  <d:prop><c:calendar-home-set><d:href>\(AccountPasswordUpdateTests.calendarHomePath)</d:href></c:calendar-home-set></d:prop>
                  <d:status>HTTP/1.1 200 OK</d:status>
                </d:propstat>
              </d:response>
            </d:multistatus>
            """
    }

    // MARK: - Fixture

    /// Whether the account has a calendar, and what password it was stored with.
    enum CalendarLink: Sendable {
        case none
        case samePassword
        case otherPassword
    }

    struct Fixture {
        let server: FakeIMAPServer
        let calendarServer: FakeCalendarServer
        let account: Account
        let config: CalDAVConfig?
        let pool: DatabasePool
        let oldMail: IMAPProvider?
        let oldCalendar: CalDAVProvider?
    }

    /// An account of `kind` stored in an installed test database, with its old
    /// password in the Keychain and its old providers registered. The calendar
    /// server accepts the NEW password unless a test says otherwise.
    private func withAccount(
        _ kind: AccountProvider,
        calendar link: CalendarLink,
        _ body: (Fixture) async throws -> Void
    ) async throws {
        let manager = AccountManager.shared
        let (pool, dir, previous) = try FolderEpochTestFixture.makeAppDB()
        let server = FakeIMAPServer(mailboxes: ["INBOX": []])
        try server.start()
        let calendarServer = FakeCalendarServer(username: Self.calendarUser, accepting: Self.newPassword)

        var account = Account(emailAddress: "update-\(UUID().uuidString.prefix(8))@example.com",
                              displayName: "Update fixture", provider: kind)
        if kind == .caldav {
            account.calendarOnly = true
        } else {
            account.imapHost = "127.0.0.1"
            account.imapPort = server.port
            account.imapUsername = server.username
        }
        let stored = account
        try await pool.write { db in try stored.insert(db) }

        var config: CalDAVConfig?
        if link != .none {
            var made = CalDAVConfig(accountId: account.id, serverURL: Self.calendarServerURL,
                                    username: Self.calendarUser, displayName: "Fixture Calendar")
            made.principalURL = Self.calendarServerURL + "/principals/fixture/"
            made.calendarHomeURL = Self.calendarServerURL + Self.calendarHomePath
            let toInsert = made
            try await pool.write { db in try toInsert.insert(db) }
            config = made
        }

        if !account.calendarOnly {
            try KeychainHelper.save(Self.oldPassword, for: KeychainHelper.passwordKey(accountId: account.id))
        }
        if let config {
            let calendarPassword = link == .otherPassword ? Self.otherPassword : Self.oldPassword
            try KeychainHelper.save(calendarPassword, for: "caldav_password_\(config.id)")
        }

        manager.setIMAPUseTLSOverrideForTesting(false)
        manager.setCalDAVSessionOverrideForTesting(calendarServer.http.session)

        var oldMail: IMAPProvider?
        if !account.calendarOnly {
            let provider = try await manager.createIMAPProvider(for: account)
            await manager.registerProviderForTesting(accountId: account.id, provider: provider)
            oldMail = provider
        }
        var oldCalendar: CalDAVProvider?
        if let config, let home = URL(string: config.calendarHomeURL ?? ""), let base = URL(string: config.serverURL) {
            let provider = CalDAVProvider(
                client: manager.makeCalDAVClient(username: config.username, password: Self.oldPassword),
                calendarHomeURL: home, serverBaseURL: base)
            await manager.registerCalendarProviderForTesting(accountId: account.id, provider: provider)
            oldCalendar = provider
        }

        let accountId = account.id
        let configId = config?.id
        func finish() async {
            if let live = await manager.provider(accountId: accountId) { try? await live.disconnect() }
            await manager.unregisterProviderForTesting(accountId: accountId)
            await manager.unregisterCalendarProviderForTesting(accountId: accountId)
            await manager.syncEngine.remove(accountId: accountId)
            await manager.clearAuthFailed(accountId)
            KeychainHelper.delete(key: KeychainHelper.passwordKey(accountId: accountId))
            if let configId { KeychainHelper.delete(key: "caldav_password_\(configId)") }
            manager.setIMAPUseTLSOverrideForTesting(nil)
            manager.setCalDAVSessionOverrideForTesting(nil)
            calendarServer.http.close()
            server.stop()
            InstalledTestDatabaseLifetime.finish(previous: previous, pool: pool, directory: dir)
        }
        let fixture = Fixture(server: server, calendarServer: calendarServer, account: account, config: config,
                              pool: pool, oldMail: oldMail, oldCalendar: oldCalendar)
        do {
            try await body(fixture)
        } catch {
            await finish()
            throw error
        }
        await finish()
    }

    // MARK: - Observations

    private static func storedMailPassword(_ f: Fixture) -> String? {
        KeychainHelper.loadString(key: KeychainHelper.passwordKey(accountId: f.account.id))
    }

    private static func storedCalendarPassword(_ f: Fixture) -> String? {
        guard let config = f.config else { return nil }
        return KeychainHelper.loadString(key: "caldav_password_\(config.id)")
    }

    private static func liveMail(_ f: Fixture) async -> IMAPProvider? {
        await AccountManager.shared.provider(accountId: f.account.id) as? IMAPProvider
    }

    private static func liveCalendar(_ f: Fixture) async -> CalDAVProvider? {
        await AccountManager.shared.calendarProviders[f.account.id] as? CalDAVProvider
    }

    private static func isMarked(_ f: Fixture) async -> Bool {
        await AccountManager.shared.authFailedAccounts.contains(f.account.id)
    }

    private static func mailLoginCount(_ f: Fixture) -> Int {
        f.server.recordedCommands().filter { $0.hasPrefix("LOGIN") }.count
    }

    /// Run the update and return what it threw, if anything.
    private static func update(_ password: String, for account: Account) async -> (any Error)? {
        do {
            try await AccountManager.shared.updatePassword(password, for: account)
            return nil
        } catch {
            return error
        }
    }

    // MARK: - 1. Route table

    @Test("every account kind routes to exactly one sign-in path, and the other path refuses it")
    func routeTableOverEveryKind() async throws {
        let expected: [AccountProvider: SignInMethod] = [
            .imap: .password, .icloud: .password, .caldav: .password,
            .gmail: .oauth, .outlook: .oauth,
        ]
        #expect(Set(AccountProvider.allCases) == Set(expected.keys), "an account kind has no expected route")
        let manager = AccountManager.shared
        for kind in AccountProvider.allCases {
            #expect(kind.signInMethod == expected[kind], "\(kind) routes to the wrong sign-in path")
            let account = Account(emailAddress: "route@example.com", displayName: "Route", provider: kind)
            var thrown: (any Error)?
            switch expected[kind] {
            case .oauth:
                do { try await manager.updatePassword(Self.newPassword, for: account) } catch { thrown = error }
            case .password:
                do { try await manager.reauthenticateOAuth(for: account) } catch { thrown = error }
            case nil:
                continue
            }
            #expect(thrown as? ReauthenticationError == .signInMethodMismatch,
                    "\(kind): the other sign-in path did not refuse it (\(String(describing: thrown)))")
        }
    }

    @Test("the iCloud prompt asks for an app-specific password; other password accounts for their password")
    func promptNamesThePassword() {
        let icloud = Account(emailAddress: "prompt@example.com", displayName: "Prompt", provider: .icloud)
        #expect(PasswordPrompt.message(for: icloud).contains("app-specific password"))
        for kind in AccountProvider.allCases where kind.signInMethod == .password && kind != .icloud {
            let account = Account(emailAddress: "prompt@example.com", displayName: "Prompt", provider: kind)
            let message = PasswordPrompt.message(for: account)
            #expect(message.contains("password") && !message.contains("app-specific"), "\(kind): \(message)")
        }
    }

    // MARK: - 2. Mail accounts against FakeIMAPServer

    @Test("a good password is saved, made live, and clears the sign-in mark",
          arguments: [AccountProvider.imap, .icloud])
    func goodPasswordIsSavedAndLive(kind: AccountProvider) async throws {
        try await withAccount(kind, calendar: .none) { f in
            await AccountManager.shared.markAuthFailed(f.account.id)

            let thrown = await Self.update(Self.newPassword, for: f.account)

            #expect(thrown == nil, "\(String(describing: thrown))")
            #expect(Self.storedMailPassword(f) == Self.newPassword, "the new password was not saved")
            let live = try #require(await Self.liveMail(f), "no live mail provider after the update")
            #expect(live !== f.oldMail, "the old provider is still the live one")
            #expect(live.hasSignInOutcomeReporter, "the provider made live does not report sign-in outcomes")
            #expect(await !Self.isMarked(f), "the accepted password did not clear the sign-in mark")
        }
    }

    @Test("a refused password changes nothing, throws, and never marks the account",
          arguments: [AccountProvider.imap, .icloud])
    func refusedPasswordChangesNothing(kind: AccountProvider) async throws {
        try await withAccount(kind, calendar: .none) { f in
            f.server.failNextCommand(containing: "LOGIN", message: "[AUTHENTICATIONFAILED] Invalid credentials")

            let thrown = await Self.update(Self.newPassword, for: f.account)

            let error = try #require(thrown, "a refused password returned without an error")
            #expect(AccountReauthAlert.passwordUpdateLine(for: error, host: "127.0.0.1") == AccountReauthAlert.passwordLine,
                    "\(error)")
            #expect(Self.mailLoginCount(f) > 0, "the new password was not tried against the mail server")
            #expect(Self.storedMailPassword(f) == Self.oldPassword, "a refused password was saved")
            #expect(await Self.liveMail(f) === f.oldMail, "a refused password replaced the live provider")
            #expect(await !Self.isMarked(f), "a refused password typed in the prompt marked the account")
        }
    }

    // MARK: - 3. iCloud mail and calendar

    @Test("iCloud: the calendar password follows the mail password")
    func iCloudCalendarFollows() async throws {
        try await withAccount(.icloud, calendar: .samePassword) { f in
            let thrown = await Self.update(Self.newPassword, for: f.account)

            #expect(thrown == nil, "\(String(describing: thrown))")
            #expect(Self.storedMailPassword(f) == Self.newPassword)
            #expect(Self.storedCalendarPassword(f) == Self.newPassword, "the calendar password did not follow")
            #expect(await Self.liveMail(f) !== f.oldMail)
            let calendar = try #require(await Self.liveCalendar(f))
            #expect(calendar !== f.oldCalendar, "the calendar provider still signs in with the old password")
        }
    }

    @Test("iCloud: mail accepted and calendar refused changes nothing")
    func iCloudCalendarRefusedChangesNothing() async throws {
        try await withAccount(.icloud, calendar: .samePassword) { f in
            f.calendarServer.accept(username: Self.calendarUser, password: Self.otherPassword)

            let thrown = await Self.update(Self.newPassword, for: f.account)

            let error = try #require(thrown, "a calendar refusal returned without an error")
            #expect(AccountReauthAlert.passwordUpdateLine(for: error, host: "127.0.0.1") == AccountReauthAlert.passwordLine,
                    "\(error)")
            #expect(Self.mailLoginCount(f) > 0, "the mail server was not asked first")
            #expect(f.calendarServer.requestCount > 0, "the calendar was not asked")
            #expect(Self.storedMailPassword(f) == Self.oldPassword, "the mail password was saved anyway")
            #expect(Self.storedCalendarPassword(f) == Self.oldPassword)
            #expect(await Self.liveMail(f) === f.oldMail, "the mail provider was replaced anyway")
            #expect(await Self.liveCalendar(f) === f.oldCalendar)
            #expect(await !Self.isMarked(f))
        }
    }

    // MARK: - 4. Plain IMAP with a linked calendar

    enum LinkedCalendarCase: String, CaseIterable, Sendable {
        case samePasswordCalendarAccepts
        case samePasswordCalendarRefuses
        case differentStoredPassword
    }

    @Test("plain IMAP: the calendar follows only when it had the same password and accepts the new one",
          arguments: LinkedCalendarCase.allCases)
    func plainIMAPLinkedCalendar(_ linked: LinkedCalendarCase) async throws {
        let link: CalendarLink = linked == .differentStoredPassword ? .otherPassword : .samePassword
        try await withAccount(.imap, calendar: link) { f in
            if linked == .samePasswordCalendarRefuses {
                f.calendarServer.accept(username: Self.calendarUser, password: Self.otherPassword)
            }

            let thrown = await Self.update(Self.newPassword, for: f.account)

            #expect(thrown == nil, "\(linked): \(String(describing: thrown))")
            #expect(Self.storedMailPassword(f) == Self.newPassword, "\(linked): the mail password was not saved")
            #expect(await Self.liveMail(f) !== f.oldMail, "\(linked): the mail provider was not replaced")
            switch linked {
            case .samePasswordCalendarAccepts:
                #expect(Self.storedCalendarPassword(f) == Self.newPassword, "the calendar did not follow")
                #expect(await Self.liveCalendar(f) !== f.oldCalendar, "the calendar provider was not replaced")
            case .samePasswordCalendarRefuses:
                #expect(f.calendarServer.requestCount > 0, "the calendar was not asked")
                #expect(Self.storedCalendarPassword(f) == Self.oldPassword, "a refused calendar password was saved")
                #expect(await Self.liveCalendar(f) === f.oldCalendar, "a refusing calendar was replaced")
            case .differentStoredPassword:
                #expect(f.calendarServer.requestCount == 0, "a calendar with its own password was asked")
                #expect(Self.storedCalendarPassword(f) == Self.otherPassword, "a calendar with its own password was changed")
                #expect(await Self.liveCalendar(f) === f.oldCalendar)
            }
        }
    }

    @Test("a mail save that fails after the calendar save is repaired by trying the same password again",
          arguments: [AccountProvider.icloud, .imap])
    func failedMailSaveIsRepairedByRetry(kind: AccountProvider) async throws {
        try await withAccount(kind, calendar: .samePassword) { f in
            await AccountManager.shared.markAuthFailed(f.account.id)
            KeychainHelper.failNextSaveForTesting(key: KeychainHelper.passwordKey(accountId: f.account.id))
            defer { KeychainHelper.failNextSaveForTesting(key: nil) }

            let first = await Self.update(Self.newPassword, for: f.account)

            #expect(first is KeychainError, "\(kind): the failed mail save was not reported: \(String(describing: first))")
            #expect(Self.storedCalendarPassword(f) == Self.newPassword, "\(kind): the calendar save did not happen first")
            #expect(Self.storedMailPassword(f) == Self.oldPassword, "\(kind): the mail password changed despite the failed save")
            #expect(await Self.liveMail(f) === f.oldMail, "\(kind): the mail provider was replaced after a failed save")
            #expect(await Self.isMarked(f), "\(kind): a failed save cleared the sign-in mark")

            let retry = await Self.update(Self.newPassword, for: f.account)

            #expect(retry == nil, "\(kind): the retry failed: \(String(describing: retry))")
            #expect(Self.storedMailPassword(f) == Self.newPassword, "\(kind): the retry did not save the mail password")
            #expect(Self.storedCalendarPassword(f) == Self.newPassword, "\(kind): the calendar lost the new password")
            #expect(await Self.liveMail(f) !== f.oldMail, "\(kind): the retry did not replace the mail provider")
            let calendar = try #require(await Self.liveCalendar(f), "\(kind): no live calendar provider after the retry")
            #expect(calendar !== f.oldCalendar, "\(kind): the calendar provider still signs in with the old password")
            #expect(await !Self.isMarked(f), "\(kind): the retry did not clear the sign-in mark")
        }
    }

    struct CalendarFailureCase: Sendable, CustomTestStringConvertible {
        let kind: AccountProvider
        let failure: FakeCalendarServer.Failure
        var testDescription: String { "\(kind) \(failure)" }
    }

    @Test("a calendar failure that is not a refusal saves nothing, keeps the providers, and is not called a wrong password",
          arguments: [
            CalendarFailureCase(kind: .imap, failure: .serverError),
            CalendarFailureCase(kind: .imap, failure: .transportError),
            CalendarFailureCase(kind: .icloud, failure: .serverError),
            CalendarFailureCase(kind: .icloud, failure: .transportError),
          ])
    func calendarFailureThatIsNotARefusal(_ c: CalendarFailureCase) async throws {
        try await withAccount(c.kind, calendar: .samePassword) { f in
            f.calendarServer.failEveryRequest(c.failure)

            let thrown = await Self.update(Self.newPassword, for: f.account)

            let error = try #require(thrown, "\(c.testDescription): the update went ahead")
            let line = AccountReauthAlert.passwordUpdateLine(for: error, host: "127.0.0.1")
            #expect(line == nil || line == AccountReauthAlert.setupLine,
                    "\(c.testDescription): unexpected alert line for \(error)")
            #expect(line != AccountReauthAlert.passwordLine, "\(c.testDescription): a calendar failure was called a wrong password")
            #expect(f.calendarServer.requestCount > 0, "\(c.testDescription): the calendar was not asked")
            #expect(Self.storedMailPassword(f) == Self.oldPassword, "\(c.testDescription): the mail password was saved")
            #expect(Self.storedCalendarPassword(f) == Self.oldPassword, "\(c.testDescription): the calendar password was saved")
            #expect(await Self.liveMail(f) === f.oldMail, "\(c.testDescription): the mail provider was replaced")
            #expect(await Self.liveCalendar(f) === f.oldCalendar, "\(c.testDescription): the calendar provider was replaced")
            #expect(await !Self.isMarked(f), "\(c.testDescription): the account was marked for signing in again")
        }
    }

    @Test("an account removed while its new password is being checked: nothing is saved, and the alert says so",
          arguments: [AccountProvider.imap, .icloud])
    func accountRemovedDuringTheChecks(kind: AccountProvider) async throws {
        try await withAccount(kind, calendar: .samePassword) { f in
            let config = try #require(f.config)
            let stall = f.calendarServer.stallNextRequest()
            defer { stall.release() }
            let account = f.account

            let update = Task { await Self.update(Self.newPassword, for: account) }
            for await _ in stall.entered { break }
            // The mail server has accepted; the calendar check is in flight.
            await AccountManager.shared.disconnectAccount(account, deletingCredentials: [config.id])
            stall.release()
            let thrown = await update.value

            let error = try #require(thrown, "\(kind): the update went ahead for a removed account")
            #expect(AccountReauthAlert.passwordUpdateLine(for: error, host: "127.0.0.1") == AccountReauthAlert.accountChangedLine,
                    "\(kind): the alert did not say so (\(error))")
            #expect(Self.mailLoginCount(f) > 0, "\(kind): the mail check did not run before the removal")
            #expect(Self.storedMailPassword(f) == nil, "\(kind): a mail password was saved for a removed account")
            #expect(Self.storedCalendarPassword(f) == nil, "\(kind): a calendar password was saved for a removed account")
            #expect(await Self.liveMail(f) == nil, "\(kind): a removed account got a live mail provider")
            #expect(await Self.liveCalendar(f) == nil, "\(kind): a removed account got a live calendar provider")
        }
    }

    // MARK: - 5. Calendar only

    @Test("calendar only: a good password updates the calendar alone")
    func calendarOnlyGoodPassword() async throws {
        try await withAccount(.caldav, calendar: .samePassword) { f in
            let thrown = await Self.update(Self.newPassword, for: f.account)

            #expect(thrown == nil, "\(String(describing: thrown))")
            #expect(Self.storedCalendarPassword(f) == Self.newPassword, "the calendar password was not saved")
            #expect(await Self.liveCalendar(f) !== f.oldCalendar, "the calendar provider was not replaced")
            #expect(Self.mailLoginCount(f) == 0, "a calendar-only account tried a mail sign-in")
            #expect(Self.storedMailPassword(f) == nil, "a calendar-only account got a mail password")
            #expect(await Self.liveMail(f) == nil)
        }
    }

    @Test("calendar only: a refused password changes nothing and throws")
    func calendarOnlyRefusedPassword() async throws {
        try await withAccount(.caldav, calendar: .samePassword) { f in
            f.calendarServer.accept(username: Self.calendarUser, password: Self.otherPassword)

            let thrown = await Self.update(Self.newPassword, for: f.account)

            let error = try #require(thrown, "a refused calendar password returned without an error")
            #expect(AccountReauthAlert.passwordUpdateLine(for: error, host: "") == AccountReauthAlert.passwordLine,
                    "\(error)")
            #expect(Self.storedCalendarPassword(f) == Self.oldPassword)
            #expect(await Self.liveCalendar(f) === f.oldCalendar)
        }
    }

    // MARK: - 6. Account removed or replaced while the prompt was open

    /// How the stored account differs from the one the prompt opened on: gone,
    /// or different in one field that decides how it signs in.
    enum MidPromptChange: String, CaseIterable, Sendable {
        case removed
        case replaced // another user name
        case otherHost
        case otherPort
        case otherAddress
        case otherProvider
        case nowCalendarOnly
    }

    @Test("an account removed or replaced while the prompt was open: nothing is saved, and the alert says so",
          arguments: MidPromptChange.allCases)
    func accountChangedWhilePromptOpen(_ change: MidPromptChange) async throws {
        try await withAccount(.imap, calendar: .samePassword) { f in
            // The prompt opened on `promptAccount`; the stored row now differs
            // from it. Where a field differs, the prompt holds the other value and
            // the stored row stays a working account, so an update that ignored
            // the field would go through.
            let accountId = f.account.id
            var promptAccount = f.account
            switch change {
            case .removed:
                try await f.pool.write { db in _ = try Account.deleteOne(db, key: accountId) }
            case .replaced:
                try await f.pool.write { db in
                    try db.execute(sql: "UPDATE account SET imapUsername = ? WHERE id = ?",
                                   arguments: ["someone-else@example.com", accountId])
                }
            case .otherHost:
                promptAccount.imapHost = "imap.example.com"
            case .otherPort:
                promptAccount.imapPort = (f.account.imapPort ?? 0) + 1
            case .otherAddress:
                promptAccount.emailAddress = "someone-else@example.com"
            case .otherProvider:
                promptAccount.provider = .icloud
            case .nowCalendarOnly:
                promptAccount.calendarOnly = true
            }

            let thrown = await Self.update(Self.newPassword, for: promptAccount)

            let error = try #require(thrown, "\(change): the save went ahead")
            #expect(AccountReauthAlert.passwordUpdateLine(for: error, host: "127.0.0.1") == AccountReauthAlert.accountChangedLine,
                    "\(change): the alert did not say so (\(error))")
            #expect(Self.mailLoginCount(f) == 0, "\(change): the new password was sent to the server")
            #expect(f.calendarServer.requestCount == 0, "\(change): the new password was sent to the calendar")
            #expect(Self.storedMailPassword(f) == Self.oldPassword, "\(change): the mail password was saved")
            #expect(Self.storedCalendarPassword(f) == Self.oldPassword, "\(change): the calendar password was saved")
            #expect(await Self.liveMail(f) === f.oldMail)
            #expect(await Self.liveCalendar(f) === f.oldCalendar)
        }
    }
}
