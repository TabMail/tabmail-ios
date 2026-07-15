/* This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at https://mozilla.org/MPL/2.0/. */

import Foundation
import GRDB
import Testing
@testable import TabMail

/// `recoverHeaderIfMissing` (2026-07-07): tapping "Open Email" on a chat email
/// pill pushes `MessageDetailView` with a plain composite header id of an
/// older, NON-staged message. `seedAtInit()` is zero-I/O (staged snapshot
/// only) and misses, so `message == nil` on construction (skeleton). If the
/// subsequent `loadBody()`'s initial header read then gets cancelled by
/// nav/collapse churn, it defers to `startBodyPoll()` (`CANCELLED (initial
/// read) → poll`) WITHOUT ever running the header-resolve ladder —
/// `loadBodyCalled` latches true so it never retries. Before this fix,
/// nothing ever set `message`, and the skeleton (gated on the HEADER) pulsed
/// forever even once the body landed. `startBodyPoll` is the designated
/// un-cancelled recovery task; it now resolves the header the same way the
/// cancelled `loadBody` would have (PK → cross-folder → rfc822 → staged
/// fallback via `resolveMessageAsync`).
///
/// Ids use a distinctive `hdrrec-` prefix: suites run concurrently and other
/// suites post real notifications — matching is id-scoped so cross-suite
/// activity can't interfere (and vice versa).
@Suite("MessageDetail header recovery via poll", .processGlobalState)
struct MessageDetailHeaderRecoveryTests {

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
            for id in ["acc1", "acc2"] {
                var acc = Account(emailAddress: "\(id)@example.com", displayName: id, provider: .imap)
                acc.id = id
                try acc.insert(db)
            }
        }
        return (pool, dir, previous)
    }

    private func stagedRow(accountId: String = "acc1", messageId: String, subject: String) -> StagedInboxRow {
        StagedInboxRow(
            accountId: accountId, folderPath: "INBOX", messageId: messageId,
            rfc822MessageId: "<\(accountId)-\(messageId)@x>", threadId: nil, inReplyTo: nil, references: [],
            subject: subject, senderName: "Sender", senderAddress: "s@example.com",
            to: "me@example.com", snippet: "snip", date: Date(),
            isRead: false, isFlagged: false, hasAttachments: false, isReplied: false,
            isForwarded: false, actionTag: nil, summaryBlurb: nil
        )
    }

    @MainActor
    private func insertDurableHeader(_ header: MessageHeader, into pool: DatabasePool) throws {
        try pool.writeWithoutTransaction { db in try header.insert(db) }
    }

    @MainActor
    private func waitUntil(_ deadline: TimeInterval = 2, _ cond: () -> Bool) async {
        let end = Date().addingTimeInterval(deadline)
        while !cond() && Date() < end {
            try? await Task.sleep(for: .milliseconds(25))
        }
    }

    @MainActor
    private func cleanup(_ dir: URL, _ previous: AppDatabase?) {
        AppDatabase.shared.withLock { $0 = previous }
        NSEDataBridge.latestStagedRows.withLock { $0 = [] }
        NSEDataBridge.latestStagedBodies.withLock { $0 = [:] }
        try? FileManager.default.removeItem(at: dir)
    }

    // MARK: - Tests

    @MainActor
    @Test("chat-pill repro: durable header+body, not staged — poll recovers BOTH")
    func chatPillReproRecoversHeaderAndBody() async throws {
        let (pool, dir, previous) = try makePool()
        defer { cleanup(dir, previous) }
        NSEDataBridge.latestStagedRows.withLock { $0 = [] }

        let row = stagedRow(messageId: "hdrrec-100", subject: "Older durable email")
        let header = row.toMessageHeader()
        try insertDurableHeader(header, into: pool)
        try await pool.write { db in
            try MessageBody(headerId: header.id, htmlContent: "<p>durable body</p>").insert(db)
        }

        // Staged snapshot is empty → zero-I/O init misses → skeleton state,
        // exactly the chat-pill repro (composite id of an older, non-staged
        // message).
        let vm = MessageDetailViewModel(messageId: header.id, dbPool: pool, fetchBodyOverride: { _ in })
        #expect(vm.message == nil, "zero-I/O init with empty staged snapshot must miss")

        vm.startBodyPoll()

        await waitUntil { vm.message != nil && vm.messageBody != nil }
        #expect(vm.message?.subject == "Older durable email")
        #expect(vm.messageBody?.htmlContent == "<p>durable body</p>")
        #expect(vm.isLoading == false)
    }

    @MainActor
    @Test("header-only durable (no body): poll recovers header, stays alive for body")
    func headerOnlyRecoversHeaderStaysAliveForBody() async throws {
        let (pool, dir, previous) = try makePool()
        defer { cleanup(dir, previous) }
        NSEDataBridge.latestStagedRows.withLock { $0 = [] }

        let row = stagedRow(messageId: "hdrrec-200", subject: "Header only durable email")
        let header = row.toMessageHeader()
        try insertDurableHeader(header, into: pool)
        // Deliberately NO MessageBody insert.

        let vm = MessageDetailViewModel(messageId: header.id, dbPool: pool, fetchBodyOverride: { _ in })
        #expect(vm.message == nil)

        vm.startBodyPoll()

        await waitUntil { vm.message != nil }
        #expect(vm.message?.subject == "Header only durable email")
        // Body never landed (fetch override is a no-op) — poll stays alive,
        // no crash/no-op assertions beyond this.
        #expect(vm.messageBody == nil)
    }

    @MainActor
    @Test("no-clobber: an already-set header is never overwritten by recovery")
    func recoveryDoesNotClobberExistingHeader() async throws {
        let (pool, dir, previous) = try makePool()
        defer { cleanup(dir, previous) }
        NSEDataBridge.latestStagedRows.withLock { $0 = [] }

        let row = stagedRow(messageId: "hdrrec-300", subject: "DURABLE subject (should not be adopted)")
        let header = row.toMessageHeader()
        try insertDurableHeader(header, into: pool)

        let vm = MessageDetailViewModel(messageId: header.id, dbPool: pool, fetchBodyOverride: { _ in })
        var seeded = header
        seeded.subject = "Seeded subject"
        vm._testSeedMessage(seeded)

        vm.startBodyPoll()

        // Bounded settle: recovery must observe `message != nil` and no-op.
        try? await Task.sleep(for: .milliseconds(300))
        #expect(vm.message?.subject == "Seeded subject", "message != nil → recovery must no-op")
    }

    @MainActor
    @Test("pending-tap guard: recovery must not run while a notification-tap resolve is pending")
    func recoveryDoesNotRunDuringPendingTapResolve() async throws {
        let (pool, dir, previous) = try makePool()
        defer { cleanup(dir, previous) }
        NSEDataBridge.latestStagedRows.withLock { $0 = [] }

        let tapId = MessageDetailViewModel.notificationTapIdPrefix + "acc1::hdrrec-404"
        let vm = MessageDetailViewModel(messageId: tapId, dbPool: pool, fetchBodyOverride: { _ in })
        #expect(vm.message == nil)
        #expect(vm.messageId == tapId, "pending sentinel stays unresolved — no durable/staged row exists")

        // No durable rows inserted at all.
        vm.startBodyPoll()

        try? await Task.sleep(for: .milliseconds(300))
        #expect(vm.message == nil, "recovery must not run while a tap resolve is pending")
        #expect(vm.messageId == tapId, "messageId must stay the unresolved sentinel")
    }
}
