/* This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at https://mozilla.org/MPL/2.0/. */

import Testing
import Foundation
import GRDB
@testable import TabMail

/// Locks `SearchResult`'s identity contract (the Bug-1 fix).
///
/// The id MUST be a stable, content-derived `accountId + folderPath +
/// messageId` — never a fresh `UUID()` (which churned across the per-keystroke
/// array rebuilds and made SwiftUI paint the wrong subject) and never bare
/// `messageId` (IMAP's per-folder UID repeats across folders, so a search-all
/// over several folders of one account would mint DUPLICATE identities → wrong
/// subject again).
///
/// 🚨 The account term is `Account.id`, not `emailAddress` (audit round 1 / C-3):
/// an address is not a key, and two accounts holding one address collapsed into a
/// single identity.
@Suite("SearchResult identity (folder-aware, stable)")
struct SearchResultIdentityTests {

    private func make(
        accountId: String, email: String = "a@example.com", folder: String, msg: String
    ) -> SearchResult {
        SearchResult(
            source: .remote, accountId: accountId, accountEmail: email,
            messageId: msg, folderPath: folder,
            subject: "subject for \(folder)/\(msg)", from: "From", fromAddress: "from@example.com",
            date: Date(), snippet: "", isRead: false, isFlagged: false, headerId: nil
        )
    }

    @Test("Same (account, folder, messageId) → identical, stable id")
    func sameMessageSameId() {
        let a = make(accountId: "acc-a", folder: "INBOX", msg: "5")
        let b = make(accountId: "acc-a", folder: "INBOX", msg: "5")
        #expect(a.id == b.id, "the same message must keep one identity across array rebuilds")
    }

    @Test("Same account + same UID, DIFFERENT folder → different id (IMAP cross-folder collision)")
    func crossFolderUidDoesNotCollide() {
        let inbox = make(accountId: "acc-a", folder: "INBOX", msg: "5")
        let archive = make(accountId: "acc-a", folder: "Archive", msg: "5")
        #expect(inbox.id != archive.id, "per-folder UIDs collide on messageId alone — folder must disambiguate")
    }

    @Test("Different account, same folder+messageId → different id")
    func differentAccountDifferentId() {
        let a = make(accountId: "acc-a", email: "a@example.com", folder: "INBOX", msg: "5")
        let b = make(accountId: "acc-b", email: "b@example.com", folder: "INBOX", msg: "5")
        #expect(a.id != b.id)
    }

    /// 🚨 AUDIT ROUND 1 / C-3. Two accounts CAN carry the same address — the same
    /// mailbox alias on two servers, two credential sets during a migration —
    /// because `Account.id` is a UUID and nothing constrains `emailAddress`. Keyed
    /// on the address, these two results were ONE identity: the list showed one row
    /// for two different messages, and whichever `SearchResult` value the row
    /// carried decided which account's message the tap opened and marked read.
    @Test("Two accounts sharing one email address still produce DIFFERENT result identities")
    func sameEmailDifferentAccountsDoNotCollide() {
        let a = make(accountId: "acc-a", email: "shared@example.com", folder: "INBOX", msg: "5")
        let b = make(accountId: "acc-b", email: "shared@example.com", folder: "INBOX", msg: "5")
        #expect(a.id != b.id,
                """
                two accounts sharing an address collapsed to one result identity. UID 5 on server A and \
                UID 5 on server B are different messages, and the surviving row decides which one a tap \
                opens and durably marks read (C3).
                """)
    }

    @Test("Different messageId in the same folder → different id")
    func differentMessageDifferentId() {
        let a = make(accountId: "acc-a", folder: "INBOX", msg: "5")
        let b = make(accountId: "acc-a", folder: "INBOX", msg: "6")
        #expect(a.id != b.id)
    }

    @Test("id is not a UUID — equal-content results in a ForEach must share identity")
    func idIsContentDerivedNotRandom() {
        // Two SearchResult VALUES with identical content (as a re-sort/rebuild
        // produces) must resolve to the SAME ForEach identity. A UUID()-based id
        // would make these two distinct → the row-recycling subject bug.
        let ids = Set((0..<3).map { _ in make(accountId: "acc-a", folder: "INBOX", msg: "5").id })
        #expect(ids.count == 1, "content-equal results must collapse to one identity, not three")
    }
}

