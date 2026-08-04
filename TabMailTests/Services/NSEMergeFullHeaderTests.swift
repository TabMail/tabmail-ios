/* This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at https://mozilla.org/MPL/2.0/. */

import Testing
import Foundation
import GRDB
@testable import TabMail

/// End-to-end coverage for the insert-new-header branch of the NSE staging
/// merge. Exercises `NSEDataBridge.insertNewHeaderFromStaging` against an
/// in-memory main-GRDB so every write the merge does is asserted against
/// the resulting `messageHeader` / `messageReference` / `messageUserLabel`
/// rows.
///
/// Guards the 2026-04-19 fix against regression:
///   • No placeholder `to: ""` / default flags.
///   • `references` chain becomes `messageReference` junction rows.
///   • Provider labels filtered per-provider + materialized as
///     `messageUserLabel` junction rows (with parent `userLabel` upserted
///     so FK holds).
///   • Idempotence — re-running the merge doesn't duplicate rows.
///   • Subject-based `computedThreadId` fallback matches sync.
@Suite("NSE merge — full-header end-to-end")
struct NSEMergeFullHeaderTests {

    // MARK: - Helpers

    private func makeDB() throws -> DatabaseQueue {
        let db = try TestDatabase.make()
        try TestDatabase.insertAccount(db, id: "acc1", email: "user@gmail.com")
        try TestDatabase.insertFolder(db, name: "INBOX", path: "INBOX", role: .inbox, accountId: "acc1")
        return db
    }

    private func staged(
        messageId: String = "msg-1",
        provider: String = "gmail",
        rfc822: String? = "rfc@x.com",
        to: String = "\"Bob\" <bob@x.com>, eve@x.com",
        cc: String = "cc@x.com",
        bcc: String = "bcc@x.com",
        replyTo: String? = "reply@x.com",
        inReplyTo: String? = "parent@x.com",
        references: [String] = ["root@x.com", "parent@x.com"],
        isRead: Bool = true,
        isFlagged: Bool = true,
        hasAttachments: Bool = true,
        isReplied: Bool = false,
        isForwarded: Bool = false,
        providerLabels: [String] = [],
        actionTag: String? = nil,
        aiCompleted: Bool = false,
        htmlContent: String? = nil,
        textContent: String? = nil,
        summaryBlurb: String? = nil
    ) -> NSEDataBridge.StagedMessage {
        NSEDataBridge.StagedMessage(
            id: "acc1:\(messageId)",
            accountId: "acc1",
            accountEmail: "user@gmail.com",
            provider: provider,
            messageId: messageId,
            rfc822MessageId: rfc822,
            threadId: nil,
            folderPath: "INBOX",
            subject: "Subject under test",
            senderName: "Alice",
            senderEmail: "alice@x.com",
            snippet: "snippet preview",
            date: 1_710_000_000,
            to: to, cc: cc, bcc: bcc, replyTo: replyTo,
            inReplyTo: inReplyTo,
            references: references,
            isRead: isRead,
            isFlagged: isFlagged,
            hasAttachments: hasAttachments,
            isReplied: isReplied,
            isForwarded: isForwarded,
            providerLabels: providerLabels,
            summaryBlurb: summaryBlurb, summaryTodos: nil, actionTag: actionTag,
            reminderDate: nil, reminderTime: nil, reminderContent: nil,
            processedAt: Date().timeIntervalSince1970,
            aiCompleted: aiCompleted, notified: false,
            htmlContent: htmlContent, textContent: textContent, attachmentsJSON: nil,
            icsText: nil, hasUnresolvedCIDs: false
        )
    }

    private func insert(
        _ msg: NSEDataBridge.StagedMessage, into db: DatabaseQueue
    ) throws -> (inserted: Bool, headerId: String) {
        var ftsBatch: [NSEDataBridge.NSEFTSBodyItem] = []
        var inserted = false
        try db.write { db in
            inserted = try NSEDataBridge.insertNewHeaderFromStaging(
                msg, db: db, ftsBatch: &ftsBatch
            )
        }
        let headerId = MessageIdentity.headerId(
            accountId: msg.accountId, folderPath: msg.folderPath, messageId: msg.messageId
        )
        return (inserted, headerId)
    }

    // MARK: - Two-phase merge: headerOnly defers body + AI

