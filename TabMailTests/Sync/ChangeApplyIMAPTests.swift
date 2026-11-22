/* This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at https://mozilla.org/MPL/2.0/. */

import Foundation
import GRDB
import Testing
@testable import TabMail

/// The apply rules the IMAP reader relies on (ADR-IOS-111, IMAP half), driven
/// through `SyncEngine.applyFolderChanges` inside a write transaction exactly as
/// the pass calls it: the binding epoch check, a refused bookmark under a new
/// UIDVALIDITY, the untracked status, and the upgrade-only answered/forwarded
/// merge with ReplyDetect. Each case asserts the stored rows and folder.
@Suite("Change apply: the IMAP rules", .serialized, .processGlobalState)
struct ChangeApplyIMAPTests {
    typealias Base = ChangeApplyTests

    static let storedEpoch = 41_001

    static func setEpoch(_ w: Base.World, _ folderId: String, _ epoch: Int?, cursor: String? = nil, state: String? = nil) throws {
        try w.pool.write { db in
            try db.execute(
                sql: "UPDATE folder SET lastKnownUidValidity = ?, changeCursor = ?, changeState = ? WHERE id = ?",
                arguments: [epoch, cursor, state, folderId])
        }
    }

    static func apply(_ w: Base.World, _ changes: FolderChanges) throws -> FolderChangeApplyResult {
        try w.pool.write { db in try SyncEngine.applyFolderChanges(changes, db: db) }
    }

    static func folder(_ w: Base.World, _ id: String) throws -> Folder {
        try #require(try w.pool.read { db in try Folder.fetchOne(db, key: id) })
    }

    static func readRecord(_ id: String, isRead: Bool) -> ChangeRecord {
        var record = ChangeRecord(messageId: id)
        record.isRead = isRead
        record.isFlagged = false
        return record
    }


    // MARK: - Epoch

    @Test("Binding check: a read under another UIDVALIDITY than the folder stores writes nothing, not even the bookmark")
    func bindingEpochCheck() async throws {
        try await Base.withWorld { w in
            try Self.setEpoch(w, w.inboxId, Self.storedEpoch, cursor: "old-cursor")
            try w.insertRow("7", in: w.inboxId, path: "INBOX", isRead: false)
            var changes = FolderChanges(
                folderId: w.inboxId, status: .tracked, addressEpoch: Self.storedEpoch + 1,
                records: [Self.readRecord("7", isRead: true)], removals: [])
            changes.cursor = "new-cursor"
            _ = try Self.apply(w, changes)
            #expect(try w.row("7", in: w.inboxId)?.isRead == false)
            #expect(try Self.folder(w, w.inboxId).changeCursor == "old-cursor")

            changes.addressEpoch = Self.storedEpoch
            _ = try Self.apply(w, changes)
            #expect(try w.row("7", in: w.inboxId)?.isRead == true, "the same read under the stored epoch applies")
            #expect(try Self.folder(w, w.inboxId).changeCursor == "new-cursor")
        }
    }

    @Test("Refused under a new UIDVALIDITY: the bookmark and re-read list are cleared and the turnover reaction is armed")
    func epochRefusalArmsTurnover() async throws {
        try await Base.withWorld { w in
            var state = FolderChangeState(raw: nil)
            state.tracking = true
            state.recheck = ["3"]
            try Self.setEpoch(w, w.inboxId, Self.storedEpoch, cursor: "c", state: state.encoded)
            try w.insertRow("3", in: w.inboxId, path: "INBOX")
            let result = try Self.apply(w, FolderChanges(
                folderId: w.inboxId, status: .refused(.addressEpochChanged(Self.storedEpoch + 9))))
            let folder = try Self.folder(w, w.inboxId)
            #expect(folder.changeCursor == nil)
            #expect(folder.uidValidityResetPendingAt != nil)
            #expect(result.armedTurnoverPath == "INBOX")
            let after = FolderChangeState(raw: folder.changeState)
            #expect(!after.tracking)
            #expect(after.recheck.isEmpty, "the re-read ids name messages of the dead generation")
            #expect(try w.row("3", in: w.inboxId) != nil, "the refusal itself removes no row; the reaction does")
        }
    }

