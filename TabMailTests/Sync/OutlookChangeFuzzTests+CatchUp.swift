/* This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at https://mozilla.org/MPL/2.0/. */

import Foundation
import GRDB
import Synchronization
import Testing
@testable import TabMail

/// Seeded schedules for Outlook's catch-up of older mail (ADR-IOS-107) with slow
/// reads: every listing page moves the catch-up's wall clock (`CatchUpWallClock`)
/// on by 0 to 40 s, now and then past the completion log's retention, and the
/// user's flag and read actions complete while a slice's read is in flight.
/// Between slices other clients change, delete and move mail, faults hit
/// listings and proofs, and lapses arm new listings.
///
/// Invariants, never expected values for a schedule:
/// 1. **Completion ledger**: a user action that completed while a slice's read
///    was in flight still shows after that slice is applied. The read began
///    before the action completed, so whatever it carries for that message is
///    older than the user's value.
/// 2. **Liveness**: once the faults and the user's actions stop (the reads stay
///    slow, up to 40 s per page), a new listing of each folder completes within
///    `CatchUpFuzz.livenessSlices` slices.
/// 3. **Convergence**: after that listing, every row's read and flag state is
///    the server's, and no row names a message the server does not hold in
///    that folder.
extension OutlookChangeFuzzTests {

    enum CatchUpFuzz {
        static let defaultIterations = 6
        static let defaultSeed: UInt64 = 0x0C7A_DE17_A000_0B07

        static var iterations: Int {
            if let raw = ProcessInfo.processInfo.environment["OUTLOOK_CATCHUP_FUZZ_ITERATIONS"], let v = Int(raw), v > 0 { return v }
            return defaultIterations
        }

        static var seed: UInt64 {
            guard let raw = ProcessInfo.processInfo.environment["OUTLOOK_CATCHUP_FUZZ_SEED"] else { return defaultSeed }
            if raw.hasPrefix("0x") || raw.hasPrefix("0X") { return UInt64(raw.dropFirst(2), radix: 16) ?? defaultSeed }
            return UInt64(raw) ?? defaultSeed
        }

        /// Messages in each folder at the start, all held locally.
        static let initialPerFolder = 12
        /// Slices per iteration before quiescence.
        static let slices = 14
        /// Largest wall-clock jump per listing page, in seconds.
        static let maxJumpSeconds: UInt64 = 40
        /// Percent chance a page's jump goes past the completion log's retention.
        static let retentionJumpPercent = 4
        /// Percent chance a slice has a user action complete during its read.
        static let actionPercent = 50
        /// Other-client changes between slices.
        static let maxServerChangesPerSlice = 3
        /// Percent chance a slice arms a lapse on a folder.
        static let lapsePercent = 25
        /// Percent chance a slice injects a listing or proof fault.
        static let faultPercent = 25
        /// Largest slice request count drawn (the production slice's is larger).
        static let maxSliceRequests: UInt64 = 12
        /// Page cap, so a folder takes several pages.
        static let pageCap = 4
        /// Slices allowed for a listing to complete once faults and actions stop.
        static let livenessSlices = 40
    }

    @Test("Seeded catch-up schedules with slow reads keep every in-flight user action, complete their listings, and converge")
    func catchUpFuzz() async throws {
        let base = CatchUpFuzz.seed
        for iteration in 0..<CatchUpFuzz.iterations {
            var rng = SplitMix64(seed: base &+ UInt64(iteration))
            let label = "catch-up seed=0x\(String(base, radix: 16)) iteration=\(iteration)"
            if try await runCatchUpIteration(&rng, label: label) { break }
        }
    }

    /// One user action that completed during a slice's read: the message, the
    /// folder and the value the user set.
    struct CompletedAction: CustomStringConvertible {
        let id: String
        let folder: String
        let isRead: Bool?
        let isFlagged: Bool?
        var description: String { "\(id) in \(folder) read=\(isRead.map(String.init) ?? "-") flagged=\(isFlagged.map(String.init) ?? "-")" }
    }

