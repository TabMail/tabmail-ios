/* This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at https://mozilla.org/MPL/2.0/. */

import Foundation
import GRDB
import Synchronization
import Testing
@testable import TabMail

/// Gmail under the change seam (ADR-IOS-111): the reader on its own, and what a
/// user sees across passes now that a tracked folder gets no window listing.
/// Same world as `GmailDeltaApplyInvariantTests` (a real `GmailProvider` against
/// `StatefulGmailActionServer`).
@Suite("Gmail change reading", .serialized, .processGlobalState)
struct GmailChangeReadingTests {
    typealias Pins = GmailDeltaApplyInvariantTests

    // MARK: - Helpers

    static func request(_ w: Pins.World, scope: ChangeScope = .all, recheck: [String: [String]] = [:]) -> ChangeRequest {
        ChangeRequest(
            folders: w.folders.values.sorted { $0.id < $1.id }.map { ChangeFolder(id: $0.id, path: $0.path, role: $0.role) },
            scope: scope, recheck: recheck, context: ChangeContext(onProgress: { _ in }))
    }

    static func read(_ w: Pins.World, cursor: String?, scope: ChangeScope = .all, recheck: [String: [String]] = [:]) async throws -> ChangeSet {
        try #require(try await w.provider.fetchChanges(
            since: ChangeCursor(account: cursor), request: request(w, scope: scope, recheck: recheck)))
    }

    static func changes(_ set: ChangeSet, _ folder: Folder) -> FolderChanges? {
        set.folders.first { $0.folderId == folder.id }
    }

    /// The full sync's window listings: one unbounded first page of
    /// `SyncConfig.syncMessageLimit` per folder (a catch-up list carries
    /// `after:`/`before:` bounds, a later page a token).
    static func windowListings(_ w: Pins.World) -> Int {
        w.server.http.recordedCalls().filter { call in
            guard let components = URLComponents(string: call.url), components.path.hasSuffix("/messages") else { return false }
            let items = components.queryItems ?? []
            let q = items.first { $0.name == "q" }?.value ?? ""
            return items.first { $0.name == "maxResults" }?.value == String(SyncConfig.syncMessageLimit)
                && !items.contains { $0.name == "pageToken" }
                && !q.contains("after:") && !q.contains("before:")
        }.count
    }

    /// The catch-up's whole-folder lists (bounded by `after:` and `before:`).
    static func catchUpListings(_ w: Pins.World) -> [String?] {
        w.server.listRequests().filter { $0.bound("after") != nil && $0.bound("before") != nil }.map(\.labelId)
    }

    static func clearBookmark(_ w: Pins.World) async throws {
        try await w.pool.write { db in
            _ = try Account.filter(Column("id") == w.accountId).updateAll(db, Column("lastHistoryId").set(to: nil as String?))
            try db.execute(sql: "UPDATE folder SET changeState = NULL WHERE accountId = ?", arguments: [w.accountId])
        }
    }

    // MARK: - The reader

    @Test("Reader: a pass with scope .all carries the label list; a push pass does not")
    func readerFolderList() async throws {
        try await Pins.withWorld(seeds: []) { w in
            let all = try await Self.read(w, cursor: w.server.currentHistoryId())
            let paths = Set(all.folderList?.map(\.path) ?? [])
            #expect(paths.isSuperset(of: ["INBOX", Pins.userLabelId]))
            let push = try await Self.read(w, cursor: w.server.currentHistoryId(), scope: .inboxOnly)
            #expect(push.folderList == nil)
        }
    }

    @Test("Reader: with no bookmark it reads a candidate first, lists nothing, reads no history, and every folder waits for its listing")
    func readerBaselineCandidate() async throws {
        try await Pins.withWorld(seeds: [Pins.seed("rb-1", labels: ["INBOX"])]) { w in
            let listsBefore = w.server.listRequests().count
            let set = try await Self.read(w, cursor: nil)
            #expect(set.account == .candidate(w.server.currentHistoryId()))
            #expect(set.folders.allSatisfy { if case .baselineReady = $0.status { return true } else { return false } })
            #expect(set.folders.allSatisfy { $0.records.isEmpty && $0.removals.isEmpty })
            #expect(w.historyRequestCount() == 0)
            #expect(w.server.listRequests().count == listsBefore, "a candidate never lists")
        }
    }

    @Test("Reader: an expired or over-long history refuses every folder and clears the bookmark")
    func readerRefusal() async throws {
        try await Pins.withWorld(seeds: [Pins.seed("rr-1", labels: ["INBOX"])]) { w in
            let cursor = w.server.currentHistoryId()
            w.server.applyLabelChange(providerMessageId: "rr-1", add: ["STARRED"])
            w.server.expireHistory()
            let expired = try await Self.read(w, cursor: cursor)
            #expect(expired.account == .clear)
            #expect(expired.folders.allSatisfy { if case .refused = $0.status { return true } else { return false } })
        }
        try await Pins.withWorld(seeds: [Pins.seed("rr-2", labels: ["INBOX"])]) { w in
            let cursor = w.server.currentHistoryId()
            w.server.answerHistoryTooLong(true)
            let tooLong = try await Self.read(w, cursor: cursor)
            #expect(tooLong.account == .clear)
        }
    }

    @Test("Reader: no change and nothing to re-read advances the bookmark with no message read")
    func readerZeroChange() async throws {
        try await Pins.withWorld(seeds: [Pins.seed("rz-1", labels: ["INBOX"])]) { w in
            let set = try await Self.read(w, cursor: w.server.currentHistoryId())
            #expect(set.account == .set(w.server.currentHistoryId()))
            #expect(set.folders.allSatisfy { if case .tracked = $0.status { return true } else { return false } })
            #expect(w.server.messageGets().isEmpty)
        }
    }

    @Test("Reader: a message asked to be re-read is read with no history change; a gone one is a removal everywhere")
    func readerRecheck() async throws {
        try await Pins.withWorld(seeds: [Pins.seed("rk-here", labels: ["INBOX", "STARRED"])]) { w in
            let set = try await Self.read(w, cursor: w.server.currentHistoryId(),
                                          recheck: [w.inbox.id: ["rk-here", "rk-gone"]])
            let inbox = try #require(Self.changes(set, w.inbox))
            #expect(inbox.records.map(\.messageId) == ["rk-here"])
            #expect(inbox.records.first?.isFlagged == true)
            #expect(inbox.removals == ["rk-gone"])
            let label = try #require(Self.changes(set, w.label))
            #expect(Set(label.removals) == ["rk-gone", "rk-here"], "a folder its labels leave out gets a removal")
        }
    }

    @Test("Reader: a failed detail read keeps the history's removals, reports the failure and keeps the bookmark")
    func readerDetailFailure() async throws {
        try await Pins.withWorld(seeds: [
            Pins.seed("rf-del", labels: ["INBOX"]), Pins.seed("rf-chg", labels: ["INBOX"]),
        ]) { w in
            let cursor = w.server.currentHistoryId()
            w.server.removeMessage(providerMessageId: "rf-del")
            w.server.applyLabelChange(providerMessageId: "rf-chg", add: ["STARRED"])
            w.server.injectGetFailure(providerMessageId: "rf-chg", .status(500))
            let set = try await Self.read(w, cursor: cursor)
            #expect(set.account == .keep)
            let inbox = try #require(Self.changes(set, w.inbox))
            #expect(inbox.removals == ["rf-del"])
            guard case .failed = inbox.status else { Issue.record("expected .failed, got \(inbox.status)"); return }
        }
    }

    // MARK: - R2-1: the bookmark is read before the listing

    @Test("R2-1: a change made to older mail during a new bookmark's listing arrives on the next pass (#464, #460)")
    func changeDuringBaselineListingArrives() async throws {
        try await Pins.withWorld(seeds: [
            Pins.seed("r21-old", labels: ["INBOX", "UNREAD"], date: Pins.daysAgo(60)),
        ]) { w in
            try w.insertRow("r21-old", in: w.inbox, date: Pins.daysAgo(60), isRead: false)
            // A pass that completes the catch-up's first look, so no catch-up
            // listing runs in the pass under test.
            try await w.foregroundPassWithFullSyncDue()
            try await Self.clearBookmark(w)

            // All Mail is listed after the Inbox; reading this new archived
            // message's details is the moment another client marks the old
            // Inbox message read.
            w.server.addMessage(Pins.seed("r21-archived", labels: [], date: Pins.daysAgo(0.1)))
            let fired = Mutex(false)
            let server = w.server
            w.server.onGet(providerMessageId: "r21-archived") {
                guard fired.withLock({ was in defer { was = true }; return !was }) else { return }
                server.applyLabelChange(providerMessageId: "r21-old", remove: ["UNREAD"])
            }
            try await w.foregroundPassWithFullSyncDue()
            #expect(fired.withLock { $0 }, "precondition: the change was made during the listing")

            try await w.completedDelta()
            #expect(try w.row("r21-old", in: w.inbox)?.isRead == true, "the next pass reads the change")
        }
    }

    // MARK: - R2-2: a kept-back change on older mail converges (R33)

    @Test("R2-2: a flag change on older mail kept back under a pending op lands once the op is gone")
    func shieldedOlderFlagConverges() async throws {
        try await Pins.withWorld(seeds: [
            Pins.seed("r22-old", labels: ["INBOX", "UNREAD"], date: Pins.daysAgo(90)),
        ]) { w in
            try w.insertRow("r22-old", in: w.inbox, date: Pins.daysAgo(90), isRead: false)
            let op = try w.insertOp(.markUnread, key: "r22-old", folder: w.inbox)
            w.server.applyLabelChange(providerMessageId: "r22-old", add: ["STARRED"])
            try await w.completedDelta()
            #expect(try w.row("r22-old", in: w.inbox)?.isFlagged == false, "precondition: kept back")

            try await w.pool.write { db in _ = try PendingOperation.deleteOne(db, key: op.id) }
            try await w.completedDelta()
            #expect(try w.row("r22-old", in: w.inbox)?.isFlagged == true, "the next pass lands it, with no new history")
        }
    }

    // MARK: - R2-3: a tracked folder gets no window listing

    @Test("R2-3: a full sync of a tracked Gmail account sends no window listing")
    func trackedFoldersAreNotListed() async throws {
        try await Pins.withWorld(seeds: [Pins.seed("r23-1", labels: ["INBOX"])]) { w in
            try await w.foregroundPassWithFullSyncDue()
            let before = Self.windowListings(w)
            #expect(before > 0, "precondition: the first pass listed the untracked folders")
            try await w.foregroundPassWithFullSyncDue()
            #expect(Self.windowListings(w) == before, "no window listing once the folders are tracked")
        }
    }

    // MARK: - R2-4, R2-7: a refusal re-lists once; no scheduled check while tracked

    @Test("R2-4/R2-7: a refusal re-lists in the same pass, stores a new bookmark, runs ONE catch-up check, and none later while tracked")
    func refusalRelistsOnce() async throws {
        try await Pins.withWorld(seeds: [
            Pins.seed("r24-1", labels: ["INBOX"], date: Pins.daysAgo(40)),
            Pins.seed("r24-2", labels: ["INBOX"], date: Pins.daysAgo(1)),
        ]) { w in
            try await w.foregroundPassWithFullSyncDue()
            w.server.applyLabelChange(providerMessageId: "r24-1", add: ["STARRED"])
            w.server.expireHistory()

            let catchUpBefore = Self.catchUpListings(w).count
            let windowBefore = Self.windowListings(w)
            try await w.foregroundPassWithFullSyncDue()
            #expect(Self.windowListings(w) > windowBefore, "the refusal re-lists in the same pass")
            #expect(try w.account().lastHistoryId == w.server.currentHistoryId(), "and stores a new bookmark")
            let catchUpAfterRefusal = Self.catchUpListings(w).count
            #expect(catchUpAfterRefusal > catchUpBefore, "one catch-up check runs")
            #expect(try w.row("r24-1", in: w.inbox)?.isFlagged == true)

            try await w.foregroundPassWithFullSyncDue()
            #expect(Self.catchUpListings(w).count == catchUpAfterRefusal, "no second check")

            // Eight days on: every stored catch-up time moved back.
            try await w.pool.write { db in
                for key in ["lastCompletedAt", "createdAt", "lastAttemptAt"] {
                    try db.execute(sql: """
                        UPDATE folder SET catchUpState = json_set(catchUpState, '$.' || ?, json_extract(catchUpState, '$.' || ?) - ?)
                        WHERE accountId = ? AND json_type(catchUpState, '$.' || ?) IN ('integer', 'real')
                        """, arguments: [key, key, 8 * 86_400, w.accountId, key])
                }
            }
            try await w.foregroundPassWithFullSyncDue()
            #expect(Self.catchUpListings(w).count == catchUpAfterRefusal, "no scheduled check while tracked (#715)")
        }
    }

    // MARK: - R2-5: label changes show on the next pass

    @Test("R2-5: a label created, renamed or deleted on the server shows on the next pass")
    func labelChangesShowNextPass() async throws {
        try await Pins.withWorld(seeds: []) { w in
            w.server.setUserLabel(id: "Label_2", name: "Receipts")
            w.server.setUserLabel(id: Pins.userLabelId, name: "Renamed")
            try await w.completedDelta()
            let folders = try await w.pool.read { db in
                try Folder.filter(Column("accountId") == w.accountId).fetchAll(db)
            }
            #expect(folders.first { $0.path == "Label_2" }?.name == "Receipts", "created")
            #expect(folders.first { $0.path == Pins.userLabelId }?.name == "Renamed", "renamed")

            w.server.removeUserLabel(id: "Label_2")
            try await w.completedDelta()
            let paths = try await w.pool.read { db in
                try Folder.filter(Column("accountId") == w.accountId).fetchAll(db).map(\.path)
            }
            #expect(!paths.contains("Label_2"), "deleted")
        }
    }

    // MARK: - R2-6: a stale label read during the app's own archive (#735)

    @Test("R2-6: a message archived by the app during a stale label read is listed in All Mail on a later pass (#735)")
    func staleReadDuringArchiveHeals() async throws {
        try await Pins.withWorld(seeds: [
            Pins.seed("r26-msg", labels: ["INBOX"], date: Pins.daysAgo(120)),
        ]) { w in
            // The app's archive is queued: the Inbox row is gone optimistically.
            let op = try w.insertOp(.archive, key: "r26-msg", folder: w.inbox)
            // A change read while the archive is still in flight sees the old labels.
            w.server.applyLabelChange(providerMessageId: "r26-msg", add: ["STARRED"])
            try await w.completedDelta()
            #expect(try w.rows("r26-msg").isEmpty, "precondition: the stale read inserted nothing")

            // The archive completes.
            w.server.applyLabelChange(providerMessageId: "r26-msg", remove: ["INBOX"])
            try await w.pool.write { db in _ = try PendingOperation.deleteOne(db, key: op.id) }
            await AccountManager.shared.recordRecentlyCompleted(messageIds: ["r26-msg"])
            try await w.completedDelta()
            #expect(try w.row("r26-msg", in: w.allMail) == nil, "precondition: held back by the just-completed archive")

            // The protection lifts; no new history touches the message.
            await AccountManager.shared.clearRecentlyCompletedForTesting()
            try await w.completedDelta()
            #expect(try w.row("r26-msg", in: w.allMail) != nil, "listed in All Mail")
        }
    }

    // MARK: - R2-8: a new account lists each folder once (#783)

    @Test("R2-8: a new account's first sync lists each folder once for the catch-up, and a change during it reaches the next pass (#783)")
    func newAccountListsEachFolderOnce() async throws {
        try await Pins.withWorld(seeds: [
            Pins.seed("r28-old", labels: ["INBOX", "UNREAD"], date: Pins.daysAgo(30)),
            Pins.seed("r28-new", labels: ["INBOX"], date: Pins.daysAgo(0.2)),
        ]) { w in
            try await Self.clearBookmark(w)
            let fired = Mutex(false)
            let server = w.server
            w.server.onGet(providerMessageId: "r28-new") {
                guard fired.withLock({ was in defer { was = true }; return !was }) else { return }
                server.applyLabelChange(providerMessageId: "r28-old", remove: ["UNREAD"])
            }
            try await w.foregroundPassWithFullSyncDue()
            let first = Self.catchUpListings(w)
            #expect(!first.isEmpty, "precondition: the first sync ran the catch-up")
            #expect(try w.account().lastHistoryId != nil, "the first sync stored a bookmark")

            try await w.foregroundPassWithFullSyncDue()
            #expect(Self.catchUpListings(w).count == first.count, "no folder is listed a second time")

            try await w.completedDelta()
            #expect(try w.row("r28-old", in: w.inbox)?.isRead == true, "the change made during the first sync arrives")
        }
    }
}