    @Test("Refused with the epoch the folder already stores, or with none stored: nothing is armed")
    func epochRefusalNeedsKnownDifferentEpoch() async throws {
        try await Base.withWorld { w in
            try Self.setEpoch(w, w.inboxId, Self.storedEpoch, cursor: "c")
            let same = try Self.apply(w, FolderChanges(
                folderId: w.inboxId, status: .refused(.addressEpochChanged(Self.storedEpoch))))
            #expect(same.armedTurnoverPath == nil)
            #expect(try Self.folder(w, w.inboxId).uidValidityResetPendingAt == nil)

            try Self.setEpoch(w, w.archiveId, nil, cursor: "c")
            let unknown = try Self.apply(w, FolderChanges(
                folderId: w.archiveId, status: .refused(.addressEpochChanged(Self.storedEpoch))))
            #expect(unknown.armedTurnoverPath == nil)
            #expect(try Self.folder(w, w.archiveId).uidValidityResetPendingAt == nil)
        }
    }

    @Test("A baseline the binding check rejects is not tracked; the next pass, with the epoch stamped, starts it and arms the catch-up (two passes)")
    func rejectedBaselineIsNotTracked() async throws {
        try await Base.withWorld { w in
            try Self.setEpoch(w, w.inboxId, nil)
            let inboxId = w.inboxId
            try Self.setCompletedCatchUp(w, [inboxId])
            let baseline: @Sendable (ChangeCursor, ChangeRequest) -> ChangeSet = { _, request in
                ChangeSet(account: .keep, folderList: nil, folders: request.folders.map {
                    var changes = FolderChanges(
                        folderId: $0.id, status: $0.id == inboxId ? .baselineReady : .notRun,
                        addressEpoch: $0.id == inboxId ? Self.storedEpoch : nil,
                        cursor: $0.id == inboxId ? "baseline-cursor" : nil)
                    changes.armCatchUpWithBookmark = $0.id == inboxId
                    return changes
                })
            }
            await w.script([baseline, baseline])

            // Pass 1: the folder stores no epoch, so the read is rejected whole.
            let first = try await w.outcome()
            #expect(!first.trackableFolderIds.contains(inboxId))
            #expect(try Self.lapses(w, inboxId) == 0, "a rejected read arms nothing")
            try await SyncEngine().commitChangeBaseline(account: try w.account(), outcome: first, listedFolderIds: [inboxId])
            #expect(!(try w.state(inboxId)).tracking, "never tracked without a written bookmark")
            #expect(try Self.folder(w, inboxId).changeCursor == nil)

            // The listing stamps the epoch; pass 2 starts the bookmark for real.
            try await w.pool.write { db in
                try db.execute(sql: "UPDATE folder SET lastKnownUidValidity = ? WHERE id = ?", arguments: [Self.storedEpoch, inboxId])
            }
            let second = try await w.outcome()
            #expect(second.trackableFolderIds.contains(inboxId))
            #expect(try Self.lapses(w, inboxId) == 1, "the stored bookmark arms its catch-up")
            #expect(try Self.folder(w, inboxId).changeCursor == "baseline-cursor")
        }
    }

    static func setCompletedCatchUp(_ w: Base.World, _ folderIds: [String]) throws {
        let completed = IMAPCatchUpState(epoch: 1, completionStamp: 5, lastCompletedAt: Date(), listing: nil)
        try w.pool.write { db in
            for id in folderIds {
                try db.execute(sql: "UPDATE folder SET catchUpState = ? WHERE id = ?", arguments: [completed.encoded(), id])
            }
        }
    }

    static func lapses(_ w: Base.World, _ id: String) throws -> Int {
        let raw = try w.pool.read { db in try Folder.fetchOne(db, key: id)?.catchUpState }
        return IMAPCatchUpState.decode(raw)?.lapseCount ?? 0
    }

    @Test("A bookmark that starts with the catch-up arm marks the folder's catch-up in the transaction that stores it, with no commit of tracking; one without does not, and the commit adds nothing")
    func catchUpArmedWithTheBookmark() async throws {
        try await Base.withWorld { w in
            try Self.setEpoch(w, w.inboxId, Self.storedEpoch)
            try Self.setEpoch(w, w.archiveId, Self.storedEpoch)
            try Self.setCompletedCatchUp(w, [w.inboxId, w.archiveId])
            let inboxId = w.inboxId
            let baseline: @Sendable (ChangeCursor, ChangeRequest) -> ChangeSet = { _, request in
                ChangeSet(account: .keep, folderList: nil, folders: request.folders.map {
                    var changes = FolderChanges(
                        folderId: $0.id, status: .baselineReady, addressEpoch: Self.storedEpoch,
                        cursor: "baseline-\($0.id)")
                    changes.armCatchUpWithBookmark = $0.id == inboxId
                    return changes
                })
            }
            await w.script([baseline])
            // The pass reads and applies; nothing commits tracking (a background
            // pass, a listing that fails, or a crash before the commit).
            let outcome = try await w.outcome()
            #expect(try Self.folder(w, w.inboxId).changeCursor == "baseline-\(w.inboxId)", "setup: the bookmark is stored")
            #expect(try Self.lapses(w, w.inboxId) == 1, "armed with the stored bookmark")
            #expect(try Self.lapses(w, w.archiveId) == 0, "a bookmark without the arm arms nothing")
            #expect(!(try w.state(w.inboxId)).tracking)
            // The commit of tracking arms nothing more.
            try await SyncEngine().commitChangeBaseline(account: try w.account(), outcome: outcome, listedFolderIds: [w.inboxId, w.archiveId])
            #expect(try w.state(w.inboxId).tracking && w.state(w.archiveId).tracking)
            #expect(try Self.lapses(w, w.inboxId) == 1)
            #expect(try Self.lapses(w, w.archiveId) == 0)
        }
    }

