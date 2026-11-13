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

    @Test("Reader: a message whose own answer is unusable is read again later; the rest of the pass lands and the bookmark moves")
    func readerUnreadableMessage() async throws {
        try await Pins.withWorld(seeds: [
            Pins.seed("rf-del", labels: ["INBOX"]), Pins.seed("rf-chg", labels: ["INBOX"]),
        ]) { w in
            let cursor = w.server.currentHistoryId()
            w.server.removeMessage(providerMessageId: "rf-del")
            w.server.applyLabelChange(providerMessageId: "rf-chg", add: ["STARRED"])
            w.server.injectGetFailure(providerMessageId: "rf-chg", .status(500))
            let set = try await Self.read(w, cursor: cursor)
            #expect(set.account == .set(w.server.currentHistoryId()))
            for folder in [w.inbox, w.allMail, w.label] {
                let changes = try #require(Self.changes(set, folder))
                #expect(changes.removals == ["rf-del"], "\(folder.path)")
                #expect(changes.rereadLater == ["rf-chg"], "every folder reads it again: \(folder.path)")
                #expect(changes.records.isEmpty, "\(folder.path)")
                guard case .tracked = changes.status else { Issue.record("expected .tracked in \(folder.path), got \(changes.status)"); return }
            }
        }
    }

    @Test("Reader: a failure about the account keeps the history's removals, reports the failure and keeps the bookmark")
    func readerAccountFailure() async throws {
        try await Pins.withWorld(seeds: [
            Pins.seed("rf-del", labels: ["INBOX"]), Pins.seed("rf-chg", labels: ["INBOX"]),
        ]) { w in
            let cursor = w.server.currentHistoryId()
            w.server.removeMessage(providerMessageId: "rf-del")
            w.server.applyLabelChange(providerMessageId: "rf-chg", add: ["STARRED"])
            w.server.injectGetFailure(providerMessageId: "rf-chg", .transport(.networkConnectionLost))
            let set = try await Self.read(w, cursor: cursor)
            #expect(set.account == .keep)
            let inbox = try #require(Self.changes(set, w.inbox))
            #expect(inbox.removals == ["rf-del"])
            #expect(inbox.rereadLater.isEmpty)
            guard case .failed = inbox.status else { Issue.record("expected .failed, got \(inbox.status)"); return }
        }
    }

    // MARK: - the bookmark is read before the listing

    @Test("a change made to older mail during a new bookmark's listing arrives on the next pass (#464, #460)")
    func changeDuringBaselineListingArrives() async throws {
        try await Pins.withWorld(seeds: [
            Pins.seed("during-listing-old", labels: ["INBOX", "UNREAD"], date: Pins.daysAgo(60)),
        ]) { w in
            try w.insertRow("during-listing-old", in: w.inbox, date: Pins.daysAgo(60), isRead: false)
            // A pass that completes the catch-up's first look, so no catch-up
            // listing runs in the pass under test.
            try await w.foregroundPassWithFullSyncDue()
            try await Self.clearBookmark(w)

            // All Mail is listed after the Inbox; reading this new archived
            // message's details is the moment another client marks the old
            // Inbox message read.
            w.server.addMessage(Pins.seed("during-listing-archived", labels: [], date: Pins.daysAgo(0.1)))
            let fired = Mutex(false)
            let server = w.server
            w.server.onGet(providerMessageId: "during-listing-archived") {
                guard fired.withLock({ was in defer { was = true }; return !was }) else { return }
                server.applyLabelChange(providerMessageId: "during-listing-old", remove: ["UNREAD"])
            }
            try await w.foregroundPassWithFullSyncDue()
            #expect(fired.withLock { $0 }, "precondition: the change was made during the listing")

            try await w.completedDelta()
            #expect(try w.row("during-listing-old", in: w.inbox)?.isRead == true, "the next pass reads the change")
        }
    }

    // MARK: - a kept-back change on older mail converges

    @Test("a flag change on older mail kept back under a pending op lands once the op is gone")
    func shieldedOlderFlagConverges() async throws {
        try await Pins.withWorld(seeds: [
            Pins.seed("kept-back-old", labels: ["INBOX", "UNREAD"], date: Pins.daysAgo(90)),
        ]) { w in
            try w.insertRow("kept-back-old", in: w.inbox, date: Pins.daysAgo(90), isRead: false)
            let op = try w.insertOp(.markUnread, key: "kept-back-old", folder: w.inbox)
            w.server.applyLabelChange(providerMessageId: "kept-back-old", add: ["STARRED"])
            try await w.completedDelta()
            #expect(try w.row("kept-back-old", in: w.inbox)?.isFlagged == false, "precondition: kept back")

            try await w.pool.write { db in _ = try PendingOperation.deleteOne(db, key: op.id) }
            try await w.completedDelta()
            #expect(try w.row("kept-back-old", in: w.inbox)?.isFlagged == true, "the next pass lands it, with no new history")
        }
    }

    // MARK: - a tracked folder gets no window listing

    @Test("a full sync of a tracked Gmail account sends no window listing")
    func trackedFoldersAreNotListed() async throws {
        try await Pins.withWorld(seeds: [Pins.seed("tracked-1", labels: ["INBOX"])]) { w in
            try await w.foregroundPassWithFullSyncDue()
            let before = Self.windowListings(w)
            #expect(before > 0, "precondition: the first pass listed the untracked folders")
            try await w.foregroundPassWithFullSyncDue()
            #expect(Self.windowListings(w) == before, "no window listing once the folders are tracked")
        }
    }

    // MARK: - a refusal re-lists once; no scheduled check while tracked

    @Test("a refusal re-lists in the same pass, stores a new bookmark, runs ONE catch-up check, and none later while tracked")
    func refusalRelistsOnce() async throws {
        try await Pins.withWorld(seeds: [
            Pins.seed("refused-1", labels: ["INBOX"], date: Pins.daysAgo(40)),
            Pins.seed("refused-2", labels: ["INBOX"], date: Pins.daysAgo(1)),
        ]) { w in
            try await w.foregroundPassWithFullSyncDue()
            w.server.applyLabelChange(providerMessageId: "refused-1", add: ["STARRED"])
            w.server.expireHistory()

            let catchUpBefore = Self.catchUpListings(w).count
            let windowBefore = Self.windowListings(w)
            try await w.foregroundPassWithFullSyncDue()
            #expect(Self.windowListings(w) > windowBefore, "the refusal re-lists in the same pass")
            #expect(try w.account().lastHistoryId == w.server.currentHistoryId(), "and stores a new bookmark")
            let catchUpAfterRefusal = Self.catchUpListings(w).count
            #expect(catchUpAfterRefusal > catchUpBefore, "one catch-up check runs")
            #expect(try w.row("refused-1", in: w.inbox)?.isFlagged == true)

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

    enum NeedsListing: String, CaseIterable, Sendable {
        /// The server refuses the bookmark (history expired).
        case refused
        /// The account has no bookmark (a reset).
        case noBookmark
    }

    /// The pass reads the account before its change read, so the full sync due
    /// time that read writes is not in the pass's copy. With the full sync NOT
    /// due on that copy, the read's need for a listing alone must still run the
    /// listing and store the new bookmark in the same pass.
    @Test("a read that needs a listing lists in the same pass even when the full sync was not due", arguments: NeedsListing.allCases)
    func listingNeededRunsTheFullSync(reason: NeedsListing) async throws {
        try await Pins.withWorld(seeds: [
            Pins.seed("not-due-1", labels: ["INBOX"], date: Pins.daysAgo(40)),
        ]) { w in
            try await w.foregroundPassWithFullSyncDue()
            #expect(try w.account().lastHistoryId == w.server.currentHistoryId(), "precondition: a bookmark is stored")
            switch reason {
            case .refused:
                // A change past the stored bookmark, then the history expires
                // below it: the read is answered 404.
                w.server.applyLabelChange(providerMessageId: "not-due-1", add: ["STARRED"])
                w.server.expireHistory()
            case .noBookmark: try await Self.clearBookmark(w)
            }
            try await w.pool.write { db in
                _ = try Account.filter(Column("id") == w.accountId).updateAll(db,
                    Column("lastSyncedAt").set(to: nil as Date?),
                    Column("lastFullSyncAt").set(to: Date().addingTimeInterval(-60)))
            }
            let windowBefore = Self.windowListings(w)
            let engine = SyncEngine()
            await engine.register(
                accountId: w.accountId, provider: w.provider,
                workQueue: ProviderWorkQueue(provider: w.provider, maxConcurrency: 1))
            _ = try await engine.sync(account: try w.account())

            #expect(Self.windowListings(w) > windowBefore, "the read needed a listing and the pass did not list")
            #expect(try w.account().lastHistoryId == w.server.currentHistoryId(), "the new bookmark was not stored in the same pass")
        }
    }

    static func isTracking(_ w: Pins.World, _ folder: Folder) throws -> Bool {
        try w.pool.read { db in
            FolderChangeState(raw: try Folder.fetchOne(db, key: folder.id)?.changeState).tracking
        }
    }

    /// A folder is tracked only after a window listing of it finished: a folder
    /// the read covered but the full sync did not list (its listing lost the
    /// connection twice) stays untracked, so the next full sync lists it.
    @Test("a folder whose window listing did not finish is not tracked, and a later pass lists it")
    func unlistedFolderStaysUntracked() async throws {
        try await Pins.withWorld(seeds: [
            Pins.seed("unlisted-1", labels: [Pins.userLabelId], date: Pins.daysAgo(1)),
        ]) { w in
            try await w.foregroundPassWithFullSyncDue()
            #expect(try Self.isTracking(w, w.label), "precondition: the label folder is tracked")
            try await w.pool.write { db in
                try db.execute(sql: "UPDATE folder SET changeState = NULL WHERE id = ?", arguments: [w.label.id])
            }

            w.server.failListings(transport: .networkConnectionLost, label: Pins.userLabelId)
            try await w.foregroundPassWithFullSyncDue()
            w.server.clearListingFailures()
            #expect(w.server.listingFailuresServedCount() > 0, "precondition: the label's window listing failed")
            #expect(try w.account().lastFullSyncAt != nil, "precondition: the full sync finished past the failed folder")
            #expect(try !Self.isTracking(w, w.label), "a folder the full sync did not list must not be tracked")
            #expect(try Self.isTracking(w, w.inbox), "non-vacuity: a listed folder stays tracked")

            let before = Self.windowListings(w)
            try await w.foregroundPassWithFullSyncDue()
            #expect(Self.windowListings(w) > before, "the untracked folder is listed once its listing works")
            #expect(try Self.isTracking(w, w.label), "and tracked after that listing")
        }
    }

    /// A message-data reset clears the bookmark and every folder's change state
    /// outside the account's sync turn, so a pass already past its change read
    /// can turn tracking back on after the reset: folders flagged tracked with
    /// no bookmark. The account must still converge: with no bookmark nothing
    /// covers a folder, so the next pass lists every folder and stores one.
    @Test("folders left flagged tracked with no bookmark are listed, and the pass stores a bookmark")
    func trackedFoldersWithNoBookmarkAreListed() async throws {
        try await Pins.withWorld(seeds: [
            Pins.seed("no-bookmark-1", labels: ["INBOX"], date: Pins.daysAgo(1)),
        ]) { w in
            try await w.foregroundPassWithFullSyncDue()
            #expect(try Self.isTracking(w, w.inbox), "precondition: the folders are tracked")
            // The state a reset racing a pass leaves: the bookmark is gone, the flags are back.
            try await w.pool.write { db in
                _ = try Account.filter(Column("id") == w.accountId).updateAll(db, Column("lastHistoryId").set(to: nil as String?))
            }
            w.server.addMessage(Pins.seed("no-bookmark-new", labels: ["INBOX"], date: Pins.daysAgo(0)))

            let before = Self.windowListings(w)
            try await w.foregroundPassWithFullSyncDue()
            #expect(Self.windowListings(w) > before, "a folder flagged tracked was skipped with no bookmark to cover it")
            #expect(try w.account().lastHistoryId == w.server.currentHistoryId(), "the pass did not store a bookmark")
            #expect(try w.row("no-bookmark-new", in: w.inbox) != nil, "new mail did not land")
        }
    }

    /// The folder list is applied on every change read with scope `.all` (each
    /// poll and push wake). Its write must leave the backfill walk's version
    /// alone, or a page walk in progress fails its compare-and-set on every poll.
    @Test("applying the read's folder list leaves the backfill walk's version unchanged")
    func folderListKeepsBackfillVersion() async throws {
        try await Pins.withWorld(seeds: [
            Pins.seed("version-1", labels: ["INBOX"], date: Pins.daysAgo(1)),
        ]) { w in
            // Delta passes only: a foreground pass would start the backfill walk,
            // which bumps the version itself.
            try await w.completedDelta()
            let versions = { try w.pool.read { db in
                try Dictionary(uniqueKeysWithValues: Folder.filter(Column("accountId") == w.accountId).fetchAll(db)
                    .map { ($0.id, $0.backfillVersion) })
            } }
            let before = try versions()
            #expect(!before.isEmpty, "precondition: the account has folders")
            w.server.setUserLabel(id: Pins.userLabelId, name: "Renamed")
            try await w.completedDelta()
            let labelName = { try w.pool.read { db in try Folder.fetchOne(db, key: w.label.id)?.name } }
            #expect(try labelName() == "Renamed", "precondition: the read's folder list was applied")
            #expect(try versions() == before, "a folder list write bumped the backfill version")
        }
    }

    // MARK: - label changes show on the next pass

    @Test("a label created, renamed or deleted on the server shows on the next pass")
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

    static func labelRequests(_ w: Pins.World) -> Int {
        w.server.http.recordedCalls().filter { URL(string: $0.url)?.path.hasSuffix("/labels") == true }.count
    }

    /// The folder list is applied by `applyFolderList`, shared by the change
    /// read and the full sync. A foreground pass with the full sync due applies
    /// it once: the read's list, which the full sync takes instead of asking again.
    @Test("a foreground pass with the full sync due applies the folder list from one label request")
    func foregroundPassAppliesFolderListOnce() async throws {
        try await Pins.withWorld(seeds: []) { w in
            w.server.setUserLabel(id: "Label_3", name: "Travel")
            w.server.removeUserLabel(id: Pins.userLabelId)
            let before = Self.labelRequests(w)
            try await w.foregroundPassWithFullSyncDue()
            let paths = try await w.pool.read { db in
                try Folder.filter(Column("accountId") == w.accountId).fetchAll(db).map(\.path)
            }
            #expect(paths.contains("Label_3"), "a label created on the server is a folder after the pass")
            #expect(!paths.contains(Pins.userLabelId), "a label deleted on the server is gone after the pass")
            #expect(Self.labelRequests(w) - before == 1, "the pass asked for the label list \(Self.labelRequests(w) - before) times")
        }
    }

    // MARK: - a refusal whose re-read loses the connection

    /// Each folder's lapse count (`CatchUpLapse.countKey`, absent = 0), for the
    /// folders that hold a catch-up state.
    static func lapseCounts(_ w: Pins.World) throws -> [String: Int] {
        try w.pool.read { db in
            var counts: [String: Int] = [:]
            for row in try Row.fetchAll(db, sql: """
                SELECT id, COALESCE(json_extract(catchUpState, '$.' || ?), 0) AS n
                FROM folder WHERE accountId = ? AND catchUpState IS NOT NULL
                """, arguments: [CatchUpLapse.countKey, w.accountId]) {
                counts[row["id"] as String] = row["n"] as Int
            }
            return counts
        }
    }

    /// The refusal is applied (bookmark cleared, one lapse) before the same pass
    /// reads again with no bookmark. When that re-read loses the connection, the
    /// pass's retry must start from the account as it is now (no bookmark), not
    /// from the pass's copy: that copy's bookmark is refused a second time. The
    /// full sync is not forced due, so the pass lists only because the read
    /// needs it, and having listed it must not report the lost connection.
    @Test("a refusal whose re-read loses the connection marks ONE lapse, reads the history once, and the pass that lists does not fail")
    func refusalThenLostConnectionMarksOneLapse() async throws {
        try await Pins.withWorld(seeds: [
            Pins.seed("lapse-once", labels: ["INBOX"], date: Pins.daysAgo(40)),
        ]) { w in
            try await w.foregroundPassWithFullSyncDue()
            let before = try Self.lapseCounts(w)
            #expect(!before.isEmpty, "precondition: the folders hold a catch-up state")

            w.server.applyLabelChange(providerMessageId: "lapse-once", add: ["STARRED"])
            w.server.expireHistory()
            w.server.failNextProfile(transport: .networkConnectionLost)
            let historyBefore = w.historyRequestCount()
            #expect(try w.account().lastFullSyncAt != nil, "precondition: the full sync is not due by time")
            try await Self.foregroundPassFullSyncNotForced(w)

            #expect(w.server.profileFailuresServedCount() == 1, "precondition: the re-read after the refusal lost its connection")
            #expect(w.historyRequestCount() - historyBefore == 1, "the retry read the refused bookmark's history again")
            let after = try Self.lapseCounts(w)
            for (folderId, count) in before {
                #expect(after[folderId] == count + 1, "folder \(folderId.suffix(12)): lapse count \(count) -> \(after[folderId] ?? -1), not one lapse")
            }
            #expect(try w.account().lastHistoryId == w.server.currentHistoryId(), "the pass stores a new bookmark")
            #expect(try w.row("lapse-once", in: w.inbox)?.isFlagged == true, "the change behind the refusal lands")
        }
    }

    /// The background twin: its retry must start from the account row too.
    @Test("a background pass whose re-read after a refusal loses the connection marks ONE lapse and reads the history once")
    func backgroundRefusalThenLostConnectionMarksOneLapse() async throws {
        try await Pins.withWorld(seeds: [
            Pins.seed("bg-lapse-once", labels: ["INBOX"], date: Pins.daysAgo(40)),
        ]) { w in
            try await w.foregroundPassWithFullSyncDue()
            let before = try Self.lapseCounts(w)
            #expect(!before.isEmpty, "precondition: the folders hold a catch-up state")

            w.server.applyLabelChange(providerMessageId: "bg-lapse-once", add: ["STARRED"])
            w.server.expireHistory()
            w.server.failNextProfile(transport: .networkConnectionLost)
            let historyBefore = w.historyRequestCount()
            try await Self.backgroundPass(w)

            #expect(w.server.profileFailuresServedCount() == 1, "precondition: the re-read after the refusal lost its connection")
            #expect(w.historyRequestCount() - historyBefore == 1, "the retry read the refused bookmark's history again")
            let after = try Self.lapseCounts(w)
            for (folderId, count) in before {
                #expect(after[folderId] == count + 1, "folder \(folderId.suffix(12)): lapse count \(count) -> \(after[folderId] ?? -1), not one lapse")
            }
            #expect(try w.account().lastHistoryId == nil, "a background pass stores no candidate; the next foreground pass lists")
        }
    }

    // MARK: - a folder the full sync drops

    /// One foreground pass with the full sync NOT forced due.
    static func foregroundPassFullSyncNotForced(_ w: Pins.World) async throws {
        try await w.pool.write { db in
            _ = try Account.filter(Column("id") == w.accountId).updateAll(db, Column("lastSyncedAt").set(to: nil as Date?))
        }
        let engine = SyncEngine()
        await engine.register(
            accountId: w.accountId, provider: w.provider,
            workQueue: ProviderWorkQueue(provider: w.provider, maxConcurrency: 1))
        _ = try await engine.sync(account: try w.account())
    }

    /// The label ids of the full sync's window listings so far, in order (nil:
    /// All Mail, listed by query).
    static func windowListingLabels(_ w: Pins.World) -> [String?] {
        w.server.http.recordedCalls().compactMap { call -> String?? in
            guard let components = URLComponents(string: call.url), components.path.hasSuffix("/messages") else { return nil }
            let items = components.queryItems ?? []
            let q = items.first { $0.name == "q" }?.value ?? ""
            guard items.first(where: { $0.name == "maxResults" })?.value == String(SyncConfig.syncMessageLimit),
                  !items.contains(where: { $0.name == "pageToken" }),
                  !q.contains("after:"), !q.contains("before:") else { return nil }
            return .some(items.first { $0.name == "labelIds" }?.value)
        }
    }

    /// The candidate is read before the listings, so a folder the full sync
    /// drops does not hold it back: the dropped folders stay untracked, the full
    /// sync stays due, and the next foreground pass lists only them. Their
    /// changes after the candidate arrive by the reads. A lost connection stops
    /// the listing at that folder, so every later folder is dropped too.
    @Test("a first sync whose listing loses the connection stores the bookmark, and the next pass lists only the folders not yet listed, with their changes")
    func droppedFolderDoesNotHoldTheBookmark() async throws {
        try await Pins.withWorld(seeds: [
            Pins.seed("dropped-changed", labels: [Pins.userLabelId], date: Pins.daysAgo(2)),
            Pins.seed("dropped-quiet", labels: [Pins.userLabelId], date: Pins.daysAgo(2)),
            Pins.seed("dropped-inbox", labels: ["INBOX"], date: Pins.daysAgo(2)),
        ]) { w in
            // A new account: no bookmark, nothing tracked.
            try await Self.clearBookmark(w)
            w.server.failListings(transport: .networkConnectionLost, label: Pins.userLabelId)
            try await w.foregroundPassWithFullSyncDue()
            #expect(w.server.listingFailuresServedCount() > 0, "precondition: the label's listing lost the connection")
            #expect(try w.account().lastHistoryId != nil, "the bookmark is stored though the listing dropped folders")
            #expect(try Self.isTracking(w, w.inbox), "a listed folder is tracked")
            #expect(try !Self.isTracking(w, w.label), "a dropped folder stays untracked")
            #expect(try w.account().lastFullSyncAt == nil, "the full sync stays due")
            #expect(try w.row("dropped-inbox", in: w.inbox) != nil)

            // During the failure another client changes a message in the dropped folder.
            w.server.applyLabelChange(providerMessageId: "dropped-changed", add: ["STARRED"])
            let beforeRetry = Self.windowListingLabels(w).count
            try await Self.foregroundPassFullSyncNotForced(w)
            let retried = Array(Self.windowListingLabels(w).dropFirst(beforeRetry))
            #expect(retried.contains(Pins.userLabelId), "the next pass lists the dropped folder again: \(retried)")
            #expect(!retried.contains("INBOX"), "a tracked folder is not listed again: \(retried)")
            #expect(try w.row("dropped-changed", in: w.label)?.isFlagged == true,
                    "a change to a message the dropped folder does not hold yet arrives by the read")

            w.server.clearListingFailures()
            let beforeRecovery = Self.windowListingLabels(w).count
            try await Self.foregroundPassFullSyncNotForced(w)
            let recovered = Array(Self.windowListingLabels(w).dropFirst(beforeRecovery))
            #expect(recovered.contains(Pins.userLabelId) && !recovered.contains("INBOX"),
                    "once the listing works the pass lists only the folders not yet listed: \(recovered)")
            #expect(try Self.isTracking(w, w.label), "and tracks them")
            #expect(try w.account().lastFullSyncAt != nil, "and the full sync is done")
            #expect(try w.row("dropped-changed", in: w.label)?.isFlagged == true, "the change made during the failure is there")
            #expect(try w.row("dropped-quiet", in: w.label) != nil, "a message no change named arrives by the listing")

            let afterDone = Self.windowListingLabels(w).count
            try await Self.foregroundPassFullSyncNotForced(w)
            #expect(Self.windowListingLabels(w).count == afterDone, "with the full sync done, the next pass lists nothing")
        }
    }

    // MARK: - full re-read lists and the background deadline

    /// One background pass as the app runs it: the delta only, under the
    /// per-account deadline.
    static func backgroundPass(_ w: Pins.World) async throws {
        let engine = SyncEngine()
        await engine.register(
            accountId: w.accountId, provider: w.provider,
            workQueue: ProviderWorkQueue(provider: w.provider, maxConcurrency: 1))
        let account = try w.account()
        _ = try await withTimeout(seconds: SyncConfig.backgroundPerAccountTimeoutSeconds) {
            try await engine.backgroundDeltaSync(account: account, inboxOnly: true)
        }
    }

    /// Full re-read lists on a slow server: reading every listed id would take
    /// half again the background deadline. The pass must still land new mail and
    /// move the bookmark inside it, and drop no id it did not read.
    @Test("with full re-read lists and a slow server, a background pass lands new mail and moves the bookmark inside its deadline; the ids it did not read stay listed")
    func fullRereadListsFitTheBackgroundDeadline() async throws {
        let ids = (0..<SyncConfig.changeRecheckLimit).map { "slow-reread-\($0)" }
        try await Pins.withWorld(seeds: ids.map { Pins.seed($0, labels: ["INBOX"], date: Pins.daysAgo(30)) }) { w in
            let rounds = (Double(ids.count) / Double(GmailAPI.maxConcurrentRequests)).rounded(.up)
            let latency = SyncConfig.backgroundPerAccountTimeoutSeconds * 1.5 / rounds
            for id in ids { w.server.holdGet(providerMessageId: id, forSeconds: latency) }
            try await w.pool.write { db in
                try db.execute(sql: "UPDATE folder SET changeState = ? WHERE id = ?",
                               arguments: [FolderChangeState(tracking: true, recheck: ids).encoded, w.inbox.id])
            }
            w.server.addMessage(Pins.seed("slow-new-mail", labels: ["INBOX", "UNREAD"], date: Pins.daysAgo(0)))

            try await Self.backgroundPass(w)

            #expect(try w.row("slow-new-mail", in: w.inbox) != nil, "new mail landed")
            #expect(try w.account().lastHistoryId == w.server.currentHistoryId(), "the bookmark moved")
            let read = Set(w.server.messageGets()).intersection(ids)
            let inboxId = w.inbox.id
            let left = try await w.pool.read { db in
                FolderChangeState(raw: try Folder.fetchOne(db, key: inboxId)?.changeState).recheck
            }
            #expect(read.count == SyncConfig.changeRereadBudgetPerPass, "the pass re-read \(read.count) ids, not the budget")
            #expect(!left.isEmpty, "precondition: the pass did not read every listed id")
            #expect(Set(left) == Set(ids).subtracting(read),
                    "every id the pass did not read stays listed, and every id it read and applied leaves")
        }
    }

    // MARK: - a stale label read during the app's own archive (#735)

    @Test("a message archived by the app during a stale label read is listed in All Mail on a later pass (#735)")
    func staleReadDuringArchiveHeals() async throws {
        try await Pins.withWorld(seeds: [
            Pins.seed("stale-read-msg", labels: ["INBOX"], date: Pins.daysAgo(120)),
        ]) { w in
            // The app's archive is queued: the Inbox row is gone optimistically.
            let op = try w.insertOp(.archive, key: "stale-read-msg", folder: w.inbox)
            // A change read while the archive is still in flight sees the old labels.
            w.server.applyLabelChange(providerMessageId: "stale-read-msg", add: ["STARRED"])
            try await w.completedDelta()
            #expect(try w.rows("stale-read-msg").isEmpty, "precondition: the stale read inserted nothing")

            // The archive completes.
            w.server.applyLabelChange(providerMessageId: "stale-read-msg", remove: ["INBOX"])
            try await w.pool.write { db in _ = try PendingOperation.deleteOne(db, key: op.id) }
            await AccountManager.shared.recordRecentlyCompleted(messageIds: ["stale-read-msg"])
            try await w.completedDelta()
            #expect(try w.row("stale-read-msg", in: w.allMail) == nil, "precondition: held back by the just-completed archive")

            // The protection lifts; no new history touches the message.
            await AccountManager.shared.clearRecentlyCompletedForTesting()
            try await w.completedDelta()
            #expect(try w.row("stale-read-msg", in: w.allMail) != nil, "listed in All Mail")
        }
    }

    // MARK: - a new account lists each folder once (#783)

    @Test("a new account's first sync lists each folder once for the catch-up, and a change during it reaches the next pass (#783)")
    func newAccountListsEachFolderOnce() async throws {
        try await Pins.withWorld(seeds: [
            Pins.seed("new-account-old", labels: ["INBOX", "UNREAD"], date: Pins.daysAgo(30)),
            Pins.seed("new-account-new", labels: ["INBOX"], date: Pins.daysAgo(0.2)),
        ]) { w in
            try await Self.clearBookmark(w)
            let fired = Mutex(false)
            let server = w.server
            w.server.onGet(providerMessageId: "new-account-new") {
                guard fired.withLock({ was in defer { was = true }; return !was }) else { return }
                server.applyLabelChange(providerMessageId: "new-account-old", remove: ["UNREAD"])
            }
            try await w.foregroundPassWithFullSyncDue()
            let first = Self.catchUpListings(w)
            #expect(!first.isEmpty, "precondition: the first sync ran the catch-up")
            #expect(try w.account().lastHistoryId != nil, "the first sync stored a bookmark")

            try await w.foregroundPassWithFullSyncDue()
            #expect(Self.catchUpListings(w).count == first.count, "no folder is listed a second time")

            try await w.completedDelta()
            #expect(try w.row("new-account-old", in: w.inbox)?.isRead == true, "the change made during the first sync arrives")
        }
    }
}
