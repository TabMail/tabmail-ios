/* This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at https://mozilla.org/MPL/2.0/. */

import Testing
import Foundation
@testable import TabMail

/// Unit coverage for the shared `MessageIdentity` helper. These functions
/// are the single source of truth for GRDB header IDs and AI-cache keys
/// across the main app + NSE; a format drift here breaks pre-sync row
/// materialization and silently duplicates messages.
@Suite("MessageIdentity")
struct MessageIdentityTests {

    @Test("headerId is the accountId:folderPath:messageId composite")
    func headerIdFormat() {
        let id = MessageIdentity.headerId(accountId: "acct-1", folderPath: "INBOX", messageId: "msg-42")
        #expect(id == "acct-1:INBOX:msg-42")
    }

    @Test("headerId keeps Outlook Graph folder IDs intact (no double-accountId)")
    func headerIdWithGraphFolderPath() {
        // Outlook's parentFolderId is opaque + long; it must not be re-wrapped.
        let graphFolder = "AQMkADAwATE2MTQwLTk2YTQtNjViMy0wMAItMDAKAC4AAAMDNjEovScBQ45d1u-N6VF6AQBsEuKMUAqnSoipbS5grLZLAAACAQwAAAA="
        let id = MessageIdentity.headerId(accountId: "acct-o", folderPath: graphFolder, messageId: "msg-outlook")
        #expect(id == "acct-o:\(graphFolder):msg-outlook")
    }

    @Test("folderId is the accountId:folderPath composite")
    func folderIdFormat() {
        #expect(MessageIdentity.folderId(accountId: "acct", folderPath: "INBOX") == "acct:INBOX")
    }

    @Test("aiCacheKey matches MessageAICache.cacheKey byte-for-byte")
    func aiCacheKeyMatchesMessageAICache() {
        // This is the contract the NSE cross-device peer probe depends on.
        let shared = MessageIdentity.aiCacheKey(
            accountId: "acct", folderPath: "INBOX", rfc822MessageId: "abc@example.com"
        )
        let mac = MessageAICache.cacheKey(
            accountId: "acct", folderPath: "INBOX", rfc822MessageId: "abc@example.com"
        )
        #expect(shared == mac)
        #expect(shared == "acct:INBOX:abc@example.com")
    }

    @Test("aiCacheKey returns nil when rfc822MessageId is missing (no cache row for those)")
    func aiCacheKeyNilOnMissingRfc() {
        #expect(MessageIdentity.aiCacheKey(accountId: "a", folderPath: "INBOX", rfc822MessageId: nil) == nil)
        #expect(MessageIdentity.aiCacheKey(accountId: "a", folderPath: "INBOX", rfc822MessageId: "") == nil)
    }

    @Test("aiCacheKey does NOT double-wrap the folder — regression guard for bug 2a")
    func aiCacheKeyNoDoubleAccountId() {
        // The NSEDataBridge pre-fix path built keys as
        // "accountId:accountId:INBOX:rfc" (folderId already embedded accountId,
        // then accountId was prefixed again). Assert the shared helper
        // produces the flat shape the main-app cache stores under.
        let key = MessageIdentity.aiCacheKey(
            accountId: "dup", folderPath: "INBOX", rfc822MessageId: "r@x"
        )
        #expect(key == "dup:INBOX:r@x")
        #expect(key != "dup:dup:INBOX:r@x")
    }

    @Test("MessageHeader.id goes through MessageIdentity — same composite")
    func messageHeaderUsesMessageIdentity() {
        let header = MessageHeader(
            messageId: "m", subject: "", from: "", fromAddress: "", to: "",
            date: Date(timeIntervalSince1970: 0), snippet: "",
            folderId: "acct:INBOX", accountId: "acct",
            folderPath: "INBOX", isInInbox: true
        )
        #expect(header.id == MessageIdentity.headerId(
            accountId: "acct", folderPath: "INBOX", messageId: "m"
        ))
    }
}
