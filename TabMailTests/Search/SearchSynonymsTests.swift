/* This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at https://mozilla.org/MPL/2.0/. */

import Testing
import Foundation
@testable import TabMail

@Suite("SearchSynonyms")
struct SearchSynonymsTests {

    @Test("expand returns OR group for known synonym")
    func expandKnown() {
        let result = SearchSynonyms.expand("meeting")
        #expect(result.contains("("))
        #expect(result.contains(" OR "))
        #expect(result.contains("meeting"))
    }

    @Test("expand returns original word for unknown word")
    func expandUnknown() {
        let result = SearchSynonyms.expand("xyzzyplugh")
        #expect(result == "xyzzyplugh")
    }

    @Test("expand is case-insensitive")
    func expandCaseInsensitive() {
        let lower = SearchSynonyms.expand("meeting")
        let upper = SearchSynonyms.expand("MEETING")
        // Both should expand (lookup is lowercased)
        #expect(lower.contains("OR"))
        #expect(upper.contains("OR"))
    }

    @Test("wouldExpand returns true for synonyms")
    func wouldExpandTrue() {
        #expect(SearchSynonyms.wouldExpand("meeting") == true)
        #expect(SearchSynonyms.wouldExpand("urgent") == true)
        #expect(SearchSynonyms.wouldExpand("invoice") == true)
    }

    @Test("wouldExpand returns false for unknown words")
    func wouldExpandFalse() {
        #expect(SearchSynonyms.wouldExpand("xyzzyplugh") == false)
    }

    @Test("wouldExpand returns false for single-member groups")
    func wouldExpandSingleMember() {
        // "tomorrow" has no synonyms (group of 1)
        #expect(SearchSynonyms.wouldExpand("tomorrow") == false)
    }

    @Test("Synonym map is populated")
    func mapPopulated() {
        #expect(!SearchSynonyms.map.isEmpty)
        #expect(SearchSynonyms.map["meeting"] != nil)
        #expect(SearchSynonyms.map["meeting"]!.count > 1)
    }

    @Test("All group members have their own entry in the map")
    func allMembersHaveEntries() {
        for (_, group) in SearchSynonyms.map {
            for member in group {
                #expect(SearchSynonyms.map[member] != nil, "\(member) should have a synonym group")
            }
        }
    }
}
