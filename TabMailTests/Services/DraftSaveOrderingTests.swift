/* This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at https://mozilla.org/MPL/2.0/. */

import Foundation
import GRDB
import Testing
@testable import TabMail

/// T4.D2 — `DraftStore.applySave`'s out-of-order guard, and the invariant behind
/// the deliberately-unported v2final F3a back-seed: a save merges AUTHORED fields
/// only and never re-creates provider linkage the row does not currently hold.
///
/// PORT reference: `v2final:TabMail/Services/AI/DraftStore.swift` → `applySave`.
@Suite("Draft save ordering and linkage")
struct DraftSaveOrderingTests {

    private func makeDraft(
        id: String = "new:draft-1",
        body: String,
        updatedAt: Double,
        serverDraftId: String? = nil,
        rfc822MessageId: String? = nil
    ) -> Draft {
        Draft(
            id: id, accountId: "acc1", toJSON: "[]", ccJSON: "[]", bccJSON: "[]",
            subject: "subject", body: body, replyToId: nil, isForward: false,
            editHistoryJSON: nil, createdAt: updatedAt, updatedAt: updatedAt,
            serverDraftId: serverDraftId, serverPushStatus: nil,
            rfc822MessageId: rfc822MessageId, attachmentsDirName: nil)
    }

    @Test("An older in-flight snapshot cannot clobber a newer one")
    func staleSnapshotIsRefused() throws {
        let db = try TestDatabase.make()
        try TestDatabase.insertAccount(db)
        // Relative to now, so nothing in this test can go stale.
        let now = Date().timeIntervalSince1970
        let newer = makeDraft(body: "the newer authored body", updatedAt: now)
        let older = makeDraft(body: "the older in-flight body", updatedAt: now - 120)

        let firstResult = try db.write { try DraftStore.applySave(newer, db: $0) }
        #expect(firstResult == .applied)
        let afterInsert = try db.read { try Draft.fetchOne($0, key: newer.id) }
        #expect(afterInsert != nil)
        guard let afterInsert else { return }

        let secondResult = try db.write { try DraftStore.applySave(older, db: $0) }
        #expect(secondResult == .notApplied)

        let survivor = try db.read { try Draft.fetchOne($0, key: newer.id) }
        #expect(survivor?.body == "the newer authored body")
        #expect(survivor?.updatedAt == now)
        // A losing snapshot writes NOTHING — not the body, not the conflict
        // version, not the eviction-recency key.
        #expect(survivor?.pushAttemptVersion == afterInsert.pushAttemptVersion)
        #expect(survivor?.lastTouchedSeq == afterInsert.lastTouchedSeq)
    }

    @Test("An equal-or-newer snapshot is applied and bumps the conflict version")
    func newerSnapshotIsApplied() throws {
        let db = try TestDatabase.make()
        try TestDatabase.insertAccount(db)
        let now = Date().timeIntervalSince1970
        let first = makeDraft(body: "first", updatedAt: now - 120)
        _ = try db.write { try DraftStore.applySave(first, db: $0) }
        let afterInsert = try db.read { try Draft.fetchOne($0, key: first.id) }
        #expect(afterInsert != nil)
        guard let afterInsert else { return }

        let second = makeDraft(body: "second", updatedAt: now)
        let result = try db.write { try DraftStore.applySave(second, db: $0) }
        #expect(result == .applied)

        let merged = try db.read { try Draft.fetchOne($0, key: first.id) }
        #expect(merged?.body == "second")
        #expect(merged?.pushAttemptVersion == afterInsert.pushAttemptVersion + 1)
        #expect((merged?.lastTouchedSeq ?? 0) > afterInsert.lastTouchedSeq)
    }

    @Test("A newer save cannot resurrect provider linkage the row no longer holds")
    func linkageIsNeverBackSeeded() throws {
        let db = try TestDatabase.make()
        try TestDatabase.insertAccount(db)
        let now = Date().timeIntervalSince1970

        // A pushed draft, addressable at a provider resource.
        let pushed = makeDraft(
            body: "authored", updatedAt: now - 120,
            serverDraftId: "resource-1", rfc822MessageId: "draft-1@example.com")
        _ = try db.write { try DraftStore.applySave(pushed, db: $0) }

        // The push completion then reported the copy UNADDRESSABLE and cleared the
        // whole linkage — exactly what `applyPushCompletion`'s `.unaddressable` arm
        // writes.
        try db.write { connection in
            try connection.execute(sql: """
                UPDATE draft
                   SET serverDraftId = NULL,
                       serverDraftUidValidity = NULL,
                       serverDraftFolderPath = NULL,
                       serverPushStatus = NULL
                 WHERE id = ?
            """, arguments: [pushed.id])
        }

        // A compose that read the row BEFORE the clear now saves newer authored
        // text while still carrying the old address in its snapshot.
        let staleLinkageSnapshot = makeDraft(
            body: "authored some more", updatedAt: now,
            serverDraftId: "resource-1", rfc822MessageId: "draft-1@example.com")
        let result = try db.write { try DraftStore.applySave(staleLinkageSnapshot, db: $0) }
        #expect(result == .applied)

        let row = try db.read { try Draft.fetchOne($0, key: pushed.id) }
        // The authored bytes land…
        #expect(row?.body == "authored some more")
        // …and the disowned provider address stays gone. The row, never the
        // snapshot, is the authority on server linkage.
        #expect(row?.serverDraftId == nil)
        #expect(row?.serverDraftUidValidity == nil)
        #expect(row?.serverDraftFolderPath == nil)
    }
}
