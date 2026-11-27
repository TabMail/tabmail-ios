/* This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at https://mozilla.org/MPL/2.0/. */

import Testing
import Foundation
import GRDB
import Synchronization
@testable import TabMail

/// A chat about an email belongs to that email wherever its row moves. The
/// session id is made of the email's stable id, so when a re-key changes the
/// stable id the saved chat moves to the new session id, and the email its
/// first turn names becomes the new row. Nothing else moves: another email's
/// chat, another account's, a turn naming another row.
@Suite("A saved chat follows its email's re-key")
struct SavedChatFollowsItsEmailTests {

    private let account = "acc1"

    @Test("A new stable id moves the chat, in both stored forms, and names the new row")
    func newStableIdMovesTheChat() throws {
        let db = try TestDatabase.make()
        let oldHeader = "acc1:INBOX:g-old"
        let newHeader = "acc1:Archive:g-new"
        let own = SavedChatFixture.sessionId(accountId: account, stableId: "g-old")
        let demo = SavedChatFixture.sessionId(accountId: account, stableId: "g-old", demo: true)
        let other = SavedChatFixture.sessionId(accountId: account, stableId: "g-other")
        let otherAccount = SavedChatFixture.sessionId(accountId: "acc2", stableId: "g-old")
        try db.write { db in
            try SavedChatFixture.insert(tag: "own", sessionId: own, namingHeaderId: oldHeader, db: db)
            try SavedChatFixture.insert(tag: "demo", sessionId: demo, namingHeaderId: oldHeader, db: db)
            try SavedChatFixture.insert(tag: "other", sessionId: other, namingHeaderId: "acc1:INBOX:g-other", db: db)
            try SavedChatFixture.insert(tag: "acc2", sessionId: otherAccount, namingHeaderId: "acc2:INBOX:g-old", db: db)
        }
        let move = HeaderRekeyRecord(
            oldHeaderId: oldHeader, newHeaderId: newHeader, newProviderMessageId: "g-new",
            stableIds: StableIds(accountId: account, old: "g-old", new: "g-new"))

        try db.write { db in try ChatStore.followRekeyedEmails([move], db: db) }

        let chats = try db.read { db in
            (own: try SavedChatFixture.read(tag: "own", db: db),
             demo: try SavedChatFixture.read(tag: "demo", db: db),
             other: try SavedChatFixture.read(tag: "other", db: db),
             acc2: try SavedChatFixture.read(tag: "acc2", db: db))
        }
        let ownMoved = SavedChatFixture.expected(
            sessionId: SavedChatFixture.sessionId(accountId: account, stableId: "g-new"), namingHeaderId: newHeader)
        let demoMoved = SavedChatFixture.expected(
            sessionId: SavedChatFixture.sessionId(accountId: account, stableId: "g-new", demo: true),
            namingHeaderId: newHeader)
        let otherKept = SavedChatFixture.expected(sessionId: other, namingHeaderId: "acc1:INBOX:g-other")
        let acc2Kept = SavedChatFixture.expected(sessionId: otherAccount, namingHeaderId: "acc2:INBOX:g-old")
        #expect(chats.own == ownMoved)
        #expect(chats.demo == demoMoved)
        #expect(chats.other == otherKept)
        #expect(chats.acc2 == acc2Kept)
    }

