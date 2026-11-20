/* This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at https://mozilla.org/MPL/2.0/. */

import SwiftUI
import Testing
import UIKit
@testable import TabMail

/// The sender line above a group-chat bubble.
///
/// THE SYSTEM PROPERTY pinned here: at the largest accessibility text size nothing of the bubble
/// is drawn past its column (so off the screen); the sender's name stays one line, and the
/// "(replied only to …)" label is laid out in full below it. At a normal size the name and the
/// label stay together on one line. The bubble is hosted for real in a `UIWindow`; what it draws
/// is read back from its layers.
@Suite("Chat bubble sender line layout", .serialized)
@MainActor
struct ChatBubbleNameLineLayoutTests {
    private static let screenWidth: CGFloat = 390
    private static let largest = DynamicTypeSize.accessibility5
    private static let longName = "Alexandra Montgomery-Fitzgerald Wellington"
    private static var column: CGFloat { screenWidth * ChatViewLayout.bubbleMaxWidthFraction }
    private static var labelText: String { "(replied only to \(onlyTo.label()))" }

    @Test("At the largest text size nothing is drawn past the bubble column")
    func nothingRunsPastTheColumnAtLargestSize() throws {
        let host = try Self.host(ChatBubbleView(
            item: Self.item(name: Self.longName), isGroup: true, extras: nil, isHighlighted: false, onOpen: {}
        ), size: Self.largest)
        defer { host.window.isHidden = true }
        let drawn = Self.inkFrames(in: host.window)
        try #require(!drawn.isEmpty, "nothing was drawn")
        // The column starts right of the avatar, where the bubble and its sender line start.
        let avatarRight = try #require(drawn.min { $0.minX < $1.minX }).maxX
        let content = drawn.filter { $0.minX >= avatarRight }
        let start = try #require(content.map(\.minX).min())
        for frame in content {
            #expect(frame.maxX <= start + Self.column + 0.5,
                    "drawn past the bubble column (\(start)...\(start + Self.column)): \(frame)")
            #expect(frame.maxX <= Self.screenWidth + 0.5, "drawn off the screen: \(frame)")
        }
    }

    @Test("At the largest text size the name is one line and the label is laid out in full below it")
    func nameOneLineLabelInFullAtLargestSize() throws {
        let sender = ChatSenderLine(
            item: Self.item(name: Self.longName))
        let line = Self.fittedSize(sender, width: Self.column, size: Self.largest)
        let oneLine = Self.fittedSize(Text("Ag").font(.caption), width: Self.column, size: Self.largest).height
        let label = Self.fittedSize(Text(Self.labelText).font(.caption), width: Self.column, size: Self.largest)
        let name = Self.fittedSize(Text(Self.longName).font(.caption).fontWeight(.medium), width: Self.column, size: Self.largest)
        #expect(name.height > oneLine * 1.5, "control: the long name would wrap if allowed")
        #expect(label.height > oneLine * 1.5, "control: the label needs more than one line here")
        #expect(line.width <= Self.column + 0.5, "the sender line is \(line.width) wide; the column is \(Self.column)")
        #expect(line.height >= oneLine + label.height - 0.5,
                "the label is not laid out in full under the name: \(line.height) < \(oneLine) + \(label.height)")
        #expect(line.height < oneLine * 2 + label.height,
                "the name takes more than one line: \(line.height)")
    }

    @Test("At a normal text size the name and the label stay on one line")
    func oneLineAtNormalSize() throws {
        let sender = ChatSenderLine(
            item: Self.item(name: "Alex"))
        let line = Self.fittedSize(sender, width: Self.column, size: .large)
        let oneLine = Self.fittedSize(Text("Ag").font(.caption), width: Self.column, size: .large).height
        let label = Self.fittedSize(Text(Self.labelText).font(.caption), width: .greatestFiniteMagnitude, size: .large)
        #expect(abs(line.height - oneLine) <= 1, "the line is \(line.height) tall; one line is \(oneLine)")
        #expect(line.width > label.width, "the name and the label are not side by side")
        #expect(line.width <= Self.column + 0.5)
    }

    // MARK: - Fixtures

    private static let onlyTo = ChatThread.OnlyTo(
        includesYou: true, people: [ChatThread.Person(address: "sam@example.com", name: "Sam")])

    private static func item(name: String) -> ChatThread.Item {
        var header = MessageHeader(
            messageId: "1", subject: "Plans", from: name, fromAddress: "alex@example.com",
            to: "me@example.com", date: Date(), snippet: "snippet",
            folderId: "acc1:INBOX", accountId: "acc1", folderPath: "INBOX", isInInbox: true)
        header.summaryTextMessage = "See you there."
        return ChatThread.Item(
            header: header, isOwn: false, sender: ChatThread.Person(address: "alex@example.com", name: name),
            repliedOnlyTo: onlyTo, showsTimeStamp: false, showsUnreadLine: false)
    }

    // MARK: - Hosting

    private struct Host {
        let window: UIWindow
    }

    private static func host(_ view: some View, size: DynamicTypeSize) throws -> Host {
        guard let scene = UIApplication.shared.connectedScenes.compactMap({ $0 as? UIWindowScene }).first else {
            throw HostingFailure("no UIWindowScene is available")
        }
        let controller = UIHostingController(rootView: view.environment(\.dynamicTypeSize, size))
        let window = UIWindow(windowScene: scene)
        window.frame = CGRect(x: 0, y: 0, width: screenWidth, height: 1600)
        window.rootViewController = controller
        window.isHidden = false
        window.layoutIfNeeded()
        controller.view.layoutIfNeeded()
        CATransaction.flush()
        return Host(window: window)
    }

    /// The window frame of every layer that draws content (text and glyphs).
    private static func inkFrames(in window: UIWindow) -> [CGRect] {
        var frames: [CGRect] = []
        func walk(_ layer: CALayer) {
            if layer.contents != nil, layer.bounds.width > 0, layer.bounds.height > 0 {
                frames.append(layer.convert(layer.bounds, to: window.layer))
            }
            layer.sublayers?.forEach(walk)
        }
        walk(window.layer)
        return frames
    }

    private static func fittedSize(_ view: some View, width: CGFloat, size: DynamicTypeSize) -> CGSize {
        let controller = UIHostingController(rootView: view.environment(\.dynamicTypeSize, size))
        return controller.sizeThatFits(in: CGSize(width: width, height: .greatestFiniteMagnitude))
    }

    private struct HostingFailure: Error, CustomStringConvertible {
        let description: String
        init(_ description: String) { self.description = description }
    }
}
