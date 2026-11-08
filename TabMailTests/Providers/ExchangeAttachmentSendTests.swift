/* This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at https://mozilla.org/MPL/2.0/. */

import Foundation
import Synchronization
import Testing
@testable import TabMail

/// An Outlook send must deliver one message carrying every authored file, whatever
/// the files' sizes, keep a reply in its thread, and leave nothing behind in Drafts (#422). Graph limits a file
/// added inline, in `sendMail` or in a single attachment POST, to under 3 MB, and
/// asks for an upload session for 3-150 MB ("Attach large files to Outlook
/// messages"). The fake mailbox refuses what Graph documents as refused, at the
/// strict decimal reading of that limit, and records only the remote effects: what
/// was sent and which drafts remain. The file sizes stay clear of the window
/// between 3,000,000 bytes and the app's binary-megabyte constant (#433).
@Suite("Outlook sends with attachments (#422)")
struct ExchangeAttachmentSendTests {
    /// Graph's documented "under 3 MB", read strictly.
    private static let documentedInlineLimit = 3_000_000

    private func draft(_ files: [DraftAttachment]) -> DraftMessage {
        DraftMessage(to: ["recipient@example.com"], cc: ["copy@example.com"],
                     bcc: ["blind@example.com"], subject: "Re: Plan", body: "Authored text",
                     inReplyTo: "parent@example.com",
                     references: ["root@example.com", "parent@example.com"], attachments: files)
    }

    private func provider(_ http: FakeHTTP.Scenario) -> ExchangeProvider {
        ExchangeProvider(userEmail: "owner@example.com", accessToken: { _ in "token" }, session: http.session)
    }

    private static func file(_ name: String, bytes: Int) -> DraftAttachment {
        DraftAttachment(filename: name, mimeType: "application/octet-stream",
                        data: Data((0..<bytes).map { UInt8(truncatingIfNeeded: $0 &* 31 &+ name.count) }))
    }

    private final class Mailbox: Sendable {
        /// `@unchecked Sendable`: the JSON dictionary is decoded from a request body and only
        /// stored or read inside `state`'s lock.
        struct Message: @unchecked Sendable {
            var json: [String: Any]
            var files: [String: Data]
        }
        struct State {
            var creations = 0
            var drafts: [String: Message] = [:]
            var sent: [Message] = []
            var uploads: [String: (name: String, total: Int, bytes: Data)] = [:]
            var uploadAuthorizations: [String?] = []
        }
        let state = Mutex(State())
        /// A path suffix whose next POST times out once, as a lost connection would.
        let failOnce = Mutex<String?>(nil)

        private static func inlineFiles(_ json: [String: Any]) -> [String: Data]? {
            var files: [String: Data] = [:]
            for file in json["attachments"] as? [[String: Any]] ?? [] {
                guard let name = file["name"] as? String, let raw = file["contentBytes"] as? String,
                      let bytes = Data(base64Encoded: raw),
                      bytes.count < ExchangeAttachmentSendTests.documentedInlineLimit else { return nil }
                files[name] = bytes
            }
            return files
        }

