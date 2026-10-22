/* This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at https://mozilla.org/MPL/2.0/. */

import Foundation
import GRDB
import SwiftMail
import Synchronization
import Testing
@testable import TabMail

/// #217 fourth owner ruling (2026-10-21, ADR-IOS-091): LAST SAVE WINS. THE INVARIANTS:
/// 1. **A Gmail or Outlook draft with no unsent edits opens as the server's version.**
///    No comparison; a row with unsent edits opens as it is.
/// 2. **A reload never loses content the server holds.** A draft-copy read is
///    COMPLETE (every inline image, every attachment's bytes) or it throws.
/// 3. **A save makes the server copy equal the local draft**, attachments included,
///    so the next open's reload brings back exactly what was saved.
/// 4. **A reload never overwrites a newer local write** (generation, version,
///    status and address CAS).

@Suite("Draft open reload decision (#217)")
struct DraftOpenReloadDecisionTests {
    @Test("Only a Gmail or Outlook row with no unsent edits reloads before it opens", arguments: [
        ("pushed", DraftDeleteIdentity.gmail(resourceId: "r1"), true),
        ("pushed", .outlook(graphId: "g1"), true),
        ("dirty", .gmail(resourceId: "r1"), false),
        ("pushing", .outlook(graphId: "g1"), false),
        (nil, .outlook(graphId: "g1"), false),
        ("pushed", .imap(folder: "Drafts", uidValidity: 9, uid: 7), false),
        ("pushed", .demo(localId: "d1"), false),
        ("pushed", .gmailContainedMessage(messageId: "m1"), false),
    ] as [(String?, DraftDeleteIdentity, Bool)])
    func decision(status: String?, identity: DraftDeleteIdentity, reloads: Bool) {
        #expect(ExternalDraftAdoption.reloadsBeforeOpen(serverPushStatus: status, identity: identity) == reloads)
    }
}

/// The reload's row write, on a plain queue.
@Suite("Draft reload row write (#217)")
struct DraftReloadRowTests {
    private static let accountId = "acc-imap"

    /// An adopted IMAP draft at Drafts/900001/7.
    private func makeAdoptedImapDraft(_ db: DatabaseQueue) throws -> Draft {
        try TestDatabase.insertAccount(
            db, id: Self.accountId, email: "imap@example.com", provider: .imap)
        var folder = Folder(name: "Drafts", path: "Drafts", role: .drafts, accountId: Self.accountId)
        folder.lastKnownUidValidity = 900_001
        try db.write { try folder.insert($0) }
        var header = try TestDatabase.insertMessageHeader(
            db, messageId: "7", subject: "From the server", to: "alice@example.com",
            folderId: folder.id, accountId: Self.accountId, folderPath: "Drafts",
            isInInbox: false, rfc822MessageId: "server@example.com")
        header.observedUidValidity = 900_001
        try db.write { try header.update($0) }
        let address = try #require(try db.read { db in
            try ExternalDraftAdoption.adoptableAddress(db: db, header: header, runtimeKind: .imap)
        })
        let inserted = try db.write { db in
            try ExternalDraftAdoption.insertAdoptedDraft(
                db: db, header: header, address: address, runtimeKind: .imap,
                content: Self.content(body: "old local text"))
        }
        let draftId = try #require(inserted)
        return try #require(try db.read { try Draft.fetchOne($0, key: draftId) })
    }

    static func content(
        subject: String = "From the server", to: String = "alice@example.com", bcc: String = "",
        body: String
    ) -> ExternalDraftAdoption.ServerContent {
        ExternalDraftAdoption.ServerContent(
            subject: subject, to: to, cc: "", bcc: bcc, body: body,
            attachmentsDirName: nil, attachmentCount: 0)
    }

    private func reload(_ db: DatabaseQueue, decided: Draft) throws -> String?? {
        try db.write { db in
            try ExternalDraftAdoption.applyReload(
                db: db, decided: decided,
                content: Self.content(
                    subject: "Edited in another app", to: "alice@example.com, dave@example.com",
                    bcc: "erin@example.com", body: "server text"))
        }
    }

    @Test("Reload replaces the row's content with the fetched copy, marks it clean and advances the version")
    func reloadReplacesContent() throws {
        let db = try TestDatabase.make()
        let draft = try makeAdoptedImapDraft(db)

        let written = try reload(db, decided: draft)

        #expect(written != nil, "the reload wrote nothing")
        let row = try #require(try db.read { try Draft.fetchOne($0, key: draft.id) })
        #expect(row.body == "server text")
        #expect(row.subject == "Edited in another app", "subject must come from the fetched copy")
        #expect(row.toArray == ["alice@example.com", "dave@example.com"])
        #expect(row.bccArray == ["erin@example.com"])
        #expect(row.serverPushStatus == "pushed", "a reloaded row holds no unsent edits")
        #expect(row.serverDraftId == "7", "the reload must keep the exact address")
        #expect(row.pushAttemptVersion > draft.pushAttemptVersion,
                "an upload started before the reload must retire at Stage A")
    }

    @Test("Reload writes nothing over a row that changed while the server copy was read", arguments: [
        "newer save", "saved and uploaded", "generation", "status", "address",
    ])
    func reloadFailsClosed(change: String) throws {
        let db = try TestDatabase.make()
        let decided = try makeAdoptedImapDraft(db)
        try db.write { db in
            var row = try #require(try Draft.fetchOne(db, key: decided.id))
            switch change {
            case "newer save":
                row.body = "newest local edit"
                row.updatedAt += 1
                try DraftStore.applySave(row, db: db)
                return
            case "saved and uploaded":
                // A save, then its upload's Stage A and completion: the row is back
                // to "pushed" at the same address, and only its version moved on.
                row.body = "newest local edit"
                row.updatedAt += 1
                try DraftStore.applySave(row, db: db)
                var uploaded = try #require(try Draft.fetchOne(db, key: decided.id))
                uploaded.serverPushStatus = "pushed"
                uploaded.pushAttemptVersion += 1
                try uploaded.update(db)
                return
            case "generation": row.instanceEpoch = "another-generation"
            case "status": row.serverPushStatus = "dirty"
            default: row.serverDraftId = "9"
            }
            try row.update(db)
        }
        let before = try #require(try db.read { try Draft.fetchOne($0, key: decided.id) })

        #expect(try reload(db, decided: decided) == nil)

        let after = try #require(try db.read { try Draft.fetchOne($0, key: decided.id) })
        #expect(after.body == before.body && after.subject == before.subject
                && after.serverPushStatus == before.serverPushStatus
                && after.pushAttemptVersion == before.pushAttemptVersion,
                "a refused reload must leave the row untouched (\(change))")
    }
}

