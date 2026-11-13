/* This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at https://mozilla.org/MPL/2.0/. */

import Foundation
import GRDB
import Synchronization
import Testing
@testable import TabMail

/// Seeded fuzz of the generic change apply (root testing rule 11) against a
/// mock reader that reports a model mailbox. Each seed interleaves other-client
/// changes, the user's queued ops (added and drained, some DURING a read) and
/// recent completions. Invariants, checked continuously:
/// - a row whose message has a queued op for the whole pass is never removed by it;
/// - a message whose op completes during a read is not inserted by that pass;
/// - after quiescence (no op, no completion) every message the reader ever
///   reported matches the model: membership and flags.
@Suite("Change apply: seeded fuzz", .serialized, .processGlobalState)
struct ChangeApplyFuzzTests {
    static let seeds: [UInt64] = [1, 2, 3, 5, 8, 13, 21, 34]
    static let messageCount = 12
    static let steps = 14

    struct RNG: RandomNumberGenerator {
        var state: UInt64
        mutating func next() -> UInt64 {
            state &+= 0x9E37_79B9_7F4A_7C15
            var z = state
            z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
            z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
            return z ^ (z >> 31)
        }
    }

    struct ModelMessage: Sendable { var folders: Set<String>; var isRead: Bool; var isFlagged: Bool }

    final class Model: Sendable {
        let messages: Mutex<[String: ModelMessage]>
        let unreported = Mutex<Set<String>>([])
        let everReported = Mutex<Set<String>>([])
        /// A completion to record while the next read runs.
        let completeDuringRead = Mutex<String?>(nil)
        init(_ messages: [String: ModelMessage]) { self.messages = Mutex(messages) }
    }

    static func info(_ id: String, _ m: ModelMessage) -> MessageHeaderInfo {
        MessageHeaderInfo(
            messageId: id, rfc822MessageId: "\(id)-fuzz@example.com", inReplyTo: nil, references: [],
            threadId: nil, subject: "fuzz \(id)", from: "Sender", fromAddress: "sender@example.com",
            to: "recipient@example.com", cc: "", bcc: "", replyTo: nil,
            date: Date().addingTimeInterval(-86_400), snippet: "fuzz", isRead: m.isRead, isFlagged: m.isFlagged,
            hasAttachments: false, isReplied: false, isForwarded: false, actionTag: nil)
    }

    @Test("The apply keeps queued intentions, honours completions during a read, and converges", arguments: seeds)
    func fuzz(seed: UInt64) async throws {
        try await ChangeApplyTests.withWorld { w in
            var rng = RNG(state: seed)
            let paths = ["INBOX", "Archive"]
            var initial: [String: ModelMessage] = [:]
            for index in 0..<Self.messageCount {
                let id = "fz\(index)"
                initial[id] = ModelMessage(folders: [paths[index % 2]], isRead: false, isFlagged: false)
            }
            for (id, message) in initial {
                for path in message.folders { try w.insertRow(id, in: "\(w.accountId):\(path)", path: path) }
            }
            let model = Model(initial)
            let accountId = w.accountId

            await w.mock.setChangeReader { _, request in
                if let id = model.completeDuringRead.withLock({ value in defer { value = nil }; return value }) {
                    await AccountManager.shared.recordRecentlyCompleted(messageIds: [id])
                }
                let ids = model.unreported.withLock { set in defer { set.removeAll() }; return set }
                    .union(request.recheck.values.flatMap { $0 })
                model.everReported.withLock { $0.formUnion(ids) }
                let snapshot = model.messages.withLock { $0 }
                return ChangeSet(account: .set("c"), folderList: nil, folders: request.folders.map { folder in
                    var changes = FolderChanges(folderId: folder.id, status: .tracked)
                    for id in ids.sorted() {
                        guard let message = snapshot[id] else { continue }
                        if message.folders.contains(folder.path) {
                            changes.records.append(ChangeRecord(header: Self.info(id, message)))
                        } else {
                            changes.removals.append(id)
                        }
                    }
                    return changes
                })
            }

            var queued: [String: PendingOperation] = [:]
            for _ in 0..<Self.steps {
                // Another client changes a message.
                let id = "fz\(Int.random(in: 0..<Self.messageCount, using: &rng))"
                model.messages.withLock { messages in
                    switch Int.random(in: 0..<3, using: &rng) {
                    case 0: messages[id]?.isRead.toggle()
                    case 1: messages[id]?.isFlagged.toggle()
                    default: messages[id]?.folders = [paths.randomElement(using: &rng)!]
                    }
                }
                model.unreported.withLock { _ = $0.insert(id) }

                // The user queues or drains an op; sometimes an op completes during the read.
                let target = "fz\(Int.random(in: 0..<Self.messageCount, using: &rng))"
                switch Int.random(in: 0..<4, using: &rng) {
                case 0 where queued[target] == nil:
                    let op = try await w.pool.write { db in
                        var op = PendingOperation(type: .markRead, messageIds: [target], accountId: accountId, folderPath: "INBOX")
                        try op.insert(db)
                        return op
                    }
                    queued[target] = op
                case 1:
                    if let entry = queued.first {
                        let opId = entry.value.id
                        try await w.pool.write { db in _ = try PendingOperation.deleteOne(db, key: opId) }
                        queued[entry.key] = nil
                    }
                case 2:
                    model.completeDuringRead.withLock { $0 = target }
                    model.unreported.withLock { _ = $0.insert(target) }
                default:
                    break
                }

                let queuedIds = Set(queued.keys)
                let protectedRows = try await w.pool.read { db in
                    try MessageHeader.filter(Column("accountId") == accountId).fetchAll(db)
                        .filter { queuedIds.contains($0.messageId) }.map(\.id)
                }
                let completing = model.completeDuringRead.withLock { $0 }
                let rowsBefore = try await w.pool.read { db in
                    Set(try MessageHeader.filter(Column("accountId") == accountId).fetchAll(db).map(\.id))
                }
                try await w.pass()
                let rowsAfter = try await w.pool.read { db in
                    Set(try MessageHeader.filter(Column("accountId") == accountId).fetchAll(db).map(\.id))
                }
                for row in protectedRows {
                    #expect(rowsAfter.contains(row), "seed \(seed): a row with a queued op was removed: \(row)")
                }
                if let completing {
                    let inserted = rowsAfter.subtracting(rowsBefore).filter { $0.hasSuffix(":\(completing)") }
                    #expect(inserted.isEmpty, "seed \(seed): a message completing during the read was inserted: \(inserted)")
                }
            }

            // Quiescence: no op, no completion, two passes.
            try await w.pool.write { db in _ = try PendingOperation.deleteAll(db) }
            await AccountManager.shared.clearRecentlyCompletedForTesting()
            try await w.pass()
            try await w.pass()

            let reported = model.everReported.withLock { $0 }
            let final = model.messages.withLock { $0 }
            for id in reported.sorted() {
                guard let message = final[id] else { continue }
                for path in paths {
                    let row = try w.row(id, in: "\(accountId):\(path)")
                    #expect((row != nil) == message.folders.contains(path), "seed \(seed): \(id) in \(path)")
                    if let row {
                        #expect(row.isRead == message.isRead && row.isFlagged == message.isFlagged, "seed \(seed): \(id) flags")
                    }
                }
            }
        }
    }
}
