/* This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at https://mozilla.org/MPL/2.0/. */

import AuthenticationServices
import Foundation
import Synchronization
import Testing
@testable import TabMail

/// Account deletion stops TabMail's use of a Sign in with Apple account. Invariants:
/// - only an account whose access token lists the `apple` provider sees Apple's sheet;
/// - the sheet runs once, right before the deletion request and after every subscription check, and its
///   code goes only into that request's body;
/// - every way the sheet can end without a code (closed, failed, no code) still sends the deletion;
/// - a request without a code is unchanged on the wire (no body for `/account/delete`, only `request_id` for
///   `/account/age-ineligible`);
/// - after a failed age check the sheet runs only once billing has acknowledged the deletion (a 2xx), never
///   while a request is in flight, at most once, and never changes whether the person is signed out; a later OK
///   after a sign-out decision sends nothing and shows no sheet;
/// - the confirmation shows the manual steps unless billing answered that it revoked the authorization.
private struct SheetFailure: Error {}
private struct RequestFailure: Error {}
private struct Unexpected: Error {}

/// What billing and Apple's sheet saw during one refusal, in order: each request (`send:<code>` or `send:none`),
/// each held request's answer (`answered`) and each sheet. When `holdsNextUncodedRequest` is set, the next
/// request without a code waits for the test; the hold is one-shot, so a duplicate request is answered at once
/// and shows in `events`.
@MainActor
private final class RefusalRecorder {
    var events: [String] = []
    var answers: [Error?]
    var holdsNextUncodedRequest = false
    var held: [CheckedContinuation<Void, Never>] = []

    init(answers: [Error?]) {
        self.answers = answers
    }

    func exit() -> AgeAndTermsConsent.RefusalExit {
        AgeAndTermsConsent.RefusalExit(send: { [self] code in
            events.append("send:\(code ?? "none")")
            if code == nil, holdsNextUncodedRequest {
                holdsNextUncodedRequest = false
                await withCheckedContinuation { continuation in
                    held.append(continuation)
                }
                events.append("answered")
            }
            guard !answers.isEmpty else { return AgeAndTermsConsent.DeletionAnswer(error: Unexpected()) }
            return AgeAndTermsConsent.DeletionAnswer(error: answers.removeFirst())
        })
    }

    func sheet(code: String?) -> String? {
        events.append("sheet")
        return code
    }

    /// Lets queued main-actor work run until `condition` holds (bounded).
    func settle(until condition: () -> Bool) async {
        for _ in 0..<10_000 {
            if condition() { return }
            await Task.yield()
        }
    }
}

@Suite("Sign in with Apple revoke on account deletion")
@MainActor
struct AppleSignInRevokeTests {

    // MARK: - Fixtures

    private static let header = "eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9"

    /// A token shaped like the app's access token, with `claims` as its payload segment (base64url, no
    /// padding). Returns the token and that segment.
    private static func accessToken(claims: [String: Any]) throws -> (token: String, payload: String) {
        let json = try JSONSerialization.data(withJSONObject: claims, options: [.sortedKeys])
        let payload = json.base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
        return ("\(header).\(payload).test-signature", payload)
    }

    private static func providers(_ list: [String]) -> [String: Any] {
        ["sub": "user-1", "app_metadata": ["provider": list.first ?? "email", "providers": list] as [String: Any]]
    }

    private static func deletionResponse(revoked: Bool?) throws -> BillingClient.DeletionResponse {
        let date = ISO8601DateFormatter().string(from: Date.now.addingTimeInterval(30 * 24 * 60 * 60))
        let revokedJSON = revoked.map { ",\"apple_authorization_revoked\":\($0)" } ?? ""
        return try JSONDecoder().decode(
            BillingClient.DeletionResponse.self,
            from: Data("{\"status\":\"scheduled\",\"deletion_date\":\"\(date)\"\(revokedJSON)}".utf8)
        )
    }

    private static func accountInfo(hasSubscription: Bool, provider: String? = nil) throws -> AccountInfo {
        let providerJSON = provider.map { "\"\($0)\"" } ?? "null"
        return try JSONDecoder().decode(
            AccountInfo.self,
            from: Data(
                """
                {"logged_in": true, "has_subscription": \(hasSubscription), \
                "subscription_provider": \(providerJSON), "pending_cancellation": null}
                """.utf8
            )
        )
    }

    private static func jsonObject(_ body: Data?) throws -> [String: String] {
        let data = try #require(body)
        return try #require(try JSONSerialization.jsonObject(with: data) as? [String: String])
    }

    // MARK: - Which account sees the sheet

    @Test("An access token listing the apple provider is an Apple account, alone or beside others")
    func appleProviderListed() throws {
        let appleOnly = try Self.accessToken(claims: Self.providers(["apple"])).token
        let mixed = try Self.accessToken(claims: Self.providers(["email", "apple"])).token
        #expect(AppleIDSignIn.isAppleAccount(accessToken: appleOnly))
        #expect(AppleIDSignIn.isAppleAccount(accessToken: mixed))
    }

    @Test("Other providers, no provider list, or a list of the wrong type is not an Apple account")
    func otherProviders() throws {
        let others = try Self.accessToken(claims: Self.providers(["email", "google"])).token
        let noMetadata = try Self.accessToken(claims: ["sub": "user-1"]).token
        let noList = try Self.accessToken(claims: ["sub": "user-1", "app_metadata": ["provider": "apple"]]).token
        let wrongType = try Self.accessToken(claims: ["sub": "user-1", "app_metadata": ["providers": "apple"]]).token
        for token in [others, noMetadata, noList, wrongType] {
            #expect(!AppleIDSignIn.isAppleAccount(accessToken: token), "\(token)")
        }
    }