/// The provider reads and writes themselves, against canned HTTP.
@Suite("Draft server copy reads and writes (#217)")
struct DraftCopyReadTests {
    private static func base64URL(_ data: Data) -> String {
        data.base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }

    private static func graphMessageJSON(id: String, html: String) -> String {
        let received = ISO8601DateFormatter().string(from: Date())
        return """
            {"id":"\(id)","subject":"Plan","from":{"emailAddress":{"address":"owner@example.com"}},
             "receivedDateTime":"\(received)","isRead":true,"hasAttachments":false,
             "body":{"contentType":"html","content":"\(html)"}}
            """
    }

    /// A Gmail draft message whose HTML references `imageCount` inline images,
    /// each fetched through the attachments API as `img<index>`.
    private static func gmailMessageJSON(id: String, imageCount: Int) -> String {
        let internalDate = String(Int(Date().timeIntervalSince1970 * 1000))
        let refs = (0..<imageCount).map { "<img src=\"cid:pic\($0)\">" }.joined()
        let html = base64URL(Data("<div>Meet on Monday\(refs)</div>".utf8))
        let images = (0..<imageCount).map { index in
            #",{"mimeType":"image/png","headers":[{"name":"Content-ID","value":"<pic\#(index)>"}],"body":{"size":4,"attachmentId":"img\#(index)"}}"#
        }.joined()
        return """
            {"id":"\(id)","internalDate":"\(internalDate)","labelIds":["DRAFT"],
             "payload":{"mimeType":"multipart/related",
               "headers":[{"name":"Subject","value":"Plan"},{"name":"From","value":"owner@example.com"}],
               "parts":[{"mimeType":"text/html","body":{"size":20,"data":"\(html)"}}\(images)]}}
            """
    }

