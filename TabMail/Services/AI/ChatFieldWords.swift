/* This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at https://mozilla.org/MPL/2.0/. */

import Foundation
import GRDB
import Observation
import Synchronization
import SwiftUI

/// The unsent words of a chat's field, kept on this iPhone like Messages keeps them (ADR-IOS-117):
/// they are in the field again when the user comes back to the chat, also after the app was closed.
///
/// ONE owner of a chat's words for every pill about an email (the chat view's reply field, the
/// email screen's pill), keyed by the thread's chat key, the one the chat history uses
/// (`key(for:)`), so a newer email in the thread keeps the words and another thread never shows
/// them. Every pill on a chat reads and changes the same fill (`apply`), so two pills on one chat
/// never hold two drafts. Never synced, never sent, never indexed, never logged.
///
/// A chat's stored words are read into its fill once in this run (`load`), and only while nothing
/// changed it: a change made first is the user's newer intention (typed, emptied, sent, dictating),
/// and is what is kept. A read that fails changes nothing, so the stored words stay for the next
/// read. Every change lands in memory at once and is written behind it, in order, the newest words
/// of a key winning, so Back and an immediate reopen never race the write.
@MainActor
@Observable
final class ChatFieldWords {
    /// The app's store. A test installs a new one to start as a new app run would.
    static var shared = ChatFieldWords()

    /// A chat's words to write, with what decides whether they may still be written.
    struct Write: Sendable {
        /// "" deletes the chat's row.
        let words: String
        /// The demo run the words were typed in (`DemoModeStore.chatAdmission`); nil outside one.
        let admission: DemoModeStore.Admission?
        /// The store's record of accounts being removed and removed.
        let lifetimes: Lifetimes

        /// Whether the words may be written now: not while their account's removal runs, never once
        /// it is removed, never once their demo ended.
        func admits(_ key: String) -> Bool { lifetimes.admits(key, admission: admission) }

        /// Whether the words are still the user's: their account is not removed and their demo run
        /// has not ended. A removal still running holds them; it does not end them.
        func isKept(_ key: String) -> Bool { !lifetimes.isGone(key, admission: admission) }
    }

    /// One account removal's hold on its account's words (`beginRemoval`). Only its own removal
    /// releases it (`commitRemoval`, `rollBackRemoval`), so overlapping removals of one account never release each
    /// other's, as the push cleanup's per-attempt generations do.
    struct Removal: Sendable, Equatable {
        let accountId: String
        fileprivate let attempt: UInt64
    }

    /// Which accounts' words may be written: none of an account whose removal runs (each attempt's
    /// own hold), none of an account removed in this run. Checked inside the write's own
    /// transaction, so a write lands before the account's row-delete transaction (and is deleted by
    /// it) or is refused.
    final class Lifetimes: Sendable {
        private struct State {
            var holds: [String: Set<UInt64>] = [:]
            var removed: Set<String> = []
            var lastAttempt: UInt64 = 0
        }
        private let state = Mutex(State())

        func hold(_ accountId: String) -> Removal {
            state.withLock { state in
                state.lastAttempt += 1
                state.holds[accountId, default: []].insert(state.lastAttempt)
                return Removal(accountId: accountId, attempt: state.lastAttempt)
            }
        }

        /// Ends `removal`'s hold; `committed` records its account as removed.
        func release(_ removal: Removal, committed: Bool) {
            state.withLock { state in
                state.holds[removal.accountId]?.remove(removal.attempt)
                if state.holds[removal.accountId]?.isEmpty == true { state.holds[removal.accountId] = nil }
                if committed { state.removed.insert(removal.accountId) }
            }
        }

        /// The account `accountId` exists again (the demo's fixed account, seeded anew).
        func reopen(_ accountId: String) {
            state.withLock { _ = $0.removed.remove(accountId) }
        }

        /// Whether a removal of the chat `key`'s account is running.
        func isHeld(_ key: String) -> Bool {
            guard let accountId = ChatThreadKey.parse(key)?.accountId else { return false }
            return state.withLock { $0.holds[accountId] != nil }
        }

        /// Whether the chat `key`'s words are no longer anyone's: its account was removed, or its
        /// demo run (`admission`) is not the current one or ended.
        func isGone(_ key: String, admission: DemoModeStore.Admission?) -> Bool {
            if let accountId = ChatThreadKey.parse(key)?.accountId, state.withLock({ $0.removed.contains(accountId) }) {
                return true
            }
            return !DemoModeStore.admits(sessionId: key, admission: admission)
        }

