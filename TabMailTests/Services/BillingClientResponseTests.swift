/* This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at https://mozilla.org/MPL/2.0/. */

import Testing
import Foundation
@testable import TabMail

@Suite("BillingClient.DeletionResponse Decodable")
struct DeletionResponseDecodableTests {

    @Test("Decodes scheduled response")
    func decodesScheduled() throws {
        let json = """
        {"status":"scheduled","deletion_date":"2026-03-21","requested_at":"2026-03-14T12:00:00Z"}
        """
        let response = try JSONDecoder().decode(BillingClient.DeletionResponse.self, from: Data(json.utf8))
        #expect(response.status == "scheduled")
        #expect(response.deletion_date == "2026-03-21")
        #expect(response.requested_at == "2026-03-14T12:00:00Z")
    }

    @Test("Decodes already_scheduled response")
    func decodesAlreadyScheduled() throws {
        let json = """
        {"status":"already_scheduled","deletion_date":"2026-03-21"}
        """
        let response = try JSONDecoder().decode(BillingClient.DeletionResponse.self, from: Data(json.utf8))
        #expect(response.status == "already_scheduled")
        #expect(response.requested_at == nil)
    }
}

@Suite("BillingClient.CancelDeletionResponse Decodable")
struct CancelDeletionResponseDecodableTests {

    @Test("Decodes restored response")
    func decodesRestored() throws {
        let json = #"{"status":"restored"}"#
        let response = try JSONDecoder().decode(BillingClient.CancelDeletionResponse.self, from: Data(json.utf8))
        #expect(response.status == "restored")
        #expect(response.error == nil)
        #expect(response.request_id == nil)
        #expect(response.subscription_outcome == nil)
        #expect(!response.subscriptionLapsedDuringGrace)
    }

    @Test("Decodes error response")
    func decodesError() throws {
        let json = #"{"error":"no pending deletion"}"#
        let response = try JSONDecoder().decode(BillingClient.CancelDeletionResponse.self, from: Data(json.utf8))
        #expect(response.status == nil)
        #expect(response.error == "no pending deletion")
        #expect(response.request_id == nil)
        #expect(response.subscription_outcome == nil)
        #expect(!response.subscriptionLapsedDuringGrace)
    }

    // These decoding-level tests pin the predicate consumed by RootView. They
    // do not render RootView or exercise the final SwiftUI alert/navigation hop.
    @Test("Flags only expired_during_grace")
    func flagsOnlyExpiredDuringGrace() throws {
        let lapsedJSON = #"{"status":"restored","subscription_outcome":"expired_during_grace"}"#
        let lapsed = try JSONDecoder().decode(
            BillingClient.CancelDeletionResponse.self,
            from: Data(lapsedJSON.utf8)
        )
        #expect(lapsed.subscription_outcome == "expired_during_grace")
        #expect(lapsed.subscriptionLapsedDuringGrace)

        for outcome in ["restored", "none", "unknown"] {
            let healthyJSON = #"{"status":"restored","subscription_outcome":"\#(outcome)"}"#
            let healthy = try JSONDecoder().decode(
                BillingClient.CancelDeletionResponse.self,
                from: Data(healthyJSON.utf8)
            )
            #expect(!healthy.subscriptionLapsedDuringGrace)
        }
    }

    @Test("Missing and null subscription outcomes are not flagged")
    func missingAndNullOutcomesAreNotFlagged() throws {
        for json in [
            #"{"status":"restored"}"#,
            #"{"status":"restored","subscription_outcome":null}"#
        ] {
            let response = try JSONDecoder().decode(
                BillingClient.CancelDeletionResponse.self,
                from: Data(json.utf8)
            )
            #expect(response.subscription_outcome == nil)
            #expect(!response.subscriptionLapsedDuringGrace)
        }
    }

    @Test("Unknown future outcome remains forward-compatible")
    func futureOutcomeRemainsForwardCompatible() throws {
        let json = #"{"status":"restored","subscription_outcome":"needs_manual_review","future_field":true}"#
        let response = try JSONDecoder().decode(
            BillingClient.CancelDeletionResponse.self,
            from: Data(json.utf8)
        )
        #expect(response.status == "restored")
        #expect(response.subscription_outcome == "needs_manual_review")
        #expect(!response.subscriptionLapsedDuringGrace)
    }
}

@Suite("BillingClient.DeletionStatusResponse Decodable")
struct DeletionStatusResponseDecodableTests {

    @Test("Decodes pending=true with date")
    func decodesPendingTrue() throws {
        let requestId = "11111111-1111-4111-8111-111111111111"
        let json = #"{"pending":true,"deletion_date":"2026-03-21","request_id":"\#(requestId)"}"#
        let response = try JSONDecoder().decode(BillingClient.DeletionStatusResponse.self, from: Data(json.utf8))
        #expect(response.pending == true)
        #expect(response.deletion_date == "2026-03-21")
        #expect(response.request_id == requestId)
    }

