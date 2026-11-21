/* This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at https://mozilla.org/MPL/2.0/. */

import SwiftUI
import Testing
import UIKit
@testable import TabMail

/// "Enable Chat View" (`ChatViewToggleRow`, the row TabMail Settings and the tutorial's switch step
/// both show), hosted in a window as they host it, inside a `Form`.
///
/// THE SYSTEM PROPERTIES pinned here:
///  1. With AI on, the switch can be used and flipping it stores the user's choice.
///  2. With AI off, opted out, with no AI choice made yet or with no active plan, the switch is
///     grayed out and the stored choice is kept as it was, so it comes back when AI does.
///  3. An inbox row (`MessageRowView`) on screen follows the same AI state: with Chat View on, AI
///     on and an active plan it shows the email's text message, and once the device opts out of
///     AI the same row shows the snippet, without being built again.
@Suite("Chat View switch", .serialized, .processGlobalState)
@MainActor
struct ChatViewToggleRowTests {

    /// AI on; AI off because the user opted out; AI off because the AI choice is not made yet; AI
    /// off because there is no active plan (the subscription gate is closed while the user still
    /// consents).
    enum AIState: CaseIterable, Sendable { case on, optedOut, noChoice, noPlan }

    @Test("The switch works while AI is on and stores the choice; with AI off it is grayed out and the choice is kept",
          arguments: AIState.allCases)
    func switchFollowsAI(state: AIState) async throws {
        let aiOn = state == .on
        let defaults = UserDefaults.standard
        let savedChoice = defaults.object(forKey: ChatViewConfig.enabledKey)
        let restoreAISetting = AITestSetting.save()
        let gate = AISubscriptionGate.shared
        let gateWasOpen = gate.isActive
        defer {
            defaults.set(savedChoice, forKey: ChatViewConfig.enabledKey)
            restoreAISetting()
            if gateWasOpen { gate.openGate() } else { gate.closeGate() }
        }
        if state == .noPlan { gate.closeGate() } else { gate.openGate() }
        if state == .noChoice { AITestSetting.clear() } else { AITestSetting.set(aiOff: state == .optedOut) }
        // With AI off the stored choice is on, so the test sees it shown and kept.
        defaults.set(!aiOn, forKey: ChatViewConfig.enabledKey)
        #expect(gate.isActive == (state != .noPlan), "control: the plan state is set")

        let window = try Self.host(Form { ChatViewToggleRow() })
        defer { window.isHidden = true }
        let control = try #require(await Self.waitForSwitch(in: window), "the row renders a switch")
        #expect(control.isOn == !aiOn, "it shows the stored choice")
        if aiOn {
            #expect(control.isEnabled, "AI on: the switch can be used")
            control.setOn(true, animated: false)
            control.sendActions(for: .valueChanged)
            let stored = await Self.waitUntil { defaults.bool(forKey: ChatViewConfig.enabledKey) }
            #expect(stored, "flipping the switch stores the choice")
        } else {
            #expect(!control.isEnabled, "AI off: the switch is grayed out")
            try await Task.sleep(for: .milliseconds(100))
            #expect(defaults.object(forKey: ChatViewConfig.enabledKey) as? Bool == true,
                    "AI off leaves the stored choice as it was")
        }
    }

    // Chat View on, the AI choice made with AI on, and an active plan: a row on screen shows the
    // email's text message. Opting out of AI on this device is the only change (the choice stays
    // made, the plan stays active, Chat View stays on), so the same mounted row must repaint to
    // the snippet.
    @Test("A row on screen shows the text message while AI is on and the snippet once the device opts out")
    func rowFollowsTheOptOut() async throws {
        #expect(HostedAccessibility.isAvailable, "control: the test can read the hosted row")
        let defaults = UserDefaults.standard
        let savedChoice = defaults.object(forKey: ChatViewConfig.enabledKey)
        let restoreAISetting = AITestSetting.save()
        let gate = AISubscriptionGate.shared
        let gateWasOpen = gate.isActive
        defer {
            defaults.set(savedChoice, forKey: ChatViewConfig.enabledKey)
            restoreAISetting()
            if gateWasOpen { gate.openGate() } else { gate.closeGate() }
        }
        defaults.set(true, forKey: ChatViewConfig.enabledKey)
        AITestSetting.set(aiOff: false)
        gate.openGate()
        #expect(gate.isActive, "control: an active plan")
        #expect(!AIService.isAIOff, "control: the AI choice is made, with AI on")
        #expect(!DemoModeStore.shared.hidesAIContent, "control: no demo hides AI")
        #expect(!TutorialCoordinator.shared.isRunning, "control: no tutorial run decides the view")

        let textMessage = "See you at noon"
        let snippet = "Lunch moves to noon on Friday, details below"
        var header = MessageHeader(
            messageId: "1", subject: "Plans", from: "Alex", fromAddress: "alex@example.com",
            to: "me@example.com", date: Date(), snippet: snippet, folderId: "acc1:INBOX",
            accountId: "acc1", folderPath: "INBOX", isInInbox: true)
        header.summaryTextMessage = textMessage
        let row = MessageSnapshot(from: header)
        let chatLine = row.preview(chatViewActive: true)
        let classicLine = row.preview(chatViewActive: false)
        #expect(chatLine == textMessage, "control: the chat-style line is the text message")
        #expect(classicLine == snippet, "control: the classic line is the snippet")

        try await HostedAccessibility.withAutomation {
            let window = try Self.host(MessageRowView(message: row))
            defer {
                window.isHidden = true
                window.rootViewController = nil
            }
            let rowShows = { (line: String) in HostedAccessibility.labels(in: window).contains(line) }

            let chatRow = await Self.waitUntil(seconds: 8) { rowShows(textMessage) }
            let beforeLabels = HostedAccessibility.labels(in: window)
            #expect(chatRow, "AI on: the row shows the text message: \(beforeLabels)")
            let beforeShowsSnippet = rowShows(snippet)
            #expect(!beforeShowsSnippet, "AI on: the row does not show the snippet")

            AITestSetting.set(aiOff: true)
            #expect(AIService.isAIOff, "control: the device opted out")
            #expect(gate.isActive, "control: the plan is still active")
            #expect(ChatViewConfig.isEnabledByUser, "control: Chat View is still on")

            let classicRow = await Self.waitUntil(seconds: 8) { rowShows(snippet) }
            let afterLabels = HostedAccessibility.labels(in: window)
            #expect(classicRow, "opted out: the same row shows the snippet: \(afterLabels)")
            let afterShowsText = rowShows(textMessage)
            #expect(!afterShowsText, "opted out: the row no longer shows the text message")
        }
    }

    // MARK: - Hosting

    private struct HostingFailure: Error, CustomStringConvertible {
        let description: String
    }

    private static func host<V: View>(_ view: V) throws -> UIWindow {
        guard let scene = UIApplication.shared.connectedScenes.compactMap({ $0 as? UIWindowScene }).first else {
            throw HostingFailure(description: "no UIWindowScene is available to host the row")
        }
        let controller = UIHostingController(rootView: view)
        let window = UIWindow(windowScene: scene)
        window.frame = CGRect(x: 0, y: 0, width: 390, height: 400)
        window.rootViewController = controller
        window.isHidden = false
        window.makeKeyAndVisible()
        window.layoutIfNeeded()
        return window
    }

    private static func switches(in view: UIView) -> [UISwitch] {
        (view as? UISwitch).map { [$0] } ?? view.subviews.flatMap { switches(in: $0) }
    }

    /// Bounded: a row that never renders a switch fails the test rather than hanging it.
    private static func waitForSwitch(in window: UIWindow) async -> UISwitch? {
        _ = await waitUntil { switches(in: window).count == 1 }
        let found = switches(in: window)
        return found.count == 1 ? found[0] : nil
    }

    private static func waitUntil(seconds: TimeInterval = 2, _ condition: () -> Bool) async -> Bool {
        let deadline = Date().addingTimeInterval(seconds)
        while Date() < deadline {
            if condition() { return true }
            try? await Task.sleep(for: .milliseconds(20))
        }
        return condition()
    }
}