    @Test("No token, or one that is not three segments of base64url JSON, is not an Apple account")
    func malformedTokens() throws {
        let payload = try Self.accessToken(claims: Self.providers(["apple"])).payload
        let tokens: [String?] = [
            nil, "", "not-a-token", "\(Self.header).\(payload)", "\(Self.header).\(payload).sig.extra",
            "\(Self.header).!!!.sig", "\(Self.header)..sig", ".\(payload).", "\(Self.header).\(payload).", ".\(payload).sig",
            "\(Self.header).\(Data("not json".utf8).base64EncodedString()).sig",
        ]
        for token in tokens {
            #expect(!AppleIDSignIn.isAppleAccount(accessToken: token), "\(String(describing: token))")
        }
    }

    @Test("A payload is read as base64url: its - and _ characters and a missing padding")
    func base64URLPayloads() throws {
        var sawURLAlphabet = false
        var sawUnpadded = false
        for fillerLength in 0..<12 {
            var claims = Self.providers(["apple"])
            // "?" is 0x3F: runs of it encode to "/" in base64 ("_" in base64url) at some alignments.
            claims["filler"] = String(repeating: "?", count: fillerLength) + String(repeating: ">", count: fillerLength)
            let (token, payload) = try Self.accessToken(claims: claims)
            if payload.contains("-") || payload.contains("_") { sawURLAlphabet = true }
            if payload.count % 4 != 0 { sawUnpadded = true }
            #expect(AppleIDSignIn.isAppleAccount(accessToken: token), "filler \(fillerLength)")
        }
        #expect(sawURLAlphabet, "at least one payload used the base64url alphabet")
        #expect(sawUnpadded, "at least one payload had no padding")
    }

    // MARK: - The sheet

    @Test("The deletion sheet's request asks for no scopes and carries no nonce")
    func revokeRequest() {
        let request = AppleIDSignIn.makeRevokeRequest()
        let scopes = request.requestedScopes ?? []
        #expect(scopes.isEmpty)
        #expect(request.nonce == nil)
    }

    @Test("A fresh code is the sheet's authorization code as text, from one sheet with the deletion request")
    func freshCode() async {
        var requests: [ASAuthorizationAppleIDRequest] = []
        let code = await AppleIDSignIn.freshAuthorizationCode { request in
            requests.append(request)
            return Data("code-1".utf8)
        }
        #expect(code == "code-1")
        #expect(requests.count == 1)
        guard requests.count == 1 else { return }
        let scopes = requests[0].requestedScopes ?? []
        #expect(scopes.isEmpty)
        #expect(requests[0].nonce == nil)
    }

    @Test(
        "A sheet that is closed or fails gives no code and never throws",
        arguments: [ASAuthorizationError(.canceled), ASAuthorizationError(.failed), URLError(.notConnectedToInternet)] as [Error]
    )
    func sheetEndsWithoutCode(error: Error) async {
        let code = await AppleIDSignIn.freshAuthorizationCode { _ in throw error }
        #expect(code == nil)
    }

    @Test(
        "No code data, empty data or data that is not UTF-8 gives no code",
        arguments: [nil, Data(), Data([0xFF, 0xFE, 0xFD])] as [Data?]
    )
    func unusableCode(data: Data?) async {
        let code = await AppleIDSignIn.freshAuthorizationCode { _ in data }
        #expect(code == nil)
    }

    // MARK: - The deletion request with the sheet in front

    @Test("An Apple account runs the sheet once, then sends the deletion with its code")
    func appleAccountSendsCode() async throws {
        var events: [String] = []
        let response = try await AppleIDSignIn.scheduleDeletion(
            isAppleAccount: true,
            authorize: { _ in
                events.append("sheet")
                return Data("code-1".utf8)
            },
            request: { code in
                events.append("request:\(code ?? "none")")
                return try Self.deletionResponse(revoked: true)
            }
        )
        #expect(events == ["sheet", "request:code-1"])
        #expect(response.apple_authorization_revoked == true)
    }

    @Test(
        "An Apple account whose sheet ends without a code still sends the deletion, without a code",
        arguments: [ASAuthorizationError(.canceled), SheetFailure()] as [Error]
    )
    func appleAccountWithoutCodeStillDeletes(error: Error) async throws {
        var events: [String] = []
        _ = try await AppleIDSignIn.scheduleDeletion(
            isAppleAccount: true,
            authorize: { _ in
                events.append("sheet")
                throw error
            },
            request: { code in
                events.append("request:\(code ?? "none")")
                return try Self.deletionResponse(revoked: nil)
            }
        )
        #expect(events == ["sheet", "request:none"])
    }

    @Test("Any other account sends the deletion without a sheet or a code")
    func otherAccountNoSheet() async throws {
        var events: [String] = []
        _ = try await AppleIDSignIn.scheduleDeletion(
            isAppleAccount: false,
            authorize: { _ in
                events.append("sheet")
                return Data("code-1".utf8)
            },
            request: { code in
                events.append("request:\(code ?? "none")")
                return try Self.deletionResponse(revoked: nil)
            }
        )
        #expect(events == ["request:none"])
    }

    @Test("A failed deletion request is passed on as it is")
    func requestFailurePassedOn() async {
        var threw = false
        do {
            _ = try await AppleIDSignIn.scheduleDeletion(
                isAppleAccount: true,
                authorize: { _ in Data("code-1".utf8) },
                request: { _ in throw RequestFailure() }
            )
        } catch is RequestFailure {
            threw = true
        } catch {
            threw = false
        }
        #expect(threw)
    }

