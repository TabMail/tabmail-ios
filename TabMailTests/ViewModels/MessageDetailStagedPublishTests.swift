/* This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at https://mozilla.org/MPL/2.0/. */

import Foundation
import GRDB
import Testing
@testable import TabMail

/// The `.messagesStaged` SEED observer (2026-07-07): a notification tap races
/// the tap-kicked merge's in-memory snapshot publish — `seedAtInit` and the
/// resolve ladder read `latestStagedRows` BEFORE the merge replaces it (~100ms
/// later), so every in-memory tier misses and the skeleton pulses until an
/// unrelated later event sets the header (boot_logs 7: seconds). The fix reacts
/// to the publish instead of racing it: when `.messagesStaged` fires and the
/// open is still header-less, seed the header (+ read-flip + staged body) from
/// the just-published snapshot.
///
/// Ids use a distinctive `tapseed-` prefix: suites run concurrently and other
/// suites post `.messagesStaged` from real merges — matching is id-scoped so
/// cross-suite posts can't seed these VMs (and vice versa).
@Suite("MessageDetail staged-publish seed", .processGlobalState)
struct MessageDetailStagedPublishTests {

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

    /// Publish rows the way the merge does: replace the snapshot FIRST, then
    /// post `.messagesStaged` on main (observers read the snapshot, not the
    /// notification payload).
    @MainActor
    private func publish(_ rows: [StagedInboxRow], bodies: [String: NSEDataBridge.StagedBodySnapshot] = [:]) {
        NSEDataBridge.latestStagedRows.withLock { $0 = rows }
        NSEDataBridge.latestStagedBodies.withLock { $0 = bodies }
        NotificationCenter.default.post(name: .messagesStaged, object: rows)
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

    // MARK: - Seeding

    @MainActor
    @Test("pending sentinel tap: publish seeds header, rewrites messageId, flips read")
    func pendingSentinelSeedsOnPublish() async throws {
        let (pool, dir, previous) = try makePool()
        defer { cleanup(dir, previous) }
        NSEDataBridge.latestStagedRows.withLock { $0 = [] }

        // Tap lands BEFORE any merge published the snapshot → pending sentinel.
        let vm = MessageDetailViewModel(
            messageId: MessageDetailViewModel.notificationTapIdPrefix + "acc1::tapseed-100",
            dbPool: pool, fetchBodyOverride: { _ in },
            observeNotifications: true
        )
        #expect(vm.message == nil, "snapshot empty at init → skeleton state")

        // The tap-kicked merge publishes ~100ms later.
        let row = stagedRow(messageId: "tapseed-100", subject: "Seeded on publish")
        publish([row])

        await waitUntil { vm.message != nil }
        #expect(vm.message?.subject == "Seeded on publish")
        #expect(vm.messageId == row.headerId, "messageId rewritten to the composite")
        #expect(vm.message?.isRead == true, "open marks read — re-armed mark-read fast path")
    }

    @MainActor
    @Test("resolved composite but header-less (cancelled loadBody): publish seeds via stagedRowFallback")
    func resolvedCompositeSeedsOnPublish() async throws {
        let (pool, dir, previous) = try makePool()
        defer { cleanup(dir, previous) }
        NSEDataBridge.latestStagedRows.withLock { $0 = [] }

        // The resolve landed (composite id) but loadBody's durable header read
        // was cancelled / missed — VM constructed directly with the composite.
        let row = stagedRow(messageId: "tapseed-200", subject: "Late header")
        let vm = MessageDetailViewModel(
            messageId: row.headerId,
            dbPool: pool, fetchBodyOverride: { _ in },
            observeNotifications: true
        )
        #expect(vm.message == nil)

        publish([row])
        await waitUntil { vm.message != nil }
        #expect(vm.message?.subject == "Late header")
    }

    @MainActor
    @Test("publish never clobbers an already-set header (durable-first)")
    func publishDoesNotClobber() async throws {
        let (pool, dir, previous) = try makePool()
        defer { cleanup(dir, previous) }

        let row = stagedRow(messageId: "tapseed-300", subject: "STALE staged")
        var durable = row.toMessageHeader()
        durable.subject = "Durable truth"
        let vm = MessageDetailViewModel(
            messageId: row.headerId,
            dbPool: pool, fetchBodyOverride: { _ in },
            observeNotifications: true
        )
        vm._testSeedMessage(durable)

        publish([row])
        // Bounded settle: the observer must run and no-op.
        try? await Task.sleep(for: .milliseconds(200))
        #expect(vm.message?.subject == "Durable truth", "message != nil → seed must no-op")
    }

    @MainActor
    @Test("account-scoped: a same-UID row from ANOTHER account never seeds; the right one does")
    func publishIsAccountScoped() async throws {
        let (pool, dir, previous) = try makePool()
        defer { cleanup(dir, previous) }
        NSEDataBridge.latestStagedRows.withLock { $0 = [] }

        let vm = MessageDetailViewModel(
            messageId: MessageDetailViewModel.notificationTapIdPrefix + "acc2::tapseed-400",
            dbPool: pool, fetchBodyOverride: { _ in },
            observeNotifications: true
        )

        // Wrong account only → must NOT seed.
        publish([stagedRow(accountId: "acc1", messageId: "tapseed-400", subject: "A1")])
        try? await Task.sleep(for: .milliseconds(200))
        #expect(vm.message == nil, "acc1 row must not satisfy an acc2 tap")

        // Right account arrives → seeds.
        let a2 = stagedRow(accountId: "acc2", messageId: "tapseed-400", subject: "A2")
        publish([
            stagedRow(accountId: "acc1", messageId: "tapseed-400", subject: "A1"),
            a2
        ])
        await waitUntil { vm.message != nil }
        #expect(vm.message?.subject == "A2")
        #expect(vm.messageId == a2.headerId)
    }

    @MainActor
    @Test("composite branch is EXACT-match: same-UID staged INBOX push never seeds an Archive open")
    func compositeSeedRequiresExactHeaderId() async throws {
        let (pool, dir, previous) = try makePool()
        defer { cleanup(dir, previous) }
        NSEDataBridge.latestStagedRows.withLock { $0 = [] }

        // Normal (non-tap) open of an IMAP Archive message, still in its skeleton
        // window. IMAP UIDs are per-folder, so a just-pushed INBOX message can
        // carry the SAME UID — publishing it must NOT seed this open (the fuzzy
        // accountId+messageId match would rewrite messageId to the wrong
        // composite AND mark the wrong message read — review round, 2026-07-07).
        let archiveComposite = MessageIdentity.headerId(
            accountId: "acc1", folderPath: "Archive", messageId: "tapseed-600"
        )
        let vm = MessageDetailViewModel(
            messageId: archiveComposite,
            dbPool: pool, fetchBodyOverride: { _ in },
            observeNotifications: true
        )
        #expect(vm.message == nil)

        let inboxPush = stagedRow(messageId: "tapseed-600", subject: "WRONG inbox push")
        publish([inboxPush])
        try? await Task.sleep(for: .milliseconds(200))
        #expect(vm.message == nil, "same-UID INBOX row must not seed an Archive composite")
        #expect(vm.messageId == archiveComposite, "identity must never be rewritten to the wrong composite")
    }

    @MainActor
    @Test("body catch-up: staged body published alongside the header is adopted for display")
    func publishAdoptsStagedBody() async throws {
        let (pool, dir, previous) = try makePool()
        defer { cleanup(dir, previous) }
        NSEDataBridge.latestStagedRows.withLock { $0 = [] }

        let row = stagedRow(messageId: "tapseed-500", subject: "With body")
        let vm = MessageDetailViewModel(
            messageId: MessageDetailViewModel.notificationTapIdPrefix + "acc1::tapseed-500",
            dbPool: pool, fetchBodyOverride: { _ in },
            observeNotifications: true
        )

        publish(
            [row],
            bodies: [row.headerId: NSEDataBridge.StagedBodySnapshot(
                htmlContent: "<p>staged body</p>", attachmentsJSON: nil, icsText: nil
            )]
        )
        await waitUntil { vm.messageBody != nil }
        #expect(vm.message?.subject == "With body")
        #expect(vm.messageBody?.htmlContent == "<p>staged body</p>")
        #expect(vm.isLoading == false)
    }
}
