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

/// #217 (ADR-IOS-091) regressions found in review, end to end against the real
/// providers on canned HTTP. THE INVARIANTS:
/// 1. A server copy another app changed — in ANY field it can edit, Bcc and
///    attachments included — is never replaced without the user choosing to.
/// 2. Every open of a saved draft, from any screen, shows the server's version of
///    a draft with no unsent edits, with every field from that one version.
/// 3. An older action never undoes a newer user choice.
/// 4. Taking over another app's draft keeps its inline images.
@Suite("Draft server change regressions (#217)", .serialized, .processGlobalState)
@MainActor
struct DraftServerChangeRegressionTests {
    private func withInstalledPool(_ body: (DatabasePool) async throws -> Void) async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("draft-server-regression-\(UUID().uuidString)")
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

    private nonisolated static let accountId = "acc-217-regression"

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

    /// The copy the row last saw: "Plan" to alice, body "now here".
    private nonisolated static func copy(
        body: String = "now here", bcc: String = "", attachment: Bool = false
    ) -> FullMessageInfo {
        let header = MessageHeaderInfo(
            messageId: "g1", rfc822MessageId: nil, inReplyTo: nil, references: [], threadId: nil,
            subject: "Plan", from: "", fromAddress: "", to: "alice@example.com", cc: "", bcc: bcc,
            replyTo: nil, date: Date(), snippet: "", isRead: true, isFlagged: false,
            hasAttachments: attachment, isReplied: false, isForwarded: false, actionTag: nil)
        return FullMessageInfo(
            header: header, htmlBody: "<p>\(body)</p>", textBody: nil,
            attachments: attachment
                ? [AttachmentInfo(filename: "new.txt", contentType: "text/plain", section: "new-att", size: 3, encoding: nil)]
                : [])
    }

    /// A row with unsent edits ("phone edit") whose copy of the server text is `copy()`.
    private nonisolated func insertDraft(
        _ db: Database, provider: AccountProvider = .outlook, status: String = "dirty"
    ) throws -> Draft {
        var account = Account(emailAddress: "owner@example.com", displayName: "Test", provider: provider)
        account.id = Self.accountId
        try account.insert(db)
        var draft = Draft(
            id: "adopted:regression", accountId: account.id,
            toJSON: Draft.encodeStringArray(["alice@example.com"]), ccJSON: "[]", bccJSON: "[]",
            subject: "Plan", body: "phone edit", replyToId: nil, isForward: false,
            editHistoryJSON: nil, createdAt: 1, updatedAt: 2,
            serverDraftId: provider == .gmail ? "r1" : "g1", serverPushStatus: status,
            rfc822MessageId: nil, attachmentsDirName: nil)
        draft.instanceEpoch = "E1"
        draft.serverDraftText = DraftServerText.of(Self.copy())
        try draft.insert(db)
        return draft
    }

    private nonisolated static func base64URL(_ data: Data) -> String {
        data.base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }

