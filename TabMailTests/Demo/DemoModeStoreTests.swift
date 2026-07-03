/* This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at https://mozilla.org/MPL/2.0/. */

import Testing
import Foundation
@testable import TabMail

@MainActor
@Suite("DemoModeStore — counter + refund matrix")
struct DemoModeStoreTests {

    init() {
        DemoModeStore.shared._resetForTests()
    }

    @Test("totalCallBudget is 50")
    func budgetIs50() {
        #expect(DemoModeStore.totalCallBudget == 50)
    }

    @Test("Initial state: 0 consumed, 50 remaining, not exhausted")
    func initialState() {
        DemoModeStore.shared._resetForTests()
        let store = DemoModeStore.shared
        #expect(store.callsConsumed == 0)
        #expect(store.callsRemaining == 50)
        #expect(!store.isCallBudgetExhausted)
    }

    @Test("consumeCall increments by 1 and persists")
    func consumeIncrements() {
        DemoModeStore.shared._resetForTests()
        let store = DemoModeStore.shared
        store.consumeCall()
        #expect(store.callsConsumed == 1)
        #expect(store.callsRemaining == 49)
        // Verify persistence
        #expect(UserDefaults.standard.integer(forKey: "demo.callsConsumed") == 1)
    }

    @Test("Counter cap: callsRemaining never goes below 0")
    func capAtZero() {
        DemoModeStore.shared._resetForTests()
        let store = DemoModeStore.shared
        for _ in 0..<60 {
            store.consumeCall()
        }
        #expect(store.callsConsumed == 60)
        #expect(store.callsRemaining == 0)
        #expect(store.isCallBudgetExhausted)
    }

    @Test("refundCall decrements; never below 0")
    func refundFloor() {
        DemoModeStore.shared._resetForTests()
        let store = DemoModeStore.shared
        store.refundCall()
        #expect(store.callsConsumed == 0)

        store.consumeCall()
        store.refundCall()
        #expect(store.callsConsumed == 0)
    }

    @Test("resetCallBudget zeroes the counter and persists (debug-menu reset)")
    func resetCallBudgetZeroes() {
        DemoModeStore.shared._resetForTests()
        let store = DemoModeStore.shared
        for _ in 0..<7 { store.consumeCall() }
        #expect(store.callsConsumed == 7)

        store.resetCallBudget()
        #expect(store.callsConsumed == 0)
        #expect(store.callsRemaining == 50)
        #expect(!store.isCallBudgetExhausted)
        #expect(UserDefaults.standard.integer(forKey: "demo.callsConsumed") == 0)
    }

    // MARK: - Session ID scoping

    @Test("scopedSessionId adds the demo: prefix only while demo is active")
    func scopedSessionIdPrefixing() {
        DemoModeStore.shared._resetForTests()
        // Inactive: pass-through for every session shape.
        #expect(DemoModeStore.scopedSessionId("msg:acct:stable") == "msg:acct:stable")
        #expect(DemoModeStore.scopedSessionId("compose:d1") == "compose:d1")
        #expect(DemoModeStore.scopedSessionId("ABC-UUID") == "ABC-UUID")

        DemoModeStore.shared.isActive = true
        #expect(DemoModeStore.scopedSessionId("msg:acct:stable") == "demo:msg:acct:stable")
        #expect(DemoModeStore.scopedSessionId("compose:d1") == "demo:compose:d1")
        #expect(DemoModeStore.scopedSessionId("ABC-UUID") == "demo:ABC-UUID")
        DemoModeStore.shared._resetForTests()
    }

    // MARK: - Prompt overlay (ADR-IOS-038)

    @Test("PromptStore demo overlay: writes route to demo keys; real prompts untouched; exit restores")
    func promptStoreDemoOverlayRoundtrip() {
        let d = UserDefaults.standard
        let store = PromptStore.shared
        let realKBBefore = store.rawKB
        DemoModeStore.shared._resetForTests()
        DemoModeStore.shared.isActive = true
        defer {
            DemoModeStore.shared._resetForTests()
            PromptStore.removeDemoOverlayKeys()
        }

        // Key redirection while demo active
        #expect(PromptStore.storageKey("x") == "demo.x")

        store.enterDemoOverlay()
        store.rawKB = "- demo kb edit"
        // Snapshot (the chat KB injection path) sees the demo overlay…
        #expect(PromptStore.kbTextSnapshot() == "- demo kb edit")
        // …while the REAL key is untouched.
        #expect(d.string(forKey: "user_prompts:user_kb.md") == realKBBefore)

        // Exit (still demo-active per contract) restores the real values and
        // deletes the demo keys.
        store.exitDemoOverlay()
        #expect(store.rawKB == realKBBefore)
        #expect(d.object(forKey: "demo.user_prompts:user_kb.md") == nil)

        DemoModeStore.shared.isActive = false
        #expect(PromptStore.storageKey("x") == "x")
        #expect(PromptStore.kbTextSnapshot() == realKBBefore)
    }

