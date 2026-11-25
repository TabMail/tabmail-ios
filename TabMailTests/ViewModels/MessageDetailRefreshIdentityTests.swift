/* This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at https://mozilla.org/MPL/2.0/. */

import Foundation
import GRDB
import Testing
@testable import TabMail

/// The Message-ID of the row stored under the opened email's id.
enum StoredMessageId: Sendable {
    /// The opened email's own Message-ID.
    case same
    /// No Message-ID.
    case missing
}

/// One case of the opened email's witness: whether the opened email has a
/// Message-ID, the Message-ID and epoch of the row now stored under its id, the
/// epoch the opened email was read under, and whether the refresh may show the
/// stored row.
struct WitnessRefreshCase: Sendable, CustomTestStringConvertible {
    let heldHasMessageId: Bool
    let storedMessageId: StoredMessageId
    let heldEpoch: Int?
    let storedEpoch: Int?
    let refreshLands: Bool
    var testDescription: String {
        "held Message-ID \(heldHasMessageId ? "yes" : "none"), stored Message-ID \(storedMessageId), "
            + "held epoch \(heldEpoch.map(String.init) ?? "none"), stored epoch \(storedEpoch.map(String.init) ?? "none")"
    }
}

/// Without a Message-ID, a different proven epoch is a reset and keeps the shown
/// email; without that proof the witness gives no verdict and the refresh lands,
/// as before (IOS-IDENTITY-001: refusal is never broadened to rows it cannot tell
/// apart). With a Message-ID, the Message-ID alone decides: the same one lands
/// whatever the epochs say, and one that went missing keeps the shown email, in
/// the witness's documented direction.
let witnessRefreshCases: [WitnessRefreshCase] = [
    WitnessRefreshCase(heldHasMessageId: false, storedMessageId: .missing, heldEpoch: 7, storedEpoch: 8, refreshLands: false),
    WitnessRefreshCase(heldHasMessageId: false, storedMessageId: .missing, heldEpoch: 7, storedEpoch: 7, refreshLands: true),
    WitnessRefreshCase(heldHasMessageId: false, storedMessageId: .missing, heldEpoch: 7, storedEpoch: nil, refreshLands: true),
    WitnessRefreshCase(heldHasMessageId: false, storedMessageId: .missing, heldEpoch: nil, storedEpoch: 8, refreshLands: true),
    WitnessRefreshCase(heldHasMessageId: true, storedMessageId: .same, heldEpoch: 7, storedEpoch: 8, refreshLands: true),
    WitnessRefreshCase(heldHasMessageId: true, storedMessageId: .missing, heldEpoch: nil, storedEpoch: nil, refreshLands: false),
]

/// A per-row refresh never swaps a different email into a row the message screen
/// holds (tabmail-ios #1138).
///
/// After a mailbox reset (a UIDVALIDITY change) a different email can be stored
/// under an id the screen still holds. Each test stores such an email under a
/// shown id and posts that id's `.messageDataDidChange`, as an AI result would.
/// It then posts a visible change for a control row and waits for it: display
/// turns run first in, first out, so the shown row's refresh has ended by then.
/// A recorder sees every publication, so even a brief swap fails the test.
///
/// `.serialized`, `.processGlobalState`: the view models observe process-wide
/// notifications and install the shared database.
@Suite("MessageDetail refresh keeps the shown email (#1138)", .serialized, .processGlobalState)
struct MessageDetailRefreshIdentityTests {

    /// Sentinel `object` for test posts of `.nseMergeDidCommit`, so count
    /// contracts in other suites can exclude them (production posts `nil`).
    static let testPostSentinel = "MessageDetailRefreshIdentityTests"

    /// Every value a screen field took, in order, from the view model's
    /// publication seam.
    @MainActor
    final class Recorder<Value: Equatable> {
        private(set) var values: [Value]
        private let vm: MessageDetailViewModel
        private let field: MessageDetailViewModel.DisplayField
        private let startCount: Int
        private var recorded = 0

        init(
            _ vm: MessageDetailViewModel, _ field: MessageDetailViewModel.DisplayField,
            _ read: @escaping @MainActor () -> Value
        ) {
            self.vm = vm
            self.field = field
            values = [read()]
            startCount = vm.publicationCountForTesting[field] ?? 0
            let previous = vm._publicationHook
            vm._publicationHook = { [weak self] published in
                previous?(published)
                guard let self, published == self.field else { return }
                self.recorded += 1
                self.values.append(read())
            }
        }

        /// True when every publication of the field since init was recorded.
        var isComplete: Bool { recorded == (vm.publicationCountForTesting[field] ?? 0) - startCount }
    }

