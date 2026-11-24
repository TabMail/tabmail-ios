/* This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at https://mozilla.org/MPL/2.0/. */

import Foundation
import Testing
import UIKit
@testable import TabMail

/// "Copy Address" (`AddressCopy`): a long press on a person copies their bare address, never the
/// display name, and every place that shows a person offers it with that person's address: the
/// email view's sender, To, Cc and Bcc, a compose recipient, and in the chat view the avatars and
/// the people and searched contacts of the "Reply to" / "Add recipient" sheet.
@MainActor
@Suite("Copy Address copies the person's bare address")
struct CopyAddressTests {
    typealias Entry = AddressCopy.Entry

    // MARK: - The bare address

    @Test("A plain address is offered as itself")
    func plainAddress() {
        let entries = AddressCopy.entries(in: ["name@example.com"])
        #expect(entries == [Entry(name: "name@example.com", address: "name@example.com")])
    }

    @Test("A named address is offered by its name and copies the address alone")
    func namedAddress() {
        let entries = AddressCopy.entries(in: ["Name <name@example.com>"])
        #expect(entries == [Entry(name: "Name", address: "name@example.com")])
    }

    @Test("A quoted name holding a comma copies the address alone")
    func quotedNameWithComma() {
        let entries = AddressCopy.entries(in: ["\"Doe, John\" <john@example.com>"])
        #expect(entries == [Entry(name: "Doe, John", address: "john@example.com")])
    }

    @Test("A quoted name that looks like an address copies the address in the angle brackets")
    func quotedNameHoldingAnAddress() {
        let addresses = AddressCopy.entries(in: ["\"Ann <ann@example.com>\" <real@example.com>"]).map(\.address)
        #expect(addresses == ["real@example.com"])
    }

    @Test("White space around a person is not part of the address")
    func whiteSpaceAround() {
        let addresses = AddressCopy.entries(in: ["  ann@example.com  ,   Bob   <bob@example.com>  "]).map(\.address)
        #expect(addresses == ["ann@example.com", "bob@example.com"])
    }

    @Test("Text that names no address offers nobody")
    func noAddress() {
        let junk = AddressCopy.entries(in: ["not an address"])
        let emptyGroup = AddressCopy.entries(in: ["undisclosed-recipients:;"])
        let empty = AddressCopy.entries(in: [""])
        #expect(junk.isEmpty)
        #expect(emptyGroup.isEmpty)
        #expect(empty.isEmpty)
    }

    // MARK: - Everyone a field names

    @Test("Each person of a list, in order, with the name shown for them")
    func listEntries() {
        let entries = AddressCopy.entries(in: ["\"Doe, John\" <john@example.com>, jane@example.com, Bob <bob@example.com>"])
        let expected = [
            Entry(name: "Doe, John", address: "john@example.com"),
            Entry(name: "jane@example.com", address: "jane@example.com"),
            Entry(name: "Bob", address: "bob@example.com"),
        ]
        #expect(entries == expected)
    }

    @Test("A group gives its members")
    func groupMembers() {
        let entries = AddressCopy.entries(in: ["Team: a@example.com, Bee <b@example.com>;"])
        let expected = [
            Entry(name: "a@example.com", address: "a@example.com"),
            Entry(name: "Bee", address: "b@example.com"),
        ]
        #expect(entries == expected)
    }

    @Test("A person in two fields is offered once, as first listed")
    func duplicatesAcrossFields() {
        let entries = AddressCopy.entries(in: ["Ann <ann@example.com>", "ANN@example.com, bob@example.com"])
        let addresses = entries.map(\.address)
        #expect(addresses == ["ann@example.com", "bob@example.com"])
    }

    // MARK: - The menu

    @Test("One person: one Copy Address item, no heading")
    func onePersonItem() {
        let entries = [Entry(name: "Ann Lee", address: "ann@example.com")]
        let items = AddressCopy.items(entries)
        let heading = AddressCopy.heading(entries)
        #expect(items == [AddressCopy.Item(title: AddressCopy.title, subtitle: nil, address: "ann@example.com")])
        #expect(heading == nil)
    }

    @Test("Several people: one item each, by name with the address under it, below a Copy Address heading")
    func severalPeopleItems() {
        let entries = [
            Entry(name: "Ann Lee", address: "ann@example.com"),
            Entry(name: "bob@example.com", address: "bob@example.com"),
        ]
        let items = AddressCopy.items(entries)
        let heading = AddressCopy.heading(entries)
        let expected = [
            AddressCopy.Item(title: "Ann Lee", subtitle: "ann@example.com", address: "ann@example.com"),
            AddressCopy.Item(title: "bob@example.com", subtitle: nil, address: "bob@example.com"),
        ]
        #expect(items == expected)
        #expect(heading == AddressCopy.title)
    }

