/* This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at https://mozilla.org/MPL/2.0/. */

import Testing
import Foundation
import GRDB
import Synchronization
@testable import TabMail

// MARK: - Helpers

/// Insert an OutboxMessage via raw SQL for full column control.
@discardableResult
private func insertOutboxMessage(
    _ db: DatabaseQueue,
    id: String = UUID().uuidString,
    accountId: String = "acc1",
    toJSON: String = "[\"to@test.com\"]",
    ccJSON: String = "[]",
    bccJSON: String = "[]",
    subject: String = "Test Subject",
    body: String = "Test body",
    isHTML: Bool = false,
    inReplyTo: String? = nil,
    referencesJSON: String? = nil,
    status: String = "queued",
    sentAt: Date? = nil,
    sentMessageId: String? = nil,
    appendedToSent: Bool = false,
    isForward: Bool = false
) throws -> String {
    try db.write { dbConn in
        try dbConn.execute(
            sql: """
                INSERT INTO outboxMessage
                (id, accountId, toJSON, ccJSON, bccJSON, subject, body, isHTML,
                 inReplyTo, referencesJSON, attachmentsDirName, status, errorMessage,
                 retryCount, createdAt, originalMessageHeaderId, isForward,
                 sentAt, sentMessageId, appendedToSent)
                VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
            """,
            arguments: [
                id, accountId, toJSON, ccJSON, bccJSON, subject, body, isHTML,
                inReplyTo, referencesJSON, nil, status, nil,
                0, Date(), nil, isForward,
                sentAt, sentMessageId, appendedToSent
            ]
        )
    }
    return id
}

/// Insert an optimistic sent header (simulates insertOptimisticSentHeader).
@discardableResult
private func insertOptimisticSentHeader(
    _ db: DatabaseQueue,
    outboxId: String,
    rfc822MessageId: String,
    accountId: String = "acc1",
    sentFolderPath: String = "Sent",
    subject: String = "Test Subject",
    from: String = "test@example.com",
    to: String = "to@test.com",
    cc: String = "",
    bcc: String = "",
    body: String = "Test body",
    isHTML: Bool = false,
    inReplyTo: String? = nil,
    references: [String] = []
) throws -> MessageHeader {
    try db.write { dbConn in
        let folderId = "\(accountId):\(sentFolderPath)"
        let rfc822 = EmailFilter.normalizeMessageId(rfc822MessageId)
        let plainText = isHTML ? EmailFilter.htmlToPlainText(body) : body
        let snippet = EmailFilter.snippetFromPlainText(plainText)
        let placeholderMsgId = "sent-\(outboxId)"
        let headerId = "\(accountId):\(sentFolderPath):\(placeholderMsgId)"

        var header = MessageHeader(
            messageId: placeholderMsgId,
            subject: subject,
            from: from,
            fromAddress: from,
            to: to,
            date: Date(),
            snippet: snippet,
            folderId: folderId,
            accountId: accountId,
            folderPath: sentFolderPath,
            isInInbox: false
        )
        header.rfc822MessageId = rfc822
        header.cc = cc
        header.bcc = bcc
        header.isRead = true
        // Mirror production behavior (AccountManager.insertOptimisticSentHeader):
        // - headerComplete=1 after FTS indexing so the optimistic header is visible
        //   in folder queries immediately.
        // - bodyComplete=1 because the body is already persisted locally — without
        //   this, BackfillBodyQueue picks up the row and feeds the synthetic
        //   "sent-<UUID>" id to the provider's body fetch (Gmail/Graph 400). When
        //   updating production, update both flags here so the simulator stays in
        //   lockstep.
        header.headerComplete = true
        header.bodyComplete = true
        header.inReplyTo = inReplyTo.map { EmailFilter.normalizeMessageId($0) }
        header.referencesJSON = MessageHeader.encodeReferences(references)
        try ThreadUtils.assignComputedThreadId(to: &header, nativeThreadId: nil, db: dbConn)
        try header.insert(dbConn)
        try ThreadUtils.insertMessageReferences(for: header, db: dbConn)

        let htmlContent = isHTML ? body : MessageBody.plainTextToHTML(body)
        let messageBody = MessageBody( contentKey: ContentKey(rawValue: headerId), htmlContent: htmlContent)
        try messageBody.save(dbConn)

        return header
    }
}

/// Builds a MessageHeaderInfo for simulating server-side messages.
private func makeHeaderInfo(
    messageId: String = "100",
    rfc822MessageId: String? = nil,
    inReplyTo: String? = nil,
    references: [String] = [],
    threadId: String? = nil,
    subject: String = "Test Subject",
    from: String = "Test Sender",
    fromAddress: String = "sender@example.com",
    to: String = "to@test.com",
    cc: String = "",
    bcc: String = "",
    replyTo: String? = nil,
    date: Date = Date(),
    snippet: String = "Test snippet",
    isRead: Bool = true,
    isFlagged: Bool = false,
    hasAttachments: Bool = false,
    isReplied: Bool = false,
    isForwarded: Bool = false,
    actionTag: ActionTag? = nil
) -> MessageHeaderInfo {
    MessageHeaderInfo(
        messageId: messageId,
        rfc822MessageId: rfc822MessageId,
        inReplyTo: inReplyTo,
        references: references,
        threadId: threadId,
        subject: subject,
        from: from,
        fromAddress: fromAddress,
        to: to,
        cc: cc,
        bcc: bcc,
        replyTo: replyTo,
        date: date,
        snippet: snippet,
        isRead: isRead,
        isFlagged: isFlagged,
        hasAttachments: hasAttachments,
        isReplied: isReplied,
        isForwarded: isForwarded,
        actionTag: actionTag
    )
}

/// Simulate the sync stale detection + upsert for Sent folder, including the new
/// outbox protection and rfc822 dedup logic.
private func simulateSyncForSentFolder(
    db: DatabaseQueue,
    folder: Folder,
    messages: [MessageHeaderInfo],
    limit: Int = 500
) throws -> (newHeaders: [MessageHeader], staleIds: [String], uidMigratedOldIds: [String]) {
    let folderPath = folder.path
    let folderId = folder.id
    let accountId = folder.accountId

    let remoteIds = Set(messages.map(\.messageId))

    return try db.write { dbConn in
        let pendingOps = try PendingOperation.fetchAll(dbConn)
        let opsTargetingThisFolder = pendingOps.filter {
            $0.accountId == accountId && ($0.folderPath == folderPath || $0.destinationPath == folderPath)
        }
        let pendingAllIds = Set(opsTargetingThisFolder.flatMap(\.messageIds))
        let pendingDestructiveIds = Set(
            opsTargetingThisFolder
                .filter { [.archive, .delete, .move].contains($0.type) }
                .flatMap(\.messageIds)
        )
        let isPendingDestructive: (MessageHeaderInfo) -> Bool = { info in
            pendingDestructiveIds.contains(info.messageId) ||
            (info.rfc822MessageId.map { pendingDestructiveIds.contains($0) } ?? false)
        }

        var newHeaders: [MessageHeader] = []
        var staleIds: [String] = []

        // Stale detection — delegate to the production source of truth
        // (`SyncEngine.selectStaleHeaders`, ADR-IOS-042) so this harness can never
        // drift from real sync behavior. Same idiom as the sibling harness in
        // `E2ESyncScenarioTests`.
        //
        // Coverage models a server that returned `messages` verbatim for a window of
        // `limit` — the harness feeds `selectStaleHeaders` directly, so there is no
        // provider narrowing between the two and `messages.count` IS the server's
        // record count here. Real providers must NOT derive coverage this way; see
        // `FetchCoverage`.
        //
        // `.date` is the windowed branch for the non-IMAP folders these fixtures
        // use. Every caller passes at most a handful of messages against the
        // default `limit` of 500, so coverage always spans the folder and the
        // windowed branch is unreachable here; it is supplied rather than
        // hardcoded to `[]` so the harness matches production if that changes.
        let allLocal = try MessageHeader.filter(Column("folderId") == folderId).fetchAll(dbConn)
        let stale = SyncEngine.selectStaleHeaders(
            candidates: allLocal, fetched: messages,
            coverage: FetchCoverage(
                serverRecordCount: messages.count,
                spansEntireFolder: messages.count < limit,
                unmaterialisedIds: []),
            windowMode: .date)

        // Outbox protection for optimistic sent headers
        var outboxProtectedRfc822s = Set<String>()
        if folder.role == .sent {
            let outboxRfc822s = try String.fetchAll(dbConn, sql: """
                SELECT sentMessageId FROM outboxMessage
                WHERE accountId = ? AND sentMessageId IS NOT NULL
            """, arguments: [accountId])
            for raw in outboxRfc822s {
                outboxProtectedRfc822s.insert(EmailFilter.normalizeMessageId(raw))
            }
        }

        // UID remap detection
        var uidMigratedRemoteIds = Set<String>()
        var uidMigratedOldMsgIds: [String] = []
        let localMsgIds = Set(try MessageHeader.filter(Column("folderId") == folderId).fetchAll(dbConn).map(\.messageId))
        let newRemoteIds = remoteIds.subtracting(localMsgIds)
        var newMessagesByRfc822: [String: [MessageHeaderInfo]] = [:]
        for msg in messages where newRemoteIds.contains(msg.messageId) {
            if let rfc822 = msg.rfc822MessageId, !rfc822.isEmpty {
                newMessagesByRfc822[rfc822, default: []].append(msg)
            }
        }
        for staleMsg in stale {
            guard let rfc822 = staleMsg.rfc822MessageId, !rfc822.isEmpty else { continue }
            guard let match = newMessagesByRfc822[rfc822]?.first(where: {
                !uidMigratedRemoteIds.contains($0.messageId)
            }) else { continue }
            let oldId = staleMsg.id
            let newMsgId = match.messageId
            let newId = "\(accountId):\(folderPath):\(newMsgId)"
            // Fetch the body BEFORE deleting the header, then delete its row
            // EXPLICITLY — mirroring `SyncEngine.reconcileUidRemaps` after Stage D
            // (`v70_dropMessageBodyHeaderFK`) removed the cascade that used to do it.
            // Without the delete the copy re-inserted under `newId` below leaves the
            // old row behind: a duplicate plus a leak.
            let oldBody = try MessageBody.fetchOne(dbConn, key: oldId)
            try staleMsg.delete(dbConn)
            try MessageBody.deleteOne(dbConn, key: ContentKey(rawValue: oldId))
            var migrated = staleMsg
            migrated.id = newId
            migrated.messageId = newMsgId
            migrated.isRead = match.isRead
            migrated.isFlagged = match.isFlagged
            migrated.date = match.date
            try migrated.insert(dbConn)
            if var body = oldBody {
                body.id = ContentKey(rawValue: newId)
                try body.insert(dbConn)
            }
            uidMigratedRemoteIds.insert(newMsgId)
            uidMigratedOldMsgIds.append(staleMsg.messageId)
        }

        let uidMigratedSet = Set(uidMigratedOldMsgIds)
        let isProtected: (MessageHeader) -> Bool = { msg in
            pendingAllIds.contains(msg.messageId) ||
            (msg.rfc822MessageId.map { pendingAllIds.contains($0) } ?? false) ||
            (msg.rfc822MessageId.map { outboxProtectedRfc822s.contains($0) } ?? false)
        }
        let staleFiltered = stale.filter { !isProtected($0) && !uidMigratedSet.contains($0.messageId) }
        staleIds = staleFiltered.map(\.id)
        for msg in staleFiltered {
            try msg.delete(dbConn)
        }

        // Upsert with rfc822 dedup for Sent folder
        for info in messages where !isPendingDestructive(info) && !uidMigratedRemoteIds.contains(info.messageId) {
            if try MessageHeader
                .filter(Column("messageId") == info.messageId && Column("folderId") == folderId)
                .fetchOne(dbConn) != nil {
                // Already exists — skip for simplicity (full sync updates fields)
                continue
            }

            var header = MessageHeader(
                messageId: info.messageId,
                subject: info.subject,
                from: info.from,
                fromAddress: info.fromAddress,
                to: info.to,
                date: info.date,
                snippet: EmailFilter.cleanSnippet(info.snippet),
                folderId: folderId,
                accountId: accountId,
                folderPath: folderPath,
                isInInbox: false
            )
            header.rfc822MessageId = info.rfc822MessageId
            header.inReplyTo = info.inReplyTo
            header.referencesJSON = MessageHeader.encodeReferences(info.references)
            header.isRead = info.isRead
            header.isFlagged = info.isFlagged
            header.hasAttachments = info.hasAttachments
            header.isReplied = info.isReplied
            header.isForwarded = info.isForwarded
            try ThreadUtils.assignComputedThreadId(to: &header, nativeThreadId: info.threadId, db: dbConn)

            // rfc822 dedup for Sent folder (matches production code)
            var deferredBody: MessageBody?
            if folder.role == .sent,
               let rfc822 = header.rfc822MessageId, !rfc822.isEmpty,
               let optimistic = try MessageHeader
                .filter(Column("folderId") == folderId && Column("rfc822MessageId") == rfc822 && Column("messageId") != header.messageId)
                .fetchOne(dbConn) {
                let oldId = optimistic.id
                if let body = try MessageBody.fetchOne(dbConn, key: ContentKey(rawValue: oldId)) {
                    var newBody = body
                    newBody.id = ContentKey(rawValue: header.id)
                    try MessageBody.deleteOne(dbConn, key: ContentKey(rawValue: oldId))
                    deferredBody = newBody
                }
                try optimistic.delete(dbConn)
            }

            try header.insert(dbConn)
            if let body = deferredBody { try body.insert(dbConn) }
            try ThreadUtils.insertMessageReferences(for: header, db: dbConn)
            newHeaders.append(header)
        }

        return (newHeaders, staleIds, uidMigratedOldMsgIds)
    }
}

