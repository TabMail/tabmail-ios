/* This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at https://mozilla.org/MPL/2.0/. */

import Testing
import Foundation
import GRDB
@testable import TabMail

/// Guards the compose-dismiss fix on the OUTBOX-CRITICAL path (CLAUDE.md: "a
/// dropped send or double-send is a product-ending bug").
///
/// Two guarantees are exercised:
///  1. **Double-send firewall** — `AccountManager.persistQueuedSend` (the single
///     source of truth `queueSend` delegates to) creates AT MOST ONE in-flight
///     outbox row per `draftId`. A rapid double-tap — or async reentrancy during
///     the now-SUSPENDING dismiss window — must NOT produce two sends. Before the
///     fix, the only thing preventing this was the synchronous writes blocking the
///     main thread (and `isSending` was dead code); suspending the main actor
///     reopens that window, so the persistence-layer firewall is mandatory.
///  2. **Main-actor responsiveness** — the send persistence runs through the async
///     `dbPool.write` overload, so a `@MainActor` caller is suspended, not frozen,
///     while the single serialized writer is busy (the 2–3 s compose-dismiss lag).
///
/// `persistQueuedSend` is drain-free by design, so these tests are deterministic:
/// no fire-and-forget `drainOutbox` Task to race teardown (it would otherwise
/// schedule a +6 s wake-up that reads `AppDatabase.dbPool` after the test restores
/// `AppDatabase.shared` — a process-killing crash; see the NSE merge test).

// MARK: - Shared test database

/// Build a real temp-file `DatabasePool` (WAL, single writer, busyMode 5s,
/// 64 readers — matching `AppDatabase.makePool`), run migrations, and register it
/// as `AppDatabase.shared` so `persistQueuedSend`'s `AppDatabase.dbPool.write`
/// hits it. Seeds the `acc1` account the insert path's FK expects. Returns the
/// previous shared instance for restoration.
@MainActor
private func makeOutboxTestDatabase() throws -> (dir: URL, pool: DatabasePool, previous: AppDatabase?) {
    let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    var config = Configuration()
    config.journalMode = .wal
    config.busyMode = .timeout(5)
    config.foreignKeysEnabled = true
    config.maximumReaderCount = 64
    let pool = try DatabasePool(path: dir.appendingPathComponent("tabmail.sqlite").path, configuration: config)
    let appDb = try AppDatabase(dbPool: pool)   // runs schema migrations
    let previous = AppDatabase.shared.withLock { current -> AppDatabase? in
        let prev = current
        current = appDb
        return prev
    }
    try pool.writeWithoutTransaction { db in
        var acc = Account(emailAddress: "user@example.com", displayName: "Test", provider: .gmail)
        acc.id = "acc1"
        try acc.insert(db)
        try Folder(name: "INBOX", path: "INBOX", role: .inbox, accountId: "acc1").insert(db)
    }
    return (dir, pool, previous)
}

private func makeDraft(subject: String = "Hello", body: String = "Body") -> DraftMessage {
    DraftMessage(to: ["recipient@example.com"], subject: subject, body: body)
}

// MARK: - Double-send firewall

@Suite("Outbox double-send firewall", .serialized, .processGlobalState)
@MainActor
struct OutboxDoubleSendTests {

    private func outboxCount(_ pool: DatabasePool) async throws -> Int {
        try await pool.read { db in try OutboxMessage.fetchCount(db) }
    }

