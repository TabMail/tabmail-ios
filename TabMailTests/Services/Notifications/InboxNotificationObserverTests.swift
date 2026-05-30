/* This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at https://mozilla.org/MPL/2.0/. */

import Testing
import GRDB
import Synchronization
@testable import TabMail

@Suite(.serialized)
struct InboxNotificationObserverTests {

    // MARK: - Helpers

    /// Thread-safe recorder for clear(accountId:messageId:) calls.
    private final class ClearRecorder: @unchecked Sendable {
        private let lock = Mutex<[(String, String)]>([])
        var calls: [(String, String)] { lock.withLock { $0 } }
        func record(_ acct: String, _ mid: String) { lock.withLock { $0.append((acct, mid)) } }
    }

    /// Make a migrated in-memory queue with the observer pre-seeded + wired in
    /// against a default account/inbox folder.
    /// Returns the observer too — caller MUST bind it (e.g. `let (q, rec, _obs) = …`).
    /// GRDB holds observers weakly at `.observerLifetime`; if the observer's only
    /// strong ref goes out of scope, events stop firing silently.
    private static func makeWired() throws -> (DatabaseQueue, ClearRecorder, InboxNotificationObserver) {
        let queue = try TestDatabase.make()
        try TestDatabase.insertAccount(queue, id: "acc1")
        try TestDatabase.insertFolder(queue, name: "INBOX", path: "INBOX", role: .inbox, accountId: "acc1")
        let rec = ClearRecorder()
        let observer = InboxNotificationObserver(clear: { acct, mid in rec.record(acct, mid) })
        try queue.write { db in
            try observer.seed(db)
            db.add(transactionObserver: observer)
        }
        return (queue, rec, observer)
    }

    // MARK: - Steady state

    @Test func updateFlippingIsInInboxFalse_firesClear() async throws {
        let (q, rec, _observer) = try Self.makeWired()
        _ = _observer  // observer's lifetime is load-bearing — notifications stop if it deinits
        try TestDatabase.insertFolder(q, name: "Archive", path: "Archive", role: .archive, accountId: "acc1")
        try TestDatabase.insertMessageHeader(q, messageId: "1", folderId: "acc1:INBOX",
                                             accountId: "acc1", folderPath: "INBOX", isInInbox: true)
        try await q.write { db in
            try db.execute(sql: "UPDATE messageHeader SET isInInbox = 0, folderId = 'acc1:Archive', folderPath = 'Archive' WHERE messageId = '1'")
        }
        #expect(rec.calls.count == 1)
        guard rec.calls.count == 1 else { return }
        #expect(rec.calls[0].0 == "acc1")
        #expect(rec.calls[0].1 == "1")
    }

    @Test func deleteOfInboxRow_firesClear() async throws {
        let (q, rec, _observer) = try Self.makeWired()
        _ = _observer  // observer's lifetime is load-bearing — notifications stop if it deinits
        try TestDatabase.insertMessageHeader(q, messageId: "1", isInInbox: true)
        try await q.write { db in try db.execute(sql: "DELETE FROM messageHeader WHERE messageId = '1'") }
        #expect(rec.calls.count == 1)
    }

    @Test func deleteOfNonInboxRow_doesNotFire() async throws {
        let (q, rec, _observer) = try Self.makeWired()
        _ = _observer  // observer's lifetime is load-bearing — notifications stop if it deinits
        try TestDatabase.insertFolder(q, name: "Archive", path: "Archive", role: .archive, accountId: "acc1")
        try TestDatabase.insertMessageHeader(q, messageId: "9", folderId: "acc1:Archive",
                                             folderPath: "Archive", isInInbox: false)
        try await q.write { db in try db.execute(sql: "DELETE FROM messageHeader WHERE messageId = '9'") }
        #expect(rec.calls.isEmpty)
    }

    @Test func updateOnInboxRowKeepingIsInInboxTrue_doesNotFire() async throws {
        // Mimics markRead / markFlagged — touches the row but doesn't change isInInbox.
        let (q, rec, _observer) = try Self.makeWired()
        _ = _observer  // observer's lifetime is load-bearing — notifications stop if it deinits
        try TestDatabase.insertMessageHeader(q, messageId: "1", isInInbox: true)
        try await q.write { db in try db.execute(sql: "UPDATE messageHeader SET isRead = 1 WHERE messageId = '1'") }
        #expect(rec.calls.isEmpty)
    }

    @Test func insertWithIsInInboxTrue_doesNotFire() async throws {
        // New inbox arrival shouldn't fire — observer only fires on EXIT.
        let (q, rec, _observer) = try Self.makeWired()
        _ = _observer  // observer's lifetime is load-bearing — notifications stop if it deinits
        try TestDatabase.insertMessageHeader(q, messageId: "42", isInInbox: true)
        #expect(rec.calls.isEmpty)
    }