    @Test("An untracked folder changed: a new UID, a different count, or a different HIGHESTMODSEQ, each alone")
    func untrackedChangedPredicate() {
        func obs(_ count: Int, _ next: Int, _ modseq: Int?) -> UntrackedObservation {
            UntrackedObservation(messageCount: count, uidNext: next, highestModSeq: modseq, uidValidity: 1)
        }
        func f(_ o: UntrackedObservation, _ uidNext: Int?, _ count: Int, _ modseq: Int?, _ due: Bool = false) -> Bool {
            SyncEngine.untrackedFolderChanged(
                observation: o, lastKnownUidNext: uidNext, totalCount: count, lastKnownHighestModSeq: modseq, listingDue: due)
        }
        #expect(!f(obs(3, 10, 7), 10, 3, 7))
        #expect(f(obs(3, 11, 7), 10, 3, 7), "a new UID")
        #expect(f(obs(2, 10, 7), 10, 3, 7), "a different count")
        #expect(f(obs(3, 10, 8), 10, 3, 7), "a different HIGHESTMODSEQ")
        #expect(f(obs(3, 11, nil), nil, 3, nil), "no stored UIDNEXT: no listing proved the folder unchanged, so it is listed")
        #expect(f(obs(3, 10, 7), 10, 3, nil), "a HIGHESTMODSEQ the server reports while the last listing stored none asks for a listing")
        #expect(f(obs(3, 10, 7), 10, 3, 7, true), "a count check that did not finish asks for a listing")
        // NOMODSEQ (RFC 7162): STATUS reports HIGHESTMODSEQ 0 and the listing stores
        // none; an unchanged folder is not listed again on the next poll, or ever.
        for _ in 0..<3 {
            #expect(!f(obs(3, 10, 0), 10, 3, nil), "a NOMODSEQ folder never triggers on its modseq")
            #expect(!f(obs(3, 10, 0), 10, 3, 0), "a stored 0 is no modseq either")
        }
        #expect(f(obs(3, 11, 0), 10, 3, nil), "a NOMODSEQ folder still lists on a new UID")
    }

    @Test("NOMODSEQ: a HIGHESTMODSEQ of 0 never proves a folder unchanged, so the full sync never skips on it")
    func noModSeqNeverSkips() {
        func skip(_ fresh: Int?, _ cached: Int?) -> Bool {
            SyncEngine.shouldSkipFolderFetch(
                role: .archive, freshModSeq: fresh, cachedModSeq: cached, isDeepSync: false,
                freshCount: 3, freshUidNext: 10, listedCount: 3, listedUidNext: 10)
        }
        #expect(skip(7, 7))
        #expect(!skip(0, 0), "0 == 0 is no proof: the mailbox keeps no mod-sequences")
        #expect(!skip(0, nil))
        #expect(SyncEngine.knownModSeq(0) == nil)
        #expect(SyncEngine.knownModSeq(5) == 5)
    }

    // MARK: - Untracked

    @Test("Untracked: the folder's tracking is cleared, its bookmark kept for the next read that can track it, its rows untouched")
    func untrackedKeepsBookmark() async throws {
        try await Base.withWorld { w in
            var state = FolderChangeState(raw: nil)
            state.tracking = true
            try Self.setEpoch(w, w.inboxId, Self.storedEpoch, cursor: "c", state: state.encoded)
            try w.insertRow("4", in: w.inboxId, path: "INBOX")
            _ = try Self.apply(w, FolderChanges(
                folderId: w.inboxId,
                status: .untracked(UntrackedObservation(messageCount: 1, uidNext: 5, highestModSeq: nil, uidValidity: Self.storedEpoch))))
            let folder = try Self.folder(w, w.inboxId)
            #expect(folder.changeCursor == "c")
            #expect(!FolderChangeState(raw: folder.changeState).tracking)
            #expect(try w.row("4", in: w.inboxId) != nil)
        }
    }

