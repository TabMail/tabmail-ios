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
        static let rekeyedUid = "171"
        static let mainActorSettleYields = 8
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

    private func fetchHeader(_ fixture: Fixture, id: String) throws -> MessageHeader? {
        try fixture.pool.read { db in try MessageHeader.fetchOne(db, key: id) }
    }

    /// The archive already ran locally (the row sits in Archive under its INBOX id)
    /// and its provider MOVE is in flight.
    @discardableResult
    private func installInFlightArchive(_ fixture: Fixture, id: String) throws -> PendingOperation {
        try fixture.pool.write { db in
            _ = try MessageHeader.filter(key: id).updateAll(
                db,
                Column("folderId").set(to: fixture.archive.id),
                Column("folderPath").set(to: fixture.archive.path),
                Column("isInInbox").set(to: false),
                Column("observedUidValidity").set(to: nil as Int?))
            var forward = PendingOperation(
                type: .move, messageIds: [Config.uid], accountId: fixture.accountId,
                folderPath: fixture.inbox.path, destinationPath: fixture.archive.path,
                observedUidValidity: Config.gestureEpoch)
            forward.status = PendingStatus.inFlight.rawValue
            forward.everAttempted = true
            return try forward.inserted(db)
        }
    }

    /// An in-flight archive with a gesture back to the inbox waiting behind it as a
    /// deferred successor (the shape `move` registers while the archive's provider
    /// MOVE has not yet proven the destination address).
    @discardableResult
    private func installDeferredSuccessor(_ fixture: Fixture, id: String) async throws -> PendingOperation {
        let forward = try installInFlightArchive(fixture, id: id)
        let row = try #require(try fetchHeader(fixture, id: id))
        await AccountManager.shared.move([row], to: fixture.inbox.path)
        #expect(await AccountManager.shared.deferredMoveSuccessorCountForTesting() == 1,
                "setup: the opposite move must wait as a deferred successor")
        return forward
    }

    /// Lets the MainActor run a notification post an actor method queued as a
    /// MainActor task before returning.
    private func settleMainActorPosts() async {
        for _ in 0..<Config.mainActorSettleYields { await Task.yield() }
    }

    private func setInboxEpoch(_ fixture: Fixture, _ epoch: Int) throws {
        try fixture.pool.writeWithoutTransaction { db in
            _ = try Folder.filter(key: fixture.inbox.id)
                .updateAll(db, Column("lastKnownUidValidity").set(to: epoch))
        }
    }

    private func restore(_ fixture: Fixture) {
        MessageHeaderRekey.clearAddressHandoffsForTesting()
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

    // MARK: - Outstanding behind an in-flight move: never reported

    /// A move that waits behind an in-flight opposite move is still outstanding: its
    /// row must stay hidden, so it must never be reported refused. Covers the three
    /// ways `move` leaves such a member outstanding: registered as a deferred
    /// successor (the in-flight archive's opposite), retargeted while deferred, and
    /// cancelled by a gesture back to the predecessor's destination.
    @Test("A move waiting behind an in-flight opposite move is never reported refused")
    func deferredSuccessorIsNotReportedRefused() async throws {
        let fixture = try makeFixture()
        defer { restore(fixture) }
        await AccountManager.shared.clearDeferredMoveSuccessorsForTesting()
        clearOverlay()

        // Back to the inbox while the archive is in flight: a deferred successor.
        let id = try insertInboxHeader(fixture, uid: Config.uid)
        let tap = MoveRefusalTap(watching: [id])
        defer { tap.stop() }
        try await installDeferredSuccessor(fixture, id: id)
        let row = try #require(try fetchHeader(fixture, id: id))
        let manager = AccountManager.shared
        #expect(tap.snapshot.isEmpty, "a deferred successor is outstanding, not refused")

        // Retargeted while still deferred.
        await manager.move([row], to: fixture.projects.path)
        #expect(await manager.deferredMoveSuccessorCountForTesting() == 1,
                "setup: the retarget keeps the deferred successor")
        #expect(tap.snapshot.isEmpty, "a retargeted deferred successor is outstanding, not refused")

        // Archive again: cancels the deferred successor; the in-flight archive stands.
        await manager.move([row], to: fixture.archive.path)
        #expect(await manager.deferredMoveSuccessorCountForTesting() == 0,
                "setup: the gesture back to the predecessor's destination cancels the successor")
        #expect(tap.snapshot.isEmpty, "a gesture that the in-flight move already fulfils is not refused")
        await manager.clearDeferredMoveSuccessorsForTesting()
    }

    // MARK: - Nothing written: reported

    /// Runs one archive gesture with its queued write held, applies `between` (which
    /// may also change the view's hide sets, as a notification would) while it is
    /// held, then drains and applies the view's settlement seam.
    private func archiveWithHeldWrite(
        _ fixture: Fixture, id: String, watching: Set<String> = [],
        between: (inout Set<String>, inout Set<String>) throws -> Void
    ) async throws -> (vm: InboxViewModel, reported: Set<String>, dismissed: Set<String>, fading: Set<String>) {
        let vm = InboxViewModel(folders: [fixture.inbox])
        await vm.reloadMessages()
        let tap = MoveRefusalTap(watching: watching.union([id]))
        defer { tap.stop() }
        let gate = await gateWriteQueue()
        var dismissed: Set<String> = []
        var fading: Set<String> = []
        await performGesture(
            .archive, vm: vm, ids: [id], fixture: fixture,
            dismissed: &dismissed, fading: &fading)
        try between(&dismissed, &fading)
        gate.finish()
        await AccountManager.shared.awaitWriteQueueDrain()
        let reported = tap.snapshot
        MoveRefusalReceiver.apply(reported, dismissedMessages: &dismissed, swipeFadingMessages: &fading)
        await vm.reloadMessages()
        return (vm, reported, dismissed, fading)
    }

    @Test("A move whose row vanished before its queued write is reported, so the hide is lifted")
    func vanishedRowIsReportedRefused() async throws {
        let fixture = try makeFixture()
        defer { restore(fixture) }
        clearOverlay()
        let id = try insertInboxHeader(fixture, uid: Config.uid)

        let result = try await archiveWithHeldWrite(fixture, id: id) { _, _ in
            try fixture.pool.writeWithoutTransaction { db in
                _ = try MessageHeader.deleteOne(db, key: id)
            }
        }

        #expect(result.reported == [id], "nothing was movable: the gesture-time hide must be lifted")
        #expect(!result.dismissed.contains(id) && !result.fading.contains(id))
    }

    @Test("A move whose queued write rolled back is reported, and its row is visible again")
    func rolledBackWriteIsReportedRefused() async throws {
        let fixture = try makeFixture()
        defer { restore(fixture) }
        clearOverlay()
        let id = try insertInboxHeader(fixture, uid: Config.uid)

        // Fail only the move's own durable insert, so the whole move transaction
        // rolls back and nothing is written.
        let result = try await archiveWithHeldWrite(fixture, id: id) { _, _ in
            try fixture.pool.writeWithoutTransaction { db in
                try db.execute(sql: """
                    CREATE TEMP TRIGGER failMoveInsert BEFORE INSERT ON \(PendingOperation.databaseTableName)
                    WHEN NEW.type = '\(OperationType.move.rawValue)'
                    BEGIN SELECT RAISE(ABORT, 'test: move insert fails'); END
                    """)
            }
        }

        #expect(try fetchHeader(fixture, id: id)?.folderId == fixture.inbox.id,
                "setup: the rolled-back write must leave the row where it was")
        #expect(result.reported == [id], "the write rolled back: the gesture-time hide must be lifted")
        #expect(visibleIds(result.vm, dismissed: result.dismissed).contains(id),
                "the row the rolled-back move left in place must be visible again")
        #expect(!result.fading.contains(id))
    }

    /// The row's id changes between the gesture and its queued write by a
    /// provider-proven re-key, which the view follows with its own hide set
    /// (`HeaderRekeyReceiver`). The write no longer finds the id the gesture named;
    /// the report must still settle the hide the view now holds under the NEW id.
    @Test("A move whose row was re-keyed before its queued write lifts the hide under the new id")
    func rekeyedRowIsReportedUnderItsNewId() async throws {
        let fixture = try makeFixture()
        defer { restore(fixture) }
        MessageHeaderRekey.clearAddressHandoffsForTesting()
        clearOverlay()
        let oldId = try insertInboxHeader(fixture, uid: Config.uid)
        let newId = MessageIdentity.headerId(
            accountId: fixture.accountId, folderPath: fixture.inbox.path, messageId: Config.rekeyedUid)
        let record = HeaderRekeyRecord(
            oldHeaderId: oldId, newHeaderId: newId,
            newProviderMessageId: Config.rekeyedUid,
            newObservedUidValidity: Config.gestureEpoch)

        let result = try await archiveWithHeldWrite(
            fixture, id: oldId, watching: [newId]
        ) { dismissed, fading in
            let insertedId = try insertInboxHeader(fixture, uid: Config.rekeyedUid)
            #expect(insertedId == newId, "setup: the re-keyed row must carry the expected id")
            try fixture.pool.write { db in
                _ = try MessageHeader.deleteOne(db, key: oldId)
                MessageHeaderRekey.publishAddressHandoffsAfterCommit([record], in: db)
            }
            var selected: String?
            var pushed: String?
            HeaderRekeyReceiver.apply(
                [record], dismissedMessages: &dismissed, swipeFadingMessages: &fading,
                selectedMessageId: &selected, pushedMessageId: &pushed)
            #expect(dismissed.contains(newId), "setup: the view follows the re-key with its hide")
        }

        #expect(result.reported.contains(newId),
                "the report must name the id the view hides after the re-key")
        #expect(result.reported.contains(oldId),
                "the report must still name the id the gesture hid")
        #expect(visibleIds(result.vm, dismissed: result.dismissed).contains(newId),
                "the re-keyed row the refused move never touched must be visible again")
        #expect(!result.fading.contains(newId))
    }

    /// The same re-key, but the view has NOT yet moved its hide to the new id when
    /// the refusal arrives (the re-key notification reaches it second). The refusal
    /// must settle the hide under the old id, so the late re-key carries no hide to
    /// the new id.
    @Test("A refusal that reaches the view before its re-key leaves the re-keyed row visible")
    func refusalBeforeRekeyNotificationLeavesRowVisible() async throws {
        let fixture = try makeFixture()
        defer { restore(fixture) }
        MessageHeaderRekey.clearAddressHandoffsForTesting()
        clearOverlay()
        let oldId = try insertInboxHeader(fixture, uid: Config.uid)
        let newId = MessageIdentity.headerId(
            accountId: fixture.accountId, folderPath: fixture.inbox.path, messageId: Config.rekeyedUid)
        let record = HeaderRekeyRecord(
            oldHeaderId: oldId, newHeaderId: newId,
            newProviderMessageId: Config.rekeyedUid,
            newObservedUidValidity: Config.gestureEpoch)

        var result = try await archiveWithHeldWrite(
            fixture, id: oldId, watching: [newId]
        ) { dismissed, _ in
            let insertedId = try insertInboxHeader(fixture, uid: Config.rekeyedUid)
            #expect(insertedId == newId, "setup: the re-keyed row must carry the expected id")
            try fixture.pool.write { db in
                _ = try MessageHeader.deleteOne(db, key: oldId)
                MessageHeaderRekey.publishAddressHandoffsAfterCommit([record], in: db)
            }
            #expect(dismissed.contains(oldId) && !dismissed.contains(newId),
                    "setup: the view still hides the old id")
        }

        // The re-key notification reaches the view after the refusal.
        var selected: String?
        var pushed: String?
        HeaderRekeyReceiver.apply(
            [record], dismissedMessages: &result.dismissed, swipeFadingMessages: &result.fading,
            selectedMessageId: &selected, pushedMessageId: &pushed)

        #expect(result.reported.contains(oldId), "the report must name the id the view hides")
        #expect(visibleIds(result.vm, dismissed: result.dismissed).contains(newId),
                "the late re-key must not carry a settled hide to the new id")
        #expect(!result.fading.contains(newId))
    }

    // MARK: - A deferred successor dropped later: reported

    @Test("A deferred successor dropped with its predecessor is reported refused")
    func droppedDeferredSuccessorIsReportedRefused() async throws {
        let fixture = try makeFixture()
        defer { restore(fixture) }
        await AccountManager.shared.clearDeferredMoveSuccessorsForTesting()
        clearOverlay()
        let id = try insertInboxHeader(fixture, uid: Config.uid)
        let tap = MoveRefusalTap(watching: [id])
        defer { tap.stop() }
        let forward = try await installDeferredSuccessor(fixture, id: id)
        #expect(tap.snapshot.isEmpty, "setup: a deferred successor is outstanding")

        await AccountManager.shared.dropDeferredMoveSuccessors(for: forward.id)
        await settleMainActorPosts()

        #expect(await AccountManager.shared.deferredMoveSuccessorCountForTesting() == 0)
        #expect(tap.snapshot == [id], "the dropped successor will never move: its hide must be lifted")
    }

    @Test("A deferred successor the predecessor's finish cannot address is reported refused")
    func unmaterializableDeferredSuccessorIsReportedRefused() async throws {
        let fixture = try makeFixture()
        defer { restore(fixture) }
        await AccountManager.shared.clearDeferredMoveSuccessorsForTesting()
        clearOverlay()
        let id = try insertInboxHeader(fixture, uid: Config.uid)
        let tap = MoveRefusalTap(watching: [id])
        defer { tap.stop() }
        let forward = try await installDeferredSuccessor(fixture, id: id)
        #expect(tap.snapshot.isEmpty, "setup: a deferred successor is outstanding")

        // The forward finished without proving a destination address for the member,
        // so the successor has no row to move and is dropped.
        await AccountManager.shared.materializeDeferredMoveSuccessors(
            after: forward, result: .empty)
        await AccountManager.shared.awaitWriteQueueDrain()

        #expect(await AccountManager.shared.deferredMoveSuccessorCountForTesting() == 0)
        #expect(tap.snapshot == [id], "the unmaterializable successor will never move: its hide must be lifted")
    }
}

