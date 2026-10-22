/* This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at https://mozilla.org/MPL/2.0/. */

import Foundation
import GRDB
import Synchronization
import SwiftUI
import Testing
import UIKit
import WebKit
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
/// 5. A draft holding an attachment TabMail cannot carry is refused, and a save
///    never deletes such an attachment from the server (#241).
/// 6. The Drafts-list loader's own sequence: open the owner, else adopt and open,
///    refuse for good, retry a failed read, or report no copy.
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

    /// A saved draft "Plan" to alice, body "phone edit", at Graph id `g1` (Gmail `r1`);
    /// `replyTo` names its parent's header id and provider message id.
    private nonisolated func insertDraft(
        _ db: Database, provider: AccountProvider = .outlook, status: String? = "pushed",
        id: String = "adopted:open-reload", replyTo: (headerId: String, messageId: String)? = nil
    ) throws -> Draft {
        var account = Account(emailAddress: "owner@example.com", displayName: "Test", provider: provider)
        account.id = Self.accountId
        try account.insert(db)
        var draft = Draft(
            id: id, accountId: account.id,
            toJSON: Draft.encodeStringArray(["alice@example.com"]), ccJSON: "[]", bccJSON: "[]",
            subject: "Plan", body: "phone edit", replyToId: replyTo?.headerId, isForward: false,
            editHistoryJSON: nil, createdAt: 1, updatedAt: 2,
            serverDraftId: provider == .gmail ? "r1" : "g1", serverPushStatus: status,
            rfc822MessageId: nil, attachmentsDirName: nil)
        draft.instanceEpoch = "E1"
        draft.replyToProviderMessageId = replyTo?.messageId
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

    /// Every alert message presented over the window's root, in order.
    private func alertMessages(_ window: UIWindow) -> [String] {
        var messages: [String] = []
        var next = window.rootViewController?.presentedViewController
        while let controller = next {
            if let message = (controller as? UIAlertController)?.message { messages.append(message) }
            next = controller.presentedViewController
        }
        return messages
    }

    private func webViews(_ view: UIView) -> [WKWebView] {
        (view as? WKWebView).map { [$0] } ?? view.subviews.flatMap { webViews($0) }
    }

    /// Opens `draftId` the way the Drafts list's direct presenter does, in a real
    /// window, and runs `body` against that window. The deadline only bounds a
    /// wait; every wait ends as soon as its condition holds.
    private func withPresentedDraft(
        _ draftId: String, pool: DatabasePool, _ body: (UIWindow) async throws -> Void
    ) async throws {
        let account = try #require(try await pool.read { try Account.fetchOne($0, key: Self.accountId) })
        let scene = try #require(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let navigationStore = NavigationStore()
        navigationStore.accounts = [account]
        let window = UIWindow(windowScene: scene)
        window.frame = CGRect(x: 0, y: 0, width: 390, height: 844)
        window.rootViewController = UIHostingController(
            rootView: DraftComposePresenter(draftId: draftId).environment(navigationStore))
        window.isHidden = false
        window.makeKeyAndVisible()
        defer {
            window.rootViewController?.dismiss(animated: false)
            window.isHidden = true
            window.rootViewController = nil
        }
        try await body(window)
    }

    private nonisolated static let presenterDeadlineSeconds: TimeInterval = 60

    private func wait(until condition: () -> Bool) async throws {
        let deadline = Date().addingTimeInterval(Self.presenterDeadlineSeconds)
        while Date() < deadline && !condition() {
            try await Task.sleep(for: .milliseconds(20))
        }
    }

    @Test("Resuming a saved draft from a direct presenter shows the server's newer version")
    func directPresenterShowsTheServerVersion() async throws {
        try await withInstalledPool { pool in
            let draft = try await pool.write { try insertDraft($0) }
            let http = FakeHTTP.Scenario()
            defer { http.close() }
            let provider = exchangeProvider(http, copyResponse: .json(raw: Self.copyJSON(body: "fresh remote body")))
            try await withRegisteredProvider(provider) {
                try await withPresentedDraft(draft.id, pool: pool) { window in
                    try await wait {
                        textViews(window).contains { $0.text == "phone edit" || $0.text == "fresh remote body" }
                    }

                    let displayed = textViews(window).map(\.text)
                    #expect(displayed.contains("phone edit") || displayed.contains("fresh remote body"),
                            "precondition: the persisted draft's editor loaded")
                    #expect(displayed.contains("fresh remote body"),
                            "the editor showed the older local copy although the server's was newer")
                }
            }
        }
    }

    @Test("A direct presenter refuses a draft whose server copy gained an attachment TabMail cannot carry")
    func directPresenterRefusesAnUncarriableDraft() async throws {
        try await withInstalledPool { pool in
            let draft = try await pool.write { try insertDraft($0) }
            let model = ServerModel()
            model.body.withLock { $0 = "edited in Outlook" }
            model.attachments.withLock {
                $0 = [.init(id: "a2", name: "Fw: Report", contentType: "message/rfc822", isInline: false,
                            contentId: nil, bytes: Data(), odataType: "#microsoft.graph.itemAttachment")]
            }
            let http = FakeHTTP.Scenario()
            defer { http.close() }
            registerGraphServer(http, model: model)
            let provider = ExchangeProvider(
                userEmail: "owner@example.com", accessToken: { _ in "token" }, session: http.session)
            try await withRegisteredProvider(provider) {
                try await withPresentedDraft(draft.id, pool: pool) { window in
                    try await wait {
                        !alertMessages(window).isEmpty || textViews(window).contains { $0.text == "phone edit" }
                    }

                    #expect(alertMessages(window) == [DraftReadConfig.unsupportedAttachmentMessage],
                            "the user is told why the draft does not open")
                    #expect(!textViews(window).contains { $0.text == "phone edit" },
                            "the stale local copy opened for editing; its save would overwrite the server's version")
                }
                let row = try #require(try await pool.read { try Draft.fetchOne($0, key: draft.id) })
                #expect(row.body == "phone edit" && row.serverPushStatus == "pushed"
                        && row.pushAttemptVersion == draft.pushAttemptVersion)
                #expect(!http.recordedCalls().contains { $0.method != "GET" }, "the refused open wrote nothing to the server")
            }
        }
    }

    /// A reply draft taken over from another app already carries that app's quote in
    /// its body, so its open adds none; a TabMail reply to the same parent quotes it.
    @Test("An adopted reply draft opens without a second quote of its parent",
          arguments: ["adopted:open-reload", "reply:\(accountId):p1@example.com"])
    func adoptedReplyAddsNoQuote(draftId: String) async throws {
        try await withInstalledPool { pool in
            let parentId = MessageIdentity.folderId(accountId: Self.accountId, folderPath: "INBOX") + ":m1"
            let draft = try await pool.write { db -> Draft in
                let draft = try insertDraft(
                    db, status: "dirty", id: draftId, replyTo: (headerId: parentId, messageId: "m1"))
                try Folder(name: "INBOX", path: "INBOX", role: .inbox, accountId: Self.accountId).insert(db)
                var parent = MessageHeader(
                    messageId: "m1", subject: "Plan", from: "alice@example.com", fromAddress: "alice@example.com",
                    to: "owner@example.com", date: Date(), snippet: "parent words",
                    folderId: MessageIdentity.folderId(accountId: Self.accountId, folderPath: "INBOX"),
                    accountId: Self.accountId, folderPath: "INBOX", isInInbox: true)
                parent.rfc822MessageId = "p1@example.com"
                try parent.insert(db)
                #expect(parent.id == parentId, "precondition: the draft names its parent's row")
                try MessageBody(contentKey: ContentKey(rawValue: parent.id), htmlContent: "<p>parent words</p>").insert(db)
                return draft
            }
            let quote = try await pool.read { db in
                try Draft.resolveReplyQuote(
                    draftKey: draft.id, replyToId: draft.replyToId, isForward: false,
                    expectedProviderMessageId: draft.replyToProviderMessageId,
                    expectedUidValidity: nil, db: db)
            }
            #expect(quote?.bodyHTML != nil, "precondition: the parent resolves with a body to quote")
            let http = FakeHTTP.Scenario()
            defer { http.close() }
            let provider = exchangeProvider(http, copyResponse: .status(500))
            try await withRegisteredProvider(provider) {
                try await withPresentedDraft(draft.id, pool: pool) { window in
                    try await wait { textViews(window).contains { $0.text == "phone edit" } }
                    #expect(textViews(window).contains { $0.text == "phone edit" }, "precondition: the draft opened")
                    let adopted = ExternalDraftAdoption.isAdoptedKey(draft.id)
                    if adopted {
                        // Nothing marks the end of the open, so give the quote read the
                        // time it takes the TabMail reply below to show its quote.
                        try await Task.sleep(for: .seconds(3))
                    } else {
                        try await wait { !webViews(window).isEmpty }
                    }
                    #expect(webViews(window).isEmpty == adopted,
                            adopted ? "the other app's quote is already in the body; a second would be sent"
                                    : "a TabMail reply quotes its parent")
                }
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
          arguments: ["offline", "server error", "gone", "no body"])
    func unreadableCopyKeepsTheLocalCopy(failure: String) async throws {
        try await withInstalledPool { pool in
            let draft = try await pool.write { try insertDraft($0) }
            let http = FakeHTTP.Scenario()
            defer { http.close() }
            let response: FakeHTTP.CannedResponse = switch failure {
            case "offline": .transportError(.notConnectedToInternet)
            case "server error": .status(500)
            case "no body": .json(raw: """
                {"id":"g1","subject":"Plan","from":{"emailAddress":{"address":"owner@example.com"}},\
                "receivedDateTime":"\(ISO8601DateFormatter().string(from: Date()))","isRead":true,"isDraft":true,\
                "hasAttachments":false}
                """)
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
            /// Only a file attachment has bytes; another kind is listed and never read.
            var odataType = "#microsoft.graph.fileAttachment"
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
                guard one.odataType == "#microsoft.graph.fileAttachment" else {
                    return .json(raw: "{\"@odata.type\":\"\(one.odataType)\",\"id\":\"\(one.id)\"}")
                }
                return .json(raw: "{\"contentBytes\":\"\(one.bytes.base64EncodedString())\"}")
            }
            let items: [[String: Any]] = all.map { item in
                var json: [String: Any] = [
                    "id": item.id, "name": item.name, "contentType": item.contentType, "size": item.bytes.count,
                    "isInline": item.isInline, "@odata.type": item.odataType,
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

    // MARK: - 5. A draft holding an attachment TabMail cannot carry (#241)

    /// Every stored copy of a file named `name` under the attachment storage root,
    /// so a test can prove no staging directory was left behind.
    private nonisolated static func storedCopies(named name: String) -> [URL] {
        let enumerator = FileManager.default.enumerator(
            at: DraftAttachmentStorage.baseDir, includingPropertiesForKeys: nil)
        var found: [URL] = []
        while let url = enumerator?.nextObject() as? URL {
            if url.lastPathComponent.hasSuffix("_" + name) { found.append(url) }
        }
        return found
    }

    @Test("A server copy holding an attachment TabMail cannot carry refuses the open and changes nothing",
          arguments: ["#microsoft.graph.itemAttachment", "#microsoft.graph.referenceAttachment", "unsafe file name"])
    func uncarriableAttachmentRefusesTheOpen(kind: String) async throws {
        try await withInstalledPool { pool in
            let draft = try await pool.write { try insertDraft($0) }
            let model = ServerModel()
            model.body.withLock { $0 = "edited in Outlook" }
            model.attachments.withLock {
                $0 = [kind == "unsafe file name"
                    ? .init(id: "a2", name: "a/b.txt", contentType: "text/plain", isInline: false,
                            contentId: nil, bytes: Data("x".utf8))
                    : .init(id: "a2", name: "Fw: Report", contentType: "message/rfc822", isInline: false,
                            contentId: nil, bytes: Data(), odataType: kind)]
            }
            let http = FakeHTTP.Scenario()
            defer { http.close() }
            registerGraphServer(http, model: model)
            let provider = ExchangeProvider(
                userEmail: "owner@example.com", accessToken: { _ in "token" }, session: http.session)
            try await withRegisteredProvider(provider) {
                let check = await ExternalDraftAdoption.refreshBeforeOpen(draftId: draft.id, willReadServer: {})

                #expect(check == .unsupportedAttachment,
                        "editing the local copy would let its save overwrite the server's version")
                let row = try #require(try await pool.read { try Draft.fetchOne($0, key: draft.id) })
                #expect(row.body == "phone edit" && row.serverPushStatus == "pushed" && row.attachmentsDirName == nil)
                #expect(row.pushAttemptVersion == draft.pushAttemptVersion)
                #expect(!http.recordedCalls().contains { $0.url.contains("/attachments/a2") },
                        "an attachment the draft cannot carry is never downloaded")
                #expect(!http.recordedCalls().contains { $0.method != "GET" }, "opening never writes to the server")
            }
        }
    }

    @Test("A save deletes only files TabMail could have read; every other server attachment stays")
    func saveNeverDeletesAnAttachmentTabMailCannotCarry() async throws {
        try await withInstalledPool { pool in
            let keep = DraftAttachment(filename: "keep.txt", mimeType: "text/plain", data: Data("keep".utf8))
            let dir = DraftAttachmentStorage.newStagingDirName()
            try DraftAttachmentStorage.saveAttachments([keep], dirName: dir)
            defer { DraftAttachmentStorage.deleteAttachments(dirName: dir) }
            let draft = try await pool.write { db -> Draft in
                var row = try insertDraft(db, status: "dirty")
                row.attachmentsDirName = dir
                try row.update(db)
                return row
            }
            let model = ServerModel()
            model.attachments.withLock {
                $0 = [
                    .init(id: "f1", name: "keep.txt", contentType: "text/plain", isInline: false,
                          contentId: nil, bytes: keep.data),
                    .init(id: "f2", name: "removed.txt", contentType: "text/plain", isInline: false,
                          contentId: nil, bytes: Data("old".utf8)),
                    .init(id: "e1", name: "Fw: Report", contentType: "message/rfc822", isInline: false,
                          contentId: nil, bytes: Data(), odataType: "#microsoft.graph.itemAttachment"),
                    .init(id: "r1", name: "Plan.docx", contentType: "application/octet-stream", isInline: false,
                          contentId: nil, bytes: Data(), odataType: "#microsoft.graph.referenceAttachment"),
                    .init(id: "u1", name: "a/b.txt", contentType: "text/plain", isInline: false,
                          contentId: nil, bytes: Data("x".utf8)),
                ]
            }
            let http = FakeHTTP.Scenario()
            defer { http.close() }
            registerGraphServer(http, model: model)
            let provider = ExchangeProvider(
                userEmail: "owner@example.com", accessToken: { _ in "token" }, session: http.session)

            #expect(try await DraftStore.shared.pushDraftToServer(
                draftId: draft.id, expectedInstanceEpoch: "E1", provider: provider,
                runtimeKind: .outlook, draftsFolderPath: "Drafts") == .completed)

            #expect(model.attachments.withLock { $0.map(\.id) } == ["f1", "e1", "r1", "u1"],
                    "only the file the user removed is deleted; Graph cannot restore a deleted attachment")
        }
    }

    /// Another app's draft in a non-UTF-8 charset, its Content-Type as that app wrote it
    /// (Outlook quotes the value). Each is text no fallback decode reads correctly:
    /// ISO-2022-JP read as ASCII keeps its escape sequences, windows-1251 read as Latin
    /// is mojibake, so only the declared charset passes.
    nonisolated static let charsetDrafts: [(contentType: String, bytes: [UInt8], text: String)] = [
        ("text/plain; charset=\"ISO-2022-JP\"", Array("日本語の下書き".data(using: .iso2022JP)!), "日本語の下書き"),
        ("text/plain; Charset=\"windows-1251\"", [0xCF, 0xF0, 0xE8, 0xE2, 0xE5, 0xF2], "Привет"),
        ("text/plain; charset=iso-8859-1", [0x43, 0x61, 0x66, 0xE9, 0x20, 0x61, 0x74, 0x20, 0x35], "Caf\u{E9} at 5"),
    ]

    @Test("A Gmail draft written in another charset reloads as its text, in that charset",
          arguments: 0..<charsetDrafts.count)
    func gmailDraftInAnotherCharsetReloadsAsItsText(index: Int) async throws {
        let (contentType, bytes, text) = Self.charsetDrafts[index]
        try await withInstalledPool { pool in
            let draft = try await pool.write { try insertDraft($0, provider: .gmail) }
            let date = String(Int(Date().timeIntervalSince1970 * 1000))
            let http = FakeHTTP.Scenario()
            defer { http.close() }
            http.register(path: "/drafts/r1", method: "GET", response: .json(raw: #"{"id":"r1","message":{"id":"m3"}}"#))
            http.register(path: "/messages/m3", method: "GET", response: .json(raw: """
                {"id":"m3","internalDate":"\(date)","labelIds":["DRAFT"],"payload":{"mimeType":"text/plain",\
                "headers":[{"name":"Subject","value":"Plan"},{"name":"From","value":"owner@example.com"},\
                {"name":"To","value":"alice@example.com"},\
                {"name":"Content-Type","value":"\(contentType.replacingOccurrences(of: "\"", with: "\\\""))"}],\
                "body":{"size":\(bytes.count),"data":"\(Self.base64URL(Data(bytes)))"}}}
                """))
            let provider = GmailProvider(
                userEmail: "owner@example.com", accessToken: { _ in "token" }, session: http.session)
            try await withRegisteredProvider(provider) {
                await ExternalDraftAdoption.refreshBeforeOpen(draftId: draft.id, willReadServer: {})

                let row = try #require(try await pool.read { try Draft.fetchOne($0, key: draft.id) })
                #expect(row.pushAttemptVersion > draft.pushAttemptVersion, "precondition: the open reloaded")
                #expect(row.body == text, "a draft decoded in the wrong charset is uploaded garbled by the next save")
            }
        }
    }

    @Test("A server read that outlasts the open budget opens the local copy, and its late answer writes nothing")
    func slowServerReadOpensTheLocalCopy() async throws {
        try await withInstalledPool { pool in
            let draft = try await pool.write { try insertDraft($0) }
            let gate = DispatchSemaphore(value: 0)
            let http = FakeHTTP.Scenario()
            defer { http.close() }
            let provider = exchangeProvider(http, copyResponse: .parked {
                _ = gate.wait(timeout: .now() + 30)
                return .json(raw: Self.copyJSON(body: "late server body"))
            })
            try await withRegisteredProvider(provider) {
                let started = Date()
                let check = await ExternalDraftAdoption.refreshBeforeOpen(draftId: draft.id, willReadServer: {})
                let waited = Date().timeIntervalSince(started)
                for _ in 0..<4 { gate.signal() }

                #expect(check == .open)
                #expect(waited >= ExternalDraftOpenConfig.reloadTimeoutSeconds - 0.5,
                        "precondition: the open waited for the read until its budget ran out")
                #expect(waited < ExternalDraftOpenConfig.reloadTimeoutSeconds + 5, "the open never waits past its budget")
                try await Task.sleep(for: .milliseconds(500))
                let row = try #require(try await pool.read { try Draft.fetchOne($0, key: draft.id) })
                #expect(row.body == "phone edit" && row.pushAttemptVersion == draft.pushAttemptVersion,
                        "a read that answered after the open must not change the draft")
            }
        }
    }

    @Test("A reload that loses to a newer save keeps that save and leaves no staged copy of the server's files")
    func reloadLosingToANewerSaveLeavesNothingStaged() async throws {
        try await withInstalledPool { pool in
            let draft = try await pool.write { try insertDraft($0) }
            let name = "staged-\(UUID().uuidString).txt"
            let model = ServerModel()
            model.attachments.withLock {
                $0 = [.init(id: "a1", name: name, contentType: "text/plain", isInline: false,
                            contentId: nil, bytes: Data("server file".utf8))]
            }
            let http = FakeHTTP.Scenario()
            defer { http.close() }
            registerGraphServer(http, model: model)
            // While the server copy is read, another save advances the row.
            http.register(path: "/messages/g1/attachments/a1", method: "GET") { _ in
                try? pool.write { db in
                    guard var row = try Draft.fetchOne(db, key: draft.id) else { return }
                    row.body = "newer save"
                    row.pushAttemptVersion += 1
                    try row.update(db)
                }
                return .json(raw: "{\"contentBytes\":\"\(Data("server file".utf8).base64EncodedString())\"}")
            }
            let provider = ExchangeProvider(
                userEmail: "owner@example.com", accessToken: { _ in "token" }, session: http.session)
            try await withRegisteredProvider(provider) {
                await ExternalDraftAdoption.refreshBeforeOpen(draftId: draft.id, willReadServer: {})

                let row = try #require(try await pool.read { try Draft.fetchOne($0, key: draft.id) })
                #expect(row.body == "newer save" && row.attachmentsDirName == nil)
                #expect(Self.storedCopies(named: name).isEmpty, "the losing reload left its staged files on disk")
            }
        }
    }

    @Test("Adopting a copy another row already owns inserts nothing and leaves no staged files")
    func adoptionIntoAnOwnedAddressLeavesNothingStaged() async throws {
        try await withInstalledPool { pool in
            let name = "adopt-\(UUID().uuidString).txt"
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
                attachmentNames: [name], attachmentData: ["mock-att-0": Data("notes".utf8)])))
            try await withRegisteredProvider(provider) {
                let address = try #require(try await pool.read { db in
                    try ExternalDraftAdoption.adoptableAddress(db: db, header: header, runtimeKind: .imap)
                })
                // Another open adopted the same copy while this one read it.
                try await pool.write { db in
                    var owner = Draft(
                        id: "adopted:first", accountId: Self.accountId,
                        toJSON: "[]", ccJSON: "[]", bccJSON: "[]", subject: "Plan", body: "first",
                        replyToId: nil, isForward: false, editHistoryJSON: nil, createdAt: 1, updatedAt: 2,
                        serverDraftId: "7", serverPushStatus: "pushed", rfc822MessageId: nil, attachmentsDirName: nil)
                    owner.serverDraftFolderPath = "Drafts"
                    owner.serverDraftUidValidity = 900_001
                    owner.instanceEpoch = "E1"
                    try owner.insert(db)
                }
                try await ExternalDraftAdoption.adopt(header: header, address: address, runtimeKind: .imap)

                #expect(try await pool.read { try Draft.fetchCount($0) } == 1, "a second row was adopted for one copy")
                #expect(Self.storedCopies(named: name).isEmpty, "the refused adoption left its staged files on disk")
            }
        }
    }

    // MARK: - 6. The Drafts-list loader's production sequence

    /// An Outlook account with a Drafts header at Graph id `g1`, optionally owned by
    /// a saved row, or in the Inbox when `inDrafts` is false.
    private nonisolated func insertOutlookHeader(
        _ db: Database, owned: Bool = false, inDrafts: Bool = true
    ) throws -> MessageHeader {
        var account = Account(emailAddress: "owner@example.com", displayName: "Test", provider: .outlook)
        account.id = Self.accountId
        try account.insert(db)
        let folder = Folder(
            name: inDrafts ? "Drafts" : "Inbox", path: inDrafts ? "Drafts" : "Inbox",
            role: inDrafts ? .drafts : .inbox, accountId: Self.accountId)
        try folder.insert(db)
        let header = MessageHeader(
            messageId: "g1", subject: "Plan", from: "owner@example.com", fromAddress: "owner@example.com",
            to: "alice@example.com", date: Date(), snippet: "", folderId: folder.id,
            accountId: Self.accountId, folderPath: folder.path, isInInbox: !inDrafts)
        try header.insert(db)
        if owned {
            var draft = Draft(
                id: "owned-draft", accountId: Self.accountId,
                toJSON: "[]", ccJSON: "[]", bccJSON: "[]", subject: "Plan", body: "phone edit",
                replyToId: nil, isForward: false, editHistoryJSON: nil, createdAt: 1, updatedAt: 2,
                serverDraftId: "g1", serverPushStatus: "pushed", rfc822MessageId: nil, attachmentsDirName: nil)
            draft.instanceEpoch = "E1"
            try draft.insert(db)
        }
        return header
    }

    /// What `ServerDraftComposeLoader` shows for `header`: its production sequence,
    /// classified as the view classifies it.
    private func loaderResolution(_ header: MessageHeader) async -> ServerDraftComposeLoader.Resolution {
        let outcome: Result<LocallyAuthoredDraftOpenAuthority?, any Error>
        do {
            outcome = .success(try await ServerDraftComposeLoader.resolveOpenAuthority(header: header))
        } catch {
            outcome = .failure(error)
        }
        return ServerDraftComposeLoader.classify(outcome)
    }

    @Test("The loader opens a draft this device owns without reading the server")
    func loaderOpensTheOwnedDraft() async throws {
        try await withInstalledPool { pool in
            let header = try await pool.write { try insertOutlookHeader($0, owned: true) }
            let http = FakeHTTP.Scenario()
            defer { http.close() }
            let provider = exchangeProvider(http, copyResponse: .json(raw: Self.copyJSON(body: "server body")))
            try await withRegisteredProvider(provider) {
                let resolution = await loaderResolution(header)

                guard case .authorized(let authority) = resolution else {
                    Issue.record("expected the owned draft, got \(resolution)")
                    return
                }
                #expect(authority.draftId == "owned-draft")
                #expect(http.recordedCalls().isEmpty, "an owned draft is not adopted again")
            }
        }
    }

    @Test("The loader adopts another app's draft, then opens the adopted row")
    func loaderAdoptsThenOpens() async throws {
        try await withInstalledPool { pool in
            let header = try await pool.write { try insertOutlookHeader($0) }
            let http = FakeHTTP.Scenario()
            defer { http.close() }
            let provider = exchangeProvider(http, copyResponse: .json(raw: Self.copyJSON(body: "written elsewhere")))
            try await withRegisteredProvider(provider) {
                let resolution = await loaderResolution(header)

                guard case .authorized(let authority) = resolution else {
                    Issue.record("expected the adopted draft, got \(resolution)")
                    return
                }
                let row = try #require(try await pool.read { try Draft.fetchOne($0, key: authority.draftId) })
                #expect(ExternalDraftAdoption.isAdoptedKey(row.id) && row.serverDraftId == "g1")
                #expect(row.body == "written elsewhere")
            }
        }
    }

    @Test("The loader refuses, for good, a draft holding an attachment TabMail cannot carry")
    func loaderRefusesAnUncarriableDraft() async throws {
        try await withInstalledPool { pool in
            let header = try await pool.write { try insertOutlookHeader($0) }
            let model = ServerModel()
            model.attachments.withLock {
                $0 = [.init(id: "e1", name: "Fw: Report", contentType: "message/rfc822", isInline: false,
                            contentId: nil, bytes: Data(), odataType: "#microsoft.graph.itemAttachment")]
            }
            let http = FakeHTTP.Scenario()
            defer { http.close() }
            registerGraphServer(http, model: model)
            let provider = ExchangeProvider(
                userEmail: "owner@example.com", accessToken: { _ in "token" }, session: http.session)
            try await withRegisteredProvider(provider) {
                #expect(await loaderResolution(header) == .unsupportedAttachment,
                        "a refusal that can never succeed must not offer Try Again")
                let drafts = try await pool.read { try Draft.fetchCount($0) }
                #expect(drafts == 0)
            }
        }
    }

    /// A Gmail account with a Drafts header for contained message `m-5`, owned by
    /// `owners` saved rows naming draft resource `r1`.
    private nonisolated func insertGmailHeader(_ db: Database, owners: Int) throws -> MessageHeader {
        var account = Account(emailAddress: "owner@example.com", displayName: "Test", provider: .gmail)
        account.id = Self.accountId
        try account.insert(db)
        let folder = Folder(name: "Drafts", path: "[Gmail]/Drafts", role: .drafts, accountId: Self.accountId)
        try folder.insert(db)
        let header = MessageHeader(
            messageId: "m-5", subject: "Plan", from: "owner@example.com", fromAddress: "owner@example.com",
            to: "alice@example.com", date: Date(), snippet: "", folderId: folder.id,
            accountId: Self.accountId, folderPath: folder.path, isInInbox: false)
        try header.insert(db)
        for index in 0..<owners {
            var draft = Draft(
                id: "owned-draft-\(index)", accountId: Self.accountId,
                toJSON: "[]", ccJSON: "[]", bccJSON: "[]", subject: "Plan", body: "phone edit",
                replyToId: nil, isForward: false, editHistoryJSON: nil, createdAt: 1, updatedAt: 2,
                serverDraftId: "r1", serverPushStatus: index == 0 ? "pushed" : "dirty",
                rfc822MessageId: nil, attachmentsDirName: nil)
            draft.instanceEpoch = "E\(index)"
            try draft.insert(db)
        }
        return header
    }

    /// A Gmail server whose draft resource `r1` wraps message `m-5`, holding `body`
    /// and `files` (part JSON). `onList` runs when the loader looks the resource up.
    private func gmailProvider(
        _ http: FakeHTTP.Scenario, body: String, files: String = "",
        onList: @escaping @Sendable () -> Void = {}
    ) -> GmailProvider {
        http.register(path: "/drafts", method: "GET") { _ in
            onList()
            return .json(raw: #"{"drafts":[{"id":"r1","message":{"id":"m-5"}}]}"#)
        }
        http.register(path: "/drafts/r1", method: "GET", response: .json(raw: #"{"message":{"id":"m-5"}}"#))
        let internalDate = String(Int(Date().timeIntervalSince1970 * 1000))
        let data = Data(body.utf8).base64EncodedString()
            .replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
        http.register(path: "/messages/m-5", method: "GET", response: .json(raw: """
            {"id":"m-5","internalDate":"\(internalDate)","labelIds":["DRAFT"],
             "payload":{"mimeType":"multipart/mixed","headers":[{"name":"Subject","value":"Plan"}],
               "parts":[{"mimeType":"text/plain","body":{"size":\(body.utf8.count),"data":"\(data)"}}\(files)]}}
            """))
        return GmailProvider(userEmail: "owner@example.com", accessToken: { _ in "token" }, session: http.session)
    }

    @Test("Gmail: the loader opens the one row that owns the draft resource, without reading the draft")
    func gmailLoaderOpensTheOwnedDraft() async throws {
        try await withInstalledPool { pool in
            let header = try await pool.write { try insertGmailHeader($0, owners: 1) }
            let http = FakeHTTP.Scenario()
            defer { http.close() }
            try await withRegisteredProvider(gmailProvider(http, body: "server body")) {
                let resolution = await loaderResolution(header)

                guard case .authorized(let authority) = resolution else {
                    Issue.record("expected the owned draft, got \(resolution)")
                    return
                }
                #expect(authority.draftId == "owned-draft-0")
                #expect(authority.address == .gmail(resourceId: "r1", containedMessageId: "m-5"))
                #expect(!http.recordedCalls().contains { $0.url.contains("/messages/") }, "an owned draft is not adopted again")
            }
        }
    }

    @Test("Gmail: the loader adopts another app's draft, then opens the adopted row")
    func gmailLoaderAdoptsThenOpens() async throws {
        try await withInstalledPool { pool in
            let header = try await pool.write { try insertGmailHeader($0, owners: 0) }
            let http = FakeHTTP.Scenario()
            defer { http.close() }
            try await withRegisteredProvider(gmailProvider(http, body: "written elsewhere")) {
                let resolution = await loaderResolution(header)

                guard case .authorized(let authority) = resolution else {
                    Issue.record("expected the adopted draft, got \(resolution)")
                    return
                }
                let row = try #require(try await pool.read { try Draft.fetchOne($0, key: authority.draftId) })
                #expect(ExternalDraftAdoption.isAdoptedKey(row.id) && row.serverDraftId == "r1")
                #expect(row.body == "written elsewhere")
            }
        }
    }

    @Test("Gmail: adoption keeps a file whose bytes came in the draft and fetches the others")
    func gmailAdoptionCarriesInlineBytesAndFetchesTheRest() async throws {
        try await withInstalledPool { pool in
            let header = try await pool.write { try insertGmailHeader($0, owners: 0) }
            let http = FakeHTTP.Scenario()
            defer { http.close() }
            let invite = Data("BEGIN:VCALENDAR".utf8).base64EncodedString()
            let provider = gmailProvider(http, body: "Agenda attached", files: """
                ,{"mimeType":"text/calendar","body":{"size":15,"data":"\(invite)"}}
                ,{"mimeType":"application/pdf","filename":"plan.pdf","body":{"size":3,"attachmentId":"att1"}}
                """)
            http.register(path: "/messages/m-5/attachments/att1", method: "GET",
                          response: .json(raw: "{\"size\":3,\"data\":\"\(Data([1, 2, 3]).base64EncodedString())\"}"))
            try await withRegisteredProvider(provider) {
                let resolution = await loaderResolution(header)

                guard case .authorized(let authority) = resolution else {
                    Issue.record("expected the adopted draft, got \(resolution)")
                    return
                }
                let row = try #require(try await pool.read { try Draft.fetchOne($0, key: authority.draftId) })
                let files = try DraftAttachmentStorage.loadAttachments(dirName: row.attachmentsDirName)
                #expect(files.map(\.filename) == [DraftReadConfig.unnamedAttachmentFilename, "plan.pdf"])
                #expect(files.map(\.data) == [Data("BEGIN:VCALENDAR".utf8), Data([1, 2, 3])])
                if let dir = row.attachmentsDirName { DraftAttachmentStorage.deleteAttachments(dirName: dir) }
            }
        }
    }

    @Test("Gmail: the loader opens nothing when two rows claim the draft resource")
    func gmailLoaderRefusesTwoOwners() async throws {
        try await withInstalledPool { pool in
            let header = try await pool.write { try insertGmailHeader($0, owners: 2) }
            let http = FakeHTTP.Scenario()
            defer { http.close() }
            try await withRegisteredProvider(gmailProvider(http, body: "server body")) {
                #expect(await loaderResolution(header) == .noLocalCopy)
                let drafts = try await pool.read { try Draft.fetchCount($0) }
                #expect(drafts == 2, "a third row was adopted for one resource")
            }
        }
    }

    @Test("Gmail: the loader opens nothing when the header changed while the resource was looked up")
    func gmailLoaderRefusesAHeaderThatChanged() async throws {
        try await withInstalledPool { pool in
            let header = try await pool.write { try insertGmailHeader($0, owners: 1) }
            let http = FakeHTTP.Scenario()
            defer { http.close() }
            let provider = gmailProvider(http, body: "server body") {
                // Another save replaced the draft's message while the lookup ran.
                try? pool.write { db in
                    try db.execute(sql: "UPDATE messageHeader SET messageId = 'm-6' WHERE id = ?", arguments: [header.id])
                }
            }
            try await withRegisteredProvider(provider) {
                #expect(await loaderResolution(header) == .noLocalCopy)
                let drafts = try await pool.read { try Draft.fetchCount($0) }
                #expect(drafts == 1)
            }
        }
    }

    @Test("The loader shows a read that failed as retryable, never as an absent draft")
    func loaderFailedReadIsRetryable() async throws {
        try await withInstalledPool { pool in
            let header = try await pool.write { try insertOutlookHeader($0) }
            let http = FakeHTTP.Scenario()
            defer { http.close() }
            let provider = exchangeProvider(http, copyResponse: .status(500))
            try await withRegisteredProvider(provider) {
                #expect(await loaderResolution(header) == .resolveFailed)
                let drafts = try await pool.read { try Draft.fetchCount($0) }
                #expect(drafts == 0)
            }
        }
    }

    @Test("The loader finds no editable copy for a header outside a Drafts folder")
    func loaderHasNoCopyOutsideDrafts() async throws {
        try await withInstalledPool { pool in
            let header = try await pool.write { try insertOutlookHeader($0, inDrafts: false) }
            let http = FakeHTTP.Scenario()
            defer { http.close() }
            let provider = exchangeProvider(http, copyResponse: .json(raw: Self.copyJSON(body: "server body")))
            try await withRegisteredProvider(provider) {
                #expect(await loaderResolution(header) == .noLocalCopy)
                let drafts = try await pool.read { try Draft.fetchCount($0) }
                #expect(http.recordedCalls().isEmpty && drafts == 0)
            }
        }
    }
}
