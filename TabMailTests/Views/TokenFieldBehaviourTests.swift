/* This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at https://mozilla.org/MPL/2.0/. */

import Observation
import SwiftUI
import Testing
import UIKit
@testable import TabMail

/// The recipient field hosted in a window and driven through its real text
/// field: typed and pasted text, Return and leaving the field must reach the
/// recipients of the field's own role (ADR-IOS-092). The field is the one
/// `ComposeView.recipientTokenField` shows, bound to a model's recipients as
/// ComposeView binds its own.
@MainActor
@Suite("A hosted recipient field commits what is typed into it", .serialized)
struct TokenFieldBehaviourTests {
    typealias Role = ComposeDraftGuards.RecipientRole

    @Observable
    final class Model {
        var recipients = ComposeDraftGuards.Recipients(
            to: .init(tokens: ["to@example.com"]),
            cc: .init(tokens: ["cc@example.com"]),
            bcc: .init(tokens: ["bcc@example.com"]))
        var showCc = false
    }

    private struct Harness: View {
        let model: Model
        let role: Role
        @State private var revealed: String?

        var body: some View {
            @Bindable var model = model
            RecipientTokenField(
                role: role,
                recipients: $model.recipients,
                showCc: $model.showCc,
                searchResults: [],
                onFocus: {},
                revealedChipKey: $revealed)
            .frame(width: 360)
        }
    }

    private struct Hosted {
        let window: UIWindow
        let field: UITextField
    }

    private static func host(_ model: Model, role: Role) async throws -> Hosted {
        let scene = try #require(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let window = UIWindow(windowScene: scene)
        window.frame = CGRect(x: 0, y: 0, width: 390, height: 400)
        window.rootViewController = UIHostingController(rootView: Harness(model: model, role: role))
        window.isHidden = false
        window.makeKeyAndVisible()
        window.layoutIfNeeded()
        var field: UITextField?
        _ = await waitUntil { field = textField(in: window); return field != nil }
        let found = try #require(field, "the recipient field has no text field")
        found.becomeFirstResponder()
        _ = await waitUntil { found.isFirstResponder }
        return Hosted(window: window, field: found)
    }

    private static func close(_ hosted: Hosted) {
        hosted.field.resignFirstResponder()
        hosted.window.isHidden = true
        hosted.window.rootViewController = nil
    }

    private static func textField(in view: UIView) -> UITextField? {
        if let field = view as? UITextField { return field }
        for subview in view.subviews {
            if let field = textField(in: subview) { return field }
        }
        return nil
    }

    /// Polls on the main actor so SwiftUI can apply its updates; bounded so a
    /// broken binding fails an expectation instead of hanging.
    private static func waitUntil(seconds: TimeInterval = 3, _ condition: () -> Bool) async -> Bool {
        let deadline = Date().addingTimeInterval(seconds)
        while Date() < deadline {
            if condition() { return true }
            try? await Task.sleep(for: .milliseconds(20))
        }
        return condition()
    }

    /// One keystroke at a time, each fully handled (its change handler run)
    /// before the next. Keystrokes SwiftUI sees together read as one paste,
    /// which commits at once, so without this a test could pass with Return or
    /// leaving the field doing nothing.
    private static func type(_ text: String, into hosted: Hosted, model: Model, role: Role) async {
        for character in text {
            hosted.field.insertText(String(character))
            await settle(hosted)
        }
    }

    private static func settle(_ hosted: Hosted) async {
        for _ in 0..<3 {
            hosted.window.layoutIfNeeded()
            try? await Task.sleep(for: .milliseconds(15))
        }
    }

    private static let start = Model().recipients

    /// Expects every field but `role` to be as it started.
    private static func expectOthersUnchanged(_ model: Model, _ role: Role, _ label: String) {
        for other in Role.allCases where other != role {
            #expect(model.recipients[other] == start[other], "\(label): \(other) changed")
        }
    }

    @Test("A typed separator, Return and leaving the field each commit to the field's own role",
          arguments: Role.allCases)
    func typedTextIsCommitted(role: Role) async throws {
        let model = Model()
        let hosted = try await Self.host(model, role: role)
        defer { Self.close(hosted) }
        let tokens = Self.start[role].tokens

        await Self.type("ann@example.com,", into: hosted, model: model, role: role)
        #expect(await Self.waitUntil { model.recipients[role].tokens == tokens + ["ann@example.com"] },
                "separator: \(model.recipients[role])")
        #expect(model.recipients[role].input.isEmpty)

