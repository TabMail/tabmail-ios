/* This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at https://mozilla.org/MPL/2.0/. */

import Foundation
import GRDB
import Synchronization
import SwiftUI
import Testing
import UIKit
@testable import TabMail

/// #217 (ADR-IOS-091, last save wins) end to end against the real providers on
/// canned HTTP. THE INVARIANTS:
/// 1. Every open of a saved Gmail or Outlook draft with no unsent edits, from any
///    screen, shows the server's version, every field from that one version.
/// 2. Opening never loses local content: unsent edits, an unreadable or gone copy
///    and a timeout all open the local row unchanged.
/// 3. A save replaces the server copy without reading it first, and what it saved
///    (attachments included) is what the next open's reload brings back.
/// 4. Taking over another app's draft keeps its inline images and attachments.
@Suite("Draft open reload, end to end (#217)", .serialized, .processGlobalState)
@MainActor
struct DraftOpenReloadTests {
    private func withInstalledPool(_ body: (DatabasePool) async throws -> Void) async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("draft-open-reload-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        var configuration = Configuration()
        configuration.foreignKeysEnabled = true
        let pool = try DatabasePool(
            path: directory.appendingPathComponent("test.sqlite").path, configuration: configuration)
        let appDatabase = try AppDatabase(dbPool: pool)
        let previous = AppDatabase.shared.withLock { current -> AppDatabase? in
            let saved = current
            current = appDatabase
            return saved
        }
        defer {
            InstalledTestDatabaseLifetime.finish(previous: previous, pool: pool, directory: directory)
        }
        try await body(pool)
    }

    private nonisolated static let accountId = "acc-217-open-reload"

    /// Runs `body` with `provider` registered for the account, unregistering it
    /// before returning, so no later test sees it.
    private func withRegisteredProvider(
        _ provider: any EmailProvider, _ body: () async throws -> Void
    ) async throws {
        await AccountManager.shared.registerProviderForTesting(accountId: Self.accountId, provider: provider)
        do {
            try await body()
        } catch {
            await AccountManager.shared.unregisterProviderForTesting(accountId: Self.accountId)
            throw error
        }
        await AccountManager.shared.unregisterProviderForTesting(accountId: Self.accountId)
    }

    /// A saved draft "Plan" to alice, body "phone edit", at Graph id `g1` (Gmail `r1`).
    private nonisolated func insertDraft(
        _ db: Database, provider: AccountProvider = .outlook, status: String? = "pushed"
    ) throws -> Draft {
        var account = Account(emailAddress: "owner@example.com", displayName: "Test", provider: provider)
        account.id = Self.accountId
        try account.insert(db)
        var draft = Draft(
            id: "adopted:open-reload", accountId: account.id,
            toJSON: Draft.encodeStringArray(["alice@example.com"]), ccJSON: "[]", bccJSON: "[]",
            subject: "Plan", body: "phone edit", replyToId: nil, isForward: false,
            editHistoryJSON: nil, createdAt: 1, updatedAt: 2,
            serverDraftId: provider == .gmail ? "r1" : "g1", serverPushStatus: status,
            rfc822MessageId: nil, attachmentsDirName: nil)
        draft.instanceEpoch = "E1"
        try draft.insert(db)
        return draft
    }

    private nonisolated static func base64URL(_ data: Data) -> String {
        data.base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }

    /// The draft as the Graph API returns it.
    private nonisolated static func copyJSON(body: String, subject: String = "Plan") -> String {
        """
        {"id":"g1","subject":"\(subject)","from":{"emailAddress":{"address":"owner@example.com"}},\
        "toRecipients":[{"emailAddress":{"address":"alice@example.com"}}],\
        "receivedDateTime":"\(ISO8601DateFormatter().string(from: Date()))","isRead":true,"isDraft":true,\
        "hasAttachments":false,"body":{"contentType":"html","content":"<p>\(body)</p>"}}
        """
    }

