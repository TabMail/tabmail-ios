/* This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at https://mozilla.org/MPL/2.0/. */

import Testing
import Foundation
import GRDB
@testable import TabMail

// MARK: - Error classification

/// Tests for `AccountManager.isMessageNotFoundError` + new `isConfirmedGoneError`.
///
/// Covers the Culprit-#2 bugfix: Exchange/Gmail providers wrap HTTP 404 as
/// `ProviderError.networkError(underlying: HTTPError.networkError(statusCode: 404))`.
/// The old implementation only matched `(underlying as NSError).code == 404`, which
/// fails for the plain-Swift-enum HTTPError (bridging returns the case discriminator,
/// not the associated value). This suite exercises both the pre-existing branches
/// (no regression) AND the HTTPError-wrapped branch (the fix).
@Suite("AccountManager.isMessageNotFoundError — HTTPError unwrap + regression")
struct IsMessageNotFoundHTTPErrorTests {

    // MARK: - True cases (message IS considered gone)

    @Test("HTTPError(404) wrapped in ProviderError.networkError — the Culprit-#2 fix")
    @MainActor
    func httpError404() {
        let error = ProviderError.networkError(underlying: HTTPError.networkError(statusCode: 404))
        #expect(AccountManager.shared.isMessageNotFoundError(error) == true)
    }

    @Test("HTTPError(410) wrapped in ProviderError.networkError — not currently in scope for MessageNotFound (410 handled by ConfirmedGone only)")
    @MainActor
    func httpError410ForMessageNotFound() {
        // isMessageNotFoundError explicitly checks statusCode == 404. 410 is treated
        // as permanent-gone by isConfirmedGoneError but NOT by this classifier.
        // Keeping them separate so we don't accidentally over-drop pending ops on 410
        // from providers that use it for other semantics.
        let error = ProviderError.networkError(underlying: HTTPError.networkError(statusCode: 410))
        #expect(AccountManager.shared.isMessageNotFoundError(error) == false)
    }

    @Test("ProviderError.messageNotFound — pre-existing behavior, regression guard")
    @MainActor
    func providerMessageNotFound() {
        #expect(AccountManager.shared.isMessageNotFoundError(ProviderError.messageNotFound) == true)
    }

    @Test("NSError(code: 404) wrapped in ProviderError.networkError — pre-existing fallback")
    @MainActor
    func nsError404Fallback() {
        // The NSError(code: 404) path was the only 404 detection in the old code.
        // The fix ADDS HTTPError matching without removing the NSError fallback —
        // this test guards that any code path still throwing a raw NSError(404) works.
        let underlying = NSError(domain: "SomeDomain", code: 404, userInfo: nil)
        let error = ProviderError.networkError(underlying: underlying)
        #expect(AccountManager.shared.isMessageNotFoundError(error) == true)
    }

    @Test("IMAP 'NONEXISTENT' string match — pre-existing fallback")
    @MainActor
    func imapNonexistent() {
        let error = NSError(domain: "IMAP", code: 0, userInfo: [NSLocalizedDescriptionKey: "[NONEXISTENT] mailbox does not exist"])
        #expect(AccountManager.shared.isMessageNotFoundError(error) == true)
    }

    @Test("'no such message' string — pre-existing fallback")
    @MainActor
    func imapNoSuchMessage() {
        let error = NSError(domain: "IMAP", code: 0, userInfo: [NSLocalizedDescriptionKey: "IMAP server returned: no such message"])
        #expect(AccountManager.shared.isMessageNotFoundError(error) == true)
    }

    // MARK: - False cases (message is NOT gone — operation should retry)

    @Test("HTTPError(500) is NOT messageNotFound — transient")
    @MainActor
    func httpError500() {
        let error = ProviderError.networkError(underlying: HTTPError.networkError(statusCode: 500))
        #expect(AccountManager.shared.isMessageNotFoundError(error) == false)
    }

    @Test("HTTPError(429 rate limit) is NOT messageNotFound")
    @MainActor
    func httpError429() {
        let error = ProviderError.networkError(underlying: HTTPError.networkError(statusCode: 429))
        #expect(AccountManager.shared.isMessageNotFoundError(error) == false)
    }