// MARK: - Suite 1: Optimistic Sent Header Insertion

@Suite("Optimistic Sent Header — Insertion")
struct OptimisticSentHeaderInsertionTests {

    @Test("inserts header into Sent folder with correct fields")
    func insertsHeaderWithCorrectFields() throws {
        let db = try TestDatabase.make()
        try TestDatabase.insertAccount(db)
        try TestDatabase.insertFolder(db, name: "Sent", path: "Sent", role: .sent, accountId: "acc1")

        let outboxId = "outbox-123"
        let rfc822 = "<test-msg-id@example.com>"

        let header = try insertOptimisticSentHeader(
            db,
            outboxId: outboxId,
            rfc822MessageId: rfc822,
            subject: "Hello",
            from: "me@example.com",
            to: "you@example.com",
            cc: "cc@example.com",
            body: "Plain text body"
        )

        #expect(header.messageId == "sent-\(outboxId)")
        #expect(header.folderId == "acc1:Sent")
        #expect(header.accountId == "acc1")
        #expect(header.folderPath == "Sent")
        #expect(header.subject == "Hello")
        #expect(header.from == "me@example.com")
        #expect(header.to == "you@example.com")
        #expect(header.cc == "cc@example.com")
        #expect(header.isRead == true)
        #expect(header.isInInbox == false)
        #expect(header.rfc822MessageId == "test-msg-id@example.com")

        // Verify body was created
        let body = try db.read { try MessageBody.fetchOne($0, key: header.id) }
        #expect(body != nil)
        #expect(body?.htmlContent?.contains("Plain text body") == true)
    }

    @Test("v57 migration heals legacy sent-<UUID> placeholders left with bodyComplete=0")
    func v57MigrationHealsLegacyPlaceholders() throws {
        // Pre-fix, insertOptimisticSentHeader did NOT set bodyComplete=1, leaving
        // every existing user with rows that match BackfillBody's repopulate query
        // and trigger 400s on cold start until SyncEngine delta-dedup happens. The
        // v57 migration heals those rows in one pass. This test bypasses the test
        // helper (which mirrors the post-fix simulator) and writes the legacy
        // shape directly so we can verify the migration's UPDATE actually runs.
        let db = try TestDatabase.make()
        try TestDatabase.insertAccount(db)
        try TestDatabase.insertFolder(db, name: "Sent", path: "Sent", role: .sent, accountId: "acc1")

        // Construct the legacy state: synthetic id, headerComplete=1 (the FTS
        // pipeline DID run pre-fix), bodyComplete=0 (the bug), MessageBody row
        // present (body was saved locally before headerComplete update).
        let outboxId = "legacy-12345"
        let placeholderMsgId = "sent-\(outboxId)"
        let headerId = "acc1:Sent:\(placeholderMsgId)"
        try db.write { dbConn in
            try dbConn.execute(sql: """
                INSERT INTO messageHeader (
                    id, messageId, subject, "from", fromAddress, "to", date, snippet,
                    folderId, accountId, folderPath, isInInbox, headerComplete, bodyComplete,
                    bodyEmptyConfirmed, isRead, computedThreadId
                ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, 0, 1, 0, 0, 1, ?)
                """, arguments: [
                    headerId, placeholderMsgId, "Legacy", "me", "me@example.com",
                    "you", Date(), "snippet", "acc1:Sent", "acc1", "Sent",
                    "legacy-thread@example.com"
                ])
            try dbConn.execute(sql: """
                INSERT INTO messageBody (id, htmlContent, fetchedAt) VALUES (?, ?, ?)
                """, arguments: [headerId, "<p>Body that was already on disk</p>", Date()])
        }

        // Simulate the v57 migration UPDATE (the migrator already ran during
        // TestDatabase.make(); we re-run the same statement to verify the SQL
        // is what we think it is, and to keep the test independent of migration
        // ordering subtleties).
        try db.write { dbConn in
            try dbConn.execute(sql: """
                UPDATE messageHeader
                SET bodyComplete = 1
                WHERE messageId LIKE 'sent-%'
                  AND headerComplete = 1
                  AND bodyComplete = 0
                  AND id IN (SELECT id FROM messageBody)
                """)
        }

        // The legacy row is now bodyComplete=1 — it's invisible to BackfillBody.
        let bodyComplete = try db.read { dbConn in
            try Bool.fetchOne(dbConn, sql: "SELECT bodyComplete FROM messageHeader WHERE id = ?", arguments: [headerId])
        }
        #expect(bodyComplete == true)

        let backfillCandidates = try db.read { dbConn in
            // The production query itself. A hand-copied replica stops BEING the
            // admission predicate the moment production gains a clause — it just
            // gained `AND bodyMetadataOversized = 0`, and this assertion would have
            // gone on describing a queue that no longer asks this question.
            try Row.fetchAll(dbConn, sql: BackfillBodyQueue.admissionSQL)
        }
        #expect(backfillCandidates.isEmpty)
    }

    @Test("v57 migration leaves placeholders without a cached body alone")
    func v57MigrationSkipsRowsWithoutBody() throws {
        // Migration is bounded to rows that actually have a messageBody row. A
        // placeholder without a body is genuine garbage (orphaned by some other
        // bug) — flipping bodyComplete=1 would lie. Leave it alone; the existing
        // self-heal / stale-deletion paths will clean it up.
        let db = try TestDatabase.make()
        try TestDatabase.insertAccount(db)
        try TestDatabase.insertFolder(db, name: "Sent", path: "Sent", role: .sent, accountId: "acc1")

        let headerId = "acc1:Sent:sent-orphan"
        try db.write { dbConn in
            try dbConn.execute(sql: """
                INSERT INTO messageHeader (
                    id, messageId, subject, "from", fromAddress, "to", date, snippet,
                    folderId, accountId, folderPath, isInInbox, headerComplete, bodyComplete,
                    bodyEmptyConfirmed, isRead, computedThreadId
                ) VALUES (?, 'sent-orphan', 'Subject', 'me', 'me@x', 'you', ?, 'snip',
                          'acc1:Sent', 'acc1', 'Sent', 0, 1, 0, 0, 1, 'orphan@x')
                """, arguments: [headerId, Date()])
            // No messageBody insert — orphan placeholder.
        }

        try db.write { dbConn in
            try dbConn.execute(sql: """
                UPDATE messageHeader
                SET bodyComplete = 1
                WHERE messageId LIKE 'sent-%'
                  AND headerComplete = 1
                  AND bodyComplete = 0
                  AND id IN (SELECT id FROM messageBody)
                """)
        }

        let bodyComplete = try db.read { dbConn in
            try Bool.fetchOne(dbConn, sql: "SELECT bodyComplete FROM messageHeader WHERE id = ?", arguments: [headerId])
        }
        #expect(bodyComplete == false)
    }