    /// Phase 1 of the two-phase merge inserts a HEADER-ONLY row
    /// (`headerOnly: true`): the message goes inbox-visible on a lightweight
    /// write (snippet present), but the multi-MB body blob and the AI fields are
    /// deferred to phase 2 — off the visibility critical path. The default
    /// (`headerOnly: false`) writes them, as the new-header fallback still must.
    @Test("headerOnly=true defers body blob + AI fields; default writes them")
    func headerOnlyDefersBodyAndAI() throws {
        // Phase 1 — headerOnly: true.
        let dbA = try makeDB()
        let msgA = staged(
            actionTag: "reply", aiCompleted: true,
            htmlContent: "<p>the body</p>", textContent: "the body", summaryBlurb: "a summary"
        )
        var ftsA: [NSEDataBridge.NSEFTSBodyItem] = []
        try dbA.write { db in
            _ = try NSEDataBridge.insertNewHeaderFromStaging(msgA, db: db, ftsBatch: &ftsA, headerOnly: true)
        }
        let hidA = MessageIdentity.headerId(
            accountId: msgA.accountId, folderPath: msgA.folderPath, messageId: msgA.messageId
        )
        let headerA = try dbA.read { try MessageHeader.fetchOne($0, key: hidA) }
        // DISPLAY snippet: body-derived wins when staged text exists (identical
        // to phase-2's canonical value → no visible "snap"); the raw provider
        // snippet ("snippet preview") is only the no-body fallback, cleaned.
        // See NSEDataBridge.stagedDisplaySnippet.
        #expect(headerA?.snippet == "the body")          // visible: snippet present
        #expect(headerA?.summaryBlurb == nil)            // AI deferred to phase 2
        #expect(headerA?.actionTag == nil)               // AI deferred to phase 2
        let bodyCountA = try dbA.read {
            try MessageBody.filter(Column("id") == hidA).fetchCount($0)
        }
        #expect(bodyCountA == 0)                          // body blob deferred to phase 2
        // The header-only FTS batch carries no body work either.
        #expect(ftsA.isEmpty)

        // Default (headerOnly: false) — body + AI written (new-header fallback path).
        let dbB = try makeDB()
        let msgB = staged(
            actionTag: "reply", aiCompleted: true,
            htmlContent: "<p>the body</p>", textContent: "the body", summaryBlurb: "a summary"
        )
        var ftsB: [NSEDataBridge.NSEFTSBodyItem] = []
        try dbB.write { db in
            _ = try NSEDataBridge.insertNewHeaderFromStaging(msgB, db: db, ftsBatch: &ftsB)
        }
        let hidB = MessageIdentity.headerId(
            accountId: msgB.accountId, folderPath: msgB.folderPath, messageId: msgB.messageId
        )
        let headerB = try dbB.read { try MessageHeader.fetchOne($0, key: hidB) }
        #expect(headerB?.summaryBlurb == "a summary")
        #expect(headerB?.actionTag?.rawValue == "reply")
        let bodyCountB = try dbB.read {
            try MessageBody.filter(Column("id") == hidB).fetchCount($0)
        }
        #expect(bodyCountB == 1)                          // body blob written
    }

    // MARK: - Header fields populated (no placeholders)

    @Test("Merge populates every MessageHeader field from the staged row")
    func allFieldsPopulated() throws {
        let db = try makeDB()
        let (_, headerId) = try insert(staged(), into: db)

        let header = try db.read { try MessageHeader.fetchOne($0, key: headerId) }
        guard let header else {
            Issue.record("header not inserted"); return
        }

        // Recipient fields — NOT empty (the 2026-04-19 bug).
        #expect(header.to == "\"Bob\" <bob@x.com>, eve@x.com")
        #expect(header.cc == "cc@x.com")
        #expect(header.bcc == "bcc@x.com")
        #expect(header.replyTo == "reply@x.com")

        // Threading fields — present.
        #expect(header.inReplyTo == "parent@x.com")
        #expect(header.references == ["root@x.com", "parent@x.com"])
        #expect(header.rfc822MessageId == "rfc@x.com")

        // Flags — NOT defaulted to false.
        #expect(header.isRead)
        #expect(header.isFlagged)
        #expect(header.hasAttachments)

        // Core identity.
        #expect(header.subject == "Subject under test")
        #expect(header.from == "Alice")
        #expect(header.fromAddress == "alice@x.com")
        #expect(header.accountId == "acc1")
        #expect(header.folderPath == "INBOX")
        #expect(header.isInInbox)
    }

