/* This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at https://mozilla.org/MPL/2.0/. */

import Testing
import Foundation
@testable import TabMail

/// Tests for nested-attachment classification: attachments inside a `message/rfc822`
/// part should be marked `parentEmlSection != nil` so the UI shows them inside the
/// `.eml` preview instead of at the top level, and so Forward carry-over doesn't
/// duplicate them.
///
/// All sections used here are synthetic / arbitrary.
@Suite("IMAPFetchMapping.parentEmlSection — nested attachment classification")
struct IMAPProviderNestedAttachmentTests {

    // MARK: - Classification helper

    @Test("Top-level part (no rfc822 around it) returns nil")
    func topLevelNoRfc822() {
        let result = IMAPFetchMapping.parentEmlSection(for: [2], rfc822Sections: [])
        #expect(result == nil)
    }

    @Test("Top-level part with rfc822 siblings returns nil")
    func topLevelSiblingRfc822() {
        // Parts at sections 1 (text), 2 (rfc822), 3 (top-level pdf)
        let result = IMAPFetchMapping.parentEmlSection(for: [3], rfc822Sections: [[2]])
        #expect(result == nil)
    }

    @Test("Part nested inside single rfc822 returns that rfc822 section")
    func nestedInsideRfc822() {
        // rfc822 at 2, PDF inside at 2.2
        let result = IMAPFetchMapping.parentEmlSection(for: [2, 2], rfc822Sections: [[2]])
        #expect(result == "2")
    }

    @Test("Deeply nested part returns the nearest enclosing rfc822")
    func deeplyNestedReturnsNearest() {
        // rfc822 at 2, then another rfc822 at 2.3 (email forwarded inside a forward)
        // PDF at 2.3.2 should return "2.3" (nearest), not "2"
        let result = IMAPFetchMapping.parentEmlSection(
            for: [2, 3, 2],
            rfc822Sections: [[2], [2, 3]]
        )
        #expect(result == "2.3")
    }

    @Test("Component prefix match — [1,2] is NOT prefix of [1,20]")
    func componentwisePrefix() {
        // If we did string-prefix matching on "1", then "1.20" would match.
        // Component matching: [1] is a prefix of [1, 20] → IS nested. Good.
        let result1 = IMAPFetchMapping.parentEmlSection(for: [1, 20], rfc822Sections: [[1]])
        #expect(result1 == "1")
        // But [1, 2] is NOT a prefix of [1, 20] — different component 2 vs 20.
        let result2 = IMAPFetchMapping.parentEmlSection(for: [1, 20], rfc822Sections: [[1, 2]])
        #expect(result2 == nil)
    }

    @Test("Equal-length components are not considered nested")
    func equalLengthNotNested() {
        // A part AT section 2 (the rfc822 itself) is not "nested inside" itself.
        let result = IMAPFetchMapping.parentEmlSection(for: [2], rfc822Sections: [[2]])
        #expect(result == nil)
    }

    @Test("Multi-digit section components are preserved in dot-joined output")
    func multiDigitSections() {
        let result = IMAPFetchMapping.parentEmlSection(
            for: [1, 10, 3],
            rfc822Sections: [[1, 10]]
        )
        #expect(result == "1.10")
    }

    @Test("Multiple rfc822s at different levels — longest prefix wins")
    func longestPrefixWins() {
        // Three rfc822s at [2], [2,3], [2,3,5]
        // Part at 2.3.5.1 should return "2.3.5"
        let result = IMAPFetchMapping.parentEmlSection(
            for: [2, 3, 5, 1],
            rfc822Sections: [[2], [2, 3], [2, 3, 5]]
        )
        #expect(result == "2.3.5")
    }

    // MARK: - AttachmentInfo Codable backwards compatibility

    @Test("AttachmentInfo decodes old JSON (no parentEmlSection field)")
    func decodesLegacyJSON() throws {
        // Old records in GRDB predate parentEmlSection; adding a required field
        // would break decode. It MUST be optional and default to nil.
        let legacyJSON = """
        {
            "filename": "doc.pdf",
            "contentType": "application/pdf",
            "section": "2",
            "size": 102400,
            "encoding": "base64"
        }
        """
        let data = legacyJSON.data(using: .utf8)!
        let att = try JSONDecoder().decode(AttachmentInfo.self, from: data)
        #expect(att.filename == "doc.pdf")
        #expect(att.parentEmlSection == nil)
    }

    @Test("AttachmentInfo round-trips parentEmlSection")
    func roundTripsNestedField() throws {
        let original = AttachmentInfo(
            filename: "x.pdf",
            contentType: "application/pdf",
            section: "2.2",
            size: 100,
            encoding: "base64",
            parentEmlSection: "2"
        )
        let data = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(AttachmentInfo.self, from: data)
        #expect(decoded.parentEmlSection == "2")
        #expect(decoded.section == "2.2")
    }

    @Test("AttachmentInfo default init leaves parentEmlSection nil")
    func defaultInitNil() {
        let a = AttachmentInfo(
            filename: "a.txt",
            contentType: "text/plain",
            section: "1",
            size: 1,
            encoding: nil
        )
        #expect(a.parentEmlSection == nil)
    }
}
