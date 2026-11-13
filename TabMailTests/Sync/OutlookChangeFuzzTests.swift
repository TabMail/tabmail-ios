/* This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at https://mozilla.org/MPL/2.0/. */

import Foundation
import GRDB
import Testing
@testable import TabMail

/// Seeded adversarial schedules for Outlook's change reader against
/// `StatefulExchangeActionServer`, each read applied by the engine's own apply.
/// A round reads in one of three ways, drawn from the seed: a bare read with a
/// frozen clock (where a budget cut can land), the engine's change pass (the
/// folder-list apply and the pass's success or failure), or a foreground pass
/// (the full sync, which lists every folder not tracked and commits its
/// bookmark).
///
/// Each iteration starts with an Inbox and an Archive, mail inside and below
/// the held range, and reads until both folders track. A round then draws, from
/// the seed: changes made by another client (new mail, read and flag changes,
/// deletes, moves between the two folders, at any age), a read the user queues
/// on a message the phone holds and when that read completes, and chaos for the
/// read itself: page and batch latency, failed pages (a server error, a
/// throttle, a dropped connection), failed batches, one message whose header
/// fetch answers an error, a read budget cut anywhere, and an expensive network.
///
/// Invariants checked after every read, never expected values for a schedule:
/// 1. **Intention ledger**: every queued read the schedule did not complete is
///    still queued, and its message still shows as read.
/// 2. **No wrong-folder row**: every row in a folder names a message the server
///    held in that folder at some point.
/// 3. **Convergence**: after quiescence (every read completed, faults cleared,
///    reads until every folder tracks and no re-read list is left), each
///    folder's rows equal the server's messages within that folder's held range
///    plus every message that arrived in it after its baseline, with the
///    server's flags. A foreground pass lists the newest messages of a folder
///    it does not track whatever their age, so a row below the held range is
///    allowed when it is still in the folder and was there when a foreground
///    pass ran.
///
/// Knobs (`TEST_RUNNER_` prefix on the CLI): `OUTLOOK_CHANGE_FUZZ_ITERATIONS`
/// (default `FuzzConfig.defaultIterations`) and `OUTLOOK_CHANGE_FUZZ_SEED`
/// (`0x…` hex or decimal). A failure names its seed and iteration; replay with
/// that seed and `ITERATIONS` set to the iteration plus one.
@Suite("Outlook change reader fuzzer", .serialized, .processGlobalState)
struct OutlookChangeFuzzTests {

    typealias Reader = OutlookChangeReadingTests

    enum FuzzConfig {
        static let defaultIterations = 8
        static let defaultSeed: UInt64 = 0x0C7A_DE17_A000_0003

        static var iterations: Int {
            if let raw = ProcessInfo.processInfo.environment["OUTLOOK_CHANGE_FUZZ_ITERATIONS"], let v = Int(raw), v > 0 { return v }
            return defaultIterations
        }

        static var seed: UInt64 {
            guard let raw = ProcessInfo.processInfo.environment["OUTLOOK_CHANGE_FUZZ_SEED"] else { return defaultSeed }
            if raw.hasPrefix("0x") || raw.hasPrefix("0X") { return UInt64(raw.dropFirst(2), radix: 16) ?? defaultSeed }
            return UInt64(raw) ?? defaultSeed
        }

        /// Messages in each folder at the start.
        static let initialPerFolder = 8
        /// Start of the held range, in days before now.
        static let heldDays: Double = 30
        /// Reads per iteration.
        static let rounds = 6
        /// Other-client changes per round.
        static let maxServerChangesPerRound = 5
        /// Percent chance a round has the user queue a read.
        static let pendingReadPercent = 40
        /// Percent chance a queued read completes in a round.
        static let completePercent = 50
        /// Percent chance a round cuts the read budget.
        static let budgetCutPercent = 40
        /// Largest cut budget, in requests. A pass here costs a page per folder
        /// plus a header batch, so a cut of 1 to 3 lands inside the pass: between
        /// a page and the headers it is missing, where the page-hold rule matters.
        static let budgetCutMaxRequests = 3
        /// Percent chance a round injects a page or batch fault.
        static let faultPercent = 30
        /// Seeded latency bound for pages and batches.
        static let latencyMaxMilliseconds = 5
        /// Percent chance a round runs the engine's change pass instead of a bare read.
        static let enginePassPercent = 30
        /// Percent chance a round runs a foreground pass instead of a bare read.
        static let foregroundPassPercent = 10
        /// Reads allowed for quiescence.
        static let quiescenceReads = 8
    }

