/* This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at https://mozilla.org/MPL/2.0/. */

import Testing
import Foundation
@testable import TabMail

@Suite("MemorySearchCache", .serialized)
struct MemorySearchCacheTests {

    private func hit(id: String, dateMs: Int64 = 1000, content: String = "x") -> MemoryHit {
        MemoryHit(
            chatHistoryId: id,
            sessionId: "s",
            role: "user",
            dateMs: dateMs,
            content: content,
            snippet: "",
            textScore: 0.5,
            vectorScore: 0.5,
            finalScore: 0.5
        )
    }

    @Test("set then get returns cached hits")
    func setGetHitsCache() async {
        await MemorySearchCache.shared.reset()
        let key = MemorySearchCache.makeKey(query: "foo", fromDate: nil, toDate: nil)
        await MemorySearchCache.shared.set(key, [hit(id: "t1"), hit(id: "t2")])
        let got = await MemorySearchCache.shared.get(key)
        #expect(got?.count == 2)
        #expect(got?.first?.chatHistoryId == "t1")
    }

    @Test("reset clears all keys")
    func resetClearsAllKeys() async {
        await MemorySearchCache.shared.reset()
        let k1 = MemorySearchCache.makeKey(query: "a", fromDate: nil, toDate: nil)
        let k2 = MemorySearchCache.makeKey(query: "b", fromDate: nil, toDate: nil)
        await MemorySearchCache.shared.set(k1, [hit(id: "t1")])
        await MemorySearchCache.shared.set(k2, [hit(id: "t2")])
        #expect(await MemorySearchCache.shared._testKeyCount() == 2)
        await MemorySearchCache.shared.reset()
        #expect(await MemorySearchCache.shared._testKeyCount() == 0)
        #expect(await MemorySearchCache.shared.get(k1) == nil)
    }

    @Test("distinct keys isolate cache entries")
    func distinctKeysIsolate() async {
        await MemorySearchCache.shared.reset()
        let k1 = MemorySearchCache.makeKey(query: "foo", fromDate: nil, toDate: nil)
        let k2 = MemorySearchCache.makeKey(query: "foo", fromDate: "2025-01-01", toDate: nil)
        let k3 = MemorySearchCache.makeKey(query: "foo", fromDate: nil, toDate: "2025-12-31")
        #expect(k1 != k2)
        #expect(k1 != k3)
        #expect(k2 != k3)
        await MemorySearchCache.shared.set(k1, [hit(id: "k1")])
        await MemorySearchCache.shared.set(k2, [hit(id: "k2")])
        #expect(await MemorySearchCache.shared.get(k1)?.first?.chatHistoryId == "k1")
        #expect(await MemorySearchCache.shared.get(k2)?.first?.chatHistoryId == "k2")
        #expect(await MemorySearchCache.shared.get(k3) == nil)
    }

    @Test("makeKey is stable for same inputs")
    func keyStable() {
        let a = MemorySearchCache.makeKey(query: "Hello World", fromDate: "2025-01-01", toDate: "2025-12-31")
        let b = MemorySearchCache.makeKey(query: "Hello World", fromDate: "2025-01-01", toDate: "2025-12-31")
        #expect(a == b)
    }

    @Test("makeKey trims query whitespace")
    func keyTrimsWhitespace() {
        let a = MemorySearchCache.makeKey(query: "  foo  ", fromDate: nil, toDate: nil)
        let b = MemorySearchCache.makeKey(query: "foo", fromDate: nil, toDate: nil)
        #expect(a == b)
    }

    @Test("makeKey escapes double quotes in query")
    func keyEscapesQuotes() {
        let k = MemorySearchCache.makeKey(query: "what \"is\" this?", fromDate: nil, toDate: nil)
        #expect(k.contains("\\\""))
    }
}