/// Locks the folder-scoped, fail-CLOSED contract of
/// `SearchView.resolveRemoteResultHeaderId` — the resolver every REMOTE search
/// result passes through when the user TAPS it.
///
/// The invariant, not the mechanism: **the row a tap opens must be the row the
/// tapped result names, or nothing at all.** Opening seeds
/// `MessageDetailView`/`MessageDetailViewModel`, whose `markReadOnOpenIfNeeded`
/// durably marks the opened message read, so a wrong resolve is a wrong-message
/// MUTATION (C3), not merely a wrong render. IMAP's `messageId` is the
/// per-folder UID (`IMAPFetchMapping.messageIdString`), so `(accountId,
/// messageId)` alone is an ADDRESS, not an identity.
///
/// Two-sided on purpose: a resolver that always returned nil would satisfy the
/// never-open-the-wrong-row half while silently dropping the user's intention,
/// so the ordinary-result cases below assert a POSITIVE resolve.
@Suite("Remote search result resolve (folder-scoped, fail-closed)")
struct SearchRemoteResultResolveTests {

    private func resolve(
        _ db: DatabaseQueue, accountId: String, messageId: String, folderPath: String
    ) throws -> String? {
        try db.read { conn in
            try SearchView.resolveRemoteResultHeaderId(
                accountId: accountId, messageId: messageId, folderPath: folderPath, db: conn)
        }
    }

    /// (i) A same-UID row in a DIFFERENT folder is never resolved.
    @Test("A colliding UID in another folder is never opened for a result searched in INBOX")
    func collidingUidInAnotherFolderNeverResolves() throws {
        let db = try TestDatabase.make()
        try TestDatabase.insertAccount(db, id: "acc1", email: "user@example.com", provider: .imap)
        try TestDatabase.insertFolder(db, name: "INBOX", path: "INBOX", role: .inbox, accountId: "acc1")
        try TestDatabase.insertFolder(db, name: "Archive", path: "Archive", role: .archive, accountId: "acc1")
        // UID 5 exists ONLY in Archive. The remote search of INBOX returned UID 5
        // (a genuinely different message that INBOX has not synced yet).
        let archive = try TestDatabase.insertMessageHeader(
            db, messageId: "5", folderId: "acc1:Archive", accountId: "acc1", folderPath: "Archive")

        let resolved = try resolve(db, accountId: "acc1", messageId: "5", folderPath: "INBOX")

        #expect(resolved == nil, "identity cannot be established in INBOX → open nothing")
        #expect(resolved != archive.id, "the Archive row is a DIFFERENT message; opening it would mark it read")
    }

    /// (ii) The correct row in the expected folder still resolves — both ways.
    @Test("Same UID in two folders resolves each result to its OWN folder's header")
    func eachFolderResolvesToItsOwnHeader() throws {
        let db = try TestDatabase.make()
        try TestDatabase.insertAccount(db, id: "acc1", email: "user@example.com", provider: .imap)
        try TestDatabase.insertFolder(db, name: "INBOX", path: "INBOX", role: .inbox, accountId: "acc1")
        try TestDatabase.insertFolder(db, name: "Archive", path: "Archive", role: .archive, accountId: "acc1")
        let inbox = try TestDatabase.insertMessageHeader(
            db, messageId: "5", folderId: "acc1:INBOX", accountId: "acc1", folderPath: "INBOX")
        let archive = try TestDatabase.insertMessageHeader(
            db, messageId: "5", folderId: "acc1:Archive", accountId: "acc1", folderPath: "Archive")

        // v3's own composition — `MessageIdentity.headerId`, never a hand-built string.
        #expect(inbox.id == MessageIdentity.headerId(accountId: "acc1", folderPath: "INBOX", messageId: "5"))
        #expect(archive.id == MessageIdentity.headerId(accountId: "acc1", folderPath: "Archive", messageId: "5"))

        #expect(try resolve(db, accountId: "acc1", messageId: "5", folderPath: "INBOX") == inbox.id)
        #expect(try resolve(db, accountId: "acc1", messageId: "5", folderPath: "Archive") == archive.id)
    }

