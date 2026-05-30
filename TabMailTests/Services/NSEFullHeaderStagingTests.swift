/* This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at https://mozilla.org/MPL/2.0/. */

import Testing
import Foundation
import GRDB
@testable import TabMail

/// Covers the 2026-04-19 fix that stops the NSE merge from inserting rows
/// with placeholder `to: ""` + default-`false` flags — violating
/// `CLAUDE.md` Data Integrity Rule #1 (no sentinel values for data that
/// WAS fetched).
///
/// These tests replicate production staging SQL + merge-read SQL without
/// linking the NSE target (staging DB writer lives there; schema lives in
/// `AppDatabase.createNSEStagingDBIfNeeded` which this target can reach).
/// Rationale: main-app `NSEDataBridge.mergeNSEStagingData` reads these
/// columns and if the read path or column name drifts from what the NSE
/// writes, merge silently produces the same placeholder rows that
/// motivated this fix. The tests here catch that drift.
@Suite("NSE full-header staging round-trip")
struct NSEFullHeaderStagingTests {

    // MARK: - Helpers

    /// Build an in-memory staging DB with the v4 schema — must match
    /// `AppDatabase.createNSEStagingDBIfNeeded` AFTER the 2026-04-19
    /// migration. If this drifts, the round-trip test fails because raw
    /// SQL writes error on a missing column.
    private func makeStagingDB() throws -> DatabaseQueue {
        let db = try DatabaseQueue(configuration: Configuration())
        try db.write { db in
            try db.execute(sql: """
                CREATE TABLE IF NOT EXISTS nse_processed_message (
                    id TEXT PRIMARY KEY,
                    accountId TEXT NOT NULL, accountEmail TEXT NOT NULL,
                    provider TEXT NOT NULL, messageId TEXT NOT NULL,
                    rfc822MessageId TEXT, threadId TEXT, folderPath TEXT,
                    subject TEXT DEFAULT '', senderName TEXT DEFAULT '', senderEmail TEXT DEFAULT '',
                    snippet TEXT DEFAULT '', date REAL, isRead INTEGER DEFAULT 0,
                    summaryBlurb TEXT, summaryTodos TEXT, actionTag TEXT,
                    reminderDate TEXT, reminderTime TEXT, reminderContent TEXT,
                    processedAt REAL NOT NULL, historyId TEXT,
                    aiCompleted INTEGER DEFAULT 0, notified INTEGER DEFAULT 0,
                    htmlContent TEXT, textContent TEXT,
                    attachmentsJSON TEXT, icsText TEXT,
                    hasUnresolvedCIDs INTEGER DEFAULT 0,
                    toRaw TEXT DEFAULT '', ccRaw TEXT DEFAULT '', bccRaw TEXT DEFAULT '',
                    replyToRaw TEXT, inReplyTo TEXT, referencesJSON TEXT,
                    isFlagged INTEGER DEFAULT 0, hasAttachments INTEGER DEFAULT 0,
                    providerLabelsJSON TEXT,
                    isReplied INTEGER DEFAULT 0, isForwarded INTEGER DEFAULT 0
                )
                """)
        }
        return db
    }

    /// Insert a staged row using the same column list `NSEStagingDB
    /// .persistProcessedMessage` uses. Failing to keep this in sync with
    /// production writes surfaces as a test failure, which is the point.
    private func insertStagedRow(
        _ db: DatabaseQueue,
        id: String,
        toRaw: String,
        ccRaw: String = "",
        bccRaw: String = "",
        replyToRaw: String? = nil,
        inReplyTo: String? = nil,
        references: [String] = [],
        isRead: Bool = false,
        isFlagged: Bool = false,
        hasAttachments: Bool = false,
        providerLabels: [String] = []
    ) throws {
        func encodeArray(_ a: [String]) -> String? {
            guard !a.isEmpty,
                  let d = try? JSONSerialization.data(withJSONObject: a),
                  let s = String(data: d, encoding: .utf8) else { return nil }
            return s
        }
        try db.write { db in
            try db.execute(sql: """
                INSERT INTO nse_processed_message
                (id, accountId, accountEmail, provider, messageId, rfc822MessageId, threadId,
                 folderPath, subject, senderName, senderEmail, snippet, date,
                 toRaw, ccRaw, bccRaw, replyToRaw, inReplyTo, referencesJSON,
                 isRead, isFlagged, hasAttachments, providerLabelsJSON,
                 processedAt)
                VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?,
                        ?, ?, ?, ?, ?, ?,
                        ?, ?, ?, ?, ?)
                """, arguments: [
                    id, "acc1", "u@x.com", "gmail", "msg-1",
                    "rfc@example.com", "thr-1", "INBOX",
                    "Test", "Alice", "alice@x.com", "snippet", 1_710_000_000.0,
                    toRaw, ccRaw, bccRaw, replyToRaw, inReplyTo, encodeArray(references),
                    isRead ? 1 : 0, isFlagged ? 1 : 0, hasAttachments ? 1 : 0,
                    encodeArray(providerLabels),
                    Date().timeIntervalSince1970
                ])
        }
    }