    // MARK: - MessageReference junction

    @Test("Merge materializes MessageReference junction rows for references chain")
    func messageReferenceJunction() throws {
        let db = try makeDB()
        let (_, headerId) = try insert(staged(), into: db)

        // `ThreadUtils.insertMessageReferences` prepends `inReplyTo` and then
        // appends every entry of `references` — including duplicates if the
        // parent also appears in references. This is the same behavior
        // sync produces, so our merge matches it verbatim.
        let refs = try db.read { db in
            try Row.fetchAll(db, sql: """
                SELECT referencedRfc822Id FROM messageReference
                WHERE messageHeaderId = ?
                """, arguments: [headerId])
        }.map { $0["referencedRfc822Id"] as String }
        #expect(Set(refs) == Set(["parent@x.com", "root@x.com"]))
        // All three rows present (inReplyTo + references), matching sync.
        #expect(refs.count == 3)
    }

    @Test("Empty references + inReplyTo inserts zero junction rows")
    func noReferencesNoJunctions() throws {
        let db = try makeDB()
        let msg = staged(inReplyTo: nil, references: [])
        let (_, headerId) = try insert(msg, into: db)

        let count = try db.read { try Int.fetchOne($0, sql: """
            SELECT COUNT(*) FROM messageReference WHERE messageHeaderId = ?
            """, arguments: [headerId]) } ?? -1
        #expect(count == 0)
    }

    @Test("inReplyTo alone (no references) inserts one junction row")
    func inReplyToOnly() throws {
        let db = try makeDB()
        let msg = staged(inReplyTo: "parent@x.com", references: [])
        let (_, headerId) = try insert(msg, into: db)

        let refs = try db.read { db in
            try Row.fetchAll(db, sql: """
                SELECT referencedRfc822Id FROM messageReference WHERE messageHeaderId = ?
                """, arguments: [headerId])
        }.map { $0["referencedRfc822Id"] as String }
        #expect(refs == ["parent@x.com"])
    }

    // MARK: - MessageUserLabel junction + filtering

    /// Path A contract: Gmail merge keeps ONLY labelIds that exist in
    /// main-GRDB's `userLabel` with `isSystem=false`. Unknown labels (not
    /// yet synced) and system labels (either absent or `isSystem=true`)
    /// are dropped. Re-verifies the Path A behavior documented on
    /// `NSEDataBridge.filterUserLabels`.
    @Test("Gmail merge drops labels not registered in userLabel table")
    func gmailUnregisteredLabelsDropped() throws {
        let db = try makeDB()
        // No userLabel rows exist → any Gmail labelId is "unknown".
        let msg = staged(
            providerLabels: ["INBOX", "UNREAD", "STARRED", "Label_123"]
        )
        let (_, headerId) = try insert(msg, into: db)

        let userLabels = try db.read { try UserLabel.fetchAll($0) }
        #expect(userLabels.isEmpty)

        let count = try db.read { try Int.fetchOne($0, sql: """
            SELECT COUNT(*) FROM messageUserLabel WHERE messageId = ?
            """, arguments: [headerId]) } ?? -1
        #expect(count == 0)
    }

    @Test("Gmail merge strips rows where userLabel.isSystem=true")
    func gmailSystemLabelsStripped() throws {
        let db = try makeDB()
        // Register an isSystem=true label. It should NOT appear in the junction.
        try db.write { db in
            try UserLabel(accountId: "acc1", providerLabelId: "STARRED", name: "Starred", isSystem: true).insert(db)
        }
        let msg = staged(
            providerLabels: ["INBOX", "UNREAD", "STARRED", "CATEGORY_PROMOTIONS"]
        )
        let (_, headerId) = try insert(msg, into: db)
        let count = try db.read { try Int.fetchOne($0, sql: """
            SELECT COUNT(*) FROM messageUserLabel WHERE messageId = ?
            """, arguments: [headerId]) } ?? -1
        #expect(count == 0)
    }