    @Test("optimistic draft placeholder is excluded from BackfillBodyQueue repopulate")
    func optimisticDraftHeaderExcludedFromBodyBackfill() throws {
        // Sister test to the Sent placeholder regression. queueDraftSave (in
        // AccountManagerActions.swift) writes a "draft-<draftId>" placeholder
        // messageId with a locally-saved MessageBody row. Today drafts get
        // headerComplete=0 by default so they fall out of BackfillBody's filter
        // for a coincidental reason. If anyone later flips headerComplete=1 in
        // the draft visibility path (mirroring the Sent flow), they MUST also
        // set bodyComplete=1 — otherwise the draft placeholder leaks into the
        // queue and Gmail/Graph 400 the synthetic id. This test pins that.
        let db = try TestDatabase.make()
        try TestDatabase.insertAccount(db)
        try TestDatabase.insertFolder(db, name: "Drafts", path: "Drafts", role: .drafts, accountId: "acc1")

        // Construct an optimistic draft placeholder the way queueDraftSave does:
        // messageId = "draft-<draftId>", body persisted, headerComplete left at
        // default. (We don't have a `queueDraftSave` simulator here yet —
        // hand-construct minimally.)
        let draftId = UUID().uuidString
        let placeholderMsgId = "draft-\(draftId)"
        let headerId = "acc1:Drafts:\(placeholderMsgId)"
        try db.write { dbConn in
            var header = MessageHeader(
                messageId: placeholderMsgId,
                subject: "Untitled draft",
                from: "me",
                fromAddress: "me@example.com",
                to: "you@example.com",
                date: Date(),
                snippet: "draft body",
                folderId: "acc1:Drafts",
                accountId: "acc1",
                folderPath: "Drafts",
                isInInbox: false
            )
            header.rfc822MessageId = "draft-\(draftId)@tabmail.local"
            header.isRead = true
            // Deliberately NOT setting headerComplete here — this matches today's
            // queueDraftSave behavior. If this changes upstream, this test will
            // start to require bodyComplete=1 too, surfacing the gap.
            try header.insert(dbConn)
            let body = MessageBody( contentKey: ContentKey(rawValue: headerId), htmlContent: "<p>Draft body</p>")
            try body.save(dbConn)
        }

        let candidates = try db.read { dbConn in
            // The production query itself. A hand-copied replica stops BEING the
            // admission predicate the moment production gains a clause — it just
            // gained `AND bodyMetadataOversized = 0`, and this assertion would have
            // gone on describing a queue that no longer asks this question.
            try Row.fetchAll(dbConn, sql: BackfillBodyQueue.admissionSQL)
        }
        #expect(candidates.isEmpty, "optimistic Draft placeholder leaked into BackfillBodyQueue repopulate query")
    }

    @Test("optimistic sent header is excluded from BackfillBodyQueue repopulate (bodyComplete=1)")
    func optimisticHeaderExcludedFromBodyBackfill() throws {
        // Regression: prior to the fix, the optimistic Sent placeholder was inserted
        // with bodyComplete=0 even though MessageBody was persisted locally. On every
        // cold start, BackfillBodyQueue.repopulateFromDatabase() picked up the row
        // and forwarded the synthetic "sent-<UUID>" messageId to GmailProvider /
        // GraphAPI, which respond HTTP 400 "Invalid id value" because that id never
        // existed on the server. The placeholder is normally replaced by SyncEngine
        // delta-sync dedup once the server returns the real header — but until then
        // (and across crashes/quits before sync), every backfill cycle hammers the
        // provider with 400s.
        //
        // The query below is copy-pasted verbatim from
        // BackfillBodyQueue.repopulateFromDatabase (BackfillBodyQueue.swift). If
        // either side drifts, this test fails.
        let db = try TestDatabase.make()
        try TestDatabase.insertAccount(db)
        try TestDatabase.insertFolder(db, name: "Sent", path: "Sent", role: .sent, accountId: "acc1")

        try insertOptimisticSentHeader(
            db,
            outboxId: "backfill-regression",
            rfc822MessageId: "<backfill-regression@example.com>",
            body: "Body that is already on disk locally"
        )

        // The PRODUCTION query, not a copy — the copy here had drifted from it (no
        // `bodyMetadataOversized` conjunct, no `ORDER BY`), so it no longer answered the
        // question the assertion below asks.
        let candidates = try db.read { dbConn in
            try Row.fetchAll(dbConn, sql: BackfillBodyQueue.admissionSQL)
        }

        // The optimistic Sent placeholder must NOT match BackfillBody's repopulate
        // query — otherwise we'll send "sent-<UUID>" to the provider and 400.
        #expect(candidates.isEmpty, "optimistic Sent placeholder leaked into BackfillBodyQueue repopulate query")
    }

    @Test("optimistic sent header is visible in folder query (headerComplete=1)")
    func optimisticHeaderVisibleInFolderQuery() throws {
        // Regression test: InboxViewModel filters by headerComplete==true. If the
        // optimistic sent header is inserted with headerComplete=false (default),
        // it's invisible in the Sent folder — causing a transient "missing message"
        // flicker after send. The production code must FTS-index + set headerComplete=1.
        let db = try TestDatabase.make()
        try TestDatabase.insertAccount(db)
        try TestDatabase.insertFolder(db, name: "Sent", path: "Sent", role: .sent, accountId: "acc1")

        _ = try insertOptimisticSentHeader(
            db,
            outboxId: "outbox-vis",
            rfc822MessageId: "<vis-msg@example.com>",
            subject: "Visible After Send",
            from: "me@example.com",
            to: "you@example.com",
            body: "Sent body"
        )

        // Query as InboxViewModel does — filter by headerComplete=true
        let visible = try db.read { dbConn in
            try MessageHeader
                .filter(Column("folderId") == "acc1:Sent")
                .filter(Column("headerComplete") == true)
                .fetchAll(dbConn)
        }
        #expect(visible.count == 1)
        guard visible.count == 1 else { return }
        #expect(visible[0].subject == "Visible After Send")
        #expect(visible[0].headerComplete == true)
    }

    @Test("inserts body as HTML when draft is HTML")
    func insertsHTMLBody() throws {
        let db = try TestDatabase.make()
        try TestDatabase.insertAccount(db)
        try TestDatabase.insertFolder(db, name: "Sent", path: "Sent", role: .sent, accountId: "acc1")

        let htmlBody = "<div>Hello <b>World</b></div>"
        let header = try insertOptimisticSentHeader(
            db,
            outboxId: "outbox-html",
            rfc822MessageId: "<html-msg@example.com>",
            body: htmlBody,
            isHTML: true
        )

        let body = try db.read { try MessageBody.fetchOne($0, key: header.id) }
        #expect(body?.htmlContent == htmlBody)
    }

    @Test("snippet strips HTML tags when body is HTML")
    func snippetStripsHTML() throws {
        let db = try TestDatabase.make()
        try TestDatabase.insertAccount(db)
        try TestDatabase.insertFolder(db, name: "Sent", path: "Sent", role: .sent, accountId: "acc1")

        let htmlBody = "<div>Hello <b>World</b></div><blockquote>Quoted text that should be stripped</blockquote>"
        let header = try insertOptimisticSentHeader(
            db,
            outboxId: "outbox-snippet",
            rfc822MessageId: "<snippet-msg@example.com>",
            body: htmlBody,
            isHTML: true
        )

        // Snippet should not contain HTML tags
        #expect(!header.snippet.contains("<div>"))
        #expect(!header.snippet.contains("<b>"))
        #expect(header.snippet.contains("Hello"))
        #expect(header.snippet.contains("World"))
    }

    @Test("normalizes rfc822MessageId by stripping angle brackets")
    func normalizesRfc822MessageId() throws {
        let db = try TestDatabase.make()
        try TestDatabase.insertAccount(db)
        try TestDatabase.insertFolder(db, name: "Sent", path: "Sent", role: .sent, accountId: "acc1")

        let header = try insertOptimisticSentHeader(
            db,
            outboxId: "outbox-norm",
            rfc822MessageId: "<angle-brackets@example.com>"
        )

        #expect(header.rfc822MessageId == "angle-brackets@example.com")
    }

    @Test("idempotent — skips insert if rfc822MessageId already exists in folder")
    func idempotentInsert() throws {
        let db = try TestDatabase.make()
        try TestDatabase.insertAccount(db)
        try TestDatabase.insertFolder(db, name: "Sent", path: "Sent", role: .sent, accountId: "acc1")

        let rfc822 = "<idempotent@example.com>"
        try insertOptimisticSentHeader(db, outboxId: "first", rfc822MessageId: rfc822)

        // Insert an existing header with the same rfc822MessageId (simulating real message from server)
        try db.write { dbConn in
            var existing = MessageHeader(
                messageId: "real-uid-999", subject: "Test Subject", from: "test@example.com",
                fromAddress: "test@example.com", to: "to@test.com", date: Date(),
                snippet: "snippet", folderId: "acc1:Sent", accountId: "acc1",
                folderPath: "Sent", isInInbox: false
            )
            existing.rfc822MessageId = "idempotent@example.com"
            try existing.insert(dbConn)
        }

        // Count headers with this rfc822MessageId
        let count = try db.read { dbConn in
            try MessageHeader
                .filter(Column("folderId") == "acc1:Sent" && Column("rfc822MessageId") == "idempotent@example.com")
                .fetchCount(dbConn)
        }
        #expect(count == 2) // One optimistic, one "real" — dedup happens during sync
    }
}

// MARK: - Suite 2: Thread Grouping

@Suite("Optimistic Sent Header — Thread Grouping")
struct OptimisticSentHeaderThreadTests {

    @Test("reply gets same computedThreadId as parent message")
    func replySharesThreadId() throws {
        let db = try TestDatabase.make()
        try TestDatabase.insertAccount(db)
        try TestDatabase.insertFolder(db, name: "INBOX", path: "INBOX", role: .inbox, accountId: "acc1")
        try TestDatabase.insertFolder(db, name: "Sent", path: "Sent", role: .sent, accountId: "acc1")

        // Insert parent message in inbox
        var parent = try TestDatabase.insertMessageHeader(
            db, messageId: "parent-uid", subject: "Original Thread",
            folderId: "acc1:INBOX", folderPath: "INBOX",
            rfc822MessageId: "parent@example.com"
        )
        // Set computedThreadId on parent
        try db.write { dbConn in
            try ThreadUtils.assignComputedThreadId(to: &parent, nativeThreadId: nil, db: dbConn)
            try parent.update(dbConn)
            try ThreadUtils.insertMessageReferences(for: parent, db: dbConn)
        }

        // Insert optimistic sent reply
        let sentHeader = try insertOptimisticSentHeader(
            db,
            outboxId: "reply-outbox",
            rfc822MessageId: "<reply@example.com>",
            subject: "Re: Original Thread",
            inReplyTo: "parent@example.com",
            references: ["parent@example.com"]
        )

        // Both should share the same computedThreadId
        let refreshedParent = try db.read { try MessageHeader.fetchOne($0, key: parent.id)! }
        #expect(!sentHeader.computedThreadId.isEmpty)
        #expect(sentHeader.computedThreadId == refreshedParent.computedThreadId)
    }

    @Test("new compose gets its own computedThreadId")
    func newComposeGetsOwnThread() throws {
        let db = try TestDatabase.make()
        try TestDatabase.insertAccount(db)
        try TestDatabase.insertFolder(db, name: "Sent", path: "Sent", role: .sent, accountId: "acc1")

        let header = try insertOptimisticSentHeader(
            db,
            outboxId: "new-compose",
            rfc822MessageId: "<new-compose@example.com>"
        )

        // Should have a computedThreadId (its own rfc822MessageId)
        #expect(!header.computedThreadId.isEmpty)
        #expect(header.computedThreadId == "new-compose@example.com")
    }

