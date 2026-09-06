/* This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at https://mozilla.org/MPL/2.0/. */

import Testing
import Foundation
import GRDB
@testable import TabMail

/// Tests for optimistic draft header creation, FTS indexing, headerComplete visibility,
/// and the `handleAgentToastTap` compose navigation path.
///
/// R15-FIX-4b — that last clause was FALSE from the day it was written until
/// 2026-08-06: no `@Test` here touched the toast-tap path, and the regression it
/// claimed to cover (the compose branch decoding session keys with a bare
/// `dropFirst`, after `ActiveAgentTracker.composeSessionKey` had moved to the
/// length-prefixed form) shipped underneath the claim. The claim is now true —
/// see "Agent toast navigation" at the bottom of this suite.
@Suite("Draft Optimistic Save Tests")
struct DraftOptimisticSaveTests {

    let db: DatabaseQueue

    init() throws {
        db = try TestDatabase.make()
        try TestDatabase.insertAccount(db, id: "acc1", email: "me@test.com")
        try TestDatabase.insertFolder(db, name: "Drafts", path: "DRAFT", role: .drafts, accountId: "acc1")
    }

    // MARK: - Optimistic header with headerComplete

    @Test("Optimistic draft header defaults to headerComplete=false")
    func headerDefaultsIncomplete() throws {
        let draftId = "hc-default-\(UUID().uuidString)"
        let folderId = "acc1:DRAFT"
        let placeholderMsgId = "draft-\(draftId)"
        let headerId = "\(folderId):\(placeholderMsgId)"

        try db.write { db in
            var header = MessageHeader(
                messageId: placeholderMsgId,
                subject: "Test",
                from: "me@test.com",
                fromAddress: "me@test.com",
                to: "recipient@test.com",
                date: Date(),
                snippet: "body",
                folderId: folderId,
                accountId: "acc1",
                folderPath: "DRAFT",
                isInInbox: false
            )
            header.rfc822MessageId = "draft-\(UUID().uuidString)@test.com"
            header.isRead = true
            // Do NOT set headerComplete — should default to false
            try header.insert(db)
        }

        let header = try db.read { db in try MessageHeader.fetchOne(db, key: headerId) }
        #expect(header != nil)
        #expect(header?.headerComplete == false)
    }

    @Test("Draft header with headerComplete=false is excluded from folder query")
    func incompleteHeaderExcludedFromQuery() throws {
        let draftId = "hc-query-\(UUID().uuidString)"
        let folderId = "acc1:DRAFT"
        let placeholderMsgId = "draft-\(draftId)"

        try db.write { db in
            var header = MessageHeader(
                messageId: placeholderMsgId,
                subject: "Invisible Draft",
                from: "me@test.com",
                fromAddress: "me@test.com",
                to: "recipient@test.com",
                date: Date(),
                snippet: "body",
                folderId: folderId,
                accountId: "acc1",
                folderPath: "DRAFT",
                isInInbox: false
            )
            header.rfc822MessageId = "draft-\(UUID().uuidString)@test.com"
            header.isRead = true
            // headerComplete defaults to false
            try header.insert(db)
        }

        // Query with headerComplete filter (same as InboxViewModel)
        let visible = try db.read { db in
            try MessageHeader
                .filter(Column("folderId") == folderId)
                .filter(Column("headerComplete") == true)
                .fetchAll(db)
        }
        #expect(visible.isEmpty)
    }

    @Test("Draft header with headerComplete=true appears in folder query")
    func completeHeaderVisibleInQuery() throws {
        let draftId = "hc-visible-\(UUID().uuidString)"
        let folderId = "acc1:DRAFT"
        let placeholderMsgId = "draft-\(draftId)"

        try db.write { db in
            var header = MessageHeader(
                messageId: placeholderMsgId,
                subject: "Visible Draft",
                from: "me@test.com",
                fromAddress: "me@test.com",
                to: "recipient@test.com",
                date: Date(),
                snippet: "body",
                folderId: folderId,
                accountId: "acc1",
                folderPath: "DRAFT",
                isInInbox: false
            )
            header.rfc822MessageId = "draft-\(UUID().uuidString)@test.com"
            header.isRead = true
            header.headerComplete = true
            try header.insert(db)
        }

        let visible = try db.read { db in
            try MessageHeader
                .filter(Column("folderId") == folderId)
                .filter(Column("headerComplete") == true)
                .fetchAll(db)
        }
        #expect(visible.count == 1)
        guard visible.count == 1 else { return }
        #expect(visible[0].subject == "Visible Draft")
    }

