/* This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at https://mozilla.org/MPL/2.0/. */

import Testing
import Foundation
import GRDB
@testable import TabMail

/// A draft placeholder whose save landed without a server address (so it was
/// never re-keyed) is removed by the next Drafts sync whose page reaches its
/// latest save, however many drafts are newer than its FIRST save. While that
/// save is still queued, the same sync keeps the placeholder.
///
/// On a provider that windows stale detection by provider date, sync judges a
/// local row stale only when its provider date is at or above the oldest draft
/// on the fetched page. A re-saved draft's placeholder must therefore carry the
/// time of its latest save; one stuck at its first save sits below the page once
/// a full page of drafts is newer than that, and the Drafts list shows the draft
/// twice for as long as that lasts. Inside the page, the queued save is all that
/// keeps the placeholder of a draft the server does not have yet.
@Suite("A re-saved draft placeholder stays inside the Drafts sync window", .serialized, .processGlobalState)
struct DraftPlaceholderStaleWindowTests {

    private static let draftsPath = "DRAFTS"
    private static let pageLimit = 50

    private static func info(id: String, date: Date) -> MessageHeaderInfo {
        MessageHeaderInfo(
            messageId: id, rfc822MessageId: nil, inReplyTo: nil, references: [],
            threadId: nil, subject: "Draft \(id)", from: "User",
            fromAddress: "user@example.com", to: "recipient@example.com",
            cc: "", bcc: "", replyTo: nil,
            date: date, snippet: "draft",
            isRead: true, isFlagged: false, hasAttachments: false,
            isReplied: false, isForwarded: false, actionTag: nil)
    }

    /// A Drafts folder whose draft was saved ten days ago and again an hour ago,
    /// both through the real producer.
    private struct Scene: Sendable {
        let pool: DatabasePool
        let folder: Folder
        let placeholderMessageId: String
        let firstSave: Date
        let latestSave: Date
    }

    /// Builds the scene and runs `body` on it. The first save's op is retired
    /// with no server address, as is the latest one unless
    /// `keepLatestSaveQueued`, which leaves it in the queue the way a save that
    /// has not reached the server stays there.
    @MainActor
    private func withReSavedPlaceholder(
        keepLatestSaveQueued: Bool,
        _ body: (Scene) async throws -> Void
    ) async throws {
        let accountId = "stale-window-\(UUID().uuidString)"
        let (pool, dir, previous) = try FolderEpochTestFixture.makeAppDB()
        defer {
            AppDatabase.shared.withLock { $0 = previous }
            TestDatabaseTeardown.retire(pool: pool, directory: dir)
        }
        _ = try FolderEpochTestFixture.makeAccount(id: accountId, provider: .gmail, pool: pool)
        try FolderEpochTestFixture.insertFolder(
            accountId: accountId, path: Self.draftsPath, role: .drafts, pool: pool)
        let folder = try #require(
            try FolderEpochTestFixture.readFolder(accountId: accountId, path: Self.draftsPath, pool: pool))

        let now = Date()
        let firstSave = now.addingTimeInterval(-10 * 86_400)
        let latestSave = now.addingTimeInterval(-3_600)

        // First save, ten days ago.
        let draftId = UUID().uuidString
        var draft = Draft(
            id: draftId, accountId: accountId,
            toJSON: "[\"recipient@example.com\"]", ccJSON: "[]", bccJSON: "[]",
            subject: "Long-lived draft", body: "Draft body",
            replyToId: nil, isForward: false, editHistoryJSON: nil,
            createdAt: firstSave.timeIntervalSince1970,
            updatedAt: firstSave.timeIntervalSince1970,
            serverDraftId: nil, serverPushStatus: nil,
            rfc822MessageId: nil, attachmentsDirName: nil)
        draft.instanceEpoch = "E-\(UUID().uuidString)"
        let firstVersion = draft
        try await pool.write { db in try firstVersion.insert(db) }
        #expect(await AccountManager.shared.queueDraftSave(draftId: draftId, accountId: accountId))

        // That save landed with no server address: its op is gone and the
        // placeholder row stays.
        try await pool.write { db in _ = try PendingOperation.deleteAll(db) }