    /// THE double-tap test: two `persistQueuedSend` calls for the SAME compose
    /// session (same `draftId`) — exactly what a rapid double-tap on Send, or the
    /// async-reentrancy window the fix opens, produces. Only ONE outbox row may
    /// exist, and the second call must report `deduped` and return the SAME id
    /// (so the undo toast points at the real queued message).
    @Test("Double-tap Send queues exactly one outbox row")
    func doubleTapQueuesExactlyOneSend() async throws {
        let (dir, pool, previous) = try makeOutboxTestDatabase()
        defer {
            AppDatabase.shared.withLock { $0 = previous }
            TestDatabaseTeardown.retire(pool: pool, directory: dir)
        }
        let draft = makeDraft()

        let first = try await AccountManager.persistQueuedSend(
            draft: draft, accountId: "acc1", replyToHeaderId: nil,
            isForward: false, serverDraftId: nil, draftId: "draft-1"
        )
        let second = try await AccountManager.persistQueuedSend(
            draft: draft, accountId: "acc1", replyToHeaderId: nil,
            isForward: false, serverDraftId: nil, draftId: "draft-1"
        )

        #expect(first.deduped == false, "first send should insert a fresh row")
        #expect(second.deduped == true, "second (double-tap) send must dedup")
        #expect(second.outboxId == first.outboxId, "dedup must return the existing row's id")
        let count = try await outboxCount(pool)
        #expect(count == 1, "double-tap must leave exactly ONE outbox row, got \(count)")
    }

    /// Concurrency variant: fire both sends at once (no ordering guarantee between
    /// the two tasks). GRDB serializes writers, so whichever transaction runs
    /// second sees the first's row inside the SAME write and dedups — still exactly
    /// one row. Proves the firewall is race-free, not merely sequential.
    @Test("Concurrent double-tap still queues exactly one outbox row")
    func concurrentDoubleTapQueuesExactlyOneSend() async throws {
        let (dir, pool, previous) = try makeOutboxTestDatabase()
        defer {
            AppDatabase.shared.withLock { $0 = previous }
            TestDatabaseTeardown.retire(pool: pool, directory: dir)
        }
        let draft = makeDraft()

        async let a = AccountManager.persistQueuedSend(
            draft: draft, accountId: "acc1", replyToHeaderId: nil,
            isForward: false, serverDraftId: nil, draftId: "draft-concurrent"
        )
        async let b = AccountManager.persistQueuedSend(
            draft: draft, accountId: "acc1", replyToHeaderId: nil,
            isForward: false, serverDraftId: nil, draftId: "draft-concurrent"
        )
        let results = try await [a, b]

        let dedupedCount = results.filter { $0.deduped }.count
        #expect(dedupedCount == 1, "exactly one of two concurrent sends must dedup, got \(dedupedCount)")
        // Both calls must agree on the surviving row id.
        #expect(results[0].outboxId == results[1].outboxId, "both concurrent sends must resolve to the same row id")
        let count = try await outboxCount(pool)
        #expect(count == 1, "concurrent double-tap must leave exactly ONE outbox row, got \(count)")
    }

    /// A `.failed` row must NOT block a fresh send of the same draft — re-sending
    /// an explicitly-failed message is legitimate user intention (Never Drop User
    /// Intention), not a duplicate. The firewall dedups ONLY against in-flight
    /// (.queued/.sending) rows.
    @Test("A .failed row does not block re-sending the same draft")
    func failedRowDoesNotBlockResend() async throws {
        let (dir, pool, previous) = try makeOutboxTestDatabase()
        defer {
            AppDatabase.shared.withLock { $0 = previous }
            TestDatabaseTeardown.retire(pool: pool, directory: dir)
        }
        // Seed a .failed row for draft "draft-failed".
        try await pool.write { db in
            var failed = OutboxMessage(accountId: "acc1", draft: makeDraft(subject: "Old attempt"))
            failed.draftId = "draft-failed"
            failed.status = OutboxStatus.failed.rawValue
            failed.retryCount = 3
            try failed.insert(db)
        }

        let result = try await AccountManager.persistQueuedSend(
            draft: makeDraft(subject: "Retry"), accountId: "acc1", replyToHeaderId: nil,
            isForward: false, serverDraftId: nil, draftId: "draft-failed"
        )

        #expect(result.deduped == false, "a .failed row must not dedup a fresh re-send")
        let queued = try await pool.read { db in
            try OutboxMessage.filter(Column("status") == OutboxStatus.queued.rawValue).fetchCount(db)
        }
        #expect(queued == 1, "the re-send must create one .queued row, got \(queued)")
        let total = try await outboxCount(pool)
        #expect(total == 2, "expected the old .failed row + the new .queued row, got \(total)")
    }

