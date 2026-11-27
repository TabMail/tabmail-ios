/* This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at https://mozilla.org/MPL/2.0/. */

import Testing
import Foundation
import GRDB
@testable import TabMail

/// A forward starts a thread of its own (ADR-IOS-043, forward split): it never
/// joins the thread of the email it forwards, a reply to it joins it, and the
/// related-messages search keeps the two threads apart.
///
/// The Message-IDs are chosen so the source's sorts BEFORE the forward's: an
/// `IN` probe over the `rfc822MessageId` index visits its values in key order,
/// so a probe that takes the first match (`LIMIT 1`) answers with the source,
/// which these tests must never accept.
@Suite("ThreadUtils.assignComputedThreadId — a forward starts its own thread")
struct AssignComputedThreadIdForwardSplitTests {

    private static let source = "a-source@example.com"
    private static let sourceThread = "T-source"
    private static let forward = "f-forward@example.com"

    private func makeDB() throws -> DatabaseQueue {
        let db = try TestDatabase.make()
        try TestDatabase.insertAccount(db, id: "acc1")
        try TestDatabase.insertFolder(db, name: "INBOX", path: "INBOX", role: .inbox, accountId: "acc1")
        return db
    }

    private func make(
        messageId: String,
        subject: String,
        rfc822: String,
        inReplyTo: String? = nil,
        references: [String] = []
    ) -> MessageHeader {
        var h = MessageHeader(
            messageId: messageId, subject: subject, from: "a", fromAddress: "a@example.com",
            to: "b@example.com", date: Date(), snippet: "", folderId: "acc1:INBOX",
            accountId: "acc1", folderPath: "INBOX", isInInbox: true
        )
        h.rfc822MessageId = rfc822
        h.inReplyTo = inReplyTo
        h.referencesJSON = MessageHeader.encodeReferences(references)
        return h
    }

    /// Assigns the thread as the sync does, then stores the row.
    @discardableResult
    private func store(
        _ header: MessageHeader, nativeThreadId: String?, sentAsForward: Bool = false, in db: DatabaseQueue
    ) throws -> MessageHeader {
        var h = header
        try db.write { db in
            try ThreadUtils.assignComputedThreadId(
                to: &h, nativeThreadId: nativeThreadId, sentAsForward: sentAsForward, db: db)
            try h.insert(db)
            try ThreadUtils.insertMessageReferences(for: h, db: db)
        }
        return h
    }

    /// The source email, in its own Gmail conversation.
    private func storeSource(in db: DatabaseQueue) throws {
        let s = try store(
            make(messageId: "uid-source", subject: "Plans", rfc822: Self.source),
            nativeThreadId: Self.sourceThread, in: db)
        #expect(s.computedThreadId == Self.sourceThread)
    }

    @Test("a forward whose References name its source, filed in the source's Gmail conversation, starts its own thread")
    func forwardWithReferencesStartsOwnThread() throws {
        let db = try makeDB()
        try storeSource(in: db)
        let f = try store(
            make(messageId: "uid-forward", subject: "Fwd: Plans", rfc822: Self.forward, references: [Self.source]),
            nativeThreadId: Self.sourceThread, in: db)
        #expect(f.computedThreadId == Self.forward)
    }

    @Test("a forward that names its source in In-Reply-To (Thunderbird's shape) starts its own thread")
    func forwardWithInReplyToStartsOwnThread() throws {
        let db = try makeDB()
        try storeSource(in: db)
        let f = try store(
            make(messageId: "uid-forward", subject: "Fw: Plans", rfc822: Self.forward,
                 inReplyTo: Self.source, references: [Self.source]),
            nativeThreadId: nil, in: db)
        #expect(f.computedThreadId == Self.forward)
    }

    @Test("a forward the send recorded starts its own thread when its subject reads as an ordinary email")
    func sentAsForwardWithRewrittenSubject() throws {
        let db = try makeDB()
        try storeSource(in: db)
        let f = try store(
            make(messageId: "uid-forward", subject: "Plans for Friday", rfc822: Self.forward, references: [Self.source]),
            nativeThreadId: Self.sourceThread, sentAsForward: true, in: db)
        #expect(f.computedThreadId == Self.forward)
    }

