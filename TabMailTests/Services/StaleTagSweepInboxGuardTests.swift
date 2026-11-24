/* This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at https://mozilla.org/MPL/2.0/. */

import Foundation
import GRDB
import Synchronization
import Testing
@testable import TabMail

/// The stale action-tag sweep's Gmail duplicate guard (#1404). The sweep used to read up to
/// `SyncConfig.maxLoadedMessages` inbox rows of the account after every full sync, whether or not any tag
/// needed the guard, and skipped a tag whose Message-ID was among those rows. It now checks each candidate
/// (a tagged non-inbox row past the TTL with a Message-ID) on its own with one Message-ID seek.
///
/// These tests drive the real `SyncEngine.sweepStaleActionTags` through its production signature only, so they
/// also build against the replaced code: the differential keeps the replaced decisions as its oracle, and the
/// other two fail on the replaced code.
@Suite("Stale action-tag sweep: inbox guard per candidate", .serialized, .processGlobalState)
struct StaleTagSweepInboxGuardTests {

    // MARK: - (a) Differential

    /// The mailboxes the differential runs on, each with at most `SyncConfig.maxLoadedMessages` inbox rows, so the
    /// replaced up-front read saw every one of them.
    enum Mailbox: String, CaseIterable, CustomTestStringConvertible {
        /// Every kind of row, fewer candidates than the per-pass budget.
        case mixed
        /// Exactly as many inbox rows as the replaced read's limit.
        case atTheReplacedReadsLimit
        /// More clearable rows than the per-pass budget, so the budget ends the sweep.
        case budgetSpent

        var testDescription: String { rawValue }

        var inboxRows: Int {
            switch self {
            case .mixed: return 120
            case .atTheReplacedReadsLimit: return SyncConfig.maxLoadedMessages
            case .budgetSpent: return 60
            }
        }

        var rowsPerFolder: Int {
            switch self {
            case .mixed: return 27
            case .atTheReplacedReadsLimit: return 36
            case .budgetSpent: return SyncConfig.pruneChunkSize + 1
            }
        }

        var kinds: [StaleTagSweepFixture.Kind] {
            switch self {
            case .mixed, .atTheReplacedReadsLimit:
                return StaleTagSweepFixture.Kind.allCases
            case .budgetSpent:
                // In row order the replaced sweep reads 50 rows of the first folder (40 cleared), 10 of the second
                // (8) and 2 of the third (2): the budget ends it exactly.
                return [.expiredInInbox, .expired, .nullStampNoMessageId, .emptyMessageId, .otherAccountsInbox]
            }
        }
    }