        /// Whether the chat `key`'s words may be written now.
        func admits(_ key: String, admission: DemoModeStore.Admission?) -> Bool {
            !isHeld(key) && !isGone(key, admission: admission)
        }
    }

    /// Where the words are read from and written to.
    struct Storage: Sendable {
        /// The words stored for a key; nil when none.
        let read: @Sendable (String) async throws -> String?
        /// Writes each key's words; "" deletes the key's row. Words of an account being removed or
        /// removed, or of an ended demo, are refused (`Write.admits`).
        /// Returns the keys it refused.
        let write: @Sendable ([String: Write]) async throws -> Set<String>

        /// The app's database (tests install their own).
        static func database(_ database: @escaping @Sendable () -> PrioritizedDatabase) -> Storage {
            Storage(
                read: { key in
                    // The raw pool: the words never come from the extension's staging, so the
                    // read needs no staging merge first.
                    try await database().pool.read { db in
                        try String.fetchOne(
                            db, sql: "SELECT words FROM \(ChatFieldWordsRecord.databaseTableName) WHERE sessionId = ?",
                            arguments: [key])
                    }
                },
                write: { batch in
                    let now = Date()
                    return try await database().write { db -> Set<String> in
                        var refused: Set<String> = []
                        for (key, write) in batch {
                            if write.words.isEmpty {
                                try ChatFieldWordsRecord.filter(key: key).deleteAll(db)
                            } else if write.admits(key) {
                                try ChatFieldWordsRecord(sessionId: key, words: write.words, updatedAt: now).save(db)
                            } else {
                                refused.insert(key)
                            }
                        }
                        return refused
                    }
                })
        }
    }

    private let storage: Storage
    /// The fill of every chat this run has read or changed: what each pill on the chat shows.
    private var fills: [String: ChatFieldFill] = [:]
    /// Chats changed in this run: their fill is newer than anything stored, and no read replaces it.
    @ObservationIgnored private var changed: Set<String> = []
    /// Chats whose stored words this run has read.
    @ObservationIgnored private var read: Set<String> = []
    /// The read in progress of each chat. Its id tells the chat's current read from an obsolete one.
    @ObservationIgnored private var reading: [String: (id: UUID, task: Task<String?, Error>)] = [:]
    /// Chats whose words changed since they were last written, with the words to write.
    @ObservationIgnored private var unwritten: [String: Write] = [:]
    /// The accounts being removed and removed in this run (`beginRemoval`).
    private let lifetimes = Lifetimes()
    /// The write in progress, if any; it writes until `unwritten` is empty.
    @ObservationIgnored private var writer: Task<Void, Never>?

    init(storage: Storage = .database { AppDatabase.dbPool }) {
        self.storage = storage
    }

    convenience init(database: @escaping @Sendable () -> PrioritizedDatabase) {
        self.init(storage: .database(database))
    }

    /// The key a pill about `message` keeps its words under: its thread's chat key
    /// (`ChatThreadKey`), `demo:`-scoped while a demo runs, as the chat history's.
    static func key(for message: MessageHeader) -> String {
        DemoModeStore.scopedSessionId(ChatThreadKey.key(for: message))
    }

    /// The chat `key`'s fill: its words and its field's state, as every pill on it shows them.
    func fill(for key: String) -> ChatFieldFill {
        fills[key] ?? ChatFieldFill()
    }

    /// The only way a chat's words change (`ChatFieldFill.apply`), from any pill on it. What is
    /// not sent (`ChatFieldFill.unsent`) is kept whenever it changes; "" keeps nothing.
    func apply(_ change: ChatFieldFill.Change, to key: String) {
        // A removed account's chat, or an ended demo's, keeps nothing. One whose removal runs keeps
        // its words in memory until the removal commits or fails.
        let admission = DemoModeStore.shared.chatAdmission
        guard !lifetimes.isGone(key, admission: admission) else { return }
        let before = fill(for: key)
        var after = before
        after.apply(change)
        guard after != before else { return }
        fills[key] = after
        changed.insert(key)
        guard after.unsent != before.unsent else { return }
        unwritten[key] = Write(words: after.unsent, admission: admission, lifetimes: lifetimes)
        startWriter()
    }

