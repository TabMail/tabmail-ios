/* This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at https://mozilla.org/MPL/2.0/. */

import SwiftUI

/// What the "Reply to" sheet holds: the newest email's people, all ticked for Reply
/// All, and anyone added, ticked. Done turns it into the chat's `ChatReplyTarget`.
struct ChatReplyToChoice: Equatable {
    private(set) var people: [ChatThread.Person]
    private(set) var ticked: Set<String>

    init(replyPeople: [ChatThread.Person], target: ChatReplyTarget) {
        let known = Set(replyPeople.map(\.address))
        people = replyPeople + (target.only ?? []).filter { !known.contains($0.address) }
        ticked = Set((target.only ?? replyPeople).map(\.address))
    }

    func isTicked(_ person: ChatThread.Person) -> Bool { ticked.contains(person.address) }

    mutating func toggle(_ person: ChatThread.Person) {
        if ticked.remove(person.address) == nil { ticked.insert(person.address) }
    }

    /// Adds the address in `text` (a contact pick, or a typed address), ticked. Nothing for text
    /// that names no address or names the user. Returns whether someone was added or ticked.
    @discardableResult
    mutating func add(_ text: String, name: String? = nil, ownAddresses: Set<String>) -> Bool {
        guard let recipient = RecipientEntry(text).recipients.first else { return false }
        let address = recipient.address.lowercased()
        guard !ownAddresses.contains(address) else { return false }
        if !people.contains(where: { $0.address == address }) {
            let shownName = [name, recipient.name].compactMap { $0 }.first { !$0.isEmpty }
            people.append(ChatThread.Person(address: address, name: shownName ?? ChatThread.fallbackName(address)))
        }
        ticked.insert(address)
        return true
    }

    /// The people of `recent` not in the list yet: the ones a Recent row offers to add.
    func unlisted(_ recent: [ChatThread.Person]) -> [ChatThread.Person] {
        let listed = Set(people.map(\.address))
        return recent.filter { !listed.contains($0.address) }
    }

    /// Done needs someone to reply to.
    var canFinish: Bool { !ticked.isEmpty }

    func target(replyPeople: [ChatThread.Person]) -> ChatReplyTarget {
        ChatReplyTarget.chosen(people.filter { ticked.contains($0.address) }, replyPeople: replyPeople)
    }
}

/// "Reply to", from the bottom when the chat header's names are tapped. A new email's chat opens it
/// as "Add recipient", starting with the people already picked (none at first), with a Recent
/// section of the people the user recently sent email to.
struct ChatReplyToSheet: View {
    let replyPeople: [ChatThread.Person]
    let ownAddresses: Set<String>
    let title: String
    /// The recent people, read as the sheet opens (`ChatRecentPeople`); nil: no Recent section.
    let recentPeople: (@MainActor () async -> [ChatThread.Person])?
    let onDone: (ChatReplyTarget) -> Void

    @State private var choice: ChatReplyToChoice
    @State private var recent: [ChatThread.Person] = []
    @State private var query = ""
    @State private var contactSearch = ContactSearchService()
    @FocusState private var queryFocused: Bool
    @Environment(\.dismiss) private var dismiss

    static let replyToTitle = "Reply to"
    static let addRecipientTitle = "Add recipient"
    static let recentTitle = "Recent"
    /// A row of the list, and a Recent row, as tests find them.
    static let personId = "chatReplyToPerson"
    static let recentId = "chatRecentPerson"

    init(replyPeople: [ChatThread.Person], target: ChatReplyTarget, ownAddresses: Set<String>,
         title: String = Self.replyToTitle, recentPeople: (@MainActor () async -> [ChatThread.Person])? = nil,
         onDone: @escaping (ChatReplyTarget) -> Void) {
        self.replyPeople = replyPeople
        self.ownAddresses = ownAddresses
        self.title = title
        self.recentPeople = recentPeople
        self.onDone = onDone
        self._choice = State(initialValue: ChatReplyToChoice(replyPeople: replyPeople, target: target))
    }

    var body: some View {
        NavigationStack {
            List {
                Section {
                    ForEach(choice.people, id: \.address) { person in
                        Button { choice.toggle(person) } label: { row(person) }
                            .buttonStyle(.plain)
                            .accessibilityAddTraits(choice.isTicked(person) ? .isSelected : [])
                            .accessibilityIdentifier(Self.personId)
                    }
                }
                Section("Add someone") {
                    TextField("Name or email", text: $query)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .keyboardType(.emailAddress)
                        .focused($queryFocused)
                        .onSubmit { addTyped() }
                    ForEach(contactSearch.search(query)) { contact in
                        Button { pick(contact.email, name: contact.name) } label: {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(contact.name.isEmpty ? contact.email : contact.name)
                                    .foregroundStyle(Theme.textPrimary)
                                if !contact.name.isEmpty {
                                    Text(contact.email).font(.caption).foregroundStyle(Theme.textSecondary)
                                }
                            }
                        }
                    }
                }
                // Someone recent who is not in the list yet: a tap adds them there, ticked, as a
                // search result does.
                let recentToAdd = choice.unlisted(recent)
                if !recentToAdd.isEmpty {
                    Section(Self.recentTitle) {
                        ForEach(recentToAdd, id: \.address) { person in
                            Button { pick(person.address, name: person.name) } label: { row(person) }
                                .buttonStyle(.plain)
                                .accessibilityIdentifier(Self.recentId)
                        }
                    }
                }
            }
            .navigationTitle(title)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") {
                        addTyped()
                        guard choice.canFinish else { return }
                        onDone(choice.target(replyPeople: replyPeople))
                        dismiss()
                    }
                    .disabled(!choice.canFinish && query.isEmpty)
                }
            }
            .task {
                if let recentPeople { recent = await recentPeople() }
            }
            .onAppear { contactSearch.requestAccess() }
        }
        .dismissKeyboardOnTap()
        .presentationDetents([.medium, .large])
        .presentationDragIndicator(.visible)
    }

    private func addTyped() {
        if choice.add(query, ownAddresses: ownAddresses) { query = "" }
    }

    /// A search result or a Recent row: added, ticked, and the search cleared, so Done does not
    /// add the typed text as well.
    private func pick(_ address: String, name: String) {
        choice.add(address, name: name, ownAddresses: ownAddresses)
        query = ""
    }

    private func row(_ person: ChatThread.Person) -> some View {
        HStack(spacing: 12) {
            ChatAvatar(person: person, size: ChatViewLayout.avatarSize)
            VStack(alignment: .leading, spacing: 2) {
                Text(person.name).foregroundStyle(Theme.textPrimary)
                Text(person.address).font(.caption).foregroundStyle(Theme.textSecondary)
            }
            Spacer(minLength: 0)
            Image(systemName: choice.isTicked(person) ? "checkmark.circle.fill" : "circle")
                .font(.title3)
                .foregroundStyle(choice.isTicked(person) ? Theme.accent : Theme.textSecondary)
        }
        .contentShape(Rectangle())
        .accessibilityElement(children: .combine)
    }
}

/// The full list behind a "+N" (the "Replying only to" chips, a "replied only to" label).
struct ChatPeopleList: View {
    let title: String
    let names: [String]

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title).font(.subheadline.weight(.semibold))
            ForEach(Array(names.enumerated()), id: \.offset) { _, name in
                Text(name).font(.subheadline)
            }
        }
        .padding()
        .presentationCompactAdaptation(.popover)
    }
}
