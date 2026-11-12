/* This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at https://mozilla.org/MPL/2.0/. */

import Foundation
import GRDB
import Synchronization
import Testing
@testable import TabMail

/// Seeded adversarial schedules for the Gmail change pass, driven through the
/// public entries (`performDeltaSync`, a foreground pass) against
/// `StatefulGmailActionServer`, on folders small enough that the full sync's
/// listing spans each whole folder.
///
/// Each iteration converges the account with one foreground pass, then runs
/// several rounds. A round draws, from the seed: changes made by another
/// client (read, star, user label, archive, delete, new mail), user actions
/// on the app (an archive queued as a move, a pending read), when each queued
/// archive completes relative to the pass (before it, DURING the pass's fetch
/// of that message, or after it), and a latency per message fetch. Gmail's
/// label read lags the app's own move: the server applies a completed archive
/// only after the pass that raced it.
///
/// Invariants checked after every pass, never expected values for a schedule:
/// 1. **Intention ledger**: every queued operation the schedule did not
///    complete is still queued.
/// 2. **No ghost (#106)**: a message the app archived never reappears in the
///    Inbox once its archive completed.
/// 3. **Search equals rows**: every row is searchable; every row a pass
///    removed leaves search.
/// 4. **Badge**: the Inbox unread count equals its unread rows.
/// 5. **Convergence**: after quiescence (every op drained, protections gone,
///    one foreground pass), every tracked folder's rows and flags equal the
///    server's.
///
/// Knobs (`TEST_RUNNER_` prefix on the CLI): `GMAIL_DELTA_FUZZ_ITERATIONS`
/// (default `FuzzConfig.defaultIterations`) and `GMAIL_DELTA_FUZZ_SEED`
/// (`0x…` hex or decimal). A failure names its seed and iteration; replay with
/// that seed and `ITERATIONS` set to the iteration plus one.
@Suite("Gmail change pass fuzzer", .serialized, .processGlobalState)
struct GmailDeltaFuzzTests {

    typealias Pins = GmailDeltaApplyInvariantTests

    enum FuzzConfig {
        static let defaultIterations = 6
        static let defaultSeed: UInt64 = 0x6D41_DE17_A000_0001

        static var iterations: Int {
            if let raw = ProcessInfo.processInfo.environment["GMAIL_DELTA_FUZZ_ITERATIONS"], let v = Int(raw), v > 0 { return v }
            return defaultIterations
        }

        static var seed: UInt64 {
            guard let raw = ProcessInfo.processInfo.environment["GMAIL_DELTA_FUZZ_SEED"] else { return defaultSeed }
            if raw.hasPrefix("0x") || raw.hasPrefix("0X") { return UInt64(raw.dropFirst(2), radix: 16) ?? defaultSeed }
            return UInt64(raw) ?? defaultSeed
        }

        /// Messages in the mailbox at the start (all fit one listing).
        static let initialMessages = 8
        /// Delta rounds per iteration.
        static let rounds = 4
        /// Other-client changes per round.
        static let maxServerChangesPerRound = 4
        /// Percent chance a round has the user archive an Inbox message.
        static let archivePercent = 70
        /// Percent chance a round has the user queue a read on a message.
        static let pendingReadPercent = 40
        /// Seeded per-fetch latency bound: stretches the pass's await windows.
        static let latencyMaxMilliseconds = 6
    }

    /// Where a queued archive completes relative to the pass.
    enum CompletionPoint: CaseIterable { case beforePass, duringFetch, afterPass }

    /// Labels another client toggles. TRASH is left out: Gmail's listing hides
    /// it, so the convergence oracle could not read Trash back.
    static let toggledLabels = ["UNREAD", "STARRED", "INBOX", Pins.userLabelId]

    struct Ghost: Sendable {
        let messageId: String
    }

