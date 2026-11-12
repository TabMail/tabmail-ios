/* This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at https://mozilla.org/MPL/2.0/. */

import Foundation
import GRDB
import Testing
@testable import TabMail

/// A DRAFT THAT NEVER REACHED THE SERVER STAYS OPENABLE ACROSS AN APP UPDATE (#519).
///
/// The sequence is the production one end to end: `AccountManager.queueDraftSave`
/// writes the `draft-…` placeholder header and queues `.saveDraft`; the app-release
/// boundary (`AppDatabase.init` → `retirePreviousReleaseActionQueue`) retires that
/// operation and marks the account full-sync-due; the Drafts folder's full sync
/// (`SyncEngine.runSyncMessages`) then runs against a server that never received
/// the draft. The sync used to delete the placeholder, the only row the draft opens
/// from: through the whole-folder branch on every provider, and through the date
/// window on Gmail and Outlook.
///
/// Reachability is measured through the production open route,
/// `ServerDraftComposeLoader.resolveOpenAuthority`, with a provider of the
/// account's runtime kind registered, over every Drafts header the server did
/// not list: the question is whether any row still opens the user's draft.
///
/// The other two tests pin the scope from the other side: a placeholder whose
/// draft is gone, or whose draft has a server copy, is still removed, so no row
/// that opens nothing (or a second row for one draft) is left in Drafts.
///
/// `.serialized, .processGlobalState`: these tests swap `AppDatabase.shared` and
/// drive `AccountManager.shared` and `SearchIndex.shared`, like
/// `AppReleaseBoundaryAdmissionTests`.
@Suite("Never-uploaded draft placeholders and the full sync", .serialized, .processGlobalState)
struct NeverUploadedDraftPlaceholderSyncTests {

    // MARK: - Cases

    struct ProviderCase: Sendable, CustomTestStringConvertible {
        let provider: AccountProvider
        let windowMode: StaleWindowMode
        let runtimeKind: DraftRuntimeIdentityKind
        var testDescription: String { provider.rawValue }
    }

    /// Every account provider that has mail (`.caldav` is calendar-only), with the
    /// stale window its real `EmailProvider` uses (`IMAPProvider` is `.uid`; Gmail
    /// and Graph take the protocol's `.date`) and the runtime its drafts open under.
    static let providers: [ProviderCase] = [
        ProviderCase(provider: .imap, windowMode: .uid, runtimeKind: .imap),
        ProviderCase(provider: .icloud, windowMode: .uid, runtimeKind: .imap),
        ProviderCase(provider: .gmail, windowMode: .date, runtimeKind: .gmail),
        ProviderCase(provider: .outlook, windowMode: .date, runtimeKind: .outlook),
    ]

    /// The two stale-deletion branches of `runSyncMessages`. The mock reports
    /// whole-folder coverage when it returns fewer messages than the limit, and a
    /// window when the page is full.
    enum Branch: String, Sendable, CaseIterable, CustomTestStringConvertible {
        case wholeFolder
        case window
        var testDescription: String { rawValue }
    }

    /// Where the stale rule reaches a placeholder at all: the whole-folder branch
    /// on every provider, and the date window. The UID window never selects a
    /// non-numeric id (`selectStaleHeaders`), so a removal test there has nothing
    /// to measure.
    static let removalCases: [(ProviderCase, Branch)] = providers.flatMap { item in
        item.windowMode == .date ? [(item, .wholeFolder), (item, .window)] : [(item, .wholeFolder)]
    }

    // MARK: - Harness

    private struct Fixture {
        let pool: DatabasePool
        let directory: URL
        let previous: AppDatabase?
        let accountId: String
        let item: ProviderCase
    }

    private static let draftsPath = "Drafts"
    /// A release string that is not, and cannot become, the running bundle's.
    private static let previousRelease = "0.0.1 (1)"
    private static let epoch = "E-never-uploaded"

