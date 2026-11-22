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
///     AI the same row shows the snippet, without being built again. This holds for an untagged
///     row and for a tagged one, whose chip branch reads nothing else that changes with the
///     opt-out, so only the preview's own reading of the setting can repaint it.
///
/// Each test puts back the Chat View choice, the AI setting and the subscription gate it found
/// (`AIGateTestState`: the gate's open state, its checked bit and both stored values, which
/// `gateStateComesBackAsFound` checks).
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
        let gateState = AIGateTestState()
        defer {
            defaults.set(savedChoice, forKey: ChatViewConfig.enabledKey)
            restoreAISetting()
            gateState.restore()
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
    // the snippet. A tagged single inbox row draws the tag chip instead of the classify spinner:
    // its shimmer reads the plan alone and its thread spinner needs a thread, so nothing but the
    // preview's own reading of the opt-out can repaint it.
    @Test("A row on screen shows the text message while AI is on and the snippet once the device opts out",
          arguments: [false, true])
    func rowFollowsTheOptOut(tagged: Bool) async throws {
        #expect(HostedAccessibility.isAvailable, "control: the test can read the hosted row")
        let defaults = UserDefaults.standard
        let savedChoice = defaults.object(forKey: ChatViewConfig.enabledKey)
        let restoreAISetting = AITestSetting.save()
        let gate = AISubscriptionGate.shared
        let gateState = AIGateTestState()
        defer {
            defaults.set(savedChoice, forKey: ChatViewConfig.enabledKey)
            restoreAISetting()
            gateState.restore()
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
        if tagged { header.actionTag = .reply }
        let row = MessageSnapshot(from: header)
        let chatLine = row.preview(chatViewActive: true)
        let classicLine = row.preview(chatViewActive: false)
        #expect(chatLine == textMessage, "control: the chat-style line is the text message")
        #expect(classicLine == snippet, "control: the classic line is the snippet")
        let rowTag = row.actionTag
        let expectedTag: ActionTag? = tagged ? .reply : nil
        #expect(rowTag == expectedTag, "control: the row is tagged (\(tagged)), a single inbox row")
        #expect(row.isInInbox, "control: the row is in the inbox, so a tag draws the chip")

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
            let choiceMade = AIService.optOutStore.bool(forKey: AIService.aiChoiceMadeKey)
            #expect(choiceMade, "control: the AI choice is still made")
            #expect(gate.isActive, "control: the plan is still active")
            #expect(ChatViewConfig.isEnabledByUser, "control: Chat View is still on")

            let classicRow = await Self.waitUntil(seconds: 8) { rowShows(snippet) }
            let afterLabels = HostedAccessibility.labels(in: window)
            #expect(classicRow, "opted out: the same row shows the snippet: \(afterLabels)")
            let afterShowsText = rowShows(textMessage)
            #expect(!afterShowsText, "opted out: the row no longer shows the text message")
        }
    }

    // The fixture every test here puts the subscription gate back with (`AIGateTestState`): what a
    // test changes when it opens the gate (the open state, the checked bit and both stored values)
    // is back as found after `restore()`, a stored false and an absent value included.
    @Test("Putting the subscription gate back restores its open state, its checked bit, a stored false and an absent value")
    func gateStateComesBackAsFound() {
        let activeKey = "ai_subscription_last_known_active"
        let checkedKey = "ai_subscription_has_checked_once"
        let defaults = UserDefaults.standard
        let gate = AISubscriptionGate.shared
        let asTheTestFoundIt = AIGateTestState()
        defer { asTheTestFoundIt.restore() }

        // The state to come back to: the gate closed and never checked, one value stored as false
        // and the other absent.
        gate.restoreForTesting(isActive: false, hasCheckedOnce: false)
        defaults.set(false, forKey: activeKey)
        defaults.removeObject(forKey: checkedKey)
        let found = AIGateTestState()

        gate.openGate()
        let openedActive = gate.isActive
        let openedChecked = gate.hasCheckedOnce
        let openedActiveValue = defaults.object(forKey: activeKey) as? Bool
        let openedCheckedValue = defaults.object(forKey: checkedKey) as? Bool
        #expect(openedActive, "control: opening the gate opens it")
        #expect(openedChecked, "control: opening the gate stamps it checked")
        #expect(openedActiveValue == true, "control: opening the gate stores the open state")
        #expect(openedCheckedValue == true, "control: opening the gate stores the checked bit")

        found.restore()
        let isActive = gate.isActive
        let hasCheckedOnce = gate.hasCheckedOnce
        let activeValue = defaults.object(forKey: activeKey) as? Bool
        let checkedAbsent = defaults.object(forKey: checkedKey) == nil
        #expect(!isActive, "the gate is closed again")
        #expect(!hasCheckedOnce, "the gate's checked bit is clear again")
        #expect(activeValue == false, "the stored false is back")
        #expect(checkedAbsent, "the absent value is absent again")
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
