/* This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at https://mozilla.org/MPL/2.0/. */

import Foundation
import Darwin
import ObjectiveC
import SwiftUI
import Observation
import UIKit
import Vision
import Synchronization
import Testing
@testable import TabMail

/// The shared FakeHTTP adds a per-scenario header. This transport deliberately
/// does not, so the actual privacy request can be inspected without a test ID.
private final class FeedbackPacketProtocol: URLProtocol, @unchecked Sendable {
    enum Mode: Sendable { case status(Int), failure, held, redirect, trickling }
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
        var chunks = 0
    }
    static let state = Mutex(State())
    private let streamTask = Mutex<Task<Void, Never>?>(nil)

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
        case .trickling:
            let response = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: "HTTP/1.1",
                headerFields: ["Content-Length": "1000000"])!
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            let task = Task { @Sendable [weak self] in
                for _ in 0..<400 {
                    do { try await Task.sleep(for: .milliseconds(100)) } catch { return }
                    guard let self, !Task.isCancelled else { return }
                    Self.state.withLock { $0.chunks += 1 }
                    self.client?.urlProtocol(self, didLoad: Data([0x20]))
                }
            }
            streamTask.withLock { $0 = task }
        case .redirect:
            if request.url?.host == TrialFeedbackConfig.endpoint.host {
                var redirected = request
                redirected.url = URL(string: "https://unrelated.example.test/feedback")!
                redirected.httpBody = bytes
                let response = HTTPURLResponse(url: request.url!, statusCode: 307, httpVersion: nil, headerFields: ["Location": redirected.url!.absoluteString])!
                client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
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
    override func stopLoading() {
        streamTask.withLock { $0?.cancel(); $0 = nil }
        Self.state.withLock { $0.stopped += 1 }
    }
}

/// Scoped interception of the public NSURLSession factory. The production
/// initializer, delegate and task still run; only the local protocol is installed.
/// A preflight proves interception before any default feedback flow may submit.
private final class FeedbackSessionScope: @unchecked Sendable {
    private typealias Factory = @convention(c) (AnyObject, Selector, URLSessionConfiguration, AnyObject?, OperationQueue?) -> URLSession
    private typealias FactoryBlock = @convention(block) (AnyObject, URLSessionConfiguration, AnyObject?, OperationQueue?) -> URLSession
    private final class References: @unchecked Sendable {
        private let lock = NSLock()
        private weak var session: URLSession?
        private weak var delegate: AnyObject?
        init(session: URLSession, delegate: AnyObject?) { self.session = session; self.delegate = delegate }
        var released: Bool {
            lock.lock(); defer { lock.unlock() }
            return session == nil && delegate == nil
        }
        func cancel() {
            lock.lock(); let current = session; lock.unlock()
            current?.invalidateAndCancel()
        }
    }
    private final class Probe: @unchecked Sendable {
        let entries = Mutex<[References]>([])
        func capture(_ session: URLSession, delegate: AnyObject?) {
            entries.withLock { $0.append(References(session: session, delegate: delegate)) }
        }
    }
    private struct RetainedBlock: @unchecked Sendable { let implementation: IMP }
    // Retain the few test-scope blocks until process exit: an unrelated factory
    // call already in flight may still hold the previous IMP after restoration.
    private static let retainedBlocks = Mutex<[RetainedBlock]>([])
    private let method: Method
    private let original: IMP
    private let replacement: IMP
    private let probe: Probe
    private let closed = Mutex(false)

    init() throws {
        let selector = NSSelectorFromString("sessionWithConfiguration:delegate:delegateQueue:")
        let method = try #require(class_getClassMethod(URLSession.self, selector))
        let original = method_getImplementation(method)
        let factory = unsafeBitCast(original, to: Factory.self)
        let probe = Probe()
        let block: FactoryBlock = { object, config, delegate, queue in
            if delegate is TrialFeedbackSessionDelegate {
                config.protocolClasses = [FeedbackPacketProtocol.self]
                let session = factory(object, selector, config, delegate, queue)
                probe.capture(session, delegate: delegate)
                return session
            }
            return factory(object, selector, config, delegate, queue)
        }
        self.method = method
        self.original = original
        self.replacement = imp_implementationWithBlock(block)
        self.probe = probe
        method_setImplementation(method, replacement)
        do {
            let session = URLSession(configuration: .ephemeral, delegate: TrialFeedbackSessionDelegate(), delegateQueue: nil)
            defer { session.invalidateAndCancel() }
            try #require(probe.entries.withLock { $0.count } == 1)
            try #require(session.configuration.protocolClasses?.contains { $0 == FeedbackPacketProtocol.self } == true)
            probe.entries.withLock { $0.removeAll() }
        } catch { close(); throw error }
    }

