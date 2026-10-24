/* This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at https://mozilla.org/MPL/2.0/. */

import Foundation
import GRDB
import Testing
@testable import TabMail

/// #217: adoption inserts draft rows, and the draft table is capped
/// (`SyncConfig.maxComposeDraftSessions`). Opening drafts another app wrote is not a
/// save, so it must never push a draft saved here, whose text may exist only on this
/// device, past the cap.
@Suite("Opening drafts written elsewhere never evicts drafts saved here (#217)")
struct ExternalDraftAdoptionEvictionTests {
    private static let accountId = "acc-outlook-evict"

    private func makePool() throws -> (pool: DatabasePool, directory: URL) {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("adoption-eviction-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        var configuration = Configuration()
        configuration.foreignKeysEnabled = true
        let pool = try DatabasePool(
            path: directory.appendingPathComponent("test.sqlite").path,
            configuration: configuration)
        try AppDatabase.runMigrations(on: pool)
        return (pool, directory)
    }

    /// Seeds the account, its Drafts folder and one authored draft whose upload
    /// never succeeded (status nil: its text exists only on this device).
    private func seed(_ pool: DatabasePool, authoredId: String, status: String?) throws {
        let now = Date().timeIntervalSince1970
        try pool.write { db in
            var account = Account(
                emailAddress: "me@example.com", displayName: "Test", provider: .outlook)
            account.id = Self.accountId
            try account.insert(db)
            let folder = Folder(name: "Drafts", path: "Drafts", role: .drafts, accountId: Self.accountId)
            try folder.insert(db)
            var authored = Draft(
                id: authoredId, accountId: Self.accountId,
                toJSON: "[]", ccJSON: "[]", bccJSON: "[]",
                subject: "typed here", body: "text that exists only on this device",
                replyToId: nil, isForward: false, editHistoryJSON: nil,
                createdAt: now, updatedAt: now,
                serverDraftId: nil, serverPushStatus: status,
                rfc822MessageId: nil, attachmentsDirName: nil)
            authored.instanceEpoch = "E-authored"
            _ = try DraftStore.applySave(authored, db: db)
        }
    }

    /// The user opens `count` drafts another app wrote; each open adopts one
    /// through the production writer (`ExternalDraftAdoption.insertAdoptedDraft`).
    private func openDraftsWrittenElsewhere(_ pool: DatabasePool, count: Int) throws -> Int {
        var adopted = 0
        for index in 0..<count {
            let inserted: String? = try pool.write { db in
                guard let folder = try Folder
                    .filter(Column("accountId") == Self.accountId)
                    .fetchOne(db) else { return nil }
                var header = MessageHeader(
                    messageId: "graph-elsewhere-\(index)", subject: "Started elsewhere \(index)",
                    from: "me@example.com", fromAddress: "me@example.com",
                    to: "bob@example.com", date: Date(), snippet: "",
                    folderId: folder.id, accountId: Self.accountId,
                    folderPath: "Drafts", isInInbox: false)
                header.rfc822MessageId = "other-\(index)@example.com"
                try header.insert(db)
                guard let address = try ExternalDraftAdoption.adoptableAddress(
                    db: db, header: header, runtimeKind: .outlook) else { return nil }
                return try ExternalDraftAdoption.insertAdoptedDraft(
                    db: db, header: header, address: address, runtimeKind: .outlook,
                    content: ExternalDraftAdoption.ServerContent(
                        subject: header.subject, to: header.to, cc: "", bcc: "",
                        body: "server text \(index)", attachmentsDirName: nil,
                        attachmentCount: 0))
            }
            if inserted != nil { adopted += 1 }
        }
        return adopted
    }

    @Test("Opening drafts written elsewhere never evicts a draft whose text never reached the server")
    func adoptionNeverEvictsUnpushedAuthoredDraft() throws {
        let fixture = try makePool()
        defer { TestDatabaseTeardown.retire(pool: fixture.pool, directory: fixture.directory) }
        let authoredId = "new:unpushed-authored"
        try seed(fixture.pool, authoredId: authoredId, status: nil)

        let adopted = try openDraftsWrittenElsewhere(
            fixture.pool, count: SyncConfig.maxComposeDraftSessions)
        #expect(adopted == SyncConfig.maxComposeDraftSessions, "fixture: every open adopts one row")

        // Precondition, two-sided: before maintenance the authored row is present.
        let before = try fixture.pool.read { try Draft.fetchOne($0, key: authoredId) }
        #expect(before != nil)

        // Background maintenance (`SyncEngine.runWALMaintenance` -> `runEvictChatSessions`).
        let evicted = try DraftStore.shared.evictSync(
            dbPool: PrioritizedDatabase(pool: fixture.pool),
            limit: SyncConfig.maxComposeDraftSessions)

        let after = try fixture.pool.read { try Draft.fetchOne($0, key: authoredId) }
        let adoptedLeft = try fixture.pool.read { db in
            try Draft.filter(Column("id").like("adopted:%")).fetchCount(db)
        }
        #expect(after != nil,
                "opening \(adopted) drafts written elsewhere evicted (\(evicted) row(s)) a draft whose text never reached the server; adopted rows left: \(adoptedLeft)")
    }