    @Test("Decodes pending=false without date")
    func decodesPendingFalse() throws {
        let json = #"{"pending":false}"#
        let response = try JSONDecoder().decode(BillingClient.DeletionStatusResponse.self, from: Data(json.utf8))
        #expect(response.pending == false)
        #expect(response.deletion_date == nil)
        #expect(response.request_id == nil)
    }
}

@Suite("Exact account deletion cancellation", .serialized)
@MainActor
struct ExactAccountDeletionCancellationTests {
    private let requestId = "11111111-1111-4111-8111-111111111111"

    @Test("Uses the exact path and request-id JSON body")
    func exactPathAndBody() throws {
        let request = try BillingClient.makeCancelAccountDeletionRequest(
            baseURL: try #require(URL(string: "https://billing.example.com")),
            token: "test-token",
            requestId: requestId
        )

        #expect(request.url?.path == "/account/cancel-deletion/exact")
        #expect(request.httpMethod == "POST")
        #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer test-token")
        #expect(request.value(forHTTPHeaderField: "Content-Type") == "application/json")

        let data = try #require(request.httpBody)
        let object = try #require(JSONSerialization.jsonObject(with: data) as? [String: String])
        #expect(object == ["request_id": requestId])
    }

    @Test("A matching restored receipt clears the banner and preserves its additive outcome")
    func matchingReceiptClearsBanner() async {
        var callCount = 0
        let result = await BillingClient.matchingCancelAccountDeletionReceipt(requestId: requestId) { receivedId in
            callCount += 1
            #expect(receivedId == requestId)
            let json = """
            {"status":"restored","request_id":"\(requestId)","subscription_outcome":"expired_during_grace"}
            """
            let data = Data(json.utf8)
            return try BillingClient.decodeCancelAccountDeletionResponse(statusCode: 200, data: data)
        }

        #expect(callCount == 1)
        #expect(result?.status == "restored")
        #expect(result?.request_id == requestId)
        #expect(result?.subscriptionLapsedDuringGrace == true)
    }

    @Test("Missing and invalid request ids retain the banner without a cancellation call")
    func missingAndInvalidRequestIdsRetainBanner() async {
        for candidate in [nil, "not-a-uuid"] as [String?] {
            var callCount = 0
            let result = await BillingClient.matchingCancelAccountDeletionReceipt(requestId: candidate) { _ in
                callCount += 1
                return try BillingClient.decodeCancelAccountDeletionResponse(
                    statusCode: 200,
                    data: Data(#"{"status":"restored"}"#.utf8)
                )
            }
            #expect(callCount == 0)
            #expect(result == nil)
        }
    }

    @Test("Every non-2xx response retains the banner")
    func nonSuccessResponsesRetainBanner() async {
        for statusCode in [404, 409, 500] {
            let result = await BillingClient.matchingCancelAccountDeletionReceipt(requestId: requestId) { _ in
                try BillingClient.decodeCancelAccountDeletionResponse(
                    statusCode: statusCode,
                    data: Data(#"{"error":"not_restored"}"#.utf8)
                )
            }
            #expect(result == nil, "HTTP \(statusCode) must retain the banner")
        }
    }

    @Test("Malformed or incomplete success payloads retain the banner")
    func malformedPayloadsRetainBanner() async {
        let payloads = [
            #"{"status":123,"request_id":"11111111-1111-4111-8111-111111111111"}"#,
            #"{"status":"restored"}"#,
            #"{"status":"unexpected","request_id":"11111111-1111-4111-8111-111111111111"}"#
        ]

        for payload in payloads {
            let result = await BillingClient.matchingCancelAccountDeletionReceipt(requestId: requestId) { _ in
                try BillingClient.decodeCancelAccountDeletionResponse(
                    statusCode: 200,
                    data: Data(payload.utf8)
                )
            }
            #expect(result == nil)
        }
    }

    @Test("A restored receipt for a different request retains the banner")
    func mismatchedReceiptRetainsBanner() async {
        let otherRequestId = "22222222-2222-4222-8222-222222222222"
        let result = await BillingClient.matchingCancelAccountDeletionReceipt(requestId: requestId) { _ in
            try BillingClient.decodeCancelAccountDeletionResponse(
                statusCode: 200,
                data: Data(#"{"status":"restored","request_id":"\#(otherRequestId)"}"#.utf8)
            )
        }
        #expect(result == nil)
    }

    @Test("A network failure retains the banner")
    func networkFailureRetainsBanner() async {
        let result = await BillingClient.matchingCancelAccountDeletionReceipt(requestId: requestId) { _ in
            throw URLError(.notConnectedToInternet)
        }
        #expect(result == nil)
    }
}
