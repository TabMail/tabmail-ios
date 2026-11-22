/* This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at https://mozilla.org/MPL/2.0/. */

import Foundation
import GRDB
import SQLite3
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
            /// The keys of every batch handed to the storage, in order.
            var batches: [Set<String>] = []
            /// The fuzzer's seeded faults and latency (`enableChaos`); nil: none.
            var chaos: Chaos?
        }

        /// Seeded faults and latency for the fuzzer: a write fails before its transaction one
        /// time in `faultOneIn`, and every read and write parks for up to `maxLatency` before and
        /// after the database, stretching the await windows where the store's races live.
        struct Chaos {
            var rng: SplitMix64
            let faultOneIn: Int
            let maxLatencyMicroseconds: Int
        }

        /// Where a read or write parks.
        private func chaosPoint() async {
            let micros = state.withLock { state -> Int? in
                guard var chaos = state.chaos else { return nil }
                defer { state.chaos = chaos }
                return chaos.rng.pick(chaos.maxLatencyMicroseconds + 1)
            }
            guard let micros else { return }
            if micros % 2 == 0 {
                for _ in 0..<(micros % 7) { await Task.yield() }
            } else {
                try? await Task.sleep(for: .microseconds(micros))
            }
        }

        /// Whether the fuzzer fails this write.
        private func chaosFault() -> Bool {
            state.withLock { state in
                guard var chaos = state.chaos else { return false }
                defer { state.chaos = chaos }
                return chaos.rng.pick(chaos.faultOneIn) == 0
            }
        }

        func enableChaos(seed: UInt64, faultOneIn: Int, maxLatencyMicroseconds: Int) {
            state.withLock {
                $0.chaos = Chaos(rng: SplitMix64(seed: seed), faultOneIn: faultOneIn, maxLatencyMicroseconds: maxLatencyMicroseconds)
            }
        }

        func disableChaos() { state.withLock { $0.chaos = nil } }

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
                    await chaosPoint()
                    let result = try await base.read(key)
                    await chaosPoint()
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
                            state.batches.append(Set(batch.keys))
                            guard state.holdsWrites else { return false }
                            state.waitingWrites.append(continuation)
                            return true
                        }
                        if !held { continuation.resume() }
                    }
                    await chaosPoint()
                    if state.withLock({ $0.failsWrites }) || chaosFault() { throw Refused() }
                    try await base.write(batch)
                    await chaosPoint()
                    // A held return: the transaction is done and its answer waits.
                    await withCheckedContinuation { continuation in
                        let held = state.withLock { state in
                            guard state.holdsWriteReturns else { return false }
                            state.waitingWriteReturns.append(continuation)
                            return true
                        }
                        if !held { continuation.resume() }
                    }
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

        /// How many batches were handed to the storage so far.
        var batchCount: Int { state.withLock { $0.batches.count } }

        /// The keys of every batch handed to the storage from the `from`th on.
        func batchKeys(from: Int) -> [Set<String>] {
            state.withLock { Array($0.batches.dropFirst(from)) }
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
        // A chat's words are written only while its account row exists (`Storage.admits`).
        for account in accounts { try insertAccount(account, pool: pool) }
        let storage = ControlledStorage(pool)
        try await body(pool, storage, ChatFieldWords(storage: storage.storage))
    }

    /// Every account the tests type words for.
    private static let accounts = [account, account + "-2", account + "-live", account + "-other", "other",
                                   DemoSeed.demoAccountId, "fz-a", "fz-b"]

    /// Inserts the account row `id`, as its setup (or the demo's seed) does.
    private static func insertAccount(_ id: String, pool: DatabasePool) throws {
        _ = try FolderEpochTestFixture.makeAccount(id: id, provider: .gmail, pool: pool)
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

    @Test("A live transcript after a field Send makes the words newly written: kept in full, read by the next run, and left by the answer; unedited sent words go",
          arguments: [false, true])
    func liveTranscriptAfterAFieldSendIsKept(edited: Bool) async throws {
        try await Self.withStore { pool, storage, store in
            let key = ChatFieldWords.key(for: Self.header("lt-1", thread: "live-transcript-\(edited)"))
            let sent = "Ask her about Tuesday"
            let said = "and whether Friday works too"
            let full = DictationController.appending(said, to: sent)
            store.apply(.put(sent), to: key)
            store.apply(.sentFromField, to: key)
            await store.written()
            let atSend = try Self.rows(pool)
            #expect(atSend.isEmpty, "control: the sent words are not kept while the send is open")
            if edited {
                store.apply(.startHearing, to: key)
                store.apply(.heard(said), to: key)
                #expect(store.fill(for: key).words == full, "control: the transcript adds to the sent words")
                await store.written()
                let afterHeard = try Self.storedWords(pool)
                #expect(afterHeard == [key: full], "the edited words are kept in full: \(afterHeard)")
                #expect(await Self.nextRun(storage, key) == full, "and a new run on the same database reads them")
            }
            // The send's answer, then its card's completion.
            store.apply(.answered, to: key)
            store.apply(.completed, to: key)
            await store.written()
            let stored = try Self.storedWords(pool)
            if edited {
                #expect(store.fill(for: key).words == full, "the answer leaves the newly written words")
                #expect(stored == [key: full], "\(stored)")
                #expect(await Self.nextRun(storage, key) == full)
            } else {
                #expect(store.fill(for: key).words == "", "control: the unedited sent words go with the answer")
                #expect(stored.isEmpty, "\(stored)")
                #expect(await Self.nextRun(storage, key) == "")
            }
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

    @Test("A change that changes nothing while the chat's read is held is no intention: the saved words still load")
    func noOpChangeLetsTheSavedWordsLoad() async throws {
        try await Self.withStore { _, storage, store in
            let key = ChatFieldWords.key(for: Self.header("noop-1", thread: "no-op"))
            store.apply(.put("Saved words"), to: key)
            await store.written()

            let run = ChatFieldWords(storage: storage.storage)
            storage.hold(readsOf: key)
            let loading = Task { await run.load(key) }
            #expect(await storage.waitForReads(of: key), "control: the read started")
            // An answer with no send open and an echo of the empty field change nothing.
            run.apply(.answered, to: key)
            run.apply(.put(""), to: key)
            #expect(run.fill(for: key) == ChatFieldFill(), "control: the fill is unchanged")
            storage.release(readsOf: key)
            await loading.value
            #expect(run.fill(for: key).words == "Saved words", "the saved words load: \(run.fill(for: key).words)")
        }
    }

    @Test("A confirmation card after an unchanged field send empties its words before the answer; a card from a request with no field key leaves them",
          arguments: [true, false])
    func confirmationCardEmptiesTheFieldSend(fromField: Bool) async throws {
        try await Self.withStore { _, _, store in
            let previous = ChatFieldWords.shared
            ChatFieldWords.shared = store
            defer { ChatFieldWords.shared = previous }
            let key = ChatFieldWords.key(for: Self.header("card-1", thread: "card-\(fromField)"))
            store.apply(.put("Archive these"), to: key)
            store.apply(.sentFromField, to: key)
            let card = AgentToolRouter.ActionConfirmation(
                action: .archive, emails: [], contacts: [], calendarEvents: [], templates: [], onRespond: { _ in })
            let session = ChatPillState.Session()
            SessionUISink(session: session, fieldWordsKey: fromField ? key : nil).deliverConfirmation(card)
            #expect(session.chatMessages.count == 1, "control: the card was delivered")
            let fill = store.fill(for: key)
            if fromField {
                #expect(fill.words == "" && fill.atSend == "Archive these", "the card emptied the sent words, the send still open: \(fill)")
            } else {
                #expect(fill.words == "Archive these" && fill.holdsSentWords, "another request's card leaves the words: \(fill)")
            }
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

    @Test("Words typed while a read runs stay when that read fails: shown, stored, and read by the next run")
    func failedReadAfterAnEditKeepsTheNewerWords() async throws {
        try await Self.withStore { pool, storage, store in
            let key = ChatFieldWords.key(for: Self.header("f-2", thread: "failed-read-edit"))
            store.apply(.put("Older stored words"), to: key)
            await store.written()

            let run = ChatFieldWords(storage: storage.storage)
            storage.hold(readsOf: key)
            storage.failReads(true)
            let load = Task { await run.load(key) }
            #expect(await storage.waitForReads(of: key), "control: the read started")
            // The user types while the read is out, and the typed words are written; the read then fails.
            let typed = "Typed while the read was out"
            run.apply(.put(typed), to: key)
            await run.written()
            let typedRows = try Self.rows(pool)
            #expect(typedRows.map(\.words) == [typed], "control: the typed words are stored before the read fails")
            let batches = storage.batchCount
            storage.release(readsOf: key)
            await load.value
            storage.failReads(false)
            await run.written()
            #expect(run.fill(for: key).words == typed, "the failed read leaves the typed words: \(run.fill(for: key).words)")
            let stored = try Self.rows(pool)
            #expect(stored == typedRows, "the failed read writes nothing: the typed words' row, its stamp unchanged")
            let laterBatches = storage.batchCount
            #expect(laterBatches == batches, "no write after the failed read")
            #expect(await Self.nextRun(storage, key) == typed, "and the next run reads them")
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

    /// A save point other than a change: the app going to the background, a pill showing a chat.
    enum SavePoint: String, CaseIterable, Sendable { case background, open }

    @Test("Words a failed write left unsaved are kept for the next run once a later save point succeeds, typed or emptied, with no further change",
          arguments: [false, true], SavePoint.allCases)
    func failedWriteIsSavedAtTheNextSavePoint(emptied: Bool, savePoint: SavePoint) async throws {
        try await Self.withStore { _, storage, store in
            let key = ChatFieldWords.key(for: Self.header("sp-1", thread: "save-point"))
            let earlier = "Saved earlier"
            let newest = emptied ? "" : "Typed before the failure"
            // Control: a write that succeeds is kept for the next run at once.
            store.apply(.put(earlier), to: key)
            await store.written()
            #expect(await Self.nextRun(storage, key) == earlier, "control: a successful write is kept")

            storage.failWrites(true)
            store.apply(.put(newest), to: key)
            await store.written()
            storage.failWrites(false)
            #expect(await Self.nextRun(storage, key) == earlier, "control: the failed write kept nothing, and nothing but a save point writes")
            #expect(store.fill(for: key).words == newest, "the run still shows the newest")

            switch savePoint {
            case .background: store.saveUnwritten()
            case .open: await store.load(key)
            }
            await store.written()
            #expect(await Self.nextRun(storage, key) == newest, "the save point wrote the newest words")
        }
    }

    @Test("The app going to the background is a save point for unsaved chat words")
    func backgroundIsASavePoint() throws {
        let text = try Self.source("TabMail/Views/RootView.swift")
        let background = try #require(text.range(of: "case .background:"), "control: RootView handles the background phase")
        let rest = text[background.upperBound...]
        let save = try #require(rest.range(of: "ChatFieldWords.shared.saveUnwritten()"), "the background phase saves the unsaved words")
        let nextCase = rest.range(of: "case .")?.lowerBound ?? rest.endIndex
        #expect(save.lowerBound < nextCase, "in the background branch itself")
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

    /// `days` days after `base`.
    private static func later(_ days: Int, from base: Date) throws -> Date {
        try #require(Calendar.current.date(byAdding: .day, value: days, to: base))
    }

    /// `hours` hours after `base`.
    private static func hours(_ hours: Int, after base: Date) throws -> Date {
        try #require(Calendar.current.date(byAdding: .hour, value: hours, to: base))
    }

    @Test("A pass that sees the thread re-stamps words still inside the grace: they survive a later pass with the email briefly gone, just past their old cutoff")
    func passRestampsWordsInsideTheGrace() async throws {
        try await Self.withStore { pool, _, store in
            try FolderEpochTestFixture.insertFolder(accountId: Self.account, path: "INBOX", role: .inbox, pool: pool)
            let email = Self.header("g-1", thread: "inside-grace")
            try await pool.write { try email.insert($0) }
            let key = ChatFieldWords.key(for: email)
            store.apply(.put("Typed almost a grace ago"), to: key)
            await store.written()
            let seen = Date()
            // An hour inside the grace at the first pass.
            let cutoff = try Self.later(-SyncConfig.aiCacheOrphanGraceDays, from: seen)
            let typed = try Self.hours(1, after: cutoff)
            try await pool.write {
                try $0.execute(sql: "UPDATE chatFieldWords SET updatedAt = ? WHERE sessionId = ?", arguments: [typed, key])
            }
            let database = PrioritizedDatabase(pool: pool)

            // A pass that sees the thread's email.
            SyncEngine.runPurgeOrphanedChatFieldWords(dbPool: database, now: seen)
            #expect(try Self.rows(pool).map(\.sessionId) == [key], "control: the thread's email is here")

            // The email briefly gone, and the next pass two hours later, past the old stamp's cutoff.
            try await pool.write { _ = try MessageHeader.deleteOne($0, key: email.id) }
            SyncEngine.runPurgeOrphanedChatFieldWords(dbPool: database, now: try Self.hours(2, after: seen))
            #expect(try Self.rows(pool).map(\.sessionId) == [key],
                    "the grace counts from the pass that saw the thread, not from when the words were typed")
        }
    }

    @Test("Words past the grace survive a pass in which their thread's email is briefly gone, after a pass that saw it; words of a thread gone for the whole grace go")
    func wordsGoWithTheThreadsAIData() async throws {
        try await Self.withStore { pool, _, store in
            try FolderEpochTestFixture.insertFolder(accountId: Self.account, path: "INBOX", role: .inbox, pool: pool)
            let email = Self.header("l-1", thread: "lifetime")
            try await pool.write { try email.insert($0) }
            let key = ChatFieldWords.key(for: email)
            let fresh = ChatFieldWords.key(for: Self.header("l-2", thread: "fresh-orphan"))
            store.apply(.put("Kept while the email is here"), to: key)
            store.apply(.put("Typed today"), to: fresh)
            await store.written()
            try Self.age(key, pool: pool)
            let database = PrioritizedDatabase(pool: pool)
            let seen = Date()

            // A pass that sees the thread's email.
            SyncEngine.runPurgeOrphanedChatFieldWords(dbPool: database, now: seen)
            #expect(try Self.rows(pool).map(\.sessionId).sorted() == [fresh, key].sorted(),
                    "the thread's email is here, and a fresh row waits out the grace as AI results do")

            // The email is briefly gone (a resync re-walking, a move between folders): the next pass
            // keeps the words, the grace counting from the pass that saw the thread.
            try await pool.write { _ = try MessageHeader.deleteOne($0, key: email.id) }
            SyncEngine.runPurgeOrphanedChatFieldWords(dbPool: database, now: try Self.later(1, from: seen))
            #expect(try Self.rows(pool).map(\.sessionId).sorted() == [fresh, key].sorted(),
                    "words past the grace survive their thread's email being briefly gone")

            // Gone for the whole grace since the last pass that saw it: the words go, and so does
            // the fresh row no pass ever saw with an email.
            SyncEngine.runPurgeOrphanedChatFieldWords(
                dbPool: database, now: try Self.later(SyncConfig.aiCacheOrphanGraceDays + 1, from: seen))
            #expect(try Self.rows(pool).isEmpty, "no email of the thread for the whole grace: its words went")
        }
    }

    /// The ways the app deletes a thread's emails to download them again.
    enum Resync: String, CaseIterable, Sendable {
        /// Settings' Delete All Email Index Data (`SettingsView.localIndexWipeTxn`).
        case indexWipe
        /// An account's Reset Message Data (`AccountDetailView.resetMessageDataTxn`).
        case accountReset
        /// A folder's UIDVALIDITY change (`AccountManager.uidValidityResetPurgeTxn`).
        case uidValidity

        /// Deletes the emails of `account`'s INBOX in `pool` as this resync does.
        @MainActor
        func run(_ pool: DatabasePool, account: String) async throws {
            switch self {
            case .indexWipe:
                try await pool.write { try SettingsView.localIndexWipeTxn($0) }
            case .accountReset:
                try await pool.write { try AccountDetailView.resetMessageDataTxn($0, accountId: account) }
            case .uidValidity:
                let purged = await AccountManager.shared.uidValidityResetPurgeTxn(
                    accountId: account, folderPath: "INBOX",
                    folderId: MessageIdentity.folderId(accountId: account, folderPath: "INBOX"))
                let committed = purged != nil
                #expect(committed, "control: the folder's purge committed")
            }
        }
    }

    @Test("Every resync (Delete All Email Index Data, Reset Message Data, a UIDVALIDITY change) keeps a thread's old unsent words for the full grace from the reset, whether a maintenance pass last saw the thread partway through the grace or none ran since the words aged past it; once the full grace from the reset passes with the thread still gone its words go; an orphan already past the grace goes; after the resync the words show again",
          arguments: Resync.allCases, [true, false])
    func resyncKeepsTheWordsForTheFullGrace(_ resync: Resync, passSawTheThread: Bool) async throws {
        try await Self.withStore { pool, storage, store in
            try FolderEpochTestFixture.insertFolder(accountId: Self.account, path: "INBOX", role: .inbox, pool: pool)
            let tag = "\(resync.rawValue)-\(passSawTheThread)"
            let email = Self.header("w-1-\(tag)", thread: "wiped-\(tag)")
            // A thread whose email the resync never brings back (deleted on the server meanwhile).
            let lost = Self.header("w-3-\(tag)", thread: "lost-\(tag)")
            try await pool.write { db in
                try email.insert(db)
                try lost.insert(db)
            }
            let key = ChatFieldWords.key(for: email)
            let lostKey = ChatFieldWords.key(for: lost)
            // A thread with no email on the device.
            let orphan = ChatFieldWords.key(for: Self.header("w-2-\(tag)", thread: "gone-\(tag)"))
            let words = "Typed long before the reset"
            store.apply(.put(words), to: key)
            store.apply(.put("Words of a thread the resync loses"), to: lostKey)
            store.apply(.put("Words of a thread long gone"), to: orphan)
            await store.written()
            for live in [key, lostKey] { try Self.age(live, pool: pool) }
            let database = PrioritizedDatabase(pool: pool)
            // With `passSawTheThread`, the last maintenance pass saw the threads half the grace
            // before the reset: their words are inside the grace, which ends well before the
            // reset's. Without it, no pass ran since the words aged past the grace (the app was not
            // polled): only the reset itself can mark the threads as seen.
            if passSawTheThread {
                let lastPass = try Self.hours(-SyncConfig.aiCacheOrphanGraceDays * 12, after: Date())
                SyncEngine.runPurgeOrphanedChatFieldWords(dbPool: database, now: lastPass)
                #expect(try Self.rows(pool).map(\.sessionId).sorted() == [key, lostKey, orphan].sorted(),
                        "control: the last pass kept every row")
            }
            // The orphan is past the grace when the reset runs.
            try Self.age(orphan, pool: pool)

            let reset = Date()
            try await resync.run(pool, account: Self.account)
            let left = try await pool.read { try MessageHeader.fetchCount($0) }
            #expect(left == 0, "control: the reset deleted the threads' emails")
            let deadline = try Self.later(SyncConfig.aiCacheOrphanGraceDays, from: reset)
            // The first poll after the reset runs maintenance before the threads are back, an hour
            // inside the full grace counted from the reset.
            SyncEngine.runPurgeOrphanedChatFieldWords(dbPool: database, now: try Self.hours(-1, after: deadline))
            #expect(try Self.rows(pool).map(\.sessionId).sorted() == [key, lostKey].sorted(),
                    "the live threads' words wait out the full grace from the reset; the orphan past the grace went")

            // The resync restores one thread; the other never comes back. An hour past the full
            // grace from the reset, the lost thread's words go and the restored thread's stay.
            try await pool.write { try email.insert($0) }
            SyncEngine.runPurgeOrphanedChatFieldWords(dbPool: database, now: try Self.hours(1, after: deadline))
            #expect(try Self.rows(pool).map(\.sessionId) == [key],
                    "no email of the lost thread for the full grace from the reset: its words went")
            #expect(await Self.nextRun(storage, key) == words, "the restored thread's unsent words show again")
        }
    }

    @Test("The re-stamp binds one key per statement: more live chats than SQLite's bound-variable limit are all re-stamped, and the transaction it runs in commits")
    func restampHasNoBoundVariableLimit() async throws {
        try await Self.withStore { pool, _, store in
            try FolderEpochTestFixture.insertFolder(accountId: Self.account, path: "INBOX", role: .inbox, pool: pool)
            // The writer's limit for this test: twice as many live chats as bound variables.
            let limit: Int32 = 8
            let emails = (0..<Int(limit) * 2).map { Self.header("v-\($0)", thread: "bound-\($0)") }
            try await pool.write { db in
                for email in emails { try email.insert(db) }
            }
            let keys = emails.map { ChatFieldWords.key(for: $0) }
            for key in keys { store.apply(.put("Words of \(key)"), to: key) }
            await store.written()
            for key in keys { try Self.age(key, pool: pool) }
            let now = Date()
            let live = try await pool.write { db -> Set<String>? in
                guard let connection = db.sqliteConnection else { return nil }
                let previous = sqlite3_limit(connection, SQLITE_LIMIT_VARIABLE_NUMBER, limit)
                defer { sqlite3_limit(connection, SQLITE_LIMIT_VARIABLE_NUMBER, previous) }
                return try ChatFieldWords.restampLive(db: db, now: now)
            }
            #expect(live == Set(keys), "every live chat's key")
            let stamps = try Self.rows(pool).map(\.updatedAt)
            let restamped = stamps.count == keys.count && stamps.allSatisfy { abs($0.timeIntervalSince(now)) < 1 }
            #expect(restamped, "every row re-stamped: \(stamps)")
        }
    }

    @Test("A thread's email in another account keeps no words alive; an email with no thread id keeps its own")
    func orphanRuleIsPerAccountAndThreadless() async throws {
        try await Self.withStore { pool, _, store in
            let other = Self.account + "-other"
            for account in [Self.account, other] {
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
            // The pass above saw the email and re-stamped the row, so age it past the grace again.
            try Self.age(threadlessKey, pool: pool)
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
            for key in [removed, kept] { store.apply(.put("Words of \(key)"), to: key) }
            await store.written()
            // The demo-scoped row of the same account, persisted as a demo run's write lands it
            // (no demo runs here, so the store would refuse it): inserted directly.
            try await pool.write {
                try ChatFieldWordsRecord(sessionId: removedDemo, words: "Demo words of the removed account", updatedAt: Date()).insert($0)
            }
            let before = try Self.rows(pool)
            #expect(Set(before.map(\.sessionId)) == [removed, removedDemo, kept], "control: all three rows are stored")
            let account = Self.account
            // No demo wipe follows: only the account removal may delete the demo row.
            try await pool.write { try AccountManager.removeAccountRowsTxn($0, accountId: account, wasPrimary: false) }
            let stored = try Self.rows(pool)
            #expect(stored.map(\.sessionId) == [kept], "the removed account's real and demo words are gone, the other account's stay")
        }
    }

    @Test("A demo's kept words go with the demo; real ones stay")
    func demoWipeRemovesDemoWords() async throws {
        DemoModeStore.shared._resetForTests()
        defer { DemoModeStore.shared._resetForTests() }
        try await Self.withStore { pool, _, store in
            // A real chat's key, taken before the demo starts: once one runs, `key(for:)`
            // scopes every key to the demo.
            let real = ChatFieldWords.key(for: Self.header("d-1", thread: "real"))
            #expect(!real.hasPrefix("demo:"), "control: the real chat's key is not demo-scoped")
            // A demo runs, so the store admits its words and they reach the disk.
            DemoModeStore.shared.isActive = true
            let demo = "demo:" + ChatThreadKey.key(accountId: DemoSeed.demoAccountId, threadId: "demo-thread")
            store.apply(.put("Real words"), to: real)
            store.apply(.put("Demo words"), to: demo)
            await store.written()
            #expect(Set(try Self.rows(pool).map(\.sessionId)) == [real, demo], "control: the demo's words were stored")
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
    /// words forgotten, the demo's rows wiped), then starts the next run, its account seeded anew.
    private static func endDemoAndStartTheNext(_ store: ChatFieldWords, pool: DatabasePool) async throws {
        DemoModeStore.shared.revokeAdmission()
        store.forgetDemo()
        try await pool.write { try DemoSeed.wipe($0) }
        DemoModeStore.shared.isActive = false
        DemoModeStore.shared.isActive = true
        try insertAccount(DemoSeed.demoAccountId, pool: pool)
    }

    /// Removes the account `account` as `AccountManager.removeAccount` does: its row-delete
    /// transaction, then the store forgets its words.
    private static func remove(_ account: String, store: ChatFieldWords, pool: DatabasePool) async throws {
        try await pool.write { try AccountManager.removeAccountRowsTxn($0, accountId: account, wasPrimary: false) }
        store.forgetAccount(account)
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
            let afterRemoval = storage.batchCount
            storage.releaseWrites()
            await store.written()
            storage.failWrites(false)
            store.apply(.put("Live account's newer words"), to: live)
            await store.written()

            let stored = try Self.storedWords(pool)
            #expect(stored == [live: "Live account's newer words"], "\(stored)")
            // The store never offers a removed account's words to a write again, a failed write's
            // retry included: the transaction's own refusal is the second fence, not the only one.
            let later = storage.batchKeys(from: afterRemoval)
            #expect(later.contains { $0.contains(live) }, "control: the live chat's words were written after the removal")
            #expect(!later.contains { $0.contains(removed) }, "the removed account's words reached a write again: \(later)")
            #expect(store.fill(for: removed).words == "")
            #expect(await Self.nextRun(storage, removed) == "")
        }
    }

    @Test("A removal that fails keeps every word of the account: typed before it and not yet written, and written while it ran")
    func failedRemovalKeepsTheWords() async throws {
        try await Self.withStore { pool, storage, store in
            let earlier = ChatFieldWords.key(for: Self.header("fr-1", thread: "typed-earlier"))
            let inFlight = ChatFieldWords.key(for: Self.header("fr-2", thread: "in-flight"))
            // Typed earlier, its write failed: only memory has it.
            storage.failWrites(true)
            store.apply(.put("Typed earlier"), to: earlier)
            await store.written()
            storage.failWrites(false)
            let onDisk751 = try Self.rows(pool)
            #expect(onDisk751.isEmpty, "control: not on disk")

            // A write waits as the removal's delete runs and fails (as `AccountRemovalSavedFilesGrew`
            // refuses it): the transaction rolls back, the account row stays.
            storage.holdWrites()
            store.apply(.put("Written as it ran"), to: inFlight)
            #expect(await storage.waitForWrites(2), "control: the write is running")
            struct Refused: Error {}
            let account = Self.account
            await #expect(throws: Refused.self) {
                try await pool.write { db in
                    try AccountManager.removeAccountRowsTxn(db, accountId: account, wasPrimary: false)
                    throw Refused()
                }
            }
            storage.releaseWrites()
            await store.written()
            store.saveUnwritten()
            await store.written()
            let onDisk768 = try Self.storedWords(pool)
            #expect(onDisk768 == [earlier: "Typed earlier", inFlight: "Written as it ran"])
            #expect(store.fill(for: earlier).words == "Typed earlier")
            #expect(await Self.nextRun(storage, earlier) == "Typed earlier")
        }
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
            let afterEnd = storage.batchCount
            storage.releaseWrites()
            await store.written()
            storage.failWrites(false)
            // A field edit in the next demo starts the writer again.
            store.apply(.put("Next words"), to: next)
            await store.written()
            let later = storage.batchKeys(from: afterEnd)
            #expect(later.contains { $0.contains(next) }, "control: the next words were written after the demo ended")
            #expect(!later.contains { $0.contains(demo) }, "the ended demo's words reached a write again: \(later)")

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

    @Test("A read of a demo chat started after the demo's exit forgot it, while the wipe waits, never brings the old words into the next demo; a live demo's and a real chat's reads land")
    func readStartedDuringTheDemosExitNeverLands() async throws {
        DemoModeStore.shared._resetForTests()
        defer { DemoModeStore.shared._resetForTests() }
        try await Self.withStore { pool, storage, run in
            DemoModeStore.shared.isActive = true
            let demo = Self.demoKey("exit-read")
            let real = ChatThreadKey.key(accountId: Self.account, threadId: "real-during-exit")
            try await pool.write { db in
                try ChatFieldWordsRecord(sessionId: demo, words: "Old demo words", updatedAt: Date()).insert(db)
                try ChatFieldWordsRecord(sessionId: real, words: "Real words", updatedAt: Date()).insert(db)
            }

            // Control: in a live demo, a held read of the same key lands.
            let live = ChatFieldWords(storage: storage.storage)
            storage.hold(resultsOf: demo)
            let liveLoad = Task { await live.load(demo) }
            #expect(await storage.waitForHeldResult(of: demo), "control: the live demo's read has its words")
            storage.release(resultsOf: demo)
            await liveLoad.value
            #expect(live.fill(for: demo).words == "Old demo words", "control: a live demo's read lands")

            // The exit revokes the run and forgets its words; the wipe has not run yet.
            DemoModeStore.shared.revokeAdmission()
            run.forgetDemo()
            storage.hold(resultsOf: demo)
            let finished = Finished()
            let lateLoad = Task { await run.load(demo); finished.value = true }
            let deadline = ContinuousClock.now + ControlledStorage.waitLimit
            while !finished.value, storage.heldResultCount(of: demo) == 0, ContinuousClock.now < deadline {
                try await Task.sleep(for: .milliseconds(10))
            }
            // Control: a real chat's read during the exit lands.
            await run.load(real)
            #expect(run.fill(for: real).words == "Real words", "control: a real chat's read lands during the exit")

            // The wipe finishes, the demo ends and the next one is seeded; then the read is released.
            try await pool.write { try DemoSeed.wipe($0) }
            DemoModeStore.shared.isActive = false
            DemoModeStore.shared.isActive = true
            try Self.insertAccount(DemoSeed.demoAccountId, pool: pool)
            storage.release(resultsOf: demo)
            await lateLoad.value

            #expect(run.fill(for: demo).words == "", "the old words are not in the next demo's field")
            await run.load(demo)
            #expect(run.fill(for: demo).words == "", "and the next demo's own read finds none")
            run.apply(.put("Next demo's words"), to: demo)
            await run.written()
            let stored = try Self.storedWords(pool)
            #expect(stored == [real: "Real words", demo: "Next demo's words"], "\(stored)")
        }
    }

    // MARK: - 9. Seeded concurrency fuzz

    /// The fuzzer's bounds: a fixed seed list, a small iteration count, and the faults and
    /// latency injected into storage.
    enum FuzzConfig {
        static let seeds: [UInt64] = [1, 7, 42, 1009, 65_537]
        static let iterationsPerSeed = 4
        static let operationsPerIteration = 60
        static let writeFaultOneIn = 4
        static let maxLatencyMicroseconds = 400
    }

    /// Seeded random sequences of field changes (put, send, answer, transcript), reads, save points,
    /// writes, account removals (their delete committed, or rolled back) and demo runs ended and
    /// seeded anew, against storage with seeded write faults and latency before and after the
    /// database. Checked against a model, never a schedule: the newest unsent words of a live chat
    /// are in its field and on disk once a save point succeeds (a failed write's words included), a
    /// load never changes a fill, and a removed account's or an ended demo's words never come back.
    /// Acceptance mutant: dropping the account-row check from `ChatFieldWords.Storage.admits` lets a
    /// write running across a removal land on a removed account's chat, which the disk check reports.
    @Test("Seeded fuzz: the newest unsent words win, failed writes are retried, retired chats never get words back",
          arguments: FuzzConfig.seeds)
    func seededConcurrencyFuzz(seed: UInt64) async throws {
        for iteration in 0..<FuzzConfig.iterationsPerSeed {
            try await Self.fuzzOnce(seed: seed &+ UInt64(iteration) &* 0x1_0000_0001, label: "seed \(seed) iteration \(iteration)")
        }
    }

    private static func fuzzOnce(seed: UInt64, label: String) async throws {
        DemoModeStore.shared._resetForTests()
        defer { DemoModeStore.shared._resetForTests() }
        try await withStore { pool, storage, store in
            DemoModeStore.shared.isActive = true
            var rng = SplitMix64(seed: seed)
            storage.enableChaos(seed: seed ^ 0xC4A0_5EED, faultOneIn: FuzzConfig.writeFaultOneIn,
                                maxLatencyMicroseconds: FuzzConfig.maxLatencyMicroseconds)
            let accounts = ["fz-a", "fz-b", DemoSeed.demoAccountId]
            let keysOf: [String: [String]] = [
                "fz-a": ["fz-a-1", "fz-a-2"].map { ChatThreadKey.key(accountId: "fz-a", threadId: $0) },
                "fz-b": ["fz-b-1", "fz-b-2"].map { ChatThreadKey.key(accountId: "fz-b", threadId: $0) },
                DemoSeed.demoAccountId: [demoKey("fz-d-1"), demoKey("fz-d-2")],
            ]
            let keys = accounts.flatMap { keysOf[$0]! }
            let accountOf = Dictionary(uniqueKeysWithValues: accounts.flatMap { a in keysOf[a]!.map { ($0, a) } })
            // The model: each live chat's fill, and the accounts whose words are retired.
            var model: [String: ChatFieldFill] = [:]
            var retired: Set<String> = []
            var loads: [Task<Void, Never>] = []
            var log: [String] = []
            let texts = ["", "Sounds good", "Tuesday works", "See you then", "Sounds good"]

            for _ in 0..<FuzzConfig.operationsPerIteration {
                let roll = rng.pick(100)
                if roll < 50 {
                    let key = keys[rng.pick(keys.count)]
                    let change: ChatFieldFill.Change
                    switch rng.pick(10) {
                    case 0...3: change = .put(texts[rng.pick(texts.count)] + (rng.pick(2) == 0 ? "" : " \(rng.pick(9))"))
                    case 4: change = .sentFromField
                    case 5: change = .answered
                    case 6: change = .completed
                    case 7: change = .startHearing
                    case 8: change = .heard("and Friday \(rng.pick(9))")
                    default:
                        let rare: [ChatFieldFill.Change] = [.sentFromSheet, .composeOpened, .confirmationCard]
                        change = rare[rng.pick(rare.count)]
                    }
                    log.append("apply \(change) \(key)")
                    store.apply(change, to: key)
                    if !retired.contains(accountOf[key]!) { model[key, default: ChatFieldFill()].apply(change) }
                } else if roll < 58 {
                    let key = keys[rng.pick(keys.count)]
                    log.append("load \(key)")
                    loads.append(Task { await store.load(key) })
                } else if roll < 66 {
                    // A real account removed: its delete commits, or fails and rolls back.
                    let account = ["fz-a", "fz-b"][rng.pick(2)]
                    if retired.contains(account) { continue }
                    if rng.pick(3) == 0 {
                        log.append("remove \(account)")
                        try await remove(account, store: store, pool: pool)
                        retired.insert(account)
                        for key in keysOf[account]! { model[key] = nil }
                    } else {
                        log.append("failedRemoval \(account)")
                        struct RolledBack: Error {}
                        _ = try? await pool.write { db in
                            try AccountManager.removeAccountRowsTxn(db, accountId: account, wasPrimary: false)
                            throw RolledBack()
                        }
                    }
                } else if roll < 70 {
                    // The demo ends (its account and rows wiped), and the next one is seeded.
                    log.append("demoReopen")
                    try await endDemoAndStartTheNext(store, pool: pool)
                    for key in keysOf[DemoSeed.demoAccountId]! { model[key] = nil }
                } else if roll < 80 {
                    log.append("written")
                    await store.written()
                } else if roll < 85 {
                    log.append("saveUnwritten")
                    store.saveUnwritten()
                } else {
                    for _ in 0..<rng.pick(6) { await Task.yield() }
                }
                for key in keys {
                    let expected = retired.contains(accountOf[key]!) ? "" : (model[key]?.words ?? "")
                    #expect(store.fill(for: key).words == expected,
                            "\(label): the field of \(key) is not the newest words; ops: \(log)")
                }
            }

            // Quiesce: loads land, faults stop, and one save point succeeds.
            for load in loads { await load.value }
            await store.written()
            storage.disableChaos()
            store.saveUnwritten()
            await store.written()

            let stored = try storedWords(pool)
            for key in keys {
                let gone = retired.contains(accountOf[key]!)
                let words = gone ? "" : (model[key]?.words ?? "")
                let unsent = gone ? "" : (model[key]?.unsent ?? "")
                #expect(store.fill(for: key).words == words,
                        "\(label): a load or late write changed the field of \(key); ops: \(log)")
                #expect(stored[key] == (unsent.isEmpty ? nil : unsent),
                        "\(label): \(key) stored \(stored[key] ?? "nothing"), the newest unsent words are \"\(unsent)\" (retired: \(gone)); ops: \(log)")
                #expect(await nextRun(storage, key) == unsent,
                        "\(label): a new run reads the wrong words for \(key); ops: \(log)")
            }
        }
    }
}
