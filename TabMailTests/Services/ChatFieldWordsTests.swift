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
            var heldResults: Set<String> = []
            var waitingResults: [String: [CheckedContinuation<Void, Never>]] = [:]
            var waitingReads: [String: [CheckedContinuation<Void, Never>]] = [:]
            var holdsWrites = false
            var holdsWriteReturns = false
            var waitingWriteReturns: [CheckedContinuation<Void, Never>] = []
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
                    let result = try await base.read(key)
                    // A held result: the read has its words and waits to hand them over.
                    await withCheckedContinuation { continuation in
                        let held = state.withLock { state in
                            guard state.heldResults.contains(key) else { return false }
                            state.waitingResults[key, default: []].append(continuation)
                            return true
                        }
                        if !held { continuation.resume() }
                    }
                    return result
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
                    let refused = try await base.write(batch)
                    // A held return: the transaction is done and its answer waits.
                    await withCheckedContinuation { continuation in
                        let held = state.withLock { state in
                            guard state.holdsWriteReturns else { return false }
                            state.waitingWriteReturns.append(continuation)
                            return true
                        }
                        if !held { continuation.resume() }
                    }
                    return refused
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

        /// Holds `key`'s reads after they read their words, before they return them.
        func hold(resultsOf key: String) {
            state.withLock { _ = $0.heldResults.insert(key) }
        }

        func release(resultsOf key: String) {
            let waiting = state.withLock { state in
                _ = state.heldResults.remove(key)
                return state.waitingResults.removeValue(forKey: key) ?? []
            }
            waiting.forEach { $0.resume() }
        }

        /// Waits until a read of `key` holds its result.
        func waitForHeldResult(of key: String) async -> Bool {
            await poll { !($0.waitingResults[key] ?? []).isEmpty }
        }

        /// How many reads of `key` hold their result.
        func heldResultCount(of key: String) -> Int {
            state.withLock { $0.waitingResults[key]?.count ?? 0 }
        }

        /// Stops holding `key`'s next reads, leaving the reads already held waiting.
        func stopHolding(resultsOf key: String) {
            state.withLock { _ = $0.heldResults.remove(key) }
        }

        /// Holds each write after its transaction, before it returns.
        func holdWriteReturns() {
            state.withLock { $0.holdsWriteReturns = true }
        }

        func releaseWriteReturns() {
            let waiting = state.withLock { state in
                state.holdsWriteReturns = false
                defer { state.waitingWriteReturns = [] }
                return state.waitingWriteReturns
            }
            waiting.forEach { $0.resume() }
        }

        /// Waits until a write's transaction is done and its return is held.
        func waitForHeldWriteReturn() async -> Bool {
            await poll { !$0.waitingWriteReturns.isEmpty }
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

        /// How long a test waits for a held read or write before it fails.
        static let waitLimit: Duration = .seconds(10)

        private func poll(_ done: (State) -> Bool) async -> Bool {
            let deadline = ContinuousClock.now + Self.waitLimit
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
        #expect(!text.contains("ownFill."), "the pill's own fill changes only through `fieldFill`")
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

    // MARK: - 8. A removed account's and an ended demo's words never come back

    /// Set once a task it is handed to finishes.
    @MainActor private final class Finished { var value = false }

    /// A demo chat's key in the demo account.
    private static func demoKey(_ thread: String) -> String {
        "demo:" + ChatThreadKey.key(accountId: DemoSeed.demoAccountId, threadId: thread)
    }

    /// Ends the current demo run as `DemoModeService.exit` does (admission revoked, the store's demo
    /// words forgotten, the demo's rows wiped), then starts the next run.
    private static func endDemoAndStartTheNext(_ store: ChatFieldWords, pool: DatabasePool) async throws {
        DemoModeStore.shared.revokeAdmission()
        store.forgetDemo()
        try await pool.write { try DemoSeed.wipe($0) }
        DemoModeStore.shared.isActive = false
        DemoModeStore.shared.isActive = true
    }

    /// Removes the account `account` as `AccountManager.removeAccount` does around its delete.
    private static func remove(_ account: String, store: ChatFieldWords, pool: DatabasePool) async throws {
        let removal = store.beginRemoval(account)
        try await pool.write { try AccountManager.removeAccountRowsTxn($0, accountId: account, wasPrimary: false) }
        store.commitRemoval(removal)
    }

    private static func storedWords(_ pool: DatabasePool) throws -> [String: String] {
        Dictionary(uniqueKeysWithValues: try rows(pool).map { ($0.sessionId, $0.words) })
    }

    @Test("Removing an account while its words wait for a failed write's retry: they are never written, and a live account's retry still is")
    func removedAccountsFailedWriteNeverComesBack() async throws {
        try await Self.withStore { pool, storage, store in
            let removed = ChatFieldWords.key(for: Self.header("rm-1", thread: "removed"))
            let live = ChatFieldWords.key(for: Self.header("rm-2", thread: "live", account: Self.account + "-live"))
            let other = ChatFieldWords.key(for: Self.header("rm-3", thread: "other", account: Self.account + "-live"))
            storage.failWrites(true)
            store.apply(.put("Removed account's words"), to: removed)
            store.apply(.put("Live account's words"), to: live)
            await store.written()
            let onDisk696 = try Self.rows(pool)
            #expect(onDisk696.isEmpty, "control: the write failed, both are waiting for a retry")

            try await Self.remove(Self.account, store: store, pool: pool)
            storage.failWrites(false)
            // Typing in another chat writes what waits.
            store.apply(.put("Other chat's words"), to: other)
            await store.written()

            let stored = try Self.storedWords(pool)
            #expect(stored == [live: "Live account's words", other: "Other chat's words"],
                    "the removed account's words are not back on disk; the live retry is written: \(stored)")
            #expect(store.fill(for: removed).words == "", "nor in the store")
            await store.load(removed)
            #expect(store.fill(for: removed).words == "")
            #expect(await Self.nextRun(storage, removed) == "")
        }
    }

    @Test("Removing an account while a write of its words runs: whether that write lands or fails, they never come back",
          arguments: [false, true])
    func removedAccountsInFlightWriteNeverComesBack(fails: Bool) async throws {
        try await Self.withStore { pool, storage, store in
            let removed = ChatFieldWords.key(for: Self.header("if-1", thread: "removed-in-flight"))
            let live = ChatFieldWords.key(for: Self.header("if-2", thread: "live-in-flight", account: Self.account + "-live"))
            storage.holdWrites()
            storage.failWrites(fails)
            store.apply(.put("Removed account's words"), to: removed)
            store.apply(.put("Live account's words"), to: live)
            #expect(await storage.waitForWrites(1), "control: the write is running")

            try await Self.remove(Self.account, store: store, pool: pool)
            storage.releaseWrites()
            await store.written()
            storage.failWrites(false)
            store.apply(.put("Live account's newer words"), to: live)
            await store.written()

            let stored = try Self.storedWords(pool)
            #expect(stored == [live: "Live account's newer words"], "\(stored)")
            #expect(store.fill(for: removed).words == "")
            #expect(await Self.nextRun(storage, removed) == "")
        }
    }

    @Test("A removal that fails keeps every word of the account: typed before it and not yet written, typed during it, and refused by its fence")
    func failedRemovalKeepsTheWords() async throws {
        try await Self.withStore { pool, storage, store in
            let earlier = ChatFieldWords.key(for: Self.header("fr-1", thread: "typed-earlier"))
            let inFlight = ChatFieldWords.key(for: Self.header("fr-2", thread: "in-flight"))
            let during = ChatFieldWords.key(for: Self.header("fr-3", thread: "typed-during"))
            // Typed earlier, its write failed: only memory has it.
            storage.failWrites(true)
            store.apply(.put("Typed earlier"), to: earlier)
            await store.written()
            storage.failWrites(false)
            let onDisk751 = try Self.rows(pool)
            #expect(onDisk751.isEmpty, "control: not on disk")

            // A write running as the removal begins: its transaction finds the fence.
            storage.holdWrites()
            store.apply(.put("Written as it began"), to: inFlight)
            #expect(await storage.waitForWrites(2), "control: the write is running")
            let removal = store.beginRemoval(Self.account)
            storage.releaseWrites()
            await store.written()
            store.apply(.put("Typed during"), to: during)
            await store.written()
            let onDisk762 = try Self.rows(pool)
            #expect(onDisk762.isEmpty, "control: nothing of the account is written while its removal runs")
            #expect(store.fill(for: earlier).words == "Typed earlier", "the field keeps its words meanwhile")

            // The delete fails (as `AccountRemovalSavedFilesGrew` refuses it): rolled back.
            store.rollBackRemoval(removal)
            await store.written()
            let onDisk768 = try Self.storedWords(pool)
            #expect(onDisk768 == [earlier: "Typed earlier", inFlight: "Written as it began", during: "Typed during"])
            #expect(store.fill(for: earlier).words == "Typed earlier")
            #expect(await Self.nextRun(storage, earlier) == "Typed earlier")
        }
    }

    @Test("Words a removal's fence refused are written once it fails, even when it ended before the write returned")
    func refusedWordsSurviveARollbackBeforeTheWriteReturns() async throws {
        try await Self.withStore { pool, storage, store in
            let key = ChatFieldWords.key(for: Self.header("rr-1", thread: "refused-then-rolled-back"))
            // The writer has the words and waits before its transaction.
            storage.holdWrites()
            store.apply(.put("Refused by the fence"), to: key)
            #expect(await storage.waitForWrites(1), "control: the write is running")
            // A removal begins; the transaction runs under its fence and refuses the words.
            let removal = store.beginRemoval(Self.account)
            storage.holdWriteReturns()
            storage.releaseWrites()
            #expect(await storage.waitForHeldWriteReturn(), "control: the transaction ran")
            let onDisk787 = try Self.rows(pool)
            #expect(onDisk787.isEmpty, "control: the fence refused the words")
            // The removal fails, and ends, before the write returns.
            store.rollBackRemoval(removal)
            storage.releaseWriteReturns()
            await store.written()
            #expect(await Self.nextRun(storage, key) == "Refused by the fence", "a new run loads them with no further edit")
        }
    }

    @Test("Two removals of one account, one failed and one committed, in either order: a delayed write never brings its words back",
          arguments: [false, true])
    func overlappingRemovalsNeverReopen(failedFirst: Bool) async throws {
        try await Self.withStore { pool, storage, store in
            _ = try FolderEpochTestFixture.makeAccount(id: Self.account, provider: .gmail, pool: pool)
            let key = ChatFieldWords.key(for: Self.header("ov-1", thread: "overlap"))
            let live = ChatFieldWords.key(for: Self.header("ov-2", thread: "overlap-live", account: Self.account + "-live"))
            // A batch of the account's words, delayed before its transaction.
            storage.holdWrites()
            store.apply(.put("Delayed words"), to: key)
            #expect(await storage.waitForWrites(1), "control: the write is running")

            let failed = store.beginRemoval(Self.account)
            let committed = store.beginRemoval(Self.account)
            let account = Self.account
            if failedFirst { store.rollBackRemoval(failed) }
            try await pool.write { try AccountManager.removeAccountRowsTxn($0, accountId: account, wasPrimary: false) }
            if failedFirst {
                // The delete has committed and the committed removal has not finished yet: its own
                // hold still fences the delayed batch, which the failed one's end did not release.
                storage.releaseWrites()
                await store.written()
            }
            store.commitRemoval(committed)
            if !failedFirst { store.rollBackRemoval(failed) }
            storage.releaseWrites()
            await store.written()
            store.apply(.put("Live words"), to: live)
            await store.written()

            let onDisk820 = try Self.storedWords(pool)
            #expect(onDisk820 == [live: "Live words"], "the removed account's words stay gone")
            let accountLeft = try await pool.read { try Account.fetchOne($0, key: account) }
            #expect(accountLeft == nil, "control: the account is removed")
            #expect(store.fill(for: key).words == "")
        }
    }

    @Test("The demo account removed, the demo ended and seeded anew: the next demo's field keeps its words; the old run's never come back")
    func removedDemoAccountReopensWithTheNextSeed() async throws {
        DemoModeStore.shared._resetForTests()
        defer { DemoModeStore.shared._resetForTests() }
        try await Self.withStore { pool, storage, store in
            DemoModeStore.shared.isActive = true
            let demo = Self.demoKey("removed-demo")
            // The old run's write, delayed past everything below.
            storage.holdWrites()
            store.apply(.put("Old run's words"), to: demo)
            #expect(await storage.waitForWrites(1), "control: the write is running")

            try await Self.remove(DemoSeed.demoAccountId, store: store, pool: pool)
            try await Self.endDemoAndStartTheNext(store, pool: pool)
            // `DemoModeService.completeSetup`, once the new seed committed.
            store.reopenAccount(DemoSeed.demoAccountId)
            storage.releaseWrites()
            await store.written()

            store.apply(.put("New run's words"), to: demo)
            #expect(store.fill(for: demo).words == "New run's words", "the next demo's field takes the edit")
            await store.written()
            let onDisk849 = try Self.storedWords(pool)
            #expect(onDisk849 == [demo: "New run's words"], "and keeps it; the old run's write stays refused")
        }
    }

    @Test("The demo's seed reopens its fixed account's words with the account settings, after the seed commits")
    func demoSeedReopensTheWords() throws {
        let text = try Self.source("TabMail/Services/Demo/DemoModeService.swift")
        #expect(text.contains("try DemoSeed.seed() AccountFieldPersistenceStore.production.reactivateAccount(DemoSeed.demoAccountId)"))
        #expect(text.contains("ChatFieldWords.shared.reopenAccount(DemoSeed.demoAccountId) } catch {"))
    }

    @Test("A demo's write running as the demo ends: whether it lands or fails, its words are never in the next demo; real words are",
          arguments: [false, true])
    func endedDemosWriteNeverComesBack(fails: Bool) async throws {
        DemoModeStore.shared._resetForTests()
        defer { DemoModeStore.shared._resetForTests() }
        try await Self.withStore { pool, storage, store in
            DemoModeStore.shared.isActive = true
            let demo = Self.demoKey("ended-demo")
            let real = ChatThreadKey.key(accountId: Self.account, threadId: "real-during-demo")
            let next = ChatThreadKey.key(accountId: Self.account, threadId: "real-after-demo")
            storage.holdWrites()
            storage.failWrites(fails)
            store.apply(.put("Old demo words"), to: demo)
            store.apply(.put("Real words"), to: real)
            #expect(await storage.waitForWrites(1), "control: the write is running")

            try await Self.endDemoAndStartTheNext(store, pool: pool)
            storage.releaseWrites()
            await store.written()
            storage.failWrites(false)
            // A field edit in the next demo starts the writer again.
            store.apply(.put("Next words"), to: next)
            await store.written()

            let stored = Dictionary(uniqueKeysWithValues: try Self.rows(pool).map { ($0.sessionId, $0.words) })
            #expect(stored == [real: "Real words", next: "Next words"],
                    "the ended demo's words are not on disk; the real chat's are, retry included: \(stored)")
            #expect(store.fill(for: demo).words == "", "nor in the next demo's field")
            await store.load(demo)
            #expect(store.fill(for: demo).words == "")
        }
    }

    @Test("A demo's read that has its words as the demo ends never lands in the next demo, whichever read lands first",
          arguments: [false, true])
    func endedDemosReadNeverLands(oldFirst: Bool) async throws {
        DemoModeStore.shared._resetForTests()
        defer { DemoModeStore.shared._resetForTests() }
        try await Self.withStore { pool, storage, _ in
            DemoModeStore.shared.isActive = true
            let demo = Self.demoKey("read-demo")
            try await pool.write { try ChatFieldWordsRecord(sessionId: demo, words: "Old demo words", updatedAt: Date()).insert($0) }

            // Control: a read the demo outlives lands its words through the same held path.
            let control = ChatFieldWords(storage: storage.storage)
            storage.hold(resultsOf: demo)
            let controlLoad = Task { await control.load(demo) }
            #expect(await storage.waitForHeldResult(of: demo), "control: the read has its words")
            storage.release(resultsOf: demo)
            await controlLoad.value
            #expect(control.fill(for: demo).words == "Old demo words", "control: an uninterrupted read lands")

            let run = ChatFieldWords(storage: storage.storage)
            storage.hold(resultsOf: demo)
            let oldLoad = Task { await run.load(demo) }
            #expect(await storage.waitForHeldResult(of: demo), "the old read has the old words")
            try await Self.endDemoAndStartTheNext(run, pool: pool)
            let onDisk917 = try Self.rows(pool)
            #expect(onDisk917.isEmpty, "control: the wipe took the old words off disk")

            if oldFirst {
                storage.release(resultsOf: demo)
                await oldLoad.value
                await run.load(demo)
            } else {
                // The next demo's read of the same key runs and lands first.
                let waiting = storage.heldResultCount(of: demo)
                storage.stopHolding(resultsOf: demo)
                let finished = Finished()
                let newLoad = Task { await run.load(demo); finished.value = true }
                // The next demo's read is its own: it never waits for the ended demo's (bounded by the suite's wait limit, so
                // a read that joins the old one fails here rather than hanging the run).
                let deadline = ContinuousClock.now + ControlledStorage.waitLimit
                while !finished.value, ContinuousClock.now < deadline {
                    try await Task.sleep(for: .milliseconds(20))
                }
                #expect(finished.value, "the next demo's read waited for the ended demo's")
                #expect(waiting == 1, "control: only the old read is held")
                storage.release(resultsOf: demo)
                await newLoad.value
                await oldLoad.value
            }
            #expect(run.fill(for: demo).words == "", "the next demo's field never shows the ended demo's words")
            run.apply(.put("x"), to: Self.demoKey("other"))
            await run.written()
            let onDisk935 = try Self.rows(pool)
            #expect(onDisk935.map(\.sessionId) == [Self.demoKey("other")], "nor does its disk")
        }
    }
}
