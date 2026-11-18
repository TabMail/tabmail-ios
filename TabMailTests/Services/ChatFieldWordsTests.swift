/* This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at https://mozilla.org/MPL/2.0/. */

import Foundation
import GRDB
import Testing
@testable import TabMail

/// iOS #979, ADR-IOS-117: the store of a chat field's unsent words.
///
/// THE SYSTEM PROPERTIES pinned here:
///  1. Kept words survive a new app run: a new store on the same database reads them.
///  2. Words are kept per thread chat: one thread's words are never read for another thread, or
///     for the same thread id in another account; every email of a thread reads them.
///  3. Words that were sent, and an emptied field, leave nothing stored.
///  4. Kept words live by the thread's AI data rule: they stay while an email of the thread is on
///     the device and go once none is (past the same grace); removing the account removes them;
///     a demo's go with the demo.
@Suite("Chat field words store", .serialized, .processGlobalState)
@MainActor
struct ChatFieldWordsTests {

    private static let account = "words-acct"

    private static func header(_ uid: String, thread: String, account: String = account) -> MessageHeader {
        ChatFieldWordsRuntimeTests.header(uid, thread: thread, account: account)
    }

    /// An installed database, as one app run has, and its store.
    private static func withStore(_ body: @MainActor (DatabasePool, ChatFieldWords) async throws -> Void) async throws {
        let (pool, directory, previous) = try FolderEpochTestFixture.makeAppDB()
        defer { InstalledTestDatabaseLifetime.finish(previous: previous, pool: pool, directory: directory) }
        try await body(pool, ChatFieldWords())
    }

    /// An app source file with its whitespace collapsed.
    private static func source(_ path: String) throws -> String {
        let projectRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let text = try String(contentsOf: projectRoot.appendingPathComponent(path), encoding: .utf8)
        return text.split(whereSeparator: \.isWhitespace).joined(separator: " ")
    }

    private static func rows(_ pool: DatabasePool) throws -> [ChatFieldWordsRecord] {
        try pool.read { try ChatFieldWordsRecord.order(Column("sessionId")).fetchAll($0) }
    }

    // MARK: - 1. A new app run

    @Test("Words kept by one app run are read by the next")
    func wordsSurviveARestart() async throws {
        try await Self.withStore { pool, store in
            let key = ChatFieldWords.key(for: Self.header("r-1", thread: "restart"))
            store.set("Sounds good, see you Tuesday", for: key)
            await store.written()
            let next = ChatFieldWords()
            #expect(await next.words(for: key) == "Sounds good, see you Tuesday")
            let stored1 = try Self.rows(pool)
            #expect(stored1.map(\.sessionId) == [key], "one row, under the thread's chat key")
        }
    }

    @Test("The newest words of a key are the ones kept, however fast they change")
    func newestWordsWin() async throws {
        try await Self.withStore { _, store in
            let key = ChatFieldWords.key(for: Self.header("n-1", thread: "newest"))
            for words in ["S", "So", "Sou", "Soun", "Sound", ""] + ["Sounds good"] { store.set(words, for: key) }
            #expect(await store.words(for: key) == "Sounds good", "the run reads the newest at once")
            await store.written()
            #expect(await ChatFieldWords().words(for: key) == "Sounds good", "and the next run reads it")
        }
    }

    // MARK: - 2. Keyed by the thread's chat

