/* This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at https://mozilla.org/MPL/2.0/. */

import Testing
import Foundation
import GRDB
@testable import TabMail

/// Fix B — IMAP CONDSTORE (RFC 7162) flag-aware delta sync. Guards the MODSEQ change
/// decision and the v65 `Folder.lastKnownHighestModSeq` cursor.
@Suite("IMAP CONDSTORE delta (Fix B)")
struct SyncModSeqTests {

    @Test("MODSEQ change signal fires ONLY when both present and differ")
    func modSeqChangeDetection() {
        // Non-CONDSTORE server (nil HIGHESTMODSEQ) → no signal; caller falls back to the
        // uidNext+count comparison, so non-CONDSTORE servers behave exactly as today.
        #expect(SyncEngine.modSeqIndicatesChange(server: nil, cached: 100) == false)
        // First observation (nil cursor) → no signal; the cursor is recorded for next time.
        #expect(SyncEngine.modSeqIndicatesChange(server: 100, cached: nil) == false)
        #expect(SyncEngine.modSeqIndicatesChange(server: nil, cached: nil) == false)
        // Stable epoch, unchanged → no signal (this is what lets a quiet folder be skipped).
        #expect(SyncEngine.modSeqIndicatesChange(server: 100, cached: 100) == false)
        // A \Seen/flag change bumped HIGHESTMODSEQ while uidNext+count stayed put → signal.
        // This is exactly the case delta MISSED before Fix B (the latent "read-on-another-
        // client doesn't propagate on IMAP" bug).
        #expect(SyncEngine.modSeqIndicatesChange(server: 101, cached: 100) == true)
    }

    @Test("Folder.lastKnownHighestModSeq round-trips through the v65 migration")
    func folderModSeqRoundTrips() throws {
        let db = try TestDatabase.make()
        try TestDatabase.insertAccount(db, id: "acc1", email: "u@ex.com")

        var folder = Folder(name: "INBOX", path: "INBOX", role: .inbox, accountId: "acc1")
        folder.lastKnownHighestModSeq = 4242
        try db.write { try folder.insert($0) }

        let read = try db.read { try Folder.fetchOne($0, key: "acc1:INBOX") }
        #expect(read?.lastKnownHighestModSeq == 4242)

        // Default is nil (non-CONDSTORE / not yet observed) — the fallback path.
        #expect(Folder(name: "X", path: "X", role: .inbox, accountId: "acc1").lastKnownHighestModSeq == nil)
    }
}