    @Test("Nobody: no items")
    func nobody() {
        let items = AddressCopy.items([])
        let heading = AddressCopy.heading([])
        #expect(items.isEmpty)
        #expect(heading == nil)
    }

    @Test("An item puts its person's bare address on the clipboard, never the title it shows")
    func copyWritesTheAddress() throws {
        let name = UIPasteboard.Name("copy-address-tests-\(UUID().uuidString)")
        let pasteboard = try #require(UIPasteboard(name: name, create: true))
        defer { UIPasteboard.remove(withName: name) }
        let one = AddressCopy.items([Entry(name: "Ann Lee", address: "ann@example.com")])
        let several = AddressCopy.items(AddressCopy.entries(in: ["\"Doe, John\" <john@example.com>, jane@example.com"]))
        #expect(one.count == 1)
        #expect(several.count == 2)
        guard let oneItem = one.first, several.count == 2 else { return }
        let firstOfSeveral = several[0]
        AddressCopy.copy(oneItem, to: pasteboard)
        let copiedOne = pasteboard.string
        AddressCopy.copy(firstOfSeveral, to: pasteboard)
        let copiedFirst = pasteboard.string
        #expect(oneItem.title == AddressCopy.title)
        #expect(copiedOne == "ann@example.com")
        #expect(firstOfSeveral.title == "Doe, John")
        #expect(copiedFirst == "john@example.com")
    }

    @Test("VoiceOver: one person gets a named Copy Address action that copies their item; nobody or several get none")
    func accessibilityAction() {
        let ann = [Entry(name: "Ann Lee", address: "ann@example.com")]
        let several = ann + [Entry(name: "bob@example.com", address: "bob@example.com")]
        let action = AddressCopy.accessibilityAction(ann)
        let title = action?.title
        let item = action?.item
        let nobodyTitle = AddressCopy.accessibilityAction([])?.title
        let severalTitle = AddressCopy.accessibilityAction(several)?.title
        #expect(title == "Copy Ann Lee's Address")
        #expect(item == AddressCopy.Item(title: AddressCopy.title, subtitle: nil, address: "ann@example.com"))
        #expect(nobodyTitle == nil)
        #expect(severalTitle == nil)
    }

    // MARK: - Each place, with the right person

    private static func message() -> MessageHeader {
        var header = MessageHeader(
            messageId: "100",
            subject: "Plans",
            from: "Ann Lee",
            fromAddress: "ann@example.com",
            to: "\"Doe, John\" <john@example.com>, jane@example.com",
            date: Date(),
            snippet: "",
            folderId: "acc1:INBOX",
            accountId: "acc1",
            folderPath: "INBOX",
            isInInbox: true)
        header.cc = "Bob <bob@example.com>, JANE@example.com"
        header.bcc = "carol@example.com"
        return header
    }

    @Test("Email view: the sender's lines offer the sender's address")
    func emailViewSender() {
        let entries = MessageCardView.copyEntries(.sender, of: Self.message())
        #expect(entries == [Entry(name: "Ann Lee", address: "ann@example.com")])
    }

    @Test("Email view: a sender with no name is offered by address; no sender address offers nothing")
    func emailViewSenderEdges() {
        var unnamed = Self.message()
        unnamed.from = ""
        var noAddress = Self.message()
        noAddress.fromAddress = ""
        let unnamedEntries = MessageCardView.copyEntries(.sender, of: unnamed)
        let noAddressEntries = MessageCardView.copyEntries(.sender, of: noAddress)
        #expect(unnamedEntries == [Entry(name: "ann@example.com", address: "ann@example.com")])
        #expect(noAddressEntries.isEmpty)
    }

    @Test("Email view: the To, Cc and Bcc lines offer their own people")
    func emailViewRecipientLines() {
        let message = Self.message()
        let to = MessageCardView.copyEntries(.to, of: message).map(\.address)
        let cc = MessageCardView.copyEntries(.cc, of: message).map(\.address)
        let bcc = MessageCardView.copyEntries(.bcc, of: message).map(\.address)
        #expect(to == ["john@example.com", "jane@example.com"])
        #expect(cc == ["bob@example.com", "JANE@example.com"])
        #expect(bcc == ["carol@example.com"])
    }

    @Test("Email view: a named To address is offered by its name and copies the address alone")
    func emailViewNamedTo() {
        var message = Self.message()
        message.to = "Name <name@example.com>"
        let entries = MessageCardView.copyEntries(.to, of: message)
        let copied = AddressCopy.items(entries).map(\.address)
        #expect(entries == [Entry(name: "Name", address: "name@example.com")])
        #expect(copied == ["name@example.com"])
    }

    @Test("Email view: the short recipient line offers everyone it names, each once")
    func emailViewShortLine() {
        let addresses = MessageCardView.copyEntries(.recipients, of: Self.message()).map(\.address)
        #expect(addresses == ["john@example.com", "jane@example.com", "bob@example.com", "carol@example.com"])
    }

