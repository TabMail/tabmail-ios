/* This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at https://mozilla.org/MPL/2.0/. */

import Foundation
import GRDB
import SwiftUI
import Testing
import UIKit
@testable import TabMail

/// Undo send, end to end: the real Send of a hosted compose decides who offers the send's Undo, and
/// the bubble's fill is checked as drawn.
///
/// THE SYSTEM PROPERTIES pinned here:
///  1. Who offers a send's Undo is decided from the chat view setting at the Send tap. A reply sent
///     with the chat view on (the ready AI Reply included) has it on its bubble and no toast; a reply
///     sent with it off, and any new email, has the toast. Changing the setting right after the tap
///     changes nothing for that send. A later bubble send leaves an earlier send's toast showing.
///  2. Drawn: the solid blue rises from the bottom edge, inside the bubble's shape; in light mode the
///     text is the pending text colour over the tint and white over the solid; under Reduce Motion
///     there is no rising fill; a mounted bubble drops its Undo when its deadline passes.
@Suite("Undo send routing and drawing", .serialized, .processGlobalState)
@MainActor
struct ChatUndoSendRoutingTests {
    nonisolated private static let account = "acc-undo-routing"

    // MARK: - 1. The real Send

    private struct Fixture {
        let pool: DatabasePool
        let account: Account
        let parent: MessageHeader
    }

    private static func makeFixture(_ pool: DatabasePool) async throws -> Fixture {
        let account = try FolderEpochTestFixture.makeAccount(id: Self.account, provider: .gmail, pool: pool)
        try FolderEpochTestFixture.insertFolder(accountId: Self.account, path: "INBOX", role: .inbox, pool: pool)
        try FolderEpochTestFixture.insertFolder(accountId: Self.account, path: "Sent", role: .sent, pool: pool)
        var parent = MessageHeader(
            messageId: "routing-parent", subject: "Lunch plans", from: "sender@example.com", fromAddress: "sender@example.com",
            to: account.emailAddress, date: Date().addingTimeInterval(-600), snippet: "Note",
            folderId: MessageIdentity.folderId(accountId: Self.account, folderPath: "INBOX"),
            accountId: Self.account, folderPath: "INBOX", isInInbox: true)
        parent.rfc822MessageId = "routing-parent@example.com"
        parent.headerComplete = true
        parent.bodyComplete = true
        parent.isRead = true
        let stored = parent
        try await pool.write { db in try stored.insert(db) }
        return Fixture(pool: pool, account: account, parent: parent)
    }

    /// Hosts `root` as the app does (with the accounts in the navigation store), taps its Send,
    /// runs `afterTap` at once (before the send has suspended anywhere), and returns the outbox row
    /// the send queued.
    private static func send(
        _ root: some View, fixture: Fixture, afterTap: () -> Void = {}
    ) async throws -> OutboxMessage {
        let before = try await fixture.pool.read { try OutboxMessage.fetchAll($0).map(\.id) }
        let scene = try #require(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let navigationStore = NavigationStore()
        navigationStore.accounts = [fixture.account]
        let window = UIWindow(windowScene: scene)
        window.frame = CGRect(x: 0, y: 0, width: 393, height: 852)
        let controller = UIHostingController(rootView: root.environment(navigationStore))
        window.rootViewController = controller
        window.makeKeyAndVisible()
        defer {
            window.isHidden = true
            window.rootViewController = nil
        }
        func ids() -> [String] { HostedAccessibility.identifiers(in: controller.view) }
        for _ in 0..<80 where !ids().contains(ComposeView.sendButtonId) { try await Task.sleep(for: .milliseconds(100)) }
        #expect(HostedAccessibility.activate(ComposeView.sendButtonId, in: controller.view), "control: Send was tapped")
        afterTap()
        var queued: OutboxMessage?
        for _ in 0..<100 where queued == nil {
            try await Task.sleep(for: .milliseconds(100))
            queued = try await fixture.pool.read { db in
                try OutboxMessage.order(Column("createdAt")).fetchAll(db).last { !before.contains($0.id) }
            }
        }
        let row = try #require(queued, "the send queued its email")
        // The owner is recorded when the compose presents, right after the queue write.
        for _ in 0..<50 where PendingSendService.shared.undoOwner(for: row.id) == nil {
            try await Task.sleep(for: .milliseconds(100))
        }
        return row
    }

    private static func readyAIReply(_ fixture: Fixture) -> some View {
        ChatReplyCompose.make(replyTo: fixture.parent, target: ChatReplyTarget(only: nil), accounts: [fixture.account])
            .composeView(replyTo: fixture.parent, suggestedBody: "Tuesday works for me.", onAgentOutcome: { _ in })
    }

    private static func newEmail(_ fixture: Fixture) -> some View {
        ComposeView(
            suggestedBody: "Here is the plan.", account: fixture.account,
            prefillTo: ["someone@example.com"], prefillCc: nil, prefillBcc: nil, prefillSubject: "Plan",
            onAgentOutcome: { _ in })
    }