    private nonisolated static func gmailMessage(_ body: String, id: String, bcc: String? = nil) -> String {
        let date = String(Int(Date().timeIntervalSince1970 * 1000))
        let bccHeader = bcc.map { #",{"name":"Bcc","value":"\#($0)"}"# } ?? ""
        return """
            {"id":"\(id)","internalDate":"\(date)","labelIds":["DRAFT"],"payload":{"mimeType":"text/plain",\
            "headers":[{"name":"Subject","value":"Plan"},{"name":"From","value":"owner@example.com"},\
            {"name":"To","value":"alice@example.com"}\(bccHeader)],\
            "body":{"size":\(body.utf8.count),"data":"\(base64URL(Data(body.utf8)))"}}}
            """
    }

    // MARK: - 1. Every field another app can edit is guarded

    @Test("Upload refuses a server copy whose Bcc, attachments or word spacing changed",
          arguments: ["bcc", "attachment", "spacing"])
    func uploadRefusesRemoteChanges(kind: String) async throws {
        try await withInstalledPool { pool in
            let draft = try await pool.write { try insertDraft($0) }
            let provider = MockEmailProvider(saveDraftResult: .created(.outlook(graphId: "g1")))
            await provider.setDraftCopy(.success(Self.copy(
                body: kind == "spacing" ? "nowhere" : "now here",
                bcc: kind == "bcc" ? "new@example.com" : "", attachment: kind == "attachment")))

            let disposition = try await DraftStore.shared.pushDraftToServer(
                draftId: draft.id, expectedInstanceEpoch: "E1", provider: provider,
                runtimeKind: .outlook, draftsFolderPath: "Drafts")

            #expect(disposition == .serverChanged)
            #expect(await provider.fetchDraftCopyLog.count == 1, "precondition: the server check ran")
            #expect(await provider.callLog.contains { $0.hasPrefix("saveDraft") } == false)
            let row = try #require(try await pool.read { try Draft.fetchOne($0, key: draft.id) })
            #expect(row.body == "phone edit")
            #expect(row.serverPushStatus == "dirty")
        }
    }

    @Test("Gmail: an update never replaces a draft another app added a Bcc to")
    func gmailUpdateKeepsRemoteBcc() async throws {
        try await withInstalledPool { pool in
            let draft = try await pool.write { try insertDraft($0, provider: .gmail) }
            let http = FakeHTTP.Scenario()
            defer { http.close() }
            http.register(path: "/drafts/r1", method: "GET", response: .json(raw: #"{"message":{"id":"m2"}}"#))
            http.register(path: "/messages/m2", method: "GET",
                          response: .json(raw: Self.gmailMessage("now here", id: "m2", bcc: "new@example.com")))
            http.register(path: "/drafts/r1", method: "PUT", response: .json(raw: #"{"id":"r1","message":{"id":"m3"}}"#))
            let provider = GmailProvider(
                userEmail: "owner@example.com", accessToken: { _ in "token" }, session: http.session)

            let result = try await DraftStore.shared.pushDraftToServer(
                draftId: draft.id, expectedInstanceEpoch: "E1", provider: provider,
                runtimeKind: .gmail, draftsFolderPath: "Drafts")

            #expect(result == .serverChanged)
            #expect(http.recordedCalls().contains { $0.method == "GET" && $0.url.contains("/messages/m2") })
            #expect(!http.recordedCalls().contains { $0.method == "PUT" },
                    "Gmail's replacement deletes the old copy; it must not run without the user's choice")
        }
    }

    // MARK: - 2. Every open follows the server, with every field from one version

    @Test("Opening a draft with no unsent edits takes subject, To, Bcc and body from the fetched copy")
    func openReloadsEveryFieldFromTheFetchedCopy() async throws {
        try await withInstalledPool { pool in
            let draft = try await pool.write { try insertDraft($0, status: "pushed") }
            let http = FakeHTTP.Scenario()
            defer { http.close() }
            let date = ISO8601DateFormatter().string(from: Date())
            http.register(path: "/messages/g1", method: "GET", response: .json(raw: """
                {"id":"g1","subject":"fresh subject","from":{"emailAddress":{"address":"owner@example.com"}},\
                "toRecipients":[{"emailAddress":{"address":"fresh@example.com"}}],\
                "bccRecipients":[{"emailAddress":{"address":"new-bcc@example.com"}}],\
                "receivedDateTime":"\(date)","isRead":true,"isDraft":true,"hasAttachments":false,\
                "body":{"contentType":"html","content":"<p>fresh body</p>"}}
                """))
            http.register(path: "/messages/g1/attachments", method: "GET", response: .json(raw: #"{"value":[]}"#))
            let provider = ExchangeProvider(
                userEmail: "owner@example.com", accessToken: { _ in "token" }, session: http.session)
            try await withRegisteredProvider(provider) {
                var asked = false

                await ExternalDraftAdoption.refreshBeforeOpen(
                    draftId: draft.id, willReadServer: {},
                    askAboutUnsentEdits: { asked = true; return nil })

                #expect(!asked, "a row with no unsent edits takes the server version without asking")
                let row = try #require(try await pool.read { try Draft.fetchOne($0, key: draft.id) })
                #expect(row.body == "fresh body")
                #expect(row.subject == "fresh subject")
                #expect(RecipientEntry(row.toArray).addresses == ["fresh@example.com"])
                #expect(RecipientEntry(row.bccArray).addresses == ["new-bcc@example.com"])
                #expect(row.serverPushStatus == "pushed")
                #expect(row.pushAttemptVersion > draft.pushAttemptVersion)
            }
        }
    }

    /// A real Exchange provider, so the open check resolves the row's identity and
    /// reaches the wire; `copyResponse` answers the draft read.
    private func exchangeProvider(
        _ http: FakeHTTP.Scenario, copyResponse: FakeHTTP.CannedResponse
    ) -> ExchangeProvider {
        http.register(path: "/messages/g1", method: "GET", response: copyResponse)
        http.register(path: "/messages/g1/attachments", method: "GET", response: .json(raw: #"{"value":[]}"#))
        return ExchangeProvider(
            userEmail: "owner@example.com", accessToken: { _ in "token" }, session: http.session)
    }

    /// The draft as the Graph API returns it; `copyJSON(body: "now here")` is the
    /// same draft as `copy()`, the text the test row last saw.
    private static func copyJSON(body: String) -> FakeHTTP.CannedResponse {
        .json(raw: """
            {"id":"g1","subject":"Plan","from":{"emailAddress":{"address":"owner@example.com"}},\
            "toRecipients":[{"emailAddress":{"address":"alice@example.com"}}],\
            "receivedDateTime":"\(ISO8601DateFormatter().string(from: Date()))","isRead":true,"isDraft":true,\
            "hasAttachments":false,"body":{"contentType":"html","content":"<p>\(body)</p>"}}
            """)
    }

    @Test("Opening a draft with unsent edits and an unchanged server copy opens the edits without asking")
    func openKeepsUnsentEditsWhenTheServerIsUnchanged() async throws {
        try await withInstalledPool { pool in
            let draft = try await pool.write { try insertDraft($0, status: "dirty") }
            let http = FakeHTTP.Scenario()
            defer { http.close() }
            let provider = exchangeProvider(http, copyResponse: Self.copyJSON(body: "now here"))
            try await withRegisteredProvider(provider) {
                var asked = false

                await ExternalDraftAdoption.refreshBeforeOpen(
                    draftId: draft.id, willReadServer: {},
                    askAboutUnsentEdits: { asked = true; return nil })

                #expect(http.recordedCalls().contains { $0.method == "GET" && $0.url.contains("/messages/g1") },
                        "the server copy must actually be read")
                #expect(!asked, "only a server-side change asks")
                let row = try #require(try await pool.read { try Draft.fetchOne($0, key: draft.id) })
                #expect(row.body == "phone edit" && row.serverPushStatus == "dirty")
                #expect(row.pushAttemptVersion == draft.pushAttemptVersion)
            }
        }
    }

    enum OpenAnswer: String, CaseIterable, Sendable {
        case overwrite, reload, saveAsNew, cancel

        var choice: ExternalDraftAdoption.ServerChangeChoice? {
            switch self {
            case .overwrite: .overwrite
            case .reload: .reload
            case .saveAsNew: .saveAsNew
            case .cancel: nil
            }
        }
    }

    @Test("Opening a draft with unsent edits that changed on the server asks first, then applies the answer",
          arguments: OpenAnswer.allCases)
    func openAsksAboutUnsentEditsWhenTheServerChanged(answer: OpenAnswer) async throws {
        try await withInstalledPool { pool in
            let draft = try await pool.write { try insertDraft($0, status: "dirty") }
            let http = FakeHTTP.Scenario()
            defer { http.close() }
            let provider = exchangeProvider(http, copyResponse: Self.copyJSON(body: "rewritten elsewhere"))
            try await withRegisteredProvider(provider) {
                var askCount = 0
                var rowWhenAsked: Draft?

                await ExternalDraftAdoption.refreshBeforeOpen(
                    draftId: draft.id, willReadServer: {},
                    askAboutUnsentEdits: {
                        askCount += 1
                        rowWhenAsked = try? await pool.read { try Draft.fetchOne($0, key: draft.id) }
                        return answer.choice
                    })

                #expect(askCount == 1)
                #expect(rowWhenAsked?.body == "phone edit", "nothing is written before the user answers")
                let row = try #require(try await pool.read { try Draft.fetchOne($0, key: draft.id) })
                switch answer {
                case .overwrite:
                    #expect(row.body == "phone edit" && row.serverDraftId == "g1")
                    #expect(row.serverDraftText == DraftServerText.of(Self.copy(body: "rewritten elsewhere")),
                            "the next upload must see the server copy as known, and replace it")
                    #expect(row.pushAttemptVersion > draft.pushAttemptVersion)
                case .reload:
                    #expect(row.body == "rewritten elsewhere" && row.serverPushStatus == "pushed")
                    #expect(row.pushAttemptVersion > draft.pushAttemptVersion,
                            "a queued upload of the dropped edits must retire")
                case .saveAsNew:
                    #expect(row.body == "phone edit")
                    #expect(row.serverDraftId == nil && row.serverPushStatus == nil,
                            "the edits become a new server draft; the other version stays")
                    #expect(row.pushAttemptVersion > draft.pushAttemptVersion)
                case .cancel:
                    #expect(row.body == "phone edit" && row.serverDraftId == "g1"
                            && row.serverDraftText == draft.serverDraftText
                            && row.serverPushStatus == "dirty"
                            && row.pushAttemptVersion == draft.pushAttemptVersion,
                            "Cancel opens the edits with nothing written; Save asks again")
                }
                #expect(!http.recordedCalls().contains { $0.method != "GET" },
                        "opening never writes to the server")
            }
        }
    }

    @Test("Opening offline keeps the local copy untouched")
    func openOfflineKeepsTheLocalCopy() async throws {
        try await withInstalledPool { pool in
            // Saved offline: unsent edits, reopened while still offline.
            let draft = try await pool.write { try insertDraft($0, status: "dirty") }
            let http = FakeHTTP.Scenario()
            defer { http.close() }
            let provider = exchangeProvider(http, copyResponse: .transportError(.notConnectedToInternet))
            try await withRegisteredProvider(provider) {
                var coverShown = false
                var asked = false

                await ExternalDraftAdoption.refreshBeforeOpen(
                    draftId: draft.id, willReadServer: { coverShown = true },
                    askAboutUnsentEdits: { asked = true; return .reload })

                #expect(coverShown)
                #expect(!asked, "an unread server copy is never a reason to ask")
                #expect(http.recordedCalls().contains { $0.method == "GET" && $0.url.contains("/messages/g1") })
                let row = try #require(try await pool.read { try Draft.fetchOne($0, key: draft.id) })
                #expect(row.body == "phone edit" && row.subject == "Plan" && row.serverPushStatus == "dirty")
                #expect(row.pushAttemptVersion == draft.pushAttemptVersion)
            }
        }
    }

    private func textViews(_ view: UIView) -> [UITextView] {
        (view as? UITextView).map { [$0] } ?? view.subviews.flatMap { textViews($0) }
    }

    @Test("Resuming a saved draft from a direct presenter shows the server's newer version")
    func directPresenterShowsTheServerVersion() async throws {
        try await withInstalledPool { pool in
            let draft = try await pool.write { try insertDraft($0, status: "pushed") }
            let account = try #require(try await pool.read { try Account.fetchOne($0, key: draft.accountId) })
            let http = FakeHTTP.Scenario()
            defer { http.close() }
            let date = ISO8601DateFormatter().string(from: Date())
            http.register(path: "/messages/g1", method: "GET", response: .json(raw: """
                {"id":"g1","subject":"Plan","from":{"emailAddress":{"address":"owner@example.com"}},\
                "toRecipients":[{"emailAddress":{"address":"alice@example.com"}}],\
                "receivedDateTime":"\(date)","isRead":true,"isDraft":true,"hasAttachments":false,\
                "body":{"contentType":"html","content":"<p>fresh remote body</p>"}}
                """))
            http.register(path: "/messages/g1/attachments", method: "GET", response: .json(raw: #"{"value":[]}"#))
            let provider = ExchangeProvider(
                userEmail: "owner@example.com", accessToken: { _ in "token" }, session: http.session)
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
                #expect(http.recordedCalls().contains { $0.method == "GET" })
            }
        }
    }

    // MARK: - 3. An older action never undoes a newer choice

    @Test("Save as new retires an upload that was already reading the server copy")
    func saveAsNewRetiresASuspendedUpload() async throws {
        try await withInstalledPool { pool in
            let draft = try await pool.write { try insertDraft($0, provider: .gmail) }
            let http = FakeHTTP.Scenario()
            defer { http.close() }
            let wrappedMessageId = Mutex("m1")
            let receivedOldRead = Mutex(false)
            let releaseOldRead = DispatchSemaphore(value: 0)
            defer { releaseOldRead.signal() }
            http.register(path: "/drafts/r1", method: "GET", handler: { _ in
                .json(raw: "{\"message\":{\"id\":\"\(wrappedMessageId.withLock { $0 })\"}}")
            })
            let original = Self.gmailMessage("now here", id: "m1")
            http.register(path: "/messages/m1", method: "GET", handler: { _ in
                .parked {
                    receivedOldRead.withLock { $0 = true }
                    _ = releaseOldRead.wait(timeout: .now() + 30)
                    return .json(raw: original)
                }
            })
            http.register(path: "/messages/m2", method: "GET",
                          response: .json(raw: Self.gmailMessage("newer remote work", id: "m2")))
            http.register(path: "/drafts/r1", method: "PUT", response: .json(raw: #"{"id":"r1","message":{"id":"m3"}}"#))
            let provider = GmailProvider(
                userEmail: "owner@example.com", accessToken: { _ in "token" }, session: http.session)
            let olderUpload = Task {
                try await DraftStore.shared.pushDraftToServer(
                    draftId: draft.id, expectedInstanceEpoch: "E1", provider: provider,
                    runtimeKind: .gmail, draftsFolderPath: "Drafts")
            }
            let deadline = Date().addingTimeInterval(10)
            while !receivedOldRead.withLock({ $0 }) && Date() < deadline {
                try await Task.sleep(for: .milliseconds(20))
            }
            let entered = receivedOldRead.withLock { $0 }
            #expect(entered, "precondition: the older upload is suspended in its server read")
            guard entered else {
                releaseOldRead.signal()
                _ = try? await olderUpload.value
                return
            }

            // The user, seeing the other app's newer version, chooses Save as new.
            wrappedMessageId.withLock { $0 = "m2" }
            #expect(try await pool.write { db in
                try DraftStore.detachFromServerCopy(draftId: draft.id, expectedInstanceEpoch: "E1", db: db)
            })
            releaseOldRead.signal()
            let outcome = try await olderUpload.value

            #expect(outcome == .notApplied)
            #expect(!http.recordedCalls().contains { $0.method == "PUT" },
                    "the other app's draft was replaced after the user chose to keep both")
            let after = try #require(try await pool.read { try Draft.fetchOne($0, key: draft.id) })
            #expect(after.serverDraftId == nil, "the older upload reattached the row to the released draft")
        }
    }

    // MARK: - 4. Taking over keeps inline images

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
                    runtimeKind: .gmail, draftsFolderPath: "DRAFT") == .completed,
                        "the adopted copy, image included, must compare unchanged at the first upload")
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

