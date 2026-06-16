/* This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at https://mozilla.org/MPL/2.0/. */

import Testing
import Foundation
@testable import TabMail

/// Locks `SearchResult`'s identity contract (the Bug-1 fix).
///
/// The id MUST be a stable, content-derived `accountEmail + folderPath +
/// messageId` — never a fresh `UUID()` (which churned across the per-keystroke
/// array rebuilds and made SwiftUI paint the wrong subject) and never bare
/// `messageId` (IMAP's per-folder UID repeats across folders, so a search-all
/// over several folders of one account would mint DUPLICATE identities → wrong
/// subject again).
@Suite("SearchResult identity (folder-aware, stable)")
struct SearchResultIdentityTests {

    private func make(account: String, folder: String, msg: String) -> SearchResult {
        SearchResult(
            source: .remote, accountEmail: account, messageId: msg, folderPath: folder,
            subject: "subject for \(folder)/\(msg)", from: "From", fromAddress: "from@example.com",
            date: Date(), snippet: "", isRead: false, isFlagged: false, headerId: nil
        )
    }

    @Test("Same (account, folder, messageId) → identical, stable id")
    func sameMessageSameId() {
        let a = make(account: "a@example.com", folder: "INBOX", msg: "5")
        let b = make(account: "a@example.com", folder: "INBOX", msg: "5")
        #expect(a.id == b.id, "the same message must keep one identity across array rebuilds")
    }

    @Test("Same account + same UID, DIFFERENT folder → different id (IMAP cross-folder collision)")
    func crossFolderUidDoesNotCollide() {
        let inbox = make(account: "a@example.com", folder: "INBOX", msg: "5")
        let archive = make(account: "a@example.com", folder: "Archive", msg: "5")
        #expect(inbox.id != archive.id, "per-folder UIDs collide on messageId alone — folder must disambiguate")
    }

    @Test("Different account, same folder+messageId → different id")
    func differentAccountDifferentId() {
        let a = make(account: "a@example.com", folder: "INBOX", msg: "5")
        let b = make(account: "b@example.com", folder: "INBOX", msg: "5")
        #expect(a.id != b.id)
    }

    @Test("Different messageId in the same folder → different id")
    func differentMessageDifferentId() {
        let a = make(account: "a@example.com", folder: "INBOX", msg: "5")
        let b = make(account: "a@example.com", folder: "INBOX", msg: "6")
        #expect(a.id != b.id)
    }

    @Test("id is not a UUID — equal-content results in a ForEach must share identity")
    func idIsContentDerivedNotRandom() {
        // Two SearchResult VALUES with identical content (as a re-sort/rebuild
        // produces) must resolve to the SAME ForEach identity. A UUID()-based id
        // would make these two distinct → the row-recycling subject bug.
        let ids = Set((0..<3).map { _ in make(account: "a@example.com", folder: "INBOX", msg: "5").id })
        #expect(ids.count == 1, "content-equal results must collapse to one identity, not three")
    }
}
