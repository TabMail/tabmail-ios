/* This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at https://mozilla.org/MPL/2.0/. */

import Foundation
import GRDB
import SwiftUI
import Testing
import UIKit
@testable import TabMail

/// ADR-IOS-114 decision 9: what a bubble's controls open, in the chat opened for real in a window.
///
/// THE SYSTEM PROPERTIES pinned here:
///  1. A bubble shows at most `ChatViewLayout.attachmentChipCount` attachment chips, then one "+N"
///     chip for the rest, as the header shows its names (`ChatThread.headerTitle`).
///  2. The bubble, each of its chips and its "+N" open that email's card, never another email's.
///  3. The invite card under a bubble is that email's invite, and its button adds that invite's
///     calendar file.
///  4. A bubble that shows its sender offers VoiceOver "Copy <name>'s Address" (the avatar's menu,
///     which VoiceOver does not reach), and it puts that sender's bare address on the clipboard.
///
/// Each chip is pressed through its accessibility element, as VoiceOver presses it; the card it
/// opens is read from the sheet the chat presents. The bubble's own element takes no press in the
/// hosted harness (VoiceOver taps its activation point), and the calendar import leaves the app for
/// Safari, so those two are pinned by their exact source wiring.
@Suite("A chat bubble's controls", .serialized, .processGlobalState)
@MainActor
struct ChatBubbleActionTests {
    private static let account = "acc-chat-bubble"

    private static func rfc(_ index: Int) -> String { "<bubble-\(index)@example.com>" }

    /// The thread: e0 from Alex with seven attachments, e1 from Bo with two, e2 from Alex with an
    /// invite, oldest first; each with its own subject.
    private static let subjects = ["Budget review", "Trip notes", "Planning call"]
    private static let senders = ["Alex Doe", "Bo Lee", "Alex Doe"]

    private static func ics() -> String {
        """
        BEGIN:VCALENDAR
        VERSION:2.0
        METHOD:REQUEST
        BEGIN:VEVENT
        SUMMARY:Planning
        DTSTART:20990105T170000Z
        DTEND:20990105T180000Z
        ORGANIZER;CN=Alex Doe:mailto:alex@example.com
        ATTENDEE;CN=Bo Lee:mailto:bo@example.com
        END:VEVENT
        END:VCALENDAR
        """
    }

    private static func attachments(_ prefix: String, count: Int) throws -> String {
        let list = (1...count).map {
            AttachmentInfo(filename: "\(prefix)\($0).pdf", contentType: "application/pdf", section: "\($0 + 1)", size: 10, encoding: nil)
        }
        return String(decoding: try JSONEncoder().encode(list), as: UTF8.self)
    }

    private static func insertThread(pool: DatabasePool) throws -> [MessageHeader] {
        _ = try FolderEpochTestFixture.makeAccount(id: account, provider: .gmail, pool: pool)
        try FolderEpochTestFixture.insertFolder(accountId: account, path: "INBOX", role: .inbox, pool: pool)
        let now = Date()
        var headers: [MessageHeader] = []
        for index in 0..<subjects.count {
            let address = senders[index] == "Bo Lee" ? "bo@example.com" : "alex@example.com"
            var header = MessageHeader(
                messageId: "bubble\(index)", subject: subjects[index], from: "\(senders[index]) <\(address)>",
                fromAddress: address, to: "me@example.com",
                date: now.addingTimeInterval(TimeInterval(index - subjects.count) * 600), snippet: "Note \(index)",
                folderId: MessageIdentity.folderId(accountId: account, folderPath: "INBOX"),
                accountId: account, folderPath: "INBOX", isInInbox: true)
            header.rfc822MessageId = rfc(index)
            header.inReplyTo = index == 0 ? nil : rfc(index - 1)
            header.headerComplete = true
            header.bodyComplete = true
            header.isRead = true
            let row = header
            var body = MessageBody(contentKey: ContentKey(rawValue: row.id), htmlContent: "<p>Note \(index)</p>")
            switch index {
            case 0: body.attachmentsJSON = try attachments("budget-", count: 7)
            case 1: body.attachmentsJSON = try attachments("trip-", count: 2)
            default: body.icsText = ics()
            }
            let bodyRow = body
            try pool.write { db in
                try row.insert(db)
                try bodyRow.insert(db)
            }
            headers.append(header)
        }
        return headers
    }

    @MainActor
    struct Chat {
        let controller: UIHostingController<AnyView>
        var view: UIView { controller.view }
    }

