/* This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at https://mozilla.org/MPL/2.0/. */

import Testing
import Foundation
@testable import TabMail

@Suite("BackendError Extended")
struct BackendErrorExtendedTests {

    // MARK: - 403 Backoff Behavior

    @Test("forbidden errorDescription mentions 403")
    func forbiddenDescription() {
        let desc = BackendError.forbidden.errorDescription!
        #expect(desc.contains("403"))
    }

    @Test("accountGone errorDescription is descriptive")
    func accountGoneDescription() {
        let desc = BackendError.accountGone.errorDescription!
        #expect(!desc.isEmpty)
    }

    @Test("unauthorized errorDescription mentions 401")
    func unauthorizedDescription() {
        let desc = BackendError.unauthorized.errorDescription!
        #expect(desc.contains("401"))
    }

    // MARK: - isRetriable boundary cases

    @Test("499 is not retriable (unknown 4xx)")
    func status499NotRetriable() {
        #expect(BackendError.requestFailed(statusCode: 499).isRetriable == false)
    }

    @Test("504 gateway timeout is retriable (5xx)")
    func status504Retriable() {
        #expect(BackendError.requestFailed(statusCode: 504).isRetriable == true)
    }

    @Test("599 is retriable (5xx)")
    func status599Retriable() {
        #expect(BackendError.requestFailed(statusCode: 599).isRetriable == true)
    }

    @Test("600 is not retriable (outside 5xx range)")
    func status600NotRetriable() {
        #expect(BackendError.requestFailed(statusCode: 600).isRetriable == false)
    }

    @Test("200 is not retriable (success codes shouldn't be errors)")
    func status200NotRetriable() {
        #expect(BackendError.requestFailed(statusCode: 200).isRetriable == false)
    }

    @Test("requestFailed description includes status code")
    func requestFailedDescriptionIncludesCode() {
        let errors: [Int] = [400, 404, 429, 500, 502, 503]
        for code in errors {
            let desc = BackendError.requestFailed(statusCode: code).errorDescription!
            #expect(desc.contains("\(code)"))
        }
    }

    // MARK: - streamTruncated (connection-lost / resume)

    @Test("streamTruncated is NOT auto-retriable (manual tap-to-retry only)")
    func streamTruncatedNotRetriable() {
        // If this flips to true, a retry path keyed on isRetriable would
        // silently auto-retry truncations, and the agent-chat tool loop's
        // conversion to a resumable ChatConnectionLostError could be bypassed.
        #expect(BackendError.streamTruncated.isRetriable == false)
    }

    @Test("streamTruncated errorDescription is descriptive")
    func streamTruncatedDescription() {
        let desc = BackendError.streamTruncated.errorDescription!
        #expect(!desc.isEmpty)
    }

    /// A connection-lost error's round request, with marker values in every place a
    /// request holds text: the message, its variables, each tier's settings, and the
    /// continuation of the earlier rounds (a tool's result and the model's thinking).
    private static func connectionLostRequest(marker: String) -> CompletionsRequest {
        let tier = BYOKTierConfig(provider: "openai", api_key: "fixture-key-\(marker)", model: "fixture-model-\(marker)")
        let earlierRounds = ConversationState(
            harmony_messages: [
                HarmonyMessage(role: "assistant", content: nil, thinking: "fixture thinking \(marker)",
                               tool_calls: nil, tool_call_id: nil),
                HarmonyMessage(role: "tool", content: "fixture tool result \(marker)", thinking: nil,
                               tool_calls: nil, tool_call_id: "call-\(marker)"),
            ],
            current_round: 2)
        return CompletionsRequest(
            messages: [CompletionsMessage(role: "user", content: "fixture prompt \(marker)",
                                          vars: ["email_body": .string("fixture body \(marker)")])],
            client_timezone: "UTC", disable_tools: nil,
            conversation_state: earlierRounds,
            byok: BYOKConfig(background: tier, interactive: tier))
    }

    @Test("Connection-lost error descriptions stay short and fixed")
    func connectionLostDescriptionsStayFixed() {
        let marker = "Qz7k"
        let error = ChatConnectionLostError(resumeRequest: Self.connectionLostRequest(marker: marker))
        // Control: the error keeps the whole request, and the request's own text holds the markers.
        let requestText = String(describing: error.resumeRequest)
        let keptMarkers = ["fixture-key-\(marker)", "fixture prompt \(marker)", "fixture body \(marker)",
                           "fixture thinking \(marker)", "fixture tool result \(marker)"]
        for kept in keptMarkers {
            let isKept = requestText.contains(kept)
            #expect(isKept, "control: the request the error keeps holds \(kept)")
        }

        let asError: any Error = error
        let renderings = [
            "\(error)",
            String(describing: error),
            String(reflecting: error),
            "\(asError)",
            String(describing: asError),
            String(reflecting: asError),
            error.localizedDescription,
            asError.localizedDescription,
            "\(asError as NSError)",
            (asError as NSError).debugDescription,
        ]
        for text in renderings {
            let holdsMarker = text.contains(marker)
            #expect(!holdsMarker, "an error's text names no part of its request: \(text.prefix(160))")
        }

        // Fixed: another request gives the same text.
        let other = ChatConnectionLostError(resumeRequest: Self.connectionLostRequest(marker: "Wx9m"))
        #expect(String(describing: other) == String(describing: error))
        #expect(String(reflecting: other) == String(reflecting: error))
    }

    // MARK: - Error conformance

    @Test("BackendError conforms to LocalizedError")
    func conformsToLocalizedError() {
        let error: any LocalizedError = BackendError.unauthorized
        #expect(error.errorDescription != nil)
    }

    @Test("BackendError conforms to Error")
    func conformsToError() {
        let error: any Error = BackendError.requestFailed(statusCode: 500)
        #expect(error.localizedDescription.contains("500"))
    }
}