    @Test("Through the coordinator, the sheet comes after the final subscription re-read, right before the request")
    func coordinatorRunsTheSheetLast() async throws {
        var events: [String] = []
        let execution = try await AccountDeletionSubscriptionCoordinator.execute(
            fetchAccountInfo: {
                events.append("fetch")
                return try Self.accountInfo(hasSubscription: false)
            },
            cancelStripe: { throw Unexpected() },
            manageAppleSubscription: { false },
            scheduleDeletion: {
                try await AppleIDSignIn.scheduleDeletion(
                    isAppleAccount: true,
                    authorize: { _ in
                        events.append("sheet")
                        return Data("code-1".utf8)
                    },
                    request: { code in
                        events.append("delete:\(code ?? "none")")
                        return try Self.deletionResponse(revoked: true)
                    }
                )
            },
            progress: { _ in }
        )
        #expect(events == ["fetch", "fetch", "sheet", "delete:code-1"])
        guard case .scheduled(_, let revoked) = execution else {
            Issue.record("Expected the deletion to be scheduled")
            return
        }
        #expect(revoked == true)
    }

    @Test("A deletion the final re-read blocks never shows the sheet")
    func blockedDeletionShowsNoSheet() async throws {
        let noSubscription = try Self.accountInfo(hasSubscription: false)
        let activeStripe = try Self.accountInfo(hasSubscription: true, provider: "stripe")
        var snapshots = [noSubscription, activeStripe]
        var sheets = 0
        var deletions = 0
        let execution = try await AccountDeletionSubscriptionCoordinator.execute(
            fetchAccountInfo: { snapshots.removeFirst() },
            cancelStripe: { throw Unexpected() },
            manageAppleSubscription: { false },
            scheduleDeletion: {
                try await AppleIDSignIn.scheduleDeletion(
                    isAppleAccount: true,
                    authorize: { _ in
                        sheets += 1
                        return Data("code-1".utf8)
                    },
                    request: { _ in
                        deletions += 1
                        return try Self.deletionResponse(revoked: true)
                    }
                )
            },
            progress: { _ in }
        )
        guard case .blocked = execution else {
            Issue.record("Expected the final re-read to block the deletion")
            return
        }
        #expect(sheets == 0)
        #expect(deletions == 0)
        #expect(snapshots.isEmpty)
    }

    @Test("The scheduled result carries billing's revoke answer as it is", arguments: [true, false, nil] as [Bool?])
    func scheduledCarriesTheAnswer(revoked: Bool?) async throws {
        let execution = try await AccountDeletionSubscriptionCoordinator.execute(
            fetchAccountInfo: { try Self.accountInfo(hasSubscription: false) },
            cancelStripe: { throw Unexpected() },
            manageAppleSubscription: { false },
            scheduleDeletion: { try Self.deletionResponse(revoked: revoked) },
            progress: { _ in }
        )
        guard case .scheduled(_, let answer) = execution else {
            Issue.record("Expected the deletion to be scheduled")
            return
        }
        #expect(answer == revoked)
    }

    // MARK: - On the wire

    @Test("A deletion request without a code has no body")
    func accountDeletionWithoutCode() throws {
        let request = try BillingClient.makeAccountDeletionRequest(
            baseURL: URL(string: "https://billing.example.com")!, token: "token-a", appleAuthorizationCode: nil)
        #expect(request.url?.absoluteString == "https://billing.example.com/account/delete")
        #expect(request.httpMethod == "POST")
        #expect(request.allHTTPHeaderFields == ["Authorization": "Bearer token-a", "Content-Type": "application/json"])
        #expect(request.httpBody == nil)
    }