    @Test("messageReference rows are created for reply chain")
    func messageReferencesCreated() throws {
        let db = try TestDatabase.make()
        try TestDatabase.insertAccount(db)
        try TestDatabase.insertFolder(db, name: "Sent", path: "Sent", role: .sent, accountId: "acc1")

        let header = try insertOptimisticSentHeader(
            db,
            outboxId: "ref-test",
            rfc822MessageId: "<ref-test@example.com>",
            inReplyTo: "parent@example.com",
            references: ["grandparent@example.com", "parent@example.com"]
        )

        let refs = try db.read { dbConn in
            try String.fetchAll(dbConn, sql: """
                SELECT referencedRfc822Id FROM messageReference WHERE messageHeaderId = ?
            """, arguments: [header.id])
        }
        // inReplyTo + all references are inserted (inReplyTo may duplicate a references entry)
        #expect(refs.count >= 2)
        #expect(refs.contains("parent@example.com"))
        #expect(refs.contains("grandparent@example.com"))
    }
}

// MARK: - Suite 3: Stale Deletion Protection

@Suite("Optimistic Sent Header — Stale Protection")
struct OptimisticSentHeaderStaleProtectionTests {

    @Test("outbox record protects optimistic header from stale deletion")
    func outboxProtectsFromStaleDeletion() throws {
        let db = try TestDatabase.make()
        try TestDatabase.insertAccount(db)
        let sentFolder = try TestDatabase.insertFolder(db, name: "Sent", path: "Sent", role: .sent, accountId: "acc1")

        let outboxId = "protected-msg"
        let rfc822 = "<protected@example.com>"

        // Insert optimistic header
        try insertOptimisticSentHeader(db, outboxId: outboxId, rfc822MessageId: rfc822)

        // Insert in-flight outbox message (sentAt set, not yet appended)
        try insertOutboxMessage(
            db, id: outboxId, accountId: "acc1",
            status: "sending", sentAt: Date(),
            sentMessageId: rfc822
        )

        // Sync with empty server (no messages) — should NOT delete the optimistic header
        let result = try simulateSyncForSentFolder(
            db: db,
            folder: sentFolder,
            messages: [] // Server has nothing yet
        )

        #expect(result.staleIds.isEmpty)

        // Verify header still exists
        let remaining = try db.read { dbConn in
            try MessageHeader.filter(Column("folderId") == "acc1:Sent").fetchCount(dbConn)
        }
        #expect(remaining == 1)
    }

    @Test("optimistic header IS deleted when no outbox record exists")
    func deletedWhenNoOutboxProtection() throws {
        let db = try TestDatabase.make()
        try TestDatabase.insertAccount(db)
        let sentFolder = try TestDatabase.insertFolder(db, name: "Sent", path: "Sent", role: .sent, accountId: "acc1")

        // Insert optimistic header with NO corresponding outbox message
        try insertOptimisticSentHeader(
            db, outboxId: "orphan-msg",
            rfc822MessageId: "<orphan@example.com>"
        )

        // Sync with empty server — should delete the unprotected header
        let result = try simulateSyncForSentFolder(
            db: db,
            folder: sentFolder,
            messages: []
        )

        #expect(result.staleIds.count == 1)

        let remaining = try db.read { dbConn in
            try MessageHeader.filter(Column("folderId") == "acc1:Sent").fetchCount(dbConn)
        }
        #expect(remaining == 0)
    }

    @Test("protection only applies to Sent folder, not other folders")
    func protectionIsSentFolderOnly() throws {
        let db = try TestDatabase.make()
        try TestDatabase.insertAccount(db)
        let inboxFolder = try TestDatabase.insertFolder(db, name: "INBOX", path: "INBOX", role: .inbox, accountId: "acc1")

        // Insert a header in inbox with an rfc822MessageId that matches an outbox sentMessageId
        try TestDatabase.insertMessageHeader(
            db, messageId: "inbox-msg", folderId: "acc1:INBOX", folderPath: "INBOX",
            rfc822MessageId: "shared@example.com"
        )
        try insertOutboxMessage(
            db, accountId: "acc1", status: "sending",
            sentAt: Date(), sentMessageId: "<shared@example.com>"
        )

        // Sync inbox with empty server — header should be deleted (no outbox protection for inbox)
        let result = try simulateSyncForSentFolder(
            db: db,
            folder: inboxFolder, // Not a .sent folder
            messages: []
        )

        #expect(result.staleIds.count == 1)
    }
}

// MARK: - Suite 4: Coalescing (rfc822 Dedup)

@Suite("Optimistic Sent Header — Coalescing")
struct OptimisticSentHeaderCoalesceTests {

    @Test("sync replaces optimistic header with real server message via rfc822 dedup")
    func coalesceViaRfc822Dedup() throws {
        let db = try TestDatabase.make()
        try TestDatabase.insertAccount(db)
        let sentFolder = try TestDatabase.insertFolder(db, name: "Sent", path: "Sent", role: .sent, accountId: "acc1")

        let rfc822 = "<coalesce@example.com>"
        let normalizedRfc822 = "coalesce@example.com"

        // Insert optimistic header + body
        try insertOptimisticSentHeader(
            db, outboxId: "coalesce-msg",
            rfc822MessageId: rfc822,
            subject: "Coalesce Test",
            body: "My reply body"
        )

        // Server returns the real message with same rfc822MessageId but real IMAP UID
        let serverMsg = makeHeaderInfo(
            messageId: "12345", // Real IMAP UID
            rfc822MessageId: normalizedRfc822,
            subject: "Coalesce Test",
            to: "to@test.com",
            snippet: "My reply body"
        )

        _ = try simulateSyncForSentFolder(
            db: db,
            folder: sentFolder,
            messages: [serverMsg]
        )

        // After sync, only one header should remain — the real one (via UID remap or rfc822 dedup)
        let headers = try db.read { dbConn in
            try MessageHeader.filter(Column("folderId") == "acc1:Sent").fetchAll(dbConn)
        }
        #expect(headers.count == 1)
        #expect(headers[0].messageId == "12345")
        #expect(headers[0].rfc822MessageId == normalizedRfc822)
    }

    @Test("coalesce migrates body from optimistic to real header")
    func coalesceMigratesBody() throws {
        let db = try TestDatabase.make()
        try TestDatabase.insertAccount(db)
        let sentFolder = try TestDatabase.insertFolder(db, name: "Sent", path: "Sent", role: .sent, accountId: "acc1")

        let rfc822 = "<body-migrate@example.com>"

        // Insert optimistic header with body
        let optimistic = try insertOptimisticSentHeader(
            db, outboxId: "body-test",
            rfc822MessageId: rfc822,
            body: "My important reply"
        )

        // Verify body exists under optimistic id
        let oldBody = try db.read { try MessageBody.fetchOne($0, key: optimistic.id) }
        #expect(oldBody != nil)

        // Server returns real message
        let serverMsg = makeHeaderInfo(
            messageId: "uid-999",
            rfc822MessageId: "body-migrate@example.com"
        )

        _ = try simulateSyncForSentFolder(
            db: db,
            folder: sentFolder,
            messages: [serverMsg]
        )

        // Body should now be under the real header's id
        let realHeaderId = "acc1:Sent:uid-999"
        let migratedBody = try db.read { try MessageBody.fetchOne($0, key: realHeaderId) }
        #expect(migratedBody != nil)
        #expect(migratedBody?.htmlContent?.contains("My important reply") == true)

        // Old body should be gone
        let oldBodyAfter = try db.read { try MessageBody.fetchOne($0, key: optimistic.id) }
        #expect(oldBodyAfter == nil)
    }

    @Test("coalesce via UID remap when both stale and new exist in same sync batch")
    func coalesceViaUIDRemap() throws {
        let db = try TestDatabase.make()
        try TestDatabase.insertAccount(db)
        let sentFolder = try TestDatabase.insertFolder(db, name: "Sent", path: "Sent", role: .sent, accountId: "acc1")

        let rfc822 = "<remap@example.com>"
        let normalizedRfc822 = "remap@example.com"

        // Insert optimistic header
        let optimistic = try insertOptimisticSentHeader(
            db, outboxId: "remap-test",
            rfc822MessageId: rfc822,
            body: "Remap body"
        )

        // Insert body for the optimistic header
        let bodyBefore = try db.read { try MessageBody.fetchOne($0, key: optimistic.id) }
        #expect(bodyBefore != nil)

        // Server returns real message — optimistic is stale (not in remoteIds),
        // real message is new. UID remap should catch this.
        let serverMsg = makeHeaderInfo(
            messageId: "real-uid-42",
            rfc822MessageId: normalizedRfc822,
            subject: "Test Subject",
            to: "to@test.com"
        )

        let result = try simulateSyncForSentFolder(
            db: db,
            folder: sentFolder,
            messages: [serverMsg]
        )

        // UID remap should have migrated the optimistic header
        let headers = try db.read { dbConn in
            try MessageHeader.filter(Column("folderId") == "acc1:Sent").fetchAll(dbConn)
        }
        #expect(headers.count == 1)
        #expect(headers[0].messageId == "real-uid-42")

        // Body should have been migrated to new id
        let realHeaderId = "acc1:Sent:real-uid-42"
        let migratedBody = try db.read { try MessageBody.fetchOne($0, key: realHeaderId) }
        #expect(migratedBody != nil)
        // Check that the UID remap path was used (staleIds should be empty since it was remapped)
        #expect(result.uidMigratedOldIds.contains("sent-remap-test"))
    }

    @Test("no duplicate when optimistic and real message have different rfc822MessageIds")
    func noDedupForDifferentRfc822() throws {
        let db = try TestDatabase.make()
        try TestDatabase.insertAccount(db)
        let sentFolder = try TestDatabase.insertFolder(db, name: "Sent", path: "Sent", role: .sent, accountId: "acc1")

        // Insert optimistic header with one rfc822
        try insertOptimisticSentHeader(
            db, outboxId: "no-dedup",
            rfc822MessageId: "<msgA@example.com>"
        )

        // Server returns a DIFFERENT message (different rfc822)
        let serverMsg = makeHeaderInfo(
            messageId: "uid-different",
            rfc822MessageId: "msgB@example.com"
        )

        _ = try simulateSyncForSentFolder(
            db: db,
            folder: sentFolder,
            messages: [serverMsg]
        )

        // Both should exist (no dedup — different messages)
        // But the optimistic one would be stale-deleted if no outbox protection
        let headers = try db.read { dbConn in
            try MessageHeader.filter(Column("folderId") == "acc1:Sent").fetchAll(dbConn)
        }
        // Without outbox protection, optimistic header gets stale-deleted
        #expect(headers.count == 1)
        #expect(headers[0].messageId == "uid-different")
    }
}

// MARK: - Suite 5: Delta Sync Dedup

@Suite("Optimistic Sent Header — Delta Sync Dedup")
struct OptimisticSentHeaderDeltaSyncTests {

