/* This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at https://mozilla.org/MPL/2.0/. */

import Testing
import Foundation
@testable import TabMail

@Suite("EmailDeleteTool.parseUniqueIds")
struct EmailDeleteToolParseTests {

    @Test("Array of ints returns all ints")
    func arrayOfInts() {
        let args: [String: JSONValue] = ["unique_ids": .array([.int(1), .int(2), .int(3)])]
        let result = EmailDeleteTool.parseUniqueIds(args)
        #expect(result == [1, 2, 3])
    }

    @Test("Array of strings returns parsed ints")
    func arrayOfStrings() {
        let args: [String: JSONValue] = ["unique_ids": .array([.string("10"), .string("20")])]
        let result = EmailDeleteTool.parseUniqueIds(args)
        #expect(result == [10, 20])
    }

    @Test("Array of doubles returns truncated ints")
    func arrayOfDoubles() {
        let args: [String: JSONValue] = ["unique_ids": .array([.double(5.0), .double(7.9)])]
        let result = EmailDeleteTool.parseUniqueIds(args)
        #expect(result == [5, 7])
    }

    @Test("Mixed array extracts all convertible items")
    func mixedArray() {
        let args: [String: JSONValue] = ["unique_ids": .array([
            .int(1), .string("2"), .double(3.0), .bool(true)
        ])]
        let result = EmailDeleteTool.parseUniqueIds(args)
        #expect(result == [1, 2, 3])
    }

    @Test("Empty array returns empty")
    func emptyArray() {
        let args: [String: JSONValue] = ["unique_ids": .array([])]
        let result = EmailDeleteTool.parseUniqueIds(args)
        #expect(result.isEmpty)
    }

    @Test("Missing unique_ids returns empty")
    func missingKey() {
        let result = EmailDeleteTool.parseUniqueIds([:])
        #expect(result.isEmpty)
    }

    @Test("Non-parseable strings are skipped")
    func nonParseableStrings() {
        let args: [String: JSONValue] = ["unique_ids": .array([.string("abc"), .string("5")])]
        let result = EmailDeleteTool.parseUniqueIds(args)
        #expect(result == [5])
    }

    @Test("Single unique_id int falls through to singular key")
    func singleIntId() {
        let args: [String: JSONValue] = ["unique_id": .int(42)]
        let result = EmailDeleteTool.parseUniqueIds(args)
        #expect(result == [42])
    }

    @Test("Single unique_id string falls through to singular key")
    func singleStringId() {
        let args: [String: JSONValue] = ["unique_id": .string("99")]
        let result = EmailDeleteTool.parseUniqueIds(args)
        #expect(result == [99])
    }

    @Test("Single unique_id non-parseable string returns empty")
    func singleNonParseableString() {
        let args: [String: JSONValue] = ["unique_id": .string("abc")]
        let result = EmailDeleteTool.parseUniqueIds(args)
        #expect(result.isEmpty)
    }

    @Test("unique_ids takes priority over unique_id")
    func arrayTakesPriority() {
        let args: [String: JSONValue] = [
            "unique_ids": .array([.int(1), .int(2)]),
            "unique_id": .int(99)
        ]
        let result = EmailDeleteTool.parseUniqueIds(args)
        #expect(result == [1, 2])
    }

    @Test("Bool values in array are skipped")
    func boolsSkipped() {
        let args: [String: JSONValue] = ["unique_ids": .array([.bool(true), .bool(false)])]
        let result = EmailDeleteTool.parseUniqueIds(args)
        #expect(result.isEmpty)
    }
}
