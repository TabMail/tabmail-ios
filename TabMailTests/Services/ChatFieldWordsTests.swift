/* This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at https://mozilla.org/MPL/2.0/. */

import Foundation
import GRDB
import Synchronization
import Testing
@testable import TabMail

/// iOS #979, ADR-IOS-117: the store of a chat field's unsent words.
///
/// THE SYSTEM PROPERTIES pinned here:
///  1. Kept words survive a new app run: a new store on the same storage reads them.
///  2. Words are kept per thread chat: one thread's words are never read for another thread, or
///     for the same thread id in another account; every email of a thread reads them.
///  3. Words that were sent, and an emptied field, leave nothing stored.
///  4. The stored words never beat the user's newer intention: whatever the user did in the chat
///     before its stored words were read (typed, emptied, sent, dictated) is what the chat shows
///     and keeps once the read lands.
///  5. Every change reaches storage, the newest words of each chat winning: changes made while a
///     write runs, and changes a failed write held, are written by the next write.
///  6. Kept words live by the thread's AI data rule: they stay while an email of the thread (of
///     the same account) is on the device and go once none is (past the same grace); removing the
///     account removes them; a demo's go with the demo.
@Suite("Chat field words store", .serialized, .processGlobalState)
@MainActor
struct ChatFieldWordsTests {

    private static let account = "words-acct"

    private static func header(_ uid: String, thread: String, account: String = account) -> MessageHeader {
        ChatFieldWordsRuntimeTests.header(uid, thread: thread, account: account)
    }

    /// The store's storage over a test database; a test holds a key's reads or every write,
    /// releases them, or makes them fail.
    final class ControlledStorage: Sendable {
        private struct State {
            var heldKeys: Set<String> = []
            var waitingReads: [String: [CheckedContinuation<Void, Never>]] = [:]
            var holdsWrites = false
            var waitingWrites: [CheckedContinuation<Void, Never>] = []
            var failsReads = false
            var failsWrites = false
            var reads: [String] = []
            var writes = 0
        }

        struct Refused: Error {}

        private let state = Mutex(State())
        private let base: ChatFieldWords.Storage

        init(_ pool: DatabasePool) {
            base = .database { PrioritizedDatabase(pool: pool) }
        }

        var storage: ChatFieldWords.Storage {
            ChatFieldWords.Storage(
                read: { [self] key in
                    await withCheckedContinuation { continuation in
                        let held = state.withLock { state in
                            state.reads.append(key)
                            guard state.heldKeys.contains(key) else { return false }
                            state.waitingReads[key, default: []].append(continuation)
                            return true
                        }
                        if !held { continuation.resume() }
                    }
                    if state.withLock({ $0.failsReads }) { throw Refused() }
                    return try await base.read(key)
                },
                write: { [self] batch in
                    await withCheckedContinuation { continuation in
                        let held = state.withLock { state in
                            state.writes += 1
                            guard state.holdsWrites else { return false }
                            state.waitingWrites.append(continuation)
                            return true
                        }
                        if !held { continuation.resume() }
                    }
                    if state.withLock({ $0.failsWrites }) { throw Refused() }
                    try await base.write(batch)
                })
        }

        func hold(readsOf key: String) {
            state.withLock { _ = $0.heldKeys.insert(key) }
        }

        func release(readsOf key: String) {
            let waiting = state.withLock { state in
                _ = state.heldKeys.remove(key)
                return state.waitingReads.removeValue(forKey: key) ?? []
            }
            waiting.forEach { $0.resume() }
        }

        func holdWrites() {
            state.withLock { $0.holdsWrites = true }
        }

        func releaseWrites() {
            let waiting = state.withLock { state in
                state.holdsWrites = false
                defer { state.waitingWrites = [] }
                return state.waitingWrites
            }
            waiting.forEach { $0.resume() }
        }

        func failReads(_ fails: Bool) { state.withLock { $0.failsReads = fails } }
        func failWrites(_ fails: Bool) { state.withLock { $0.failsWrites = fails } }

        /// Waits until `key` was read `count` times (a held read counts once it is waiting).
        func waitForReads(of key: String, count: Int = 1) async -> Bool {
            await poll { state in state.reads.filter { $0 == key }.count >= count }
        }

