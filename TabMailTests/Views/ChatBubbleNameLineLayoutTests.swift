/* This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at https://mozilla.org/MPL/2.0/. */

import SwiftUI
import Testing
import UIKit
@testable import TabMail

/// The sender line above a group-chat bubble.
///
/// THE SYSTEM PROPERTY pinned here: at every accessibility text size nothing of the bubble
/// is drawn past its column (so off the screen); the sender's name stays one line, and the
/// "(replied only to …)" label is laid out in full below it. At a normal size the name and the
/// label stay together on one line. The bubble is hosted for real in a `UIWindow`; what it draws
/// is read back from its layers.
@Suite("Chat bubble sender line layout", .serialized)
@MainActor
struct ChatBubbleNameLineLayoutTests {
    private static let screenWidth: CGFloat = 390
    private static let longName = "Alexandra Montgomery-Fitzgerald Wellington"
    private static var column: CGFloat { screenWidth * ChatViewLayout.bubbleMaxWidthFraction }
    private static var labelText: String { "(replied only to \(onlyTo.label()))" }

    /// Every accessibility text size, and every normal one as the controls.
    nonisolated private static let accessibilitySizes: [DynamicTypeSize] = DynamicTypeSize.allCases.filter(\.isAccessibilitySize)
    nonisolated private static let normalSizes: [DynamicTypeSize] = DynamicTypeSize.allCases.filter { !$0.isAccessibilitySize }

