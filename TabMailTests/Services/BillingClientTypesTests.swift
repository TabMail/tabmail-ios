/* This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at https://mozilla.org/MPL/2.0/. */

import Testing
import Foundation
@testable import TabMail

@Suite("BillingClient Codable Types")
struct BillingClientTypesTests {

    // MARK: - DeletionResponse

    @Test("DeletionResponse decodes with all fields")
    func decodeDeletionResponse() throws {
        let json = """
        {"status": "scheduled", "deletion_date": "2024-04-15T00:00:00Z", "requested_at": "2024-03-15T10:00:00Z"}
        """.data(using: .utf8)!
        let r = try JSONDecoder().decode(BillingClient.DeletionResponse.self, from: json)
        #expect(r.status == "scheduled")
        #expect(r.deletion_date == "2024-04-15T00:00:00Z")
        #expect(r.requested_at == "2024-03-15T10:00:00Z")
    }

    @Test("DeletionResponse decodes already_scheduled status")
    func decodeDeletionResponseAlreadyScheduled() throws {
        let json = """
        {"status": "already_scheduled", "deletion_date": "2024-04-15T00:00:00Z", "requested_at": null}
        """.data(using: .utf8)!
        let r = try JSONDecoder().decode(BillingClient.DeletionResponse.self, from: json)
        #expect(r.status == "already_scheduled")
        #expect(r.requested_at == nil)
    }

    @Test("DeletionResponse with missing optional requested_at")
    func decodeDeletionResponseMissingOptional() throws {
        let json = """
        {"status": "scheduled", "deletion_date": "2024-05-01T00:00:00Z"}
        """.data(using: .utf8)!
        let r = try JSONDecoder().decode(BillingClient.DeletionResponse.self, from: json)
        #expect(r.requested_at == nil)
        #expect(r.deletion_date == "2024-05-01T00:00:00Z")
    }

    // MARK: - CancelDeletionResponse

    @Test("CancelDeletionResponse decodes restored status")
    func decodeCancelDeletionRestored() throws {
        let json = """
        {"status": "restored", "error": null}
        """.data(using: .utf8)!
        let r = try JSONDecoder().decode(BillingClient.CancelDeletionResponse.self, from: json)
        #expect(r.status == "restored")
        #expect(r.error == nil)
    }

    @Test("CancelDeletionResponse decodes error")
    func decodeCancelDeletionError() throws {
        let json = """
        {"status": null, "error": "No pending deletion found"}
        """.data(using: .utf8)!
        let r = try JSONDecoder().decode(BillingClient.CancelDeletionResponse.self, from: json)
        #expect(r.status == nil)
        #expect(r.error == "No pending deletion found")
    }

    @Test("CancelDeletionResponse with both fields null")
    func decodeCancelDeletionBothNull() throws {
        let json = """
        {"status": null, "error": null}
        """.data(using: .utf8)!
        let r = try JSONDecoder().decode(BillingClient.CancelDeletionResponse.self, from: json)
        #expect(r.status == nil)
        #expect(r.error == nil)
    }

    // MARK: - DeletionStatusResponse

    @Test("DeletionStatusResponse with pending deletion")
    func decodeDeletionStatusPending() throws {
        let json = """
        {"pending": true, "deletion_date": "2024-04-15T00:00:00Z"}
        """.data(using: .utf8)!
        let r = try JSONDecoder().decode(BillingClient.DeletionStatusResponse.self, from: json)
        #expect(r.pending == true)
        #expect(r.deletion_date == "2024-04-15T00:00:00Z")
    }

    @Test("DeletionStatusResponse with no pending deletion")
    func decodeDeletionStatusNoPending() throws {
        let json = """
        {"pending": false, "deletion_date": null}
        """.data(using: .utf8)!
        let r = try JSONDecoder().decode(BillingClient.DeletionStatusResponse.self, from: json)
        #expect(r.pending == false)
        #expect(r.deletion_date == nil)
    }

    @Test("DeletionStatusResponse with missing optional field")
    func decodeDeletionStatusMissingOptional() throws {
        let json = """
        {"pending": false}
        """.data(using: .utf8)!
        let r = try JSONDecoder().decode(BillingClient.DeletionStatusResponse.self, from: json)
        #expect(r.pending == false)
        #expect(r.deletion_date == nil)
    }
}
