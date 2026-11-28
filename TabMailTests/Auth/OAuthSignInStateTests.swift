/* This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at https://mozilla.org/MPL/2.0/. */

import CryptoKit
import Foundation
import Security
import Testing
@testable import TabMail

/// A sign-in reply is accepted only when it carries back, once and exactly, the
/// `state` this sign-in sent (RFC 6749 section 4.1.2). Any other reply is not
/// the answer to this sign-in, so it is refused before its code reaches a token
/// endpoint.
@Suite("OAuth sign-in state")
struct OAuthSignInStateTests {

    /// The on-device sign-in calls: adding or re-authenticating a mail account,
    /// the identity-only first step, and the step after it that names the
    /// account it found, for each provider.
    enum Flow: String, CaseIterable, CustomTestStringConvertible, Sendable {
        case google, googleIdentityOnly, googleHinted, microsoft, microsoftIdentityOnly, microsoftHinted
        var testDescription: String { rawValue }

        static let hint = "user@example.com"

        var isGoogle: Bool { self == .google || self == .googleIdentityOnly || self == .googleHinted }
        var isHinted: Bool { self == .googleHinted || self == .microsoftHinted }

        var page: String {
            isGoogle
                ? "https://accounts.google.com/o/oauth2/v2/auth"
                : "https://login.microsoftonline.com/common/oauth2/v2.0/authorize"
        }

        var tokenEndpoint: String {
            isGoogle
                ? "https://oauth2.googleapis.com/token"
                : "https://login.microsoftonline.com/common/oauth2/v2.0/token"
        }

        var callbackScheme: String {
            isGoogle ? OAuthConfig.googleRedirectScheme : OAuthConfig.microsoftRedirectScheme
        }

        /// The registered address the provider sends the user back to.
        var callback: String {
            isGoogle ? "\(callbackScheme):/oauthredirect" : "\(callbackScheme)://auth"
        }

        @MainActor
        func signIn(_ service: OAuthService) async throws -> OAuthTokens {
            switch self {
            case .google: return try await service.authenticateGoogle()
            case .googleIdentityOnly: return try await service.authenticateGoogleIdentityOnly()
            case .googleHinted: return try await service.authenticateGoogle(loginHint: Self.hint)
            case .microsoft: return try await service.authenticateMicrosoft()
            case .microsoftIdentityOnly: return try await service.authenticateMicrosoftIdentityOnly()
            case .microsoftHinted: return try await service.authenticateMicrosoft(loginHint: Self.hint)
            }
        }
    }

    /// Replies that are not the answer to this sign-in, by the `state` items
    /// they carry (nil: a `state` item with no value).
    enum ForeignReply: String, CaseIterable, CustomTestStringConvertible {
        case noState, otherState, emptyState, valuelessState, caseChangedState,
             sentTwice, sentThenOther, otherThenSent, sentThenValueless, valuelessThenSent
        var testDescription: String { rawValue }

        static let other = String(repeating: "A", count: 43)

        func states(sent: String) -> [String?] {
            switch self {
            case .noState: []
            case .otherState: [Self.other]
            case .emptyState: [""]
            case .valuelessState: [nil]
            case .caseChangedState: [String(sent.flatMap { $0.isUppercase ? $0.lowercased() : $0.uppercased() })]
            case .sentTwice: [sent, sent]
            case .sentThenOther: [sent, Self.other]
            case .otherThenSent: [Self.other, sent]
            case .sentThenValueless: [sent, nil]
            case .valuelessThenSent: [nil, sent]
            }
        }
    }

    /// Stands in for the system sign-in sheet: records every page it is shown
    /// and answers each with the reply the test builds from that page's state.
    @MainActor
    final class FakeBrowser {
        private(set) var pages: [URL] = []
        private(set) var schemes: [String] = []
        var answer: (_ sentState: String) -> URL

        init(answer: @escaping (_ sentState: String) -> URL) {
            self.answer = answer
        }

        var open: OAuthService.SignInBrowser {
            { [self] page, scheme in
                pages.append(page)
                schemes.append(scheme)
                let sent = OAuthSignInStateTests.states(in: page).compactMap { $0 }.first ?? ""
                return answer(sent)
            }
        }
    }