    @Test("A deletion request with a code sends only the code")
    func accountDeletionWithCode() throws {
        let request = try BillingClient.makeAccountDeletionRequest(
            baseURL: URL(string: "https://billing.example.com")!, token: "token-a", appleAuthorizationCode: "code-1")
        #expect(request.url?.absoluteString == "https://billing.example.com/account/delete")
        #expect(request.allHTTPHeaderFields == ["Authorization": "Bearer token-a", "Content-Type": "application/json"],
                "the code goes only into the body")
        let json = try Self.jsonObject(request.httpBody)
        #expect(json == ["apple_authorization_code": "code-1"])
    }

    @Test("The age deletion request without a code sends only the request id; with one, both")
    func ageDeletionBodies() throws {
        let base = URL(string: "https://billing.example.com")!
        let without = try BillingClient.makeAgeIneligibleDeletionRequest(
            baseURL: base, token: "token-a", requestId: "req-1", appleAuthorizationCode: nil)
        #expect(without.httpBody == Data("{\"request_id\":\"req-1\"}".utf8), "byte for byte the request sent before")
        let with = try BillingClient.makeAgeIneligibleDeletionRequest(
            baseURL: base, token: "token-a", requestId: "req-1", appleAuthorizationCode: "code-1")
        #expect(without.url?.absoluteString == "https://billing.example.com/account/age-ineligible")
        #expect(with.url?.absoluteString == "https://billing.example.com/account/age-ineligible")
        #expect(without.httpMethod == "POST" && with.httpMethod == "POST")
        let withBody = try Self.jsonObject(with.httpBody)
        #expect(withBody == ["request_id": "req-1", "apple_authorization_code": "code-1"])
        let headers = ["Authorization": "Bearer token-a", "Content-Type": "application/json"]
        #expect(without.allHTTPHeaderFields == headers)
        #expect(with.allHTTPHeaderFields == headers, "the code goes only into the body")
        #expect(without.timeoutInterval == 30 && with.timeoutInterval == 30)
    }

    @Test("The deletion answer reads the revoke field when present and nil when not", arguments: [true, false, nil] as [Bool?])
    func deletionResponseDecodes(revoked: Bool?) throws {
        let response = try Self.deletionResponse(revoked: revoked)
        #expect(response.apple_authorization_revoked == revoked)
        #expect(response.status == "scheduled")
    }

    // MARK: - The confirmation

    @Test("The manual steps show for an Apple account unless billing answered true")
    func manualStopLine() {
        #expect(!AppleIDSignIn.showsManualStopLine(isAppleAccount: true, appleAuthorizationRevoked: true))
        #expect(AppleIDSignIn.showsManualStopLine(isAppleAccount: true, appleAuthorizationRevoked: false))
        #expect(AppleIDSignIn.showsManualStopLine(isAppleAccount: true, appleAuthorizationRevoked: nil))
        for answer in [true, false, nil] as [Bool?] {
            #expect(!AppleIDSignIn.showsManualStopLine(isAppleAccount: false, appleAuthorizationRevoked: answer))
        }
    }

    @Test("The manual steps name Apple's own path and its support article")
    func manualStopCopy() {
        #expect(AccountDeletionCopy.appleSignInManualStop.contains("Sign in with Apple"))
        #expect(AccountDeletionCopy.appleSignInManualStop.contains("Delete"))
        #expect(AccountDeletionCopy.appleSignInSupportURL == "https://support.apple.com/102571")
        #expect(AccountDeletionCopy.appleSignInConfirmNotice.contains("the deletion still goes ahead"))
    }

    // MARK: - After a failed age check

    /// Runs one refusal the way the screen does: the request at the failed check (unless `sentAtCheck` is false,
    /// a device already blocked), then `oks` taps of OK. `answers` are billing's answers to the requests in
    /// order. Returns each OK's decision and what billing and the sheet saw.
    private func refusal(
        sentAtCheck: Bool = true,
        isAppleAccount: Bool = true,
        answers: [Error?],
        sheetCode: String? = "code-1",
        oks: Int = 1
    ) async -> (handshakes: [AgeAndTermsConsent.DeletionHandshake], events: [String]) {
        let recorder = RefusalRecorder(answers: answers)
        let exit = recorder.exit()
        if sentAtCheck { exit.requestDeletion() }
        var handshakes: [AgeAndTermsConsent.DeletionHandshake] = []
        for _ in 0..<oks {
            let handshake = await exit.leave(
                isAppleAccount: isAppleAccount,
                appleAuthorizationCode: { recorder.sheet(code: sheetCode) }
            )
            handshakes.append(handshake)
        }
        return (handshakes, recorder.events)
    }

    @Test("Acknowledged at the failed check: one sheet, then one request with its code, then sign out")
    func acknowledgedEarlierSendsCode() async {
        let result = await refusal(answers: [nil, nil])
        #expect(result.handshakes == [.signOut])
        #expect(result.events == ["send:none", "sheet", "send:code-1"])
    }

    @Test("Acknowledged, and the sheet ends without a code: nothing more is sent, sign out")
    func acknowledgedSheetClosed() async {
        let result = await refusal(answers: [nil], sheetCode: nil)
        #expect(result.handshakes == [.signOut])
        #expect(result.events == ["send:none", "sheet"])
    }

    @Test("Never sent (a device already blocked): sent at OK without a code, then the sheet and the code")
    func neverSentEarlier() async {
        let result = await refusal(sentAtCheck: false, answers: [nil, nil])
        #expect(result.handshakes == [.signOut])
        #expect(result.events == ["send:none", "sheet", "send:code-1"])
    }

    @Test("No answer at the failed check: sent again without a code; acknowledged, then the sheet and the code")
    func retriedThenAcknowledged() async {
        let result = await refusal(answers: [BackendError.requestFailed(statusCode: 503), nil, nil])
        #expect(result.handshakes == [.signOut])
        #expect(result.events == ["send:none", "send:none", "sheet", "send:code-1"])
    }

    @Test("Still no answer: stay on the refusal, no sheet; the next OK asks again")
    func stillNoAnswer() async {
        let result = await refusal(
            answers: [URLError(.notConnectedToInternet), BackendError.requestFailed(statusCode: 0), nil, nil],
            oks: 2
        )
        #expect(result.handshakes == [.retry, .signOut])
        #expect(result.events == ["send:none", "send:none", "send:none", "sheet", "send:code-1"])
    }

    @Test(
        "A refusal or a gone session signs out with no sheet and nothing more sent",
        arguments: [BackendError.requestFailed(statusCode: 409), BackendError.requestFailed(statusCode: 400), BackendError.unauthorized] as [Error]
    )
    func refusalSignsOutWithoutSheet(error: Error) async {
        let atCheck = await refusal(answers: [error])
        #expect(atCheck.handshakes == [.signOut])
        #expect(atCheck.events == ["send:none"])

        let atOK = await refusal(sentAtCheck: false, answers: [error])
        #expect(atOK.handshakes == [.signOut])
        #expect(atOK.events == ["send:none"])
    }

    @Test("Any other account signs out with no sheet once billing acknowledged")
    func otherAccountNoSheetAfterAgeCheck() async {
        let result = await refusal(isAppleAccount: false, answers: [nil])
        #expect(result.handshakes == [.signOut])
        #expect(result.events == ["send:none"])
    }

    @Test("A request with the code that gets no answer still signs out")
    func codeRequestFailureStillSignsOut() async {
        let result = await refusal(answers: [nil, BackendError.requestFailed(statusCode: 503)])
        #expect(result.handshakes == [.signOut])
        #expect(result.events == ["send:none", "sheet", "send:code-1"])
    }

    @Test(
        "After a sign-out decision a later OK signs out again at once: no request, no second sheet",
        arguments: [nil, BackendError.requestFailed(statusCode: 503)] as [Error?]
    )
    func laterOKKeepsTheDecision(codeAnswer: Error?) async {
        let apple = await refusal(answers: [nil, codeAnswer], oks: 2)
        #expect(apple.handshakes == [.signOut, .signOut])
        #expect(apple.events == ["send:none", "sheet", "send:code-1"])

        let other = await refusal(isAppleAccount: false, answers: [nil], oks: 2)
        #expect(other.handshakes == [.signOut, .signOut])
        #expect(other.events == ["send:none"])

        let refused = await refusal(answers: [BackendError.requestFailed(statusCode: 409)], oks: 2)
        #expect(refused.handshakes == [.signOut, .signOut])
        #expect(refused.events == ["send:none"])
    }

    @Test("No sheet while the failed check's request is in flight; the sheet follows its 2xx")
    func sheetWaitsForTheCheckRequest() async {
        let recorder = RefusalRecorder(answers: [nil, nil])
        recorder.holdsNextUncodedRequest = true
        let exit = recorder.exit()
        exit.requestDeletion()
        await recorder.settle(until: { recorder.held.count == 1 })
        #expect(recorder.events == ["send:none"], "the failed check's request is the one held")
        let leaving = Task {
            await exit.leave(isAppleAccount: true, appleAuthorizationCode: { recorder.sheet(code: "code-1") })
        }
        await recorder.settle(until: { false })
        #expect(recorder.events == ["send:none"], "OK waits; no second request and no sheet while in flight")
        #expect(recorder.held.count == 1)
        guard recorder.held.count == 1 else { return }
        recorder.held.removeFirst().resume()
        let handshake = await leaving.value
        #expect(handshake == .signOut)
        #expect(recorder.events == ["send:none", "answered", "sheet", "send:code-1"])
    }

    @Test("A device already blocked: no sheet while OK's own request is in flight; the sheet follows its 2xx")
    func sheetWaitsForTheOKRequest() async {
        let recorder = RefusalRecorder(answers: [nil, nil])
        recorder.holdsNextUncodedRequest = true
        let exit = recorder.exit()
        let leaving = Task {
            await exit.leave(isAppleAccount: true, appleAuthorizationCode: { recorder.sheet(code: "code-1") })
        }
        await recorder.settle(until: { recorder.held.count == 1 })
        await recorder.settle(until: { false })
        #expect(recorder.events == ["send:none"])
        #expect(recorder.held.count == 1)
        guard recorder.held.count == 1 else { return }
        recorder.held.removeFirst().resume()
        let handshake = await leaving.value
        #expect(handshake == .signOut)
        #expect(recorder.events == ["send:none", "answered", "sheet", "send:code-1"])
    }
}

