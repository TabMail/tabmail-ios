/* This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at https://mozilla.org/MPL/2.0/. */

import Foundation
import GRDB
import Testing
@testable import TabMail

/// An Outlook send asks Graph to give the message the Message-ID the Outbox keys
/// its optimistic Sent row by. Graph answers a send with no id, so that row is
/// replaced only when sync finds a Sent Items copy whose `internetMessageId`
/// matches it; a copy with an id Graph made up leaves the row beside it, and a
/// reply to the row names an id no recipient has. The id goes as the message's
/// `internetMessageId`, which Graph lets a draft set, on both send routes:
/// `sendMail` for a message without files, and the draft create before
/// `/messages/{id}/send` for one with files. A reply's In-Reply-To and References
/// travel beside it as the MAPI properties Exchange writes those headers from.
@Suite("Outlook sends carry the Outbox's Message-ID")
struct ExchangeSentMessageIdTests {

    private static let file = DraftAttachment(filename: "a.txt", mimeType: "text/plain", data: Data("file".utf8))

    private func draft(
        messageId: String, files: [DraftAttachment] = [],
        inReplyTo: String? = nil, references: [String] = []
    ) -> DraftMessage {
        var draft = DraftMessage(
            to: ["recipient@example.com"], subject: "Plan", body: "Text",
            inReplyTo: inReplyTo, references: references, attachments: files)
        draft.messageId = messageId
        return draft
    }

    private func provider(_ http: FakeHTTP.Scenario) -> ExchangeProvider {
        ExchangeProvider(userEmail: "owner@example.com", accessToken: { _ in "token" }, session: http.session)
    }

    /// The message a request hands Graph: the `sendMail` body wraps it in
    /// `message`, a draft create or update is the message itself.
    private func requestedMessage(_ body: Data?, wrappedInMessage: Bool) throws -> [String: Any] {
        let top = try #require(try JSONSerialization.jsonObject(with: body ?? Data()) as? [String: Any])
        return wrappedInMessage ? try #require(top["message"] as? [String: Any]) : top
    }

    /// The Message-ID the request asks Graph to give the message, or nil.
    private func requestedMessageId(_ body: Data?, wrappedInMessage: Bool) throws -> String? {
        try requestedMessage(body, wrappedInMessage: wrappedInMessage)["internetMessageId"] as? String
    }

    /// Every extended property the request sets, by property id.
    private func requestedProperties(_ body: Data?, wrappedInMessage: Bool) throws -> [String: String] {
        let message = try requestedMessage(body, wrappedInMessage: wrappedInMessage)
        let properties = message["singleValueExtendedProperties"] as? [[String: String]] ?? []
        var byId: [String: String] = [:]
        for property in properties {
            let id = try #require(property["id"])
            #expect(byId[id] == nil, "property \(id) is set twice")
            byId[id] = property["value"]
        }
        return byId
    }

