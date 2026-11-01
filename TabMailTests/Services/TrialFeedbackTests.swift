/* This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at https://mozilla.org/MPL/2.0/. */

import Foundation
import SwiftUI
import UIKit
import Vision
import Synchronization
import Testing
@testable import TabMail

/// The shared FakeHTTP adds a per-scenario header. This transport deliberately
/// does not, so the actual privacy request can be inspected without a test ID.
private final class FeedbackPacketProtocol: URLProtocol, @unchecked Sendable {
    enum Mode: Sendable { case status(Int), failure, held, redirect }
    struct Packet: Sendable {
        let url: URL?
        let method: String?
        let headers: [String: String]
        let body: Data
    }
    struct State: Sendable {
        var mode: Mode = .status(204)
        var packets: [Packet] = []
        var stopped = 0
    }
    static let state = Mutex(State())

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        var bytes = request.httpBody ?? Data()
        if let stream = request.httpBodyStream {
            stream.open()
            defer { stream.close() }
            var buffer = [UInt8](repeating: 0, count: 1024)
            while stream.hasBytesAvailable {
                let count = stream.read(&buffer, maxLength: buffer.count)
                if count <= 0 { break }
                bytes.append(contentsOf: buffer.prefix(count))
            }
        }
        let mode = Self.state.withLock { value in
            value.packets.append(Packet(url: request.url, method: request.httpMethod, headers: request.allHTTPHeaderFields ?? [:], body: bytes))
            return value.mode
        }
        switch mode {
        case .failure:
            client?.urlProtocol(self, didFailWithError: URLError(.notConnectedToInternet))
        case .held: break
        case .redirect:
            if request.url?.host == TrialFeedbackConfig.endpoint.host {
                var redirected = request
                redirected.url = URL(string: "https://unrelated.example.test/feedback")!
                redirected.httpBody = bytes
                let response = HTTPURLResponse(url: request.url!, statusCode: 307, httpVersion: nil, headerFields: ["Location": redirected.url!.absoluteString])!
                client?.urlProtocol(self, wasRedirectedTo: redirected, redirectResponse: response)
                client?.urlProtocolDidFinishLoading(self)
            } else { finish(status: 204) }
        case .status(let code): finish(status: code)
        }
    }

    private func finish(status: Int) {
        let response = HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil, headerFields: nil)!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() { Self.state.withLock { $0.stopped += 1 } }
}

@Suite("Feedback request privacy", .serialized, .processGlobalState)
struct TrialFeedbackClientTests {
    private struct ConfigurationSnapshot: Sendable {
        let noCookies: Bool
        let noCredentials: Bool
        let noCache: Bool
        let noConnectivityWait: Bool
    }

    @Test(arguments: TrialFeedbackReason.allCases)
    func onlyTheVersionAndExplicitReasonLeaveTheClient(reason: TrialFeedbackReason) async throws {
        FeedbackPacketProtocol.state.withLock { $0 = .init() }
        let snapshot = Mutex<ConfigurationSnapshot?>(nil)
        let client = TrialFeedbackClient { config in
            snapshot.withLock { $0 = ConfigurationSnapshot(noCookies: config.httpCookieStorage == nil && !config.httpShouldSetCookies,
                noCredentials: config.urlCredentialStorage == nil, noCache: config.urlCache == nil,
                noConnectivityWait: !config.waitsForConnectivity) }
            config.protocolClasses = [FeedbackPacketProtocol.self]
        }
        try await client.submit(reason: reason)
        let packets = FeedbackPacketProtocol.state.withLock { $0.packets }
        #expect(packets.count == 1)
        let packet = try #require(packets.first)
        #expect(packet.url?.absoluteString == "https://usage-dev.tabmail.ai/feedback/trial")
        #expect(packet.url?.query == nil && packet.url?.user == nil && packet.url?.password == nil)
        #expect(packet.method == "POST")
        let fields = Dictionary(uniqueKeysWithValues: packet.headers.map { ($0.key.lowercased(), $0.value) })
        #expect(fields["user-agent"] == "TabMail Feedback")
        #expect(fields["accept-language"] == "*")
        for forbidden in ["authorization", "cookie", "referer", "origin", "x-user-id", "x-device-id", "x-internal-usage-secret", "x-gateway-user-id"] {
            #expect(fields[forbidden] == nil)
        }
        let body = try #require(JSONSerialization.jsonObject(with: packet.body) as? [String: String])
        #expect(body == ["questionnaire_version": "trial-v1", "reason": reason.rawValue])
        let config = try #require(snapshot.withLock { $0 })
        #expect(config.noCookies && config.noCredentials && config.noCache && config.noConnectivityWait)
    }

