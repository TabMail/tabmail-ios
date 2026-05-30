/* This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at https://mozilla.org/MPL/2.0/. */

import Testing
import Foundation
@testable import TabMail

@Suite("ChatTurn.generateId")
struct ChatStoreGenerateIdTests {

    @Test("generateId produces timestamp-random format")
    func idFormat() {
        let id = ChatTurn.generateId()
        let parts = id.split(separator: "-")
        #expect(parts.count == 2)
        // First part should be a numeric timestamp in milliseconds
        #expect(Int(parts[0]) != nil)
        // Second part should be 6 alphanumeric characters
        #expect(parts[1].count == 6)
    }

    @Test("generateId timestamp part is recent")
    func idTimestampIsRecent() {
        let before = Int(Date().timeIntervalSince1970 * 1000)
        let id = ChatTurn.generateId()
        let after = Int(Date().timeIntervalSince1970 * 1000)

        let parts = id.split(separator: "-")
        let ts = Int(parts[0])!
        #expect(ts >= before)
        #expect(ts <= after)
    }

    @Test("generateId random part contains only lowercase alphanumeric")
    func idRandomPartCharset() {
        let allowed = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyz0123456789")
        for _ in 0..<20 {
            let id = ChatTurn.generateId()
            let randomPart = String(id.split(separator: "-")[1])
            for char in randomPart.unicodeScalars {
                #expect(allowed.contains(char))
            }
        }
    }

    @Test("generateId produces unique IDs")
    func idUniqueness() {
        var ids = Set<String>()
        for _ in 0..<100 {
            ids.insert(ChatTurn.generateId())
        }
        // All 100 should be unique (extremely unlikely collision with 36^6 random space + ms timestamp)
        #expect(ids.count == 100)
    }

    @Test("generateId random part is exactly 6 characters")
    func idRandomPartLength() {
        for _ in 0..<50 {
            let id = ChatTurn.generateId()
            let randomPart = String(id.split(separator: "-")[1])
            #expect(randomPart.count == 6)
        }
    }

    @Test("generateId contains exactly one hyphen separator")
    func idSingleHyphen() {
        let id = ChatTurn.generateId()
        let hyphenCount = id.filter { $0 == "-" }.count
        #expect(hyphenCount == 1)
    }

    @Test("generateId timestamp is positive")
    func idTimestampPositive() {
        let id = ChatTurn.generateId()
        let ts = Int(id.split(separator: "-")[0])!
        #expect(ts > 0)
    }

    @Test("generateId is non-empty")
    func idNonEmpty() {
        let id = ChatTurn.generateId()
        #expect(!id.isEmpty)
    }
}
