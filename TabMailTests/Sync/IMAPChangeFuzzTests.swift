/* This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at https://mozilla.org/MPL/2.0/. */

import Foundation
import Testing
@testable import TabMail

/// Seeded fuzzer for the IMAP change reader (Testing Rule 11): the real
/// `IMAPProvider.fetchChanges` against `FakeIMAPServer`'s QRESYNC model, and its
/// CONDSTORE model without QRESYNC (#755: expunges that leave HIGHESTMODSEQ
/// unchanged, injected `UID SEARCH` failures, and budgets that stop the removal
/// check part-way, so it resumes on later reads), with
/// another client changing the mailbox between reads (flags, `\Deleted` and
/// un-deleting, expunges, arrivals), seeded per-command latency, injected SELECT failures and
/// cut budgets. The device side is a mirror applied from what the reader reports.
///
/// Invariants, checked after every read:
/// - I1 a removal never names a message the server still shows (never-drop);
/// - I2 a record names a message the server holds, with the server's flags (no
///   wrong-message state);
/// - I3 after a quiet read with no faults, the mirror equals the server: every
///   shown message held with its flags, nothing else held (convergence).
/// Plus the wire oracle: no wrong-message violation, ENABLE once per connection.
///
/// Knobs (`TEST_RUNNER_` prefix on the CLI): `IMAP_CHANGE_FUZZ_ITERATIONS` and
/// `IMAP_CHANGE_FUZZ_SEED` (`0x…` or decimal). A failure names its seed and
/// iteration; replay with that seed and `ITERATIONS` set to the iteration plus one.
@Suite("IMAP change reader fuzzer", .serialized, .processGlobalState)
struct IMAPChangeFuzzTests {
    typealias R = IMAPChangeReaderTests

    enum FuzzConfig {
        static let defaultIterations = 6
        static let defaultSeed: UInt64 = 0x0751_C0DE_0000_0001
        static var iterations: Int {
            if let raw = ProcessInfo.processInfo.environment["IMAP_CHANGE_FUZZ_ITERATIONS"], let v = Int(raw), v > 0 { return v }
            return defaultIterations
        }
        static var seed: UInt64 {
            guard let raw = ProcessInfo.processInfo.environment["IMAP_CHANGE_FUZZ_SEED"] else { return defaultSeed }
            if raw.hasPrefix("0x") || raw.hasPrefix("0X") { return UInt64(raw.dropFirst(2), radix: 16) ?? defaultSeed }
            return UInt64(raw) ?? defaultSeed
        }
        static let initialMessages = 8
        static let rounds = 8
        static let maxChangesPerRound = 5
        static let faultPercent = 20
        static let budgetCutPercent = 15
        static let latencyMaxMilliseconds = 5
    }

    /// The device's view of the inbox: held UIDs and their two flags.
    struct Mirror {
        var held: [Int: (read: Bool, flagged: Bool)] = [:]
        var cursor: String?
    }

    static func shown(_ server: FakeIMAPServer) -> [Int: (read: Bool, flagged: Bool)] {
        var out: [Int: (read: Bool, flagged: Bool)] = [:]
        for message in server.messages(in: R.inboxPath) {
            let flags = server.flags(in: R.inboxPath, uid: message.uid)
            guard !flags.contains("\\Deleted") else { continue }
            out[message.uid] = (flags.contains("\\Seen"), flags.contains("\\Flagged"))
        }
        return out
    }

    /// The server's change-reading capability.
    enum Mode: String, CaseIterable, Sendable, CustomStringConvertible {
        case qresync, condstore
        var description: String { rawValue }
    }

    static func withWorld(_ mode: Mode, inbox: [Int], _ body: (R.World) async throws -> Void) async throws {
        switch mode {
        case .qresync: try await R.withWorld(inbox: inbox, body)
        case .condstore: try await IMAPChangeCondstoreTests.withWorld(inbox: inbox, body)
        }
    }

