/* This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at https://mozilla.org/MPL/2.0/. */

import Foundation
import GRDB
import Testing
@testable import TabMail

/// `IOS-NSE-001` — the NSE observes a UIDVALIDITY with its own live SELECT and
/// stages it, and three projections then threw it away on the way into the app:
/// `StagedMessage.toInboxRow()`, `StagedInboxRow.toMessageHeader()` and
/// `NSEDataBridge.insertNewHeaderFromStaging`.
///
/// **THE INVARIANT UNDER TEST — stated as a system property, never as a field
/// copy:** *a row produced by these projections is adjudicated on the evidence
/// the NSE actually had.* Concretely: the user's gesture on a just-pushed
/// message is ADMITTED when the proven epoch still equals the folder's live
/// epoch, and REFUSED — terminally — when that epoch has since moved. A test
/// that merely asserted `observedUidValidity != nil` would pin the mechanism
/// and stay green on a system that admits the wrong message, so every case here
/// asserts the admission OUTCOME (`RoleMoveAdmission` disposition, the
/// `PendingOperation` that did or did not reach the queue, and whether the local
/// row moved) rather than the stamp.
///
/// **Why carrying the epoch cannot widen admission (the C3 direction).**
/// `AccountManager.admittedOrdinaryActionTargets` admits an IMAP row only when
/// its `observedUidValidity` EQUALS the folder's live `lastKnownUidValidity`, so
/// a carried value either matches (the address is current — correct admission)
/// or disagrees (refused). The disposal path for a positively-stale staged row
/// already exists upstream: ARM 1 (`detectOldEpochStagedRows` →
/// `applyOldEpochStagingCleanup`) DELETES it and ARM 2 keeps a quarantined row
/// for retry, so no positively-stale value ever reaches the insert.
@Suite("NSE staged-row epoch carry", .serialized, .processGlobalState)
struct NSEStagedEpochCarryTests {

    // MARK: - Harness

    private struct Fixture {
        let pool: DatabasePool
        let directory: URL
        let previous: AppDatabase?
        let accountId: String
    }

    /// Folders are `(path, role, lastKnownUidValidity)`.
    @MainActor
    private func fixture(
        accountId: String,
        folders: [(String, FolderRole, Int?)] = [
            ("INBOX", .inbox, 10), ("Archive", .archive, 10),
        ]
    ) throws -> Fixture {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        var configuration = Configuration()
        configuration.foreignKeysEnabled = true
        let pool = try DatabasePool(
            path: directory.appendingPathComponent("test.sqlite").path,
            configuration: configuration)
        let appDatabase = try AppDatabase(dbPool: pool)
        let previous = AppDatabase.shared.withLock { current -> AppDatabase? in
            let old = current
            current = appDatabase
            return old
        }
        try pool.writeWithoutTransaction { db in
            var account = Account(
                emailAddress: "staged@example.com", displayName: "Staged", provider: .imap)
            account.id = accountId
            try account.insert(db)
            for (path, role, epoch) in folders {
                var folder = Folder(name: path, path: path, role: role, accountId: accountId)
                folder.lastKnownUidValidity = epoch
                try folder.insert(db)
            }
        }
        return Fixture(pool: pool, directory: directory, previous: previous, accountId: accountId)
    }

    @MainActor
    private func finish(_ fixture: Fixture) {
        NSEDataBridge.latestStagedRows.withLock { $0 = [] }
        NSEDataBridge.latestStagedBodies.withLock { $0 = [:] }
        InstalledTestDatabaseLifetime.finish(
            previous: fixture.previous, pool: fixture.pool, directory: fixture.directory)
    }