    @Test("At every accessibility text size nothing is drawn past the bubble column", arguments: accessibilitySizes)
    func nothingRunsPastTheColumnAtAccessibilitySizes(size: DynamicTypeSize) throws {
        let host = try Self.host(ChatBubbleView(
            item: Self.item(name: Self.longName), isGroup: true, extras: nil, isHighlighted: false, onOpen: {}
        ), size: size)
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

    @Test("At every accessibility text size the name is one line and the label is laid out in full below it",
          arguments: accessibilitySizes)
    func nameOneLineLabelInFullAtAccessibilitySizes(size: DynamicTypeSize) throws {
        let sender = ChatSenderLine(
            item: Self.item(name: Self.longName))
        let line = Self.fittedSize(sender, width: Self.column, size: size)
        let oneLine = Self.fittedSize(Text("Ag").font(ChatSenderLine.nameFont), width: Self.column, size: size).height
        let label = Self.fittedSize(Text(Self.labelText).font(.caption), width: Self.column, size: size)
        let name = Self.fittedSize(Text(Self.longName).font(ChatSenderLine.nameFont).fontWeight(.medium), width: Self.column, size: size)
        #expect(name.height > oneLine * 1.5, "control: the long name would wrap if allowed")
        #expect(line.width <= Self.column + 0.5, "the sender line is \(line.width) wide; the column is \(Self.column)")
        #expect(line.height >= oneLine + label.height - 0.5,
                "the label is not laid out in full under the name: \(line.height) < \(oneLine) + \(label.height)")
        #expect(line.height < oneLine * 2 + label.height,
                "the name takes more than one line: \(line.height)")
    }

    @Test("At every normal text size the name and the label stay on one line", arguments: normalSizes)
    func oneLineAtNormalSizes(size: DynamicTypeSize) throws {
        let sender = ChatSenderLine(
            item: Self.item(name: "Alex"))
        let line = Self.fittedSize(sender, width: Self.column, size: size)
        let oneLine = Self.fittedSize(Text("Ag").font(ChatSenderLine.nameFont), width: Self.column, size: size).height
        let label = Self.fittedSize(Text(Self.labelText).font(.caption), width: .greatestFiniteMagnitude, size: size)
        #expect(abs(line.height - oneLine) <= 1, "the line is \(line.height) tall; one line is \(oneLine)")
        #expect(line.width > label.width, "the name and the label are not side by side")
        #expect(line.width <= Self.column + 0.5)
    }

    @Test("The open recipient list shows every recipient, in the one-line and the stacked layout",
          arguments: [DynamicTypeSize.large, .accessibility5])
    func openListShowsEveryRecipient(size: DynamicTypeSize) async throws {
        #expect(HostedAccessibility.isAvailable, "control: accessibility automation is available")
        let only = ChatThread.OnlyTo(includesYou: true, people: Self.manyPeople)
        #expect(only.label().contains("+"), "control: the label shows only some of the names")
        // The state the label's tap sets (`openRecipientList`; the fence below pins the tap to it).
        let line = ChatSenderLine(item: Self.item(name: "Alex", onlyTo: only), showsOnlyList: true)
        let controller = UIHostingController(rootView: line.environment(\.dynamicTypeSize, size))
        let window = UIWindow(windowScene: try Self.scene())
        window.frame = CGRect(x: 0, y: 0, width: Self.screenWidth, height: 800)
        window.rootViewController = controller
        window.isHidden = false
        defer { window.isHidden = true }
        try await HostedAccessibility.withAutomation {
            let deadline = Date().addingTimeInterval(Self.presentWait)
            while controller.presentedViewController == nil, Date() < deadline {
                try await Task.sleep(for: .milliseconds(50))
            }
            let list = try #require(controller.presentedViewController?.view, "the recipient list did not open")
            var labels: [String] = []
            while Date() < deadline {
                labels = HostedAccessibility.labels(in: list)
                if labels.contains("Alex replied only to") { break }
                try await Task.sleep(for: .milliseconds(50))
            }
            #expect(labels.contains("Alex replied only to"), "the list's title: \(labels)")
            for name in ["You"] + Self.manyPeople.map(\.name) {
                #expect(labels.contains(name), "\(name) is missing from the list: \(labels)")
            }
        }
    }

    @Test("Source fence: the label's tap opens the recipient list through openRecipientList")
    func labelTapOpensTheList() throws {
        let source = try String(contentsOf: Self.bubbleSource, encoding: .utf8)
        #expect(source.contains("Button { openRecipientList() } label: {"),
                "the \"replied only to\" label must call openRecipientList()")
        let method = try #require(source.range(of: "func openRecipientList() {"), "openRecipientList() is gone")
        let body = source[method.upperBound...].prefix { $0 != "}" }
        #expect(body.contains("showsOnlyList = true"), "openRecipientList() must open the list")
    }

    @Test("At a normal text size a long name keeps its full width and the line stays one line")
    func longNameStaysOneLineAtNormalSize() throws {
        let name = String(repeating: "Alexandra Montgomery-Fitzgerald ", count: 3)
        let only = ChatThread.OnlyTo(includesYou: true, people: Self.manyPeople)
        let line = Self.fittedSize(ChatSenderLine(item: Self.item(name: name, onlyTo: only)), width: Self.column, size: .large)
        let oneLine = Self.fittedSize(Text("Ag").font(ChatSenderLine.nameFont), width: Self.column, size: .large).height
        let fullName = Self.fittedSize(
            Text(name).font(ChatSenderLine.nameFont).fontWeight(.medium).fixedSize(), width: .greatestFiniteMagnitude, size: .large)
        #expect(fullName.width > Self.column, "control: the name is wider than the column")
        #expect(abs(line.height - oneLine) <= 1, "the line wrapped: \(line.height) tall; one line is \(oneLine)")
        #expect(line.width >= fullName.width - 0.5,
                "the name lost its full width: the line is \(line.width), the name \(fullName.width)")
    }

    @Test("At an accessibility text size the user's own line sits at the trailing edge; someone else's at the leading edge",
          arguments: [true, false])
    func ownLineAlignsTrailing(isOwn: Bool) throws {
        let only = ChatThread.OnlyTo(includesYou: false, people: Self.manyPeople + Self.manyPeople.map {
            ChatThread.Person(address: "x.\($0.address)", name: "\($0.name) Longername")
        })
        let host = try Self.host(
            ChatSenderLine(item: Self.item(name: "Alex", onlyTo: only, isOwn: isOwn)).frame(width: Self.column),
            size: .accessibility3)
        defer { host.window.isHidden = true }
        let layers = Self.drawnLayers(in: host.window).sorted { $0.frame.minY < $1.frame.minY }
        try #require(layers.count >= 2, "control: the name and the label are drawn: \(layers.map(\.frame))")
        let name = layers[0], label = Array(layers.dropFirst())
        let labelLeft = label.map(\.frame.minX).min() ?? 0, labelRight = label.map(\.frame.maxX).max() ?? 0
        // The label's lines, by the ink in its rows.
        let rows = label.flatMap { Self.inkRuns(of: $0.layer) }
        #expect(rows.count >= 2, "control: the label wraps to more than one line")
        if isOwn {
            #expect(abs(name.frame.maxX - labelRight) <= 2, "\"You\" is not at the trailing edge: \(name.frame) vs \(labelRight)")
            let rights = rows.map(\.right)
            #expect((rights.max() ?? 0) - (rights.min() ?? 0) <= 3, "the label's lines are not trailing-aligned: \(rights)")
        } else {
            #expect(abs(name.frame.minX - labelLeft) <= 2, "the name is not at the leading edge: \(name.frame) vs \(labelLeft)")
            let lefts = rows.map(\.left)
            #expect((lefts.max() ?? 0) - (lefts.min() ?? 0) <= 3, "the label's lines are not leading-aligned: \(lefts)")
        }
    }

    @Test("The sender line is hidden from VoiceOver, in both layouts", arguments: [DynamicTypeSize.large, .accessibility5])
    func senderLineHiddenFromVoiceOver(size: DynamicTypeSize) async throws {
        #expect(HostedAccessibility.isAvailable, "control: accessibility automation is available")
        let view = VStack {
            Text("Probe")
            ChatSenderLine(item: Self.item(name: "Alex"))
        }
        let host = try Self.host(view, size: size)
        defer { host.window.isHidden = true }
        await HostedAccessibility.withAutomation {
            try? await Task.sleep(for: .milliseconds(300))
            let labels = HostedAccessibility.labels(in: host.window)
            #expect(labels.contains("Probe"), "control: VoiceOver sees the screen: \(labels)")
            #expect(!labels.contains { $0.contains("Alex") || $0.contains("replied only to") },
                    "VoiceOver reads the sender line: \(labels)")
        }
    }

    // MARK: - Fixtures

    private static let onlyTo = ChatThread.OnlyTo(
        includesYou: true, people: [ChatThread.Person(address: "sam@example.com", name: "Sam")])

    private static let manyPeople = ["Sam", "Riley", "Jordan", "Casey"].map {
        ChatThread.Person(address: "\($0.lowercased())@example.com", name: $0)
    }
    private static let presentWait: TimeInterval = 5
    private static var bubbleSource: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent() // Views
            .deletingLastPathComponent() // TabMailTests
            .deletingLastPathComponent() // repo root
            .appendingPathComponent("TabMail/Views/Chat/ChatBubbleView.swift")
    }

    private static func item(
        name: String, onlyTo: ChatThread.OnlyTo = ChatBubbleNameLineLayoutTests.onlyTo, isOwn: Bool = false
    ) -> ChatThread.Item {
        var header = MessageHeader(
            messageId: "1", subject: "Plans", from: name, fromAddress: "alex@example.com",
            to: "me@example.com", date: Date(), snippet: "snippet",
            folderId: "acc1:INBOX", accountId: "acc1", folderPath: "INBOX", isInInbox: true)
        header.summaryTextMessage = "See you there."
        return ChatThread.Item(
            header: header, isOwn: isOwn, sender: ChatThread.Person(address: "alex@example.com", name: name),
            repliedOnlyTo: onlyTo, showsTimeStamp: false, showsUnreadLine: false)
    }

    // MARK: - Hosting

    private struct Host {
        let window: UIWindow
    }

    private static func scene() throws -> UIWindowScene {
        guard let scene = UIApplication.shared.connectedScenes.compactMap({ $0 as? UIWindowScene }).first else {
            throw HostingFailure("no UIWindowScene is available")
        }
        return scene
    }

    private static func host(_ view: some View, size: DynamicTypeSize) throws -> Host {
        let scene = try scene()
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

    private struct Drawn {
        let layer: CALayer
        let frame: CGRect
    }

    private static func drawnLayers(in window: UIWindow) -> [Drawn] {
        var out: [Drawn] = []
        func walk(_ layer: CALayer) {
            if layer.contents != nil, layer.bounds.width > 0, layer.bounds.height > 0 {
                out.append(Drawn(layer: layer, frame: layer.convert(layer.bounds, to: window.layer)))
            }
            layer.sublayers?.forEach(walk)
        }
        walk(window.layer)
        return out
    }

    /// Each run of inked pixel rows in `layer` (one text line), with its leftmost and rightmost ink in
    /// points.
    private static func inkRuns(of layer: CALayer) -> [(left: CGFloat, right: CGFloat)] {
        let format = UIGraphicsImageRendererFormat()
        format.scale = layer.contentsScale
        format.opaque = false
        guard let image = UIGraphicsImageRenderer(size: layer.bounds.size, format: format)
            .image(actions: { layer.render(in: $0.cgContext) }).cgImage else { return [] }
        let width = image.width, height = image.height
        var pixels = [UInt8](repeating: 0, count: width * height * 4)
        let context = CGContext(
            data: &pixels, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4,
            space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
        context?.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        let rowInk: [(Int, Int)?] = (0..<height).map { y in
            let inked = (0..<width).filter { pixels[(y * width + $0) * 4 + 3] > 0 }
            guard let first = inked.first, let last = inked.last else { return nil }
            return (first, last)
        }
        var runs: [(left: CGFloat, right: CGFloat)] = []
        var current: (Int, Int)?
        for ink in rowInk + [nil] {
            if let ink {
                current = current.map { (min($0.0, ink.0), max($0.1, ink.1)) } ?? ink
            } else if let run = current {
                let x = layer.frame.minX
                runs.append((x + CGFloat(run.0) / format.scale, x + CGFloat(run.1 + 1) / format.scale))
                current = nil
            }
        }
        return runs
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