    // MARK: - Round-2 review regressions

    @Test("Opening takes a confirmed empty server body instead of keeping the old one",
          arguments: ["pushed", "dirty"])
    func openTakesAnEmptyServerBody(status: String) async throws {
        try await withInstalledPool { pool in
            let draft = try await pool.write { db in
                var row = try insertDraft(db, status: status)
                if status == "pushed" { row.body = "now here"; try row.update(db) }
                return row
            }
            let http = FakeHTTP.Scenario()
            defer { http.close() }
            let provider = exchangeProvider(http, copyResponse: Self.copyJSON(body: ""))
            try await withRegisteredProvider(provider) {
                var asked = 0
                await ExternalDraftAdoption.refreshBeforeOpen(
                    draftId: draft.id, willReadServer: {},
                    askAboutUnsentEdits: { asked += 1; return .reload })
                #expect(http.recordedCalls().contains { $0.method == "GET" && $0.url.contains("/messages/g1") },
                        "the server copy really was fetched")
                #expect(asked == (status == "dirty" ? 1 : 0))
                let row = try #require(try await pool.read { try Draft.fetchOne($0, key: draft.id) })
                #expect(row.body.isEmpty, "a successful empty body must replace the old text")
                #expect(row.serverPushStatus == "pushed")
            }
        }
    }

    @Test("Save as new on open keeps the phone edit reachable in Drafts")
    func openSaveAsNewKeepsTheEditReachable() async throws {
        try await withInstalledPool { pool in
            let (draft, header, authority) = try await pool.write { db in
                let draft = try insertDraft(db, status: "dirty")
                let folder = Folder(name: "Drafts", path: "Drafts", role: .drafts, accountId: Self.accountId)
                try folder.insert(db)
                let header = MessageHeader(messageId: "g1", subject: "Plan", from: "owner@example.com", fromAddress: "owner@example.com",
                    to: "alice@example.com", date: Date(), snippet: "now here", folderId: folder.id, accountId: Self.accountId,
                    folderPath: "Drafts", isInInbox: false)
                try header.insert(db)
                // The save that left unsent edits also left the generation's
                // placeholder header; that is the state Save as new starts from.
                let placeholder = MessageHeader(
                    messageId: PendingOperation.draftPlaceholderMessageId(draftId: draft.id, instanceEpoch: draft.instanceEpoch),
                    subject: "Plan", from: "owner@example.com", fromAddress: "owner@example.com", to: "alice@example.com",
                    date: Date(), snippet: "phone edit", folderId: folder.id, accountId: Self.accountId,
                    folderPath: "Drafts", isInInbox: false)
                try placeholder.insert(db)
                let authority = try #require(try LocallyAuthoredDraftOpenAuthority.resolve(db: db, header: header, runtimeKind: .outlook))
                return (draft, header, authority)
            }
            #expect(authority.draftId == draft.id, "fixture: the row is reachable before choosing")
            let http = FakeHTTP.Scenario()
            defer { http.close() }
            let provider = exchangeProvider(http, copyResponse: Self.copyJSON(body: "rewritten elsewhere"))
            try await withRegisteredProvider(provider) {
                var asked = 0
                await ExternalDraftAdoption.refreshBeforeOpen(draftId: draft.id, willReadServer: {},
                    askAboutUnsentEdits: { asked += 1; return .saveAsNew })
                #expect(asked == 1)
                let row = try #require(try await pool.read { try Draft.fetchOne($0, key: draft.id) })
                #expect(row.body == "phone edit", "the phone edit must still exist")
                let routes = try await pool.read { db in
                    try MessageHeader.filter(Column("accountId") == Self.accountId).fetchAll(db).compactMap {
                        try LocallyAuthoredDraftOpenAuthority.resolve(db: db, header: $0, runtimeKind: .outlook)?.draftId
                    }
                }
                #expect(routes.contains(draft.id), "some Drafts row must still open the phone edit")
                #expect(!authority.matches(row, runtimeKind: .outlook), "the server copy's row no longer opens the detached edit")
                #expect(try await pool.read { try MessageHeader.fetchOne($0, key: header.id) } != nil,
                        "the other app's server draft is kept")
            }
        }
    }

    @Test("A demo draft saves again and reopens with its Cc and Bcc; it is never compared")
    func demoDraftKeepsRecipientsOnReopen() async throws {
        try await withInstalledPool { pool in
            let draft = try await pool.write { db in
                var draft = try insertDraft(db, status: "dirty")
                draft.serverDraftId = nil
                draft.serverDraftText = nil
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
            // A second save replaces the demo copy it now has an address for; it must
            // not wait on a server comparison no demo draft can answer.
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
                await ExternalDraftAdoption.refreshBeforeOpen(draftId: draft.id, willReadServer: {},
                    askAboutUnsentEdits: { Issue.record("no other app edits a demo draft"); return .reload })
                let after = try #require(try await pool.read { try Draft.fetchOne($0, key: draft.id) })
                #expect(after.ccArray == before.ccArray && after.bccArray == before.bccArray,
                        "the demo copy must never replace the draft's recipients")
            }
        }
    }
}