    @Test("Opening drafts written elsewhere never evicts a draft holding unsent edits")
    func adoptionNeverEvictsDirtyAuthoredDraft() throws {
        let fixture = try makePool()
        defer { TestDatabaseTeardown.retire(pool: fixture.pool, directory: fixture.directory) }
        let authoredId = "new:dirty-authored"
        try seed(fixture.pool, authoredId: authoredId, status: "dirty")

        let adopted = try openDraftsWrittenElsewhere(
            fixture.pool, count: SyncConfig.maxComposeDraftSessions)
        #expect(adopted == SyncConfig.maxComposeDraftSessions)
        let before = try fixture.pool.read { try Draft.fetchOne($0, key: authoredId) }
        #expect(before?.serverPushStatus == "dirty")

        _ = try DraftStore.shared.evictSync(
            dbPool: PrioritizedDatabase(pool: fixture.pool),
            limit: SyncConfig.maxComposeDraftSessions)

        let after = try fixture.pool.read { try Draft.fetchOne($0, key: authoredId) }
        #expect(after != nil, "opening drafts written elsewhere evicted a draft holding unsent edits")
    }

    /// Saves one more authored draft through the production save writer.
    private func saveAuthored(_ pool: DatabasePool, id: String) throws {
        let now = Date().timeIntervalSince1970
        try pool.write { db in
            var authored = Draft(
                id: id, accountId: Self.accountId,
                toJSON: "[]", ccJSON: "[]", bccJSON: "[]",
                subject: "typed here too", body: "another draft typed on this device",
                replyToId: nil, isForward: false, editHistoryJSON: nil,
                createdAt: now, updatedAt: now,
                serverDraftId: nil, serverPushStatus: nil,
                rfc822MessageId: nil, attachmentsDirName: nil)
            authored.instanceEpoch = "E-\(id)"
            _ = try DraftStore.applySave(authored, db: db)
        }
    }

    @Test("With the cap's worth of drafts saved here, opening ONE draft written elsewhere evicts none of them")
    func oneOpenAtTheCapNeverEvictsAnAuthoredDraft() throws {
        let fixture = try makePool()
        defer { TestDatabaseTeardown.retire(pool: fixture.pool, directory: fixture.directory) }
        let stuckId = "new:stuck-oldest"
        try seed(fixture.pool, authoredId: stuckId, status: nil)
        var savedIds = [stuckId]
        for index in 1..<SyncConfig.maxComposeDraftSessions {
            let id = "new:saved-\(index)"
            try saveAuthored(fixture.pool, id: id)
            savedIds.append(id)
        }
        // Control half: at the cap, maintenance alone evicts nothing.
        let evictedBefore = try DraftStore.shared.evictSync(
            dbPool: PrioritizedDatabase(pool: fixture.pool),
            limit: SyncConfig.maxComposeDraftSessions)
        #expect(evictedBefore == 0, "fixture: \(savedIds.count) saved drafts sit exactly at the cap")

        let adopted = try openDraftsWrittenElsewhere(fixture.pool, count: 1)
        #expect(adopted == 1, "fixture: the one open adopts one row")

        _ = try DraftStore.shared.evictSync(
            dbPool: PrioritizedDatabase(pool: fixture.pool),
            limit: SyncConfig.maxComposeDraftSessions)

        let survivors = try fixture.pool.read { db in
            try Draft.filter(savedIds.contains(Column("id"))).fetchCount(db)
        }
        let stuckAfter = try fixture.pool.read { try Draft.fetchOne($0, key: stuckId) }
        #expect(survivors == savedIds.count,
                "one open of a draft written elsewhere evicted \(savedIds.count - survivors) draft(s) typed on this device")
        #expect(stuckAfter != nil, "the oldest draft, whose text never reached the server, was evicted by one open")
    }

    @Test("With fewer drafts opened than the cap, the draft saved here survives")
    func controlBelowCap() throws {
        let fixture = try makePool()
        defer { TestDatabaseTeardown.retire(pool: fixture.pool, directory: fixture.directory) }
        let authoredId = "new:control"
        try seed(fixture.pool, authoredId: authoredId, status: nil)
        let adopted = try openDraftsWrittenElsewhere(
            fixture.pool, count: SyncConfig.maxComposeDraftSessions - 1)
        #expect(adopted == SyncConfig.maxComposeDraftSessions - 1)
        _ = try DraftStore.shared.evictSync(
            dbPool: PrioritizedDatabase(pool: fixture.pool),
            limit: SyncConfig.maxComposeDraftSessions)
        let after = try fixture.pool.read { try Draft.fetchOne($0, key: authoredId) }
        #expect(after != nil)
    }
}
