/* This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at https://mozilla.org/MPL/2.0/. */

import Foundation
import GRDB
import Testing
@testable import TabMail

/// INVARIANT: **a row whose move the queued write refused is VISIBLE in the list
/// again once the action settles.**
///
/// `InboxView` hides a row at gesture time by inserting its id into the `@State` set
/// `dismissedMessages` and renders `visibleGroups = displayGroups − dismissedMessages`.
/// The move itself is admitted later, inside the queued write (`AccountManager.move`),
/// where the IMAP admission compares the row's observed UIDVALIDITY with the folder's.
/// When the folder's epoch moved between the gesture and that write, the move is
/// refused: nothing is written, the overlay is released and the list reloads, but the
/// view's own hide set still named the row, so the message now at that address stayed
/// hidden until the view was rebuilt (tabmail-ios #441).
///
/// These tests drive the real gesture (`InboxViewModel`), the real queued write and the
/// view's real settlement seam (`MoveRefusalReceiver`), and assert on the VISIBLE set,
/// so they stay valid if the mechanism is replaced. The `IntentionLedger` settles each
/// refused intention: REPORTED-REFUSED is the only honest outcome for a move that was
/// neither executed nor left queued. The positive control pins the other direction: an
/// admitted move stays hidden.
///
/// `.serialized` / `.processGlobalState`: swaps `AppDatabase.shared`, gates the
/// process-wide FIFO write queue and touches the `AccountManager.shared` overlay.
@Suite("A refused queued move shows its row again", .serialized, .processGlobalState)
@MainActor
struct InboxRefusedMoveVisibilityTests {

    enum Gesture: String, CaseIterable, Sendable {
        case archive, delete, move, archiveThread
    }

    private enum Config {
        static let gestureEpoch = 41
        static let resetEpoch = 42
        static let uid = "71"
        static let siblingUid = "72"
    }

    private struct Fixture {
        let pool: DatabasePool
        let dir: URL
        let previous: AppDatabase?
        let accountId: String
        let inbox: Folder
        let archive: Folder
        let trash: Folder
        let projects: Folder
    }

    // MARK: - Harness

    private func makeFixture() throws -> Fixture {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        var config = Configuration()
        config.foreignKeysEnabled = true
        let pool = try DatabasePool(path: dir.appendingPathComponent("test.sqlite").path, configuration: config)
        let appDb = try AppDatabase(dbPool: pool)
        let previous = AppDatabase.shared.withLock { current -> AppDatabase? in
            let prev = current; current = appDb; return prev
        }
        let accountId = "refused-move-\(UUID().uuidString)"
        var account = Account(emailAddress: "user@example.com", displayName: "Test", provider: .imap)
        account.id = accountId
        func folder(_ name: String, _ role: FolderRole) -> Folder {
            var folder = Folder(name: name, path: name, role: role, accountId: accountId)
            folder.lastKnownUidValidity = Config.gestureEpoch
            return folder
        }
        let inbox = folder("INBOX", .inbox)
        let archive = folder("Archive", .archive)
        let trash = folder("Trash", .trash)
        let projects = folder("Projects", .custom)
        try pool.writeWithoutTransaction { db in
            try account.insert(db)
            for folder in [inbox, archive, trash, projects] { try folder.insert(db) }
        }
        return Fixture(
            pool: pool, dir: dir, previous: previous, accountId: accountId,
            inbox: inbox, archive: archive, trash: trash, projects: projects)
    }

    private func insertInboxHeader(_ fixture: Fixture, uid: String) throws -> String {
        var header = MessageHeader(
            messageId: uid, subject: "Subj \(uid)", from: "Sender",
            fromAddress: "sender@example.com", to: "me@example.com", date: Date(),
            snippet: "snip", folderId: fixture.inbox.id, accountId: fixture.accountId,
            folderPath: fixture.inbox.path, isInInbox: true)
        header.headerComplete = true
        header.observedUidValidity = Config.gestureEpoch
        try fixture.pool.writeWithoutTransaction { db in try header.insert(db) }
        return header.id
    }

    private func setInboxEpoch(_ fixture: Fixture, _ epoch: Int) throws {
        try fixture.pool.writeWithoutTransaction { db in
            _ = try Folder.filter(key: fixture.inbox.id)
                .updateAll(db, Column("lastKnownUidValidity").set(to: epoch))
        }
    }

    private func restore(_ fixture: Fixture) {
        clearOverlay()
        UndoService.shared.dismissAll()
        InstalledTestDatabaseLifetime.finish(
            previous: fixture.previous, pool: fixture.pool, directory: fixture.dir)
    }

    private func clearOverlay() {
        let snapshot = AccountManager.shared.snapshotOverlay()
        AccountManager.shared.removeOverlayEntries(ids: Array(snapshot.keys))
    }

    /// `InboxView`'s `visibleGroups`, verbatim.
    private func visibleIds(_ vm: InboxViewModel, dismissed: Set<String>) -> Set<String> {
        Set(vm.displayGroups
            .filter { !dismissed.contains($0.representative.id) }
            .flatMap { $0.members.map(\.id) })
    }

    /// Blocks the FIFO write queue until the returned continuation finishes, so the
    /// gesture's queued write cannot run before the test moves the folder's epoch.
    private func gateWriteQueue() async -> AsyncStream<Void>.Continuation {
        let (stream, gate) = AsyncStream<Void>.makeStream()
        await AccountManager.shared.enqueueWrite {
            var iterator = stream.makeAsyncIterator()
            _ = await iterator.next()
        }
        return gate
    }

