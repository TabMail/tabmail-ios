/* This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at https://mozilla.org/MPL/2.0/. */

import Testing
import Foundation
@testable import TabMail

@Suite("EmailComposeTool.parseStringArray")
struct EmailComposeParseStringArrayTests {

    @Test("nil returns nil")
    func nilReturnsNil() {
        #expect(EmailComposeTool.parseStringArray(nil) == nil)
    }

    @Test("Array of strings")
    func arrayOfStrings() {
        let value: JSONValue = .array([.string("a@b.com"), .string("c@d.com")])
        let result = EmailComposeTool.parseStringArray(value)
        #expect(result == ["a@b.com", "c@d.com"])
    }

    @Test("Array of email dicts")
    func arrayOfEmailDicts() {
        let value: JSONValue = .array([
            .dictionary(["email": .string("a@b.com")]),
            .dictionary(["email": .string("c@d.com")])
        ])
        let result = EmailComposeTool.parseStringArray(value)
        #expect(result == ["a@b.com", "c@d.com"])
    }

    @Test("Single string")
    func singleString() {
        let value: JSONValue = .string("a@b.com")
        let result = EmailComposeTool.parseStringArray(value)
        #expect(result == ["a@b.com"])
    }

    @Test("Empty string returns nil")
    func emptyStringReturnsNil() {
        let result = EmailComposeTool.parseStringArray(.string(""))
        #expect(result == nil)
    }

    @Test("Empty array returns nil")
    func emptyArrayReturnsNil() {
        let result = EmailComposeTool.parseStringArray(.array([]))
        #expect(result == nil)
    }

    @Test("Non-string/array returns nil")
    func nonStringReturnsNil() {
        let result = EmailComposeTool.parseStringArray(.int(42))
        #expect(result == nil)
    }

    @Test("Mixed array extracts strings and emails")
    func mixedArray() {
        let value: JSONValue = .array([
            .string("plain@test.com"),
            .dictionary(["email": .string("dict@test.com")]),
            .int(42)  // ignored
        ])
        let result = EmailComposeTool.parseStringArray(value)
        #expect(result == ["plain@test.com", "dict@test.com"])
    }

    @Test("Dict with empty email filtered out")
    func emptyEmailDict() {
        let value: JSONValue = .array([
            .dictionary(["email": .string("")]),
            .dictionary(["email": .string("valid@test.com")])
        ])
        let result = EmailComposeTool.parseStringArray(value)
        #expect(result == ["valid@test.com"])
    }
}

@Suite("EmailDeleteTool.parseUniqueIds")
struct EmailDeleteParseUniqueIdsTests {

    @Test("Array of ints")
    func arrayOfInts() {
        let args: [String: JSONValue] = ["unique_ids": .array([.int(1), .int(2), .int(3)])]
        let ids = EmailDeleteTool.parseUniqueIds(args)
        #expect(ids == [1, 2, 3])
    }

    @Test("Array of strings")
    func arrayOfStrings() {
        let args: [String: JSONValue] = ["unique_ids": .array([.string("10"), .string("20")])]
        let ids = EmailDeleteTool.parseUniqueIds(args)
        #expect(ids == [10, 20])
    }

    @Test("Array of doubles")
    func arrayOfDoubles() {
        let args: [String: JSONValue] = ["unique_ids": .array([.double(5.0), .double(10.0)])]
        let ids = EmailDeleteTool.parseUniqueIds(args)
        #expect(ids == [5, 10])
    }

    @Test("Single unique_id int fallback")
    func singleIntFallback() {
        let args: [String: JSONValue] = ["unique_id": .int(42)]
        let ids = EmailDeleteTool.parseUniqueIds(args)
        #expect(ids == [42])
    }

    @Test("Single unique_id string fallback")
    func singleStringFallback() {
        let args: [String: JSONValue] = ["unique_id": .string("99")]
        let ids = EmailDeleteTool.parseUniqueIds(args)
        #expect(ids == [99])
    }

    @Test("Empty arguments returns empty")
    func emptyArgs() {
        let args: [String: JSONValue] = [:]
        let ids = EmailDeleteTool.parseUniqueIds(args)
        #expect(ids.isEmpty)
    }

    @Test("Non-numeric strings filtered out")
    func nonNumericFiltered() {
        let args: [String: JSONValue] = ["unique_ids": .array([.string("abc"), .string("5")])]
        let ids = EmailDeleteTool.parseUniqueIds(args)
        #expect(ids == [5])
    }

    @Test("Mixed types in array")
    func mixedTypes() {
        let args: [String: JSONValue] = ["unique_ids": .array([.int(1), .string("2"), .double(3.0)])]
        let ids = EmailDeleteTool.parseUniqueIds(args)
        #expect(ids == [1, 2, 3])
    }
}