    @Test("Compose: a recipient offers its own address, under the name its chip shows")
    func composeRecipient() {
        let named = AddressCopy.recipient("bob@example.com", displayNames: ["bob@example.com": "Bob Stone"])
        let unnamed = AddressCopy.recipient("carol@example.com", displayNames: ["bob@example.com": "Bob Stone"])
        #expect(named == [Entry(name: "Bob Stone", address: "bob@example.com")])
        #expect(unnamed == [Entry(name: "carol@example.com", address: "carol@example.com")])
    }

    @Test("Chat: a person offers their own address")
    func chatPerson() {
        let person = ChatThread.Person(address: "ann@example.com", name: "Ann Lee")
        let entries = AddressCopy.person(person)
        #expect(entries == [Entry(name: "Ann Lee", address: "ann@example.com")])
    }

    @Test("Chat: a person kept as written (a reply entry that cannot be sent to) copies the bare address")
    func chatPersonKeptAsWritten() {
        let person = ChatThread.Person(address: "support team <support@localhost>", name: "support team")
        let entries = AddressCopy.person(person)
        #expect(entries == [Entry(name: "support team", address: "support@localhost")])
    }

    @Test("Reply sheet search: a contact is offered by name, by address when it has none; no address offers nothing")
    func searchedContact() {
        let named = AddressCopy.named("Ann Lee", address: "ann@example.com")
        let unnamed = AddressCopy.named("", address: "ann@example.com")
        let noAddress = AddressCopy.named("Ann Lee", address: "not an address")
        let empty = AddressCopy.named("Ann Lee", address: "")
        #expect(named == [Entry(name: "Ann Lee", address: "ann@example.com")])
        #expect(unnamed == [Entry(name: "ann@example.com", address: "ann@example.com")])
        #expect(noAddress.isEmpty)
        #expect(empty.isEmpty)
    }

    // MARK: - Every place attaches it

    private static let projectRoot = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()
        .deletingLastPathComponent()
        .deletingLastPathComponent()

    private static func source(_ path: String) throws -> [String] {
        try String(contentsOf: projectRoot.appendingPathComponent(path), encoding: .utf8)
            .components(separatedBy: "\n")
    }

    /// The lines holding `anchor`, and how many of them have `menu` within `before` lines above or
    /// `after` lines below.
    private static func anchors(_ anchor: String, menu: String, before: Int = 0, after: Int = 0,
                                in lines: [String]) -> (found: Int, withMenu: Int) {
        var found = 0
        var withMenu = 0
        for (index, line) in lines.enumerated() where line.contains(anchor) {
            found += 1
            let window = lines[max(0, index - before)...min(lines.count - 1, index + after)]
            if window.contains(where: { $0.contains(menu) }) { withMenu += 1 }
        }
        return (found, withMenu)
    }

    /// Each anchor is how a place shows a person; every one of them must carry the menu with that
    /// person's entries, so a new place that shows them without it fails here.
    @Test("Every place that shows a person attaches Copy Address with that person", arguments: [
        ("TabMail/Views/Message/MessageCardView.swift", "Text(message.from)",
         "CopyAddressMenu(entries: Self.copyEntries(.sender, of: message)", 1, 0, 3),
        ("TabMail/Views/Message/MessageCardView.swift", "Text(message.fromAddress)",
         "CopyAddressMenu(entries: Self.copyEntries(.sender, of: message)", 1, 0, 1),
        ("TabMail/Views/Message/MessageCardView.swift", "Text(\"To: \\(message.to)\")",
         "CopyAddressMenu(entries: Self.copyEntries(.to, of: message)", 1, 0, 1),
        ("TabMail/Views/Message/MessageCardView.swift", "Text(\"Cc: \\(message.cc)\")",
         "CopyAddressMenu(entries: Self.copyEntries(.cc, of: message)", 1, 0, 1),
        ("TabMail/Views/Message/MessageCardView.swift", "Text(\"Bcc: \\(message.bcc)\")",
         "CopyAddressMenu(entries: Self.copyEntries(.bcc, of: message)", 1, 0, 1),
        ("TabMail/Views/Message/MessageCardView.swift", "Text(compressedRecipientLabel)",
         "CopyAddressMenu(entries: Self.copyEntries(.recipients, of: message)", 1, 0, 1),
        ("TabMail/Views/Chat/ChatHeaderView.swift", "ChatAvatar(person: person, size: ChatViewLayout.headerAvatarSize)",
         ".copyAddressMenu(AddressCopy.person(person))", 0, 3, 1),
        ("TabMail/Views/Chat/ChatBubbleView.swift", "ChatAvatar(person: item.sender, size: ChatViewLayout.avatarSize)",
         ".copyAddressMenu(AddressCopy.person(item.sender))", 0, 2, 1),
        ("TabMail/Views/Chat/ChatBubbleView.swift",
         "if showsSender, let copy = AddressCopy.accessibilityAction(AddressCopy.person(item.sender))",
         "Button(copy.title) { AddressCopy.copy(copy.item) }", 0, 1, 1),
        ("TabMail/Views/Chat/ChatReplyToSheet.swift", "label: { row(person) }",
         ".copyAddressMenu(AddressCopy.person(person))", 0, 2, 2),
        ("TabMail/Views/Chat/ChatReplyToSheet.swift", "Button { pick(contact.email, name: contact.name) } label: {",
         ".copyAddressMenu(AddressCopy.named(contact.name, address: contact.email))", 0, 9, 1),
    ])
    func everyPlaceAttachesIt(_ place: (String, String, String, Int, Int, Int)) throws {
        let (path, anchor, menu, before, after, expected) = place
        let lines = try Self.source(path)
        let result = Self.anchors(anchor, menu: menu, before: before, after: after, in: lines)
        #expect(result.found == expected, "\(path): \(anchor)")
        #expect(result.withMenu == result.found, "\(path): \(anchor)")
    }

