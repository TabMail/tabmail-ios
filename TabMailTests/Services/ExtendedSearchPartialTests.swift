/* This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at https://mozilla.org/MPL/2.0/. */

import NIOIMAPCore
import Testing
@testable import SwiftMail
@testable import TabMail

/// A PARTIAL answer pages the matches; without ALL it never lists them all, so
/// it is refused as a set (#755), whatever its COUNT says.
@Suite("ExtendedSearchResult PARTIAL without ALL")
struct ExtendedSearchPartialTests {
    static func page(_ uids: [Int]) -> ExtendedSearchResult<SwiftMail.UID>.PartialResult {
        ExtendedSearchResult<SwiftMail.UID>.PartialResult(
            range: .first(NIOIMAPCore.MessageIdentifierRange(NIOIMAPCore.SequenceNumber(1)...NIOIMAPCore.SequenceNumber(100))), results: MessageIdentifierSet<SwiftMail.UID>(uids.map { SwiftMail.UID(UInt32($0)) }))
    }

    @Test("A PARTIAL answer without ALL is refused, including COUNT 0 with a nonempty page")
    func partialWithoutAllIsRefused() {
        for result in [
            ExtendedSearchResult<SwiftMail.UID>(partial: Self.page([1, 2])),
            ExtendedSearchResult<SwiftMail.UID>(count: 0, partial: Self.page([1, 2])),
            ExtendedSearchResult<SwiftMail.UID>(partial: Self.page([])),
        ] {
            #expect(throws: ExtendedSearchUnlisted.self) { try result.listed(within: .anyUID) }
        }
    }

    @Test("Control: a complete answer (ALL, or COUNT 0 alone) is read as listed")
    func completeAnswerIsListed() throws {
        let all = ExtendedSearchResult<SwiftMail.UID>(count: 2, all: MessageIdentifierSet<SwiftMail.UID>([SwiftMail.UID(1), SwiftMail.UID(2)]))
        #expect(try all.listed(within: .anyUID).toArray() == [SwiftMail.UID(1), SwiftMail.UID(2)])
        #expect(try ExtendedSearchResult<SwiftMail.UID>(count: 0).listed(within: .anyUID).isEmpty)
    }
}
