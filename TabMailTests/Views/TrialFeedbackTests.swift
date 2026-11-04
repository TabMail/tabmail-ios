/* This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at https://mozilla.org/MPL/2.0/. */

import Foundation
import SwiftUI
import Synchronization
import Testing
import UIKit
@testable import TabMail

/// The anonymous trial-feedback sheet (`TrialFeedback`, `TrialFeedbackForm`,
/// `TrialFeedbackSheet`, `TrialFeedbackPresentation`, `trialFeedbackSheetHost()`,
/// `trialFeedbackAutoOpen(isInbox:)`) and the trial-ended banners' Feedback
/// buttons (`InboxTrialReminder`, the folder list's subscribe banner).
///
/// INVARIANTS:
/// - It is presented only over the inbox of a signed-in, non-demo user whose
///   signup trial ENDED, never over another presentation, and once per
///   install: once it has appeared it never appears again.
/// - What is sent is `{version, reason, comment?}` and nothing else: no
///   account, user, device, token or cookie, in the body or the headers. It is
///   sent once, never retried.
/// - The comment field never holds more than the server's cap (500 code
///   points), and what Send sends is what the field shows.
/// - Nothing about the answer is written to the local log.
/// - Once the trial ended (no subscription), the inbox row reads "Free trial
///   ended" and both banners offer feedback, which opens the same sheet, until
///   an answer was SENT; Not now leaves it offered.
@Suite("Trial feedback", .serialized, .processGlobalState)
struct TrialFeedbackTests {

    // MARK: - When it is presented

