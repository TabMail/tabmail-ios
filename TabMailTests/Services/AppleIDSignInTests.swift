/* This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at https://mozilla.org/MPL/2.0/. */

import AuthenticationServices
import Foundation
import Synchronization
import SwiftUI
import Testing
@testable import TabMail

/// Sign in with Apple through Apple's own sheet: the request it sends, how its result and its errors are
/// read, and the token exchange with the auth server. Serialized: the route cases share the exchange's
/// test transport.
@Suite("Sign in with Apple", .serialized)
@MainActor
struct AppleIDSignInTests {

    private static let base64URL = Set("ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-_")

    @Test("A raw nonce is 43 base64url characters (32 random bytes) and new every time")
    func rawNonce() {
        let nonces = (0..<20).map { _ in AppleIDSignIn.makeRawNonce() }
        for nonce in nonces {
            #expect(nonce.count == 43)
            let allowed = nonce.allSatisfy { Self.base64URL.contains($0) }
            #expect(allowed)
        }
        #expect(Set(nonces).count == nonces.count)
    }

    @Test("The nonce hash is SHA-256 in lowercase hex")
    func nonceHash() {
        #expect(AppleIDSignIn.sha256Hex("abc") == "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad")
        #expect(AppleIDSignIn.sha256Hex("") == "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855")
    }

    @Test("The sheet's request asks for the email address only and carries the hashed nonce, never the raw one")
    func request() {
        let rawNonce = "test-raw-nonce"
        let request = AppleIDSignIn.makeRequest(rawNonce: rawNonce)
        let scopes = request.requestedScopes
        #expect(scopes == [.email])
        #expect(request.nonce == AppleIDSignIn.sha256Hex(rawNonce))
        #expect(request.nonce != rawNonce)
    }

    @Test("The ID token is Apple's token as text")
    func idToken() throws {
        let token = try AppleIDSignIn.idToken(from: Data("header.payload.signature".utf8))
        #expect(token == "header.payload.signature")
    }

    @Test("No token, an empty token or one that is not UTF-8 is no session", arguments: [nil, Data(), Data([0xFF, 0xFE, 0xFD])] as [Data?])
    func noToken(data: Data?) {
        let isNoSession: Bool
        do {
            _ = try AppleIDSignIn.idToken(from: data)
            isNoSession = false
        } catch TabMailAuthError.noSession {
            isNoSession = true
        } catch {
            isNoSession = false
        }
        #expect(isNoSession)
    }

    @Test("Closing Apple's sheet ends quietly as a cancel, whether the error arrives typed or as an NSError")
    func cancel() {
        let typed = AppleIDSignIn.signInError(ASAuthorizationError(.canceled))
        #expect(typed is CancellationError)
        let bridged = AppleIDSignIn.signInError(NSError(domain: ASAuthorizationError.errorDomain, code: ASAuthorizationError.Code.canceled.rawValue))
        #expect(bridged is CancellationError)
    }

    @Test("Any other sheet failure is passed on as it is")
    func otherFailures() {
        let failed = AppleIDSignIn.signInError(ASAuthorizationError(.failed))
        let failedCode = (failed as? ASAuthorizationError)?.code
        #expect(failedCode == .failed)
        let unknown = AppleIDSignIn.signInError(ASAuthorizationError(.unknown))
        let unknownCode = (unknown as? ASAuthorizationError)?.code
        #expect(unknownCode == .unknown)
        let offline = AppleIDSignIn.signInError(URLError(.notConnectedToInternet))
        let offlineCode = (offline as? URLError)?.code
        #expect(offlineCode == .notConnectedToInternet)
    }

    @Test("The Apple exchange posts the ID token and the raw nonce to the auth server's id_token grant")
    func appleExchange() throws {
        let request = try TabMailAuthService.idTokenGrantRequest(provider: .apple, idToken: "test-id-token", nonce: "test-raw-nonce")
        let url = request.url
        #expect(url?.scheme == "https")
        #expect(url?.host == "auth.tabmail.ai")
        #expect(url?.path == "/auth/v1/token")
        #expect(url?.query == "grant_type=id_token")
        #expect(request.httpMethod == "POST")
        #expect(request.value(forHTTPHeaderField: "Content-Type") == "application/json")
        let key = request.value(forHTTPHeaderField: "apikey")
        #expect(key?.isEmpty == false)
        let authorization = request.value(forHTTPHeaderField: "Authorization")
        let expectedAuthorization = key.map { "Bearer \($0)" }
        #expect(authorization == expectedAuthorization)
        let body = try Self.body(of: request)
        #expect(body == ["provider": "apple", "id_token": "test-id-token", "nonce": "test-raw-nonce"])
    }