    @Test(arguments: [200, 201, 400, 404, 429, 503])
    func errorsAreNotAutomaticallyRetriedOrReportedAsAccepted(status: Int) async {
        FeedbackPacketProtocol.state.withLock { $0 = .init(mode: .status(status)) }
        let client = TrialFeedbackClient { $0.protocolClasses = [FeedbackPacketProtocol.self] }
        do { try await client.submit(reason: .priceValue); Issue.record("A non-204 response was accepted") } catch {}
        #expect(FeedbackPacketProtocol.state.withLock { $0.packets.count } == 1)
    }

    @Test func transportFailureIsNotAutomaticallyRetried() async {
        FeedbackPacketProtocol.state.withLock { $0 = .init(mode: .failure) }
        let client = TrialFeedbackClient { $0.protocolClasses = [FeedbackPacketProtocol.self] }
        do { try await client.submit(reason: .missingFeature); Issue.record("A failed request was accepted") } catch {}
        #expect(FeedbackPacketProtocol.state.withLock { $0.packets.count } == 1)
    }

    @Test(.timeLimit(.minutes(1)))
    func theAnswerIsNeverForwardedToARedirectDestination() async {
        FeedbackPacketProtocol.state.withLock { $0 = .init(mode: .redirect) }
        let client = TrialFeedbackClient { $0.protocolClasses = [FeedbackPacketProtocol.self] }
        do { try await client.submit(reason: .aiReliability); Issue.record("Redirected feedback was accepted") } catch {}
        let packets = FeedbackPacketProtocol.state.withLock { $0.packets }
        #expect(packets.count == 1)
        #expect(packets.allSatisfy { $0.url?.host == "usage-dev.tabmail.ai" })
    }

    @Test(.timeLimit(.minutes(1)))
    func cancellationStopsTheDedicatedTransport() async throws {
        FeedbackPacketProtocol.state.withLock { $0 = .init(mode: .held) }
        let client = TrialFeedbackClient { $0.protocolClasses = [FeedbackPacketProtocol.self] }
        let task = Task { try await client.submit(reason: .notEnoughUse) }
        for _ in 0..<100 {
            if FeedbackPacketProtocol.state.withLock({ !$0.packets.isEmpty }) { break }
            try await Task.sleep(for: .milliseconds(10))
        }
        try #require(FeedbackPacketProtocol.state.withLock { $0.packets.count } == 1)
        task.cancel()
        do { try await task.value; Issue.record("A cancelled request was accepted") } catch {}
        #expect(FeedbackPacketProtocol.state.withLock { $0.stopped } > 0)
    }
}

private final class FeedbackChallengeSender: NSObject, URLAuthenticationChallengeSender {
    func use(_ credential: URLCredential, for challenge: URLAuthenticationChallenge) { }
    func continueWithoutCredential(for challenge: URLAuthenticationChallenge) { }
    func cancel(_ challenge: URLAuthenticationChallenge) { }
}