    @Test("The key is the thread's chat key: every email of the thread shares it, another thread or account never")
    func keyIsTheThreadsChat() {
        let first = Self.header("k-1", thread: "thread-A")
        let newer = Self.header("k-2", thread: "thread-A")
        #expect(ChatFieldWords.key(for: first) == ChatFieldWords.key(for: newer), "a newer email keeps the thread's words")
        #expect(ChatFieldWords.key(for: first) == DemoModeStore.scopedSessionId(ChatThreadKey.key(for: newer)),
                "the chat history's own key, no second scheme")
        #expect(ChatFieldWords.key(for: first) != ChatFieldWords.key(for: Self.header("k-3", thread: "thread-B")))
        #expect(ChatFieldWords.key(for: first) != ChatFieldWords.key(for: Self.header("k-1", thread: "thread-A", account: "other")))
    }

    @Test("One thread's words are never read for another thread or another account")
    func wordsStayInTheirThread() async throws {
        try await Self.withStore { _, store in
            let threadA = ChatFieldWords.key(for: Self.header("s-1", thread: "thread-A"))
            let threadB = ChatFieldWords.key(for: Self.header("s-2", thread: "thread-B"))
            let otherAccount = ChatFieldWords.key(for: Self.header("s-1", thread: "thread-A", account: "other"))
            store.set("Only for A", for: threadA)
            await store.written()
            for store in [store, ChatFieldWords()] {
                #expect(await store.words(for: threadB) == "")
                #expect(await store.words(for: otherAccount) == "")
                #expect(await store.words(for: threadA) == "Only for A", "control: A's words are kept")
            }
        }
    }

    @Test("A pill moving to another thread's chat shows that chat's words, never the earlier one's")
    func otherChatReplacesTheWords() {
        var fill = ChatFieldFill()
        fill.apply(.otherChat("thread:a:1", kept: "A's words"))
        #expect(fill.words(in: "thread:a:1") == "A's words")
        fill.apply(.sentFromField)
        fill.apply(.otherChat("thread:a:2", kept: ""))
        #expect(fill.words == "", "nothing of A carries over")
        #expect(fill.kept == ChatFieldFill.Kept(chat: "thread:a:2", words: ""))
        fill.apply(.completed)
        fill.apply(.put("B's words"))
        #expect(fill.kept == ChatFieldFill.Kept(chat: "thread:a:2", words: "B's words"))
        #expect(fill.words(in: "thread:a:1") == "", "shown on A's key: none, they are B's")
    }

    @Test("Words typed before the chat's kept words were read are newer, and stay")
    func typingFirstWins() {
        var fill = ChatFieldFill()
        fill.apply(.put("Typed first"))
        #expect(fill.kept == nil, "no chat yet, nothing to keep")
        fill.apply(.otherChat("thread:a:1", kept: "Older words"))
        #expect(fill.words == "Typed first")
        #expect(fill.kept == ChatFieldFill.Kept(chat: "thread:a:1", words: "Typed first"))
    }

    // MARK: - 3. Cleared on Send and when emptied

    /// The pill's wiring, `.onChange(of: fieldFill.kept)` into the store, run on a fill.
    private static func keep(_ fill: ChatFieldFill, in store: ChatFieldWords) {
        if let kept = fill.kept { store.set(kept.words, for: kept.chat) }
    }

    @Test("A send from the field, or from the open sheet, leaves no words stored", arguments: [false, true])
    func sendClearsTheWords(fromSheet: Bool) async throws {
        try await Self.withStore { pool, store in
            let key = ChatFieldWords.key(for: Self.header("c-1", thread: "send-\(fromSheet)"))
            var fill = ChatFieldFill()
            fill.apply(.otherChat(key, kept: ""))
            fill.apply(.put("Tell her Tuesday works"))
            Self.keep(fill, in: store)
            await store.written()
            let stored2 = try Self.rows(pool)
            #expect(stored2.map(\.words) == ["Tell her Tuesday works"], "control: the words were kept")
            fill.apply(fromSheet ? .sentFromSheet : .sentFromField)
            Self.keep(fill, in: store)
            await store.written()
            let stored3 = try Self.rows(pool)
            #expect(stored3.isEmpty, "the sent words are not kept")
            #expect(await ChatFieldWords().words(for: key) == "", "the next run's field is empty")
            // Words typed after the send are newer and kept, the send still in flight.
            fill.apply(.put("And bring the slides"))
            Self.keep(fill, in: store)
            fill.apply(.completed)
            Self.keep(fill, in: store)
            await store.written()
            let stored4 = try Self.rows(pool)
            #expect(stored4.map(\.words) == ["And bring the slides"])
        }
    }

    @Test("An emptied field leaves no words stored")
    func emptiedFieldClearsTheWords() async throws {
        try await Self.withStore { pool, store in
            let key = ChatFieldWords.key(for: Self.header("e-1", thread: "emptied"))
            store.set("Draft words", for: key)
            await store.written()
            let stored5 = try Self.rows(pool)
            #expect(stored5.count == 1, "control: the words were kept")
            store.set("", for: key)
            await store.written()
            let stored6 = try Self.rows(pool)
            #expect(stored6.isEmpty)
            #expect(await ChatFieldWords().words(for: key) == "")
        }
    }

    @Test("The pill keeps each change of its words in the store, under its chat")
    func pillWiring() throws {
        let text = try Self.source("TabMail/Views/Inbox/DynamicIslandChatButton.swift")
        #expect(text.contains(".onChange(of: fieldFill.kept) { _, kept in guard let kept else { return } ChatFieldWords.shared.set(kept.words, for: kept.chat) }"))
        #expect(text.contains("guard composeContext == nil, let message else { return nil } return ChatFieldWords.key(for: message)"))
        #expect(text.contains(".task(id: wordsKey) { guard let key = wordsKey, fieldFill.chat != key else { return } let kept = await ChatFieldWords.shared.words(for: key) guard wordsKey == key, fieldFill.chat != key else { return } fieldFill.apply(.otherChat(key, kept: kept)) }"))
    }

    // MARK: - 4. Lifetime

    /// `key`'s row, last changed past the AI data's grace.
    private static func age(_ key: String, pool: DatabasePool) throws {
        let old = try #require(Calendar.current.date(byAdding: .day, value: -(SyncConfig.aiCacheOrphanGraceDays + 1), to: Date()))
        try pool.write { try $0.execute(sql: "UPDATE chatFieldWords SET updatedAt = ? WHERE sessionId = ?", arguments: [old, key]) }
    }

    @Test("Kept words stay while an email of the thread is on the device, and go with the thread's AI data")
    func wordsGoWithTheThreadsAIData() async throws {
        try await Self.withStore { pool, store in
            _ = try FolderEpochTestFixture.makeAccount(id: Self.account, provider: .gmail, pool: pool)
            try FolderEpochTestFixture.insertFolder(accountId: Self.account, path: "INBOX", role: .inbox, pool: pool)
            let email = Self.header("l-1", thread: "lifetime")
            try await pool.write { try email.insert($0) }
            let key = ChatFieldWords.key(for: email)
            let fresh = ChatFieldWords.key(for: Self.header("l-2", thread: "fresh-orphan"))
            store.set("Kept while the email is here", for: key)
            store.set("Typed today", for: fresh)
            await store.written()
            try Self.age(key, pool: pool)

            SyncEngine.runPurgeOrphanedChatFieldWords(dbPool: PrioritizedDatabase(pool: pool))
            let stored7 = try Self.rows(pool)
            #expect(stored7.map(\.sessionId).sorted() == [fresh, key].sorted(),
                    "the thread's email is here, and a fresh row waits out the grace as AI results do")

            try await pool.write { _ = try MessageHeader.deleteOne($0, key: email.id) }
            SyncEngine.runPurgeOrphanedAICache(dbPool: PrioritizedDatabase(pool: pool))
            SyncEngine.runPurgeOrphanedChatFieldWords(dbPool: PrioritizedDatabase(pool: pool))
            let stored8 = try Self.rows(pool)
            #expect(stored8.map(\.sessionId) == [fresh], "no email of the thread is left: its words went")
        }
    }

    @Test("The maintenance pass that purges orphaned AI results purges orphaned words with it")
    func purgeRunsWithTheAICachePurge() throws {
        let text = try Self.source("TabMail/Services/Sync/SyncEngine.swift")
        #expect(text.contains("runPurgeOrphanedAICache(dbPool: dbPool) runPurgeOrphanedChatFieldWords(dbPool: dbPool)"))
    }

    @Test("Removing an account removes its kept words, real and demo, and no other account's")
    func accountRemovalRemovesTheWords() async throws {
        try await Self.withStore { pool, store in
            let removed = ChatFieldWords.key(for: Self.header("a-1", thread: "gone"))
            let removedDemo = "demo:" + removed
            let kept = ChatFieldWords.key(for: Self.header("a-1", thread: "gone", account: Self.account + "-2"))
            for key in [removed, removedDemo, kept] { store.set("Words of \(key)", for: key) }
            await store.written()
            let account = Self.account
            try await pool.write { try AccountManager.removeAccountRowsTxn($0, accountId: account, wasPrimary: false) }
            let stored9 = try Self.rows(pool)
            #expect(stored9.map(\.sessionId) == [kept])
        }
    }

    @Test("A demo's kept words go with the demo; real ones stay")
    func demoWipeRemovesDemoWords() async throws {
        try await Self.withStore { pool, store in
            let real = ChatFieldWords.key(for: Self.header("d-1", thread: "real"))
            let demo = "demo:" + ChatThreadKey.key(accountId: DemoSeed.demoAccountId, threadId: "demo-thread")
            store.set("Real words", for: real)
            store.set("Demo words", for: demo)
            await store.written()
            try await pool.write { try DemoSeed.wipe($0) }
            let stored10 = try Self.rows(pool)
            #expect(stored10.map(\.sessionId) == [real])
            store.forgetDemo()
            #expect(await store.words(for: demo) == "", "the run does not show them again either")
        }
    }
}
