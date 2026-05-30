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
    }

    @Test("Decodes error response")
    func decodesError() throws {
        let json = #"{"error":"no pending deletion"}"#
        let response = try JSONDecoder().decode(BillingClient.CancelDeletionResponse.self, from: Data(json.utf8))
        #expect(response.status == nil)
        #expect(response.error == "no pending deletion")
    }
}

@Suite("BillingClient.DeletionStatusResponse Decodable")
struct DeletionStatusResponseDecodableTests {

    @Test("Decodes pending=true with date")
    func decodesPendingTrue() throws {
        let json = #"{"pending":true,"deletion_date":"2026-03-21"}"#
        let response = try JSONDecoder().decode(BillingClient.DeletionStatusResponse.self, from: Data(json.utf8))
        #expect(response.pending == true)
        #expect(response.deletion_date == "2026-03-21")
    }

    @Test("Decodes pending=false without date")
    func decodesPendingFalse() throws {
        let json = #"{"pending":false}"#
        let response = try JSONDecoder().decode(BillingClient.DeletionStatusResponse.self, from: Data(json.utf8))
        #expect(response.pending == false)
        #expect(response.deletion_date == nil)
    }
}
