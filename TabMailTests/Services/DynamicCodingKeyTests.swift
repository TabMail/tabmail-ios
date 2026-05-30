/* This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at https://mozilla.org/MPL/2.0/. */

import Testing
import Foundation
@testable import TabMail

@Suite("DynamicCodingKey")
struct DynamicCodingKeyTests {

    @Test("Init with string")
    func initWithString() {
        let key = DynamicCodingKey("myKey")
        #expect(key.stringValue == "myKey")
        #expect(key.intValue == nil)
    }

    @Test("Init with stringValue")
    func initWithStringValue() {
        let key = DynamicCodingKey(stringValue: "test")
        #expect(key != nil)
        #expect(key?.stringValue == "test")
    }

    @Test("Init with intValue returns nil")
    func initWithIntValue() {
        let key = DynamicCodingKey(intValue: 42)
        #expect(key == nil)
    }
}
