/* This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at https://mozilla.org/MPL/2.0/. */

import SwiftMail
import SwiftUI
import UIKit

/// "Copy Address" on a person: a long press on a sender, a recipient, a compose recipient or a chat
/// avatar opens the standard iOS menu, and its item puts the person's bare address
/// (`name@example.com`) on the clipboard, never their display name. Every place offers it the same
/// way: `copyAddressMenu(_:)`, or `CopyAddressMenu` for a line inside a `List` row that shows more
/// than that person (the email view's cards).
enum AddressCopy {
    static let title = "Copy Address"
    static let systemImage = "doc.on.doc"

    /// One person the menu offers: the name shown for them (their address when they have none) and
    /// the address it copies.
    struct Entry: Equatable {
        let name: String
        let address: String
    }

    /// One item of the menu: what it says, and the address it copies.
    struct Item: Equatable {
        let title: String
        let subtitle: String?
        let address: String
    }

    /// Everyone the address fields name, in order, each once: header values such as
    /// `"Doe, John" <john@example.com>, jane@example.com`, read with SwiftMail's parser as the
    /// email view's names are (`MessageViewHelpers.extractNames`); a group gives its members. Text
    /// that names no mailbox gives nobody.
    static func entries(in fields: [String]) -> [Entry] {
        var seen = Set<String>()
        return fields
            .flatMap { AddressParser.parseAddressList($0).flatMap(\.mailboxes) }
            .filter { seen.insert($0.address.lowercased()).inserted }
            .map { mailbox in
                let name = mailbox.name.flatMap { $0.isEmpty ? nil : $0 } ?? mailbox.address
                return Entry(name: name, address: mailbox.address)
            }
    }

    /// A message's sender: the name the email view shows and the sender's address. Nobody when the
    /// message has no sender address.
    static func sender(name: String, address: String) -> [Entry] {
        guard !address.isEmpty else { return [] }
        return [Entry(name: name.isEmpty ? address : name, address: address)]
    }

    /// One person shown by `name`, whose address comes from an address field: the bare address the
    /// value names, read with the same parser as `entries(in:)`, so a value kept as written
    /// (`support team <support@localhost>`) copies `support@localhost`. Shown by that address when
    /// `name` is empty; nobody when the value names no address.
    static func named(_ name: String, address: String) -> [Entry] {
        guard let mailbox = entries(in: [address]).first else { return [] }
        return [Entry(name: name.isEmpty ? mailbox.address : name, address: mailbox.address)]
    }

    /// A chat person (`ChatThread.Person`). Their address is usually bare, but the reply list keeps
    /// each entry it cannot send to as written (`RecipientEntry.leftovers`, through
    /// `buildReplyAllRecipients`), so it is read through `named(_:address:)`.
    static func person(_ person: ChatThread.Person) -> [Entry] {
        named(person.name, address: person.address)
    }

    /// A compose recipient: the chip's address (a field holds addresses only, ADR-IOS-092) and the
    /// name the chip shows for it.
    static func recipient(_ token: String, displayNames: [String: String]) -> [Entry] {
        sender(name: displayNames[token] ?? token, address: token)
    }

    /// The menu's items. One person: one "Copy Address" item. Several (a To line): one item per
    /// person, titled with their name and the address under it, below a "Copy Address" heading
    /// (`heading(_:)`).
    static func items(_ entries: [Entry]) -> [Item] {
        if entries.count == 1, let entry = entries.first {
            return [Item(title: title, subtitle: nil, address: entry.address)]
        }
        return entries.map { Item(title: $0.name, subtitle: $0.name == $0.address ? nil : $0.address, address: $0.address) }
    }

    /// The heading over several people's items; nil for one person.
    static func heading(_ entries: [Entry]) -> String? {
        entries.count > 1 ? title : nil
    }

    /// VoiceOver's named action for one person whose menu is on a view it does not reach (a chat
    /// avatar): "Copy Ann Lee's Address", and the item it copies. Nil unless exactly one person.
    static func accessibilityAction(_ entries: [Entry]) -> (title: String, item: Item)? {
        guard entries.count == 1, let entry = entries.first, let item = items(entries).first else { return nil }
        return ("Copy \(entry.name)'s Address", item)
    }

    /// Puts `item`'s address on the clipboard: what every item of the menu does.
    @MainActor
    static func copy(_ item: Item, to pasteboard: UIPasteboard = .general) {
        pasteboard.string = item.address
    }
}

/// The menu's items for `entries` (`AddressCopy.items`).
struct CopyAddressMenuItems: View {
    let entries: [AddressCopy.Entry]

    var body: some View {
        let items = AddressCopy.items(entries)
        if let heading = AddressCopy.heading(entries) {
            // `SwiftUI.` because SwiftMail also declares a `Section`.
            SwiftUI.Section(heading) {
                ForEach(Array(items.enumerated()), id: \.offset) { _, item in
                    Button { AddressCopy.copy(item) } label: {
                        Text(item.title)
                        if let subtitle = item.subtitle { Text(subtitle) }
                    }
                }
            }
        } else if let item = items.first {
            Button(item.title, systemImage: AddressCopy.systemImage) { AddressCopy.copy(item) }
        }
    }
}

extension View {
    /// A long press opens the standard menu with "Copy Address" for `entries`; nothing for nobody.
    /// Inside a `List` row a context menu belongs to the whole row: fine for a row that is one
    /// person (the reply sheet's), but a line in a row that shows more uses `CopyAddressMenu`.
    func copyAddressMenu(_ entries: [AddressCopy.Entry]) -> some View {
        contextMenu { if !entries.isEmpty { CopyAddressMenuItems(entries: entries) } }
    }
}

/// `label` with the "Copy Address" menu on a long press, for a view inside a `List` row (the email
/// view's cards): a context menu there would belong to the whole row, so this is a `Menu`, as the
/// card's subject and labels are, and a tap runs `primaryAction`, what a tap on the label did
/// before. For nobody it is the label alone.
struct CopyAddressMenu<Label: View>: View {
    let entries: [AddressCopy.Entry]
    let primaryAction: @MainActor () -> Void
    @ViewBuilder let label: () -> Label

    var body: some View {
        if entries.isEmpty {
            label()
        } else {
            Menu {
                CopyAddressMenuItems(entries: entries)
            } label: {
                // A menu's label centres wrapped lines; a header line keeps them at the leading edge,
                // as the card's subject does.
                label()
                    .multilineTextAlignment(.leading)
            } primaryAction: {
                primaryAction()
            }
        }
    }
}