    /// (iii) Identity cannot be established → nil, never a looser global match.
    @Test("An unresolvable account never falls back to a global cross-account messageId match")
    func unknownAccountResolvesToNothing() throws {
        let db = try TestDatabase.make()
        try TestDatabase.insertAccount(db, id: "acc1", email: "user@example.com", provider: .imap)
        try TestDatabase.insertFolder(db, name: "INBOX", path: "INBOX", role: .inbox, accountId: "acc1")
        let other = try TestDatabase.insertMessageHeader(
            db, messageId: "5", folderId: "acc1:INBOX", accountId: "acc1", folderPath: "INBOX")

        // The result names an account this device no longer has a row for.
        let resolved = try resolve(db, accountId: "acc-removed", messageId: "5", folderPath: "INBOX")

        #expect(resolved == nil, "no account identity → no resolve; a global messageId match is another account's message")
        #expect(resolved != other.id)

        // …and an EMPTY account id is not a wildcard either.
        #expect(try resolve(db, accountId: "", messageId: "5", folderPath: "INBOX") == nil)
    }

    /// 🚨 AUDIT ROUND 1 / C-3 — the headline property, end to end.
    ///
    /// Two accounts hold the SAME email address on different servers (IMAP setup
    /// permits it; `Account.id` is the only key). Both have an INBOX, and UID 5 in
    /// each names a DIFFERENT message. A remote result found on account B must open
    /// B's message — never A's, whose row `Account.filter(emailAddress == …)
    /// .fetchOne` would have returned instead. Opening durably marks the row read
    /// (`markReadOnOpenIfNeeded`), so this is a wrong-message MUTATION, not a
    /// display glitch.
    @Test("A result from one of two accounts sharing an email address opens ITS OWN message")
    func sharedEmailAddressResolvesPerAccountNotPerAddress() throws {
        let db = try TestDatabase.make()
        try TestDatabase.insertAccount(db, id: "accA", email: "shared@example.com", provider: .imap)
        try TestDatabase.insertAccount(db, id: "accB", email: "shared@example.com", provider: .imap)
        try TestDatabase.insertFolder(db, name: "INBOX", path: "INBOX", role: .inbox, accountId: "accA")
        try TestDatabase.insertFolder(db, name: "INBOX", path: "INBOX", role: .inbox, accountId: "accB")
        let mineA = try TestDatabase.insertMessageHeader(
            db, messageId: "5", folderId: "accA:INBOX", accountId: "accA", folderPath: "INBOX")
        let mineB = try TestDatabase.insertMessageHeader(
            db, messageId: "5", folderId: "accB:INBOX", accountId: "accB", folderPath: "INBOX")

        // NON-VACUITY: both rows exist and the addresses really do collide, so a
        // correct resolve below is a discrimination, not an empty table.
        #expect(mineA.id != mineB.id)
        let sharing = try db.read { conn in
            try Account.filter(Column("emailAddress") == "shared@example.com").fetchCount(conn)
        }
        #expect(sharing == 2)

        #expect(try resolve(db, accountId: "accB", messageId: "5", folderPath: "INBOX") == mineB.id,
                """
                a result found on account B resolved into the OTHER account's message at the same \
                folder+UID. Opening it marks that message read — the wrong message, mutated.
                """)
        #expect(try resolve(db, accountId: "accA", messageId: "5", folderPath: "INBOX") == mineA.id,
                "and the mirror direction must hold too, or the resolver is merely biased the other way")
    }

    /// (ii) again, for the provider account-wide path — plus (i)'s cross-ACCOUNT face.
    @Test("Account-wide provider search (empty folderPath) still opens, and stays inside its own account")
    func accountWideSearchStillResolvesWithinItsAccount() throws {
        let db = try TestDatabase.make()
        try TestDatabase.insertAccount(db, id: "acc1", email: "one@example.com", provider: .gmail)
        try TestDatabase.insertAccount(db, id: "acc2", email: "two@example.com", provider: .gmail)
        try TestDatabase.insertFolder(db, name: "INBOX", path: "INBOX", role: .inbox, accountId: "acc1")
        try TestDatabase.insertFolder(db, name: "INBOX", path: "INBOX", role: .inbox, accountId: "acc2")
        // Gmail/Graph account-wide search passes folderPath "" — the local row
        // still lives in a real folder, so a folder constraint would break it.
        let mine = try TestDatabase.insertMessageHeader(
            db, messageId: "provider-id-1", folderId: "acc1:INBOX", accountId: "acc1", folderPath: "INBOX")
        let theirs = try TestDatabase.insertMessageHeader(
            db, messageId: "provider-id-1", folderId: "acc2:INBOX", accountId: "acc2", folderPath: "INBOX")

        let resolved = try resolve(db, accountId: "acc1", messageId: "provider-id-1", folderPath: "")

        #expect(resolved == mine.id, "an ordinary account-wide remote result MUST still open — never drop the tap")
        #expect(resolved != theirs.id, "the other account's row is a different message")
    }
}
