/* This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at https://mozilla.org/MPL/2.0/. */

import Testing
import Foundation
@testable import TabMail

@Suite("ActionTag Extended")
struct ActionTagExtendedTests {

    @Test("Reply sort order is lowest (highest priority)")
    func replySortOrderLowest() {
        #expect(ActionTag.reply.sortOrder < ActionTag.none.sortOrder)
        #expect(ActionTag.reply.sortOrder < ActionTag.archive.sortOrder)
        #expect(ActionTag.reply.sortOrder < ActionTag.delete.sortOrder)
    }

    @Test("Sort order: reply < none < archive < delete")
    func sortOrderRelative() {
        #expect(ActionTag.reply.sortOrder < ActionTag.none.sortOrder)
        #expect(ActionTag.none.sortOrder < ActionTag.archive.sortOrder)
        #expect(ActionTag.archive.sortOrder < ActionTag.delete.sortOrder)
    }

    @Test("All tags have display names")
    func allTagsHaveDisplayNames() {
        for tag in ActionTag.allCases {
            #expect(!tag.displayName.isEmpty)
        }
    }

    @Test("Non-none tags have single-character letters")
    func nonNoneTagsHaveLetters() {
        for tag in ActionTag.allCases where tag != .none {
            #expect(tag.letter?.count == 1)
        }
    }

    @Test("None tag has nil letter")
    func noneTagNilLetter() {
        #expect(ActionTag.none.letter == nil)
    }

    @Test("imapKeyword has tm_ prefix")
    func imapKeywordPrefix() {
        for tag in ActionTag.allCases {
            #expect(tag.imapKeyword.hasPrefix("tm_"))
        }
    }

    @Test("fromIMAPKeyword round-trips all tags")
    func fromIMAPKeywordRoundTrips() {
        for tag in ActionTag.allCases {
            let keyword = tag.imapKeyword
            let recovered = ActionTag.fromIMAPKeyword(keyword)
            #expect(recovered == tag)
        }
    }

    @Test("fromIMAPKeyword returns nil for unknown keyword")
    func fromIMAPKeywordUnknown() {
        #expect(ActionTag.fromIMAPKeyword("tm_unknown") == nil)
        #expect(ActionTag.fromIMAPKeyword("not_a_keyword") == nil)
        #expect(ActionTag.fromIMAPKeyword("") == nil)
    }

    @Test("allCases contains exactly 4 cases")
    func allCasesCount() {
        #expect(ActionTag.allCases.count == 4)
    }

    @Test("Codable strips tm_ prefix on encode")
    func codableEncoding() throws {
        let data = try JSONEncoder().encode(ActionTag.archive)
        let str = String(data: data, encoding: .utf8)!
        #expect(!str.contains("tm_"))
    }

    @Test("Codable with tm_ prefix on decode")
    func codableDecodeWithPrefix() throws {
        let json = "\"tm_archive\""
        let tag = try JSONDecoder().decode(ActionTag.self, from: json.data(using: .utf8)!)
        #expect(tag == .archive)
    }

    @Test("Codable without prefix also decodes")
    func codableDecodeWithoutPrefix() throws {
        let json = "\"archive\""
        let tag = try JSONDecoder().decode(ActionTag.self, from: json.data(using: .utf8)!)
        #expect(tag == .archive)
    }
}