    /// A staging row shaped exactly as `NSEIMAPConnection` leaves one: an IMAP
    /// push, addressed by mailbox-local UID, carrying the epoch its own SELECT
    /// reported (or nil when the server reported none).
    private func stagedMessage(
        _ fixture: Fixture, uid: Int, observedUidValidity: Int?
    ) -> NSEDataBridge.StagedMessage {
        NSEDataBridge.StagedMessage(
            id: "\(fixture.accountId):\(uid)",
            accountId: fixture.accountId,
            accountEmail: "staged@example.com",
            provider: "imap_new_mail",
            messageId: String(uid),
            rfc822MessageId: "pushed-\(uid)@example.com",
            threadId: nil,
            folderPath: "INBOX",
            subject: "pushed \(uid)",
            senderName: "Sender",
            senderEmail: "sender@example.com",
            snippet: "pushed body",
            date: 1_710_000_000,
            to: "staged@example.com", cc: "", bcc: "", replyTo: nil,
            inReplyTo: nil,
            references: [],
            isRead: false, isFlagged: false, hasAttachments: false,
            isReplied: false, isForwarded: false,
            providerLabels: [],
            summaryBlurb: nil, summaryTodos: nil, actionTag: nil,
            reminderDate: nil, reminderTime: nil, reminderContent: nil,
            processedAt: Date().timeIntervalSince1970,
            aiCompleted: false, notified: false,
            htmlContent: nil, textContent: nil, attachmentsJSON: nil,
            icsText: nil, hasUnresolvedCIDs: false,
            observedUidValidity: observedUidValidity
        )
    }

    /// The merge's own new-header write — the third projection — driven directly.
    @discardableResult
    private func merge(
        _ msg: NSEDataBridge.StagedMessage, into fixture: Fixture
    ) throws -> String {
        var ftsBatch: [NSEDataBridge.NSEFTSBodyItem] = []
        try fixture.pool.writeWithoutTransaction { db in
            try db.inTransaction {
                _ = try NSEDataBridge.insertNewHeaderFromStaging(
                    msg, db: db, ftsBatch: &ftsBatch, headerOnly: true)
                return .commit
            }
        }
        return MessageIdentity.headerId(
            accountId: msg.accountId, folderPath: msg.folderPath, messageId: msg.messageId)
    }

    /// Publish the in-memory read model the inbox renders and
    /// `resolveHeadersForAction` falls back to (ADR-IOS-049) — the first two
    /// projections, in sequence.
    private func publishStaged(_ msg: NSEDataBridge.StagedMessage) {
        NSEDataBridge.latestStagedRows.withLock { $0 = [msg.toInboxRow()] }
    }

    private func storedHeader(_ fixture: Fixture, id: String) throws -> MessageHeader? {
        try fixture.pool.read { try MessageHeader.fetchOne($0, key: id) }
    }

    private func setFolderEpoch(_ fixture: Fixture, path: String, to epoch: Int) throws {
        try fixture.pool.writeWithoutTransaction { db in
            try db.execute(
                sql: "UPDATE folder SET lastKnownUidValidity = ? WHERE id = ?",
                arguments: [epoch, MessageIdentity.folderId(
                    accountId: fixture.accountId, folderPath: path)])
        }
    }

    private func queuedOps(_ fixture: Fixture) throws -> [PendingOperation] {
        try fixture.pool.read { try PendingOperation.fetchAll($0) }
    }

    /// The admission predicate's answer, flattened so it can cross a `write`
    /// boundary. Mirrors `admittedOrdinaryActionTargets`' tuple exactly.
    private struct AdmittedTargets: Sendable {
        let ids: [String]
        let providerIds: [String]
        let observedUidValidity: Int?
    }

    /// Run the production admission predicate over a resolved action target.
    private func admit(
        _ target: MessageHeader, pool: DatabasePool, accountId: String, folderPath: String
    ) async throws -> AdmittedTargets? {
        try await pool.write { db -> AdmittedTargets? in
            guard let admission = try AccountManager.admittedOrdinaryActionTargets(
                [target], accountId: accountId, folderPath: folderPath, db: db) else { return nil }
            return AdmittedTargets(
                ids: admission.messages.map(\.id),
                providerIds: admission.providerIds,
                observedUidValidity: admission.observedUidValidity)
        }
    }

    // MARK: - The headline — the gesture the epoch was proven for now runs