    @Test("Due only on the inbox of a signed-in, non-demo user whose trial ended, not asked yet, with nothing else presented")
    func presentationMatrix() {
        let states: [TrialState] = [.noTrial, .active(daysRemaining: 1), .active(daysRemaining: 7), .ended]
        for state in states {
            for isInbox in [true, false] {
                for hasSession in [true, false] {
                    for isDemo in [true, false] {
                        for alreadyAsked in [true, false] {
                            for somethingPresented in [true, false] {
                                let expected = state == .ended && isInbox && hasSession && !isDemo && !alreadyAsked && !somethingPresented
                                #expect(
                                    TrialFeedback.shouldPresent(
                                        isInbox: isInbox, hasSession: hasSession, isDemo: isDemo, trialState: state,
                                        alreadyAsked: alreadyAsked, somethingPresented: somethingPresented
                                    ) == expected,
                                    "state=\(state) inbox=\(isInbox) session=\(hasSession) demo=\(isDemo) asked=\(alreadyAsked) presented=\(somethingPresented)"
                                )
                            }
                        }
                    }
                }
            }
        }
    }

    @Test("The copy and choices are the blessed ones, with the server's keys, in display order")
    func copyAndReasons() {
        #expect(TrialFeedback.navigationTitle == "Your free trial ended")
        #expect(TrialFeedback.question == "What held you back?")
        #expect(TrialFeedback.commentPlaceholder == "Anything else? (optional)")
        #expect(TrialFeedback.footnote == "Anonymous. Not linked to your account.")
        #expect(TrialFeedback.sendLabel == "Send")
        #expect(TrialFeedback.dismissLabel == "Not now")
        #expect(TrialFeedback.Reason.allCases.map(\.rawValue) == [
            "too_expensive", "not_used_enough", "missing_feature", "prefer_other_app", "something_else",
        ])
        #expect(TrialFeedback.Reason.allCases.map(\.label) == [
            "Too expensive", "Didn't use it enough", "Missing a feature I need", "I prefer another app", "Something else",
        ])
    }

    // MARK: - Request

    private func body(_ request: URLRequest) throws -> [String: Any] {
        let data = try #require(request.httpBody)
        let object = try JSONSerialization.jsonObject(with: data)
        return try #require(object as? [String: Any])
    }

    @Test("The request carries only version 1, the reason and an optional comment, and no identity")
    func requestHasNoIdentity() throws {
        for reason in TrialFeedback.Reason.allCases {
            let request = TrialFeedback.request(for: reason, comment: "")
            let json = try body(request)
            #expect(Set(json.keys) == ["version", "reason"])
            #expect(json["version"] as? Int == 1)
            #expect(json["reason"] as? String == reason.rawValue)
            #expect(request.httpMethod == "POST")
            #expect(request.httpShouldHandleCookies == false)
            #expect(request.allHTTPHeaderFields ?? [:] == ["Content-Type": "application/json"])
        }
    }

    @Test("Production posts to forms.tabmail.ai and the dev servers to forms-dev.tabmail.ai")
    func endpointHosts() {
        let defaults = UserDefaults.standard
        let unlockKey = "debug_mode_unlocked"
        let previousUnlock = defaults.object(forKey: unlockKey)
        let previousDev = BackendConfig.useDevServers
        defer {
            BackendConfig.useDevServers = previousDev
            if let previousUnlock { defaults.set(previousUnlock, forKey: unlockKey) } else { defaults.removeObject(forKey: unlockKey) }
        }
        defaults.set(true, forKey: unlockKey)
        BackendConfig.useDevServers = false
        #expect(TrialFeedback.request(for: .tooExpensive, comment: "").url?.absoluteString == "https://forms.tabmail.ai/feedback/trial")
        BackendConfig.useDevServers = true
        #expect(TrialFeedback.request(for: .tooExpensive, comment: "").url?.absoluteString == "https://forms-dev.tabmail.ai/feedback/trial")
    }

    @Test("A comment is sent exactly as typed; a blank one is left out")
    func commentAsTyped() throws {
        let typed = "  Needed calendar sync 😀 \"quoted\" \\ \n"
        #expect(try body(TrialFeedback.request(for: .missingFeature, comment: typed))["comment"] as? String == typed)
        for blank in ["", "   ", "\n\t"] {
            #expect(try body(TrialFeedback.request(for: .missingFeature, comment: blank))["comment"] == nil)
        }
    }

    // MARK: - Comment cap

    @Test("The field takes 500 code points and refuses the 501st; a longer paste is refused whole, never cut")
    @MainActor
    func commentCap() {
        let form = TrialFeedbackForm(session: Self.unusedSession)
        let atMax = String(repeating: "😀", count: 500) // one code point each, as the server counts
        #expect(form.edit(atMax))
        #expect(form.comment == atMax)
        #expect(form.edit(atMax + "a") == false)
        #expect(form.comment == atMax)

        let fresh = TrialFeedbackForm(session: Self.unusedSession)
        fresh.edit("ab")
        #expect(fresh.edit(String(repeating: "a", count: 510)) == false)
        #expect(fresh.comment == "ab")

        // A grapheme of several code points counts each one (7 for this family emoji).
        let family = "👨‍👩‍👧‍👦"
        #expect(family.unicodeScalars.count == 7)
        let near = TrialFeedbackForm(session: Self.unusedSession)
        let nearMax = String(repeating: "a", count: 494)
        near.edit(nearMax)
        #expect(near.edit(nearMax + family) == false)
        #expect(near.comment == nearMax)
        #expect(near.edit(String(repeating: "a", count: 493) + family))
        #expect(near.comment.unicodeScalars.count == 500)
    }

    /// For forms that never send: a fake session with no routes.
    private static let unusedSession = FakeHTTP.Scenario().session

    /// The answers a fake worker received, decoded.
    private static func answers(_ fake: FakeHTTP.Scenario) throws -> [[String: Any]] {
        try fake.recordedCalls().map { call in
            let data = try #require(call.body)
            return try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
        }
    }

    /// A fake worker that takes every answer.
    private static func acceptingWorker() -> FakeHTTP.Scenario {
        let fake = FakeHTTP.Scenario()
        fake.register(path: "/feedback/trial", method: "POST", response: .status(204))
        return fake
    }

    /// The sheet hosted in a window, with its one comment text view focused.
    @MainActor
    private static func hostSheet(_ form: TrialFeedbackForm) async throws -> (UIWindow, UITextView) {
        let host = UIHostingController(rootView: TrialFeedbackSheet(form: form))
        let window = try Self.window(host)
        try await Task.sleep(for: .milliseconds(300))
        host.view.layoutIfNeeded()
        let inputs = Self.descendants(host.view).compactMap { $0 as? UITextView }
        try #require(inputs.count == 1)
        let input = try #require(inputs.first)
        try #require(input.becomeFirstResponder())
        return (window, input)
    }

    @MainActor
    private static func descendants(_ root: UIView) -> [UIView] {
        [root] + root.subviews.flatMap { descendants($0) }
    }

    @MainActor
    private static func window(_ root: UIViewController) throws -> UIWindow {
        let scene = try #require(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let window = UIWindow(windowScene: scene)
        window.frame = CGRect(x: 0, y: 0, width: 390, height: 844)
        window.rootViewController = root
        window.makeKeyAndVisible()
        window.layoutIfNeeded()
        return window
    }

    @Test("The real comment field never shows more than 500 code points, and Send sends what it shows")
    @MainActor
    func visibleFieldStopsAtCap() async throws {
        let worker = Self.acceptingWorker()
        defer { worker.close() }
        let form = TrialFeedbackForm(session: worker.session)
        let (window, input) = try await Self.hostSheet(form)
        defer { window.isHidden = true; window.rootViewController = nil }
        let max = String(repeating: "a", count: 500)
        input.insertText(max)
        try await Task.sleep(for: .milliseconds(200))
        #expect(input.text == max)
        input.insertText("b")
        try await Task.sleep(for: .milliseconds(200))
        #expect(input.text == max)
        #expect(form.comment == max)
        input.resignFirstResponder()

        form.select(.somethingElse)
        await form.send()?.value
        let sent = try Self.answers(worker)
        #expect(sent.count == 1)
        guard sent.count == 1 else { return }
        #expect(sent[0]["comment"] as? String == max)
    }

    @Test("Replacing the text with canonically equal text of more than 500 code points is refused whole, and Send sends the bytes shown")
    @MainActor
    func canonicallyEqualReplacementRefused() async throws {
        let worker = Self.acceptingWorker()
        defer { worker.close() }
        let form = TrialFeedbackForm(session: worker.session)
        let (window, input) = try await Self.hostSheet(form)
        defer { window.isHidden = true; window.rootViewController = nil }
        // 500 precomposed "é" (500 scalars), then the same text decomposed
        // ("e" + combining acute, 1,000 scalars): Swift's == holds them equal.
        let composed = String(repeating: "\u{e9}", count: 500)
        let decomposed = String(repeating: "e\u{301}", count: 500)
        try #require(composed == decomposed)
        input.insertText(composed)
        try await Task.sleep(for: .milliseconds(300))
        try #require(input.text.unicodeScalars.elementsEqual(composed.unicodeScalars))
        input.selectedRange = NSRange(location: 0, length: input.text.utf16.count)
        input.insertText(decomposed)
        try await Task.sleep(for: .milliseconds(400))
        input.resignFirstResponder()
        // The field may rebuild its text view: read whichever one shows now.
        let view = try #require(window.rootViewController?.view)
        view.layoutIfNeeded()
        let shownViews = Self.descendants(view).compactMap { $0 as? UITextView }
        try #require(shownViews.count == 1)
        let shown = try #require(shownViews.first)
        #expect(shown.text.unicodeScalars.count == 500)
        #expect(shown.text.unicodeScalars.elementsEqual(composed.unicodeScalars))
        #expect(form.comment.unicodeScalars.elementsEqual(composed.unicodeScalars))

        form.select(.somethingElse)
        await form.send()?.value
        let calls = worker.recordedCalls()
        #expect(calls.count == 1)
        guard calls.count == 1 else { return }
        let body = try #require(calls[0].body)
        let sent = try #require(JSONSerialization.jsonObject(with: body) as? [String: Any])
        let comment = try #require(sent["comment"] as? String)
        #expect(comment.unicodeScalars.elementsEqual(shown.text.unicodeScalars))
    }

    // MARK: - The form

    @Test("Send is off until a choice is picked, sends once, and sends the answer as it was at Send")
    @MainActor
    func formSendsOnce() async throws {
        let worker = Self.acceptingWorker()
        defer { worker.close() }
        let form = TrialFeedbackForm(session: worker.session)
        #expect(form.canSend == false)
        #expect(form.send() == nil)
        form.edit("Needed calendar sync")
        #expect(form.canSend == false)
        form.select(.tooExpensive)
        form.select(.missingFeature) // the last choice wins
        #expect(form.selected == .missingFeature)
        #expect(form.canSend)
        let task = form.send()
        form.edit("changed after Send")
        #expect(form.canSend == false)
        #expect(form.send() == nil)
        await task?.value
        let sent = try Self.answers(worker)
        #expect(sent.count == 1)
        guard sent.count == 1 else { return }
        #expect(sent[0]["reason"] as? String == "missing_feature")
        #expect(sent[0]["comment"] as? String == "Needed calendar sync")
    }

    @Test("A form posts on the app's shared ephemeral session unless given another")
    @MainActor
    func formUsesTheSharedEphemeralSession() {
        #expect(TrialFeedbackForm().session === sharedEphemeralSession)
    }

    // MARK: - Send

    @Test("Send makes exactly one POST with the answer, whatever the worker answers")
    func sendOnceOverStatuses() async throws {
        for status in [204, 400, 413, 429, 404, 500, 503] {
            let fake = FakeHTTP.Scenario()
            defer { fake.close() }
            fake.register(path: "/feedback/trial", method: "POST", response: .status(status))
            await TrialFeedback.send(.tooExpensive, comment: "x", session: fake.session)
            let calls = fake.recordedCalls()
            #expect(calls.count == 1, "status=\(status)")
            guard calls.count == 1 else { continue }
            let sent = try #require(calls[0].body)
            let json = try #require(JSONSerialization.jsonObject(with: sent) as? [String: Any])
            #expect(json["reason"] as? String == "too_expensive")
            #expect(json["comment"] as? String == "x")
        }
    }

    @Test("A transport failure is not retried")
    func transportFailureNotRetried() async {
        for error in [URLError.notConnectedToInternet, .timedOut, .networkConnectionLost, .cancelled] {
            let fake = FakeHTTP.Scenario()
            defer { fake.close() }
            fake.register(path: "/feedback/trial", method: "POST", response: .transportError(error))
            await TrialFeedback.send(.tooExpensive, comment: "x", session: fake.session)
            #expect(fake.recordedCalls().count == 1, "error=\(error.rawValue)")
        }
    }

    @Test("An answer the worker accepted but whose reply was lost is not posted again")
    func lostReplyNotResent() async throws {
        let accepted = Mutex<[Data]>([])
        let fake = FakeHTTP.Scenario()
        defer { fake.close() }
        let comment = "Synthetic feedback after a lost reply"
        fake.register(path: "/feedback/trial", method: "POST") { request in
            if let data = request.body { accepted.withLock { $0.append(data) } }
            return .transportError(.networkConnectionLost)
        }
        await TrialFeedback.send(.missingFeature, comment: comment, session: fake.session)
        #expect(fake.recordedCalls().count == 1)
        let records = accepted.withLock { $0 }
        #expect(records.count == 1)
        guard records.count == 1 else { return }
        let json = try #require(JSONSerialization.jsonObject(with: records[0]) as? [String: Any])
        #expect(json["reason"] as? String == "missing_feature")
        #expect(json["comment"] as? String == comment)
    }

    @Test("The local debug log never holds the reason or the comment")
    func noAnswerInTheLog() async throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("trial-feedback-log-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let url = dir.appendingPathComponent("app.log")
        let previousFile = AppLogStore.fileURLOverride.withLock { $0 }
        let previousGate = DebugModeManager.loggingEnabledOverrideForTesting.withLock { $0 }
        AppLogStore.fileURLOverride.withLock { $0 = url }
        DebugModeManager.loggingEnabledOverrideForTesting.withLock { $0 = true }
        defer {
            _ = AppLogStore.read()
            AppLogStore.fileURLOverride.withLock { $0 = previousFile }
            DebugModeManager.loggingEnabledOverrideForTesting.withLock { $0 = previousGate }
            try? FileManager.default.removeItem(at: dir)
        }
        let comment = "Synthetic feedback that must stay out of the local log"
        let ok = FakeHTTP.Scenario()
        defer { ok.close() }
        ok.register(path: "/feedback/trial", method: "POST", response: .status(204))
        let failing = FakeHTTP.Scenario()
        defer { failing.close() }
        failing.register(path: "/feedback/trial", method: "POST", response: .transportError(.timedOut))
        BackgroundSyncLogger.logDebug("trial-feedback-log-control")
        for reason in TrialFeedback.Reason.allCases {
            await TrialFeedback.send(reason, comment: comment, session: ok.session)
            await TrialFeedback.send(reason, comment: comment, session: failing.session)
        }
        _ = AppLogStore.read() // flushes the pending writes to the file
        let persisted = try String(contentsOf: url, encoding: .utf8)
        #expect(persisted.contains("trial-feedback-log-control"))
        #expect(persisted.contains("[TrialFeedback] sent: HTTP 204"))
        #expect(persisted.contains("[TrialFeedback] send failed"))
        for reason in TrialFeedback.Reason.allCases {
            #expect(!persisted.contains(reason.rawValue), "reason=\(reason.rawValue)")
            #expect(!persisted.contains(reason.label), "label=\(reason.label)")
        }
        #expect(!persisted.contains(comment))
    }

    // MARK: - Presenting over the inbox

    private struct Presented {
        let window: UIWindow
        let host: UIViewController
        let presentation: TrialFeedbackPresentation
        let defaults: UserDefaults
        let suiteName: String
        /// The fake worker the sheet's form posts to, and that form.
        let worker: FakeHTTP.Scenario
        let form: TrialFeedbackForm
    }

    /// The inbox's auto-open and the app's one sheet host, as the app wires them.
    @MainActor
    private static func presentInbox(
        alreadyAsked: Bool = false,
        isInbox: Bool = true,
        hasSession: Bool = true,
        somethingPresented: Bool = false
    ) throws -> Presented {
        let suiteName = "TrialFeedbackTests-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        if alreadyAsked { defaults.set(true, forKey: TrialFeedback.askedKey) }
        let presentation = TrialFeedbackPresentation()
        let worker = acceptingWorker()
        let form = TrialFeedbackForm(session: worker.session)
        let root = Color.clear
            .trialFeedbackAutoOpen(isInbox: isInbox, presentation: presentation, isSomethingPresented: { somethingPresented })
            .trialFeedbackSheetHost(presentation: presentation, makeForm: { form })
            .environment(\.hasTabMailSession, hasSession)
            .defaultAppStorage(defaults)
        let host = UIHostingController(rootView: root)
        return Presented(window: try window(host), host: host, presentation: presentation, defaults: defaults, suiteName: suiteName, worker: worker, form: form)
    }

    @MainActor
    private static func close(_ presented: Presented) async {
        presented.host.dismiss(animated: false)
        try? await Task.sleep(for: .milliseconds(200))
        presented.window.isHidden = true
        presented.window.rootViewController = nil
        presented.defaults.removePersistentDomain(forName: presented.suiteName)
        presented.worker.close()
    }

    @MainActor
    private static func endTrial() throws {
        UsageThrottleStore.shared.update(from: try WhoamiFixture.expiredSignupTrial(endedDaysAgo: 1, reference: Date()))
    }

    @MainActor
    private static func resetTrial() {
        if let info = try? WhoamiFixture.signedInWithoutSubscription() { UsageThrottleStore.shared.update(from: info) }
    }

    @Test("An ended trial presents the sheet over the inbox, and once it appeared it is never presented again")
    @MainActor
    func presentsOnceAndMarksAsked() async throws {
        try Self.endTrial()
        defer { Self.resetTrial() }
        let first = try Self.presentInbox()
        try await Task.sleep(for: .milliseconds(800))
        #expect(first.host.presentedViewController != nil)
        #expect(first.defaults.bool(forKey: TrialFeedback.askedKey))
        let asked = first.defaults.bool(forKey: TrialFeedback.askedKey)
        await Self.close(first)

        // The next inbox appearance on this install (the same flag) presents nothing.
        let second = try Self.presentInbox(alreadyAsked: asked)
        try await Task.sleep(for: .milliseconds(800))
        #expect(second.host.presentedViewController == nil)
        await Self.close(second)
    }

    @Test("Never presented over another presentation, and the question stays unasked for the next appearance")
    @MainActor
    func notOverAnotherSheet() async throws {
        try Self.endTrial()
        defer { Self.resetTrial() }
        let presented = try Self.presentInbox(somethingPresented: true)
        try await Task.sleep(for: .milliseconds(800))
        #expect(presented.host.presentedViewController == nil)
        #expect(presented.defaults.bool(forKey: TrialFeedback.askedKey) == false)
        await Self.close(presented)
    }

    @Test("Not presented outside the inbox, or while the trial has not ended")
    @MainActor
    func notPresentedWhenNotDue() async throws {
        try Self.endTrial()
        let other = try Self.presentInbox(isInbox: false)
        try await Task.sleep(for: .milliseconds(800))
        #expect(other.host.presentedViewController == nil)
        await Self.close(other)

        Self.resetTrial()
        let running = try Self.presentInbox()
        try await Task.sleep(for: .milliseconds(800))
        #expect(running.host.presentedViewController == nil)
        #expect(running.defaults.bool(forKey: TrialFeedback.askedKey) == false)
        await Self.close(running)
    }

    @Test("A /whoami that reports the ended trial after the inbox appeared still presents it")
    @MainActor
    func latePlanStatePresents() async throws {
        Self.resetTrial()
        defer { Self.resetTrial() }
        let presented = try Self.presentInbox()
        try await Task.sleep(for: .milliseconds(500))
        #expect(presented.host.presentedViewController == nil)
        try Self.endTrial()
        try await Task.sleep(for: .milliseconds(800))
        #expect(presented.host.presentedViewController != nil)
        #expect(presented.defaults.bool(forKey: TrialFeedback.askedKey))
        await Self.close(presented)
    }

    @MainActor @Observable
    final class Navigation {
        var path: [Int] = []
        var inboxShowing = false
    }

    /// An inbox in a navigation stack that can push a message detail over it,
    /// with the app's auto-open on the inbox and its one host at the root.
    private struct InboxWithDetail: View {
        @Bindable var navigation: Navigation
        let presentation: TrialFeedbackPresentation
        let form: TrialFeedbackForm
        let defaults: UserDefaults

        var body: some View {
            NavigationStack(path: $navigation.path) {
                Text("Synthetic inbox")
                    .onAppear { navigation.inboxShowing = true }
                    .onDisappear { navigation.inboxShowing = false }
                    .trialFeedbackAutoOpen(isInbox: true, presentation: presentation, isSomethingPresented: { false })
                    .navigationDestination(for: Int.self) { _ in Text("Synthetic message") }
            }
            .trialFeedbackSheetHost(presentation: presentation, makeForm: { form })
            .environment(\.hasTabMailSession, true)
            .defaultAppStorage(defaults)
        }
    }

    @Test("A /whoami that ends the trial while a message covers the inbox waits for the inbox, and only then marks it asked")
    @MainActor
    func lateEligibilityWaitsForTheInbox() async throws {
        Self.resetTrial()
        defer { Self.resetTrial() }
        let suiteName = "TrialFeedbackTests-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let worker = Self.acceptingWorker()
        defer { worker.close() }
        let navigation = Navigation()
        let presentation = TrialFeedbackPresentation()
        let host = UIHostingController(rootView: InboxWithDetail(
            navigation: navigation, presentation: presentation,
            form: TrialFeedbackForm(session: worker.session), defaults: defaults))
        let window = try Self.window(host)
        defer { window.isHidden = true; window.rootViewController = nil }
        try await Task.sleep(for: .milliseconds(500))
        try #require(navigation.inboxShowing)

        navigation.path = [1]
        try await Task.sleep(for: .milliseconds(700))
        try #require(navigation.inboxShowing == false)
        try Self.endTrial()
        try await Task.sleep(for: .milliseconds(800))
        #expect(presentation.isPresented == false)
        #expect(host.presentedViewController == nil)
        #expect(defaults.bool(forKey: TrialFeedback.askedKey) == false)

        navigation.path = []
        try await Task.sleep(for: .milliseconds(900))
        #expect(host.presentedViewController != nil)
        #expect(defaults.bool(forKey: TrialFeedback.askedKey))
        host.dismiss(animated: false)
        try await Task.sleep(for: .milliseconds(200))
    }

    /// Waits up to `seconds` for `condition`, so a setup step or a positive
    /// check does not depend on how fast a loaded simulator lays out.
    @MainActor
    private static func eventually(within seconds: Double = 5, _ condition: () -> Bool) async -> Bool {
        let end = Date().addingTimeInterval(seconds)
        while !condition() {
            if Date() >= end { return false }
            try? await Task.sleep(for: .milliseconds(25))
        }
        return true
    }

    @MainActor @Observable
    final class Tabs {
        var selected = 0
        var inboxShowing = false
    }

    /// An inbox in one tab of two: the other tab hides it while it stays live.
    private struct InboxInTabs: View {
        @Bindable var tabs: Tabs
        let presentation: TrialFeedbackPresentation
        let form: TrialFeedbackForm
        let defaults: UserDefaults

        var body: some View {
            TabView(selection: $tabs.selected) {
                Text("Synthetic inbox")
                    .onAppear { tabs.inboxShowing = true }
                    .onDisappear { tabs.inboxShowing = false }
                    .trialFeedbackAutoOpen(isInbox: true, presentation: presentation, isSomethingPresented: { false })
                    .tag(0)
                Text("Synthetic other tab")
                    .tag(1)
            }
            .trialFeedbackSheetHost(presentation: presentation, makeForm: { form })
            .environment(\.hasTabMailSession, true)
            .defaultAppStorage(defaults)
        }
    }

    @Test("A /whoami that ends the trial while the inbox is hidden but live waits for the inbox, and only then marks it asked")
    @MainActor
    func lateEligibilityWaitsWhileHiddenButLive() async throws {
        Self.resetTrial()
        defer { Self.resetTrial() }
        let suiteName = "TrialFeedbackTests-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let worker = Self.acceptingWorker()
        defer { worker.close() }
        let tabs = Tabs()
        let presentation = TrialFeedbackPresentation()
        let host = UIHostingController(rootView: InboxInTabs(
            tabs: tabs, presentation: presentation,
            form: TrialFeedbackForm(session: worker.session), defaults: defaults))
        let window = try Self.window(host)
        defer { window.isHidden = true; window.rootViewController = nil }
        try #require(await Self.eventually { tabs.inboxShowing })

        tabs.selected = 1
        try #require(await Self.eventually { !tabs.inboxShowing })
        try Self.endTrial()
        try await Task.sleep(for: .milliseconds(800))
        #expect(presentation.isPresented == false)
        #expect(host.presentedViewController == nil)
        #expect(defaults.bool(forKey: TrialFeedback.askedKey) == false)

        tabs.selected = 0
        #expect(await Self.eventually { host.presentedViewController != nil })
        #expect(defaults.bool(forKey: TrialFeedback.askedKey))
        host.dismiss(animated: false)
        try await Task.sleep(for: .milliseconds(200))
    }

    @Test("Signed out or in demo mode, an ended trial presents nothing and leaves it unasked")
    @MainActor
    func notForSignedOutOrDemo() async throws {
        try Self.endTrial()
        defer { Self.resetTrial() }
        let signedOut = try Self.presentInbox(hasSession: false)
        try await Task.sleep(for: .milliseconds(800))
        #expect(signedOut.host.presentedViewController == nil)
        #expect(signedOut.defaults.bool(forKey: TrialFeedback.askedKey) == false)
        await Self.close(signedOut)

        let wasDemo = DemoModeStore.shared.isActive
        DemoModeStore.shared.isActive = true
        defer { DemoModeStore.shared.isActive = wasDemo }
        let demo = try Self.presentInbox()
        try await Task.sleep(for: .milliseconds(800))
        #expect(demo.host.presentedViewController == nil)
        #expect(demo.defaults.bool(forKey: TrialFeedback.askedKey) == false)
        await Self.close(demo)
    }

    @Test("The real inbox opens the sheet once its trial has ended")
    @MainActor
    func inboxViewAutoOpens() async throws {
        try Self.endTrial()
        defer { Self.resetTrial() }
        let suiteName = "TrialFeedbackTests-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let presentation = TrialFeedbackPresentation.shared
        presentation.isPresented = false
        defer { presentation.isPresented = false }
        let worker = Self.acceptingWorker()
        defer { worker.close() }
        let inbox = Folder(name: "INBOX", path: "INBOX", role: .inbox, accountId: "trial-feedback-test")
        let root = NavigationStack {
            InboxView(title: "Inbox", folders: [inbox], selection: .unified(.inbox),
                      selectedMessageId: .constant(nil), pushedMessageId: .constant(nil))
        }
        .trialFeedbackSheetHost(makeForm: { TrialFeedbackForm(session: worker.session) })
        .environment(NavigationStore())
        .environment(\.hasTabMailSession, true)
        .defaultAppStorage(defaults)
        let host = UIHostingController(rootView: root)
        let window = try Self.window(host)
        defer { window.isHidden = true; window.rootViewController = nil }
        try await Task.sleep(for: .milliseconds(1200))
        #expect(host.presentedViewController != nil)
        #expect(defaults.bool(forKey: TrialFeedback.askedKey))
        host.dismiss(animated: false)
        try await Task.sleep(for: .milliseconds(200))
    }

    @Test("A banner's Feedback opens the sheet even after it opened by itself once")
    @MainActor
    func feedbackOpensTheSheetAfterAsked() async throws {
        try Self.endTrial()
        defer { Self.resetTrial() }
        let presented = try Self.presentInbox(alreadyAsked: true)
        try await Task.sleep(for: .milliseconds(500))
        #expect(presented.host.presentedViewController == nil)
        presented.presentation.open() // what both banners' Feedback buttons call
        try await Task.sleep(for: .milliseconds(800))
        #expect(presented.host.presentedViewController != nil)
        await Self.close(presented)
    }

    @Test("The default presented check sees a sheet already up in the key window")
    @MainActor
    func keyWindowPresentedCheck() async throws {
        let root = UIViewController()
        let window = try Self.window(root)
        defer { window.isHidden = true; window.rootViewController = nil }
        #expect(TrialFeedbackAutoOpen.keyWindowIsPresenting() == false)
        root.present(UIViewController(), animated: false)
        #expect(TrialFeedbackAutoOpen.keyWindowIsPresenting())
        root.dismiss(animated: false)
        try await Task.sleep(for: .milliseconds(200))
    }

    // MARK: - The sheet's own controls

    /// The toolbar item with this title in the presented sheet's navigation bar.
    @MainActor
    private static func barItem(_ title: String, in root: UIView) -> UIBarButtonItem? {
        descendants(root).compactMap { $0 as? UINavigationBar }
            .compactMap(\.topItem)
            .flatMap { $0.leadingItemGroups + $0.trailingItemGroups }
            .flatMap(\.barButtonItems)
            .first { $0.title == title }
    }

    @MainActor
    private static func tap(_ item: UIBarButtonItem) throws {
        let action = try #require(item.action)
        UIApplication.shared.sendAction(action, to: item.target, from: item, for: nil)
    }

    @Test("Send is off until a choice is picked, then sends that choice once, closes the sheet and marks it sent")
    @MainActor
    func toolbarSend() async throws {
        try Self.endTrial()
        defer { Self.resetTrial() }
        let presented = try Self.presentInbox()
        let form = presented.form
        try await Task.sleep(for: .milliseconds(800))
        let sheet = try #require(presented.host.presentedViewController)
        let send = try #require(Self.barItem("Send", in: sheet.view))
        #expect(send.isEnabled == false)
        // A hosted SwiftUI row exposes no control or list selection to drive,
        // so the choice goes through the entry point the row calls.
        form.select(.notUsedEnough)
        try await Task.sleep(for: .milliseconds(300))
        #expect(form.selected == .notUsedEnough)
        let enabled = try #require(Self.barItem("Send", in: sheet.view))
        #expect(enabled.isEnabled)
        #expect(presented.defaults.bool(forKey: TrialFeedback.sentKey) == false)
        try Self.tap(enabled)
        try await Task.sleep(for: .milliseconds(800))
        let answers = try Self.answers(presented.worker)
        #expect(answers.count == 1)
        #expect(answers.first?["reason"] as? String == "not_used_enough")
        #expect(presented.host.presentedViewController == nil)
        #expect(presented.defaults.bool(forKey: TrialFeedback.askedKey))
        // Sent hides the banners' Feedback button.
        let sent = presented.defaults.bool(forKey: TrialFeedback.sentKey)
        #expect(sent)
        #expect(TrialFeedback.offersFeedback(sent: sent) == false)
        await Self.close(presented)
    }

    @Test("Not now closes the sheet, sends nothing, is not asked again, and leaves Feedback offered")
    @MainActor
    func toolbarNotNow() async throws {
        try Self.endTrial()
        defer { Self.resetTrial() }
        let presented = try Self.presentInbox()
        try await Task.sleep(for: .milliseconds(800))
        let sheet = try #require(presented.host.presentedViewController)
        try Self.tap(try #require(Self.barItem("Not now", in: sheet.view)))
        try await Task.sleep(for: .milliseconds(800))
        #expect(presented.host.presentedViewController == nil)
        #expect(presented.worker.recordedCalls().isEmpty)
        #expect(presented.defaults.bool(forKey: TrialFeedback.askedKey))
        let sent = presented.defaults.bool(forKey: TrialFeedback.sentKey)
        #expect(sent == false)
        #expect(TrialFeedback.offersFeedback(sent: sent))
        await Self.close(presented)
    }

    // MARK: - The trial-ended banners

    @Test("Feedback is offered until an answer was sent")
    func offersFeedbackUntilSent() {
        #expect(TrialFeedback.bannerEndedText == "Free trial ended")
        #expect(TrialFeedback.bannerFeedbackLabel == "Feedback")
        #expect(TrialFeedback.offersFeedback(sent: false))
        #expect(TrialFeedback.offersFeedback(sent: true) == false)
    }

    /// Each body is decoded by the real `/whoami` parser into the store the
    /// inbox reads.
    @Test("The inbox shows the running-trial row, the ended row, or nothing, per account state")
    @MainActor
    func inboxRowPerState() throws {
        let now = Date()
        let store = UsageThrottleStore.shared
        defer { Self.resetTrial() }
        func rows(isInbox: Bool = true, isSignedIn: Bool = true, isDemo: Bool = false) -> (String?, String?) {
            (InboxTrialReminder.text(for: store.trialState, isInbox: isInbox, isSignedIn: isSignedIn, isDemo: isDemo),
             InboxTrialReminder.endedText(for: store.trialState, isInbox: isInbox, isSignedIn: isSignedIn, isDemo: isDemo))
        }

        store.update(from: try WhoamiFixture.runningSignupTrial(daysLeft: 3, reference: now))
        #expect(rows().0 == "Free trial · 3 days left")
        #expect(rows().1 == nil)

        store.update(from: try WhoamiFixture.expiredSignupTrial(endedDaysAgo: 1, reference: now))
        #expect(rows().0 == nil)
        #expect(rows().1 == "Free trial ended")
        #expect(rows(isInbox: false).1 == nil)
        #expect(rows(isSignedIn: false).1 == nil)
        #expect(rows(isDemo: true).1 == nil)

        // Subscribing makes it disappear.
        store.update(from: try WhoamiFixture.accountInfo(hasSubscription: true, planTier: AccountPlanConfig.basicTierKey, provider: "apple"))
        #expect(rows().0 == nil)
        #expect(rows().1 == nil)

        // BYOK and no trial show nothing either.
        store.update(from: try WhoamiFixture.accountInfo(hasSubscription: true, planTier: AccountPlanConfig.byokTierKey, provider: "stripe"))
        #expect(rows().1 == nil)
        store.update(from: try WhoamiFixture.signedInWithoutSubscription())
        #expect(rows().1 == nil)
    }

    @Test("The ended-state matrix: only a signed-in, non-demo inbox with an ended trial gets the ended row")
    func endedRowMatrix() {
        let states: [TrialState] = [.noTrial, .active(daysRemaining: 1), .ended]
        for state in states {
            for isInbox in [true, false] {
                for isSignedIn in [true, false] {
                    for isDemo in [true, false] {
                        let expected = state == .ended && isInbox && isSignedIn && !isDemo
                        #expect(
                            (InboxTrialReminder.endedText(for: state, isInbox: isInbox, isSignedIn: isSignedIn, isDemo: isDemo) != nil) == expected,
                            "state=\(state) inbox=\(isInbox) signedIn=\(isSignedIn) demo=\(isDemo)"
                        )
                    }
                }
            }
        }
    }

    // MARK: - Wiring read from source

    /// The project root, for reading view sources too large to host here.
    private static var projectRoot: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
    }

    /// A source file with every run of whitespace made one space.
    private static func source(_ path: String) throws -> String {
        let text = try String(contentsOf: projectRoot.appendingPathComponent(path), encoding: .utf8)
        return text.split(whereSeparator: \.isWhitespace).joined(separator: " ")
    }

    private static func count(_ needle: String, in text: String) -> Int {
        text.components(separatedBy: needle).count - 1
    }

    @Test("The app hosts the sheet exactly once, at the mail root")
    func oneSheetHost() throws {
        let root = Self.projectRoot.appendingPathComponent("TabMail")
        let files = try #require(FileManager.default.enumerator(at: root, includingPropertiesForKeys: nil))
        var hosts: [String] = []
        for case let url as URL in files where url.pathExtension == "swift" {
            let text = try String(contentsOf: url, encoding: .utf8)
            let uses = Self.count(".trialFeedbackSheetHost(", in: text)
            hosts += Array(repeating: url.lastPathComponent, count: uses)
        }
        #expect(hosts == ["MailNavigationView.swift"])
    }

    @Test("The inbox auto-opens it once and its ended row offers Feedback until sent")
    func inboxWiring() throws {
        let text = try Self.source("TabMail/Views/Inbox/InboxView.swift")
        #expect(Self.count(".trialFeedbackAutoOpen(isInbox: isInboxView)", in: text) == 1)
        #expect(Self.count(".trialFeedbackAutoOpen(", in: text) == 1)
        #expect(Self.count("@AppStorage(TrialFeedback.sentKey) private var trialFeedbackSent = false", in: text) == 1)
        #expect(Self.count("} else if let trialEnded = InboxTrialReminder.endedText( for: UsageThrottleStore.shared.trialState, isInbox: isInboxView, isSignedIn: hasTabMailSession, isDemo: DemoModeStore.shared.isActive ) { InboxTrialReminder( text: trialEnded, onFeedback: TrialFeedback.offersFeedback(sent: trialFeedbackSent) ? { TrialFeedbackPresentation.shared.open() } : nil ) }", in: text) == 1)
        // The row draws Feedback, before Plans, exactly when given the action.
        let row = try Self.source("TabMail/Views/Shared/InboxTrialReminder.swift")
        #expect(Self.count("if let onFeedback { Button(action: onFeedback) {", in: row) == 1)
        let feedbackAt = try #require(row.range(of: "if let onFeedback {")).lowerBound
        let plansAt = try #require(row.range(of: "Button(\"Plans\")")).lowerBound
        #expect(feedbackAt < plansAt)
    }

    @Test("In the inbox row Plans is the filled main action and Feedback the gray secondary one")
    func bannerButtonStyles() throws {
        let row = try Self.source("TabMail/Views/Shared/InboxTrialReminder.swift")
        // Plans, on both the running-trial and the ended row.
        #expect(Self.count("Button(\"Plans\") { NotificationCenter.default.post(name: .navigateToPlanPicker, object: nil) } .font(.caption.weight(.semibold)) .buttonStyle(.borderedProminent) .buttonBorderShape(.capsule) .controlSize(.mini)", in: row) == 1)
        #expect(Self.count("if let onFeedback { Button(action: onFeedback) { Label(TrialFeedback.bannerFeedbackLabel, systemImage: TrialFeedback.bannerFeedbackSymbol) } .font(.caption.weight(.semibold)) .buttonStyle(.bordered) .buttonBorderShape(.capsule) .controlSize(.mini) .tint(.gray) }", in: row) == 1)
        #expect(TrialFeedback.bannerFeedbackSymbol == "bubble.left")
        // The folder list words its feedback button on its own.
        #expect(TrialFeedback.folderListFeedbackLabel == "Not for you? Tell us why")
        let sidebar = try Self.source("TabMail/Views/MailNavigationView.swift")
        #expect(Self.count("bannerFeedbackLabel", in: sidebar) == 0)
    }

    @Test("The folder list's ended banner is See Plans plus Tell us why until sent; every other state is the one Plans/sign-in button with its chevron")
    func sidebarWiring() throws {
        let text = try Self.source("TabMail/Views/MailNavigationView.swift")
        #expect(Self.count("private var showsTrialEndedCopy: Bool { hasTabMailSession && trialHasEnded }", in: text) == 1)
        #expect(Self.count("@AppStorage(TrialFeedback.sentKey) private var trialFeedbackSent = false", in: text) == 1)
        // The ended state, sent or not, gets its own banner; every other state
        // is the single button it was on main.
        #expect(Self.count("if showsTrialEndedCopy { trialEndedBanner } else { Button(action: subscribeBannerTapped) { subscribeBannerLabel.padding(.vertical, 4) } }", in: text) == 1)
        #expect(Self.count("trialEndedBanner", in: text) == 2)
        // The ended banner: text with no chevron and no tap, a filled See
        // Plans button, and the feedback text button only until sent.
        let banner = try #require(text.range(of: "private var trialEndedBanner: some View {"))
        let bannerEnd = try #require(text.range(of: "/// The subscribe banner's tap", range: banner.upperBound..<text.endIndex))
        let bannerBody = String(text[banner.upperBound..<bannerEnd.lowerBound])
        #expect(Self.count("VStack(spacing: 8) { HStack(spacing: 12) { subscribeBannerIcon subscribeBannerTexts Spacer() } Button(action: subscribeBannerTapped) { Text(\"See Plans\") .font(.subheadline.weight(.semibold)) .frame(maxWidth: .infinity) } .buttonStyle(.borderedProminent) .buttonBorderShape(.capsule) if TrialFeedback.offersFeedback(sent: trialFeedbackSent) { Button(TrialFeedback.folderListFeedbackLabel) { TrialFeedbackPresentation.shared.open() } .font(.subheadline) .buttonStyle(.borderless) } } .padding(.vertical, 4)", in: bannerBody) == 1)
        #expect(!bannerBody.contains("chevron"))
        #expect(!bannerBody.contains("subscribeBannerLabel"))
        #expect(Self.count("Button(action: subscribeBannerTapped)", in: text) == 2)
        #expect(Self.count("TrialFeedbackPresentation.shared.open()", in: text) == 1)
        // The other states' label keeps the chevron and offers no feedback.
        let label = try #require(text.range(of: "private var subscribeBannerLabel: some View {"))
        let labelEnd = try #require(text.range(of: "/// The banner once the trial has ended", range: label.upperBound..<text.endIndex))
        let labelBody = text[label.upperBound..<labelEnd.lowerBound]
        #expect(Self.count("HStack(spacing: 12) { subscribeBannerIcon subscribeBannerTexts Spacer() Image(systemName: \"chevron.right\")", in: String(labelBody)) == 1)
        #expect(!labelBody.contains("TrialFeedback"))
    }
}
