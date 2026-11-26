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

    // MARK: - normalizeSubject (the strip both lists feed)

    /// Pins the strip's behaviour from before its one prefix list was split into
    /// a reply list and a forward list: every prefix it removed, in any case,
    /// nested, with or without a space; and what it leaves.
    @Test("normalizeSubject strips exactly Re, Fwd, Fw, Aw, Sv and Vs", arguments: zip(stripInputs, stripOutputs))
    func normalizeSubjectPin(_ input: String, _ expected: String) {
        #expect(ThreadUtils.normalizeSubject(input) == expected, "normalizeSubject(\"\(input)\")")
    }

    // MARK: - hasForwardPrefix

    @Test("A subject whose first prefix is Fwd or Fw is a forward's", arguments: [
        "Fwd: Slides", "FWD: Slides", "fwd:Slides", "Fw: Slides", "FW: Slides", "fw:", "  Fwd: Slides",
        "\tFW: Slides", "Fwd: Re: Slides",
    ])
    func forwardPrefix(_ subject: String) {
        #expect(ThreadUtils.hasForwardPrefix(subject))
    }

    @Test("A reply's subject, the ambiguous Vs, localized forward prefixes and lookalikes are not a forward's", arguments: [
        "Re: Slides", "Re: Fwd: Slides", "RE: FW: Slides", "Aw: Slides", "Sv: Slides", "VS: Slides", "Vs: Slides",
        "WG: Slides", "TR: Slides", "RV: Slides", "Fwd Slides", "Fwd", "Forward: Slides", "Slides Fwd: x", "", "   ",
    ])
    func notForwardPrefix(_ subject: String) {
        #expect(!ThreadUtils.hasForwardPrefix(subject))
    }
}

/// `normalizeSubject` inputs and what it returns (file scope: a `@Test` trait
/// cannot name a static member of its own type).
private let stripCases: [(String, String)] = [
    ("Re: A", "A"), ("RE: A", "A"), ("re:A", "A"),
    ("Fwd: A", "A"), ("FWD:A", "A"), ("fwd: A", "A"),
    ("Fw: A", "A"), ("FW: A", "A"), ("fw:A", "A"),
    ("Aw: A", "A"), ("AW: A", "A"),
    ("Sv: A", "A"), ("SV: A", "A"),
    ("Vs: A", "A"), ("VS: A", "A"),
    ("Re: Fwd: Aw: Sv: Vs: Fw: A", "A"), ("Fw:Fwd:Re:A", "A"),
    ("  Fwd:   Re:  A  ", "A"), ("Re:", ""), ("", ""),
    ("Ref: A", "Ref: A"), ("Fwd A", "Fwd A"), ("Forward: A", "Forward: A"),
    ("A Re: B", "A Re: B"), ("A Fwd: B", "A Fwd: B"),
    ("WG: A", "WG: A"), ("TR: A", "TR: A"), ("RV: A", "RV: A"),
    ("Re: WG: A", "WG: A"),
]
private let stripInputs = stripCases.map(\.0)
private let stripOutputs = stripCases.map(\.1)