    @Test("a reply to a forward joins the forward's thread, though its References also name the source")
    func replyToForwardJoinsForward() throws {
        let db = try makeDB()
        try storeSource(in: db)
        let f = try store(
            make(messageId: "uid-forward", subject: "Fwd: Plans", rfc822: Self.forward, references: [Self.source]),
            nativeThreadId: Self.sourceThread, in: db)
        // "Re: Fwd:" answers the forward: it is not a forward itself.
        let r = try store(
            make(messageId: "uid-reply", subject: "Re: Fwd: Plans", rfc822: "r-reply@example.com",
                 inReplyTo: Self.forward, references: [Self.source, Self.forward]),
            nativeThreadId: Self.sourceThread, in: db)
        #expect(r.computedThreadId == f.computedThreadId)
        #expect(r.computedThreadId != Self.sourceThread)
    }

    @Test("another copy of a forward joins the forward's thread")
    func forwardCopyJoinsForward() throws {
        let db = try makeDB()
        try storeSource(in: db)
        let f = try store(
            make(messageId: "uid-forward", subject: "Fwd: Plans", rfc822: Self.forward, references: [Self.source]),
            nativeThreadId: "T-other", in: db)
        let copy = try store(
            make(messageId: "uid-forward-copy", subject: "Fwd: Plans", rfc822: Self.forward, references: [Self.source]),
            nativeThreadId: Self.sourceThread, in: db)
        #expect(copy.computedThreadId == f.computedThreadId)
        #expect(copy.computedThreadId != Self.sourceThread)
    }

    @Test("an email joins its own stored copy first: the sync's copy of a sent forward whose subject was rewritten")
    func copyBeforeAncestors() throws {
        let db = try makeDB()
        try storeSource(in: db)
        let sent = "m-sent@example.com"
        let placeholder = try store(
            make(messageId: "sent-outbox", subject: "Plans for Friday", rfc822: sent, references: [Self.source]),
            nativeThreadId: nil, sentAsForward: true, in: db)
        #expect(placeholder.computedThreadId == sent)
        // The server's copy: nothing marks it a forward.
        let copy = try store(
            make(messageId: "uid-sent", subject: "Plans for Friday", rfc822: sent, references: [Self.source]),
            nativeThreadId: nil, in: db)
        #expect(copy.computedThreadId == sent)
    }

    @Test("a reply with References only joins the newest stored ancestor's thread")
    func referencesNewestFirst() throws {
        let db = try makeDB()
        let older = try store(make(messageId: "uid-1", subject: "Plans", rfc822: "a1@example.com"),
                              nativeThreadId: "T-older", in: db)
        let newer = try store(make(messageId: "uid-2", subject: "Re: Plans", rfc822: "b2@example.com"),
                              nativeThreadId: "T-newer", in: db)
        #expect(older.computedThreadId == "T-older")
        #expect(newer.computedThreadId == "T-newer")
        let r = try store(
            make(messageId: "uid-3", subject: "Re: Plans", rfc822: "c3@example.com",
                 references: ["a1@example.com", "b2@example.com"]),
            nativeThreadId: nil, in: db)
        #expect(r.computedThreadId == "T-newer")
    }

    @Test("an ordinary reply still joins its source's thread")
    func ordinaryReplyJoinsSource() throws {
        let db = try makeDB()
        try storeSource(in: db)
        let r = try store(
            make(messageId: "uid-reply", subject: "Re: Plans", rfc822: "r-reply@example.com",
                 inReplyTo: Self.source, references: [Self.source]),
            nativeThreadId: "T-elsewhere", in: db)
        #expect(r.computedThreadId == Self.sourceThread)
    }