    /// **THE PROPERTY: a gesture on a just-pushed message whose epoch the NSE
    /// positively proved reaches the queue, bound to that epoch.**
    ///
    /// It did not. The merge wrote the header with `observedUidValidity` nil, so
    /// `admittedOrdinaryActionTargets` refused the swipe on evidence the system
    /// had already obtained and discarded — a silent no-op for the user (owner
    /// decision §9 D6(a)) and an instance of the `IOS-EPOCH-001` window
    /// manufactured rather than inherited.
    ///
    /// RED PROOF (recorded): with `insertNewHeaderFromStaging`'s
    /// `header.observedUidValidity = …` line reverted to its dropping form, the
    /// gesture comes back `retainedForRetry`, `admittedIds` is empty and zero
    /// `PendingOperation` rows exist.
    @Test("A gesture on a just-pushed row whose epoch the NSE proved reaches the queue")
    @MainActor
    func provenEpochAdmitsTheNextGesture() async throws {
        let f = try fixture(accountId: "nse-proven")
        defer { finish(f) }
        let msg = stagedMessage(f, uid: 16, observedUidValidity: 10)
        let headerId = try merge(msg, into: f)

        // The merged row is what the gesture re-resolves (`move` re-resolves by
        // id through `resolveHeadersForAction`, durable row first).
        let seeded = try #require(try storedHeader(f, id: headerId))
        #expect(seeded.observedUidValidity == 10)

        let admission = await AccountManager.shared.move([seeded], to: "Archive")

        #expect(admission.admittedIds == [headerId])
        #expect(admission.failedIds.isEmpty)
        #expect(admission.pendingIds.isEmpty)

        // The op that reached the queue is bound to the SAME epoch, addressed by
        // the provider-native UID — i.e. the intention is durable and executable.
        let ops = try queuedOps(f)
        #expect(ops.count == 1)
        guard ops.count == 1 else { return }
        #expect(ops[0].type == .move)
        #expect(ops[0].messageIds == ["16"])
        #expect(ops[0].observedUidValidity == 10)
        #expect(ops[0].destinationPath == "Archive")
    }

