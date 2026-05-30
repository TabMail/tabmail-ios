/* This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at https://mozilla.org/MPL/2.0/. */

import Testing
@testable import TabMail

@Suite("PendingDeepLinkStore")
struct PendingDeepLinkStoreTests {

    init() {
        // Clear any leftover state before each test
        _ = PendingDeepLinkStore.consume()
    }

    @Test("consume returns nil when nothing stored")
    func consumeEmpty() {
        let result = PendingDeepLinkStore.consume()
        #expect(result == nil)
    }

    @Test("store and consume message deep link")
    func storeAndConsumeMessage() {
        PendingDeepLinkStore.store(.message(id: "acct1:INBOX:msg123"))
        let result = PendingDeepLinkStore.consume()
        guard case .message(let id) = result else {
            Issue.record("Expected .message deep link")
            return
        }
        #expect(id == "acct1:INBOX:msg123")
    }

    @Test("store and consume inbox deep link")
    func storeAndConsumeInbox() {
        PendingDeepLinkStore.store(.inbox)
        let result = PendingDeepLinkStore.consume()
        guard case .inbox = result else {
            Issue.record("Expected .inbox deep link")
            return
        }
    }

    @Test("consume clears the stored value")
    func consumeClearsValue() {
        PendingDeepLinkStore.store(.inbox)
        _ = PendingDeepLinkStore.consume()
        let second = PendingDeepLinkStore.consume()
        #expect(second == nil)
    }

    @Test("store overwrites previous value")
    func storeOverwrites() {
        PendingDeepLinkStore.store(.message(id: "first"))
        PendingDeepLinkStore.store(.message(id: "second"))
        let result = PendingDeepLinkStore.consume()
        guard case .message(let id) = result else {
            Issue.record("Expected .message deep link")
            return
        }
        #expect(id == "second")
    }

    @Test("store message then overwrite with inbox")
    func storeMessageThenInbox() {
        PendingDeepLinkStore.store(.message(id: "msg1"))
        PendingDeepLinkStore.store(.inbox)
        let result = PendingDeepLinkStore.consume()
        guard case .inbox = result else {
            Issue.record("Expected .inbox deep link after overwrite")
            return
        }
    }
}