    @Test("IMAP merge strips excluded keywords")
    func imapExcludedKeywordFilter() throws {
        let db = try makeDB()
        // `$Forwarded` is excluded (tracked via isReplied / isForwarded),
        // as are any tm_* labels.
        let msg = staged(
            provider: "imap_new_mail",
            providerLabels: ["tm_reply", "$Forwarded", "Important", "work"]
        )
        let (_, headerId) = try insert(msg, into: db)

        // Only non-excluded keywords survive. Expected set matches
        // `IMAPProvider.buildMessageHeaderInfo` behavior (lowercased).
        let junctionIds = try db.read { db in
            try Row.fetchAll(db, sql: """
                SELECT userLabelId FROM messageUserLabel
                WHERE messageId = ? ORDER BY userLabelId
                """, arguments: [headerId])
        }.map { $0["userLabelId"] as String }
        // Junction ids are the account-prefixed SURROGATE `userLabel.id`
        // (D10 / `IOS-LABEL-001`); the bare keyword lives in `providerLabelId`.
        #expect(!junctionIds.contains("acc1:tm_reply"))
        #expect(!junctionIds.contains("acc1:$Forwarded"))
        // `Important` and `work` should survive (if they aren't excluded).
        #expect(junctionIds.contains("acc1:important") || junctionIds.contains("acc1:work"))
    }

    @Test("Outlook merge inserts NO user-label rows (categories not yet surfaced)")
    func outlookNoUserLabels() throws {
        let db = try makeDB()
        let msg = staged(
            provider: "outlook",
            providerLabels: ["tm_reply", "Important"]
        )
        let (_, headerId) = try insert(msg, into: db)
        let count = try db.read { try Int.fetchOne($0, sql: """
            SELECT COUNT(*) FROM messageUserLabel WHERE messageId = ?
            """, arguments: [headerId]) } ?? -1
        #expect(count == 0)
    }

    // MARK: - Idempotence

    @Test("Re-running merge on the same staged row is a no-op (INSERT OR IGNORE)")
    func idempotence() throws {
        let db = try makeDB()
        let msg = staged(providerLabels: ["Label_42"])

        let (firstInserted, headerId) = try insert(msg, into: db)
        #expect(firstInserted)

        let (secondInserted, _) = try insert(msg, into: db)
        #expect(!secondInserted)

        // Header count == 1, junction count stable.
        let headerCount = try db.read { try Int.fetchOne($0, sql: """
            SELECT COUNT(*) FROM messageHeader WHERE id = ?
            """, arguments: [headerId]) } ?? -1
        #expect(headerCount == 1)
    }

    // MARK: - Parity with existing NSE tests (no regression in AI merge)

    // MARK: - isReplied / isForwarded (IMAP)

    @Test("IMAP isReplied/isForwarded propagate from stage to MessageHeader")
    func imapRepliedForwardedPropagate() throws {
        let db = try makeDB()
        let msg = staged(
            provider: "imap_new_mail",
            isReplied: true, isForwarded: true
        )
        let (_, headerId) = try insert(msg, into: db)
        let header = try db.read { try MessageHeader.fetchOne($0, key: headerId) }
        #expect(header?.isReplied == true)
        #expect(header?.isForwarded == true)
    }

    @Test("Gmail/Outlook stages isReplied=false (REST surface doesn't expose it)")
    func gmailOutlookRepliedAlwaysFalse() throws {
        let db = try makeDB()
        let gmailMsg = staged(messageId: "msg-g", provider: "gmail", isReplied: false, isForwarded: false)
        let outlookMsg = staged(messageId: "msg-o", provider: "outlook", isReplied: false, isForwarded: false)

        let (_, gmailId) = try insert(gmailMsg, into: db)
        let (_, outlookId) = try insert(outlookMsg, into: db)

        let g = try db.read { try MessageHeader.fetchOne($0, key: gmailId) }
        let o = try db.read { try MessageHeader.fetchOne($0, key: outlookId) }
        #expect(g?.isReplied == false)
        #expect(g?.isForwarded == false)
        #expect(o?.isReplied == false)
        #expect(o?.isForwarded == false)
    }

    // MARK: - ActionTag resolution (ADR-IOS-036: local-only)
    //
    // Post-ADR-IOS-036 action tags are local-only. Server-side labels
    // (IMAP `tm_*` keywords, Gmail `tm_*` label IDs, Outlook `tm_*`
    // categories) are NOT resolved to ActionTag on merge — only the
    // AI-computed `msg.actionTag` from the NSE's staging row drives the
    // final `MessageHeader.actionTag`. These tests pin that behavior so
    // a future regression that re-introduces server resolution is loud.

