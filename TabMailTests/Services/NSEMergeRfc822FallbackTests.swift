/* This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at https://mozilla.org/MPL/2.0/. */

import Testing
import Foundation
import GRDB
@testable import TabMail

/// Regression coverage for commit 92d85ca — "Dedup NSE staging merge by
/// rfc822MessageId fallback". The commit changed `NSEDataBridge.mergeNSE-
/// StagingData` to add a second lookup by (accountId, rfc822MessageId) when
/// the primary (accountId, messageId) lookup misses. Without it, an IMAP
/// archive → undo round-trip re-assigns a fresh UID in INBOX, the push
/// notification carries that new UID as messageId, the primary lookup misses,
/// and the merge inserts a duplicate header.
///
/// The merge body runs inside a big `AppDatabase.dbPool.write` and isn't
/// exposed as a unit-testable seam. Mirroring the MergeIdempotenceTests
/// pattern, these tests exercise the exact SQL the helper emits against an
/// in-memory DB. Drift between the production SQL and these queries surfaces
/// as a test-file change — keeping the contract legible at the boundary.
@Suite("NSE merge rfc822 fallback lookup (SQL contract)")
struct NSEMergeRfc822FallbackTests {

    /// Lookup sequence the production merge uses. Lifted verbatim from
    /// `NSEDataBridge.swift:379-389`. If the file changes, update this helper
    /// and re-verify the test still proves the invariant.
    private func existingHeaderRow(
        db: Database,
        accountId: String,
        messageId: String,
        rfc822MessageId: String?
    ) throws -> Row? {
        // Primary lookup — by messageId.
        var row = try Row.fetchOne(db, sql: """
            SELECT id, folderPath, rfc822MessageId FROM messageHeader
            WHERE accountId = ? AND messageId = ?
            """, arguments: [accountId, messageId])
        // Fallback lookup — by rfc822MessageId when the primary misses and
        // the staged row carries a non-empty rfc822 Message-ID.
        if row == nil,
           let rfc822 = rfc822MessageId, !rfc822.isEmpty {
            row = try Row.fetchOne(db, sql: """
                SELECT id, folderPath, rfc822MessageId FROM messageHeader
                WHERE accountId = ? AND rfc822MessageId = ?
                """, arguments: [accountId, rfc822])
        }
        return row
    }

    @Test("Primary lookup matches → fallback is not needed")
    func primaryHit() throws {
        let db = try TestDatabase.make()
        try TestDatabase.insertAccount(db, id: "acc1", email: "u@ex.com")
        try TestDatabase.insertFolder(db, name: "INBOX", path: "INBOX", role: .inbox, accountId: "acc1")
        try TestDatabase.insertMessageHeader(
            db, messageId: "uid-100", folderId: "acc1:INBOX",
            accountId: "acc1", rfc822MessageId: "rfc-abc@example.com"
        )

        try db.read { conn in
            let row = try existingHeaderRow(
                db: conn,
                accountId: "acc1",
                messageId: "uid-100",
                rfc822MessageId: "rfc-abc@example.com"
            )
            #expect(row != nil)
            #expect(row?["rfc822MessageId"] == "rfc-abc@example.com")
        }
    }

    @Test("Primary misses, fallback matches by rfc822 (archive→undo UID remap)")
    func fallbackByRfc822() throws {
        // Existing header under the PRE-archive UID ("uid-100"). User archives,
        // then undoes → server MOVE-BACK assigns a fresh UID ("uid-555") in
        // INBOX. Push notification fires with the new UID as messageId.
        let db = try TestDatabase.make()
        try TestDatabase.insertAccount(db, id: "acc1", email: "u@ex.com")
        try TestDatabase.insertFolder(db, name: "INBOX", path: "INBOX", role: .inbox, accountId: "acc1")
        try TestDatabase.insertMessageHeader(
            db, messageId: "uid-100", folderId: "acc1:INBOX",
            accountId: "acc1", rfc822MessageId: "rfc-xyz@example.com"
        )

        try db.read { conn in
            // NSE staging carries (uid-555, rfc-xyz). Primary lookup misses;
            // fallback should find the pre-archive header by rfc822 match.
            let row = try existingHeaderRow(
                db: conn,
                accountId: "acc1",
                messageId: "uid-555",                    // post-remap UID
                rfc822MessageId: "rfc-xyz@example.com"   // stable across the move
            )
            #expect(row != nil, "Fallback by rfc822 must find the pre-remap header")
            #expect(row?["rfc822MessageId"] == "rfc-xyz@example.com")
        }
    }

    @Test("Primary misses, no rfc822 provided → no fallback, nothing matches")
    func fallbackSkippedWithoutRfc822() throws {
        let db = try TestDatabase.make()
        try TestDatabase.insertAccount(db, id: "acc1", email: "u@ex.com")
        try TestDatabase.insertFolder(db, name: "INBOX", path: "INBOX", role: .inbox, accountId: "acc1")
        try TestDatabase.insertMessageHeader(
            db, messageId: "uid-100", folderId: "acc1:INBOX",
            accountId: "acc1", rfc822MessageId: "rfc-xyz@example.com"
        )

        try db.read { conn in
            let row = try existingHeaderRow(
                db: conn,
                accountId: "acc1",
                messageId: "uid-555",
                rfc822MessageId: nil
            )
            #expect(row == nil)
        }
    }

    @Test("Primary misses, empty rfc822 → no fallback, nothing matches")
    func fallbackSkippedWithEmptyRfc822() throws {
        let db = try TestDatabase.make()
        try TestDatabase.insertAccount(db, id: "acc1", email: "u@ex.com")
        try TestDatabase.insertFolder(db, name: "INBOX", path: "INBOX", role: .inbox, accountId: "acc1")
        try TestDatabase.insertMessageHeader(
            db, messageId: "uid-100", folderId: "acc1:INBOX",
            accountId: "acc1", rfc822MessageId: "rfc-xyz@example.com"
        )

        try db.read { conn in
            // Empty-string rfc822 must be treated the same as nil per the
            // `!rfc822.isEmpty` guard. If the guard is dropped we'd match all
            // rows with empty rfc822, which is wrong.
            let row = try existingHeaderRow(
                db: conn,
                accountId: "acc1",
                messageId: "uid-555",
                rfc822MessageId: ""
            )
            #expect(row == nil)
        }
    }

    @Test("Fallback is scoped by accountId (same rfc822 on different account does not match)")
    func fallbackScopedByAccount() throws {
        // Two separate accounts both receive the same Message-ID (e.g. same
        // list, same user on two gmail addresses). The fallback must NOT
        // cross-match — each account owns its own row.
        let db = try TestDatabase.make()
        try TestDatabase.insertAccount(db, id: "acc1", email: "u1@ex.com")
        try TestDatabase.insertAccount(db, id: "acc2", email: "u2@ex.com")
        try TestDatabase.insertFolder(db, name: "INBOX", path: "INBOX", role: .inbox, accountId: "acc1")
        try TestDatabase.insertFolder(db, name: "INBOX", path: "INBOX", role: .inbox, accountId: "acc2")
        try TestDatabase.insertMessageHeader(
            db, messageId: "uid-100", folderId: "acc1:INBOX",
            accountId: "acc1", rfc822MessageId: "rfc-shared@example.com"
        )

        try db.read { conn in
            let row = try existingHeaderRow(
                db: conn,
                accountId: "acc2",                          // different account
                messageId: "uid-200",
                rfc822MessageId: "rfc-shared@example.com"
            )
            #expect(row == nil, "Fallback must be scoped by accountId")
        }
    }
}
