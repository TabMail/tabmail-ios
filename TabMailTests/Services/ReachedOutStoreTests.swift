/* This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at https://mozilla.org/MPL/2.0/. */

import Testing
import Foundation
@testable import TabMail

@Suite("ReachedOutStore.Entry")
struct ReachedOutStoreEntryTests {

    @Test("Entry Codable round-trip")
    func codableRoundTrip() throws {
        let entry = ReachedOutStore.Entry(notifiedAt: Date(timeIntervalSince1970: 1710500000))
        let data = try JSONEncoder().encode(entry)
        let decoded = try JSONDecoder().decode(ReachedOutStore.Entry.self, from: data)
        #expect(decoded.notifiedAt.timeIntervalSince1970 == entry.notifiedAt.timeIntervalSince1970)
    }

    @Test("Entry is Sendable")
    func isSendable() {
        let entry = ReachedOutStore.Entry(notifiedAt: Date())
        let _: any Sendable = entry
    }

    @Test("Entry round-trips through JSON encode/decode")
    func decodeFromJSON() throws {
        let original = ReachedOutStore.Entry(notifiedAt: Date(timeIntervalSince1970: 1710513000))
        let data = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(ReachedOutStore.Entry.self, from: data)
        #expect(abs(decoded.notifiedAt.timeIntervalSince1970 - 1710513000) < 0.001)
    }

    @Test("Entry map encodes and decodes as dictionary")
    func entryMapRoundTrip() throws {
        let entries: [String: ReachedOutStore.Entry] = [
            "m:abc123": ReachedOutStore.Entry(notifiedAt: Date(timeIntervalSince1970: 1000)),
            "k:def456": ReachedOutStore.Entry(notifiedAt: Date(timeIntervalSince1970: 2000)),
        ]
        let data = try JSONEncoder().encode(entries)
        let decoded = try JSONDecoder().decode([String: ReachedOutStore.Entry].self, from: data)
        #expect(decoded.count == 2)
        #expect(decoded["m:abc123"] != nil)
        #expect(abs(decoded["m:abc123"]!.notifiedAt.timeIntervalSince1970 - 1000) < 0.001)
    }

    @Test("Entry within 48h TTL is considered notified")
    func withinTTL() {
        let oneHourAgo = Date().addingTimeInterval(-3600)
        let entry = ReachedOutStore.Entry(notifiedAt: oneHourAgo)
        let ttlSeconds: TimeInterval = 48 * 3600
        let isWithinTTL = Date().timeIntervalSince(entry.notifiedAt) < ttlSeconds
        #expect(isWithinTTL == true)
    }

    @Test("Entry older than 48h TTL is expired")
    func beyondTTL() {
        let old = Date().addingTimeInterval(-49 * 3600)
        let entry = ReachedOutStore.Entry(notifiedAt: old)
        let ttlSeconds: TimeInterval = 48 * 3600
        let isWithinTTL = Date().timeIntervalSince(entry.notifiedAt) < ttlSeconds
        #expect(isWithinTTL == false)
    }

    @Test("Entry exactly at 48h boundary is expired")
    func atBoundary() {
        let exactly48h = Date().addingTimeInterval(-48 * 3600)
        let entry = ReachedOutStore.Entry(notifiedAt: exactly48h)
        let ttlSeconds: TimeInterval = 48 * 3600
        let isWithinTTL = Date().timeIntervalSince(entry.notifiedAt) < ttlSeconds
        #expect(isWithinTTL == false)
    }

    @Test("Fresh entry is within TTL")
    func freshEntry() {
        let entry = ReachedOutStore.Entry(notifiedAt: Date())
        let ttlSeconds: TimeInterval = 48 * 3600
        let isWithinTTL = Date().timeIntervalSince(entry.notifiedAt) < ttlSeconds
        #expect(isWithinTTL == true)
    }

    @Test("Pruning logic filters expired entries correctly")
    func pruneLogic() {
        let ttlSeconds: TimeInterval = 48 * 3600
        let cutoff = Date().addingTimeInterval(-ttlSeconds)

        let map: [String: ReachedOutStore.Entry] = [
            "fresh": ReachedOutStore.Entry(notifiedAt: Date()),
            "recent": ReachedOutStore.Entry(notifiedAt: Date().addingTimeInterval(-3600)),
            "expired": ReachedOutStore.Entry(notifiedAt: Date().addingTimeInterval(-50 * 3600)),
            "veryOld": ReachedOutStore.Entry(notifiedAt: Date(timeIntervalSince1970: 0)),
        ]

        let pruned = map.filter { _, entry in entry.notifiedAt > cutoff }
        #expect(pruned.count == 2)
        #expect(pruned["fresh"] != nil)
        #expect(pruned["recent"] != nil)
        #expect(pruned["expired"] == nil)
        #expect(pruned["veryOld"] == nil)
    }

    @Test("Multiple entries can be encoded as a map")
    func multipleEntries() throws {
        var map: [String: ReachedOutStore.Entry] = [:]
        for i in 0..<10 {
            map["hash\(i)"] = ReachedOutStore.Entry(notifiedAt: Date(timeIntervalSince1970: Double(i * 1000)))
        }
        let data = try JSONEncoder().encode(map)
        let decoded = try JSONDecoder().decode([String: ReachedOutStore.Entry].self, from: data)
        #expect(decoded.count == 10)
        #expect(abs(decoded["hash5"]!.notifiedAt.timeIntervalSince1970 - 5000) < 0.001)
    }
}
