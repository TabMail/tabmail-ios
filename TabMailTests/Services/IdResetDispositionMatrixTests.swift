/* This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at https://mozilla.org/MPL/2.0/. */

import Foundation
import GRDB
import Testing
@testable import TabMail

/// T0.9 — compact provider-ID replacement for v2final's quarantine matrix.
///
/// PORT: the five-phase shape, faithful renumber-with-flags fixture, decoy
/// wire oracle, IntentionLedger settlement, fixture lifetime,
/// `.processGlobalState`, and check-first drain barrier come from
/// `v2final:TabMailTests/Services/UIDValidityQuarantinePhaseMatrixTests.swift`
/// and histories `564fe4ce0`, `00f02bfa5`, `10836346f`, `31a2f2582`, and
/// `f214c704a`. Checkpoint behavior is the A4/live-Selection port in
/// `v2final:TabMail/Services/Account/AccountManagerQueue.swift` and
/// `v2final:TabMail/Providers/IMAPProvider.swift` (`4d34ee864`, `e70f674f3`,
/// `dad1b52f6`).
///
/// SUBTRACT: quarantine/reaction, journal/F9/reporting/demotion/recovery,
/// resync, RFC actions, labels, drafts, outbox, Undo, compatibility, and
/// rediscovery. The provider-ID forward-port intentionally drops ordinary
/// actions at an epoch boundary and lets sync reconcile.
///
/// ⚑ NO REFERENCE — INVENTED: this compact no-quarantine six-action phase
/// mapping. A subsystem/call-site/history census found no provider-ID matrix
/// in v2final; its matrix exclusively drives the removed reaction architecture.
@Suite("T0.9 — id-reset disposition matrix", .serialized, .processGlobalState)
@MainActor
struct IdResetDispositionMatrixTests {
    enum Gesture: String, CaseIterable, Sendable {
        case read, unread, flag, unflag, archive, delete
    }

    enum Phase: String, CaseIterable, Sendable {
        case recognizedBeforeAdmission
        case afterAdmissionBeforeClaim
        case databaseE1LiveSelectE2
        case wrapperToInnerReset
        case matchingPositiveControl

        var isReset: Bool { self != .matchingPositiveControl }
    }

    struct Cell: Sendable, CustomStringConvertible {
        let gesture: Gesture
        let phase: Phase
        var description: String { "\(gesture.rawValue)-\(phase.rawValue)" }

        static let all: [Cell] = Phase.allCases.flatMap { phase in
            Gesture.allCases.map { Cell(gesture: $0, phase: phase) }
        }
    }

    private enum Config {
        static let oldEpoch = 41
        static let newEpoch = 42
        static let targetUid = 71
        static let renumberedUid = 7_071
        static let drainAttempts = 300
        static let drainIntervalMs = 10
    }

    private struct Fixture {
        let pool: DatabasePool
        let directory: URL
        let previous: AppDatabase?
        let accountId: String
        let inbox: Folder
        let archive: Folder
        let trash: Folder
    }

    private struct ResetState {
        let target: FakeIMAPServer.Message
        let decoy: FakeIMAPServer.Message
        let targetFlags: Set<String>
        let decoyFlags: Set<String>
    }

    private func makeFixture(accountId: String) throws -> Fixture {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        var configuration = Configuration()
        configuration.foreignKeysEnabled = true
        let pool = try DatabasePool(
            path: directory.appendingPathComponent("test.sqlite").path,
            configuration: configuration
        )
        let appDatabase = try AppDatabase(dbPool: pool)
        let previous = AppDatabase.shared.withLock { current -> AppDatabase? in
            let old = current
            current = appDatabase
            return old
        }
        var account = Account(
            emailAddress: "\(accountId)@example.com", displayName: "Matrix", provider: .imap)
        account.id = accountId
        var inbox = Folder(name: "INBOX", path: "INBOX", role: .inbox, accountId: accountId)
        inbox.lastKnownUidValidity = Config.oldEpoch
        var archive = Folder(name: "Archive", path: "Archive", role: .archive, accountId: accountId)
        archive.lastKnownUidValidity = Config.oldEpoch
        var trash = Folder(name: "Trash", path: "Trash", role: .trash, accountId: accountId)
        trash.lastKnownUidValidity = Config.oldEpoch
        try pool.writeWithoutTransaction { db in
            try account.insert(db)
            try inbox.insert(db)
            try archive.insert(db)
            try trash.insert(db)
        }
        return Fixture(
            pool: pool, directory: directory, previous: previous,
            accountId: accountId, inbox: inbox, archive: archive, trash: trash)
    }