    @Test("Graph: the draft's current content is read, and 404 means gone")
    func graphCopy() async throws {
        let http = FakeHTTP.Scenario()
        defer { http.close() }
        http.register(path: "/messages/g1", method: "GET",
                      response: .json(raw: Self.graphMessageJSON(id: "g1", html: "<p>Meet on Monday</p>")))
        // Reading a Graph message always lists its attachments too.
        http.register(path: "/messages/g1/attachments", method: "GET", response: .json(raw: #"{"value":[]}"#))
        http.register(path: "/messages/g404", method: "GET", response: .status(404))
        let provider = ExchangeProvider(
            userEmail: "owner@example.com", accessToken: { _ in "token" }, session: http.session)

        let copy = try #require(try await provider.fetchDraftCopy(identity: .outlook(graphId: "g1")))
        #expect(copy.header.subject == "Plan")
        #expect(copy.htmlBody?.contains("Meet on Monday") == true)
        #expect(try await provider.fetchDraftCopy(identity: .outlook(graphId: "g404")) == nil)
    }

    @Test("Graph: a server error is an unknown, never gone")
    func graphErrorThrows() async {
        let http = FakeHTTP.Scenario()
        defer { http.close() }
        http.register(path: "/messages/g1", method: "GET", response: .status(500))
        let provider = ExchangeProvider(
            userEmail: "owner@example.com", accessToken: { _ in "token" }, session: http.session)

        await #expect(throws: (any Error).self) {
            try await provider.fetchDraftCopy(identity: .outlook(graphId: "g1"))
        }
    }

    @Test("Graph: an inline image that cannot be read fails the draft read, never drops the image")
    func graphInlineImageFailureThrows() async {
        let http = FakeHTTP.Scenario()
        defer { http.close() }
        http.register(path: "/messages/g1", method: "GET",
                      response: .json(raw: Self.graphMessageJSON(id: "g1", html: "<p>See <img src='cid:logo'></p>")))
        http.register(path: "/messages/g1/attachments", method: "GET", response: .json(raw: """
            {"value":[{"id":"a1","name":"logo.png","contentType":"image/png","size":4,"isInline":true,
             "contentId":"<logo>","@odata.type":"#microsoft.graph.fileAttachment"}]}
            """))
        http.register(path: "/messages/g1/attachments/a1", method: "GET", response: .status(500))
        let provider = ExchangeProvider(
            userEmail: "owner@example.com", accessToken: { _ in "token" }, session: http.session)

        await #expect(throws: (any Error).self) {
            try await provider.fetchDraftCopy(identity: .outlook(graphId: "g1"))
        }
    }