        await Self.type("bob@example.com", into: hosted, model: model, role: role)
        try? await Task.sleep(for: .milliseconds(200))
        #expect(model.recipients[role].tokens == tokens + ["ann@example.com"], "added before Return")
        #expect(model.recipients[role].input == "bob@example.com")
        // What UIKit sends when the Return key is pressed.
        hosted.field.sendActions(for: .editingDidEndOnExit)
        #expect(await Self.waitUntil { model.recipients[role].tokens == tokens + ["ann@example.com", "bob@example.com"] },
                "Return: \(model.recipients[role])")

        // Return may end editing, as it does in a single-line field.
        hosted.field.becomeFirstResponder()
        _ = await Self.waitUntil { hosted.field.isFirstResponder }
        await Self.type("nobody", into: hosted, model: model, role: role)
        try? await Task.sleep(for: .milliseconds(200))
        #expect(model.recipients[role].input == "nobody", "committed before leaving the field")
        hosted.field.resignFirstResponder()
        #expect(await Self.waitUntil { model.recipients[role].rejected == ["nobody"] },
                "leaving the field: \(model.recipients[role])")
        #expect(model.recipients[role].input.isEmpty)
        Self.expectOthersUnchanged(model, role, "typing")
        #expect(model.showCc == (role != .to), "typing: Cc and Bcc shown")
    }

    @Test("A pasted list becomes one recipient each, and text in it that is no address a rejected entry",
          arguments: Role.allCases)
    func pastedListIsSplit(role: Role) async throws {
        let model = Model()
        let hosted = try await Self.host(model, role: role)
        defer { Self.close(hosted) }
        hosted.field.insertText("a@example.com b@example.com; \"First")
        #expect(await Self.waitUntil {
            model.recipients[role].tokens == Self.start[role].tokens + ["a@example.com", "b@example.com"]
        }, "paste: \(model.recipients[role])")
        #expect(model.recipients[role].rejected == ["\"First"])
        #expect(model.recipients[role].input.isEmpty)
        Self.expectOthersUnchanged(model, role, "paste")
        #expect(model.showCc == (role != .to), "paste: Cc and Bcc shown")
    }

    // MARK: - The field's own controls

    /// The TokenField that `RecipientTokenField` builds for `role`, bound to
    /// `model`, so its callbacks and bindings are the production ones.
    private static func controls(_ model: Model, role: Role) throws -> TokenField {
        let field = RecipientTokenField(
            role: role,
            recipients: Binding(get: { model.recipients }, set: { model.recipients = $0 }),
            showCc: Binding(get: { model.showCc }, set: { model.showCc = $0 }),
            searchResults: [], onFocus: {}, revealedChipKey: .constant(nil))
        return try #require((field.body as Any) as? TokenField)
    }

    @Test("A picked contact goes to the field it was picked in, under its name", arguments: Role.allCases)
    func pickedContact(role: Role) throws {
        let model = Model()
        try Self.controls(model, role: role).onSelectContact(ContactResult(name: "Picked", email: "picked@example.com"))
        #expect(model.recipients[role].tokens == Self.start[role].tokens + ["picked@example.com"])
        #expect(model.recipients[role].displayNames["picked@example.com"] == "Picked")
        Self.expectOthersUnchanged(model, role, "pick")
        #expect(model.showCc == (role != .to))
    }

    @Test("A tapped rejected entry moves to its own field's input line", arguments: Role.allCases)
    func editedRejectedEntry(role: Role) throws {
        let model = Model()
        model.recipients[role].rejected = ["unfinished"]
        model.recipients[role].input = "typed@example.com"
        let before = model.recipients
        try Self.controls(model, role: role).onEditRejected(0)
        #expect(model.recipients[role].rejected.isEmpty)
        #expect(model.recipients[role].input == "unfinished")
        #expect(model.recipients[role].tokens == before[role].tokens + ["typed@example.com"])
        Self.expectOthersUnchanged(model, role, "edit")
    }

    @Test("Removing an address or a rejected entry changes only its own field", arguments: Role.allCases)
    func removedChips(role: Role) throws {
        let model = Model()
        model.recipients[role].rejected = ["first", "second"]
        let controls = try Self.controls(model, role: role)
        controls.tokens.removeAll()
        controls.rejected.removeFirst()
        #expect(model.recipients[role].tokens.isEmpty)
        #expect(model.recipients[role].rejected == ["second"])
        Self.expectOthersUnchanged(model, role, "remove")
    }

    // MARK: - Showing Cc and Bcc

    /// A change that leaves Cc or Bcc holding anything shows those fields, so a
    /// Bcc recipient, or a rejected entry that refuses Send, is never hidden.
    @Test("Cc and Bcc are shown whenever a change leaves something in them")
    func ccAndBccShown() {
        let empty = ComposeDraftGuards.Recipients()
        #expect(!empty.filling(to: RecipientEntry("a@example.com")).revealsCcOrBcc(comparedTo: empty))
        #expect(empty.filling(cc: RecipientEntry("a@example.com")).revealsCcOrBcc(comparedTo: empty))
        #expect(empty.filling(bcc: RecipientEntry("a@example.com")).revealsCcOrBcc(comparedTo: empty))
        #expect(empty.filling(bcc: RecipientEntry("nobody")).revealsCcOrBcc(comparedTo: empty))
        #expect(empty.committing("nobody,", typing: "", to: .bcc).revealsCcOrBcc(comparedTo: empty))
        let aiAdd = empty.applying(to: nil, cc: nil, bcc: RecipientEntryTests.delta(add: "Jane"))
        #expect(aiAdd.revealsCcOrBcc(comparedTo: empty))
        let full = empty.filling(bcc: RecipientEntry("a@example.com"))
        #expect(!full.revealsCcOrBcc(comparedTo: full))
        let cleared = full.applying(to: nil, cc: nil, bcc: RecipientEntryTests.delta(remove: "*"))
        #expect(!cleared.revealsCcOrBcc(comparedTo: full))

        // The write every change makes: it stores the change and shows Cc and
        // Bcc only when the change reveals them.
        var stored = full
        var showCc = false
        stored.replace(with: cleared, showCc: &showCc)
        #expect(stored == cleared)
        #expect(!showCc)
        stored.replace(with: full, showCc: &showCc)
        #expect(stored == full)
        #expect(showCc)
    }
}
