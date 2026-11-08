/* This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at https://mozilla.org/MPL/2.0/. */

import Foundation
import Synchronization
import Testing
@testable import TabMail

/// An Outlook send must deliver one message carrying every authored file, whatever
/// the files' sizes, keep a reply in its thread, and leave nothing behind in Drafts (#422).
/// A failed send must reach the Outbox with the error it would classify as before, and
/// a send must never be dropped. Graph limits a file added inline to under 3 MB and
/// asks for an upload session for 3-150 MB ("Attach large files to Outlook messages").
/// The fake mailbox records only the remote effects: what was sent and which drafts
/// remain. Adding a file to the draft refuses at Graph's own two edges
/// (`GraphAttachmentLimits`), never at the app's constant (#433). One refusal is an
/// assumption stricter than any Graph page, so it can only cause a false red:
/// `sendMail` and the draft create answer 413 for an inline file of 3,000,000 bytes
/// or more (the behaviour #422 reported; the sendMail page states no limit).
@Suite("Outlook sends with attachments (#422)")
struct ExchangeAttachmentSendTests {
    /// The inline refusal #422 reported for `sendMail`, read strictly as 3,000,000 bytes.
    private static let documentedInlineLimit = 3_000_000

    private func draft(_ files: [DraftAttachment], html: Bool = false) -> DraftMessage {
        DraftMessage(to: ["recipient@example.com"], cc: ["copy@example.com"],
                     bcc: ["blind@example.com"], subject: "Re: Plan",
                     body: html ? "<p>Authored <b>text</b></p><blockquote>Quoted</blockquote>" : "Authored text",
                     isHTML: html, inReplyTo: "parent@example.com",
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
        /// The next `/send` is applied, then its answer is lost.
        let loseSendAnswerOnce = Mutex(false)
        /// Every DELETE is refused, as an unavailable server would refuse it.
        let refuseDeletes = Mutex(false)
        /// The next `/send` is refused with this HTTP status; the draft stays.
        let refuseSendOnce = Mutex<Int?>(nil)
        /// Created drafts get ids `\(idPrefix)1`, `\(idPrefix)2`, …; Graph ids are opaque.
        let idPrefix: String

        init(idPrefix: String = "g") { self.idPrefix = idPrefix }

        private static func inlineFiles(
            _ json: [String: Any], under limit: Int = ExchangeAttachmentSendTests.documentedInlineLimit
        ) -> [String: Data]? {
            var files: [String: Data] = [:]
            for file in json["attachments"] as? [[String: Any]] ?? [] {
                guard let name = file["name"] as? String, let raw = file["contentBytes"] as? String,
                      let bytes = Data(base64Encoded: raw),
                      bytes.count < limit else { return nil }
                files[name] = bytes
            }
            return files
        }

        private static func json(_ request: FakeHTTP.Request) -> [String: Any]? {
            request.body.flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] }
        }

