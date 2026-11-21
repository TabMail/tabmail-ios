/* This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at https://mozilla.org/MPL/2.0/. */

import GRDB
@testable import TabMail

/// Fixtures that seed a folder's listing counters. A whole-record save never
/// writes them (`Folder.listingCounterColumns`), so a fixture that needs them
/// stored writes them through their one writer after the record.
extension Folder {
    func writeFixtureListingCounters(_ db: Database) throws {
        try SyncEngine.writeListingCounters(
            ListingCounters(messageCount: totalCount, uidNext: lastKnownUidNext, highestModSeq: lastKnownHighestModSeq),
            folderId: id, db: db)
    }

    func insertWithListingCounters(_ db: Database) throws {
        try insert(db)
        try writeFixtureListingCounters(db)
    }

    func updateWithListingCounters(_ db: Database) throws {
        try update(db)
        try writeFixtureListingCounters(db)
    }
}