    static let folders = [Reader.inbox, Reader.archive]

    @Test("Seeded schedules keep queued reads, never put a row in the wrong folder, and converge")
    func fuzz() async throws {
        let base = FuzzConfig.seed
        for iteration in 0..<FuzzConfig.iterations {
            var rng = SplitMix64(seed: base &+ UInt64(iteration))
            let label = "seed=0x\(String(base, radix: 16)) iteration=\(iteration)"
            if try await runIteration(&rng, label: label) { break }
        }
    }

    // MARK: - One iteration

    /// Returns true when an invariant failed (the run stops there).
    private func runIteration(_ rng: inout SplitMix64, label: String) async throws -> Bool {
        var seeds: [StatefulExchangeActionServer.Seed] = []
        for folder in Self.folders {
            for i in 0..<FuzzConfig.initialPerFolder {
                let age = Double(rng.next() % 60) + 0.5
                seeds.append(Reader.seed("\(folder)-fz\(i)", in: folder, daysAgo: age,
                                         isRead: rng.next() % 2 == 0, isFlagged: rng.next() % 3 == 0))
            }
        }
        var failed = false
        var localRng = rng
        try await Reader.withWorld(seeds: seeds, heldSince: Reader.daysAgo(FuzzConfig.heldDays)) { w in
            var now = Date()
            try await w.baselineAll(now: now)
            var everIn: [String: Set<String>] = [:]
            for folder in Self.folders { everIn[folder] = w.server.messageIds(inFolder: folder) }
            var arrivedAfterBaseline: [String: Set<String>] = [:]
            // Messages in each folder when a foreground pass ran.
            var listable: [String: Set<String>] = [:]
            var openReads: [String: (opId: String, folder: String)] = [:]
            var nextId = 0
            // What each round did, reported with a failure so its schedule reads directly.
            var trace: [String] = []

            for round in 0..<FuzzConfig.rounds {
                let where_ = "\(label) round=\(round)"
                now = now.addingTimeInterval(60)
                var did: [String] = []

                // Other clients.
                let changes = Int(localRng.next() % UInt64(FuzzConfig.maxServerChangesPerRound + 1))
                for _ in 0..<changes {
                    let folder = Self.folders[Int(localRng.next() % 2)]
                    let ids = w.server.messageIds(inFolder: folder).sorted().filter { openReads[$0] == nil }
                    switch localRng.next() % 6 {
                    case 0:
                        let id = "new-fz\(nextId)"
                        nextId += 1
                        w.server.deliver(Reader.seed(id, in: folder, daysAgo: Double(localRng.next() % 3)))
                        arrivedAfterBaseline[folder, default: []].insert(id)
                        did.append("deliver \(id) to \(folder)")
                    case 1:
                        if let id = Self.pick(ids, &localRng) {
                            let read = w.server.snapshot(providerMessageId: id)?.isRead ?? false
                            w.server.setReadFromOtherClient(providerMessageId: id, isRead: !read)
                            did.append("read \(id)=\(!read)")
                        }
                    case 2:
                        if let id = Self.pick(ids, &localRng) {
                            let flagged = w.server.snapshot(providerMessageId: id)?.isFlagged ?? false
                            w.server.setFlagFromOtherClient(providerMessageId: id, isFlagged: !flagged)
                            did.append("flag \(id)=\(!flagged)")
                            // A flag record carries the message's date, so a message the
                            // phone does not hold gets its headers and appears, whatever
                            // its age (a read-only record carries no date and inserts nothing).
                            arrivedAfterBaseline[folder, default: []].insert(id)
                        }
                    case 3:
                        if let id = Self.pick(ids, &localRng) {
                            w.server.deleteFromOtherClient(providerMessageId: id)
                            did.append("delete \(id)")
                        }
                    default:
                        let destination = folder == Reader.inbox ? Reader.archive : Reader.inbox
                        if let id = Self.pick(ids, &localRng),
                           let moved = w.server.moveFromOtherClient(providerMessageId: id, to: destination) {
                            arrivedAfterBaseline[destination, default: []].insert(moved)
                            did.append("move \(id) to \(destination) as \(moved)")
                        }
                    }
                }
                for folder in Self.folders { everIn[folder, default: []].formUnion(w.server.messageIds(inFolder: folder)) }

                // The user reads a message the phone holds; an earlier read may complete.
                for (id, open) in openReads where Int(localRng.next() % 100) < FuzzConfig.completePercent {
                    w.server.setReadFromOtherClient(providerMessageId: id, isRead: true)
                    try await w.pool.write { db in _ = try PendingOperation.deleteOne(db, key: open.opId) }
                    openReads[id] = nil
                    did.append("queued read on \(id) completes")
                }
                if Int(localRng.next() % 100) < FuzzConfig.pendingReadPercent {
                    let folder = Self.folders[Int(localRng.next() % 2)]
                    let held = try w.rowIds(in: folder).sorted().filter {
                        openReads[$0] == nil && w.server.snapshot(providerMessageId: $0)?.folderId == folder
                    }
                    if let id = Self.pick(held, &localRng) {
                        try await w.pool.write { db in
                            _ = try MessageHeader.filter(Column("folderId") == w.folderId(folder) && Column("messageId") == id)
                                .updateAll(db, Column("isRead").set(to: true))
                        }
                        let op = PendingOperation(type: .markRead, messageIds: [id], accountId: w.accountId, folderPath: folder)
                        try await w.pool.write { db in
                            var row = op
                            try row.insert(db)
                        }
                        openReads[id] = (op.id, folder)
                        did.append("user reads \(id)")
                    }
                }

                // Chaos for this read.
                w.server.setDeltaPageLatency(Double(localRng.next() % UInt64(FuzzConfig.latencyMaxMilliseconds + 1)) / 1000)
                w.server.setBatchLatency(Double(localRng.next() % UInt64(FuzzConfig.latencyMaxMilliseconds + 1)) / 1000)
                if Int(localRng.next() % 100) < FuzzConfig.faultPercent {
                    let faults: [FakeHTTP.CannedResponse] = [.status(500), .status(429), .status(503), .transportError(.networkConnectionLost)]
                    let fault = faults[Int(localRng.next() % UInt64(faults.count))]
                    if localRng.next() % 2 == 0 { w.server.failDeltaPages([fault]) } else { w.server.failBatches([fault]) }
                    did.append("fault \(fault)")
                }
                w.server.clearBatchItemAnswers()
                if Int(localRng.next() % 100) < FuzzConfig.faultPercent,
                   let id = Self.pick(arrivedAfterBaseline.values.flatMap { $0 }.sorted(), &localRng) {
                    let status = localRng.next() % 2 == 0 ? 503 : 400
                    w.server.answerBatchItem(providerMessageId: id, status: status, body: nil)
                    did.append("item \(id) answers \(status)")
                }
                let requests: Int? = Int(localRng.next() % 100) < FuzzConfig.budgetCutPercent
                    ? 1 + Int(localRng.next() % UInt64(FuzzConfig.budgetCutMaxRequests)) : nil
                let expensive = localRng.next() % 5 == 0

                let driver = Int(localRng.next() % 100)
                if driver < FuzzConfig.foregroundPassPercent {
                    for folder in Self.folders { listable[folder, default: []].formUnion(w.server.messageIds(inFolder: folder)) }
                    // A pass the faults made fail is an outcome, not a finding: the
                    // invariants below judge what it left.
                    do { try await w.foregroundPass(); did.append("foreground pass") } catch { did.append("foreground pass failed: \(error)") }
                } else if driver < FuzzConfig.foregroundPassPercent + FuzzConfig.enginePassPercent {
                    do { try await w.delta(); did.append("change pass") } catch { did.append("change pass failed: \(error)") }
                } else {
                    try await w.read(now: now, requests: requests, expensive: expensive)
                    did.append("read requests=\(requests.map(String.init) ?? "all") expensive=\(expensive)")
                }
                let differs = try Self.differences(w).joined(separator: ", ")
                trace.append("round \(round): \(did.joined(separator: "; ")); differs: \(differs)")

                if try !Self.checkInvariants(w, openReads: openReads, everIn: everIn, where: where_) {
                    Issue.record("[\(where_)] schedule:\n\(trace.joined(separator: "\n"))")
                    failed = true
                    return
                }
            }

            // Quiescence: every queued read completes, faults clear, reads until settled.
            for (id, open) in openReads {
                w.server.setReadFromOtherClient(providerMessageId: id, isRead: true)
                try await w.pool.write { db in _ = try PendingOperation.deleteOne(db, key: open.opId) }
            }
            w.server.clearBatchItemAnswers()
            w.server.setDeltaPageLatency(0)
            w.server.setBatchLatency(0)
            w.server.state.value.withLock { $0.delta.pageFailures = []; $0.delta.batchFailures = [] }
            for _ in 0..<FuzzConfig.quiescenceReads {
                now = now.addingTimeInterval(60)
                try await w.read(now: now)
                let differs = try Self.differences(w).joined(separator: ", ")
                trace.append("quiescence read; differs: \(differs)")
                let settled = try Self.folders.allSatisfy { folder in
                    try w.cursor(folder)?.phase == .tracking && w.recheck(folder).isEmpty
                }
                if settled { break }
            }
            if try !Self.checkConvergence(
                w, arrivedAfterBaseline: arrivedAfterBaseline, listable: listable, where: "\(label) quiescence") {
                Issue.record("[\(label)] schedule:\n\(trace.joined(separator: "\n"))")
                failed = true
            }
        }
        rng = localRng
        return failed
    }

