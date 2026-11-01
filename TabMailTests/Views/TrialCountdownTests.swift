/* This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at https://mozilla.org/MPL/2.0/. */

import Foundation
import Darwin
import Observation
import SwiftUI
import Synchronization
import Testing
import UIKit
import Vision
@testable import TabMail

private func cancelledCountdownAccount(now: Date) throws -> AccountInfo {
    let end = Int(now.addingTimeInterval(3 * AccountPlanConfig.secondsPerDay).timeIntervalSince1970)
    let json: [String: Any] = ["logged_in": true, "has_subscription": true, "plan_tier": "Basic",
        "subscription_provider": "stripe", "trial": ["is_trial": true, "trial_end": end],
        "pending_cancellation": ["cancel_at": end]]
    return try JSONDecoder().decode(AccountInfo.self, from: JSONSerialization.data(withJSONObject: json))
}

struct TrialCountdownModelTests {
    @Test(arguments: [0.1, 1.5, 14.0])
    func signupUsesThePromisedDeadline(days: Double) throws {
        let now = Date()
        let info = try WhoamiFixture.runningSignupTrial(daysLeft: days, reference: now)
        let notice = try #require(TrialCountdownNotice.from(info, now: now))
        let promisedEnd = try #require(info.trial?.trialEnd)
        #expect(notice.end.timeIntervalSince1970 == Double(promisedEnd))
        #expect(notice.kind == .signup)
        let text = try #require(notice.presentation(now: now))
        let expected = days == 0.1 ? "1 day left" : days == 1.5 ? "2 days left" : "14 days left"
        #expect(text.title.contains(expected))
        #expect(text.actionTitle == "Plans")
        #expect(text.detail == "Ends \(notice.end.formatted(date: .abbreviated, time: .omitted))")
        #expect(notice.presentation(now: notice.end) == nil)
        #expect(notice.presentation(now: notice.end.addingTimeInterval(1)) == nil)
    }

    @Test(arguments: ["apple", "stripe"])
    func purchasedTrialsUseManageWithoutReplacingSignupRules(provider: String) throws {
        let now = Date()
        let info = try WhoamiFixture.cardTrial(provider: provider, planTier: "Basic", daysLeft: 4, reference: now)
        let notice = try #require(TrialCountdownNotice.from(info, now: now))
        #expect(notice.kind == .subscription)
        #expect(notice.presentation(now: now)?.actionTitle == "Manage")
        #expect(notice.presentation(now: now)?.title == "Free until \(notice.end.formatted(date: .abbreviated, time: .omitted))")
        #expect(notice.presentation(now: now)?.detail.contains("Payment begins") == true)
        #expect(info.trialState(now: now) == .noTrial)
    }

    @Test func absentEndedPaidAndZeroAccountsHaveNoCountdown() throws {
        let now = Date()
        let accounts = [
            try WhoamiFixture.signedInWithoutSubscription(),
            try WhoamiFixture.expiredSignupTrial(endedDaysAgo: 1, reference: now),
            try WhoamiFixture.accountInfo(hasSubscription: true),
            try WhoamiFixture.cardTrial(provider: "apple", planTier: "BYOK", daysLeft: 4, reference: now),
            try WhoamiFixture.accountInfo(hasSubscription: true, planTier: "Trial", provider: "signup", isTrial: true)
        ]
        for info in accounts { #expect(TrialCountdownNotice.from(info, now: now) == nil) }
    }

    @Test func cancelledRenewalDoesNotPromiseAPayment() throws {
        let now = Date()
        let info = try cancelledCountdownAccount(now: now)
        let notice = try #require(TrialCountdownNotice.from(info, now: now))
        let copy = try #require(notice.presentation(now: now))
        #expect(copy.detail == "Renewal is cancelled.")
        #expect(copy.actionTitle == "Manage")
        #expect(!copy.detail.contains("Payment"))
    }

    @Test func clockScheduleReachesEveryLabelChangeAndTheExactExpiry() {
        let now = Date()
        let day = AccountPlanConfig.secondsPerDay
        let end = now.addingTimeInterval(2.5 * day)
        let schedule = TrialCountdownSchedule(end: end)
        let dates = Array(schedule.entries(from: now, mode: .normal))
        #expect(dates == [now, now.addingTimeInterval(0.5 * day), now.addingTimeInterval(1.5 * day), end])
        #expect(Array(schedule.entries(from: end, mode: .normal)) == [end])
        let after = end.addingTimeInterval(day)
        #expect(Array(schedule.entries(from: after, mode: .normal)) == [after])
    }
}

@MainActor
private struct TrialCountdownGateScope {
    let active = AISubscriptionGate.shared.isActive
    let ended = AISubscriptionGate.shared.trialHasEnded
    let demo = DemoModeStore.shared.isActive

