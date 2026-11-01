/* This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at https://mozilla.org/MPL/2.0/. */

import Foundation
import StoreKit
import SwiftUI
import Synchronization
import Testing
import UIKit
import Vision
@testable import TabMail

private final class PaymentHTTPState: @unchecked Sendable {
    struct Values: Sendable {
        var accountReads = 0
        var validAuthorization = true
        var deliveredTokens: [String] = []
        var deliveredEnvironments: [String] = []
    }
    private let values = Mutex(Values())

    func nextRead(_ request: FakeHTTP.Request) -> Int {
        values.withLock {
            $0.accountReads += 1
            $0.validAuthorization = $0.validAuthorization && request.headers.contains {
                $0.key.lowercased() == "authorization" && $0.value == "Bearer synthetic-local-token"
            }
            return $0.accountReads
        }
    }

    func delivery(_ request: FakeHTTP.Request) {
        let object = request.body.flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] }
        let jws = object?["signedTransactionInfo"] as? String ?? ""
        let parts = jws.split(separator: ".")
        var encoded = parts.count == 3 ? String(parts[1]) : ""
        encoded = encoded.replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
        while encoded.count % 4 != 0 { encoded.append("=") }
        let payload = Data(base64Encoded: encoded).flatMap {
            try? JSONSerialization.jsonObject(with: $0) as? [String: Any]
        }
        values.withLock {
            $0.deliveredTokens.append((payload?["appAccountToken"] as? String ?? "missing").lowercased())
            $0.deliveredEnvironments.append(payload?["environment"] as? String ?? "missing")
        }
    }

    var snapshot: Values { values.withLock { $0 } }
}

private final class PaymentHeldHTTP: @unchecked Sendable {
    private let entered = Mutex(false)
    private let expired = Mutex(false)
    private let releaseSignal = DispatchSemaphore(value: 0)
    var hasEntered: Bool { entered.withLock { $0 } }
    var hasTimedOut: Bool { expired.withLock { $0 } }
    func response(_ response: FakeHTTP.CannedResponse) -> FakeHTTP.CannedResponse {
        .parked { [self] in
            entered.withLock { $0 = true }
            if releaseSignal.wait(timeout: .now() + 15) == .success { return response }
            expired.withLock { $0 = true }
            return .status(598)
        }
    }
    func release() { releaseSignal.signal() }
}

@MainActor
private final class PaymentViewFixture {
    static let userA = "11111111-1111-4111-8111-111111111111"
    static let userB = "22222222-2222-4222-8222-222222222222"
    let catalog: TrialStoreKitFixture
    let http = FakeHTTP.Scenario()
    let requests = PaymentHTTPState()
    let sessionStore: TabMailSessionStore
    let backend: BackendClient
    let heldPreflight: PaymentHeldHTTP?
    var action: PlanPickerView.PurchaseAction?
    var state: PlanPickerView.PurchaseStateReader?
    private let defaults: UserDefaults
    private let defaultsName: String
    private let lockDirectory: URL
    private let originalGateActive: Bool
    private let originalGateEnded: Bool
    private let originalUsage: (String?, Bool, Bool)