    /// Returns true when an invariant failed (the run stops there).
    private func runCatchUpIteration(_ rng: inout SplitMix64, label: String) async throws -> Bool {
        let clock = Clock()
        var seeds: [StatefulExchangeActionServer.Seed] = []
        for folder in Self.folders {
            for i in 0..<CatchUpFuzz.initialPerFolder {
                // Graph gives several messages of a folder one second: about a
                // third share the previous message's, so page boundaries fall
                // inside such groups.
                let previous = i > 0 ? seeds.last?.receivedAt : nil
                let at = previous.flatMap { rng.next() % 3 == 0 ? $0 : nil } ?? clock.daysAgo(Double(rng.next() % 300) + 1)
                seeds.append(OutlookCatchUpTests.seed("\(folder)-cu\(i)", in: folder, at: at,
                                                      isRead: rng.next() % 2 == 0, isFlagged: rng.next() % 3 == 0))
            }
        }
        var failed = false
        var localRng = rng
        try await OutlookCatchUpTests.withWorld(seeds: seeds, heldSince: clock.daysAgo(400)) { w, engine in
            for seed in seeds { try w.insertRow(seed.providerMessageId, in: seed.folderId, date: seed.receivedAt) }
            try await w.baselineAll()
            w.server.setCatchUpListingPageCap(CatchUpFuzz.pageCap)

            let wall = Mutex(Date())
            CatchUpWallClock.nowForTesting.withLock { $0 = { wall.withLock { $0 } } }
            defer { CatchUpWallClock.nowForTesting.withLock { $0 = nil } }
            // Drawn before each slice, consumed by the page hook.
            struct PageChaos: Sendable {
                var jumps: [TimeInterval] = []
                var action: (id: String, folder: String, isRead: Bool?, isFlagged: Bool?)?
                var done: [CompletedAction] = []
            }
            let chaos = Mutex(PageChaos())
            let server = w.server
            let pool = w.pool
            let accountId = w.accountId
            server.afterCatchUpListingPage { _ in
                let step = chaos.withLock { c -> (jump: TimeInterval, action: (id: String, folder: String, isRead: Bool?, isFlagged: Bool?)?) in
                    let jump = c.jumps.isEmpty ? 0 : c.jumps.removeFirst()
                    let action = c.action
                    c.action = nil
                    if let action { c.done.append(CompletedAction(id: action.id, folder: action.folder, isRead: action.isRead, isFlagged: action.isFlagged)) }
                    return (jump, action)
                }
                wall.withLock { $0 = $0.addingTimeInterval(step.jump) }
                // The user's action completes during the read: the phone shows
                // it, the server holds it, and its completion is recorded, as the
                // queue's drain does (its 30 s protection has run out).
                guard let action = step.action else { return }
                let key = MessageIdentity.headerId(accountId: accountId, folderPath: action.folder, messageId: action.id)
                try? pool.write { db in
                    if let isRead = action.isRead {
                        try db.execute(sql: "UPDATE messageHeader SET isRead = ? WHERE id = ?", arguments: [isRead, key])
                    }
                    if let isFlagged = action.isFlagged {
                        try db.execute(sql: "UPDATE messageHeader SET isFlagged = ? WHERE id = ?", arguments: [isFlagged, key])
                    }
                }
                if let isRead = action.isRead { server.setReadFromOtherClient(providerMessageId: action.id, isRead: isRead) }
                if let isFlagged = action.isFlagged { server.setFlagFromOtherClient(providerMessageId: action.id, isFlagged: isFlagged) }
                AccountManager.shared.recordActionCompleted(accountId: accountId, messageKeys: [action.id])
            }
            defer { server.afterCatchUpListingPage(nil) }

            var trace: [String] = []
            var nextId = 0
            func drawJumps(_ rng: inout SplitMix64, retention: Bool) -> [TimeInterval] {
                (0..<16).map { _ in
                    if retention, Int(rng.next() % 100) < CatchUpFuzz.retentionJumpPercent {
                        return SyncConfig.catchUpCompletionLogRetentionSeconds + 1
                    }
                    return TimeInterval(rng.next() % (CatchUpFuzz.maxJumpSeconds + 1))
                }
            }

            for slice in 0..<CatchUpFuzz.slices {
                let where_ = "\(label) slice=\(slice)"
                var did: [String] = []

                // Other clients, between slices.
                for _ in 0..<Int(localRng.next() % UInt64(CatchUpFuzz.maxServerChangesPerSlice + 1)) {
                    let folder = Self.folders[Int(localRng.next() % 2)]
                    let ids = w.server.messageIds(inFolder: folder).sorted()
                    switch localRng.next() % 5 {
                    case 0:
                        if let id = Self.pickOne(ids, &localRng) {
                            let read = w.server.snapshot(providerMessageId: id)?.isRead ?? false
                            w.server.setReadFromOtherClient(providerMessageId: id, isRead: !read)
                            did.append("read \(id)=\(!read)")
                        }
                    case 1:
                        if let id = Self.pickOne(ids, &localRng) {
                            let flagged = w.server.snapshot(providerMessageId: id)?.isFlagged ?? false
                            w.server.setFlagFromOtherClient(providerMessageId: id, isFlagged: !flagged)
                            did.append("flag \(id)=\(!flagged)")
                        }
                    case 2:
                        if let id = Self.pickOne(ids, &localRng) {
                            w.server.deleteFromOtherClient(providerMessageId: id)
                            did.append("delete \(id)")
                        }
                    case 3:
                        let destination = folder == Reader.inbox ? Reader.archive : Reader.inbox
                        if let id = Self.pickOne(ids, &localRng),
                           let moved = w.server.moveFromOtherClient(providerMessageId: id, to: destination) {
                            did.append("move \(id) to \(destination) as \(moved)")
                        }
                    default:
                        let id = "old-cu\(nextId)"
                        nextId += 1
                        w.server.deliver(OutlookCatchUpTests.seed(id, in: folder, at: clock.daysAgo(Double(localRng.next() % 300) + 1)))
                        did.append("old \(id) moved into \(folder)")
                    }
                }
                for folder in Self.folders where Int(localRng.next() % 100) < CatchUpFuzz.lapsePercent {
                    let folderId = w.folderId(folder)
                    try await w.pool.write { db in try SyncEngine.markCatchUpLapse(folderId: folderId, db: db) }
                    did.append("lapse \(folder)")
                }

                // Chaos for this slice's read.
                w.server.clearBatchItemAnswers()
                if Int(localRng.next() % 100) < CatchUpFuzz.faultPercent {
                    let faults: [FakeHTTP.CannedResponse] = [.status(500), .status(502), .transportError(.networkConnectionLost)]
                    let fault = faults[Int(localRng.next() % UInt64(faults.count))]
                    if localRng.next() % 2 == 0 { w.server.failCatchUpListings([fault]) } else { w.server.failBatches([fault]) }
                    did.append("fault \(fault)")
                }
                let jumps = drawJumps(&localRng, retention: true)
                var action: (id: String, folder: String, isRead: Bool?, isFlagged: Bool?)?
                if Int(localRng.next() % 100) < CatchUpFuzz.actionPercent {
                    let folder = Self.folders[Int(localRng.next() % 2)]
                    let held = try w.rowIds(in: folder).sorted().filter {
                        w.server.snapshot(providerMessageId: $0)?.folderId == folder
                    }
                    if let id = Self.pickOne(held, &localRng), let row = try w.row(id, in: folder) {
                        action = localRng.next() % 2 == 0
                            ? (id, folder, !row.isRead, nil) : (id, folder, nil, !row.isFlagged)
                    }
                }
                chaos.withLock { $0 = PageChaos(jumps: jumps, action: action, done: []) }
                let requests = 1 + Int(localRng.next() % CatchUpFuzz.maxSliceRequests)

                await OutlookCatchUpTests.pass(w, engine, Self.folders, context: OutlookCatchUpTests.requests(requests))

                let done = chaos.withLock { $0.done }
                did.append("slice requests=\(requests) jumps=\(jumps.prefix(4).map { Int($0) }) actions=\(done)")
                trace.append("slice \(slice): \(did.joined(separator: "; "))")

                // 1. Completion ledger.
                for completed in done {
                    guard let row = try w.row(completed.id, in: completed.folder) else { continue }
                    if let isRead = completed.isRead, row.isRead != isRead {
                        Issue.record("[\(where_)] a read that began before \(completed) overwrote it: read=\(row.isRead)"); failed = true
                    }
                    if let isFlagged = completed.isFlagged, row.isFlagged != isFlagged {
                        Issue.record("[\(where_)] a read that began before \(completed) overwrote it: flagged=\(row.isFlagged)"); failed = true
                    }
                }
                if failed {
                    Issue.record("[\(where_)] schedule:\n\(trace.joined(separator: "\n"))")
                    return
                }
            }

            // Quiescence: faults and actions stop; the reads stay slow (no jump
            // past the retention). A lapse arms a new listing of each folder.
            w.server.clearBatchItemAnswers()
            w.server.state.value.withLock { $0.delta.batchFailures = []; $0.catchUp.failures = [] }
            // Completion times are on the budget's clock (`Date`), not the wall clock.
            let armedAt = Date()
            for folder in Self.folders {
                let folderId = w.folderId(folder)
                try await w.pool.write { db in try SyncEngine.markCatchUpLapse(folderId: folderId, db: db) }
            }
            var slicesTaken = 0
            func listedSinceArming() throws -> Bool {
                try Self.folders.allSatisfy { folder in
                    let state = try OutlookCatchUpTests.state(w, folder)
                    return state?.listing == nil && (state?.lastCompletedAt).map { $0 >= armedAt } == true
                }
            }
            while try !listedSinceArming(), slicesTaken < CatchUpFuzz.livenessSlices {
                chaos.withLock { $0 = PageChaos(jumps: drawJumps(&localRng, retention: false), action: nil, done: []) }
                await OutlookCatchUpTests.pass(w, engine, Self.folders, context: OutlookCatchUpTests.requests(SyncConfig.catchUpSliceMaxRequests))
                slicesTaken += 1
            }
            // 2. Liveness.
            if try !listedSinceArming() {
                Issue.record("[\(label)] the listings did not complete within \(CatchUpFuzz.livenessSlices) slices once the faults stopped\n\(trace.joined(separator: "\n"))")
                failed = true
                return
            }
            // 3. Convergence, and no message has two rows.
            let messages = w.server.state.value.withLock { $0.messagesByProviderId }
            for folder in Self.folders {
                let folderId = w.folderId(folder)
                let rowCount = try await w.pool.read { db in
                    try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM messageHeader WHERE folderId = ?", arguments: [folderId]) ?? 0
                }
                if rowCount != (try w.rowIds(in: folder)).count {
                    Issue.record("[\(label)] \(folder) holds a message twice"); failed = true
                }
                for id in try w.rowIds(in: folder).sorted() {
                    guard let message = messages[id], message.folderId == folder else {
                        Issue.record("[\(label)] row \(id) in \(folder) names a message the server does not hold there"); failed = true
                        continue
                    }
                    guard let row = try w.row(id, in: folder) else { continue }
                    if row.isRead != message.isRead || row.isFlagged != message.isFlagged {
                        Issue.record("[\(label)] \(folder) \(id) read=\(row.isRead) flagged=\(row.isFlagged) != server read=\(message.isRead) flagged=\(message.isFlagged)")
                        failed = true
                    }
                }
            }
            if failed { Issue.record("[\(label)] schedule:\n\(trace.joined(separator: "\n"))") }
        }
        rng = localRng
        return failed
    }

    private static func pickOne(_ ids: [String], _ rng: inout SplitMix64) -> String? {
        guard !ids.isEmpty else { return nil }
        return ids[Int(rng.next() % UInt64(ids.count))]
    }

    /// Whole-second dates, as Graph serves them.
    struct Clock {
        let now = Date(timeIntervalSince1970: Date().timeIntervalSince1970.rounded(.down))
        func daysAgo(_ days: Double) -> Date {
            Date(timeIntervalSince1970: (now.timeIntervalSince1970 - days * 86_400).rounded(.down))
        }
    }
}