@Suite("Feedback authentication boundary")
struct TrialFeedbackAuthenticationTests {
    @Test(arguments: [NSURLAuthenticationMethodHTTPBasic, NSURLAuthenticationMethodDefault, NSURLAuthenticationMethodServerTrust])
    func sessionAndTaskChallengesNeverUseStoredCredentials(method: String) {
        let session = URLSession(configuration: .ephemeral)
        defer { session.invalidateAndCancel() }
        let task = session.dataTask(with: TrialFeedbackConfig.endpoint)
        let space = URLProtectionSpace(host: "example.test", port: 443, protocol: "https", realm: nil, authenticationMethod: method)
        let challenge = URLAuthenticationChallenge(protectionSpace: space,
            proposedCredential: URLCredential(user: "synthetic", password: "synthetic", persistence: .none),
            previousFailureCount: 0, failureResponse: nil, error: nil, sender: FeedbackChallengeSender())
        let delegate = TrialFeedbackSessionDelegate()
        let results = Mutex<[(URLSession.AuthChallengeDisposition, Bool)]>([])
        let capture: @Sendable (URLSession.AuthChallengeDisposition, URLCredential?) -> Void = { disposition, credential in
            results.withLock { $0.append((disposition, credential == nil)) }
        }
        delegate.urlSession(session, didReceive: challenge, completionHandler: capture)
        delegate.urlSession(session, task: task, didReceive: challenge, completionHandler: capture)
        let observed = results.withLock { $0 }
        #expect(observed.count == 2)
        for (disposition, noCredential) in observed {
            #expect(noCredential)
            #expect(disposition == (method == NSURLAuthenticationMethodServerTrust ? .performDefaultHandling : .cancelAuthenticationChallenge))
        }
    }
}

private actor FeedbackSubmitter: TrialFeedbackSubmitting {
    enum Failure: Error { case unavailable }
    let held: Bool
    let fails: Bool
    private(set) var reasons: [TrialFeedbackReason] = []
    private var continuation: CheckedContinuation<Void, any Error>?
    init(held: Bool = false, fails: Bool = false) { self.held = held; self.fails = fails }
    func submit(reason: TrialFeedbackReason) async throws {
        reasons.append(reason)
        if fails { throw Failure.unavailable }
        if held { try await withCheckedThrowingContinuation { continuation = $0 } }
    }
    func release() { continuation?.resume(); continuation = nil }
}

@Suite("Optional feedback choices", .serialized, .processGlobalState)
@MainActor
struct TrialFeedbackFlowTests {
    private func fixture() throws -> (String, UserDefaults, TrialFeedbackPromptState) {
        let name = "TrialFeedbackTests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: name))
        return (name, defaults, TrialFeedbackPromptState(defaults: defaults))
    }

    @Test func noSelectionAndLocalDismissalsSendNothing() async throws {
        let (name, defaults, prompt) = try fixture()
        defer { defaults.removePersistentDomain(forName: name) }
        let client = FeedbackSubmitter()
        let flow = TrialFeedbackFlow(prompt: prompt, client: client)
        #expect(flow.selectedReason == nil && !flow.canSubmit)
        await flow.submit()
        prompt.notNow()
        #expect(prompt.deferredThisRun)
        #expect(defaults.persistentDomain(forName: name) == nil || defaults.persistentDomain(forName: name)?.isEmpty == true)
        prompt.doNotAskAgain()
        #expect(TrialFeedbackPromptState(defaults: defaults).isSuppressed)
        #expect(await client.reasons.isEmpty)
    }

    @Test func aConfirmedSubmissionStoresOnlyTheDeviceSuppressionChoice() async throws {
        let (name, defaults, prompt) = try fixture()
        defer { defaults.removePersistentDomain(forName: name) }
        let client = FeedbackSubmitter()
        let flow = TrialFeedbackFlow(prompt: prompt, client: client)
        flow.selectedReason = .priceValue
        await flow.submit()
        #expect(flow.isComplete && !flow.isSubmitting && flow.selectedReason == nil)
        #expect(prompt.isSuppressed)
        #expect(await client.reasons == [.priceValue])
        let saved = try #require(defaults.persistentDomain(forName: name))
        #expect(Set(saved.keys) == ["trialFeedback.suppressed"])
        #expect(saved["trialFeedback.suppressed"] as? Bool == true)
        await flow.submit()
        #expect(await client.reasons.count == 1)
    }