        /// Waits until `count` writes started (a held write counts once it is waiting).
        func waitForWrites(_ count: Int) async -> Bool {
            await poll { $0.writes >= count }
        }

        private func poll(_ done: (State) -> Bool) async -> Bool {
            let deadline = ContinuousClock.now + .seconds(10)
            while ContinuousClock.now < deadline {
                if state.withLock({ done($0) }) { return true }
                try? await Task.sleep(for: .milliseconds(10))
            }
            return false
        }
    }

    /// An installed database, as one app run has, its controllable storage, and a store on it.
    private static func withStore(
        _ body: @MainActor (DatabasePool, ControlledStorage, ChatFieldWords) async throws -> Void
    ) async throws {
        let (pool, directory, previous) = try FolderEpochTestFixture.makeAppDB()
        defer { InstalledTestDatabaseLifetime.finish(previous: previous, pool: pool, directory: directory) }
        let storage = ControlledStorage(pool)
        try await body(pool, storage, ChatFieldWords(storage: storage.storage))
    }

    /// What a new app run's field shows for `key`: a new store, its words read.
    private static func nextRun(_ storage: ControlledStorage, _ key: String) async -> String {
        let next = ChatFieldWords(storage: storage.storage)
        await next.load(key)
        return next.fill(for: key).words
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
        try await Self.withStore { pool, storage, store in
            let key = ChatFieldWords.key(for: Self.header("r-1", thread: "restart"))
            store.apply(.put("Sounds good, see you Tuesday"), to: key)
            await store.written()
            #expect(await Self.nextRun(storage, key) == "Sounds good, see you Tuesday")
            let stored = try Self.rows(pool)
            #expect(stored.map(\.sessionId) == [key], "one row, under the thread's chat key")
        }
    }

