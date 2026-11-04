/* This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at https://mozilla.org/MPL/2.0/. */

import Foundation
import Testing
@testable import TabMail

@Suite("Inbox trial reminder")
struct InboxTrialReminderTests {

    private func text(_ state: TrialState, isInbox: Bool = true, isSignedIn: Bool = true, isDemo: Bool = false) -> String? {
        InboxTrialReminder.text(for: state, isInbox: isInbox, isSignedIn: isSignedIn, isDemo: isDemo)
    }

    @Test("A running trial shows the days left")
    func copy() {
        #expect(text(.active(daysRemaining: 3)) == "Free trial · 3 days left")
        #expect(text(.active(daysRemaining: 1)) == "Free trial · 1 day left")
    }

    @Test("No trial or an ended trial shows no row")
    func otherTrialStates() {
        #expect(text(.noTrial) == nil)
        #expect(text(.ended) == nil)
    }

    @Test("Other folders, signed out and demo mode show no row")
    func hiddenOutsideTheSignedInInbox() {
        #expect(text(.active(daysRemaining: 3), isInbox: false) == nil)
        #expect(text(.active(daysRemaining: 3), isSignedIn: false) == nil)
        #expect(text(.active(daysRemaining: 3), isDemo: true) == nil)
    }

    /// The inbox reads `UsageThrottleStore.shared.trialState`, which the
    /// foreground `/whoami` refreshes through `update(from:)`. Each body here
    /// is decoded by the real parser, and the latest one decides, so an
    /// account switch to a non-trial account hides the row.
    @Test("The latest /whoami decides, and switching to a non-trial account hides the row")
    @MainActor
    func latestAccountDecides() throws {
        let now = Date()
        let store = UsageThrottleStore.shared
        let shown = { InboxTrialReminder.text(for: store.trialState, isInbox: true, isSignedIn: true, isDemo: false) }

        store.update(from: try WhoamiFixture.runningSignupTrial(daysLeft: 3, reference: now))
        #expect(shown() == "Free trial · 3 days left")

        store.update(from: try WhoamiFixture.cardTrial(provider: "apple", planTier: AccountPlanConfig.basicTierKey, daysLeft: 3, reference: now))
        #expect(shown() == nil)

        store.update(from: try WhoamiFixture.runningSignupTrial(daysLeft: 3, reference: now))
        store.update(from: try WhoamiFixture.accountInfo(hasSubscription: true, planTier: AccountPlanConfig.byokTierKey, provider: "stripe"))
        #expect(shown() == nil)

        store.update(from: try WhoamiFixture.expiredSignupTrial(endedDaysAgo: 1, reference: now))
        #expect(store.trialState == .ended)
        #expect(shown() == nil)

        // Leave the shared store on a no-trial, no-banner account.
        store.update(from: try WhoamiFixture.signedInWithoutSubscription())
        #expect(store.trialState == .noTrial)
    }

    /// The inbox and the store cannot be driven from a unit test: `InboxView`
    /// needs the whole mail environment, and the store is a singleton that
    /// tests share. So this reads their source and pins the three places the
    /// tests above do not reach: the inbox passes the real cached state and
    /// its own inbox, session and demo signals, Plans opens Choose a Plan, and
    /// the store starts with no trial, so nothing shows before the first
    /// `/whoami`.
    @Test("The inbox feeds the row its real inputs, Plans opens Choose a Plan, and the store starts with no trial")
    func wiring() throws {
        #expect(try Self.count(in: "TabMail/Views/Inbox/InboxView.swift",
            "if let trialReminder = InboxTrialReminder.text( for: UsageThrottleStore.shared.trialState, isInbox: isInboxView, isSignedIn: hasTabMailSession, isDemo: DemoModeStore.shared.isActive ) { InboxTrialReminder(text: trialReminder) }") == 1)
        #expect(try Self.count(in: "TabMail/Views/Inbox/InboxView.swift", "InboxTrialReminder") == 4,
            "two call sites in the inbox: the running-trial row and the trial-ended row")
        #expect(try Self.count(in: "TabMail/Views/Shared/InboxTrialReminder.swift",
            "Button(\"Plans\") { NotificationCenter.default.post(name: .navigateToPlanPicker, object: nil) }") == 1)
        #expect(try Self.count(in: "TabMail/Services/AI/UsageThrottleStore.swift",
            "private(set) var trialState: TrialState = .noTrial") == 1)
    }

    /// Occurrences of `needle` in a source file, with every run of whitespace
    /// made one space so line breaks and indentation do not matter.
    private static func count(in path: String, _ needle: String) throws -> Int {
        let projectRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let text = try String(contentsOf: projectRoot.appendingPathComponent(path), encoding: .utf8)
            .split(whereSeparator: \.isWhitespace).joined(separator: " ")
        return text.components(separatedBy: needle).count - 1
    }
}
