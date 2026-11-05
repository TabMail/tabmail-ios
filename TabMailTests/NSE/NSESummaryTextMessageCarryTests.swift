/* This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at https://mozilla.org/MPL/2.0/. */

import Testing
import Foundation
import GRDB
import Synchronization
import UserNotifications
@testable import TabMail

/// The summary's text message, end to end through the extension: the open-time column upgrade
/// (`NSEStagingDB.ensureSummaryTextMessageColumn`), the gradual `stageSummary` and the terminal
/// `persistProcessedMessage`, `StagedMessage(row:)`, and the new-header merge. A push must not lose
/// the text message the extension already paid for, or the chat view asks the model again.
@Suite("NSE staging carries the summary text message")
struct NSESummaryTextMessageCarryTests {

    private static func metadata(_ messageId: String) -> NSEMessageMetadata {
        NSEMessageMetadata(
            messageId: messageId, threadId: "t-\(messageId)", rfc822MessageId: "\(messageId)@example.com",
            senderName: "Sender", senderEmail: "sender@example.com",
            to: "recipient@example.com", cc: "", bcc: "", replyTo: nil,
            inReplyTo: nil, references: [], subject: "staged \(messageId)", snippet: "s",
            dateString: "", date: Date(), isRead: false, isFlagged: false, hasAttachments: false,
            isReplied: false, isForwarded: false, providerLabels: ["INBOX"], folderPath: "INBOX"
        )
    }