    /// Runs `gesture` exactly as `InboxView` does: hide first, then the view-model call,
    /// then un-hide whatever the call itself reports as skipped.
    private func performGesture(
        _ gesture: Gesture, vm: InboxViewModel, ids: [String], fixture: Fixture,
        dismissed: inout Set<String>, fading: inout Set<String>
    ) async {
        dismissed.formUnion(ids)
        fading.formUnion(ids)
        switch gesture {
        case .archive:
            #expect(vm.archive(ids[0]), "setup: the gesture must record")
        case .delete:
            #expect(await vm.delete(ids[0]), "setup: the gesture must record")
        case .move:
            #expect(vm.move(ids[0], toFolderPath: fixture.projects.path), "setup: the gesture must record")
        case .archiveThread:
            let skipped = vm.archiveThread(ids)
            #expect(skipped.isEmpty, "setup: every member must record")
            MoveRefusalReceiver.apply(
                Set(skipped), dismissedMessages: &dismissed, swipeFadingMessages: &fading)
        }
    }

    private func destination(_ gesture: Gesture, _ fixture: Fixture) -> Folder {
        switch gesture {
        case .archive, .archiveThread: fixture.archive
        case .delete: fixture.trash
        case .move: fixture.projects
        }
    }

    // MARK: - Refused at the queued write

    @Test(
        "A move refused at the queued write (folder epoch moved after the gesture) shows the row again",
        arguments: Gesture.allCases)
    func refusedMoveRowIsVisibleAgain(gesture: Gesture) async throws {
        let fixture = try makeFixture()
        defer { restore(fixture) }
        clearOverlay()

        var ids = [try insertInboxHeader(fixture, uid: Config.uid)]
        if gesture == .archiveThread {
            ids.append(try insertInboxHeader(fixture, uid: Config.siblingUid))
        }
        let vm = InboxViewModel(folders: [fixture.inbox])
        await vm.reloadMessages()
        #expect(visibleIds(vm, dismissed: []).isSuperset(of: ids), "precondition: rows are listed")

        let tap = MoveRefusalTap(watching: Set(ids))
        defer { tap.stop() }
        let gate = await gateWriteQueue()
        var dismissed: Set<String> = []
        var fading: Set<String> = []
        await performGesture(
            gesture, vm: vm, ids: ids, fixture: fixture,
            dismissed: &dismissed, fading: &fading)
        #expect(visibleIds(vm, dismissed: dismissed).isDisjoint(with: ids),
                "precondition: the gesture hides the rows")

        // The folder's UIDVALIDITY turns over after the gesture and before its queued
        // write runs: the addresses the gesture named may now hold different messages.
        try setInboxEpoch(fixture, Config.resetEpoch)
        gate.finish()
        await AccountManager.shared.awaitWriteQueueDrain()

        // The view's settlement seam applies what the manager reported.
        MoveRefusalReceiver.apply(
            tap.snapshot, dismissedMessages: &dismissed, swipeFadingMessages: &fading)
        await vm.reloadMessages()

        let visible = visibleIds(vm, dismissed: dismissed)
        for id in ids {
            #expect(visible.contains(id),
                    "\(gesture.rawValue): the refused row must be visible again, not hidden for the life of the view")
            #expect(!fading.contains(id), "\(gesture.rawValue): the refused row must not stay faded")
        }

        let destinationId = destination(gesture, fixture).id
        let ledger = IntentionLedger()
        for id in ids {
            ledger.record(
                label: "\(gesture.rawValue) \(id)",
                durableIdentity: id.split(separator: ":").last.map(String.init) ?? id,
                reportIdentity: id,
                endStateAchieved: { db in
                    try MessageHeader.fetchOne(db, key: id)?.folderId == destinationId
                })
        }
        let outcomes = await ledger.settle(
            pool: fixture.pool, reportedIds: tap.snapshot)
        #expect(outcomes.count == ids.count)
        #expect(outcomes.allSatisfy { $0.outcome == .reportedRefused },
                "a refused move must settle REPORTED-REFUSED: \(outcomes.map { "\($0.label)=\($0.outcome)" })")
    }

    // MARK: - Positive control

    @Test("An admitted move keeps its row hidden and reports no refusal", arguments: Gesture.allCases)
    func admittedMoveRowStaysHidden(gesture: Gesture) async throws {
        let fixture = try makeFixture()
        defer { restore(fixture) }
        clearOverlay()

        var ids = [try insertInboxHeader(fixture, uid: Config.uid)]
        if gesture == .archiveThread {
            ids.append(try insertInboxHeader(fixture, uid: Config.siblingUid))
        }
        let vm = InboxViewModel(folders: [fixture.inbox])
        await vm.reloadMessages()

        let tap = MoveRefusalTap(watching: Set(ids))
        defer { tap.stop() }
        var dismissed: Set<String> = []
        var fading: Set<String> = []
        await performGesture(
            gesture, vm: vm, ids: ids, fixture: fixture,
            dismissed: &dismissed, fading: &fading)
        await AccountManager.shared.awaitWriteQueueDrain()

        #expect(tap.snapshot.isEmpty, "an admitted move must not be reported refused")
        MoveRefusalReceiver.apply(
            tap.snapshot, dismissedMessages: &dismissed, swipeFadingMessages: &fading)
        await vm.reloadMessages()

        let destinationId = destination(gesture, fixture).id
        let movedIds = ids
        let folders = try await fixture.pool.read { db in
            try movedIds.map { try MessageHeader.fetchOne(db, key: $0)?.folderId }
        }
        #expect(folders.allSatisfy { $0 == destinationId }, "setup: the move must be admitted")
        #expect(visibleIds(vm, dismissed: dismissed).isDisjoint(with: ids),
                "\(gesture.rawValue): an admitted move must stay hidden")
    }
}
