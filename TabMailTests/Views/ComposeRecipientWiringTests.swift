/* This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at https://mozilla.org/MPL/2.0/. */

import Foundation
import Testing
@testable import TabMail

/// `ComposeDraftGuards.Recipients` keeps each role's recipients in their own
/// field (ComposeRecipientsTests), but ComposeView chooses the role at each
/// place it calls it, and a hosted SwiftUI view cannot be driven from a unit
/// test. These checks read ComposeView's source and pin each of those places to
/// its own role, so a Bcc recipient can never be passed on as To or Cc there.
@Suite("Compose view passes each recipient field its own role")
struct ComposeRecipientWiringTests {
    /// ComposeView's source with every run of whitespace made one space, so a
    /// line break or indent change does not matter.
    private static func source() throws -> String {
        let projectRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let text = try String(
            contentsOf: projectRoot.appendingPathComponent("TabMail/Views/Compose/ComposeView.swift"),
            encoding: .utf8)
        return text.split(whereSeparator: \.isWhitespace).joined(separator: " ")
    }

    private static func count(_ needle: String, in text: String) -> Int {
        text.components(separatedBy: needle).count - 1
    }

    @Test("Each recipient field is built for its own role, and the builder uses only that role")
    func fieldsUseTheirRole() throws {
        let text = try Self.source()
        for role in ["to", "cc", "bcc"] {
            #expect(Self.count("recipientTokenField(.\(role))", in: text) == 1, "\(role) field")
        }
        let start = try #require(text.range(of: "private func recipientTokenField("))
        let end = try #require(text[start.upperBound...].range(of: "private "))
        let builder = String(text[start.lowerBound..<end.lowerBound])
        #expect(Self.count("recipients[role]", in: builder) == 6)
        #expect(builder.contains("recipients.picking(contact.email, name: contact.name, to: role)"))
        #expect(builder.contains("recipients.committing(text, typing: typing, to: role)"))
        for literal in [".to", ".cc", ".bcc", "recipients.to", "recipients.cc", "recipients.bcc"] {
            #expect(!builder.contains(literal + ")") && !builder.contains(literal + "."), "builder names \(literal)")
        }
    }

    /// A SwiftUI callback cannot be driven from a unit test, so this pins that
    /// the input line's change handler splits a typed or pasted separator
    /// (`inputToSplit`, tested in RecipientEntryTests) into recipients.
    @Test("Typing or pasting a separator in a recipient field splits it into recipients")
    func inputChangeSplits() throws {
        let text = try Self.source()
        #expect(Self.count(
            ".onChange(of: input) { old, text in if let split = ComposeDraftGuards.inputToSplit(was: old, now: text) { commit(split.text, split.typing) } }",
            in: text) == 1)
    }

    /// The agent's autosave runs right after `applyInlineEdit` returns, so an AI
    /// recipient edit applied only after the text fade would be saved without it.
    @Test("An AI recipient edit is applied before the text fade, not after it")
    func aiEditAppliedAtOnce() throws {
        let text = try Self.source()
        let start = try #require(text.range(of: "private func applyInlineEdit("))
        let body = text[start.upperBound...]
        let apply = try #require(body.range(of: "setRecipients(recipients.applying(to: toDelta, cc: ccDelta, bcc: bccDelta))"))
        let fade = try #require(body.range(of: "Task { @MainActor in"))
        #expect(apply.lowerBound < fade.lowerBound)
    }

    @Test("A reopened draft, a prefill and an AI edit fill each field from its own role")
    func fillsUseTheirRole() throws {
        let text = try Self.source()
        #expect(text.contains(
            "to: RecipientEntry(draft.toArray), cc: RecipientEntry(draft.ccArray), bcc: RecipientEntry(draft.bccArray)"))
        #expect(text.contains(
            "to: prefillTo.map { RecipientEntry($0) }, cc: prefillCc.map { RecipientEntry($0) }, bcc: prefillBcc.map { RecipientEntry($0) }"))
        #expect(text.contains(
            "onDraftUpdate: { newSubject, newBody, toDelta, ccDelta, bccDelta in applyInlineEdit(subject: newSubject, body: newBody, toDelta: toDelta, ccDelta: ccDelta, bccDelta: bccDelta)"))
        #expect(text.contains("recipients.applying(to: toDelta, cc: ccDelta, bcc: bccDelta)"))
    }

    @Test("Send, Save and the agent's autosave take each field's recipients whole")
    func sendAndSaveUseTheirRole() throws {
        let text = try Self.source()
        #expect(text.contains("case .send(let to, let cc, let bcc): (finalTo, finalCc, finalBcc) = (to, cc, bcc)"))
        #expect(Self.count("to: finalTo, cc: finalCc, bcc: finalBcc,", in: text) == 2)
        #expect(Self.count("finalBcc", in: text) == 4)
        #expect(text.contains("let (capTo, capCc, capBcc) = recipients.stored"))
        #expect(text.contains(
            "e.toJSON = Draft.encodeStringArray(capTo) e.ccJSON = Draft.encodeStringArray(capCc) e.bccJSON = Draft.encodeStringArray(capBcc)"))
        #expect(text.contains(
            "toJSON: Draft.encodeStringArray(capTo), ccJSON: Draft.encodeStringArray(capCc), bccJSON: Draft.encodeStringArray(capBcc),"))
        #expect(Self.count("capBcc", in: text) == 3)
        #expect(text.contains("composeRecipients: { recipients.stored },"))
    }
}