        // The user edits the draft an hour ago.
        draft.updatedAt = latestSave.timeIntervalSince1970
        let secondVersion = draft
        try await pool.write { db in try secondVersion.update(db) }
        #expect(await AccountManager.shared.queueDraftSave(draftId: draftId, accountId: accountId))
        if !keepLatestSaveQueued {
            try await pool.write { db in _ = try PendingOperation.deleteAll(db) }
        }

        let placeholderMessageId = PendingOperation.draftPlaceholderMessageId(
            draftId: draftId, instanceEpoch: draft.instanceEpoch)
        let scene = Scene(
            pool: pool, folder: folder, placeholderMessageId: placeholderMessageId,
            firstSave: firstSave, latestSave: latestSave)
        #expect(try await placeholderCount(scene) == 1, "precondition: the placeholder row exists before sync")
        try await body(scene)
    }

    /// Runs one Drafts sync against the server's page: a full page, so it does
    /// not span the folder. Its newest entry is the draft's own server copy at
    /// the latest save; the other drafts were all created after the first save.
    private func syncDrafts(_ scene: Scene) async throws {
        var page = [Self.info(id: "server-copy", date: scene.latestSave)]
        for i in 1..<Self.pageLimit {
            page.append(Self.info(id: "newer-\(i)", date: scene.firstSave.addingTimeInterval(86_400 + Double(i) * 60)))
        }
        let provider = MockEmailProvider(staleWindowMode: .date)
        await provider.setFetchMessagesResult(page)
        _ = try await SyncEngine.runSyncMessages(
            for: scene.folder, provider: provider, limit: Self.pageLimit, dbPool: PrioritizedDatabase(pool: scene.pool))
    }

    private func placeholderCount(_ scene: Scene) async throws -> Int {
        try await scene.pool.read { db in
            try MessageHeader.filter(Column("messageId") == scene.placeholderMessageId).fetchCount(db)
        }
    }

    @Test("A placeholder re-saved after a page of newer drafts is reconciled away")
    @MainActor
    func aReSavedPlaceholderIsReconciledAway() async throws {
        try await withReSavedPlaceholder(keepLatestSaveQueued: false) { scene in
            try await syncDrafts(scene)
            #expect(try await placeholderCount(scene) == 0, """
                the placeholder's latest save is inside the fetched page and the server does not \
                list it, so sync must remove it; a row left at its first save is below the page \
                and the draft shows twice
                """)
        }
    }

    /// Queued, and in flight: the drain claims a save (status `inFlight`) before
    /// it awaits the provider, and a Drafts sync can run while it waits.
    @Test(
        "A re-saved placeholder whose latest save has not landed survives the sync, then goes once the save lands",
        arguments: [PendingStatus.queued, PendingStatus.inFlight])
    @MainActor
    func anOutstandingReSavedPlaceholderSurvivesTheSync(saveStatus: PendingStatus) async throws {
        try await withReSavedPlaceholder(keepLatestSaveQueued: true) { scene in
            let ops = try await scene.pool.read { db in try PendingOperation.fetchAll(db) }
            #expect(ops.count == 1, "precondition: the latest save is still in the queue")
            guard ops.count == 1 else { return }
            var save = ops[0]
            #expect(save.type == .saveDraft)
            #expect(save.messageIds.contains(scene.placeholderMessageId))
            if saveStatus == .inFlight {
                // What the drain's claim writes before it awaits the provider.
                save.status = PendingStatus.inFlight.rawValue
                save.everAttempted = true
                let claimed = save
                try await scene.pool.write { db in try claimed.update(db) }
            }
            let saveId = save.id
            let stored = try await scene.pool.read { db in try PendingOperation.fetchOne(db, key: saveId) }
            #expect(stored?.status == saveStatus.rawValue, "precondition: the save is \(saveStatus.rawValue)")

            try await syncDrafts(scene)
            #expect(try await placeholderCount(scene) == 1, """
                the latest save has not reached the server, so its placeholder is the draft's \
                only row in the Drafts list; sync must keep it while that save is \(saveStatus.rawValue)
                """)

            // The save lands with no server address.
            try await scene.pool.write { db in _ = try PendingOperation.deleteAll(db) }
            try await syncDrafts(scene)
            #expect(try await placeholderCount(scene) == 0, "once the save has landed, the next sync removes the placeholder")
        }
    }
}