    /// Reply path: the first send sets optimistic `isReplied` on the original
    /// message and returns its id; a second (double-tap) send dedups WITHOUT
    /// inserting a second row and without re-touching the original. Guards that the
    /// firewall short-circuit doesn't lose the reply-badge side effect on the first
    /// pass nor double-apply it.
    @Test("Reply double-tap sets isReplied once and queues one row")
    func replyDoubleTapPreservesSingleRowAndFlags() async throws {
        let (dir, pool, previous) = try makeOutboxTestDatabase()
        defer {
            AppDatabase.shared.withLock { $0 = previous }
            TestDatabaseTeardown.retire(pool: pool, directory: dir)
        }
        // Seed the original inbox message being replied to.
        let originalId = "acc1:INBOX:orig-1"
        try await pool.write { db in
            let h = MessageHeader(
                messageId: "orig-1", subject: "Original", from: "Sender",
                fromAddress: "sender@example.com", to: "user@example.com",
                date: Date(), snippet: "snip", folderId: "acc1:INBOX",
                accountId: "acc1", folderPath: "INBOX", isInInbox: true)
            #expect(h.id == originalId)
            try h.insert(db)
        }

        let first = try await AccountManager.persistQueuedSend(
            draft: makeDraft(subject: "Re: Original"), accountId: "acc1",
            replyToHeaderId: originalId, isForward: false, serverDraftId: nil, draftId: "draft-reply"
        )
        #expect(first.deduped == false)
        #expect(first.resolvedOriginalId == originalId, "first reply send should resolve the original header")

        let second = try await AccountManager.persistQueuedSend(
            draft: makeDraft(subject: "Re: Original"), accountId: "acc1",
            replyToHeaderId: originalId, isForward: false, serverDraftId: nil, draftId: "draft-reply"
        )
        #expect(second.deduped == true, "second reply send (double-tap) must dedup")
        #expect(second.resolvedOriginalId == nil, "deduped send must not re-resolve / re-touch the original")

        let count = try await outboxCount(pool)
        #expect(count == 1, "reply double-tap must leave exactly ONE outbox row, got \(count)")
        let isReplied = try await pool.read { db in
            try MessageHeader.fetchOne(db, key: originalId)?.isReplied ?? false
        }
        #expect(isReplied == true, "original message should be flagged isReplied")
    }

    /// Direct unit of the firewall predicate: it matches `.queued`/`.sending` rows
    /// but not `.failed`, and is scoped to the exact `draftId`.
    @Test("inFlightOutboxId matches only in-flight rows for the exact draft")
    func inFlightPredicateScoping() async throws {
        let (dir, pool, previous) = try makeOutboxTestDatabase()
        defer {
            AppDatabase.shared.withLock { $0 = previous }
            TestDatabaseTeardown.retire(pool: pool, directory: dir)
        }
        try await pool.write { db in
            for (draftId, status) in [
                ("q", OutboxStatus.queued), ("s", .sending), ("f", .failed)
            ] {
                var m = OutboxMessage(accountId: "acc1", draft: makeDraft())
                m.draftId = "draft-\(draftId)"
                m.status = status.rawValue
                try m.insert(db)
            }
        }
        // Lift `try` out of `#expect` (the macro can't host a throwing expression).
        let (q, s, f, absent) = try await pool.read { db in
            (
                try AccountManager.inFlightOutboxId(forDraftId: "draft-q", db: db),
                try AccountManager.inFlightOutboxId(forDraftId: "draft-s", db: db),
                try AccountManager.inFlightOutboxId(forDraftId: "draft-f", db: db),
                try AccountManager.inFlightOutboxId(forDraftId: "draft-absent", db: db)
            )
        }
        #expect(q != nil)
        #expect(s != nil)
        #expect(f == nil, ".failed must not count as in-flight")
        #expect(absent == nil)
    }
}

