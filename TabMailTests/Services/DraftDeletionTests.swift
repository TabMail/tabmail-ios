/* This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at https://mozilla.org/MPL/2.0/. */

import Testing
import Foundation
import GRDB
@testable import TabMail

/// Tests for draft save/delete lifecycle: isPermanentlyInvalidError classification,
/// typed DraftSaveOutcome, pendingAllIds protection for .saveDraft ops, and
/// flushAIBatch folder filtering.
@Suite("Draft Deletion Tests")
struct DraftDeletionTests {

    let db: DatabaseQueue

    init() throws {
        db = try TestDatabase.make()
        try TestDatabase.insertAccount(db, id: "acc1")
        try TestDatabase.insertFolder(db, name: "Drafts", path: "DRAFT", role: .drafts, accountId: "acc1")
        try TestDatabase.insertFolder(db, name: "Inbox", path: "INBOX", role: .inbox, accountId: "acc1")
        try TestDatabase.insertFolder(db, name: "Trash", path: "Trash", role: .trash, accountId: "acc1")
    }

    // MARK: - isPermanentlyInvalidError
    //
    // 🚨 THIS WHOLE BLOCK WAS CORRECTED (audit round 1, finding B-3), and the
    // three tests that changed verdict were the ones blessing the defect.
    //
    // The classifier decides ONE thing: may this failure retire a durable
    // `PendingOperation`? Under the never-drop rule that is exit 2 — a
    // PROVIDER-AUTHORITATIVE stale/no-op result — and nothing else. The old
    // implementation answered it from the STATUS CODE (`400` from a REST
    // provider ⇒ terminal), binding any response body to `_`. So Gmail
    // replying `"Precondition check failed."` — a `failedPrecondition` that a
    // later retry can resolve — silently destroyed the user's archive, move or
    // flag, indistinguishable from Gmail saying the id was never valid.
    //
    // The corrected property, which every test below is an instance of:
    //
    //   TERMINAL  ⟺  the provider's own structured body PROVES the request can
    //                never succeed.
    //   Everything else — a bodyless 400, an unparseable body, a structured
    //   body with an unrecognised reason or message — is an ABSENCE OF
    //   EVIDENCE and stays retryable forever.
    //
    // RED PROOF for the inverted cases, recorded: restoring the pre-fix arms
    //     case .networkError(400), .networkErrorWithBody(400, _): return true
    // (plus the NSError `domain == "Gmail"/"Exchange" && code == 400` arms) makes
    // `bareStatus400IsNotAuthoritative`, `exchangeBareStatus400IsNotAuthoritative`
    // and `unparseableBody400IsNotAuthoritative` fail on their `#expect(!…)`.
    // `structuredInvalidIdBody400IsAuthoritative` is the non-vacuity partner and
    // passes in BOTH states, so the suite cannot be satisfied by a classifier
    // that simply answers `false` to everything.

    @Test("isPermanentlyInvalidError: a bare Gmail 400 with no body is NOT authoritative")
    func bareStatus400IsNotAuthoritative() {
        // The provider rejected the request and told us nothing about why.
        // A status code is not a classification.
        let error = ProviderError.networkError(underlying: NSError(domain: "Gmail", code: 400))
        let manager = AccountManager.shared
        #expect(!manager.isPermanentlyInvalidError(error))
    }

    @Test("isPermanentlyInvalidError: a bare Exchange 400 with no body is NOT authoritative")
    func exchangeBareStatus400IsNotAuthoritative() {
        let error = ProviderError.networkError(underlying: NSError(domain: "Exchange", code: 400))
        let manager = AccountManager.shared
        #expect(!manager.isPermanentlyInvalidError(error))
    }

    @Test("isPermanentlyInvalidError: non-REST domain 400 returns false")
    func permanentlyInvalidOtherDomain400() {
        let error = ProviderError.networkError(underlying: NSError(domain: "IMAP", code: 400))
        let manager = AccountManager.shared
        #expect(!manager.isPermanentlyInvalidError(error))
    }

