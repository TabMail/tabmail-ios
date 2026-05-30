/* This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at https://mozilla.org/MPL/2.0/. */

import Testing
import Foundation
@testable import TabMail

/// Covers the compose subject-prefix helpers that feed Reply / Reply-All / Forward.
/// Regression: prior inline logic used case-sensitive `hasPrefix("Re:")` / `hasPrefix("Fwd:")`,
/// producing doubled prefixes like "Re: RE: Budget" or "Fwd: Fw: Slides".
@Suite("Subject prefix formatting (reply/forward)")
struct SubjectPrefixTests {

    // MARK: - replySubject

    @Test("bare subject gets Re: prepended")
    func replyBare() {
        #expect(ThreadUtils.replySubject(for: "Budget") == "Re: Budget")
    }

    @Test("existing canonical Re: is not doubled")
    func replyCanonical() {
        #expect(ThreadUtils.replySubject(for: "Re: Budget") == "Re: Budget")
    }

    @Test("uppercase RE: is normalized, not doubled")
    func replyUppercase() {
        #expect(ThreadUtils.replySubject(for: "RE: Budget") == "Re: Budget")
    }

    @Test("lowercase re: is normalized, not doubled")
    func replyLowercase() {
        #expect(ThreadUtils.replySubject(for: "re: Budget") == "Re: Budget")
    }

    @Test("Fwd: on a reply collapses to a single Re:")
    func replyOnForward() {
        #expect(ThreadUtils.replySubject(for: "Fwd: Slides") == "Re: Slides")
    }

    @Test("Fw: (Outlook) on a reply collapses to a single Re:")
    func replyOnOutlookForward() {
        #expect(ThreadUtils.replySubject(for: "Fw: Slides") == "Re: Slides")
    }

    @Test("deeply nested mixed-case prefixes collapse")
    func replyNested() {
        #expect(ThreadUtils.replySubject(for: "RE: Fwd: re: FW: Hello") == "Re: Hello")
    }

    @Test("empty subject yields bare Re:")
    func replyEmpty() {
        #expect(ThreadUtils.replySubject(for: "") == "Re:")
    }

    @Test("whitespace-only subject yields bare Re:")
    func replyWhitespace() {
        #expect(ThreadUtils.replySubject(for: "   ") == "Re:")
    }

    @Test("Re: with no body yields bare Re:")
    func replyPrefixOnly() {
        #expect(ThreadUtils.replySubject(for: "Re:") == "Re:")
    }

    @Test("special characters in subject are preserved")
    func replySpecialChars() {
        #expect(ThreadUtils.replySubject(for: "Re: [URGENT] 🚨 Fix: bug #123")
                == "Re: [URGENT] 🚨 Fix: bug #123")
    }

    @Test("German AW: is treated as reply prefix")
    func replyGerman() {
        #expect(ThreadUtils.replySubject(for: "AW: Besprechung") == "Re: Besprechung")
    }

    // MARK: - forwardSubject

    @Test("bare subject gets Fwd: prepended")
    func forwardBare() {
        #expect(ThreadUtils.forwardSubject(for: "Slides") == "Fwd: Slides")
    }

    @Test("existing canonical Fwd: is not doubled")
    func forwardCanonical() {
        #expect(ThreadUtils.forwardSubject(for: "Fwd: Slides") == "Fwd: Slides")
    }

    @Test("Outlook Fw: is normalized to Fwd:, not doubled")
    func forwardOutlook() {
        #expect(ThreadUtils.forwardSubject(for: "Fw: Slides") == "Fwd: Slides")
    }

    @Test("uppercase FWD: is normalized, not doubled")
    func forwardUppercase() {
        #expect(ThreadUtils.forwardSubject(for: "FWD: Slides") == "Fwd: Slides")
    }

    @Test("Re: on a forward collapses to a single Fwd:")
    func forwardOnReply() {
        #expect(ThreadUtils.forwardSubject(for: "Re: Budget") == "Fwd: Budget")
    }

    @Test("empty subject yields bare Fwd:")
    func forwardEmpty() {
        #expect(ThreadUtils.forwardSubject(for: "") == "Fwd:")
    }
}
