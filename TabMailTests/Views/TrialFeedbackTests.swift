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
///   ended" and both banners offer Feedback, which opens the same sheet, until
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
        let form = TrialFeedbackForm(deliver: { _, _ in })
        let atMax = String(repeating: "😀", count: 500) // one code point each, as the server counts
        #expect(form.edit(atMax))
        #expect(form.comment == atMax)
        #expect(form.edit(atMax + "a") == false)
        #expect(form.comment == atMax)

        let fresh = TrialFeedbackForm(deliver: { _, _ in })
        fresh.edit("ab")
        #expect(fresh.edit(String(repeating: "a", count: 510)) == false)
        #expect(fresh.comment == "ab")

        // A grapheme of several code points counts each one (7 for this family emoji).
        let family = "👨‍👩‍👧‍👦"
        #expect(family.unicodeScalars.count == 7)
        let near = TrialFeedbackForm(deliver: { _, _ in })
        let nearMax = String(repeating: "a", count: 494)
        near.edit(nearMax)
        #expect(near.edit(nearMax + family) == false)
        #expect(near.comment == nearMax)
        #expect(near.edit(String(repeating: "a", count: 493) + family))
        #expect(near.comment.unicodeScalars.count == 500)
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
        let delivered = Mutex<[String]>([])
        let form = TrialFeedbackForm(deliver: { _, comment in delivered.withLock { $0.append(comment) } })
        let host = UIHostingController(rootView: TrialFeedbackSheet(form: form))
        let window = try Self.window(host)
        defer { window.isHidden = true; window.rootViewController = nil }
        try await Task.sleep(for: .milliseconds(300))
        host.view.layoutIfNeeded()
        let inputs = Self.descendants(host.view).compactMap { $0 as? UITextView }
        try #require(inputs.count == 1)
        let input = try #require(inputs.first)
        try #require(input.becomeFirstResponder())
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
        #expect(delivered.withLock { $0 } == [max])
    }

    // MARK: - The form

    @Test("Send is off until a choice is picked, sends once, and sends the answer as it was at Send")
    @MainActor
    func formSendsOnce() async {
        let delivered = Mutex<[(TrialFeedback.Reason, String)]>([])
        let form = TrialFeedbackForm(deliver: { reason, comment in delivered.withLock { $0.append((reason, comment)) } })
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
        let sent = delivered.withLock { $0 }
        #expect(sent.count == 1)
        guard sent.count == 1 else { return }
        #expect(sent[0].0 == .missingFeature)
        #expect(sent[0].1 == "Needed calendar sync")
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
    }

    /// The inbox's auto-open and the app's one sheet host, as the app wires them.
    @MainActor
    private static func presentInbox(
        alreadyAsked: Bool = false,
        isInbox: Bool = true,
        somethingPresented: Bool = false,
        makeForm: @escaping @MainActor () -> TrialFeedbackForm = { TrialFeedbackForm(deliver: { _, _ in }) }
    ) throws -> Presented {
        let suiteName = "TrialFeedbackTests-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        if alreadyAsked { defaults.set(true, forKey: TrialFeedback.askedKey) }
        let presentation = TrialFeedbackPresentation()
        let root = Color.clear
            .trialFeedbackAutoOpen(isInbox: isInbox, presentation: presentation, isSomethingPresented: { somethingPresented })
            .trialFeedbackSheetHost(presentation: presentation, makeForm: makeForm)
            .environment(\.hasTabMailSession, true)
            .defaultAppStorage(defaults)
        let host = UIHostingController(rootView: root)
        return Presented(window: try window(host), host: host, presentation: presentation, defaults: defaults, suiteName: suiteName)
    }

    @MainActor
    private static func close(_ presented: Presented) async {
        presented.host.dismiss(animated: false)
        try? await Task.sleep(for: .milliseconds(200))
        presented.window.isHidden = true
        presented.window.rootViewController = nil
        presented.defaults.removePersistentDomain(forName: presented.suiteName)
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
        let delivered = Mutex<[TrialFeedback.Reason]>([])
        let form = TrialFeedbackForm(deliver: { reason, _ in delivered.withLock { $0.append(reason) } })
        let presented = try Self.presentInbox(makeForm: { form })
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
        #expect(delivered.withLock { $0 } == [.notUsedEnough])
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
        let delivered = Mutex<Int>(0)
        let form = TrialFeedbackForm(deliver: { _, _ in delivered.withLock { $0 += 1 } })
        let presented = try Self.presentInbox(makeForm: { form })
        try await Task.sleep(for: .milliseconds(800))
        let sheet = try #require(presented.host.presentedViewController)
        try Self.tap(try #require(Self.barItem("Not now", in: sheet.view)))
        try await Task.sleep(for: .milliseconds(800))
        #expect(presented.host.presentedViewController == nil)
        #expect(delivered.withLock { $0 } == 0)
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
        #expect(Self.count("if let onFeedback { Button(TrialFeedback.bannerFeedbackLabel, action: onFeedback)", in: row) == 1)
        let feedbackAt = try #require(row.range(of: "Button(TrialFeedback.bannerFeedbackLabel")).lowerBound
        let plansAt = try #require(row.range(of: "Button(\"Plans\")")).lowerBound
        #expect(feedbackAt < plansAt)
    }

    @Test("The folder list's subscribe banner offers Feedback only for an ended trial, until sent, apart from its Plans tap")
    func sidebarWiring() throws {
        let text = try Self.source("TabMail/Views/MailNavigationView.swift")
        #expect(Self.count("private var showsTrialEndedCopy: Bool { hasTabMailSession && trialHasEnded }", in: text) == 1)
        #expect(Self.count("@AppStorage(TrialFeedback.sentKey) private var trialFeedbackSent = false", in: text) == 1)
        #expect(Self.count("if showsTrialEndedCopy, TrialFeedback.offersFeedback(sent: trialFeedbackSent) { Button(TrialFeedback.bannerFeedbackLabel) { TrialFeedbackPresentation.shared.open() }", in: text) == 1)
        // Feedback is its own button, not inside the Plans button's label.
        #expect(Self.count("Button(action: subscribeBannerTapped)", in: text) == 2)
    }
}
