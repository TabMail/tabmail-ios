/* This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at https://mozilla.org/MPL/2.0/. */

import SwiftUI
import Testing
import UIKit
@testable import TabMail

/// How wide an email's bubble is in the chat (ADR-IOS-114).
///
/// THE SYSTEM PROPERTY pinned here: an email's bubble is as wide as the wider of its words and
/// its Details pin, and no wider. A short email's bubble hugs its words as the user's own message
/// and Sending bubbles do, so the user's bubble keeps its width when the sent email takes its
/// place; long words wrap at the bubble column as they do there. The pin sits under the words at
/// the bubble's trailing edge. Every bubble of the user's email carries the pin, inactive while
/// there is nothing to open (the user's message, the Sending bubble), so the same words keep one
/// bubble, width and height, through the send. Hosted for real in a `UIWindow`, read back from the
/// accessibility frames.
@Suite("Chat bubble width", .serialized)
@MainActor
struct ChatBubbleWidthTests {
    private static let screenWidth: CGFloat = 390
    private static var column: CGFloat { screenWidth * ChatViewLayout.bubbleMaxWidthFraction }
    nonisolated private static let shortWords = "Lunch on Friday?"
    nonisolated private static let longWords = "Lunch on Friday works for me, and I can bring the slides for the planning meeting afterwards if that helps."
    /// Narrower than the Details pin.
    nonisolated private static let pinWiderWords = "Ok"