    init(accountJSON: String, period: TrialStoreKitFixture.Period = .week,
         includesFreeOffer: Bool = true, failedPreflight: Bool = false,
         holdPreflight: Bool = false) throws {
        catalog = try TrialStoreKitFixture(period: period, basicOnly: true, includesFreeOffer: includesFreeOffer)
        defaultsName = "PaymentViewTests.\(UUID().uuidString)"
        defaults = try #require(UserDefaults(suiteName: defaultsName))
        lockDirectory = FileManager.default.temporaryDirectory.appendingPathComponent(defaultsName)
        sessionStore = TabMailSessionStore(backend: MemorySessionKeychainBackend(),
            storageLock: CredentialStorageLock(directory: lockDirectory), cleanupDefaults: defaults)
        let coordinator = TabMailTokenCoordinator(sessionStore: sessionStore,
            dataForRequest: { _ in throw URLError(.cannotConnectToHost) })
        backend = BackendClient(accountReadSession: http.session, accountTokenCoordinator: coordinator)
        heldPreflight = holdPreflight ? PaymentHeldHTTP() : nil
        originalGateActive = AISubscriptionGate.shared.isActive
        originalGateEnded = AISubscriptionGate.shared.trialHasEnded
        let usage = UsageThrottleStore.shared
        originalUsage = (usage.planTier, usage.isThrottled, usage.hasOwnAPIKeys)
        try install(user: Self.userA)

        let requests = self.requests
        let held = heldPreflight
        let preflight: FakeHTTP.CannedResponse = failedPreflight ? .status(500) : .json(raw: accountJSON)
        let purchased = Self.accountJSON(subscriptionTrial: true)
        http.register(path: "/whoami") { request in
            switch requests.nextRead(request) {
            case 1: return .json(raw: accountJSON)
            case 2: return held?.response(preflight) ?? preflight
            default: return .json(raw: purchased)
            }
        }
        http.register(path: "/usage/stats", response: .json(raw:
            "{\"today\":{\"calls\":0,\"tokens_input\":0,\"tokens_output\":0,\"tokens_total\":0,\"cost_cents\":0},\"daily_stats\":[]}"))
        http.register(path: "/verify-purchase", method: "POST") { request in
            requests.delivery(request)
            return .json(raw: "{}")
        }
    }

    func load() async throws {
        // A real shared login must never be borrowed by this local-only suite.
        try #require(!TabMailAuthService.hasSession())
        try #require(!DemoModeStore.shared.isActive && !DemoModeStore.shared.isTutorialPractice)
        try await catalog.load()
        _ = try catalog.product()
        AISubscriptionGate.shared.closeGate()
    }

    func install(user: String) throws {
        let data = Data("""
        {"access_token":"synthetic-local-token","refresh_token":"synthetic-refresh","expires_at":9999999999,"user":{"id":"\(user)","email":"person@example.test"}}
        """.utf8)
        _ = try sessionStore.installNewSession(data)
    }

    func changeSession(to user: String) throws {
        try sessionStore.deactivate()
        AISubscriptionGate.shared.noteSignedOut()
        try install(user: user)
        AISubscriptionGate.shared.closeGate()
    }

    func plans() -> some View {
        PlanPickerView(backend: backend, sessionStore: sessionStore, verificationSession: http.session,
            onPurchaseActionReady: { [weak self] action, state in
                self?.action = action
                self?.state = state
            })
            .environment(catalog.manager)
    }

    func dashboard() -> some View {
        AccountDashboardView(backend: backend, sessionStore: sessionStore).environment(catalog.manager)
    }

    func ready() -> Bool { action != nil && state?().account != nil && requests.snapshot.accountReads >= 1 }

    func close() {
        action = nil
        state = nil
        heldPreflight?.release()
        http.close()
        catalog.close()
        if AISubscriptionGate.shared.trialHasEnded != originalGateEnded {
            let info: AccountInfo?
            if originalGateEnded {
                info = try? WhoamiFixture.expiredSignupTrial(endedDaysAgo: 1, reference: Date())
            } else {
                info = try? WhoamiFixture.accountInfo(hasSubscription: true, planTier: "Pro", provider: "stripe")
            }
            if let info { AISubscriptionGate.shared.apply(info) }
        }
        if originalGateActive { AISubscriptionGate.shared.openGate() } else { AISubscriptionGate.shared.closeGate() }
        UsageThrottleStore.shared.previewConfigure(planTier: originalUsage.0,
            isThrottled: originalUsage.1, hasOwnAPIKeys: originalUsage.2)
        defaults.removePersistentDomain(forName: defaultsName)
        try? FileManager.default.removeItem(at: lockDirectory)
    }

    static func accountJSON(subscriptionTrial: Bool? = nil, signupDays: Double? = nil) -> String {
        let end = Int(Date().addingTimeInterval((signupDays ?? 7) * 86_400).timeIntervalSince1970)
        if signupDays != nil {
            return "{\"logged_in\":true,\"has_subscription\":true,\"plan_tier\":\"Trial\",\"subscription_provider\":\"signup\",\"trial\":{\"is_trial\":true,\"trial_end\":\(end)}}"
        }
        if let subscriptionTrial {
            return "{\"logged_in\":true,\"has_subscription\":true,\"plan_tier\":\"Basic\",\"subscription_provider\":\"apple\",\"trial\":{\"is_trial\":\(subscriptionTrial),\"trial_end\":\(end)}}"
        }
        return "{\"logged_in\":true,\"has_subscription\":false}"
    }
}

