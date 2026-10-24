/* This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at https://mozilla.org/MPL/2.0/. */

import Foundation
import GRDB
import SwiftMail
import Synchronization
import Testing
import UIKit
@testable import TabMail

/// #217: a draft read from the server becomes the editable draft, so it must be the
/// draft whole and as written: every body piece and file with its own name and
/// bytes, one version's reply parent, and nothing left behind when the write fails.
@Suite("Draft copy integrity (#217)", .serialized, .processGlobalState)
@MainActor
struct DraftCopyIntegrityTests {
    private nonisolated static let accountId = "acc-217-copy-integrity"

    nonisolated static func base64URL(_ data: Data) -> String {
        data.base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }

    private func withInstalledPool(_ body: (DatabasePool) async throws -> Void) async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("draft-copy-integrity-\(UUID().uuidString)")
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
        defer { InstalledTestDatabaseLifetime.finish(previous: previous, pool: pool, directory: directory) }
        try await body(pool)
    }

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

    // MARK: - File names

    @Test("An IMAP draft's file keeps the name its own MIME header gives it",
          arguments: ["notes.txt", "docs\\notes.txt"])
    func imapFileKeepsItsHeaderName(filename: String) async throws {
        #expect(AttachmentFilename.isSafeFileComponent(filename), "fixture: the name is storable")
        let bytes = Data("attachment bytes".utf8)
        let encoded = Data(bytes.base64EncodedString().utf8)
        let body = Data("body".utf8)
        // The server's BODYSTRUCTURE lost the backslash; the part's MIME header has it.
        let summaryName = filename.replacingOccurrences(of: "\\", with: "")
        let mime = Data("""
            Content-Type: text/plain; name="\(filename)"\r
            Content-Disposition: attachment; filename="\(filename)"\r
            Content-Transfer-Encoding: base64\r
            \r

            """.utf8)
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(identifier: "UTC")
        formatter.dateFormat = "EEE, dd MMM yyyy HH:mm:ss Z"
        let date = formatter.string(from: Date())
        formatter.dateFormat = "dd-MMM-yyyy HH:mm:ss Z"
        let internalDate = formatter.string(from: Date())
        let header = """
            From: Sender <sender@example.com>\r
            To: Recipient <recipient@example.com>\r
            Subject: draft\r
            Date: \(date)\r
            Message-ID: <file-name@example.com>\r
            Content-Type: multipart/mixed; boundary=b\r
            \r

            """
        let structure = """
            (("TEXT" "PLAIN" ("CHARSET" "UTF-8") NIL NIL "7BIT" \(body.count) 1)\
            ("TEXT" "PLAIN" ("NAME" "\(summaryName)") NIL NIL "BASE64" \(encoded.count) 1 NIL \
            ("attachment" ("filename" "\(summaryName)"))) "MIXED")
            """
        let message = FakeIMAPServer.makeMultipartMessage(
            uid: 5, subject: "draft", from: "Sender <sender@example.com>",
            to: "Recipient <recipient@example.com>", date: date, internalDate: internalDate,
            messageID: "<file-name@example.com>", rawHeader: header, fullMessage: Data(header.utf8),
            bodystructure: structure, partBodies: ["1": body, "2": encoded, "2.MIME": mime])
        let epoch = 73_099
        let server = FakeIMAPServer(mailboxes: ["Drafts": [message]])
        server.setUidValidity(epoch, for: "Drafts")
        try server.start()
        defer { server.stop() }
        let provider = IMAPProvider(
            host: "127.0.0.1", port: server.port, username: server.username, password: server.password,
            smtpHost: "127.0.0.1", smtpPort: 587, useTLS: false)
        try await provider.connect()
        defer { Task { try? await provider.disconnect() } }

        let copy = try #require(try await provider.fetchDraftCopy(
            identity: .imap(folder: "Drafts", uidValidity: epoch, uid: 5)))

        #expect(copy.textBody == "body")
        #expect(copy.attachmentData?["2"] == bytes)
        #expect(copy.attachments.map(\.filename) == [filename], "the draft's file was renamed")
    }

    // MARK: - One version's reply parent

    /// The Gmail draft `r1` was listed at message `m-old`, a reply to `old-parent`; the
    /// other app has since replaced it with `m-new`, a reply to `new-parent`.
    private nonisolated func insertReplyFixture(
        _ db: Database, adopted: Bool, copyInReplyTo: String? = nil
    ) throws -> MessageHeader {
        var account = Account(emailAddress: "owner@example.com", displayName: "Test", provider: .gmail)
        account.id = Self.accountId
        try account.insert(db)
        let drafts = Folder(name: "Drafts", path: "DRAFT", role: .drafts, accountId: account.id)
        let inbox = Folder(name: "Inbox", path: "INBOX", role: .inbox, accountId: account.id)
        try drafts.insert(db)
        try inbox.insert(db)
        for (id, rfc) in [("p-old", "old-parent@example.com"), ("p-new", "new-parent@example.com")] {
            var parent = MessageHeader(
                messageId: id, subject: id, from: "sender@example.com", fromAddress: "sender@example.com",
                to: "owner@example.com", date: Date(), snippet: "", folderId: inbox.id,
                accountId: account.id, folderPath: inbox.path, isInInbox: true)
            parent.rfc822MessageId = rfc
            try parent.insert(db)
        }
        var header = MessageHeader(
            messageId: "m-old", subject: "old draft", from: "owner@example.com", fromAddress: "owner@example.com",
            to: "old@example.com", date: Date(), snippet: "", folderId: drafts.id,
            accountId: account.id, folderPath: drafts.path, isInInbox: false)
        header.rfc822MessageId = "old-draft@example.com"
        header.inReplyTo = "old-parent@example.com"
        try header.insert(db)
        if adopted {
            _ = try ExternalDraftAdoption.insertAdoptedDraft(
                db: db, header: header, address: .gmail(resourceId: "r1", containedMessageId: "m-old"),
                runtimeKind: .gmail,
                content: .init(subject: "old draft", to: "old@example.com", cc: "", bcc: "", body: "old body",
                               attachmentsDirName: nil, attachmentCount: 0, inReplyTo: copyInReplyTo))
        }
        return header
    }

    /// The row id of the fixture's inbox parent with the given UID.
    private nonisolated func parentHeaderId(_ messageId: String) -> String {
        MessageIdentity.headerId(accountId: Self.accountId, folderPath: "INBOX", messageId: messageId)
    }

    /// `parent` nil: the other app replaced the draft with a standalone message.
    private func registerReplacedGmailDraft(_ http: FakeHTTP.Scenario, parent: String?) throws {
        http.register(path: "/drafts", method: "GET", response: .json(raw: #"{"drafts":[{"id":"r1","message":{"id":"m-old"}}]}"#))
        http.register(path: "/drafts/r1", method: "GET", response: .json(raw: #"{"message":{"id":"m-new"}}"#))
        var headers = [["name": "Subject", "value": "new reply"],
                       ["name": "From", "value": "owner@example.com"], ["name": "To", "value": "new@example.com"],
                       ["name": "Message-ID", "value": "<new-draft@example.com>"]]
        if let parent { headers.append(["name": "In-Reply-To", "value": "<\(parent)>"]) }
        let payload: [String: Any] = [
            "id": "m-new", "internalDate": String(Int(Date().timeIntervalSince1970 * 1000)), "labelIds": ["DRAFT"],
            "payload": [
                "mimeType": "text/plain",
                "headers": headers,
                "body": ["size": 14, "data": Self.base64URL(Data("new reply text".utf8))],
            ] as [String: Any],
        ]
        http.register(path: "/messages/m-new", method: "GET", response: .json(
            raw: String(decoding: try JSONSerialization.data(withJSONObject: payload), as: UTF8.self)))
    }

    /// The sent reply's parent, as the send path derives it from the row.
    private func sentParent(_ pool: DatabasePool, draftId: String) async throws -> String? {
        let row = try #require(try await pool.read { try Draft.fetchOne($0, key: draftId) })
        let parent = try await pool.read { db in
            try Draft.resolveReplyToHeader(
                draftKey: row.id, replyToId: row.replyToId, isForward: row.isForward,
                expectedProviderMessageId: row.replyToProviderMessageId,
                expectedUidValidity: row.replyToUidValidity, db: db)
        }
        return ThreadUtils.outgoingThreadHeaders(
            replyTo: parent, sendAccountId: row.accountId, sendSubject: row.subject, providerKind: .gmail).inReplyTo
    }

    @Test("Gmail adoption never pairs a newer message's text with the listed message's reply parent")
    func gmailAdoptionOfAReplacedDraftKeepsOneVersion() async throws {
        try await withInstalledPool { pool in
            let header = try await pool.write { try self.insertReplyFixture($0, adopted: false) }
            let http = FakeHTTP.Scenario()
            defer { http.close() }
            try registerReplacedGmailDraft(http, parent: "new-parent@example.com")
            let provider = GmailProvider(userEmail: "owner@example.com", accessToken: { _ in "token" }, session: http.session)
            try await withRegisteredProvider(provider) {
                let authority = try await ServerDraftComposeLoader.resolveOpenAuthority(header: header)
                #expect(http.recordedCalls().contains { $0.url.contains("/messages/m-new") }, "precondition: the newer copy was read")
                if let authority {
                    #expect(try await sentParent(pool, draftId: authority.draftId)?.contains("old-parent") != true,
                            "the new text would be sent as a reply to the old parent")
                } else {
                    #expect(try await pool.read { try Draft.fetchCount($0) } == 0, "a refused adoption stores nothing")
                }
                #expect(http.recordedCalls().allSatisfy { $0.method == "GET" }, "opening must not change the server")
            }
        }
    }

    @Test("A Gmail reload never keeps the old reply parent under another app's reply to a different message",
          arguments: ["new-parent@example.com", "old-parent@example.com"])
    func gmailReloadKeepsOneVersionsParent(copyParent: String) async throws {
        try await withInstalledPool { pool in
            let header = try await pool.write { try self.insertReplyFixture($0, adopted: true) }
            let existing = try #require(try await pool.read { try Draft.fetchOne($0) })
            #expect(existing.body == "old body" && existing.replyToId == parentHeaderId("p-old"), "fixture: an adopted reply to old-parent")
            let http = FakeHTTP.Scenario()
            defer { http.close() }
            try registerReplacedGmailDraft(http, parent: copyParent)
            let provider = GmailProvider(userEmail: "owner@example.com", accessToken: { _ in "token" }, session: http.session)
            try await withRegisteredProvider(provider) {
                let check = await ExternalDraftAdoption.refreshBeforeOpen(draftId: existing.id, willReadServer: {})
                #expect(http.recordedCalls().contains { $0.url.contains("/messages/m-new") }, "precondition: the newer copy was read")
                #expect(http.recordedCalls().allSatisfy { $0.method == "GET" }, "opening must not change the server")
                let row = try await pool.read { try Draft.fetchOne($0, key: existing.id) }
                if copyParent == "old-parent@example.com" {
                    // Same parent: an ordinary reload.
                    #expect(check == .open)
                    #expect(row?.body == "new reply text" && row?.replyToId == parentHeaderId("p-old"))
                    return
                }
                #expect(check == .replacedElsewhere)
                #expect(row == nil, "the row would send the new text as a reply to the old parent")
                // Reopening from the list never brings the old parent back.
                if let authority = try await ServerDraftComposeLoader.resolveOpenAuthority(header: header) {
                    #expect(try await sentParent(pool, draftId: authority.draftId)?.contains("old-parent") != true)
                }
            }
        }
    }

    // MARK: - A reply replaced by a standalone message (#278)

    /// A TabMail reply (or forward) to `old-parent`, saved on the device and uploaded
    /// through Gmail as draft `r1` (contained message `m-old`). Returns the row and
    /// the raw message the upload sent.
    private func pushTabMailGmailDraft(
        _ pool: DatabasePool, http: FakeHTTP.Scenario, isForward: Bool = false, includeContainedMessageId: Bool = true
    ) async throws -> (draft: Draft, raw: String) {
        let draftId = "\(isForward ? "forward" : "reply"):\(Self.accountId):old-parent@example.com"
        try await pool.write { db in
            _ = try self.insertReplyFixture(db, adopted: false)
            var draft = Draft(
                id: draftId, accountId: Self.accountId, toJSON: #"["old@example.com"]"#, ccJSON: "[]", bccJSON: "[]",
                subject: "old draft", body: "old body", replyToId: self.parentHeaderId("p-old"), isForward: isForward,
                editHistoryJSON: nil, createdAt: 1, updatedAt: 2, serverDraftId: nil,
                serverPushStatus: nil, rfc822MessageId: nil, attachmentsDirName: nil)
            draft.instanceEpoch = "tabmail-E1"
            draft.replyToProviderMessageId = "p-old"
            try DraftStore.applySave(draft, db: db)
        }
        http.register(path: "/drafts", method: "POST", response: .json(raw: includeContainedMessageId ? #"{"id":"r1","message":{"id":"m-old"}}"# : #"{"id":"r1"}"#))
        let provider = GmailProvider(userEmail: "owner@example.com", accessToken: { _ in "token" }, session: http.session)
        let saved = try await DraftStore.shared.pushDraftToServer(
            draftId: draftId, expectedInstanceEpoch: "tabmail-E1", provider: provider,
            runtimeKind: .gmail, draftsFolderPath: "DRAFT")
        try #require(saved == .completed, "precondition: the upload made a clean Gmail draft")
        let upload = try #require(http.recordedCalls().last { $0.method == "POST" && $0.url.hasSuffix("/drafts") })
        let uploadBody = try #require(upload.body)
        let json = try #require(try JSONSerialization.jsonObject(with: uploadBody) as? [String: Any])
        let encoded = try #require((json["message"] as? [String: Any])?["raw"] as? String)
        var base64 = encoded.replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
        base64 += String(repeating: "=", count: (4 - base64.count % 4) % 4)
        let rawData = try #require(Data(base64Encoded: base64))
        let raw = String(decoding: rawData, as: UTF8.self)
        let draft = try #require(try await pool.read { try Draft.fetchOne($0, key: draftId) })
        return (draft, raw)
    }

    @Test("A Gmail reply draft TabMail uploads names its parent as Send will; a forward names none",
          arguments: [false, true])
    func gmailReplyUploadNamesItsParent(isForward: Bool) async throws {
        try await withInstalledPool { pool in
            let http = FakeHTTP.Scenario()
            defer { http.close() }
            let (draft, raw) = try await pushTabMailGmailDraft(pool, http: http, isForward: isForward)
            let headerLines = raw.components(separatedBy: "\r\n\r\n").first?.components(separatedBy: "\r\n") ?? []
            if isForward {
                #expect(!headerLines.contains { $0.hasPrefix("In-Reply-To:") || $0.hasPrefix("References:") })
                #expect(draft.serverCopyNamesParent == false)
                return
            }
            #expect(headerLines.contains("In-Reply-To: <old-parent@example.com>"))
            #expect(headerLines.contains("References: <old-parent@example.com>"))
            #expect(try await sentParent(pool, draftId: draft.id) == "old-parent@example.com",
                    "the upload names the parent Send replies to")
            #expect(draft.serverCopyNamesParent == true)
        }
    }

    enum StandaloneReplacementCase: String, CaseIterable, Sendable {
        /// TabMail uploaded the reply, naming its parent; the copy now names none.
        case tabMailUpload
        /// The adopted copy named the parent; the copy now names none.
        case adoptedReply
        /// A row from before the record existed: nothing says what the copy named.
        case rowWithoutRecord
        /// The adopted copy named no parent either: nothing changed.
        case adoptedCopyNamedNone
    }

    @Test("A Gmail reload never keeps the old reply parent under another app's standalone message",
          arguments: StandaloneReplacementCase.allCases)
    func gmailReloadOfAReplyReplacedByAStandaloneMessage(_ scenario: StandaloneReplacementCase) async throws {
        try await withInstalledPool { pool in
            let http = FakeHTTP.Scenario()
            defer { http.close() }
            let existing: Draft
            switch scenario {
            case .tabMailUpload, .rowWithoutRecord:
                existing = try await pushTabMailGmailDraft(pool, http: http).draft
                if scenario == .rowWithoutRecord {
                    try await pool.write { db in
                        try db.execute(sql: "UPDATE draft SET serverCopyNamesParent = NULL WHERE id = ?",
                                       arguments: [existing.id])
                    }
                }
            case .adoptedReply, .adoptedCopyNamedNone:
                _ = try await pool.write {
                    try self.insertReplyFixture(
                        $0, adopted: true,
                        copyInReplyTo: scenario == .adoptedReply ? "<old-parent@example.com>" : nil)
                }
                existing = try #require(try await pool.read { try Draft.fetchOne($0) })
            }
            try #require(try await sentParent(pool, draftId: existing.id) == "old-parent@example.com",
                         "fixture: a reply to old-parent")
            try registerReplacedGmailDraft(http, parent: nil)
            let provider = GmailProvider(userEmail: "owner@example.com", accessToken: { _ in "token" }, session: http.session)
            try await withRegisteredProvider(provider) {
                let check = await ExternalDraftAdoption.refreshBeforeOpen(draftId: existing.id, willReadServer: {})
                try #require(http.recordedCalls().contains { $0.url.contains("/messages/m-new") }, "precondition: the new copy was read")
                let row = try await pool.read { try Draft.fetchOne($0, key: existing.id) }
                switch scenario {
                case .tabMailUpload, .adoptedReply:
                    #expect(check == .replacedElsewhere)
                    #expect(row == nil, "the standalone message would be sent as a reply to old-parent")
                case .rowWithoutRecord, .adoptedCopyNamedNone:
                    // Nothing says the copy ever named a parent: an ordinary reload.
                    #expect(check == .open)
                    #expect(row?.body == "new reply text")
                    #expect(row?.serverCopyNamesParent == false, "the record follows the copy just read")
                }
            }
        }
    }

    enum MovedParentCase: String, CaseIterable, Sendable {
        /// The parent moved; the copy still replies to it: an ordinary reload.
        case movedSameParent
        /// The parent moved; the copy replies to another message.
        case movedOtherParent
        /// No local row holds the parent any more; the copy names one.
        case parentGone
    }

    @Test("A Gmail reload compares the parent Send would use: one that moved is still found, and one that is gone is not taken as agreement",
          arguments: MovedParentCase.allCases)
    func gmailReloadComparesTheParentSendUses(_ scenario: MovedParentCase) async throws {
        try await withInstalledPool { pool in
            try await pool.write { db in
                _ = try self.insertReplyFixture(db, adopted: false)
                _ = try Draft.deleteAll(db)
            }
            // A reply to a message in another (IMAP) account, saved from the Gmail
            // account: the key and stamps name the source account's parent.
            let sourceAccountId = "acc-217-source-imap"
            let draftId = "reply:\(sourceAccountId):old-parent@example.com"
            let oldParentId: String = try await pool.write { db in
                var source = Account(emailAddress: "source@example.com", displayName: "Source", provider: .imap)
                source.id = sourceAccountId
                try source.insert(db)
                var inbox = Folder(name: "Inbox", path: "INBOX", role: .inbox, accountId: source.id)
                inbox.lastKnownUidValidity = 5
                try inbox.insert(db)
                var parent = MessageHeader(
                    messageId: "42", subject: "old parent", from: "sender@example.com", fromAddress: "sender@example.com",
                    to: "source@example.com", date: Date(), snippet: "", folderId: inbox.id,
                    accountId: source.id, folderPath: inbox.path, isInInbox: true)
                parent.rfc822MessageId = "old-parent@example.com"
                parent.observedUidValidity = 5
                try parent.insert(db)
                var draft = Draft(
                    id: draftId, accountId: Self.accountId, toJSON: "[]", ccJSON: "[]", bccJSON: "[]",
                    subject: "old draft", body: "old body", replyToId: parent.id, isForward: false,
                    editHistoryJSON: nil, createdAt: 1, updatedAt: 2, serverDraftId: nil,
                    serverPushStatus: nil, rfc822MessageId: nil, attachmentsDirName: nil)
                draft.instanceEpoch = "cross-account-E1"
                draft.replyToProviderMessageId = parent.messageId
                draft.replyToUidValidity = parent.observedUidValidity
                try DraftStore.applySave(draft, db: db)
                return parent.id
            }
            let saved = try await DraftStore.shared.pushDraftToServer(
                draftId: draftId, expectedInstanceEpoch: "cross-account-E1",
                provider: MockEmailProvider(saveDraftResult: .created(.gmail(resourceId: "r1", containedMessageId: "m-old"))),
                runtimeKind: .gmail, draftsFolderPath: "DRAFT")
            try #require(saved == .completed, "precondition: the push made a clean Gmail draft")
            let existing = try #require(try await pool.read { try Draft.fetchOne($0, key: draftId) })
            try #require(existing.serverPushStatus == "pushed" && existing.serverDraftId == "r1")
            try await pool.write { db in
                let old = try #require(try MessageHeader.fetchOne(db, key: oldParentId))
                _ = try old.delete(db)
                guard scenario != .parentGone else { return }
                // Archived: sync replaces the old row with one under a new key.
                var archive = Folder(name: "Archive", path: "Archive", role: .archive, accountId: sourceAccountId)
                archive.lastKnownUidValidity = 9
                try archive.insert(db)
                var moved = MessageHeader(
                    messageId: "3", subject: "old parent", from: "sender@example.com", fromAddress: "sender@example.com",
                    to: "source@example.com", date: Date(), snippet: "", folderId: archive.id,
                    accountId: sourceAccountId, folderPath: archive.path, isInInbox: false)
                moved.rfc822MessageId = "old-parent@example.com"
                moved.observedUidValidity = 9
                try moved.insert(db)
            }
            if scenario != .parentGone {
                try #require(try await sentParent(pool, draftId: existing.id)?.contains("old-parent") == true,
                             "precondition: Send resolves the archived parent")
            }
            let http = FakeHTTP.Scenario()
            defer { http.close() }
            try registerReplacedGmailDraft(
                http, parent: scenario == .movedSameParent ? "old-parent@example.com" : "new-parent@example.com")
            let provider = GmailProvider(userEmail: "owner@example.com", accessToken: { _ in "token" }, session: http.session)
            try await withRegisteredProvider(provider) {
                let check = await ExternalDraftAdoption.refreshBeforeOpen(draftId: existing.id, willReadServer: {})
                try #require(http.recordedCalls().contains { $0.url.contains("/messages/m-new") }, "precondition: the new copy was read")
                #expect(http.recordedCalls().allSatisfy { $0.method == "GET" }, "opening never writes the server")
                let row = try await pool.read { try Draft.fetchOne($0, key: existing.id) }
                if scenario == .movedSameParent {
                    #expect(check == .open)
                    #expect(row?.body == "new reply text", "the same parent is an ordinary reload")
                    #expect(try await sentParent(pool, draftId: existing.id)?.contains("old-parent") == true)
                    return
                }
                #expect(check == .replacedElsewhere)
                #expect(row == nil, "new-parent's text would be kept under old-parent's claim")
            }
        }
    }

    // MARK: - Every body piece and every image

    @Test("A Gmail draft keeps both body pieces around an inline image, in order", arguments: ["text/plain", "text/html"])
    func gmailSplitBodyKeepsBothPieces(mime: String) async throws {
        let http = FakeHTTP.Scenario()
        defer { http.close() }
        http.register(path: "/drafts/r1", method: "GET", response: .json(raw: #"{"message":{"id":"m1"}}"#))
        let payload: [String: Any] = [
            "id": "m1", "internalDate": String(Int(Date().timeIntervalSince1970 * 1000)), "labelIds": ["DRAFT"],
            "payload": ["mimeType": "multipart/mixed", "parts": [
                ["mimeType": mime, "body": ["size": 7, "data": Self.base64URL(Data("before\n".utf8))]],
                ["mimeType": "image/png", "headers": [["name": "Content-ID", "value": "<image>"]],
                 "body": ["size": 2, "data": Self.base64URL(Data([4, 5]))]],
                ["mimeType": mime, "body": ["size": 5, "data": Self.base64URL(Data("after".utf8))]],
            ] as [[String: Any]]] as [String: Any],
        ]
        http.register(path: "/messages/m1", method: "GET", response: .json(
            raw: String(decoding: try JSONSerialization.data(withJSONObject: payload), as: UTF8.self)))
        let provider = GmailProvider(userEmail: "owner@example.com", accessToken: { _ in "token" }, session: http.session)

        let copy = try #require(try await provider.fetchDraftCopy(identity: .gmail(resourceId: "r1")))

        #expect((mime == "text/plain" ? copy.textBody : copy.htmlBody) == "before\nafter")
        #expect(copy.inlineImages.map(\.data) == [Data([4, 5])])
    }

    // MARK: - Multipart grouping (#272)

    /// A Gmail draft body shape and the one body it opens as.
    struct GroupingCase: CustomTestStringConvertible, Sendable {
        let name: String
        let mimeType: String
        /// The root multipart's parts.
        let parts: [GroupingPart]
        let body: String
        var testDescription: String { name }
    }

    indirect enum GroupingPart: Sendable {
        case leaf(mimeType: String, contentType: String, text: String)
        case multipart(mimeType: String, parts: [GroupingPart])

        nonisolated var json: [String: Any] {
            switch self {
            case .leaf(let mimeType, let contentType, let text):
                let data = Data(text.utf8)
                return ["mimeType": mimeType, "headers": [["name": "Content-Type", "value": contentType]],
                        "body": ["size": data.count, "data": DraftCopyIntegrityTests.base64URL(data)]]
            case .multipart(let mimeType, let parts):
                return ["mimeType": mimeType, "parts": parts.map(\.json)]
            }
        }
    }

    nonisolated static let groupingCases: [GroupingCase] = [
        GroupingCase(
            name: "two plain-text alternatives read once", mimeType: "multipart/alternative",
            parts: [.leaf(mimeType: "text/plain", contentType: "text/plain; charset=utf-8", text: "Hello there"),
                    .leaf(mimeType: "text/plain", contentType: "text/plain; charset=utf-8; format=flowed",
                          text: "Hello \r\nthere")],
            body: "Hello there"),
        GroupingCase(
            name: "a plain-text and an HTML alternative read once (control)", mimeType: "multipart/alternative",
            parts: [.leaf(mimeType: "text/plain", contentType: "text/plain; charset=utf-8", text: "Plain version"),
                    .leaf(mimeType: "text/html", contentType: "text/html; charset=utf-8", text: "<p>HTML version</p>")],
            body: "HTML version"),
        GroupingCase(
            name: "mixed plain-text and HTML pieces both read, in order", mimeType: "multipart/mixed",
            parts: [.leaf(mimeType: "text/plain", contentType: "text/plain; charset=utf-8", text: "Plain piece"),
                    .leaf(mimeType: "text/html", contentType: "text/html; charset=utf-8", text: "<p>HTML piece</p>")],
            body: "Plain piece\nHTML piece"),
        GroupingCase(
            name: "an alternative inside a mixed body reads once, before the next piece", mimeType: "multipart/mixed",
            parts: [.multipart(mimeType: "multipart/alternative", parts: [
                        .leaf(mimeType: "text/plain", contentType: "text/plain; charset=utf-8", text: "Top"),
                        .leaf(mimeType: "text/html", contentType: "text/html; charset=utf-8", text: "<b>Top</b>")]),
                    .leaf(mimeType: "text/plain", contentType: "text/plain; charset=utf-8", text: "Bottom")],
            body: "Top\nBottom"),
        GroupingCase(
            name: "an empty last alternative is the body", mimeType: "multipart/alternative",
            parts: [.leaf(mimeType: "text/plain", contentType: "text/plain", text: "obsolete"),
                    .leaf(mimeType: "text/html", contentType: "text/html", text: "")],
            body: ""),
        GroupingCase(
            name: "a trailing attached message does not displace the body", mimeType: "multipart/alternative",
            parts: [.leaf(mimeType: "text/plain", contentType: "text/plain", text: "selected"),
                    .leaf(mimeType: "message/rfc822", contentType: "message/rfc822", text: "file")],
            body: "selected"),
        GroupingCase(
            name: "a trailing file does not displace the body", mimeType: "multipart/alternative",
            parts: [.leaf(mimeType: "text/plain", contentType: "text/plain", text: "selected"),
                    .leaf(mimeType: "application/octet-stream", contentType: "application/octet-stream", text: "file")],
            body: "selected"),
        GroupingCase(
            name: "the last alternative is a related body", mimeType: "multipart/alternative",
            parts: [.leaf(mimeType: "text/plain", contentType: "text/plain", text: "obsolete"),
                    .multipart(mimeType: "multipart/related", parts: [
                        .leaf(mimeType: "text/html", contentType: "text/html", text: "<b>selected</b>")])],
            body: "selected"),
        GroupingCase(
            name: "an alternative inside an unread alternative stays unread", mimeType: "multipart/alternative",
            parts: [.multipart(mimeType: "multipart/alternative", parts: [
                        .leaf(mimeType: "text/plain", contentType: "text/plain", text: "obsolete plain"),
                        .leaf(mimeType: "text/html", contentType: "text/html", text: "<b>obsolete HTML</b>")]),
                    .leaf(mimeType: "text/plain", contentType: "text/plain", text: "selected")],
            body: "selected"),
        GroupingCase(
            name: "a plain piece next to an HTML piece stays literal", mimeType: "multipart/mixed",
            parts: [.leaf(mimeType: "text/plain", contentType: "text/plain", text: "<b>literal</b> &amp;"),
                    .leaf(mimeType: "text/html", contentType: "text/html", text: "<em>rich</em>")],
            body: "<b>literal</b> &amp;\nrich"),
        GroupingCase(
            name: "an HTML piece keeps its spacing", mimeType: "multipart/mixed",
            parts: [.leaf(mimeType: "text/plain", contentType: "text/plain", text: "Intro"),
                    .leaf(mimeType: "text/html", contentType: "text/html", text: "<p>A&nbsp; B</p>")],
            body: "Intro\nA  B"),
        GroupingCase(
            name: "a plain piece starting with a line break gets no second one", mimeType: "multipart/mixed",
            parts: [.leaf(mimeType: "text/plain", contentType: "text/plain", text: "Intro"),
                    .leaf(mimeType: "text/plain", contentType: "text/plain", text: "\nNext")],
            body: "Intro\nNext"),
        GroupingCase(
            name: "a piece after HTML starting with a line break gets no second one", mimeType: "multipart/mixed",
            parts: [.leaf(mimeType: "text/html", contentType: "text/html", text: "<b>Intro</b>"),
                    .leaf(mimeType: "text/plain", contentType: "text/plain", text: "\nNext")],
            body: "Intro\nNext"),
    ]

    /// The Gmail draft `r1` at its listed message `m-old`, a reply to `old-parent`,
    /// with the body `grouping` gives.
    private func registerGmailDraft(_ http: FakeHTTP.Scenario, _ grouping: GroupingCase) throws {
        http.register(path: "/drafts", method: "GET", response: .json(raw: #"{"drafts":[{"id":"r1","message":{"id":"m-old"}}]}"#))
        http.register(path: "/drafts/r1", method: "GET", response: .json(raw: #"{"message":{"id":"m-old"}}"#))
        var root = GroupingPart.multipart(mimeType: grouping.mimeType, parts: grouping.parts).json
        root["headers"] = [["name": "Subject", "value": "old draft"],
                           ["name": "From", "value": "owner@example.com"], ["name": "To", "value": "old@example.com"],
                           ["name": "Message-ID", "value": "<old-draft@example.com>"],
                           ["name": "In-Reply-To", "value": "<old-parent@example.com>"]]
        let payload: [String: Any] = [
            "id": "m-old", "internalDate": String(Int(Date().timeIntervalSince1970 * 1000)), "labelIds": ["DRAFT"],
            "payload": root,
        ]
        http.register(path: "/messages/m-old", method: "GET", response: .json(
            raw: String(decoding: try JSONSerialization.data(withJSONObject: payload), as: UTF8.self)))
    }

    @Test("A Gmail draft opens with one body: one alternative, every mixed piece in order (adoption)",
          arguments: groupingCases)
    func gmailAdoptionReadsOneBody(_ grouping: GroupingCase) async throws {
        try await withInstalledPool { pool in
            let header = try await pool.write { try self.insertReplyFixture($0, adopted: false) }
            let http = FakeHTTP.Scenario()
            defer { http.close() }
            try registerGmailDraft(http, grouping)
            let provider = GmailProvider(userEmail: "owner@example.com", accessToken: { _ in "token" }, session: http.session)
            try await withRegisteredProvider(provider) {
                let authority = try #require(try await ServerDraftComposeLoader.resolveOpenAuthority(header: header))
                let row = try await pool.read { try Draft.fetchOne($0, key: authority.draftId) }
                #expect(row?.body == grouping.body)
                #expect(http.recordedCalls().allSatisfy { $0.method == "GET" }, "opening must not change the server")
            }
        }
    }

    @Test("A Gmail draft opens with one body: one alternative, every mixed piece in order (reload)",
          arguments: groupingCases)
    func gmailReloadReadsOneBody(_ grouping: GroupingCase) async throws {
        try await withInstalledPool { pool in
            _ = try await pool.write { try self.insertReplyFixture($0, adopted: true) }
            let existing = try #require(try await pool.read { try Draft.fetchOne($0) })
            #expect(existing.body == "old body", "fixture: an adopted draft")
            let http = FakeHTTP.Scenario()
            defer { http.close() }
            try registerGmailDraft(http, grouping)
            let provider = GmailProvider(userEmail: "owner@example.com", accessToken: { _ in "token" }, session: http.session)
            try await withRegisteredProvider(provider) {
                let check = await ExternalDraftAdoption.refreshBeforeOpen(draftId: existing.id, willReadServer: {})
                #expect(check == .open)
                let row = try await pool.read { try Draft.fetchOne($0, key: existing.id) }
                #expect(row?.body == grouping.body)
                #expect(http.recordedCalls().allSatisfy { $0.method == "GET" }, "opening must not change the server")
            }
        }
    }

    /// A Gmail draft whose first alternative is a related body holding an
    /// image and a file beside an HTML last alternative. The image is read
    /// from `/attachments/image`; the related body's own text is never read.
    private func registerGmailDraftWithFilesInUnreadAlternative(
        _ http: FakeHTTP.Scenario, image: Data, file: Data, imageFails: Bool
    ) throws {
        http.register(path: "/drafts", method: "GET", response: .json(raw: #"{"drafts":[{"id":"r1","message":{"id":"m-old"}}]}"#))
        http.register(path: "/drafts/r1", method: "GET", response: .json(raw: #"{"message":{"id":"m-old"}}"#))
        let selected = Data("<p>selected</p>".utf8)
        let root: [String: Any] = [
            "mimeType": "multipart/alternative",
            "headers": [["name": "Subject", "value": "old draft"], ["name": "From", "value": "owner@example.com"],
                        ["name": "To", "value": "old@example.com"], ["name": "Message-ID", "value": "<old-draft@example.com>"],
                        ["name": "In-Reply-To", "value": "<old-parent@example.com>"]],
            "parts": [
                ["mimeType": "multipart/related", "parts": [
                    ["mimeType": "text/plain", "body": ["size": 9, "attachmentId": "unread-body"]],
                    ["mimeType": "image/png", "headers": [["name": "Content-ID", "value": "<old-image>"]],
                     "body": ["size": image.count, "attachmentId": "image"]],
                    ["mimeType": "text/plain", "filename": "inactive.txt",
                     "headers": [["name": "Content-Disposition", "value": "attachment"]],
                     "body": ["size": file.count, "data": Self.base64URL(file)]],
                ] as [[String: Any]]],
                ["mimeType": "text/html", "body": ["size": selected.count, "data": Self.base64URL(selected)]],
            ] as [[String: Any]],
        ]
        let message: [String: Any] = ["id": "m-old", "internalDate": String(Int(Date().timeIntervalSince1970 * 1000)),
                                      "labelIds": ["DRAFT"], "payload": root]
        http.register(path: "/messages/m-old", method: "GET", response: .json(
            raw: String(decoding: try JSONSerialization.data(withJSONObject: message), as: UTF8.self)))
        http.register(path: "/messages/m-old/attachments/image", method: "GET", response: imageFails
            ? .status(500) : .json(raw: "{\"size\":\(image.count),\"data\":\"\(Self.base64URL(image))\"}"))
        http.register(path: "/messages/m-old/attachments/unread-body", method: "GET", response: .status(500))
    }

    @Test("A Gmail draft carries the files and images of an alternative it does not read",
          arguments: [false, true])
    func gmailUnreadAlternativeKeepsItsFiles(adopted: Bool) async throws {
        let image = Data([4, 5, 6])
        let file = Data("FILE".utf8)
        try await withInstalledPool { pool in
            let header = try await pool.write { try self.insertReplyFixture($0, adopted: adopted) }
            let http = FakeHTTP.Scenario()
            defer { http.close() }
            try registerGmailDraftWithFilesInUnreadAlternative(http, image: image, file: file, imageFails: false)
            let provider = GmailProvider(userEmail: "owner@example.com", accessToken: { _ in "token" }, session: http.session)
            try await withRegisteredProvider(provider) {
                let draftId: String
                if adopted {
                    let existing = try #require(try await pool.read { try Draft.fetchOne($0) })
                    #expect(await ExternalDraftAdoption.refreshBeforeOpen(draftId: existing.id, willReadServer: {}) == .open)
                    draftId = existing.id
                } else {
                    draftId = try #require(try await ServerDraftComposeLoader.resolveOpenAuthority(header: header)).draftId
                }
                let row = try #require(try await pool.read { try Draft.fetchOne($0, key: draftId) })
                defer { if let dir = row.attachmentsDirName { DraftAttachmentStorage.deleteAttachments(dirName: dir) } }
                #expect(row.body == "selected")
                let files = try DraftAttachmentStorage.loadAttachments(dirName: row.attachmentsDirName)
                #expect(files.map(\.filename) == ["inactive.txt", "image1.png"])
                #expect(files.map(\.data) == [file, image])
                #expect(!http.recordedCalls().contains { $0.url.contains("/attachments/unread-body") },
                        "the unread alternative's text is not fetched")
                #expect(http.recordedCalls().allSatisfy { $0.method == "GET" }, "opening must not change the server")
            }
        }
    }

    @Test("A Gmail reload whose unread alternative's image fails keeps the old draft whole")
    func gmailUnreadAlternativeImageFailureKeepsTheOldDraft() async throws {
        try await withInstalledPool { pool in
            _ = try await pool.write { try self.insertReplyFixture($0, adopted: true) }
            let existing = try #require(try await pool.read { try Draft.fetchOne($0) })
            let http = FakeHTTP.Scenario()
            defer { http.close() }
            try registerGmailDraftWithFilesInUnreadAlternative(http, image: Data([4, 5, 6]), file: Data("FILE".utf8), imageFails: true)
            let provider = GmailProvider(userEmail: "owner@example.com", accessToken: { _ in "token" }, session: http.session)
            try await withRegisteredProvider(provider) {
                #expect(await ExternalDraftAdoption.refreshBeforeOpen(draftId: existing.id, willReadServer: {}) == .open)
                let row = try #require(try await pool.read { try Draft.fetchOne($0, key: existing.id) })
                #expect(http.recordedCalls().contains { $0.url.contains("/attachments/image") })
                let encoder = JSONEncoder()
                encoder.outputFormatting = .sortedKeys
                #expect(try encoder.encode(row) == encoder.encode(existing), "an incomplete read keeps the old draft row")
                #expect(http.recordedCalls().allSatisfy { $0.method == "GET" }, "opening must not change the server")
            }
        }
    }

    @Test("An IMAP draft keeps both body pieces and every inline image, past the viewer's limit",
          arguments: ["text/plain", "text/html"])
    func imapSplitBodyKeepsEveryPiece(mime: String) throws {
        try #require(SyncConfig.maxInlineImages >= 0 && SyncConfig.maxInlineImages < 128, "keep the fixture small")
        let imageCount = SyncConfig.maxInlineImages + 1
        let imageBytes = (0..<imageCount).map { Data([4, UInt8($0)]) }
        let images = (0..<imageCount).map { index in
            MessagePart(sectionString: String(index + 2), contentType: "image/png",
                        contentId: "<image\(index)>", data: imageBytes[index])
        }
        let info = MessageInfo(sequenceNumber: SequenceNumber(1), subject: "draft", date: Date())
        let full = FullMessageInfo(
            header: MessageHeaderInfo(
                messageId: "5", rfc822MessageId: nil, inReplyTo: nil, references: [], threadId: nil,
                subject: "draft", from: "", fromAddress: "", to: "", cc: "", bcc: "", replyTo: nil, date: Date(),
                snippet: "", isRead: true, isFlagged: false, hasAttachments: false, isReplied: false,
                isForwarded: false, actionTag: nil),
            htmlBody: "render only", textBody: nil)
        let parts = [MessagePart(sectionString: "1", contentType: mime, data: Data("before\n".utf8))] + images
            + [MessagePart(sectionString: String(imageCount + 2), contentType: mime, data: Data("after".utf8))]

        let copy = try IMAPProvider.completeDraftCopy(full, message: SwiftMail.Message(header: info, parts: parts))

        #expect((mime == "text/plain" ? copy.textBody : copy.htmlBody) == "before\nafter")
        #expect(copy.inlineImages.map(\.contentId) == (0..<imageCount).map { "image\($0)" })
        #expect(copy.inlineImages.map(\.data) == imageBytes)
    }

    @Test("An Outlook draft carries every inline image as its own named file, past the viewer's limit")
    func outlookDraftCarriesEveryInlineImage() async throws {
        try #require(SyncConfig.maxInlineImages >= 0 && SyncConfig.maxInlineImages < 128, "keep the fixture small")
        let count = SyncConfig.maxInlineImages + 1
        let expected = (0..<count).map { Data([0x22, UInt8($0)]) }
        try await withInstalledPool { pool in
            let draftId = "adopted:copy-integrity-images"
            try await pool.write { db in
                var account = Account(emailAddress: "owner@example.com", displayName: "Test", provider: .outlook)
                account.id = Self.accountId
                try account.insert(db)
                var draft = Draft(
                    id: draftId, accountId: Self.accountId, toJSON: "[]", ccJSON: "[]", bccJSON: "[]",
                    subject: "draft", body: "local copy", replyToId: nil, isForward: false, editHistoryJSON: nil,
                    createdAt: 1, updatedAt: 2, serverDraftId: "g1", serverPushStatus: "pushed",
                    rfc822MessageId: nil, attachmentsDirName: nil)
                draft.instanceEpoch = "images-E1"
                try draft.insert(db)
            }
            let http = FakeHTTP.Scenario()
            defer { http.close() }
            http.register(path: "/messages/g1", method: "GET", response: .json(raw: """
                {"id":"g1","subject":"draft","from":{"emailAddress":{"address":"owner@example.com"}},\
                "receivedDateTime":"\(ISO8601DateFormatter().string(from: Date()))","isRead":true,\
                "body":{"contentType":"text","content":"draft body"},"hasAttachments":false}
                """))
            let items: [[String: Any]] = (0..<count).map { index in
                ["@odata.type": "#microsoft.graph.fileAttachment", "id": "a\(index)", "name": "image\(index).png",
                 "contentType": "image/png", "isInline": true, "contentId": "pic\(index)", "size": 2]
            }
            http.register(path: "/messages/g1/attachments", method: "GET", response: .json(
                raw: String(decoding: try JSONSerialization.data(withJSONObject: ["value": items]), as: UTF8.self)))
            for index in 0..<count {
                http.register(path: "/messages/g1/attachments/a\(index)", method: "GET",
                              response: .json(raw: "{\"contentBytes\":\"\(expected[index].base64EncodedString())\"}"))
            }
            let provider = ExchangeProvider(userEmail: "owner@example.com", accessToken: { _ in "token" }, session: http.session)
            try await withRegisteredProvider(provider) {
                #expect(await ExternalDraftAdoption.refreshBeforeOpen(draftId: draftId, willReadServer: {}) == .open)
                let row = try #require(try await pool.read { try Draft.fetchOne($0, key: draftId) })
                defer { if let dir = row.attachmentsDirName { DraftAttachmentStorage.deleteAttachments(dirName: dir) } }
                #expect(row.body == "draft body")
                let files = try DraftAttachmentStorage.loadAttachments(dirName: row.attachmentsDirName)
                let byName = Dictionary(files.map { ($0.filename, $0.data) }, uniquingKeysWith: { first, _ in first })
                #expect(files.count == count, "an image was lost or duplicated")
                #expect(byName == Dictionary(uniqueKeysWithValues: (0..<count).map { ("image\($0).png", expected[$0]) }),
                        "an image lost its name or its bytes")
            }
        }
    }

    // MARK: - Inline image names

    // Bounded: three fixed cycles, two-byte files, at most eight server files.
    @Test("An Outlook inline image keeps its name across saves, and one TabMail cannot store refuses the draft",
          arguments: ["logo.png", "bad/name.png"])
    func outlookInlineImageNameNeverMultipliesFiles(filename: String) async throws {
        struct File: Sendable {
            let id: String
            let name: String
            let inline: Bool
            let bytes: Data
        }
        let safe = AttachmentFilename.isSafeFileComponent(filename)
        #expect(safe == (filename == "logo.png"), "fixture: one storable name and one not")
        try await withInstalledPool { pool in
            let draftId = "adopted:copy-integrity-inline"
            var staged: [String] = []
            defer { for name in staged { DraftAttachmentStorage.deleteAttachments(dirName: name) } }
            try await pool.write { db in
                var account = Account(emailAddress: "owner@example.com", displayName: "Test", provider: .outlook)
                account.id = Self.accountId
                try account.insert(db)
                var draft = Draft(
                    id: draftId, accountId: Self.accountId, toJSON: "[]", ccJSON: "[]", bccJSON: "[]",
                    subject: "draft", body: "local copy", replyToId: nil, isForward: false, editHistoryJSON: nil,
                    createdAt: 1, updatedAt: 2, serverDraftId: "g1", serverPushStatus: "pushed",
                    rfc822MessageId: nil, attachmentsDirName: nil)
                draft.instanceEpoch = "inline-E1"
                try draft.insert(db)
            }
            let bytes = Data([3, 7])
            let files = Mutex<[File]>([File(id: "original", name: filename, inline: true, bytes: bytes)])
            let http = FakeHTTP.Scenario()
            defer { http.close() }
            http.register(path: "/messages/g1", method: "GET", response: .json(raw: """
                {"id":"g1","subject":"draft","from":{"emailAddress":{"address":"owner@example.com"}},\
                "receivedDateTime":"\(ISO8601DateFormatter().string(from: Date()))","isRead":true,\
                "body":{"contentType":"text","content":"server copy"},"toRecipients":[],"hasAttachments":false}
                """))
            http.register(path: "/messages/g1/attachments", method: "GET") { _ in
                let list: [[String: Any]] = files.withLock { state in
                    state.map { file in
                        var entry: [String: Any] = [
                            "@odata.type": "#microsoft.graph.fileAttachment", "id": file.id, "name": file.name,
                            "contentType": "image/png", "size": file.bytes.count, "isInline": file.inline]
                        if file.inline { entry["contentId"] = "logo" }
                        return entry
                    }
                }
                let data = (try? JSONSerialization.data(withJSONObject: ["value": list])) ?? Data()
                return .json(raw: String(decoding: data, as: UTF8.self))
            }
            http.register(path: "/messages/g1/attachments/", method: "GET") { request in
                guard let file = files.withLock({ $0.first { $0.id == request.url.lastPathComponent } }) else {
                    return .status(404)
                }
                return .json(raw: "{\"contentBytes\":\"\(file.bytes.base64EncodedString())\"}")
            }
            http.register(path: "/messages/g1", method: "PATCH", response: .json(raw: #"{"id":"g1"}"#))
            http.register(path: "/messages/g1/attachments", method: "POST") { request in
                guard let body = request.body,
                      let object = try? JSONSerialization.jsonObject(with: body) as? [String: Any],
                      let name = object["name"] as? String, let raw = object["contentBytes"] as? String,
                      let data = Data(base64Encoded: raw), data.count <= 16 else { return .status(400) }
                let id: String? = files.withLock { state in
                    guard state.count < 8 else { return nil }
                    let id = "added-\(state.count)"
                    state.append(File(id: id, name: name, inline: false, bytes: data))
                    return id
                }
                guard let id else { return .status(413) }
                return .json(raw: "{\"id\":\"\(id)\"}")
            }
            http.register(path: "/messages/g1/attachments/", method: "DELETE") { request in
                files.withLock { $0.removeAll { $0.id == request.url.lastPathComponent } }
                return .status(204)
            }
            let provider = ExchangeProvider(userEmail: "owner@example.com", accessToken: { _ in "token" }, session: http.session)
            try await withRegisteredProvider(provider) {
                var localNames: [[String]] = []
                var serverCounts: [Int] = []
                for cycle in 0..<3 {
                    let check = await ExternalDraftAdoption.refreshBeforeOpen(draftId: draftId, willReadServer: {})
                    let row = try #require(try await pool.read { try Draft.fetchOne($0, key: draftId) })
                    if !safe {
                        #expect(cycle == 0 && check == .unsupportedAttachment, "the name refusal covers inline images")
                        #expect(row.body == "local copy" && row.attachmentsDirName == nil)
                        #expect(files.withLock { $0.count } == 1)
                        #expect(http.recordedCalls().allSatisfy { $0.method == "GET" })
                        return
                    }
                    #expect(check == .open)
                    if let name = row.attachmentsDirName { staged.append(name) }
                    let attachments = try DraftAttachmentStorage.loadAttachments(dirName: row.attachmentsDirName)
                    #expect(attachments.allSatisfy { $0.data == bytes })
                    localNames.append(attachments.map(\.filename))
                    _ = try await provider.saveDraft(
                        DraftMessage(to: row.toArray, cc: row.ccArray, bcc: row.bccArray, subject: row.subject,
                                     body: row.body, isHTML: false, inReplyTo: nil, attachments: attachments),
                        existingIdentity: .outlook(graphId: "g1"), draftsFolderPath: "Drafts")
                    serverCounts.append(files.withLock { $0.count })
                }
                #expect(localNames == [[filename], [filename], [filename]], "a read-save cycle renamed or added a file")
                #expect(serverCounts == [1, 1, 1], "a read-save cycle added a server file")
            }
        }
    }

    // MARK: - A failed write leaves nothing behind

    @Test("A database failure after staging keeps the old row and its files and leaves no new files",
          arguments: ["adopt", "reload"])
    func databaseFailureLeavesNoStagedFiles(mode: String) async throws {
        try await withInstalledPool { pool in
            let filename = "staged-\(UUID().uuidString).txt"
            let oldDirectory = DraftAttachmentStorage.newStagingDirName()
            defer { DraftAttachmentStorage.deleteAttachments(dirName: oldDirectory) }
            let draftId = "adopted:copy-integrity-cleanup"
            let header = try await pool.write { db -> MessageHeader in
                var account = Account(emailAddress: "owner@example.com", displayName: "Test",
                                      provider: mode == "adopt" ? .imap : .outlook)
                account.id = Self.accountId
                try account.insert(db)
                var folder = Folder(name: "Drafts", path: "Drafts", role: .drafts, accountId: Self.accountId)
                folder.lastKnownUidValidity = 900_001
                try folder.insert(db)
                var header = MessageHeader(
                    messageId: "7", subject: "old", from: "owner@example.com", fromAddress: "owner@example.com",
                    to: "recipient@example.com", date: Date(), snippet: "", folderId: folder.id,
                    accountId: Self.accountId, folderPath: "Drafts", isInInbox: false)
                header.observedUidValidity = 900_001
                try header.insert(db)
                if mode == "reload" {
                    var draft = Draft(
                        id: draftId, accountId: Self.accountId, toJSON: "[]", ccJSON: "[]", bccJSON: "[]",
                        subject: "old", body: "local body", replyToId: nil, isForward: false, editHistoryJSON: nil,
                        createdAt: 1, updatedAt: 2, serverDraftId: "g1", serverPushStatus: "pushed",
                        rfc822MessageId: nil, attachmentsDirName: oldDirectory)
                    draft.instanceEpoch = "cleanup-E1"
                    try draft.insert(db)
                }
                let operation = mode == "adopt" ? "INSERT" : "UPDATE"
                try db.execute(sql: """
                    CREATE TRIGGER copy_integrity_abort BEFORE \(operation) ON draft
                    BEGIN SELECT RAISE(ABORT, 'synthetic database failure'); END
                    """)
                return header
            }
            if mode == "reload" {
                try DraftAttachmentStorage.saveAttachments(
                    [DraftAttachment(filename: "old.txt", mimeType: "text/plain", data: Data("old bytes".utf8))],
                    dirName: oldDirectory)
            }
            let http = FakeHTTP.Scenario()
            defer { http.close() }
            let mock = MockEmailProvider()
            let provider: any EmailProvider
            if mode == "adopt" {
                await mock.setDraftCopy(.success(MockEmailProvider.draftCopy(
                    subject: "server", to: ["recipient@example.com"], cc: [], html: "<p>body</p>",
                    attachmentNames: [filename], attachmentData: ["mock-att-0": Data("xyz".utf8)])))
                provider = mock
            } else {
                http.register(path: "/messages/g1", method: "GET", response: .json(raw: """
                    {"id":"g1","subject":"server","from":{"emailAddress":{"address":"owner@example.com"}},\
                    "receivedDateTime":"\(ISO8601DateFormatter().string(from: Date()))","isRead":true,\
                    "body":{"contentType":"text","content":"server body"},"toRecipients":[],"hasAttachments":true}
                    """))
                let list: [String: Any] = ["value": [[
                    "@odata.type": "#microsoft.graph.fileAttachment", "id": "a1", "name": filename,
                    "contentType": "text/plain", "size": 3, "isInline": false]]]
                http.register(path: "/messages/g1/attachments", method: "GET", response: .json(
                    raw: String(decoding: try JSONSerialization.data(withJSONObject: list), as: UTF8.self)))
                http.register(path: "/messages/g1/attachments/a1", method: "GET", response: .json(raw: #"{"contentBytes":"eHl6"}"#))
                provider = ExchangeProvider(userEmail: "owner@example.com", accessToken: { _ in "token" }, session: http.session)
            }
            try await withRegisteredProvider(provider) {
                if mode == "adopt" {
                    do {
                        try await ExternalDraftAdoption.adopt(
                            header: header, address: .imap(folderPath: "Drafts", uidValidity: 900_001, uid: "7"),
                            runtimeKind: .imap)
                        Issue.record("fixture: the trigger must reject the insert")
                    } catch {
                        #expect(String(describing: error).contains("synthetic database failure"))
                    }
                    #expect(await mock.fetchDraftCopyLog.count == 1, "precondition: the copy was read and staged")
                    #expect(try await pool.read { try Draft.fetchCount($0) } == 0)
                } else {
                    #expect(await ExternalDraftAdoption.refreshBeforeOpen(draftId: draftId, willReadServer: {}) == .open)
                    let row = try #require(try await pool.read { try Draft.fetchOne($0, key: draftId) })
                    #expect(row.body == "local body" && row.attachmentsDirName == oldDirectory && row.pushAttemptVersion == 0)
                    #expect(try DraftAttachmentStorage.loadAttachments(dirName: oldDirectory).first?.data == Data("old bytes".utf8))
                    #expect(http.recordedCalls().contains { $0.url.contains("/attachments/a1") },
                            "precondition: the file was downloaded and staged")
                    #expect(http.recordedCalls().allSatisfy { $0.method == "GET" }, "opening must not change the server")
                }
            }
            var leftovers: [URL] = []
            let enumerator = FileManager.default.enumerator(at: DraftAttachmentStorage.baseDir, includingPropertiesForKeys: nil)
            while let url = enumerator?.nextObject() as? URL {
                if url.lastPathComponent.hasSuffix("_" + filename) { leftovers.append(url) }
            }
            #expect(leftovers.isEmpty, "a rejected database write left the staged files behind")
            for url in leftovers { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        }
    }

    // MARK: - Flowed markers are ASCII

    @Test("Flowed quote marks and stuffing are read as ASCII, even before a combining mark",
          arguments: [">\u{0301} a \n> b", "> \u{0301} a \n> b"])
    func flowedMarkersAreASCII(encoded: String) {
        let type = "text/plain; charset=utf-8; format=flowed"
        let reference = EmailFilter.decodeFormatFlowed(">X a \n> b", contentType: type)
        #expect(reference == "> X a b", "fixture: a flowed quoted paragraph")
        #expect(EmailFilter.decodeFormatFlowed(encoded, contentType: type)
                == reference.replacingOccurrences(of: "X", with: "\u{0301}"))
    }

    @Test("A flowed soft break is read as a scalar space, even after a Prepend scalar",
          arguments: [("text/plain; format=flowed", "a\u{0605} b"), ("text/plain; format=flowed; delsp=yes", "a\u{0605}b")])
    func flowedSpaceAfterAPrependScalar(contentType: String, decoded: String) {
        #expect(EmailFilter.decodeFormatFlowed("a\u{0605} \nb", contentType: contentType) == decoded)
        #expect(EmailFilter.decodeFormatFlowed("a \nb", contentType: contentType)
                == decoded.replacingOccurrences(of: "\u{0605}", with: ""), "control: the ASCII form joins the same way")
    }

    // MARK: - Shortened parts

    /// An IMAP draft whose one text part BODYSTRUCTURE declares `declaredSize` octets
    /// and whose part fetch returns the 4 bytes "body".
    private func imapCopy(declaredSize: Int) async throws -> FullMessageInfo {
        let delivered = Data("body".utf8)
        let stored = declaredSize == delivered.count ? delivered : Data("body and tail!".utf8)
        try #require(stored.count == declaredSize, "fixture: the server holds the declared bytes")
        return try await imapCopy(
            bodystructure: "(\"TEXT\" \"PLAIN\" (\"CHARSET\" \"UTF-8\") NIL NIL \"7BIT\" \(declaredSize) 1)",
            contentType: "text/plain; charset=UTF-8", body: stored, partBodies: ["1": delivered])
    }

    /// An IMAP draft read through the fake server: `bodystructure` is sent as written,
    /// `body` is the stored message body, and `partBodies` answer each part fetch.
    private func imapCopy(bodystructure: String, contentType: String, body: Data,
                          partBodies: [String: Data]) async throws -> FullMessageInfo {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(identifier: "UTC")
        formatter.dateFormat = "EEE, dd MMM yyyy HH:mm:ss Z"
        let date = formatter.string(from: Date())
        formatter.dateFormat = "dd-MMM-yyyy HH:mm:ss Z"
        let internalDate = formatter.string(from: Date())
        let header = "From: Sender <sender@example.com>\r\nTo: Recipient <recipient@example.com>\r\nSubject: draft\r\nDate: \(date)\r\nMessage-ID: <short-part@example.com>\r\nContent-Type: \(contentType)\r\n\r\n"
        let message = FakeIMAPServer.makeMultipartMessage(
            uid: 5, subject: "draft", from: "Sender <sender@example.com>",
            to: "Recipient <recipient@example.com>", date: date, internalDate: internalDate,
            messageID: "<short-part@example.com>", rawHeader: header, fullMessage: Data(header.utf8) + body,
            bodystructure: bodystructure, partBodies: partBodies)
        let server = FakeIMAPServer(mailboxes: ["Drafts": [message]])
        server.setUidValidity(73099, for: "Drafts")
        try server.start()
        defer { server.stop() }
        let provider = IMAPProvider(host: "127.0.0.1", port: server.port,
            username: server.username, password: server.password,
            smtpHost: "127.0.0.1", smtpPort: 587, useTLS: false)
        try await provider.connect()
        do {
            let copy = try #require(try await provider.fetchDraftCopy(
                identity: .imap(folder: "Drafts", uidValidity: 73099, uid: 5)))
            try await provider.disconnect()
            return copy
        } catch {
            try? await provider.disconnect()
            throw error
        }
    }

    // MARK: - Text parts with a Content-ID (#276)

    @Test("An IMAP draft's text body with a Content-ID opens as its body, not as a file")
    func imapTextBodyWithContentIdIsTheBody() async throws {
        // Python's EmailMessage.set_content(..., cid=...) writes a plain-text body
        // with a Content-ID and no filename.
        let text = Data("Hello from the draft".utf8)
        let copy = try await imapCopy(
            bodystructure: "(\"TEXT\" \"PLAIN\" (\"CHARSET\" \"UTF-8\") \"<body@example.com>\" NIL \"7BIT\" \(text.count) 1)",
            contentType: "text/plain; charset=UTF-8", body: text, partBodies: ["1": text])
        #expect(copy.textBody == "Hello from the draft")
        #expect(copy.attachments.isEmpty)
        #expect((copy.attachmentData ?? [:]).isEmpty)
    }

    /// The HTML root's extension fields after its line count: none, or an
    /// inline disposition as some clients write it.
    nonisolated static let relatedRootExtensions = ["", " NIL (\"INLINE\" NIL) NIL NIL"]

    @Test("A multipart/related draft's HTML root with a Content-ID is the body; its image stays an inline image",
          arguments: relatedRootExtensions)
    func imapRelatedRootWithContentIdIsTheBody(rootExtension: String) async throws {
        let html = Data("<p>Hello</p>".utf8)
        let png = Data([0x89, 0x50, 0x4E, 0x47])
        let pngBase64 = Data(png.base64EncodedString().utf8)
        let copy = try await imapCopy(
            bodystructure: "((\"TEXT\" \"HTML\" (\"CHARSET\" \"UTF-8\") \"<root@example.com>\" NIL \"7BIT\" \(html.count) 1\(rootExtension))"
                + "(\"IMAGE\" \"PNG\" NIL \"<logo@example.com>\" NIL \"BASE64\" \(pngBase64.count) NIL (\"INLINE\" NIL) NIL NIL) \"RELATED\")",
            contentType: "multipart/related; boundary=b", body: html + pngBase64,
            partBodies: ["1": html, "2": pngBase64])
        #expect(copy.htmlBody == "<p>Hello</p>")
        #expect(copy.attachments.isEmpty)
        #expect(copy.inlineImages.map(\.contentId) == ["logo@example.com"])
        #expect(copy.inlineImages.first?.data == png)
    }

    // MARK: - RFC 2231 extended parameters (#277)

    /// GBK bytes for 中文.
    private nonisolated static let gbk = Data([0xD6, 0xD0, 0xCE, 0xC4])

    /// `bytes` as a base64 transfer-encoded part, which keeps a non-UTF-8 body
    /// ASCII on the fake server's wire.
    private static func base64Part(_ bytes: Data) -> Data {
        Data(bytes.base64EncodedString().utf8)
    }

    @Test("An IMAP draft's charset or format written in RFC 2231 extended form is read", arguments: [
        ("(\"CHARSET*\" \"utf-8''gbk\")", gbk, "中文"),
        ("(\"CHARSET*0*\" \"utf-8''g\" \"CHARSET*1\" \"bk\")", gbk, "中文"),
        ("(\"CHARSET\" \"UTF-8\" \"FORMAT*\" \"utf-8''flowed\")", Data("Hello \r\nthere".utf8), "Hello there"),
        ("(\"CHARSET*0\" \"g\" \"CHARSET*1\" \"bk\")", gbk, "中文"),
        ("(\"CHARSET\" \"UTF-8\" \"FORMAT*0\" \"flo\" \"FORMAT*1\" \"wed\")", Data("Hello \r\nthere".utf8), "Hello there"),
    ])
    func imapExtendedParametersAreRead(parameters: String, bytes: Data, text: String) async throws {
        let wire = Self.base64Part(bytes)
        let copy = try await imapCopy(
            bodystructure: "(\"TEXT\" \"PLAIN\" \(parameters) NIL NIL \"BASE64\" \(wire.count) 1)",
            contentType: "text/plain", body: wire, partBodies: ["1": wire])
        #expect(copy.textBody == text)
    }

    @Test("An IMAP draft whose extended charset no platform resolves is refused, never read as a guess")
    func imapUnknownExtendedCharsetIsRefused() async throws {
        let wire = Self.base64Part(Self.gbk)
        await #expect(throws: IMAPProvider.IMAPDraftCopyIncomplete.self) {
            _ = try await self.imapCopy(
                bodystructure: "(\"TEXT\" \"PLAIN\" (\"CHARSET*\" \"utf-8''x-unknown-label\") NIL NIL \"BASE64\" \(wire.count) 1)",
                contentType: "text/plain", body: wire, partBodies: ["1": wire])
        }
    }

    @Test("A Gmail draft's charset written in RFC 2231 extended form is read", arguments: [
        "text/plain; charset*=utf-8''gbk",
        "text/plain; charset*0=g; charset*1=bk",
    ])
    func gmailExtendedCharsetIsRead(contentType: String) async throws {
        let http = FakeHTTP.Scenario()
        defer { http.close() }
        http.register(path: "/drafts/r1", method: "GET", response: .json(raw: #"{"message":{"id":"m1"}}"#))
        let payload: [String: Any] = [
            "id": "m1", "internalDate": String(Int(Date().timeIntervalSince1970 * 1000)), "labelIds": ["DRAFT"],
            "payload": ["mimeType": "text/plain",
                        "headers": [["name": "Content-Type", "value": contentType]],
                        "body": ["size": Self.gbk.count, "data": Self.base64URL(Self.gbk)]] as [String: Any],
        ]
        http.register(path: "/messages/m1", method: "GET", response: .json(
            raw: String(decoding: try JSONSerialization.data(withJSONObject: payload), as: UTF8.self)))
        let provider = GmailProvider(userEmail: "owner@example.com", accessToken: { _ in "token" }, session: http.session)

        let copy = try await provider.fetchDraftCopy(identity: .gmail(resourceId: "r1"))
        #expect(copy?.textBody == "中文")
    }

    // MARK: - IMAP multipart grouping (#272)

    /// An IMAP draft body shape (its BODYSTRUCTURE and part bodies) and the one body
    /// it opens as.
    struct IMAPGroupingCase: CustomTestStringConvertible, Sendable {
        let name: String
        let bodystructure: String
        let contentType: String
        let parts: [String: String]
        let body: String
        /// Whether a non-body part rides along as a file.
        var hasFile = false
        var testDescription: String { name }
    }

    nonisolated static let imapGroupingCases: [IMAPGroupingCase] = {
        func text(_ subtype: String, _ value: String, flowed: Bool = false) -> String {
            let parameters = flowed ? "(\"CHARSET\" \"UTF-8\" \"FORMAT\" \"flowed\")" : "(\"CHARSET\" \"UTF-8\")"
            return "(\"TEXT\" \"\(subtype)\" \(parameters) NIL NIL \"7BIT\" \(Data(value.utf8).count) 1)"
        }
        let attachedMessage = "Subject: inner\r\n\r\nfile"
        let attachedMessagePart = "(\"MESSAGE\" \"RFC822\" NIL NIL NIL \"7BIT\" \(Data(attachedMessage.utf8).count) "
            + "(NIL \"inner\" NIL NIL NIL NIL NIL NIL NIL NIL) \(text("PLAIN", "file")) 1)"
        let filePart = "(\"APPLICATION\" \"OCTET-STREAM\" NIL NIL NIL \"7BIT\" 4)"
        return [
            IMAPGroupingCase(
                name: "two plain-text alternatives read once",
                bodystructure: "(\(text("PLAIN", "Hello there"))\(text("PLAIN", "Hello \r\nthere", flowed: true)) \"ALTERNATIVE\")",
                contentType: "multipart/alternative; boundary=b",
                parts: ["1": "Hello there", "2": "Hello \r\nthere"], body: "Hello there"),
            IMAPGroupingCase(
                name: "a plain-text and an HTML alternative read once (control)",
                bodystructure: "(\(text("PLAIN", "Plain version"))\(text("HTML", "<p>HTML version</p>")) \"ALTERNATIVE\")",
                contentType: "multipart/alternative; boundary=b",
                parts: ["1": "Plain version", "2": "<p>HTML version</p>"], body: "HTML version"),
            IMAPGroupingCase(
                name: "mixed plain-text and HTML pieces both read, in order",
                bodystructure: "(\(text("PLAIN", "Plain piece"))\(text("HTML", "<p>HTML piece</p>")) \"MIXED\")",
                contentType: "multipart/mixed; boundary=b",
                parts: ["1": "Plain piece", "2": "<p>HTML piece</p>"], body: "Plain piece\nHTML piece"),
            IMAPGroupingCase(
                name: "two alternatives in a mixed body each read their own last branch",
                bodystructure: "((\(text("PLAIN", "old first"))\(text("PLAIN", "selected first")) \"ALTERNATIVE\")"
                    + "(\(text("PLAIN", "old second"))\(text("PLAIN", "middle second"))\(text("PLAIN", "selected second")) \"ALTERNATIVE\") \"MIXED\")",
                contentType: "multipart/mixed; boundary=b",
                parts: ["1.1": "old first", "1.2": "selected first", "2.1": "old second",
                        "2.2": "middle second", "2.3": "selected second"], body: "selected first\nselected second"),
            IMAPGroupingCase(
                name: "an alternative inside a mixed body reads once, before the next piece",
                bodystructure: "((\(text("PLAIN", "Top"))\(text("HTML", "<b>Top</b>")) \"ALTERNATIVE\")\(text("PLAIN", "Bottom")) \"MIXED\")",
                contentType: "multipart/mixed; boundary=b",
                parts: ["1.1": "Top", "1.2": "<b>Top</b>", "2": "Bottom"], body: "Top\nBottom"),
            IMAPGroupingCase(
                name: "an empty last alternative is the body",
                bodystructure: "(\(text("PLAIN", "obsolete"))\(text("HTML", "")) \"ALTERNATIVE\")",
                contentType: "multipart/alternative; boundary=b",
                parts: ["1": "obsolete", "2": ""], body: ""),
            IMAPGroupingCase(
                name: "a trailing attached message does not displace the body",
                bodystructure: "(\(text("PLAIN", "selected"))\(attachedMessagePart) \"ALTERNATIVE\")",
                contentType: "multipart/alternative; boundary=b",
                parts: ["1": "selected", "2": attachedMessage, "2.1": "file"], body: "selected", hasFile: true),
            IMAPGroupingCase(
                name: "a trailing file does not displace the body",
                bodystructure: "(\(text("PLAIN", "selected"))\(filePart) \"ALTERNATIVE\")",
                contentType: "multipart/alternative; boundary=b",
                parts: ["1": "selected", "2": "file"], body: "selected", hasFile: true),
            IMAPGroupingCase(
                name: "the last alternative is a related body",
                bodystructure: "(\(text("PLAIN", "obsolete"))(\(text("HTML", "<b>selected</b>")) \"RELATED\") \"ALTERNATIVE\")",
                contentType: "multipart/alternative; boundary=b",
                parts: ["1": "obsolete", "2.1": "<b>selected</b>"], body: "selected"),
            IMAPGroupingCase(
                name: "an alternative inside an unread alternative stays unread",
                bodystructure: "((\(text("PLAIN", "obsolete plain"))\(text("HTML", "<b>obsolete HTML</b>")) \"ALTERNATIVE\")"
                    + "\(text("PLAIN", "selected")) \"ALTERNATIVE\")",
                contentType: "multipart/alternative; boundary=b",
                parts: ["1.1": "obsolete plain", "1.2": "<b>obsolete HTML</b>", "2": "selected"], body: "selected"),
            IMAPGroupingCase(
                name: "a plain piece next to an HTML piece stays literal",
                bodystructure: "(\(text("PLAIN", "<b>literal</b> &amp;"))\(text("HTML", "<em>rich</em>")) \"MIXED\")",
                contentType: "multipart/mixed; boundary=b",
                parts: ["1": "<b>literal</b> &amp;", "2": "<em>rich</em>"], body: "<b>literal</b> &amp;\nrich"),
            IMAPGroupingCase(
                name: "an HTML piece keeps its spacing",
                bodystructure: "(\(text("PLAIN", "Intro"))\(text("HTML", "<p>A&nbsp; B</p>")) \"MIXED\")",
                contentType: "multipart/mixed; boundary=b",
                parts: ["1": "Intro", "2": "<p>A&nbsp; B</p>"], body: "Intro\nA  B"),
            IMAPGroupingCase(
                name: "a plain piece starting with a line break gets no second one",
                bodystructure: "(\(text("PLAIN", "Intro"))\(text("PLAIN", "\nNext")) \"MIXED\")",
                contentType: "multipart/mixed; boundary=b",
                parts: ["1": "Intro", "2": "\nNext"], body: "Intro\nNext"),
            IMAPGroupingCase(
                name: "a piece after HTML starting with a line break gets no second one",
                bodystructure: "(\(text("HTML", "<b>Intro</b>"))\(text("PLAIN", "\nNext")) \"MIXED\")",
                contentType: "multipart/mixed; boundary=b",
                parts: ["1": "<b>Intro</b>", "2": "\nNext"], body: "Intro\nNext"),
        ]
    }()

    @Test("An IMAP draft opens with one body: one alternative, every mixed piece in order",
          arguments: imapGroupingCases)
    func imapDraftReadsOneBody(_ grouping: IMAPGroupingCase) async throws {
        let stored = grouping.parts.keys.sorted().map { Data(grouping.parts[$0]!.utf8) }.reduce(Data(), +)
        let copy = try await imapCopy(
            bodystructure: grouping.bodystructure, contentType: grouping.contentType, body: stored,
            partBodies: grouping.parts.mapValues { Data($0.utf8) })
        // As adoption reads it: a returned body part, even an empty one, is the body.
        let editable = ExternalDraftAdoption.editableBody(
            text: copy.textBody, html: copy.htmlBody,
            bodyEmptyConfirmed: copy.textBody != nil || copy.htmlBody != nil, hasAttachments: false)
        #expect(editable == grouping.body)
        #expect(copy.attachments.isEmpty == !grouping.hasFile)
    }

    /// An IMAP draft whose first alternative is a related body holding text,
    /// an inline image and a file, beside an HTML last alternative. The related
    /// body's text arrives `unreadTextShortBy` bytes short of its declared size,
    /// and the image `imageShortBy` bytes short.
    private func imapCopyWithFilesInUnreadAlternative(
        image: Data, file: Data, unreadTextShortBy: Int, imageShortBy: Int
    ) async throws -> FullMessageInfo {
        let unread = Data("unread body".utf8)
        let selected = Data("<p>selected</p>".utf8)
        let imageWire = Data(image.base64EncodedString().utf8)
        return try await imapCopy(
            bodystructure: "(((\"TEXT\" \"PLAIN\" (\"CHARSET\" \"UTF-8\") NIL NIL \"7BIT\" \(unread.count) 1)"
                + "(\"IMAGE\" \"PNG\" NIL \"<old-image@example.com>\" NIL \"BASE64\" \(imageWire.count) NIL (\"INLINE\" NIL) NIL NIL)"
                + "(\"TEXT\" \"PLAIN\" (\"CHARSET\" \"UTF-8\") NIL NIL \"7BIT\" \(file.count) 1 NIL (\"ATTACHMENT\" (\"FILENAME\" \"inactive.txt\")) NIL NIL)"
                + " \"RELATED\")(\"TEXT\" \"HTML\" (\"CHARSET\" \"UTF-8\") NIL NIL \"7BIT\" \(selected.count) 1) \"ALTERNATIVE\")",
            contentType: "multipart/alternative; boundary=b", body: unread + imageWire + file + selected,
            partBodies: ["1.1": unread.dropLast(unreadTextShortBy), "1.2": imageWire.dropLast(imageShortBy),
                         "1.3": file, "2": selected])
    }

    @Test("An IMAP draft carries the files and images of an alternative it does not read")
    func imapUnreadAlternativeKeepsItsFiles() async throws {
        let image = Data([4, 5, 6])
        let file = Data("FILE".utf8)
        // The unread text arriving short does not matter: it is not read.
        let copy = try await imapCopyWithFilesInUnreadAlternative(image: image, file: file, unreadTextShortBy: 4, imageShortBy: 0)
        let editable = ExternalDraftAdoption.editableBody(
            text: copy.textBody, html: copy.htmlBody, bodyEmptyConfirmed: false, hasAttachments: true)
        #expect(editable == "selected")
        #expect(copy.inlineImages.map(\.contentId) == ["old-image@example.com"])
        #expect(copy.inlineImages.map(\.data) == [image])
        #expect(copy.attachments.map(\.filename) == ["inactive.txt"])
        #expect(copy.attachments.map { copy.attachmentData?[$0.section] } == [file])
    }

    @Test("An IMAP draft whose unread alternative's image arrives short is incomplete, never the draft")
    func imapUnreadAlternativeImageFailureIsIncomplete() async throws {
        await #expect(throws: IMAPProvider.IMAPDraftCopyIncomplete.self) {
            _ = try await self.imapCopyWithFilesInUnreadAlternative(
                image: Data([4, 5, 6]), file: Data("FILE".utf8), unreadTextShortBy: 0, imageShortBy: 2)
        }
    }

    @Test("An IMAP draft part that arrives shorter than BODYSTRUCTURE declares is incomplete, never the draft")
    func imapShortenedPartIsIncomplete() async throws {
        let whole = try await imapCopy(declaredSize: 4)
        #expect(whole.textBody == "body", "control: a part that arrives whole is the draft")
        await #expect(throws: IMAPProvider.IMAPDraftCopyIncomplete.self) {
            _ = try await imapCopy(declaredSize: 14)
        }
    }

    @Test("A Gmail draft part whose data decodes shorter than its size is incomplete, never the draft",
          arguments: [true, false])
    func gmailShortenedPartIsIncomplete(shortened: Bool) async throws {
        let stored = Data("body and tail!".utf8)
        let delivered = shortened ? stored.prefix(4) : stored
        let http = FakeHTTP.Scenario()
        defer { http.close() }
        http.register(path: "/drafts/r1", method: "GET", response: .json(raw: #"{"message":{"id":"m1"}}"#))
        let payload: [String: Any] = [
            "id": "m1", "internalDate": String(Int(Date().timeIntervalSince1970 * 1000)), "labelIds": ["DRAFT"],
            "payload": ["mimeType": "text/plain", "headers": [["name": "Subject", "value": "Short response"]],
                        "body": ["size": stored.count, "data": Self.base64URL(Data(delivered))]] as [String: Any]]
        http.register(path: "/messages/m1", method: "GET", response: .json(raw:
            String(decoding: try JSONSerialization.data(withJSONObject: payload), as: UTF8.self)))
        let provider = GmailProvider(userEmail: "owner@example.com", accessToken: { _ in "token" }, session: http.session)
        if shortened {
            await #expect(throws: GmailDraftCopyIncomplete.self) {
                _ = try await provider.fetchDraftCopy(identity: .gmail(resourceId: "r1"))
            }
        } else {
            let copy = try await provider.fetchDraftCopy(identity: .gmail(resourceId: "r1"))
            #expect(copy?.textBody == "body and tail!", "control: a part that arrives whole is the draft")
        }
        #expect(http.recordedCalls().allSatisfy { $0.method == "GET" })
    }

    // MARK: - A reply's parent after it moves

    @Test("A reply edited but unsent survives eviction while its parent, moved out of Inbox and back, is still in Inbox",
          arguments: [true, false], ["evict-parent@example.com", "\u{0301}evict-parent@example.com"])
    func movedInboxParentKeepsTheReply(adopted: Bool, parentId: String) async throws {
        try await withInstalledPool { pool in
            let draftId = try await pool.write { db -> String in
                var account = Account(emailAddress: "owner@example.com", displayName: "Test", provider: .imap)
                account.id = Self.accountId
                try account.insert(db)
                var inbox = Folder(name: "Inbox", path: "INBOX", role: .inbox, accountId: account.id)
                inbox.lastKnownUidValidity = 5
                try inbox.insert(db)
                var drafts = Folder(name: "Drafts", path: "Drafts", role: .drafts, accountId: account.id)
                drafts.lastKnownUidValidity = 9
                try drafts.insert(db)
                var parent = MessageHeader(messageId: "42", subject: "parent", from: "sender@example.com", fromAddress: "sender@example.com",
                    to: "owner@example.com", date: Date(), snippet: "", folderId: inbox.id, accountId: account.id,
                    folderPath: inbox.path, isInInbox: true)
                parent.rfc822MessageId = parentId
                parent.observedUidValidity = 5
                try parent.insert(db)
                var header = MessageHeader(messageId: "7", subject: "reply", from: "owner@example.com", fromAddress: "owner@example.com",
                    to: "sender@example.com", date: Date(), snippet: "", folderId: drafts.id, accountId: account.id,
                    folderPath: drafts.path, isInInbox: false)
                header.rfc822MessageId = "evict-draft@example.com"
                header.inReplyTo = parentId
                header.observedUidValidity = 9
                try header.insert(db)
                let id: String
                if adopted {
                    id = try #require(try ExternalDraftAdoption.insertAdoptedDraft(db: db, header: header,
                        address: .imap(folderPath: drafts.path, uidValidity: 9, uid: "7"), runtimeKind: .imap,
                        content: .init(subject: "reply", to: header.to, cc: "", bcc: "", body: "server text",
                                       attachmentsDirName: nil, attachmentCount: 0)))
                } else {
                    id = "reply:\(account.id):\(parentId)"
                    var reply = Draft(id: id, accountId: account.id, toJSON: "[]", ccJSON: "[]", bccJSON: "[]",
                        subject: "reply", body: "server text", replyToId: parent.id, isForward: false,
                        editHistoryJSON: nil, createdAt: 1, updatedAt: 1, serverDraftId: "7", serverPushStatus: "pushed",
                        rfc822MessageId: "evict-draft@example.com", attachmentsDirName: nil)
                    reply.instanceEpoch = "ordinary-E1"
                    reply.replyToProviderMessageId = "42"
                    reply.replyToUidValidity = 5
                    reply.serverDraftFolderPath = "Drafts"
                    reply.serverDraftUidValidity = 9
                    try DraftStore.applySave(reply, db: db)
                }
                var edited = try #require(try Draft.fetchOne(db, key: id))
                try #require(edited.replyToId == parent.id, "fixture: the reply claims this parent")
                edited.body = "UNSENT LOCAL EDIT"
                edited.updatedAt = Date().timeIntervalSince1970
                try DraftStore.applySave(edited, db: db)
                // Archived and moved back: the same message under a new Inbox UID and key.
                try parent.delete(db)
                parent.messageId = "99"
                parent.id = MessageIdentity.headerId(accountId: account.id, folderPath: inbox.path, messageId: "99")
                try parent.insert(db)
                let resolved = try Draft.resolveReplyToHeader(draftKey: id, replyToId: edited.replyToId, isForward: false,
                    expectedProviderMessageId: edited.replyToProviderMessageId, expectedUidValidity: edited.replyToUidValidity, db: db)
                #expect(resolved?.id == parent.id, "Send follows the parent to its new key")
                for index in 0..<SyncConfig.maxComposeDraftSessions {
                    var other = Draft(id: "new:cap-\(index)", accountId: account.id, toJSON: "[]", ccJSON: "[]", bccJSON: "[]",
                        subject: "other", body: "other text", replyToId: nil, isForward: false, editHistoryJSON: nil,
                        createdAt: 1, updatedAt: Date().timeIntervalSince1970, serverDraftId: nil, serverPushStatus: nil,
                        rfc822MessageId: nil, attachmentsDirName: nil)
                    other.instanceEpoch = "fill-\(index)"
                    try DraftStore.applySave(other, db: db)
                }
                return id
            }
            let before = try #require(try await pool.read { try Draft.fetchOne($0, key: draftId) })
            try #require(before.serverPushStatus == "dirty" && before.body == "UNSENT LOCAL EDIT")
            _ = try DraftStore.shared.evictSync(dbPool: PrioritizedDatabase(pool: pool), limit: SyncConfig.maxComposeDraftSessions)
            let after = try await pool.read { try Draft.fetchOne($0, key: draftId) }
            #expect(after?.body == "UNSENT LOCAL EDIT", "the unsent reply to an Inbox message is kept")
        }
    }

    @Test("A flowed line that reads \"-- \" only once delsp drops its marker is text, not a signature separator")
    func flowedDashDashIsASignatureOnlyAsWritten() {
        let type = "text/plain; format=flowed; delsp=yes"
        #expect(EmailFilter.decodeFormatFlowed("first \r\n-- \r\nlast", contentType: type) == "first\n-- \nlast",
                "control: a signature separator as written is a line of its own")
        #expect(EmailFilter.decodeFormatFlowed("first \r\n--  \r\nlast", contentType: type) == "first-- last",
                "a text space and the soft-break marker: the paragraph continues")
    }

    @Test("A Gmail body, inline image or file fetched apart that arrives short keeps the whole local draft",
          arguments: ["body", "inline", "file"], [true, false])
    func gmailShortSeparatePartKeepsTheLocalDraft(kind: String, shortened: Bool) async throws {
        try await withInstalledPool { pool in
            let oldBytes = Data("LOCAL WHOLE FILE".utf8)
            let oldDir = DraftAttachmentStorage.newStagingDirName()
            try DraftAttachmentStorage.saveAttachments([
                DraftAttachment(filename: "old.bin", mimeType: "application/octet-stream", data: oldBytes)
            ], dirName: oldDir)
            defer { DraftAttachmentStorage.deleteAttachments(dirName: oldDir) }
            let draftId = "new:separate-part"
            try await pool.write { db in
                var account = Account(emailAddress: "owner@example.com", displayName: "Test", provider: .gmail)
                account.id = Self.accountId
                try account.insert(db)
                var draft = Draft(id: draftId, accountId: account.id, toJSON: "[]", ccJSON: "[]", bccJSON: "[]",
                    subject: "local", body: "LOCAL WHOLE BODY", replyToId: nil, isForward: false,
                    editHistoryJSON: nil, createdAt: 1, updatedAt: 2, serverDraftId: "r1", serverPushStatus: "pushed",
                    rfc822MessageId: nil, attachmentsDirName: oldDir)
                draft.instanceEpoch = "E1"
                try draft.insert(db)
            }
            let remote: Data
            if kind == "inline" {
                remote = UIGraphicsImageRenderer(size: CGSize(width: 1, height: 1)).pngData { context in
                    UIColor.red.setFill()
                    context.fill(CGRect(x: 0, y: 0, width: 1, height: 1))
                }
            } else {
                remote = Data("REMOTE WHOLE PART".utf8)
            }
            let delivered = shortened ? Data(remote.prefix(4)) : remote
            var separated: [String: Any] = [
                "mimeType": kind == "body" ? "text/plain" : (kind == "inline" ? "image/png" : "application/octet-stream"),
                "body": ["size": remote.count, "data": "", "attachmentId": "separate"],
            ]
            if kind == "inline" { separated["headers"] = [["name": "Content-ID", "value": "<image>"]] }
            if kind == "file" { separated["filename"] = "remote.bin" }
            var parts: [[String: Any]] = []
            if kind != "body" {
                parts.append(["mimeType": "text/plain", "body": ["size": 11, "data": Self.base64URL(Data("remote body".utf8))]])
            }
            parts.append(separated)
            let payload: [String: Any] = [
                "id": "m1", "internalDate": String(Int(Date().timeIntervalSince1970 * 1000)), "labelIds": ["DRAFT"],
                "payload": ["mimeType": "multipart/mixed", "parts": parts,
                            "headers": [["name": "Subject", "value": "remote"]]]]
            let http = FakeHTTP.Scenario()
            defer { http.close() }
            http.register(path: "/drafts/r1", method: "GET", response: .json(raw: #"{"message":{"id":"m1"}}"#))
            http.register(path: "/messages/m1", method: "GET", response: .json(raw:
                String(decoding: try JSONSerialization.data(withJSONObject: payload), as: UTF8.self)))
            http.register(path: "/messages/m1/attachments/separate", method: "GET", response: .json(raw:
                "{\"size\":\(remote.count),\"data\":\"\(Self.base64URL(delivered))\"}"))
            let provider = GmailProvider(userEmail: "owner@example.com", accessToken: { _ in "token" }, session: http.session)
            try await withRegisteredProvider(provider) {
                await ExternalDraftAdoption.refreshBeforeOpen(draftId: draftId, willReadServer: {})
            }
            let row = try #require(try await pool.read { try Draft.fetchOne($0, key: draftId) })
            defer { if let name = row.attachmentsDirName, name != oldDir { DraftAttachmentStorage.deleteAttachments(dirName: name) } }
            let files = try DraftAttachmentStorage.loadAttachments(dirName: row.attachmentsDirName)
            #expect(http.recordedCalls().contains { $0.url.contains("/attachments/separate") }, "fixture: the part was fetched apart")
            #expect(http.recordedCalls().allSatisfy { $0.method == "GET" }, "opening changes nothing on the server")
            if shortened {
                #expect(row.body == "LOCAL WHOLE BODY" && row.pushAttemptVersion == 0 && row.attachmentsDirName == oldDir,
                        "the local row is unchanged")
                #expect(files.map(\.data) == [oldBytes], "the local file survives whole")
            } else {
                #expect(row.pushAttemptVersion == 1, "control: a whole server copy is taken")
                #expect(row.body == (kind == "body" ? "REMOTE WHOLE PART" : "remote body"))
                #expect(files.map(\.data) == (kind == "body" ? [] : [remote]))
            }
        }
    }
}

// #278 review: the parent the upload names, and how the copy's parent is learned and compared.
extension DraftCopyIntegrityTests {
    @Test("The upload names a moved parent with its history, and only on Gmail", arguments: ["reply", "moved", "outlook", "imap"])
    func uploadThreadHeadersFollowParentAndProvider(_ mode: String) throws {
        let queue = try TestDatabase.make()
        try queue.write { db in
            _ = try insertReplyFixture(db, adopted: false)
            var parent = try #require(try MessageHeader.fetchOne(db, key: parentHeaderId("p-old")))
            parent.referencesJSON = MessageHeader.encodeReferences(["ancestor-1@example.com", "ancestor-2@example.com"])
            var account = try #require(try Account.fetchOne(db, key: Self.accountId))
            let kind: DraftRuntimeIdentityKind
            if mode == "outlook" { account.provider = .outlook; kind = .outlook }
            else if mode == "imap" { account.provider = .imap; kind = .imap }
            else { kind = .gmail }
            try account.update(db)
            if mode == "imap" {
                try parent.delete(db)
                parent.messageId = "7"
                parent.id = MessageIdentity.headerId(accountId: Self.accountId, folderPath: "INBOX", messageId: "7")
                parent.observedUidValidity = 901
                try parent.insert(db)
                try Folder.filter(Column("id") == parent.folderId).updateAll(db, Column("lastKnownUidValidity").set(to: 901))
            } else { try parent.update(db) }
            var draft = Draft(
                id: "reply:\(Self.accountId):old-parent@example.com", accountId: Self.accountId,
                toJSON: #"["old@example.com"]"#, ccJSON: "[]", bccJSON: "[]", subject: "Re: p-old", body: "typed text",
                replyToId: parent.id, isForward: false, editHistoryJSON: nil, createdAt: 1, updatedAt: 2)
            draft.replyToUidValidity = mode == "imap" ? 901 : nil
            draft.replyToProviderMessageId = parent.messageId
            draft.instanceEpoch = "tabmail-E1"
            try DraftStore.applySave(draft, db: db)
            if mode == "moved" {
                let archive = Folder(name: "Archive", path: "Archive", role: .archive, accountId: Self.accountId)
                try archive.insert(db)
                try parent.delete(db)
                parent.folderPath = archive.path; parent.folderId = archive.id
                parent.id = MessageIdentity.headerId(accountId: Self.accountId, folderPath: archive.path, messageId: parent.messageId)
                try parent.insert(db)
                #expect(try MessageHeader.fetchOne(db, key: draft.replyToId!) == nil)
            }
            let headers = try DraftStore.uploadThreadHeaders(for: draft, runtimeKind: kind, db: db)
            if kind == .gmail {
                #expect(headers.inReplyTo == "old-parent@example.com")
                #expect(headers.references == ["ancestor-1@example.com", "ancestor-2@example.com", "old-parent@example.com"])
            } else { #expect(headers == .none) }
            let plan = try Row.fetchAll(db, sql: "EXPLAIN QUERY PLAN " + Draft.replyTargetLookupSQL,
                                        arguments: [Self.accountId, "old-parent@example.com"])
            let details = plan.map { $0["detail"] as String }
            #expect(details.contains { $0.contains("messageHeader_rfc822MessageId") })
        }
    }

    @Test("A reload that reads the same reply makes a later standalone replacement detectable")
    func reloadLearnsParentBeforeStandaloneReplacement() throws {
        let queue = try TestDatabase.make()
        try queue.write { db in
            _ = try insertReplyFixture(db, adopted: true, copyInReplyTo: "<old-parent@example.com>")
            var row = try #require(try Draft.fetchOne(db))
            // The v94 migration is the producer of UNKNOWN on existing rows.
            row.serverCopyNamesParent = nil; try row.update(db)
            let same = ExternalDraftAdoption.ServerContent(subject: "reply", to: "old@example.com", cc: "", bcc: "", body: "server reply", attachmentsDirName: nil, attachmentCount: 0, inReplyTo: "<old-parent@example.com>")
            #expect(try ExternalDraftAdoption.applyReload(db: db, decided: row, content: same) == .applied(previousDirName: nil))
            let refreshed = try #require(try Draft.fetchOne(db, key: row.id))
            #expect(refreshed.serverCopyNamesParent == true)
            let standalone = ExternalDraftAdoption.ServerContent(subject: "new", to: "new@example.com", cc: "", bcc: "", body: "new standalone text", attachmentsDirName: nil, attachmentCount: 0)
            #expect(try ExternalDraftAdoption.applyReload(db: db, decided: refreshed, content: standalone) == .removed(previousDirName: nil))
            #expect(try Draft.fetchOne(db, key: row.id) == nil)
        }
    }

    @Test("A server reply whose parent is absent stays adopted on repeated reload")
    func unclaimedReplyDoesNotEvictItself() throws {
        let queue = try TestDatabase.make()
        try queue.write { db in
            var header = try insertReplyFixture(db, adopted: false)
            header.inReplyTo = "not-on-this-device@example.com"; try header.update(db)
            let content = ExternalDraftAdoption.ServerContent(subject: "external reply", to: "old@example.com", cc: "", bcc: "", body: "server text", attachmentsDirName: nil, attachmentCount: 0, inReplyTo: "<not-on-this-device@example.com>")
            let id = try #require(try ExternalDraftAdoption.insertAdoptedDraft(db: db, header: header, address: .gmail(resourceId: "r1", containedMessageId: "m-old"), runtimeKind: .gmail, content: content))
            var row = try #require(try Draft.fetchOne(db, key: id))
            #expect(row.replyToId == nil && Draft.replyKeyTail(draftKey: id, isForward: false) == nil)
            #expect(row.serverCopyNamesParent == true)
            for _ in 0..<2 {
                #expect(try ExternalDraftAdoption.applyReload(db: db, decided: row, content: content) == .applied(previousDirName: nil))
                row = try #require(try Draft.fetchOne(db, key: id))
                #expect(row.body == "server text" && row.serverPushStatus == "pushed")
            }
        }
    }

    @Test("A Gmail upload answered without a contained message id still records its parent")
    func uploadWithoutContainedMessageIdRecordsParent() async throws {
        try await withInstalledPool { pool in
            let http = FakeHTTP.Scenario(); defer { http.close() }
            let (draft, raw) = try await pushTabMailGmailDraft(pool, http: http, includeContainedMessageId: false)
            #expect(raw.contains("In-Reply-To: <old-parent@example.com>\r\n"))
            #expect(draft.serverDraftId == "r1" && draft.serverPushStatus == "pushed")
            #expect(draft.serverCopyNamesParent == true)
            try registerReplacedGmailDraft(http, parent: nil)
            let provider = GmailProvider(userEmail: "owner@example.com", accessToken: { _ in "token" }, session: http.session)
            try await withRegisteredProvider(provider) {
                #expect(await ExternalDraftAdoption.refreshBeforeOpen(draftId: draft.id, willReadServer: {}) == .replacedElsewhere)
                let after = try await pool.read { try Draft.fetchOne($0, key: draft.id) }
                #expect(after == nil)
            }
        }
    }

    @Test("A forward stays a forward through a reply-bearing then a parentless reload")
    func forwardIsNotReclassifiedByReplyHeaders() async throws {
        try await withInstalledPool { pool in
            let http = FakeHTTP.Scenario(); defer { http.close() }
            let existing = try await pushTabMailGmailDraft(pool, http: http, isForward: true).draft
            let provider = GmailProvider(userEmail: "owner@example.com", accessToken: { _ in "token" }, session: http.session)
            try await withRegisteredProvider(provider) {
                try registerReplacedGmailDraft(http, parent: "new-parent@example.com")
                #expect(await ExternalDraftAdoption.refreshBeforeOpen(draftId: existing.id, willReadServer: {}) == .open)
                let first = try #require(try await pool.read { try Draft.fetchOne($0, key: existing.id) })
                #expect(first.isForward && first.body == "new reply text")
                #expect(first.serverCopyNamesParent == true)
                // Equal-prefix FakeHTTP routes keep their first registration. Reset,
                // and model Gmail's new contained id for the second replacement.
                http.reset()
                http.register(path: "/drafts/r1", method: "GET", response: .json(raw: #"{"message":{"id":"m-new-2"}}"#))
                let text = Data("standalone text".utf8)
                let payload: [String: Any] = [
                    "id": "m-new-2", "internalDate": String(Int(Date().timeIntervalSince1970 * 1000)), "labelIds": ["DRAFT"],
                    "payload": ["mimeType": "text/plain", "headers": [["name": "Subject", "value": "standalone"], ["name": "To", "value": "new@example.com"]],
                                "body": ["size": text.count, "data": Self.base64URL(text)]] as [String: Any]]
                http.register(path: "/messages/m-new-2", method: "GET", response: .json(raw: String(decoding: try JSONSerialization.data(withJSONObject: payload), as: UTF8.self)))
                #expect(await ExternalDraftAdoption.refreshBeforeOpen(draftId: existing.id, willReadServer: {}) == .open)
                let second = try #require(try await pool.read { try Draft.fetchOne($0, key: existing.id) })
                #expect(second.isForward && second.body == "standalone text")
                #expect(second.serverCopyNamesParent == false)
                #expect(http.servedCallSequence().count == 2)
            }
        }
    }
}