    @Test func batchUpdate_acrossManyRows_firesOncePerRowThatLeftInbox() async throws {
        let (q, rec, _observer) = try Self.makeWired()
        _ = _observer  // observer's lifetime is load-bearing — notifications stop if it deinits
        try TestDatabase.insertFolder(q, name: "Archive", path: "Archive", role: .archive, accountId: "acc1")
        for i in 0..<5 {
            try TestDatabase.insertMessageHeader(q, messageId: "\(i)", isInInbox: true)
        }
        try TestDatabase.insertMessageHeader(q, messageId: "99", folderId: "acc1:Archive",
                                             folderPath: "Archive", isInInbox: false)
        try await q.write { db in
            // optimisticMoveToFolder-style mass update.
            try db.execute(sql: "UPDATE messageHeader SET isInInbox = 0, folderId = 'acc1:Archive', folderPath = 'Archive' WHERE folderPath = 'INBOX'")
        }
        let mids = Set(rec.calls.map { $0.1 })
        #expect(mids == Set(["0", "1", "2", "3", "4"]))
    }

    @Test func rollback_doesNotFireAndDoesNotMutateMap() async throws {
        let (q, rec, _observer) = try Self.makeWired()
        _ = _observer  // observer's lifetime is load-bearing — notifications stop if it deinits
        try TestDatabase.insertMessageHeader(q, messageId: "1", isInInbox: true)
        struct Boom: Error {}
        do {
            try await q.write { db in
                try db.execute(sql: "UPDATE messageHeader SET isInInbox = 0 WHERE messageId = '1'")
                throw Boom()
            }
        } catch {}
        #expect(rec.calls.isEmpty)
        // Subsequent real exit still fires — map intact across rollback.
        try await q.write { db in try db.execute(sql: "UPDATE messageHeader SET isInInbox = 0 WHERE messageId = '1'") }
        #expect(rec.calls.count == 1)
    }

    @Test func multiAccount_isolation() async throws {
        let (q, rec, _observer) = try Self.makeWired()
        _ = _observer  // observer's lifetime is load-bearing — notifications stop if it deinits
        try TestDatabase.insertAccount(q, id: "acctB", email: "b@example.com")
        try TestDatabase.insertFolder(q, name: "INBOX", path: "INBOX", role: .inbox, accountId: "acctB")
        try TestDatabase.insertMessageHeader(q, messageId: "1", folderId: "acc1:INBOX", accountId: "acc1", isInInbox: true)
        try TestDatabase.insertMessageHeader(q, messageId: "1", folderId: "acctB:INBOX", accountId: "acctB", isInInbox: true)
        try await q.write { db in
            try db.execute(sql: "UPDATE messageHeader SET isInInbox = 0 WHERE accountId = 'acc1'")
        }
        #expect(rec.calls.count == 1)
        guard rec.calls.count == 1 else { return }
        #expect(rec.calls[0].0 == "acc1")
    }

    @Test func seedPicksUpExistingInboxRows_observerFiresOnTheirExit() async throws {
        // Insert BEFORE wiring observer — simulates app launch with pre-existing inbox state.
        let q = try TestDatabase.make()
        try TestDatabase.insertAccount(q, id: "acc1")
        try TestDatabase.insertFolder(q, name: "INBOX", path: "INBOX", role: .inbox, accountId: "acc1")
        try TestDatabase.insertMessageHeader(q, messageId: "1", isInInbox: true)
        let rec = ClearRecorder()
        let observer = InboxNotificationObserver(clear: { acct, mid in rec.record(acct, mid) })
        try await q.write { db in
            try observer.seed(db)
            db.add(transactionObserver: observer)
        }
        try await q.write { db in try db.execute(sql: "UPDATE messageHeader SET isInInbox = 0 WHERE messageId = '1'") }
        #expect(rec.calls.count == 1)
    }

    @Test func emptySeed_doesNotCrash() async throws {
        // Map starts empty when no rows have isInInbox=1.
        let q = try TestDatabase.make()
        try TestDatabase.insertAccount(q, id: "acc1")
        try TestDatabase.insertFolder(q, name: "Archive", path: "Archive", role: .archive, accountId: "acc1")
        let rec = ClearRecorder()
        let observer = InboxNotificationObserver(clear: { acct, mid in rec.record(acct, mid) })
        try await q.write { db in
            try observer.seed(db)
            db.add(transactionObserver: observer)
        }
        try TestDatabase.insertMessageHeader(q, messageId: "1", folderId: "acc1:Archive",
                                             folderPath: "Archive", isInInbox: false)
        try await q.write { db in try db.execute(sql: "DELETE FROM messageHeader WHERE messageId = '1'") }
        #expect(rec.calls.isEmpty)
    }

    @Test func updateChangingMessageIdOnInboxRow_clearsWithOriginalId() async throws {
        // Defensive — id swaps shouldn't happen in practice. When they do, the
        // observer clears using the messageId RECORDED IN THE MAP (i.e. the
        // value at the time the row entered inbox), not the post-commit value.
        // This matches notification-posting semantics: the notification id was
        // built from the original messageId, so that's the one we must clear.
        let (q, rec, _observer) = try Self.makeWired()
        _ = _observer  // observer's lifetime is load-bearing — notifications stop if it deinits
        try TestDatabase.insertMessageHeader(q, messageId: "1", isInInbox: true)
        try await q.write { db in
            try db.execute(sql: "UPDATE messageHeader SET messageId = '1-renamed' WHERE messageId = '1'")
            try db.execute(sql: "UPDATE messageHeader SET isInInbox = 0 WHERE messageId = '1-renamed'")
        }
        #expect(rec.calls.count == 1)
        guard rec.calls.count == 1 else { return }
        #expect(rec.calls[0].1 == "1")
    }
}