    // MARK: - Existing header update path

    @Test("Updating existing optimistic header preserves rfc822MessageId and body")
    func existingHeaderUpdatePreservesFields() throws {
        let draftId = "update-\(UUID().uuidString)"
        let folderId = "acc1:DRAFT"
        let placeholderMsgId = "draft-\(draftId)"
        let headerId = "\(folderId):\(placeholderMsgId)"
        let rfc822 = "draft-\(UUID().uuidString)@test.com"

        // Create initial optimistic header
        try db.write { db in
            var header = MessageHeader(
                messageId: placeholderMsgId,
                subject: "Original Subject",
                from: "me@test.com",
                fromAddress: "me@test.com",
                to: "old@test.com",
                date: Date(),
                snippet: "old body",
                folderId: folderId,
                accountId: "acc1",
                folderPath: "DRAFT",
                isInInbox: false
            )
            header.rfc822MessageId = rfc822
            header.isRead = true
            header.headerComplete = true
            try header.insert(db)

            let body = MessageBody( contentKey: ContentKey(rawValue: headerId), htmlContent: "<p>old body</p>")
            try body.save(db)
        }

        // Simulate update path (as queueDraftSave does for existing headers)
        try db.write { db in
            if var existing = try MessageHeader
                .filter(Column("folderId") == folderId && Column("rfc822MessageId") == rfc822)
                .fetchOne(db) {
                existing.subject = "Updated Subject"
                existing.to = "new@test.com"
                existing.snippet = "new body"
                existing.date = Date()
                try existing.update(db)

                let body = MessageBody( contentKey: ContentKey(rawValue: existing.id), htmlContent: "<p>new body</p>")
                try body.save(db)
            }
        }

        // Verify update
        let header = try db.read { db in
            try MessageHeader
                .filter(Column("folderId") == folderId && Column("rfc822MessageId") == rfc822)
                .fetchOne(db)
        }
        #expect(header?.subject == "Updated Subject")
        #expect(header?.to == "new@test.com")
        #expect(header?.rfc822MessageId == rfc822) // preserved

        let body = try db.read { db in try MessageBody.fetchOne(db, key: headerId) }
        #expect(body?.htmlContent?.contains("new body") == true)
    }

    // MARK: - PendingOperation creation