        private static func json(_ request: FakeHTTP.Request) -> [String: Any]? {
            request.body.flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] }
        }

        /// The message id in `/messages/{id}/…`.
        private static func messageId(_ request: FakeHTTP.Request) -> String? {
            let parts = request.url.pathComponents
            return parts.firstIndex(of: "messages").flatMap { $0 + 1 < parts.count ? parts[$0 + 1] : nil }
        }

        func install(_ http: FakeHTTP.Scenario) {
            http.register(path: "/sendMail", method: "POST") { request in
                guard let wrapper = Self.json(request), let message = wrapper["message"] as? [String: Any],
                      let files = Self.inlineFiles(message) else { return .status(413) }
                self.state.withLock { $0.sent.append(Message(json: message, files: files)) }
                return .status(202)
            }
            http.register(path: "/mailFolders/drafts/messages", method: "POST") { request in
                guard let json = Self.json(request), let files = Self.inlineFiles(json) else { return .status(413) }
                return self.state.withLock { state in
                    state.creations += 1
                    let id = "g\(state.creations)"
                    state.drafts[id] = Message(json: json, files: files)
                    return .json(raw: "{\"id\":\"\(id)\"}", statusCode: 201)
                }
            }
            http.register(path: "/messages/", method: "GET") { request in
                let id = Self.messageId(request) ?? ""
                return self.state.withLock { $0.drafts[id] } == nil ? .status(404) : .json(raw: #"{"value":[]}"#)
            }
            http.register(path: "/messages/", method: "POST") { request in
                let id = Self.messageId(request) ?? ""
                let path = request.url.path
                let fails = self.failOnce.withLock { suffix in
                    guard let target = suffix, path.hasSuffix(target) else { return false }
                    suffix = nil
                    return true
                }
                if fails { return .transportError(.timedOut) }
                return self.state.withLock { state in
                    guard state.drafts[id] != nil else { return .status(404) }
                    if path.hasSuffix("/send") {
                        state.sent.append(state.drafts.removeValue(forKey: id)!)
                        return .status(202)
                    }
                    if path.hasSuffix("/createUploadSession") {
                        guard let item = Self.json(request)?["AttachmentItem"] as? [String: Any],
                              let name = item["name"] as? String, let size = item["size"] as? Int,
                              size >= ExchangeAttachmentSendTests.documentedInlineLimit else { return .status(400) }
                        state.uploads[id] = (name, size, Data())
                        return .json(raw: "{\"uploadUrl\":\"https://outlook.office.com/AttachmentSessions/\(id)?authtoken=synthetic-token\"}")
                    }
                    guard let json = Self.json(request), let name = json["name"] as? String,
                          let files = Self.inlineFiles(["attachments": [json]]), let bytes = files[name] else {
                        return .status(413)
                    }
                    state.drafts[id]?.files[name] = bytes
                    return .json(raw: #"{"id":"file"}"#, statusCode: 201)
                }
            }
            http.register(path: "AttachmentSessions", method: "PUT") { request in
                let id = request.url.lastPathComponent
                return self.state.withLock { state in
                    state.uploadAuthorizations.append(request.header("Authorization"))
                    guard var upload = state.uploads[id], state.drafts[id] != nil else { return .status(404) }
                    upload.bytes.append(request.body ?? Data())
                    state.uploads[id] = upload
                    guard upload.bytes.count == upload.total else { return .json(raw: "{}") }
                    state.drafts[id]?.files[upload.name] = upload.bytes
                    state.uploads[id] = nil
                    return .json(raw: "{}", statusCode: 201)
                }
            }
            http.register(path: "/messages/", method: "DELETE") { request in
                let id = request.url.lastPathComponent
                return self.state.withLock { $0.drafts.removeValue(forKey: id) } == nil ? .status(404) : .status(204)
            }
        }

        var sent: [Message] { state.withLock { $0.sent } }
        var draftIds: Set<String> { state.withLock { Set($0.drafts.keys) } }
    }

    private static func expectSent(_ message: Mailbox.Message, matches authored: DraftMessage) {
        #expect(message.files == Dictionary(uniqueKeysWithValues: authored.attachments.map { ($0.filename, $0.data) }))
        #expect(message.json["subject"] as? String == authored.subject)
        #expect((message.json["body"] as? [String: String]) == ["contentType": "text", "content": authored.body])
        for (key, expected) in [("toRecipients", authored.to), ("ccRecipients", authored.cc), ("bccRecipients", authored.bcc)] {
            let recipients = message.json[key] as? [[String: [String: String]]]
            #expect(recipients?.compactMap { $0["emailAddress"]?["address"] } == expected)
        }
        // A reply keeps its thread whichever way it is sent (#419).
        let properties = message.json["singleValueExtendedProperties"] as? [[String: String]] ?? []
        #expect(Dictionary(uniqueKeysWithValues: properties.compactMap { p in p["id"].map { ($0, p["value"] ?? "") } }) == [
            "String 0x1042": "<parent@example.com>",
            "String 0x1039": "<root@example.com> <parent@example.com>",
        ])
    }

    @Test("One message goes out carrying every file, and no draft is left behind",
          arguments: ["small", "combined", "large", "mixed"])
    func sendCarriesEveryFile(shape: String) async throws {
        let http = FakeHTTP.Scenario()
        defer { http.close() }
        let mailbox = Mailbox()
        mailbox.install(http)
        let small = Self.file("notes.txt", bytes: 5)
        let large = Self.file("photo.jpg", bytes: 6_000_000)
        let files: [DraftAttachment] = switch shape {
        case "small": [small]
        case "combined": [Self.file("one.bin", bytes: 1_600_000), Self.file("two.bin", bytes: 1_600_000)]
        case "large": [large]
        default: [small, large, Self.file("other.pdf", bytes: 7_000_000)]
        }
        let authored = draft(files)

        try await provider(http).send(draft: authored)

        let sent = mailbox.sent
        #expect(sent.count == 1)
        guard sent.count == 1 else { return }
        Self.expectSent(sent[0], matches: authored)
        #expect(mailbox.draftIds.isEmpty)
        #expect(mailbox.state.withLock { $0.uploadAuthorizations.allSatisfy { $0 == nil } },
                "the pre-authenticated upload URL must not also carry the account token")
    }

    @Test("A send without attachments stays one sendMail call")
    func sendWithoutAttachments() async throws {
        let http = FakeHTTP.Scenario()
        defer { http.close() }
        let mailbox = Mailbox()
        mailbox.install(http)
        let authored = draft([])

        try await provider(http).send(draft: authored)

        let sent = mailbox.sent
        #expect(sent.count == 1)
        guard sent.count == 1 else { return }
        Self.expectSent(sent[0], matches: authored)
        #expect(http.recordedCalls().map { "\($0.method) \(URL(string: $0.url)?.path ?? "")" } == ["POST /v1.0/me/sendMail"])
    }

    @Test("A failed send throws, removes only its own draft, and the retry sends exactly once",
          arguments: ["upload", "send"])
    func failedSendIsRetryable(stage: String) async throws {
        let http = FakeHTTP.Scenario()
        defer { http.close() }
        let mailbox = Mailbox()
        mailbox.failOnce.withLock { $0 = stage == "upload" ? "/createUploadSession" : "/send" }
        mailbox.install(http)
        let authored = draft([Self.file("notes.txt", bytes: 5), Self.file("photo.jpg", bytes: 6_000_000)])
        let graph = provider(http)

        await #expect(throws: (any Error).self) {
            try await graph.send(draft: authored)
        }

        #expect(mailbox.sent.isEmpty)
        #expect(mailbox.draftIds.isEmpty, "a failed send must not leave its draft behind for every retry")
        let deleted = http.recordedCalls().filter { $0.method == "DELETE" }
        #expect(deleted.map { URL(string: $0.url)?.path } == ["/v1.0/me/messages/g1"])

        try await graph.send(draft: authored)

        let sent = mailbox.sent
        #expect(sent.count == 1)
        guard sent.count == 1 else { return }
        Self.expectSent(sent[0], matches: authored)
        #expect(mailbox.draftIds.isEmpty)
    }
}