/// Every request billing received in a wire test, headers included, answered with one fixed response. Runs on
/// the stub transport's own thread, hence `Sendable` and a `Mutex`.
private final class Billing: Sendable {
    private let received = Mutex<[FakeHTTP.Request]>([])
    private let response: FakeHTTP.CannedResponse

    init(_ response: FakeHTTP.CannedResponse) {
        self.response = response
    }

    func respond(to request: FakeHTTP.Request) -> FakeHTTP.CannedResponse {
        received.withLock { $0.append(request) }
        return response
    }

    var requests: [FakeHTTP.Request] { received.withLock { $0 } }

    /// True when no request carried `code` in its URL or in any header name or value: the code goes only into a
    /// body.
    func codeOnlyInBodies(_ code: String) -> Bool {
        requests.allSatisfy { request in
            !request.url.absoluteString.contains(code)
                && !request.headers.contains(where: { $0.key.contains(code) || $0.value.contains(code) })
        }
    }

    /// The full URL of every request, query and fragment included.
    var urls: [String] { requests.map(\.url.absoluteString) }
}

/// The deletion requests through the real `BillingClient` methods and the age screen's send, over a stub
/// transport: a code goes only into the body, and a request without one is unchanged. Installs a valid synthetic
/// session in the app's shared session store, hence `.serialized` and `.processGlobalState`; the previous one is
/// restored.
@Suite("Sign in with Apple revoke: the requests on the wire", .serialized, .processGlobalState)
@MainActor
struct AppleSignInRevokeWireTests {
    private static func jsonObject(_ body: Data?) throws -> [String: String] {
        let data = try #require(body)
        return try #require(try JSONSerialization.jsonObject(with: data) as? [String: String])
    }

    private func withSession<T: Sendable>(_ body: () async throws -> T) async throws -> T {
        let previous = TabMailSessionStore.shared.loadActiveSession()?.data
        defer {
            _ = TabMailAuthService.completeSession(mode: .deactivate, notify: false)
            if let previous { _ = try? TabMailSessionStore.shared.installNewSession(previous) }
        }
        _ = TabMailAuthService.completeSession(mode: .deactivate, notify: false)
        let expires = Int(Date().addingTimeInterval(3600).timeIntervalSince1970)
        let user: [String: Any] = ["id": "test-user", "email": "user@example.com"]
        let json: [String: Any] = [
            "access_token": "test-access", "refresh_token": "test-refresh", "expires_at": expires, "user": user,
        ]
        _ = try TabMailSessionStore.shared.installNewSession(try JSONSerialization.data(withJSONObject: json))
        return try await body()
    }

