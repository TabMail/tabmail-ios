/* This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at https://mozilla.org/MPL/2.0/. */

import Foundation
import GRDB
import Testing
@testable import TabMail

/// A removed account's AI cache entries stay removed.
///
/// THE SYSTEM PROPERTY pinned here: removing an account deletes its `messageAICache` entries
/// (`AccountManager.removeAccountRowsTxn`), and no write that lands after the removal brings one
/// back, whichever writer it comes from. The cache has no account column and no foreign key, so
/// nothing else would ever delete such an entry: the removed account's email content would stay.
///
/// Every writer that creates entries is driven: the app's one writer (`MessageAICache.writeThrough`,
/// which every AI producer and sync pass calls), the extension's merge
/// (`NSEDataBridge.upsertAICacheFromStaging`), and the summary at Send, the producer that holds its
/// request longest, with the account removed while its request is out. Each runs with and without
/// the removal, so a writer that writes nothing at all fails too. The fence below proves there is
/// no other writer.
@Suite("AI cache: a removed account's entries stay removed", .serialized, .processGlobalState)
@MainActor
struct AICacheRemovedAccountTests {
    nonisolated private static let account = "acc-removed"
    nonisolated private static let messageId = "removed-1@example.com"

    enum Writer: String, CaseIterable, Sendable {
        case writeThrough, extensionMerge, summaryAtSend
    }