    @Test("Seeded schedules never remove a shown message, never write wrong state, and converge", arguments: Mode.allCases)
    func fuzz(_ mode: Mode) async throws {
        let base = FuzzConfig.seed
        for iteration in 0..<FuzzConfig.iterations {
            var rng = SplitMix64(seed: base &+ UInt64(iteration))
            let label = "\(mode) seed=0x\(String(base, radix: 16)) iteration=\(iteration)"
            try await Self.withWorld(mode, inbox: Array(1...FuzzConfig.initialMessages)) { w in
                w.server.setSeededLatencyInjection(seed: base &+ UInt64(iteration) &* 31, maxMilliseconds: FuzzConfig.latencyMaxMilliseconds)
                var mirror = Mirror()
                for (uid, flags) in Self.shown(w.server) { mirror.held[uid] = flags }
                var nextUid = FuzzConfig.initialMessages + 1

                for round in 0..<FuzzConfig.rounds {
                    // Another client changes the mailbox.
                    for _ in 0..<rng.pick(FuzzConfig.maxChangesPerRound + 1) {
                        var uids = w.server.messages(in: R.inboxPath).map(\.uid)
                        let deleted = uids.filter { w.server.flags(in: R.inboxPath, uid: $0).contains("\\Deleted") }
                        switch rng.pick(6) {
                        case 5 where !deleted.isEmpty:
                            // Un-deleted elsewhere: it is shown again and must come back.
                            let uid = deleted[rng.pick(deleted.count)]
                            var flags = w.server.flags(in: R.inboxPath, uid: uid)
                            flags.remove("\\Deleted")
                            w.server.setFlags(flags, in: R.inboxPath, uid: uid)
                        case 0 where !uids.isEmpty:
                            let uid = uids[rng.pick(uids.count)]
                            var flags = w.server.flags(in: R.inboxPath, uid: uid)
                            if flags.contains("\\Seen") { flags.remove("\\Seen") } else { flags.insert("\\Seen") }
                            w.server.setFlags(flags, in: R.inboxPath, uid: uid)
                        case 1 where !uids.isEmpty:
                            let uid = uids[rng.pick(uids.count)]
                            var flags = w.server.flags(in: R.inboxPath, uid: uid)
                            if flags.contains("\\Flagged") { flags.remove("\\Flagged") } else { flags.insert("\\Flagged") }
                            w.server.setFlags(flags, in: R.inboxPath, uid: uid)
                        case 2 where !uids.isEmpty:
                            let uid = uids[rng.pick(uids.count)]
                            var flags = w.server.flags(in: R.inboxPath, uid: uid)
                            flags.insert("\\Deleted")
                            w.server.setFlags(flags, in: R.inboxPath, uid: uid)
                        case 3 where !uids.isEmpty:
                            uids.remove(at: rng.pick(uids.count))
                            w.server.setMessages(uids.map(R.message), in: R.inboxPath)
                        default:
                            uids.append(nextUid)
                            nextUid += 1
                            w.server.setMessages(uids.map(R.message), in: R.inboxPath)
                        }
                    }
                    let fault = rng.pick(100) < FuzzConfig.faultPercent
                    let cut = rng.pick(100) < FuzzConfig.budgetCutPercent
                    if fault {
                        // CONDSTORE: half the faults hit the removal check's SEARCH.
                        let searchFault = mode == .condstore && rng.pick(2) == 0
                        w.server.failNextCommand(containing: searchFault ? "UID SEARCH" : "SELECT")
                    }
                    // CONDSTORE: a cut is a budget the removal check runs out of
                    // part-way (one to four SEARCH steps), not a pass that never starts.
                    let budget: ChangeContext? = cut && mode == .condstore
                        ? IMAPChangeCondstoreCheckTests.searchBudget(
                            w, seconds: SyncConfig.changeReadRequestTimeoutSeconds * Double(3 + rng.pick(4)))
                        : nil
                    try await Self.readAndApply(w, &mirror, mode: mode, cut: cut, budget: budget, label: "\(label) round=\(round)")
                }

                // Quiescence: reads with no faults until the mirror converges.
                for quiet in 0..<3 {
                    try await Self.readAndApply(w, &mirror, mode: mode, cut: false, budget: nil, label: "\(label) quiet=\(quiet)")
                }
                let server = Self.shown(w.server)
                #expect(Set(mirror.held.keys) == Set(server.keys), "I3 held set converges, \(label)")
                for (uid, flags) in server {
                    #expect(mirror.held[uid]?.read == flags.read && mirror.held[uid]?.flagged == flags.flagged,
                            "I3 flags converge for \(uid), \(label)")
                }
                if mode == .qresync {
                    #expect(w.server.enableQResyncCountByConnection.values.allSatisfy { $0 == 1 }, "ENABLE once per connection, \(label)")
                } else {
                    #expect(w.server.enableQResyncCountByConnection.isEmpty, "no ENABLE QRESYNC on a CONDSTORE server, \(label)")
                }
            }
        }
    }

    /// One read of the inbox, checked (I1, I2) and applied to the mirror.
    static func readAndApply(
        _ w: R.World, _ mirror: inout Mirror, mode: Mode, cut: Bool, budget: ChangeContext?, label: String
    ) async throws {
        w.local.set(w.inboxId, Array(mirror.held.keys))
        let context = budget ?? (cut
            ? ChangeContext(deadline: Date.distantPast, onProgress: { _ in })
            : ChangeContext(onProgress: { _ in }))
        let set = try await R.read(w, cursors: [w.inboxId: mirror.cursor], context: context)
        let changes = try R.inbox(w, set)
        let server = shown(w.server)
        let present = Set(w.server.messages(in: R.inboxPath).map(\.uid))

        for removal in changes.removals {
            let uid = try #require(Int(removal))
            #expect(server[uid] == nil, "I1 removal of shown message \(uid), \(label)")
            mirror.held.removeValue(forKey: uid)
        }
        for record in changes.records {
            let uid = try #require(Int(record.messageId))
            #expect(present.contains(uid), "I2 record for a message the server lacks \(uid), \(label)")
            let flags = w.server.flags(in: R.inboxPath, uid: uid)
            if let read = record.isRead { #expect(read == flags.contains("\\Seen"), "I2 read state of \(uid), \(label)") }
            if let flagged = record.isFlagged { #expect(flagged == flags.contains("\\Flagged"), "I2 flag of \(uid), \(label)") }
            if mirror.held[uid] != nil {
                mirror.held[uid] = (record.isRead ?? mirror.held[uid]!.read, record.isFlagged ?? mirror.held[uid]!.flagged)
            } else if record.header != nil, let read = record.isRead, let flagged = record.isFlagged {
                mirror.held[uid] = (read, flagged)
            }
        }
        switch changes.status {
        case .tracked:
            if let cursor = changes.cursor { mirror.cursor = cursor }
        case .baselineReady:
            // The engine lists the folder in the same pass, then commits the bookmark.
            mirror.cursor = changes.cursor
            mirror.held = server
        case .refused:
            // The engine lists the folder again and starts a new bookmark.
            mirror.cursor = nil
            mirror.held = server
        case .failed:
            if let cursor = changes.cursor { mirror.cursor = cursor }
        case .untracked(let observation):
            // CONDSTORE: a removal check cut by the budget. The engine lists the
            // folder the same pass and keeps the bookmark with the check's progress.
            guard mode == .condstore, observation.mustList else {
                Issue.record("an inbox the server tracks reported untracked (\(mode)), \(label)"); return
            }
            mirror.cursor = changes.cursor ?? mirror.cursor
            mirror.held = server
        case .notRun, .baselining:
            break
        }
    }
}