    // MARK: - Answered / forwarded

    @Test("Answered and forwarded are raised by a record, never lowered")
    func repliedForwardedUpgradeOnly() async throws {
        try await Base.withWorld { w in
            try Self.setEpoch(w, w.inboxId, Self.storedEpoch)
            try w.insertRow("5", in: w.inboxId, path: "INBOX")
            try w.insertRow("6", in: w.inboxId, path: "INBOX")
            try w.pool.write { db in
                try db.execute(sql: "UPDATE messageHeader SET isReplied = 1, isForwarded = 1 WHERE messageId = '6'")
            }
            var raise = Self.readRecord("5", isRead: false)
            raise.isReplied = true
            raise.isForwarded = true
            var lower = Self.readRecord("6", isRead: false)
            lower.isReplied = false
            lower.isForwarded = false
            _ = try Self.apply(w, FolderChanges(
                folderId: w.inboxId, status: .tracked, addressEpoch: Self.storedEpoch, records: [raise, lower], removals: []))
            let five = try #require(try w.row("5", in: w.inboxId))
            let six = try #require(try w.row("6", in: w.inboxId))
            #expect(five.isReplied && five.isForwarded)
            #expect(six.isReplied && six.isForwarded, "a server without the mark never clears one found another way")
        }
    }

    @Test("ReplyDetect: a message tagged reply that the server reports answered becomes none, with a queued tag write")
    func replyDetectOnAnswered() async throws {
        try await Base.withWorld { w in
            try Self.setEpoch(w, w.inboxId, Self.storedEpoch)
            try w.insertRow("8", in: w.inboxId, path: "INBOX")
            try w.pool.write { db in
                try db.execute(sql: "UPDATE messageHeader SET actionTag = ? WHERE messageId = '8'", arguments: [ActionTag.reply.rawValue])
            }
            var record = Self.readRecord("8", isRead: false)
            record.isReplied = true
            _ = try Self.apply(w, FolderChanges(
                folderId: w.inboxId, status: .tracked, addressEpoch: Self.storedEpoch, records: [record], removals: []))
            let row = try #require(try w.row("8", in: w.inboxId))
            #expect(row.actionTag == ActionTag.none)
            #expect(row.actionTagSetAt != nil, "a tag write is stamped like any other (setActionTag)")
            let ops = try w.pool.read { db in
                try PendingOperation.filter(Column("accountId") == w.accountId).fetchAll(db)
            }
            #expect(ops.contains { $0.type == .setTag && $0.tagValue == ActionTag.none.rawValue })
        }
    }

