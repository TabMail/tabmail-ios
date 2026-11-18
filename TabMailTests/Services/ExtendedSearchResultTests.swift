/* This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at https://mozilla.org/MPL/2.0/. */

import Testing
import SwiftMail
@testable import TabMail

@Suite("ExtendedSearchResult.listed(within:)")
struct ExtendedSearchResultAsSetTests {
    /// A whole-mailbox SEARCH whose selection reported no UIDNEXT: every valid UID.
    static let everyUID = MessageIdentifierSet<UID>.selectionScope(uidNext: UID(0))

    @Test("Returns .all when ESEARCH populates it")
    func returnsAllWhenPresent() throws {
        let uids = MessageIdentifierSet<UID>([UID(10), UID(20), UID(30)])
        let result = ExtendedSearchResult<UID>(all: uids)
        #expect(try result.listed(within: Self.everyUID).toArray() == [UID(10), UID(20), UID(30)])
    }

    @Test("Falls back to .ordered when .all is nil")
    func fallsBackToOrdered() throws {
        let ordered: [UID] = [UID(5), UID(7), UID(9)]
        let result = ExtendedSearchResult<UID>(ordered: ordered)
        #expect(try result.listed(within: Self.everyUID).toArray() == [UID(5), UID(7), UID(9)])
    }

    @Test("An answer with no match lists the empty set")
    func emptyWhenBothNil() throws {
        let result = ExtendedSearchResult<UID>()
        #expect(try result.listed(within: Self.everyUID).isEmpty)
    }

    @Test("Prefers .all over .ordered when both populated")
    func prefersAllOverOrdered() throws {
        let allSet = MessageIdentifierSet<UID>([UID(1), UID(2)])
        let orderedDifferent: [UID] = [UID(99)]
        let result = ExtendedSearchResult<UID>(all: allSet, ordered: orderedDifferent)
        #expect(try result.listed(within: Self.everyUID).toArray() == [UID(1), UID(2)])
    }

    @Test("An answer that reports matches without listing them is refused, never read as a set",
          arguments: [
              ExtendedSearchResult<UID>(count: 3),
              ExtendedSearchResult<UID>(min: UID(4)),
              ExtendedSearchResult<UID>(max: UID(9)),
              ExtendedSearchResult<UID>(count: 2, min: UID(4), max: UID(9)),
          ])
    func unlistedAnswerIsRefused(_ result: ExtendedSearchResult<UID>) {
        #expect(throws: ExtendedSearchUnlisted.self) { try result.listed(within: Self.everyUID) }
    }

    @Test("An answer to a restricted SEARCH that names an identifier outside the request is refused, never trimmed to the request; one inside it is read as listed")
    func answerOutsideTheRequestIsRefused() throws {
        var requested = MessageIdentifierSet<UID>()
        requested.insert(range: 10...20)
        requested.insert(UID(30))
        let outside = ExtendedSearchResult<UID>(all: MessageIdentifierSet<UID>([UID(500)]))
        #expect(throws: ExtendedSearchUnlisted.self) { try outside.listed(within: requested) }
        let straddling = ExtendedSearchResult<UID>(all: MessageIdentifierSet<UID>([UID(20), UID(21)]))
        #expect(throws: ExtendedSearchUnlisted.self) { try straddling.listed(within: requested) }
        let inside = ExtendedSearchResult<UID>(all: MessageIdentifierSet<UID>([UID(12), UID(30)]))
        #expect(try inside.listed(within: requested).toArray() == [UID(12), UID(30)])
        let empty = ExtendedSearchResult<UID>(all: MessageIdentifierSet<UID>())
        #expect(try empty.listed(within: requested).isEmpty)
    }

    @Test("An ALL list that contradicts the same answer's COUNT, MIN or MAX is refused",
          arguments: [
              ExtendedSearchResult<UID>(count: 3, all: MessageIdentifierSet<UID>([UID(4), UID(9)])),
              ExtendedSearchResult<UID>(min: UID(2), all: MessageIdentifierSet<UID>([UID(4), UID(9)])),
              ExtendedSearchResult<UID>(max: UID(12), all: MessageIdentifierSet<UID>([UID(4), UID(9)])),
          ])
    func contradictoryAllIsRefused(_ result: ExtendedSearchResult<UID>) {
        #expect(throws: ExtendedSearchUnlisted.self) { try result.listed(within: Self.everyUID) }
    }

    @Test("An ALL list that agrees with its COUNT, MIN and MAX is read as listed")
    func agreeingAllIsListed() throws {
        let result = ExtendedSearchResult<UID>(count: 2, min: UID(4), max: UID(9),
                                               all: MessageIdentifierSet<UID>([UID(4), UID(9)]))
        #expect(try result.listed(within: Self.everyUID).toArray() == [UID(4), UID(9)])
    }

    @Test("COUNT 0 with no ALL lists the empty set")
    func countZeroIsEmpty() throws {
        #expect(try ExtendedSearchResult<UID>(count: 0).listed(within: Self.everyUID).isEmpty)
    }
}

/// The fake server's UID SEARCH replies follow RFC 3501 and RFC 4731, so a
/// test of a no-match answer exercises the form a real server sends.
@Suite("FakeIMAPServer UID SEARCH reply forms")
struct FakeUIDSearchReplyFormTests {
    static let esearchRequest = "UID SEARCH RETURN (COUNT MIN MAX ALL) UID 1:*"

    @Test("Plain SEARCH: a no-match reply is a bare * SEARCH; a match lists the UIDs")
    func plainForms() {
        #expect(FakeIMAPServer.uidSearchReply(tag: "A1", uids: [], esearch: false, request: "UID SEARCH ALL")
                == "* SEARCH\r\nA1 OK UID SEARCH completed\r\n")
        #expect(FakeIMAPServer.uidSearchReply(tag: "A1", uids: ["4", "9"], esearch: false, request: "UID SEARCH ALL")
                == "* SEARCH 4 9\r\nA1 OK UID SEARCH completed\r\n")
    }

    @Test("ESEARCH: a no-match reply carries COUNT 0 and no ALL, MIN or MAX; a match carries all four")
    func esearchForms() {
        #expect(FakeIMAPServer.uidSearchReply(tag: "A1", uids: [], esearch: true, request: Self.esearchRequest)
                == "* ESEARCH (TAG \"A1\") UID COUNT 0\r\nA1 OK UID SEARCH completed\r\n")
        #expect(FakeIMAPServer.uidSearchReply(tag: "A1", uids: ["9", "4"], esearch: true, request: Self.esearchRequest)
                == "* ESEARCH (TAG \"A1\") UID MIN 4 MAX 9 ALL 4,9 COUNT 2\r\nA1 OK UID SEARCH completed\r\n")
    }
}

extension ExtendedSearchResultAsSetTests {
    @Test("The selection scope: UIDs below UIDNEXT, none for an empty mailbox (UIDNEXT 1), every valid UID when none was reported; an answer above UIDNEXT is refused")
    func selectionScope() throws {
        let scope = MessageIdentifierSet<UID>.selectionScope(uidNext: UID(11))
        #expect(scope.contains(UID(1)) && scope.contains(UID(10)) && !scope.contains(UID(11)))
        #expect(MessageIdentifierSet<UID>.selectionScope(uidNext: UID(1)).isEmpty)
        #expect(MessageIdentifierSet<UID>.selectionScope(uidNext: UID(0)).contains(UID(UInt32.max)))
        var above = MessageIdentifierSet<UID>()
        above.insert(UID(12))
        #expect(throws: ExtendedSearchUnlisted.self) { try ExtendedSearchResult<UID>(all: above).listed(within: scope) }
    }
}