    @Test("An unchanged stable id keeps the session and names the new row only where the old one was named")
    func sameStableIdNamesTheNewRow() throws {
        let db = try TestDatabase.make()
        let rfc = "same-stable@example.com"
        let session = SavedChatFixture.sessionId(accountId: account, stableId: rfc)
        try db.write { db in
            try SavedChatFixture.insert(tag: "inbox", sessionId: session, namingHeaderId: "acc1:INBOX:100", db: db)
            // The same email's copy in Sent shares the session id; its chat names that copy.
            try SavedChatFixture.insert(tag: "sent", sessionId: session, namingHeaderId: "acc1:Sent:7", db: db)
        }
        let move = HeaderRekeyRecord(
            oldHeaderId: "acc1:INBOX:100", newHeaderId: "acc1:INBOX:200", newProviderMessageId: "200",
            carriesProviderAuthority: false,
            stableIds: StableIds(accountId: account, old: rfc, new: rfc))

        try db.write { db in try ChatStore.followRekeyedEmails([move], db: db) }

        let chats = try db.read { db in
            (inbox: try SavedChatFixture.read(tag: "inbox", db: db),
             sent: try SavedChatFixture.read(tag: "sent", db: db))
        }
        let inboxFollowed = SavedChatFixture.expected(sessionId: session, namingHeaderId: "acc1:INBOX:200")
        let sentKept = SavedChatFixture.expected(sessionId: session, namingHeaderId: "acc1:Sent:7")
        #expect(chats.inbox == inboxFollowed)
        #expect(chats.sent == sentKept)
    }
}

/// The chat open on screen follows its email as the move is published: it is
/// reached by the key of the new stable id, its session id and the email it
/// names follow, and a reply still running under the old key keeps reaching
/// the same session and writes its turns where the chat now is.
///
/// `.serialized, .processGlobalState`: the turn-write test replaces
/// `AppDatabase.shared`.
@Suite("An open chat follows its email", .serialized, .processGlobalState)
@MainActor
struct OpenChatFollowsItsEmailTests {

    private let account = "acc1"

    private func key(_ stableId: String) -> String {
        ChatStore.messageSessionId(accountId: account, stableId: stableId)
    }

    private func move(_ from: String, _ to: String) -> HeaderRekeyRecord {
        HeaderRekeyRecord(
            oldHeaderId: "acc1:INBOX:\(from)", newHeaderId: "acc1:Archive:\(to)", newProviderMessageId: to,
            stableIds: StableIds(accountId: account, old: from, new: to))
    }

    private func context(_ headerId: String) -> EmailContextSnapshot {
        EmailContextSnapshot(messageHeaderId: headerId, subject: "Fixture", from: "sender@example.com")
    }

    @Test("The open chat is reached by the new key, keeps the old one, and names the new row")
    func openChatFollows() {
        let pills = ChatPillState()
        let session = pills.session(for: key("g-old"))
        session.currentSessionId = key("g-old")
        session.sessionEmailContexts[key("g-old")] = context("acc1:INBOX:g-old")
        let bystander = pills.session(for: key("g-other"))
        bystander.currentSessionId = key("g-other")
        bystander.sessionEmailContexts[key("g-other")] = context("acc1:INBOX:g-other")

        pills.followRekeyedEmails([move("g-old", "g-new")])

        let byNewKey = pills.session(for: key("g-new"))
        let byOldKey = pills.session(for: key("g-old"))
        #expect(byNewKey === session)
        #expect(byOldKey === session, "a reply still running holds the old key")
        #expect(session.currentSessionId == key("g-new"))
        #expect(session.sessionEmailContexts[key("g-new")] == context("acc1:Archive:g-new"))
        #expect(session.sessionEmailContexts[key("g-old")] == nil)
        #expect(bystander.currentSessionId == key("g-other"))
        #expect(bystander.sessionEmailContexts[key("g-other")] == context("acc1:INBOX:g-other"))
    }