    private static func decode(_ queue: DatabaseQueue, id: String) throws -> NSEDataBridge.StagedMessage {
        let row = try #require(try queue.read { db in
            try Row.fetchOne(db, sql: "SELECT * FROM nse_processed_message WHERE id = ?", arguments: [id])
        })
        return NSEDataBridge.StagedMessage(row: row)
    }

    private static func columns(_ queue: DatabaseQueue) throws -> Set<String> {
        try queue.read { db in
            Set(try Row.fetchAll(db, sql: "PRAGMA table_info(nse_processed_message)").map { $0["name"] as String })
        }
    }

    private static func makeStaging() throws -> (dir: URL, queue: DatabaseQueue) {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let path = dir.appendingPathComponent("nse_staging.sqlite").path
        #expect(AppDatabase.createNSEStagingDB(atPath: path))
        let queue = try DatabaseQueue(path: path)
        // The columns `NSEStagingDB.open` adds before any write; the text message column is
        // left to each test, which checks its upgrade.
        NSEStagingDB.ensureObservedUidValidityColumn(db: queue)
        NSEStagingDB.ensureProviderDateColumn(db: queue)
        return (dir, queue)
    }

    @Test("A fresh staging schema has the column")
    func freshSchemaHasColumn() throws {
        let (dir, queue) = try Self.makeStaging()
        defer { try? FileManager.default.removeItem(at: dir) }
        #expect(try Self.columns(queue).contains("summaryTextMessage"))
    }

    @Test("Staging writers, decoder and merge carry the text message; a legacy row decodes nil")
    func roundTrip() throws {
        let (dir, queue) = try Self.makeStaging()
        defer { try? FileManager.default.removeItem(at: dir) }
        // The schema an older app shipped, with a row staged under it.
        try queue.write { db in
            try db.execute(sql: "ALTER TABLE nse_processed_message DROP COLUMN summaryTextMessage")
            try db.execute(sql: """
                INSERT INTO nse_processed_message
                    (id, accountId, accountEmail, provider, messageId, rfc822MessageId, folderPath,
                     subject, senderName, senderEmail, snippet, date, summaryBlurb, processedAt,
                     aiCompleted, notified, populated)
                VALUES ('acc1:legacy', 'acc1', 'user@example.com', 'gmail', 'legacy', 'legacy@example.com', 'INBOX',
                        'legacy', 'Sender', 'sender@example.com', '', ?, 'old summary', ?, 1, 0, 1)
                """, arguments: [Date().timeIntervalSince1970, Date().timeIntervalSince1970])
        }
        #expect(!(try Self.columns(queue)).contains("summaryTextMessage"), "precondition: old schema")
        // A legacy row read before the extension upgrades the table decodes nil, never traps.
        #expect(try Self.decode(queue, id: "acc1:legacy").summaryTextMessage == nil)

        NSEStagingDB.ensureSummaryTextMessageColumn(db: queue)
        #expect(try Self.columns(queue).contains("summaryTextMessage"))
        NSEStagingDB.ensureSummaryTextMessageColumn(db: queue) // idempotent
        #expect(try Self.columns(queue).contains("summaryTextMessage"))

        let meta = Self.metadata("push-1")
        NSEStagingDB.stageHeader(db: queue, accountId: "acc1", accountEmail: "user@example.com",
                                 provider: "gmail", message: meta, historyId: "1")
        NSEStagingDB.stageSummary(db: queue, accountId: "acc1", message: meta,
                                  summaryBlurb: "Budget review.", summaryTodos: nil,
                                  reminderDate: nil, reminderTime: nil, reminderContent: nil,
                                  summaryTextMessage: "Can you review the budget?")
        #expect(try Self.decode(queue, id: "acc1:push-1").summaryTextMessage == "Can you review the budget?")

        let persisted = NSEStagingDB.persistProcessedMessage(
            db: queue, accountId: "acc1", accountEmail: "user@example.com", provider: "gmail",
            message: meta, renderedBody: nil, summaryBlurb: "Budget review.", summaryTodos: nil,
            actionTag: "reply", reminderDate: nil, reminderTime: nil, reminderContent: nil,
            summaryTextMessage: "Can you review the budget by Friday?", historyId: "2",
            aiCompleted: true, notified: true)
        #expect(persisted)
        let staged = try Self.decode(queue, id: "acc1:push-1")
        #expect(staged.summaryTextMessage == "Can you review the budget by Friday?")

        let main = try TestDatabase.make()
        try TestDatabase.insertAccount(main, id: "acc1", email: "user@example.com")
        try TestDatabase.insertFolder(main, name: "INBOX", path: "INBOX", role: .inbox, accountId: "acc1")
        var fts: [NSEDataBridge.NSEFTSBodyItem] = []
        let legacy = try Self.decode(queue, id: "acc1:legacy")
        try main.write { db in
            _ = try NSEDataBridge.insertNewHeaderFromStaging(staged, db: db, ftsBatch: &fts)
            _ = try NSEDataBridge.insertNewHeaderFromStaging(legacy, db: db, ftsBatch: &fts)
        }
        let header = try #require(try main.read {
            try MessageHeader.fetchOne($0, key: MessageIdentity.headerId(accountId: "acc1", folderPath: "INBOX", messageId: "push-1"))
        })
        #expect(header.summaryBlurb == "Budget review.")
        #expect(header.summaryTextMessage == "Can you review the budget by Friday?")
        let legacyHeader = try #require(try main.read {
            try MessageHeader.fetchOne($0, key: MessageIdentity.headerId(accountId: "acc1", folderPath: "INBOX", messageId: "legacy"))
        })
        #expect(legacyHeader.summaryBlurb == "old summary")
        #expect(legacyHeader.summaryTextMessage == nil)
    }

    @Test("Opening an older build's staging database adds the column this build writes")
    func openUpgradesOlderDatabase() throws {
        let (dir, queue) = try Self.makeStaging()
        defer { try? FileManager.default.removeItem(at: dir) }
        try queue.write { try $0.execute(sql: "ALTER TABLE nse_processed_message DROP COLUMN summaryTextMessage") }
        #expect(!(try Self.columns(queue)).contains("summaryTextMessage"), "precondition: old schema")
        try queue.close()

        let opened = try #require(NSEStagingDB.open(path: dir.appendingPathComponent("nse_staging.sqlite").path))

        let columns = try Self.columns(opened)
        #expect(columns.contains("summaryTextMessage"))
        #expect(columns.contains("observedUidValidity"))
        #expect(columns.contains("providerDate"))
    }

    @Test("The extension and the app send the same protocol version, from their own bundles")
    func extensionBundleProtocolVersion() throws {
        let appex = try #require(Bundle.main.builtInPlugInsURL?.appendingPathComponent("TabMailNotificationService.appex"))
        let extensionVersion = try #require(Bundle(url: appex)?.infoDictionary?["TabMailProtocolVersion"] as? String)
        #expect(extensionVersion == "2.0.0")
        #expect(extensionVersion == BackendClient.clientVersion)
    }

    @Test("A terminal write without a text message stages nil (a peer hit or AI off)")
    func terminalWithoutTextMessage() throws {
        let (dir, queue) = try Self.makeStaging()
        defer { try? FileManager.default.removeItem(at: dir) }
        let meta = Self.metadata("peer-1")
        NSEStagingDB.stageHeader(db: queue, accountId: "acc1", accountEmail: "user@example.com",
                                 provider: "gmail", message: meta, historyId: "1")
        NSEStagingDB.stageSummary(db: queue, accountId: "acc1", message: meta,
                                  summaryBlurb: "S.", summaryTodos: nil, reminderDate: nil,
                                  reminderTime: nil, reminderContent: nil, summaryTextMessage: "T.")
        let persisted = NSEStagingDB.persistProcessedMessage(
            db: queue, accountId: "acc1", accountEmail: "user@example.com", provider: "gmail",
            message: meta, renderedBody: nil, summaryBlurb: "Peer summary", summaryTodos: nil,
            actionTag: "none", reminderDate: nil, reminderTime: nil, reminderContent: nil,
            historyId: "2", aiCompleted: true, notified: false)
        #expect(persisted)
        #expect(try Self.decode(queue, id: "acc1:peer-1").summaryTextMessage == nil)
    }

    /// The whole extension path: a Gmail push through `NotificationService.didReceive`, a summary
    /// answered with a text message, and the staged row the merge reads. Catches the extension
    /// parsing the text message and then not passing it on.
    @MainActor
    @Test("A push through the extension stages the summary's text message")
    func pushStagesTextMessage() async throws {
        let (dir, _) = try Self.makeStaging()
        defer { try? FileManager.default.removeItem(at: dir) }
        let stagingPath = dir.appendingPathComponent("nse_staging.sqlite").path
        let accountId = "nse-text-" + UUID().uuidString
        let suiteName = "nse-text." + UUID().uuidString
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        let store = ProviderCredentialStore.shared
        let h = CredentialTestHarness()
        let http = FakeHTTP.Scenario()
        defer {
            http.close()
            try? store.remove(accountId: accountId)
            UserDefaults.standard.removePersistentDomain(forName: suiteName)
        }
        try store.install(accountId: accountId, tokens: .init(accessToken: "synthetic-access",
            refreshToken: "synthetic-refresh", expiresAt: Date().addingTimeInterval(3600)))
        try h.sessions.installNewSession(CredentialTestHarness.sessionData(access: "synthetic-backend", expired: false))
        defaults.set("{\"user@example.com\":\"\(accountId)\"}", forKey: SharedNSEData.accountMapKey)
        defaults.set(false, forKey: SharedNSEData.deviceSyncEnabledKey)

        let body = Data("Lunch on Friday?".utf8).base64EncodedString()
            .replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
        let message = """
        {"id": "synthetic-message", "threadId": "synthetic-thread",
         "internalDate": "\(Int(Date().timeIntervalSince1970 * 1000))", "labelIds": ["INBOX", "UNREAD"],
         "snippet": "Lunch on Friday?",
         "payload": {"mimeType": "text/plain",
           "headers": [{"name": "Subject", "value": "Lunch"}, {"name": "From", "value": "Sender <sender@example.com>"},
                       {"name": "To", "value": "user@example.com"}, {"name": "Message-ID", "value": "<lunch@example.com>"}],
           "body": {"size": 16, "data": "\(body)"}}}
        """
        http.register(path: "/messages/synthetic-message", response: .json(raw: message))

        let prompts = Mutex<[String]>([])
        let backend: NSETokenManager.DataForRequest = { request in
            let sent = try JSONSerialization.jsonObject(with: request.httpBody ?? Data()) as? [String: Any]
            let alias = (sent?["messages"] as? [[String: Any]])?.first?["content"] as? String ?? ""
            prompts.withLock { $0.append(alias) }
            let assistant = alias == "system_prompt_summary"
                ? #"{"todos": [], "summary": "Lunch on Friday.", "reminder": {"due_date": null, "due_time": null, "content": null}, "text_message": "Lunch Friday?"}"#
                : #"{"action": "reply"}"#
            return (try JSONSerialization.data(withJSONObject: ["assistant": assistant]),
                    HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!)
        }
        let refresh: NSEAuthSource.Transport = { _ in throw URLError(.notConnectedToInternet) }

        let delivered = CredentialTestLatch()
        let service = NotificationService()
        let content = UNMutableNotificationContent()
        content.title = "New Email"
        content.userInfo = ["provider": "gmail", "accountEmail": "user@example.com", "messageId": "synthetic-message"]
        await SharedNSEData.$suiteOverride.withValue(.init(defaults: defaults)) {
            await NSETokenManager.$storeOverride.withValue(h.sessions) {
                await AuthedHTTP.$sessionOverride.withValue(http.session) {
                    await NSEAuthSource.$transport.withValue(refresh) {
                        await BackendNSEClient.$transport.withValue(backend) {
                            await NotificationService.$stagingPathOverride.withValue(stagingPath) {
                                await NotificationService.$visualCapability.withValue({ true }) {
                                    service.didReceive(UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil)) { @Sendable _ in
                                        Task { await delivered.signal() }
                                    }
                                    await delivered.wait()
                                }
                            }
                        }
                    }
                }
            }
        }
        service.serviceExtensionTimeWillExpire()

        #expect(prompts.withLock { $0 }.first == "system_prompt_summary")
        let staged = try Self.decode(try DatabaseQueue(path: stagingPath), id: "\(accountId):synthetic-message")
        #expect(staged.summaryBlurb == "Lunch on Friday.")
        #expect(staged.actionTag == "reply")
        #expect(staged.summaryTextMessage == "Lunch Friday?")
    }
}