    /// A real Exchange provider, so the open resolves the row's identity and reaches
    /// the wire; `copyResponse` answers the draft read.
    private func exchangeProvider(
        _ http: FakeHTTP.Scenario, copyResponse: FakeHTTP.CannedResponse
    ) -> ExchangeProvider {
        http.register(path: "/messages/g1", method: "GET", response: copyResponse)
        http.register(path: "/messages/g1/attachments", method: "GET", response: .json(raw: #"{"value":[]}"#))
        return ExchangeProvider(
            userEmail: "owner@example.com", accessToken: { _ in "token" }, session: http.session)
    }

    // MARK: - 1. Every open follows the server

    @Test("Opening a draft with no unsent edits takes subject, To, Bcc and body from the fetched copy")
    func openReloadsEveryFieldFromTheFetchedCopy() async throws {
        try await withInstalledPool { pool in
            let draft = try await pool.write { try insertDraft($0) }
            let http = FakeHTTP.Scenario()
            defer { http.close() }
            let date = ISO8601DateFormatter().string(from: Date())
            let provider = exchangeProvider(http, copyResponse: .json(raw: """
                {"id":"g1","subject":"fresh subject","from":{"emailAddress":{"address":"owner@example.com"}},\
                "toRecipients":[{"emailAddress":{"address":"fresh@example.com"}}],\
                "bccRecipients":[{"emailAddress":{"address":"new-bcc@example.com"}}],\
                "receivedDateTime":"\(date)","isRead":true,"isDraft":true,"hasAttachments":false,\
                "body":{"contentType":"html","content":"<p>fresh body</p>"}}
                """))
            try await withRegisteredProvider(provider) {
                var coverShown = false
                await ExternalDraftAdoption.refreshBeforeOpen(
                    draftId: draft.id, willReadServer: { coverShown = true })

                #expect(coverShown, "the editor is covered while the server copy is read")
                let row = try #require(try await pool.read { try Draft.fetchOne($0, key: draft.id) })
                #expect(row.body == "fresh body")
                #expect(row.subject == "fresh subject")
                #expect(RecipientEntry(row.toArray).addresses == ["fresh@example.com"])
                #expect(RecipientEntry(row.bccArray).addresses == ["new-bcc@example.com"])
                #expect(row.serverPushStatus == "pushed")
                #expect(row.pushAttemptVersion > draft.pushAttemptVersion)
                #expect(!http.recordedCalls().contains { $0.method != "GET" }, "opening never writes to the server")
            }
        }
    }

    @Test("Opening takes a confirmed empty server body instead of keeping the old one")
    func openTakesAnEmptyServerBody() async throws {
        try await withInstalledPool { pool in
            let draft = try await pool.write { try insertDraft($0) }
            let http = FakeHTTP.Scenario()
            defer { http.close() }
            let provider = exchangeProvider(http, copyResponse: .json(raw: Self.copyJSON(body: "")))
            try await withRegisteredProvider(provider) {
                await ExternalDraftAdoption.refreshBeforeOpen(draftId: draft.id, willReadServer: {})
                let row = try #require(try await pool.read { try Draft.fetchOne($0, key: draft.id) })
                #expect(row.body.isEmpty, "a successful empty body must replace the old text")
                #expect(row.serverPushStatus == "pushed")
            }
        }
    }

    private func textViews(_ view: UIView) -> [UITextView] {
        (view as? UITextView).map { [$0] } ?? view.subviews.flatMap { textViews($0) }
    }

    @Test("Resuming a saved draft from a direct presenter shows the server's newer version")
    func directPresenterShowsTheServerVersion() async throws {
        try await withInstalledPool { pool in
            let draft = try await pool.write { try insertDraft($0) }
            let account = try #require(try await pool.read { try Account.fetchOne($0, key: draft.accountId) })
            let http = FakeHTTP.Scenario()
            defer { http.close() }
            let provider = exchangeProvider(http, copyResponse: .json(raw: Self.copyJSON(body: "fresh remote body")))
            try await withRegisteredProvider(provider) {
                let scene = try #require(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
                let navigationStore = NavigationStore()
                navigationStore.accounts = [account]
                let window = UIWindow(windowScene: scene)
                window.frame = CGRect(x: 0, y: 0, width: 390, height: 844)
                window.rootViewController = UIHostingController(
                    rootView: DraftComposePresenter(draftId: draft.id).environment(navigationStore))
                window.isHidden = false
                window.makeKeyAndVisible()
                defer {
                    window.isHidden = true
                    window.rootViewController = nil
                }
                let deadline = Date().addingTimeInterval(10)
                while Date() < deadline && !textViews(window).contains(where: {
                    $0.text == "phone edit" || $0.text == "fresh remote body"
                }) {
                    try await Task.sleep(for: .milliseconds(20))
                }

                let displayed = textViews(window).map(\.text)
                #expect(displayed.contains("phone edit") || displayed.contains("fresh remote body"),
                        "precondition: the persisted draft's editor loaded")
                #expect(displayed.contains("fresh remote body"),
                        "the editor showed the older local copy although the server's was newer")
            }
        }
    }

    // MARK: - 2. Opening never loses local content