    /// The open chat follows inside the publish, before the post: a holder that
    /// hears of the move and opens the email's chat finds it on the new row
    /// (`MailPointerMoves.publish`).
    @Test("A published move reaches the open chat before any holder hears of it")
    func publishMovesTheOpenChatBeforeThePost() {
        let old = "pub-\(UUID().uuidString)"
        let new = "pub-\(UUID().uuidString)"
        let oldKey = key(old)
        let newKey = key(new)
        let pills = ChatPillState.shared
        defer {
            pills.removeSession(for: oldKey)
            pills.removeSession(for: newKey)
        }
        let session = pills.session(for: oldKey)
        session.currentSessionId = oldKey
        let record = move(old, new)
        let heard = Mutex<String?>(nil)
        let token = NotificationCenter.default.addObserver(
            forName: .mailPointersMoved, object: nil, queue: nil
        ) { notification in
            // Other suites may post at the same time: read only this test's move.
            guard let moves = MailPointerMoves.posted(in: notification),
                  moves.row(movedFrom: record.oldHeaderId) != nil else { return }
            let found = MainActor.assumeIsolated {
                ChatPillState.shared.session(for: newKey).currentSessionId
            }
            heard.withLock { $0 = found }
        }
        defer { NotificationCenter.default.removeObserver(token) }

        MailPointerMoves.publish(MailPointerMoves([.row(record)]))

        let current = heard.withLock { $0 }
        #expect(current == newKey, "the chat a holder opens names the new row's session")
    }

    @Test("An unchanged stable id keeps the chat's key and names the new row")
    func sameStableIdNamesTheNewRow() {
        let pills = ChatPillState()
        let rfc = "same-stable@example.com"
        let session = pills.session(for: key(rfc))
        session.currentSessionId = key(rfc)
        session.sessionEmailContexts[key(rfc)] = context("acc1:INBOX:100")

        pills.followRekeyedEmails([HeaderRekeyRecord(
            oldHeaderId: "acc1:INBOX:100", newHeaderId: "acc1:INBOX:200", newProviderMessageId: "200",
            carriesProviderAuthority: false,
            stableIds: StableIds(accountId: account, old: rfc, new: rfc))])

        #expect(session.currentSessionId == key(rfc))
        #expect(session.sessionEmailContexts[key(rfc)] == context("acc1:INBOX:200"))
    }

    @Test("A reply that started before the chat followed its email writes where the chat now is")
    func runningReplyWritesToTheFollowedSession() async throws {
        let (pool, dir, previous) = try FolderEpochTestFixture.makeAppDB()
        defer {
            AppDatabase.shared.withLock { $0 = previous }
            TestDatabaseTeardown.retire(pool: pool, directory: dir)
        }
        await MemoryIndex.shared._testReset()
        let pills = ChatPillState()
        let session = pills.session(for: key("g-1"))
        session.currentSessionId = key("g-1")

        // The email moves twice while the reply runs.
        pills.followRekeyedEmails([move("g-1", "g-2")])
        pills.followRekeyedEmails([move("g-2", "g-3")])
        let reply = ChatTurn(
            id: "reply-\(UUID().uuidString)", timestamp: Date().timeIntervalSince1970 * 1000,
            role: "assistant", content: "It asks for a date.", userMessage: nil, type: "normal", chars: 19,
            renderedContent: nil, sessionId: key("g-1"), remindersSnapshot: nil, emailContextJSON: nil,
            thinkingContent: nil)
        let unrelated = ChatTurn(
            id: "unrelated-\(UUID().uuidString)", timestamp: Date().timeIntervalSince1970 * 1000,
            role: "user", content: "chat_converse", userMessage: "Hello", type: "normal", chars: 5,
            renderedContent: nil, sessionId: "inbox-\(UUID().uuidString)", remindersSnapshot: nil,
            emailContextJSON: nil, thinkingContent: nil)

        await session.appendTurn(reply, admission: nil)
        await session.appendTurn(unrelated, admission: nil)

        let stored = try await pool.read { db in
            (reply: try ChatTurn.fetchOne(db, key: reply.id)?.sessionId,
             history: try ChatHistoryTurn.fetchOne(db, key: reply.id)?.sessionId,
             unrelated: try ChatTurn.fetchOne(db, key: unrelated.id)?.sessionId)
        }
        #expect(stored.reply == key("g-3"))
        #expect(stored.history == key("g-3"))
        #expect(stored.unrelated == unrelated.sessionId)
    }
}