    /// Stands in for the system's random generator: call N fills its buffer
    /// with `patterns[N - 1]` repeated (the last pattern once they run out),
    /// and call `failingCall` reports a failure.
    @MainActor
    final class FakeRandom {
        private(set) var calls = 0
        let failingCall: Int?
        let patterns: [[UInt8]]

        init(failingCall: Int? = nil, patterns: [[UInt8]] = [[0xFB, 0xFF, 0xBF]]) {
            self.failingCall = failingCall
            self.patterns = patterns
        }

        var fill: OAuthService.RandomFill {
            { [self] count, bytes in
                calls += 1
                if calls == failingCall { return errSecAllocate }
                let pattern = patterns[min(calls, patterns.count) - 1]
                let buffer = bytes.assumingMemoryBound(to: UInt8.self)
                for index in 0..<count { buffer[index] = pattern[index % pattern.count] }
                return errSecSuccess
            }
        }
    }

    private static let base64url = Set("ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-_")

    /// The values of every query item called `name` in `url`.
    static func items(in url: URL, named name: String) -> [String?] {
        (URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? [])
            .filter { $0.name == name }
            .map(\.value)
    }

    static func states(in url: URL) -> [String?] {
        items(in: url, named: "state")
    }

    static func reply(to flow: Flow, code: String?, states: [String?], error: String? = nil) -> URL {
        var components = URLComponents(string: flow.callback)!
        var items: [URLQueryItem] = []
        if let code { items.append(URLQueryItem(name: "code", value: code)) }
        if let error { items.append(URLQueryItem(name: "error", value: error)) }
        items += states.map { URLQueryItem(name: "state", value: $0) }
        components.queryItems = items
        return components.url!
    }