    @Test("ProviderError.notConnected is NOT messageNotFound")
    @MainActor
    func notConnected() {
        #expect(AccountManager.shared.isMessageNotFoundError(ProviderError.notConnected) == false)
    }

    @Test("ProviderError.authenticationFailed is NOT messageNotFound")
    @MainActor
    func authFailed() {
        #expect(AccountManager.shared.isMessageNotFoundError(ProviderError.authenticationFailed) == false)
    }

    @Test("Plain 500 NSError is NOT messageNotFound")
    @MainActor
    func nsError500() {
        let underlying = NSError(domain: "SomeDomain", code: 500, userInfo: nil)
        let error = ProviderError.networkError(underlying: underlying)
        #expect(AccountManager.shared.isMessageNotFoundError(error) == false)
    }

    @Test("Generic error description is NOT messageNotFound")
    @MainActor
    func genericError() {
        struct Opaque: Error { }
        #expect(AccountManager.shared.isMessageNotFoundError(Opaque()) == false)
    }
}

/// Tests for the stricter `isConfirmedGoneError` sibling — gates header DELETION.
/// Only structural permanent-gone signals should trigger header deletion. The
/// string-matching fallback (used by `isMessageNotFoundError` for dropping the
/// pending op) deliberately does NOT trigger header deletion — too risky to
/// permanently delete user data on a fuzzy string.
@Suite("AccountManager.isConfirmedGoneError — strict header-delete gate")
struct IsConfirmedGoneErrorTests {

    // MARK: - True (delete header)

    @Test("ProviderError.messageNotFound is confirmed gone")
    @MainActor
    func providerMessageNotFound() {
        #expect(AccountManager.shared.isConfirmedGoneError(ProviderError.messageNotFound) == true)
    }

    @Test("HTTPError(404) is confirmed gone")
    @MainActor
    func http404() {
        let error = ProviderError.networkError(underlying: HTTPError.networkError(statusCode: 404))
        #expect(AccountManager.shared.isConfirmedGoneError(error) == true)
    }

    @Test("HTTPError(410 Gone) is confirmed gone")
    @MainActor
    func http410() {
        let error = ProviderError.networkError(underlying: HTTPError.networkError(statusCode: 410))
        #expect(AccountManager.shared.isConfirmedGoneError(error) == true)
    }

    @Test("NSError(code: 404) is confirmed gone")
    @MainActor
    func nsError404() {
        let underlying = NSError(domain: "D", code: 404, userInfo: nil)
        let error = ProviderError.networkError(underlying: underlying)
        #expect(AccountManager.shared.isConfirmedGoneError(error) == true)
    }

    @Test("NSError(code: 410) is confirmed gone")
    @MainActor
    func nsError410() {
        let underlying = NSError(domain: "D", code: 410, userInfo: nil)
        let error = ProviderError.networkError(underlying: underlying)
        #expect(AccountManager.shared.isConfirmedGoneError(error) == true)
    }

    // MARK: - False (do NOT delete header)

    @Test("String 'NONEXISTENT' is NOT confirmed gone — stricter than isMessageNotFoundError")
    @MainActor
    func stringNonexistent() {
        // isMessageNotFoundError returns true for this (drops pending op), but
        // isConfirmedGoneError returns false (won't delete header) — safety gate.
        let error = NSError(domain: "IMAP", code: 0, userInfo: [NSLocalizedDescriptionKey: "[NONEXISTENT] mailbox"])
        #expect(AccountManager.shared.isConfirmedGoneError(error) == false)
    }

    @Test("String 'no such message' is NOT confirmed gone — safety gate")
    @MainActor
    func stringNoSuchMessage() {
        let error = NSError(domain: "IMAP", code: 0, userInfo: [NSLocalizedDescriptionKey: "no such message"])
        #expect(AccountManager.shared.isConfirmedGoneError(error) == false)
    }

