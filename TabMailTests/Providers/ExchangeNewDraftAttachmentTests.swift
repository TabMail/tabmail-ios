/* This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at https://mozilla.org/MPL/2.0/. */

import Foundation
import Synchronization
import Testing
@testable import TabMail

/// A first save must leave Graph holding every authored file, within Graph's
/// per-file upload limits. An incomplete first save must throw so the durable
/// Save producer remains retryable; only the copy made by that attempt may go.
@Suite("New Outlook draft attachments (#237)")
struct ExchangeNewDraftAttachmentTests {
    private func draft(_ files: [DraftAttachment]) -> DraftMessage {
        DraftMessage(to: ["recipient@example.com"], cc: ["copy@example.com"],
                     bcc: ["blind@example.com"], subject: "Plan", body: "Authored text\n\nNext line",
                     attachments: files)
    }

    private func provider(_ http: FakeHTTP.Scenario) -> ExchangeProvider {
        ExchangeProvider(userEmail: "owner@example.com", accessToken: { _ in "token" }, session: http.session)
    }

    /// Model only the remote effects the invariant observes, independently of
    /// which upload path the provider selects. Inline creation is refused when
    /// the combined files exceed Graph's request limit, as on the issue's wire.
    private final class Mailbox: Sendable {
        struct State {
            var creations = 0
            var files: [String: Data] = [:]
            var draftIds = Set<String>()
            var uploaded = Data()
        }
        let state = Mutex(State())

