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

    @Test("Array of objects with 'email' key extracts emails")
    func arrayOfEmailObjects() {
        let value: JSONValue = .array([
            .dictionary(["email": .string("x@y.com"), "name": .string("X Y")]),
            .dictionary(["email": .string("a@b.com")])
        ])
        let result = EmailComposeTool.parseStringArray(value)
        #expect(result == ["x@y.com", "a@b.com"])
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