/// Pins that `InboxView` actually attaches both settlement receivers to the list
/// whose hide sets they settle. The behavioural suites drive the receivers' pure
/// seams directly, so without this pin deleting either attachment stays green.
@Suite("InboxView attaches its hide-settlement receivers")
struct InboxViewSettlementWiringTests {
    private func inboxViewBody() throws -> String {
        let projectRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let source = try String(
            contentsOf: projectRoot.appendingPathComponent("TabMail/Views/Inbox/InboxView.swift"),
            encoding: .utf8)
        let start = try #require(source.range(of: "struct InboxView: View {"))
        // Comment lines cannot attach a modifier; drop them so a commented-out
        // attachment does not pass.
        return source[start.lowerBound...]
            .split(separator: "\n", omittingEmptySubsequences: false)
            .filter { !$0.trimmingCharacters(in: .whitespaces).hasPrefix("//") }
            .joined(separator: "\n")
    }

    @Test("InboxView applies MoveRefusalReceiver and HeaderRekeyReceiver to its own hide sets",
          arguments: ["MoveRefusalReceiver", "HeaderRekeyReceiver"])
    func receiverIsAttached(receiver: String) throws {
        let body = try inboxViewBody()
        let attach = try #require(
            body.range(of: ".modifier(\(receiver)("),
            "InboxView must apply \(receiver)")
        let arguments = body[attach.upperBound...].prefix(400)
        #expect(arguments.contains("dismissedMessages: $dismissedMessages"))
        #expect(arguments.contains("swipeFadingMessages: $swipeFadingMessages"))
    }
}
