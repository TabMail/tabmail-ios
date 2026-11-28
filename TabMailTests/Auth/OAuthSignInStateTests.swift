/* This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at https://mozilla.org/MPL/2.0/. */

import Foundation
import Testing
@testable import TabMail

/// A sign-in reply is accepted only when it carries back, once and exactly, the
/// `state` this sign-in sent (RFC 6749 section 4.1.2). Any other reply did not
/// come from this sign-in, so it is refused before its code reaches a token
/// endpoint: the user is never signed in to an account they did not choose.
@Suite("OAuth sign-in state")
struct OAuthSignInStateTests {

    /// The four on-device sign-in calls: adding or re-authenticating a mail
    /// account, and the identity-only first step, for each provider.
    enum Flow: String, CaseIterable, CustomTestStringConvertible {
        case google, googleIdentityOnly, microsoft, microsoftIdentityOnly
        var testDescription: String { rawValue }

        var isGoogle: Bool { self == .google || self == .googleIdentityOnly }

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
            case .microsoft: return try await service.authenticateMicrosoft()
            case .microsoftIdentityOnly: return try await service.authenticateMicrosoftIdentityOnly()
            }
        }
    }

    /// Replies that are not the answer to this sign-in, by the `state` items
    /// they carry.
    enum ForeignReply: String, CaseIterable, CustomTestStringConvertible {
        case noState, otherState, emptyState, caseChangedState, sentTwice, sentThenOther, otherThenSent
        var testDescription: String { rawValue }

        static let other = String(repeating: "A", count: 43)

        func states(sent: String) -> [String] {
            switch self {
            case .noState: []
            case .otherState: [Self.other]
            case .emptyState: [""]
            case .caseChangedState: [String(sent.flatMap { $0.isUppercase ? $0.lowercased() : $0.uppercased() })]
            case .sentTwice: [sent, sent]
            case .sentThenOther: [sent, Self.other]
            case .otherThenSent: [Self.other, sent]
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

    private static let base64url = Set("ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-_")

    static func states(in url: URL) -> [String?] {
        (URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? [])
            .filter { $0.name == "state" }
            .map(\.value)
    }

    static func reply(to flow: Flow, code: String?, states: [String]) -> URL {
        var components = URLComponents(string: flow.callback)!
        var items: [URLQueryItem] = []
        if let code { items.append(URLQueryItem(name: "code", value: code)) }
        items += states.map { URLQueryItem(name: "state", value: $0) }
        components.queryItems = items
        return components.url!
    }

    @MainActor
    private static func service(_ browser: FakeBrowser) -> (OAuthService, FakeHTTP.Scenario) {
        let http = FakeHTTP.Scenario()
        http.register(path: "token", method: "POST",
                      response: .json(raw: #"{"access_token":"access","refresh_token":"refresh","expires_in":3600}"#))
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

    private static func isStateMismatch(_ error: (any Error)?) -> Bool {
        guard let error = error as? OAuthError, case .stateMismatch = error else { return false }
        return true
    }

    private static func isNoAuthCode(_ error: (any Error)?) -> Bool {
        guard let error = error as? OAuthError, case .noAuthCode = error else { return false }
        return true
    }

    private static func codes(_ http: FakeHTTP.Scenario) -> [[String]?] {
        http.recordedCalls().map { call in
            FormDecoding.fields(call.body.flatMap { String(data: $0, encoding: .utf8) } ?? "")["code"]
        }
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
        #expect(tokens.accessToken == "access")
        #expect(schemes == [flow.callbackScheme])
        #expect(pages.count == 1)
        guard pages.count == 1 else { return }
        let address = pages[0].absoluteString
        #expect(address.hasPrefix(flow.page + "?"), "\(address)")
        let sent = Self.states(in: pages[0])
        #expect(sent.count == 1, "the page carries one state: \(sent)")
        guard sent.count == 1, let state = sent[0] else { return }
        let isBase64url = state.allSatisfy { Self.base64url.contains($0) }
        #expect(state.count == 43, "256 bits, base64url without padding: \(state)")
        #expect(isBase64url, "\(state)")
        #expect(urls == [flow.tokenEndpoint])
        #expect(codes == [["code-1"]])
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
        #expect(sent.count == 2, "\(sent)")
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
}