    @Test func failureKeepsTheChoiceWithoutClaimingConfirmedDeliveryOrSuppressingTheInvitation() async throws {
        let (name, defaults, prompt) = try fixture()
        defer { defaults.removePersistentDomain(forName: name) }
        let client = FeedbackSubmitter(fails: true)
        let flow = TrialFeedbackFlow(prompt: prompt, client: client)
        flow.selectedReason = .missingFeature
        await flow.submit()
        #expect(!flow.isComplete && !flow.isSubmitting && flow.canSubmit)
        #expect(flow.selectedReason == .missingFeature)
        #expect(flow.errorText?.contains("couldn't confirm delivery") == true)
        #expect(!prompt.isSuppressed)
        #expect(await client.reasons.count == 1)
    }

    @Test(.timeLimit(.minutes(1)))
    func onePendingSubmissionCapturesItsChoiceAndCancellationDoesNotSuppressAnotherInvitation() async throws {
        let (name, defaults, prompt) = try fixture()
        defer { defaults.removePersistentDomain(forName: name) }
        let client = FeedbackSubmitter(held: true)
        let flow = TrialFeedbackFlow(prompt: prompt, client: client)
        flow.selectedReason = .existingWorkflow
        let task = Task { await flow.submit() }
        for _ in 0..<100 {
            if await client.reasons.count == 1 { break }
            try await Task.sleep(for: .milliseconds(10))
        }
        try #require(await client.reasons.count == 1)
        #expect(flow.isSubmitting && !flow.canSubmit)
        flow.selectedReason = .other
        await flow.submit()
        #expect(await client.reasons == [.existingWorkflow])
        task.cancel()
        await client.release()
        await task.value
        #expect(!flow.isComplete && !flow.isSubmitting)
        #expect(!prompt.isSuppressed && flow.errorText == nil)
    }
}


@MainActor
private final class TrialFeedbackHost {
    private let window: UIWindow
    private let controller: UIViewController

    init<V: View>(_ view: V, dark: Bool = false, largeText: Bool = false) throws {
        let scene = try #require(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        controller = UIHostingController(rootView: view.environment(\.locale, Locale(identifier: "en_US"))
            .dynamicTypeSize(largeText ? .accessibility3 : .large))
        window = UIWindow(windowScene: scene)
        window.frame = CGRect(x: 0, y: 0, width: 390, height: 844)
        window.overrideUserInterfaceStyle = dark ? .dark : .light
        window.rootViewController = controller
        window.makeKeyAndVisible()
        window.layoutIfNeeded()
    }

    func close() {
        window.isHidden = true
        controller.view.removeFromSuperview()
        window.rootViewController = nil
    }

    func text(topOnly: Bool = false) async throws -> String {
        // A short settling interval is followed by one local OCR pass. No
        // customer screenshot or UI contents leave the test process.
        try await Task.sleep(for: .milliseconds(350))
        controller.view.layoutIfNeeded()
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        let rendered = UIGraphicsImageRenderer(bounds: controller.view.bounds, format: format).image { _ in
            controller.view.drawHierarchy(in: controller.view.bounds, afterScreenUpdates: true)
        }
        var cg = try #require(rendered.cgImage)
        if topOnly { cg = try #require(cg.cropping(to: CGRect(x: 0, y: 0, width: cg.width, height: min(cg.height, 440)))) }
        let request = VNRecognizeTextRequest()
        request.revision = VNRecognizeTextRequestRevision3
        request.recognitionLanguages = ["en-US"]
        request.recognitionLevel = .accurate
        request.usesLanguageCorrection = false
        try VNImageRequestHandler(cgImage: cg, options: [:]).perform([request])
        return try #require(request.results).compactMap { $0.topCandidates(1).first?.string }
            .joined(separator: " ").split(whereSeparator: \.isWhitespace).joined(separator: " ").lowercased()
    }
}

