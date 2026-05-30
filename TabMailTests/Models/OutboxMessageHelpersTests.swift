/* This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at https://mozilla.org/MPL/2.0/. */

import Testing
import Foundation
@testable import TabMail

@Suite("encodeStringArray / decodeStringArray")
struct OutboxMessageHelpersTests {

    @Test("encodeStringArray encodes empty array to []")
    func encodesEmptyArray() {
        let result = encodeStringArray([])
        #expect(result == "[]")
    }

    @Test("encodeStringArray encodes single element")
    func encodesSingleElement() {
        let result = encodeStringArray(["alice@example.com"])
        let decoded = decodeStringArray(result)
        #expect(decoded == ["alice@example.com"])
    }

    @Test("encodeStringArray encodes multiple elements")
    func encodesMultipleElements() {
        let input = ["a@b.com", "c@d.com", "e@f.com"]
        let result = encodeStringArray(input)
        let decoded = decodeStringArray(result)
        #expect(decoded == input)
    }

    @Test("decodeStringArray decodes valid JSON array")
    func decodesValidJSON() {
        let result = decodeStringArray("[\"hello\",\"world\"]")
        #expect(result == ["hello", "world"])
    }

    @Test("decodeStringArray returns empty for empty JSON array")
    func decodesEmptyJSONArray() {
        let result = decodeStringArray("[]")
        #expect(result.isEmpty)
    }

    @Test("decodeStringArray returns empty for invalid JSON")
    func decodesInvalidJSON() {
        let result = decodeStringArray("not json at all")
        #expect(result.isEmpty)
    }

    @Test("decodeStringArray returns empty for empty string")
    func decodesEmptyString() {
        let result = decodeStringArray("")
        #expect(result.isEmpty)
    }

    @Test("Roundtrip preserves special characters")
    func roundtripSpecialCharacters() {
        let input = ["user+tag@example.com", "\"Doe, John\" <j@x.com>", "café@example.com"]
        let encoded = encodeStringArray(input)
        let decoded = decodeStringArray(encoded)
        #expect(decoded == input)
    }

    @Test("Roundtrip preserves unicode")
    func roundtripUnicode() {
        let input = ["日本語@example.com", "emoji😀@test.com"]
        let encoded = encodeStringArray(input)
        let decoded = decodeStringArray(encoded)
        #expect(decoded == input)
    }

    @Test("Roundtrip preserves strings with quotes")
    func roundtripQuotes() {
        let input = ["he said \"hello\"", "it's fine"]
        let encoded = encodeStringArray(input)
        let decoded = decodeStringArray(encoded)
        #expect(decoded == input)
    }

    @Test("encodeStringArray produces valid JSON")
    func producesValidJSON() {
        let result = encodeStringArray(["a", "b"])
        // Should be parseable as JSON
        let data = result.data(using: .utf8)!
        let parsed = try? JSONSerialization.jsonObject(with: data) as? [String]
        #expect(parsed == ["a", "b"])
    }

    @Test("decodeStringArray handles JSON with whitespace")
    func decodesJSONWithWhitespace() {
        let result = decodeStringArray("[ \"a\" , \"b\" ]")
        #expect(result == ["a", "b"])
    }

    @Test("Roundtrip preserves empty strings in array")
    func roundtripEmptyStrings() {
        let input = ["", "nonempty", ""]
        let encoded = encodeStringArray(input)
        let decoded = decodeStringArray(encoded)
        #expect(decoded == input)
    }

    @Test("Roundtrip preserves large array")
    func roundtripLargeArray() {
        let input = (0..<100).map { "user\($0)@example.com" }
        let encoded = encodeStringArray(input)
        let decoded = decodeStringArray(encoded)
        #expect(decoded == input)
    }
}