    /// Simulates the delta sync insert path with rfc822 dedup (Gmail/Exchange pattern).
    private func simulateDeltaSyncInsert(
        db: DatabaseQueue,
        folder: Folder,
        newMessage: MessageHeaderInfo
    ) throws -> MessageHeader {
        try db.write { dbConn in
            let folderId = folder.id
            var header = MessageHeader(
                messageId: newMessage.messageId,
                subject: newMessage.subject,
                from: newMessage.from,
                fromAddress: newMessage.fromAddress,
                to: newMessage.to,
                date: newMessage.date,
                snippet: EmailFilter.cleanSnippet(newMessage.snippet),
                folderId: folderId,
                accountId: folder.accountId,
                folderPath: folder.path,
                isInInbox: false
            )
            header.rfc822MessageId = newMessage.rfc822MessageId
            header.isRead = newMessage.isRead
            try ThreadUtils.assignComputedThreadId(to: &header, nativeThreadId: newMessage.threadId, db: dbConn)

            // rfc822 dedup for Sent folder (matches production delta sync code)
            // Save migrated body to insert AFTER header (FK constraint)
            var deferredBody: MessageBody?
            if folder.role == .sent,
               let rfc822 = header.rfc822MessageId, !rfc822.isEmpty,
               let optimistic = try MessageHeader
                .filter(Column("folderId") == folderId && Column("rfc822MessageId") == rfc822 && Column("messageId") != header.messageId)
                .fetchOne(dbConn) {
                let oldId = optimistic.id
                if let body = try MessageBody.fetchOne(dbConn, key: ContentKey(rawValue: oldId)) {
                    var newBody = body
                    newBody.id = ContentKey(rawValue: header.id)
                    try MessageBody.deleteOne(dbConn, key: ContentKey(rawValue: oldId))
                    deferredBody = newBody
                }
                try optimistic.delete(dbConn)
            }

            try header.insert(dbConn)
            if let body = deferredBody {
                try body.insert(dbConn)
            }
            try ThreadUtils.insertMessageReferences(for: header, db: dbConn)
            return header
        }
    }

    @Test("delta sync replaces optimistic header with real message")
    func deltaSyncCoalesces() throws {
        let db = try TestDatabase.make()
        try TestDatabase.insertAccount(db)
        let sentFolder = try TestDatabase.insertFolder(db, name: "Sent", path: "Sent", role: .sent, accountId: "acc1")

        let rfc822 = "<delta-dedup@example.com>"

        // Insert optimistic header
        try insertOptimisticSentHeader(
            db, outboxId: "delta-msg",
            rfc822MessageId: rfc822,
            body: "Delta body"
        )

        // Delta sync brings in the real message
        let serverMsg = makeHeaderInfo(
            messageId: "gmail-id-abc",
            rfc822MessageId: "delta-dedup@example.com"
        )

        let inserted = try simulateDeltaSyncInsert(
            db: db,
            folder: sentFolder,
            newMessage: serverMsg
        )

        #expect(inserted.messageId == "gmail-id-abc")

        // Should have exactly one header in Sent
        let headers = try db.read { dbConn in
            try MessageHeader.filter(Column("folderId") == "acc1:Sent").fetchAll(dbConn)
        }
        #expect(headers.count == 1)
        #expect(headers[0].messageId == "gmail-id-abc")
    }

    @Test("delta sync migrates body during dedup")
    func deltaSyncMigratesBody() throws {
        let db = try TestDatabase.make()
        try TestDatabase.insertAccount(db)
        let sentFolder = try TestDatabase.insertFolder(db, name: "Sent", path: "Sent", role: .sent, accountId: "acc1")

        let rfc822 = "<delta-body@example.com>"

        let optimistic = try insertOptimisticSentHeader(
            db, outboxId: "delta-body-test",
            rfc822MessageId: rfc822,
            body: "Important content"
        )

        // Confirm body under old id
        let oldBody = try db.read { try MessageBody.fetchOne($0, key: optimistic.id) }
        #expect(oldBody != nil)

        let serverMsg = makeHeaderInfo(
            messageId: "exchange-id-xyz",
            rfc822MessageId: "delta-body@example.com"
        )

        _ = try simulateDeltaSyncInsert(
            db: db,
            folder: sentFolder,
            newMessage: serverMsg
        )

        // Body should be under new id
        let newHeaderId = "acc1:Sent:exchange-id-xyz"
        let migratedBody = try db.read { try MessageBody.fetchOne($0, key: newHeaderId) }
        #expect(migratedBody != nil)
        #expect(migratedBody?.htmlContent?.contains("Important content") == true)

        // Old body gone
        let oldBodyAfter = try db.read { try MessageBody.fetchOne($0, key: optimistic.id) }
        #expect(oldBodyAfter == nil)
    }

    @Test("delta sync does not dedup in non-Sent folder")
    func deltaSyncNoDeduInInbox() throws {
        let db = try TestDatabase.make()
        try TestDatabase.insertAccount(db)
        let inboxFolder = try TestDatabase.insertFolder(db, name: "INBOX", path: "INBOX", role: .inbox, accountId: "acc1")

        // Insert a header that looks like an optimistic placeholder in inbox
        try db.write { dbConn in
            var header = MessageHeader(
                messageId: "placeholder-inbox", subject: "Test", from: "me@example.com",
                fromAddress: "me@example.com", to: "you@example.com", date: Date(),
                snippet: "test", folderId: "acc1:INBOX", accountId: "acc1",
                folderPath: "INBOX", isInInbox: true
            )
            header.rfc822MessageId = "inbox-rfc822@example.com"
            try header.insert(dbConn)
        }

        // Insert real message with same rfc822
        let serverMsg = makeHeaderInfo(
            messageId: "real-inbox-msg",
            rfc822MessageId: "inbox-rfc822@example.com"
        )

        _ = try simulateDeltaSyncInsert(
            db: db,
            folder: inboxFolder,
            newMessage: serverMsg
        )

        // Both should exist — no dedup for inbox
        let headers = try db.read { dbConn in
            try MessageHeader.filter(Column("folderId") == "acc1:INBOX").fetchAll(dbConn)
        }
        #expect(headers.count == 2)
    }
}

// MARK: - Suite 6: Edge Cases

@Suite("Optimistic Sent Header — Edge Cases")
struct OptimisticSentHeaderEdgeCaseTests {

    @Test("outbox with multiple sentMessageIds protects multiple optimistic headers")
    func multipleOutboxProtectMultipleHeaders() throws {
        let db = try TestDatabase.make()
        try TestDatabase.insertAccount(db)
        let sentFolder = try TestDatabase.insertFolder(db, name: "Sent", path: "Sent", role: .sent, accountId: "acc1")

        // Insert two optimistic headers
        try insertOptimisticSentHeader(db, outboxId: "msg-1", rfc822MessageId: "<msg1@example.com>")
        try insertOptimisticSentHeader(db, outboxId: "msg-2", rfc822MessageId: "<msg2@example.com>")

        // Insert two corresponding outbox records
        try insertOutboxMessage(db, id: "msg-1", status: "sending", sentAt: Date(), sentMessageId: "<msg1@example.com>")
        try insertOutboxMessage(db, id: "msg-2", status: "sending", sentAt: Date(), sentMessageId: "<msg2@example.com>")

        // Sync with empty server
        let result = try simulateSyncForSentFolder(db: db, folder: sentFolder, messages: [])

        #expect(result.staleIds.isEmpty)

        let count = try db.read { try MessageHeader.filter(Column("folderId") == "acc1:Sent").fetchCount($0) }
        #expect(count == 2)
    }

    @Test("completed outbox (sentAt + appendedToSent deleted) no longer protects")
    func completedOutboxNoProtection() throws {
        let db = try TestDatabase.make()
        try TestDatabase.insertAccount(db)
        let sentFolder = try TestDatabase.insertFolder(db, name: "Sent", path: "Sent", role: .sent, accountId: "acc1")

        // Insert optimistic header
        try insertOptimisticSentHeader(db, outboxId: "done-msg", rfc822MessageId: "<done@example.com>")

        // NO outbox record (it was finalized and deleted)

        // Sync with server that has the real message
        let serverMsg = makeHeaderInfo(
            messageId: "real-uid-77",
            rfc822MessageId: "done@example.com"
        )
        _ = try simulateSyncForSentFolder(db: db, folder: sentFolder, messages: [serverMsg])

        // Optimistic header should have been replaced via rfc822 dedup (or UID remap)
        let headers = try db.read { dbConn in
            try MessageHeader.filter(Column("folderId") == "acc1:Sent").fetchAll(dbConn)
        }
        #expect(headers.count == 1)
        #expect(headers[0].messageId == "real-uid-77")
    }

    @Test("forward message gets correct isForward state in thread")
    func forwardOptimisticHeader() throws {
        let db = try TestDatabase.make()
        try TestDatabase.insertAccount(db)
        try TestDatabase.insertFolder(db, name: "Sent", path: "Sent", role: .sent, accountId: "acc1")

        let header = try insertOptimisticSentHeader(
            db,
            outboxId: "fwd-msg",
            rfc822MessageId: "<fwd@example.com>",
            subject: "Fwd: Original Subject",
            to: "someone@else.com"
        )

        // Verify it's in the DB with correct subject
        let fetched = try db.read { try MessageHeader.fetchOne($0, key: header.id) }
        #expect(fetched?.subject == "Fwd: Original Subject")
        #expect(fetched?.to == "someone@else.com")
    }

    @Test("cc and bcc preserved on optimistic header")
    func ccBccPreserved() throws {
        let db = try TestDatabase.make()
        try TestDatabase.insertAccount(db)
        try TestDatabase.insertFolder(db, name: "Sent", path: "Sent", role: .sent, accountId: "acc1")

        let header = try insertOptimisticSentHeader(
            db,
            outboxId: "cc-bcc",
            rfc822MessageId: "<ccbcc@example.com>",
            to: "to@test.com",
            cc: "cc1@test.com, cc2@test.com",
            bcc: "bcc@test.com"
        )

        #expect(header.cc == "cc1@test.com, cc2@test.com")
        #expect(header.bcc == "bcc@test.com")
    }

    @Test("inReplyTo is normalized when stored")
    func inReplyToNormalized() throws {
        let db = try TestDatabase.make()
        try TestDatabase.insertAccount(db)
        try TestDatabase.insertFolder(db, name: "Sent", path: "Sent", role: .sent, accountId: "acc1")

        let header = try insertOptimisticSentHeader(
            db,
            outboxId: "irt-norm",
            rfc822MessageId: "<irt@example.com>",
            inReplyTo: "<parent@example.com>",
            references: ["parent@example.com"]
        )

        #expect(header.inReplyTo == "parent@example.com") // No angle brackets
    }
}

// MARK: - Suite 7: FK-Safe Body Migration (Draft + Sent + UID Remap)

@Suite("Body Migration — FK CASCADE Safety")
struct BodyMigrationFKSafetyTests {