    @Test("Google and Microsoft exchanges carry no nonce", arguments: [(TabMailProvider.google, "google"), (TabMailProvider.microsoft, "azure")])
    func exchangeWithoutNonce(provider: TabMailProvider, wireName: String) throws {
        let request = try TabMailAuthService.idTokenGrantRequest(provider: provider, idToken: "test-id-token", nonce: nil)
        let path = request.url?.path
        #expect(path == "/auth/v1/token")
        let body = try Self.body(of: request)
        #expect(body == ["provider": wireName, "id_token": "test-id-token"])
    }

    @Test("A sheet result that is not an Apple ID credential is no session")
    func notAppleID() {
        let isNoSession: Bool
        do {
            _ = try AppleIDSignIn.identityToken(of: .password(ASPasswordCredential(user: "user", password: "test-password")))
            isNoSession = false
        } catch TabMailAuthError.noSession {
            isNoSession = true
        } catch {
            isNoSession = false
        }
        #expect(isNoSession)
    }

    @Test("The sheet gets the email-only request, and the exchange sends the sheet's token with the raw nonce behind the request's hash")
    func appleRoute() async throws {
        let exchange = ExchangeRecorder()
        TabMailAuthService._setSignInTransportForTesting(exchange.refuse)
        defer { TabMailAuthService._setSignInTransportForTesting(nil) }
        var sheetRequests: [ASAuthorizationAppleIDRequest] = []

        let outcome = await Self.outcome {
            try await TabMailAuthService().signInWithApple { request in
                sheetRequests.append(request)
                return Data("header.payload.signature".utf8)
            }
        }

        // The refusal ends the sign-in as the auth server's message, before any session is written.
        #expect(outcome == "refused: test refusal")
        #expect(sheetRequests.count == 1)
        guard sheetRequests.count == 1 else { return }
        let scopes = sheetRequests[0].requestedScopes
        #expect(scopes == [.email])
        let requests = exchange.requests
        #expect(requests.count == 1)
        guard requests.count == 1 else { return }
        let path = requests[0].url?.path
        #expect(path == "/auth/v1/token")
        let body = try Self.body(of: requests[0])
        #expect(body["provider"] == "apple")
        #expect(body["id_token"] == "header.payload.signature")
        let rawNonce = try #require(body["nonce"])
        let sentHash = AppleIDSignIn.sha256Hex(rawNonce)
        #expect(sheetRequests[0].nonce == sentHash)
        #expect(rawNonce.count == 43)
    }

    @Test("A second attempt on the same service gets its own nonce: each exchange carries the raw nonce behind its own sheet request")
    func retryGetsItsOwnNonce() async throws {
        let exchange = ExchangeRecorder()
        TabMailAuthService._setSignInTransportForTesting(exchange.refuse)
        defer { TabMailAuthService._setSignInTransportForTesting(nil) }
        let service = TabMailAuthService()
        var sheetNonces: [String?] = []

        for _ in 0..<2 {
            let outcome = await Self.outcome {
                try await service.signInWithApple { request in
                    sheetNonces.append(request.nonce)
                    return Data("header.payload.signature".utf8)
                }
            }
            #expect(outcome == "refused: test refusal")
        }

        let requests = exchange.requests
        #expect(sheetNonces.count == 2)
        #expect(requests.count == 2)
        guard sheetNonces.count == 2, requests.count == 2 else { return }
        let firstBody = try Self.body(of: requests[0])
        let secondBody = try Self.body(of: requests[1])
        let first = try #require(firstBody["nonce"])
        let second = try #require(secondBody["nonce"])
        #expect(first != second)
        let firstHash = AppleIDSignIn.sha256Hex(first)
        let secondHash = AppleIDSignIn.sha256Hex(second)
        #expect(sheetNonces[0] == firstHash)
        #expect(sheetNonces[1] == secondHash)
    }

