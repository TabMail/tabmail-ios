/* This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at https://mozilla.org/MPL/2.0/. */

import Foundation
import Testing
@testable import TabMail

/// The compose's To, Cc and Bcc fields (ADR-IOS-092). Every change the compose
/// makes goes through `ComposeDraftGuards.Recipients`, so these tests check
/// that each change lands in the field it names and nowhere else: a Bcc
/// recipient that reached To or Cc would be shown to everyone the message goes to.
@Suite("Compose recipient fields keep each role's recipients")
struct ComposeRecipientsTests {
    typealias Role = ComposeDraftGuards.RecipientRole

    /// Fields that each hold their own address and text, so a change that
    /// lands in the wrong field shows.
    private static let start = ComposeDraftGuards.Recipients(
        to: .init(tokens: ["to@example.com"]),
        cc: .init(tokens: ["cc@example.com"]),
        bcc: .init(tokens: ["bcc@example.com"]))

    /// Expects `result` to differ from `start` only in `role`'s field.
    private static func expectOnly(_ role: Role, changed result: ComposeDraftGuards.Recipients,
                                   _ label: String, sourceLocation: SourceLocation = #_sourceLocation) {
        for other in Role.allCases where other != role {
            #expect(result[other] == start[other], "\(label): \(other) changed", sourceLocation: sourceLocation)
        }
        #expect(result[role] != start[role], "\(label): \(role) unchanged", sourceLocation: sourceLocation)
    }

    @Test("Each role reads and writes its own field", arguments: Role.allCases)
    func subscriptRoles(role: Role) {
        var value = Self.start
        value[role].tokens.append("new@example.com")
        Self.expectOnly(role, changed: value, "subscript")
        #expect(value[role].tokens.last == "new@example.com")
    }

    @Test("Typing, a contact pick, a fill and an AI edit change only the field they name", arguments: Role.allCases)
    func changesLandInTheirField(role: Role) {
        let typed = Self.start.committing("new@example.com,", typing: "", to: role)
        Self.expectOnly(role, changed: typed, "typing")
        #expect(typed[role].tokens.last == "new@example.com")

        let picked = Self.start.picking("new@example.com", name: "New", to: role)
        Self.expectOnly(role, changed: picked, "pick")
        #expect(picked[role].tokens.last == "new@example.com")
        #expect(picked[role].displayNames["new@example.com"] == "New")

        let entry = RecipientEntry("new@example.com, leftover")
        let filled: ComposeDraftGuards.Recipients
        switch role {
        case .to: filled = Self.start.filling(to: entry)
        case .cc: filled = Self.start.filling(cc: entry)
        case .bcc: filled = Self.start.filling(bcc: entry)
        }
        Self.expectOnly(role, changed: filled, "fill")
        #expect(filled[role].tokens == ["new@example.com"])
        #expect(filled[role].rejected == ["leftover"])
        #expect(filled[role].input.isEmpty)

        let delta = RecipientEntryTests.delta(add: "new@example.com", remove: "*")
        let edited: ComposeDraftGuards.Recipients
        switch role {
        case .to: edited = Self.start.applying(to: delta, cc: nil, bcc: nil)
        case .cc: edited = Self.start.applying(to: nil, cc: delta, bcc: nil)
        case .bcc: edited = Self.start.applying(to: nil, cc: nil, bcc: delta)
        }
        Self.expectOnly(role, changed: edited, "AI edit")
        #expect(edited[role].tokens == ["new@example.com"])
    }