    @Test("Up to the replaced read's limit, the sweep clears and keeps exactly the rows the replaced sweep did",
          arguments: Mailbox.allCases)
    func clearsWhatTheReplacedSweepCleared(mailbox: Mailbox) async throws {
        let fixture = try StaleTagSweepFixture()
        defer { fixture.restore() }
        let folders = try fixture.makeFolders()
        try await fixture.pool.write { db in
            for j in 0..<mailbox.inboxRows {
                try fixture.insert(db, folder: folders.inbox, messageId: "inbox-\(j)",
                                   rfc: StaleTagSweepFixture.inboxMessageId(j), tag: nil, setAt: nil)
            }
            for k in 0..<StaleTagSweepFixture.otherInboxRows {
                try fixture.insert(db, folder: folders.otherInbox, messageId: "other-\(k)",
                                   rfc: StaleTagSweepFixture.otherInboxMessageId(k), tag: nil, setAt: nil,
                                   accountId: StaleTagSweepFixture.otherAccountId)
            }
            var g = 0
            for folder in folders.swept {
                for _ in 0..<mailbox.rowsPerFolder {
                    let kind = mailbox.kinds[g % mailbox.kinds.count]
                    // Zero-padded, so every order a folder's rows can be read in (rowid, UID, date) is insertion order.
                    try fixture.insert(db, folder: folder, messageId: String(format: "%@-%05d", folder.path, g), kind: kind,
                                       index: g, inboxRows: mailbox.inboxRows)
                    g += 1
                }
            }
        }

        let cutoff = Date().addingTimeInterval(-SyncConfig.actionTagTTLSeconds)
        let replaced = try await fixture.pool.read { db in
            try StaleTagSweepFixture.replacedSweepDecisions(db, accountId: fixture.accountId, cutoff: cutoff)
        }
        let taggedBefore = try await fixture.taggedIds()
        #expect(!replaced.cleared.isEmpty, "precondition: the replaced sweep clears something here")
        #expect(replaced.keptByTheInboxGuard > 0, "precondition: the replaced sweep's inbox guard keeps something here")
        if mailbox == .budgetSpent {
            #expect(replaced.cleared.count == SyncConfig.pruneChunkSize, "precondition: the budget ends the replaced sweep")
        } else {
            #expect(replaced.cleared.count < SyncConfig.pruneChunkSize, "precondition: the budget does not end the replaced sweep")
        }

        await SyncEngine().sweepStaleActionTags(account: fixture.account, provider: MockEmailProvider())

        let tagged = try await fixture.taggedIds()
        let cleared = taggedBefore.subtracting(tagged)
        #expect(cleared == replaced.cleared,
                "\(mailbox): cleared \(cleared.count), the replaced sweep \(replaced.cleared.count); only new: \(cleared.subtracting(replaced.cleared).sorted()), only replaced: \(replaced.cleared.subtracting(cleared).sorted())")
        let clearedRows = try await fixture.pool.read { db in
            try MessageHeader.filter(keys: Array(cleared)).fetchAll(db)
        }
        #expect(clearedRows.allSatisfy { $0.tagSortOrder == 99 && $0.actionTagSetAt == nil },
                "a cleared row keeps a sort order or a stamp")
    }

    // MARK: - (b) An inbox copy the replaced read never saw

    /// Gmail shows one message in Inbox and in All Mail. When the inbox copy is not among the first
    /// `SyncConfig.maxLoadedMessages` inbox rows the replaced read returned, the replaced sweep cleared the All Mail
    /// copy's tag although the message is still in the inbox. The per-candidate check finds the inbox copy wherever
    /// it is.
    @Test("A Gmail duplicate whose inbox copy lies past the replaced read's limit keeps its tag")
    func inboxCopyPastTheReplacedLimitKeepsTheTag() async throws {
        let fixture = try StaleTagSweepFixture()
        defer { fixture.restore() }
        let folders = try fixture.makeFolders()
        let duplicate = "<gmail-duplicate@example.com>"
        let expired = Date().addingTimeInterval(-(SyncConfig.actionTagTTLSeconds + 3600))
        let limit = SyncConfig.maxLoadedMessages
        let (allMailCopy, control) = try await fixture.pool.write { db -> (MessageHeader, MessageHeader) in
            // The inbox copy is inserted last, with the newest date and the highest UID, so it is past the limit
            // in rowid, date and messageId order alike.
            let now = Date()
            for j in 0..<limit {
                try fixture.insert(db, folder: folders.inbox, messageId: String(format: "inbox-%05d", j),
                                   rfc: StaleTagSweepFixture.inboxMessageId(j), tag: nil, setAt: nil,
                                   date: now.addingTimeInterval(-Double(limit - j) * 60))
            }
            try fixture.insert(db, folder: folders.inbox, messageId: "inbox-99999", rfc: duplicate,
                               tag: .reply, setAt: expired, date: now)
            let copy = try fixture.insert(db, folder: folders.swept[0], messageId: "allmail-duplicate",
                                          rfc: duplicate, tag: .reply, setAt: expired)
            let control = try fixture.insert(db, folder: folders.swept[0], messageId: "allmail-control",
                                             rfc: "<archived-only@example.com>", tag: .archive, setAt: expired)
            return (copy, control)
        }
        let seenByTheReplacedRead = try await fixture.pool.read { db in
            try StaleTagSweepFixture.replacedInboxRead(db, accountId: fixture.accountId)
        }
        #expect(seenByTheReplacedRead.count == limit, "precondition: the replaced read returns \(limit) Message-IDs")
        #expect(!seenByTheReplacedRead.contains(duplicate), "precondition: the replaced read misses the inbox copy")

        await SyncEngine().sweepStaleActionTags(account: fixture.account, provider: MockEmailProvider())

        let (stored, storedControl) = try await fixture.pool.read { db in
            (try MessageHeader.fetchOne(db, key: allMailCopy.id), try MessageHeader.fetchOne(db, key: control.id))
        }
        #expect(storedControl?.actionTag == nil, "precondition: the sweep ran and cleared the archived-only copy")
        #expect(stored?.actionTag == .reply, "the All Mail copy of a message still in the inbox lost its tag")
        #expect(stored?.actionTagSetAt != nil)
    }

    // MARK: - (d) No candidate, no inbox read

    /// A sweep whose tagged rows are all young, untagged or without a Message-ID needs no inbox check, so it reads
    /// no inbox row. The replaced sweep read up to `SyncConfig.maxLoadedMessages` of them after every full sync.
    @Test("A sweep with no candidate for the inbox guard reads no inbox row")
    func noCandidateReadsNoInboxRow() async throws {
        let fixture = try StaleTagSweepFixture()
        defer { fixture.restore() }
        let folders = try fixture.makeFolders()
        let expired = Date().addingTimeInterval(-(SyncConfig.actionTagTTLSeconds + 3600))
        let young = Date().addingTimeInterval(-3600)
        let (youngCopy, noMessageId, emptyMessageId) = try await fixture.pool.write { db in
            for j in 0..<5 {
                try fixture.insert(db, folder: folders.inbox, messageId: "inbox-\(j)",
                                   rfc: StaleTagSweepFixture.inboxMessageId(j), tag: nil, setAt: nil)
            }
            try fixture.insert(db, folder: folders.swept[0], messageId: "untagged",
                               rfc: StaleTagSweepFixture.inboxMessageId(0), tag: nil, setAt: nil)
            let youngCopy = try fixture.insert(db, folder: folders.swept[0], messageId: "young",
                                               rfc: StaleTagSweepFixture.inboxMessageId(1), tag: .reply, setAt: young)
            let noMessageId = try fixture.insert(db, folder: folders.swept[1], messageId: "no-message-id",
                                                 rfc: nil, tag: .delete, setAt: nil)
            let emptyMessageId = try fixture.insert(db, folder: folders.swept[1], messageId: "empty-message-id",
                                                    rfc: "", tag: .archive, setAt: expired)
            return (youngCopy, noMessageId, emptyMessageId)
        }
        fixture.tape.clear()

        await SyncEngine().sweepStaleActionTags(account: fixture.account, provider: MockEmailProvider())

        let inboxReads = fixture.inboxReads()
        let (storedYoung, storedNoId, storedEmptyId) = try await fixture.pool.read { db in
            (try MessageHeader.fetchOne(db, key: youngCopy.id),
             try MessageHeader.fetchOne(db, key: noMessageId.id),
             try MessageHeader.fetchOne(db, key: emptyMessageId.id))
        }
        #expect(storedNoId?.actionTag == nil, "precondition: the sweep ran and cleared the row with no Message-ID")
        #expect(storedEmptyId?.actionTag == nil, "precondition: the sweep cleared the row with an empty Message-ID")
        #expect(storedYoung?.actionTag == .reply, "precondition: the young tag stays")
        #expect(inboxReads.isEmpty, "a sweep with no candidate read inbox rows: \(inboxReads)")
    }
}