@Suite("Feedback surfaces", .serialized, .processGlobalState)
@MainActor
struct TrialFeedbackViewTests {
    @Test(arguments: [false, true])
    func openingTheFormIsOptionalAndDoesNotSubmit(dark: Bool) async throws {
        let name = "TrialFeedbackViews.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: name))
        defer { defaults.removePersistentDomain(forName: name) }
        let prompt = TrialFeedbackPromptState(defaults: defaults)
        let client = FeedbackSubmitter()
        let flow = TrialFeedbackFlow(prompt: prompt, client: client)
        let host = try TrialFeedbackHost(TrialFeedbackForm(flow: flow), dark: dark)
        defer { host.close() }
        let text = try await host.text()
        #expect(text.contains("help improve tabmail"))
        #expect(text.contains("not now"))
        #expect(text.contains("price is higher"))
        #expect(text.contains("haven't used it enough"))
        #expect(flow.selectedReason == nil && !flow.canSubmit)
        #expect(await client.reasons.isEmpty)
    }

    @Test func theMountedFormShowsAConfirmedOutcome() async throws {
        let name = "TrialFeedbackViews.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: name))
        defer { defaults.removePersistentDomain(forName: name) }
        let prompt = TrialFeedbackPromptState(defaults: defaults)
        let flow = TrialFeedbackFlow(prompt: prompt, client: FeedbackSubmitter())
        let host = try TrialFeedbackHost(TrialFeedbackForm(flow: flow))
        defer { host.close() }
        flow.selectedReason = .notEnoughUse
        await flow.submit()
        let complete = try await host.text()
        #expect(complete.contains("thanks for your feedback"))
        #expect(!complete.contains("main reason"))
        #expect(prompt.isSuppressed)
    }

