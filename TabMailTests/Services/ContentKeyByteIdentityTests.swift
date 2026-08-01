/* This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at https://mozilla.org/MPL/2.0/. */

import Testing
import Foundation
@testable import TabMail

/// Stage-B byte-identity pin for the `ContentKey` newtype.
///
/// The newtype is a **type-level** change only: `ContentKey.forHeader(...)`
/// must produce the exact string `MessageHeader.id` already carries, for every
/// provider space, so the whole tree can be re-typed with zero runtime effect.
/// Stage E1 is the single commit that changes the factory's body to
/// `MessageIdentity.contentKey(...)`; these tests are what will go RED then,
/// which is the intended signal — they are the ledger of "here is where the
/// runtime behaviour changed", not a permanent contract.
///
/// The invariant under test is `ContentKey.forHeader(...).rawValue ==
/// MessageHeader.id built from the same inputs` — asserted through the real
/// `MessageHeader` initializer, not against a hand-written string, so a change
/// to the header-id FORMAT can't make these vacuously pass.
@Suite("ContentKey byte identity (Stage B)")
struct ContentKeyByteIdentityTests {

    private func makeHeader(
        accountId: String,
        folderPath: String,
        providerMessageId: String,
        rfc822MessageId: String?
    ) -> MessageHeader {
        var header = MessageHeader(
            messageId: providerMessageId,
            subject: "Subject",
            from: "Sender",
            fromAddress: "sender@example.com",
            to: "recipient@example.com",
            date: Date(timeIntervalSince1970: 1_700_000_000),
            snippet: "",
            folderId: MessageIdentity.folderId(accountId: accountId, folderPath: folderPath),
            accountId: accountId,
            folderPath: folderPath,
            isInInbox: folderPath == "INBOX"
        )
        header.rfc822MessageId = rfc822MessageId
        return header
    }

    @Test("Gmail (.stableProviderId): forHeader == messageHeader.id")
    func gmailStableProviderIdMatchesHeaderId() {
        let header = makeHeader(
            accountId: "acct-gmail",
            folderPath: "INBOX",
            providerMessageId: "18f2c9a4b7d13e55",
            rfc822MessageId: "CAB=abc123@mail.example.com"
        )
        let key = ContentKey.forHeader(
            accountId: "acct-gmail",
            folderPath: "INBOX",
            providerMessageId: "18f2c9a4b7d13e55",
            rfc822MessageId: "CAB=abc123@mail.example.com",
            space: .stableProviderId
        )
        #expect(key.rawValue == header.id)
    }

    @Test("Outlook Graph (.stableProviderId): opaque folder id survives intact")
    func outlookStableProviderIdMatchesHeaderId() {
        // Graph parentFolderIds are long, opaque, and contain '=' — they must be
        // embedded verbatim, exactly as `MessageIdentity.headerId` does.
        let graphFolder = "AQMkADAwATE2MTQwLTk2YTQtNjViMy0wMAItMDAKAC4AAAA="
        let header = makeHeader(
            accountId: "acct-outlook",
            folderPath: graphFolder,
            providerMessageId: "AAMkAGI2TG93AAA=",
            rfc822MessageId: "outlook-msg-1@example.com"
        )
        let key = ContentKey.forHeader(
            accountId: "acct-outlook",
            folderPath: graphFolder,
            providerMessageId: "AAMkAGI2TG93AAA=",
            rfc822MessageId: "outlook-msg-1@example.com",
            space: .stableProviderId
        )
        #expect(key.rawValue == header.id)
    }

    /// The load-bearing case. Under `.uidAddressed`, Stage E1 will prefer the
    /// RFC 822 Message-ID tail — so this is the assertion that proves Stage B
    /// has NOT started doing that yet. If this ever goes green by accident
    /// (e.g. the factory started reading `rfc822MessageId`), the key would be
    /// `acct-imap:INBOX:imap-msg-1@example.com`, not `…:4471`.
    @Test("IMAP (.uidAddressed): forHeader still == messageHeader.id, RFC id UNUSED")
    func imapUidAddressedStillMatchesHeaderId() {
        let header = makeHeader(
            accountId: "acct-imap",
            folderPath: "INBOX",
            providerMessageId: "4471",
            rfc822MessageId: "imap-msg-1@example.com"
        )
        let key = ContentKey.forHeader(
            accountId: "acct-imap",
            folderPath: "INBOX",
            providerMessageId: "4471",
            rfc822MessageId: "imap-msg-1@example.com",
            space: .uidAddressed
        )
        #expect(key.rawValue == header.id)
        #expect(key.rawValue == "acct-imap:INBOX:4471")
        // Explicitly NOT the RFC-tailed key Stage E1 will mint.
        #expect(key.rawValue != MessageIdentity.contentKey(
            accountId: "acct-imap",
            folderPath: "INBOX",
            providerMessageId: "4471",
            rfc822MessageId: "imap-msg-1@example.com",
            space: .uidAddressed
        ))
    }

    @Test("iCloud (.uidAddressed) with no RFC id: forHeader == messageHeader.id")
    func icloudUidAddressedWithoutRfcIdMatchesHeaderId() {
        let header = makeHeader(
            accountId: "acct-icloud",
            folderPath: "Archive",
            providerMessageId: "90210",
            rfc822MessageId: nil
        )
        let key = ContentKey.forHeader(
            accountId: "acct-icloud",
            folderPath: "Archive",
            providerMessageId: "90210",
            rfc822MessageId: nil,
            space: .uidAddressed
        )
        #expect(key.rawValue == header.id)
    }

    @Test("The space argument does not change the Stage-B result")
    func spaceIsInertAtStageB() {
        // Same inputs, both spaces — identical output is the whole point of the
        // stage. This is the single assertion that fails FIRST at E1.
        let stable = ContentKey.forHeader(
            accountId: "acct", folderPath: "INBOX", providerMessageId: "77",
            rfc822MessageId: "rfc-77@example.com", space: .stableProviderId
        )
        let uid = ContentKey.forHeader(
            accountId: "acct", folderPath: "INBOX", providerMessageId: "77",
            rfc822MessageId: "rfc-77@example.com", space: .uidAddressed
        )
        #expect(stable == uid)
        #expect(stable.rawValue == "acct:INBOX:77")
    }

    @Test("ContentKey round-trips through its raw string")
    func rawValueRoundTrip() {
        let key = ContentKey.forHeader(
            accountId: "acct", folderPath: "INBOX", providerMessageId: "5",
            rfc822MessageId: nil, space: .uidAddressed
        )
        #expect(ContentKey(rawValue: key.rawValue) == key)
        #expect(key.description == key.rawValue)
    }
}