@MainActor
private final class PaymentViewHost {
    struct Frame {
        let image: CGImage
        let pixels: [UInt8]
        let bluePixels: Int
        func difference(from other: Frame) -> Int {
            guard pixels.count == other.pixels.count else { return Int.max }
            return zip(pixels, other.pixels).reduce(0) { $0 + ($1.0 == $1.1 ? 0 : 1) }
        }
    }
    let window: UIWindow
    private let controller: UIViewController

    init(_ view: some View) throws {
        let scene = try #require(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let controller = UIHostingController(rootView: view.tint(.blue))
        self.controller = controller
        window = UIWindow(windowScene: scene)
        window.frame = CGRect(x: 0, y: 0, width: 390, height: 844)
        window.overrideUserInterfaceStyle = .light
        window.rootViewController = controller
        window.makeKeyAndVisible()
        window.layoutIfNeeded()
        controller.view.layoutIfNeeded()
    }

    func close() {
        window.isHidden = true
        window.rootViewController = nil
        controller.view.removeFromSuperview()
    }

    func frame() throws -> Frame {
        controller.view.layoutIfNeeded()
        let bounds = controller.view.bounds
        try #require(bounds.width > 0 && bounds.height > 0)
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        format.opaque = true
        var drawn = false
        let image = UIGraphicsImageRenderer(bounds: bounds, format: format).image { _ in
            drawn = controller.view.drawHierarchy(in: bounds, afterScreenUpdates: true)
        }
        try #require(drawn)
        let imageCG = try #require(image.cgImage)
        var pixels = [UInt8](repeating: 0, count: imageCG.width * imageCG.height * 4)
        let converted = pixels.withUnsafeMutableBytes { buffer -> Bool in
            guard let context = CGContext(data: buffer.baseAddress, width: imageCG.width, height: imageCG.height,
                bitsPerComponent: 8, bytesPerRow: imageCG.width * 4, space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue | CGBitmapInfo.byteOrder32Big.rawValue) else { return false }
            context.draw(imageCG, in: CGRect(x: 0, y: 0, width: imageCG.width, height: imageCG.height))
            return true
        }
        try #require(converted)
        var blue = 0
        for index in stride(from: 0, to: pixels.count, by: 4) {
            let r = Int(pixels[index]), g = Int(pixels[index + 1]), b = Int(pixels[index + 2])
            if b > 150 && b > r + 90 && b > g + 45 { blue += 1 }
        }
        return Frame(image: imageCG, pixels: pixels, bluePixels: blue)
    }

    /// Recognize only a completed stable render, on device and without custom
    /// words that could bias the observed payment terms toward the expectation.
    func renderedText(from frame: Frame) throws -> String {
        let request = VNRecognizeTextRequest()
        request.revision = VNRecognizeTextRequestRevision3
        request.recognitionLevel = .accurate
        request.recognitionLanguages = ["en-US"]
        request.usesLanguageCorrection = false
        try VNImageRequestHandler(cgImage: frame.image, options: [:]).perform([request])
        let recognized = try #require(request.results).compactMap { $0.topCandidates(1).first?.string }
        return Self.normalizeLayout(recognized.joined(separator: " "))
    }

    static func normalizeLayout(_ text: String) -> String {
        text.split(whereSeparator: \.isWhitespace).joined(separator: " ").lowercased()
    }

    func stableFrame() async throws -> Frame {
        var previous = try frame()
        for _ in 0..<50 {
            try await Task.sleep(for: .milliseconds(20))
            let next = try frame()
            if next.difference(from: previous) == 0 { return next }
            previous = next
        }
        Issue.record("Hosted payment view did not produce a stable same-input frame")
        return previous
    }
}

