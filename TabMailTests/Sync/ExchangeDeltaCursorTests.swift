/* This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at https://mozilla.org/MPL/2.0/. */

import Foundation
import GRDB
import Synchronization
import Testing
@testable import TabMail

/// The Outlook delta cursor (`Account.lastHistoryId`, a Graph `@odata.deltaLink`)
/// driven through production `SyncEngine` against a fake Graph.
///
/// Three invariants. The first two come from Microsoft Graph's documented delta
/// contract (learn.microsoft.com/graph/delta-query-overview, delta-query-messages):
///
/// 1. **A cursor is discarded only when Graph refuses it.** An expired token is
///    answered with "a 40X-series error with error codes such as
///    `syncStateNotFound`", and a reset with `410 Gone`, on any page of the
///    round. An authorization failure (401, 403), a timeout (408), a throttle
///    (429), a server error (5xx), no connection or a cancelled request says
///    nothing about the token, so the cursor must survive it and the next delta
///    pass retries it.
/// 2. **Every full sync ends with a new cursor for the account's Inbox**, whatever
///    cursor was held, so a full sync heals whatever the delta missed. Getting one
///    costs a walk of the whole folder ("the initial sync request doesn't include
///    any state token. This round returns all the messages in that folder"), so
///    the walk pages with `Prefer: odata.maxpagesize` instead of one message per
///    request.
/// 3. **Moving the Inbox in Settings launches a full sync** (`FolderRoleEdit` marks
///    it due, provider-blind), and that full sync takes the new Inbox's cursor.
///
/// `.serialized, .processGlobalState`: these tests replace `AppDatabase.shared`
/// so `SyncEngine.dbPool` resolves to the fixture pool.
@Suite("Exchange delta cursor: kept unless refused; every full sync takes a new one",
       .serialized, .processGlobalState)
struct ExchangeDeltaCursorTests {
    private static let inboxId = "f-inbox"
    private static let heldCursor =
        "https://graph.microsoft.com/v1.0/me/mailFolders('f-inbox')/messages/delta?$deltatoken=held"

    private static func seedAccount(
        id accountId: String, cursor: String?, pool: DatabasePool,
        provider: AccountProvider = .outlook, withInbox: Bool = true,
        lastFullSyncAt: Date? = nil, lastSyncedAt: Date? = nil
    ) throws -> Account {
        var account = Account(
            emailAddress: "\(accountId)@example.com",
            displayName: "Delta cursor fixture",
            provider: provider
        )
        account.id = accountId
        account.lastHistoryId = cursor
        account.lastFullSyncAt = lastFullSyncAt
        account.lastSyncedAt = lastSyncedAt
        let toInsert = account
        try pool.write { db in
            try toInsert.insert(db)
            if withInbox {
                try Folder(name: "Inbox", path: inboxId, role: .inbox, accountId: accountId).insert(db)
            }
        }
        return account
    }

    private static func storedCursor(_ accountId: String, pool: DatabasePool) throws -> String? {
        try pool.read { try Account.fetchOne($0, key: accountId) }?.lastHistoryId
    }

    private static func provider(_ accountId: String, _ http: FakeHTTP.Scenario) -> ExchangeProvider {
        ExchangeProvider(
            userEmail: "\(accountId)@example.com",
            accessToken: { _ in "fake-graph-token" },
            session: http.session
        )
    }

    private static func deltaRequests(_ http: FakeHTTP.Scenario) -> [String] {
        http.recordedCalls().map(\.url).filter { $0.contains("/messages/delta") }
    }

    // MARK: - Invariant 1: a transient failure keeps the cursor