    private func makePool() throws -> (pool: DatabasePool, dir: URL, previous: AppDatabase?) {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        var config = Configuration()
        config.foreignKeysEnabled = true
        let pool = try DatabasePool(path: dir.appendingPathComponent("test.sqlite").path, configuration: config)
        let appDb = try AppDatabase(dbPool: pool)
        let previous = AppDatabase.shared.withLock { current -> AppDatabase? in
            let prev = current; current = appDb; return prev
        }
        try pool.writeWithoutTransaction { db in
            var acc = Account(emailAddress: "test@example.com", displayName: "Test", provider: .gmail)
            acc.id = "acc1"
            try acc.insert(db)
            try Folder(name: "INBOX", path: "INBOX", role: .inbox, accountId: "acc1").insert(db)
        }
        return (pool, dir, previous)
    }

    private func cleanUp(_ pool: DatabasePool, _ dir: URL, _ previous: AppDatabase?) {
        InstalledTestDatabaseLifetime.finish(previous: previous, pool: pool, directory: dir)
    }

    private func insert(_ header: MessageHeader, into pool: DatabasePool) throws {
        try pool.writeWithoutTransaction { db in try header.insert(db) }
    }

    /// A unique header per test: the shared `AccountManager` overlay is keyed by id.
    private func header(_ name: String, summary: String, references: [String] = []) -> MessageHeader {
        let messageId = "\(name)-\(UUID().uuidString)"
        return StagedInboxRow(
            accountId: "acc1", folderPath: "INBOX", messageId: messageId,
            rfc822MessageId: "<\(messageId)@example.com>", threadId: nil, inReplyTo: nil,
            references: references, subject: "Subject \(name)", senderName: "Sender",
            senderAddress: "sender@example.com", to: "me@example.com", snippet: "snip",
            date: Date(), isRead: false, isFlagged: false, hasAttachments: false,
            isReplied: false, isForwarded: false, actionTag: nil, summaryBlurb: summary
        ).toMessageHeader()
    }

    /// The reset: a different email is stored under `id`, then a row change for
    /// `id` is posted, as a later AI result for that id would post it.
    private func storeOtherEmail(
        under id: String, rfc822MessageId: String?, epoch: Int?, in pool: DatabasePool
    ) async throws {
        try await pool.write { db in
            try db.execute(
                sql: """
                    UPDATE messageHeader
                    SET rfc822MessageId = ?, subject = 'Subject other', summaryBlurb = 'other summary',
                        observedUidValidity = ?
                    WHERE id = ?
                    """,
                arguments: [rfc822MessageId, epoch, id])
        }
        NotificationCenter.default.post(name: .messageDataDidChange, object: id)
    }

    /// A visible change to the control row, posted after the shown row's change.
    private func save(summary: String, for id: String, in pool: DatabasePool) async throws {
        try await pool.write { db in
            try db.execute(
                sql: "UPDATE messageHeader SET summaryBlurb = ? WHERE id = ?",
                arguments: [summary, id])
        }
        NotificationCenter.default.post(name: .messageDataDidChange, object: id)
    }

    @MainActor
    private func waitUntil(seconds: Double = 3, _ condition: () -> Bool) async throws {
        let deadline = Date().addingTimeInterval(seconds)
        while !condition() && Date() < deadline {
            try await Task.sleep(for: .milliseconds(20))
        }
    }

    /// Opens `opened` with its thread loaded: `control` is the thread row whose
    /// change marks the end of the refreshes posted before it.
    @MainActor
    private func openWithThread(
        _ opened: MessageHeader, control: MessageHeader, pool: DatabasePool
    ) async throws -> MessageDetailViewModel {
        let vm = MessageDetailViewModel(
            messageId: opened.id, dbPool: pool, fetchBodyOverride: { _ in },
            observeNotifications: true)
        vm._testSeedMessage(opened)
        NotificationCenter.default.post(name: .nseMergeDidCommit, object: Self.testPostSentinel)
        try await waitUntil { vm.threadMessages.contains { $0.id == control.id } }
        try await waitUntil { vm.displayTurnIsIdleForTesting }
        return vm
    }

    /// Posts the control row's change and waits until it is shown and no display
    /// turn runs or waits: every refresh posted before it has ended.
    @MainActor
    private func passControl(
        _ control: MessageHeader, in vm: MessageDetailViewModel, pool: DatabasePool
    ) async throws {
        try await save(summary: "control changed", for: control.id, in: pool)
        try await waitUntil {
            vm.threadMessages.first { $0.id == control.id }?.summaryBlurb == "control changed"
                && vm.displayTurnIsIdleForTesting
        }
        let controlSummary = vm.threadMessages.first { $0.id == control.id }?.summaryBlurb
        #expect(controlSummary == "control changed")
        #expect(vm.displayTurnIsIdleForTesting)
    }

    // MARK: - Thread rows