@Suite("Real payment View integration", .serialized, .processGlobalState)
@MainActor
struct PaymentViewIntegrationTests {
    private enum PurchaseFailure: Error { case failed }

    private func waitUntil(_ reason: String = "payment view condition", _ condition: () -> Bool) async throws {
        for _ in 0..<250 {
            if condition() { return }
            try await Task.sleep(for: .milliseconds(20))
        }
        try #require(condition(), "\(reason)")
    }

    private func renderedFrame(account: String, dashboard: Bool = false,
                               period: TrialStoreKitFixture.Period = .week,
                               includesFreeOffer: Bool = true,
                               inspect: ((PaymentViewHost, PaymentViewHost.Frame, Product, SubscriptionTrialOffer?) throws -> Void)? = nil) async throws -> PaymentViewHost.Frame {
        let fixture = try PaymentViewFixture(accountJSON: account, period: period, includesFreeOffer: includesFreeOffer)
        defer { fixture.close() }
        try await fixture.load()
        let host = try PaymentViewHost(dashboard ? AnyView(fixture.dashboard()) : AnyView(fixture.plans()))
        defer { host.close() }
        if dashboard {
            try await waitUntil { fixture.http.servedCallSequence().contains("GET /usage/stats") }
        } else {
            try await waitUntil { fixture.ready() }
        }
        // Allow the actual load's final @State/observation update to paint.
        try await Task.sleep(for: .milliseconds(80))
        let first = try await host.stableFrame()
        let second = try await host.stableFrame()
        let sameInputDifference = first.difference(from: second)
        #expect(sameInputDifference == 0)
        if let inspect {
            let product = try fixture.catalog.product()
            let offer = await fixture.catalog.manager.freeTrialOffer(for: product)
            try inspect(host, second, product, offer)
        }
        return second
    }

    @Test(arguments: [false, true])
    func actualParentIncludesThePurchasedTrialStatus(dashboard: Bool) async throws {
        let ordinary = PaymentViewFixture.accountJSON(subscriptionTrial: false)
        let trial = PaymentViewFixture.accountJSON(subscriptionTrial: true)
        let first = try await renderedFrame(account: ordinary, dashboard: dashboard)
        let repeatControl = try await renderedFrame(account: ordinary, dashboard: dashboard)
        let repeatedDifference = first.difference(from: repeatControl)
        #expect(repeatedDifference == 0)
        let withTrial = try await renderedFrame(account: trial, dashboard: dashboard)
        let trialDifference = first.difference(from: withTrial)
        #expect(trialDifference > 100)
    }

    @Test(arguments: [TrialStoreKitFixture.Period.week, .twoWeeks])
    func actualParentPassesTheFreeOfferToItsCard(period: TrialStoreKitFixture.Period) async throws {
        let account = PaymentViewFixture.accountJSON()
        let without = try await renderedFrame(account: account, period: period, includesFreeOffer: false)
        let withOffer = try await renderedFrame(account: account, period: period) { host, frame, product, offer in
            let offer = try #require(offer)
            let subscription = try #require(product.subscription)
            try #require(subscription.subscriptionPeriod.unit == .month)
            try #require(subscription.subscriptionPeriod.value == 1)
            let expectedTerms = PaymentViewHost.normalizeLayout(
                "\(offer.durationDescription) free when you subscribe, then \(product.displayPrice)/month.")
            let renderedTerms = try host.renderedText(from: frame)
            #expect(renderedTerms.contains(expectedTerms))
        }
        let offerDifference = without.difference(from: withOffer)
        #expect(offerDifference > 100)
    }

    @Test func actualCardDisablesPurchaseWhenItsOfferWouldShortenThePromise() async throws {
        let account = PaymentViewFixture.accountJSON(signupDays: 12)
        let restricted = try await renderedFrame(account: account, period: .week)
        let allowed = try await renderedFrame(account: account, period: .twoWeeks)
        // Read the actual enabled/disabled prominent-button fill, independently
        // of the reason text (which remains present in the predicate mutant).
        let restrictedBlue = restricted.bluePixels
        let allowedBlue = allowed.bluePixels
        #expect(allowedBlue > restrictedBlue + 1_000)
    }

