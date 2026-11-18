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