    @Test("The newest words of a key are the ones kept, however fast they change")
    func newestWordsWin() async throws {
        try await Self.withStore { _, storage, store in
            let key = ChatFieldWords.key(for: Self.header("n-1", thread: "newest"))
            for words in ["S", "So", "Sou", "Soun", "Sound", ""] + ["Sounds good"] { store.apply(.put(words), to: key) }
            #expect(store.fill(for: key).words == "Sounds good", "the run shows the newest at once")
            await store.written()
            #expect(await Self.nextRun(storage, key) == "Sounds good", "and the next run reads it")
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
        try await Self.withStore { _, storage, store in
            let threadA = ChatFieldWords.key(for: Self.header("s-1", thread: "thread-A"))
            let threadB = ChatFieldWords.key(for: Self.header("s-2", thread: "thread-B"))
            let otherAccount = ChatFieldWords.key(for: Self.header("s-1", thread: "thread-A", account: "other"))
            store.apply(.put("Only for A"), to: threadA)
            await store.written()
            #expect(store.fill(for: threadB).words == "" && store.fill(for: otherAccount).words == "")
            #expect(await Self.nextRun(storage, threadB) == "")
            #expect(await Self.nextRun(storage, otherAccount) == "")
            #expect(await Self.nextRun(storage, threadA) == "Only for A", "control: A's words are kept")
        }
    }

    // MARK: - 3. Cleared on Send and when emptied

    @Test("A send from the field, or from the open sheet, leaves no words stored", arguments: [false, true])
    func sendClearsTheWords(fromSheet: Bool) async throws {
        try await Self.withStore { pool, storage, store in
            let key = ChatFieldWords.key(for: Self.header("c-1", thread: "send-\(fromSheet)"))
            store.apply(.put("Tell her Tuesday works"), to: key)
            await store.written()
            let kept = try Self.rows(pool)
            #expect(kept.map(\.words) == ["Tell her Tuesday works"], "control: the words were kept")
            store.apply(fromSheet ? .sentFromSheet : .sentFromField, to: key)
            await store.written()
            let afterSend = try Self.rows(pool)
            #expect(afterSend.isEmpty, "the sent words are not kept")
            #expect(await Self.nextRun(storage, key) == "", "the next run's field is empty")
            // Words typed after the send are newer and kept, the send still in flight.
            store.apply(.put("And bring the slides"), to: key)
            store.apply(.completed, to: key)
            await store.written()
            let newer = try Self.rows(pool)
            #expect(newer.map(\.words) == ["And bring the slides"])
        }
    }

    @Test("An emptied field leaves no words stored")
    func emptiedFieldClearsTheWords() async throws {
        try await Self.withStore { pool, storage, store in
            let key = ChatFieldWords.key(for: Self.header("e-1", thread: "emptied"))
            store.apply(.put("Draft words"), to: key)
            await store.written()
            let kept = try Self.rows(pool)
            #expect(kept.count == 1, "control: the words were kept")
            store.apply(.put(""), to: key)
            await store.written()
            let emptied = try Self.rows(pool)
            #expect(emptied.isEmpty)
            #expect(await Self.nextRun(storage, key) == "")
        }
    }

    // MARK: - 4. The stored words never beat the user's newer intention

    /// What the user does in a chat while its stored words are being read.
    enum Intention: String, CaseIterable, Sendable {
        case typed, emptied, sentFromSheet, sentFromField, dictating

        /// The changes, in order.
        var changes: [ChatFieldFill.Change] {
            switch self {
            case .typed: [.put("Newer words")]
            case .emptied: [.put("x"), .put("")]
            case .sentFromSheet: [.put("Ask this"), .sentFromSheet]
            case .sentFromField: [.put("Ask this"), .sentFromField]
            case .dictating: [.startHearing, .heard("Said aloud")]
            }
        }

        /// What the field shows after them.
        var shown: String {
            switch self {
            case .typed: "Newer words"
            case .emptied, .sentFromSheet: ""
            case .sentFromField: "Ask this"
            case .dictating: "Said aloud"
            }
        }

        /// What is kept after them.
        var kept: String {
            switch self {
            case .typed: "Newer words"
            case .emptied, .sentFromSheet, .sentFromField: ""
            case .dictating: "Said aloud"
            }
        }
    }

    @Test("Whatever the user did before the chat's stored words were read is what it shows and keeps",
          arguments: Intention.allCases)
    func storedWordsNeverBeatNewerIntention(_ intention: Intention) async throws {
        try await Self.withStore { pool, storage, store in
            let key = ChatFieldWords.key(for: Self.header("h-1", thread: "held-\(intention.rawValue)"))
            store.apply(.put("Older stored words"), to: key)
            await store.written()

            // A new run: the chat's read is held while the user acts.
            let run = ChatFieldWords(storage: storage.storage)
            storage.hold(readsOf: key)
            let loading = Task { await run.load(key) }
            #expect(await storage.waitForReads(of: key), "control: the read started")
            for change in intention.changes { run.apply(change, to: key) }
            storage.release(readsOf: key)
            await loading.value
            await run.written()

            #expect(run.fill(for: key).words == intention.shown, "the newer intention stays: \(run.fill(for: key).words)")
            #expect(run.fill(for: key).unsent == intention.kept)
            let stored = try Self.rows(pool).map(\.words)
            #expect(stored == (intention.kept.isEmpty ? [] : [intention.kept]), "and is what is kept: \(stored)")
            #expect(await Self.nextRun(storage, key) == intention.kept)
            // A live transcript goes on adding to its own words.
            if intention == .dictating {
                run.apply(.heard("Said aloud, and more"), to: key)
                #expect(run.fill(for: key).words == "Said aloud, and more")
            }
        }
    }

    @Test("A chat's stored words read while nothing changed it come back; a late read never replaces a newer change")
    func lateReadNeverReplacesANewerChange() async throws {
        try await Self.withStore { _, storage, store in
            let key = ChatFieldWords.key(for: Self.header("late-1", thread: "late"))
            store.apply(.put("Stored words"), to: key)
            await store.written()

            let control = ChatFieldWords(storage: storage.storage)
            await control.load(key)
            #expect(control.fill(for: key).words == "Stored words", "control: an untouched chat reads them")

            let run = ChatFieldWords(storage: storage.storage)
            storage.hold(readsOf: key)
            let first = Task { await run.load(key) }
            #expect(await storage.waitForReads(of: key, count: 2))
            // A second pill on the chat waits for the same read.
            let second = Task { await run.load(key) }
            run.apply(.put("Newer words"), to: key)
            storage.release(readsOf: key)
            await first.value
            await second.value
            #expect(run.fill(for: key).words == "Newer words")
            await run.load(key)
            #expect(run.fill(for: key).words == "Newer words", "a later load reads nothing over it")
        }
    }

    @Test("A failed read keeps the stored words for the next read, in this run and the next")
    func failedReadKeepsTheStoredWords() async throws {
        try await Self.withStore { pool, storage, store in
            let key = ChatFieldWords.key(for: Self.header("f-1", thread: "failed-read"))
            store.apply(.put("Words worth keeping"), to: key)
            await store.written()

            let run = ChatFieldWords(storage: storage.storage)
            storage.failReads(true)
            await run.load(key)
            storage.failReads(false)
            await run.written()
            let stored = try Self.rows(pool).map(\.words)
            #expect(stored == ["Words worth keeping"], "the stored words are still stored: \(stored)")
            await run.load(key)
            #expect(run.fill(for: key).words == "Words worth keeping", "the next read in this run shows them")
            #expect(await Self.nextRun(storage, key) == "Words worth keeping", "and the next run's")
        }
    }

    @Test("A pill switching chats while a read runs: each chat keeps only its own words, whichever read lands first",
          arguments: [false, true])
    func readsLandOnlyOnTheirOwnChat(newerFirst: Bool) async throws {
        try await Self.withStore { pool, storage, store in
            let chatA = ChatFieldWords.key(for: Self.header("t-1", thread: "transfer-A"))
            let chatB = ChatFieldWords.key(for: Self.header("t-2", thread: "transfer-B"))
            store.apply(.put("A's words"), to: chatA)
            await store.written()

            let run = ChatFieldWords(storage: storage.storage)
            storage.hold(readsOf: chatA)
            storage.hold(readsOf: chatB)
            let loadA = Task { await run.load(chatA) }
            let loadB = Task { await run.load(chatB) }
            #expect(await storage.waitForReads(of: chatA), "control: A's read started")
            #expect(await storage.waitForReads(of: chatB), "control: B's read started")
            // The pill is on B now: the user's words are B's.
            run.apply(.put("B's words"), to: chatB)
            for chat in newerFirst ? [chatB, chatA] : [chatA, chatB] { storage.release(readsOf: chat) }
            await loadA.value
            await loadB.value
            await run.written()
            #expect(run.fill(for: chatB).words == "B's words")
            #expect(run.fill(for: chatA).words == "A's words", "A shows its own words")
            let stored = try Self.rows(pool)
            #expect(Dictionary(uniqueKeysWithValues: stored.map { ($0.sessionId, $0.words) })
                    == [chatA: "A's words", chatB: "B's words"])
        }
    }

