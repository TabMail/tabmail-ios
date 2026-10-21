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
        "newer save", "generation", "status", "address",
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

    @Test("Graph: updating a draft makes its attachments exactly the local ones")
    func graphUpdateReplacesAttachments() async throws {
        let http = FakeHTTP.Scenario()
        defer { http.close() }
        http.register(path: "/messages/g1", method: "PATCH", response: .json(raw: #"{"id":"g1"}"#))
        http.register(path: "/messages/g1/attachments", method: "GET",
                      response: .json(raw: #"{"value":[{"id":"old1"},{"id":"old2"}]}"#))
        http.register(path: "/messages/g1/attachments/", method: "DELETE", response: .status(204))
        http.register(path: "/messages/g1/attachments", method: "POST", response: .json(raw: #"{"id":"new1"}"#))
        let provider = ExchangeProvider(
            userEmail: "owner@example.com", accessToken: { _ in "token" }, session: http.session)
        let draft = DraftMessage(
            to: ["alice@example.com"], cc: [], bcc: [], subject: "Plan", body: "Meet on Monday",
            attachments: [DraftAttachment(filename: "added.pdf", mimeType: "application/pdf", data: Data("pdf".utf8))])

        let result = try await provider.saveDraft(
            draft, existingIdentity: .outlook(graphId: "g1"), draftsFolderPath: "Drafts")

        #expect(result == .created(.outlook(graphId: "g1")))
        let calls = http.recordedCalls()
        let patch = try #require(calls.first { $0.method == "PATCH" })
        let patchJSON = try #require(try JSONSerialization.jsonObject(with: patch.body ?? Data()) as? [String: Any])
        #expect(patchJSON["attachments"] == nil, "Graph's PATCH cannot change attachments")
        let deleted = calls.filter { $0.method == "DELETE" }.compactMap { URL(string: $0.url)?.lastPathComponent }
        #expect(Set(deleted) == ["old1", "old2"], "every attachment the server held must go")
        let posts = calls.filter { $0.method == "POST" }
        #expect(posts.count == 1)
        let posted = try #require(try JSONSerialization.jsonObject(with: posts.first?.body ?? Data()) as? [String: Any])
        #expect(posted["name"] as? String == "added.pdf")
        #expect(posted["contentBytes"] as? String == Data("pdf".utf8).base64EncodedString())
        #expect(calls.lastIndex { $0.method == "DELETE" }! < calls.firstIndex { $0.method == "POST" }!,
                "the new set is added after the old one is gone")
    }

    @Test("Graph: a failed attachment replacement fails the save, so it retries")
    func graphUpdateAttachmentFailureThrows() async {
        let http = FakeHTTP.Scenario()
        defer { http.close() }
        http.register(path: "/messages/g1", method: "PATCH", response: .json(raw: #"{"id":"g1"}"#))
        http.register(path: "/messages/g1/attachments", method: "GET", response: .json(raw: #"{"value":[]}"#))
        http.register(path: "/messages/g1/attachments", method: "POST", response: .status(500))
        let provider = ExchangeProvider(
            userEmail: "owner@example.com", accessToken: { _ in "token" }, session: http.session)
        let draft = DraftMessage(
            to: [], cc: [], bcc: [], subject: "Plan", body: "x",
            attachments: [DraftAttachment(filename: "a.txt", mimeType: "text/plain", data: Data("a".utf8))])

        await #expect(throws: (any Error).self) {
            try await provider.saveDraft(draft, existingIdentity: .outlook(graphId: "g1"), draftsFolderPath: "Drafts")
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
