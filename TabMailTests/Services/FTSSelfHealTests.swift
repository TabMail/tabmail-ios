/* This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at https://mozilla.org/MPL/2.0/. */

import Testing
import Foundation
import GRDB
@testable import TabMail

/// Covers the data-integrity scenario where `messageHeader.bodyComplete = 1`
/// but the FTS index has no row for the headerId. This state was produced by
/// historical buggy write paths (pre-fix NSE merge, attachment-only BodyFetch
/// branch, v31 snapshot migration) and left messages stuck in an AI-dropping
/// loop. The fix is `SyncEngine.selfHealFTSBodyMembership`, which uses
/// `SearchIndex.contentKeysMissingFromFTS` + re-index + reset bodyComplete=0.
@Suite("FTS Self-Heal - Missing Body Membership", .serialized, .processGlobalState)
struct FTSSelfHealTests {

    private var index: SearchIndex { SearchIndex.shared }
    private func prefix(_ label: String) -> String { "selfheal_\(label)" }

    @Test("contentKeysMissingFromFTS returns headers not indexed in FTS")
    func detectsMissingHeaders() async throws {
        let indexedId = "\(prefix("det")):INBOX:present"
        let missingId = "\(prefix("det")):INBOX:absent"

        // Clean any leftovers
        try await index.removeMessages( contentKeys: [indexedId, missingId].map(ContentKey.init(rawValue:)))

        // Index one, leave the other absent
        let record = FTSHeaderRecord( contentKey: ContentKey(rawValue: indexedId),
            headerId: indexedId,
            messageId: "m1",
            subject: "Present",
            from: "a@test.com",
            to: "b@test.com",
            dateMs: Int64(Date().timeIntervalSince1970 * 1000)
        )
        _ = try await index.indexHeaders([record])

        let missing = try await index.contentKeysMissingFromFTS([indexedId, missingId].map(ContentKey.init(rawValue:)))
        #expect(missing.count == 1)
        #expect(missing.contains(ContentKey(rawValue: missingId)))
        #expect(!missing.contains(ContentKey(rawValue: indexedId)))

        try await index.removeMessages( contentKeys: [indexedId].map(ContentKey.init(rawValue:)))
    }

    @Test("Stuck-state is healable: detect, re-index, reset bodyComplete")
    func healStuckMessage() async throws {
        let db = try TestDatabase.make()
        try TestDatabase.insertAccount(db)
        try TestDatabase.insertFolder(db)

        // Simulate the bug: GRDB has a header with bodyComplete=1 and
        // headerComplete=1, but FTS has no row (as produced by old NSE merge
        // or attachment-only branch).
        let header = try TestDatabase.insertMessageHeader(
            db,
            messageId: "stuck_1",
            subject: "Stuck Message",
            date: Date(),
            snippet: "previously snippeted"
        )
        try await db.write { conn in
            try conn.execute(
                sql: "UPDATE messageHeader SET bodyComplete = 1, headerComplete = 1 WHERE id = ?",
                arguments: [header.id]
            )
        }
        try await index.removeMessages( contentKeys: [header.id].map(ContentKey.init(rawValue:)))

        // Step 1: detect
        let missing = try await index.contentKeysMissingFromFTS([header.id].map(ContentKey.init(rawValue:)))
        #expect(missing == [ContentKey(rawValue: header.id)])

        // Step 2: re-index (what indexHeadersForFTS does)
        let record = FTSHeaderRecord( contentKey: ContentKey(rawValue: header.id),
            headerId: header.id,
            messageId: header.messageId,
            subject: header.subject,
            from: "\(header.from) <\(header.fromAddress)>",
            to: header.to,
            dateMs: Int64(header.date.timeIntervalSince1970 * 1000)
        )
        let inserted = try await index.indexHeaders([record])
        #expect(inserted == 1)

        // Step 3: reset bodyComplete=0 so body queue re-runs
        try await db.write { conn in
            try conn.execute(
                sql: "UPDATE messageHeader SET bodyComplete = 0 WHERE id = ?",
                arguments: [header.id]
            )
        }

        // Post-heal invariants:
        // - no longer missing from FTS
        let stillMissing = try await index.contentKeysMissingFromFTS([header.id].map(ContentKey.init(rawValue:)))
        #expect(stillMissing.isEmpty)

        // - bodyComplete is now 0 (eligible for body queue)
        let flag: Bool = try await db.read { conn in
            try Bool.fetchOne(conn,
                sql: "SELECT bodyComplete FROM messageHeader WHERE id = ?",
                arguments: [header.id]) ?? true
        }
        #expect(flag == false)

        // - headerComplete stays 1 (unchanged by self-heal)
        let headerFlag: Bool = try await db.read { conn in
            try Bool.fetchOne(conn,
                sql: "SELECT headerComplete FROM messageHeader WHERE id = ?",
                arguments: [header.id]) ?? false
        }
        #expect(headerFlag == true)

        try await index.removeMessages( contentKeys: [header.id].map(ContentKey.init(rawValue:)))
    }