    private static func remove(_ pool: DatabasePool) async throws {
        try await pool.write { db in
            try AccountManager.removeAccountRowsTxn(db, accountId: Self.account, wasPrimary: false)
        }
        #expect(try await pool.read { try Account.fetchOne($0, key: Self.account) } == nil,
                "control: the removal committed")
        #expect(try await pool.read { try MessageAICache.fetchCount($0) } == 0,
                "control: the removal deleted the account's entries")
    }

    @Test("A write that lands after its account was removed creates no entry; without the removal it does",
          arguments: Writer.allCases, [true, false])
    func lateWrite(writer: Writer, removed: Bool) async throws {
        let (pool, directory, previous) = try FolderEpochTestFixture.makeAppDB()
        defer { InstalledTestDatabaseLifetime.finish(previous: previous, pool: pool, directory: directory) }
        _ = try FolderEpochTestFixture.makeAccount(id: Self.account, provider: .gmail, pool: pool)
        try FolderEpochTestFixture.insertFolder(accountId: Self.account, path: "INBOX", role: .inbox, pool: pool)
        try FolderEpochTestFixture.insertFolder(accountId: Self.account, path: "Sent", role: .sent, pool: pool)
        // An entry the removal deletes, so its "deleted" control is not vacuous.
        try await pool.write { db in
            try MessageAICache.writeThrough(
                accountId: Self.account, folderPath: "INBOX", rfc822MessageId: "older@example.com",
                summaryBlurb: "Older.", summaryTextMessage: "Older.", db: db)
        }
        #expect(try await pool.read { try MessageAICache.fetchCount($0) } == 1, "control: an entry exists")

        let key: String
        switch writer {
        case .writeThrough:
            key = "\(Self.account):INBOX:\(Self.messageId)"
            if removed { try await Self.remove(pool) }
            try await pool.write { db in
                try MessageAICache.writeThrough(
                    accountId: Self.account, folderPath: "INBOX", rfc822MessageId: Self.messageId,
                    summaryBlurb: "Private note.", summaryTextMessage: "Private note.", db: db)
            }

        case .extensionMerge:
            key = "\(Self.account):INBOX:\(Self.messageId)"
            let staged = try Self.stagedMessage(directory: directory)
            if removed { try await Self.remove(pool) }
            try await pool.write { db in
                try NSEDataBridge.upsertAICacheFromStaging(
                    staged, cacheKey: key, rfc822MessageId: Self.messageId, db: db)
            }

        case .summaryAtSend:
            let outboxId = try await Self.queueSend(pool)
            let row = try #require(try await pool.read { try OutboxMessage.fetchOne($0, key: outboxId) })
            key = "\(Self.account):Sent:\(EmailFilter.normalizeMessageId(try #require(row.sentMessageId)))"
            // The backend holds its answer until the account is removed.
            let asked = DispatchSemaphore(value: 0)
            let answer = DispatchSemaphore(value: 0)
            let http = FakeHTTP.Scenario()
            http.register(path: "/completions/chat", method: "POST") { _ in
                asked.signal()
                _ = answer.wait(timeout: .now() + 30)
                let object: [String: Any] = ["summary": "Private note.", "todos": [], "reminder": NSNull(), "text_message": "Private note."]
                let assistant = String(decoding: try! JSONSerialization.data(withJSONObject: object), as: UTF8.self)
                let final = String(decoding: try! JSONSerialization.data(withJSONObject: ["assistant": assistant]), as: UTF8.self)
                return .bytes(Data("event: final\ndata: \(final)\n\n".utf8), contentType: "text/event-stream")
            }
            defer { answer.signal(); http.close() }
            let service = AIService(backendClient: BackendClient(llmSession: http.session), peerProbe: { _ in nil })
            let summarizing = Task { await SentEmailSummary.summarize(outboxId: outboxId, aiService: service) }
            let started = await withCheckedContinuation { (done: CheckedContinuation<Bool, Never>) in
                DispatchQueue.global().async { done.resume(returning: asked.wait(timeout: .now() + 10) == .success) }
            }
            try #require(started, "control: the summary read its email and made its request")
            if removed { try await Self.remove(pool) }
            answer.signal()
            await summarizing.value
            #expect(http.recordedCalls().count == 1, "control: the request completed")
        }

        let entry = try await pool.read { try MessageAICache.fetchOne($0, key: key) }
        if removed {
            #expect(entry == nil, "\(writer.rawValue): no entry of the removed account came back")
            #expect(try await pool.read { try MessageAICache.fetchCount($0) } == 0, "\(writer.rawValue): none at all")
        } else {
            #expect(entry?.summaryTextMessage == "Private note.", "control: \(writer.rawValue) writes while the account exists")
        }
    }

    /// The extension's staged result for the email, decoded as the merge decodes it.
    private static func stagedMessage(directory: URL) throws -> NSEDataBridge.StagedMessage {
        let path = directory.appendingPathComponent("nse_staging_removed.sqlite").path
        #expect(AppDatabase.createNSEStagingDB(atPath: path))
        let staging = try #require(NSEStagingDB.open(path: path))
        let message = NSEMessageMetadata(
            messageId: "removed-1", threadId: "t-removed-1", rfc822MessageId: Self.messageId,
            senderName: "Sender", senderEmail: "sender@example.com",
            to: "recipient@example.com", cc: "", bcc: "", replyTo: nil,
            inReplyTo: nil, references: [], subject: "staged", snippet: "s",
            dateString: "", date: Date(), isRead: false, isFlagged: false, hasAttachments: false,
            isReplied: false, isForwarded: false, providerLabels: ["INBOX"], folderPath: "INBOX")
        #expect(NSEStagingDB.persistProcessedMessage(
            db: staging, accountId: Self.account, accountEmail: "\(Self.account)@example.com", provider: "gmail",
            message: message, summaryBlurb: "Private note.", summaryTodos: nil, actionTag: "reply",
            reminderDate: nil, reminderTime: nil, reminderContent: nil, summaryTextMessage: "Private note.",
            historyId: nil, aiCompleted: true, notified: false))
        let row = try #require(try staging.read { db in
            try Row.fetchOne(db, sql: "SELECT * FROM nse_processed_message WHERE id = ?",
                             arguments: ["\(Self.account):removed-1"])
        })
        try staging.close()
        return NSEDataBridge.StagedMessage(row: row)
    }

    /// Queues an email from the account as compose does, and returns its outbox row's id.
    private static func queueSend(_ pool: DatabasePool) async throws -> String {
        try await pool.write { db in
            var draft = Draft(
                id: "draft-removed", accountId: Self.account, toJSON: "[]", ccJSON: "[]", bccJSON: "[]",
                subject: "Lunch", body: "Tuesday works", replyToId: nil, isForward: false,
                editHistoryJSON: nil, createdAt: Date().timeIntervalSince1970, updatedAt: Date().timeIntervalSince1970)
            draft.instanceEpoch = "E1"
            try draft.insert(db)
        }
        return try await AccountManager.persistQueuedSend(
            draft: DraftMessage(to: ["someone@example.com"], subject: "Lunch", body: "Tuesday works for me."),
            accountId: Self.account, replyToHeaderId: nil, isForward: false, serverDraftId: nil,
            draftId: "draft-removed", instanceEpoch: "E1", holdsForUndo: true).outboxId
    }

    // MARK: - The fence: no other writer creates entries

    private static let projectRoot = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()
        .deletingLastPathComponent()
        .deletingLastPathComponent()

    /// Every Swift source of the app, the shared code and the extension.
    private static func productionSources() throws -> [(path: String, text: String)] {
        var sources: [(String, String)] = []
        for top in ["TabMail", "Shared", "TabMailNotificationService"] {
            let directory = projectRoot.appendingPathComponent(top)
            guard let walker = FileManager.default.enumerator(at: directory, includingPropertiesForKeys: nil) else {
                continue
            }
            for case let url as URL in walker where url.pathExtension == "swift" {
                let relative = String(url.path.dropFirst(projectRoot.path.count + 1))
                sources.append((relative, try String(contentsOf: url, encoding: .utf8)))
            }
        }
        return sources
    }

    private static func count(_ pattern: String, in text: String, caseInsensitive: Bool) throws -> Int {
        let regex = try NSRegularExpression(pattern: pattern, options: caseInsensitive ? [.caseInsensitive] : [])
        return regex.numberOfMatches(in: text, range: NSRange(text.startIndex..., in: text))
    }

    /// Only three places create AI cache entries, each of which checks the account or runs where
    /// it cannot be gone: `MessageAICache.writeThrough` (the one place a `MessageAICache` value is
    /// made to be saved), the extension merge's one statement, and the migrations in
    /// `AppDatabase.swift` (whose triggers write from a header row, which the removal deletes
    /// first). `DemoSeed` also makes its entries, in the same transaction that creates the demo
    /// account. A new writer must check the account too, and be added here.
    @Test("No other code creates AI cache entries")
    func onlyTheCheckedWritersCreateEntries() throws {
        let sources = try Self.productionSources()
        #expect(sources.count > 400, "control: the walk found the sources (\(sources.count))")
        let sqlInsert = #"\b(insert|replace)\s+(or\s+\w+\s+)?into\s+messageAICache\b"#
        let made = #"\bMessageAICache\s*\("#
        var inserts: [String: Int] = [:]
        var values: [String: Int] = [:]
        for (path, text) in sources {
            let i = try Self.count(sqlInsert, in: text, caseInsensitive: true)
            if i > 0 { inserts[path] = i }
            let v = try Self.count(made, in: text, caseInsensitive: false)
            if v > 0 { values[path] = v }
        }
        #expect(inserts["TabMail/Services/NSEDataBridge.swift"] == 1, "control: the extension merge's statement is found")
        #expect((inserts["TabMail/Services/AppDatabase.swift"] ?? 0) > 0, "control: the migrations' statements are found")
        #expect(Set(inserts.keys) == ["TabMail/Services/NSEDataBridge.swift", "TabMail/Services/AppDatabase.swift"],
                "SQL that creates AI cache entries: \(inserts)")
        #expect(values["TabMail/Models/MessageAICache.swift"] == 1, "control: writeThrough's value is found")
        #expect(Set(values.keys) == ["TabMail/Models/MessageAICache.swift", "TabMail/Services/Demo/DemoSeed.swift"],
                "code that makes an AI cache value: \(values)")
    }
}