    @Test("a forward joins its own stored copy, even one stored before the split in its source's thread")
    func forwardJoinsCopyStoredBeforeSplit() throws {
        let db = try makeDB()
        try storeSource(in: db)
        // Stored by an earlier build: in its source's thread.
        var old = make(messageId: "uid-forward", subject: "Fwd: Plans", rfc822: Self.forward, references: [Self.source])
        old.computedThreadId = Self.sourceThread
        try db.write { db in try old.insert(db) }
        let copy = try store(
            make(messageId: "uid-forward-archive", subject: "Fwd: Plans", rfc822: Self.forward, references: [Self.source]),
            nativeThreadId: nil, in: db)
        #expect(copy.computedThreadId == Self.sourceThread)
    }

    @Test("a forward stored after a reply to it joins the reply's thread")
    func forwardStoredAfterItsReply() throws {
        let db = try makeDB()
        let r = try store(
            make(messageId: "uid-reply", subject: "Re: Fwd: Plans", rfc822: "r-reply@example.com",
                 inReplyTo: Self.forward, references: [Self.forward]),
            nativeThreadId: nil, in: db)
        let f = try store(
            make(messageId: "uid-forward", subject: "Fwd: Plans", rfc822: Self.forward),
            nativeThreadId: nil, in: db)
        #expect(f.computedThreadId == r.computedThreadId)
    }
}

/// The related-messages search (the email's screen, the chat's emails) keeps a
/// forward's thread and its source's apart.
@Suite("ThreadDetection — a forward's thread and its source's stay apart")
struct ThreadDetectionForwardSplitTests {

    private func header(
        _ id: String, subject: String, rfc822: String, thread: String,
        inReplyTo: String? = nil, references: [String] = [], minutesAgo: Double
    ) -> MessageHeader {
        var h = MessageHeader(
            messageId: id, subject: subject, from: "a", fromAddress: "a@example.com",
            to: "b@example.com", date: Date().addingTimeInterval(-minutesAgo * 60), snippet: "",
            folderId: "acc1:INBOX", accountId: "acc1", folderPath: "INBOX", isInInbox: true)
        h.rfc822MessageId = rfc822
        h.inReplyTo = inReplyTo
        h.referencesJSON = MessageHeader.encodeReferences(references)
        h.computedThreadId = thread
        return h
    }

    private var source: MessageHeader {
        header("s1", subject: "Plans", rfc822: "s1@example.com", thread: "T-source", minutesAgo: 30)
    }
    private var sourceReply: MessageHeader {
        header("s2", subject: "Re: Plans", rfc822: "s2@example.com", thread: "T-source",
               inReplyTo: "s1@example.com", references: ["s1@example.com"], minutesAgo: 25)
    }
    private var forward: MessageHeader {
        header("f1", subject: "Fwd: Plans", rfc822: "f1@example.com", thread: "f1@example.com",
               references: ["s1@example.com", "s2@example.com"], minutesAgo: 20)
    }
    private var forwardReply: MessageHeader {
        header("r1", subject: "Re: Fwd: Plans", rfc822: "r1@example.com", thread: "f1@example.com",
               inReplyTo: "f1@example.com", references: ["s1@example.com", "s2@example.com", "f1@example.com"],
               minutesAgo: 10)
    }

    @Test("from the source: the forward and the replies to it are left out")
    func fromSource() {
        let kept = ThreadDetection.excludeAcrossForwards([sourceReply, forward, forwardReply], of: source)
        #expect(kept.map(\.messageId) == ["s2"])
    }

    @Test("from the forward: the source's thread is left out, the replies to it stay")
    func fromForward() {
        let kept = ThreadDetection.excludeAcrossForwards([source, sourceReply, forwardReply], of: forward)
        #expect(kept.map(\.messageId) == ["r1"])
    }

    @Test("from a reply to the forward: the source's thread is left out, the forward stays")
    func fromForwardReply() {
        let kept = ThreadDetection.excludeAcrossForwards([source, sourceReply, forward], of: forwardReply)
        #expect(kept.map(\.messageId) == ["f1"])
    }