    /// A save point: writes what a failed write left unsaved in memory. The next change is one
    /// (`apply`); so are the app going to the background (`RootView`) and a pill showing a chat
    /// (`load`). No timer and no retry count: words stay unsaved until a save point succeeds.
    func saveUnwritten() {
        startWriter()
    }

    /// Starts the one writer, unless it runs or nothing waits. The writer takes each key's
    /// newest words at the moment it builds its batch.
    private func startWriter() {
        guard writer == nil, !unwritten.isEmpty else { return }
        writer = Task { await writeUnwritten() }
    }

    /// Reads the chat `key`'s stored words into its fill, once in this run, unless the chat changed
    /// first or meanwhile. A failed read changes nothing: the stored words stay, and the next pill
    /// to show the chat reads them again. The read runs on its own, so a pill that goes away while
    /// it runs does not end it for another pill on the chat.
    func load(_ key: String) async {
        // Showing a chat is a save point for what a failed write left unsaved.
        saveUnwritten()
        // A read for a removed account's chat, or an ended demo's, never starts, and one whose
        // account or demo run ended while it ran never lands (S1: a read started after a demo's
        // exit forgot it, while its wipe runs, would bring the old words back into the next run).
        let admission = DemoModeStore.shared.chatAdmission
        guard !lifetimes.isGone(key, admission: admission) else { return }
        guard !changed.contains(key), !read.contains(key) else { return }
        let current: (id: UUID, task: Task<String?, Error>)
        if let inFlight = reading[key] {
            current = inFlight
        } else {
            let storage = storage
            current = (UUID(), Task { try await storage.read(key) })
            reading[key] = current
        }
        let stored: String?
        do {
            stored = try await current.task.value
        } catch {
            if reading[key]?.id == current.id { reading[key] = nil }
            if DebugModeManager.isLoggingEnabled() {
                BackgroundSyncLogger.logDebug("[ChatFieldWords] read failed: \(type(of: error))")
            }
            return
        }
        // Only the chat's current read lands (a demo's exit makes its reads obsolete), and only
        // on a chat nothing changed.
        guard reading[key]?.id == current.id else { return }
        reading[key] = nil
        guard !lifetimes.isGone(key, admission: admission) else { return }
        guard !changed.contains(key) else { return }
        read.insert(key)
        guard let stored, !stored.isEmpty else { return }
        var fill = ChatFieldFill()
        fill.apply(.put(stored))
        fills[key] = fill
    }

    /// Returns once every change made so far is written.
    func written() async {
        while let writer { await writer.value }
    }

    /// Forget a demo's words in this run: a demo's exit deletes its rows (`DemoSeed.wipe`), and the
    /// next demo's chats have the same keys.
    func forgetDemo() {
        let isDemo = { (key: String) in key.hasPrefix(Self.demoPrefix) }
        forget(where: isDemo)
    }

    /// An account removal begins: no word of the account's chats, real or demo, is written until it
    /// ends (`commitRemoval`, `rollBackRemoval`); they stay in memory meanwhile. Account removal calls it before its
    /// row-delete transaction (`AccountManager.removeAccount`), as it does
    /// `AccountFieldPersistenceStore.discardAccount`.
    func beginRemoval(_ accountId: String) -> Removal {
        lifetimes.hold(accountId)
    }

    /// The removal `removal` committed: the account's words are forgotten and never written again
    /// in this run, a write in progress or a failed write's retry included.
    func commitRemoval(_ removal: Removal) {
        lifetimes.release(removal, committed: true)
        forget { ChatThreadKey.parse($0)?.accountId == removal.accountId }
    }

    /// The removal `removal` failed: the words it held are kept, and written unless another
    /// removal of the account still runs.
    func rollBackRemoval(_ removal: Removal) {
        lifetimes.release(removal, committed: false)
        startWriter()
    }

    /// The account `accountId` exists again: the demo's fixed account, seeded anew once its seed
    /// committed (`DemoModeService.completeSetup`). An ended demo run's words stay refused by their
    /// run's admission.
    func reopenAccount(_ accountId: String) {
        lifetimes.reopen(accountId)
    }

    /// Forget every chat `matches` names: its fill, its reads (a read in progress lands nowhere),
    /// and its words not yet written.
    private func forget(where matches: (String) -> Bool) {
        fills = fills.filter { !matches($0.key) }
        changed = changed.filter { !matches($0) }
        read = read.filter { !matches($0) }
        reading = reading.filter { !matches($0.key) }
        unwritten = unwritten.filter { !matches($0.key) }
    }