    @Test("Gmail: the message the draft currently wraps is read, and 404 means gone")
    func gmailCopy() async throws {
        let http = FakeHTTP.Scenario()
        defer { http.close() }
        http.register(path: "/drafts/r1", method: "GET",
                      response: .json(raw: #"{"message":{"id":"m-5"}}"#))
        http.register(path: "/drafts/r404", method: "GET", response: .status(404))
        http.register(path: "/messages/m-5", method: "GET",
                      response: .json(raw: Self.gmailMessageJSON(id: "m-5", imageCount: 0)))
        let provider = GmailProvider(
            userEmail: "owner@example.com", accessToken: { _ in "token" }, session: http.session)

        let copy = try #require(try await provider.fetchDraftCopy(identity: .gmail(resourceId: "r1")))
        #expect(copy.header.subject == "Plan")
        #expect(copy.htmlBody?.contains("Meet on Monday") == true)
        #expect(try await provider.fetchDraftCopy(identity: .gmail(resourceId: "r404")) == nil)
    }

    @Test("Gmail: a draft read carries every inline image, past the display cap")
    func gmailCopyReadsEveryInlineImage() async throws {
        let count = SyncConfig.maxInlineImages + 1
        let http = FakeHTTP.Scenario()
        defer { http.close() }
        http.register(path: "/drafts/r1", method: "GET", response: .json(raw: #"{"message":{"id":"m-5"}}"#))
        http.register(path: "/messages/m-5", method: "GET",
                      response: .json(raw: Self.gmailMessageJSON(id: "m-5", imageCount: count)))
        http.register(path: "/messages/m-5/attachments/", method: "GET",
                      response: .json(raw: "{\"size\":4,\"data\":\"\(Self.base64URL(Data([1, 2, 3, 4])))\"}"))
        let provider = GmailProvider(
            userEmail: "owner@example.com", accessToken: { _ in "token" }, session: http.session)

        let copy = try #require(try await provider.fetchDraftCopy(identity: .gmail(resourceId: "r1")))
        #expect(copy.inlineImages.count == count,
                "a reload of a capped read drops images, and the next save deletes them")
    }

    @Test("Gmail: an inline image that cannot be read fails the draft read, never drops the image")
    func gmailInlineImageFailureThrows() async {
        let http = FakeHTTP.Scenario()
        defer { http.close() }
        http.register(path: "/drafts/r1", method: "GET", response: .json(raw: #"{"message":{"id":"m-5"}}"#))
        http.register(path: "/messages/m-5", method: "GET",
                      response: .json(raw: Self.gmailMessageJSON(id: "m-5", imageCount: 1)))
        http.register(path: "/messages/m-5/attachments/", method: "GET", response: .status(500))
        let provider = GmailProvider(
            userEmail: "owner@example.com", accessToken: { _ in "token" }, session: http.session)

        await #expect(throws: (any Error).self) {
            try await provider.fetchDraftCopy(identity: .gmail(resourceId: "r1"))
        }
    }

    @Test("Graph: a draft read is the draft as text, every inline image, and attached mail kept as files")
    func graphDraftReadIsTheDraftOnly() async throws {
        let http = FakeHTTP.Scenario()
        defer { http.close() }
        let reads = RequestLog()
        let received = ISO8601DateFormatter().string(from: Date())
        http.register(path: "/messages/g1", method: "GET") { request in
            reads.requests.withLock { $0.append(request) }
            return .json(raw: """
                {"id":"g1","subject":"Plan","from":{"emailAddress":{"address":"owner@example.com"}},
                 "receivedDateTime":"\(received)","isRead":true,"hasAttachments":true,
                 "body":{"contentType":"text","content":"Hi Bob,\\r\\n\\r\\n  indented\\r\\n> quoted"}}
                """)
        }
        http.register(path: "/messages/g1/attachments", method: "GET", response: .json(raw: """
            {"value":[
             {"id":"e1","name":"Forwarded","contentType":"message/rfc822","size":9,"isInline":false,
              "@odata.type":"#microsoft.graph.itemAttachment"},
             {"id":"f1","name":"fwd.eml","contentType":"application/octet-stream","size":9,"isInline":false,
              "@odata.type":"#microsoft.graph.fileAttachment"},
             {"id":"i1","name":"logo.png","contentType":"image/png","size":2,"isInline":true,"contentId":"<logo>",
              "@odata.type":"#microsoft.graph.fileAttachment"},
             {"id":"i2","name":"pic.png","contentType":"image/png","size":2,"isInline":true,"contentId":" ",
              "@odata.type":"#microsoft.graph.fileAttachment"}]}
            """))
        http.register(path: "/messages/g1/attachments/i1", method: "GET",
                      response: .json(raw: "{\"contentBytes\":\"\(Data([7, 8]).base64EncodedString())\"}"))
        let provider = ExchangeProvider(
            userEmail: "owner@example.com", accessToken: { _ in "token" }, session: http.session)

        let copy = try #require(try await provider.fetchDraftCopy(identity: .outlook(graphId: "g1")))

        #expect(reads.requests.withLock { $0 }.contains { $0.header("Prefer") == "outlook.body-content-type=\"text\"" },
                "the draft body must be read as text, not re-converted from HTML")
        #expect(copy.textBody == "Hi Bob,\r\n\r\n  indented\r\n> quoted")
        #expect(copy.htmlBody == nil, "an attached message's text must never join the draft body")
        #expect(copy.inlineImages.map(\.contentId) == ["logo"], "an inline image the body does not reference is still the draft's")
        #expect(copy.inlineImages.first?.data == Data([7, 8]))
        #expect(copy.attachments.map(\.filename) == ["Forwarded", "fwd.eml", "pic.png"],
                "attached mail stays a file, and an image with no Content-ID is carried as a file")
        #expect(!http.recordedCalls().contains { $0.url.contains("$expand") || $0.url.contains("/attachments/f1") },
                "a draft read never opens an attached message")
    }

    @Test("Gmail: a draft read takes only the draft's own text, keeps attached mail a file, and every inline image")
    func gmailDraftReadIsTheDraftOnly() async throws {
        let http = FakeHTTP.Scenario()
        defer { http.close() }
        let internalDate = String(Int(Date().timeIntervalSince1970 * 1000))
        let own = Self.base64URL(Data("Hi Bob,\n\nPlan".utf8))
        let ownHTML = Self.base64URL(Data("<div>Hi Bob,</div><div><br></div><div>Plan</div>".utf8))
        let inner = Self.base64URL(Data("INNER TEXT".utf8))
        http.register(path: "/drafts/r1", method: "GET", response: .json(raw: #"{"message":{"id":"m-5"}}"#))
        http.register(path: "/messages/m-5", method: "GET", response: .json(raw: """
            {"id":"m-5","internalDate":"\(internalDate)","labelIds":["DRAFT"],
             "payload":{"mimeType":"multipart/mixed",
               "headers":[{"name":"Subject","value":"Plan"},{"name":"From","value":"owner@example.com"}],
               "parts":[
                 {"mimeType":"multipart/alternative","parts":[
                   {"mimeType":"text/plain","body":{"size":19,"data":"\(own)"}},
                   {"mimeType":"text/html","body":{"size":50,"data":"\(ownHTML)"}}]},
                 {"mimeType":"message/rfc822","filename":"","body":{"size":30,"attachmentId":"eml1"},
                  "parts":[{"mimeType":"text/plain","body":{"size":10,"data":"\(inner)"}},
                           {"mimeType":"text/html","body":{"size":10,"data":"\(inner)"}}]},
                 {"mimeType":"image/png","headers":[{"name":"Content-ID","value":"<logo>"}],
                  "body":{"size":4,"attachmentId":"img0"}},
                 {"mimeType":"image/png","filename":"photo.png","body":{"size":4,"attachmentId":"p1"}}]}}
            """))
        http.register(path: "/messages/m-5/attachments/", method: "GET",
                      response: .json(raw: "{\"size\":4,\"data\":\"\(Self.base64URL(Data([1, 2, 3, 4])))\"}"))
        let provider = GmailProvider(
            userEmail: "owner@example.com", accessToken: { _ in "token" }, session: http.session)

        let copy = try #require(try await provider.fetchDraftCopy(identity: .gmail(resourceId: "r1")))

        #expect(copy.textBody == "Hi Bob,\n\nPlan")
        #expect(copy.htmlBody == "<div>Hi Bob,</div><div><br></div><div>Plan</div>")
        #expect(copy.attachments.map(\.filename) == ["attached-email.eml", "photo.png"])
        #expect(copy.inlineImages.map(\.contentId) == ["logo"], "an unreferenced inline image is still the draft's")
        let editable = try #require(ExternalDraftAdoption.editableBody(
            text: copy.textBody, html: copy.htmlBody, bodyEmptyConfirmed: false, hasAttachments: true))
        #expect(editable == "Hi Bob,\n\nPlan", "the attached message's text joined the draft body")
    }

    /// #238: a text-only draft another app wrote as `format=flowed` opens with its
    /// soft line breaks joined; one that does not declare it keeps its trailing spaces.
    @Test("Gmail: a text-only draft is decoded as format=flowed only when its part says so", arguments: [
        ("text/plain; charset=\\\"UTF-8\\\"; format=flowed", "Thanks for the long explanation.\n\nAlice"),
        ("text/plain; charset=\\\"UTF-8\\\"", "Thanks for the long \nexplanation.\n\nAlice"),
    ])
    func gmailFlowedDraftRead(contentType: String, expected: String) async throws {
        let http = FakeHTTP.Scenario()
        defer { http.close() }
        let internalDate = String(Int(Date().timeIntervalSince1970 * 1000))
        let text = Self.base64URL(Data("Thanks for the long \r\nexplanation.\r\n\r\nAlice".utf8))
        http.register(path: "/drafts/r1", method: "GET", response: .json(raw: #"{"message":{"id":"m-6"}}"#))
        http.register(path: "/messages/m-6", method: "GET", response: .json(raw: """
            {"id":"m-6","internalDate":"\(internalDate)","labelIds":["DRAFT"],
             "payload":{"mimeType":"text/plain",
               "headers":[{"name":"Subject","value":"Plan"},{"name":"Content-Type","value":"\(contentType)"}],
               "body":{"size":44,"data":"\(text)"}}}
            """))
        let provider = GmailProvider(
            userEmail: "owner@example.com", accessToken: { _ in "token" }, session: http.session)

        let copy = try #require(try await provider.fetchDraftCopy(identity: .gmail(resourceId: "r1")))

        #expect(ExternalDraftAdoption.editableBody(
            text: copy.textBody, html: copy.htmlBody, bodyEmptyConfirmed: false, hasAttachments: false) == expected)
    }

    @Test("Providers refuse to read another provider's draft address")
    func foreignIdentityIsRefused() async {
        let http = FakeHTTP.Scenario()
        defer { http.close() }
        let gmail = GmailProvider(
            userEmail: "owner@example.com", accessToken: { _ in "token" }, session: http.session)
        let graph = ExchangeProvider(
            userEmail: "owner@example.com", accessToken: { _ in "token" }, session: http.session)
        await #expect(throws: ProviderError.self) {
            try await gmail.fetchDraftCopy(identity: .outlook(graphId: "g1"))
        }
        await #expect(throws: ProviderError.self) {
            try await graph.fetchDraftCopy(identity: .gmail(resourceId: "r1"))
        }
        #expect(http.recordedCalls().isEmpty)
    }

    final class RequestLog: Sendable {
        let requests = Mutex<[FakeHTTP.Request]>([])
    }

    private static func graphUpdateProvider(
        _ http: FakeHTTP.Scenario, serverFiles: [(id: String, name: String)]
    ) -> ExchangeProvider {
        http.register(path: "/messages/g1", method: "PATCH", response: .json(raw: #"{"id":"g1"}"#))
        let items = serverFiles.map { "{\"id\":\"\($0.id)\",\"name\":\"\($0.name)\"}" }.joined(separator: ",")
        http.register(path: "/messages/g1/attachments", method: "GET", response: .json(raw: "{\"value\":[\(items)]}"))
        http.register(path: "/messages/g1/attachments/", method: "DELETE", response: .status(204))
        return ExchangeProvider(
            userEmail: "owner@example.com", accessToken: { _ in "token" }, session: http.session)
    }

    private static func draft(attachments: [DraftAttachment]) -> DraftMessage {
        DraftMessage(to: ["alice@example.com"], cc: [], bcc: [], subject: "Plan", body: "Meet on Monday",
                     attachments: attachments)
    }

    private static func file(_ name: String, _ text: String = "bytes") -> DraftAttachment {
        DraftAttachment(filename: name, mimeType: "application/pdf", data: Data(text.utf8))
    }

    @Test("Graph: a save leaves the server holding exactly the draft's files, adding before deleting")
    func graphUpdateSyncsAttachmentsByName() async throws {
        let http = FakeHTTP.Scenario()
        defer { http.close() }
        let provider = Self.graphUpdateProvider(http, serverFiles: [(id: "k1", name: "keep.pdf"), (id: "r1", name: "removed.pdf")])
        http.register(path: "/messages/g1/attachments", method: "POST", response: .json(raw: #"{"id":"n1"}"#))

        let result = try await provider.saveDraft(
            Self.draft(attachments: [Self.file("keep.pdf"), Self.file("added.pdf", "pdf")]),
            existingIdentity: .outlook(graphId: "g1"), draftsFolderPath: "Drafts")

        #expect(result == .created(.outlook(graphId: "g1")))
        let calls = http.recordedCalls()
        let patch = try #require(calls.first { $0.method == "PATCH" })
        let patchJSON = try #require(try JSONSerialization.jsonObject(with: patch.body ?? Data()) as? [String: Any])
        #expect(patchJSON["attachments"] == nil, "Graph's PATCH cannot change attachments")
        let posts = calls.filter { $0.method == "POST" }
        #expect(posts.count == 1, "a file the server already holds is never sent again")
        let posted = try #require(try JSONSerialization.jsonObject(with: posts.first?.body ?? Data()) as? [String: Any])
        #expect(posted["name"] as? String == "added.pdf")
        #expect(posted["contentBytes"] as? String == Data("pdf".utf8).base64EncodedString())
        let deleted = calls.filter { $0.method == "DELETE" }.compactMap { URL(string: $0.url)?.lastPathComponent }
        #expect(deleted == ["r1"], "only the file the draft no longer has goes; keep.pdf stays")
        let lastAdd = try #require(calls.lastIndex { $0.method == "POST" })
        let firstDelete = try #require(calls.firstIndex { $0.method == "DELETE" })
        #expect(lastAdd < firstDelete, "a delete before the add leaves the server short if the add fails")
    }

    @Test("Graph: a failed add fails the save and the server still holds every file")
    func graphUpdateAttachmentFailureThrows() async {
        let http = FakeHTTP.Scenario()
        defer { http.close() }
        let provider = Self.graphUpdateProvider(http, serverFiles: [(id: "k1", name: "keep.pdf"), (id: "r1", name: "removed.pdf")])
        http.register(path: "/messages/g1/attachments", method: "POST", response: .status(500))

        await #expect(throws: (any Error).self) {
            try await provider.saveDraft(
                Self.draft(attachments: [Self.file("keep.pdf"), Self.file("added.pdf")]),
                existingIdentity: .outlook(graphId: "g1"), draftsFolderPath: "Drafts")
        }
        #expect(!http.recordedCalls().contains { $0.method == "DELETE" },
                "a failed save must not remove anything from the server copy")
    }

    @Test("Graph: files pair with server attachments by name, one to one")
    func draftAttachmentPlanPairsByName() {
        let plan = ExchangeProvider.draftAttachmentPlan(
            server: [(id: "s1", name: "a.pdf"), (id: "s2", name: "b.pdf"), (id: "s3", name: "b.pdf")],
            local: [Self.file("a.pdf"), Self.file("a.pdf"), Self.file("c.pdf")])
        #expect(plan.add.map(\.filename) == ["a.pdf", "c.pdf"], "a second same-named local file needs its own copy")
        #expect(plan.deleteIds == ["s2", "s3"])
        let unchanged = ExchangeProvider.draftAttachmentPlan(
            server: [(id: "s1", name: "a.pdf")], local: [Self.file("a.pdf")])
        #expect(unchanged.add.isEmpty && unchanged.deleteIds.isEmpty)
    }

    @Test("Graph: a file too large for one POST goes through an upload session, in ordered ranges, without the token")
    func graphLargeAttachmentUsesUploadSession() async throws {
        let http = FakeHTTP.Scenario()
        defer { http.close() }
        let provider = Self.graphUpdateProvider(http, serverFiles: [])
        http.register(path: "/messages/g1/attachments/createUploadSession", method: "POST", response: .json(raw: """
            {"uploadUrl":"https://outlook.office.com/api/v2.0/Users('u')/Messages('g1')/AttachmentSessions('s1')?authtoken=t"}
            """))
        let total = ExchangeDraftConfig.singlePostAttachmentLimitBytes + 1
        let bytes = Data((0..<total).map { UInt8(truncatingIfNeeded: $0) })
        let puts = RequestLog()
        http.register(path: "AttachmentSessions", method: "PUT") { request in
            let isLast = puts.requests.withLock { $0.append(request); return $0.count } > 1
            return isLast ? .json(raw: "{}", statusCode: 201) : .json(raw: "{}")
        }

        _ = try await provider.saveDraft(
            Self.draft(attachments: [DraftAttachment(filename: "big.bin", mimeType: "application/octet-stream", data: bytes)]),
            existingIdentity: .outlook(graphId: "g1"), draftsFolderPath: "Drafts")

        let calls = http.recordedCalls()
        #expect(!calls.contains { $0.method == "POST" && $0.url.hasSuffix("/attachments") },
                "a file of the single-POST limit or more cannot go in one POST")
        let session = try #require(calls.first { $0.url.contains("createUploadSession") })
        let sessionJSON = try #require(try JSONSerialization.jsonObject(with: session.body ?? Data()) as? [String: Any])
        let item = try #require(sessionJSON["AttachmentItem"] as? [String: Any])
        #expect(item["name"] as? String == "big.bin")
        #expect(item["size"] as? Int == total)
        let sent = puts.requests.withLock { $0 }
        try #require(sent.count == 2)
        let chunk = ExchangeDraftConfig.uploadChunkBytes
        #expect(sent.map { $0.header("Content-Range") } == ["bytes 0-\(chunk - 1)/\(total)", "bytes \(chunk)-\(total - 1)/\(total)"])
        #expect(sent.allSatisfy { $0.header("Authorization") == nil }, "the session URL is pre-authenticated; the token must not leave Graph")
        #expect(sent.compactMap(\.body).reduce(Data(), +) == bytes, "the server must receive the file's exact bytes")
    }

    @Test("Graph: an upload session URL off the documented Outlook hosts is refused")
    func uploadURLMustBeAnOutlookHost() throws {
        for raw in ["https://outlook.office.com/api/v2.0/x", "https://OUTLOOK.office365.com/api/v2.0/x"] {
            #expect(throws: Never.self) { try ExchangeProvider.validatedUploadURL(raw) }
        }
        for raw in [nil, "http://outlook.office.com/x", "https://attacker.example.com/x",
                    "https://outlook.office.com.example.com/x", "https://u:p@outlook.office.com/x",
                    "https://outlook.office.com:8443/x"] {
            #expect(throws: ProviderError.self) { try ExchangeProvider.validatedUploadURL(raw) }
        }
    }
}