    @Test("A sent email's bubble is as wide as the user's own bubble of the same words: hugging short words, wrapping long ones at the column",
          arguments: [shortWords, longWords])
    func sentBubbleKeepsTheWordsWidth(words: String) async throws {
        #expect(HostedAccessibility.isAvailable, "control: accessibility automation is available")
        let view = VStack(spacing: 20) {
            ChatFieldMessageBubble(text: words)
            ChatBubbleView(item: Self.item(words), isGroup: false, extras: nil, isHighlighted: false, onOpen: {})
        }
        try await Self.withHosted(view) { root in
            let message = try #require(Self.frame(of: ChatFieldMessageBubble.bubbleId, in: root), "control: the user's bubble shows")
            let sent = try #require(Self.frame(of: ChatBubbleView.bubbleId, in: root), "control: the sent email's bubble shows")
            #expect(abs(sent.width - message.width) <= 1,
                    "the sent email's bubble is \(sent.width) wide; the user's bubble of the same words \(message.width)")
            #expect(abs(sent.maxX - message.maxX) <= 1, "both at the trailing edge: \(sent) \(message)")
            #expect(sent.width <= Self.column + 0.5, "never past the column \(Self.column): \(sent.width)")
            if words == Self.shortWords {
                #expect(sent.width + 1 < Self.column, "a short email's bubble hugs its words, short of the column: \(sent.width) of \(Self.column)")
            } else {
                #expect(sent.width > Self.column / 2, "control: long words fill the column before they wrap: \(sent.width)")
            }
        }
    }

    @Test("The same words keep one bubble from the user's message through its Sending bubble to the sent email's: one width and one height, as each carries the Details pin; only the sent email's opens",
          arguments: [pinWiderWords, shortWords, longWords])
    func sameBubbleThroughTheSend(words: String) async throws {
        #expect(HostedAccessibility.isAvailable, "control: accessibility automation is available")
        let opens = OpenCount()
        let reply = ChatUnsentReply(outboxId: "o-pin", status: .queued, sentAt: nil, holdUntil: nil,
                                    draftId: "d", instanceEpoch: "E1", filed: false, textMessage: words)
        let view = VStack(spacing: 20) {
            ChatFieldMessageBubble(text: words)
            ChatUnsentReplyBubble(reply: reply, retry: {}, delete: {}, undo: {})
            ChatBubbleView(item: Self.item(words), isGroup: false, extras: nil, isHighlighted: false, onOpen: { opens.count += 1 })
        }
        try await Self.withHosted(view) { root in
            let message = try #require(Self.frame(of: ChatFieldMessageBubble.bubbleId, in: root), "control: the user's bubble shows")
            let sending = try #require(Self.frame(of: ChatUnsentReplyBubble.bubbleId, in: root), "control: the Sending bubble shows")
            let sent = try #require(Self.frame(of: ChatBubbleView.bubbleId, in: root), "control: the sent email's bubble shows")
            #expect(abs(sending.width - message.width) <= 1 && abs(sent.width - sending.width) <= 1,
                    "one width: message \(message.width), Sending \(sending.width), sent \(sent.width)")
            #expect(abs(sending.height - message.height) <= 1 && abs(sent.height - sending.height) <= 1,
                    "one height, the pin under the words in each: message \(message.height), Sending \(sending.height), sent \(sent.height)")
            if words == Self.pinWiderWords {
                #expect(sent.width < Self.column / 2, "words narrower than the pin: the bubble hugs the pin, \(sent.width) of \(Self.column)")
            }
            // Nothing to open before the email is stored: VoiceOver reads no pin, and the only
            // button is the sent email's bubble, which opens it.
            let labels = HostedAccessibility.labels(in: root)
            #expect(!labels.contains { $0.contains("Details") }, "no pin is read: \(labels)")
            let buttons = Set(HostedAccessibility.elements(under: root)
                .filter { $0.accessibilityTraits.contains(.button) }
                .map { HostedAccessibility.identifier(of: $0) ?? "<no identifier>" })
            #expect(buttons == [ChatBubbleView.bubbleId], "only the sent email's bubble is a button: \(buttons)")
            #expect(HostedAccessibility.activate(ChatBubbleView.bubbleId, in: root), "control: the sent email's bubble takes a tap")
            for _ in 0..<20 where opens.count == 0 {
                try await Task.sleep(for: .milliseconds(50))
            }
            let opened = opens.count
            #expect(opened == 1, "and opens the email")
        }
    }

    /// How many times the sent email's bubble opened it.
    @MainActor private final class OpenCount {
        var count = 0
    }

    @Test("The Details pin takes the same size active or inactive; inactive, it is dimmed")
    func pinKeepsItsSize() {
        let fit = CGSize(width: Self.screenWidth, height: .greatestFiniteMagnitude)
        for color in [ChatDetailsPin.ownColor(on: Color.white), Theme.textSecondary] {
            let active = UIHostingController(rootView: ChatDetailsPin(isActive: true, color: color)).sizeThatFits(in: fit)
            let inactive = UIHostingController(rootView: ChatDetailsPin(isActive: false, color: color)).sizeThatFits(in: fit)
            #expect(active.width > 0 && active.height > 0, "control: the pin has a size: \(active)")
            #expect(active == inactive, "same size: active \(active), inactive \(inactive)")
        }
        let activeOpacity = ChatDetailsPin.opacity(isActive: true)
        let inactiveOpacity = ChatDetailsPin.opacity(isActive: false)
        #expect(activeOpacity == 1, "active: full")
        #expect(inactiveOpacity > 0 && inactiveOpacity < activeOpacity, "inactive: dimmed, still seen: \(inactiveOpacity)")
    }

    @Test("The stack is as wide as the wider of its words and its pin; the words at the leading edge, the pin under them at the trailing edge",
          arguments: [true, false])
    func stackPlacesThePin(wordsWider: Bool) async throws {
        #expect(HostedAccessibility.isAvailable, "control: accessibility automation is available")
        let spacing: CGFloat = 6
        let view = ChatBubbleStack(spacing: spacing) {
            Text(wordsWider ? Self.shortWords : "Ok").accessibilityIdentifier("words")
            Text("Details").font(.caption2).accessibilityIdentifier("pin")
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("stack")
        try await Self.withHosted(view) { root in
            let words = try #require(Self.frame(of: "words", in: root), "control: the words show")
            let pin = try #require(Self.frame(of: "pin", in: root), "control: the pin shows")
            let stack = try #require(Self.frame(of: "stack", in: root), "control: the stack shows")
            #expect(abs(stack.width - max(words.width, pin.width)) <= 0.5, "as wide as the wider: \(stack.width), \(words.width), \(pin.width)")
            #expect(abs(words.minX - stack.minX) <= 0.5, "the words at the leading edge: \(words) in \(stack)")
            #expect(abs(pin.maxX - stack.maxX) <= 0.5, "the pin at the trailing edge: \(pin) in \(stack)")
            #expect(abs(pin.minY - words.maxY - spacing) <= 0.5, "the pin under the words: \(pin) \(words)")
            #expect(abs(stack.height - (words.height + spacing + pin.height)) <= 0.5, "as tall as both: \(stack.height)")
        }
    }

    // MARK: - Fixtures

    /// The user's own sent email, its summary `words`.
    private static func item(_ words: String) -> ChatThread.Item {
        var header = MessageHeader(
            messageId: "1", subject: "Plans", from: "Me", fromAddress: "me@example.com",
            to: "alex@example.com", date: Date(), snippet: "snippet",
            folderId: "acc1:Sent", accountId: "acc1", folderPath: "Sent", isInInbox: false)
        header.summaryTextMessage = words
        return ChatThread.Item(
            header: header, isOwn: true, sender: ChatThread.Person(address: "me@example.com", name: "Me"),
            repliedOnlyTo: nil, showsTimeStamp: false, showsUnreadLine: false)
    }

    // MARK: - Hosting

    /// Shows `view` in a window as wide as a phone and runs `body` once its elements are read.
    private static func withHosted(_ view: some View, _ body: @MainActor (UIView) async throws -> Void) async throws {
        let scene = try #require(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let controller = UIHostingController(rootView: view)
        let window = UIWindow(windowScene: scene)
        window.frame = CGRect(x: 0, y: 0, width: screenWidth, height: 900)
        window.rootViewController = controller
        window.isHidden = false
        defer {
            window.isHidden = true
            window.rootViewController = nil
        }
        try await HostedAccessibility.withAutomation {
            for _ in 0..<50 where HostedAccessibility.identifiers(in: controller.view).isEmpty {
                try await Task.sleep(for: .milliseconds(100))
            }
            try await Task.sleep(for: .milliseconds(300))
            try await body(controller.view)
        }
    }

    /// The window frame of the element named `id`.
    private static func frame(of id: String, in view: UIView) -> CGRect? {
        HostedAccessibility.elements(under: view).first { HostedAccessibility.identifier(of: $0) == id }?.accessibilityFrame
    }
}
