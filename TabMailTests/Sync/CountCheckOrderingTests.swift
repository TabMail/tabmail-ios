import Foundation
import GRDB
import Testing
@testable import TabMail

/// The count check (ADR-IOS-051 phase 2) against newer evidence that lands
/// before it finishes: the OLDER one always lands last here.
@Suite("Count check: an older check never undoes newer evidence", .serialized, .processGlobalState)
struct CountCheckOrderingTests {

    @Test("An older check's clear lands after a newer listing marked the folder due: the folder stays due")
    func olderClearNeverClearsANewerMark() {
        var state = FolderChangeState()
        let older = state.markListingDue()      // the older check marks before its walk
        let newer = state.markListingDue()      // a newer listing marks while the walk runs
        state.clearListingDue(ifMarkedBy: older) // the older check finishes last
        #expect(state.listingDue, "the newer mark survives the older check's clear")
        #expect(FolderChangeState(raw: state.encoded).listingDue, "and survives the round trip through the column")
        state.clearListingDue(ifMarkedBy: newer)
        #expect(!state.listingDue)
        #expect(state.encoded == nil)
    }

    @Test("A listing that arms the folder while an older check runs: the older check's clear leaves it due")
    func armDuringAnOlderCheckStaysDue() async throws {
        try await ChangeApplyTests.withWorld { w in
            let folderId = w.archiveId
            // The older check's own mark.
            let older = try await w.pool.write { db -> String in
                var state = FolderChangeState(raw: try String.fetchOne(db, sql: "SELECT changeState FROM folder WHERE id = ?", arguments: [folderId]))
                let token = state.markListingDue()
                try db.execute(sql: "UPDATE folder SET changeState = ? WHERE id = ?", arguments: [state.encoded, folderId])
                return token
            }
            // A newer listing holds more rows than the server counts and arms the folder.
            try w.insertRow("held1", in: folderId, path: "Archive")
            try w.insertRow("held2", in: folderId, path: "Archive")
            try await w.pool.write { db in
                try SyncEngine.armListingDueIfHeldExceeds(0, folderId: folderId, db: db)
            }
            // The older check finishes last and clears its own mark.
            try await w.pool.write { db in
                var state = FolderChangeState(raw: try String.fetchOne(db, sql: "SELECT changeState FROM folder WHERE id = ?", arguments: [folderId]))
                state.clearListingDue(ifMarkedBy: older)
                try db.execute(sql: "UPDATE folder SET changeState = ? WHERE id = ?", arguments: [state.encoded, folderId])
            }
            #expect(try w.state(folderId).listingDue, "the newer listing's mark is never cleared by the older check")
        }
    }

    @Test("A local-only draft (never uploaded) is not a held server row: a Drafts folder whose server rows agree with the server's count is not made due by the listing, its count check (phase 2) sees agreement, does not walk and keeps it not due on the next unchanged pass; a real ghost still makes it due")
    func localOnlyDraftNeverMakesAHealthyFolderDue() async throws {
        try await ChangeApplyTests.withWorld { w in
            let folderId = w.draftsId
            for uid in ["1", "2"] { try w.insertRow(uid, in: folderId, path: "Drafts") }
            // A draft that never reached the server, and its placeholder row, as
            // `DraftStore` and `AccountManager.queueDraftSave` leave them before upload.
            let draftId = UUID().uuidString
            let epoch = "E-\(UUID().uuidString)"
            let placeholder = PendingOperation.draftPlaceholderMessageId(draftId: draftId, instanceEpoch: epoch)
            try await w.pool.write { db in
                var draft = Draft(
                    id: draftId, accountId: w.accountId,
                    toJSON: "[\"recipient@example.com\"]", ccJSON: "[]", bccJSON: "[]",
                    subject: "Local draft", body: "Draft body",
                    replyToId: nil, isForward: false, editHistoryJSON: nil,
                    createdAt: Date().timeIntervalSince1970, updatedAt: Date().timeIntervalSince1970,
                    serverDraftId: nil, serverPushStatus: nil,
                    rfc822MessageId: nil, attachmentsDirName: nil)
                draft.instanceEpoch = epoch
                try draft.insert(db)
            }
            try w.insertRow(placeholder, in: folderId, path: "Drafts")

            let held = try await w.pool.read { db in try SyncEngine.heldServerRowCount(folderId: folderId, accountId: w.accountId, db: db) }
            #expect(held == 2, "the placeholder is not a server row")
            try await w.pool.write { db in try SyncEngine.armListingDueIfHeldExceeds(2, folderId: folderId, db: db) }
            #expect(try !w.state(folderId).listingDue, "the server's count matches every server row: not due")

            // Phase 2, the count check after a listing, on the same healthy
            // folder: no walk, not due, nothing removed; twice (the next
            // unchanged pass). No work queue is registered, so a walk, had it
            // started, could not finish and would leave the folder due.
            let engine = SyncEngine()
            for run in 1...2 {
                let folder = try #require(try await w.pool.read { db in try Folder.fetchOne(db, key: folderId) })
                await engine.reconcileDeletionsAfterListing(folder: folder, provider: w.mock, serverCount: 2, logPrefix: "[Test]")
                #expect(try !w.state(folderId).listingDue, "run \(run): the count check sees agreement and leaves the folder not due")
                for id in ["1", "2", placeholder] {
                    #expect(try w.row(id, in: folderId) != nil, "run \(run): \(id) is kept")
                }
            }

            // Control: one real ghost still makes it due, in both places.
            try w.insertRow("3", in: folderId, path: "Drafts")
            try await w.pool.write { db in try SyncEngine.armListingDueIfHeldExceeds(2, folderId: folderId, db: db) }
            #expect(try w.state(folderId).listingDue, "a held server row the server does not count makes it due")
            let folder = try #require(try await w.pool.read { db in try Folder.fetchOne(db, key: folderId) })
            await engine.reconcileDeletionsAfterListing(folder: folder, provider: w.mock, serverCount: 2, logPrefix: "[Test]")
            #expect(try w.state(folderId).listingDue, "the count check with a real ghost it cannot walk leaves the folder due")
        }
    }

    @Test("A count walk's answer from the old epoch lands after a turnover: nothing is deleted")
    func oldEpochAnswerAfterTurnoverDeletesNothing() async throws {
        try await ChangeApplyTests.withWorld { w in
            let folderId = w.archiveId
            try ChangeApplyIMAPTests.setEpoch(w, folderId, ChangeApplyIMAPTests.storedEpoch)
            try w.insertRow("7", in: folderId, path: "Archive")
            let folder = try #require(try await w.pool.read { db in try Folder.fetchOne(db, key: folderId) })
            let oldEpoch = UInt32(ChangeApplyIMAPTests.storedEpoch)
            // The turnover lands while the walk's answer is in flight.
            try ChangeApplyIMAPTests.setEpoch(w, folderId, ChangeApplyIMAPTests.storedEpoch + 1)
            let removed = try await SyncEngine().deleteServerConfirmedDeletions(
                folder: folder, ids: ["7"], reason: "test", answerEpoch: oldEpoch)
            #expect(removed == 0, "an answer about the old mailbox deletes nothing in the new one")
            #expect(try w.row("7", in: folderId) != nil)
            // Under the epoch it was read in, the same answer deletes.
            let removedSameEpoch = try await SyncEngine().deleteServerConfirmedDeletions(
                folder: folder, ids: ["7"], reason: "test", answerEpoch: oldEpoch + 1)
            #expect(removedSameEpoch == 1)
        }
    }
}
