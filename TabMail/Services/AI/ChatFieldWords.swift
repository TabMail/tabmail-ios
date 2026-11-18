/* This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at https://mozilla.org/MPL/2.0/. */

import Foundation
import GRDB

/// The unsent words of a chat's field, kept on this iPhone like Messages keeps them (ADR-IOS-117):
/// they are in the field again when the user comes back to the chat, also after the app was closed.
///
/// ONE store for every pill about an email (the chat view's reply field, the email screen's pill),
/// keyed by the thread's chat key, the one the chat history uses (`key(for:)`), so a newer email in
/// the thread keeps the words and another thread never shows them. Never synced, never sent, never
/// indexed, never logged.
///
/// Within the app run, `known` is what the field reads: a key's words are read from the database
/// once, and every change lands in memory at once and is written behind it, in order, the newest
/// words of a key winning. So Back and an immediate reopen never race the write.
@MainActor
final class ChatFieldWords {
    /// The app's store. A test installs a new one to start as a new app run would.
    static var shared = ChatFieldWords()

    /// The database the words are written to, read when used (tests install their own).
    private let database: @Sendable () -> PrioritizedDatabase
    /// The words of every key this run has read or changed; "" is none.
    private var known: [String: String] = [:]
    /// Keys whose words changed since they were last written, with the words to write.
    private var unwritten: [String: String] = [:]
    /// The write in progress, if any; it writes until `unwritten` is empty.
    private var writer: Task<Void, Never>?

    init(database: @escaping @Sendable () -> PrioritizedDatabase = { AppDatabase.dbPool }) {
        self.database = database
    }

    /// The key a pill about `message` keeps its words under: its thread's chat key
    /// (`ChatThreadKey`), `demo:`-scoped while a demo runs, as the chat history's.
    static func key(for message: MessageHeader) -> String {
        DemoModeStore.scopedSessionId(ChatThreadKey.key(for: message))
    }

    /// The words kept for `key`; "" when none.
    func words(for key: String) async -> String {
        if let words = known[key] { return words }
        // The raw pool: the words never come from the extension's staging, so the read needs
        // no staging merge first.
        let pool = database().pool
        let stored: String?
        do {
            stored = try await pool.read { db in
                try String.fetchOne(db, sql: "SELECT words FROM \(ChatFieldWordsRecord.databaseTableName) WHERE sessionId = ?",
                                    arguments: [key])
            }
        } catch {
            if DebugModeManager.isLoggingEnabled() {
                BackgroundSyncLogger.logDebug("[ChatFieldWords] read failed: \(type(of: error))")
            }
            return ""
        }
        // A change made while reading is newer than what was stored.
        if let words = known[key] { return words }
        known[key] = stored ?? ""
        return stored ?? ""
    }

    /// Keep `words` for `key`; "" removes them.
    func set(_ words: String, for key: String) {
        guard known[key] != words else { return }
        known[key] = words
        unwritten[key] = words
        guard writer == nil else { return }
        writer = Task { await writeUnwritten() }
    }

    /// Returns once every change made so far is written.
    func written() async {
        while let writer { await writer.value }
    }

    /// Forget a demo's words in this run: a demo's exit deletes its rows (`DemoSeed.wipe`), and the
    /// next demo's chats have the same keys.
    func forgetDemo() {
        known = known.filter { !$0.key.hasPrefix(Self.demoPrefix) }
        unwritten = unwritten.filter { !$0.key.hasPrefix(Self.demoPrefix) }
    }

    private nonisolated static let demoPrefix = "demo:"

    private func writeUnwritten() async {
        while !unwritten.isEmpty {
            let batch = unwritten
            unwritten = [:]
            let now = Date()
            do {
                try await database().write { db in
                    for (key, words) in batch {
                        if words.isEmpty {
                            try ChatFieldWordsRecord.filter(key: key).deleteAll(db)
                        } else {
                            try ChatFieldWordsRecord(sessionId: key, words: words, updatedAt: now).save(db)
                        }
                    }
                }
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
