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

    @Test("durable action identity accepts bare or balanced brackets and preserves case")
    func durableActionIdentityNormalizesAcceptedForms() {
        #expect(MessageIdentity.durableActionRFC822MessageId(
            "  <Case.Sensitive@Example.COM>  "
        ) == "Case.Sensitive@Example.COM")
        #expect(MessageIdentity.durableActionRFC822MessageId(
            "bare@example.com"
        ) == "bare@example.com")
    }

    @Test("durable action identity rejects malformed and provider-specific identities")
    func durableActionIdentityRequiresRFCShape() {
        #expect(MessageIdentity.durableActionRFC822MessageId(nil) == nil)
        #expect(MessageIdentity.durableActionRFC822MessageId("   ") == nil)
        #expect(MessageIdentity.durableActionRFC822MessageId("opaque-provider-token") == nil)
        #expect(MessageIdentity.durableActionRFC822MessageId("<missing-close@example.com") == nil)
        #expect(MessageIdentity.durableActionRFC822MessageId("missing-open@example.com>") == nil)
        #expect(MessageIdentity.durableActionRFC822MessageId("<<nested@example.com>>") == nil)
        #expect(MessageIdentity.durableActionRFC822MessageId("legacy opaque token") == nil)
        #expect(MessageIdentity.durableActionRFC822MessageId("local@@example.com") == nil)
        #expect(MessageIdentity.durableActionRFC822MessageId("@example.com") == nil)
        #expect(MessageIdentity.durableActionRFC822MessageId("local@") == nil)
        #expect(MessageIdentity.durableActionRFC822MessageId("local @example.com") == nil)
        #expect(MessageIdentity.durableActionRFC822MessageId("line@example.com\r\nInjected: value") == nil)
    }

    @Test("durable action address admits RFC identity and scope together")
    func durableActionAddressRequiresCompleteScope() {
        let address = MessageIdentity.durableActionAddress(
            accountId: "account",
            folderPath: "INBOX",
            rfc822MessageId: " <member@example.com> "
        )
        #expect(address?.accountId == "account")
        #expect(address?.folderPath == "INBOX")
        #expect(address?.rfc822MessageId == "member@example.com")
        #expect(MessageIdentity.durableActionAddress(
            accountId: " ", folderPath: "INBOX", rfc822MessageId: "member@example.com"
        ) == nil)
        #expect(MessageIdentity.durableActionAddress(
            accountId: "account", folderPath: "\n", rfc822MessageId: "member@example.com"
        ) == nil)
    }

    @Test("durable message-action factory normalizes all members and rejects other identity domains")
    func durableMessageActionFactoryEnforcesBoundary() {
        let operation = PendingOperation.durableMessageAction(
            type: .move,
            messageIds: ["<first@example.com>", "second@example.com"],
            accountId: "account",
            folderPath: "INBOX",
            destinationPath: "Archive"
        )
        #expect(operation?.messageIds == ["first@example.com", "second@example.com"])
        #expect(PendingOperation.durableMessageAction(
            type: .markRead,
            messageIds: ["line@example.com\r\nInjected: value"],
            accountId: "account",
            folderPath: "INBOX"
        ) == nil)
        #expect(PendingOperation.durableMessageAction(
            type: .saveDraft,
            messageIds: ["provider-draft-resource"],
            accountId: "account",
            folderPath: "Drafts"
        ) == nil)
        #expect(PendingOperation.durableMessageAction(
            type: .archive,
            messageIds: ["archive@example.com"],
            accountId: "account",
            folderPath: "INBOX",
            destinationPath: "Archive"
        ) == nil)
        #expect(PendingOperation.durableMessageAction(
            type: .delete,
            messageIds: ["delete@example.com"],
            accountId: "account",
            folderPath: "INBOX",
            destinationPath: "Trash"
        ) == nil)
        #expect(PendingOperation.durableMessageAction(
            type: .move,
            messageIds: ["move@example.com"],
            accountId: "account",
            folderPath: "INBOX",
            destinationPath: " \n"
        ) == nil)
        #expect(PendingOperation.durableMessageAction(
            type: .addUserLabel,
            messageIds: ["label@example.com"],
            accountId: "account",
            folderPath: "INBOX",
            userLabelId: "\t"
        ) == nil)
        #expect(PendingOperation.durableMessageAction(
            type: .removeUserLabel,
            messageIds: ["label@example.com"],
            accountId: "account",
            folderPath: "INBOX",
            userLabelId: "label-id"
        )?.userLabelId == "label-id")
    }

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
            accountId: "dup", folderPath: "INBOX", rfc822MessageId: "identity@example.com"
        )
        #expect(key == "dup:INBOX:identity@example.com")
        #expect(key != "dup:dup:INBOX:identity@example.com")
    }

    @Test("recent provenance keys cannot collide when folder and message contain colons")
    func recentProvenanceKeysLengthPrefixComponents() {
        let accountId = "acct"
        let firstFolder = "Foo"
        let firstMessageId = "bar:baz"
        let secondFolder = "Foo:bar"
        let secondMessageId = "baz"

        #expect(MessageIdentity.recentlyCompletedFolderKey(
            accountId: accountId,
            folderPath: firstFolder,
            messageId: firstMessageId
        ) != MessageIdentity.recentlyCompletedFolderKey(
            accountId: accountId,
            folderPath: secondFolder,
            messageId: secondMessageId
        ))
        #expect(MessageIdentity.recentlyCompletedFieldKey(
            accountId: accountId,
            folderPath: firstFolder,
            messageId: firstMessageId,
            field: .read
        ) != MessageIdentity.recentlyCompletedFieldKey(
            accountId: accountId,
            folderPath: secondFolder,
            messageId: secondMessageId,
            field: .read
        ))
        #expect(MessageIdentity.recentlyCompletedFieldValueKey(
            accountId: accountId,
            folderPath: firstFolder,
            messageId: firstMessageId,
            value: .read(false)
        ) != MessageIdentity.recentlyCompletedFieldValueKey(
            accountId: accountId,
            folderPath: secondFolder,
            messageId: secondMessageId,
            value: .read(false)
        ))
        #expect(MessageIdentity.recentlyCompletedPushKey(
            accountId: accountId,
            folderPath: firstFolder,
            messageId: firstMessageId
        ) != MessageIdentity.recentlyCompletedPushKey(
            accountId: accountId,
            folderPath: secondFolder,
            messageId: secondMessageId
        ))
        #expect(MessageIdentity.membershipKey(
            accountId: accountId,
            folderPath: firstFolder,
            messageId: firstMessageId,
            membership: .addedDestination
        ) != MessageIdentity.membershipKey(
            accountId: accountId,
            folderPath: secondFolder,
            messageId: secondMessageId,
            membership: .addedDestination
        ))
    }

    @Test("field-value provenance distinguishes polarity, type, and action-tag nil")
    func recentFieldValueKeysPreserveExactValue() {
        let readTrue = MessageIdentity.recentlyCompletedFieldValueKey(
            accountId: "account",
            messageId: "message",
            value: .read(true)
        )
        let readFalse = MessageIdentity.recentlyCompletedFieldValueKey(
            accountId: "account",
            messageId: "message",
            value: .read(false)
        )
        let flaggedTrue = MessageIdentity.recentlyCompletedFieldValueKey(
            accountId: "account",
            messageId: "message",
            value: .flagged(true)
        )
        let removedTag = MessageIdentity.recentlyCompletedFieldValueKey(
            accountId: "account",
            messageId: "message",
            value: .actionTag(nil)
        )
        let literalNilTag = MessageIdentity.recentlyCompletedFieldValueKey(
            accountId: "account",
            messageId: "message",
            value: .actionTag("nil")
        )
        let emptyTag = MessageIdentity.recentlyCompletedFieldValueKey(
            accountId: "account",
            messageId: "message",
            value: .actionTag("")
        )

        #expect(readTrue != readFalse)
        #expect(readTrue != flaggedTrue)
        #expect(removedTag != literalNilTag)
        #expect(removedTag != emptyTag)
        #expect(Set([
            readTrue, readFalse, flaggedTrue, removedTag, literalNilTag, emptyTag,
        ]).count == 6)
    }

    @Test("field-value provenance scopes account and folder boundaries independently")
    func recentFieldValueKeysScopeIdentity() {
        let accountA = MessageIdentity.recentlyCompletedFieldValueKey(
            accountId: "account:A",
            messageId: "message",
            value: .flagged(false)
        )
        let accountB = MessageIdentity.recentlyCompletedFieldValueKey(
            accountId: "account",
            messageId: "A:message",
            value: .flagged(false)
        )
        let folderA = MessageIdentity.recentlyCompletedFieldValueKey(
            accountId: "account",
            folderPath: "Folder:A",
            messageId: "message",
            value: .actionTag(ActionTag.archive.rawValue)
        )
        let folderB = MessageIdentity.recentlyCompletedFieldValueKey(
            accountId: "account",
            folderPath: "Folder",
            messageId: "A:message",
            value: .actionTag(ActionTag.archive.rawValue)
        )

        #expect(accountA != accountB)
        #expect(folderA != folderB)
        #expect(accountA != folderA)
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