    @Test("HTTPError(500) is NOT confirmed gone")
    @MainActor
    func http500() {
        let error = ProviderError.networkError(underlying: HTTPError.networkError(statusCode: 500))
        #expect(AccountManager.shared.isConfirmedGoneError(error) == false)
    }

    @Test("ProviderError.notConnected is NOT confirmed gone")
    @MainActor
    func notConnected() {
        #expect(AccountManager.shared.isConfirmedGoneError(ProviderError.notConnected) == false)
    }

    @Test("ProviderError.authenticationFailed is NOT confirmed gone")
    @MainActor
    func authFailed() {
        #expect(AccountManager.shared.isConfirmedGoneError(ProviderError.authenticationFailed) == false)
    }

    @Test("Plain 500 NSError is NOT confirmed gone")
    @MainActor
    func nsError500() {
        let underlying = NSError(domain: "D", code: 500, userInfo: nil)
        let error = ProviderError.networkError(underlying: underlying)
        #expect(AccountManager.shared.isConfirmedGoneError(error) == false)
    }
}

// MARK: - Header deletion SQL correctness

/// Validates `AccountManager.deleteConfirmedGoneHeader`. The helper is scoped to
/// `headerId` (full `accountId:folderPath:messageId` primary key) — NOT to
/// `(accountId, messageId)` alone — so IMAP UIDs that coincide across folders
/// don't get mass-deleted when only one is confirmed gone.
@Suite("Confirmed-gone header deletion — scoped to exact headerId")
struct DeleteConfirmedGoneHeaderTests {