// MARK: - Fixture

/// A temp-file pool migrated by `AppDatabase`, swapped into `AppDatabase.shared` so `SyncEngine.dbPool`
/// (`AppDatabase.syncPool`) reads it, with every connection's statements recorded. Two accounts: the swept
/// account, and another whose inbox shares no row with it.
struct StaleTagSweepFixture: Sendable {
    /// The statements the pool's connections ran, recorded by `Database.trace`.
    final class SQLTape: Sendable {
        private let statements = Mutex<[String]>([])
        func record(_ sql: String) { statements.withLock { $0.append(sql) } }
        func clear() { statements.withLock { $0.removeAll() } }
        var all: [String] { statements.withLock { $0 } }
    }

    /// One row of a swept (non-inbox) folder.
    enum Kind: CaseIterable, Sendable {
        case untaggedInInbox
        case expiredInInbox
        case expired
        case youngInInbox
        case nullStampNoMessageId
        case emptyMessageId
        case otherAccountsInbox
        case young
        case nullStampInInbox
    }

    struct Folders: Sendable {
        let inbox: Folder
        let otherInbox: Folder
        /// The swept account's non-inbox folders, in insertion order.
        let swept: [Folder]
    }

    static let otherAccountId = "sweep-guard-other-account"
    static let otherInboxRows = 20