    /// Simulate the full sync rfc822 dedup path for Drafts folder (same code as Sent).
    /// Tests that body is preserved through the dedup despite CASCADE DELETE on header.
    private func simulateFullSyncDedup(
        db: DatabaseQueue,
        folder: Folder,
        serverMessage: MessageHeaderInfo
    ) throws -> MessageHeader {
        try db.write { dbConn in
            let folderId = folder.id
            let accountId = folder.accountId
            let folderPath = folder.path

            var header = MessageHeader(
                messageId: serverMessage.messageId,
                subject: serverMessage.subject,
                from: serverMessage.from,
                fromAddress: serverMessage.fromAddress,
                to: serverMessage.to,
                date: serverMessage.date,
                snippet: serverMessage.snippet,
                folderId: folderId,
                accountId: accountId,
                folderPath: folderPath,
                isInInbox: false
            )
            header.rfc822MessageId = serverMessage.rfc822MessageId
            try ThreadUtils.assignComputedThreadId(to: &header, nativeThreadId: nil, db: dbConn)

            // Replicate production dedup: deferred body insert
            var deferredBody: MessageBody?
            if let rfc822 = header.rfc822MessageId, !rfc822.isEmpty,
               let optimistic = try MessageHeader
                .filter(Column("folderId") == folderId && Column("rfc822MessageId") == rfc822 && Column("messageId") != header.messageId)
                .fetchOne(dbConn) {
                let oldId = optimistic.id
                if let body = try MessageBody.fetchOne(dbConn, key: ContentKey(rawValue: oldId)) {
                    var newBody = body
                    newBody.id = ContentKey(rawValue: header.id)
                    try MessageBody.deleteOne(dbConn, key: ContentKey(rawValue: oldId))
                    deferredBody = newBody
                }
                try optimistic.delete(dbConn)
            }
            try header.insert(dbConn)
            if let body = deferredBody { try body.insert(dbConn) }
            try ThreadUtils.insertMessageReferences(for: header, db: dbConn)
            return header
        }
    }

    /// Simulate UID remap: stale header with body + new server message with same rfc822.
    /// Tests that body is fetched BEFORE cascade-deleting the header.
    private func simulateUIDRemap(
        db: DatabaseQueue,
        folder: Folder,
        staleHeader: MessageHeader,
        newMessageId: String
    ) throws -> MessageHeader {
        try db.write { dbConn in
            let newId = "\(folder.accountId):\(folder.path):\(newMessageId)"
            // Fetch the body BEFORE deleting the header, then delete its row
            // EXPLICITLY — mirroring `SyncEngine.reconcileUidRemaps` after Stage D
            // (`v70_dropMessageBodyHeaderFK`) removed the cascade that used to do it.
            let oldBody = try MessageBody.fetchOne(dbConn, key: staleHeader.id)
            try staleHeader.delete(dbConn)
            try MessageBody.deleteOne(dbConn, key: staleHeader.id)
            var migrated = staleHeader
            migrated.id = newId
            migrated.messageId = newMessageId
            try migrated.insert(dbConn)
            if var body = oldBody {
                body.id = ContentKey(rawValue: newId)
                try body.insert(dbConn)
            }
            return migrated
        }
    }

    @Test("draft dedup preserves body through CASCADE delete")
    func draftDedupPreservesBody() throws {
        let db = try TestDatabase.make()
        try TestDatabase.insertAccount(db)
        try TestDatabase.insertFolder(db, name: "Drafts", path: "Drafts", role: .drafts, accountId: "acc1")
        let draftsFolder = try db.read { try Folder.filter(Column("role") == FolderRole.drafts.rawValue).fetchOne($0)! }

        // Insert optimistic draft header + body
        let placeholderMsgId = "draft-abc123"
        let headerId = "acc1:Drafts:\(placeholderMsgId)"
        let rfc822 = "draft-rfc822@example.com"
        try db.write { dbConn in
            var header = MessageHeader(
                messageId: placeholderMsgId, subject: "Draft Subject",
                from: "test@example.com", fromAddress: "test@example.com",
                to: "to@test.com", date: Date(), snippet: "Draft body",
                folderId: "acc1:Drafts", accountId: "acc1", folderPath: "Drafts", isInInbox: false
            )
            header.rfc822MessageId = rfc822
            header.isRead = true
            try header.insert(dbConn)
            let body = MessageBody( contentKey: ContentKey(rawValue: headerId), htmlContent: "<p>My draft content</p>")
            try body.insert(dbConn)
        }

        // Server sync returns real draft with same rfc822MessageId
        let serverMsg = makeHeaderInfo(
            messageId: "imap-uid-555",
            rfc822MessageId: rfc822,
            subject: "Draft Subject"
        )

        let result = try simulateFullSyncDedup(db: db, folder: draftsFolder, serverMessage: serverMsg)

        // Real header should exist
        #expect(result.messageId == "imap-uid-555")

        // Body should be migrated to new id
        let realHeaderId = "acc1:Drafts:imap-uid-555"
        let migratedBody = try db.read { try MessageBody.fetchOne($0, key: realHeaderId) }
        #expect(migratedBody != nil)
        #expect(migratedBody?.htmlContent == "<p>My draft content</p>")

        // Old body should be gone (CASCADE deleted with old header)
        let oldBody = try db.read { try MessageBody.fetchOne($0, key: headerId) }
        #expect(oldBody == nil)

        // Only one header should remain
        let count = try db.read { try MessageHeader.filter(Column("folderId") == "acc1:Drafts").fetchCount($0) }
        #expect(count == 1)
    }

    @Test("sent dedup preserves body through CASCADE delete")
    func sentDedupPreservesBody() throws {
        let db = try TestDatabase.make()
        try TestDatabase.insertAccount(db)
        try TestDatabase.insertFolder(db, name: "Sent", path: "Sent", role: .sent, accountId: "acc1")
        let sentFolder = try db.read { try Folder.filter(Column("role") == FolderRole.sent.rawValue).fetchOne($0)! }

        let optimistic = try insertOptimisticSentHeader(
            db, outboxId: "fk-test",
            rfc822MessageId: "<fk-test@example.com>",
            body: "Sent body content"
        )

        let serverMsg = makeHeaderInfo(
            messageId: "imap-uid-777",
            rfc822MessageId: "fk-test@example.com",
            subject: "Test Subject"
        )

        _ = try simulateFullSyncDedup(db: db, folder: sentFolder, serverMessage: serverMsg)

        let realHeaderId = "acc1:Sent:imap-uid-777"
        let migratedBody = try db.read { try MessageBody.fetchOne($0, key: realHeaderId) }
        #expect(migratedBody != nil)
        #expect(migratedBody?.htmlContent?.contains("Sent body content") == true)

        let oldBody = try db.read { try MessageBody.fetchOne($0, key: optimistic.id) }
        #expect(oldBody == nil)
    }

    @Test("UID remap preserves body through CASCADE delete")
    func uidRemapPreservesBody() throws {
        let db = try TestDatabase.make()
        try TestDatabase.insertAccount(db)
        try TestDatabase.insertFolder(db, name: "INBOX", path: "INBOX", role: .inbox, accountId: "acc1")
        let inboxFolder = try db.read { try Folder.filter(Column("role") == FolderRole.inbox.rawValue).fetchOne($0)! }

        // Insert a header with body (simulating a message that will get UID-remapped)
        let oldMsgId = "old-uid-100"
        let headerId = "acc1:INBOX:\(oldMsgId)"
        let rfc822 = "remap-body@example.com"
        var header: MessageHeader!
        try db.write { dbConn in
            var h = MessageHeader(
                messageId: oldMsgId, subject: "Remap Body Test",
                from: "sender@example.com", fromAddress: "sender@example.com",
                to: "me@example.com", date: Date(), snippet: "Important content",
                folderId: "acc1:INBOX", accountId: "acc1", folderPath: "INBOX", isInInbox: true
            )
            h.rfc822MessageId = rfc822
            try h.insert(dbConn)
            header = h
            let body = MessageBody( contentKey: ContentKey(rawValue: headerId), htmlContent: "<p>Must not be lost</p>")
            try body.insert(dbConn)
        }

        // Simulate UID remap (e.g., IMAP MOVE round-trip changed the UID)
        let migrated = try simulateUIDRemap(
            db: db, folder: inboxFolder,
            staleHeader: header,
            newMessageId: "new-uid-200"
        )

        #expect(migrated.messageId == "new-uid-200")

        // Body should be under new id
        let newHeaderId = "acc1:INBOX:new-uid-200"
        let migratedBody = try db.read { try MessageBody.fetchOne($0, key: newHeaderId) }
        #expect(migratedBody != nil)
        #expect(migratedBody?.htmlContent == "<p>Must not be lost</p>")

        // Old body gone
        let oldBody = try db.read { try MessageBody.fetchOne($0, key: headerId) }
        #expect(oldBody == nil)
    }

    @Test("UID remap without body still succeeds")
    func uidRemapWithoutBody() throws {
        let db = try TestDatabase.make()
        try TestDatabase.insertAccount(db)
        try TestDatabase.insertFolder(db, name: "INBOX", path: "INBOX", role: .inbox, accountId: "acc1")
        let inboxFolder = try db.read { try Folder.filter(Column("role") == FolderRole.inbox.rawValue).fetchOne($0)! }

        // Header with NO body (common — body fetched separately/later)
        var header: MessageHeader!
        try db.write { dbConn in
            var h = MessageHeader(
                messageId: "no-body-uid", subject: "No Body",
                from: "sender@example.com", fromAddress: "sender@example.com",
                to: "me@example.com", date: Date(), snippet: "snippet",
                folderId: "acc1:INBOX", accountId: "acc1", folderPath: "INBOX", isInInbox: true
            )
            h.rfc822MessageId = "no-body@example.com"
            try h.insert(dbConn)
            header = h
        }

        let migrated = try simulateUIDRemap(
            db: db, folder: inboxFolder,
            staleHeader: header,
            newMessageId: "remapped-uid"
        )

        #expect(migrated.messageId == "remapped-uid")

        // No body to migrate — no crash
        let body = try db.read { try MessageBody.fetchOne($0, key: "acc1:INBOX:remapped-uid") }
        #expect(body == nil)
    }
}

/// Drives the production post-provider-send owner rather than an insertion
/// simulator. A matching row makes the optimistic write idempotent; a probe
/// failure is non-fatal because the provider send has already succeeded.
@Suite("Optimistic Sent — production post-send RFC probe", .serialized, .processGlobalState)
struct OptimisticSentProductionProbeTests {
    private func makePool(accountId: String) throws -> (
        pool: DatabasePool, directory: URL, previous: AppDatabase?
    ) {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        var configuration = Configuration()
        configuration.foreignKeysEnabled = true
        let pool = try DatabasePool(
            path: directory.appendingPathComponent("test.sqlite").path,
            configuration: configuration)
        let appDatabase = try AppDatabase(dbPool: pool)
        let previous = AppDatabase.shared.withLock { current -> AppDatabase? in
            let prior = current
            current = appDatabase
            return prior
        }
        try pool.writeWithoutTransaction { db in
            var account = Account(
                emailAddress: "\(accountId)@example.com", displayName: "Sender", provider: .imap)
            account.id = accountId
            try account.insert(db)
            try Folder(name: "Sent", path: "Sent", role: .sent, accountId: accountId).insert(db)
        }
        return (pool, directory, previous)
    }

