/* This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at https://mozilla.org/MPL/2.0/. */

import Testing
@testable import TabMail

@Suite("NSE transaction-derived push protection")
struct NSEPushProtectionTests {
    @Test("Every durable commit source contributes to stale protection")
    func everyDurableCommitSourceContributes() {
        let phase1 = NSEDataBridge.DurablePushIdentity(
            accountId: "account-phase1",
            folderPath: "INBOX",
            messageId: "provider-phase1",
            rfc822MessageId: "rfc-phase1@example.com"
        )
        let phase2 = NSEDataBridge.DurablePushIdentity(
            accountId: "account-phase2",
            folderPath: "INBOX",
            messageId: "provider-phase2",
            rfc822MessageId: nil
        )
        let verifiedSkip = NSEDataBridge.DurablePushIdentity(
            accountId: "account-skip",
            folderPath: "INBOX",
            messageId: "provider-skip",
            rfc822MessageId: "rfc-skip@example.com"
        )

        let committed = NSEDataBridge.committedPushIdentities(
            phase1: [phase1],
            phase2: [phase2],
            verifiedSkips: [verifiedSkip]
        )

        #expect(committed == Set([phase1, phase2, verifiedSkip]))
    }

    @Test("A fully rolled-back merge publishes no stale protection")
    func fullyRolledBackMergePublishesNothing() {
        let committed = NSEDataBridge.committedPushIdentities(
            phase1: [], phase2: [], verifiedSkips: []
        )

        #expect(committed.isEmpty)
        #expect(NSEDataBridge.recentPushProtectionKeys(for: committed).isEmpty)
    }

    @Test("Protection keys preserve the exact durable account and folder identities")
    func protectionKeysUseExactDurableIdentity() {
        let rfc822MessageId = "<RFC-ID@EXAMPLE.COM>"
        let identity = NSEDataBridge.DurablePushIdentity(
            accountId: "account-a",
            folderPath: "Folder:With:Separators",
            messageId: "provider:id",
            rfc822MessageId: rfc822MessageId
        )

        let keys = NSEDataBridge.recentPushProtectionKeys(for: [identity])

        #expect(keys == Set([
            MessageIdentity.recentlyCompletedPushKey(
                accountId: identity.accountId,
                folderPath: identity.folderPath,
                messageId: identity.messageId
            ),
            MessageIdentity.recentlyCompletedPushKey(
                accountId: identity.accountId,
                folderPath: identity.folderPath,
                messageId: EmailFilter.normalizeMessageId(rfc822MessageId)
            )
        ]))
    }
}
