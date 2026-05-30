/* This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at https://mozilla.org/MPL/2.0/. */

import Testing
import SwiftMail
@testable import TabMail

@Suite("ExtendedSearchResult.asSet")
struct ExtendedSearchResultAsSetTests {

    @Test("Returns .all when ESEARCH populates it")
    func returnsAllWhenPresent() {
        let uids = MessageIdentifierSet<UID>([UID(10), UID(20), UID(30)])
        let result = ExtendedSearchResult<UID>(all: uids)
        #expect(result.asSet.toArray() == [UID(10), UID(20), UID(30)])
    }

    @Test("Falls back to .ordered when .all is nil")
    func fallsBackToOrdered() {
        let ordered: [UID] = [UID(5), UID(7), UID(9)]
        let result = ExtendedSearchResult<UID>(ordered: ordered)
        #expect(result.asSet.toArray() == [UID(5), UID(7), UID(9)])
    }

    @Test("Returns empty set when both .all and .ordered are nil")
    func emptyWhenBothNil() {
        let result = ExtendedSearchResult<UID>()
        #expect(result.asSet.isEmpty)
    }

    @Test("Prefers .all over .ordered when both populated")
    func prefersAllOverOrdered() {
        let allSet = MessageIdentifierSet<UID>([UID(1), UID(2)])
        let orderedDifferent: [UID] = [UID(99)]
        let result = ExtendedSearchResult<UID>(all: allSet, ordered: orderedDifferent)
        #expect(result.asSet.toArray() == [UID(1), UID(2)])
    }
}
