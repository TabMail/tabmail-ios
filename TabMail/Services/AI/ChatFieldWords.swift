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
///
/// A field send's own transitions (its confirmation card, the agent's answer, its compose card
/// opening and its reply going out) are applied here by the request, on the key captured when it was
/// sent (`ToolInvocation.fieldWordsKey`), never by a view on the chat it shows by then: a pill that
/// moved to another chat, or a chat closed before the answer, cannot misroute or miss them.
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
    }

    /// Where the words are read from and written to.
    struct Storage: Sendable {
        /// The words stored for a key; nil when none.
        let read: @Sendable (String) async throws -> String?
        /// Writes each key's words; "" deletes the key's row. Words whose account row is gone, or
        /// of an ended demo, are refused and dropped (`admits`).
        let write: @Sendable ([String: Write]) async throws -> Void

        /// Whether `write` may land under `key`, checked inside the write's own transaction: the
        /// key's account row still exists and its demo run is the current one. The account's
        /// removal deletes its row and its words in one transaction (`AccountManager.removeAccountRowsTxn`,
        /// `DemoSeed.wipe`), so a write lands before it (and is deleted by it) or is refused after
        /// it; a removal that rolls back leaves the row, so the write lands. As
        /// `AccountFieldPersistenceStore.persist` guards account writes.
        nonisolated static func admits(_ key: String, write: Write, db: Database) throws -> Bool {
            guard DemoModeStore.admits(sessionId: key, admission: write.admission) else { return false }
            guard let accountId = ChatThreadKey.parse(key)?.accountId else { return false }
            return try Bool.fetchOne(db, sql: "SELECT EXISTS(SELECT 1 FROM account WHERE id = ?)", arguments: [accountId]) == true
        }

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
                        for (key, write) in batch {
                            if write.words.isEmpty {
                                try ChatFieldWordsRecord.filter(key: key).deleteAll(db)
                            } else if try admits(key, write: write, db: db) {
                                try ChatFieldWordsRecord(sessionId: key, words: write.words, updatedAt: now).save(db)
                            }
                            // A refused write is dropped: its account or demo run is gone.
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
    @ObservationIgnored private var unwritten: [String: Write] = [:]
    /// Real accounts removed in this run (`forgetAccount`): their chats take no words again. A real
    /// account's id is never reused; the demo's fixed account is fenced by its run's admission.
    @ObservationIgnored private var removedAccounts: Set<String> = []
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
        // A removed account's chat, or an ended demo's, keeps nothing.
        let admission = DemoModeStore.shared.chatAdmission
        guard !isGone(key, admission: admission) else { return }
        let before = fill(for: key)
        var after = before
        after.apply(change)
        guard after != before else { return }
        fills[key] = after
        changed.insert(key)
        guard after.unsent != before.unsent else { return }
        unwritten[key] = Write(words: after.unsent, admission: admission)
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
        // account or demo run ended while it ran never lands: both forget its reads
        // (`forgetAccount`, `forgetDemo`), so the reading-id check below refuses it (S1: a read
        // started after a demo's exit forgot it, while its wipe runs, would bring the old words
        // back into the next run).
        guard !isGone(key, admission: DemoModeStore.shared.chatAdmission) else { return }
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
        // Only the chat's current read lands (a removal or a demo's exit makes its reads obsolete), and only
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
        forget(where: isDemo)
    }

    /// The account `accountId` was removed (its row-delete transaction committed,
    /// `AccountManager.removeAccount`): its chats' words are forgotten in this run and take no new
    /// words. A write already running is refused by its own transaction (`Storage.admits`).
    func forgetAccount(_ accountId: String) {
        removedAccounts.insert(accountId)
        forget { ChatThreadKey.parse($0)?.accountId == accountId && !$0.hasPrefix(Self.demoPrefix) }
    }

    /// Whether the chat `key`'s words are no longer anyone's: its real account was removed in this
    /// run, or its demo run (`admission`) is not the current one.
    private func isGone(_ key: String, admission: DemoModeStore.Admission?) -> Bool {
        if !key.hasPrefix(Self.demoPrefix), let accountId = ChatThreadKey.parse(key)?.accountId,
           removedAccounts.contains(accountId) {
            return true
        }
        return !DemoModeStore.admits(sessionId: key, admission: admission)
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
        while !unwritten.isEmpty {
            let batch = unwritten
            unwritten = [:]
            do {
                try await storage.write(batch)
            } catch {
                // Kept unsaved in memory; the next save point (`saveUnwritten`, a change) writes them.
                // A removed account's, or an ended demo's, are not: they were forgotten while this wrote.
                for (key, write) in batch where unwritten[key] == nil && !isGone(key, admission: write.admission) {
                    unwritten[key] = write
                }
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

        /// The words are still those of the open send, unedited (`ChatFieldFill.holdsSentWords`).
        var holdsSentWords: Bool {
            guard let key else { return own.wrappedValue.holdsSentWords }
            return ChatFieldWords.shared.fill(for: key).holdsSentWords
        }

        func apply(_ change: ChatFieldFill.Change) {
            guard let key else { own.wrappedValue.apply(change); return }
            ChatFieldWords.shared.apply(change, to: key)
        }
    }

    // MARK: - Lifetime

    /// Delete the words of every thread with no email left on the device: a row not seen with an
    /// email of its account and thread (`ChatThreadKey.memberSQL`) for `SyncConfig.aiCacheOrphanGraceDays`,
    /// or with no thread at all. Every row whose thread still has an email is re-stamped to `now`
    /// first (`restampLive`), so the grace counts from the last pass that saw the thread: emails
    /// briefly gone (a UIDVALIDITY resync re-walking, a move between folders) never cost the words.
    /// The rule the thread's AI results live by (`SyncEngine.runPurgeOrphanedAICache`), run in the
    /// same pass. Returns how many went.
    @discardableResult
    nonisolated static func purgeOrphans(db: Database, now: Date) throws -> Int {
        let cutoff = Calendar.current.date(byAdding: .day, value: -SyncConfig.aiCacheOrphanGraceDays, to: now) ?? .distantPast
        let live = try restampLive(db: db, now: now)
        let rows = try Row.fetchAll(db, sql: "SELECT sessionId, updatedAt FROM \(ChatFieldWordsRecord.databaseTableName)")
        var purged = 0
        for row in rows {
            let key: String = row["sessionId"]
            guard !live.contains(key) else { continue }
            let updatedAt: Date = row["updatedAt"]
            if updatedAt < cutoff {
                purged += try ChatFieldWordsRecord.filter(key: key).deleteAll(db)
            }
        }
        return purged
    }

    /// Re-stamp to `now`, in one UPDATE, every row whose thread still has an email on the device
    /// (`ChatThreadKey.memberSQL`), and return their keys. The orphan pass runs it first; Delete All
    /// Email Index Data (`SettingsView.localIndexWipeTxn`) runs it in its transaction before the
    /// headers go, so the resync's re-walk counts as emails briefly gone from that moment, however
    /// long ago the last orphan pass ran.
    @discardableResult
    nonisolated static func restampLive(db: Database, now: Date) throws -> Set<String> {
        let keys = try String.fetchAll(db, sql: "SELECT sessionId FROM \(ChatFieldWordsRecord.databaseTableName)")
        var live: [String] = []
        for key in keys {
            if let (accountId, threadId) = ChatThreadKey.parse(key),
               try Bool.fetchOne(db, sql: "SELECT EXISTS(SELECT 1 FROM messageHeader WHERE \(ChatThreadKey.memberSQL))",
                                 arguments: [accountId, threadId, threadId]) == true {
                live.append(key)
            }
        }
        if !live.isEmpty {
            let marks = Array(repeating: "?", count: live.count).joined(separator: ",")
            try db.execute(
                sql: "UPDATE \(ChatFieldWordsRecord.databaseTableName) SET updatedAt = ? WHERE sessionId IN (\(marks))",
                arguments: StatementArguments([now]) + StatementArguments(live))
        }
        return Set(live)
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
    /// When the words last changed, or the last maintenance pass that saw an email of the thread
    /// (`ChatFieldWords.purgeOrphans`), whichever is later: the orphan grace counts from it.
    var updatedAt: Date
}
