/* This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at https://mozilla.org/MPL/2.0/. */

import Foundation
import GRDB
import Observation
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

    /// Where the words are read from and written to.
    struct Storage: Sendable {
        /// The words stored for a key; nil when none.
        let read: @Sendable (String) async throws -> String?
        /// Writes each key's words; "" deletes the key's row.
        let write: @Sendable ([String: String]) async throws -> Void

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
                    try await database().write { db in
                        for (key, words) in batch {
                            if words.isEmpty {
                                try ChatFieldWordsRecord.filter(key: key).deleteAll(db)
                            } else {
                                try ChatFieldWordsRecord(sessionId: key, words: words, updatedAt: now).save(db)
                            }
                        }
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
    @ObservationIgnored private var unwritten: [String: String] = [:]
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
        let before = fill(for: key)
        var after = before
        after.apply(change)
        guard after != before else { return }
        fills[key] = after
        changed.insert(key)
        guard after.unsent != before.unsent else { return }
        unwritten[key] = after.unsent
        guard writer == nil else { return }
        writer = Task { await writeUnwritten() }
    }

    /// Reads the chat `key`'s stored words into its fill, once in this run, unless the chat changed
    /// first or meanwhile. A failed read changes nothing: the stored words stay, and the next pill
    /// to show the chat reads them again. The read runs on its own, so a pill that goes away while
    /// it runs does not end it for another pill on the chat.
    func load(_ key: String) async {
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
        fills = fills.filter { !isDemo($0.key) }
        changed = changed.filter { !isDemo($0) }
        read = read.filter { !isDemo($0) }
        reading = reading.filter { !isDemo($0.key) }
        unwritten = unwritten.filter { !isDemo($0.key) }
    }

    private nonisolated static let demoPrefix = "demo:"

    private func writeUnwritten() async {
        while !unwritten.isEmpty {
            let batch = unwritten
            unwritten = [:]
            do {
                try await storage.write(batch)
            } catch {
                // Kept in memory for this run; the next change writes them again.
                for (key, words) in batch where unwritten[key] == nil { unwritten[key] = words }
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