    private nonisolated static let demoPrefix = "demo:"

    private func writeUnwritten() async {
        while true {
            // Words an account removal holds wait in memory (`rollBackRemoval`).
            let batch = unwritten.filter { !lifetimes.isHeld($0.key) }
            guard !batch.isEmpty else { break }
            for key in batch.keys { unwritten[key] = nil }
            do {
                let refused = try await storage.write(batch)
                // Words the transaction refused are kept unless their account was removed or their
                // demo ended, whether or not the removal that held them has ended since: one still
                // held waits for its end (`rollBackRemoval`), one released is written next.
                for key in refused {
                    guard let write = batch[key], unwritten[key] == nil, write.isKept(key) else { continue }
                    unwritten[key] = write
                }
            } catch {
                // Kept unsaved in memory; the next save point (`saveUnwritten`, a change) writes them. A removed
                // account's, or an ended demo's, are not: they were forgotten while this wrote.
                for (key, write) in batch where unwritten[key] == nil && write.isKept(key) { unwritten[key] = write }
                if DebugModeManager.isLoggingEnabled() {
                    BackgroundSyncLogger.logDebug("[ChatFieldWords] write failed: \(type(of: error))")
                }
                break
            }
        }
        writer = nil
    }

    /// A pill's handle on its words: its chat's fill here when it is about an email (`key`), else
    /// its own (`own`: the inbox's chat and a compose's pill keep none).
    @MainActor
    struct Field {
        let key: String?
        let own: Binding<ChatFieldFill>

        var words: String {
            guard let key else { return own.wrappedValue.words }
            return ChatFieldWords.shared.fill(for: key).words
        }

        func apply(_ change: ChatFieldFill.Change) {
            guard let key else { own.wrappedValue.apply(change); return }
            ChatFieldWords.shared.apply(change, to: key)
        }
    }

    // MARK: - Lifetime

    /// Delete the words of every thread with no email left on the device: a row untouched for
    /// `SyncConfig.aiCacheOrphanGraceDays` whose key names no email of its account and thread
    /// (`ChatThreadKey.memberSQL`), or no thread at all. The rule the thread's AI results live by
    /// (`SyncEngine.runPurgeOrphanedAICache`), run in the same pass. Returns how many went.
    @discardableResult
    nonisolated static func purgeOrphans(db: Database, now: Date) throws -> Int {
        let cutoff = Calendar.current.date(byAdding: .day, value: -SyncConfig.aiCacheOrphanGraceDays, to: now) ?? .distantPast
        let keys = try String.fetchAll(
            db, sql: "SELECT sessionId FROM \(ChatFieldWordsRecord.databaseTableName) WHERE updatedAt < ?",
            arguments: [cutoff])
        var purged = 0
        for key in keys {
            if let (accountId, threadId) = ChatThreadKey.parse(key),
               try Bool.fetchOne(db, sql: "SELECT EXISTS(SELECT 1 FROM messageHeader WHERE \(ChatThreadKey.memberSQL))",
                                 arguments: [accountId, threadId, threadId]) == true {
                continue
            }
            purged += try ChatFieldWordsRecord.filter(key: key).deleteAll(db)
        }
        return purged
    }

    /// Delete every row of the account `accountId`, real and demo: part of the account's
    /// row-delete transaction (`AccountManager.removeAccountRowsTxn`).
    nonisolated static func deleteAccount(_ accountId: String, db: Database) throws {
        let thread = ChatThreadKey.prefix + MessageIdentity.escapeForLike(accountId) + ":%"
        try db.execute(
            sql: #"DELETE FROM chatFieldWords WHERE sessionId LIKE ? ESCAPE '\' OR sessionId LIKE ? ESCAPE '\'"#,
            arguments: [thread, demoPrefix + thread])
    }
}

/// A row of `chatFieldWords` (`v109_addChatFieldWords`): one chat's unsent words.
struct ChatFieldWordsRecord: Codable, FetchableRecord, PersistableRecord, Equatable, Sendable {
    static let databaseTableName = "chatFieldWords"
    /// The thread's chat key (`ChatFieldWords.key(for:)`).
    var sessionId: String
    var words: String
    /// When the words last changed.
    var updatedAt: Date
}