    private func withChat(_ body: @MainActor (Chat) async throws -> Void) async throws {
        let saved = ChatSummaryQueueTests.SavedChatViewState()
        let (pool, directory, previous) = try FolderEpochTestFixture.makeAppDB()
        let queue = ActiveAIQueue.shared
        await queue.setDispatchSuppressedForTesting(true)
        await queue.clearForTesting()
        defer {
            saved.restore()
            InstalledTestDatabaseLifetime.finish(previous: previous, pool: pool, directory: directory)
        }
        saved.setChatView(on: true)
        let headers = try Self.insertThread(pool: pool)

        let scene = try #require(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let window = UIWindow(windowScene: scene)
        window.frame = CGRect(x: 0, y: 0, width: 393, height: 852)
        let controller = UIHostingController(rootView: AnyView(NavigationStack {
            ChatThreadView(messageId: headers[headers.count - 1].id)
        }.environment(NavigationStore())))
        window.rootViewController = controller
        window.makeKeyAndVisible()
        let chat = Chat(controller: controller)
        defer {
            window.isHidden = true
            window.rootViewController = nil
        }
        try await Self.waitUntil { Self.labels(chat.view).contains("Attachment trip-1.pdf") }
        do {
            try await body(chat)
        } catch {
            await queue.clearForTesting()
            await queue.setDispatchSuppressedForTesting(false)
            throw error
        }
        await queue.clearForTesting()
        await queue.setDispatchSuppressedForTesting(false)
    }

    private static func labels(_ view: UIView) -> [String] { HostedAccessibility.labels(in: view) }

    private static func element(_ label: String, in view: UIView) -> NSObject? {
        HostedAccessibility.elements(under: view).first { $0.accessibilityLabel == label }
    }

    /// The bubble of email `index`: its label names the sender and the subject (no summary yet).
    private static func bubble(_ index: Int, in view: UIView) -> NSObject? {
        HostedAccessibility.elements(under: view).first { isBubble(index, $0.accessibilityLabel ?? "") }
    }

    private static func isBubble(_ index: Int, _ label: String) -> Bool {
        label.hasPrefix(senders[index]) && label.contains(" said: \(subjects[index])")
    }

    private static func waitUntil(_ condition: @MainActor () async throws -> Bool) async throws {
        for _ in 0..<50 {
            if try await condition() { return }
            try await Task.sleep(for: .milliseconds(100))
        }
    }

    /// Presses `control` and returns the labels of the card the chat opens, then closes it.
    private static func cardLabels(pressing control: NSObject, in chat: Chat) async throws -> [String] {
        #expect(control.accessibilityActivate(), "control: the element takes a press")
        try await waitUntil { chat.controller.presentedViewController != nil }
        let card = try #require(chat.controller.presentedViewController?.view, "a card opened")
        var found: [String] = []
        try await waitUntil {
            found = labels(card)
            return found.contains { $0.contains("Note") || subjects.contains(where: $0.contains) }
        }
        chat.controller.dismiss(animated: false)
        try await waitUntil { chat.controller.presentedViewController == nil }
        return found
    }

