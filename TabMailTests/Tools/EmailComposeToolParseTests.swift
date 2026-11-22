/* This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at https://mozilla.org/MPL/2.0/. */

import Testing
import Foundation
@testable import TabMail

@Suite("EmailComposeTool.parseStringArray — extended")
struct EmailComposeToolParseTests {

    @Test("nil returns nil")
    func nilReturnsNil() {
        #expect(EmailComposeTool.parseStringArray(nil) == nil)
    }

    @Test("Array of strings returns array")
    func arrayOfStrings() {
        let value: JSONValue = .array([.string("a@b.com"), .string("c@d.com")])
        let result = EmailComposeTool.parseStringArray(value)
        #expect(result == ["a@b.com", "c@d.com"])
    }

    /// Re-scoped (issue 1015): this test was "Array of objects with 'email' key extracts
    /// emails" and expected `["x@y.com", "a@b.com"]`, which blessed dropping the name.
    @Test("Array of {name, email} objects keeps each address and its display name")
    func arrayOfEmailObjects() throws {
        let value: JSONValue = .array([
            .dictionary(["email": .string("x@y.com"), "name": .string("X Y")]),
            .dictionary(["email": .string("a@b.com")])
        ])
        let result = try #require(EmailComposeTool.parseStringArray(value))
        let entry = RecipientEntry(result)
        #expect(entry.leftovers.isEmpty)
        #expect(entry.addresses == ["x@y.com", "a@b.com"])
        #expect(entry.recipients.map(\.name) == ["X Y", nil])
        #expect(result.last == "a@b.com")
    }

    /// A blank name is no name, so the chip shows the address; a padded name is trimmed.
    @Test("A tool recipient's blank name gives no display name and a padded one is trimmed",
          arguments: [("   ", nil), (" Sam Lee ", "Sam Lee")] as [(String, String?)])
    func blankAndPaddedNames(_ name: String, _ expected: String?) throws {
        let value: JSONValue = .array([
            .dictionary(["name": .string(name), "email": .string("sam@example.com")]),
        ])
        let result = try #require(EmailComposeTool.parseStringArray(value))
        let field = ComposeDraftGuards.fieldState(RecipientEntry(result))
        #expect(field.tokens == ["sam@example.com"])
        #expect(field.rejected.isEmpty)
        #expect(field.displayNames["sam@example.com"] == expected)
    }

    /// Each name the model may send round-trips through the tool's mailbox text: the same
    /// name, exactly one recipient at the given address, nothing rejected or invented.
    @Test("A tool recipient's name round-trips, whatever characters it holds",
          arguments: [
              "Sam Lee",
              "Sam \"The Boss\" Lee",
              "Back\\slash Lee",
              "ceo@example.org",
              "Lee, Sam <other@example.org>",
          ])
    func nameRoundTrips(_ name: String) throws {
        let value: JSONValue = .array([
            .dictionary(["name": .string(name), "email": .string("sam@example.com")]),
        ])
        let result = try #require(EmailComposeTool.parseStringArray(value))
        let entry = RecipientEntry(result)
        #expect(entry.leftovers.isEmpty)
        #expect(entry.addresses == ["sam@example.com"])
        #expect(entry.recipients.map(\.name) == [name])
    }

    @Test("A tool recipient's display name reaches the compose draft card")
    func nameReachesDraftCard() throws {
        let value: JSONValue = .array([
            .dictionary(["name": .string("Lee, Sam"), "email": .string("sam@example.com")]),
            .dictionary(["name": .string(""), "email": .string("pat@example.com")]),
        ])
        let result = try #require(EmailComposeTool.parseStringArray(value))
        // ComposeView fills a prefilled field exactly this way (`prefillTo` -> fieldState).
        let field = ComposeDraftGuards.fieldState(RecipientEntry(result))
        #expect(field.tokens == ["sam@example.com", "pat@example.com"])
        #expect(field.rejected.isEmpty)
        #expect(field.displayNames == ["sam@example.com": "Lee, Sam"])
    }

    @Test("Single string returns array with one element")
    func singleString() {
        let result = EmailComposeTool.parseStringArray(.string("solo@test.com"))
        #expect(result == ["solo@test.com"])
    }

    @Test("Empty string returns nil")
    func emptyString() {
        let result = EmailComposeTool.parseStringArray(.string(""))
        #expect(result == nil)
    }

    @Test("Empty array returns nil")
    func emptyArray() {
        let result = EmailComposeTool.parseStringArray(.array([]))
        #expect(result == nil)
    }

    @Test("Mixed array: strings + objects extracts both")
    func mixedArray() {
        let value: JSONValue = .array([
            .string("plain@test.com"),
            .dictionary(["email": .string("dict@test.com")]),
            .int(42)  // should be skipped
        ])
        let result = EmailComposeTool.parseStringArray(value)
        #expect(result == ["plain@test.com", "dict@test.com"])
    }

    @Test("Object without 'email' key is skipped")
    func objectWithoutEmailKey() {
        let value: JSONValue = .array([
            .dictionary(["name": .string("No Email")]),
            .string("valid@test.com")
        ])
        let result = EmailComposeTool.parseStringArray(value)
        #expect(result == ["valid@test.com"])
    }

    @Test("Object with empty 'email' value is skipped")
    func objectWithEmptyEmail() {
        let value: JSONValue = .array([
            .dictionary(["email": .string("")]),
            .dictionary(["email": .string("valid@test.com")])
        ])
        let result = EmailComposeTool.parseStringArray(value)
        #expect(result == ["valid@test.com"])
    }

    @Test("Non-array/non-string JSONValue returns nil")
    func intReturnsNil() {
        #expect(EmailComposeTool.parseStringArray(.int(42)) == nil)
    }

    @Test("Bool JSONValue returns nil")
    func boolReturnsNil() {
        #expect(EmailComposeTool.parseStringArray(.bool(true)) == nil)
    }

    @Test("Double JSONValue returns nil")
    func doubleReturnsNil() {
        #expect(EmailComposeTool.parseStringArray(.double(3.14)) == nil)
    }

    @Test("Dictionary JSONValue returns nil")
    func dictReturnsNil() {
        #expect(EmailComposeTool.parseStringArray(.dictionary(["key": .string("val")])) == nil)
    }

    @Test("Array of all non-extractable items returns nil")
    func allNonExtractable() {
        let value: JSONValue = .array([.int(1), .bool(false), .double(2.0)])
        let result = EmailComposeTool.parseStringArray(value)
        #expect(result == nil)
    }
}