/// IMAP: the draft copy is complete and carries its attachment bytes from the one
/// read made under the proven UIDVALIDITY.
@Suite("IMAP draft copy completeness (#217)")
struct IMAPDraftCopyCompletenessTests {
    private static func full(attachments: [AttachmentInfo]) -> FullMessageInfo {
        FullMessageInfo(
            header: MessageHeaderInfo(
                messageId: "7", rfc822MessageId: nil, inReplyTo: nil, references: [], threadId: nil,
                subject: "Plan", from: "", fromAddress: "", to: "", cc: "", bcc: "", replyTo: nil,
                date: Date(), snippet: "", isRead: true, isFlagged: false, hasAttachments: !attachments.isEmpty,
                isReplied: false, isForwarded: false, actionTag: nil),
            htmlBody: "<p>x</p>", textBody: nil, attachments: attachments)
    }

    private static func message(_ parts: [MessagePart]) -> SwiftMail.Message {
        Message(header: MessageInfo(sequenceNumber: SequenceNumber(1), subject: "Plan"), parts: parts)
    }

    @Test("Top-level attachment bytes are decoded from the read; nested ones are left to their parent")
    func carriesAttachmentBytes() throws {
        let pdf = Data("pdf bytes".utf8)
        let copy = try IMAPProvider.completeDraftCopy(
            Self.full(attachments: [
                AttachmentInfo(filename: "a.pdf", contentType: "application/pdf", section: "2", size: 9, encoding: "base64"),
                AttachmentInfo(filename: "inner.txt", contentType: "text/plain", section: "3.eml-nested.0",
                               size: 1, encoding: "base64", parentEmlSection: "3"),
            ]),
            message: Self.message([
                MessagePart(sectionString: "1", contentType: "text/html", data: Data("<p>x</p>".utf8)),
                MessagePart(sectionString: "2", contentType: "application/pdf", disposition: "attachment",
                            encoding: "base64", filename: "a.pdf", data: Data(pdf.base64EncodedString().utf8)),
            ]))
        #expect(copy.attachmentData == ["2": pdf])
    }

