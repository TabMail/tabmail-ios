/* This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at https://mozilla.org/MPL/2.0/. */

import Foundation
import Testing
@testable import TabMail

/// An Outlook send asks Graph to give the message the Message-ID the Outbox keys
/// its optimistic Sent row by. Graph answers a send with no id, so that row is
/// replaced only when sync finds a Sent Items copy whose `internetMessageId`
/// matches it; a copy with an id Graph made up leaves the row beside it, and a
/// reply to the row names an id no recipient has. Graph's `internetMessageHeaders`
/// takes only custom `x-` headers, so the id travels as PidTagInternetMessageId
/// (`String 0x1035`), on both send routes: `sendMail` for a message without files,
/// and the draft create before `/messages/{id}/send` for one with files.
@Suite("Outlook sends carry the Outbox's Message-ID")
struct ExchangeSentMessageIdTests {

    private static let messageIdProperty = "String 0x1035"

    private func draft(messageId: String, files: [DraftAttachment] = []) -> DraftMessage {
        var draft = DraftMessage(
            to: ["recipient@example.com"], subject: "Plan", body: "Text", attachments: files)
        draft.messageId = messageId
        return draft
    }

    private func provider(_ http: FakeHTTP.Scenario) -> ExchangeProvider {
        ExchangeProvider(userEmail: "owner@example.com", accessToken: { _ in "token" }, session: http.session)
    }

    private func registerDraftRoutes(_ http: FakeHTTP.Scenario) {
        http.register(path: "/mailFolders/drafts/messages", method: "POST", response: .json(raw: #"{"id":"g1"}"#, statusCode: 201))
        http.register(path: "/messages/g1", method: "PATCH", response: .json(raw: #"{"id":"g1"}"#))
        http.register(path: "/messages/g1/attachments", method: "GET", response: .json(raw: #"{"value":[]}"#))
        http.register(path: "/messages/g1/attachments", method: "POST", response: .json(raw: #"{"id":"a1"}"#, statusCode: 201))
        http.register(path: "/messages/g1/send", method: "POST", response: .status(202))
    }

    /// The Message-ID the request asks Graph to give the message, or nil.
    private func requestedMessageId(_ body: Data?, wrappedInMessage: Bool) throws -> String? {
        let top = try #require(try JSONSerialization.jsonObject(with: body ?? Data()) as? [String: Any])
        let message = wrappedInMessage ? try #require(top["message"] as? [String: Any]) : top
        let properties = message["singleValueExtendedProperties"] as? [[String: String]] ?? []
        return properties.first { $0["id"] == Self.messageIdProperty }?["value"]
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
        registerDraftRoutes(http)
        let file = DraftAttachment(filename: "a.txt", mimeType: "text/plain", data: Data("file".utf8))

        try await provider(http).send(draft: draft(messageId: "<outbox-2@example.com>", files: [file]))

        let calls = http.recordedCalls()
        let create = try #require(calls.first { $0.method == "POST" && $0.url.contains("/mailFolders/drafts/messages") })
        #expect(try requestedMessageId(create.body, wrappedInMessage: false) == "<outbox-2@example.com>")
        #expect(calls.contains { $0.method == "POST" && $0.url.contains("/messages/g1/send") },
                "the draft carrying the id is the message sent")
    }

    @Test("A draft save does not set the Message-ID")
    func draftSaveLeavesTheMessageIdToGraph() async throws {
        let http = FakeHTTP.Scenario()
        defer { http.close() }
        registerDraftRoutes(http)
        let saved = draft(messageId: "<draft-1@example.com>")

        _ = try await provider(http).saveDraft(saved, existingIdentity: nil, draftsFolderPath: "Drafts")
        _ = try await provider(http).saveDraft(saved, existingIdentity: .outlook(graphId: "g1"), draftsFolderPath: "Drafts")

        let calls = http.recordedCalls()
        let create = try #require(calls.first { $0.method == "POST" && $0.url.contains("/mailFolders/drafts/messages") })
        #expect(try requestedMessageId(create.body, wrappedInMessage: false) == nil)
        let update = try #require(calls.first { $0.method == "PATCH" })
        #expect(try requestedMessageId(update.body, wrappedInMessage: false) == nil)
    }
}