    @Test("isPermanentlyInvalidError: Gmail 404 returns false (not permanently invalid)")
    func permanentlyInvalidGmail404() {
        let error = ProviderError.networkError(underlying: NSError(domain: "Gmail", code: 404))
        let manager = AccountManager.shared
        #expect(!manager.isPermanentlyInvalidError(error))
    }

    @Test("isPermanentlyInvalidError: Gmail 500 returns false")
    func permanentlyInvalidGmail500() {
        let error = ProviderError.networkError(underlying: NSError(domain: "Gmail", code: 500))
        let manager = AccountManager.shared
        #expect(!manager.isPermanentlyInvalidError(error))
    }

    @Test("isPermanentlyInvalidError: non-ProviderError returns false")
    func permanentlyInvalidNonProviderError() {
        let error = NSError(domain: "Gmail", code: 400)
        let manager = AccountManager.shared
        #expect(!manager.isPermanentlyInvalidError(error))
    }

    @Test("isPermanentlyInvalidError: messageNotFound returns false")
    func permanentlyInvalidMessageNotFound() {
        let error = ProviderError.messageNotFound
        let manager = AccountManager.shared
        #expect(!manager.isPermanentlyInvalidError(error))
    }

    // MARK: - isPermanentlyInvalidError — HTTPError enum shape (commit 06f4b3c)
    //
    // GmailProvider / ExchangeProvider's `request()` helpers throw
    // `ProviderError.networkError(underlying: HTTPError.networkError(statusCode: N))`.
    // The classifier must enum-pattern-match the underlying directly — bridging
    // HTTPError to NSError gives `domain="TabMail.HTTPError" code=<case ordinal>`,
    // NOT the HTTP status code.
    //
    // ⚑ The original rationale for this block ended "...which is why a stuck
    // `.move` op (Gmail 'Invalid label: Deleted Messages') retried for 9 days".
    // That real incident is still the motivating case and is still fixed — but
    // by RECOGNISING that body (`reason == invalidArgument`, message prefix
    // `"Invalid label"`), not by treating its status code as terminal. See
    // `structuredInvalidLabelBody400IsAuthoritative` below.

    @Test("isPermanentlyInvalidError: a bodyless HTTPError 400 is NOT authoritative")
    func bodylessHTTPError400IsNotAuthoritative() {
        // Same absence of evidence as the NSError shape: no body, no proof.
        let error = ProviderError.networkError(underlying: HTTPError.networkError(statusCode: 400))
        let manager = AccountManager.shared
        #expect(!manager.isPermanentlyInvalidError(error))
    }

    @Test("isPermanentlyInvalidError: HTTPError.networkError(404) returns false")
    func permanentlyInvalidHTTPError404() {
        // 404 is messageNotFound's job, not the permanent-invalid classifier.
        let error = ProviderError.networkError(underlying: HTTPError.networkError(statusCode: 404))
        let manager = AccountManager.shared
        #expect(!manager.isPermanentlyInvalidError(error))
    }

    @Test("isPermanentlyInvalidError: HTTPError.networkError(500) returns false")
    func permanentlyInvalidHTTPError500() {
        // 5xx is transient; must retry.
        let error = ProviderError.networkError(underlying: HTTPError.networkError(statusCode: 500))
        let manager = AccountManager.shared
        #expect(!manager.isPermanentlyInvalidError(error))
    }

    @Test("isPermanentlyInvalidError: HTTPError.networkError(429) returns false")
    func permanentlyInvalidHTTPError429() {
        // Throttle is transient; must retry.
        let error = ProviderError.networkError(underlying: HTTPError.networkError(statusCode: 429))
        let manager = AccountManager.shared
        #expect(!manager.isPermanentlyInvalidError(error))
    }