    @MainActor
    private func fixture(_ item: ProviderCase, _ label: String) throws -> Fixture {
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
        // Unique per test: `SearchIndex.shared` is one process-wide FTS database.
        let accountId = "nu-\(label)-\(item.provider.rawValue)-\(UUID().uuidString.prefix(8))"
        try pool.writeWithoutTransaction { db in
            var account = Account(
                emailAddress: "\(accountId)@example.com", displayName: "Never uploaded",
                provider: item.provider)
            account.id = accountId
            account.lastFullSyncAt = Date()
            try account.insert(db)
            try Folder(name: "Drafts", path: Self.draftsPath, role: .drafts, accountId: accountId)
                .insert(db)
        }
        return Fixture(pool: pool, directory: directory, previous: previous,
                       accountId: accountId, item: item)
    }

    private func finish(_ fixture: Fixture) {
        InstalledTestDatabaseLifetime.finish(
            previous: fixture.previous, pool: fixture.pool,
            queues: [], directory: fixture.directory)
    }

    /// `queueDraftSave` kicks an unstructured drain; wait for it before the
    /// relaunch so the boundary, not the drain, is what is measured.
    @MainActor
    private func settle() async {
        for _ in 0..<200 {
            if await AccountManager.shared.pendingQueueIsQuiescentForTesting() { return }
            try? await Task.sleep(for: .milliseconds(10))
        }
    }

    /// The user's draft, saved through the production Save path while the server
    /// could not be reached, then carried across an app update. Returns the draft
    /// id and its placeholder header id.
    @MainActor
    private func saveThenUpdate(
        _ f: Fixture, serverDraftId: String? = nil
    ) async throws -> (draftId: String, placeholderHeaderId: String) {
        let now = Date().timeIntervalSince1970
        var draft = Draft(
            id: "draft-key-\(f.accountId)", accountId: f.accountId,
            toJSON: "[\"recipient@example.com\"]", ccJSON: "[]", bccJSON: "[]",
            subject: "Written offline", body: "Quixotic words the user typed",
            replyToId: nil, isForward: false, editHistoryJSON: nil,
            createdAt: now, updatedAt: now,
            serverDraftId: serverDraftId, serverPushStatus: serverDraftId == nil ? nil : "dirty",
            rfc822MessageId: nil, attachmentsDirName: nil)
        draft.instanceEpoch = Self.epoch
        let stored = draft
        try await f.pool.writeWithoutTransaction { db in try stored.insert(db) }

        let admitted = await AccountManager.shared.queueDraftSave(
            draftId: stored.id, accountId: f.accountId)
        #expect(admitted, "the production Save path did not admit the save")
        await settle()
        let placeholderHeaderId = PendingOperation.draftPlaceholderHeaderPK(
            accountId: f.accountId, draftsFolderPath: Self.draftsPath,
            draftId: stored.id, instanceEpoch: Self.epoch)
        #expect(try headerExists(f, id: placeholderHeaderId),
                "the save did not write its placeholder header, so there is nothing to keep")