    // MARK: - Invariants

    private static func checkInvariants(
        _ w: Reader.World, openReads: [String: (opId: String, folder: String)], everIn: [String: Set<String>], where: String
    ) throws -> Bool {
        var ok = true
        // 1. Ledger.
        let queued = Set(try w.pool.read { db in
            try PendingOperation.filter(Column("accountId") == w.accountId).fetchAll(db).map(\.id)
        })
        for (id, open) in openReads {
            if !queued.contains(open.opId) {
                Issue.record("[\(`where`)] the queued read on \(id) was dropped"); ok = false
            }
            if let row = try w.row(id, in: open.folder), !row.isRead {
                Issue.record("[\(`where`)] \(id) shows unread while the user's read is queued"); ok = false
            }
        }
        // 2. No wrong-folder row.
        for folder in folders {
            for id in try w.rowIds(in: folder) where !(everIn[folder] ?? []).contains(id) {
                Issue.record("[\(`where`)] row \(id) is in \(folder), where the server never held it"); ok = false
            }
        }
        return ok
    }

    /// 3. Each folder's rows and flags equal what the server holds and the phone keeps.
    private static func checkConvergence(
        _ w: Reader.World, arrivedAfterBaseline: [String: Set<String>], listable: [String: Set<String>], where: String
    ) throws -> Bool {
        var ok = true
        let server = w.server.state.value.withLock { Array($0.messagesByProviderId.values) }
        for folder in folders {
            let heldSince = try #require(try w.folder(folder).oldestSyncedDate)
            if try w.cursor(folder)?.phase != .tracking || !w.recheck(folder).isEmpty {
                Issue.record("[\(`where`)] \(folder) did not settle"); ok = false
            }
            let inFolder = server.filter { $0.folderId == folder }
            let expected = Set(inFolder.filter {
                $0.receivedAt >= heldSince || (arrivedAfterBaseline[folder] ?? []).contains($0.providerMessageId)
            }.map(\.providerMessageId))
            let local = try w.rowIds(in: folder)
            let listed = (listable[folder] ?? []).intersection(inFolder.map(\.providerMessageId))
            let missing = expected.subtracting(local)
            let extra = local.subtracting(expected).subtracting(listed)
            if !missing.isEmpty || !extra.isEmpty {
                Issue.record("[\(`where`)] \(folder) rows: missing \(missing.sorted()), extra \(extra.sorted())")
                ok = false
            }
            for message in inFolder where local.contains(message.providerMessageId) {
                guard let row = try w.row(message.providerMessageId, in: folder) else { continue }
                if row.isRead != message.isRead || row.isFlagged != message.isFlagged {
                    Issue.record("[\(`where`)] \(folder) \(message.providerMessageId) read=\(row.isRead) flagged=\(row.isFlagged) != server read=\(message.isRead) flagged=\(message.isFlagged)")
                    ok = false
                }
            }
        }
        return ok
    }

    /// Rows whose read or flag state differs from the server's, for the trace.
    private static func differences(_ w: Reader.World) throws -> [String] {
        let server = w.server.state.value.withLock { $0.messagesByProviderId }
        var out: [String] = []
        for folder in folders {
            for id in try w.rowIds(in: folder).sorted() {
                guard let row = try w.row(id, in: folder), let message = server[id], message.folderId == folder else { continue }
                if row.isRead != message.isRead || row.isFlagged != message.isFlagged {
                    out.append("\(id) local r=\(row.isRead) f=\(row.isFlagged) server r=\(message.isRead) f=\(message.isFlagged)")
                }
            }
        }
        return out
    }

    private static func pick(_ ids: [String], _ rng: inout SplitMix64) -> String? {
        guard !ids.isEmpty else { return nil }
        return ids[Int(rng.next() % UInt64(ids.count))]
    }
}
