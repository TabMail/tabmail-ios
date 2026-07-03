/* This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at https://mozilla.org/MPL/2.0/. */

import Foundation
import GRDB
import Testing
@testable import TabMail

/// ADR-IOS-049 (notification tap): when a message is staged (NSE) but not yet
/// durable in GRDB, `MessageDetailViewModel` synthesizes its header from
/// `NSEDataBridge.latestStagedRows` so the detail view renders immediately
/// instead of showing "not found" until the merge write lands.
@Suite("MessageDetail staged-row fallback (ADR-IOS-049)")
struct MessageDetailStagedFallbackTests {

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
        // messageHeader.accountId has an FK → account (v2 migration); durable-row
        // inserts in these tests need the parent row.
        try pool.writeWithoutTransaction { db in
            var acc = Account(emailAddress: "test@example.com", displayName: "Test", provider: .gmail)
            acc.id = "acc1"
            try acc.insert(db)
        }
        return (pool, dir, previous)
    }

    @MainActor
    private func insertDurableHeader(_ header: MessageHeader, into pool: DatabasePool) throws {
        try pool.writeWithoutTransaction { db in try header.insert(db) }
    }

    private func stagedRow(messageId: String) -> StagedInboxRow {
        StagedInboxRow(
            accountId: "acc1", folderPath: "INBOX", messageId: messageId,
            rfc822MessageId: "<\(messageId)@x>", threadId: nil, inReplyTo: nil, references: [],
            subject: "Staged \(messageId)", senderName: "Sender", senderAddress: "s@example.com",
            to: "me@example.com", snippet: "snip", date: Date(),
            isRead: false, isFlagged: false, hasAttachments: false, isReplied: false,
            isForwarded: false, actionTag: nil, summaryBlurb: nil
        )
    }

    @MainActor
    @Test("staging-only id resolves via synthesized header (no 'not found')")
    func synthesizesFromStagedSnapshot() throws {
        let (pool, dir, previous) = try makePool()
        defer {
            AppDatabase.shared.withLock { $0 = previous }
            NSEDataBridge.latestStagedRows.withLock { $0 = [] }
            try? FileManager.default.removeItem(at: dir)
        }
        let row = stagedRow(messageId: "m-tap")
        NSEDataBridge.latestStagedRows.withLock { $0 = [row] }

        // Not in GRDB — only staged.
        let vm = MessageDetailViewModel(messageId: row.headerId, dbPool: pool, fetchBodyOverride: { _ in })
        #expect(vm.message != nil)
        #expect(vm.message?.subject == "Staged m-tap")
        #expect(vm.message?.id == row.headerId)
    }

    @MainActor
    @Test("init prefers the staged snapshot when both exist (zero-I/O main-actor resolve)")
    func initPrefersStagedSnapshot() throws {
        // Deliberate ordering flip (2026-07-03, boot_logs 6): init's resolve is a
        // SYNC main-actor read — for a staged id it used to pay a DB read (PK
        // miss + fallback queries faulting cold pages behind the in-flight
        // phase-1 fsync; measured ~4.3s MAIN THREAD STALL) before consulting the
        // in-memory snapshot. Init now checks the snapshot FIRST; durable-only
        // freshness (main-app AI fields, synced flags) is healed by the async
        // refresh paths, which remain GRDB-first.
        let (pool, dir, previous) = try makePool()
        defer {
            AppDatabase.shared.withLock { $0 = previous }
            NSEDataBridge.latestStagedRows.withLock { $0 = [] }
            try? FileManager.default.removeItem(at: dir)
        }
        let row = stagedRow(messageId: "m-dual")
        NSEDataBridge.latestStagedRows.withLock { $0 = [row] }

        var durable = row.toMessageHeader()
        durable.subject = "Durable m-dual"
        try pool.writeWithoutTransaction { db in try durable.insert(db) }

        let vm = MessageDetailViewModel(messageId: row.headerId, dbPool: pool, fetchBodyOverride: { _ in })
        #expect(vm.message?.subject == "Staged m-dual")

        // Once the staged snapshot is drained (next merge replaces it), the same
        // init resolves the durable row via the DB path.
        NSEDataBridge.latestStagedRows.withLock { $0 = [] }
        let vm2 = MessageDetailViewModel(messageId: row.headerId, dbPool: pool, fetchBodyOverride: { _ in })
        #expect(vm2.message?.subject == "Durable m-dual")
    }

    @MainActor
    @Test("genuinely unknown id still resolves to nil")
    func unknownStillNil() throws {
        let (pool, dir, previous) = try makePool()
        defer {
            AppDatabase.shared.withLock { $0 = previous }
            NSEDataBridge.latestStagedRows.withLock { $0 = [] }
            try? FileManager.default.removeItem(at: dir)
        }
        NSEDataBridge.latestStagedRows.withLock { $0 = [stagedRow(messageId: "m-other")] }
        let vm = MessageDetailViewModel(messageId: "acc1:INBOX:m-nope", dbPool: pool, fetchBodyOverride: { _ in })
        #expect(vm.message == nil)
    }

    // MARK: - Staged BODY fast-path (notification-tap open lag)

    @MainActor
    @Test("stagedBodyFallback synthesizes a display MessageBody; unknown id is nil")
    func stagedBodyFallbackSynthesizes() {
        defer { NSEDataBridge.latestStagedBodies.withLock { $0 = [:] } }
        NSEDataBridge.latestStagedBodies.withLock {
            $0 = ["acc1:INBOX:m-tap": NSEDataBridge.StagedBodySnapshot(
                htmlContent: "<p>staged body</p>", attachmentsJSON: nil, icsText: nil
            )]
        }
        let body = NSEDataBridge.stagedBodyFallback(headerId: "acc1:INBOX:m-tap")
        #expect(body?.htmlContent == "<p>staged body</p>")
        #expect(body?.id == "acc1:INBOX:m-tap")
        #expect(NSEDataBridge.stagedBodyFallback(headerId: "acc1:INBOX:m-nope") == nil)
    }

    @MainActor
    @Test("loadBody renders the staged body immediately — no server fetch, no poll wait")
    func loadBodyUsesStagedBody() async throws {
        let (pool, dir, previous) = try makePool()
        defer {
            AppDatabase.shared.withLock { $0 = previous }
            NSEDataBridge.latestStagedRows.withLock { $0 = [] }
            NSEDataBridge.latestStagedBodies.withLock { $0 = [:] }
            try? FileManager.default.removeItem(at: dir)
        }
        // Header durable (the common few-seconds-after-push case: phase 1
        // landed, phase 2's body write hasn't), body ONLY in the staged snapshot.
        let row = stagedRow(messageId: "m-body")
        // Sync helper — an inline call in this async test body would select
        // GRDB's ASYNC writeWithoutTransaction overload (needs await).
        try insertDurableHeader(row.toMessageHeader(), into: pool)
        NSEDataBridge.latestStagedBodies.withLock {
            $0 = [row.headerId: NSEDataBridge.StagedBodySnapshot(
                htmlContent: "<p>from staging</p>", attachmentsJSON: nil, icsText: nil
            )]
        }

        var serverFetchCalled = false
        let vm = MessageDetailViewModel(messageId: row.headerId, dbPool: pool, fetchBodyOverride: { _ in
            serverFetchCalled = true
        })
        await vm.loadBody()

        #expect(vm.messageBody?.htmlContent == "<p>from staging</p>")
        #expect(vm.isLoading == false)
        // The whole point: the on-device staged bytes render without a network
        // round-trip or the 2s body-poll cadence.
        #expect(!serverFetchCalled)
    }
}