    @Test("Compose: each recipient chip attaches Copy Address with its own address; a rejected entry does not")
    func composeChipAttachesIt() throws {
        let text = try Self.source("TabMail/Views/Compose/ComposeView.swift").joined(separator: "\n")
        let menu = ".copyAddressMenu(AddressCopy.recipient(token, displayNames: displayNames))"
        let chip = try #require(text.range(of: "private func tokenChip(_ token: String)"))
        let rejected = try #require(text.range(of: "private func rejectedChip(_ index: Int)"))
        let commit = try #require(text.range(of: "private func commitInput()"))
        let chipBody = text[chip.upperBound..<rejected.lowerBound]
        let rejectedBody = text[rejected.upperBound..<commit.lowerBound]
        let chipCount = chipBody.components(separatedBy: menu).count - 1
        let rejectedHasMenu = rejectedBody.contains(".copyAddressMenu(")
        #expect(chipCount == 1)
        #expect(!rejectedHasMenu)
    }

    /// The menu views: a context menu only when someone is offered; the `List`-row menu is the label
    /// alone for nobody, and a tap on it runs `primaryAction`; every item copies its own item. Read
    /// with white space collapsed, so formatting does not matter.
    @Test("The menu views: every item copies its own address, and the row menu keeps the tap")
    func menuViewsWireTheCopy() throws {
        let text = try Self.source("TabMail/Views/Components/CopyAddressMenu.swift")
            .joined(separator: " ")
            .split(whereSeparator: \.isWhitespace)
            .joined(separator: " ")
        let wiring = [
            "contextMenu { if !entries.isEmpty { CopyAddressMenuItems(entries: entries) } }",
            "if entries.isEmpty { label() } else { Menu { CopyAddressMenuItems(entries: entries) } label: {",
            "} primaryAction: { primaryAction() }",
            #"SwiftUI.Section(heading) { ForEach(Array(items.enumerated()), id: \.offset) { _, item in Button { AddressCopy.copy(item) } label: {"#,
            "Button(item.title, systemImage: AddressCopy.systemImage) { AddressCopy.copy(item) }",
        ]
        let missing = wiring.filter { !text.contains($0) }
        #expect(missing.isEmpty)
    }

    /// Each line of the email view's card keeps the tap it had before the menu: in the closed card
    /// the sender and the recipient line open the card; in the open card each header line shows more
    /// or fewer details.
    @Test("Email view: each line's menu keeps that line's tap")
    func emailViewLinesKeepTheirTap() throws {
        let text = try Self.source("TabMail/Views/Message/MessageCardView.swift").joined(separator: "\n")
        let menu = "CopyAddressMenu(entries: Self.copyEntries("
        let lines = [
            ".sender, of: message), primaryAction: { toggleExpanded() })",
            ".sender, of: message), primaryAction: { toggleHeader() })",
            ".to, of: message), primaryAction: { toggleHeader() })",
            ".cc, of: message), primaryAction: { toggleHeader() })",
            ".bcc, of: message), primaryAction: { toggleHeader() })",
            ".recipients, of: message), primaryAction: onTap)",
        ]
        let found = lines.map { text.components(separatedBy: menu + $0).count - 1 }
        let menus = text.components(separatedBy: menu).count - 1
        let closedCardTap = text.components(separatedBy: "tagRow(onTap: { toggleExpanded() })").count - 1
        let openCardTap = text.components(separatedBy: "tagRow(onTap: { toggleHeader() })").count - 1
        #expect(found == [1, 3, 1, 1, 1, 1])
        #expect(menus == 8)
        #expect(closedCardTap == 1)
        #expect(openCardTap == 1)
    }
}