    init() {
        AISubscriptionGate.shared.noteSignedOut()
        DemoModeStore.shared.isActive = false
    }

    func close() {
        let info: AccountInfo?
        if ended {
            info = try? WhoamiFixture.expiredSignupTrial(endedDaysAgo: 1, reference: Date())
        } else {
            info = try? WhoamiFixture.accountInfo(hasSubscription: true)
        }
        if let info { AISubscriptionGate.shared.apply(info) }
        AISubscriptionGate.shared.noteSignedOut()
        if active { AISubscriptionGate.shared.openGate() } else { AISubscriptionGate.shared.closeGate() }
        DemoModeStore.shared.isActive = demo
    }
}

@Suite("Authoritative inbox countdown", .serialized, .processGlobalState)
@MainActor
struct TrialCountdownGateTests {
    @Test func onlyAuthoritativeAccountStateWritesTheNotice() throws {
        let scope = TrialCountdownGateScope()
        defer { scope.close() }
        let gate = AISubscriptionGate.shared
        let now = Date()
        #expect(gate.trialCountdownNotice == nil)
        let info = try WhoamiFixture.runningSignupTrial(daysLeft: 14, reference: now)
        gate.apply(info, now: now)
        let original = try #require(gate.trialCountdownNotice)
        gate.closeGate()
        gate.openGate()
        gate.refreshAfterLocalPurchase(try WhoamiFixture.cardTrial(provider: "apple", planTier: "Basic", daysLeft: 7, reference: now))
        #expect(gate.trialCountdownNotice == original)
        #expect(gate.lastAuthoritativeApplyAt == now)
        gate.apply(try WhoamiFixture.accountInfo(hasSubscription: true), now: now)
        #expect(gate.trialCountdownNotice == nil)
        #expect(gate.isActive)
    }

    @Test(arguments: [false, true])
    func aPreviousGenerationCannotRestoreTheNotice(sameUser: Bool) throws {
        let scope = TrialCountdownGateScope()
        defer { scope.close() }
        let gate = AISubscriptionGate.shared
        let now = Date()
        gate.noteSignedIn(userId: "first-user")
        let oldGeneration = gate.signInGeneration
        let oldInfo = try WhoamiFixture.runningSignupTrial(daysLeft: 14, reference: now)
        gate.applyIfCurrentEpoch(oldInfo, fetchedInGeneration: oldGeneration, now: now)
        #expect(gate.trialCountdownNotice != nil)
        gate.noteSignedOut()
        #expect(gate.trialCountdownNotice == nil)
        gate.noteSignedIn(userId: sameUser ? "first-user" : "second-user")
        gate.applyIfCurrentEpoch(oldInfo, fetchedInGeneration: oldGeneration, now: now)
        #expect(gate.trialCountdownNotice == nil)
        #expect(gate.lastAuthoritativeApplyAt == nil)
        gate.applyIfCurrentEpoch(oldInfo, fetchedInGeneration: gate.signInGeneration, now: now)
        #expect(gate.trialCountdownNotice != nil)
        gate.noteSignedIn(userId: "third-user")
        #expect(gate.trialCountdownNotice == nil)
    }