    @MainActor
    @Test("a thread row is never replaced by a different email stored under its id, and the next thread load decides")
    func threadRowKeepsItsEmailAcrossAReset() async throws {
        let (pool, dir, previous) = try makePool()
        defer { cleanUp(pool, dir, previous) }
        let earlier = header("earlier", summary: "earlier summary")
        let control = header("control", summary: "control summary")
        let opened = header(
            "opened", summary: "opened",
            references: [earlier.rfc822MessageId!, control.rfc822MessageId!])
        try insert(earlier, into: pool)
        try insert(control, into: pool)
        try insert(opened, into: pool)
        let vm = try await openWithThread(opened, control: control, pool: pool)
        #expect(Set(vm.threadMessages.map(\.id)) == [earlier.id, control.id])

        let otherId = "<other-\(UUID().uuidString)@example.com>"
        let shown = Recorder(vm, .threadMessages) { vm.threadMessages.compactMap(\.rfc822MessageId) }
        try await storeOtherEmail(under: earlier.id, rfc822MessageId: otherId, epoch: nil, in: pool)
        try await passControl(control, in: vm, pool: pool)

        let held = vm.threadMessages.first { $0.id == earlier.id }
        #expect(held?.rfc822MessageId == earlier.rfc822MessageId)
        #expect(held?.subject == "Subject earlier")
        #expect(held?.summaryBlurb == "earlier summary")
        let otherShownBeforeLoad = shown.values.contains { $0.contains(otherId) }
        #expect(shown.isComplete)
        #expect(!otherShownBeforeLoad, "shown: \(shown.values)")

        // The next thread load decides: the email that left is no longer shown, and
        // the other email, which is not in this thread, never is.
        NotificationCenter.default.post(name: .nseMergeDidCommit, object: Self.testPostSentinel)
        try await waitUntil { !vm.threadMessages.contains { $0.id == earlier.id } }
        try await waitUntil { vm.displayTurnIsIdleForTesting }
        let otherShownAfterLoad = shown.values.contains { $0.contains(otherId) }
        #expect(vm.threadMessages.map(\.id) == [control.id])
        #expect(shown.isComplete)
        #expect(!otherShownAfterLoad, "shown: \(shown.values)")
    }

    // MARK: - The opened email

    @MainActor
    @Test("the opened email is never replaced by a different email stored under its id")
    func openedEmailKeepsItsEmailAcrossAReset() async throws {
        let (pool, dir, previous) = try makePool()
        defer { cleanUp(pool, dir, previous) }
        let control = header("control", summary: "control summary")
        let opened = header("opened", summary: "opened summary", references: [control.rfc822MessageId!])
        try insert(control, into: pool)
        try insert(opened, into: pool)
        let vm = try await openWithThread(opened, control: control, pool: pool)

        let otherId = "<other-\(UUID().uuidString)@example.com>"
        let shown = Recorder(vm, .message) { vm.message?.rfc822MessageId }
        try await storeOtherEmail(under: opened.id, rfc822MessageId: otherId, epoch: nil, in: pool)
        try await passControl(control, in: vm, pool: pool)

        #expect(vm.message?.id == opened.id)
        #expect(vm.message?.rfc822MessageId == opened.rfc822MessageId)
        #expect(vm.message?.subject == "Subject opened")
        #expect(vm.message?.summaryBlurb == "opened summary")
        #expect(shown.isComplete)
        let shownIds = shown.values.map { $0 ?? "nil" }
        #expect(!shownIds.contains(otherId), "shown: \(shownIds)")
    }

    @MainActor
    @Test("the opened email's witness: a different Message-ID or, without one, a proven different epoch keeps it", arguments: witnessRefreshCases)
    func openedEmailWitnessDecidesTheRefresh(_ testCase: WitnessRefreshCase) async throws {
        let (pool, dir, previous) = try makePool()
        defer { cleanUp(pool, dir, previous) }
        let control = header("control", summary: "control summary")
        var opened = header("opened", summary: "opened summary", references: [control.rfc822MessageId!])
        if !testCase.heldHasMessageId { opened.rfc822MessageId = nil }
        opened.observedUidValidity = testCase.heldEpoch
        try insert(control, into: pool)
        try insert(opened, into: pool)
        let vm = try await openWithThread(opened, control: control, pool: pool)

        let storedMessageId: String? = switch testCase.storedMessageId {
        case .same: opened.rfc822MessageId
        case .missing: nil
        }
        let shown = Recorder(vm, .message) { vm.message?.subject }
        try await storeOtherEmail(under: opened.id, rfc822MessageId: storedMessageId, epoch: testCase.storedEpoch, in: pool)
        try await passControl(control, in: vm, pool: pool)

        #expect(vm.message?.id == opened.id)
        #expect(shown.isComplete)
        if testCase.refreshLands {
            #expect(vm.message?.subject == "Subject other")
            #expect(vm.message?.rfc822MessageId == storedMessageId)
            #expect(vm.message?.observedUidValidity == testCase.storedEpoch)
        } else {
            let shownSubjects = shown.values.map { $0 ?? "nil" }
            #expect(vm.message?.subject == "Subject opened")
            #expect(vm.message?.rfc822MessageId == opened.rfc822MessageId)
            #expect(vm.message?.observedUidValidity == testCase.heldEpoch)
            #expect(!shownSubjects.contains("Subject other"), "shown: \(shownSubjects)")
        }
    }
}