        /// The message id in `/messages/{id}/…`, read segment by segment from the
        /// percent-encoded path so an id holding an encoded `/` stays one id.
        private static func messageId(_ request: FakeHTTP.Request) -> String? {
            let encodedPath = URLComponents(url: request.url, resolvingAgainstBaseURL: false)?.percentEncodedPath ?? ""
            let parts = encodedPath.split(separator: "/", omittingEmptySubsequences: false).map {
                String($0).removingPercentEncoding ?? String($0)
            }
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
                    let id = "\(self.idPrefix)\(state.creations)"
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
                        let refusal = self.refuseSendOnce.withLock { status in
                            defer { status = nil }
                            return status
                        }
                        if let refusal { return .status(refusal) }
                        state.sent.append(state.drafts.removeValue(forKey: id)!)
                        let lost = self.loseSendAnswerOnce.withLock { lose in
                            defer { lose = false }
                            return lose
                        }
                        return lost ? .transportError(.timedOut) : .status(202)
                    }
                    if path.hasSuffix("/createUploadSession") {
                        guard let item = Self.json(request)?["AttachmentItem"] as? [String: Any],
                              let name = item["name"] as? String, let size = item["size"] as? Int,
                              size >= GraphAttachmentLimits.uploadSessionMinimum else { return .status(400) }
                        state.uploads[id] = (name, size, Data())
                        return .json(raw: "{\"uploadUrl\":\"https://outlook.office.com/AttachmentSessions/\(id)?authtoken=synthetic-token\"}")
                    }
                    guard let json = Self.json(request), let name = json["name"] as? String,
                          let files = Self.inlineFiles(["attachments": [json]], under: GraphAttachmentLimits.singlePostMaxExclusive),
                          let bytes = files[name] else {
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
                if self.refuseDeletes.withLock({ $0 }) { return .status(503) }
                let id = Self.messageId(request) ?? ""
                return self.state.withLock { $0.drafts.removeValue(forKey: id) } == nil ? .status(404) : .status(204)
            }
        }

        var sent: [Message] { state.withLock { $0.sent } }
        var draftIds: Set<String> { state.withLock { Set($0.drafts.keys) } }
    }

    private static func expectSent(_ message: Mailbox.Message, matches authored: DraftMessage) {
        #expect(message.files == Dictionary(uniqueKeysWithValues: authored.attachments.map { ($0.filename, $0.data) }))
        #expect(message.json["subject"] as? String == authored.subject)
        #expect((message.json["body"] as? [String: String]) == ["contentType": authored.isHTML ? "html" : "text", "content": authored.body])
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
          arguments: ["small", "combined", "large", "mixed", "html", "edge"])
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
        case "html": [small, large]
        // One file per size on either reading of Graph's 3 MB (#433).
        case "edge": GraphAttachmentLimits.edgeSizes.map { Self.file("edge-\($0).bin", bytes: $0) }
        default: [small, large, Self.file("other.pdf", bytes: 7_000_000)]
        }
        // An HTML reply or forward with files must go out as HTML, not as markup in text.
        let authored = draft(files, html: shape == "html")

        try await provider(http).send(draft: authored)

        let sent = mailbox.sent
        #expect(sent.count == 1)
        guard sent.count == 1 else { return }
        Self.expectSent(sent[0], matches: authored)
        #expect(mailbox.draftIds.isEmpty)
        #expect(mailbox.state.withLock { $0.uploadAuthorizations.allSatisfy { $0 == nil } },
                "the pre-authenticated upload URL must not also carry the account token")
        #expect(!http.recordedCalls().contains { $0.method == "DELETE" },
                "a delete after an accepted send could withdraw the message being sent")
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

    /// The Outbox decides from the thrown error whether to keep retrying (a lost
    /// connection) or to count the attempt; the draft route must hand it the same error
    /// a lost connection gives, whatever its cleanup does.
    private static func expectStillTransient(_ error: (any Error)?) {
        #expect(error is URLError, "the lost connection must reach the Outbox unchanged, got \(String(describing: error))")
        #expect(error.map(AccountManager.isTransientSendError) == true)
    }

    @Test("A failed send keeps its lost-connection error, removes only its own draft, and the retry sends exactly once",
          arguments: ["upload", "send", "send, cleanup refused"])
    func failedSendIsRetryable(stage: String) async throws {
        let http = FakeHTTP.Scenario()
        defer { http.close() }
        let mailbox = Mailbox()
        mailbox.failOnce.withLock { $0 = stage == "upload" ? "/createUploadSession" : "/send" }
        let cleanupRefused = stage == "send, cleanup refused"
        mailbox.refuseDeletes.withLock { $0 = cleanupRefused }
        mailbox.install(http)
        let authored = draft([Self.file("notes.txt", bytes: 5), Self.file("photo.jpg", bytes: 6_000_000)])
        let graph = provider(http)

        var thrown: (any Error)?
        do { try await graph.send(draft: authored) } catch { thrown = error }

        Self.expectStillTransient(thrown)
        #expect(mailbox.sent.isEmpty)
        // A refused cleanup leaves this attempt's draft, and only it, for ordinary deletion.
        #expect(mailbox.draftIds == (cleanupRefused ? ["g1"] : []),
                "a failed send must not leave its draft behind for every retry")

        try await graph.send(draft: authored)

        let sent = mailbox.sent
        #expect(sent.count == 1)
        guard sent.count == 1 else { return }
        Self.expectSent(sent[0], matches: authored)
        #expect(mailbox.draftIds == (cleanupRefused ? ["g1"] : []))
        let deleted = http.recordedCalls().filter { $0.method == "DELETE" }
        #expect(deleted.map { URL(string: $0.url)?.path } == ["/v1.0/me/messages/g1"],
                "only the failed attempt's own draft is deleted, and nothing after the accepted send")
    }

    @Test("A send whose answer is lost is retried: at worst a duplicate, never a drop")
    func lostSendAnswerIsNeverADrop() async throws {
        let http = FakeHTTP.Scenario()
        defer { http.close() }
        let mailbox = Mailbox()
        mailbox.loseSendAnswerOnce.withLock { $0 = true }
        mailbox.install(http)
        let authored = draft([Self.file("photo.jpg", bytes: 6_000_000)])
        let graph = provider(http)

        var thrown: (any Error)?
        do { try await graph.send(draft: authored) } catch { thrown = error }
        Self.expectStillTransient(thrown)
        try await graph.send(draft: authored)

        let sent = mailbox.sent
        #expect(!sent.isEmpty)
        for message in sent { Self.expectSent(message, matches: authored) }
        #expect(mailbox.draftIds.isEmpty)
    }

    @Test("A send refused by Graph stays a counted refusal, whatever its cleanup does",
          arguments: [false, true])
    func refusedSendStaysPermanent(cleanupRefused: Bool) async throws {
        let http = FakeHTTP.Scenario()
        defer { http.close() }
        let mailbox = Mailbox()
        mailbox.refuseSendOnce.withLock { $0 = 403 }
        mailbox.refuseDeletes.withLock { $0 = cleanupRefused }
        mailbox.install(http)
        let authored = draft([Self.file("notes.txt", bytes: 5), Self.file("photo.jpg", bytes: 6_000_000)])

        var thrown: (any Error)?
        do { try await provider(http).send(draft: authored) } catch { thrown = error }

        // The same refusal a `sendMail` refusal gives, so the Outbox counts it and parks
        // the row after its attempts instead of retrying it forever.
        guard let failure = thrown as? ProviderError, case .networkError(let underlying) = failure,
              let httpFailure = underlying as? HTTPError, case .networkError(let status) = httpFailure else {
            Issue.record("the refusal must reach the Outbox as networkError(403), got \(String(describing: thrown))")
            return
        }
        #expect(status == 403)
        #expect(thrown.map(AccountManager.isTransientSendError) == false)
        #expect(mailbox.sent.isEmpty)
        #expect(mailbox.draftIds == (cleanupRefused ? ["g1"] : []))
    }

    @Test("A draft whose Graph id holds reserved characters is sent, and cleaned up, as that exact resource")
    func opaqueDraftIdAddressesItsOwnResource() async throws {
        let http = FakeHTTP.Scenario()
        defer { http.close() }
        let opaque = "AAMk/a+b=c?d#"
        let mailbox = Mailbox(idPrefix: opaque)
        mailbox.failOnce.withLock { $0 = "/send" }
        mailbox.install(http)
        let authored = draft([Self.file("notes.txt", bytes: 5)])
        let graph = provider(http)

        var thrown: (any Error)?
        do { try await graph.send(draft: authored) } catch { thrown = error }
        Self.expectStillTransient(thrown)
        #expect(mailbox.draftIds.isEmpty, "the cleanup must delete the draft this attempt created")

        try await graph.send(draft: authored)

        let sent = mailbox.sent
        #expect(sent.count == 1)
        guard sent.count == 1 else { return }
        Self.expectSent(sent[0], matches: authored)
        #expect(mailbox.draftIds.isEmpty)
    }
}