    private func withSendEnvironment(_ body: (Fixture, ChatSummaryQueueTests.SavedChatViewState) async throws -> Void) async throws {
        let saved = ChatSummaryQueueTests.SavedChatViewState()
        let (pool, directory, previous) = try FolderEpochTestFixture.makeAppDB()
        let service = PendingSendService.shared
        defer {
            service.dismiss()
            saved.restore()
            InstalledTestDatabaseLifetime.finish(previous: previous, pool: pool, directory: directory)
        }
        service.dismiss()
        try await HostedAccessibility.withAutomation { @MainActor in
            try await body(try await Self.makeFixture(pool), saved)
        }
    }

    @Test("The ready AI Reply sent with the chat view on has its Undo on the bubble, even if the chat view goes off right after the tap")
    func readyReplyWithChatViewOnUsesTheBubble() async throws {
        #expect(HostedAccessibility.isAvailable, "control: the test can tap the hosted compose")
        try await withSendEnvironment { fixture, saved in
            saved.setChatView(on: true)
            let row = try await Self.send(Self.readyAIReply(fixture), fixture: fixture) { saved.setChatView(on: false) }
            #expect(row.inReplyTo != nil, "control: a reply")
            #expect(PendingSendService.shared.undoOwner(for: row.id) == .bubble, "the setting at the tap decided")
            #expect(PendingSendService.shared.visibleToast?.id != row.id, "no toast for it")
        }
    }

    @Test("A reply sent with the chat view off has the toast, even if the chat view comes on right after the tap")
    func replyWithChatViewOffUsesTheToast() async throws {
        #expect(HostedAccessibility.isAvailable, "control: the test can tap the hosted compose")
        try await withSendEnvironment { fixture, saved in
            saved.setChatView(on: false)
            let row = try await Self.send(Self.readyAIReply(fixture), fixture: fixture) { saved.setChatView(on: true) }
            #expect(PendingSendService.shared.undoOwner(for: row.id) == .toast, "the setting at the tap decided")
            #expect(PendingSendService.shared.visibleToast?.id == row.id, "RootView shows its toast")
        }
    }

    @Test("A new email has the toast with the chat view on, and a reply sent next on its bubble leaves that toast showing")
    func newEmailKeepsItsToastAcrossAReply() async throws {
        #expect(HostedAccessibility.isAvailable, "control: the test can tap the hosted compose")
        try await withSendEnvironment { fixture, saved in
            saved.setChatView(on: true)
            let email = try await Self.send(Self.newEmail(fixture), fixture: fixture)
            #expect(email.inReplyTo == nil, "control: a new email")
            #expect(PendingSendService.shared.undoOwner(for: email.id) == .toast)
            #expect(PendingSendService.shared.visibleToast?.id == email.id, "RootView shows its toast")
            let reply = try await Self.send(Self.readyAIReply(fixture), fixture: fixture)
            #expect(PendingSendService.shared.undoOwner(for: reply.id) == .bubble)
            #expect(PendingSendService.shared.visibleToast?.id == email.id, "the email keeps its toast, its only Undo")
        }
    }

    // MARK: - 2. Drawn

    private struct Bitmap {
        let width: Int
        let height: Int
        let bytes: [UInt8]

        func rgba(_ x: Int, _ y: Int) -> (r: Double, g: Double, b: Double, a: Double) {
            let i = (y * width + x) * 4
            return (Double(bytes[i]) / 255, Double(bytes[i + 1]) / 255, Double(bytes[i + 2]) / 255, Double(bytes[i + 3]) / 255)
        }

        /// Whether the pixel is `color`, resolved for the mode.
        func shows(_ color: Color, at x: Int, _ y: Int, dark: Bool) -> Bool {
            let resolved = UIColor(color).resolvedColor(with: UITraitCollection(userInterfaceStyle: dark ? .dark : .light))
            var r: CGFloat = 0, g: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
            resolved.getRed(&r, green: &g, blue: &b, alpha: &a)
            let p = rgba(x, y)
            let tolerance = 0.06
            return abs(p.r - r) < tolerance && abs(p.g - g) < tolerance && abs(p.b - b) < tolerance && p.a > 0.9
        }
    }

    private static let side = 100
    private static let textColumn = 50
    private static let backgroundColumn = 10

    /// Renders `view` at `side` x `side` points, one pixel per point.
    private static func render(_ view: some View, dark: Bool) throws -> Bitmap {
        let renderer = ImageRenderer(content: view
            .frame(width: CGFloat(side), height: CGFloat(side))
            .environment(\.colorScheme, dark ? .dark : .light))
        renderer.scale = 1
        let image = try #require(renderer.cgImage, "rendered")
        var bytes = [UInt8](repeating: 0, count: side * side * 4)
        let context = try #require(CGContext(
            data: &bytes, width: side, height: side, bitsPerComponent: 8, bytesPerRow: side * 4,
            space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        context.draw(image, in: CGRect(x: 0, y: 0, width: side, height: side))
        return Bitmap(width: side, height: side, bytes: bytes)
    }

