/* This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at https://mozilla.org/MPL/2.0/. */

import Testing
import Foundation
@testable import TabMail

@Suite("MessageAICache")
struct MessageAICacheTests {

    @Test("cacheKey format is accountId:folderPath:rfc822MessageId")
    func cacheKeyFormat() {
        let key = MessageAICache.cacheKey(accountId: "acc1", folderPath: "INBOX", rfc822MessageId: "<msg@example.com>")
        #expect(key == "acc1:INBOX:<msg@example.com>")
    }

    @Test("cacheKey returns nil when rfc822MessageId is nil")
    func cacheKeyNilMessageId() {
        let key = MessageAICache.cacheKey(accountId: "acc1", folderPath: "INBOX", rfc822MessageId: nil)
        #expect(key == nil)
    }

    @Test("cacheKey returns nil when rfc822MessageId is empty")
    func cacheKeyEmptyMessageId() {
        let key = MessageAICache.cacheKey(accountId: "acc1", folderPath: "INBOX", rfc822MessageId: "")
        #expect(key == nil)
    }

    @Test("Init with minimal fields")
    func initMinimal() {
        let cache = MessageAICache(key: "acc1:INBOX:<msg@example.com>")
        #expect(cache.id == "acc1:INBOX:<msg@example.com>")
        #expect(cache.summaryBlurb == nil)
        #expect(cache.summaryTodos == nil)
        #expect(cache.reminderDate == nil)
        #expect(cache.reminderTime == nil)
        #expect(cache.reminderContent == nil)
        #expect(cache.actionTag == nil)
        #expect(cache.cachedReply == nil)
        #expect(cache.replyGeneratedAt == nil)
    }

    @Test("All AI fields are independently nullable")
    func fieldsIndependentlyNullable() {
        var cache = MessageAICache(key: "k1")
        cache.summaryBlurb = "Summary"
        #expect(cache.summaryBlurb == "Summary")
        #expect(cache.actionTag == nil)
        #expect(cache.cachedReply == nil)

        cache.actionTag = .archive
        #expect(cache.actionTag == .archive)
        #expect(cache.cachedReply == nil)
    }
}