    /// A token endpoint that answers every exchange with fixed tokens.
    static func tokenEndpoint() -> FakeHTTP.Scenario {
        let http = FakeHTTP.Scenario()
        http.register(path: "token", method: "POST",
                      response: .json(raw: #"{"access_token":"access","refresh_token":"refresh","expires_in":3600}"#))
        return http
    }

    @MainActor
    private static func service(_ browser: FakeBrowser) -> (OAuthService, FakeHTTP.Scenario) {
        let http = tokenEndpoint()
        return (OAuthService(tokenSession: http.session, signInBrowser: browser.open), http)
    }

    @MainActor
    private static func failure(of flow: Flow, _ service: OAuthService) async -> (any Error)? {
        do {
            _ = try await flow.signIn(service)
            return nil
        } catch {
            return error
        }
    }

    private static func parseFailure(_ reply: URL, state: String) -> (any Error)? {
        do {
            _ = try OAuthService.authorizationCode(from: reply, state: state)
            return nil
        } catch {
            return error
        }
    }

    private static func isStateMismatch(_ error: (any Error)?) -> Bool {
        guard let error = error as? OAuthError, case .stateMismatch = error else { return false }
        return true
    }

    private static func isNoAuthCode(_ error: (any Error)?) -> Bool {
        guard let error = error as? OAuthError, case .noAuthCode = error else { return false }
        return true
    }

    private static func isNoSecureRandomBytes(_ error: (any Error)?) -> Bool {
        guard let error = error as? OAuthError, case .noSecureRandomBytes = error else { return false }
        return true
    }

    /// The form fields of every token request, in order.
    private static func tokenRequests(_ http: FakeHTTP.Scenario) -> [[String: [String]]] {
        http.recordedCalls().map { call in
            FormDecoding.fields(call.body.flatMap { String(data: $0, encoding: .utf8) } ?? "")
        }
    }

    private static func codes(_ http: FakeHTTP.Scenario) -> [[String]?] {
        tokenRequests(http).map { $0["code"] }
    }

    /// The PKCE S256 challenge for `verifier` (RFC 7636 section 4.2), computed
    /// here rather than by the code under test.
    private static func s256(_ verifier: String) -> String {
        Data(SHA256.hash(data: Data(verifier.utf8))).base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }

    @Test("A reply carrying this sign-in's state is accepted and its code exchanged", arguments: Flow.allCases)
    @MainActor
    func echoedStateIsAccepted(flow: Flow) async throws {
        let browser = FakeBrowser { sent in Self.reply(to: flow, code: "code-1", states: [sent]) }
        let (service, http) = Self.service(browser)
        defer { http.close() }

        let tokens = try await flow.signIn(service)

        let pages = browser.pages
        let schemes = browser.schemes
        let urls = http.recordedCalls().map { $0.url }
        let codes = Self.codes(http)
        let requests = Self.tokenRequests(http)
        #expect(tokens.accessToken == "access")
        #expect(schemes == [flow.callbackScheme])
        #expect(pages.count == 1)
        #expect(requests.count == 1)
        guard pages.count == 1, requests.count == 1 else { return }
        let isProviderPage = pages[0].absoluteString.hasPrefix(flow.page + "?")
        #expect(isProviderPage, "the page is the provider's sign-in page")
        let hints = Self.items(in: pages[0], named: "login_hint")
        let expectedHints: [String?] = flow.isHinted ? [Flow.hint] : []
        #expect(hints == expectedHints)
        let sent = Self.states(in: pages[0])
        #expect(sent.count == 1, "the page carries one state")
        guard sent.count == 1, let state = sent[0] else { return }
        let stateLength = state.count
        let isBase64url = state.allSatisfy { Self.base64url.contains($0) }
        #expect(stateLength == 43, "256 bits, base64url without padding")
        #expect(isBase64url, "the state is base64url")
        #expect(urls == [flow.tokenEndpoint])
        #expect(codes == [["code-1"]])
        // The exchange proves the verifier behind the page's challenge, and
        // the state stays out of it.
        let verifiers = requests[0]["code_verifier"] ?? []
        #expect(verifiers.count == 1)
        guard verifiers.count == 1 else { return }
        let challenges = Self.items(in: pages[0], named: "code_challenge")
        let expectedChallenge = Self.s256(verifiers[0])
        #expect(challenges == [expectedChallenge])
        let methods = Self.items(in: pages[0], named: "code_challenge_method")
        #expect(methods == ["S256"])
        let sendsState = requests[0]["state"] != nil
        #expect(!sendsState, "the state stays out of the token request")
        if !flow.isGoogle {
            let askedScope = Self.items(in: pages[0], named: "scope").compactMap { $0 }
            let exchangedScope = requests[0]["scope"] ?? []
            #expect(askedScope.count == 1)
            #expect(exchangedScope == askedScope, "the exchange asks for the scope the page asked for")
        }
    }

    @Test("A reply without this sign-in's state, once and exactly, is refused before any token request",
          arguments: Flow.allCases, ForeignReply.allCases)
    @MainActor
    func foreignReplyIsRefused(flow: Flow, reply: ForeignReply) async {
        let browser = FakeBrowser { sent in
            Self.reply(to: flow, code: "code-1", states: reply.states(sent: sent))
        }
        let (service, http) = Self.service(browser)
        defer { http.close() }

        let thrown = await Self.failure(of: flow, service)

        let refused = Self.isStateMismatch(thrown)
        let pageCount = browser.pages.count
        let urls = http.recordedCalls().map { $0.url }
        #expect(refused, "thrown: \(String(describing: thrown))")
        #expect(pageCount == 1)
        #expect(urls.isEmpty, "no code reached a token endpoint: \(urls)")
    }

    @Test("A reply with this sign-in's state but no code is refused before any token request",
          arguments: Flow.allCases)
    @MainActor
    func replyWithoutCodeIsRefused(flow: Flow) async {
        let browser = FakeBrowser { sent in Self.reply(to: flow, code: nil, states: [sent]) }
        let (service, http) = Self.service(browser)
        defer { http.close() }

        let thrown = await Self.failure(of: flow, service)

        let refused = Self.isNoAuthCode(thrown)
        let urls = http.recordedCalls().map { $0.url }
        #expect(refused, "thrown: \(String(describing: thrown))")
        #expect(urls.isEmpty, "\(urls)")
    }

    @Test("An error reply is judged by its state first, then by its missing code", arguments: Flow.allCases)
    @MainActor
    func errorReplyIsCheckedForStateFirst(flow: Flow) async {
        var echoes = false
        let browser = FakeBrowser { sent in
            Self.reply(to: flow, code: nil, states: [echoes ? sent : ForeignReply.other], error: "access_denied")
        }
        let (service, http) = Self.service(browser)
        defer { http.close() }

        let foreign = await Self.failure(of: flow, service)
        echoes = true
        let own = await Self.failure(of: flow, service)

        let foreignRefused = Self.isStateMismatch(foreign)
        let ownHasNoCode = Self.isNoAuthCode(own)
        let urls = http.recordedCalls().map { $0.url }
        #expect(foreignRefused, "thrown: \(String(describing: foreign))")
        #expect(ownHasNoCode, "thrown: \(String(describing: own))")
        #expect(urls.isEmpty, "\(urls)")
    }

    @Test("The state is compared byte for byte: a canonically equivalent spelling is refused")
    @MainActor
    func canonicallyEquivalentStateIsRefused() {
        let sent = "K" + String(repeating: "a", count: 42)
        // U+212A KELVIN SIGN decomposes canonically to "K".
        let equivalent = "\u{212A}" + String(repeating: "a", count: 42)
        let swiftCallsThemEqual = equivalent == sent
        #expect(swiftCallsThemEqual, "the fixture is canonically equivalent")

        let foreign = Self.parseFailure(Self.reply(to: .google, code: "code-1", states: [equivalent]), state: sent)
        let accepted = try? OAuthService.authorizationCode(from: Self.reply(to: .google, code: "code-1", states: [sent]), state: sent)

        let refused = Self.isStateMismatch(foreign)
        #expect(refused, "thrown: \(String(describing: foreign))")
        #expect(accepted == "code-1")
    }

    @Test("Every sign-in sends a fresh state, and a reply to an earlier sign-in is refused",
          arguments: Flow.allCases)
    @MainActor
    func earlierSignInsReplyIsRefused(flow: Flow) async throws {
        let browser = FakeBrowser { sent in Self.reply(to: flow, code: "code-1", states: [sent]) }
        let (service, http) = Self.service(browser)
        defer { http.close() }

        _ = try await flow.signIn(service)
        _ = try await flow.signIn(service)
        let sent = browser.pages.flatMap { Self.states(in: $0) }
        #expect(sent.count == 2, "two pages, one state each")
        guard sent.count == 2, let first = sent[0], let second = sent[1] else { return }
        let distinct = first != second
        #expect(distinct, "each sign-in sends its own state")

        browser.answer = { _ in Self.reply(to: flow, code: "code-2", states: [first]) }
        let thrown = await Self.failure(of: flow, service)

        let refused = Self.isStateMismatch(thrown)
        let pageCount = browser.pages.count
        let codes = Self.codes(http)
        #expect(refused, "thrown: \(String(describing: thrown))")
        #expect(pageCount == 3)
        #expect(codes == [["code-1"], ["code-1"]], "only the two answered sign-ins reached a token endpoint")
    }

    /// Thirty-two bytes of FB FF BF, repeated: plain base64 spells each group
    /// "+/+/", so base64url must give "-_-_" (RFC 4648 section 5), with no
    /// padding after the last two bytes.
    static let patternBase64url = String(repeating: "-_", count: 21) + "8"
    /// The S256 challenge for `patternBase64url`.
    static let patternChallenge = "Weq42wa3m9dnJOzDW6BT5iNBH5jAzz3PTVsU5_AYaqY"
    /// Thirty-two bytes of 00 10 83, repeated: each group spells "ABCD", and
    /// the last two bytes "ABA".
    static let secondPattern: [UInt8] = [0x00, 0x10, 0x83]
    static let secondPatternBase64url = String(repeating: "ABCD", count: 10) + "ABA"

    @Test("The verifier and the state are separate draws of the generator, in base64url", arguments: Flow.allCases)
    @MainActor
    func randomBytesReachThePageAsBase64url(flow: Flow) async throws {
        let browser = FakeBrowser { sent in Self.reply(to: flow, code: "code-1", states: [sent]) }
        let random = FakeRandom(patterns: [[0xFB, 0xFF, 0xBF], Self.secondPattern])
        let http = Self.tokenEndpoint()
        defer { http.close() }
        let service = OAuthService(tokenSession: http.session, signInBrowser: browser.open, randomFill: random.fill)

        _ = try await flow.signIn(service)

        let pages = browser.pages
        let requests = Self.tokenRequests(http)
        let calls = random.calls
        #expect(calls == 2, "one verifier and one state")
        #expect(pages.count == 1)
        #expect(requests.count == 1)
        guard pages.count == 1, requests.count == 1 else { return }
        let states = Self.states(in: pages[0])
        let challenges = Self.items(in: pages[0], named: "code_challenge")
        let verifiers = requests[0]["code_verifier"]
        let pageShowsVerifier = pages[0].absoluteString.contains(Self.patternBase64url)
        // The first draw is the verifier, the second the state.
        #expect(verifiers == [Self.patternBase64url])
        #expect(challenges == [Self.patternChallenge])
        #expect(states == [Self.secondPatternBase64url])
        #expect(!pageShowsVerifier, "the page carries the challenge, never the verifier")
    }

    @Test("An accepted reply's code and state are read percent-decoded", arguments: Flow.allCases)
    @MainActor
    func percentEncodedReplyIsDecoded(flow: Flow) async throws {
        // Every byte of the state percent-encoded, and the code's "/" too, as a
        // provider may send them.
        let browser = FakeBrowser { sent in
            let state = sent.utf8.map { String(format: "%%%02X", $0) }.joined()
            return URL(string: "\(flow.callback)?code=4%2F0Ab-x_y&state=\(state)")!
        }
        let (service, http) = Self.service(browser)
        defer { http.close() }

        let tokens = try await flow.signIn(service)

        let codes = Self.codes(http)
        #expect(tokens.accessToken == "access")
        #expect(codes == [["4/0Ab-x_y"]], "the decoded code is exchanged")
    }

    @Test("A failing random generator stops the sign-in before any page opens",
          arguments: Flow.allCases, [1, 2])
    @MainActor
    func failingRandomStopsTheSignIn(flow: Flow, failingCall: Int) async {
        let browser = FakeBrowser { sent in Self.reply(to: flow, code: "code-1", states: [sent]) }
        let random = FakeRandom(failingCall: failingCall)
        let http = Self.tokenEndpoint()
        defer { http.close() }
        let service = OAuthService(tokenSession: http.session, signInBrowser: browser.open, randomFill: random.fill)

        let thrown = await Self.failure(of: flow, service)

        let stopped = Self.isNoSecureRandomBytes(thrown)
        let pageCount = browser.pages.count
        let urls = http.recordedCalls().map { $0.url }
        let calls = random.calls
        #expect(stopped, "thrown: \(String(describing: thrown))")
        #expect(calls == failingCall, "nothing more is drawn after the failure")
        #expect(pageCount == 0)
        #expect(urls.isEmpty, "\(urls)")
    }

    @Test("A refused reply and a failed generator show the sign-in error, never a silent retry")
    @MainActor
    func refusalIsShownToTheUser() {
        for error in [OAuthError.stateMismatch, .noSecureRandomBytes] {
            let outcome = ConnectErrorClassifier.classify(error)
            let shown: Bool
            if case .showError = outcome { shown = true } else { shown = false }
            let line = AccountReauthAlert.oauthLine(for: error)
            #expect(shown, "\(error)")
            #expect(line == AccountReauthAlert.oauthLine, "\(error)")
        }
    }
}

/// What the debug log holds after a sign-in. Every case points the app log at
/// a temp file and turns debug logging on: process-global seams, hence
/// `.serialized, .processGlobalState` (see `BackgroundSyncLoggerTests`).
@Suite("OAuth sign-in debug log", .serialized, .processGlobalState)
struct OAuthSignInLogTests {

    private static let marker = "Qz7k"

    @MainActor
    private func withDebugLog<T>(_ body: @MainActor () async throws -> T) async rethrows -> T {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("signinlog_\(UUID().uuidString).log")
        AppLogStore.fileURLOverride.withLock { $0 = url }
        DebugModeManager.loggingEnabledOverrideForTesting.withLock { $0 = true }
        defer {
            DebugModeManager.loggingEnabledOverrideForTesting.withLock { $0 = nil }
            AppLogStore._resetForTesting()
            try? FileManager.default.removeItem(at: url)
        }
        return try await body()
    }

    private static func prefix(_ flow: OAuthSignInStateTests.Flow) -> String {
        flow.isGoogle ? "[OAuth]" : "[OAuth] Microsoft"
    }

    @Test("A sign-in's success reply is logged by which items it holds, never their values",
          arguments: [OAuthSignInStateTests.Flow.google, .microsoft])
    @MainActor
    func successReplyIsLoggedByItemNames(flow: OAuthSignInStateTests.Flow) async throws {
        let browser = OAuthSignInStateTests.FakeBrowser { sent in
            OAuthSignInStateTests.reply(to: flow, code: Self.marker + "-code", states: [sent])
        }
        let http = OAuthSignInStateTests.tokenEndpoint()
        defer { http.close() }
        let service = OAuthService(tokenSession: http.session, signInBrowser: browser.open)

        let log = try await withDebugLog {
            _ = try await flow.signIn(service)
            return AppLogStore.read()
        }

        let sent = browser.pages.flatMap { OAuthSignInStateTests.states(in: $0) }.compactMap { $0 }
        #expect(sent.count == 1)
        guard sent.count == 1 else { return }
        let namesItems = log.contains("\(Self.prefix(flow)) callback received — code=true, state=true, error=false")
        let holdsMarker = log.contains(Self.marker)
        let holdsState = log.contains(sent[0])
        #expect(namesItems, "the reply's items are named")
        #expect(!holdsMarker, "no code value is logged")
        #expect(!holdsState, "the state is not logged")
    }

    @Test("A sign-in's error reply is logged by which items it holds, never their values, and exchanges nothing",
          arguments: [OAuthSignInStateTests.Flow.google, .microsoft])
    @MainActor
    func errorReplyIsLoggedByItemNames(flow: OAuthSignInStateTests.Flow) async {
        let browser = OAuthSignInStateTests.FakeBrowser { sent in
            OAuthSignInStateTests.reply(to: flow, code: nil, states: [sent], error: Self.marker + "-error")
        }
        let http = OAuthSignInStateTests.tokenEndpoint()
        defer { http.close() }
        let service = OAuthService(tokenSession: http.session, signInBrowser: browser.open)

        let (thrown, log) = await withDebugLog {
            var thrown: (any Error)?
            do { _ = try await flow.signIn(service) } catch { thrown = error }
            return (thrown, AppLogStore.read())
        }

        let sent = browser.pages.flatMap { OAuthSignInStateTests.states(in: $0) }.compactMap { $0 }
        let urls = http.recordedCalls().map { $0.url }
        var refused = false
        if let error = thrown as? OAuthError, case .noAuthCode = error { refused = true }
        #expect(refused, "thrown: \(String(describing: thrown))")
        #expect(urls.isEmpty, "\(urls)")
        #expect(sent.count == 1)
        guard sent.count == 1 else { return }
        let namesItems = log.contains("\(Self.prefix(flow)) callback received — code=false, state=true, error=true")
        let holdsMarker = log.contains(Self.marker)
        let holdsState = log.contains(sent[0])
        #expect(namesItems, "the reply's items are named")
        #expect(!holdsMarker, "no error value is logged")
        #expect(!holdsState, "the state is not logged")
    }

    @Test("A sign-in sheet that fails is logged by its error's domain and code, nothing more",
          arguments: [OAuthSignInStateTests.Flow.google, .microsoft])
    @MainActor
    func failedSheetIsLoggedByDomainAndCode(flow: OAuthSignInStateTests.Flow) async throws {
        let failure = NSError(domain: "TestSignInSheet", code: 7,
                              userInfo: [NSLocalizedDescriptionKey: Self.marker, "reply": Self.marker])
        let http = OAuthSignInStateTests.tokenEndpoint()
        defer { http.close() }
        let service = OAuthService(tokenSession: http.session, signInBrowser: { _, _ in throw failure })

        let (thrown, log) = await withDebugLog {
            var thrown: (any Error)?
            do { _ = try await flow.signIn(service) } catch { thrown = error }
            return (thrown, AppLogStore.read())
        }

        let rethrownError = thrown.map { $0 as NSError }
        let rethrown = rethrownError?.domain == "TestSignInSheet" && rethrownError?.code == 7
        let namesError = log.contains("\(Self.prefix(flow)) sign-in ended — domain=TestSignInSheet, code=7")
        let holdsMarker = log.contains(Self.marker)
        #expect(rethrown, "the sheet's error reaches the caller")
        #expect(namesError, "the error's domain and code are logged")
        #expect(!holdsMarker, "no error text is logged")
    }
}