    // MARK: - 5. Writes

    @Test("Changes made while a write runs are written next, the newest words of each chat winning")
    func changesDuringAWriteAreWritten() async throws {
        try await Self.withStore { _, storage, store in
            let one = ChatFieldWords.key(for: Self.header("w-1", thread: "write-1"))
            let two = ChatFieldWords.key(for: Self.header("w-2", thread: "write-2"))
            let three = ChatFieldWords.key(for: Self.header("w-3", thread: "write-3"))
            store.apply(.put("Gone soon"), to: three)
            await store.written()

            storage.holdWrites()
            store.apply(.put("First"), to: one)
            #expect(await storage.waitForWrites(2), "control: the write is running")
            store.apply(.put("Second"), to: one)
            store.apply(.put("Two's words"), to: two)
            store.apply(.put(""), to: three)
            storage.releaseWrites()
            await store.written()

            #expect(await Self.nextRun(storage, one) == "Second")
            #expect(await Self.nextRun(storage, two) == "Two's words")
            #expect(await Self.nextRun(storage, three) == "", "an emptying made while writing is written too")
        }
    }

    @Test("A failed write keeps the newest words of each chat, and the next change writes them")
    func failedWriteIsWrittenByTheNextChange() async throws {
        try await Self.withStore { _, storage, store in
            let one = ChatFieldWords.key(for: Self.header("x-1", thread: "fail-1"))
            let two = ChatFieldWords.key(for: Self.header("x-2", thread: "fail-2"))
            store.apply(.put("Stored first"), to: one)
            await store.written()

            storage.holdWrites()
            storage.failWrites(true)
            store.apply(.put("Held and failed"), to: one)
            #expect(await storage.waitForWrites(2), "control: the write is running")
            store.apply(.put("Newest"), to: one)
            storage.releaseWrites()
            await store.written()
            #expect(await Self.nextRun(storage, one) == "Stored first", "control: nothing was written yet")
            #expect(store.fill(for: one).words == "Newest", "the run still shows the newest")

            storage.failWrites(false)
            store.apply(.put("Two's words"), to: two)
            await store.written()
            #expect(await Self.nextRun(storage, one) == "Newest", "the next change wrote the newest, not the failed")
            #expect(await Self.nextRun(storage, two) == "Two's words")
        }
    }