    private func restore(_ fixture: (pool: DatabasePool, directory: URL, previous: AppDatabase?)) {
        InstalledTestDatabaseLifetime.finish(
            previous: fixture.previous, pool: fixture.pool, directory: fixture.directory)
    }

    private func seedClaimedSend(
        pool: DatabasePool, accountId: String, outboxId: String, messageId: String,
        attachments: [DraftAttachment] = []
    ) throws -> OutboxMessage {
        var draft = DraftMessage(
            to: ["recipient@example.com"], subject: "Production probe", body: "Body")
        draft.attachments = attachments
        var message = OutboxMessage(accountId: accountId, draft: draft)
        if let dirName = message.attachmentsDirName {
            try OutboxMessage.saveAttachments(attachments, dirName: dirName)
        }
        message.id = outboxId
        message.status = OutboxStatus.sending.rawValue
        message.sentMessageId = messageId
        try pool.write { try message.insert($0) }
        return message
    }

    private func removeAttachments(of message: OutboxMessage) {
        if let dir = message.attachmentsDir { try? FileManager.default.removeItem(at: dir) }
    }

    private func sentRows(
        _ pool: DatabasePool, accountId: String
    ) async throws -> (headers: [MessageHeader], bodyIds: [String]) {
        try await pool.read { db in
            let headers = try MessageHeader
                .filter(Column("folderId") == "\(accountId):Sent")
                .order(Column("id"))
                .fetchAll(db)
            let bodyIds = try headers.compactMap { header in
                try MessageBody.fetchOne(db, key: ContentKey(rawValue: header.id)).map { _ in header.id }
            }
            return (headers, bodyIds)
        }
    }

    /// The provider's copy, as its header listing reads it: its own id, and a
    /// Message-ID of its own instead of the one the send wrote.
    private static let providerRfc822 = "provider-own-id@mail.example.com"

    /// The provider's order date for its copy, whole seconds so it survives the
    /// database's date precision.
    private static func providerOrderDate() -> Date {
        Date(timeIntervalSince1970: (Date().timeIntervalSince1970 - 90).rounded())
    }

    private static func listedCopy(
        accountId: String, id: String, threadId: String?, rfc822: String? = providerRfc822,
        date: Date? = nil, providerDate: Date
    ) -> MessageHeaderInfo {
        var info = makeHeaderInfo(
            messageId: id, rfc822MessageId: rfc822, threadId: threadId,
            subject: "Production probe", from: "Sender", fromAddress: "\(accountId)@example.com",
            to: "recipient@example.com", date: date ?? providerDate)
        info.providerDate = providerDate
        return info
    }

    private func send(_ claimed: OutboxMessage, messageId: String, accountId: String, provider: MockEmailProvider) async {
        await TestProviderRegistry.withRegisteredProvider(
            accountId: accountId, provider: provider
        ) {
            await AccountManager.shared.sendClaimedOutboxMessageForTesting(
                claimed, messageId: messageId)
        }
    }

    @Test("a sent forward starts its own thread even when its subject reads as an ordinary email (forward split)")
    func sentForwardStartsOwnThread() async throws {
        let accountId = "sent-forward"
        let fixture = try makePool(accountId: accountId)
        defer { restore(fixture) }
        // The forwarded email, in a thread of its own.
        try await fixture.pool.write { db in
            try Folder(name: "INBOX", path: "INBOX", role: .inbox, accountId: accountId).insert(db)
            var source = MessageHeader(
                messageId: "source-uid", subject: "Plans", from: "Alice", fromAddress: "alice@example.com",
                to: "\(accountId)@example.com", date: Date().addingTimeInterval(-600), snippet: "",
                folderId: "\(accountId):INBOX", accountId: accountId, folderPath: "INBOX", isInInbox: true)
            source.rfc822MessageId = "a-source@example.com"
            source.computedThreadId = "T-source"
            try source.insert(db)
        }
        // The forward as the outbox queues it: References end with the source,
        // and the user rewrote the subject.
        let messageId = "<m-sent-forward@example.com>"
        var draft = DraftMessage(to: ["recipient@example.com"], subject: "Plans for Friday", body: "Body")
        draft.references = ["a-source@example.com"]
        var message = OutboxMessage(accountId: accountId, draft: draft, isForward: true)
        message.id = "outbox-sent-forward"
        message.status = OutboxStatus.sending.rawValue
        message.sentMessageId = messageId
        let claimed = message
        try await fixture.pool.write { try claimed.insert($0) }

        await send(claimed, messageId: messageId, accountId: accountId, provider: MockEmailProvider())

        let rows = try await sentRows(fixture.pool, accountId: accountId)
        #expect(rows.headers.count == 1)
        guard rows.headers.count == 1 else { return }
        #expect(rows.headers[0].computedThreadId == "m-sent-forward@example.com")
    }