    @Test(.timeLimit(.minutes(1)))
    func mountedAllowedActionUsesRealStoreKitTokenDeliveryGateAndState() async throws {
        let fixture = try PaymentViewFixture(accountJSON: PaymentViewFixture.accountJSON(signupDays: 1), holdPreflight: true)
        defer { fixture.close() }
        try await fixture.load()
        let product = try fixture.catalog.product()
        let host = try PaymentViewHost(fixture.plans())
        defer { host.close() }
        try await waitUntil("allowed initial load") { fixture.ready() }
        let action = try #require(fixture.action)
        let state = try #require(fixture.state)
        let idle = try await host.stableFrame()
        let operation = Task { await action(product, nil) }
        try await waitUntil("allowed held preflight") { fixture.heldPreflight?.hasEntered == true }
        #expect(state().busy)
        // This overlay contains an animated spinner, so identical consecutive
        // frames are neither expected nor a useful pending-state condition.
        let busy = try host.frame()
        #expect(state().busy)
        #expect(fixture.heldPreflight?.hasTimedOut == false)
        let busyDifference = idle.difference(from: busy)
        #expect(busyDifference > 100)
        fixture.heldPreflight?.release()
        await operation.value
        try await waitUntil("allowed signed delivery") { fixture.requests.snapshot.deliveredTokens.count == 1 }
        #expect(!state().busy && state().error == nil)
        #expect(state().account?.planTier == "Basic")
        #expect(AISubscriptionGate.shared.isActive)
        #expect(fixture.catalog.manager.subscriptionOwnerUserId == PaymentViewFixture.userA)
        #expect(fixture.catalog.manager.purchasedProductIDs.contains(product.id))
        #expect(fixture.requests.snapshot.accountReads == 3)
        #expect(fixture.requests.snapshot.validAuthorization)
        #expect(fixture.requests.snapshot.deliveredTokens == [PaymentViewFixture.userA])
        #expect(fixture.requests.snapshot.deliveredEnvironments == ["Xcode"])
        var actualLocalToken = false
        for await result in Transaction.currentEntitlements {
            if case .verified(let transaction) = result, transaction.productID == product.id {
                #expect(transaction.environment == .xcode)
                actualLocalToken = transaction.appAccountToken == UUID(uuidString: PaymentViewFixture.userA)
            }
        }
        #expect(actualLocalToken)
    }

    @Test func actualActionPreservesTheLegacyPromiseBeforeAnyStoreKitPurchase() async throws {
        let fixture = try PaymentViewFixture(accountJSON: PaymentViewFixture.accountJSON(signupDays: 12))
        defer { fixture.close() }
        try await fixture.load()
        let product = try fixture.catalog.product()
        let host = try PaymentViewHost(fixture.plans())
        defer { host.close() }
        try await waitUntil { fixture.ready() }
        let action = try #require(fixture.action), state = try #require(fixture.state)
        await action(product, nil)
        #expect(!state().busy)
        #expect(state().error?.contains("keep all your free time") == true)
        #expect(fixture.requests.snapshot.accountReads == 2)
        #expect(fixture.requests.snapshot.deliveredTokens.isEmpty)
        #expect(fixture.catalog.manager.purchasedProductIDs.isEmpty)
        #expect(!AISubscriptionGate.shared.isActive)
    }

    @Test func actualActionStopsWhenFreshAccountAuthorityFails() async throws {
        let fixture = try PaymentViewFixture(accountJSON: PaymentViewFixture.accountJSON(signupDays: 1), failedPreflight: true)
        defer { fixture.close() }
        try await fixture.load()
        let product = try fixture.catalog.product()
        let host = try PaymentViewHost(fixture.plans())
        defer { host.close() }
        try await waitUntil { fixture.ready() }
        let action = try #require(fixture.action), state = try #require(fixture.state)
        await action(product, nil)
        #expect(!state().busy && state().error == "Purchase failed. Please try again.")
        #expect(fixture.requests.snapshot.accountReads == 2)
        #expect(fixture.requests.snapshot.deliveredTokens.isEmpty)
        #expect(fixture.catalog.manager.purchasedProductIDs.isEmpty)
        #expect(!AISubscriptionGate.shared.isActive)
    }