    @Test("A transient failure on the first delta page keeps the cursor",
          arguments: [401, 403, 408, 429, 500, 502, 503, 504])
    func transientFailureKeepsTheCursor(status: Int) async throws {
        let (pool, dir, previous) = try FolderEpochTestFixture.makeAppDB()
        defer {
            AppDatabase.shared.withLock { $0 = previous }
            TestDatabaseTeardown.retire(pool: pool, directory: dir)
        }
        let accountId = "deltakeep\(status)"
        let account = try Self.seedAccount(id: accountId, cursor: Self.heldCursor, pool: pool)

        let http = FakeHTTP.Scenario()
        defer { http.close() }
        http.register(path: "/messages/delta", response: .status(status))

        let outcome = try? await SyncEngine().performDeltaSync(
            account: account, provider: Self.provider(accountId, http))

        #expect(!Self.deltaRequests(http).isEmpty, "precondition: the held cursor must have been tried")
        #expect(outcome?.succeeded != true)
        #expect(try Self.storedCursor(accountId, pool: pool) == Self.heldCursor,
                "HTTP \(status) says nothing about the token; the cursor must survive it")
    }

    @Test("No connection, or a cancelled request, on the first delta page fails the pass and keeps the cursor",
          arguments: [URLError.Code.notConnectedToInternet, .networkConnectionLost, .cancelled])
    func transportFailureKeepsTheCursor(code: URLError.Code) async throws {
        let (pool, dir, previous) = try FolderEpochTestFixture.makeAppDB()
        defer {
            AppDatabase.shared.withLock { $0 = previous }
            TestDatabaseTeardown.retire(pool: pool, directory: dir)
        }
        let accountId = "deltatransport\(code.rawValue)"
        let account = try Self.seedAccount(id: accountId, cursor: Self.heldCursor, pool: pool)

        let http = FakeHTTP.Scenario()
        defer { http.close() }
        http.register(path: "/messages/delta", response: .transportError(code))

        let outcome = try? await SyncEngine().performDeltaSync(
            account: account, provider: Self.provider(accountId, http))

        #expect(!Self.deltaRequests(http).isEmpty, "precondition: the held cursor must have been tried")
        #expect(outcome?.succeeded != true)
        #expect(try Self.storedCursor(accountId, pool: pool) == Self.heldCursor,
                "\(code) says nothing about the token; the cursor must survive it")
    }

    @Test("Graph refusing the token discards the cursor so the next full sync takes a new one",
          arguments: [400, 404, 410])
    func refusedTokenDiscardsTheCursor(status: Int) async throws {
        let (pool, dir, previous) = try FolderEpochTestFixture.makeAppDB()
        defer {
            AppDatabase.shared.withLock { $0 = previous }
            TestDatabaseTeardown.retire(pool: pool, directory: dir)
        }
        let accountId = "deltarefused\(status)"
        let account = try Self.seedAccount(id: accountId, cursor: Self.heldCursor, pool: pool)

        let http = FakeHTTP.Scenario()
        defer { http.close() }
        http.register(path: "/messages/delta", response: .json(
            raw: "{\"error\": {\"code\": \"syncStateNotFound\", \"message\": \"fixture\"}}",
            statusCode: status))

        let outcome = try await SyncEngine().performDeltaSync(
            account: account, provider: Self.provider(accountId, http))

        #expect(!Self.deltaRequests(http).isEmpty, "precondition: the held cursor must have been tried")
        #expect(outcome.succeeded == false)
        #expect(try Self.storedCursor(accountId, pool: pool) == nil)
    }

    // MARK: - Invariant 2: every full sync takes a new cursor, walked in coarse pages

    @Test("A full sync's capture walks the Inbox in pages of the configured size and stores the final deltaLink, whether or not a cursor is held",
          arguments: [false, true])
    func captureWalksTheInboxInCoarsePages(cursorHeld: Bool) async throws {
        let (pool, dir, previous) = try FolderEpochTestFixture.makeAppDB()
        defer {
            AppDatabase.shared.withLock { $0 = previous }
            TestDatabaseTeardown.retire(pool: pool, directory: dir)
        }
        let accountId = "deltacapture\(cursorHeld)"
        let account = try Self.seedAccount(id: accountId, cursor: cursorHeld ? Self.heldCursor : nil, pool: pool)

        let http = FakeHTTP.Scenario()
        defer { http.close() }
        // More than two pages of the configured size, so a page asked for without
        // it (the first or a later one) falls back to Graph's small default page.
        let pageSize = SyncConfig.graphDeltaCursorWalkPageSize
        let inbox = InboxModel(messageCount: 2 * pageSize + pageSize / 2)
        let prefers = Mutex<[String?]>([])
        http.register(path: "/messages/delta") { request in
            prefers.withLock { $0.append(request.header("Prefer")) }
            return inbox.serve(request)
        }

        await SyncEngine().captureSyncCursors(account: account, provider: Self.provider(accountId, http))

        let walk = Self.deltaRequests(http)
        #expect(walk.first?.contains("/mailFolders/\(Self.inboxId)/messages/delta") == true, "the capture walks the Inbox: \(walk)")
        #expect(walk.count == 3, "\(walk.count) requests to walk \(inbox.messageCount) messages")
        #expect(prefers.withLock { $0 } == Array(repeating: "odata.maxpagesize=\(pageSize)", count: walk.count),
                "every page of the walk asks for the configured page size")
        #expect(try Self.storedCursor(accountId, pool: pool) == InboxModel.finalDeltaLink,
                "the full sync takes a new cursor even when one is held")
    }

    // MARK: - A round that fails on a later page

    private static let continuation =
        "https://graph.microsoft.com/v1.0/me/mailFolders('f-inbox')/messages/delta?$skiptoken=page2"
    private static let nextCursor =
        "https://graph.microsoft.com/v1.0/me/mailFolders('f-inbox')/messages/delta?$deltatoken=next"

    /// The held cursor's round: its first page removes `m-gone` and continues to
    /// `continuation`, which `laterPage` answers. Requests for neither go to `walk`.
    private static func registerRound(
        _ http: FakeHTTP.Scenario, laterPage: FakeHTTP.CannedResponse, walk: InboxModel? = nil
    ) {
        http.register(path: "/messages/delta") { request in
            let url = request.url.absoluteString.removingPercentEncoding ?? request.url.absoluteString
            if url == Self.heldCursor {
                return .json(raw: "{\"value\": [{\"id\": \"m-gone\", \"@removed\": {\"reason\": \"deleted\"}}], \"@odata.nextLink\": \"\(Self.continuation)\"}")
            }
            if url == Self.continuation { return laterPage }
            if url == Self.nextCursor { return .json(raw: "{\"value\": [], \"@odata.deltaLink\": \"\(Self.nextCursor)\"}") }
            return walk?.serve(request) ?? .status(599)
        }
    }

    /// An Inbox email the held cursor's round removes.
    private static func seedRemovedEmail(_ accountId: String, pool: DatabasePool) throws {
        let header = MessageHeader(
            messageId: "m-gone", subject: "Fixture", from: "Sender", fromAddress: "sender@example.com",
            to: "\(accountId)@example.com", date: Date(), snippet: "",
            folderId: "\(accountId):\(inboxId)", accountId: accountId, folderPath: inboxId, isInInbox: true)
        try pool.write { try header.insert($0) }
    }

    private static func removedEmailIsStored(_ accountId: String, pool: DatabasePool) throws -> Bool {
        try pool.read { try MessageHeader.filter(Column("accountId") == accountId && Column("messageId") == "m-gone").fetchCount($0) } == 1
    }

    @Test("A transient failure on a later delta page fails the pass, applies nothing from the round, and keeps the cursor",
          arguments: [401, 403, 408, 429, 500, 503])
    func laterPageTransientFailureKeepsTheCursor(status: Int) async throws {
        let (pool, dir, previous) = try FolderEpochTestFixture.makeAppDB()
        defer {
            AppDatabase.shared.withLock { $0 = previous }
            TestDatabaseTeardown.retire(pool: pool, directory: dir)
        }
        let accountId = "deltalaterkeep\(status)"
        let account = try Self.seedAccount(id: accountId, cursor: Self.heldCursor, pool: pool)
        try Self.seedRemovedEmail(accountId, pool: pool)

        let http = FakeHTTP.Scenario()
        defer { http.close() }
        Self.registerRound(http, laterPage: .status(status))

        let outcome = try? await SyncEngine().performDeltaSync(account: account, provider: Self.provider(accountId, http))

        #expect(Self.deltaRequests(http).contains { ($0.removingPercentEncoding ?? $0) == Self.continuation },
                "precondition: the round reached its later page")
        #expect(outcome?.succeeded != true)
        #expect(try Self.removedEmailIsStored(accountId, pool: pool), "a failed round applies none of its pages")
        #expect(try Self.storedCursor(accountId, pool: pool) == Self.heldCursor,
                "HTTP \(status) on a later page says nothing about the token; the cursor must survive it")
    }

    @Test("Graph refusing the round on a later page discards the cursor, and the same sync's capture takes a new one",
          arguments: [400, 404, 410])
    func laterPageRefusalIsRecapturedBySameSync(status: Int) async throws {
        let (pool, dir, previous) = try FolderEpochTestFixture.makeAppDB()
        defer {
            AppDatabase.shared.withLock { $0 = previous }
            TestDatabaseTeardown.retire(pool: pool, directory: dir)
        }
        let accountId = "deltalaterrefused\(status)"
        // The Account value a sync reads at its start, which still names the held cursor
        // when the capture runs after the delta pass (`SyncEngine.sync(account:)`).
        let account = try Self.seedAccount(id: accountId, cursor: Self.heldCursor, pool: pool)
        try Self.seedRemovedEmail(accountId, pool: pool)

        let http = FakeHTTP.Scenario()
        defer { http.close() }
        Self.registerRound(
            http,
            laterPage: .json(raw: "{\"error\": {\"code\": \"resyncRequired\", \"message\": \"fixture\"}}", statusCode: status),
            walk: InboxModel(messageCount: 3))
        let provider = Self.provider(accountId, http)

        let outcome = try await SyncEngine().performDeltaSync(account: account, provider: provider)

        #expect(Self.deltaRequests(http).count == 2, "precondition: the round reached its later page")
        #expect(outcome.succeeded == false)
        #expect(try Self.removedEmailIsStored(accountId, pool: pool), "a refused round applies none of its pages")
        #expect(try Self.storedCursor(accountId, pool: pool) == nil)

        await SyncEngine().captureSyncCursors(account: account, provider: provider)

        #expect(Self.deltaRequests(http).count == 3, "the capture walks the Inbox, one page, for a new cursor")
        #expect(try Self.storedCursor(accountId, pool: pool) == InboxModel.finalDeltaLink)
    }

    @Test("A completed round stores Graph's new deltaLink, and the next pass asks for it")
    func completedRoundAdvancesTheCursor() async throws {
        let (pool, dir, previous) = try FolderEpochTestFixture.makeAppDB()
        defer {
            AppDatabase.shared.withLock { $0 = previous }
            TestDatabaseTeardown.retire(pool: pool, directory: dir)
        }
        let accountId = "deltaadvance"
        let account = try Self.seedAccount(id: accountId, cursor: Self.heldCursor, pool: pool)
        try Self.seedRemovedEmail(accountId, pool: pool)

        let http = FakeHTTP.Scenario()
        defer { http.close() }
        Self.registerRound(http, laterPage: .json(raw: "{\"value\": [], \"@odata.deltaLink\": \"\(Self.nextCursor)\"}"))
        let provider = Self.provider(accountId, http)

        let outcome = try await SyncEngine().performDeltaSync(account: account, provider: provider)

        #expect(outcome.succeeded)
        #expect(try !Self.removedEmailIsStored(accountId, pool: pool), "the round's removal is applied")
        #expect(try Self.storedCursor(accountId, pool: pool) == Self.nextCursor)

        var stored = account
        stored.lastHistoryId = try Self.storedCursor(accountId, pool: pool)
        _ = try? await SyncEngine().performDeltaSync(account: stored, provider: provider)

        let asked = Self.deltaRequests(http).map { $0.removingPercentEncoding ?? $0 }
        #expect(asked.count == 3)
        #expect(asked.last == Self.nextCursor, "the next pass starts from the new cursor, not the old one")
    }

    // MARK: - The full sync hands over to the capture

    /// The cursor a due full sync starts with.
    enum HeldCursor: String, CaseIterable, Sendable {
        case none
        /// Graph refuses it (`410 Gone`), so the delta pass discards it.
        case refused
        /// Graph answers it, and the delta pass keeps it.
        case working
    }

    @Test("A due full sync, through SyncEngine.sync, takes a new Inbox cursor whatever cursor it started with, and the next delta pass asks for it",
          arguments: HeldCursor.allCases)
    func fullSyncTakesTheCursor(held: HeldCursor) async throws {
        let (pool, dir, previous) = try FolderEpochTestFixture.makeAppDB()
        defer {
            AppDatabase.shared.withLock { $0 = previous }
            TestDatabaseTeardown.retire(pool: pool, directory: dir)
        }
        let accountId = "deltafullsync\(held.rawValue)"
        let account = try Self.seedAccount(
            id: accountId, cursor: held == .none ? nil : Self.heldCursor, pool: pool, withInbox: false)

        let wellKnown = ["inbox", "sentitems", "drafts", "deleteditems", "junkemail", "archive"]
        let root = "/v1.0/me/mailFolders"
        let walk = InboxModel(messageCount: 3)
        let http = FakeHTTP.Scenario()
        defer { http.close() }
        http.register(path: "/v1.0/me") { request in
            let url = request.url.absoluteString.removingPercentEncoding ?? request.url.absoluteString
            let path = request.url.path
            if url == Self.heldCursor {
                guard held == .working else {
                    return .json(raw: "{\"error\": {\"code\": \"syncStateNotFound\", \"message\": \"fixture\"}}", statusCode: 410)
                }
                return .json(raw: "{\"value\": [], \"@odata.deltaLink\": \"\(Self.heldCursor)\"}")
            }
            if path.hasSuffix("/messages/delta") { return walk.serve(request) }
            if path == root {
                let folders = wellKnown.map { "{\"id\":\"sys-\($0)\",\"displayName\":\"\($0)\",\"unreadItemCount\":0,\"totalItemCount\":0,\"childFolderCount\":0}" }
                return .json(raw: "{\"value\": [\(folders.joined(separator: ", "))]}")
            }
            if let name = wellKnown.first(where: { path == root + "/" + $0 }) {
                return .json(raw: "{\"id\":\"sys-\(name)\",\"displayName\":\"\(name)\"}")
            }
            if wellKnown.contains(where: { path == root + "/sys-" + $0 + "/messages" }) { return .json(raw: "{\"value\": []}") }
            return .status(404)
        }
        let provider = Self.provider(accountId, http)
        let engine = SyncEngine()
        await engine.register(accountId: accountId, provider: provider, workQueue: ProviderWorkQueue(provider: provider, maxConcurrency: 1))

        _ = try await engine.sync(account: account)
        await engine.cancelAllFTSTasks()

        let asked = Self.deltaRequests(http).map { $0.removingPercentEncoding ?? $0 }
        if held == .none {
            #expect(!asked.contains(Self.heldCursor), "\(asked)")
        } else {
            #expect(asked.first == Self.heldCursor, "precondition: the held cursor was tried first: \(asked)")
        }
        #expect(asked.contains { $0.contains("/mailFolders/sys-inbox/messages/delta") }, "the full sync's capture walked the Inbox: \(asked)")
        #expect(try Self.storedCursor(accountId, pool: pool) == InboxModel.finalDeltaLink)

        let stored = try #require(try await pool.read { try Account.fetchOne($0, key: accountId) })
        let outcome = try await engine.performDeltaSync(account: stored, provider: provider)

        #expect(outcome.succeeded)
        #expect(Self.deltaRequests(http).last.map { $0.removingPercentEncoding ?? $0 } == InboxModel.finalDeltaLink,
                "the next delta pass asks for the captured cursor")
    }

    // MARK: - Invariant 3: moving the Inbox launches a full sync

    /// Graph's message delta follows one folder (delta-query-messages), so a cursor
    /// taken for the Inbox keeps following that folder after another folder becomes
    /// the Inbox. Moving the Inbox marks the full sync due, and that full sync takes
    /// the new Inbox's cursor (invariant 2). Until it runs, the delta follows the old
    /// folder, which files every change by the message's own folder.

    private static let otherPath = "f-other"

    private static func seedOtherFolder(_ accountId: String, pool: DatabasePool) throws {
        try pool.write { try Folder(name: "Other", path: otherPath, role: .custom, accountId: accountId).insert($0) }
    }

    private static func roles(_ accountId: String, pool: DatabasePool) throws -> [String: FolderRole] {
        try pool.read { db in
            Dictionary(uniqueKeysWithValues: try Folder.filter(Column("accountId") == accountId).fetchAll(db).map { ($0.path, $0.role) })
        }
    }

    enum InboxEdit: String, CaseIterable, Sendable { case assignedElsewhere, cleared, setToCustom }

    private static func lastFullSyncAt(_ accountId: String, pool: DatabasePool) throws -> Date? {
        try pool.read { try Account.fetchOne($0, key: accountId) }?.lastFullSyncAt
    }

    @Test("A role edit that moves the Inbox marks the full sync due, for every provider; one that leaves the Inbox does not",
          arguments: InboxEdit.allCases, [AccountProvider.outlook, .gmail, .imap])
    func movingTheInboxMarksTheFullSyncDue(edit: InboxEdit, provider: AccountProvider) async throws {
        let (pool, dir, previous) = try FolderEpochTestFixture.makeAppDB()
        defer {
            AppDatabase.shared.withLock { $0 = previous }
            TestDatabaseTeardown.retire(pool: pool, directory: dir)
        }
        let accountId = "deltamove\(edit.rawValue)\(provider.rawValue)"
        let cursor = provider == .outlook ? Self.heldCursor : "123456"
        _ = try Self.seedAccount(id: accountId, cursor: cursor, pool: pool, provider: provider, lastFullSyncAt: Date())
        try Self.seedOtherFolder(accountId, pool: pool)
        let other = "\(accountId):\(Self.otherPath)"

        // Another role moves; the Inbox stays.
        let sentMoved = try await pool.write { db in try FolderRoleEdit.assign(.sent, to: other, accountId: accountId, db: db) }
        #expect(try Self.roles(accountId, pool: pool)[Self.otherPath] == .sent, "control: the edit was made")
        #expect(!sentMoved)
        #expect(try Self.lastFullSyncAt(accountId, pool: pool) != nil, "an edit that leaves the Inbox does not make a full sync due")

        let inboxMoved = try await pool.write { db in
            switch edit {
            case .assignedElsewhere:
                try FolderRoleEdit.assign(.inbox, to: other, accountId: accountId, db: db)
            case .cleared:
                try FolderRoleEdit.clear(.inbox, accountId: accountId, db: db)
            case .setToCustom:
                try FolderRoleEdit.set(.custom, folderId: "\(accountId):\(Self.inboxId)", accountId: accountId, db: db)
            }
        }

        let roles = try Self.roles(accountId, pool: pool)
        #expect(roles[Self.inboxId] == .custom, "control: the old Inbox is no longer the Inbox: \(roles)")
        #expect(inboxMoved, "Settings starts a sync only when told the Inbox moved")
        #expect(try Self.lastFullSyncAt(accountId, pool: pool) == nil, "moving the Inbox makes the full sync due")
        #expect(try Self.storedCursor(accountId, pool: pool) == cursor, "the cursor is left for the full sync to replace")
    }

    @Test("After the Inbox moves, the account's next sync runs the full sync, whose capture walks the new Inbox",
          arguments: [false, true])
    func syncAfterMovingTheInboxTakesTheNewInboxCursor(inboxMoved: Bool) async throws {
        let (pool, dir, previous) = try FolderEpochTestFixture.makeAppDB()
        defer {
            AppDatabase.shared.withLock { $0 = previous }
            TestDatabaseTeardown.retire(pool: pool, directory: dir)
        }
        let accountId = "deltamovesync\(inboxMoved)"
        // A full sync ran a minute ago, so none is due unless the edit makes one due;
        // the last sync is older than the recent-sync check.
        _ = try Self.seedAccount(
            id: accountId, cursor: Self.heldCursor, pool: pool,
            lastFullSyncAt: Date().addingTimeInterval(-60), lastSyncedAt: Date().addingTimeInterval(-60))
        try Self.seedOtherFolder(accountId, pool: pool)
        if inboxMoved {
            let moved = try await pool.write { db in
                try FolderRoleEdit.assign(.inbox, to: "\(accountId):\(Self.otherPath)", accountId: accountId, db: db)
            }
            #expect(moved)
        }
        // What Settings hands the sync: the account read back after the edit.
        let account = try #require(try await pool.read { try Account.fetchOne($0, key: accountId) })

        let walk = InboxModel(messageCount: 3)
        let http = FakeHTTP.Scenario()
        defer { http.close() }
        http.register(path: "/v1.0/me") { request in
            let url = request.url.absoluteString.removingPercentEncoding ?? request.url.absoluteString
            let path = request.url.path
            if url == Self.heldCursor { return .json(raw: "{\"value\": [], \"@odata.deltaLink\": \"\(Self.heldCursor)\"}") }
            if path.hasSuffix("/messages/delta") { return walk.serve(request) }
            if path == "/v1.0/me/mailFolders" {
                let folders = [Self.inboxId, Self.otherPath].map {
                    "{\"id\":\"\($0)\",\"displayName\":\"\($0)\",\"unreadItemCount\":0,\"totalItemCount\":0,\"childFolderCount\":0}"
                }
                return .json(raw: "{\"value\": [\(folders.joined(separator: ", "))]}")
            }
            if path.hasSuffix("/messages") { return .json(raw: "{\"value\": []}") }
            return .status(404)
        }
        let provider = Self.provider(accountId, http)
        let engine = SyncEngine()
        await engine.register(accountId: accountId, provider: provider, workQueue: ProviderWorkQueue(provider: provider, maxConcurrency: 1))

        _ = try await engine.sync(account: account)
        await engine.cancelAllFTSTasks()

        let asked = Self.deltaRequests(http).map { $0.removingPercentEncoding ?? $0 }
        #expect(asked.first == Self.heldCursor, "precondition: the pass ran its delta first: \(asked)")
        #expect(try Self.roles(accountId, pool: pool)[Self.otherPath] == (inboxMoved ? .inbox : .custom),
                "control: the full sync keeps the roles set in Settings")
        if inboxMoved {
            #expect(asked.contains { $0.contains("/mailFolders/\(Self.otherPath)/messages/delta") },
                    "the full sync's capture walks the new Inbox: \(asked)")
            #expect(!asked.contains { $0.contains("/mailFolders/\(Self.inboxId)/messages/delta") }, "\(asked)")
            #expect(try Self.storedCursor(accountId, pool: pool) == InboxModel.finalDeltaLink)
            #expect(try Self.lastFullSyncAt(accountId, pool: pool) != nil, "the full sync ran")
        } else {
            #expect(asked == [Self.heldCursor], "control: with no full sync due the pass only runs its delta: \(asked)")
            #expect(try Self.storedCursor(accountId, pool: pool) == Self.heldCursor)
        }
    }

    // MARK: - The capture walk resumes where it stopped

    /// The `$skiptoken` of each walk request (the initial round's pages; the held
    /// cursor's own delta carries a `$deltatoken` and is left out), "0" for page 1.
    private static func walkPages(_ http: FakeHTTP.Scenario) -> [String] {
        deltaRequests(http).compactMap { url -> String? in
            let items = URLComponents(string: url)?.queryItems ?? []
            if items.contains(where: { $0.name == "$deltatoken" }) { return nil }
            return items.first { $0.name == "$skiptoken" }?.value ?? "0"
        }
    }

    /// A walk that stops partway keeps its place on the provider: the next walk
    /// of the same folder starts at the page it had not got, not at page 1. A kept
    /// page link Graph refuses restarts the walk at page 1 within the same call; a
    /// walk of another folder starts at its own page 1; a finished walk keeps
    /// nothing. Pages are 100 messages (the `Prefer` size), five per walk.
    @Test("A walk that stopped partway resumes from its next page; a refused kept link or another folder starts at page 1")
    func walkResumesWhereItStopped() async throws {
        let walk = InboxModel(messageCount: 500)
        // One failure, served once, for the page whose `$skiptoken` is the key.
        let failOnce = Mutex<[String: Int]>([:])
        let http = FakeHTTP.Scenario()
        defer { http.close() }
        http.register(path: "/v1.0/me") { request in
            let items = URLComponents(url: request.url, resolvingAgainstBaseURL: false)?.queryItems ?? []
            let page = items.first { $0.name == "$skiptoken" }?.value ?? "0"
            if let status = failOnce.withLock({ $0.removeValue(forKey: page) }) { return .status(status) }
            if request.url.path.hasSuffix("/messages/delta") { return walk.serve(request) }
            return .status(404)
        }
        let provider = Self.provider("deltawalkresume", http)
        var seen = 0
        func newPages() -> [String] {
            let all = Self.walkPages(http)
            defer { seen = all.count }
            return Array(all.dropFirst(seen))
        }

        // A server error on page 3 fails the walk after two pages.
        failOnce.withLock { $0["200"] = 503 }
        await #expect(throws: (any Error).self) { _ = try await provider.getCurrentDeltaLink(folderId: Self.inboxId) }
        #expect(newPages() == ["0", "100", "200"])

        // The next walk resumes at page 3 and finishes.
        #expect(try await provider.getCurrentDeltaLink(folderId: Self.inboxId) == InboxModel.finalDeltaLink)
        #expect(newPages() == ["200", "300", "400"], "the walk resumed where it stopped")

        // A finished walk keeps nothing: the next one starts at page 1.
        #expect(try await provider.getCurrentDeltaLink(folderId: Self.inboxId) == InboxModel.finalDeltaLink)
        #expect(newPages() == ["0", "100", "200", "300", "400"])

        // Stopped again at page 3; then Graph refuses the kept link (410 Gone):
        // the same call starts again at page 1 and finishes.
        failOnce.withLock { $0["200"] = 503 }
        await #expect(throws: (any Error).self) { _ = try await provider.getCurrentDeltaLink(folderId: Self.inboxId) }
        #expect(newPages() == ["0", "100", "200"])
        failOnce.withLock { $0["200"] = 410 }
        #expect(try await provider.getCurrentDeltaLink(folderId: Self.inboxId) == InboxModel.finalDeltaLink)
        #expect(newPages() == ["200", "0", "100", "200", "300", "400"], "a refused kept link restarts the walk")

        // Stopped at page 2 of the Inbox; a walk of another folder starts at its own page 1.
        failOnce.withLock { $0["100"] = 503 }
        await #expect(throws: (any Error).self) { _ = try await provider.getCurrentDeltaLink(folderId: Self.inboxId) }
        #expect(newPages() == ["0", "100"])
        let before = Self.deltaRequests(http).count
        _ = try await provider.getCurrentDeltaLink(folderId: "f-other")
        let otherFirst = Self.deltaRequests(http).dropFirst(before).first.map { $0.removingPercentEncoding ?? $0 }
        #expect(otherFirst?.contains("/mailFolders/f-other/messages/delta") == true,
                "another folder's walk starts at its own page 1: \(otherFirst ?? "none")")
    }

    /// The capture walk runs inside the foreground pass, which
    /// `AccountManager.foregroundSyncOne` cuts at a per-account deadline. A large
    /// Inbox's walk can need longer than one pass has: each pass then walks the
    /// pages it has time for and the next pass continues, so within a bounded
    /// number of passes the full sync is recorded with a fresh link, and the
    /// walk requests stay near the folder's page count (a cut pass redoes at most
    /// the page it was waiting on). Passes run under production `withTimeout`.
    @Test("A capture walk longer than the pass deadline finishes over later passes without starting again")
    func walkLongerThanTheDeadlineFinishes() async throws {
        let (pool, dir, previous) = try FolderEpochTestFixture.makeAppDB()
        defer {
            AppDatabase.shared.withLock { $0 = previous }
            TestDatabaseTeardown.retire(pool: pool, directory: dir)
        }
        let accountId = "deltawalkdeadline"
        _ = try Self.seedAccount(id: accountId, cursor: Self.heldCursor, pool: pool)

        let pages = 24
        let pageSeconds = 0.25
        let deadline = 2.0
        let maxPasses = 12
        let walk = InboxModel(messageCount: pages * SyncConfig.graphDeltaCursorWalkPageSize)
        let http = FakeHTTP.Scenario()
        defer { http.close() }
        http.register(path: "/v1.0/me") { request in
            let url = request.url.absoluteString.removingPercentEncoding ?? request.url.absoluteString
            let path = request.url.path
            if url == Self.heldCursor { return .json(raw: "{\"value\": [], \"@odata.deltaLink\": \"\(Self.heldCursor)\"}") }
            if path.hasSuffix("/messages/delta") {
                return .parked {
                    Thread.sleep(forTimeInterval: pageSeconds)
                    return walk.serve(request)
                }
            }
            if path == "/v1.0/me/mailFolders" {
                return .json(raw: "{\"value\": [{\"id\":\"\(Self.inboxId)\",\"displayName\":\"Inbox\",\"unreadItemCount\":0,\"totalItemCount\":0,\"childFolderCount\":0}]}")
            }
            if path.hasSuffix("/messages") { return .json(raw: "{\"value\": []}") }
            return .status(404)
        }
        let provider = Self.provider(accountId, http)
        let engine = SyncEngine()
        await engine.register(accountId: accountId, provider: provider, workQueue: ProviderWorkQueue(provider: provider, maxConcurrency: 1))

        var passes = 0
        var timedOut = 0
        var recorded = false
        while passes < maxPasses, !recorded {
            // A later poll: the last pass is past the 15 s recent-sync skip.
            try await pool.write { db in
                _ = try Account.filter(Column("id") == accountId)
                    .updateAll(db, Column("lastSyncedAt").set(to: Date().addingTimeInterval(-300)))
            }
            let account = try #require(try await pool.read { try Account.fetchOne($0, key: accountId) })
            passes += 1
            do {
                _ = try await withTimeout(seconds: deadline) { try await engine.sync(account: account) }
            } catch is TimeoutError {
                timedOut += 1
            }
            // A cut pass unwinds after `withTimeout` returns; wait until it has
            // handed the turn back before reading what it left.
            let unwindBy = Date().addingTimeInterval(10)
            while await engine.syncPassRunning.contains(accountId), Date() < unwindBy {
                try await Task.sleep(for: .milliseconds(20))
            }
            #expect(await !engine.syncPassRunning.contains(accountId), "the cut pass handed the turn back")
            let stored = try #require(try await pool.read { try Account.fetchOne($0, key: accountId) })
            recorded = stored.lastFullSyncAt != nil && stored.lastHistoryId == InboxModel.finalDeltaLink
        }
        await engine.cancelAllFTSTasks()

        let walked = Self.walkPages(http)
        #expect(timedOut >= 1, "precondition: the walk is longer than one pass's deadline (passes \(passes))")
        #expect(recorded, "the full sync is recorded with a fresh link within \(maxPasses) passes (walk requests \(walked.count))")
        #expect(walked.count <= pages + passes, "the walk continued instead of starting again: \(walked.count) requests for \(pages) pages over \(passes) passes")
        #expect(walked.filter { $0 == "0" }.count == 1, "page 1 is walked once: \(walked.prefix(12))")
    }

    /// The initial delta round over an Inbox of `messageCount` messages.
    ///
    /// Page size: `Prefer: odata.maxpagesize` is the documented control ("to set
    /// the maximum number of messages in a response"). What `$top` does in a
    /// message delta is not documented, so the model takes the pessimistic
    /// reading the cost concern rests on, that it caps the page. With neither,
    /// the model returns 10 per page: what Graph has been observed to return, not a
    /// documented default.
    private struct InboxModel: Sendable {
        let messageCount: Int
        static let defaultPageSize = 10
        static let finalDeltaLink =
            "https://graph.microsoft.com/v1.0/me/mailFolders('f-inbox')/messages/delta?$deltatoken=fresh"

        func serve(_ request: FakeHTTP.Request) -> FakeHTTP.CannedResponse {
            let items = URLComponents(url: request.url, resolvingAgainstBaseURL: false)?.queryItems ?? []
            func intItem(_ name: String) -> Int? {
                items.first { $0.name == name }.flatMap { $0.value.flatMap(Int.init) }
            }
            if items.contains(where: { $0.name == "$deltatoken" }) {
                return .json(raw: "{\"value\": [], \"@odata.deltaLink\": \"\(Self.finalDeltaLink)\"}")
            }
            let start = intItem("$skiptoken") ?? 0
            let preferred = request.header("Prefer").flatMap { prefer -> Int? in
                guard let range = prefer.range(of: "odata.maxpagesize=") else { return nil }
                return Int(prefer[range.upperBound...].prefix { $0.isNumber })
            }
            // `$top` is carried in the nextLink, as Graph's state token encodes
            // the initial request's options; the Prefer header is per request.
            let top = intItem("$top")
            let pageSize: Int
            switch (top, preferred) {
            case let (t?, p?): pageSize = min(t, p)
            case let (t?, nil): pageSize = t
            case let (nil, p?): pageSize = p
            case (nil, nil): pageSize = Self.defaultPageSize
            }
            let end = min(start + pageSize, messageCount)
            let values = (start..<end).map { "{\"id\": \"m\($0)\"}" }.joined(separator: ", ")
            let link = end < messageCount
                ? "\"@odata.nextLink\": \"https://graph.microsoft.com/v1.0/me/mailFolders('f-inbox')/messages/delta?$skiptoken=\(end)\(top.map { "&$top=\($0)" } ?? "")\""
                : "\"@odata.deltaLink\": \"\(Self.finalDeltaLink)\""
            return .json(raw: "{\"value\": [\(values)], \(link)}")
        }
    }
}
