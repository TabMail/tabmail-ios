/* This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at https://mozilla.org/MPL/2.0/. */

import Foundation
import Testing
@testable import TabMail

/// A forward carries no In-Reply-To (`ThreadUtils.outgoingThreadHeaders` with
/// `isForward`, #1483), and its completion marks the original forwarded, never
/// replied, from the queued row's `isForward`. Both depend on ComposeView's
/// `send()` passing the view's own mode on, and a hosted SwiftUI view cannot be
/// driven from a unit test. These checks read ComposeView's source and pin each
/// place `send()` passes it, the way `ComposeRecipientWiringTests` pins the
/// recipient roles.
@Suite("Compose view sends a forward as a forward")
struct ComposeForwardThreadingWiringTests {
    /// ComposeView's source with every run of whitespace made one space, so a
    /// line break or indent change does not matter.
    private static func source() throws -> String {
        let projectRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let text = try String(
            contentsOf: projectRoot.appendingPathComponent("TabMail/Views/Compose/ComposeView.swift"),
            encoding: .utf8)
        return text.split(whereSeparator: \.isWhitespace).joined(separator: " ")
    }

    private static func count(_ needle: String, in text: String) -> Int {
        text.components(separatedBy: needle).count - 1
    }

    /// `send()`'s body, from its declaration to the next `private func`.
    private static func sendBody(_ text: String) throws -> String {
        let start = try #require(text.range(of: "private func send() async {"))
        let end = try #require(text[start.upperBound...].range(of: "private func "))
        return String(text[start.lowerBound..<end.lowerBound])
    }

    @Test("Send builds the thread headers with the view's forward mode and sends exactly those headers")
    func threadHeadersUseTheViewsForwardMode() throws {
        let text = try Self.source()
        let send = try Self.sendBody(text)
        let builder = "ThreadUtils.outgoingThreadHeaders( replyTo: sendTarget, isForward: isForward, sendAccountId: account.id, sendSubject: subject, providerKind: account.provider )"
        #expect(Self.count(builder, in: text) == 1, "the one production call of the thread-header builder")
        #expect(Self.count(builder, in: send) == 1, "built inside send()")
        #expect(send.contains(
            "inReplyTo: threadHeaders.inReplyTo, references: threadHeaders.references,"),
            "the outbound message carries the built headers")
        #expect(send.contains("threadId: threadHeaders.threadId )"))
    }

    @Test("Send records the view's forward mode on the queued send")
    func queuedSendUsesTheViewsForwardMode() throws {
        let send = try Self.sendBody(try Self.source())
        let start = try #require(send.range(of: "let snapshot = AuthoredSendSnapshot("))
        let end = try #require(send[start.upperBound...].range(of: "outbound: outbound)"))
        let snapshot = String(send[start.lowerBound..<end.upperBound])
        #expect(Self.count("isForward: isForward,", in: snapshot) == 1, "the snapshot takes the view's mode")
        let queueStart = try #require(send.range(of: "queued = try await AccountManager.shared.queueSend("))
        let queueEnd = try #require(send[queueStart.upperBound...].range(of: "isReplyAll: snapshot.isReplyAll,"))
        let queue = String(send[queueStart.lowerBound..<queueEnd.upperBound])
        #expect(queue.contains("draft: snapshot.outbound,"), "the queued draft is the snapshot's")
        #expect(queue.contains("isForward: snapshot.isForward,"), "the queued send takes the snapshot's mode")
    }
}
