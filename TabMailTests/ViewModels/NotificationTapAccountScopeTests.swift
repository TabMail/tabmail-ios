/* This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at https://mozilla.org/MPL/2.0/. */

import Foundation
import GRDB
import Testing
@testable import TabMail

/// Notification-tap ACCOUNT DISAMBIGUATION (2026-07-07). An IMAP UID is a
/// per-mailbox small integer, so the same provider id collides across accounts —
/// without scoping the resolve by accountId, a tap on account A's push could open
/// account B's message. The push payload carries `accountId`; the deep-link
/// sentinel now encodes it (`notifTap::<accountId>::<providerId>`) and every tap
/// match predicate applies it.
@Suite("Notification-tap account disambiguation", .processGlobalState)
struct NotificationTapAccountScopeTests {

    // MARK: - Sentinel decode (pure)

    @MainActor
    @Test("decodeTapSentinel splits accountId::providerId on the first `::`")
    func decodeAccountForm() {
        let (acc, prov) = MessageDetailViewModel.decodeTapSentinel("acc1::12345")
        #expect(acc == "acc1")
        #expect(prov == "12345")
    }

    @MainActor
    @Test("decodeTapSentinel treats an account-less payload as legacy (nil account)")
    func decodeLegacyForm() {
        let (acc, prov) = MessageDetailViewModel.decodeTapSentinel("12345")
        #expect(acc == nil)
        #expect(prov == "12345")
    }

    @MainActor
    @Test("decodeTapSentinel keeps `::` inside the provider id (first `::` is the boundary)")
    func decodeProviderWithColons() {
        let (acc, prov) = MessageDetailViewModel.decodeTapSentinel("acc1::AQMk::ADk::xyz")
        #expect(acc == "acc1")
        #expect(prov == "AQMk::ADk::xyz")
    }

    // MARK: - Harness (two accounts, same UID)

    private func makeTwoAccountPool() throws -> (pool: DatabasePool, dir: URL, previous: AppDatabase?) {
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

    private func stagedRow(accountId: String, messageId: String, subject: String) -> StagedInboxRow {
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
    private func insertDurableInboxHeader(_ row: StagedInboxRow, into pool: DatabasePool) throws {
        var h = row.toMessageHeader()
        h.isInInbox = true
        try pool.writeWithoutTransaction { db in try h.insert(db) }
    }

    // MARK: - resolveProviderTap disambiguation (the regression)

    @MainActor
    @Test("durable resolve: same UID in two accounts resolves the notified account")
    func durableResolveAccountScoped() async throws {
        let (pool, dir, previous) = try makeTwoAccountPool()
        defer {
            AppDatabase.shared.withLock { $0 = previous }
            NSEDataBridge.latestStagedRows.withLock { $0 = [] }
            try? FileManager.default.removeItem(at: dir)
        }
        NSEDataBridge.latestStagedRows.withLock { $0 = [] }
        let r1 = stagedRow(accountId: "acc1", messageId: "100", subject: "A1")
        let r2 = stagedRow(accountId: "acc2", messageId: "100", subject: "A2")
        try insertDurableInboxHeader(r1, into: pool)
        try insertDurableInboxHeader(r2, into: pool)

        let resolved1 = await MessageDetailViewModel.resolveProviderTap("100", accountId: "acc1")
        let resolved2 = await MessageDetailViewModel.resolveProviderTap("100", accountId: "acc2")
        #expect(resolved1 == r1.headerId, "acc1 tap must open acc1's message")
        #expect(resolved2 == r2.headerId, "acc2 tap must open acc2's message")
        #expect(resolved1 != resolved2)
    }

    @MainActor
    @Test("staged resolve: same UID in two staged rows resolves the notified account")
    func stagedResolveAccountScoped() async throws {
        let (_, dir, previous) = try makeTwoAccountPool()
        defer {
            AppDatabase.shared.withLock { $0 = previous }
            NSEDataBridge.latestStagedRows.withLock { $0 = [] }
            try? FileManager.default.removeItem(at: dir)
        }
        let r1 = stagedRow(accountId: "acc1", messageId: "100", subject: "A1")
        let r2 = stagedRow(accountId: "acc2", messageId: "100", subject: "A2")
        NSEDataBridge.latestStagedRows.withLock { $0 = [r1, r2] }

        let resolved1 = await MessageDetailViewModel.resolveProviderTap("100", accountId: "acc1")
        let resolved2 = await MessageDetailViewModel.resolveProviderTap("100", accountId: "acc2")
        #expect(resolved1 == r1.headerId)
        #expect(resolved2 == r2.headerId)
    }

    @MainActor
    @Test("legacy (nil accountId) resolve still matches on messageId alone")
    func legacyResolveMessageIdOnly() async throws {
        let (_, dir, previous) = try makeTwoAccountPool()
        defer {
            AppDatabase.shared.withLock { $0 = previous }
            NSEDataBridge.latestStagedRows.withLock { $0 = [] }
            try? FileManager.default.removeItem(at: dir)
        }
        let r1 = stagedRow(accountId: "acc1", messageId: "777", subject: "Solo")
        NSEDataBridge.latestStagedRows.withLock { $0 = [r1] }

        let resolved = await MessageDetailViewModel.resolveProviderTap("777", accountId: nil)
        #expect(resolved == r1.headerId, "no accountId → messageId-only match (today's behavior)")
    }

    // MARK: - Sentinel-carried accountId through VM init

    @MainActor
    @Test("sentinel with accountId seeds the matching staged account")
    func sentinelSeedsMatchingAccount() throws {
        let (pool, dir, previous) = try makeTwoAccountPool()
        defer {
            AppDatabase.shared.withLock { $0 = previous }
            NSEDataBridge.latestStagedRows.withLock { $0 = [] }
            try? FileManager.default.removeItem(at: dir)
        }
        let r1 = stagedRow(accountId: "acc1", messageId: "100", subject: "A1 seed")
        let r2 = stagedRow(accountId: "acc2", messageId: "100", subject: "A2 seed")
        NSEDataBridge.latestStagedRows.withLock { $0 = [r1, r2] }

        let vm = MessageDetailViewModel(
            messageId: MessageDetailViewModel.notificationTapIdPrefix + "acc2::100",
            dbPool: pool, fetchBodyOverride: { _ in }
        )
        #expect(vm.message?.subject == "A2 seed", "acc2 sentinel must seed acc2's staged row")
        #expect(vm.messageId == r2.headerId)
    }

    @MainActor
    @Test("sentinel accountId with no matching staged account leaves the tap pending (no cross-account seed)")
    func sentinelNoCrossAccountSeed() throws {
        let (pool, dir, previous) = try makeTwoAccountPool()
        defer {
            AppDatabase.shared.withLock { $0 = previous }
            NSEDataBridge.latestStagedRows.withLock { $0 = [] }
            try? FileManager.default.removeItem(at: dir)
        }
        // Only acc1 is staged; a tap claiming acc2 must NOT seed acc1's row.
        let r1 = stagedRow(accountId: "acc1", messageId: "100", subject: "A1 only")
        NSEDataBridge.latestStagedRows.withLock { $0 = [r1] }

        let vm = MessageDetailViewModel(
            messageId: MessageDetailViewModel.notificationTapIdPrefix + "acc2::100",
            dbPool: pool, fetchBodyOverride: { _ in }
        )
        #expect(vm.message == nil, "wrong-account sentinel must not seed → pending resolve")
    }
}