    @Test("A draft with unsent edits opens as it is, without reading the server",
          arguments: ["dirty", "pushing", "never uploaded"])
    func unsentEditsOpenWithoutAServerRead(status: String) async throws {
        try await withInstalledPool { pool in
            let draft = try await pool.write { try insertDraft($0, status: status == "never uploaded" ? nil : status) }
            let http = FakeHTTP.Scenario()
            defer { http.close() }
            let provider = exchangeProvider(http, copyResponse: .json(raw: Self.copyJSON(body: "rewritten elsewhere")))
            try await withRegisteredProvider(provider) {
                var coverShown = false
                await ExternalDraftAdoption.refreshBeforeOpen(
                    draftId: draft.id, willReadServer: { coverShown = true })

                #expect(!coverShown && http.recordedCalls().isEmpty,
                        "a row with unsent edits holds what the server lacks; it is never replaced on open")
                let row = try #require(try await pool.read { try Draft.fetchOne($0, key: draft.id) })
                #expect(row.body == "phone edit" && row.pushAttemptVersion == draft.pushAttemptVersion)
            }
        }
    }

    @Test("An unreadable or gone server copy opens the local copy untouched",
          arguments: ["offline", "server error", "gone"])
    func unreadableCopyKeepsTheLocalCopy(failure: String) async throws {
        try await withInstalledPool { pool in
            let draft = try await pool.write { try insertDraft($0) }
            let http = FakeHTTP.Scenario()
            defer { http.close() }
            let response: FakeHTTP.CannedResponse = switch failure {
            case "offline": .transportError(.notConnectedToInternet)
            case "server error": .status(500)
            default: .status(404)
            }
            let provider = exchangeProvider(http, copyResponse: response)
            try await withRegisteredProvider(provider) {
                await ExternalDraftAdoption.refreshBeforeOpen(draftId: draft.id, willReadServer: {})

                #expect(http.recordedCalls().contains { $0.method == "GET" && $0.url.contains("/messages/g1") },
                        "precondition: the server copy was read")
                let row = try #require(try await pool.read { try Draft.fetchOne($0, key: draft.id) })
                #expect(row.body == "phone edit" && row.subject == "Plan" && row.serverPushStatus == "pushed")
                #expect(row.pushAttemptVersion == draft.pushAttemptVersion)
            }
        }
    }

    @Test("An inline image that cannot be read keeps the local copy, image included")
    func unreadableInlineImageKeepsTheLocalCopy() async throws {
        try await withInstalledPool { pool in
            let dir = DraftAttachmentStorage.newStagingDirName()
            try DraftAttachmentStorage.saveAttachments(
                [DraftAttachment(filename: "image1.png", mimeType: "image/png", data: Data([1, 2]))], dirName: dir)
            defer { DraftAttachmentStorage.deleteAttachments(dirName: dir) }
            let draft = try await pool.write { db -> Draft in
                var row = try insertDraft(db)
                row.attachmentsDirName = dir
                try row.update(db)
                return row
            }
            let http = FakeHTTP.Scenario()
            defer { http.close() }
            http.register(path: "/messages/g1", method: "GET",
                          response: .json(raw: Self.copyJSON(body: "See <img src='cid:logo'>")))
            http.register(path: "/messages/g1/attachments", method: "GET", response: .json(raw: """
                {"value":[{"id":"a1","name":"image1.png","contentType":"image/png","size":2,"isInline":true,
                 "contentId":"<logo>","@odata.type":"#microsoft.graph.fileAttachment"}]}
                """))
            http.register(path: "/messages/g1/attachments/a1", method: "GET", response: .status(500))
            let provider = ExchangeProvider(
                userEmail: "owner@example.com", accessToken: { _ in "token" }, session: http.session)
            try await withRegisteredProvider(provider) {
                await ExternalDraftAdoption.refreshBeforeOpen(draftId: draft.id, willReadServer: {})

                let row = try #require(try await pool.read { try Draft.fetchOne($0, key: draft.id) })
                #expect(row.body == "phone edit" && row.attachmentsDirName == dir,
                        "a reload without the image would let the next save delete it")
                #expect(try DraftAttachmentStorage.loadAttachments(dirName: dir).map(\.filename) == ["image1.png"])
            }
        }
    }

    // MARK: - 3. Last save wins, and the reload brings back what was saved

    @Test("A save replaces a server copy another app changed, without reading it first")
    func saveReplacesAChangedServerCopy() async throws {
        try await withInstalledPool { pool in
            let draft = try await pool.write { try insertDraft($0, status: "dirty") }
            let provider = MockEmailProvider(saveDraftResult: .created(.outlook(graphId: "g1")))
            await provider.setDraftCopy(.failure(URLError(.badServerResponse)))

            let outcome = try await DraftStore.shared.pushDraftToServer(
                draftId: draft.id, expectedInstanceEpoch: "E1", provider: provider,
                runtimeKind: .outlook, draftsFolderPath: "Drafts")

            #expect(outcome == .completed)
            #expect(await provider.fetchDraftCopyLog.isEmpty, "last save wins: the upload never reads the server first")
            #expect(await provider.callLog.contains {
                $0.contains("existingIdentity:Optional(TabMail.DraftDeleteIdentity.outlook(graphId: \"g1\"))")
            }, "the upload replaces the copy at its address")
            let row = try await pool.read { try Draft.fetchOne($0, key: draft.id) }
            #expect(row?.serverPushStatus == "pushed")
        }
    }

    final class ServerModel: Sendable {
        struct Attachment: Sendable {
            let id: String
            let name: String
            let contentType: String
            let isInline: Bool
            let contentId: String?
            let bytes: Data
        }
        let subject = Mutex("Plan")
        /// The body exactly as the last PATCH sent it.
        let bodyType = Mutex("text")
        let body = Mutex("now here")
        let attachments = Mutex<[Attachment]>([])
        let patchCount = Mutex(0)
        let patchCarriedAttachments = Mutex(false)
    }

    /// A Graph server that applies exactly the documented semantics and stores what
    /// it is sent verbatim: PATCH updates subject, recipients and body (type and
    /// content as sent), never attachments; attachments are listed, read, deleted and
    /// added through `/messages/{id}/attachments`, where a single POST must be under
    /// the documented size.
    private func registerGraphServer(
        _ http: FakeHTTP.Scenario, model: ServerModel, onPatch: @escaping @Sendable () -> Void = {}
    ) {
        http.register(path: "/messages/g1", method: "GET") { _ in
            let message: [String: Any] = [
                "id": "g1", "subject": model.subject.withLock { $0 },
                "from": ["emailAddress": ["address": "owner@example.com"]],
                "toRecipients": [["emailAddress": ["address": "alice@example.com"]]],
                "receivedDateTime": ISO8601DateFormatter().string(from: Date()),
                "isRead": true, "isDraft": true, "hasAttachments": false,
                "body": ["contentType": model.bodyType.withLock { $0 }, "content": model.body.withLock { $0 }],
            ]
            guard let data = try? JSONSerialization.data(withJSONObject: message) else { return .status(500) }
            return .json(raw: String(decoding: data, as: UTF8.self))
        }
        http.register(path: "/messages/g1/attachments", method: "GET") { request in
            let all = model.attachments.withLock { $0 }
            let last = request.url.lastPathComponent
            if let one = all.first(where: { $0.id == last }) {
                return .json(raw: "{\"contentBytes\":\"\(one.bytes.base64EncodedString())\"}")
            }
            let items: [[String: Any]] = all.map { item in
                var json: [String: Any] = [
                    "id": item.id, "name": item.name, "contentType": item.contentType, "size": item.bytes.count,
                    "isInline": item.isInline, "@odata.type": "#microsoft.graph.fileAttachment",
                ]
                if let contentId = item.contentId { json["contentId"] = contentId }
                return json
            }
            guard let data = try? JSONSerialization.data(withJSONObject: ["value": items]) else { return .status(500) }
            return .json(raw: String(decoding: data, as: UTF8.self))
        }
        http.register(path: "/messages/g1/attachments", method: "DELETE") { request in
            let id = request.url.lastPathComponent
            model.attachments.withLock { $0.removeAll { $0.id == id } }
            return .status(204)
        }
        http.register(path: "/messages/g1/attachments", method: "POST") { request in
            guard let body = request.body,
                  let json = try? JSONSerialization.jsonObject(with: body) as? [String: Any],
                  let name = json["name"] as? String,
                  let bytes = (json["contentBytes"] as? String).flatMap({ Data(base64Encoded: $0) }) else {
                return .status(400)
            }
            guard bytes.count < ExchangeDraftConfig.singlePostAttachmentLimitBytes else { return .status(413) }
            let id = "att-\(UUID().uuidString)"
            model.attachments.withLock {
                $0.append(.init(
                    id: id, name: name, contentType: json["contentType"] as? String ?? "",
                    isInline: json["isInline"] as? Bool ?? false, contentId: json["contentId"] as? String,
                    bytes: bytes))
            }
            return .json(raw: "{\"id\":\"\(id)\"}")
        }
        http.register(path: "/messages/g1", method: "PATCH") { request in
            if let body = request.body,
               let json = try? JSONSerialization.jsonObject(with: body) as? [String: Any] {
                if json["attachments"] != nil { model.patchCarriedAttachments.withLock { $0 = true } }
                if let subject = json["subject"] as? String { model.subject.withLock { $0 = subject } }
                if let sent = json["body"] as? [String: Any],
                   let type = sent["contentType"] as? String, let content = sent["content"] as? String {
                    model.bodyType.withLock { $0 = type }
                    model.body.withLock { $0 = content }
                }
            }
            model.patchCount.withLock { $0 += 1 }
            onPatch()
            return .json(raw: #"{"id":"g1"}"#)
        }
    }

    final class StoredRaw: Sendable {
        let raw = Mutex<Data?>(nil)
    }

    /// What the user typed: blank lines, a trailing space, indentation, a quote
    /// marker and a run of blank lines, none of which may change on a save and reopen.
    private nonisolated static let typedBody = "Hi Bob,\n\n  indented line \n> quoted\n\n\nAlice"

    @Test("An Outlook draft saved and reopened has exactly the text and empty subject that were typed")
    func outlookSaveReopenKeepsTheTypedText() async throws {
        try await withInstalledPool { pool in
            let draft = try await pool.write { db -> Draft in
                var row = try insertDraft(db, status: "dirty")
                row.body = Self.typedBody
                row.subject = ""
                try row.update(db)
                return row
            }
            let model = ServerModel()
            let http = FakeHTTP.Scenario()
            defer { http.close() }
            registerGraphServer(http, model: model)
            let provider = ExchangeProvider(
                userEmail: "owner@example.com", accessToken: { _ in "token" }, session: http.session)
            #expect(try await DraftStore.shared.pushDraftToServer(
                draftId: draft.id, expectedInstanceEpoch: "E1", provider: provider,
                runtimeKind: .outlook, draftsFolderPath: "Drafts") == .completed)
            #expect(model.bodyType.withLock { $0 } == "text", "a draft uploads as the text the user typed")

            try await withRegisteredProvider(provider) {
                await ExternalDraftAdoption.refreshBeforeOpen(draftId: draft.id, willReadServer: {})
                let row = try #require(try await pool.read { try Draft.fetchOne($0, key: draft.id) })
                #expect(row.pushAttemptVersion > draft.pushAttemptVersion, "precondition: the open reloaded")
                #expect(row.body == Self.typedBody, "a save and reopen changed the spacing or line breaks")
                #expect(row.subject == "")
            }
        }
    }

    @Test("A Gmail draft saved and reopened has exactly the text and empty subject that were typed")
    func gmailSaveReopenKeepsTheTypedText() async throws {
        try await withInstalledPool { pool in
            let draft = try await pool.write { db -> Draft in
                var row = try insertDraft(db, provider: .gmail, status: "dirty")
                row.body = Self.typedBody
                row.subject = ""
                try row.update(db)
                return row
            }
            let stored = StoredRaw()
            let http = FakeHTTP.Scenario()
            defer { http.close() }
            http.register(path: "/drafts/r1", method: "PUT") { request in
                guard let body = request.body,
                      let json = try? JSONSerialization.jsonObject(with: body) as? [String: Any],
                      var raw = (json["message"] as? [String: Any])?["raw"] as? String else { return .status(400) }
                raw = raw.replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
                while raw.count % 4 != 0 { raw += "=" }
                stored.raw.withLock { $0 = Data(base64Encoded: raw) }
                return .json(raw: #"{"id":"r1","message":{"id":"m2"}}"#)
            }
            http.register(path: "/drafts/r1", method: "GET", response: .json(raw: #"{"id":"r1","message":{"id":"m2"}}"#))
            // Gmail serves the stored message's single text part, its line ends as CRLF.
            http.register(path: "/messages/m2", method: "GET") { _ in
                guard let raw = stored.raw.withLock({ $0 }).map({ String(decoding: $0, as: UTF8.self) }),
                      let split = raw.range(of: "\r\n\r\n") else { return .status(404) }
                let subject = raw[..<split.lowerBound].components(separatedBy: "\r\n")
                    .first { $0.hasPrefix("Subject:") }?.dropFirst("Subject:".count)
                    .trimmingCharacters(in: .whitespaces) ?? ""
                let text = String(raw[split.upperBound...])
                    .replacingOccurrences(of: "\r\n", with: "\n").replacingOccurrences(of: "\n", with: "\r\n")
                let message: [String: Any] = [
                    "id": "m2", "internalDate": String(Int(Date().timeIntervalSince1970 * 1000)), "labelIds": ["DRAFT"],
                    "payload": [
                        "mimeType": "text/plain",
                        "headers": [["name": "Subject", "value": subject], ["name": "From", "value": "owner@example.com"],
                                    ["name": "To", "value": "alice@example.com"]],
                        "body": ["size": text.utf8.count, "data": Self.base64URL(Data(text.utf8))],
                    ] as [String: Any],
                ]
                guard let data = try? JSONSerialization.data(withJSONObject: message) else { return .status(500) }
                return .json(raw: String(decoding: data, as: UTF8.self))
            }
            let provider = GmailProvider(
                userEmail: "owner@example.com", accessToken: { _ in "token" }, session: http.session)
            #expect(try await DraftStore.shared.pushDraftToServer(
                draftId: draft.id, expectedInstanceEpoch: "E1", provider: provider,
                runtimeKind: .gmail, draftsFolderPath: "DRAFT") == .completed)

            try await withRegisteredProvider(provider) {
                await ExternalDraftAdoption.refreshBeforeOpen(draftId: draft.id, willReadServer: {})
                let row = try #require(try await pool.read { try Draft.fetchOne($0, key: draft.id) })
                #expect(row.pushAttemptVersion > draft.pushAttemptVersion, "precondition: the open reloaded")
                #expect(row.body == Self.typedBody, "a save and reopen changed the spacing or line breaks")
                #expect(row.subject == "")
            }
        }
    }

    @Test("An attachment added to an Outlook draft is still there when the draft reopens")
    func outlookAddedAttachmentSurvivesReopen() async throws {
        try await withInstalledPool { pool in
            let dir = DraftAttachmentStorage.newStagingDirName()
            try DraftAttachmentStorage.saveAttachments(
                [DraftAttachment(filename: "added.pdf", mimeType: "application/pdf", data: Data("pdf".utf8))],
                dirName: dir)
            let draft = try await pool.write { db -> Draft in
                var row = try insertDraft(db, status: "dirty")
                row.attachmentsDirName = dir
                try row.update(db)
                return row
            }
            let model = ServerModel()
            let http = FakeHTTP.Scenario()
            defer { http.close() }
            registerGraphServer(http, model: model)
            let provider = ExchangeProvider(
                userEmail: "owner@example.com", accessToken: { _ in "token" }, session: http.session)
            let outcome = try await DraftStore.shared.pushDraftToServer(
                draftId: draft.id, expectedInstanceEpoch: "E1", provider: provider,
                runtimeKind: .outlook, draftsFolderPath: "Drafts")
            #expect(outcome == .completed, "fixture: the edit uploaded")
            #expect(model.body.withLock { $0 } == "phone edit", "fixture: the PATCH reached the fake server")

            try await withRegisteredProvider(provider) {
                await ExternalDraftAdoption.refreshBeforeOpen(draftId: draft.id, willReadServer: {})
                let row = try #require(try await pool.read { try Draft.fetchOne($0, key: draft.id) })
                defer { if let dir = row.attachmentsDirName { DraftAttachmentStorage.deleteAttachments(dirName: dir) } }
                #expect(row.pushAttemptVersion > draft.pushAttemptVersion, "precondition: the open reloaded")
                let files = try DraftAttachmentStorage.loadAttachments(dirName: row.attachmentsDirName)
                #expect(files.map(\.filename) == ["added.pdf"], "reopening removed the attachment the user added")
                #expect(files.first?.data == Data("pdf".utf8))
            }
        }
    }

    @Test("A save during this device's own in-flight upload still uploads")
    func saveDuringOwnUploadStillUploads() async throws {
        try await withInstalledPool { pool in
            let draft = try await pool.write { try insertDraft($0, status: "dirty") }
            let model = ServerModel()
            let http = FakeHTTP.Scenario()
            defer { http.close() }
            registerGraphServer(http, model: model) {
                guard model.patchCount.withLock({ $0 }) == 1 else { return }
                // The user saves a newer edit while the first upload is in flight.
                try? pool.write { db in
                    guard var row = try Draft.fetchOne(db, key: "adopted:open-reload") else { return }
                    row.body = "second edit"
                    row.updatedAt = 3
                    _ = try DraftStore.applySave(row, db: db)
                }
            }
            let provider = ExchangeProvider(
                userEmail: "owner@example.com", accessToken: { _ in "token" }, session: http.session)
            let first = try await DraftStore.shared.pushDraftToServer(
                draftId: draft.id, expectedInstanceEpoch: "E1", provider: provider,
                runtimeKind: .outlook, draftsFolderPath: "Drafts")
            #expect(first == .notApplied, "fixture: the newer save won the completion CAS")
            let second = try await DraftStore.shared.pushDraftToServer(
                draftId: draft.id, expectedInstanceEpoch: "E1", provider: provider,
                runtimeKind: .outlook, draftsFolderPath: "Drafts")
            #expect(second == .completed)
            #expect(model.body.withLock { $0 } == "second edit", "the newer save never reached the server")
        }
    }

    // MARK: - 4. Taking over keeps inline images and attachments

    @Test("Adoption carries an inline image into the draft and into its first upload")
    func adoptionKeepsInlineImages() async throws {
        try await withInstalledPool { pool in
            let header = try await pool.write { db -> MessageHeader in
                var account = Account(emailAddress: "owner@example.com", displayName: "Test", provider: .gmail)
                account.id = Self.accountId
                try account.insert(db)
                let folder = Folder(name: "Drafts", path: "DRAFT", role: .drafts, accountId: Self.accountId)
                try folder.insert(db)
                let header = MessageHeader(
                    messageId: "m1", subject: "Plan", from: "owner@example.com", fromAddress: "owner@example.com",
                    to: "alice@example.com", date: Date(), snippet: "", folderId: folder.id,
                    accountId: Self.accountId, folderPath: "DRAFT", isInInbox: false)
                try header.insert(db)
                return header
            }
            let png = UIGraphicsImageRenderer(size: CGSize(width: 1, height: 1)).pngData { context in
                UIColor.red.setFill()
                context.fill(CGRect(x: 0, y: 0, width: 1, height: 1))
            }
            let html = Self.base64URL(Data("<p>with image<img src=\"cid:picture\"></p>".utf8))
            let date = String(Int(Date().timeIntervalSince1970 * 1000))
            let http = FakeHTTP.Scenario()
            defer { http.close() }
            http.register(path: "/messages/m1", method: "GET", response: .json(raw: """
                {"id":"m1","internalDate":"\(date)","labelIds":["DRAFT"],"payload":{"mimeType":"multipart/related",\
                "headers":[{"name":"Subject","value":"Plan"},{"name":"From","value":"owner@example.com"},\
                {"name":"To","value":"alice@example.com"}],\
                "parts":[{"mimeType":"text/html","body":{"size":46,"data":"\(html)"}},\
                {"mimeType":"image/png","headers":[{"name":"Content-ID","value":"<picture>"},\
                {"name":"Content-Disposition","value":"inline"}],"body":{"size":\(png.count),"attachmentId":"img1"}}]}}
                """))
            http.register(path: "/messages/m1/attachments/img1", method: "GET",
                          response: .json(raw: "{\"size\":\(png.count),\"data\":\"\(Self.base64URL(png))\"}"))
            http.register(path: "/drafts/r1", method: "GET", response: .json(raw: #"{"id":"r1","message":{"id":"m1"}}"#))
            http.register(path: "/drafts/r1", method: "PUT", response: .json(raw: #"{"id":"r1","message":{"id":"m2"}}"#))
            let provider = GmailProvider(
                userEmail: "owner@example.com", accessToken: { _ in "token" }, session: http.session)
            try await withRegisteredProvider(provider) {
                try await ExternalDraftAdoption.adopt(
                    header: header, address: .gmail(resourceId: "r1", containedMessageId: "m1"), runtimeKind: .gmail)

                let row = try #require(try await pool.read {
                    try Draft.filter(Column("accountId") == Self.accountId).fetchOne($0)
                })
                defer { if let dir = row.attachmentsDirName { DraftAttachmentStorage.deleteAttachments(dirName: dir) } }
                let carried = try DraftAttachmentStorage.loadAttachments(dirName: row.attachmentsDirName)
                #expect(carried.contains { $0.data == png }, "the adopted draft lost its inline image")

                let saved = try await pool.write { db in
                    var edit = row
                    edit.body += " plus phone edit"
                    edit.updatedAt = Date().timeIntervalSince1970 + 1
                    return try DraftStore.applySave(edit, db: db)
                }
                #expect(saved == .applied)
                let epoch = try #require(row.instanceEpoch)
                #expect(try await DraftStore.shared.pushDraftToServer(
                    draftId: row.id, expectedInstanceEpoch: epoch, provider: provider,
                    runtimeKind: .gmail, draftsFolderPath: "DRAFT") == .completed)
                let put = try #require(http.recordedCalls().first { $0.method == "PUT" })
                let putBody = try #require(put.body)
                let json = try #require(try JSONSerialization.jsonObject(with: putBody) as? [String: Any])
                let raw = try #require((json["message"] as? [String: Any])?["raw"] as? String)
                var normalized = raw.replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
                while normalized.count % 4 != 0 { normalized += "=" }
                let decoded = try #require(Data(base64Encoded: normalized))
                #expect(String(decoding: decoded, as: UTF8.self).contains("image/png"),
                        "the replacement dropped the image the other app's draft carried")
            }
        }
    }

    @Test("IMAP adoption takes attachments from the proven read, never from a second fetch")
    func imapAdoptionUsesTheReadsAttachmentBytes() async throws {
        try await withInstalledPool { pool in
            let header = try await pool.write { db -> MessageHeader in
                var account = Account(emailAddress: "owner@example.com", displayName: "Test", provider: .imap)
                account.id = Self.accountId
                try account.insert(db)
                var folder = Folder(name: "Drafts", path: "Drafts", role: .drafts, accountId: Self.accountId)
                folder.lastKnownUidValidity = 900_001
                try folder.insert(db)
                var header = MessageHeader(
                    messageId: "7", subject: "Plan", from: "owner@example.com", fromAddress: "owner@example.com",
                    to: "alice@example.com", date: Date(), snippet: "", folderId: folder.id,
                    accountId: Self.accountId, folderPath: "Drafts", isInInbox: false)
                header.observedUidValidity = 900_001
                try header.insert(db)
                return header
            }
            // A provider whose attachment fetch cannot answer: only the bytes the
            // copy carries can reach the adopted draft.
            let provider = MockEmailProvider()
            await provider.setDraftCopy(.success(MockEmailProvider.draftCopy(
                subject: "Plan", to: ["alice@example.com"], cc: [], html: "<p>see attached</p>",
                attachmentNames: ["notes.txt"], attachmentData: ["mock-att-0": Data("notes".utf8)])))
            try await withRegisteredProvider(provider) {
                let address = try #require(try await pool.read { db in
                    try ExternalDraftAdoption.adoptableAddress(db: db, header: header, runtimeKind: .imap)
                })
                try await ExternalDraftAdoption.adopt(header: header, address: address, runtimeKind: .imap)

                let row = try #require(try await pool.read {
                    try Draft.filter(Column("accountId") == Self.accountId).fetchOne($0)
                })
                defer { if let dir = row.attachmentsDirName { DraftAttachmentStorage.deleteAttachments(dirName: dir) } }
                let files = try DraftAttachmentStorage.loadAttachments(dirName: row.attachmentsDirName)
                #expect(files.map(\.filename) == ["notes.txt"])
                #expect(files.first?.data == Data("notes".utf8))
            }
        }
    }

    @Test("A copy that carries attachment bytes but lacks one is not adopted")
    func imapAdoptionRefusesAMissingAttachment() async throws {
        try await withInstalledPool { pool in
            let header = try await pool.write { db -> MessageHeader in
                var account = Account(emailAddress: "owner@example.com", displayName: "Test", provider: .imap)
                account.id = Self.accountId
                try account.insert(db)
                var folder = Folder(name: "Drafts", path: "Drafts", role: .drafts, accountId: Self.accountId)
                folder.lastKnownUidValidity = 900_001
                try folder.insert(db)
                var header = MessageHeader(
                    messageId: "7", subject: "Plan", from: "owner@example.com", fromAddress: "owner@example.com",
                    to: "alice@example.com", date: Date(), snippet: "", folderId: folder.id,
                    accountId: Self.accountId, folderPath: "Drafts", isInInbox: false)
                header.observedUidValidity = 900_001
                try header.insert(db)
                return header
            }
            let provider = MockEmailProvider()
            await provider.setDraftCopy(.success(MockEmailProvider.draftCopy(
                subject: "Plan", to: ["alice@example.com"], cc: [], html: "<p>see attached</p>",
                attachmentNames: ["notes.txt"], attachmentData: [:])))
            try await withRegisteredProvider(provider) {
                let address = try #require(try await pool.read { db in
                    try ExternalDraftAdoption.adoptableAddress(db: db, header: header, runtimeKind: .imap)
                })
                await #expect(throws: ExternalDraftAdoption.AdoptionError.attachmentUnavailable) {
                    try await ExternalDraftAdoption.adopt(header: header, address: address, runtimeKind: .imap)
                }
                #expect(try await pool.read { try Draft.fetchCount($0) } == 0)
            }
        }
    }

    @Test("Adopting an Outlook draft takes its text, its files and every inline image from the draft itself")
    func outlookAdoptionTakesTheDraftItself() async throws {
        try await withInstalledPool { pool in
            let header = try await pool.write { db -> MessageHeader in
                var account = Account(emailAddress: "owner@example.com", displayName: "Test", provider: .outlook)
                account.id = Self.accountId
                try account.insert(db)
                let folder = Folder(name: "Drafts", path: "drafts", role: .drafts, accountId: Self.accountId)
                try folder.insert(db)
                let header = MessageHeader(
                    messageId: "g1", subject: "Plan", from: "owner@example.com", fromAddress: "owner@example.com",
                    to: "alice@example.com", date: Date(), snippet: "", folderId: folder.id,
                    accountId: Self.accountId, folderPath: "drafts", isInInbox: false)
                try header.insert(db)
                return header
            }
            let model = ServerModel()
            model.body.withLock { $0 = "Hi Bob,\r\n\r\n  indented line \r\n> quoted" }
            model.attachments.withLock {
                $0 = [.init(id: "a1", name: "notes.txt", contentType: "text/plain", isInline: false,
                            contentId: nil, bytes: Data("notes".utf8)),
                      .init(id: "a2", name: "logo.png", contentType: "image/png", isInline: true,
                            contentId: "<logo>", bytes: Data([1, 2]))]
            }
            let http = FakeHTTP.Scenario()
            defer { http.close() }
            registerGraphServer(http, model: model)
            let provider = ExchangeProvider(
                userEmail: "owner@example.com", accessToken: { _ in "token" }, session: http.session)
            try await withRegisteredProvider(provider) {
                let address = try #require(try await pool.read { db in
                    try ExternalDraftAdoption.adoptableAddress(db: db, header: header, runtimeKind: .outlook)
                })
                try await ExternalDraftAdoption.adopt(header: header, address: address, runtimeKind: .outlook)

                let row = try #require(try await pool.read {
                    try Draft.filter(Column("accountId") == Self.accountId).fetchOne($0)
                })
                defer { if let dir = row.attachmentsDirName { DraftAttachmentStorage.deleteAttachments(dirName: dir) } }
                #expect(row.serverDraftId == "g1", "the adopted row must own exactly the Graph draft it read")
                #expect(row.serverPushStatus == "pushed")
                #expect(row.body == "Hi Bob,\n\n  indented line \n> quoted")
                let files = try DraftAttachmentStorage.loadAttachments(dirName: row.attachmentsDirName)
                #expect(files.contains { $0.filename == "notes.txt" && $0.data == Data("notes".utf8) })
                #expect(files.contains { $0.data == Data([1, 2]) }, "the unreferenced inline image was dropped")
            }
        }
    }

    @Test("Fetching a synced message's attachment reads that message's part, on every provider",
          arguments: [AccountProvider.gmail, .outlook])
    func fetchAttachmentReadsTheMessagesPart(kind: AccountProvider) async throws {
        try await withInstalledPool { pool in
            let header = try await pool.write { db -> MessageHeader in
                var account = Account(emailAddress: "owner@example.com", displayName: "Test", provider: kind)
                account.id = Self.accountId
                try account.insert(db)
                let folder = Folder(name: "Inbox", path: "INBOX", role: .inbox, accountId: Self.accountId)
                try folder.insert(db)
                let header = MessageHeader(
                    messageId: "m7", subject: "Plan", from: "owner@example.com", fromAddress: "owner@example.com",
                    to: "alice@example.com", date: Date(), snippet: "", folderId: folder.id,
                    accountId: Self.accountId, folderPath: "INBOX", isInInbox: true)
                try header.insert(db)
                return header
            }
            let bytes = Data("attached".utf8)
            let http = FakeHTTP.Scenario()
            defer { http.close() }
            let provider: any EmailProvider
            if kind == .gmail {
                http.register(path: "/messages/m7/attachments/a1", method: "GET",
                              response: .json(raw: "{\"size\":\(bytes.count),\"data\":\"\(Self.base64URL(bytes))\"}"))
                provider = GmailProvider(userEmail: "owner@example.com", accessToken: { _ in "token" }, session: http.session)
            } else {
                http.register(path: "/messages/m7/attachments/a1", method: "GET",
                              response: .json(raw: "{\"contentBytes\":\"\(bytes.base64EncodedString())\"}"))
                provider = ExchangeProvider(userEmail: "owner@example.com", accessToken: { _ in "token" }, session: http.session)
            }
            try await withRegisteredProvider(provider) {
                let data = try await AccountManager.shared.fetchAttachment(for: header, section: "a1", encoding: nil)
                #expect(data == bytes)
                #expect(http.recordedCalls().contains { $0.url.contains("/messages/m7/attachments/a1") },
                        "the read must address the header's own message")
            }
        }
    }

    @Test("A demo draft saves again and reopens with its Cc and Bcc; it is never read back")
    func demoDraftKeepsRecipientsOnReopen() async throws {
        try await withInstalledPool { pool in
            let draft = try await pool.write { db in
                var draft = try insertDraft(db, status: "dirty")
                draft.serverDraftId = nil
                draft.ccJSON = Draft.encodeStringArray(["cc@example.com"])
                draft.bccJSON = Draft.encodeStringArray(["bcc@example.com"])
                try draft.update(db)
                let folder = Folder(name: "Drafts", path: "Drafts", role: .drafts, accountId: Self.accountId)
                try folder.insert(db)
                return draft
            }
            let provider = DemoProvider(accountId: Self.accountId)
            let outcome = try await DraftStore.shared.pushDraftToServer(draftId: draft.id, expectedInstanceEpoch: "E1",
                provider: provider, runtimeKind: .demo, draftsFolderPath: "Drafts")
            #expect(outcome == .completed, "fixture: the demo draft's first save succeeded")
            try await pool.write { db in
                var row = try #require(try Draft.fetchOne(db, key: draft.id))
                row.body = "second edit"
                row.serverPushStatus = "dirty"
                try row.update(db)
            }
            let second = try await DraftStore.shared.pushDraftToServer(draftId: draft.id, expectedInstanceEpoch: "E1",
                provider: provider, runtimeKind: .demo, draftsFolderPath: "Drafts")
            #expect(second == .completed, "a demo draft's second save must complete")
            let before = try #require(try await pool.read { try Draft.fetchOne($0, key: draft.id) })
            #expect(before.serverDraftId != nil, "fixture: the second save replaced an existing demo copy")
            #expect(before.ccArray == ["cc@example.com"] && before.bccArray == ["bcc@example.com"])
            try await withRegisteredProvider(provider) {
                var coverShown = false
                await ExternalDraftAdoption.refreshBeforeOpen(draftId: draft.id, willReadServer: { coverShown = true })
                #expect(!coverShown, "no other app edits a demo draft")
                let after = try #require(try await pool.read { try Draft.fetchOne($0, key: draft.id) })
                #expect(after.ccArray == before.ccArray && after.bccArray == before.bccArray,
                        "the demo copy must never replace the draft's recipients")
            }
        }
    }
}