    @Test(.timeLimit(.minutes(1)))
    func theMountedSubmitActionSendsExactlyTheChosenReasonOnce() async throws {
        let name = "TrialFeedbackActions.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: name))
        defer { defaults.removePersistentDomain(forName: name) }
        let prompt = TrialFeedbackPromptState(defaults: defaults)
        let client = FeedbackSubmitter()
        let flow = TrialFeedbackFlow(prompt: prompt, client: client)
        var actions: TrialFeedbackForm.Actions?
        let host = try TrialFeedbackHost(TrialFeedbackForm(flow: flow, actionsReady: { actions = $0 }))
        defer { host.close() }
        for _ in 0..<100 {
            if actions != nil { break }
            try await Task.sleep(for: .milliseconds(10))
        }
        let mounted = try #require(actions)
        mounted.submit()
        #expect(await client.reasons.isEmpty)
        mounted.select(.priceValue)
        mounted.submit()
        mounted.select(.other)
        mounted.submit()
        for _ in 0..<100 {
            if flow.isComplete { break }
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(flow.isComplete && prompt.isSuppressed)
        #expect(await client.reasons == [.priceValue])
        #expect((try await host.text()).contains("thanks for your feedback"))
    }

    @Test(arguments: [false, true])
    func mountedDismissalActionsSendNothingAndRespectTheLocalChoice(permanent: Bool) async throws {
        let name = "TrialFeedbackDismissal.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: name))
        defer { defaults.removePersistentDomain(forName: name) }
        let prompt = TrialFeedbackPromptState(defaults: defaults)
        let client = FeedbackSubmitter()
        let flow = TrialFeedbackFlow(prompt: prompt, client: client)
        var actions: TrialFeedbackForm.Actions?
        let host = try TrialFeedbackHost(TrialFeedbackForm(flow: flow, actionsReady: { actions = $0 }))
        defer { host.close() }
        for _ in 0..<100 {
            if actions != nil { break }
            try await Task.sleep(for: .milliseconds(10))
        }
        let mounted = try #require(actions)
        mounted.select(.existingWorkflow)
        if permanent { mounted.doNotAskAgain() } else { mounted.notNow() }
        #expect(await client.reasons.isEmpty)
        #expect(prompt.isSuppressed == permanent)
        #expect(prompt.deferredThisRun == !permanent)
        #expect(TrialFeedbackPromptState(defaults: defaults).isSuppressed == permanent)
    }

    @Test(.timeLimit(.minutes(1)))
    func removingTheMountedFormCancelsItsPendingSubmission() async throws {
        let name = "TrialFeedbackCancellation.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: name))
        defer { defaults.removePersistentDomain(forName: name) }
        let prompt = TrialFeedbackPromptState(defaults: defaults)
        let client = FeedbackSubmitter(held: true)
        let flow = TrialFeedbackFlow(prompt: prompt, client: client)
        var actions: TrialFeedbackForm.Actions?
        let host = try TrialFeedbackHost(TrialFeedbackForm(flow: flow, actionsReady: { actions = $0 }))
        defer { host.close() }
        for _ in 0..<100 {
            if actions != nil { break }
            try await Task.sleep(for: .milliseconds(10))
        }
        let mounted = try #require(actions)
        mounted.select(.aiReliability)
        mounted.submit()
        for _ in 0..<100 {
            if await client.reasons.count == 1 { break }
            try await Task.sleep(for: .milliseconds(10))
        }
        try #require(flow.isSubmitting && (await client.reasons.count) == 1)
        actions = nil
        host.close()
        try await Task.sleep(for: .milliseconds(50))
        await client.release()
        for _ in 0..<100 {
            if !flow.isSubmitting { break }
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(!flow.isComplete && !prompt.isSuppressed && !flow.isSubmitting)
        #expect(flow.errorText == nil)
        #expect(await client.reasons == [.aiReliability])
    }

    @Test(arguments: ["ended", "demo", "no-session", "other-folder", "paid", "running"])
    func theActualInboxRequiresCurrentExpiredAuthorityAndARealSession(scenario: String) async throws {
        PreviewMocks.hideAllTips()
        let gate = AISubscriptionGate.shared
        let oldActive = gate.isActive
        let oldDemo = DemoModeStore.shared.isActive
        gate.noteSignedOut()
        DemoModeStore.shared.isActive = scenario == "demo"
        defer {
            gate.noteSignedOut()
            if oldActive { gate.openGate() } else { gate.closeGate() }
            DemoModeStore.shared.isActive = oldDemo
        }
        let otherFolder = scenario == "other-folder"
        let folder = Folder(name: "Inbox", path: "INBOX", role: otherFolder ? .sent : .inbox, accountId: UUID().uuidString)
        let view = NavigationStack {
            InboxView(title: "Mailbox", folders: [folder], selection: .unified(otherFolder ? .sent : .inbox),
                selectedMessageId: .constant(nil), pushedMessageId: .constant(nil))
        }.environment(NavigationStore()).environment(\.hasTabMailSession, scenario != "no-session")
        let host = try TrialFeedbackHost(view)
        defer { host.close() }
        #expect(!(try await host.text(topOnly: true)).contains("what's keeping"))
        if scenario == "running" {
            gate.apply(try WhoamiFixture.runningSignupTrial(daysLeft: 3, reference: Date()))
        } else if scenario == "paid" {
            gate.apply(try WhoamiFixture.accountInfo(hasSubscription: true))
        } else {
            gate.apply(try WhoamiFixture.expiredSignupTrial(endedDaysAgo: 1, reference: Date()))
        }
        let ended = try await host.text(topOnly: true)
        #expect(ended.contains("what's keeping") == (scenario == "ended"))
        gate.noteSignedOut()
        #expect(!(try await host.text(topOnly: true)).contains("what's keeping"))
    }
}