// MARK: - Main-actor responsiveness (compose-dismiss freeze regression)

/// Mirrors `NSEMergeMainActorBlockTests`: a `@MainActor` heartbeat measures
/// whether the UI can make progress while a background writer holds GRDB's single
/// writer connection. Proves the send-persistence fix:
///   • A SYNCHRONOUS `dbPool.write` on the main actor (the OLD compose-dismiss
///     path) STARVES the heartbeat → frozen UI (the 2–3 s lag).
///   • `await persistQueuedSend` (the NEW path) suspends the main actor instead →
///     the heartbeat keeps ticking → responsive UI.
@Suite("Compose-dismiss send persistence must not block the main actor", .serialized, .processGlobalState)
@MainActor
struct OutboxSendMainActorBlockTests {

    @MainActor
    final class Heartbeat {
        private(set) var ticks = 0
        private var running = true
        private var task: Task<Void, Never>?
        func start() {
            task = Task { @MainActor in
                while running {
                    ticks += 1
                    try? await Task.sleep(for: .milliseconds(20))
                }
            }
        }
        func stop() { running = false; task?.cancel() }
    }

    /// Launch an ~18k header+body row background write that holds the single writer
    /// for >0.5 s on the simulator — the real foreground-return maintenance
    /// contention (sync / backfill / FTS) the compose-dismiss write must wait behind.
    private func startMaintenanceWriter(_ pool: DatabasePool) -> Task<Void, Never> {
        let bodyHTML = "<html><body>"
            + String(repeating: "<p>Lorem ipsum dolor sit amet, consectetur adipiscing elit.</p>", count: 60)
            + "</body></html>"
        return Task.detached {
            try? await pool.write { db in
                for i in 0..<18_000 {
                    var h = MessageHeader(
                        messageId: "arch-\(i)", subject: "Archived \(i)",
                        from: "Sender \(i)", fromAddress: "s\(i)@example.com",
                        to: "user@example.com",
                        date: Date(timeIntervalSince1970: Double(1_600_000_000 + i)),
                        snippet: "snip \(i)", folderId: "acc1:INBOX", accountId: "acc1",
                        folderPath: "INBOX", isInInbox: true)
                    h.isRead = true
                    try h.insert(db)
                    try MessageBody(headerId: h.id, htmlContent: bodyHTML).insert(db)
                }
            }
        }
    }

    /// Synchronous (non-async) @MainActor write — reproduces the OLD compose-dismiss
    /// path. In this non-async context the SYNC `dbPool.write` overload is selected,
    /// so the call blocks the main thread until the writer is free.
    @MainActor
    static func blockingSyncInsert() throws {
        try AppDatabase.dbPool.write { db in
            var m = OutboxMessage(accountId: "acc1", draft: DraftMessage(to: ["r@example.com"], subject: "Sync", body: "B"))
            m.draftId = "draft-sync-frozen"
            try m.insert(db)
        }
    }

