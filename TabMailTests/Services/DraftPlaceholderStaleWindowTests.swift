/* This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at https://mozilla.org/MPL/2.0/. */

import Testing
import Foundation
import GRDB
@testable import TabMail

/// A draft placeholder whose save landed without a server address (so it was
/// never re-keyed) is removed by the next Drafts sync whose page reaches its
/// latest save, however many drafts are newer than its FIRST save.
///
/// On a provider that windows stale detection by provider date, sync judges a
/// local row stale only when its provider date is at or above the oldest draft
/// on the fetched page. A re-saved draft's placeholder must therefore carry the
/// time of its latest save; one stuck at its first save sits below the page once
/// a full page of drafts is newer than that, and the Drafts list shows the draft
/// twice for as long as that lasts.
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

    @Test("A placeholder re-saved after a page of newer drafts is reconciled away")
    @MainActor
    func aReSavedPlaceholderIsReconciledAway() async throws {
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

        // The user edits the draft an hour ago; that save lands the same way.
        draft.updatedAt = latestSave.timeIntervalSince1970
        let secondVersion = draft
        try await pool.write { db in try secondVersion.update(db) }
        #expect(await AccountManager.shared.queueDraftSave(draftId: draftId, accountId: accountId))
        try await pool.write { db in _ = try PendingOperation.deleteAll(db) }

        let placeholderMessageId = PendingOperation.draftPlaceholderMessageId(
            draftId: draftId, instanceEpoch: draft.instanceEpoch)
        let before = try await pool.read { db in
            try MessageHeader.filter(Column("messageId") == placeholderMessageId).fetchCount(db)
        }
        #expect(before == 1, "precondition: the placeholder row exists before sync")

        // The server's Drafts page: a full page, so it does not span the folder.
        // Its newest entry is the draft's own server copy at the latest save; the
        // other drafts were all created after the first save.
        var page = [Self.info(id: "server-copy", date: latestSave)]
        for i in 1..<Self.pageLimit {
            page.append(Self.info(id: "newer-\(i)", date: firstSave.addingTimeInterval(86_400 + Double(i) * 60)))
        }
        let provider = MockEmailProvider(staleWindowMode: .date)
        await provider.setFetchMessagesResult(page)
        _ = try await SyncEngine.runSyncMessages(
            for: folder, provider: provider, limit: Self.pageLimit, dbPool: PrioritizedDatabase(pool: pool))

        let after = try await pool.read { db in
            try MessageHeader.filter(Column("messageId") == placeholderMessageId).fetchCount(db)
        }
        #expect(after == 0, """
            the placeholder's latest save is inside the fetched page and the server does not \
            list it, so sync must remove it; a row left at its first save is below the page \
            and the draft shows twice
            """)
    }
}