    private func restore(_ fixture: Fixture) {
        let overlay = AccountManager.shared.snapshotOverlay()
        AccountManager.shared.removeOverlayEntries(ids: Array(overlay.keys))
        NSEDataBridge.latestStagedRows.withLock { $0 = [] }
        NSEDataBridge.latestStagedBodies.withLock { $0 = [:] }
        InstalledTestDatabaseLifetime.finish(
            previous: fixture.previous, pool: fixture.pool, directory: fixture.directory)
    }

    private func rfc822(messageId: String, subject: String) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = "EEE, dd MMM yyyy HH:mm:ss Z"
        return [
            "From: Sender <sender@example.com>",
            "To: Receiver <receiver@example.com>",
            "Subject: \(subject)",
            "Date: \(formatter.string(from: Date()))",
            "Message-ID: <\(messageId)>",
            "Content-Type: text/plain; charset=utf-8",
            "", "Matrix body.", "",
        ].joined(separator: "\r\n")
    }

    private func makeHeader(
        fixture: Fixture, gesture: Gesture, rfc: String
    ) -> MessageHeader {
        var header = MessageHeader(
            messageId: String(Config.targetUid), subject: gesture.rawValue,
            from: "Sender", fromAddress: "sender@example.com",
            to: "receiver@example.com", date: Date(), snippet: "body",
            folderId: fixture.inbox.id, accountId: fixture.accountId,
            folderPath: fixture.inbox.path, isInInbox: true)
        header.headerComplete = true
        header.rfc822MessageId = rfc
        header.observedUidValidity = Config.oldEpoch
        header.isRead = gesture == .unread
        header.isFlagged = gesture == .unflag
        return header
    }

    private func initialFlags(for gesture: Gesture) -> Set<String> {
        var flags: Set<String> = []
        if gesture == .unread { flags.insert("\\Seen") }
        if gesture == .unflag { flags.insert("\\Flagged") }
        return flags
    }

    private func resetState(targetRfc: String, gesture: Gesture, decoyRfc: String) -> ResetState {
        let target = FakeIMAPServer.makeMessage(
            uid: Config.renumberedUid,
            rfc822Text: rfc822(messageId: targetRfc, subject: gesture.rawValue))
        let decoy = FakeIMAPServer.makeMessage(
            uid: Config.targetUid,
            rfc822Text: rfc822(messageId: decoyRfc, subject: "Decoy"))
        return ResetState(
            target: target, decoy: decoy,
            targetFlags: initialFlags(for: gesture),
            decoyFlags: ["\\Seen", "\\Flagged", "$Decoy"])
    }

    private func applyReset(_ reset: ResetState, to server: FakeIMAPServer) {
        server.setUidValidity(Config.newEpoch, for: "INBOX")
        server.setMessages([reset.target, reset.decoy], in: "INBOX")
        server.setFlags(reset.targetFlags, in: "INBOX", uid: Config.renumberedUid)
        server.setFlags(reset.decoyFlags, in: "INBOX", uid: Config.targetUid)
    }

    private func armWrapperReset(_ reset: ResetState, on server: FakeIMAPServer) {
        server.resetMailboxAfterNextSuccessfulResponse(
            containing: "SELECT", mailbox: "INBOX",
            uidValidity: Config.newEpoch,
            messages: [reset.target, reset.decoy],
            flagsByUID: [
                Config.renumberedUid: reset.targetFlags,
                Config.targetUid: reset.decoyFlags,
            ])
    }

    private func setDatabaseEpoch(_ epoch: Int, fixture: Fixture) throws {
        try fixture.pool.writeWithoutTransaction { db in
            _ = try Folder.filter(key: fixture.inbox.id)
                .updateAll(db, Column("lastKnownUidValidity").set(to: epoch))
        }
    }

    private func provider(_ server: FakeIMAPServer) -> IMAPProvider {
        IMAPProvider(
            host: "127.0.0.1", port: server.port,
            username: server.username, password: server.password,
            smtpHost: "127.0.0.1", smtpPort: 587, useTLS: false)
    }

    private func perform(_ gesture: Gesture, header: MessageHeader) async {
        switch gesture {
        case .read:
            await AccountManager.shared.markRead([header])
        case .unread:
            await AccountManager.shared.markUnread([header])
        case .flag:
            await AccountManager.shared.markFlagged([header], flagged: true)
        case .unflag:
            await AccountManager.shared.markFlagged([header], flagged: false)
        case .archive:
            await AccountManager.shared.archive([header])
        case .delete:
            await AccountManager.shared.delete([header])
        }
    }

    /// Verbatim reference ordering: inspect empty+quiescent first; request a
    /// drain only when idle and nonempty. Never move the drain above the check.
    private func drainProviderQueue(pool: DatabasePool) async throws {
        for _ in 0..<Config.drainAttempts {
            let isEmpty = try await pool.read { db in try PendingOperation.fetchCount(db) == 0 }
            let isQuiescent = await AccountManager.shared.pendingQueueIsQuiescentForTesting()
            if isEmpty && isQuiescent { return }
            if isQuiescent && !isEmpty { await AccountManager.shared.drainPendingQueue() }
            try await Task.sleep(for: .milliseconds(Config.drainIntervalMs))
        }
    }

    private func providerMutationCommands(_ server: FakeIMAPServer) -> [String] {
        server.recordedCommands().filter { command in
            let upper = command.uppercased()
            return upper.contains("UID STORE") || upper.contains("UID MOVE")
                || upper.contains("UID COPY") || upper.contains("UID EXPUNGE")
                || upper.hasPrefix("STORE ") || upper == "EXPUNGE"
                || upper.hasPrefix("EXPUNGE ")
        }
    }

    private nonisolated static func targetReached(
        gesture: Gesture, server: FakeIMAPServer, targetRfc: String
    ) -> Bool {
        switch gesture {
        case .read:
            return server.flags(in: "INBOX", rfc822MessageId: targetRfc)?.contains("\\Seen") == true
        case .unread:
            return server.flags(in: "INBOX", rfc822MessageId: targetRfc)
                .map { !$0.contains("\\Seen") } == true
        case .flag:
            return server.flags(in: "INBOX", rfc822MessageId: targetRfc)?.contains("\\Flagged") == true
        case .unflag:
            return server.flags(in: "INBOX", rfc822MessageId: targetRfc)
                .map { !$0.contains("\\Flagged") } == true
        case .archive:
            return server.messageIDs(in: "Archive").contains { Self.normalize($0) == targetRfc }
        case .delete:
            return server.messageIDs(in: "Trash").contains { Self.normalize($0) == targetRfc }
        }
    }

    private nonisolated static func normalize(_ rfc: String) -> String {
        rfc.trimmingCharacters(in: CharacterSet(charactersIn: "<>"))
    }

    @Test(
        "Id-reset disposition matrix drops six ordinary actions at every reset checkpoint without provider mutation",
        arguments: Cell.all)
    func phaseMatrix(cell: Cell) async throws {
        let accountId = "id-reset-\(cell.description)-\(UUID().uuidString)"
        let targetRfc = "target-\(UUID().uuidString)@example.com"
        let decoyRfc = "decoy-\(UUID().uuidString)@example.com"
        let targetMessage = FakeIMAPServer.makeMessage(
            uid: Config.targetUid,
            rfc822Text: rfc822(messageId: targetRfc, subject: cell.gesture.rawValue))
        let server = FakeIMAPServer(mailboxes: [
            "INBOX": [targetMessage], "Archive": [], "Trash": [],
        ])
        server.setUidValidity(Config.oldEpoch, for: "INBOX")
        server.setUidValidity(Config.oldEpoch, for: "Archive")
        server.setUidValidity(Config.oldEpoch, for: "Trash")
        server.setFlags(initialFlags(for: cell.gesture), in: "INBOX", uid: Config.targetUid)
        server.expectMutation(rfc822MessageId: targetRfc)
        try server.start()
        defer { server.stop() }

        let fixture = try makeFixture(accountId: accountId)
        defer { restore(fixture) }
        let header = makeHeader(fixture: fixture, gesture: cell.gesture, rfc: targetRfc)
        try await fixture.pool.writeWithoutTransaction { db in try header.insert(db) }

        let imap = provider(server)
        try await imap.connect()
        let reset = resetState(targetRfc: targetRfc, gesture: cell.gesture, decoyRfc: decoyRfc)

        switch cell.phase {
        case .recognizedBeforeAdmission:
            applyReset(reset, to: server)
            try setDatabaseEpoch(Config.newEpoch, fixture: fixture)
            await AccountManager.shared.registerProviderForTesting(accountId: accountId, provider: imap)
            await perform(cell.gesture, header: header)

        case .afterAdmissionBeforeClaim:
            await perform(cell.gesture, header: header)
            let admitted = try await fixture.pool.read { db in try PendingOperation.fetchCount(db) }
            #expect(admitted == 1, "setup: exactly one parent op must be admitted before checkpoint A")
            applyReset(reset, to: server)
            try setDatabaseEpoch(Config.newEpoch, fixture: fixture)
            await AccountManager.shared.registerProviderForTesting(accountId: accountId, provider: imap)

        case .databaseE1LiveSelectE2:
            await perform(cell.gesture, header: header)
            let admitted = try await fixture.pool.read { db in try PendingOperation.fetchCount(db) }
            #expect(admitted == 1, "setup: exactly one E1 parent op must reach checkpoint B")
            applyReset(reset, to: server)
            await AccountManager.shared.registerProviderForTesting(accountId: accountId, provider: imap)

        case .wrapperToInnerReset:
            armWrapperReset(reset, on: server)
            await AccountManager.shared.registerProviderForTesting(accountId: accountId, provider: imap)
            await perform(cell.gesture, header: header)

        case .matchingPositiveControl:
            await AccountManager.shared.registerProviderForTesting(accountId: accountId, provider: imap)
            await perform(cell.gesture, header: header)
        }

        try await drainProviderQueue(pool: fixture.pool)

        let ledger = IntentionLedger()
        let witness: IntentionLedger.IdResetDropWitness? = cell.phase.isReset
            ? .init(epochAtGesture: Config.oldEpoch, epochAtSettle: { _ in
                server.uidValidity(for: "INBOX")
            })
            : nil
        ledger.record(
            label: cell.description,
            durableIdentity: String(Config.targetUid),
            idResetDrop: witness,
            endStateAchieved: { _ in
                Self.targetReached(gesture: cell.gesture, server: server, targetRfc: targetRfc)
            })
        let outcomes = await ledger.settle(pool: fixture.pool, reportedIds: [])
        #expect(outcomes.count == 1)
        if let outcome = outcomes.first?.outcome {
            if cell.phase.isReset {
                #expect(outcome == .acceptedIdResetDrop)
            } else {
                #expect(outcome == .executed)
            }
        }

        let remaining = try await fixture.pool.read { db in try PendingOperation.fetchAll(db) }
        #expect(remaining.isEmpty, "the parent must terminate and no split child may remain")
        #expect(server.wrongMessageViolations().isEmpty)
        if cell.phase.isReset {
            #expect(providerMutationCommands(server).isEmpty)
            if cell.phase == .recognizedBeforeAdmission
                || cell.phase == .afterAdmissionBeforeClaim {
                #expect(
                    !server.recordedCommands().contains {
                        $0.uppercased().contains("SELECT")
                    },
                    "producer refusal and checkpoint A must terminate before provider selection")
            }
            #expect(server.messageIDs(in: "INBOX").contains { Self.normalize($0) == decoyRfc })
            #expect(server.flags(in: "INBOX", uid: Config.targetUid) == reset.decoyFlags)
        } else {
            #expect(!providerMutationCommands(server).isEmpty, "positive control must perform a provider mutation")
            #expect(Self.targetReached(gesture: cell.gesture, server: server, targetRfc: targetRfc))
            #expect(!server.recordedCommands().contains { $0.uppercased().contains("SEARCH") })
        }

        await AccountManager.shared.unregisterProviderForTesting(accountId: accountId)
        try? await imap.disconnect()
    }
}