    @Test("await persistQueuedSend keeps the main actor responsive under writer contention")
    func asyncSendKeepsMainActorResponsive() async throws {
        let (dir, pool, previous) = try makeOutboxTestDatabase()
        defer {
            AppDatabase.shared.withLock { $0 = previous }
            TestDatabaseTeardown.retire(pool: pool, directory: dir)
        }

        let hb = Heartbeat()
        hb.start()
        try await Task.sleep(for: .milliseconds(120))   // let the heartbeat settle

        let bg = startMaintenanceWriter(pool)
        try await Task.sleep(for: .milliseconds(50))     // let maintenance grab the writer first

        // THE FIX path: the send persistence, awaited DIRECTLY on the main actor
        // (as ComposeView.send now does). Time with CFAbsoluteTimeGetCurrent — a
        // nonisolated async wrapper would hop off the main actor and mask the probe.
        let ticksBefore = hb.ticks
        let t0 = CFAbsoluteTimeGetCurrent()
        _ = try await AccountManager.persistQueuedSend(
            draft: DraftMessage(to: ["r@example.com"], subject: "Hi", body: "Body"),
            accountId: "acc1", replyToHeaderId: nil, isForward: false,
            serverDraftId: nil, draftId: "draft-freeze"
        )
        let wallMs = Int((CFAbsoluteTimeGetCurrent() - t0) * 1000)
        let ticksDuring = hb.ticks - ticksBefore
        _ = await bg.value
        hb.stop()

        print("[OutboxSendFreezeTest] persist wall=\(wallMs)ms (waited behind maintenance) | "
              + "heartbeats during=\(ticksDuring) (~\(max(1, wallMs / 20)) if responsive, ~0 if frozen)")

        // The send row landed.
        let inserted = try await pool.read { db in
            try OutboxMessage.filter(Column("draftId") == "draft-freeze").fetchCount(db)
        }
        #expect(inserted == 1, "the send must have persisted one outbox row")

        // Contention was real: the write WAITED behind the maintenance write.
        #expect(wallMs > 500, "test did not create writer contention (persist wall \(wallMs)ms)")

        // The fix: main actor stayed live during that wait (a frozen one ticks ~0).
        #expect(
            ticksDuring > 10,
            "main actor was STARVED: only \(ticksDuring) heartbeats during a \(wallMs)ms persist — the send blocked the UI"
        )
    }

    /// Probe-validity control: the OLD pattern — a SYNCHRONOUS `dbPool.write` on the
    /// main actor under the same contention — DOES freeze the heartbeat. Proves the
    /// responsiveness assertion above is not vacuous (the probe can detect a freeze).
    @Test("Synchronous main-actor write DOES freeze the heartbeat (probe validity)")
    func syncWriteFreezesMainActor() async throws {
        let (dir, pool, previous) = try makeOutboxTestDatabase()
        defer {
            AppDatabase.shared.withLock { $0 = previous }
            TestDatabaseTeardown.retire(pool: pool, directory: dir)
        }

        let hb = Heartbeat()
        hb.start()
        try await Task.sleep(for: .milliseconds(120))

        let bg = startMaintenanceWriter(pool)
        try await Task.sleep(for: .milliseconds(50))

        // The OLD compose-dismiss behaviour: a synchronous write inline on the main
        // actor. It blocks the thread for the full writer-contention wait. Routed
        // through a synchronous @MainActor helper so the SYNC `dbPool.write` overload
        // is selected (in an `async` context the async overload wins and would
        // suspend instead of block — exactly the difference the fix relies on).
        let ticksBefore = hb.ticks
        let t0 = CFAbsoluteTimeGetCurrent()
        try Self.blockingSyncInsert()
        let wallMs = Int((CFAbsoluteTimeGetCurrent() - t0) * 1000)
        let ticksDuring = hb.ticks - ticksBefore
        _ = await bg.value
        hb.stop()

        print("[OutboxSendFreezeTest/control] SYNC write wall=\(wallMs)ms | heartbeats during=\(ticksDuring) (expect ~0)")

        #expect(wallMs > 500, "control did not create writer contention (sync wall \(wallMs)ms)")
        // A synchronous main-actor write starves the heartbeat — this is the freeze
        // the async fix removes. Allow a tiny margin for a tick mid-acquisition.
        #expect(
            ticksDuring < 3,
            "expected the synchronous write to FREEZE the main actor, but it ticked \(ticksDuring)× — probe is not measuring a real freeze"
        )
    }
}
