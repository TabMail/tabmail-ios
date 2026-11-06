/* This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at https://mozilla.org/MPL/2.0/. */

import Foundation
import GRDB
import Testing
@testable import TabMail

/// ADR-IOS-103: a bubble's card opens today's detail of that email (N3).
///
/// THE SYSTEM PROPERTY pinned here: the card marks read only the email the bubble showed. On IMAP
/// a UIDVALIDITY reset can put a different email at the same address before the detail resolves
/// it; the card passes the bubble's Message-ID with the address, so the detail marks nothing read
/// then. The unchanged email is still marked read (the control).
///
/// The account is Gmail: the witness check is the same for every provider, and a Gmail read's queued
/// operation fails at once here, where an IMAP one would try to connect and hold the shared write
/// queue into the next suite.
///
/// `.serialized, .processGlobalState`: the harness swaps `AppDatabase.shared` and reads
/// `AccountManager.shared`'s write queue and intent-cycle register.
@Suite("Chat card opens the email the bubble showed", .serialized, .processGlobalState)
@MainActor
struct ChatCardIdentityTests {
    private static let account = "acc-chat-card"

    private func makeDB() throws -> (DatabasePool, Folder, URL, AppDatabase?) {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        var config = Configuration()
        config.foreignKeysEnabled = true
        let pool = try DatabasePool(path: dir.appendingPathComponent("test.sqlite").path, configuration: config)
        let appDb = try AppDatabase(dbPool: pool)
        let previous = AppDatabase.shared.withLock { current -> AppDatabase? in
            let prev = current; current = appDb; return prev
        }
        var inbox = Folder(name: "INBOX", path: "INBOX", role: .inbox, accountId: Self.account)
        inbox.lastKnownUidValidity = 11
        try pool.writeWithoutTransaction { db in
            var acc = Account(emailAddress: "user@example.com", displayName: "User", provider: .gmail)
            acc.id = Self.account
            try acc.insert(db)
            let folder = inbox
            try folder.insert(db)
        }
        return (pool, inbox, dir, previous)
    }

    private func header(rfc: String, inbox: Folder) -> MessageHeader {
        var h = MessageHeader(
            messageId: "4242", subject: "Plans", from: "Sender", fromAddress: "sender@example.com",
            to: "user@example.com", date: Date(), snippet: "", folderId: inbox.id,
            accountId: inbox.accountId, folderPath: inbox.path, isInInbox: true)
        h.rfc822MessageId = rfc
        h.headerComplete = true
        h.observedUidValidity = 11
        return h
    }

    private func intentCycles() -> [String] {
        AccountManager.shared.pendingIntentCyclesForTesting().keys.filter { $0.hasPrefix("\(Self.account):") }
    }

    private func clearShared() {
        AccountManager.shared.removeOverlayEntries(ids: Array(AccountManager.shared.snapshotOverlay().keys))
        NSEDataBridge.latestStagedRows.withLock { $0 = [] }
    }

    private func drainWriteQueue() async {
        await withCheckedContinuation { (cont: CheckedContinuation<Void, Never>) in
            Task { await AccountManager.shared.enqueueWrite { cont.resume() } }
        }
    }

    /// The card's open, as `ChatThreadView`'s card sheet makes it: the bubble's address and its
    /// Message-ID.
    private func openCard(for bubble: MessageHeader, pool: DatabasePool) async {
        let vm = MessageDetailViewModel(
            messageId: bubble.id, dbPool: pool, fetchBodyOverride: { _ in },
            expectedRfc822MessageId: bubble.rfc822MessageId)
        await vm.markReadOnOpenIfNeeded()
    }

    @Test("A card whose address now holds a different email marks nothing read; an unchanged one is marked read",
          arguments: [false, true])
    func cardMarksOnlyTheBubblesEmail(reseated: Bool) async throws {
        let (pool, inbox, dir, previous) = try makeDB()
        defer { InstalledTestDatabaseLifetime.finish(previous: previous, pool: pool, directory: dir); clearShared() }
        clearShared()
        let bubble = header(rfc: "<shown@example.com>", inbox: inbox)
        try await pool.write { db in try bubble.insert(db) }
        let seated = reseated ? header(rfc: "<replacement@example.com>", inbox: inbox) : bubble
        if reseated {
            #expect(seated.id == bubble.id, "the replacement sits at the same address")
            try await pool.write { db in
                try bubble.delete(db)
                try seated.insert(db)
            }
        }
        // Hold the write queue so a registered read is still observable below.
        let (gateStream, gate) = AsyncStream<Void>.makeStream()
        await AccountManager.shared.enqueueWrite {
            var it = gateStream.makeAsyncIterator()
            _ = await it.next()
        }
        await openCard(for: bubble, pool: pool)
        #expect(intentCycles() == (reseated ? [] : [bubble.id]), "a read is registered only for the email the bubble showed")
        gate.finish()
        await drainWriteQueue()
        let after = try await pool.read { db in try MessageHeader.fetchOne(db, key: seated.id) }
        #expect(after?.rfc822MessageId == seated.rfc822MessageId)
        #expect(after?.isRead == !reseated)
    }

    @Test("The chat's card passes the bubble's Message-ID with its address")
    func cardWiring() throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let text = try String(contentsOf: root.appendingPathComponent("TabMail/Views/Chat/ChatThreadView.swift"), encoding: .utf8)
        let flat = text.split(whereSeparator: \.isWhitespace).joined(separator: " ")
        #expect(flat.components(separatedBy: "MessageDetailView(messageId: msg.id, expectedRfc822MessageId: msg.rfc822MessageId)").count == 2)
        #expect(!flat.contains("MessageDetailView(messageId: msg.id)"))
    }
}