    /// `deleteConfirmedGoneHeader` reclaims the body through
    /// `MessageContentStore.releaseUnowned(…, stores: [.searchIndex, .body])` AFTER
    /// its delete transaction commits — Stage D (`v70_dropMessageBodyHeaderFK`)
    /// removed the FK cascade that used to do it inline. This pins the transaction
    /// half: the header goes, the body stays for the routed release to decide on.
    /// The end state (no body outlives its owner) is pinned against the production
    /// path in `ContentOwnershipSweepTests`, which has a real `DatabasePool`.
    @Test("DELETE by headerId removes the row and leaves messageBody to the routed release")
    func deleteLeavesBodyToTheRoutedRelease() throws {
        let db = try TestDatabase.make()
        try TestDatabase.insertAccount(db)
        try TestDatabase.insertFolder(db)
        let header = try TestDatabase.insertMessageHeader(db, messageId: "1")
        _ = try TestDatabase.insertMessageBody(db, headerId: header.id)

        let bodyCountBefore = try db.read { conn in
            try Int.fetchOne(conn, sql: "SELECT COUNT(*) FROM messageBody WHERE id = ?", arguments: [header.id]) ?? 0
        }
        #expect(bodyCountBefore == 1)

        let deleted: Bool = try db.write { conn in try MessageHeader.deleteOne(conn, key: header.id) }
        #expect(deleted == true)

        let headerCount = try db.read { conn in
            try Int.fetchOne(conn, sql: "SELECT COUNT(*) FROM messageHeader WHERE id = ?", arguments: [header.id]) ?? 0
        }
        #expect(headerCount == 0)

        let bodyCountAfter = try db.read { conn in
            try Int.fetchOne(conn, sql: "SELECT COUNT(*) FROM messageBody WHERE id = ?", arguments: [header.id]) ?? 0
        }
        #expect(bodyCountAfter == 1,
                "the delete transaction must not reclaim content — only the routed release may")
    }

    /// The exact bug that motivated the audit fix. Two IMAP folders in one account
    /// can hold the same UID — they are unrelated messages (UID space is per-folder).
    /// A broader `WHERE accountId=? AND messageId=?` delete would wipe both when one
    /// is 404'd. A headerId-scoped delete affects only the specific row.
    @Test("Same UID in two folders (IMAP collision) — only the target headerId is deleted")
    func sameUidAcrossFoldersOnlyOneDeleted() throws {
        let db = try TestDatabase.make()
        try TestDatabase.insertAccount(db, id: "acc1")
        try TestDatabase.insertFolder(db, name: "INBOX", path: "INBOX", accountId: "acc1")
        try TestDatabase.insertFolder(db, name: "Archive", path: "Archive", role: .archive, accountId: "acc1")

        let inboxUid42 = try TestDatabase.insertMessageHeader(
            db, messageId: "42", folderId: "acc1:INBOX", accountId: "acc1",
            folderPath: "INBOX", isInInbox: true
        )
        let archiveUid42 = try TestDatabase.insertMessageHeader(
            db, messageId: "42", folderId: "acc1:Archive", accountId: "acc1",
            folderPath: "Archive", isInInbox: false
        )
        #expect(inboxUid42.id != archiveUid42.id)

        let deleted: Bool = try db.write { conn in try MessageHeader.deleteOne(conn, key: inboxUid42.id) }
        #expect(deleted == true)

        let inboxStillThere = try db.read { conn in
            try Int.fetchOne(conn, sql: "SELECT COUNT(*) FROM messageHeader WHERE id = ?", arguments: [inboxUid42.id]) ?? 0
        }
        let archiveStillThere = try db.read { conn in
            try Int.fetchOne(conn, sql: "SELECT COUNT(*) FROM messageHeader WHERE id = ?", arguments: [archiveUid42.id]) ?? 0
        }
        #expect(inboxStillThere == 0, "Target INBOX UID 42 should be deleted")
        #expect(archiveStillThere == 1, "Archive UID 42 (unrelated message) MUST survive")
    }

    /// Different accounts with same messageId — must not cross-delete either.
    @Test("Same messageId across accounts — scoped by primary key, only target account's row is deleted")
    func sameMessageIdAcrossAccounts() throws {
        let db = try TestDatabase.make()
        try TestDatabase.insertAccount(db, id: "accA")
        try TestDatabase.insertAccount(db, id: "accB", email: "b@example.com")
        try TestDatabase.insertFolder(db, accountId: "accA")
        try TestDatabase.insertFolder(db, accountId: "accB")
        let a = try TestDatabase.insertMessageHeader(db, messageId: "same", folderId: "accA:INBOX", accountId: "accA")
        let b = try TestDatabase.insertMessageHeader(db, messageId: "same", folderId: "accB:INBOX", accountId: "accB")

        _ = try db.write { conn in try MessageHeader.deleteOne(conn, key: a.id) }

        let aGone = try db.read { conn in
            try Int.fetchOne(conn, sql: "SELECT COUNT(*) FROM messageHeader WHERE id = ?", arguments: [a.id]) ?? 0
        }
        let bStill = try db.read { conn in
            try Int.fetchOne(conn, sql: "SELECT COUNT(*) FROM messageHeader WHERE id = ?", arguments: [b.id]) ?? 0
        }
        #expect(aGone == 0)
        #expect(bStill == 1)
    }

    /// `deleteOne` on an absent key is a no-op — safe to call even when another
    /// queue (or full-sync) has already removed the row.
    @Test("DELETE for absent headerId is a safe no-op")
    func deleteAbsentHeaderIsNoOp() throws {
        let db = try TestDatabase.make()
        try TestDatabase.insertAccount(db)
        let deleted: Bool = try db.write { conn in try MessageHeader.deleteOne(conn, key: "acc1:INBOX:doesnotexist") }
        #expect(deleted == false)
    }

    /// Regression guard: if headerId format ever changes, the PendingOperation
    /// drain call site (which reconstructs headerId via MessageIdentity) must
    /// continue to produce a key that matches the primary key contract.
    @Test("MessageIdentity.headerId format matches MessageHeader primary key")
    func headerIdFormat() throws {
        let db = try TestDatabase.make()
        try TestDatabase.insertAccount(db)
        try TestDatabase.insertFolder(db)
        let header = try TestDatabase.insertMessageHeader(db, messageId: "100")
        let reconstructed = MessageIdentity.headerId(
            accountId: header.accountId,
            folderPath: header.folderPath,
            messageId: header.messageId
        )
        #expect(reconstructed == header.id)
    }
}