    @Test func passingTheDisplayDeadlineDoesNotMutateTheEntitlement() throws {
        let scope = TrialCountdownGateScope()
        defer { scope.close() }
        let gate = AISubscriptionGate.shared
        let now = Date()
        gate.apply(try WhoamiFixture.runningSignupTrial(daysLeft: 1, reference: now), now: now)
        let notice = try #require(gate.trialCountdownNotice)
        #expect(notice.presentation(now: notice.end) == nil)
        #expect(gate.isActive)
        #expect(!gate.trialHasEnded)
        #expect(gate.lastAuthoritativeApplyAt == now)
    }

    @Test func sameUserFallbackAndBackstopRetainAnAuthoritativeNotice() throws {
        let scope = TrialCountdownGateScope()
        defer { scope.close() }
        let gate = AISubscriptionGate.shared
        let now = Date()
        gate.apply(try WhoamiFixture.runningSignupTrial(daysLeft: 3, reference: now), now: now)
        let notice = try #require(gate.trialCountdownNotice)
        let generation = gate.signInGeneration
        let owner = "11111111-1111-4111-8111-111111111111"
        gate.noteSignedIn(userId: owner, previousUserId: owner)
        #expect(gate.trialCountdownNotice == notice)
        #expect(gate.lastAuthoritativeApplyAt == now)
        #expect(gate.signInGeneration == generation)
        gate.noteSignedIn(userId: owner)
        #expect(gate.trialCountdownNotice == notice)
        #expect(gate.lastAuthoritativeApplyAt == now)
        #expect(gate.signInGeneration == generation)
    }
}

/// Hosts the actual inbox, not a reconstructed banner layout. OCR runs only on
/// a stable top-of-screen image; it is never part of an animation polling loop.
@MainActor
private final class TrialCountdownInboxHost {
    let window: UIWindow
    private var controller: UIViewController?

    init(demo: Bool = false, otherFolder: Bool = false, dark: Bool = false, largeText: Bool = false) throws {
        PreviewMocks.hideAllTips()
        DemoModeStore.shared.isActive = demo
        let folder = Folder(name: "Inbox", path: "INBOX", role: otherFolder ? .sent : .inbox, accountId: UUID().uuidString)
        let view = NavigationStack {
            InboxView(title: "Mailbox", folders: [folder], selection: .unified(otherFolder ? .sent : .inbox),
                      selectedMessageId: .constant(nil), pushedMessageId: .constant(nil))
        }
        .environment(NavigationStore())
        .environment(\.hasTabMailSession, true)
        .environment(\.locale, Locale(identifier: "en_US"))
        .dynamicTypeSize(largeText ? .accessibility3 : .large)
        let scene = try #require(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let host = UIHostingController(rootView: view)
        controller = host
        window = UIWindow(windowScene: scene)
        window.frame = CGRect(x: 0, y: 0, width: 390, height: 844)
        window.overrideUserInterfaceStyle = dark ? .dark : .light
        window.rootViewController = host
        window.makeKeyAndVisible()
        window.layoutIfNeeded()
        host.view.layoutIfNeeded()
    }

    func close() {
        window.isHidden = true
        controller?.view.removeFromSuperview()
        window.rootViewController = nil
        controller = nil
    }

    func activateReminder() async throws {
        let view = try #require(controller?.view)
        for _ in 0..<100 {
            if let element = countdownAccessibilityElement(in: view, identifier: "inbox-trial-countdown") {
                _ = element.accessibilityActivate()
                return
            }
            try await Task.sleep(for: .milliseconds(50))
        }
        var trace: [String] = []
        _ = countdownAccessibilityElement(in: view, identifier: "inbox-trial-countdown", trace: {
            if trace.count < 60 { trace.append($0) }
        })
        Issue.record(Comment(rawValue: "Rendered reminder AX tree: " + trace.joined(separator: " | ")))

    }

    private func frame() throws -> CGImage {
        let view = try #require(controller?.view)
        view.layoutIfNeeded()
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        format.opaque = true
        var drawn = false
        let image = UIGraphicsImageRenderer(bounds: view.bounds, format: format).image { _ in
            drawn = view.drawHierarchy(in: view.bounds, afterScreenUpdates: true)
        }
        try #require(drawn)
        let cg = try #require(image.cgImage)
        return try #require(cg.cropping(to: CGRect(x: 0, y: 0, width: cg.width, height: min(cg.height, 440))))
    }