        // THE APP UPDATE: the boundary retires the queued save.
        try await f.pool.writeWithoutTransaction { db in
            try db.execute(sql: """
                INSERT INTO appReleaseStamp (id, release) VALUES (1, ?)
                ON CONFLICT(id) DO UPDATE SET release = excluded.release
                """, arguments: [Self.previousRelease])
        }
        _ = try AppDatabase(dbPool: f.pool)
        // #531 (owner 2026-11-12): the boundary re-queues this unsent draft's
        // save. A queued save protects the placeholder by itself, so remove it
        // here to keep measuring the full sync's own stale rule (the state
        // after that save is gone for any other reason).
        #expect(try operationCount(f) == 1, "the boundary did not re-queue the unsent draft's save")
        try await f.pool.writeWithoutTransaction { db in
            try db.execute(sql: "DELETE FROM pendingOperation")
        }
        return (stored.id, placeholderHeaderId)
    }

    /// The server's Drafts listing: other drafts, older than the user's, and never
    /// the user's own. A full page (`count == limit`) is a window; a short one is
    /// the whole folder.
    private func serverDrafts(_ item: ProviderCase, branch: Branch, ids: [String]? = nil)
        -> (messages: [MessageHeaderInfo], limit: Int) {
        let names = ids ?? (item.windowMode == .uid ? ["7", "8"] : ["srv-a", "srv-b"])
        let messages = names.enumerated().map { index, name in
            MessageHeaderInfo(
                messageId: name, rfc822MessageId: "\(name)-\(item.provider.rawValue)@example.com",
                inReplyTo: nil, references: [], threadId: nil,
                subject: "Server draft \(name)", from: "Owner", fromAddress: "owner@example.com",
                to: "someone@example.com", cc: "", bcc: "", replyTo: nil,
                date: Date().addingTimeInterval(-Double(index + 2) * 86_400), snippet: "server",
                isRead: true, isFlagged: false, hasAttachments: false,
                isReplied: false, isForwarded: false, actionTag: nil)
        }
        return (messages, branch == .window ? messages.count : messages.count + 50)
    }

    private func runDraftsSync(
        _ f: Fixture, messages: [MessageHeaderInfo], limit: Int
    ) async throws -> SyncEngine.SyncMessagesResult {
        let drafts = try folderRow(f)
        let mock = MockEmailProvider(staleWindowMode: f.item.windowMode)
        await mock.setFetchMessagesResult(messages)
        return try await SyncEngine.runSyncMessages(
            for: drafts, provider: mock, limit: limit,
            dbPool: PrioritizedDatabase(pool: f.pool))
    }

    // Synchronous reads: GRDB's async `read` overload would win inside an async
    // test body, and an `await` cannot sit in an `#expect` autoclosure.
    private func headerExists(_ f: Fixture, id: String) throws -> Bool {
        try f.pool.read { db in try MessageHeader.fetchOne(db, key: id) != nil }
    }

    private func bodyExists(_ f: Fixture, id: String) throws -> Bool {
        try f.pool.read { db in try MessageBody.fetchOne(db, key: ContentKey(rawValue: id)) != nil }
    }

    private func operationCount(_ f: Fixture) throws -> Int {
        try f.pool.read { db in try PendingOperation.fetchCount(db) }
    }

    private func folderRow(_ f: Fixture) throws -> Folder {
        let key = MessageIdentity.folderId(accountId: f.accountId, folderPath: Self.draftsPath)
        return try #require(try f.pool.read { db in try Folder.fetchOne(db, key: key) })
    }

    /// A provider of the case's runtime kind, as production registers one for
    /// the account. Its HTTP goes to `http`, which has no routes.
    private func provider(_ item: ProviderCase, http: FakeHTTP.Scenario) -> any EmailProvider {
        switch item.runtimeKind {
        case .gmail:
            GmailProvider(userEmail: "owner@example.com", accessToken: { _ in "token" }, session: http.session)
        case .outlook:
            ExchangeProvider(userEmail: "owner@example.com", accessToken: { _ in "token" }, session: http.session)
        default:
            IMAPProvider(
                host: "127.0.0.1", port: 1, username: "owner", password: "unused",
                smtpHost: "127.0.0.1", smtpPort: 1, useTLS: false)
        }
    }

    /// Every draft id some Drafts row opens, through the production open route
    /// (`ServerDraftComposeLoader.resolveOpenAuthority`, which every Drafts open
    /// starts with). No fixture's row should fail to resolve: a thrown open is
    /// the retryable load failure, which production shows instead of the final
    /// "no editable copy" answer, so it fails the test rather than counting as
    /// "opens nothing". The rows named in `serverIds` are the server's other
    /// drafts and are left out, as opening one reads the server.
    @MainActor
    private func openableDraftIds(_ f: Fixture, serverIds: [String] = []) async throws -> [String] {
        let folderId = MessageIdentity.folderId(accountId: f.accountId, folderPath: Self.draftsPath)
        let headers = try await f.pool.read { db in
            try MessageHeader.filter(Column("folderId") == folderId).fetchAll(db)
        }.filter { !serverIds.contains($0.messageId) }
        let http = FakeHTTP.Scenario()
        defer { http.close() }
        await AccountManager.shared.registerProviderForTesting(
            accountId: f.accountId, provider: provider(f.item, http: http))
        var opened: [String] = []
        for header in headers {
            if let draftId = try await ServerDraftComposeLoader.resolveOpenAuthority(header: header)?.draftId {
                opened.append(draftId)
            }
        }
        await AccountManager.shared.unregisterProviderForTesting(accountId: f.accountId)
        #expect(http.recordedCalls().isEmpty, "opening a never-uploaded draft reached the server")
        return opened
    }

    // MARK: - The property

    /// **A draft that never reached the server still opens from Drafts after an
    /// app update and the full sync that follows it, on every provider and in
    /// both stale branches.** Its body row and its search entry stay too.
    @Test("A never-uploaded draft still opens from Drafts after the update's full sync",
          arguments: providers, Branch.allCases)
    @MainActor
    func neverUploadedDraftStaysOpenable(_ item: ProviderCase, _ branch: Branch) async throws {
        let f = try fixture(item, "keep-\(branch.rawValue)")
        defer { finish(f) }
        let (draftId, placeholderHeaderId) = try await saveThenUpdate(f)
        let before = try await openableDraftIds(f)
        #expect(before == [draftId], "the fixture's draft does not open before the sync")

        let server = serverDrafts(item, branch: branch)
        let result = try await runDraftsSync(f, messages: server.messages, limit: server.limit)

        let after = try await openableDraftIds(f, serverIds: server.messages.map(\.messageId))
        #expect(after == [draftId], """
            after the full sync no Drafts row opens the draft the user wrote; its \
            content is still on the device but nothing reaches it
            """)
        #expect(try bodyExists(f, id: placeholderHeaderId),
                "the draft's body row went with its header")
        #expect(!result.staleIds.contains(placeholderHeaderId),
                "the sync removed the draft's search entry")
    }

    /// **A placeholder whose draft is gone is still removed.** The draft was sent
    /// (the send finalizer deletes the `Draft` row and nothing else), so the
    /// placeholder opens nothing; the full sync clears it as before.
    @Test("A placeholder whose draft is gone is still removed by the full sync",
          arguments: removalCases)
    @MainActor
    func placeholderOfAGoneDraftIsRemoved(_ item: ProviderCase, _ branch: Branch) async throws {
        let f = try fixture(item, "gone-\(branch.rawValue)")
        defer { finish(f) }
        let (draftId, placeholderHeaderId) = try await saveThenUpdate(f)
        try await f.pool.writeWithoutTransaction { db in
            try DraftStore.applyDelete(id: draftId, expectedInstanceEpoch: Self.epoch, db: db)
        }
        let opened = try await openableDraftIds(f)
        #expect(opened.isEmpty, "the placeholder still opens a draft that was deleted")

        let server = serverDrafts(item, branch: branch)
        let result = try await runDraftsSync(f, messages: server.messages, limit: server.limit)

        #expect(!(try headerExists(f, id: placeholderHeaderId)), """
            a placeholder whose draft is gone stayed in Drafts; it opens nothing \
            and nothing else removes it
            """)
        #expect(result.staleIds.contains(placeholderHeaderId))
    }

    /// **A placeholder whose draft has a server copy is still removed.** The draft
    /// was uploaded once and then edited while the server could not be reached;
    /// the server copy's own row stays in Drafts, so the placeholder would be a
    /// second row for the same draft.
    @Test("A placeholder whose draft has a server copy is still removed by the full sync",
          arguments: removalCases)
    @MainActor
    func placeholderOfAnUploadedDraftIsRemoved(_ item: ProviderCase, _ branch: Branch) async throws {
        let f = try fixture(item, "uploaded-\(branch.rawValue)")
        defer { finish(f) }
        let server = serverDrafts(item, branch: branch)
        guard let serverCopy = server.messages.first?.messageId else { return }
        let (_, placeholderHeaderId) = try await saveThenUpdate(f, serverDraftId: serverCopy)

        let result = try await runDraftsSync(f, messages: server.messages, limit: server.limit)

        #expect(!(try headerExists(f, id: placeholderHeaderId)), """
            the placeholder of a draft that has a server copy stayed beside that \
            copy's row, so Drafts lists the draft twice
            """)
        #expect(result.staleIds.contains(placeholderHeaderId))
        let serverRowId = "\(f.accountId):\(Self.draftsPath):\(serverCopy)"
        #expect(try headerExists(f, id: serverRowId), "the server copy's own row is missing")
    }
}
