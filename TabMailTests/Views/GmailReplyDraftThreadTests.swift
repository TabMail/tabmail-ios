/* This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at https://mozilla.org/MPL/2.0/. */

import Foundation
import GRDB
import Testing
@testable import TabMail

/// #431: Gmail files a draft in a conversation only when "the requested threadId
/// [is] specified as part of the drafts.message or messages resource", the
/// References and In-Reply-To headers name the parent, and the Subject matches
/// (Gmail API threads guide). THE PROPERTY: every Gmail reply-draft upload, both
/// `drafts.create` and `drafts.update`, sends the same thread binding Send would
/// send for that reply: the parent's `threadId` exactly when Send's builder gives
/// one (same account, matching subject), next to the headers that name the parent.
///
/// Drives production `DraftStore.pushDraftToServer` against a real
/// `GmailProvider` on `FakeHTTP` and reads the request bodies off the wire.
@Suite("A Gmail reply draft upload carries the thread binding Send would", .serialized, .processGlobalState)
@MainActor
struct GmailReplyDraftThreadTests {
    private nonisolated static let accountId = "acc-431-draft-thread"
    private nonisolated static let parentThreadId = "thread-431-parent"
    private nonisolated static let parentSubject = "Quarterly plan"

    private func withInstalledPool(_ body: (DatabasePool) async throws -> Void) async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("gmail-reply-draft-thread-\(UUID().uuidString)")
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

    /// A Gmail account with an inbox parent in conversation `parentThreadId`.
    private nonisolated static func insertParent(_ db: Database) throws -> MessageHeader {
        var account = Account(emailAddress: "owner@example.com", displayName: "Test", provider: .gmail)
        account.id = accountId
        try account.insert(db)
        try Folder(name: "Drafts", path: "DRAFT", role: .drafts, accountId: accountId).insert(db)
        let inbox = Folder(name: "Inbox", path: "INBOX", role: .inbox, accountId: accountId)
        try inbox.insert(db)
        var parent = MessageHeader(
            messageId: "p-431", subject: parentSubject, from: "sender@example.com", fromAddress: "sender@example.com",
            to: "owner@example.com", date: Date(), snippet: "", folderId: inbox.id,
            accountId: accountId, folderPath: inbox.path, isInInbox: true)
        parent.rfc822MessageId = "parent-431@example.com"
        parent.threadId = parentThreadId
        try parent.insert(db)
        return parent
    }

    /// Bytes of the file an attached reply carries (binary, so a lossy MIME path shows).
    private nonisolated static let attachmentBytes = Data([0, 1, 2, 127, 128, 255])