        func install(_ http: FakeHTTP.Scenario) {
            http.register(path: "/mailFolders/drafts/messages", method: "POST") { request in
                guard let body = request.body,
                      let json = try? JSONSerialization.jsonObject(with: body) as? [String: Any] else {
                    return .status(400)
                }
                let inline = json["attachments"] as? [[String: Any]] ?? []
                let count = inline.compactMap { $0["contentBytes"] as? String }
                    .compactMap { Data(base64Encoded: $0) }.reduce(0) { $0 + $1.count }
                guard count < ExchangeDraftConfig.singlePostAttachmentLimitBytes else { return .status(413) }
                return self.state.withLock { state in
                    state.creations += 1
                    let id = "g\(state.creations)"
                    state.draftIds.insert(id)
                    for file in inline {
                        if let name = file["name"] as? String, let raw = file["contentBytes"] as? String {
                            state.files[name] = Data(base64Encoded: raw)
                        }
                    }
                    return .json(raw: "{\"id\":\"\(id)\"}", statusCode: 201)
                }
            }
            http.register(path: "/messages/", method: "GET", response: .json(raw: #"{"value":[]}"#))
            http.register(path: "/messages/", method: "POST") { request in
                guard let body = request.body,
                      let json = try? JSONSerialization.jsonObject(with: body) as? [String: Any] else {
                    return .status(400)
                }
                if request.url.contains("createUploadSession") {
                    self.state.withLock { $0.uploaded = Data() }
                    return .json(raw: #"{"uploadUrl":"https://outlook.office.com/AttachmentSessions/session?authtoken=synthetic-token"}"#)
                }
                guard let name = json["name"] as? String, let raw = json["contentBytes"] as? String,
                      let bytes = Data(base64Encoded: raw),
                      bytes.count < ExchangeDraftConfig.singlePostAttachmentLimitBytes else { return .status(413) }
                self.state.withLock { $0.files[name] = bytes }
                return .json(raw: #"{"id":"file"}"#, statusCode: 201)
            }
            http.register(path: "AttachmentSessions", method: "PUT") { request in
                guard let body = request.body, let range = request.header("Content-Range"),
                      let total = range.split(separator: "/").last.flatMap({ Int($0) }) else { return .status(400) }
                return self.state.withLock { state in
                    state.uploaded.append(body)
                    if state.uploaded.count == total {
                        state.files["large.bin"] = state.uploaded
                        return .json(raw: "{}", statusCode: 201)
                    }
                    return .json(raw: "{}")
                }
            }
            http.register(path: "/messages/", method: "DELETE") { request in
                let id = URL(string: request.url)?.lastPathComponent ?? ""
                self.state.withLock { state in
                    state.draftIds.remove(id)
                    state.files.removeAll()
                }
                return .status(204)
            }
        }
    }

    @Test("The first save preserves its text, recipients and every file across the upload boundary",
          arguments: ["empty", "small", "combined", "boundary", "large"])
    func firstSaveRoundTrip(shape: String) async throws {
        let http = FakeHTTP.Scenario()
        defer { http.close() }
        let mailbox = Mailbox()
        mailbox.install(http)
        let limit = ExchangeDraftConfig.singlePostAttachmentLimitBytes
        let files: [DraftAttachment]
        switch shape {
        case "empty": files = []
        case "small": files = [DraftAttachment(filename: "small.txt", mimeType: "text/plain", data: Data("notes".utf8))]
        case "combined": files = ["one.bin", "two.bin"].map {
            DraftAttachment(filename: $0, mimeType: "application/octet-stream", data: Data(repeating: 7, count: limit / 2 + 1))
        }
        default:
            files = [DraftAttachment(filename: "large.bin", mimeType: "application/octet-stream",
                                     data: Data((0..<(limit + (shape == "large" ? 1 : 0))).map { UInt8(truncatingIfNeeded: $0) }))]
        }
        let authored = draft(files)

        let result = try await provider(http).saveDraft(authored, existingIdentity: nil, draftsFolderPath: "Drafts")

        #expect(result == .created(.outlook(graphId: "g1")))
        #expect(mailbox.state.withLock { $0.draftIds } == ["g1"])
        #expect(mailbox.state.withLock { $0.files } == Dictionary(uniqueKeysWithValues: files.map { ($0.filename, $0.data) }))
        let calls = http.recordedCalls()
        let creation = try #require(calls.first)
        let json = try #require(try JSONSerialization.jsonObject(with: creation.body ?? Data()) as? [String: Any])
        #expect(json["attachments"] == nil, "large files and several small files must not share the draft-creation request")
        #expect(json["subject"] as? String == authored.subject)
        #expect((json["body"] as? [String: String]) == ["contentType": "text", "content": authored.body])
        for (key, expected) in [("toRecipients", authored.to), ("ccRecipients", authored.cc), ("bccRecipients", authored.bcc)] {
            let recipients = json[key] as? [[String: [String: String]]]
            #expect(recipients?.compactMap { $0["emailAddress"]?["address"] } == expected)
        }
        #expect(!calls.contains { $0.method == "DELETE" || $0.method == "PATCH" })
        let puts = calls.filter { $0.method == "PUT" }
        #expect(puts.isEmpty == !(shape == "boundary" || shape == "large"))
        #expect(puts.allSatisfy { $0.header("Authorization") == nil })
    }

    @Test("A failed first attachment upload throws, removes only its incomplete draft, and a retry succeeds",
          arguments: ["list", "small", "session", "range"])
    func failedUploadIsRetryable(stage: String) async throws {
        let http = FakeHTTP.Scenario()
        defer { http.close() }
        let mailbox = Mailbox()
        let fail = Mutex(true)
        let failurePath: String
        let failureMethod: String
        switch stage {
        case "list": (failurePath, failureMethod) = ("/messages/g1/attachments", "GET")
        case "small": (failurePath, failureMethod) = ("/messages/g1/attachments", "POST")
        case "session": (failurePath, failureMethod) = ("/messages/g1/attachments/createUploadSession", "POST")
        default: (failurePath, failureMethod) = ("AttachmentSessions/session", "PUT")
        }
        http.register(path: failurePath, method: failureMethod) { request in
            if stage == "range" {
                if fail.withLock({ $0 }), request.header("Content-Range")?.hasPrefix("bytes 0-") != true {
                    return .transportError(.timedOut)
                }
                let total = request.header("Content-Range")?.split(separator: "/").last.flatMap { Int($0) }
                return mailbox.state.withLock { state in
                    state.uploaded.append(request.body ?? Data())
                    if state.uploaded.count == total {
                        state.files["large.bin"] = state.uploaded
                        return .json(raw: "{}", statusCode: 201)
                    }
                    return .json(raw: "{}")
                }
            }
            if fail.withLock({ $0 }) { return .transportError(.timedOut) }
            return .json(raw: "{}", statusCode: 201)
        }
        mailbox.install(http)
        let large = DraftAttachment(filename: "large.bin", mimeType: "application/octet-stream",
                                    data: Data(count: stage == "small" ? 1 : ExchangeDraftConfig.singlePostAttachmentLimitBytes + 1))
        let files = stage == "session"
            ? [DraftAttachment(filename: "first.txt", mimeType: "text/plain", data: Data([1])), large]
            : [large]
        let graph = provider(http)

        await #expect(throws: (any Error).self) {
            try await graph.saveDraft(draft(files), existingIdentity: nil, draftsFolderPath: "Drafts")
        }

        #expect(mailbox.state.withLock { $0.draftIds.isEmpty }, "a failed new save must not accumulate incomplete drafts on retry")
        let deleted = http.recordedCalls().filter { $0.method == "DELETE" }
        #expect(deleted.map { URL(string: $0.url)?.path } == ["/v1.0/me/messages/g1"])
        fail.withLock { $0 = false }
        let result = try await graph.saveDraft(draft(files), existingIdentity: nil, draftsFolderPath: "Drafts")
        #expect(result == .created(.outlook(graphId: "g2")))
        #expect(mailbox.state.withLock { $0.draftIds } == ["g2"])
        #expect(mailbox.state.withLock { $0.files } == Dictionary(uniqueKeysWithValues: files.map { ($0.filename, $0.data) }))
    }

    @Test("Cleanup failure preserves the original retryable upload error")
    func cleanupFailureKeepsOriginalError() async throws {
        let http = FakeHTTP.Scenario()
        defer { http.close() }
        http.register(path: "/mailFolders/drafts/messages", method: "POST", response: .json(raw: #"{"id":"g1"}"#))
        http.register(path: "/messages/g1/attachments", method: "GET", response: .status(403))
        http.register(path: "/messages/g1", method: "DELETE", response: .status(503))

        do {
            _ = try await provider(http).saveDraft(draft([DraftAttachment(filename: "a.txt", mimeType: "text/plain", data: Data([1]))]),
                                                  existingIdentity: nil, draftsFolderPath: "Drafts")
            Issue.record("an incomplete upload must throw")
        } catch {
            guard let failure = error as? ProviderError, case .networkError(let underlying) = failure,
                  let httpFailure = underlying as? HTTPError, case .networkError(let status) = httpFailure else {
                Issue.record("the original upload refusal must survive cleanup failure")
                return
            }
            #expect(status == 403)
        }
        #expect(http.recordedCalls().contains { $0.method == "DELETE" })
    }

    @Test("A refused or unaddressable creation never uploads or deletes anything",
          arguments: ["refused", "missing", "malformed"])
    func unsuccessfulCreationHasNoAttachmentEffects(shape: String) async throws {
        let http = FakeHTTP.Scenario()
        defer { http.close() }
        http.register(path: "/mailFolders/drafts/messages", method: "POST", response:
                        shape == "refused" ? .status(403) : .json(raw: shape == "missing" ? "{}" : "not json"))

        await #expect(throws: (any Error).self) {
            try await provider(http).saveDraft(draft([DraftAttachment(filename: "a.txt", mimeType: "text/plain", data: Data([1]))]),
                                              existingIdentity: nil, draftsFolderPath: "Drafts")
        }
        #expect(http.recordedCalls().count == 1)
    }
}