    @Test("ReplyDetect leaves the tag alone while the user's own tag change is pending, and queues no tag write over it")
    func replyDetectYieldsToPendingUserTag() async throws {
        try await Base.withWorld { w in
            try Self.setEpoch(w, w.inboxId, Self.storedEpoch)
            try w.insertRow("8", in: w.inboxId, path: "INBOX")
            try w.pool.write { db in
                try db.execute(sql: "UPDATE messageHeader SET actionTag = ? WHERE messageId = '8'", arguments: [ActionTag.reply.rawValue])
            }
            let stableId = try #require(try w.row("8", in: w.inboxId)).stableId
            try w.pool.write { db in
                var userOp = PendingOperation(
                    type: .setTag, messageIds: [stableId], accountId: w.accountId,
                    folderPath: "INBOX", tagValue: ActionTag.reply.rawValue)
                try userOp.insert(db)
            }
            var record = Self.readRecord("8", isRead: false)
            record.isReplied = true
            _ = try Self.apply(w, FolderChanges(
                folderId: w.inboxId, status: .tracked, addressEpoch: Self.storedEpoch, records: [record], removals: []))
            let row = try #require(try w.row("8", in: w.inboxId))
            #expect(row.isReplied, "the answered mark is still raised")
            #expect(row.actionTag == .reply, "the user's pending tag stands")
            let tagOps = try w.pool.read { db in
                try PendingOperation.filter(Column("accountId") == w.accountId).fetchAll(db)
            }.filter { $0.type == .setTag }
            #expect(tagOps.count == 1 && tagOps.first?.tagValue == ActionTag.reply.rawValue,
                    "only the user's own tag write is queued: \(tagOps.map(\.tagValue))")
        }
    }

    // MARK: - A bookmark dropped between a read and its apply

    @Test("A bookmark dropped between the read and the apply is not written back, and the folder is not tracked at commit")
    func droppedBetweenReadAndApplyStaysUntracked() async throws {
        try await Base.withWorld { w in
            try Self.setEpoch(w, w.inboxId, Self.storedEpoch, cursor: nil)
            try w.insertRow("7", in: w.inboxId, path: "INBOX", isRead: false)
            // The read was issued with bookmark "B"; an unproven move dropped it since.
            var changes = FolderChanges(
                folderId: w.inboxId, status: .tracked, addressEpoch: Self.storedEpoch,
                records: [Self.readRecord("7", isRead: true)], removals: [])
            changes.cursor = "B2"
            changes.readFrom = FolderChanges.ReadFrom(cursor: "B")
            _ = try Self.apply(w, changes)
            #expect(try Self.folder(w, w.inboxId).changeCursor == nil, "the dropped bookmark is not written back")
            #expect(try w.row("7", in: w.inboxId)?.isRead == true, "the read's records still apply")

            var outcome = ChangePassOutcome()
            outcome.trackableFolderIds = [w.inboxId]
            outcome.folderBookmarkLeft[w.inboxId] = .some(nil)
            try await SyncEngine().commitChangeBaseline(account: try w.account(), outcome: outcome, listedFolderIds: [w.inboxId])
            #expect(FolderChangeState(raw: try Self.folder(w, w.inboxId).changeState).tracking == false,
                    "a folder whose bookmark was dropped after its read is not tracked")
        }
    }

    @Test("A bookmark dropped while the read is in flight stays dropped through the real pass, whether the read returned a bookmark or found nothing changed",
          arguments: [true, false])
    func droppedDuringTheRealPass(readReturnsBookmark: Bool) async throws {
        try await Base.withWorld { w in
            var tracked = FolderChangeState(raw: nil)
            tracked.tracking = true
            try Self.setEpoch(w, w.inboxId, Self.storedEpoch, cursor: "B", state: tracked.encoded)
            let inboxId = w.inboxId
            let pool = w.pool
            // The reader returns; before the engine applies, an unproven move's
            // retirement drops the bookmark (the window between the two).
            await w.script([{ _, request in
                try? pool.write { db in try SyncEngine.dropChangeBookmark(folderId: inboxId, db: db) }
                return ChangeSet(account: .keep, folderList: nil, folders: request.folders.map {
                    FolderChanges(
                        folderId: $0.id, status: $0.id == inboxId ? .tracked : .notRun,
                        addressEpoch: $0.id == inboxId ? Self.storedEpoch : nil,
                        cursor: $0.id == inboxId && readReturnsBookmark ? "B2" : nil)
                })
            }])
            let outcome = try await w.outcome()
            try await SyncEngine().commitChangeBaseline(account: try w.account(), outcome: outcome, listedFolderIds: [inboxId])
            #expect(try Self.folder(w, inboxId).changeCursor == nil, "the dropped bookmark is not written back")
            #expect(!(try w.state(inboxId)).tracking, "the folder is not tracked again on the strength of that read")
        }
    }

    @Test("A first read (no bookmark) writes one; dropped between the apply and the commit, the folder is not tracked and its listing is due",
          arguments: [true, false])
    func baselineDroppedBeforeCommitStaysUntracked(dropped: Bool) async throws {
        try await Base.withWorld { w in
            try Self.setEpoch(w, w.inboxId, Self.storedEpoch, cursor: nil)
            let inboxId = w.inboxId
            await w.script([{ _, request in
                ChangeSet(account: .keep, folderList: nil, folders: request.folders.map {
                    FolderChanges(
                        folderId: $0.id, status: $0.id == inboxId ? .baselineReady : .notRun,
                        addressEpoch: $0.id == inboxId ? Self.storedEpoch : nil,
                        cursor: $0.id == inboxId ? "first-bookmark" : nil)
                })
            }])
            let outcome = try await w.outcome()
            #expect(try Self.folder(w, inboxId).changeCursor == "first-bookmark", "setup: the first read wrote its bookmark")
            // The listing ran; an unproven move into the folder retires before the commit.
            try await w.pool.write { db in
                try db.execute(sql: "UPDATE account SET lastFullSyncAt = ? WHERE id = ?", arguments: [Date(), w.accountId])
                if dropped { try SyncEngine.dropChangeBookmark(folderId: inboxId, db: db) }
            }
            try await SyncEngine().commitChangeBaseline(account: try w.account(), outcome: outcome, listedFolderIds: [inboxId])
            if dropped {
                #expect(!(try w.state(inboxId)).tracking, "a folder whose bookmark is gone is not tracked")
                #expect(try w.account().lastFullSyncAt == nil, "its listing is due")
            } else {
                #expect(try w.state(inboxId).tracking, "control: the same pass with its bookmark intact tracks the folder")
            }
        }
    }
}