    @Test("Every inline image is carried, past the display cap")
    func carriesEveryInlineImage() throws {
        let count = SyncConfig.maxInlineImages + 1
        let parts = (0..<count).map { index in
            MessagePart(sectionString: "\(index + 2)", contentType: "image/png",
                        contentId: "<pic\(index)>", data: Data([UInt8(index)]))
        }
        let copy = try IMAPProvider.completeDraftCopy(Self.full(attachments: []), message: Self.message(parts))
        #expect(copy.inlineImages.count == count)
        #expect(copy.inlineImages.first?.contentId == "pic0")
    }

    @Test("The body is only the draft's own text; attached mail and a nameless image stay files; every inline image is kept")
    func readsTheDraftOnly() throws {
        let attached = Data("Subject: old\r\n\r\nINNER TEXT".utf8)
        let copy = try IMAPProvider.completeDraftCopy(Self.full(attachments: []), message: Self.message([
            MessagePart(sectionString: "1", contentType: "text/plain", data: Data("Hi Bob,\r\n\r\n  indented".utf8)),
            MessagePart(sectionString: "2", contentType: "message/rfc822", data: attached),
            MessagePart(sectionString: "2.1", contentType: "text/plain", data: Data("INNER TEXT".utf8)),
            MessagePart(sectionString: "2.2", contentType: "image/png", contentId: "<inner>", data: Data([9])),
            MessagePart(sectionString: "3", contentType: "image/png", contentId: "<logo>", data: Data([1, 2])),
            MessagePart(sectionString: "4", contentType: "image/png", filename: "photo.png", data: Data([3])),
        ]))
        #expect(copy.textBody == "Hi Bob,\r\n\r\n  indented")
        #expect(copy.htmlBody == nil, "the render's HTML (or an attached message's text) must not become the draft body")
        #expect(copy.inlineImages.map(\.contentId) == ["logo"], "an image inside an attached message is not the draft's")
        #expect(copy.attachments.map(\.section) == ["2", "4"])
        #expect(copy.attachmentData?["2"] == attached, "the attached message is carried whole, as a file")
        #expect(copy.attachmentData?["4"] == Data([3]))
    }

    @Test("A part that came back without bytes fails the read", arguments: ["attachment", "inline"])
    func missingBytesThrow(kind: String) {
        let attachments = kind == "attachment"
            ? [AttachmentInfo(filename: "a.pdf", contentType: "application/pdf", section: "2", size: 1, encoding: nil)]
            : []
        let part = kind == "attachment"
            ? MessagePart(sectionString: "2", contentType: "application/pdf", disposition: "attachment", filename: "a.pdf")
            : MessagePart(sectionString: "2", contentType: "image/png", contentId: "<pic>")
        #expect(throws: IMAPProvider.IMAPDraftCopyIncomplete.self) {
            try IMAPProvider.completeDraftCopy(Self.full(attachments: attachments), message: Self.message([part]))
        }
    }
}