    /// Text that names no address is kept as a rejected entry of the field it
    /// was given to, saved there, and refuses Send until the user edits it.
    @Test("A commit and an AI add keep text that names no address in their field, and a tap edits it",
          arguments: Role.allCases)
    func rejectedTextStaysInItsField(role: Role) {
        func stored(_ value: ComposeDraftGuards.Recipients) -> [String] {
            let all = value.stored
            return role == .to ? all.to : role == .cc ? all.cc : all.bcc
        }
        let typed = Self.start.committing("bob,", typing: "", to: role)
        Self.expectOnly(role, changed: typed, "typing")
        #expect(typed[role].tokens == Self.start[role].tokens)
        #expect(typed[role].rejected == ["bob"])
        #expect(stored(typed) == Self.start[role].tokens + ["bob"])

        let delta = RecipientEntryTests.delta(add: "Jane")
        #expect(!delta.isEmpty)
        let edited: ComposeDraftGuards.Recipients
        switch role {
        case .to: edited = Self.start.applying(to: delta, cc: nil, bcc: nil)
        case .cc: edited = Self.start.applying(to: nil, cc: delta, bcc: nil)
        case .bcc: edited = Self.start.applying(to: nil, cc: nil, bcc: delta)
        }
        Self.expectOnly(role, changed: edited, "AI add")
        #expect(edited[role].rejected == ["Jane"])
        #expect(stored(edited) == Self.start[role].tokens + ["Jane"])

        for (label, value, text) in [("typing", typed, "bob"), ("AI add", edited, "Jane")] {
            guard case .refused(let message) = value.pendingCommitted.sendRecipients else {
                Issue.record("\(label): Send was not refused")
                continue
            }
            #expect(message.contains(text), "\(label): \(message)")
        }

        let tapped = typed.editingRejected(at: 0, in: role)
        Self.expectOnly(role, changed: tapped, "tap")
        #expect(tapped[role].rejected.isEmpty)
        #expect(tapped[role].input == "bob")
        let fixed = tapped.committing("bob@example.com,", typing: "", to: role)
        #expect(fixed[role].tokens == Self.start[role].tokens + ["bob@example.com"])
        #expect(fixed[role].rejected.isEmpty)
    }

    @Test("A fill keeps display names the field already knows")
    func fillKeepsKnownNames() {
        var value = Self.start
        value.bcc.displayNames["bcc@example.com"] = "Hidden"
        let filled = value.filling(bcc: RecipientEntry(["bcc@example.com", "Other <other@example.com>"]))
        #expect(filled.bcc.displayNames == ["bcc@example.com": "Hidden", "other@example.com": "Other"])
    }

    @Test("Send and a save take each field's own recipients, input text included")
    func sendAndSaveKeepRoles() {
        var value = Self.start
        value.to.input = "to2@example.com"
        value.cc.input = "cc2@example.com"
        value.bcc.input = "bcc2@example.com"
        let stored = value.stored
        #expect(stored.to == ["to@example.com", "to2@example.com"])
        #expect(stored.cc == ["cc@example.com", "cc2@example.com"])
        #expect(stored.bcc == ["bcc@example.com", "bcc2@example.com"])
        let committed = value.pendingCommitted
        #expect(committed.sendRecipients == .send(
            to: ["to@example.com", "to2@example.com"],
            cc: ["cc@example.com", "cc2@example.com"],
            bcc: ["bcc@example.com", "bcc2@example.com"]))
        #expect(committed.stored.bcc == ["bcc@example.com", "bcc2@example.com"])
    }

    @Test("The recipient cap counts every field", arguments: Role.allCases)
    func capCountsEveryField(role: Role) {
        var value = ComposeDraftGuards.Recipients()
        let others = Role.allCases.filter { $0 != role }
        let full = (0..<(SyncConfig.outboxMaxRecipients - 1)).map { "r\($0)@example.com" }
        value[others[0]].tokens = Array(full.prefix(full.count / 2))
        value[others[1]].tokens = Array(full.dropFirst(full.count / 2))
        #expect(value.canAddMore)
        let result = value.committing("a@example.com b@example.com", typing: "", to: role)
        #expect(result[role].tokens == ["a@example.com"])
        #expect(ComposeDraftGuards.trimmedInput(result[role].input) == "b@example.com")
        #expect(result.total == SyncConfig.outboxMaxRecipients)
        #expect(!result.canAddMore)
    }

    @Test("A contact's name goes only to the fields that list its address")
    func namesOnlyListedFields() {
        var value = Self.start
        value.cc.tokens.append("bcc@example.com")
        #expect(!value.hasName(for: "bcc@example.com"))
        value.name("bcc@example.com", "Hidden")
        #expect(value.to.displayNames.isEmpty)
        #expect(value.cc.displayNames == ["bcc@example.com": "Hidden"])
        #expect(value.bcc.displayNames == ["bcc@example.com": "Hidden"])
        #expect(value.hasName(for: "bcc@example.com"))
    }
}