    @Test("The Settings deletion sends no body without a code, and only the code with one")
    func accountDeletionOnTheWire() async throws {
        let http = FakeHTTP.Scenario()
        defer { http.close() }
        let date = ISO8601DateFormatter().string(from: Date.now.addingTimeInterval(30 * 24 * 60 * 60))
        let billing = Billing(
            .json(raw: "{\"status\":\"scheduled\",\"deletion_date\":\"\(date)\",\"apple_authorization_revoked\":true}"))
        http.register(path: "/account/delete", method: "POST", handler: { billing.respond(to: $0) })
        let client = BillingClient(session: http.session)
        let url = BackendConfig.billingBaseURL.appending(path: "/account/delete").absoluteString
        let revoked = try await withSession {
            _ = try await client.requestAccountDeletion()
            let response = try await client.requestAccountDeletion(appleAuthorizationCode: "code-1")
            return response.apple_authorization_revoked
        }
        #expect(revoked == true)
        #expect(http.servedCallSequence() == ["POST /account/delete", "POST /account/delete"])
        let calls = http.recordedCalls()
        guard calls.count == 2 else { return }
        let firstBody = calls[0].body ?? Data()
        #expect(firstBody.isEmpty, "no body without a code")
        let secondBody = try Self.jsonObject(calls[1].body)
        #expect(secondBody == ["apple_authorization_code": "code-1"])
        #expect(billing.urls == [url, url], "the same URL with and without a code, no query")
        #expect(billing.codeOnlyInBodies("code-1"), "no URL or header carries the code")
    }

    @Test("The age deletion sends only its request id without a code, and both with one")
    func ageDeletionOnTheWire() async throws {
        let http = FakeHTTP.Scenario()
        defer { http.close() }
        let billing = Billing(.status(200))
        http.register(path: "/account/age-ineligible", method: "POST", handler: { billing.respond(to: $0) })
        let client = BillingClient(session: http.session)
        let url = BackendConfig.billingBaseURL.appending(path: "/account/age-ineligible").absoluteString
        let answers = try await withSession {
            let without = await AgeAndTermsConsent.sendDeletionRequest(appleAuthorizationCode: nil, client: client)
            let with = await AgeAndTermsConsent.sendDeletionRequest(appleAuthorizationCode: "code-1", client: client)
            return (without.handshake, with.handshake, without.error == nil, with.error == nil)
        }
        #expect(answers.2 && answers.3, "both acknowledged")
        #expect(answers.0 == .signOut && answers.1 == .signOut)
        #expect(http.servedCallSequence() == ["POST /account/age-ineligible", "POST /account/age-ineligible"])
        let calls = http.recordedCalls()
        guard calls.count == 2 else { return }
        let first = try Self.jsonObject(calls[0].body)
        let second = try Self.jsonObject(calls[1].body)
        #expect(Set(first.keys) == ["request_id"])
        let requestId = try #require(first["request_id"])
        let unchanged = Data("{\"request_id\":\"\(requestId)\"}".utf8)
        #expect(calls[0].body == unchanged, "byte for byte the request sent before")
        #expect(Set(second.keys) == ["request_id", "apple_authorization_code"])
        #expect(second["apple_authorization_code"] == "code-1")
        // Billing answers 400 to a request id that is not a UUID, and the screen signs out whatever the coded
        // request's answer is, so an unusable id would lose the revoke without a trace.
        let secondId = second["request_id"] ?? ""
        #expect(UUID(uuidString: requestId) != nil && UUID(uuidString: secondId) != nil, "both ids are UUIDs")
        #expect(billing.urls == [url, url], "the same URL with and without a code, no query")
        #expect(billing.codeOnlyInBodies("code-1"), "no URL or header carries the code")
    }

    @Test("The age screen's answer is billing's own: a 2xx acknowledges, a 409 signs out, a 503 asks again", arguments: [200, 409, 503])
    func ageAnswerFollowsBilling(status: Int) async throws {
        let http = FakeHTTP.Scenario()
        defer { http.close() }
        http.register(path: "/account/age-ineligible", method: "POST", response: .status(status))
        let client = BillingClient(session: http.session)
        let answer = try await withSession {
            let answer = await AgeAndTermsConsent.sendDeletionRequest(appleAuthorizationCode: nil, client: client)
            return (answer.handshake, answer.error == nil)
        }
        switch status {
        case 200:
            #expect(answer.1, "acknowledged")
            #expect(answer.0 == .signOut)
        case 409:
            #expect(!answer.1, "a refusal is not an acknowledgment")
            #expect(answer.0 == .signOut)
        default:
            #expect(!answer.1)
            #expect(answer.0 == .retry)
        }
    }