    @Test(arguments: [false, true])
    func realActionRejectsANewerSessionAfterItsAccountRead(changeUser: Bool) async throws {
        let fixture = try PaymentViewFixture(accountJSON: PaymentViewFixture.accountJSON(signupDays: 1), holdPreflight: true)
        defer { fixture.close() }
        try await fixture.load()
        let product = try fixture.catalog.product()
        let host = try PaymentViewHost(fixture.plans())
        defer { host.close() }
        try await waitUntil { fixture.ready() }
        let action = try #require(fixture.action), state = try #require(fixture.state)
        let operation = Task { await action(product, nil) }
        try await waitUntil { fixture.heldPreflight?.hasEntered == true }
        try fixture.changeSession(to: changeUser ? PaymentViewFixture.userB : PaymentViewFixture.userA)
        fixture.heldPreflight?.release()
        await operation.value
        #expect(!state().busy && state().error?.contains("account changed") == true)
        #expect(fixture.requests.snapshot.deliveredTokens.isEmpty)
        #expect(fixture.catalog.manager.purchasedProductIDs.isEmpty)
        #expect(!AISubscriptionGate.shared.isActive)
    }

    @Test(.timeLimit(.minutes(1)), arguments: [false, true])
    func realLocalPurchaseDeliversForAWithoutUpdatingTheNewSession(changeUser: Bool) async throws {
        let fixture = try PaymentViewFixture(accountJSON: PaymentViewFixture.accountJSON(signupDays: 1))
        defer { fixture.close() }
        try await fixture.load()
        let product = try fixture.catalog.product()
        let host = try PaymentViewHost(fixture.plans())
        defer { host.close() }
        try await waitUntil { fixture.ready() }
        let action = try #require(fixture.action), state = try #require(fixture.state)
        var held = false
        var resume: CheckedContinuation<Void, Never>?
        let operation = Task {
            await action(product, { product, userId in
                let jws = try await fixture.catalog.manager.purchase(product, userId: userId)
                held = true
                await withCheckedContinuation { resume = $0 }
                return jws
            })
        }
        try await waitUntil { held }
        #expect(fixture.catalog.manager.subscriptionOwnerUserId == PaymentViewFixture.userA)
        let newUser = changeUser ? PaymentViewFixture.userB : PaymentViewFixture.userA
        try fixture.changeSession(to: newUser)
        resume?.resume()
        await operation.value
        try await waitUntil { fixture.requests.snapshot.deliveredTokens.count == 1 }
        #expect(TabMailAuthService.getSession(sessionStore: fixture.sessionStore)?.userId == newUser)
        #expect(!AISubscriptionGate.shared.isActive)
        #expect(state().account?.planTier == "Trial")
        #expect(!state().busy && state().error == nil)
        #expect(fixture.requests.snapshot.accountReads == 2)
        #expect(fixture.requests.snapshot.deliveredTokens == [PaymentViewFixture.userA])
        #expect(fixture.requests.snapshot.deliveredEnvironments == ["Xcode"])
    }

    @Test(arguments: [false, true])
    func cancelledOrFailedPurchaseReleasesTheActualMountedState(fails: Bool) async throws {
        let fixture = try PaymentViewFixture(accountJSON: PaymentViewFixture.accountJSON(signupDays: 1))
        defer { fixture.close() }
        try await fixture.load()
        let product = try fixture.catalog.product()
        let host = try PaymentViewHost(fixture.plans())
        defer { host.close() }
        try await waitUntil { fixture.ready() }
        let action = try #require(fixture.action), state = try #require(fixture.state)
        await action(product, { _, _ in if fails { throw PurchaseFailure.failed }; return nil })
        #expect(!state().busy)
        #expect(state().error == (fails ? "Purchase failed. Please try again." : nil))
        #expect(fixture.requests.snapshot.deliveredTokens.isEmpty)
        #expect(fixture.catalog.manager.purchasedProductIDs.isEmpty)
        #expect(!AISubscriptionGate.shared.isActive)
    }
}