    @Test("An email with seven attachments shows two chips and +5; one with two shows both and no + chip")
    func chipsStopAtTheCap() async throws {
        #expect(HostedAccessibility.isAvailable, "control: the test can read the hosted chat")
        #expect(ChatViewLayout.attachmentChipCount == 2)
        try await HostedAccessibility.withAutomation {
            try await withChat { chat in
                let shown = Self.labels(chat.view)
                let chips = shown.filter { $0.hasPrefix("Attachment ") }
                #expect(chips.filter { $0.contains("budget-") } == ["Attachment budget-1.pdf", "Attachment budget-2.pdf"],
                        "the first two of seven: \(chips)")
                #expect(chips.filter { $0.contains("trip-") } == ["Attachment trip-1.pdf", "Attachment trip-2.pdf"], "both of two: \(chips)")
                let more = shown.filter { $0.hasSuffix("more attachments") }
                #expect(more == ["5 more attachments"], "one + chip, for the five left of seven: \(more)")
                #expect(shown.firstIndex(of: "5 more attachments") == shown.firstIndex(of: "Attachment budget-2.pdf").map { $0 + 1 },
                        "the + chip follows the email's last chip: \(shown)")
            }
        }
    }

    @Test("Pressing an attachment chip or +N opens that email's card, never another email's")
    func controlsOpenTheirOwnEmail() async throws {
        #expect(HostedAccessibility.isAvailable, "control: the test can press the hosted chat")
        try await HostedAccessibility.withAutomation {
            try await withChat { chat in
                #expect(Self.bubble(0, in: chat.view) != nil && Self.bubble(1, in: chat.view) != nil,
                        "control: the bubbles are on screen: \(Self.labels(chat.view))")
                let presses: [(String, Int, NSObject?)] = [
                    ("Budget review's first chip", 0, Self.element("Attachment budget-1.pdf", in: chat.view)),
                    ("Budget review's +5", 0, Self.element("5 more attachments", in: chat.view)),
                    ("Trip notes' second chip", 1, Self.element("Attachment trip-2.pdf", in: chat.view)),
                ]
                for (name, index, control) in presses {
                    let control = try #require(control, "control: \(name) is on screen: \(Self.labels(chat.view))")
                    let card = try await Self.cardLabels(pressing: control, in: chat)
                    #expect(card.contains { $0.contains(Self.subjects[index]) }, "\(name) opens its own email: \(card.prefix(20))")
                    for other in Self.subjects.indices where other != index {
                        #expect(!card.contains { $0.contains(Self.subjects[other]) },
                                "\(name) never opens \(Self.subjects[other]): \(card.prefix(20))")
                    }
                }
            }
        }
        // The bubble opens through the same `onOpen` as its chips, and the chat's `onOpen` opens
        // that row's own email, by its address and Message-ID (ChatCardIdentityTests).
        let bubble = try Self.source("TabMail/Views/Chat/ChatBubbleView.swift")
        #expect(bubble.components(separatedBy: "private var bubble: some View { Button(action: onOpen) {").count == 2)
        #expect(bubble.components(separatedBy: "Button(action: onOpen)").count == 4, "the bubble, each chip and +N")
        let thread = try Self.source("TabMail/Views/Chat/ChatThreadView.swift")
        #expect(thread.components(separatedBy: "onOpen: { cardMessage = item.header })").count == 2)
        #expect(thread.components(separatedBy: "MessageDetailView(messageId: msg.id, expectedRfc822MessageId: msg.rfc822MessageId)").count == 2)
    }

    @Test("VoiceOver's Copy Address on a bubble puts that bubble's sender's address on the clipboard")
    func bubbleCopiesItsSendersAddress() async throws {
        #expect(HostedAccessibility.isAvailable, "control: the test can read the hosted chat")
        try await HostedAccessibility.withAutomation {
            try await withChat { chat in
                let copies = Set(HostedAccessibility.actionNames(in: chat.view).filter { $0.hasSuffix("'s Address") })
                #expect(copies == ["Copy Alex Doe's Address", "Copy Bo Lee's Address"], "each sender once: \(copies)")
                // The general clipboard, as the app writes it. What another app left there is not read
                // (that would ask for paste permission); a marker the test writes first shows a no-op.
                let pasteboard = UIPasteboard.general
                pasteboard.string = "marker"
                let performed = HostedAccessibility.perform("Copy Bo Lee's Address", in: chat.view)
                let copied = pasteboard.string
                #expect(performed, "a bubble offers it")
                #expect(copied == "bo@example.com")
            }
        }
    }

    /// `path`'s source with every run of whitespace made one space.
    private static func source(_ path: String) throws -> String {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        return try String(contentsOf: root.appendingPathComponent(path), encoding: .utf8)
            .split(whereSeparator: \.isWhitespace).joined(separator: " ")
    }

    @Test("The invite card sits under its own email, and its button adds that card's calendar file")
    func inviteCardAddsItsOwnInvite() async throws {
        #expect(HostedAccessibility.isAvailable, "control: the test can read the hosted chat")
        try await HostedAccessibility.withAutomation {
            try await withChat { chat in
                let shown = Self.labels(chat.view)
                let card = try #require(shown.firstIndex(of: "Planning"), "the invite card shows: \(shown)")
                let own = try #require(shown.firstIndex { Self.isBubble(2, $0) }, "\(shown)")
                let trip = try #require(shown.firstIndex { Self.isBubble(1, $0) }, "\(shown)")
                #expect(own < card && trip < own, "the card follows its own email's bubble: \(shown)")
                #expect(shown.filter { $0 == "Add to Calendar" }.count == 1, "one invite, one button: \(shown)")
            }
        }
        // The button hands the card's own calendar file to the import, and the card is the one the
        // bubble's email carries (the hosted harness cannot follow the import into Safari).
        let bubble = try Self.source("TabMail/Views/Chat/ChatBubbleView.swift")
        #expect(bubble.components(separatedBy: "ICSCalendarImporter.presentCalendarImport(icsText: invite.icsText)").count == 2)
        #expect(bubble.components(separatedBy: "if let invite = extras?.invite { ChatInviteCard(invite: invite) }").count == 2)
        let thread = try Self.source("TabMail/Views/Chat/ChatThreadView.swift")
        #expect(thread.components(separatedBy: "extras: context.extras[item.id],").count == 2, "each bubble gets its own email's extras")
    }
}