    @Test("Seeded schedules keep the queue, the Inbox, search and the badge consistent, and converge")
    func fuzz() async throws {
        let base = FuzzConfig.seed
        for iteration in 0..<FuzzConfig.iterations {
            var rng = SplitMix64(seed: base &+ UInt64(iteration))
            let label = "seed=0x\(String(base, radix: 16)) iteration=\(iteration)"
            let failed = try await runIteration(&rng, label: label)
            if failed { break }
        }
    }

    // MARK: - One iteration

    /// Returns true when an invariant failed (the run stops there).
    private func runIteration(_ rng: inout SplitMix64, label: String) async throws -> Bool {
        var seeds: [StatefulGmailActionServer.Seed] = []
        for i in 0..<FuzzConfig.initialMessages {
            var labels: Set<String> = []
            for candidate in Self.toggledLabels where rng.next() % 2 == 0 { labels.insert(candidate) }
            seeds.append(Pins.seed("fz\(i)", labels: labels, date: Pins.daysAgo(Double(i + 1))))
        }
        var failed = false
        var localRng = rng
        try await Pins.withWorld(seeds: seeds) { w in
            try await w.foregroundPassWithFullSyncDue()
            var nextId = FuzzConfig.initialMessages
            var openOps: [String: String] = [:]        // messageId -> op id the schedule has not completed
            var completedArchives: Set<String> = []  // archived by the app, archive completed
            var serverMovesOwed: [String] = []       // archives whose server change lags
            var removedHeaderIds: Set<String> = []

            for round in 0..<FuzzConfig.rounds {
                let where_ = "\(label) round=\(round)"
                // Other clients.
                let changes = Int(localRng.next() % UInt64(FuzzConfig.maxServerChangesPerRound + 1))
                for _ in 0..<changes {
                    let ids = Self.serverIds(w)
                    switch localRng.next() % 6 {
                    case 0:
                        w.server.addMessage(Pins.seed("fz\(nextId)", labels: ["INBOX", "UNREAD"], date: Pins.daysAgo(0.01 * Double(nextId))))
                        nextId += 1
                    case 1:
                        if let id = Self.pick(ids, &localRng), openOps[id] == nil, !completedArchives.contains(id) {
                            for row in try w.rows(id) { removedHeaderIds.insert(row.id) }
                            w.server.removeMessage(providerMessageId: id)
                        }
                    default:
                        if let id = Self.pick(ids, &localRng) {
                            let flip = Self.toggledLabels[Int(localRng.next() % UInt64(Self.toggledLabels.count))]
                            let has = w.server.snapshot(providerMessageId: id)?.labels.contains(flip) ?? false
                            if !completedArchives.contains(id) || flip != "INBOX" {
                                w.server.applyLabelChange(providerMessageId: id, add: has ? [] : [flip], remove: has ? [flip] : [])
                            }
                        }
                    }
                }

                // The user archives an Inbox message.
                var completion: (id: String, point: CompletionPoint)?
                if Int(localRng.next() % 100) < FuzzConfig.archivePercent,
                   let id = Self.pick(try Self.localInboxIds(w).filter { openOps[$0] == nil && !completedArchives.contains($0) }, &localRng),
                   let row = try w.row(id, in: w.inbox) {
                    try await w.pool.write { db in _ = try row.delete(db) }
                    let moved = try w.insertRow(id, in: w.allMail, date: row.date, isRead: row.isRead, isFlagged: row.isFlagged)
                    // The app's move carries the search entry to the new row.
                    try await SearchIndex.shared.removeMessages(contentKeys: [ContentKey(rawValue: row.id)])
                    _ = try await SearchIndex.shared.indexHeaders([Self.record(moved)])
                    removedHeaderIds.insert(row.id)
                    let op = try w.insertOp(.move, key: id, folder: w.inbox)
                    openOps[id] = op.id
                    // Another client touches it too, so the history names it.
                    w.server.applyLabelChange(providerMessageId: id, add: ["STARRED"])
                    let point = CompletionPoint.allCases[Int(localRng.next() % UInt64(CompletionPoint.allCases.count))]
                    completion = (id, point)
                }
                // A pending read on some message.
                if Int(localRng.next() % 100) < FuzzConfig.pendingReadPercent,
                   let id = Self.pick(Self.serverIds(w).filter { openOps[$0] == nil }, &localRng) {
                    let op = try w.insertOp(.markRead, key: id, folder: w.inbox)
                    openOps[id] = op.id
                }

                // Chaos: per-fetch latency, and the archive's completion point.
                let pool = w.pool
                for id in Self.serverIds(w) {
                    let latency = Int(localRng.next() % UInt64(FuzzConfig.latencyMaxMilliseconds + 1))
                    let completesHere = completion?.id == id && completion?.point == .duringFetch
                    let opId = openOps[id]
                    w.server.onGet(providerMessageId: id) {
                        if latency > 0 { Thread.sleep(forTimeInterval: Double(latency) / 1000) }
                        if completesHere, let opId {
                            Pins.recordCompletionBlocking([id])
                            try? pool.write { db in _ = try PendingOperation.deleteOne(db, key: opId) }
                        }
                    }
                }
                if let completion, completion.point == .beforePass, let opId = openOps[completion.id] {
                    await AccountManager.shared.recordRecentlyCompleted(messageIds: [completion.id])
                    try await w.pool.write { db in _ = try PendingOperation.deleteOne(db, key: opId) }
                }

                // Rows before the pass, to know which the pass removed.
                let rowsBefore = try Self.accountHeaderIds(w)
                _ = try await w.delta()
                for id in Self.serverIds(w) { w.server.onGet(providerMessageId: id, nil) }

                if let completion {
                    switch completion.point {
                    case .beforePass, .duringFetch:
                        openOps[completion.id] = nil
                        completedArchives.insert(completion.id)
                        serverMovesOwed.append(completion.id)
                    case .afterPass:
                        if let opId = openOps[completion.id] {
                            await AccountManager.shared.recordRecentlyCompleted(messageIds: [completion.id])
                            try await w.pool.write { db in _ = try PendingOperation.deleteOne(db, key: opId) }
                        }
                        openOps[completion.id] = nil
                        completedArchives.insert(completion.id)
                        serverMovesOwed.append(completion.id)
                    }
                }

                removedHeaderIds.formUnion(rowsBefore.subtracting(try Self.accountHeaderIds(w)))
                if try await !Self.checkInvariants(w, openOps: openOps, completedArchives: completedArchives,
                                                   removedHeaderIds: removedHeaderIds, where: where_) {
                    failed = true
                    return
                }

                // Gmail's label read catches up with the app's archives.
                for id in serverMovesOwed { w.server.applyLabelChange(providerMessageId: id, remove: ["INBOX"]) }
                serverMovesOwed.removeAll()
            }

            // Quiescence: every op drains, protections lapse, one foreground pass.
            try await w.pool.write { db in _ = try PendingOperation.deleteAll(db) }
            await AccountManager.shared.clearRecentlyCompletedForTesting()
            try await w.foregroundPassWithFullSyncDue()
            if try await !Self.checkConvergence(w, where: "\(label) quiescence") { failed = true }
            try? await SearchIndex.shared.removeMessagesForAccount(accountId: w.accountId)
        }
        rng = localRng
        return failed
    }