    var createdCount: Int { probe.entries.withLock { $0.count } }
    var allReleased: Bool { probe.entries.withLock { !$0.isEmpty && $0.allSatisfy(\.released) } }
    func close() {
        guard closed.withLock({ value in if value { return false }; value = true; return true }) else { return }
        method_setImplementation(method, original)
        for entry in probe.entries.withLock({ $0 }) { entry.cancel() }
        Self.retainedBlocks.withLock { $0.append(RetainedBlock(implementation: replacement)) }
    }
    deinit { close() }
}

@Suite("Production feedback transport lifetime", .serialized, .processGlobalState)
@MainActor
struct TrialFeedbackNativeTransportTests {
    @Test(arguments: [204, 503, -1])
    func ownedSessionsAndDelegatesAreReleased(outcome: Int) async throws {
        let scope = try FeedbackSessionScope()
        defer { scope.close() }
        FeedbackPacketProtocol.state.withLock { $0 = .init(mode: outcome == -1 ? .held : .status(outcome)) }
        let client = TrialFeedbackClient()
        let request = Task { try await client.submit(reason: .other) }
        if outcome == -1 {
            for _ in 0..<200 {
                if FeedbackPacketProtocol.state.withLock({ !$0.packets.isEmpty }) { break }
                try await Task.sleep(for: .milliseconds(10))
            }
            try #require(FeedbackPacketProtocol.state.withLock { $0.packets.count } == 1)
            request.cancel()
        }
        do {
            try await request.value
            #expect(outcome == 204)
        } catch { #expect(outcome != 204) }
        #expect(scope.createdCount == 1)
        for _ in 0..<300 {
            if scope.allReleased { break }
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(scope.allReleased)
        #expect(FeedbackPacketProtocol.state.withLock { $0.packets.count } == 1)
    }
}


@Suite("Feedback total transfer bound", .serialized, .processGlobalState)
@MainActor
struct TrialFeedbackTransferBoundTests {
    @Test(.timeLimit(.minutes(1)))
    func aTricklingResponseCannotExtendTheTotalTransferIndefinitely() async throws {
        let scope = try FeedbackSessionScope()
        defer { scope.close() }
        FeedbackPacketProtocol.state.withLock { $0 = .init(mode: .trickling) }
        let limit = Mutex<TimeInterval?>(nil)
        let completion = Mutex<(done: Bool, code: Int?)>((false, nil))
        let client = TrialFeedbackClient { config in limit.withLock { $0 = config.timeoutIntervalForResource } }
        let began = Date()
        let task = Task {
            do { try await client.submit(reason: .other); completion.withLock { $0 = (true, nil) } }
            catch { completion.withLock { $0 = (true, (error as? URLError)?.code.rawValue) } }
        }
        for _ in 0..<200 {
            if limit.withLock({ $0 != nil }) { break }
            try await Task.sleep(for: .milliseconds(10))
        }
        let configuredLimit = try #require(limit.withLock { $0 })
        if !(configuredLimit > 0 && configuredLimit <= 30) {
            task.cancel(); await task.value
            Issue.record("The total feedback transfer bound exceeds the interactive policy ceiling")
            return
        }
        for _ in 0..<3500 {
            if completion.withLock({ $0.done }) { break }
            try await Task.sleep(for: .milliseconds(10))
        }
        if !completion.withLock({ $0.done }) { task.cancel() }
        await task.value
        #expect(completion.withLock { $0.code } == URLError.Code.timedOut.rawValue)
        #expect(Date().timeIntervalSince(began) < 35)
        #expect(FeedbackPacketProtocol.state.withLock { $0.chunks } > 2)
        #expect(FeedbackPacketProtocol.state.withLock { $0.packets.count } == 1)
    }
}

@Suite("Feedback request privacy", .serialized, .processGlobalState)
struct TrialFeedbackClientTests {
    private struct ConfigurationSnapshot: Sendable {
        let noCookies: Bool
        let noCredentials: Bool
        let noCache: Bool
        let noConnectivityWait: Bool
    }

    @Test func declaredReasonsKeepTheirMeaningOnTheWire() {
        let expected: [(TrialFeedbackReason, String)] = [
            (.priceValue, "price_value"), (.notEnoughUse, "not_enough_use"),
            (.missingFeature, "missing_feature"), (.aiReliability, "ai_reliability"),
            (.existingWorkflow, "existing_workflow"), (.other, "other_or_prefer_not_to_say")
        ]
        #expect(TrialFeedbackReason.allCases.count == expected.count)
        for (reason, wire) in expected { #expect(reason.rawValue == wire) }
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
        for _ in 0..<200 {
            if FeedbackPacketProtocol.state.withLock({ $0.stopped > 0 }) { break }
            try await Task.sleep(for: .milliseconds(10))
        }
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
        if held {
            // Record an overlapping attempt, then reject it instead of losing
            // the first continuation and hanging a deliberately broken run.
            guard continuation == nil else { throw Failure.unavailable }
            try await withCheckedThrowingContinuation { continuation = $0 }
        }
    }
    func release(failing: Bool = false) {
        if failing { continuation?.resume(throwing: Failure.unavailable) }
        else { continuation?.resume() }
        continuation = nil
    }
}

@Suite("Optional feedback choices", .serialized, .processGlobalState)
@MainActor
struct TrialFeedbackFlowTests {
    private func fixture() throws -> (String, UserDefaults, TrialFeedbackPromptState) {
        let name = "TrialFeedbackTests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: name))
        return (name, defaults, TrialFeedbackPromptState(defaults: defaults))
    }

    @Test func automaticInvitationIsOfferedOnceAcrossLaunchesWithoutSavingAnAccountOrAnswer() throws {
        let (name, defaults, prompt) = try fixture()
        defer { defaults.removePersistentDomain(forName: name) }
        #expect(prompt.claimAutomaticPresentation())
        #expect(!prompt.claimAutomaticPresentation())
        let nextLaunch = TrialFeedbackPromptState(defaults: defaults)
        #expect(!nextLaunch.isSuppressed && !nextLaunch.deferredThisRun)
        #expect(!nextLaunch.claimAutomaticPresentation())
        let saved = try #require(defaults.persistentDomain(forName: name))
        #expect(Set(saved.keys) == ["trialFeedback.automaticPresentationShown"])
        #expect(saved["trialFeedback.automaticPresentationShown"] as? Bool == true)
    }

    @Test(arguments: [false, true])
    func localDismissalPreventsAnAutomaticInvitation(suppress: Bool) throws {
        let (name, defaults, prompt) = try fixture()
        defer { defaults.removePersistentDomain(forName: name) }
        if suppress { prompt.doNotAskAgain() } else { prompt.notNow() }
        #expect(!prompt.claimAutomaticPresentation())
        #expect(!prompt.automaticPresentationShown)
        let nextLaunch = TrialFeedbackPromptState(defaults: defaults)
        #expect(nextLaunch.claimAutomaticPresentation() == !suppress)
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
private func feedbackAccessibilityElement(in root: NSObject, identifier: String, labelContains: String? = nil, trace: ((String) -> Void)? = nil) -> NSObject? {
    var pending: [NSObject] = [root]
    var seen = Set<ObjectIdentifier>()
    while let object = pending.popLast(), seen.count < 2_048 {
        guard seen.insert(ObjectIdentifier(object)).inserted else { continue }
        let typed = (object as? UIAccessibilityIdentification)?.accessibilityIdentifier
        let selector = NSSelectorFromString("accessibilityIdentifier")
        let identifierValue = typed ?? (object.responds(to: selector)
            ? object.perform(selector)?.takeUnretainedValue() as? String : nil)
        trace?(String(reflecting: type(of: object)) + ":" + (identifierValue ?? "nil"))
        if !identifier.isEmpty, identifierValue == identifier { return object }
        if let labelContains, object.accessibilityLabel?.lowercased().contains(labelContains) == true { return object }
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

/// Simulator test bootstrap only. SwiftUI omits its accessibility nodes until
/// automation is enabled. This is never linked into a shipping app target.
/// The runtime entry points follow the AccessibilitySnapshot test-enabler
/// pattern; the actual control is located/activated through public UIKit APIs.
@MainActor
private final class FeedbackAccessibilityAutomation {
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

@MainActor
private final class FeedbackSharedPromptScope {
    let prompt = TrialFeedbackPromptState.shared
    private let suppressed: Bool
    private let deferred: Bool
    private let stored: Any?
    private let automaticShown: Bool
    private let storedAutomatic: Any?
    private let key = "trialFeedback.suppressed"
    private let automaticKey = "trialFeedback.automaticPresentationShown"
    init(automaticWasShown: Bool = true) {
        suppressed = prompt.isSuppressed
        deferred = prompt.deferredThisRun
        stored = UserDefaults.standard.object(forKey: key)
        automaticShown = prompt.automaticPresentationShown
        storedAutomatic = UserDefaults.standard.object(forKey: automaticKey)
        // Manual-entry tests represent an installation already offered the popup.
        prompt.restoreTestSnapshot(suppressed: false, deferred: false, automaticShown: automaticWasShown)
        UserDefaults.standard.removeObject(forKey: key)
        UserDefaults.standard.removeObject(forKey: automaticKey)
    }
    func close() {
        if let stored { UserDefaults.standard.set(stored, forKey: key) }
        else { UserDefaults.standard.removeObject(forKey: key) }
        if let storedAutomatic { UserDefaults.standard.set(storedAutomatic, forKey: automaticKey) }
        else { UserDefaults.standard.removeObject(forKey: automaticKey) }
        prompt.restoreTestSnapshot(suppressed: suppressed, deferred: deferred, automaticShown: automaticShown)
    }
}

@MainActor
private final class FeedbackInboxScope {
    let promptScope: FeedbackSharedPromptScope
    private let active = AISubscriptionGate.shared.isActive
    private let ended = AISubscriptionGate.shared.trialHasEnded
    private let demo = DemoModeStore.shared.isActive
    init(automaticWasShown: Bool = true) {
        promptScope = FeedbackSharedPromptScope(automaticWasShown: automaticWasShown)
        AISubscriptionGate.shared.noteSignedOut()
        DemoModeStore.shared.isActive = false
    }
    func close() {
        let gate = AISubscriptionGate.shared
        let restored = ended
            ? try? WhoamiFixture.expiredSignupTrial(endedDaysAgo: 1, reference: Date())
            : try? WhoamiFixture.accountInfo(hasSubscription: true)
        if let restored { gate.apply(restored) }
        gate.noteSignedOut()
        if active { gate.openGate() } else { gate.closeGate() }
        DemoModeStore.shared.isActive = demo
        promptScope.close()
    }
}

@MainActor
private func feedbackInbox(hasSession: Bool = true, otherFolder: Bool = false) -> some View {
    let folder = Folder(name: "Inbox", path: "INBOX", role: otherFolder ? .sent : .inbox, accountId: UUID().uuidString)
    return NavigationStack {
        InboxView(title: "Mailbox", folders: [folder], selection: .unified(otherFolder ? .sent : .inbox),
            selectedMessageId: .constant(nil), pushedMessageId: .constant(nil))
    }.environment(NavigationStore()).environment(\.hasTabMailSession, hasSession)
}

@MainActor @Observable
private final class FeedbackSceneState {
    var phase = ScenePhase.inactive
}

private struct FeedbackForegroundInbox: View {
    let state: FeedbackSceneState
    var body: some View { feedbackInbox().environment(\.scenePhase, state.phase) }
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

    private var activeView: UIView {
        var active = controller
        while let presented = active.presentedViewController { active = presented }
        return active.view
    }

    func waitForSheetDismissal() async throws {
        for _ in 0..<100 {
            if controller.presentedViewController == nil { return }
            try await Task.sleep(for: .milliseconds(50))
        }
        Issue.record("The feedback sheet did not finish dismissal")
    }

    private func find(_ identifier: String, labelContains: String? = nil) async throws -> NSObject? {
        var scrolls: [UIScrollView] = []
        var views: [UIView] = [activeView]
        while let view = views.popLast() {
            views.append(contentsOf: view.subviews)
            if let scroll = view as? UIScrollView, scroll.contentSize.height > scroll.bounds.height {
                scrolls.append(scroll)
            }
        }
        for step in 0..<24 {
            activeView.layoutIfNeeded()
            if let element = feedbackAccessibilityElement(in: activeView, identifier: identifier, labelContains: labelContains) {
                return element
            }
            for scroll in scrolls {
                let maximum = max(-scroll.adjustedContentInset.top,
                    scroll.contentSize.height - scroll.bounds.height + scroll.adjustedContentInset.bottom)
                let offset = min(maximum, -scroll.adjustedContentInset.top + CGFloat(step) * scroll.bounds.height / 2)
                scroll.setContentOffset(CGPoint(x: 0, y: offset), animated: false)
            }
            try await Task.sleep(for: .milliseconds(100))
        }
        return nil
    }

    func activate(_ identifier: String, expectedLabel: String? = nil) async throws {
        let element = try #require(try await find(identifier), Comment(rawValue: "Rendered feedback control missing: " + identifier))
        if let expectedLabel {
            #expect(element.accessibilityLabel?.contains(expectedLabel) == true,
                Comment(rawValue: "Visible feedback choice: " + (element.accessibilityLabel ?? "missing label")))
        }
        _ = element.accessibilityActivate()
    }

    func containsText(_ text: String) async throws -> Bool {
        try await find("", labelContains: text) != nil
    }

    func text(topOnly: Bool = false) async throws -> String {
        // A short settling interval is followed by one local OCR pass. No
        // customer screenshot or UI contents leave the test process.
        try await Task.sleep(for: .milliseconds(350))
        let view = activeView
        view.layoutIfNeeded()
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        let rendered = UIGraphicsImageRenderer(bounds: view.bounds, format: format).image { _ in
            view.drawHierarchy(in: view.bounds, afterScreenUpdates: true)
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
            .joined(separator: " ").split(whereSeparator: \.isWhitespace).joined(separator: " ").lowercased().replacingOccurrences(of: "’", with: "'")
    }
}

@Suite("Feedback surfaces", .serialized, .processGlobalState)
@MainActor
struct TrialFeedbackViewTests {
    @Test(arguments: [false, true])
    func expiredInboxAutomaticallyOffersTheFormOnForegroundWithoutSendingAndDoesNotRepeat(knownBeforeMount: Bool) async throws {
        PreviewMocks.hideAllTips()
        let scope = FeedbackInboxScope(automaticWasShown: false)
        defer { scope.close() }
        let transport = try FeedbackSessionScope()
        defer { transport.close() }
        let automation = try FeedbackAccessibilityAutomation()
        defer { automation.close() }
        FeedbackPacketProtocol.state.withLock { $0 = .init(mode: .status(204)) }
        let state = FeedbackSceneState()
        let expired = try WhoamiFixture.expiredSignupTrial(endedDaysAgo: 1, reference: Date())
        if knownBeforeMount { AISubscriptionGate.shared.apply(expired) }
        let host = try TrialFeedbackHost(FeedbackForegroundInbox(state: state))
        defer { host.close() }
        if !knownBeforeMount { AISubscriptionGate.shared.apply(expired) }
        #expect(!(try await host.text()).contains("your trial has ended"))
        #expect(!scope.promptScope.prompt.automaticPresentationShown)
        state.phase = .active
        let opened = try await host.text()
        try #require(opened.contains("your trial has ended") && opened.contains("main reason"))
        #expect(scope.promptScope.prompt.automaticPresentationShown)
        #expect(FeedbackPacketProtocol.state.withLock { $0.packets.isEmpty })
        try await host.activate("trial-feedback-not-now")
        try await host.waitForSheetDismissal()
        #expect(scope.promptScope.prompt.deferredThisRun)
        // The stored once-only choice must hold independently of the run deferral.
        scope.promptScope.prompt.restoreTestSnapshot(suppressed: false, deferred: false, automaticShown: true)
        state.phase = .inactive
        _ = try await host.text(topOnly: true)
        state.phase = .active
        #expect(!(try await host.text()).contains("your trial has ended"))
        #expect(FeedbackPacketProtocol.state.withLock { $0.packets.isEmpty })
    }

    @Test(arguments: ["unknown", "demo", "no-session", "other-folder", "paid", "running", "inactive-no-trial", "local-purchase", "suppressed", "deferred"])
    func automaticInvitationDoesNotConsumeItsOnceOnlyChoiceOutsideEligibility(scenario: String) async throws {
        PreviewMocks.hideAllTips()
        let scope = FeedbackInboxScope(automaticWasShown: false)
        defer { scope.close() }
        let gate = AISubscriptionGate.shared
        switch scenario {
        case "unknown": break
        case "paid": gate.apply(try WhoamiFixture.accountInfo(hasSubscription: true))
        case "running": gate.apply(try WhoamiFixture.runningSignupTrial(daysLeft: 3, reference: Date()))
        case "inactive-no-trial": gate.apply(try WhoamiFixture.signedInWithoutSubscription())
        default: gate.apply(try WhoamiFixture.expiredSignupTrial(endedDaysAgo: 1, reference: Date()))
        }
        if scenario == "demo" { DemoModeStore.shared.isActive = true }
        if scenario == "local-purchase" { gate.openGate() }
        if scenario == "suppressed" { scope.promptScope.prompt.doNotAskAgain() }
        if scenario == "deferred" { scope.promptScope.prompt.notNow() }
        let host = try TrialFeedbackHost(feedbackInbox(hasSession: scenario != "no-session", otherFolder: scenario == "other-folder")
            .environment(\.scenePhase, .active))
        defer { host.close() }
        #expect(!(try await host.text()).contains("your trial has ended"))
        #expect(!scope.promptScope.prompt.automaticPresentationShown)
    }

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
        #expect(text.contains("your trial has ended"))
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
    func theRenderedButtonsSendExactlyTheChosenReasonOnce() async throws {
        let name = "TrialFeedbackActions.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: name))
        defer { defaults.removePersistentDomain(forName: name) }
        let prompt = TrialFeedbackPromptState(defaults: defaults)
        let client = FeedbackSubmitter()
        let flow = TrialFeedbackFlow(prompt: prompt, client: client)
        let automation = try FeedbackAccessibilityAutomation()
        defer { automation.close() }
        let host = try TrialFeedbackHost(TrialFeedbackForm(flow: flow))
        defer { host.close() }
        try await Task.sleep(for: .milliseconds(350))
        #expect(flow.selectedReason == nil && !flow.canSubmit)
        #expect(await client.reasons.isEmpty)
        try await host.activate("trial-feedback-reason-price_value")
        #expect(flow.selectedReason == .priceValue)
        #expect(await client.reasons.isEmpty)
        try await host.activate("trial-feedback-submit")
        for _ in 0..<100 {
            if flow.isComplete { break }
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(flow.isComplete && prompt.isSuppressed)
        #expect(await client.reasons == [.priceValue])
        #expect((try await host.text()).contains("thanks for your feedback"))
    }

    @Test(arguments: [false, true])
    func renderedDismissalButtonsSendNothingAndRespectTheLocalChoice(permanent: Bool) async throws {
        let name = "TrialFeedbackDismissal.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: name))
        defer { defaults.removePersistentDomain(forName: name) }
        let prompt = TrialFeedbackPromptState(defaults: defaults)
        let client = FeedbackSubmitter()
        let flow = TrialFeedbackFlow(prompt: prompt, client: client)
        let automation = try FeedbackAccessibilityAutomation()
        defer { automation.close() }
        let host = try TrialFeedbackHost(TrialFeedbackForm(flow: flow))
        defer { host.close() }
        try await Task.sleep(for: .milliseconds(350))
        try await host.activate("trial-feedback-reason-existing_workflow")
        #expect(flow.selectedReason == .existingWorkflow)
        try await host.activate(permanent ? "trial-feedback-decline" : "trial-feedback-not-now")
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
        let automation = try FeedbackAccessibilityAutomation()
        defer { automation.close() }
        let host = try TrialFeedbackHost(TrialFeedbackForm(flow: flow))
        defer { host.close() }
        try await Task.sleep(for: .milliseconds(350))
        try await host.activate("trial-feedback-reason-ai_reliability")
        #expect(flow.selectedReason == .aiReliability)
        try await host.activate("trial-feedback-submit")
        for _ in 0..<100 {
            if await client.reasons.count == 1 { break }
            try await Task.sleep(for: .milliseconds(10))
        }
        let enteredReasons = await client.reasons
        try #require(flow.isSubmitting && enteredReasons.count == 1)
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

    @Test(arguments: ["ended", "demo", "no-session", "other-folder", "paid", "running", "inactive-no-trial", "local-purchase", "suppressed", "deferred"])
    func theActualInboxRequiresEachEligibilityCondition(scenario: String) async throws {
        PreviewMocks.hideAllTips()
        let scope = FeedbackInboxScope()
        defer { scope.close() }
        let gate = AISubscriptionGate.shared
        DemoModeStore.shared.isActive = scenario == "demo"
        let host = try TrialFeedbackHost(feedbackInbox(hasSession: scenario != "no-session", otherFolder: scenario == "other-folder"))
        defer { host.close() }
        let before = try await host.text(topOnly: true)
        #expect(before.contains("mailbox") && !before.contains("help improve tabmail"))
        if scenario == "running" {
            gate.apply(try WhoamiFixture.runningSignupTrial(daysLeft: 3, reference: Date()))
        } else if scenario == "paid" {
            gate.apply(try WhoamiFixture.accountInfo(hasSubscription: true))
        } else if scenario == "inactive-no-trial" {
            gate.apply(try WhoamiFixture.signedInWithoutSubscription())
            try #require(!gate.trialHasEnded && !gate.isActive && gate.lastAuthoritativeApplyAt != nil)
        } else {
            gate.apply(try WhoamiFixture.expiredSignupTrial(endedDaysAgo: 1, reference: Date()))
        }
        if ["local-purchase", "suppressed", "deferred"].contains(scenario) {
            try #require((try await host.text(topOnly: true)).contains("help improve tabmail"))
            switch scenario {
            case "local-purchase":
                gate.openGate()
                try #require(gate.isActive && gate.trialHasEnded)
            case "suppressed": scope.promptScope.prompt.doNotAskAgain()
            default: scope.promptScope.prompt.notNow()
            }
        }
        let ended = try await host.text(topOnly: true)
        #expect(ended.contains("mailbox"))
        #expect(ended.contains("help improve tabmail") == (scenario == "ended"), Comment(rawValue: "Synthetic inbox [" + scenario + "]: " + ended))
        gate.noteSignedOut()
        let after = try await host.text(topOnly: true)
        #expect(after.contains("mailbox") && !after.contains("help improve tabmail"))
    }

    @Test(.timeLimit(.minutes(1)))
    func theActualInboxUsesTheDefaultClientAndVisibleReasonsOnlyAfterSubmit() async throws {
        PreviewMocks.hideAllTips()
        let scope = FeedbackInboxScope()
        defer { scope.close() }
        let transport = try FeedbackSessionScope()
        defer { transport.close() }
        let automation = try FeedbackAccessibilityAutomation()
        defer { automation.close() }
        FeedbackPacketProtocol.state.withLock { $0 = .init(mode: .status(503)) }
        AISubscriptionGate.shared.apply(try WhoamiFixture.expiredSignupTrial(endedDaysAgo: 1, reference: Date()))
        let host = try TrialFeedbackHost(feedbackInbox())
        defer { host.close() }
        var failure: (any Error)?
        do {
        try #require((try await host.text(topOnly: true)).contains("help improve tabmail"))
        #expect(FeedbackPacketProtocol.state.withLock { $0.packets.isEmpty })
        try await host.activate("inbox-trial-feedback")
        try #require((try await host.text()).contains("main reason"))
        #expect(FeedbackPacketProtocol.state.withLock { $0.packets.isEmpty })
        let choices = [
            ("price_value", "The price is higher than the value I get."),
            ("not_enough_use", "I haven't used it enough to decide."),
            ("missing_feature", "It's missing something I need."),
            ("ai_reliability", "The AI results aren't reliable enough for me."),
            ("existing_workflow", "I prefer my existing email workflow."),
            ("other_or_prefer_not_to_say", "Another reason / prefer not to say.")
        ]
        for (index, choice) in choices.enumerated() {
            try await host.activate("trial-feedback-reason-" + choice.0, expectedLabel: choice.1)
            let preceding = index == 0 ? 0 : index + 1
            #expect(FeedbackPacketProtocol.state.withLock { $0.packets.count } == preceding)
            FeedbackPacketProtocol.state.withLock { $0.mode = .status(index == choices.count - 1 ? 204 : 503) }
            try await host.activate("trial-feedback-submit")
            for _ in 0..<200 {
                if FeedbackPacketProtocol.state.withLock({ $0.packets.count > preceding }) { break }
                try await Task.sleep(for: .milliseconds(10))
            }
            let packets = FeedbackPacketProtocol.state.withLock { $0.packets }
            try #require(packets.count == preceding + 1)
            let body = try #require(JSONSerialization.jsonObject(with: packets[preceding].body) as? [String: String])
            #expect(body == ["questionnaire_version": "trial-v1", "reason": choice.0])
            #expect(packets[preceding].url == TrialFeedbackConfig.endpoint)
            if index != choices.count - 1 {
                #expect(try await host.containsText("couldn't confirm delivery"))
                #expect(!scope.promptScope.prompt.isSuppressed)
                if index == 0 {
                    // Retry the retained choice without selecting again.
                    try await host.activate("trial-feedback-submit")
                    for _ in 0..<200 {
                        if FeedbackPacketProtocol.state.withLock({ $0.packets.count == 2 }) { break }
                        try await Task.sleep(for: .milliseconds(10))
                    }
                    let retryPackets = FeedbackPacketProtocol.state.withLock { $0.packets }
                    try #require(retryPackets.count == 2)
                    let retryBody = try #require(JSONSerialization.jsonObject(with: retryPackets[1].body) as? [String: String])
                    #expect(retryBody == ["questionnaire_version": "trial-v1", "reason": choice.0])
                    #expect(try await host.containsText("couldn't confirm delivery"))
                }
            }
        }
        for _ in 0..<200 {
            if scope.promptScope.prompt.isSuppressed { break }
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(scope.promptScope.prompt.isSuppressed)
        try await host.waitForSheetDismissal()
        #expect(!(try await host.text(topOnly: true)).contains("help improve tabmail"))
        #expect(transport.createdCount == choices.count + 1)
        #expect(FeedbackPacketProtocol.state.withLock { $0.packets.count } == choices.count + 1)
        } catch { failure = error }
        AISubscriptionGate.shared.noteSignedOut()
        try await host.waitForSheetDismissal()
        if let failure { throw failure }
    }

    @Test(.timeLimit(.minutes(1)))
    func cancelledThrowingSubmissionDoesNotPublishAnErrorOrPersistSuppression() async throws {
        let name = "TrialFeedbackThrowingCancellation.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: name))
        defer { defaults.removePersistentDomain(forName: name) }
        let prompt = TrialFeedbackPromptState(defaults: defaults)
        let client = FeedbackSubmitter(held: true)
        let flow = TrialFeedbackFlow(prompt: prompt, client: client)
        flow.selectedReason = .other
        let task = Task { await flow.submit() }
        for _ in 0..<100 {
            if await client.reasons.count == 1 { break }
            try await Task.sleep(for: .milliseconds(10))
        }
        try #require(await client.reasons.count == 1)
        task.cancel()
        await client.release(failing: true)
        await task.value
        #expect(!flow.isSubmitting && !flow.isComplete && !prompt.isSuppressed)
        #expect(flow.errorText == nil)
        #expect(await client.reasons == [.other])
        #expect(defaults.persistentDomain(forName: name) == nil || defaults.persistentDomain(forName: name)?.isEmpty == true)
    }
}
