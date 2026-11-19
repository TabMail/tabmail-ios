/* This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at https://mozilla.org/MPL/2.0/. */

import Foundation
import GRDB
import Synchronization
import Testing
@testable import TabMail

/// A message a change read proved gone never comes back from a header another
/// path read before that proof (#755), and a standalone folder listing never
/// runs between a change read and its apply (the account's sync turn). Driven
/// through the engine's own entry points against `FakeIMAPServer`, with a
/// command held on the wire to place each race deterministically.
@Suite("IMAP change reads: the turn and the from-server insert guard", .serialized, .processGlobalState)
struct IMAPChangeTurnAndGuardTests {
    typealias E = IMAPChangeEngineTests
    typealias C = IMAPChangeCondstoreTests

    /// How long a held race may take to show its first step; a bound, never a sleep.
    static let raceBoundSeconds: TimeInterval = 10
    /// How long a waiter is watched for NOT starting while the turn is held.
    static let quietWatchSeconds: TimeInterval = 1

    final class Done: Sendable { let flag = Mutex(false) }

    static func waitUntil(_ condition: () -> Bool) async throws {
        let deadline = Date().addingTimeInterval(raceBoundSeconds)
        while !condition() {
            guard Date() < deadline else { Issue.record("the race's step never happened"); return }
            try await Task.sleep(nanoseconds: 10_000_000)
        }
    }

    @Test("T15: load older holds a page whose message a change read proves gone meanwhile: the message is not re-created, and the call reports more to load")
    func loadOlderNeverRecreatesAProvenGoneMessage() async throws {
        try await E.withWorld("cs-t15", capabilities: C.condstore, serverUIDs: Array(1...6), localUIDs: [4, 5, 6]) { w in
            w.server.honorSearchUIDSetCriterion()
            w.server.setExpungeKeepsHighestModSeq(true, for: E.path)
            _ = try await w.engine.performDeltaSync(account: w.account, provider: w.provider)
            _ = try await w.engine.performDeltaSync(account: w.account, provider: w.provider)
            let folder = try w.folder()
            w.server.holdNextFetchAfterSnapshot(in: E.path)
            let older = Task { try await w.engine.fetchOlderMessages(folders: [folder]) }
            try await Self.waitUntil { w.server.isHoldingFetchAfterSnapshot(in: E.path) }
            // Expunged elsewhere while the page's answer is held; the change read
            // commits a new bookmark for the folder.
            C.remove([2], from: w.server, E.path)
            _ = try await w.engine.performDeltaSync(account: w.account, provider: w.provider)
            w.server.releaseFetchAfterSnapshot(in: E.path)
            let result = try await older.value
            #expect(!(try w.uids()).contains("2"), "a message proven gone is not re-created")
            #expect(result.mayHaveMore, "the refused page is asked again: never 'no older mail'")
            // Converges: the next call loads the live older messages and no ghost.
            _ = try await w.engine.fetchOlderMessages(folders: [try w.folder()])
            let rows = try w.uids()
            #expect(rows.contains("1") && rows.contains("3") && !rows.contains("2"), "rows: \(rows.sorted())")
        }
    }

    @Test("T16: a standalone folder listing started while a change pass reads waits for that pass's turn, and both complete")
    func standaloneListingWaitsForTheChangePass() async throws {
        try await E.withWorld("cs-t16", capabilities: C.qresync, serverUIDs: [1, 2, 3], localUIDs: [1, 2, 3]) { w in
            w.server.honorSearchUIDSetCriterion()
            _ = try await w.engine.performDeltaSync(account: w.account, provider: w.provider)
            _ = try await w.engine.performDeltaSync(account: w.account, provider: w.provider)
            w.server.setFlags(["\\Seen"], in: E.path, uid: 1)
            w.server.holdNextCommand(containing: "(QRESYNC (")
            let pass = Task { try await w.engine.performDeltaSync(account: w.account, provider: w.provider) }
            try await Self.waitUntil { w.server.isHoldingCommand(containing: "(QRESYNC (") }
            let start = w.server.recordedCommands().count
            let folder = try w.folder()
            let listing = Task { try await w.engine.syncFolderMessages(folder: folder, provider: w.provider) }
            try await Task.sleep(nanoseconds: UInt64(Self.quietWatchSeconds * 1_000_000_000))
            let duringRead = w.server.recordedCommands().dropFirst(start).filter { $0.uppercased().contains("FETCH") }
            #expect(duringRead.isEmpty, "no listing ran between the change read and its apply: \(Array(duringRead))")
            w.server.releaseHeldCommand(containing: "(QRESYNC (")
            _ = try await pass.value
            _ = try await listing.value
            #expect(try w.uids() == ["1", "2", "3"])
        }
    }

    @Test("T17: a folder listing started by a task that holds the account's turn runs in that turn (re-entrant), never deadlocks")
    func nestedListingInsideTheTurnCompletes() async throws {
        try await E.withWorld("cs-t17", capabilities: C.condstore, serverUIDs: [1, 2, 3], localUIDs: [1, 2]) { w in
            let folder = try w.folder()
            let done = Done()
            // Never awaited: a deadlock must fail the test, not hang the suite.
            Task {
                _ = try? await w.engine.oneSyncAtATime(accountId: w.account.id) {
                    try await w.engine.syncFolderMessages(folder: folder, provider: w.provider)
                }
                done.flag.withLock { $0 = true }
            }
            try await Self.waitUntil { done.flag.withLock { $0 } }
            #expect(try w.uids().contains("3"), "the nested listing ran and loaded the new message")
        }
    }
}