    /// The `message` resource of one recorded draft request, its raw header lines,
    /// and the whole raw message.
    private nonisolated static func uploadedMessage(
        _ requestBody: Data?
    ) throws -> (message: [String: Any], headerLines: [String], raw: String) {
        let body = try #require(requestBody)
        let json = try #require(try JSONSerialization.jsonObject(with: body) as? [String: Any])
        let message = try #require(json["message"] as? [String: Any])
        let encoded = try #require(message["raw"] as? String)
        var base64 = encoded.replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
        base64 += String(repeating: "=", count: (4 - base64.count % 4) % 4)
        let raw = String(decoding: try #require(Data(base64Encoded: base64)), as: UTF8.self)
        let headerLines = raw.components(separatedBy: "\r\n\r\n").first?.components(separatedBy: "\r\n") ?? []
        return (message, headerLines, raw)
    }

    /// Saves a reply draft to `parent` in `draftAccountId` (with a stored file when
    /// `withAttachment`), pushes it (drafts.create), edits it and pushes again
    /// (drafts.update), and returns the two upload requests. Each upload must carry
    /// the authored body, and the whole file when there is one.
    private static func createThenUpdate(
        pool: DatabasePool, parent: MessageHeader, draftAccountId: String,
        draftUserEmail: String, subject: String, withAttachment: Bool
    ) async throws -> [(method: String, url: String, body: Data?)] {
        let draftId = "reply:\(draftAccountId):parent-431@example.com"
        let attachmentsDirName: String? = withAttachment ? DraftAttachmentStorage.newStagingDirName() : nil
        if let attachmentsDirName {
            try DraftAttachmentStorage.saveAttachments(
                [DraftAttachment(filename: "plan.bin", mimeType: "application/octet-stream", data: attachmentBytes)],
                dirName: attachmentsDirName)
        }
        defer { if let attachmentsDirName { DraftAttachmentStorage.deleteAttachments(dirName: attachmentsDirName) } }
        try await pool.write { db in
            var draft = Draft(
                id: draftId, accountId: draftAccountId, toJSON: #"["sender@example.com"]"#, ccJSON: "[]", bccJSON: "[]",
                subject: subject, body: "first body", replyToId: parent.id, isForward: false,
                editHistoryJSON: nil, createdAt: 1, updatedAt: 2, serverDraftId: nil,
                serverPushStatus: nil, rfc822MessageId: nil, attachmentsDirName: attachmentsDirName)
            draft.instanceEpoch = "tabmail-E1"
            draft.replyToProviderMessageId = parent.messageId
            try DraftStore.applySave(draft, db: db)
        }

        let http = FakeHTTP.Scenario()
        defer { http.close() }
        http.register(path: "/drafts", method: "POST", response: .json(raw: #"{"id":"r431","message":{"id":"m-1"}}"#))
        http.register(path: "/drafts/r431", method: "PUT", response: .json(raw: #"{"id":"r431","message":{"id":"m-2"}}"#))
        let provider = GmailProvider(userEmail: draftUserEmail, accessToken: { _ in "token" }, session: http.session)

        let created = try await DraftStore.shared.pushDraftToServer(
            draftId: draftId, expectedInstanceEpoch: "tabmail-E1", provider: provider,
            runtimeKind: .gmail, draftsFolderPath: "DRAFT")
        try #require(created == .completed, "precondition: the first upload created the Gmail draft")

        // An edit, then the second upload replaces the same Gmail draft.
        let pushed = try #require(try await pool.read { try Draft.fetchOne($0, key: draftId) })
        #expect(pushed.serverDraftId == "r431", "precondition: the row names the created draft")
        try await pool.write { db in
            var edited = pushed
            edited.body = "second body"
            edited.updatedAt = 3
            try DraftStore.applySave(edited, db: db)
        }
        let updated = try await DraftStore.shared.pushDraftToServer(
            draftId: draftId, expectedInstanceEpoch: try #require(pushed.instanceEpoch), provider: provider,
            runtimeKind: .gmail, draftsFolderPath: "DRAFT")
        try #require(updated == .completed, "precondition: the second upload updated the Gmail draft")

        let uploads = http.recordedCalls().filter {
            ($0.method == "POST" && $0.url.hasSuffix("/drafts")) || ($0.method == "PUT" && $0.url.hasSuffix("/drafts/r431"))
        }
        for (call, body) in zip(uploads, ["first body", "second body"]) {
            let raw = try uploadedMessage(call.body).raw
            #expect(raw.contains(body) || raw.contains(Data(body.utf8).base64EncodedString()),
                    "\(call.method) does not carry the authored body")
            #expect(raw.contains(attachmentBytes.base64EncodedString()) == withAttachment,
                    "\(call.method) attachment presence differs from the draft (withAttachment: \(withAttachment))")
        }
        return uploads
    }

    @Test("A Gmail reply draft's create and update carry the thread id exactly when Send would",
          arguments: ["Re: Quarterly plan", "A different topic"], [false, true])
    func replyDraftUploadCarriesSendsThreadBinding(subject: String, withAttachment: Bool) async throws {
        try await withInstalledPool { pool in
            let parent = try await pool.write { try Self.insertParent($0) }
            let sendBinding = ThreadUtils.outgoingThreadHeaders(
                replyTo: parent, sendAccountId: Self.accountId, sendSubject: subject, providerKind: .gmail)
            if subject.hasSuffix(Self.parentSubject) {
                #expect(sendBinding.threadId == Self.parentThreadId, "fixture: Send threads this reply")
            } else {
                #expect(sendBinding.threadId == nil, "fixture: Send starts a new thread for a changed subject")
            }

            let uploads = try await Self.createThenUpdate(
                pool: pool, parent: parent, draftAccountId: Self.accountId,
                draftUserEmail: "owner@example.com", subject: subject, withAttachment: withAttachment)
            #expect(uploads.map(\.method) == ["POST", "PUT"], "expected drafts.create then drafts.update")
            for call in uploads {
                let (message, headerLines, _) = try Self.uploadedMessage(call.body)
                #expect(message["threadId"] as? String == sendBinding.threadId,
                        "\(call.method) sent threadId \(String(describing: message["threadId"])), Send would send \(String(describing: sendBinding.threadId))")
                #expect(headerLines.contains("In-Reply-To: <parent-431@example.com>"), "\(call.method) does not name the parent")
                #expect(headerLines.contains("References: <parent-431@example.com>"), "\(call.method) does not name the parent")
            }
        }
    }

    /// Send binds a reply to the parent's conversation only from the parent's own
    /// account (a Gmail thread id is per mailbox), so a reply draft saved in another
    /// Gmail account must name no thread, on create and on update alike.
    @Test("A reply draft saved in another Gmail account than its parent names no thread",
          arguments: [false, true])
    func crossAccountReplyDraftNamesNoThread(withAttachment: Bool) async throws {
        try await withInstalledPool { pool in
            let parent = try await pool.write { try Self.insertParent($0) }
            let otherAccountId = "acc-431-other"
            try await pool.write { db in
                var other = Account(emailAddress: "other@example.com", displayName: "Other", provider: .gmail)
                other.id = otherAccountId
                try other.insert(db)
                try Folder(name: "Drafts", path: "DRAFT", role: .drafts, accountId: otherAccountId).insert(db)
            }
            let subject = "Re: \(Self.parentSubject)"
            let sendBinding = ThreadUtils.outgoingThreadHeaders(
                replyTo: parent, sendAccountId: otherAccountId, sendSubject: subject, providerKind: .gmail)
            #expect(sendBinding.threadId == nil, "fixture: Send from the other account binds no thread")

            let uploads = try await Self.createThenUpdate(
                pool: pool, parent: parent, draftAccountId: otherAccountId,
                draftUserEmail: "other@example.com", subject: subject, withAttachment: withAttachment)
            #expect(uploads.map(\.method) == ["POST", "PUT"], "expected drafts.create then drafts.update")
            for call in uploads {
                let (message, headerLines, _) = try Self.uploadedMessage(call.body)
                #expect(!message.keys.contains("threadId"),
                        "\(call.method) sent threadId \(String(describing: message["threadId"])) from another account")
                #expect(headerLines.contains("In-Reply-To: <parent-431@example.com>"), "\(call.method) does not name the parent")
                #expect(headerLines.contains("References: <parent-431@example.com>"), "\(call.method) does not name the parent")
            }
        }
    }
}