    // MARK: - isPermanentlyInvalidError — body-preserving HTTPError shape (T4.H1 / T3.5)
    //
    // `AuthedHTTP.requestPreservingBadRequestBody` is an opt-in used by action-path
    // call sites that must STRUCTURALLY classify a 400 (Gmail's "Invalid id value")
    // instead of guessing from the status code. On a final 400 it throws
    // `HTTPError.networkErrorWithBody(statusCode:body:)`.
    //
    // 🚨 CORRECTED (audit round 1, finding B-3). The block that stood here
    // asserted the OPPOSITE of what the helper exists for: that a body-carrying
    // 400 and a bodyless one "must classify identically". Under that equivalence
    // the preserved body could not possibly change any verdict — the classifier
    // was still deciding on the status alone, and the helper's whole purpose was
    // nullified. The body is the evidence; it MUST be able to change the answer.

    @Test("isPermanentlyInvalidError: a structured 400 whose reason is unrecognised is NOT authoritative")
    func unparseableBody400IsNotAuthoritative() {
        // Gmail's real `failedPrecondition` wording. Structurally a valid error
        // body, but it does not say the request can never succeed — a retry may
        // well work, so the user's action must survive.
        let body = Data(#"""
        {"error":{"errors":[{"domain":"global","reason":"failedPrecondition","message":"Precondition check failed."}],"code":400,"message":"Precondition check failed."}}
        """#.utf8)
        let error = ProviderError.networkError(
            underlying: HTTPError.networkErrorWithBody(statusCode: 400, body: body)
        )
        let manager = AccountManager.shared
        #expect(!manager.isPermanentlyInvalidError(error))
    }

    @Test("isPermanentlyInvalidError: Gmail's structured 'Invalid id value' 400 IS authoritative")
    func structuredInvalidIdBody400IsAuthoritative() {
        // NON-VACUITY. Gmail stating the id is malformed is a fact no retry
        // changes — exit 2, the one shape permitted to retire the op. Without
        // this the suite would pass with a classifier that always says `false`.
        let body = Data(#"""
        {"error":{"errors":[{"domain":"global","reason":"invalidArgument","message":"Invalid id value abc123"}],"code":400,"message":"Invalid id value abc123"}}
        """#.utf8)
        let error = ProviderError.networkError(
            underlying: HTTPError.networkErrorWithBody(statusCode: 400, body: body)
        )
        let manager = AccountManager.shared
        #expect(manager.isPermanentlyInvalidError(error))
    }

    @Test("isPermanentlyInvalidError: Gmail's structured 'Invalid label' 400 IS authoritative")
    func structuredInvalidLabelBody400IsAuthoritative() {
        // The 9-day stuck `.move` from the original incident, now retired for
        // the right reason: Gmail named the label and said it cannot be applied.
        let body = Data(#"""
        {"error":{"errors":[{"domain":"global","reason":"invalidArgument","message":"Invalid label: Label_9999"}],"code":400,"message":"Invalid label: Label_9999"}}
        """#.utf8)
        let error = ProviderError.networkError(
            underlying: HTTPError.networkErrorWithBody(statusCode: 400, body: body)
        )
        let manager = AccountManager.shared
        #expect(manager.isPermanentlyInvalidError(error))
    }

    @Test("isPermanentlyInvalidError: an authoritative-shaped body on a non-400 status is NOT authoritative")
    func authoritativeBodyOnNon400StatusIsNotAuthoritative() {
        // Status gate, asserted from the other side: the exact wording that IS
        // terminal on a 400 must not be terminal on a 503, or a backend blip
        // that happens to echo the message could retire the op.
        let body = Data(#"""
        {"error":{"errors":[{"domain":"global","reason":"invalidArgument","message":"Invalid id value abc123"}],"code":503,"message":"Invalid id value abc123"}}
        """#.utf8)
        let error = ProviderError.networkError(
            underlying: HTTPError.networkErrorWithBody(statusCode: 503, body: body)
        )
        let manager = AccountManager.shared
        #expect(!manager.isPermanentlyInvalidError(error))
    }

    @Test("isPermanentlyInvalidError: HTTPError.networkErrorWithBody(503) returns false")
    func permanentlyInvalidHTTPErrorWithBody503() {
        let body = Data(#"{"error":{"code":503,"message":"Backend Error"}}"#.utf8)
        let error = ProviderError.networkError(
            underlying: HTTPError.networkErrorWithBody(statusCode: 503, body: body)
        )
        let manager = AccountManager.shared
        #expect(!manager.isPermanentlyInvalidError(error))
    }

    // MARK: - PendingOperation messageIds for .saveDraft

    @Test("saveDraft PendingOperation includes placeholder messageId for pendingAllIds protection")
    func saveDraftPendingOpIncludesPlaceholder() throws {
        let draftId = "test-draft-\(UUID().uuidString)"
        let placeholderMsgId = "draft-\(draftId)"

        // Insert a Draft record (required by queueDraftSave)
        try db.write { db in
            let draft = Draft(
                id: draftId,
                accountId: "acc1",
                toJSON: "[]",
                ccJSON: "[]",
                bccJSON: "[]",
                subject: "Test",
                body: "Body",
                replyToId: nil,
                isForward: false,
                editHistoryJSON: nil,
                createdAt: Date().timeIntervalSince1970,
                updatedAt: Date().timeIntervalSince1970
            )
            try draft.save(db)
        }

        // Simulate what queueDraftSave does: create PendingOperation with protection IDs
        try db.write { db in
            let draft = try Draft.fetchOne(db, key: draftId)!
            var opMsgIds = [draftId, placeholderMsgId]
            if let rfc822 = draft.rfc822MessageId {
                opMsgIds.append(rfc822)
            }
            try PendingOperation(
                type: .saveDraft,
                messageIds: opMsgIds,
                accountId: "acc1",
                folderPath: "DRAFT"
            ).insert(db)
        }

        // Verify the PendingOperation has the right messageIds
        let ops = try db.read { db in
            try PendingOperation.filter(Column("type") == OperationType.saveDraft.rawValue).fetchAll(db)
        }
        #expect(ops.count == 1)
        guard ops.count == 1 else { return }
        #expect(ops[0].messageIds.contains(draftId))
        #expect(ops[0].messageIds.contains(placeholderMsgId))
    }

    // MARK: - Optimistic draft header + body creation

    @Test("queueDraftSave creates optimistic MessageHeader in Drafts folder")
    func optimisticHeaderCreated() throws {
        let draftId = "header-test-\(UUID().uuidString)"
        let placeholderMsgId = "draft-\(draftId)"

        try db.write { db in
            let draft = Draft(
                id: draftId,
                accountId: "acc1",
                toJSON: "[\"test@example.com\"]",
                ccJSON: "[]",
                bccJSON: "[]",
                subject: "Optimistic Test",
                body: "Hello world",
                replyToId: nil,
                isForward: false,
                editHistoryJSON: nil,
                createdAt: Date().timeIntervalSince1970,
                updatedAt: Date().timeIntervalSince1970
            )
            try draft.save(db)

            // Simulate optimistic header creation (from queueDraftSave)
            let folderId = "acc1:DRAFT"
            let headerId = "\(folderId):\(placeholderMsgId)"
            var header = MessageHeader(
                messageId: placeholderMsgId,
                subject: "Optimistic Test",
                from: "me@test.com",
                fromAddress: "me@test.com",
                to: "test@example.com",
                date: Date(),
                snippet: "Hello world",
                folderId: folderId,
                accountId: "acc1",
                folderPath: "DRAFT",
                isInInbox: false
            )
            header.rfc822MessageId = "draft-\(UUID().uuidString)@test.com"
            header.isRead = true
            try header.insert(db)

            let body = MessageBody( contentKey: ContentKey(rawValue: headerId), htmlContent: MessageBody.plainTextToHTML("Hello world"))
            try body.save(db)
        }

        // Verify header exists
        let folderId = "acc1:DRAFT"
        let headerId = "\(folderId):\(placeholderMsgId)"
        let header = try db.read { db in try MessageHeader.fetchOne(db, key: headerId) }
        #expect(header != nil)
        #expect(header?.subject == "Optimistic Test")

        // Verify body exists
        let body = try db.read { db in try MessageBody.fetchOne(db, key: headerId) }
        #expect(body != nil)
        #expect(body?.htmlContent?.contains("Hello world") == true)
    }

    // MARK: - Header migration (simulates pushDraftToServer)

    @Test("Draft header migration: placeholder PK migrated to real messageId")
    func headerMigrationPlaceholderToReal() throws {
        let draftId = "migrate-test-\(UUID().uuidString)"
        let placeholderMsgId = "draft-\(draftId)"
        let realMessageId = "19d4abc123"
        let folderId = "acc1:DRAFT"
        let oldHeaderId = "\(folderId):\(placeholderMsgId)"
        let newHeaderId = "\(folderId):\(realMessageId)"

        // Create optimistic header + body
        try db.write { db in
            var header = MessageHeader(
                messageId: placeholderMsgId,
                subject: "Migration Test",
                from: "me@test.com",
                fromAddress: "me@test.com",
                to: "test@example.com",
                date: Date(),
                snippet: "Body text",
                folderId: folderId,
                accountId: "acc1",
                folderPath: "DRAFT",
                isInInbox: false
            )
            header.rfc822MessageId = "draft-rfc822@test.com"
            try header.insert(db)

            let body = MessageBody( contentKey: ContentKey(rawValue: oldHeaderId), htmlContent: "<p>Body text</p>")
            try body.save(db)
        }

        // Simulate migration (what pushDraftToServer does).
        //
        // Stage D (`v70_dropMessageBodyHeaderFK`): deleting the header NO LONGER
        // removes its `messageBody` row — a content key is not a header id, so the
        // cascade would delete a row the other N−1 owners still hold. The old body
        // is therefore deleted EXPLICITLY, in the same transaction, exactly as
        // `DraftStore.pushDraftToServer` does. Read the body first regardless: the
        // re-key needs its HTML.
        try db.write { db in
            if let existing = try MessageHeader.fetchOne(db, key: oldHeaderId) {
                let savedHtml = try MessageBody.fetchOne(db, key: oldHeaderId)?.htmlContent
                try existing.delete(db)
                _ = try MessageBody.deleteOne(db, key: ContentKey(rawValue: oldHeaderId))
                var migrated = existing
                migrated.id = newHeaderId
                migrated.messageId = realMessageId
                try migrated.insert(db)
                let newBody = MessageBody( contentKey: ContentKey(rawValue: newHeaderId), htmlContent: savedHtml)
                try newBody.insert(db)
            }
        }

        // Old PK should be gone
        let oldHeader = try db.read { db in try MessageHeader.fetchOne(db, key: oldHeaderId) }
        #expect(oldHeader == nil)
        let oldBody = try db.read { db in try MessageBody.fetchOne(db, key: oldHeaderId) }
        #expect(oldBody == nil,
                "the old content row must be reclaimed EXPLICITLY — since v70 no cascade does it")

        // New PK should exist with preserved content
        let newHeader = try db.read { db in try MessageHeader.fetchOne(db, key: newHeaderId) }
        #expect(newHeader != nil)
        #expect(newHeader?.subject == "Migration Test")
        #expect(newHeader?.messageId == realMessageId)
        #expect(newHeader?.rfc822MessageId == "draft-rfc822@test.com")

        let newBody = try db.read { db in try MessageBody.fetchOne(db, key: newHeaderId) }
        #expect(newBody != nil)
        #expect(newBody?.htmlContent == "<p>Body text</p>")
    }

    // MARK: - Three-strategy deletion (simulates optimisticDeleteDraftHeader)

    @Test("Optimistic delete: strategy 1 — exact PK from serverDraftHeader")
    func deleteByExactPK() throws {
        let headerId = "acc1:DRAFT:19d4abc123"

        try db.write { db in
            var header = MessageHeader(
                messageId: "19d4abc123",
                subject: "Delete Test",
                from: "me@test.com",
                fromAddress: "me@test.com",
                to: "test@example.com",
                date: Date(),
                snippet: "",
                folderId: "acc1:DRAFT",
                accountId: "acc1",
                folderPath: "DRAFT",
                isInInbox: false
            )
            header.isRead = true
            try header.insert(db)
        }

        // Strategy 1: delete by exact PK
        try db.write { db in
            _ = try MessageHeader.deleteOne(db, key: headerId)
        }

        let result = try db.read { db in try MessageHeader.fetchOne(db, key: headerId) }
        #expect(result == nil)
    }

    @Test("Optimistic delete: strategy 3 — rfc822MessageId fallback")
    func deleteByRfc822MessageId() throws {
        let rfc822 = "draft-fallback@test.com"
        let folderId = "acc1:DRAFT"

        try db.write { db in
            var header = MessageHeader(
                messageId: "19d4different",
                subject: "RFC822 Fallback",
                from: "me@test.com",
                fromAddress: "me@test.com",
                to: "test@example.com",
                date: Date(),
                snippet: "",
                folderId: folderId,
                accountId: "acc1",
                folderPath: "DRAFT",
                isInInbox: false
            )
            header.rfc822MessageId = rfc822
            try header.insert(db)
        }

        // Strategy 3: delete by rfc822MessageId query
        try db.write { db in
            let matches = try MessageHeader
                .filter(Column("folderId") == folderId && Column("rfc822MessageId") == rfc822)
                .fetchAll(db)
            for header in matches {
                try header.delete(db)
            }
        }

        let remaining = try db.read { db in
            try MessageHeader.filter(Column("folderId") == folderId).fetchCount(db)
        }
        #expect(remaining == 0)
    }

    // MARK: - Mock provider draft operations

    @Test("MockEmailProvider.deleteDraft records call")
    func mockDeleteDraft() async throws {
        let provider = MockEmailProvider()
        try await provider.deleteDraft(
            identity: .gmail(resourceId: "draft-123"))
        let log = await provider.callLog
        #expect(log.contains { $0.contains("deleteDraft") })
    }

    @Test("Concrete Demo and Gmail providers never cross typed draft namespaces")
    func concreteProvidersRefuseForeignDraftNamespaces() async {
        let demo = DemoProvider(accountId: "demo-account")
        await #expect(throws: ProviderError.self) {
            try await demo.deleteDraft(
                identity: .gmail(resourceId: "gmail-resource"))
        }

        let http = FakeHTTP.Scenario()
        defer { http.close() }
        let gmail = GmailProvider(
            userEmail: "owner@example.com",
            accessToken: { _ in "unused-token" },
            session: http.session)
        await #expect(throws: ProviderError.self) {
            try await gmail.deleteDraft(
                identity: .demo(localId: "demo-local"))
        }
        #expect(http.recordedCalls().isEmpty)
    }

    // MARK: - isMessageNotFoundError (boundary with isPermanentlyInvalidError)

    @Test("isMessageNotFoundError: 404 is message-not-found, not permanently invalid")
    func messageNotFound404() {
        let error = ProviderError.networkError(underlying: NSError(domain: "Gmail", code: 404))
        let manager = AccountManager.shared
        #expect(manager.isMessageNotFoundError(error))
        #expect(!manager.isPermanentlyInvalidError(error))
    }

    @Test("isMessageNotFoundError: messageNotFound enum case")
    func messageNotFoundEnumCase() {
        let error = ProviderError.messageNotFound
        let manager = AccountManager.shared
        #expect(manager.isMessageNotFoundError(error))
    }
}