    @Test("an email not stored yet (no thread) keeps every related email, forwards and their sources")
    func unstoredEmailKeepsEverything() {
        let staged = header("n1", subject: "Re: Plans", rfc822: "n1@example.com", thread: "",
                            inReplyTo: "s2@example.com", references: ["s1@example.com", "s2@example.com"], minutesAgo: 1)
        let kept = ThreadDetection.excludeAcrossForwards([source, sourceReply, forward, forwardReply], of: staged)
        #expect(kept.map(\.messageId) == ["s1", "s2", "f1", "r1"])
    }

    @Test("a source with no thread leaves no email out: emails with no thread always stay")
    func sourceWithNoThreadLeavesNothingOut() {
        let unthreadedSource = header("s1", subject: "Plans", rfc822: "s1@example.com", thread: "", minutesAgo: 30)
        let unthreadedOther = header("u1", subject: "Lunch", rfc822: "u1@example.com", thread: "", minutesAgo: 15)
        let kept = ThreadDetection.excludeAcrossForwards([unthreadedSource, unthreadedOther, forwardReply], of: forward)
        #expect(kept.map(\.messageId) == ["s1", "u1", "r1"])
    }

    @Test("a forward stored before the split shares its source's thread and still shows with it")
    func storedForwardStaysWithSource() {
        let stored = header("f0", subject: "Fwd: Plans", rfc822: "f0@example.com", thread: "T-source",
                            references: ["s1@example.com"], minutesAgo: 22)
        let fromSource = ThreadDetection.excludeAcrossForwards([sourceReply, stored], of: source)
        #expect(fromSource.map(\.messageId) == ["s2", "f0"])
        let fromStored = ThreadDetection.excludeAcrossForwards([source, sourceReply], of: stored)
        #expect(fromStored.map(\.messageId) == ["s1", "s2"])
    }

    // MARK: - The search end to end

    private func makePool() throws -> (pool: DatabasePool, directory: URL) {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("test_forward_split_\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        var config = Configuration()
        config.foreignKeysEnabled = true
        let pool = try DatabasePool(path: directory.appendingPathComponent("test.sqlite").path, configuration: config)
        try AppDatabase.runMigrations(on: pool)
        try pool.write { db in
            var account = Account(emailAddress: "test@example.com", displayName: "Test", provider: .gmail)
            account.id = "acc1"
            try account.insert(db)
            try Folder(name: "INBOX", path: "INBOX", role: .inbox, accountId: "acc1").insert(db)
        }
        return (pool, directory)
    }

    /// Stores `h` as the sync does: its thread assigned at insert, under Gmail's
    /// conversation id for all of them (Gmail files a forward with its source).
    private func store(_ h: MessageHeader, in pool: DatabasePool) throws -> MessageHeader {
        var stored = h
        stored.threadId = "gm-conversation"
        try pool.write { db in
            try ThreadUtils.assignComputedThreadId(to: &stored, nativeThreadId: stored.threadId, db: db)
            try stored.insert(db)
            try ThreadUtils.insertMessageReferences(for: stored, db: db)
        }
        return stored
    }

    @Test("Gmail: the search from each email stays on its side of the forward")
    func searchStaysOnItsSide() throws {
        let (pool, directory) = try makePool()
        defer { TestDatabaseTeardown.retire(pool: pool, directory: directory) }
        let s1 = try store(source, in: pool)
        let s2 = try store(sourceReply, in: pool)
        let f1 = try store(forward, in: pool)
        let r1 = try store(forwardReply, in: pool)
        #expect(s1.computedThreadId == s2.computedThreadId)
        #expect(f1.computedThreadId == r1.computedThreadId)
        #expect(f1.computedThreadId != s1.computedThreadId)

        let fromSource = try Set(ThreadDetection.findRelatedMessages(for: s1, in: pool).map(\.id))
        let fromForward = try Set(ThreadDetection.findRelatedMessages(for: f1, in: pool).map(\.id))
        let fromForwardReply = try Set(ThreadDetection.findRelatedMessages(for: r1, in: pool).map(\.id))
        #expect(fromSource == [s2.id])
        #expect(fromForward == [r1.id])
        #expect(fromForwardReply == [f1.id])
    }
}