    func text() async throws -> String {
        var previous = try frame()
        for _ in 0..<60 {
            try await Task.sleep(for: .milliseconds(50))
            let next = try frame()
            if let a = previous.dataProvider?.data, let b = next.dataProvider?.data, (a as Data) == (b as Data) {
                let request = VNRecognizeTextRequest()
                request.revision = VNRecognizeTextRequestRevision3
                request.recognitionLevel = .accurate
                request.recognitionLanguages = ["en-US"]
                request.usesLanguageCorrection = false
                try VNImageRequestHandler(cgImage: next, options: [:]).perform([request])
                return try #require(request.results).compactMap { $0.topCandidates(1).first?.string }
                    .joined(separator: " ").split(whereSeparator: \.isWhitespace).joined(separator: " ").lowercased()
            }
            previous = next
        }
        Issue.record("The actual inbox did not produce a stable banner-region frame")
        return ""
    }
}

@Suite("Real inbox trial reminder", .serialized, .processGlobalState)
@MainActor
struct TrialCountdownInboxTests {
    @Test(arguments: [false, true])
    func theActualInboxShowsCancelledRenewalWithoutAPaymentClaim(dark: Bool) async throws {
        let scope = TrialCountdownGateScope()
        defer { scope.close() }
        AISubscriptionGate.shared.apply(try cancelledCountdownAccount(now: Date()))
        let host = try TrialCountdownInboxHost(dark: dark, largeText: dark)
        defer { host.close() }
        let text = try await host.text()
        #expect(text.contains("mailbox"))
        #expect(text.contains("renewal is cancelled"))
        #expect(text.contains("manage"))
        #expect(!text.contains("payment begins"))
    }

    @Test(arguments: [false, true])
    func theActualInboxShowsAuthorityAndClearsItOnSignOut(dark: Bool) async throws {
        let scope = TrialCountdownGateScope()
        defer { scope.close() }
        let gate = AISubscriptionGate.shared
        gate.apply(try WhoamiFixture.runningSignupTrial(daysLeft: 3, reference: Date()))
        let host = try TrialCountdownInboxHost(dark: dark)
        defer { host.close() }
        let before = try await host.text()
        #expect(before.contains("mailbox"))
        #expect(before.contains("3 days left"))
        #expect(before.contains("plans"))
        gate.noteSignedOut()
        let after = try await host.text()
        #expect(after.contains("mailbox"))
        #expect(!after.contains("free trial"))
        #expect(!after.contains("days left"))
    }

    @Test(arguments: [false, true])
    func theActualDemoAndOtherFoldersDoNotShowTheReminder(demo: Bool) async throws {
        let scope = TrialCountdownGateScope()
        defer { scope.close() }
        AISubscriptionGate.shared.apply(try WhoamiFixture.runningSignupTrial(daysLeft: 3, reference: Date()))
        let host = try TrialCountdownInboxHost(demo: demo, otherFolder: !demo)
        defer { host.close() }
        let text = try await host.text()
        #expect(text.contains("mailbox"))
        #expect(!text.contains("days left"))
        #expect(!text.contains("free trial"))
    }