    @Test("Draft save creates PendingOperation with draftId, placeholder, and rfc822 protection IDs")
    func pendingOpIncludesAllProtectionIds() throws {
        let draftId = "op-test-\(UUID().uuidString)"
        let placeholderMsgId = "draft-\(draftId)"
        let rfc822 = "draft-\(UUID().uuidString)@test.com"

        // Insert draft with rfc822MessageId
        try db.write { db in
            var draft = Draft(
                id: draftId,
                accountId: "acc1",
                toJSON: "[\"test@example.com\"]",
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
            draft.rfc822MessageId = rfc822
            try draft.save(db)
        }

        // Simulate PendingOperation creation (from queueDraftSave)
        try db.write { db in
            let opMsgIds = [draftId, placeholderMsgId, rfc822]
            var saveDraftOp = PendingOperation(
                type: .saveDraft,
                messageIds: opMsgIds,
                accountId: "acc1",
                folderPath: "DRAFT"
            )
            try saveDraftOp.insert(db)
        }

        let ops = try db.read { db in
            try PendingOperation
                .filter(Column("type") == OperationType.saveDraft.rawValue)
                .fetchAll(db)
        }
        #expect(ops.count == 1)
        guard ops.count == 1 else { return }
        #expect(ops[0].messageIds.contains(draftId))
        #expect(ops[0].messageIds.contains(placeholderMsgId))
        #expect(ops[0].messageIds.contains(rfc822))
    }

    // MARK: - Draft not found edge case

    @Test("Missing draft produces no MessageHeader or PendingOperation")
    func missingDraftNoSideEffects() throws {
        let folderId = "acc1:DRAFT"
        let nonExistentDraftId = "missing-\(UUID().uuidString)"

        // Count before
        let headersBefore = try db.read { db in
            try MessageHeader.filter(Column("folderId") == folderId).fetchCount(db)
        }
        let opsBefore = try db.read { db in
            try PendingOperation.filter(Column("type") == OperationType.saveDraft.rawValue).fetchCount(db)
        }

        // Simulate queueDraftSave with missing draft
        try db.write { db in
            guard let _ = try Draft.fetchOne(db, key: nonExistentDraftId) else {
                return // Early return — no header or op created
            }
            // This code should NOT execute
            var saveDraftOp2 = PendingOperation(
                type: .saveDraft,
                messageIds: [nonExistentDraftId],
                accountId: "acc1",
                folderPath: "DRAFT"
            )
            try saveDraftOp2.insert(db)
        }

        // Verify nothing was created
        let headersAfter = try db.read { db in
            try MessageHeader.filter(Column("folderId") == folderId).fetchCount(db)
        }
        let opsAfter = try db.read { db in
            try PendingOperation.filter(Column("type") == OperationType.saveDraft.rawValue).fetchCount(db)
        }
        #expect(headersAfter == headersBefore)
        #expect(opsAfter == opsBefore)
    }

    // MARK: - Consolidation safety

    @Test("Sync consolidation: real IMAP header replaces optimistic header via rfc822MessageId")
    func syncConsolidationReplacesOptimisticHeader() throws {
        let folderId = "acc1:DRAFT"
        let rfc822 = "draft-\(UUID().uuidString)@test.com"
        let placeholderMsgId = "draft-placeholder"
        let realMessageId = "19d4abc123"
        let oldHeaderId = "\(folderId):\(placeholderMsgId)"
        let newHeaderId = "\(folderId):\(realMessageId)"

        // Create optimistic header
        try db.write { db in
            var header = MessageHeader(
                messageId: placeholderMsgId,
                subject: "Optimistic Draft",
                from: "me@test.com",
                fromAddress: "me@test.com",
                to: "test@example.com",
                date: Date(),
                snippet: "body",
                folderId: folderId,
                accountId: "acc1",
                folderPath: "DRAFT",
                isInInbox: false
            )
            header.rfc822MessageId = rfc822
            header.headerComplete = true
            try header.insert(db)

            let body = MessageBody( contentKey: ContentKey(rawValue: oldHeaderId), htmlContent: "<p>Draft body</p>")
            try body.save(db)
        }

        // Simulate sync consolidation (as SyncEngineDeltaSync does)
        try db.write { db in
            // Find optimistic header by rfc822MessageId
            let optimistic = try MessageHeader
                .filter(Column("folderId") == folderId && Column("rfc822MessageId") == rfc822)
                .fetchOne(db)
            #expect(optimistic != nil)

            // Preserve body
            let oldBody = try MessageBody.fetchOne(db, key: oldHeaderId)

            // Delete the optimistic header AND, explicitly, its content row. Since
            // `v70_dropMessageBodyHeaderFK` the header delete does not cascade to
            // `messageBody`; `SyncEngineDeltaSync` deletes the old key in the same
            // transaction, and this harness mirrors it.
            try optimistic?.delete(db)
            _ = try MessageBody.deleteOne(db, key: ContentKey(rawValue: oldHeaderId))

            // Insert real IMAP header
            var realHeader = MessageHeader(
                messageId: realMessageId,
                subject: "Optimistic Draft",
                from: "me@test.com",
                fromAddress: "me@test.com",
                to: "test@example.com",
                date: Date(),
                snippet: "body",
                folderId: folderId,
                accountId: "acc1",
                folderPath: "DRAFT",
                isInInbox: false
            )
            realHeader.rfc822MessageId = rfc822
            try realHeader.insert(db)

            // Re-insert preserved body with new headerId
            if let oldBody {
                let newBody = MessageBody( contentKey: ContentKey(rawValue: newHeaderId), htmlContent: oldBody.htmlContent)
                try newBody.save(db)
            }
        }

        // Verify: old header gone, new header exists with preserved body
        let oldHeader = try db.read { db in try MessageHeader.fetchOne(db, key: oldHeaderId) }
        #expect(oldHeader == nil)

        let newHeader = try db.read { db in try MessageHeader.fetchOne(db, key: newHeaderId) }
        #expect(newHeader != nil)
        #expect(newHeader?.rfc822MessageId == rfc822)

        let newBody = try db.read { db in try MessageBody.fetchOne(db, key: newHeaderId) }
        #expect(newBody?.htmlContent?.contains("Draft body") == true)
        // The re-key must MOVE the content, not duplicate it: with no cascade, an
        // old key left behind is a leak that only the TTL evictor would find.
        let oldBodyAfter = try db.read { db in try MessageBody.fetchOne(db, key: oldHeaderId) }
        #expect(oldBodyAfter == nil, "the old content key must be reclaimed explicitly")
        #expect(try db.read { try MessageBody.fetchCount($0) } == 1)
    }

    // MARK: - headerComplete set after FTS (simulated)

    @Test("headerComplete transitions from false to true after FTS indexing")
    func headerCompleteTransition() throws {
        let draftId = "fts-\(UUID().uuidString)"
        let folderId = "acc1:DRAFT"
        let placeholderMsgId = "draft-\(draftId)"
        let headerId = "\(folderId):\(placeholderMsgId)"

        // Create header with headerComplete=false (as queueDraftSave does)
        try db.write { db in
            var header = MessageHeader(
                messageId: placeholderMsgId,
                subject: "FTS Test",
                from: "me@test.com",
                fromAddress: "me@test.com",
                to: "test@example.com",
                date: Date(),
                snippet: "searchable",
                folderId: folderId,
                accountId: "acc1",
                folderPath: "DRAFT",
                isInInbox: false
            )
            header.rfc822MessageId = "draft-\(UUID().uuidString)@test.com"
            header.isRead = true
            try header.insert(db)
        }

        // Verify not visible yet
        let before = try db.read { db in
            try MessageHeader
                .filter(Column("folderId") == folderId)
                .filter(Column("headerComplete") == true)
                .fetchCount(db)
        }
        #expect(before == 0)

        // Simulate FTS indexing completion (sets headerComplete=1)
        try db.write { db in
            try db.execute(
                sql: "UPDATE messageHeader SET headerComplete = 1 WHERE id = ?",
                arguments: [headerId]
            )
        }

        // Now visible
        let after = try db.read { db in
            try MessageHeader
                .filter(Column("folderId") == folderId)
                .filter(Column("headerComplete") == true)
                .fetchCount(db)
        }
        #expect(after == 1)
    }

    // MARK: - Provider-level fetch failure for broken dates

    // The fix for the "transient 1970 header" bug lives at the provider level:
    // IMAPProvider, GmailProvider, and ExchangeProvider all return nil from their
    // parse functions when the date source is missing/unparseable. This treats
    // the broken message as a fetch failure — the caller uses compactMap to skip
    // it entirely. Next sync cycle retries, by which time the server has indexed.
    //
    // These tests document the contract: a broken date means the whole record
    // can't be trusted, so we don't try to salvage partial fields. Unit-testing
    // the provider parse functions directly requires complex GraphMessage/GmailMessage
    // fixtures, so we document the invariants here and rely on the downstream
    // sync code never receiving broken messages.

    @Test("MessageHeader with valid date inserts and is visible")
    func validDateInserts() throws {
        let folderId = "acc1:DRAFT"
        let headerId = "\(folderId):valid-1"
        let validDate = Date(timeIntervalSince1970: 1700000000)

        try db.write { db in
            var header = MessageHeader(
                messageId: "valid-1",
                subject: "Valid",
                from: "Me",
                fromAddress: "me@test.com",
                to: "you@test.com",
                date: validDate,
                snippet: "body",
                folderId: folderId,
                accountId: "acc1",
                folderPath: "DRAFT",
                isInInbox: false
            )
            header.headerComplete = true
            try header.insert(db)
        }

        let header = try db.read { db in try MessageHeader.fetchOne(db, key: headerId) }
        #expect(header?.date == validDate)
    }

    // MARK: - UID remap defense-in-depth

    @Test("UID remap preserves stale fields when match has epoch-0 date (defensive)")
    func uidRemapPreservesLocalFieldsWhenMatchEpochZero() throws {
        // Defense-in-depth: even though provider filtering should prevent broken
        // matches from reaching sync, the UID remap code guards against assigning
        // a 1970 date by checking `match.date.timeIntervalSince1970 >= 86400`.
        // If violated, the stale header's date/isRead/isFlagged are preserved.
        let folderId = "acc1:DRAFT"
        let rfc822 = "draft-\(UUID().uuidString)@test.com"
        let oldMessageId = "10"
        let newMessageId = "11"
        let oldHeaderId = "\(folderId):\(oldMessageId)"
        let newHeaderId = "\(folderId):\(newMessageId)"
        let validDate = Date(timeIntervalSince1970: 1700000000)

        try db.write { db in
            var header = MessageHeader(
                messageId: oldMessageId,
                subject: "Valid Draft",
                from: "Me",
                fromAddress: "me@test.com",
                to: "you@test.com",
                date: validDate,
                snippet: "body",
                folderId: folderId,
                accountId: "acc1",
                folderPath: "DRAFT",
                isInInbox: false
            )
            header.rfc822MessageId = rfc822
            header.headerComplete = true
            header.isRead = true
            header.isFlagged = true
            try header.insert(db)
        }

        // Simulate the remap with an epoch-0 match (shouldn't happen post-fix,
        // but the defensive check preserves local state if it does).
        let matchDate = Date(timeIntervalSince1970: 0)
        try db.write { db in
            guard let staleMsg = try MessageHeader.fetchOne(db, key: oldHeaderId) else { return }
            try staleMsg.delete(db)
            var migrated = staleMsg
            migrated.id = newHeaderId
            migrated.messageId = newMessageId
            if matchDate.timeIntervalSince1970 >= 86400 {
                migrated.isRead = false
                migrated.isFlagged = false
                migrated.date = matchDate
            }
            try migrated.insert(db)
        }

        let newHeader = try db.read { db in try MessageHeader.fetchOne(db, key: newHeaderId) }
        #expect(newHeader?.date == validDate)           // preserved
        #expect(newHeader?.isRead == true)              // preserved
        #expect(newHeader?.isFlagged == true)           // preserved
        #expect(newHeader?.messageId == newMessageId)   // UID remapped
    }

    @Test("UID remap applies remote state when match has valid date")
    func uidRemapAppliesRemoteStateWhenValid() throws {
        let folderId = "acc1:DRAFT"
        let rfc822 = "draft-\(UUID().uuidString)@test.com"
        let oldMessageId = "20"
        let newMessageId = "21"
        let oldHeaderId = "\(folderId):\(oldMessageId)"
        let newHeaderId = "\(folderId):\(newMessageId)"
        let staleDate = Date(timeIntervalSince1970: 1600000000)
        let matchDate = Date(timeIntervalSince1970: 1700000000)

        try db.write { db in
            var header = MessageHeader(
                messageId: oldMessageId,
                subject: "Stale",
                from: "Me",
                fromAddress: "me@test.com",
                to: "you@test.com",
                date: staleDate,
                snippet: "body",
                folderId: folderId,
                accountId: "acc1",
                folderPath: "DRAFT",
                isInInbox: false
            )
            header.rfc822MessageId = rfc822
            header.headerComplete = true
            header.isRead = false
            header.isFlagged = false
            try header.insert(db)
        }

        try db.write { db in
            guard let staleMsg = try MessageHeader.fetchOne(db, key: oldHeaderId) else { return }
            try staleMsg.delete(db)
            var migrated = staleMsg
            migrated.id = newHeaderId
            migrated.messageId = newMessageId
            if matchDate.timeIntervalSince1970 >= 86400 {
                migrated.isRead = true
                migrated.isFlagged = true
                migrated.date = matchDate
            }
            try migrated.insert(db)
        }

        let newHeader = try db.read { db in try MessageHeader.fetchOne(db, key: newHeaderId) }
        #expect(newHeader?.date == matchDate)
        #expect(newHeader?.isRead == true)
        #expect(newHeader?.isFlagged == true)
    }

    // MARK: - Agent toast navigation (R15-FIX-4b)

    /// THE INVARIANT: a compose session key produced by the live producer resolves,
    /// through the live toast-tap consumer, to the draft id the producer was given.
    ///
    /// Both ends are the real symbols — `ActiveAgentTracker.composeSessionKey` and
    /// `AgentToastPayload.destination`, the function `handleAgentToastTap` now calls.
    /// The format is never re-spelled here: a test that hand-built
    /// `"compose:\(n):\(epoch)\(draftId)"` would have stayed green through exactly
    /// the change that broke this path, because it would have been asserting the
    /// consumer against a copy of the format instead of against the producer.
    ///
    /// The draft ids and epochs below contain colons on purpose — that is the whole
    /// reason the key stopped being `compose:<draftId>` — and the second pair is the
    /// adversarial one: the two keys differ only in where the boundary falls, so a
    /// consumer that splits on the first (or last) colon returns a plausible-looking
    /// wrong id rather than failing loudly.
    @MainActor
    @Test("Toast tap opens the draft the compose session key named")
    func agentToastComposeKeyRoundTripsToTheProducersDraftId() {
        let cases: [(draftId: String, epoch: String)] = [
            ("draft-abc", "epoch-1"),
            ("reply:acct:msg", "legacy:op:42"),
            ("reply:acct:msg:legacy:op", "42"),
            ("default", "0"),
        ]
        for (draftId, epoch) in cases {
            let key = ActiveAgentTracker.composeSessionKey(draftId: draftId, epoch: epoch)
            #expect(
                AgentToastPayload.destination(forSessionKey: key) == .composeDraft(draftId: draftId),
                "session key for draftId=\(draftId) epoch=\(epoch) must resolve to that draft id"
            )
        }
    }