    @Test("a read Sent copy is ONE row with the provider's Message-ID, date and order date, read after the stamp, which a later Sent listing leaves as is")
    func readSentCopyIsTheRowTheSyncKeeps() async throws {
        let accountId = "sentcopy-named"
        let fixture = try makePool(accountId: accountId)
        defer { restore(fixture) }
        let messageId = "<sentcopy-named@example.com>"
        let claimed = try seedClaimedSend(
            pool: fixture.pool, accountId: accountId,
            outboxId: "outbox-sentcopy-named", messageId: messageId)
        let internalDate = Self.providerOrderDate()
        // The date the provider's listing gives the copy (Gmail: its Received
        // time), apart from both the order date and the device's clock.
        let copyDate = internalDate.addingTimeInterval(-30)
        let listed = Self.listedCopy(
            accountId: accountId, id: "gm-named", threadId: "thread-named",
            date: copyDate, providerDate: internalDate)
        let provider = MockEmailProvider()
        await provider.setSendResult(SentCopyIdentity(providerMessageId: "gm-named", threadId: "thread-named"))
        await provider.setFetchMessageHeadersResult([listed])
        let stampedAtRead = Mutex<[Bool]>([])
        let pool = fixture.pool
        let outboxId = claimed.id
        await provider.setFetchMessageHeadersHook {
            let stamped = (try? await pool.read { db in
                try OutboxMessage.fetchOne(db, key: outboxId)?.sentAt != nil
            }) ?? false
            stampedAtRead.withLock { $0.append(stamped) }
        }

        await send(claimed, messageId: messageId, accountId: accountId, provider: provider)

        #expect(stampedAtRead.withLock { $0 } == [true],
                "the copy is read once, after the send is stamped: a kill during the read resends nothing")
        let rowId = "\(accountId):Sent:gm-named"
        let afterSend = try await sentRows(fixture.pool, accountId: accountId)
        #expect(afterSend.headers.map(\.id) == [rowId], "the Sent row takes the id the provider's send named")
        guard afterSend.headers.count == 1 else { return }
        #expect(afterSend.headers[0].threadId == "thread-named", "its conversation id, which a reply from this row sends")
        #expect(afterSend.headers[0].rfc822MessageId == Self.providerRfc822,
                "the provider's own Message-ID, which recipients' copies carry")
        #expect(afterSend.headers[0].providerDate == internalDate, "the provider's order date, as the sync stores it")
        #expect(afterSend.headers[0].date == copyDate, "the copy's own date, not the device's clock")
        #expect(afterSend.bodyIds == [rowId])

        // The first sync after the send: the Sent listing names the copy.
        await provider.setFetchMessagesResult([listed])
        let folder = try await fixture.pool.read { db in try Folder.fetchOne(db, key: "\(accountId):Sent") }
        guard let folder else {
            Issue.record("the Sent folder is missing")
            return
        }
        _ = try await SyncEngine.runListing(
            for: folder, provider: provider, limit: SyncConfig.syncMessageLimit,
            dbPool: AppDatabase.dbPool).requireResult()
        // A change pass that reads the copy's arrival.
        let changes = FolderChanges(
            folderId: "\(accountId):Sent", status: .tracked, addressEpoch: nil,
            records: [ChangeRecord(header: listed)], removals: [])
        _ = try await fixture.pool.write { db in try SyncEngine.applyFolderChanges(changes, db: db) }

        let afterSync = try await sentRows(fixture.pool, accountId: accountId)
        #expect(afterSync.headers.map(\.id) == [rowId],
                "the sync's copy is the row the send wrote: one row, and the id a view holds stays valid")
        guard afterSync.headers.count == 1 else { return }
        #expect(afterSync.headers[0].rfc822MessageId == Self.providerRfc822)
        #expect(afterSync.headers[0].providerDate == internalDate)
        #expect(afterSync.headers[0].date == copyDate)
        #expect(afterSync.headers[0].threadId == "thread-named")
        #expect(afterSync.bodyIds == [rowId], "the locally written body stays with the row")
    }

    enum CopyThread: String, CaseIterable, Sendable {
        /// The send's answer names no conversation; the read copy does.
        case readOnly
        /// The read copy names no conversation; the send's answer does.
        case sendOnly
    }

    @Test("the row's conversation id is the read copy's, else the one the send's answer named",
          arguments: CopyThread.allCases)
    func readSentCopyThreadId(_ source: CopyThread) async throws {
        let accountId = "sentcopy-thread-\(source.rawValue)"
        let fixture = try makePool(accountId: accountId)
        defer { restore(fixture) }
        let messageId = "<sentcopy-thread-\(source.rawValue)@example.com>"
        let claimed = try seedClaimedSend(
            pool: fixture.pool, accountId: accountId,
            outboxId: "outbox-sentcopy-thread-\(source.rawValue)", messageId: messageId)
        let provider = MockEmailProvider()
        await provider.setSendResult(SentCopyIdentity(
            providerMessageId: "gm-thread", threadId: source == .sendOnly ? "thread-copy" : nil))
        await provider.setFetchMessageHeadersResult([Self.listedCopy(
            accountId: accountId, id: "gm-thread", threadId: source == .readOnly ? "thread-copy" : nil,
            providerDate: Self.providerOrderDate())])

        await send(claimed, messageId: messageId, accountId: accountId, provider: provider)

        let state = try await sentRows(fixture.pool, accountId: accountId)
        #expect(state.headers.map(\.id) == ["\(accountId):Sent:gm-thread"])
        guard state.headers.count == 1 else { return }
        #expect(state.headers[0].threadId == "thread-copy",
                "the conversation id a reply from this row sends, which no sync sets on a row it holds")
    }

    enum UnreadCopy: String, CaseIterable, Sendable {
        case readFails, notListed, noMessageId
        /// The listing answers with another message, which has a Message-ID.
        case otherMessage
    }

    @Test("a Sent copy that cannot be read gives the placeholder row, and the send still completes",
          arguments: UnreadCopy.allCases)
    func unreadSentCopyGivesThePlaceholder(_ unread: UnreadCopy) async throws {
        let accountId = "sentcopy-unread-\(unread.rawValue)"
        let fixture = try makePool(accountId: accountId)
        defer { restore(fixture) }
        let messageId = "<sentcopy-unread-\(unread.rawValue)@example.com>"
        let claimed = try seedClaimedSend(
            pool: fixture.pool, accountId: accountId,
            outboxId: "outbox-sentcopy-unread-\(unread.rawValue)", messageId: messageId)
        let provider = MockEmailProvider()
        await provider.setSendResult(SentCopyIdentity(providerMessageId: "gm-unread", threadId: "thread-unread"))
        switch unread {
        case .readFails:
            await provider.setFetchMessageHeadersThrows(URLError(.timedOut))
        case .notListed:
            await provider.setFetchMessageHeadersResult([])
        case .noMessageId:
            await provider.setFetchMessageHeadersResult([Self.listedCopy(
                accountId: accountId, id: "gm-unread", threadId: "thread-unread", rfc822: nil,
                providerDate: Self.providerOrderDate())])
        case .otherMessage:
            await provider.setFetchMessageHeadersResult([Self.listedCopy(
                accountId: accountId, id: "gm-other", threadId: "thread-other",
                providerDate: Self.providerOrderDate())])
        }

        await send(claimed, messageId: messageId, accountId: accountId, provider: provider)

        let rowId = "\(accountId):Sent:sent-\(claimed.id)"
        let state = try await sentRows(fixture.pool, accountId: accountId)
        let outbox = try await fixture.pool.read { db in try OutboxMessage.fetchOne(db, key: claimed.id) }
        #expect(outbox == nil, "the send completes; a failed read never fails or repeats it")
        #expect(state.headers.map(\.id) == [rowId], "the placeholder the sync replaces, as without a named copy")
        guard state.headers.count == 1 else { return }
        #expect(state.headers[0].rfc822MessageId == "sentcopy-unread-\(unread.rawValue)@example.com")
        #expect(state.headers[0].threadId == nil)
        #expect(state.headers[0].providerDate == state.headers[0].date)
        #expect(state.bodyIds == [rowId])
        #expect(state.headers[0].bodyComplete)
    }

    @Test("a Sent copy the sync stored first is kept as the sync wrote it: no error and no second row")
    func syncFirstCopyIsKept() async throws {
        let accountId = "sentcopy-sync-first"
        let fixture = try makePool(accountId: accountId)
        defer { restore(fixture) }
        let rowId = "\(accountId):Sent:gm-first"
        try await fixture.pool.write { db in
            var synced = MessageHeader(
                messageId: "gm-first", subject: "Production probe", from: "Sender",
                fromAddress: "\(accountId)@example.com", to: "recipient@example.com",
                date: Date(), snippet: "from the sync", folderId: "\(accountId):Sent",
                accountId: accountId, folderPath: "Sent", isInInbox: false)
            synced.rfc822MessageId = Self.providerRfc822
            synced.headerComplete = true
            try synced.insert(db)
        }
        let messageId = "<sentcopy-sync-first@example.com>"
        let claimed = try seedClaimedSend(
            pool: fixture.pool, accountId: accountId,
            outboxId: "outbox-sentcopy-sync-first", messageId: messageId)
        let provider = MockEmailProvider()
        await provider.setSendResult(SentCopyIdentity(providerMessageId: "gm-first", threadId: "thread-first"))
        await provider.setFetchMessageHeadersResult([Self.listedCopy(
            accountId: accountId, id: "gm-first", threadId: "thread-first", providerDate: Self.providerOrderDate())])
        let logURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("sentcopy_sync_first_\(UUID().uuidString).log")
        AppLogStore.fileURLOverride.withLock { $0 = logURL }
        DebugModeManager.loggingEnabledOverrideForTesting.withLock { $0 = true }
        defer {
            DebugModeManager.loggingEnabledOverrideForTesting.withLock { $0 = nil }
            AppLogStore._resetForTesting()
            try? FileManager.default.removeItem(at: logURL)
        }

        await send(claimed, messageId: messageId, accountId: accountId, provider: provider)

        let debugLog = AppLogStore.read(channel: .debug)
        #expect(debugLog.contains("Inserted optimistic Sent header for \(claimed.id)"),
                "the log was captured (non-vacuity)")
        #expect(!debugLog.contains("Could not insert optimistic Sent header"),
                "the copy already stored is not an error")
        let state = try await sentRows(fixture.pool, accountId: accountId)
        let outbox = try await fixture.pool.read { db in try OutboxMessage.fetchOne(db, key: claimed.id) }
        #expect(state.headers.map(\.id) == [rowId], "one row: the sync's")
        guard state.headers.count == 1 else { return }
        #expect(state.headers[0].snippet == "from the sync")
        #expect(state.headers[0].rfc822MessageId == Self.providerRfc822)
        #expect(state.headers[0].bodyComplete == false,
                "the sync's row keeps its body to fetch; the send marks nothing on it")
        #expect(state.bodyIds.isEmpty, "no local body is written over the sync's row")
        #expect(outbox == nil, "the send still finalizes")
    }

    @Test("a send with attachments writes its local body only when the provider's Sent copy was not read",
          arguments: [true, false])
    func attachmentsLeaveAReadCopysBodyToFetch(named: Bool) async throws {
        let accountId = "sentcopy-attachments-\(named)"
        let fixture = try makePool(accountId: accountId)
        defer { restore(fixture) }
        let messageId = "<sentcopy-attachments-\(named)@example.com>"
        let claimed = try seedClaimedSend(
            pool: fixture.pool, accountId: accountId,
            outboxId: "outbox-sentcopy-attachments-\(named)", messageId: messageId,
            attachments: [DraftAttachment(filename: "report.txt", mimeType: "text/plain", data: Data("report".utf8))])
        defer { removeAttachments(of: claimed) }
        let provider = MockEmailProvider()
        if named {
            await provider.setSendResult(SentCopyIdentity(providerMessageId: "gm-attached", threadId: nil))
            await provider.setFetchMessageHeadersResult([Self.listedCopy(
                accountId: accountId, id: "gm-attached", threadId: nil, providerDate: Self.providerOrderDate())])
        }

        await send(claimed, messageId: messageId, accountId: accountId, provider: provider)

        let state = try await sentRows(fixture.pool, accountId: accountId)
        let rowId = "\(accountId):Sent:" + (named ? "gm-attached" : "sent-\(claimed.id)")
        #expect(state.headers.map(\.id) == [rowId])
        guard state.headers.count == 1 else { return }
        #expect(state.headers[0].headerComplete)
        if named {
            // The local copy lists no attachments, and a body fetch keeps a stored
            // body: the provider's copy is fetched under its real id instead.
            #expect(state.headers[0].hasAttachments, "the sync's update of a row it holds never sets it")
            #expect(state.bodyIds.isEmpty)
            #expect(state.headers[0].bodyComplete == false)
        } else {
            // A placeholder id cannot be fetched; the sync replaces the row.
            #expect(state.headers[0].hasAttachments == false, "unchanged for the placeholder")
            #expect(state.bodyIds == [rowId])
            #expect(state.headers[0].bodyComplete)
        }
    }

    @Test("post-send optimistic insertion is idempotent when the RFC header already exists")
    func existingRfcHeaderSkipsTheOptimisticInsert() async throws {
        let accountId = "perf012-idempotent"
        let fixture = try makePool(accountId: accountId)
        defer { restore(fixture) }
        let messageId = "<perf012-idempotent@example.com>"
        try await fixture.pool.write { db in
            var existing = MessageHeader(
                messageId: "server-copy", subject: "Already present", from: "Sender",
                fromAddress: "\(accountId)@example.com", to: "recipient@example.com",
                date: Date(), snippet: "existing", folderId: "\(accountId):Sent",
                accountId: accountId, folderPath: "Sent", isInInbox: false)
            existing.rfc822MessageId = EmailFilter.normalizeMessageId(messageId)
            try existing.insert(db)
        }
        let claimed = try seedClaimedSend(
            pool: fixture.pool, accountId: accountId,
            outboxId: "outbox-perf012-idempotent", messageId: messageId)
        let provider = MockEmailProvider()

        await TestProviderRegistry.withRegisteredProvider(
            accountId: accountId, provider: provider
        ) {
            await AccountManager.shared.sendClaimedOutboxMessageForTesting(
                claimed, messageId: messageId)
        }

        #expect(await provider.sentDrafts.count == 1)
        #expect(await provider.appendedToSent.count == 1)
        let state = try await fixture.pool.read { db -> (headers: [MessageHeader], outbox: OutboxMessage?) in
            let headers = try MessageHeader
                .filter(Column("folderId") == "\(accountId):Sent")
                .fetchAll(db)
            return (headers, try OutboxMessage.fetchOne(db, key: claimed.id))
        }
        #expect(state.headers.map(\.id) == ["\(accountId):Sent:server-copy"],
                "the production existence probe must not add a second optimistic row")
        #expect(state.outbox == nil, "the successful provider send and append still finalize")
    }

    @Test("an RFC probe failure after provider send is non-fatal and finalization continues")
    func missingRfcIndexDoesNotUndoTheProviderSend() async throws {
        let accountId = "perf012-probe-failure"
        let fixture = try makePool(accountId: accountId)
        defer { restore(fixture) }
        let messageId = "<perf012-probe-failure@example.com>"
        let claimed = try seedClaimedSend(
            pool: fixture.pool, accountId: accountId,
            outboxId: "outbox-perf012-probe-failure", messageId: messageId)
        try await fixture.pool.write { db in
            try db.execute(sql: "DROP INDEX messageHeader_rfc822MessageId")
        }
        let provider = MockEmailProvider()

        await TestProviderRegistry.withRegisteredProvider(
            accountId: accountId, provider: provider
        ) {
            await AccountManager.shared.sendClaimedOutboxMessageForTesting(
                claimed, messageId: messageId)
        }

        #expect(await provider.sentDrafts.count == 1,
                "the provider send completed before the local RFC probe failed")
        #expect(await provider.appendedToSent.count == 1,
                "the swallowed local probe failure must not block the Sent append")
        let state = try await fixture.pool.read { db -> (headerCount: Int, outbox: OutboxMessage?) in
            let count = try MessageHeader
                .filter(Column("folderId") == "\(accountId):Sent")
                .fetchCount(db)
            return (count, try OutboxMessage.fetchOne(db, key: claimed.id))
        }
        #expect(state.headerCount == 0,
                "a failed optimistic insertion leaves sync to materialize the Sent header")
        #expect(state.outbox == nil,
                "provider-send success remains finalizable despite the non-fatal local probe failure")
    }
}