    @Test("A Google or Microsoft sign-in that gives no nonce sends none", arguments: [TabMailProvider.google, TabMailProvider.microsoft])
    func idTokenSignInSendsNoNonce(provider: TabMailProvider) async throws {
        let exchange = ExchangeRecorder()
        TabMailAuthService._setSignInTransportForTesting(exchange.refuse)
        defer { TabMailAuthService._setSignInTransportForTesting(nil) }

        let outcome = await Self.outcome {
            try await TabMailAuthService().signInWithIdToken(provider: provider, idToken: "test-id-token")
        }

        #expect(outcome == "refused: test refusal")
        let requests = exchange.requests
        #expect(requests.count == 1)
        guard requests.count == 1 else { return }
        let body = try Self.body(of: requests[0])
        #expect(body == ["provider": provider.rawValue, "id_token": "test-id-token"])
    }

    @Test("A sheet that is closed, fails, or returns no token sends nothing to the auth server", arguments: ["closed", "failed", "no token"])
    func sheetEndsWithoutExchange(how: String) async {
        let exchange = ExchangeRecorder()
        TabMailAuthService._setSignInTransportForTesting(exchange.refuse)
        defer { TabMailAuthService._setSignInTransportForTesting(nil) }

        let outcome = await Self.outcome {
            try await TabMailAuthService().signInWithApple { _ in
                switch how {
                case "closed": throw ASAuthorizationError(.canceled)
                case "failed": throw ASAuthorizationError(.failed)
                default: return nil
                }
            }
        }

        let expected = ["closed": "cancelled", "failed": "sheet failed", "no token": "no session"][how]
        #expect(outcome == expected)
        let sent = exchange.requests.count
        #expect(sent == 0)
    }

    @Test("Apple sign-in no longer goes through the web: no authorize page, no callback page, no app URL scheme for it, and the app declares Sign in with Apple")
    func noWebSignIn() throws {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()   // Services
            .deletingLastPathComponent()   // TabMailTests
            .deletingLastPathComponent()   // repository root
        let auth = try String(contentsOf: root.appendingPathComponent("TabMail/Services/TabMailAuthService.swift"), encoding: .utf8)
        #expect(!auth.contains("/auth/v1/authorize"))
        #expect(!auth.contains("ios-callback"))
        #expect(!auth.contains("ASWebAuthenticationSession"))

        // The other registrations stay: Google's and Microsoft's sign-in redirects and mailto links.
        let info = try Self.plist(at: root.appendingPathComponent("TabMail/Resources/Info.plist"))
        let urlTypes = try #require(info["CFBundleURLTypes"] as? [[String: Any]])
        let schemes = urlTypes.flatMap { $0["CFBundleURLSchemes"] as? [String] ?? [] }
        #expect(!schemes.contains("tabmail-ios"))
        #expect(schemes.sorted() == ["$(GOOGLE_REDIRECT_SCHEME)", "$(MICROSOFT_REDIRECT_SCHEME)", "mailto"])

        let entitlements = try Self.plist(at: root.appendingPathComponent("TabMail/TabMail.entitlements"))
        let appleSignIn = entitlements["com.apple.developer.applesignin"] as? [String]
        #expect(appleSignIn == ["Default"])
    }

    fileprivate static func body(of request: URLRequest) throws -> [String: String] {
        let object = try JSONSerialization.jsonObject(with: request.httpBody ?? Data())
        return object as? [String: String] ?? [:]
    }

    private static func plist(at url: URL) throws -> [String: Any] {
        let object = try PropertyListSerialization.propertyList(from: Data(contentsOf: url), format: nil)
        return object as? [String: Any] ?? [:]
    }

    /// How a sign-in ended, as one word the cases compare.
    fileprivate static func outcome(_ signIn: () async throws -> TabMailSession) async -> String {
        do {
            _ = try await signIn()
            return "signed in"
        } catch is CancellationError {
            return "cancelled"
        } catch TabMailAuthError.noSession {
            return "no session"
        } catch TabMailAuthError.otpFailed(let message) {
            return "refused: \(message)"
        } catch let error as ASAuthorizationError where error.code == .failed {
            return "sheet failed"
        } catch is DecodingError {
            return "unreadable"
        } catch {
            return "other: \(error)"
        }
    }
}