    @Test("Attachment-only placeholder body writes to FTS when header is indexed")
    func attachmentPlaceholderWritesToFTS() async throws {
        // Covers BodyFetchProcessor.process attachment-only branch: routes a
        // "[attachment]" placeholder through flushBatch → updateBodies. Must
        // actually write to FTS (not be filtered as whitespace) so bodyComplete
        // can legitimately advance to 1.
        let hid = "\(prefix("att")):INBOX:1"
        try await index.removeMessages( contentKeys: [hid].map(ContentKey.init(rawValue:)))

        let record = FTSHeaderRecord( contentKey: ContentKey(rawValue: hid),
            headerId: hid,
            messageId: "m_att",
            subject: "Invoice PDF",
            from: "a@test.com",
            to: "b@test.com",
            dateMs: Int64(Date().timeIntervalSince1970 * 1000)
        )
        _ = try await index.indexHeaders([record])

        let written = try await index.updateBodies([(headerId: hid, body: "[attachment]")].map { (contentKey: ContentKey(rawValue: $0.headerId), body: $0.body) })
        #expect(written.contains(ContentKey(rawValue: hid)), "placeholder body must write to FTS — otherwise bodyComplete gets silently deferred forever")

        // And the FTS body is retrievable
        let body = try await index.bodyText( contentKey: ContentKey(rawValue: hid))
        #expect(body == "[attachment]")

        try await index.removeMessages( contentKeys: [hid].map(ContentKey.init(rawValue:)))
    }

    @Test("NSE rollback invariant: updateBodies returns empty when header absent from FTS")
    func nseRollbackSignal() async throws {
        // Covers the NSE persistRenderedBodyFromStaging post-transaction Task:
        // when FTS header row doesn't exist yet, updateBodies must return an
        // empty written set so the Task can roll bodyComplete back to 0.
        // Without this signal, NSE-created messages stay stuck.
        let hid = "\(prefix("nse")):INBOX:rollback"
        try await index.removeMessages( contentKeys: [hid].map(ContentKey.init(rawValue:)))  // ensure absent

        let written = try await index.updateBodies([(headerId: hid, body: "real body text")].map { (contentKey: ContentKey(rawValue: $0.headerId), body: $0.body) })
        #expect(written.isEmpty, "missing FTS header must yield empty writtenIds → triggers NSE rollback path")
    }

    @Test("Healthy messages (bodyComplete=1 + in FTS) are not flagged as missing")
    func healthyMessagesIgnored() async throws {
        let db = try TestDatabase.make()
        try TestDatabase.insertAccount(db)
        try TestDatabase.insertFolder(db)

        let header = try TestDatabase.insertMessageHeader(
            db,
            messageId: "healthy_1",
            subject: "Healthy Message"
        )
        try await db.write { conn in
            try conn.execute(
                sql: "UPDATE messageHeader SET bodyComplete = 1, headerComplete = 1 WHERE id = ?",
                arguments: [header.id]
            )
        }

        // Properly indexed in FTS
        let record = FTSHeaderRecord( contentKey: ContentKey(rawValue: header.id),
            headerId: header.id,
            messageId: header.messageId,
            subject: header.subject,
            from: "\(header.from) <\(header.fromAddress)>",
            to: header.to,
            dateMs: Int64(header.date.timeIntervalSince1970 * 1000)
        )
        _ = try await index.indexHeaders([record])

        let missing = try await index.contentKeysMissingFromFTS([header.id].map(ContentKey.init(rawValue:)))
        #expect(missing.isEmpty, "Healthy message should not be flagged as missing from FTS")

        try await index.removeMessages( contentKeys: [header.id].map(ContentKey.init(rawValue:)))
    }
}

// MARK: - Candidate scope (non-inbox coverage)

/// Locks the heal's candidate contract. Pre-rekeyHeaders UID remaps produced
/// the stuck state (bodyComplete=1, missing from FTS) on MOVED — i.e.
/// non-inbox — messages; the heal was originally inbox-scoped and silently
/// skipped exactly those rows.
@Suite("FTS Self-Heal candidate scope")
struct FTSSelfHealCandidateScopeTests {

    @Test("Candidate query includes non-inbox stuck rows (UID-remap ghosts)")
    func candidateQueryCoversNonInbox() async throws {
        let db = try TestDatabase.make()
        try TestDatabase.insertAccount(db)
        try TestDatabase.insertFolder(db)
        try TestDatabase.insertFolder(db, name: "Archive", path: "Archive", role: .archive)

        let archived = try TestDatabase.insertMessageHeader(
            db, messageId: "nonbox_1",
            folderId: "acc1:Archive", accountId: "acc1", folderPath: "Archive",
            isInInbox: false
        )
        let inboxed = try TestDatabase.insertMessageHeader(
            db, messageId: "inbox_1",
            folderId: "acc1:INBOX", accountId: "acc1", folderPath: "INBOX",
            isInInbox: true
        )
        try await db.write { conn in
            for id in [archived.id, inboxed.id] {
                try conn.execute(
                    sql: "UPDATE messageHeader SET bodyComplete = 1, headerComplete = 1 WHERE id = ?",
                    arguments: [id]
                )
            }
        }

        // The EXACT SQL the heal runs — shared constant, not a copy.
        let candidates: [String] = try await db.read { conn in
            try String.fetchAll(conn, sql: SyncEngine.ftsBodyMembershipCandidateSQL)
        }
        #expect(candidates.contains(archived.id))
        #expect(candidates.contains(inboxed.id))
    }

    @Test("Candidate query excludes rows without bodyComplete")
    func candidateQueryExcludesIncomplete() async throws {
        let db = try TestDatabase.make()
        try TestDatabase.insertAccount(db)
        try TestDatabase.insertFolder(db)

        let pending = try TestDatabase.insertMessageHeader(db, messageId: "pending_1")
        try await db.write { conn in
            try conn.execute(
                sql: "UPDATE messageHeader SET bodyComplete = 0, headerComplete = 1 WHERE id = ?",
                arguments: [pending.id]
            )
        }

        let candidates: [String] = try await db.read { conn in
            try String.fetchAll(conn, sql: SyncEngine.ftsBodyMembershipCandidateSQL)
        }
        #expect(!candidates.contains(pending.id))
    }
}