    static func inboxMessageId(_ j: Int) -> String { "<inbox-\(j)@example.com>" }
    static func otherInboxMessageId(_ k: Int) -> String { "<other-inbox-\(k)@example.com>" }

    let pool: DatabasePool
    let directory: URL
    let previous: AppDatabase?
    let account: Account
    let tape: SQLTape
    var accountId: String { account.id }

    init() throws {
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("stale-tag-sweep-guard-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let tape = SQLTape()
        self.tape = tape
        var configuration = Configuration()
        configuration.foreignKeysEnabled = true
        configuration.prepareDatabase { db in
            db.trace(options: .statement) { event in tape.record(event.expandedDescription) }
        }
        pool = try DatabasePool(path: directory.appendingPathComponent("test.sqlite").path, configuration: configuration)
        let appDatabase = try AppDatabase(dbPool: pool)

        var account = Account(emailAddress: "recipient@example.com", displayName: "Test", provider: .gmail)
        account.id = "sweep-guard-\(UUID().uuidString)"
        var other = Account(emailAddress: "other@example.com", displayName: "Other", provider: .gmail)
        other.id = Self.otherAccountId
        try pool.write { db in
            try account.insert(db)
            try other.insert(db)
        }
        self.account = account
        // Last, so a failed setup never leaves the shared database swapped with no `restore()` to undo it.
        previous = AppDatabase.shared.withLock { current -> AppDatabase? in
            let previous = current
            current = appDatabase
            return previous
        }
    }

    func restore() {
        AppDatabase.shared.withLock { $0 = previous }
        TestDatabaseTeardown.closeThenUnlinkNow(pool: pool, directory: directory)
    }

    func makeFolders() throws -> Folders {
        let inbox = Folder(name: "INBOX", path: "INBOX", role: .inbox, accountId: accountId)
        let otherInbox = Folder(name: "INBOX", path: "INBOX", role: .inbox, accountId: Self.otherAccountId)
        let swept = [
            Folder(name: "All Mail", path: "AllMail", role: .custom, accountId: accountId),
            Folder(name: "Archive", path: "Archive", role: .archive, accountId: accountId),
            Folder(name: "Trash", path: "Trash", role: .trash, accountId: accountId),
        ]
        try pool.write { db in
            for folder in [inbox, otherInbox] + swept { try folder.insert(db) }
        }
        return Folders(inbox: inbox, otherInbox: otherInbox, swept: swept)
    }

    @discardableResult
    func insert(
        _ db: Database, folder: Folder, messageId: String, rfc: String?, tag: ActionTag?, setAt: Date?,
        date: Date = Date(), accountId: String? = nil
    ) throws -> MessageHeader {
        var header = MessageHeader(
            messageId: messageId,
            subject: "Test",
            from: "Sender",
            fromAddress: "sender@example.com",
            to: "recipient@example.com",
            date: date,
            snippet: "snippet",
            folderId: folder.id,
            accountId: accountId ?? self.accountId,
            folderPath: folder.path,
            isInInbox: folder.role == .inbox
        )
        header.rfc822MessageId = rfc
        // Not `setActionTag`: a fixture must be able to write a tag with no stamp (a legacy row).
        header.actionTag = tag
        header.tagSortOrder = tag?.sortOrder ?? 99
        header.actionTagSetAt = setAt
        try header.insert(db)
        return header
    }

    /// Row `index` of a swept folder, of `kind`. Tags cycle through every `ActionTag`.
    @discardableResult
    func insert(_ db: Database, folder: Folder, messageId: String, kind: Kind, index: Int, inboxRows: Int) throws -> MessageHeader {
        let tag = ActionTag.allCases[index % ActionTag.allCases.count]
        let expired = Date().addingTimeInterval(-(SyncConfig.actionTagTTLSeconds + 3600))
        let young = Date().addingTimeInterval(-3600)
        let inInbox = Self.inboxMessageId(index % inboxRows)
        let unique = "<\(messageId)@example.com>"
        switch kind {
        case .untaggedInInbox:
            return try insert(db, folder: folder, messageId: messageId, rfc: inInbox, tag: nil, setAt: nil)
        case .expiredInInbox:
            return try insert(db, folder: folder, messageId: messageId, rfc: inInbox, tag: tag, setAt: expired)
        case .expired:
            return try insert(db, folder: folder, messageId: messageId, rfc: unique, tag: tag, setAt: expired)
        case .youngInInbox:
            return try insert(db, folder: folder, messageId: messageId, rfc: inInbox, tag: tag, setAt: young)
        case .nullStampNoMessageId:
            return try insert(db, folder: folder, messageId: messageId, rfc: nil, tag: tag, setAt: nil)
        case .emptyMessageId:
            return try insert(db, folder: folder, messageId: messageId, rfc: "", tag: tag, setAt: expired)
        case .otherAccountsInbox:
            return try insert(db, folder: folder, messageId: messageId,
                              rfc: Self.otherInboxMessageId(index % Self.otherInboxRows), tag: tag, setAt: expired)
        case .young:
            return try insert(db, folder: folder, messageId: messageId, rfc: unique, tag: tag, setAt: young)
        case .nullStampInInbox:
            return try insert(db, folder: folder, messageId: messageId, rfc: inInbox, tag: tag, setAt: nil)
        }
    }

    /// The ids of the swept account's tagged rows.
    func taggedIds() async throws -> Set<String> {
        let accountId = self.accountId
        return try await pool.read { db in
            Set(try String.fetchAll(db, sql: "SELECT id FROM messageHeader WHERE accountId = ? AND actionTag IS NOT NULL",
                                    arguments: [accountId]))
        }
    }

    /// The recorded SELECTs that filter on inbox membership: the replaced up-front read (`"isInInbox" = 1`) and the
    /// per-candidate check (`+isInInbox = 1`). The inbox notification observer's per-commit read names `isInInbox`
    /// only as a column, so it does not count.
    func inboxReads() -> [String] {
        tape.all.filter {
            $0.uppercased().hasPrefix("SELECT")
                && $0.range(of: #"isInInbox"?\s*=\s*1"#, options: .regularExpression) != nil
        }
    }

    // MARK: The replaced sweep, kept as the oracle

    /// The replaced up-front read: the Message-IDs of up to `SyncConfig.maxLoadedMessages` inbox rows of the account.
    static func replacedInboxRead(_ db: Database, accountId: String) throws -> Set<String> {
        let inboxHeaders = try MessageHeader
            .filter(Column("accountId") == accountId && Column("isInInbox") == true)
            .limit(SyncConfig.maxLoadedMessages)
            .fetchAll(db)
        var ids = Set<String>()
        for msg in inboxHeaders {
            if let rfc = msg.rfc822MessageId, !rfc.isEmpty {
                ids.insert(rfc)
            }
        }
        return ids
    }

    /// The replaced sweep's decisions, without its writes: the rows it clears, and how many tags past the TTL its
    /// inbox guard keeps. Its reads do not depend on its own writes (each folder is read once, and a clear touches
    /// only a row already read), so the decisions can be taken before the sweep runs.
    static func replacedSweepDecisions(
        _ db: Database, accountId: String, cutoff: Date
    ) throws -> (cleared: Set<String>, keptByTheInboxGuard: Int) {
        let maxPerSweep = SyncConfig.pruneChunkSize
        let inboxRfc822Ids = try replacedInboxRead(db, accountId: accountId)
        let folders = try Folder.filter(Column("accountId") == accountId && Column("role") != FolderRole.inbox.rawValue).fetchAll(db)
        var cleared = Set<String>()
        var keptByTheInboxGuard = 0
        for folder in folders {
            guard cleared.count < maxPerSweep else { break }
            let remaining = maxPerSweep - cleared.count
            let msgs = try MessageHeader
                .filter(Column("folderId") == folder.id)
                .limit(remaining)
                .fetchAll(db)
            for msg in msgs where msg.actionTag != nil {
                guard cleared.count < maxPerSweep else { break }
                if let rfc = msg.rfc822MessageId, !rfc.isEmpty, inboxRfc822Ids.contains(rfc) {
                    if !(msg.actionTagSetAt.map { $0 > cutoff } ?? false) { keptByTheInboxGuard += 1 }
                    continue
                }
                if let setAt = msg.actionTagSetAt, setAt > cutoff {
                    continue
                }
                cleared.insert(msg.id)
            }
        }
        return (cleared, keptByTheInboxGuard)
    }
}