/// What an Apple sign-in leaves on the device: the stored session, the device's AI choice, the sign-in
/// epoch, and the billing sync, read at each request the sign-in sends. `.processGlobalState`: it writes the
/// real session slot, the App Group AI values and the shared app database (empty: no mail account).
@Suite("Sign in with Apple: what the exchange's answer leaves", .serialized, .processGlobalState)
@MainActor
struct AppleIDSignInSessionTests {

    @Test("An accepted exchange stores its session, clears the AI choice on a device with no mail account, starts a new sign-in epoch, and only then syncs billing with the new session's token")
    func acceptedExchange() async throws {
        let userId = "apple-test-user-\(UUID().uuidString)"
        let accessToken = "test-access-\(UUID().uuidString)"
        let server = AuthServerStandIn(answer: .session(userId: userId, accessToken: accessToken))

        let (outcome, before, _) = try await Self.withDeviceState(server) {
            await AppleIDSignInTests.outcome { try await Self.signIn() }
        }

        #expect(outcome == "signed in")
        let seen = server.seen
        let paths = seen.map(\.path)
        #expect(paths == ["/auth/v1/token", "/billing/sync-customer"])
        guard seen.count == 2 else { return }
        // Nothing is written before the auth server answers.
        #expect(seen[0].storedUserId == before.storedUserId)
        #expect(seen[0].aiChoiceMade)
        #expect(seen[0].signInGeneration == before.signInGeneration)
        // By the billing sync, the new session is stored, the AI choice cleared and the epoch moved on.
        #expect(seen[1].storedUserId == userId)
        #expect(!seen[1].aiChoiceMade)
        #expect(seen[1].signInGeneration == before.signInGeneration + 1)
        #expect(seen[1].bearer == "Bearer \(accessToken)")
    }

    @Test("A refused or unreadable answer leaves the stored session, the AI choice and the epoch as they were, and syncs nothing", arguments: ["refused", "unreadable"])
    func failedExchange(answer: String) async throws {
        let server = AuthServerStandIn(answer: answer == "refused" ? .refusal : .unreadable)

        let (outcome, before, after) = try await Self.withDeviceState(server) {
            await AppleIDSignInTests.outcome { try await Self.signIn() }
        }

        let expected = answer == "refused" ? "refused: test refusal" : "unreadable"
        #expect(outcome == expected)
        let paths = server.seen.map(\.path)
        #expect(paths == ["/auth/v1/token"])
        #expect(after.storedUserId == before.storedUserId)
        #expect(after.aiChoiceMade)
        #expect(after.signInGeneration == before.signInGeneration)
    }

    /// One Apple sign-in whose sheet returns a made-up token.
    private static func signIn() async throws -> TabMailSession {
        try await TabMailAuthService().signInWithApple { _ in Data("header.payload.signature".utf8) }
    }

    /// Runs `body` on a device signed in as a made-up earlier user, with the AI choice made and an empty app
    /// database, and with `server` answering the sign-in's requests; then puts the session slot, the AI values
    /// and the app database back. Returns `body`'s result and the state before and after it.
    private static func withDeviceState<T>(
        _ server: AuthServerStandIn,
        _ body: () async throws -> T
    ) async throws -> (T, before: SignInState, after: SignInState) {
        let previousSession = TabMailSessionStore.shared.loadActiveSession()?.data
        let restoreSetting = AITestSetting.save()
        let (pool, dir, previousDatabase) = try FolderEpochTestFixture.makeAppDB()
        TabMailAuthService._setSignInTransportForTesting(server.respond)
        defer {
            TabMailAuthService._setSignInTransportForTesting(nil)
            TabMailAuthService.completeSession(mode: .deactivate, notify: false)
            if let previousSession { _ = try? TabMailSessionStore.shared.installNewSession(previousSession) }
            AppDatabase.shared.withLock { $0 = previousDatabase }
            TestDatabaseTeardown.retire(pool: pool, directory: dir)
            restoreSetting()
        }

        let earlierUserId = "apple-test-earlier-\(UUID().uuidString)"
        _ = try TabMailSessionStore.shared.installNewSession(sessionJSON(userId: earlierUserId, accessToken: "test-earlier-access"))
        AISubscriptionGate.shared.noteSignedIn(userId: earlierUserId)
        AITestSetting.set(aiOff: false)
        let before = SignInState.now()

        let result = try await body()
        return (result, before, SignInState.now())
    }
}