    @Test("DisabledRemindersStore: demo dismissals live in a separate demo map")
    func disabledRemindersDemoScoped() {
        let suiteName = "test.demo.disabledReminders"
        let suite = UserDefaults(suiteName: suiteName)!
        suite.removePersistentDomain(forName: suiteName)
        DemoModeStore.shared._resetForTests()
        defer { DemoModeStore.shared._resetForTests() }

        DisabledRemindersStore.withTestDefaults(suite) {
            DisabledRemindersStore.setEnabled(hash: "m:real-reminder", enabled: false)
            #expect(DisabledRemindersStore.getDisabledHashes() == ["m:real-reminder"])

            // Demo map starts empty and collects demo dismissals only.
            DemoModeStore.shared.isActive = true
            #expect(DisabledRemindersStore.getDisabledHashes().isEmpty)
            DisabledRemindersStore.setEnabled(hash: "m:demo-reminder", enabled: false)
            #expect(DisabledRemindersStore.getDisabledHashes() == ["m:demo-reminder"])

            // Back to normal: real map intact, demo hash invisible.
            DemoModeStore.shared.isActive = false
            #expect(DisabledRemindersStore.getDisabledHashes() == ["m:real-reminder"])
        }
    }

    // MARK: - Refund matrix

    @Test("Refund: URLError.notConnectedToInternet")
    func refundOnNoInternet() {
        let err = URLError(.notConnectedToInternet)
        #expect(DemoModeStore.shouldRefund(for: err))
    }

    @Test("Refund: URLError.timedOut")
    func refundOnTimeout() {
        #expect(DemoModeStore.shouldRefund(for: URLError(.timedOut)))
    }

    @Test("Refund: CancellationError")
    func refundOnCancel() {
        #expect(DemoModeStore.shouldRefund(for: CancellationError()))
    }

    @Test("Refund: HTTP 503 transient")
    func refundOn503() {
        let err = NSError(domain: "BackendError", code: 0, userInfo: [NSLocalizedDescriptionKey: "HTTP 503 Service Unavailable"])
        #expect(DemoModeStore.shouldRefund(for: err))
    }

    @Test("Refund: demo_token throttle 429")
    func refundOnDemoTokenThrottle() {
        let err = NSError(domain: "BackendError", code: 0, userInfo: [NSLocalizedDescriptionKey: "rate_limited reason=demo_token"])
        #expect(DemoModeStore.shouldRefund(for: err))
    }

    @Test("No refund: HTTP 400 parse error")
    func noRefundOn400() {
        let err = NSError(domain: "BackendError", code: 400, userInfo: [NSLocalizedDescriptionKey: "Bad request"])
        #expect(!DemoModeStore.shouldRefund(for: err))
    }

    @Test("Refund: connection-lost is a transient cut — deterministic across callers")
    func refundOnConnectionLost() {
        // Refund the failed round: callers with no resume (inline edit, reply) get
        // their call back, and the chat resume re-consumes via resumeChatMessage so
        // a resumed turn still nets one call. Must be deterministic regardless of
        // the request's timestamp digits (which could trip the 5xx string-match).
        let req = CompletionsRequest(messages: [], client_timezone: "UTC", disable_tools: nil)
        let err = ChatConnectionLostError(resumeRequest: req)
        #expect(DemoModeStore.shouldRefund(for: err))
    }

    // MARK: - Persistence

    @Test("Demo gate flags persist independent of production flags")
    func gateFlagsPersistSeparately() {
        DemoModeStore.shared._resetForTests()
        UserDefaults.standard.set(false, forKey: "hasCompletedConsentGate")
        UserDefaults.standard.set(false, forKey: "hasSeenAIConsent")

        DemoModeStore.shared.hasCompletedConsentGate = true
        DemoModeStore.shared.hasSeenAIConsent = true
        DemoModeStore.shared.aiEnabled = true

        // Production flags untouched
        #expect(UserDefaults.standard.bool(forKey: "hasCompletedConsentGate") == false)
        #expect(UserDefaults.standard.bool(forKey: "hasSeenAIConsent") == false)
        // Demo flags set
        #expect(UserDefaults.standard.bool(forKey: "demo.hasCompletedConsentGate") == true)
        #expect(UserDefaults.standard.bool(forKey: "demo.hasSeenAIConsent") == true)
        #expect(UserDefaults.standard.bool(forKey: "demo.aiEnabled") == true)
    }

}

@Suite("DemoAuth helpers — JWT format constants")
struct DemoAuthConstantsTests {
    @Test("Demo aggregate UUID is valid v4 format and matches backend constant")
    func demoUUIDFormat() {
        // Mirrors the backend's DEMO_AGGREGATE_USER_ID constant — the fixed
        // sentinel that all demo usage rolls up to. If this test breaks,
        // regenerate the constant on the backend too.
        let expected = "00000000-0000-4000-8000-44454d4f0000"
        let regex = try! NSRegularExpression(pattern: "^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$")
        let range = NSRange(expected.startIndex..., in: expected)
        #expect(regex.firstMatch(in: expected, range: range) != nil)
    }
}