    /// A bubble whose "text" is a solid column in the text colour, background either side of it.
    private static func content(_ textColor: Color) -> some View {
        HStack(spacing: 0) {
            Color.clear.frame(width: 40)
            textColor.frame(width: 20)
            Color.clear.frame(width: 40)
        }
        .frame(width: CGFloat(side), height: CGFloat(side))
    }

    @Test("The solid blue rises from the bottom edge inside the bubble's shape, and light-mode text switches colour at the fill edge", arguments: [false, true])
    func fillIsDrawnFromTheBottom(dark: Bool) throws {
        let bitmap = try Self.render(ChatUndoSendFill(look: .pending(fill: 0.25)) { Self.content($0) }, dark: dark)
        let low = 90, high = 40   // inside the risen quarter, and above it
        #expect(bitmap.shows(Theme.accent, at: Self.backgroundColumn, low, dark: dark), "the bottom quarter is solid blue")
        #expect(bitmap.shows(Palette.chatUndoSendPendingTint, at: Self.backgroundColumn, high, dark: dark), "above it, the pending tint")
        #expect(bitmap.shows(Color.white, at: Self.textColumn, low, dark: dark), "text over the solid is white")
        #expect(bitmap.shows(Palette.chatUndoSendPendingText, at: Self.textColumn, high, dark: dark),
                "text over the tint is the pending text colour (navy in light mode, white in dark)")
        #expect(bitmap.rgba(0, 0).a < 0.1 && bitmap.rgba(0, Self.side - 1).a < 0.1,
                "the corners are outside the bubble's shape, the fill's included")
    }

    @Test("Under Reduce Motion the bubble does not fill; with motion it has risen by the part of the window passed")
    func reduceMotionDrawsNoFill() throws {
        // 4 of the 5 s of the window have passed: a moving fill is 80% up.
        let hold = Date().addingTimeInterval(SyncConfig.outboxClaimBufferSeconds + 1)
        let reply = ChatUnsentReply(outboxId: "o-drawn", status: .queued, sentAt: nil, holdUntil: hold,
                                    draftId: "d", instanceEpoch: "E1", filed: false, textMessage: nil)
        func drawn(reduceMotion: Bool) throws -> Bitmap {
            try Self.render(ChatUndoSendTimelineBody(reply: reply, reduceMotion: reduceMotion) { look, _ in
                ChatUndoSendFill(look: look) { Self.content($0) }
            }, dark: false)
        }
        let middle = 50
        #expect(try drawn(reduceMotion: false).shows(Theme.accent, at: Self.backgroundColumn, middle, dark: false),
                "control: with motion the middle is already solid")
        #expect(try drawn(reduceMotion: true).shows(Palette.chatUndoSendPendingTint, at: Self.backgroundColumn, middle, dark: false),
                "Reduce Motion: still the pending tint")
    }

    @Test("A mounted bubble offers Undo until its deadline passes, then shows Sending with no Undo")
    func mountedBubbleCrossesItsDeadline() async throws {
        #expect(HostedAccessibility.isAvailable, "control: the test can read the hosted bubble")
        try await HostedAccessibility.withAutomation { @MainActor in
            let hold = Date().addingTimeInterval(SyncConfig.outboxClaimBufferSeconds + 1.5)
            let reply = ChatUnsentReply(outboxId: "o-mounted", status: .queued, sentAt: nil, holdUntil: hold,
                                        draftId: "d", instanceEpoch: "E1", filed: false, textMessage: "I said Tuesday works.")
            let scene = try #require(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
            let window = UIWindow(windowScene: scene)
            window.frame = CGRect(x: 0, y: 0, width: 393, height: 300)
            let controller = UIHostingController(rootView: ChatUnsentReplyBubble(reply: reply, retry: {}, delete: {}, undo: {}))
            window.rootViewController = controller
            window.makeKeyAndVisible()
            defer {
                window.isHidden = true
                window.rootViewController = nil
            }
            let hasUndo: @MainActor () -> Bool = { HostedAccessibility.identifiers(in: controller.view).contains(ChatUndoSendStatus.undoId) }
            for _ in 0..<20 where !hasUndo() { try await Task.sleep(for: .milliseconds(50)) }
            #expect(hasUndo(), "Undo while the window lasts")
            for _ in 0..<60 where hasUndo() { try await Task.sleep(for: .milliseconds(100)) }
            #expect(!hasUndo(), "no Undo once the deadline passed")
            #expect(HostedAccessibility.labels(in: controller.view).contains { $0.contains("Sending") }, "the bubble still reads Sending")
        }
    }
}