    /// The mirror-image over-correction this must never become: a lenient fallback
    /// that, when the length-prefixed parse fails, guesses with the old bare
    /// `dropFirst("compose:".count)`. A key we cannot decode names NO draft, so it
    /// must land on the pre-existing safe destination (expand the chat pill) rather
    /// than open a presenter on a fabricated id that resolves `.notFound` and
    /// dismisses in the user's face.
    @MainActor
    @Test("Undecodable compose keys route to the chat pill, never to a guessed draft")
    func undecodableComposeKeysNeverFabricateADraftId() {
        let undecodable = [
            "compose:draft-abc",        // the pre-port bare format
            "compose:",
            "compose::epoch-1draft",    // zero-length epoch count
            "compose:0:draft-abc",      // zero-length epoch
            "compose:9:short",          // count longer than the remainder
            "compose:notanumber:draft",
        ]
        for key in undecodable {
            #expect(
                AgentToastPayload.destination(forSessionKey: key) == .chatPill,
                "\(key) must not resolve to a draft"
            )
        }
    }

    /// Non-vacuity for the extraction: the other two branches still route where they
    /// did before the decision moved out of the view. Without this, a consumer that
    /// returned `.chatPill` for everything would pass the test above.
    @MainActor
    @Test("Message and inbox toast keys still route to their own destinations")
    func nonComposeToastKeysKeepTheirDestinations() {
        #expect(
            AgentToastPayload.destination(forSessionKey: "msg:acct1:stable:id:with:colons")
                == .message(accountId: "acct1", stableId: "stable:id:with:colons")
        )
        #expect(AgentToastPayload.destination(forSessionKey: "inbox") == .chatPill)
    }
}