    @Test("A read or write failure logs the error's type, never the words")
    func failuresNeverLogTheWords() throws {
        let text = try Self.source("TabMail/Services/AI/ChatFieldWords.swift")
        let logs = text.components(separatedBy: "BackgroundSyncLogger.logDebug(").dropFirst().map { call in call.prefix { $0 != ")" } }
        #expect(logs.count == 2, "control: the read and the write log: \(logs)")
        for log in logs {
            #expect(log.components(separatedBy: "\\(").count == 2 && log.contains("\\(type(of: error"), "\(log)")
        }
    }

    // MARK: - 6. The pill's wiring

    @Test("Every pill about an email reads and changes its chat's one fill, and reads its stored words as it shows the chat")
    func pillWiring() throws {
        let text = try Self.source("TabMail/Views/Inbox/DynamicIslandChatButton.swift")
        #expect(text.contains("private var fieldFill: ChatFieldWords.Field { ChatFieldWords.Field(key: wordsKey, own: $ownFill) }"))
        #expect(text.contains("guard composeContext == nil, let message else { return nil } return ChatFieldWords.key(for: message)"))
        #expect(text.contains(".task(id: wordsKey) { guard let key = wordsKey else { return } await ChatFieldWords.shared.load(key) }"))
        #expect(!text.contains("ownFill.") && !text.contains("ownFill ="), "the pill's own fill changes only through `fieldFill`")
    }

    // MARK: - 7. Lifetime

    /// `key`'s row, last changed past the AI data's grace.
    private static func age(_ key: String, pool: DatabasePool) throws {
        let old = try #require(Calendar.current.date(byAdding: .day, value: -(SyncConfig.aiCacheOrphanGraceDays + 1), to: Date()))
        try pool.write { try $0.execute(sql: "UPDATE chatFieldWords SET updatedAt = ? WHERE sessionId = ?", arguments: [old, key]) }
    }

