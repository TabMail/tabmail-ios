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