    @Test("A send without files asks sendMail for the Outbox's Message-ID",
          arguments: ["<outbox-1@example.com>", "outbox-1@example.com"])
    func sendMailCarriesTheMessageId(messageId: String) async throws {
        let http = FakeHTTP.Scenario()
        defer { http.close() }
        http.register(path: "/sendMail", method: "POST", response: .status(202))

        try await provider(http).send(draft: draft(messageId: messageId))

        let send = try #require(http.recordedCalls().first { $0.url.contains("/sendMail") })
        let requested = try requestedMessageId(send.body, wrappedInMessage: true)
        #expect(requested == "<outbox-1@example.com>",
                "the sent copy must carry the id the optimistic Sent row is keyed by")
        #expect(requested.map(EmailFilter.normalizeMessageId) == EmailFilter.normalizeMessageId(messageId),
                "sync reads the copy's id into the same key the row holds")
    }

    @Test("A send with files creates its draft with the Outbox's Message-ID, then sends it")
    func sendWithFilesCarriesTheMessageId() async throws {
        let http = FakeHTTP.Scenario()
        defer { http.close() }
        ExchangeSentMessageIdHarness.registerDraftRoutes(http)

        try await provider(http).send(draft: draft(messageId: "<outbox-2@example.com>", files: [Self.file]))

        let calls = http.recordedCalls()
        let create = try #require(calls.first { $0.method == "POST" && $0.url.contains("/mailFolders/drafts/messages") })
        #expect(try requestedMessageId(create.body, wrappedInMessage: false) == "<outbox-2@example.com>")
        #expect(calls.contains { $0.method == "POST" && $0.url.contains("/messages/g1/send") },
                "the draft carrying the id is the message sent")
    }

    /// Every Outbox send carries a Message-ID, so every Outlook reply carries the
    /// id and its threading together.
    @Test("A reply carries its Message-ID, In-Reply-To and References, and nothing else, on both send routes",
          arguments: [false, true])
    func replyCarriesTheMessageIdAndItsThreading(withFiles: Bool) async throws {
        let http = FakeHTTP.Scenario()
        defer { http.close() }
        http.register(path: "/sendMail", method: "POST", response: .status(202))
        ExchangeSentMessageIdHarness.registerDraftRoutes(http)
        let reply = draft(
            messageId: "<reply-1@example.com>", files: withFiles ? [Self.file] : [],
            inReplyTo: "parent@example.com", references: ["<root@example.com>", "parent@example.com"])

        try await provider(http).send(draft: reply)

        let calls = http.recordedCalls()
        let carrier = try #require(withFiles
            ? calls.first(where: { $0.method == "POST" && $0.url.contains("/mailFolders/drafts/messages") })
            : calls.first(where: { $0.url.contains("/sendMail") }))
        #expect(try requestedMessageId(carrier.body, wrappedInMessage: !withFiles) == "<reply-1@example.com>")
        #expect(try requestedProperties(carrier.body, wrappedInMessage: !withFiles) == [
            "String 0x1042": "<parent@example.com>",
            "String 0x1039": "<root@example.com> <parent@example.com>",
        ], "the reply threads for its recipients only if In-Reply-To and References go with the id")
    }

    @Test("A draft save does not set the Message-ID")
    func draftSaveLeavesTheMessageIdToGraph() async throws {
        let http = FakeHTTP.Scenario()
        defer { http.close() }
        ExchangeSentMessageIdHarness.registerDraftRoutes(http)
        let saved = draft(messageId: "<draft-1@example.com>")

        _ = try await provider(http).saveDraft(saved, existingIdentity: nil, draftsFolderPath: "Drafts")
        _ = try await provider(http).saveDraft(saved, existingIdentity: .outlook(graphId: "g1"), draftsFolderPath: "Drafts")

        let calls = http.recordedCalls()
        let create = try #require(calls.first { $0.method == "POST" && $0.url.contains("/mailFolders/drafts/messages") })
        let createMessage = try requestedMessage(create.body, wrappedInMessage: false)
        #expect(createMessage["subject"] as? String == "Plan", "precondition: this is the draft's create")
        #expect(createMessage["internetMessageId"] == nil)
        let update = try #require(calls.first { $0.method == "PATCH" })
        let updateMessage = try requestedMessage(update.body, wrappedInMessage: false)
        #expect(updateMessage["subject"] as? String == "Plan", "precondition: this is the draft's update")
        #expect(updateMessage["internetMessageId"] == nil)
    }
}

/// The Outbox hands its claimed Message-ID to the provider. Driving the real
/// Outbox send for an Outlook account pins the whole chain: the id Graph is asked
/// for is the id the optimistic Sent row is keyed by, which is the claim's id.
@Suite("An Outlook Outbox send keys its Sent row by the id it asks Graph for", .serialized, .processGlobalState)
struct ExchangeOutboxSentMessageIdTests {