    @Test("With debug logging on, no log line carries the authorization code")
    func codeNeverLogged() async throws {
        let code = "code-\(UUID().uuidString)"
        let logURL = FileManager.default.temporaryDirectory.appendingPathComponent("applerevoke_\(UUID().uuidString).log")
        AppLogStore.fileURLOverride.withLock { $0 = logURL }
        DebugModeManager.loggingEnabledOverrideForTesting.withLock { $0 = true }
        defer {
            DebugModeManager.loggingEnabledOverrideForTesting.withLock { $0 = nil }
            AppLogStore._resetForTesting()
            try? FileManager.default.removeItem(at: logURL)
        }
        let date = ISO8601DateFormatter().string(from: Date.now.addingTimeInterval(30 * 24 * 60 * 60))
        let scheduled = FakeHTTP.Scenario()
        defer { scheduled.close() }
        scheduled.register(path: "/account/delete", method: "POST", response: .json(
            raw: "{\"status\":\"scheduled\",\"deletion_date\":\"\(date)\",\"apple_authorization_revoked\":false}"))
        scheduled.register(path: "/account/age-ineligible", method: "POST", response: .status(200))
        let unavailable = FakeHTTP.Scenario()
        defer { unavailable.close() }
        unavailable.register(path: "/account/age-ineligible", method: "POST", response: .status(503))
        let fresh = await AppleIDSignIn.freshAuthorizationCode { _ in Data(code.utf8) }
        #expect(fresh == code)
        let acknowledged = try await withSession {
            let client = BillingClient(session: scheduled.session)
            _ = try await client.requestAccountDeletion(appleAuthorizationCode: code)
            let first = await AgeAndTermsConsent.sendDeletionRequest(appleAuthorizationCode: code, client: client)
            let second = await AgeAndTermsConsent.sendDeletionRequest(
                appleAuthorizationCode: code, client: BillingClient(session: unavailable.session))
            return (first.error == nil, second.error == nil)
        }
        #expect(acknowledged.0 && !acknowledged.1, "one acknowledged request and one failed one, both logged")
        let log = AppLogStore.read()
        #expect(log.contains("[ConsentGate] Age-ineligible account deletion requested"), "debug logging was on")
        #expect(log.contains("[ConsentGate] Age-ineligible deletion request failed"), "debug logging was on")
        #expect(!log.contains(code), "no log line carries the code")
    }
}

/// The two screens cannot be hosted in a unit test with their environment, so this is a scoped source fence
/// over each link from the screen to the tested helpers above.
@Suite("Sign in with Apple revoke: screen wiring")
struct AppleSignInRevokeWiringTests {
    private static func source(_ path: String) throws -> String {
        let projectRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let raw = try String(contentsOf: projectRoot.appendingPathComponent(path), encoding: .utf8)
        return raw.split(whereSeparator: \.isWhitespace).joined(separator: " ")
    }

    /// The text after `signature` up to the next `private func`, or to the end of the file.
    private static func body(of signature: String, in text: String) throws -> String {
        let start = try #require(text.range(of: signature))
        let end = text[start.upperBound...].range(of: "private func ")?.lowerBound ?? text.endIndex
        return String(text[start.upperBound..<end])
    }

    private static func count(_ needle: String, in text: String) -> Int {
        text.components(separatedBy: needle).count - 1
    }