    // MARK: - Invariants

    private static func checkInvariants(
        _ w: Pins.World, openOps: [String: String], completedArchives: Set<String>,
        removedHeaderIds: Set<String>, where: String
    ) async throws -> Bool {
        var ok = true
        // 1. Ledger.
        let queued = Set(try w.pendingOps().map(\.id))
        for (id, opId) in openOps where !queued.contains(opId) {
            Issue.record("[\(`where`)] the queued op on \(id) was dropped by the pass"); ok = false
        }
        // 2. No ghost.
        for id in completedArchives where try w.row(id, in: w.inbox) != nil {
            Issue.record("[\(`where`)] ghost: \(id) was archived by the app and is back in the Inbox"); ok = false
        }
        // 3. Search equals rows.
        let rows = try accountHeaderIds(w)
        for id in rows {
            let searchable = try await Pins.eventually { try await Pins.isSearchable(id) }
            if !searchable { Issue.record("[\(`where`)] row \(id) is not searchable"); ok = false }
        }
        for id in removedHeaderIds.subtracting(rows) {
            let gone = try await Pins.eventually { try await !Pins.isSearchable(id) }
            if !gone { Issue.record("[\(`where`)] removed row \(id) is still in search"); ok = false }
        }
        // 4. Badge.
        await UnreadCountManager.shared.awaitIdleForTesting()
        let unreadRows = try w.unreadRows(in: w.inbox)
        let count = try w.unreadCount(of: w.inbox)
        if unreadRows != count { Issue.record("[\(`where`)] Inbox unread count \(count) != unread rows \(unreadRows)"); ok = false }
        return ok
    }