    @Test("IMAP legacy tm_reply keyword in providerLabels is ignored; AI tag wins")
    func imapLegacyServerTagIgnored() throws {
        let db = try makeDB()
        let msg = staged(
            provider: "imap_new_mail",
            providerLabels: ["tm_reply"],
            actionTag: "archive", aiCompleted: true
        )
        let (_, headerId) = try insert(msg, into: db)
        let header = try db.read { try MessageHeader.fetchOne($0, key: headerId) }
        #expect(header?.actionTag == .archive)
    }

    @Test("IMAP multiple legacy tm_* keywords — none resolve; AI-less message yields nil tag")
    func imapLegacyKeywordsIgnored() throws {
        let db = try makeDB()
        let msg = staged(
            provider: "imap_new_mail",
            providerLabels: ["tm_archive", "tm_reply", "tm_delete"]
        )
        let (_, headerId) = try insert(msg, into: db)
        let header = try db.read { try MessageHeader.fetchOne($0, key: headerId) }
        #expect(header?.actionTag == nil)
    }

    @Test("Outlook legacy tm_archive category is ignored; AI-less message yields nil tag")
    func outlookLegacyCategoryIgnored() throws {
        let db = try makeDB()
        let msg = staged(
            provider: "outlook",
            providerLabels: ["tm_archive"]
        )
        let (_, headerId) = try insert(msg, into: db)
        let header = try db.read { try MessageHeader.fetchOne($0, key: headerId) }
        #expect(header?.actionTag == nil)
    }

    @Test("No server tag + AI tag → AI tag wins")
    func noServerTagAIWins() throws {
        let db = try makeDB()
        let msg = staged(
            provider: "imap_new_mail",
            providerLabels: [],
            actionTag: "delete", aiCompleted: true
        )
        let (_, headerId) = try insert(msg, into: db)
        let header = try db.read { try MessageHeader.fetchOne($0, key: headerId) }
        #expect(header?.actionTag == .delete)
    }

    @Test("Gmail Label_N in providerLabels is ignored (no server resolution); AI tag wins")
    func gmailLegacyLabelIdIgnored() throws {
        let db = try makeDB()
        let msg = staged(
            provider: "gmail",
            providerLabels: ["INBOX", "UNREAD", "Label_reply_789"],
            actionTag: "archive", aiCompleted: true
        )
        let (_, headerId) = try insert(msg, into: db)
        let header = try db.read { try MessageHeader.fetchOne($0, key: headerId) }
        #expect(header?.actionTag == .archive)
    }

    // MARK: - Path A — Gmail filterUserLabels via userLabel table

    @Test("Gmail merge keeps labels that main-GRDB userLabel marks isSystem=false")
    func gmailUserLabelViaGRDB() throws {
        let db = try makeDB()
        // Pre-register a user label + a system label (sync would do this).
        try db.write { db in
            try UserLabel(accountId: "acc1", providerLabelId: "Label_work", name: "Work", isSystem: false).insert(db)
            try UserLabel(accountId: "acc1", providerLabelId: "Label_notes", name: "Notes", isSystem: true).insert(db)
        }

        let msg = staged(
            provider: "gmail",
            providerLabels: ["INBOX", "Label_work", "Label_notes", "Label_unknown"]
        )
        let (_, headerId) = try insert(msg, into: db)

        let junctionIds = try db.read { db in
            try Row.fetchAll(db, sql: """
                SELECT userLabelId FROM messageUserLabel WHERE messageId = ?
                """, arguments: [headerId])
        }.map { $0["userLabelId"] as String }
        // The junction FK is the surrogate; the bare provider id is what
        // `filterUserLabels` matched on. Both are asserted.
        #expect(junctionIds == ["acc1:Label_work"])
        let providerIds = try db.read { db in
            try String.fetchAll(db, sql: "SELECT providerLabelId FROM userLabel WHERE id = ?",
                                arguments: ["acc1:Label_work"])
        }
        #expect(providerIds == ["Label_work"])
    }

    @Test("AI-completed staged row writes AI fields on the inserted header")
    func aiFieldsPropagate() throws {
        let db = try makeDB()
        // AI completed with actionTag=reply; no server-side labels → AI wins.
        let msg = staged(
            providerLabels: [],
            actionTag: "reply",
            aiCompleted: true
        )
        let (_, headerId) = try insert(msg, into: db)

        let header = try db.read { try MessageHeader.fetchOne($0, key: headerId) }
        #expect(header?.actionTag == .reply)
        #expect(header?.tagSortOrder == ActionTag.reply.sortOrder)
    }
}