    @Test("Settings deletion reads the account once at the start and runs the sheet only inside the scheduling step")
    func accountDeletionScreen() throws {
        let text = try Self.source("TabMail/Views/Settings/AccountDeletionView.swift")
        let body = try Self.body(of: "private func deleteAccount() async {", in: text)
        let snapshot = try #require(body.range(
            of: "let appleAccount = AppleIDSignIn.isAppleAccount(accessToken: TabMailAuthService.getSession()?.accessToken)"))
        let execute = try #require(body.range(of: "AccountDeletionSubscriptionCoordinator.execute("))
        #expect(snapshot.lowerBound < execute.lowerBound, "the account is read before the deletion starts")
        let scheduling = try #require(body.range(of:
            "scheduleDeletion: { try await AppleIDSignIn.scheduleDeletion( isAppleAccount: appleAccount, authorize: authorize, " +
            "request: { try await billingClient.requestAccountDeletion(appleAuthorizationCode: $0) } ) }"))
        #expect(execute.lowerBound < scheduling.lowerBound, "the sheet runs inside the coordinator's scheduling step")
        #expect(body.contains("AppleIDSignIn.authorizationCode(of: try await authorizationController.performRequest(request))"))
        #expect(Self.count("performRequest(", in: text) == 1, "one sheet")
        #expect(Self.count("authorize(", in: text) == 0, "the sheet is never run directly")
        #expect(Self.count("freshAuthorizationCode(", in: text) == 0, "only through scheduleDeletion")
        #expect(Self.count("AppleIDSignIn.scheduleDeletion(", in: text) == 1)
        #expect(Self.count("requestAccountDeletion(", in: text) == 1, "one deletion request, the one behind the sheet")
        #expect(body.contains(
            "showsAppleManualStop = AppleIDSignIn.showsManualStopLine( isAppleAccount: appleAccount, " +
            "appleAuthorizationRevoked: appleAuthorizationRevoked )"))
    }

    @Test("The confirmation shows the manual steps and Apple's article only under the tested predicate, after the sign-out too")
    func manualStepsRenderGuard() throws {
        let text = try Self.source("TabMail/Views/Settings/AccountDeletionView.swift")
        // The shared confirmation shows the steps under its own flag only.
        let start = try #require(text.range(of: "struct AccountDeletionConfirmation: View {"))
        let end = try #require(text.range(of: "private struct BulletPoint: View {"))
        #expect(start.upperBound < end.lowerBound)
        guard start.upperBound < end.lowerBound else { return }
        let view = String(text[start.upperBound..<end.lowerBound])
        #expect(view.contains(
            "if showsAppleManualStop { VStack(spacing: 6) { Text(AccountDeletionCopy.appleSignInManualStop) " +
            ".font(.subheadline) .foregroundStyle(.secondary) .multilineTextAlignment(.center) " +
            "if let supportURL = URL(string: AccountDeletionCopy.appleSignInSupportURL) { " +
            "Link(\"How to stop using Sign in with Apple\", destination: supportURL)"))
        #expect(Self.count("showsAppleManualStop", in: view) == 2, "declared and the guard")
        #expect(Self.count("AccountDeletionCopy.appleSignInManualStop", in: text) == 1)
        #expect(Self.count("AccountDeletionCopy.appleSignInSupportURL", in: text) == 1)
        // The screen's flag starts false and is set only from the predicate, before the receipt is built, and
        // both confirmations get it: the screen's own (a failed sign-out) and the root's sheet (through the receipt).
        #expect(Self.count("showsAppleManualStop = ", in: text) == 2, "declared false, set only from the predicate")
        #expect(text.contains("@State private var showsAppleManualStop = false"))
        let body = try Self.body(of: "private func deleteAccount() async {", in: text)
        let decided = try #require(body.range(of: "showsAppleManualStop = AppleIDSignIn.showsManualStopLine("))
        let handed = try #require(body.range(of:
            "AccountDeletionReceipt.Receipt( scheduledDateText: scheduledDateText, " +
            "showsAppleManualStop: showsAppleManualStop )"))
        #expect(decided.upperBound < handed.lowerBound, "the receipt carries the decided flag")
        #expect(text.contains(
            "AccountDeletionConfirmation( scheduledDateText: scheduledDateText, " +
            "showsAppleManualStop: showsAppleManualStop, errorMessage: errorMessage )"))
        let root = try Self.source("TabMail/Views/RootView.swift")
        #expect(root.contains(
            "AccountDeletionConfirmation( scheduledDateText: receipt.scheduledDateText, " +
            "showsAppleManualStop: receipt.showsAppleManualStop, errorMessage: nil )"))
        #expect(Self.count("showsAppleManualStop", in: root) == 2, "one argument: the root only passes the receipt's flag on")
    }

    @Test("The form says Apple's sheet comes next only for an account that signed in with Apple")
    func appleNoticeOnlyForAppleAccounts() throws {
        let text = try Self.source("TabMail/Views/Settings/AccountDeletionView.swift")
        #expect(text.contains(
            "if isAppleAccount { GroupBox { Text(AccountDeletionCopy.appleSignInConfirmNotice)"))
        #expect(text.contains(
            ".task { isAppleAccount = AppleIDSignIn.isAppleAccount(accessToken: TabMailAuthService.getSession()?.accessToken) }"))
        #expect(Self.count("AccountDeletionCopy.appleSignInConfirmNotice", in: text) == 1, "no copy outside the guard")
    }

    @Test("The code is the credential's authorization code, never its identity token")
    func codeComesFromTheCredential() throws {
        let text = try Self.source("TabMail/Services/AppleIDSignIn.swift")
        #expect(text.contains(
            "static func authorizationCode(of result: ASAuthorizationResult) -> Data? { " +
            "guard case .appleID(let credential) = result else { return nil } return credential.authorizationCode }"))
    }

    @Test("The age screen sends at the failed check without a code and leaves through the tested refusal")
    func ageScreen() throws {
        let text = try Self.source("TabMail/Views/ConsentGateView.swift")
        #expect(text.contains(
            "@State private var refusalExit = AgeAndTermsConsent.RefusalExit(send: { appleAuthorizationCode in " +
            "await AgeAndTermsConsent.sendDeletionRequest(appleAuthorizationCode: appleAuthorizationCode) })"))
        let failed = try Self.body(of: "private func failAgeCheck() {", in: text)
        #expect(failed.contains("if persistsToBackend { refusalExit.requestDeletion() }"), "no sheet and no code at the failed check")
        let leave = try Self.body(of: "private func leave() {", in: text)
        #expect(leave.hasPrefix(
            " guard !isLeaving else { return } isLeaving = true errorMessage = nil Task { if persistsToBackend {"),
            "one OK at a time, and billing decides for every account kept in the backend")
        let signOut = try #require(leave.range(of: "await onIneligible()"))
        #expect(Self.count("onIneligible()", in: leave) == 1, "one sign-out")
        let snapshot = try #require(leave.range(
            of: "let appleAccount = AppleIDSignIn.isAppleAccount( accessToken: TabMailAuthService.getSession()?.accessToken )"))
        let decision = try #require(leave.range(of:
            "let handshake = await refusalExit.leave( isAppleAccount: appleAccount, " +
            "appleAuthorizationCode: { await AppleIDSignIn.freshAuthorizationCode(authorize: authorize) } )"))
        #expect(snapshot.lowerBound < decision.lowerBound, "the account is read before signing out can clear it")
        #expect(decision.upperBound < signOut.lowerBound, "signs out only after billing's decision")
        #expect(leave.contains(
            "let authorize: AppleIDSignIn.CodeAuthorization = { request in " +
            "AppleIDSignIn.authorizationCode(of: try await authorizationController.performRequest(request)) }"),
            "the sheet's code is the credential's authorization code")
        #expect(Self.count("identityToken(", in: text) == 0, "never the identity token")
        #expect(leave.contains(
            "guard handshake == .signOut else { errorMessage = \"We couldn\\u{2019}t reach TabMail. Check your connection, " +
            "then tap OK again.\" isLeaving = false return } } await onIneligible() isLeaving = false }"),
            "signs out only after a sign-out decision, and OK works again if signing out fails on the device")
        #expect(Self.count("refusalExit.", in: text) == 2, "the failed check and OK")
        #expect(Self.count("performRequest(", in: text) == 1, "one sheet")
        #expect(Self.count("authorize(", in: text) == 0, "the sheet is never run directly")
        #expect(Self.count("freshAuthorizationCode(", in: text) == 1, "only inside the refusal's decision")
        #expect(Self.count("sendDeletionRequest(", in: text) == 1)
        #expect(Self.count("requestAgeIneligibleDeletion(", in: text) == 0, "billing is reached only through the tested send")
    }
}