    /// The same property one projection earlier: while the row is staged but not
    /// yet durable, the header `resolveHeadersForAction` synthesizes from
    /// `latestStagedRows` is the one every gesture feeds to the admission
    /// predicate. It must carry the proof too, or the instant-insert path
    /// (ADR-IOS-049) is a rendering with no actions behind it.
    ///
    /// RED PROOF (recorded): with `StagedInboxRow.toMessageHeader()`'s carry
    /// removed, `admittedOrdinaryActionTargets` returns nil here.
    @Test("A staged-only row resolves to an action target the admission predicate accepts")
    @MainActor
    func provenEpochAdmitsAStagedOnlyRow() async throws {
        let f = try fixture(accountId: "nse-staged-only")
        defer { finish(f) }
        let msg = stagedMessage(f, uid: 21, observedUidValidity: 10)
        publishStaged(msg)
        let headerId = MessageIdentity.headerId(
            accountId: f.accountId, folderPath: "INBOX", messageId: "21")

        // Deliberately NOT merged: this is the pre-durable window.
        #expect(try storedHeader(f, id: headerId) == nil)

        let resolved = await AccountManager.shared.resolveHeadersForAction(ids: [headerId])
        #expect(resolved.count == 1)
        guard let target = resolved.first else { return }

        let admitted = try #require(
            try await admit(target, pool: f.pool, accountId: f.accountId, folderPath: "INBOX"))
        #expect(admitted.ids == [headerId])
        #expect(admitted.providerIds == ["21"])
        #expect(admitted.observedUidValidity == 10)
    }

    // MARK: - The refusal the carry exists to enable

    /// **THE PROPERTY: a staged row whose epoch has since moved is REFUSED, and
    /// refused TERMINALLY — nothing reaches the wire and the local row does not
    /// move.** This is why carrying the value is safe rather than merely
    /// convenient: the carried epoch is what makes the disagreement PROVABLE.
    /// Without it the same gesture is refused as an unknown and retried forever
    /// against numbering it never observed.
    ///
    /// RED PROOF (recorded): with the carry reverted, the gesture comes back
    /// `retainedForRetry` instead of `terminalStale` — the refusal happens, but
    /// on an absence of evidence rather than on proof.
    @Test("A staged row whose folder epoch has since moved is refused terminally")
    @MainActor
    func movedEpochRefusesTheGestureTerminally() async throws {
        let f = try fixture(accountId: "nse-moved")
        defer { finish(f) }
        // Staged and merged under E1 …
        let msg = stagedMessage(f, uid: 31, observedUidValidity: 10)
        let headerId = try merge(msg, into: f)
        // … and the folder has since settled on E2 (turnover recorded by sync).
        try setFolderEpoch(f, path: "INBOX", to: 11)

        let seeded = try #require(try storedHeader(f, id: headerId))
        let admission = await AccountManager.shared.move([seeded], to: "Archive")

        #expect(admission.failedIds == [headerId])
        #expect(admission.admittedIds.isEmpty)
        #expect(admission.pendingIds.isEmpty)

        // Nothing was queued and nothing moved: the refusal is total, not a
        // partial mutation followed by a refused wire op.
        #expect(try queuedOps(f).isEmpty)
        let after = try #require(try storedHeader(f, id: headerId))
        #expect(after.folderPath == "INBOX")
        #expect(after.isInInbox)
    }

    /// The same refusal one projection earlier — the staged-only, pre-durable
    /// window. The admission predicate must reject the synthesized target, so a
    /// carried-but-stale epoch can never author a wire operation.
    @Test("A staged-only row whose epoch has moved is not an admissible action target")
    @MainActor
    func movedEpochRefusesAStagedOnlyRow() async throws {
        let f = try fixture(accountId: "nse-moved-staged")
        defer { finish(f) }
        let msg = stagedMessage(f, uid: 32, observedUidValidity: 10)
        publishStaged(msg)
        try setFolderEpoch(f, path: "INBOX", to: 11)
        let headerId = MessageIdentity.headerId(
            accountId: f.accountId, folderPath: "INBOX", messageId: "32")

        let resolved = await AccountManager.shared.resolveHeadersForAction(ids: [headerId])
        #expect(resolved.count == 1)
        guard let target = resolved.first else { return }

        let admitted = try await admit(
            target, pool: f.pool, accountId: f.accountId, folderPath: "INBOX")
        #expect(admitted == nil)
    }

    // MARK: - Two-sided non-vacuity — an unknown epoch is never upgraded

    /// An unstamped staged row (Gmail/Graph, or an IMAP row staged before the
    /// `nse_processed_message.observedUidValidity` column existed) behaves
    /// EXACTLY as it does today: refused, and refused as RETRYABLE. Carrying a
    /// value must not turn an absence of evidence into proof — that is exit 4
    /// widening into clause 2, the single most repeated defect in this
    /// codebase's history.
    @Test("An unstamped staged row stays retryable, never terminal")
    @MainActor
    func unstampedStagedRowStaysRetryable() async throws {
        let f = try fixture(accountId: "nse-unstamped")
        defer { finish(f) }
        let msg = stagedMessage(f, uid: 41, observedUidValidity: nil)
        let headerId = try merge(msg, into: f)

        let seeded = try #require(try storedHeader(f, id: headerId))
        #expect(seeded.observedUidValidity == nil)

        let admission = await AccountManager.shared.move([seeded], to: "Archive")
        #expect(admission.pendingIds == [headerId])
        #expect(admission.failedIds.isEmpty)
        #expect(admission.admittedIds.isEmpty)
        #expect(try queuedOps(f).isEmpty)
    }

    /// `0` is the "server did not report a value" sentinel (RFC 3501 §2.3.1.1
    /// types UIDVALIDITY as `nz-number`), NOT an epoch. Both projections
    /// normalize it through `SyncEngine.knownUidValidity`, so a nonconforming
    /// server's `0` lands as an UNKNOWN — retryable — and never as a proven
    /// epoch that a `0 == 0` comparison could vacuously admit.
    @Test("A zero-sentinel staged epoch is an unknown, not a proven epoch")
    @MainActor
    func zeroSentinelIsNotAProvenEpoch() async throws {
        let f = try fixture(accountId: "nse-zero")
        defer { finish(f) }
        let msg = stagedMessage(f, uid: 51, observedUidValidity: 0)

        // Neither projection may launder the sentinel into a trust claim.
        #expect(msg.toInboxRow().observedUidValidity == nil)
        #expect(msg.toInboxRow().toMessageHeader().observedUidValidity == nil)

        let headerId = try merge(msg, into: f)
        let seeded = try #require(try storedHeader(f, id: headerId))
        #expect(seeded.observedUidValidity == nil)

        let admission = await AccountManager.shared.move([seeded], to: "Archive")
        #expect(admission.pendingIds == [headerId])
        #expect(admission.failedIds.isEmpty)
        #expect(try queuedOps(f).isEmpty)
    }
}
