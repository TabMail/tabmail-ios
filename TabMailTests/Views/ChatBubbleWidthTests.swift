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
/// the bubble's trailing edge. Hosted for real in a `UIWindow`, read back from the accessibility
/// frames.
@Suite("Chat bubble width", .serialized)
@MainActor
struct ChatBubbleWidthTests {
    private static let screenWidth: CGFloat = 390
    private static var column: CGFloat { screenWidth * ChatViewLayout.bubbleMaxWidthFraction }
    nonisolated private static let shortWords = "Lunch on Friday?"
    nonisolated private static let longWords = "Lunch on Friday works for me, and I can bring the slides for the planning meeting afterwards if that helps."

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

    @Test("Words narrower than the Details pin: the bubble is as wide as the pin, still hugging")
    func pinWiderThanTheWords() async throws {
        #expect(HostedAccessibility.isAvailable, "control: accessibility automation is available")
        let view = VStack(spacing: 20) {
            ChatFieldMessageBubble(text: "Ok")
            ChatBubbleView(item: Self.item("Ok"), isGroup: false, extras: nil, isHighlighted: false, onOpen: {})
        }
        try await Self.withHosted(view) { root in
            let message = try #require(Self.frame(of: ChatFieldMessageBubble.bubbleId, in: root), "control: the user's bubble shows")
            let sent = try #require(Self.frame(of: ChatBubbleView.bubbleId, in: root), "control: the sent email's bubble shows")
            #expect(sent.width > message.width, "the pin is wider than \"Ok\", so the bubble takes the pin's width: \(sent.width) vs \(message.width)")
            #expect(sent.width < Self.column / 2, "and hugs it: \(sent.width) of \(Self.column)")
        }
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