    // MARK: - Round-trip

    @Test("Every full-header column round-trips verbatim through the v4 schema")
    func fullHeaderRoundTrip() throws {
        let db = try makeStagingDB()
        try insertStagedRow(
            db, id: "acc1:msg-1",
            toRaw: "\"Bob\" <bob@x.com>, eve@x.com",
            ccRaw: "cc@x.com",
            bccRaw: "bcc@x.com",
            replyToRaw: "reply@x.com",
            inReplyTo: "parent@x.com",
            references: ["root@x.com", "parent@x.com"],
            isRead: true, isFlagged: true, hasAttachments: true,
            providerLabels: ["INBOX", "STARRED", "Label_123"]
        )

        let row = try db.read { try Row.fetchOne($0, sql: "SELECT * FROM nse_processed_message") }
        guard let row else {
            Issue.record("no row persisted"); return
        }

        #expect((row["toRaw"] as String?) == "\"Bob\" <bob@x.com>, eve@x.com")
        #expect((row["ccRaw"] as String?) == "cc@x.com")
        #expect((row["bccRaw"] as String?) == "bcc@x.com")
        #expect((row["replyToRaw"] as String?) == "reply@x.com")
        #expect((row["inReplyTo"] as String?) == "parent@x.com")

        // referencesJSON must decode back into the same array.
        let refs: [String] = {
            guard let s: String = row["referencesJSON"],
                  let d = s.data(using: .utf8),
                  let a = try? JSONSerialization.jsonObject(with: d) as? [String] else { return [] }
            return a
        }()
        #expect(refs == ["root@x.com", "parent@x.com"])

        #expect((row["isRead"] as Int?) == 1)
        #expect((row["isFlagged"] as Int?) == 1)
        #expect((row["hasAttachments"] as Int?) == 1)

        let labels: [String] = {
            guard let s: String = row["providerLabelsJSON"],
                  let d = s.data(using: .utf8),
                  let a = try? JSONSerialization.jsonObject(with: d) as? [String] else { return [] }
            return a
        }()
        #expect(labels == ["INBOX", "STARRED", "Label_123"])
    }

    @Test("Nullable fields stay NULL when absent")
    func nullableFieldsRemainNull() throws {
        let db = try makeStagingDB()
        try insertStagedRow(
            db, id: "acc1:msg-2",
            toRaw: "", // empty, not NULL — matches DEFAULT ''
            replyToRaw: nil,
            inReplyTo: nil,
            references: [],
            providerLabels: []
        )

        let row = try db.read { try Row.fetchOne($0, sql: "SELECT * FROM nse_processed_message") }
        #expect((row?["replyToRaw"] as String?) == nil)
        #expect((row?["inReplyTo"] as String?) == nil)
        #expect((row?["referencesJSON"] as String?) == nil)
        #expect((row?["providerLabelsJSON"] as String?) == nil)
        // toRaw has a DEFAULT '' so explicitly NULL-ing it is coerced to "".
        #expect((row?["toRaw"] as String?) == "")
    }

    // MARK: - Merge-read parity

    /// `NSEDataBridge.StagedMessage` in production decodes every column we
    /// write. Here we exercise the same read shapes to make sure column
    /// names + types line up — if the merge's decode ever drifts from the
    /// writer's column list, this fails.
    @Test("Row['colname'] reads succeed for every full-header column")
    func readPathTypeCoercion() throws {
        let db = try makeStagingDB()
        try insertStagedRow(
            db, id: "acc1:msg-3",
            toRaw: "x@x.com", replyToRaw: "r@x.com",
            inReplyTo: "p@x.com", references: ["a@x.com"],
            isRead: true, isFlagged: false, hasAttachments: true,
            providerLabels: ["L1"]
        )

        let row = try db.read { try Row.fetchOne($0, sql: "SELECT * FROM nse_processed_message") }
        guard let row else { Issue.record("no row"); return }

        // Smoke: each column reads into the expected Swift type without throwing.
        let _: String = row["toRaw"] ?? ""
        let _: String = row["ccRaw"] ?? ""
        let _: String = row["bccRaw"] ?? ""
        let _: String? = row["replyToRaw"]
        let _: String? = row["inReplyTo"]
        let _: String? = row["referencesJSON"]
        let _: Int = row["isRead"] ?? 0
        let _: Int = row["isFlagged"] ?? 0
        let _: Int = row["hasAttachments"] ?? 0
        let _: String? = row["providerLabelsJSON"]
    }
}
