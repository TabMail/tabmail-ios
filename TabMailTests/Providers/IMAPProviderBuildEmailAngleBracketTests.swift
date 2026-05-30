/* This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at https://mozilla.org/MPL/2.0/. */

import Testing
import Foundation
@testable import TabMail
import SwiftMail

@Suite("IMAPProvider.buildEmail — RFC 2822 angle bracket normalization")
struct IMAPProviderBuildEmailAngleBracketTests {

    // MARK: - In-Reply-To angle bracket normalization

    @Test("In-Reply-To wraps bare message ID in angle brackets")
    func inReplyToBareId() {
        let draft = DraftMessage(
            to: ["to@test.com"],
            subject: "Re: Hello",
            body: "Reply body",
            inReplyTo: "original-msg-id@example.com"
        )
        let email = IMAPProvider.buildEmail(from: draft, senderEmail: "me@test.com")
        #expect(email.additionalHeaders?["In-Reply-To"] == "<original-msg-id@example.com>")
    }

    @Test("In-Reply-To preserves already-bracketed message ID")
    func inReplyToAlreadyBracketed() {
        let draft = DraftMessage(
            to: ["to@test.com"],
            subject: "Re: Hello",
            body: "Reply body",
            inReplyTo: "<already-bracketed@example.com>"
        )
        let email = IMAPProvider.buildEmail(from: draft, senderEmail: "me@test.com")
        #expect(email.additionalHeaders?["In-Reply-To"] == "<already-bracketed@example.com>")
    }

    @Test("In-Reply-To skipped for empty string")
    func inReplyToEmpty() {
        let draft = DraftMessage(
            to: ["to@test.com"],
            subject: "Re: Hello",
            inReplyTo: ""
        )
        let email = IMAPProvider.buildEmail(from: draft, senderEmail: "me@test.com")
        #expect(email.additionalHeaders?["In-Reply-To"] == nil)
    }

    // MARK: - References angle bracket normalization

    @Test("References wraps bare message IDs in angle brackets")
    func referencesBareIds() {
        let draft = DraftMessage(
            to: ["to@test.com"],
            subject: "Re: Thread",
            references: ["msg1@example.com", "msg2@example.com"]
        )
        let email = IMAPProvider.buildEmail(from: draft, senderEmail: "me@test.com")
        #expect(email.additionalHeaders?["References"] == "<msg1@example.com> <msg2@example.com>")
    }

    @Test("References preserves already-bracketed message IDs")
    func referencesAlreadyBracketed() {
        let draft = DraftMessage(
            to: ["to@test.com"],
            subject: "Re: Thread",
            references: ["<msg1@example.com>", "<msg2@example.com>"]
        )
        let email = IMAPProvider.buildEmail(from: draft, senderEmail: "me@test.com")
        #expect(email.additionalHeaders?["References"] == "<msg1@example.com> <msg2@example.com>")
    }

    @Test("References handles mix of bare and bracketed IDs")
    func referencesMixed() {
        let draft = DraftMessage(
            to: ["to@test.com"],
            subject: "Re: Thread",
            references: ["bare@example.com", "<bracketed@example.com>", "another-bare@test.com"]
        )
        let email = IMAPProvider.buildEmail(from: draft, senderEmail: "me@test.com")
        #expect(email.additionalHeaders?["References"] == "<bare@example.com> <bracketed@example.com> <another-bare@test.com>")
    }

    // MARK: - Combined In-Reply-To + References normalization

    @Test("Both In-Reply-To and References normalized from bare IDs")
    func bothBareIds() {
        let draft = DraftMessage(
            to: ["to@test.com"],
            subject: "Re: Thread",
            inReplyTo: "parent@example.com",
            references: ["root@example.com", "parent@example.com"]
        )
        let email = IMAPProvider.buildEmail(from: draft, senderEmail: "me@test.com")
        #expect(email.additionalHeaders?["In-Reply-To"] == "<parent@example.com>")
        #expect(email.additionalHeaders?["References"] == "<root@example.com> <parent@example.com>")
    }
}