    @Test("The Outbox send asks Graph for the id its Sent row and claim hold, on both send routes",
          arguments: [false, true])
    func outboxSendAsksGraphForTheRowsId(withFiles: Bool) async throws {
        let accountId = "outlook-sent-id-\(UUID().uuidString)"
        let (pool, directory, previous) = try FolderEpochTestFixture.makeAppDB()
        defer { InstalledTestDatabaseLifetime.finish(previous: previous, pool: pool, directory: directory) }
        _ = try FolderEpochTestFixture.makeAccount(id: accountId, provider: .outlook, pool: pool)
        try FolderEpochTestFixture.insertFolder(accountId: accountId, path: "SentItems", role: .sent, pool: pool)

        let files = withFiles
            ? [DraftAttachment(filename: "a.txt", mimeType: "text/plain", data: Data("file".utf8))]
            : []
        let messageId = "<outbox-claim-\(UUID().uuidString)@example.com>"
        var claimed = OutboxMessage(
            accountId: accountId,
            draft: DraftMessage(to: ["recipient@example.com"], subject: "Outbox send", body: "Body", attachments: files))
        claimed.status = OutboxStatus.sending.rawValue
        claimed.sentMessageId = messageId
        try OutboxMessage.saveAttachments(files, dirName: claimed.id)
        defer { claimed.deleteAttachments() }
        let toInsert = claimed
        try await pool.write { db in try toInsert.insert(db) }

        let http = FakeHTTP.Scenario()
        defer { http.close() }
        http.register(path: "/sendMail", method: "POST", response: .status(202))
        ExchangeSentMessageIdHarness.registerDraftRoutes(http)
        // The post-send Sent sync's listing reads which Sent rows exist the
        // moment it is asked for: the optimistic row the send left. This fake's
        // Sent folder is empty, so once that sync ends it has removed the row;
        // the row is read here, before it can.
        let sentRowsAtListing = SentRowsBox()
        let sentFolderId = "\(accountId):SentItems"
        http.register(path: Self.sentListingPath, method: "GET") { [pool] _ in
            let keys = (try? pool.read { db in
                try MessageHeader.filter(Column("folderId") == sentFolderId).fetchAll(db).map(\.rfc822MessageId)
            }) ?? []
            sentRowsAtListing.recordFirst(keys)
            return .json(raw: #"{"value":[]}"#)
        }
        let provider = ExchangeProvider(userEmail: "\(accountId)@example.com", accessToken: { _ in "token" }, session: http.session)

        try await TestProviderRegistry.withRegisteredProvider(accountId: accountId, provider: provider) {
            await AccountManager.shared.sendClaimedOutboxMessageForTesting(claimed, messageId: messageId)
            // A finished send starts a Sent-folder sync on the account's work
            // queue without waiting for it. That sync uses this scenario's
            // session, so it must end before `http.close()` invalidates the
            // session: a request on an invalidated session raises an exception
            // Swift cannot catch, which ends the whole test process.
            let queue = try #require(await AccountManager.shared.workQueues[accountId])
            #expect(await Self.postSendSentSyncEnded(http: http, queue: queue),
                    "the post-send Sent sync reached the fake and finished")
        }

        let calls = http.recordedCalls()
        #expect(calls.contains { $0.url.contains(withFiles ? "/messages/g1/send" : "/sendMail") },
                "precondition: the message went out on the \(withFiles ? "files" : "sendMail") route")
        let carrier = try #require(withFiles
            ? calls.first(where: { $0.method == "POST" && $0.url.contains("/mailFolders/drafts/messages") })
            : calls.first(where: { $0.url.contains("/sendMail") }))
        let top = try #require(try JSONSerialization.jsonObject(with: carrier.body ?? Data()) as? [String: Any])
        let message = try #require(withFiles ? top : (top["message"] as? [String: Any]))
        let wireId = try #require(message["internetMessageId"] as? String,
                                  "the Outbox send must ask Graph for the claim's Message-ID")

        let rows = try #require(sentRowsAtListing.first, "the post-send Sent sync listed the Sent folder")
        #expect(rows.count == 1, "the send leaves one optimistic Sent row")
        guard rows.count == 1 else { return }
        #expect(EmailFilter.normalizeMessageId(wireId) == rows[0],
                "sync replaces the row only with a Sent copy whose id matches the row's key")
        #expect(rows[0] == EmailFilter.normalizeMessageId(messageId),
                "the row is keyed by the claim's id, which a retry sends again")
    }

    private static let sentListingPath = "/mailFolders/SentItems/messages"

    /// The Sent rows' Message-ID keys at the first Sent listing, written from
    /// the fake's handler thread and read by the test.
    private final class SentRowsBox: @unchecked Sendable {
        private let lock = NSLock()
        private var stored: [String?]?
        func recordFirst(_ keys: [String?]) { lock.lock(); if stored == nil { stored = keys }; lock.unlock() }
        var first: [String?]? { lock.lock(); defer { lock.unlock() }; return stored }
    }
    private static let settleAttempts = 500
    private static let settleInterval = Duration.milliseconds(10)

    /// True once the post-send Sent sync has begun (its listing request reached
    /// the fake) and ended (the work queue holds no running or waiting work).
    /// Checking the request first closes the start race: the queue is also idle
    /// before the unstructured sync has been scheduled at all.
    private static func postSendSentSyncEnded(http: FakeHTTP.Scenario, queue: ProviderWorkQueue) async -> Bool {
        for _ in 0..<settleAttempts {
            let began = http.recordedCalls().contains { $0.method == "GET" && $0.url.contains(sentListingPath) }
            let idle = await queue.activeOperations == 0
            let empty = await queue.waitingCount == 0
            if began && idle && empty { return true }
            try? await Task.sleep(for: settleInterval)
        }
        return false
    }
}

/// Graph routes for a draft create, its files, and its send.
private enum ExchangeSentMessageIdHarness {
    static func registerDraftRoutes(_ http: FakeHTTP.Scenario) {
        http.register(path: "/mailFolders/drafts/messages", method: "POST", response: .json(raw: #"{"id":"g1"}"#, statusCode: 201))
        http.register(path: "/messages/g1", method: "PATCH", response: .json(raw: #"{"id":"g1"}"#))
        http.register(path: "/messages/g1/attachments", method: "GET", response: .json(raw: #"{"value":[]}"#))
        http.register(path: "/messages/g1/attachments", method: "POST", response: .json(raw: #"{"id":"a1"}"#, statusCode: 201))
        http.register(path: "/messages/g1/send", method: "POST", response: .status(202))
    }
}
