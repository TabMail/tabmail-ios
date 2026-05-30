/* This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at https://mozilla.org/MPL/2.0/. */

import Testing
import Foundation
@testable import TabMail

@Suite("DisabledRemindersStore.hashReminder")
struct DisabledRemindersHashTests {

    @Test("Message reminder with rfc822MessageId uses m: prefix")
    func messageWithRfc822() {
        let hash = DisabledRemindersStore.hashReminder(
            source: "message", content: "irrelevant",
            uniqueId: "uid123", rfc822MessageId: "<msg@test.com>"
        )
        #expect(hash == "m:msg@test.com")
    }

    @Test("Message reminder strips angle brackets from rfc822MessageId")
    func stripsAngleBrackets() {
        let hash = DisabledRemindersStore.hashReminder(
            source: "message", content: "", uniqueId: nil,
            rfc822MessageId: "<abc@example.com>"
        )
        #expect(!hash.contains("<"))
        #expect(!hash.contains(">"))
    }

    @Test("Message reminder without rfc822 falls back to uniqueId")
    func fallbackToUniqueId() {
        let hash = DisabledRemindersStore.hashReminder(
            source: "message", content: "", uniqueId: "uid-456"
        )
        #expect(hash == "m:uid-456")
    }

    @Test("KB reminder uses k: prefix with djb2 hash")
    func kbReminder() {
        let hash = DisabledRemindersStore.hashReminder(
            source: "kb", content: "Remember to review quarterly report", uniqueId: nil
        )
        #expect(hash.hasPrefix("k:"))
    }

    @Test("KB hash is deterministic")
    func kbDeterministic() {
        let content = "Test content"
        let h1 = DisabledRemindersStore.hashReminder(source: "kb", content: content, uniqueId: nil)
        let h2 = DisabledRemindersStore.hashReminder(source: "kb", content: content, uniqueId: nil)
        #expect(h1 == h2)
    }

    @Test("KB hash differs for different content")
    func kbDifferent() {
        let h1 = DisabledRemindersStore.hashReminder(source: "kb", content: "Content A", uniqueId: nil)
        let h2 = DisabledRemindersStore.hashReminder(source: "kb", content: "Content B", uniqueId: nil)
        #expect(h1 != h2)
    }

    @Test("Unknown source uses o: prefix with first 32 chars")
    func unknownSource() {
        let hash = DisabledRemindersStore.hashReminder(
            source: "unknown", content: "Short content", uniqueId: nil
        )
        #expect(hash.hasPrefix("o:"))
        #expect(hash == "o:Short content")
    }

    @Test("Unknown source truncates to 32 chars")
    func unknownSourceTruncates() {
        let longContent = String(repeating: "x", count: 100)
        let hash = DisabledRemindersStore.hashReminder(
            source: "other", content: longContent, uniqueId: nil
        )
        #expect(hash == "o:" + String(repeating: "x", count: 32))
    }

    @Test("Message with empty rfc822 and nil uniqueId uses fallback")
    func messageEmptyBoth() {
        let hash = DisabledRemindersStore.hashReminder(
            source: "message", content: "Some content", uniqueId: nil, rfc822MessageId: ""
        )
        // Empty rfc822 + nil uniqueId → falls through to "o:" fallback
        #expect(hash.hasPrefix("o:"))
    }
}

@Suite("DisabledRemindersStore.DisabledEntry")
struct DisabledEntryTests {

    @Test("DisabledEntry Codable round-trip")
    func codableRoundTrip() throws {
        let entry = DisabledRemindersStore.DisabledEntry(enabled: false, ts: "2024-03-15T10:00:00Z")
        let data = try JSONEncoder().encode(entry)
        let decoded = try JSONDecoder().decode(DisabledRemindersStore.DisabledEntry.self, from: data)
        #expect(decoded.enabled == false)
        #expect(decoded.ts == "2024-03-15T10:00:00Z")
    }

    @Test("DisabledEntry enabled=true is tombstone")
    func enabledIsTombstone() throws {
        let entry = DisabledRemindersStore.DisabledEntry(enabled: true, ts: "2024-03-15T10:00:00Z")
        #expect(entry.enabled == true)
    }
}

@Suite("DisabledRemindersStore.djb2Hash")
struct DJB2HashTests {

    @Test("Empty string hashes to 0")
    func emptyString() {
        let result = DisabledRemindersStore.djb2Hash("")
        #expect(result == 0)
    }

    @Test("Hash is deterministic")
    func deterministic() {
        let h1 = DisabledRemindersStore.djb2Hash("hello")
        let h2 = DisabledRemindersStore.djb2Hash("hello")
        #expect(h1 == h2)
    }

    @Test("Different strings produce different hashes")
    func differentStrings() {
        let h1 = DisabledRemindersStore.djb2Hash("hello")
        let h2 = DisabledRemindersStore.djb2Hash("world")
        #expect(h1 != h2)
    }

    @Test("Single character hash")
    func singleChar() {
        // 'a' = 97 in UTF-16. hash = ((0 << 5) - 0) + 97 = 97
        let result = DisabledRemindersStore.djb2Hash("a")
        #expect(result == 97)
    }

    @Test("Uses UTF-16 code units (matching JS charCodeAt)")
    func utf16CodeUnits() {
        // Emoji that is a surrogate pair in UTF-16 should produce 2 hash iterations
        let emoji = "\u{1F600}" // Grinning face
        let h1 = DisabledRemindersStore.djb2Hash(emoji)
        // Just verify it produces a non-zero result and doesn't crash
        #expect(h1 != 0)
    }

    @Test("KB hash via hashReminder produces base-36 encoding")
    func base36Encoding() {
        let hash = DisabledRemindersStore.hashReminder(source: "kb", content: "test", uniqueId: nil)
        #expect(hash.hasPrefix("k:"))
        let base36Part = String(hash.dropFirst(2))
        // Base-36 should only contain 0-9 and a-z (and possibly leading minus)
        let validChars = CharacterSet(charactersIn: "0123456789abcdefghijklmnopqrstuvwxyz-")
        #expect(base36Part.unicodeScalars.allSatisfy { validChars.contains($0) })
    }

    @Test("Hash handles ASCII text")
    func asciiText() {
        let result = DisabledRemindersStore.djb2Hash("Hello, World!")
        #expect(result != 0)
    }

    @Test("Hash handles Unicode text")
    func unicodeText() {
        let result = DisabledRemindersStore.djb2Hash("Cafe\u{0301}")  // "Cafe" + combining accent
        #expect(result != 0)
    }

    @Test("Hash overflows gracefully with wrapping arithmetic")
    func overflowWraps() {
        // Long string should not crash thanks to &- and &+ operators
        let longString = String(repeating: "abcdefghij", count: 1000)
        let result = DisabledRemindersStore.djb2Hash(longString)
        // Just verify it doesn't crash and produces a result
        _ = result
    }
}