    @Test("Kept words stay while an email of the thread is on the device, and go with the thread's AI data")
    func wordsGoWithTheThreadsAIData() async throws {
        try await Self.withStore { pool, _, store in
            _ = try FolderEpochTestFixture.makeAccount(id: Self.account, provider: .gmail, pool: pool)
            try FolderEpochTestFixture.insertFolder(accountId: Self.account, path: "INBOX", role: .inbox, pool: pool)
            let email = Self.header("l-1", thread: "lifetime")
            try await pool.write { try email.insert($0) }
            let key = ChatFieldWords.key(for: email)
            let fresh = ChatFieldWords.key(for: Self.header("l-2", thread: "fresh-orphan"))
            store.apply(.put("Kept while the email is here"), to: key)
            store.apply(.put("Typed today"), to: fresh)
            await store.written()
            try Self.age(key, pool: pool)

            SyncEngine.runPurgeOrphanedChatFieldWords(dbPool: PrioritizedDatabase(pool: pool))
            let kept = try Self.rows(pool)
            #expect(kept.map(\.sessionId).sorted() == [fresh, key].sorted(),
                    "the thread's email is here, and a fresh row waits out the grace as AI results do")

            try await pool.write { _ = try MessageHeader.deleteOne($0, key: email.id) }
            SyncEngine.runPurgeOrphanedAICache(dbPool: PrioritizedDatabase(pool: pool))
            SyncEngine.runPurgeOrphanedChatFieldWords(dbPool: PrioritizedDatabase(pool: pool))
            let purged = try Self.rows(pool)
            #expect(purged.map(\.sessionId) == [fresh], "no email of the thread is left: its words went")
        }
    }

    @Test("A thread's email in another account keeps no words alive; an email with no thread id keeps its own")
    func orphanRuleIsPerAccountAndThreadless() async throws {
        try await Self.withStore { pool, _, store in
            let other = Self.account + "-other"
            for account in [Self.account, other] {
                _ = try FolderEpochTestFixture.makeAccount(id: account, provider: .gmail, pool: pool)
                try FolderEpochTestFixture.insertFolder(accountId: account, path: "INBOX", role: .inbox, pool: pool)
            }
            // The same thread id, in the other account only.
            let elsewhere = Self.header("o-1", thread: "shared-thread", account: other)
            let gone = ChatFieldWords.key(for: Self.header("o-1", thread: "shared-thread"))
            // An email with no thread id: its chat is its own (the header id).
            let threadless = Self.header("o-2", thread: "")
            let threadlessKey = ChatFieldWords.key(for: threadless)
            #expect(threadlessKey == ChatThreadKey.key(accountId: Self.account, threadId: threadless.id), "control: keyed by the header id")
            try await pool.write { db in
                try elsewhere.insert(db)
                try threadless.insert(db)
            }
            for key in [gone, threadlessKey] { store.apply(.put("Words of \(key)"), to: key) }
            await store.written()
            for key in [gone, threadlessKey] { try Self.age(key, pool: pool) }

            SyncEngine.runPurgeOrphanedChatFieldWords(dbPool: PrioritizedDatabase(pool: pool))
            let kept = try Self.rows(pool)
            #expect(kept.map(\.sessionId) == [threadlessKey],
                    "the other account's email keeps nothing alive here; the threadless email keeps its own")

            try await pool.write { _ = try MessageHeader.deleteOne($0, key: threadless.id) }
            SyncEngine.runPurgeOrphanedChatFieldWords(dbPool: PrioritizedDatabase(pool: pool))
            let purged = try Self.rows(pool)
            #expect(purged.isEmpty, "the threadless email gone, its words go")
        }
    }

    @Test("The maintenance pass that purges orphaned AI results purges orphaned words with it")
    func purgeRunsWithTheAICachePurge() throws {
        let text = try Self.source("TabMail/Services/Sync/SyncEngine.swift")
        #expect(text.contains("runPurgeOrphanedAICache(dbPool: dbPool) runPurgeOrphanedChatFieldWords(dbPool: dbPool)"))
    }

    @Test("Removing an account removes its kept words, real and demo, and no other account's")
    func accountRemovalRemovesTheWords() async throws {
        try await Self.withStore { pool, _, store in
            let removed = ChatFieldWords.key(for: Self.header("a-1", thread: "gone"))
            let removedDemo = "demo:" + removed
            let kept = ChatFieldWords.key(for: Self.header("a-1", thread: "gone", account: Self.account + "-2"))
            for key in [removed, removedDemo, kept] { store.apply(.put("Words of \(key)"), to: key) }
            await store.written()
            let account = Self.account
            try await pool.write { try AccountManager.removeAccountRowsTxn($0, accountId: account, wasPrimary: false) }
            let stored = try Self.rows(pool)
            #expect(stored.map(\.sessionId) == [kept])
        }
    }

    @Test("A demo's kept words go with the demo; real ones stay")
    func demoWipeRemovesDemoWords() async throws {
        try await Self.withStore { pool, _, store in
            let real = ChatFieldWords.key(for: Self.header("d-1", thread: "real"))
            let demo = "demo:" + ChatThreadKey.key(accountId: DemoSeed.demoAccountId, threadId: "demo-thread")
            store.apply(.put("Real words"), to: real)
            store.apply(.put("Demo words"), to: demo)
            await store.written()
            try await pool.write { try DemoSeed.wipe($0) }
            let stored = try Self.rows(pool)
            #expect(stored.map(\.sessionId) == [real])
            store.forgetDemo()
            await store.load(demo)
            #expect(store.fill(for: demo).words == "", "the run does not show them again either")
            #expect(store.fill(for: real).words == "Real words", "control: the real chat keeps its words")
        }
    }
}
