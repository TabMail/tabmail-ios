/* This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at https://mozilla.org/MPL/2.0/. */

import Foundation
import Testing
@testable import TabMail

/// Graph accepts only custom `x-` headers in `internetMessageHeaders`, so a reply's
/// In-Reply-To and References must reach every Graph request that carries a reply
/// (the send, and the reply draft's create and update) as the extended properties
/// Exchange writes those headers from, and never as a standard header (#419).
@Suite("Outlook reply threading on the wire (#419)")
struct ExchangeThreadingWireTests {
    private let reply = DraftMessage(
        to: ["recipient@example.com"], subject: "Re: Plan", body: "Sure",
        inReplyTo: "parent@example.com", references: ["root@example.com", "parent@example.com"]
    )

    private func expectThreading(_ body: Data?, wrappedInMessage: Bool) throws {
        let top = try #require(try JSONSerialization.jsonObject(with: body ?? Data()) as? [String: Any])
        let message = wrappedInMessage ? try #require(top["message"] as? [String: Any]) : top
        let headers = message["internetMessageHeaders"] as? [[String: String]] ?? []
        for name in headers.map({ $0["name"] ?? "" }) {
            #expect(name.lowercased().hasPrefix("x-"), "standard header \(name) in internetMessageHeaders")
        }
        let properties = message["singleValueExtendedProperties"] as? [[String: String]] ?? []
        var values: [String: String] = [:]
        for property in properties { if let id = property["id"] { values[id] = property["value"] } }
        #expect(values == [
            "String 0x1042": "<parent@example.com>",
            "String 0x1039": "<root@example.com> <parent@example.com>",
        ])
    }

    @Test("A reply's send, draft create and draft update carry its threading as extended properties")
    func replyRequestsCarryAcceptedThreading() async throws {
        let http = FakeHTTP.Scenario()
        defer { http.close() }
        http.register(path: "/sendMail", method: "POST", response: .status(202))
        http.register(path: "/mailFolders/drafts/messages", method: "POST", response: .json(raw: #"{"id":"g1"}"#, statusCode: 201))
        http.register(path: "/messages/g1", method: "PATCH", response: .json(raw: #"{"id":"g1"}"#))
        http.register(path: "/messages/g1/attachments", method: "GET", response: .json(raw: #"{"value":[]}"#))
        let provider = ExchangeProvider(userEmail: "me@example.com", accessToken: { _ in "token" }, session: http.session)

        try await provider.send(draft: reply)
        _ = try await provider.saveDraft(reply, existingIdentity: nil, draftsFolderPath: "Drafts")
        _ = try await provider.saveDraft(reply, existingIdentity: .outlook(graphId: "g1"), draftsFolderPath: "Drafts")

        let calls = http.recordedCalls()
        let send = try #require(calls.first { $0.method == "POST" && $0.url.contains("/sendMail") })
        try expectThreading(send.body, wrappedInMessage: true)
        let create = try #require(calls.first { $0.method == "POST" && $0.url.contains("/mailFolders/drafts/messages") })
        try expectThreading(create.body, wrappedInMessage: false)
        let update = try #require(calls.first { $0.method == "PATCH" })
        try expectThreading(update.body, wrappedInMessage: false)
    }
}