    @Test(.timeLimit(.minutes(1)))
    func theRenderedInboxButtonRequestsPlansOnlyAfterActivation() async throws {
        let automation = try CountdownAccessibilityAutomation()
        defer { automation.close() }
        let scope = TrialCountdownGateScope()
        defer { scope.close() }
        AISubscriptionGate.shared.apply(try WhoamiFixture.runningSignupTrial(daysLeft: 3, reference: Date()))
        let count = Mutex(0)
        let observer = NotificationCenter.default.addObserver(forName: .navigateToPlanPicker, object: nil, queue: nil) { _ in
            count.withLock { $0 += 1 }
        }
        defer { NotificationCenter.default.removeObserver(observer) }
        let host = try TrialCountdownInboxHost()
        defer { host.close() }
        #expect((try await host.text()).contains("3 days left"))
        #expect(count.withLock { $0 } == 0)
        try await host.activateReminder()
        for _ in 0..<100 {
            if count.withLock({ $0 > 0 }) { break }
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(count.withLock { $0 } == 1)
    }

    @Test(.timeLimit(.minutes(1)))
    func theActualInboxReplacesAnOldScheduleWhenAuthorityExtendsTheDeadline() async throws {
        let scope = TrialCountdownGateScope()
        defer { scope.close() }
        let gate = AISubscriptionGate.shared
        let now = Date()
        gate.apply(try WhoamiFixture.accountInfo(hasSubscription: true, planTier: "Trial", provider: "signup", isTrial: true,
            trialEnd: now.addingTimeInterval(8)), now: now)
        let host = try TrialCountdownInboxHost()
        defer { host.close() }
        #expect((try await host.text()).contains("1 day left"))
        let applied = Date()
        gate.apply(try WhoamiFixture.accountInfo(hasSubscription: true, planTier: "Basic", provider: "apple", isTrial: true,
            trialEnd: applied.addingTimeInterval(16)), now: applied)
        let notice = try #require(gate.trialCountdownNotice)
        #expect((try await host.text()).contains("free until"))
        try await Task.sleep(for: .seconds(max(0, notice.end.timeIntervalSinceNow) + 0.1))
        let after = try await host.text()
        #expect(!after.contains("free until"))
        #expect(gate.isActive && !gate.trialHasEnded)
        #expect(gate.lastAuthoritativeApplyAt == applied)
    }

    @Test(.timeLimit(.minutes(1)))
    func theActualInboxWithdrawsTheCountdownAtItsDeadlineWithoutClosingAccess() async throws {
        let scope = TrialCountdownGateScope()
        defer { scope.close() }
        let gate = AISubscriptionGate.shared
        let now = Date()
        let info = try WhoamiFixture.accountInfo(hasSubscription: true, planTier: "Trial", provider: "signup", isTrial: true,
                                               trialEnd: now.addingTimeInterval(8))
        gate.apply(info, now: now)
        let notice = try #require(gate.trialCountdownNotice)
        let host = try TrialCountdownInboxHost()
        defer { host.close() }
        let before = try await host.text()
        try #require(Date() < notice.end, "The fixture must still be before expiry at the positive control")
        #expect(before.contains("1 day left"))
        try await Task.sleep(for: .seconds(max(0, notice.end.timeIntervalSinceNow) + 0.1))
        let after = try await host.text()
        #expect(after.contains("mailbox"))
        #expect(!after.contains("day left"))
        #expect(!after.contains("free trial"))
        #expect(gate.isActive)
        #expect(!gate.trialHasEnded)
        #expect(gate.lastAuthoritativeApplyAt == now)
    }
}

@MainActor
func countdownAccessibilityElement(in root: NSObject, identifier: String, trace: ((String) -> Void)? = nil) -> NSObject? {
    var pending: [NSObject] = [root]
    var seen = Set<ObjectIdentifier>()
    while let object = pending.popLast(), seen.count < 2_048 {
        guard seen.insert(ObjectIdentifier(object)).inserted else { continue }
        let typed = (object as? UIAccessibilityIdentification)?.accessibilityIdentifier
        let selector = NSSelectorFromString("accessibilityIdentifier")
        let identifierValue = typed ?? (object.responds(to: selector)
            ? object.perform(selector)?.takeUnretainedValue() as? String : nil)
        trace?(String(reflecting: type(of: object)) + ":" + (identifierValue ?? "nil"))
        if identifierValue == identifier { return object }
        if let view = object as? UIView { pending.append(contentsOf: view.subviews) }
        pending.append(contentsOf: (object.accessibilityElements ?? []).compactMap { $0 as? NSObject })
        pending.append(contentsOf: (object.automationElements ?? []).compactMap { $0 as? NSObject })
        let count = object.accessibilityElementCount()
        if count > 0, count < 256 {
            for index in 0..<count {
                if let child = object.accessibilityElement(at: index) as? NSObject { pending.append(child) }
            }
        }
    }
    return nil
}

@MainActor @Observable
private final class CountdownPhase { var value: ScenePhase = .inactive }
@MainActor
private final class CountdownTaskStarts { var values: [Int] = [] }

@MainActor
private struct CountdownClockProbe: View {
    let notice: TrialCountdownNotice
    let phase: CountdownPhase
    let starts: CountdownTaskStarts
    var body: some View {
        TrialCountdownBanner(notice: notice, clockTaskStarted: { starts.values.append($0) })
            .environment(\.scenePhase, phase.value)
    }
}

@Suite("Mounted countdown clock lifecycle", .serialized, .processGlobalState)
@MainActor
struct TrialCountdownClockTests {
    @Test(.timeLimit(.minutes(1)))
    func foregroundAndSignificantTimeChangesRestartTheMountedScheduleWithoutChangingAuthority() async throws {
        let scope = TrialCountdownGateScope()
        defer { scope.close() }
        let gate = AISubscriptionGate.shared
        let now = Date()
        gate.apply(try WhoamiFixture.runningSignupTrial(daysLeft: 3, reference: now), now: now)
        let notice = try #require(gate.trialCountdownNotice)
        let phase = CountdownPhase()
        let starts = CountdownTaskStarts()
        let scene = try #require(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let controller = UIHostingController(rootView: CountdownClockProbe(notice: notice, phase: phase, starts: starts))
        let window = UIWindow(windowScene: scene)
        window.frame = CGRect(x: 0, y: 0, width: 390, height: 844)
        window.rootViewController = controller
        window.makeKeyAndVisible()
        defer { window.isHidden = true; controller.view.removeFromSuperview(); window.rootViewController = nil }
        func waitFor(_ count: Int) async throws {
            for _ in 0..<100 {
                if starts.values.count >= count { break }
                try await Task.sleep(for: .milliseconds(50))
            }
            try #require(starts.values.count == count)
        }
        try await waitFor(1)
        #expect(starts.values == [0])
        phase.value = .active
        try await waitFor(2)
        #expect(starts.values == [0, 1])
        NotificationCenter.default.post(name: UIApplication.significantTimeChangeNotification, object: nil)
        try await waitFor(3)
        #expect(starts.values == [0, 1, 2])
        #expect(gate.trialCountdownNotice == notice)
        #expect(gate.lastAuthoritativeApplyAt == now)
        #expect(gate.isActive && !gate.trialHasEnded)
    }
}


/// Simulator test bootstrap only. SwiftUI omits its accessibility nodes until
/// automation is enabled. This is never linked into a shipping app target.
/// The runtime entry points follow the AccessibilitySnapshot test-enabler
/// pattern; the actual control is located/activated through public UIKit APIs.
@MainActor
private final class CountdownAccessibilityAutomation {
    private let handle: UnsafeMutableRawPointer
    private let setter: @convention(c) (Int32) -> Void
    private let original: Int32
    private enum Failure: Error { case runtimeUnavailable }

    init() throws {
        #if targetEnvironment(simulator)
        let root = ProcessInfo.processInfo.environment["IPHONE_SIMULATOR_ROOT"] ?? ""
        guard let handle = dlopen(root + "/usr/lib/libAccessibility.dylib", RTLD_NOW | RTLD_LOCAL) else {
            throw Failure.runtimeUnavailable
        }
        guard let read = dlsym(handle, "_AXSAutomationEnabled"),
              let write = dlsym(handle, "_AXSSetAutomationEnabled") else {
            dlclose(handle)
            throw Failure.runtimeUnavailable
        }
        self.handle = handle
        let getter = unsafeBitCast(read, to: (@convention(c) () -> Int32).self)
        setter = unsafeBitCast(write, to: (@convention(c) (Int32) -> Void).self)
        original = getter()
        setter(1)
        #expect(getter() != 0)
        #else
        throw Failure.runtimeUnavailable
        #endif
    }

    func close() {
        setter(original)
        dlclose(handle)
    }
}
