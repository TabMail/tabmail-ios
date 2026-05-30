/* This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at https://mozilla.org/MPL/2.0/. */

import Testing
import Foundation
@testable import TabMail

@Suite("MessageAICache.cacheKey")
struct MessageAICacheKeyTests {

    @Test("Standard key format is accountId:folderPath:rfc822MessageId")
    func standardFormat() {
        let key = MessageAICache.cacheKey(accountId: "acc1", folderPath: "INBOX", rfc822MessageId: "<msg@example.com>")
        #expect(key == "acc1:INBOX:<msg@example.com>")
    }

    @Test("Returns nil when rfc822MessageId is nil")
    func nilMessageId() {
        let key = MessageAICache.cacheKey(accountId: "acc1", folderPath: "INBOX", rfc822MessageId: nil)
        #expect(key == nil)
    }

    @Test("Returns nil when rfc822MessageId is empty string")
    func emptyMessageId() {
        let key = MessageAICache.cacheKey(accountId: "acc1", folderPath: "INBOX", rfc822MessageId: "")
        #expect(key == nil)
    }

    @Test("Handles nested folder paths with separators")
    func nestedFolderPath() {
        let key = MessageAICache.cacheKey(accountId: "acc1", folderPath: "INBOX/Subfolder/Deep", rfc822MessageId: "<id@test.com>")
        #expect(key == "acc1:INBOX/Subfolder/Deep:<id@test.com>")
    }

    @Test("Handles account IDs with colons")
    func accountIdWithColons() {
        // Account IDs can contain colons (e.g., "gmail:user@gmail.com")
        let key = MessageAICache.cacheKey(accountId: "gmail:user@gmail.com", folderPath: "INBOX", rfc822MessageId: "<id@test.com>")
        #expect(key == "gmail:user@gmail.com:INBOX:<id@test.com>")
    }

    @Test("Handles special characters in message ID")
    func specialCharsInMessageId() {
        let key = MessageAICache.cacheKey(accountId: "acc", folderPath: "Sent", rfc822MessageId: "<CABx+XJ3h@mail.gmail.com>")
        #expect(key == "acc:Sent:<CABx+XJ3h@mail.gmail.com>")
    }

    @Test("Handles empty account ID")
    func emptyAccountId() {
        let key = MessageAICache.cacheKey(accountId: "", folderPath: "INBOX", rfc822MessageId: "<id@test.com>")
        #expect(key == ":INBOX:<id@test.com>")
    }

    @Test("Handles empty folder path")
    func emptyFolderPath() {
        let key = MessageAICache.cacheKey(accountId: "acc1", folderPath: "", rfc822MessageId: "<id@test.com>")
        #expect(key == "acc1::<id@test.com>")
    }

    @Test("Key components are separated by exactly one colon each")
    func colonSeparatorCount() {
        let key = MessageAICache.cacheKey(accountId: "acc", folderPath: "INBOX", rfc822MessageId: "<id>")!
        let parts = key.split(separator: ":", maxSplits: 2, omittingEmptySubsequences: false)
        #expect(parts.count == 3)
        #expect(parts[0] == "acc")
        #expect(parts[1] == "INBOX")
        #expect(parts[2] == "<id>")
    }

    @Test("Different folder paths produce different keys")
    func differentFolderPaths() {
        let k1 = MessageAICache.cacheKey(accountId: "acc", folderPath: "INBOX", rfc822MessageId: "<id>")
        let k2 = MessageAICache.cacheKey(accountId: "acc", folderPath: "Sent", rfc822MessageId: "<id>")
        #expect(k1 != k2)
    }

    @Test("Different account IDs produce different keys")
    func differentAccountIds() {
        let k1 = MessageAICache.cacheKey(accountId: "acc1", folderPath: "INBOX", rfc822MessageId: "<id>")
        let k2 = MessageAICache.cacheKey(accountId: "acc2", folderPath: "INBOX", rfc822MessageId: "<id>")
        #expect(k1 != k2)
    }

    @Test("Different message IDs produce different keys")
    func differentMessageIds() {
        let k1 = MessageAICache.cacheKey(accountId: "acc", folderPath: "INBOX", rfc822MessageId: "<id1>")
        let k2 = MessageAICache.cacheKey(accountId: "acc", folderPath: "INBOX", rfc822MessageId: "<id2>")
        #expect(k1 != k2)
    }

    @Test("Whitespace-only rfc822MessageId returns a key (not nil)")
    func whitespaceOnlyMessageId() {
        // A whitespace string is not empty, so cacheKey should return a value
        let key = MessageAICache.cacheKey(accountId: "acc", folderPath: "INBOX", rfc822MessageId: "  ")
        #expect(key != nil)
        #expect(key == "acc:INBOX:  ")
    }

    @Test("Unicode characters in folder path are preserved")
    func unicodeFolderPath() {
        let key = MessageAICache.cacheKey(accountId: "acc", folderPath: "Dossiers/Reçus", rfc822MessageId: "<id>")
        #expect(key == "acc:Dossiers/Reçus:<id>")
    }
}