    /// 5. Every tracked folder's rows and flags equal the server's.
    private static func checkConvergence(_ w: Pins.World, where: String) async throws -> Bool {
        var ok = true
        for folder in [w.inbox, w.allMail, w.label] {
            var expected: [String: (read: Bool, flagged: Bool)] = [:]
            for id in serverIds(w) {
                guard let snap = w.server.snapshot(providerMessageId: id),
                      GmailProvider.folder(folder.path, containsMessageWithLabels: Array(snap.labels)) else { continue }
                expected[id] = (snap.isRead, snap.isFlagged)
            }
            let local = try await w.pool.read { db in
                try MessageHeader.filter(Column("folderId") == folder.id).fetchAll(db)
            }
            let localIds = Set(local.map(\.messageId))
            if localIds != Set(expected.keys) {
                Issue.record("[\(`where`)] \(folder.path) rows \(localIds.sorted()) != server \(expected.keys.sorted())"); ok = false
            }
            for row in local {
                guard let want = expected[row.messageId] else { continue }
                if row.isRead != want.read || row.isFlagged != want.flagged {
                    Issue.record("[\(`where`)] \(folder.path) \(row.messageId) flags read=\(row.isRead) flagged=\(row.isFlagged) != server read=\(want.read) flagged=\(want.flagged)")
                    ok = false
                }
            }
        }
        await UnreadCountManager.shared.awaitIdleForTesting()
        if try w.unreadRows(in: w.inbox) != w.unreadCount(of: w.inbox) {
            Issue.record("[\(`where`)] Inbox unread count differs from its rows after convergence"); ok = false
        }
        return ok
    }

    // MARK: - Helpers

    private static func serverIds(_ w: Pins.World) -> [String] {
        (0..<64).map { "fz\($0)" }.filter { w.server.snapshot(providerMessageId: $0) != nil }
    }

    private static func localInboxIds(_ w: Pins.World) throws -> [String] {
        try w.pool.read { db in
            try String.fetchAll(db, sql: "SELECT messageId FROM messageHeader WHERE folderId = ? ORDER BY messageId", arguments: [w.inbox.id])
        }
    }

    private static func accountHeaderIds(_ w: Pins.World) throws -> Set<String> {
        try w.pool.read { db in
            Set(try String.fetchAll(db, sql: "SELECT id FROM messageHeader WHERE accountId = ?", arguments: [w.accountId]))
        }
    }

    private static func pick(_ ids: [String], _ rng: inout SplitMix64) -> String? {
        guard !ids.isEmpty else { return nil }
        return ids[Int(rng.next() % UInt64(ids.count))]
    }

    private static func record(_ h: MessageHeader) -> FTSHeaderRecord {
        FTSHeaderRecord(
            contentKey: ContentKey(rawValue: h.id), headerId: h.id, messageId: h.messageId,
            subject: h.subject, from: h.from, to: h.to, cc: h.cc, bcc: h.bcc,
            dateMs: Int64(h.date.timeIntervalSince1970 * 1000), folderId: h.folderId)
    }
}