/// The device state a sign-in changes.
private struct SignInState: Sendable {
    let storedUserId: String?
    let aiChoiceMade: Bool
    let signInGeneration: Int

    @MainActor
    static func now() -> SignInState {
        SignInState(
            storedUserId: TabMailAuthService.getSession()?.userId,
            aiChoiceMade: AIService.optOutStore.object(forKey: AIService.aiChoiceMadeKey) != nil,
            signInGeneration: AISubscriptionGate.shared.signInGeneration)
    }
}

/// A session body as the auth server returns it, expiring an hour from now.
private func sessionJSON(userId: String, accessToken: String) throws -> Data {
    let expiresAt = Int(Date().addingTimeInterval(60 * 60).timeIntervalSince1970)
    let object: [String: Any] = [
        "access_token": accessToken,
        "refresh_token": "test-refresh",
        "expires_at": expiresAt,
        "user": ["id": userId, "email": "apple-user@example.com"],
    ]
    return try JSONSerialization.data(withJSONObject: object)
}

/// Stands in for the auth server and the billing worker during one sign-in: answers the token exchange as
/// told (a session, a refusal, or a 200 whose body is not a session), answers the billing sync with a 200,
/// and records each request with the device state at the moment it was sent.
private final class AuthServerStandIn: Sendable {
    enum Answer: Sendable {
        case session(userId: String, accessToken: String)
        case refusal
        case unreadable
    }

    struct Seen: Sendable {
        let path: String
        let bearer: String?
        let storedUserId: String?
        let aiChoiceMade: Bool
        let signInGeneration: Int
    }

    private let answer: Answer
    private let recorded = Mutex<[Seen]>([])

    init(answer: Answer) { self.answer = answer }

    var seen: [Seen] { recorded.withLock { $0 } }

    func record(_ request: URLRequest, _ state: SignInState) {
        let entry = Seen(
            path: request.url?.path ?? "",
            bearer: request.value(forHTTPHeaderField: "Authorization"),
            storedUserId: state.storedUserId,
            aiChoiceMade: state.aiChoiceMade,
            signInGeneration: state.signInGeneration)
        recorded.withLock { $0.append(entry) }
    }

    var respond: TabMailTokenCoordinator.DataForRequest {
        { [self] request in
            let state = await SignInState.now()
            record(request, state)
            guard let url = request.url else { throw URLError(.badURL) }
            let status: Int
            let body: Data
            if url.path == "/auth/v1/token" {
                switch answer {
                case .session(let userId, let accessToken):
                    status = 200
                    body = try sessionJSON(userId: userId, accessToken: accessToken)
                case .refusal:
                    status = 400
                    body = Data(#"{"msg":"test refusal"}"#.utf8)
                case .unreadable:
                    status = 200
                    body = Data(#"{"unexpected":true}"#.utf8)
                }
            } else {
                status = 200
                body = Data("{}".utf8)
            }
            guard let response = HTTPURLResponse(url: url, statusCode: status, httpVersion: nil, headerFields: ["Content-Type": "application/json"])
            else { throw URLError(.badURL) }
            return (body, response)
        }
    }
}

/// Stands in for the auth server's token endpoint: records each exchange and refuses it with a 400 and a
/// message, so a route case ends before any session is written.
private final class ExchangeRecorder: Sendable {
    private let recorded = Mutex<[URLRequest]>([])

    var requests: [URLRequest] { recorded.withLock { $0 } }

    func record(_ request: URLRequest) { recorded.withLock { $0.append(request) } }

    var refuse: TabMailTokenCoordinator.DataForRequest {
        { [self] request in
            record(request)
            guard let url = request.url,
                  let response = HTTPURLResponse(url: url, statusCode: 400, httpVersion: nil, headerFields: ["Content-Type": "application/json"])
            else { throw URLError(.badURL) }
            return (Data(#"{"msg":"test refusal"}"#.utf8), response)
        }
    }
}
