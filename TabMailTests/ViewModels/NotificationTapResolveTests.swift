/* This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at https://mozilla.org/MPL/2.0/. */

import Foundation
import GRDB
import Testing
@testable import TabMail

/// Immediate-push notification taps (2026-07-04, boot_logs 7): the deep-link
/// handler no longer blocks navigation on the resolve ladder — it pushes the
/// detail view at once, with the sentinel-prefixed PROVIDER id when the staged
/// snapshot misses, and `MessageDetailViewModel` resolves it asynchronously
/// under the loading skeleton (`resolveProviderTap`).
@Suite("Notification-tap provider-id resolve (immediate push)")
struct NotificationTapResolveTests {

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
        }
        return (pool, dir, previous)
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
    private func insertDurableInboxHeader(from row: StagedInboxRow, subject: String, into pool: DatabasePool) throws -> MessageHeader {
        var durable = row.toMessageHeader()
        durable.subject = subject
        durable.isInInbox = true
        try pool.writeWithoutTransaction { db in try durable.insert(db) }
        return durable
    }

    // MARK: - Ladder tiers

    @MainActor
    @Test("staged snapshot tier resolves the provider id instantly")
    func stagedTierResolves() async throws {
        let (_, dir, previous) = try makePool()
        defer {
            AppDatabase.shared.withLock { $0 = previous }
            NSEDataBridge.latestStagedRows.withLock { $0 = [] }
            try? FileManager.default.removeItem(at: dir)
        }
        let row = stagedRow(messageId: "m-prov-staged")
        NSEDataBridge.latestStagedRows.withLock { $0 = [row] }

        let resolved = await MessageDetailViewModel.resolveProviderTap("m-prov-staged")
        #expect(resolved == row.headerId)
    }

    @MainActor
    @Test("durable tier resolves via the indexed inbox lookup")
    func durableTierResolves() async throws {
        let (pool, dir, previous) = try makePool()
        defer {
            AppDatabase.shared.withLock { $0 = previous }
            NSEDataBridge.latestStagedRows.withLock { $0 = [] }
            try? FileManager.default.removeItem(at: dir)
        }
        NSEDataBridge.latestStagedRows.withLock { $0 = [] }
        let row = stagedRow(messageId: "m-prov-durable")
        let durable = try insertDurableInboxHeader(from: row, subject: "Durable", into: pool)

        let resolved = await MessageDetailViewModel.resolveProviderTap("m-prov-durable")
        #expect(resolved == durable.id)
    }

    @MainActor
    @Test("exhausted ladder returns nil (message genuinely gone)")
    func exhaustedLadderReturnsNil() async throws {
        let (_, dir, previous) = try makePool()
        defer {
            AppDatabase.shared.withLock { $0 = previous }
            NSEDataBridge.latestStagedRows.withLock { $0 = [] }
            try? FileManager.default.removeItem(at: dir)
        }
        NSEDataBridge.latestStagedRows.withLock { $0 = [] }

        // Short wait keeps the bounded poll from slowing the suite.
        let resolved = await MessageDetailViewModel.resolveProviderTap(
            "m-prov-gone", waitSeconds: 0.1, pollMs: 20
        )
        #expect(resolved == nil)
    }

    // MARK: - VM sentinel handling

    @MainActor
    @Test("sentinel init seeds from the staged snapshot by provider id and rewrites messageId")
    func sentinelInitSeedsFromStaged() throws {
        let (pool, dir, previous) = try makePool()
        defer {
            AppDatabase.shared.withLock { $0 = previous }
            NSEDataBridge.latestStagedRows.withLock { $0 = [] }
            try? FileManager.default.removeItem(at: dir)
        }
        let row = stagedRow(messageId: "m-tap-sentinel")
        NSEDataBridge.latestStagedRows.withLock { $0 = [row] }

        let vm = MessageDetailViewModel(
            messageId: MessageDetailViewModel.notificationTapIdPrefix + "m-tap-sentinel",
            dbPool: pool,
            fetchBodyOverride: { _ in }
        )
        #expect(vm.message?.subject == "Staged m-tap-sentinel")
        #expect(vm.messageId == row.headerId, "messageId must be rewritten to the composite")
    }

    @MainActor
    @Test("sentinel init with no staged match: loadBody resolves durable and rewrites messageId")
    func sentinelLoadBodyResolvesDurable() async throws {
        let (pool, dir, previous) = try makePool()
        defer {
            AppDatabase.shared.withLock { $0 = previous }
            NSEDataBridge.latestStagedRows.withLock { $0 = [] }
            try? FileManager.default.removeItem(at: dir)
        }
        NSEDataBridge.latestStagedRows.withLock { $0 = [] }
        let row = stagedRow(messageId: "m-tap-durable")
        let durable = try insertDurableInboxHeader(from: row, subject: "Durable tap", into: pool)

        let vm = MessageDetailViewModel(
            messageId: MessageDetailViewModel.notificationTapIdPrefix + "m-tap-durable",
            dbPool: pool,
            fetchBodyOverride: { _ in }
        )
        #expect(vm.message == nil, "no staged match → pending resolve, skeleton state")

        await vm.loadBody()
        #expect(vm.message?.subject == "Durable tap")
        #expect(vm.messageId == durable.id, "messageId must be rewritten to the composite")
    }
}
