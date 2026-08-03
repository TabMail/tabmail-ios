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
///
/// T4.V2: a tap that carries NO accountId (legacy tray payload, bare watchdog
/// fallback, scheduled/overdue proactive reminder) FAILS CLOSED at every tier —
/// nav routing, the init seed, the staged-publish seed, and both ladder tiers.
/// Even a single unambiguous match is refused, because the row a tap opens is
/// the row `markReadOnOpenIfNeeded` durably marks read; the tap pops to the
/// inbox instead. T4.V4: the init seed matches the EXACT composite header id
/// only — the folder-blind `(accountId, messageId)` fuzzy arm cannot feed a
/// durable mutation.
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

    private func stagedRow(
        accountId: String,
        folderPath: String = "INBOX",
        messageId: String,
        subject: String
    ) -> StagedInboxRow {
        StagedInboxRow(
            accountId: accountId, folderPath: folderPath, messageId: messageId,
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
            TestDatabaseTeardown.retire(pool: pool, directory: dir)
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
        let (pool, dir, previous) = try makeTwoAccountPool()
        defer {
            AppDatabase.shared.withLock { $0 = previous }
            NSEDataBridge.latestStagedRows.withLock { $0 = [] }
            TestDatabaseTeardown.retire(pool: pool, directory: dir)
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
    @Test("nil accountId resolve fails closed (no global messageId-only match)")
    func nilAccountResolveFailsClosed() async throws {
        let (pool, dir, previous) = try makeTwoAccountPool()
        defer {
            AppDatabase.shared.withLock { $0 = previous }
            NSEDataBridge.latestStagedRows.withLock { $0 = [] }
            TestDatabaseTeardown.retire(pool: pool, directory: dir)
        }
        let r1 = stagedRow(accountId: "acc1", messageId: "777", subject: "Solo")
        NSEDataBridge.latestStagedRows.withLock { $0 = [r1] }

        // A nil accountId (legacy tray / bare watchdog fallback / scheduled or
        // overdue proactive reminder) must NOT resolve globally — even a single
        // unambiguous match is refused so the tap pops to inbox instead of
        // risking a cross-account open + durable mark-read.
        let resolved = await MessageDetailViewModel.resolveProviderTap("777", accountId: nil)
        #expect(resolved == nil, "nil accountId → fail closed (pop to inbox)")
    }

    @MainActor
    @Test("nil accountId never picks a cross-account UID collision")
    func nilAccountNoCrossAccountMatch() async throws {
        let (pool, dir, previous) = try makeTwoAccountPool()
        defer {
            AppDatabase.shared.withLock { $0 = previous }
            NSEDataBridge.latestStagedRows.withLock { $0 = [] }
            TestDatabaseTeardown.retire(pool: pool, directory: dir)
        }
        let r1 = stagedRow(accountId: "acc1", messageId: "100", subject: "A1")
        let r2 = stagedRow(accountId: "acc2", messageId: "100", subject: "A2")
        NSEDataBridge.latestStagedRows.withLock { $0 = [r1, r2] }

        let resolved = await MessageDetailViewModel.resolveProviderTap("100", accountId: nil)
        #expect(resolved == nil, "nil accountId + UID collision → fail closed, never either account")
    }

    @MainActor
    @Test("nil accountId durable resolve fails closed even when exactly one account holds the UID")
    func nilAccountDurableResolveFailsClosed() async throws {
        let (pool, dir, previous) = try makeTwoAccountPool()
        defer {
            AppDatabase.shared.withLock { $0 = previous }
            NSEDataBridge.latestStagedRows.withLock { $0 = [] }
            TestDatabaseTeardown.retire(pool: pool, directory: dir)
        }
        NSEDataBridge.latestStagedRows.withLock { $0 = [] }
        let r1 = stagedRow(accountId: "acc1", messageId: "555", subject: "Durable solo")
        try insertDurableInboxHeader(r1, into: pool)

        // The durable tier is the one that can feed a durable mark-read, so it
        // must fail closed on a nil account exactly like the staged tier.
        let resolved = await MessageDetailViewModel.resolveProviderTap(
            "555", accountId: nil, waitSeconds: 0, pollMs: 1
        )
        #expect(resolved == nil, "nil accountId → no durable global match either")
    }

    // MARK: - notificationOpenId (the nav-layer routing decision)

    @MainActor
    @Test("notificationOpenId returns the staged composite only for the tap's own account")
    func openIdStagedFastPathIsAccountScoped() {
        let r1 = stagedRow(accountId: "acc1", messageId: "100", subject: "A1")
        let r2 = stagedRow(accountId: "acc2", messageId: "100", subject: "A2")

        let open1 = MessageDetailViewModel.notificationOpenId(
            messageId: "100", accountId: "acc1", stagedRows: [r1, r2]
        )
        let open2 = MessageDetailViewModel.notificationOpenId(
            messageId: "100", accountId: "acc2", stagedRows: [r1, r2]
        )
        #expect(open1 == r1.headerId)
        #expect(open2 == r2.headerId)
    }

    @MainActor
    @Test("notificationOpenId with a nil accountId never returns a staged composite — it returns the sentinel so the (equally fail-closed) ladder decides")
    func openIdNilAccountNeverOpensStagedRowDirectly() {
        let r1 = stagedRow(accountId: "acc1", messageId: "100", subject: "A1")
        let r2 = stagedRow(accountId: "acc2", messageId: "100", subject: "A2")

        let open = MessageDetailViewModel.notificationOpenId(
            messageId: "100", accountId: nil, stagedRows: [r1, r2]
        )
        #expect(open != r1.headerId, "a nil-account tap must never open acc1's row directly")
        #expect(open != r2.headerId, "a nil-account tap must never open acc2's row directly")
        #expect(open == MessageDetailViewModel.notificationTapIdPrefix + "100")
        let (decodedAccount, decodedProvider) = MessageDetailViewModel.decodeTapSentinel(
            String(open.dropFirst(MessageDetailViewModel.notificationTapIdPrefix.count))
        )
        #expect(decodedAccount == nil, "the legacy sentinel carries no account, so the ladder fails closed")
        #expect(decodedProvider == "100")
    }

    @MainActor
    @Test("notificationOpenId with an account whose staged row is absent returns the account-scoped sentinel, never another account's composite")
    func openIdWrongAccountFallsThroughToSentinel() {
        let r1 = stagedRow(accountId: "acc1", messageId: "100", subject: "A1 only")

        let open = MessageDetailViewModel.notificationOpenId(
            messageId: "100", accountId: "acc2", stagedRows: [r1]
        )
        #expect(open == MessageDetailViewModel.notificationTapIdPrefix + "acc2::100")
        #expect(open != r1.headerId)
    }

    // MARK: - Sentinel-carried accountId through VM init

    @MainActor
    @Test("sentinel with accountId seeds the matching staged account")
    func sentinelSeedsMatchingAccount() throws {
        let (pool, dir, previous) = try makeTwoAccountPool()
        defer {
            AppDatabase.shared.withLock { $0 = previous }
            NSEDataBridge.latestStagedRows.withLock { $0 = [] }
            TestDatabaseTeardown.retire(pool: pool, directory: dir)
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
            TestDatabaseTeardown.retire(pool: pool, directory: dir)
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

    @MainActor
    @Test("a legacy account-less sentinel seeds nothing — the seed is what markReadOnOpen can durably mark read, so it must never come from a global messageId-only match")
    func legacySentinelNeverSeedsAnyAccount() throws {
        let (pool, dir, previous) = try makeTwoAccountPool()
        defer {
            AppDatabase.shared.withLock { $0 = previous }
            NSEDataBridge.latestStagedRows.withLock { $0 = [] }
            TestDatabaseTeardown.retire(pool: pool, directory: dir)
        }
        // A single unambiguous staged row: the pre-fix seed matched it on
        // messageId alone, adopted it as `self.message`, and rewrote `messageId`
        // to its composite — a durable mark-read against a row the tap never
        // proved it owned.
        let r1 = stagedRow(accountId: "acc1", messageId: "100", subject: "A1 only")
        NSEDataBridge.latestStagedRows.withLock { $0 = [r1] }

        let sentinel = MessageDetailViewModel.notificationTapIdPrefix + "100"
        let vm = MessageDetailViewModel(
            messageId: sentinel,
            dbPool: pool, fetchBodyOverride: { _ in }
        )
        #expect(vm.message == nil, "an account-less sentinel must not seed any account's staged row")
        #expect(vm.messageId == sentinel, "the id must stay the unresolved sentinel, not be rewritten to a composite")
    }

    // MARK: - seedAtInit exact-headerId (T4.V4)

    @MainActor
    @Test("seedAtInit seeds the EXACT composite header — opening acc:Archive:5 while a same-UID acc:INBOX:5 push is staged seeds the Archive row, never the folder-blind INBOX sibling (the seed is what markReadOnOpen can durably mark read)")
    func seedAtInitExactHeaderIdNeverFolderBlindSibling() throws {
        let (pool, dir, previous) = try makeTwoAccountPool()
        defer {
            AppDatabase.shared.withLock { $0 = previous }
            NSEDataBridge.latestStagedRows.withLock { $0 = [] }
            TestDatabaseTeardown.retire(pool: pool, directory: dir)
        }
        // Two staged rows share account + per-folder UID "5" in DIFFERENT folders
        // (an IMAP UID collision — needs no UIDVALIDITY reset). INBOX is placed
        // FIRST so a folder-blind (accountId, messageId) fuzzy match would return
        // it instead of the requested Archive row.
        let inbox = stagedRow(accountId: "acc1", folderPath: "INBOX", messageId: "5", subject: "INBOX five")
        let archive = stagedRow(accountId: "acc1", folderPath: "Archive", messageId: "5", subject: "Archive five")
        NSEDataBridge.latestStagedRows.withLock { $0 = [inbox, archive] }

        let vm = MessageDetailViewModel(
            messageId: "acc1:Archive:5",
            dbPool: pool, fetchBodyOverride: { _ in }
        )

        // The seed feeds a DURABLE mark-read; it must be the exact-folder row.
        #expect(vm.message != nil, "the exact Archive staged row must seed self.message")
        #expect(vm.message?.id == "acc1:Archive:5", "the seed must be the exact-folder Archive row")
        #expect(vm.message?.folderPath == "Archive")
        #expect(vm.message?.id != "acc1:INBOX:5", "must never seed the folder-blind same-UID INBOX sibling")
    }

    @MainActor
    @Test("seedAtInit seeds nothing when only a same-UID sibling in another folder is staged — a folder-blind fuzzy hit must not become the mutation seed")
    func seedAtInitNoFuzzySeedForForeignFolderSibling() throws {
        let (pool, dir, previous) = try makeTwoAccountPool()
        defer {
            AppDatabase.shared.withLock { $0 = previous }
            NSEDataBridge.latestStagedRows.withLock { $0 = [] }
            TestDatabaseTeardown.retire(pool: pool, directory: dir)
        }
        // ONLY the INBOX sibling is staged; the open is for the Archive row.
        let inbox = stagedRow(accountId: "acc1", folderPath: "INBOX", messageId: "5", subject: "INBOX five")
        NSEDataBridge.latestStagedRows.withLock { $0 = [inbox] }

        let vm = MessageDetailViewModel(
            messageId: "acc1:Archive:5",
            dbPool: pool, fetchBodyOverride: { _ in }
        )

        #expect(vm.message == nil, "no exact staged row → no seed; loadBody's durable resolve owns it")
        #expect(vm.messageId == "acc1:Archive:5", "the requested identity is never rewritten by a fuzzy hit")
    }
}
