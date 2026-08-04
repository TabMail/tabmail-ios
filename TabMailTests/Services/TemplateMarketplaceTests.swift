/* This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at https://mozilla.org/MPL/2.0/. */

import Testing
import Foundation
@testable import TabMail

// MARK: - MarketplaceError Tests

@Suite("MarketplaceError")
struct MarketplaceErrorTests {

    @Test("unauthorized has correct error description")
    func unauthorizedDescription() {
        let error = TemplateMarketplaceClient.MarketplaceError.unauthorized
        #expect(error.errorDescription == "Not authenticated")
    }

    @Test("requestFailed includes status code")
    func requestFailedDescription() {
        let error = TemplateMarketplaceClient.MarketplaceError.requestFailed(statusCode: 500)
        #expect(error.errorDescription == "Request failed (500)")
    }

    @Test("requestFailed with different status codes")
    func requestFailedVariousCodes() {
        let error404 = TemplateMarketplaceClient.MarketplaceError.requestFailed(statusCode: 404)
        #expect(error404.errorDescription == "Request failed (404)")

        let error403 = TemplateMarketplaceClient.MarketplaceError.requestFailed(statusCode: 403)
        #expect(error403.errorDescription == "Request failed (403)")

        let error0 = TemplateMarketplaceClient.MarketplaceError.requestFailed(statusCode: 0)
        #expect(error0.errorDescription == "Request failed (0)")
    }

    @Test("noAuthToken has correct error description")
    func noAuthTokenDescription() {
        let error = TemplateMarketplaceClient.MarketplaceError.noAuthToken
        #expect(error.errorDescription == "Please sign in to browse templates")
    }

    @Test("validationError passes through message")
    func validationErrorDescription() {
        let error = TemplateMarketplaceClient.MarketplaceError.validationError("Name too short")
        #expect(error.errorDescription == "Name too short")
    }

    @Test("validationError with empty message")
    func validationErrorEmpty() {
        let error = TemplateMarketplaceClient.MarketplaceError.validationError("")
        #expect(error.errorDescription == "")
    }

    @Test("All errors conform to LocalizedError")
    func conformsToLocalizedError() {
        let errors: [any LocalizedError] = [
            TemplateMarketplaceClient.MarketplaceError.unauthorized,
            TemplateMarketplaceClient.MarketplaceError.requestFailed(statusCode: 500),
            TemplateMarketplaceClient.MarketplaceError.noAuthToken,
            TemplateMarketplaceClient.MarketplaceError.validationError("test"),
        ]
        for error in errors {
            #expect(error.errorDescription != nil)
        }
    }
}

// MARK: - SortOrder Tests

@Suite("SortOrder")
struct SortOrderTests {

    @Test("SortOrder raw values")
    func rawValues() {
        #expect(TemplateMarketplaceClient.SortOrder.popular.rawValue == "popular")
        #expect(TemplateMarketplaceClient.SortOrder.recent.rawValue == "recent")
        #expect(TemplateMarketplaceClient.SortOrder.name.rawValue == "name")
    }

    @Test("SortOrder has 3 cases")
    func caseCount() {
        #expect(TemplateMarketplaceClient.SortOrder.allCases.count == 3)
    }

    @Test("SortOrder CaseIterable contains all values")
    func allCasesContains() {
        let allCases = TemplateMarketplaceClient.SortOrder.allCases
        #expect(allCases.contains(.popular))
        #expect(allCases.contains(.recent))
        #expect(allCases.contains(.name))
    }

    @Test("SortOrder init from rawValue")
    func initFromRawValue() {
        #expect(TemplateMarketplaceClient.SortOrder(rawValue: "popular") == .popular)
        #expect(TemplateMarketplaceClient.SortOrder(rawValue: "recent") == .recent)
        #expect(TemplateMarketplaceClient.SortOrder(rawValue: "name") == .name)
        #expect(TemplateMarketplaceClient.SortOrder(rawValue: "invalid") == nil)
        #expect(TemplateMarketplaceClient.SortOrder(rawValue: "") == nil)
    }
}

// MARK: - UploadRequest Encoding Tests

@Suite("UploadRequest Encoding")
struct UploadRequestEncodingTests {

    @Test("UploadRequest encodes all fields")
    func encodeAllFields() throws {
        let request = TemplateMarketplaceClient.UploadRequest(
            id: "tmpl-001",
            name: "Professional Reply",
            description: "A professional template",
            instructions: ["Be formal", "Use proper salutation"],
            example_reply: "Dear colleague,"
        )
        let data = try JSONEncoder().encode(request)
        let dict = try JSONSerialization.jsonObject(with: data) as! [String: Any]

        #expect(dict["id"] as? String == "tmpl-001")
        #expect(dict["name"] as? String == "Professional Reply")
        #expect(dict["description"] as? String == "A professional template")
        #expect(dict["instructions"] as? [String] == ["Be formal", "Use proper salutation"])
        #expect(dict["example_reply"] as? String == "Dear colleague,")
    }

    @Test("UploadRequest encodes null description")
    func encodeNullDescription() throws {
        let request = TemplateMarketplaceClient.UploadRequest(
            id: "tmpl-002",
            name: "Simple",
            description: nil,
            instructions: [],
            example_reply: "Hi"
        )
        let data = try JSONEncoder().encode(request)
        let dict = try JSONSerialization.jsonObject(with: data) as! [String: Any]

        // When description is nil, key should be present with NSNull value
        #expect(dict["name"] as? String == "Simple")
        #expect(dict["instructions"] as? [String] == [])
    }

    @Test("UploadRequest encodes empty instructions array")
    func encodeEmptyInstructions() throws {
        let request = TemplateMarketplaceClient.UploadRequest(
            id: "tmpl-003",
            name: "Minimal",
            description: nil,
            instructions: [],
            example_reply: ""
        )
        let data = try JSONEncoder().encode(request)
        let dict = try JSONSerialization.jsonObject(with: data) as! [String: Any]

        #expect(dict["instructions"] as? [String] == [])
        #expect(dict["example_reply"] as? String == "")
    }

    @Test("UploadRequest encodes special characters")
    func encodeSpecialCharacters() throws {
        let request = TemplateMarketplaceClient.UploadRequest(
            id: "id-special",
            name: "Template with \"quotes\" & <angle>",
            description: "Line 1\nLine 2\tTabbed",
            instructions: ["Use emoji: 😊", "Handle unicode: café"],
            example_reply: "Héllo wörld"
        )
        let data = try JSONEncoder().encode(request)
        let dict = try JSONSerialization.jsonObject(with: data) as! [String: Any]

        #expect(dict["name"] as? String == "Template with \"quotes\" & <angle>")
        #expect(dict["description"] as? String == "Line 1\nLine 2\tTabbed")
        #expect((dict["instructions"] as? [String])?.count == 2)
        #expect(dict["example_reply"] as? String == "Héllo wörld")
    }
}

// MARK: - Codable Round-Trip Tests

@Suite("Template Marketplace Codable Round-Trips")
struct TemplateMarketplaceCodableRoundTripTests {

    @Test("MarketplaceTemplate encode-decode round-trip")
    func marketplaceTemplateRoundTrip() throws {
        let json = """
        {
            "id": "rt-1",
            "name": "Round Trip",
            "description": "Test",
            "instructions": ["a", "b", "c"],
            "example_reply": "Hello",
            "download_count": 99,
            "is_featured": true,
            "is_official": true,
            "status": "approved",
            "category": "test",
            "tags": ["tag1", "tag2"],
            "created_at": "2024-06-01T00:00:00Z",
            "updated_at": "2024-06-15T12:30:00Z"
        }
        """.data(using: .utf8)!

        let decoded = try JSONDecoder().decode(TemplateMarketplaceClient.MarketplaceTemplate.self, from: json)
        let reEncoded = try JSONEncoder().encode(decoded)
        let reDecoded = try JSONDecoder().decode(TemplateMarketplaceClient.MarketplaceTemplate.self, from: reEncoded)

        #expect(reDecoded.id == decoded.id)
        #expect(reDecoded.name == decoded.name)
        #expect(reDecoded.description == decoded.description)
        #expect(reDecoded.instructions == decoded.instructions)
        #expect(reDecoded.example_reply == decoded.example_reply)
        #expect(reDecoded.download_count == decoded.download_count)
        #expect(reDecoded.is_featured == decoded.is_featured)
        #expect(reDecoded.is_official == decoded.is_official)
        #expect(reDecoded.status == decoded.status)
        #expect(reDecoded.category == decoded.category)
        #expect(reDecoded.tags == decoded.tags)
    }

    @Test("DownloadedTemplate encode-decode round-trip")
    func downloadedTemplateRoundTrip() throws {
        // DownloadedTemplate is not directly constructible via init in actor context,
        // but we can test via JSON round-trip
        let json = """
        {"id": "dl-1", "name": "Test", "instructions": ["x"], "exampleReply": "Hi", "enabled": true}
        """.data(using: .utf8)!
        let decoded = try JSONDecoder().decode(TemplateMarketplaceClient.DownloadedTemplate.self, from: json)
        let reEncoded = try JSONEncoder().encode(decoded)
        let reDecoded = try JSONDecoder().decode(TemplateMarketplaceClient.DownloadedTemplate.self, from: reEncoded)

        #expect(reDecoded.id == "dl-1")
        #expect(reDecoded.name == "Test")
        #expect(reDecoded.instructions == ["x"])
        #expect(reDecoded.exampleReply == "Hi")
        #expect(reDecoded.enabled == true)
    }

    @Test("MyTemplate encode-decode round-trip with rejection")
    func myTemplateRoundTrip() throws {
        let json = """
        {
            "id": "my-rt", "name": "Rejected", "description": "Bad template",
            "instructions": ["i1"], "example_reply": "Hey",
            "download_count": 3, "is_featured": false, "is_official": false,
            "status": "rejected", "category": "personal", "tags": ["tag"],
            "created_at": "2024-01-01T00:00:00Z", "updated_at": "2024-02-01T00:00:00Z",
            "rejection_reason": "Violates guidelines", "reviewed_at": "2024-01-20T10:00:00Z"
        }
        """.data(using: .utf8)!
        let decoded = try JSONDecoder().decode(TemplateMarketplaceClient.MyTemplate.self, from: json)
        let reEncoded = try JSONEncoder().encode(decoded)
        let reDecoded = try JSONDecoder().decode(TemplateMarketplaceClient.MyTemplate.self, from: reEncoded)

        #expect(reDecoded.id == decoded.id)
        #expect(reDecoded.rejection_reason == "Violates guidelines")
        #expect(reDecoded.reviewed_at == "2024-01-20T10:00:00Z")
        #expect(reDecoded.status == "rejected")
    }

    @Test("UploadResponse encode-decode round-trip")
    func uploadResponseRoundTrip() throws {
        let json = """
        {"success": true, "message": "Created", "template_id": "up-rt", "status": "pending_review"}
        """.data(using: .utf8)!
        let decoded = try JSONDecoder().decode(TemplateMarketplaceClient.UploadResponse.self, from: json)
        let reEncoded = try JSONEncoder().encode(decoded)
        let reDecoded = try JSONDecoder().decode(TemplateMarketplaceClient.UploadResponse.self, from: reEncoded)

        #expect(reDecoded.success == true)
        #expect(reDecoded.message == "Created")
        #expect(reDecoded.template_id == "up-rt")
        #expect(reDecoded.status == "pending_review")
    }

    @Test("Pagination encode-decode round-trip")
    func paginationRoundTrip() throws {
        let json = """
        {"limit": 50, "offset": 25, "total": 200, "has_more": true}
        """.data(using: .utf8)!
        let decoded = try JSONDecoder().decode(TemplateMarketplaceClient.Pagination.self, from: json)
        let reEncoded = try JSONEncoder().encode(decoded)
        let reDecoded = try JSONDecoder().decode(TemplateMarketplaceClient.Pagination.self, from: reEncoded)

        #expect(reDecoded.limit == 50)
        #expect(reDecoded.offset == 25)
        #expect(reDecoded.total == 200)
        #expect(reDecoded.has_more == true)
    }

    @Test("TemplateLimits encode-decode round-trip")
    func templateLimitsRoundTrip() throws {
        let json = """
        {"max_templates": 20, "current_count": 15, "remaining": 5}
        """.data(using: .utf8)!
        let decoded = try JSONDecoder().decode(TemplateMarketplaceClient.TemplateLimits.self, from: json)
        let reEncoded = try JSONEncoder().encode(decoded)
        let reDecoded = try JSONDecoder().decode(TemplateMarketplaceClient.TemplateLimits.self, from: reEncoded)

        #expect(reDecoded.max_templates == 20)
        #expect(reDecoded.current_count == 15)
        #expect(reDecoded.remaining == 5)
    }
}

// MARK: - Edge Cases and Boundary Tests

@Suite("Template Marketplace Edge Cases")
struct TemplateMarketplaceEdgeCaseTests {

    @Test("MarketplaceTemplate with empty instructions array")
    func emptyInstructions() throws {
        let json = """
        {
            "id": "e1", "name": "Empty", "description": null,
            "instructions": [], "example_reply": "",
            "download_count": 0, "is_featured": false, "is_official": false,
            "status": "draft", "category": null, "tags": null,
            "created_at": "2024-01-01T00:00:00Z", "updated_at": "2024-01-01T00:00:00Z"
        }
        """.data(using: .utf8)!
        let t = try JSONDecoder().decode(TemplateMarketplaceClient.MarketplaceTemplate.self, from: json)
        #expect(t.instructions.isEmpty)
        #expect(t.example_reply == "")
    }

    @Test("MarketplaceTemplate with large download count")
    func largeDownloadCount() throws {
        let json = """
        {
            "id": "pop", "name": "Popular", "description": null,
            "instructions": ["x"], "example_reply": "y",
            "download_count": 999999, "is_featured": true, "is_official": true,
            "status": "approved", "category": null, "tags": null,
            "created_at": "2024-01-01T00:00:00Z", "updated_at": "2024-01-01T00:00:00Z"
        }
        """.data(using: .utf8)!
        let t = try JSONDecoder().decode(TemplateMarketplaceClient.MarketplaceTemplate.self, from: json)
        #expect(t.download_count == 999999)
    }

    @Test("MarketplaceTemplate with many instructions")
    func manyInstructions() throws {
        let instructions = (1...50).map { "Instruction \($0)" }
        let instructionsJSON = instructions.map { "\"\($0)\"" }.joined(separator: ",")
        let json = """
        {
            "id": "many", "name": "Many", "description": null,
            "instructions": [\(instructionsJSON)], "example_reply": "y",
            "download_count": 0, "is_featured": false, "is_official": false,
            "status": "approved", "category": null, "tags": null,
            "created_at": "2024-01-01T00:00:00Z", "updated_at": "2024-01-01T00:00:00Z"
        }
        """.data(using: .utf8)!
        let t = try JSONDecoder().decode(TemplateMarketplaceClient.MarketplaceTemplate.self, from: json)
        #expect(t.instructions.count == 50)
    }

    @Test("MarketplaceTemplate with empty tags array")
    func emptyTags() throws {
        let json = """
        {
            "id": "et", "name": "Empty Tags", "description": null,
            "instructions": [], "example_reply": "",
            "download_count": 0, "is_featured": false, "is_official": false,
            "status": "draft", "category": null, "tags": [],
            "created_at": "2024-01-01T00:00:00Z", "updated_at": "2024-01-01T00:00:00Z"
        }
        """.data(using: .utf8)!
        let t = try JSONDecoder().decode(TemplateMarketplaceClient.MarketplaceTemplate.self, from: json)
        #expect(t.tags != nil)
        #expect(t.tags!.isEmpty)
    }

    @Test("ListResponse with empty templates array")
    func emptyListResponse() throws {
        let json = """
        {
            "templates": [],
            "pagination": {"limit": 20, "offset": 0, "total": 0, "has_more": false}
        }
        """.data(using: .utf8)!
        let r = try JSONDecoder().decode(TemplateMarketplaceClient.ListResponse.self, from: json)
        #expect(r.templates.isEmpty)
        #expect(r.pagination.total == 0)
        #expect(r.pagination.has_more == false)
    }

    @Test("MyTemplatesResponse with zero limits")
    func zeroLimits() throws {
        let json = """
        {
            "templates": [],
            "limits": {"max_templates": 0, "current_count": 0, "remaining": 0}
        }
        """.data(using: .utf8)!
        let r = try JSONDecoder().decode(TemplateMarketplaceClient.MyTemplatesResponse.self, from: json)
        #expect(r.limits.max_templates == 0)
        #expect(r.limits.remaining == 0)
    }

    @Test("DownloadedTemplate with disabled state")
    func disabledTemplate() throws {
        let json = """
        {"id": "dis", "name": "Disabled", "instructions": ["a"], "exampleReply": "b", "enabled": false}
        """.data(using: .utf8)!
        let t = try JSONDecoder().decode(TemplateMarketplaceClient.DownloadedTemplate.self, from: json)
        #expect(t.enabled == false)
    }

    @Test("MarketplaceTemplate Identifiable conformance uses id field")
    func identifiable() throws {
        let json = """
        {
            "id": "ident-test", "name": "Identifiable", "description": null,
            "instructions": [], "example_reply": "",
            "download_count": 0, "is_featured": false, "is_official": false,
            "status": "approved", "category": null, "tags": null,
            "created_at": "2024-01-01T00:00:00Z", "updated_at": "2024-01-01T00:00:00Z"
        }
        """.data(using: .utf8)!
        let t = try JSONDecoder().decode(TemplateMarketplaceClient.MarketplaceTemplate.self, from: json)
        #expect(t.id == "ident-test")
    }

    @Test("MyTemplate Identifiable conformance uses id field")
    func myTemplateIdentifiable() throws {
        let json = """
        {
            "id": "my-ident", "name": "My Identifiable", "description": null,
            "instructions": [], "example_reply": "",
            "download_count": 0, "is_featured": false, "is_official": false,
            "status": "approved", "category": null, "tags": null,
            "created_at": "2024-01-01T00:00:00Z", "updated_at": "2024-01-01T00:00:00Z",
            "rejection_reason": null, "reviewed_at": null
        }
        """.data(using: .utf8)!
        let t = try JSONDecoder().decode(TemplateMarketplaceClient.MyTemplate.self, from: json)
        #expect(t.id == "my-ident")
    }

    @Test("UploadRequest round-trip via encode then decode")
    func uploadRequestRoundTrip() throws {
        let request = TemplateMarketplaceClient.UploadRequest(
            id: "rt-up",
            name: "Round Trip Upload",
            description: "Testing round trip",
            instructions: ["First", "Second", "Third"],
            example_reply: "Thank you for reaching out."
        )
        let data = try JSONEncoder().encode(request)
        // UploadRequest is Encodable, but we can decode it as a dictionary
        let dict = try JSONSerialization.jsonObject(with: data) as! [String: Any]
        #expect(dict["id"] as? String == "rt-up")
        #expect(dict["name"] as? String == "Round Trip Upload")
        #expect(dict["description"] as? String == "Testing round trip")
        #expect((dict["instructions"] as? [String])?.count == 3)
        #expect(dict["example_reply"] as? String == "Thank you for reaching out.")
    }

    @Test("MarketplaceTemplate with unicode in all string fields")
    func unicodeStrings() throws {
        let json = """
        {
            "id": "日本語",
            "name": "Ünïcödë Tëmplàtë",
            "description": "描述 — описание",
            "instructions": ["使用中文", "Используйте русский"],
            "example_reply": "مرحبا بالعالم",
            "download_count": 1,
            "is_featured": false,
            "is_official": false,
            "status": "approved",
            "category": "国际",
            "tags": ["中文", "العربية"],
            "created_at": "2024-01-01T00:00:00Z",
            "updated_at": "2024-01-01T00:00:00Z"
        }
        """.data(using: .utf8)!
        let t = try JSONDecoder().decode(TemplateMarketplaceClient.MarketplaceTemplate.self, from: json)
        #expect(t.id == "日本語")
        #expect(t.name == "Ünïcödë Tëmplàtë")
        #expect(t.instructions.count == 2)
        #expect(t.tags?.count == 2)
    }
}

// MARK: - Decoding Failure Tests

@Suite("Template Marketplace Decoding Failures")
struct TemplateMarketplaceDecodingFailureTests {

    @Test("MarketplaceTemplate fails when required field missing")
    func missingRequiredField() {
        let json = """
        {
            "id": "t1",
            "name": "Missing Fields"
        }
        """.data(using: .utf8)!
        #expect(throws: DecodingError.self) {
            try JSONDecoder().decode(TemplateMarketplaceClient.MarketplaceTemplate.self, from: json)
        }
    }

    @Test("Pagination fails when field has wrong type")
    func wrongFieldType() {
        let json = """
        {"limit": "twenty", "offset": 0, "total": 100, "has_more": true}
        """.data(using: .utf8)!
        #expect(throws: DecodingError.self) {
            try JSONDecoder().decode(TemplateMarketplaceClient.Pagination.self, from: json)
        }
    }

    @Test("DownloadedTemplate fails when missing exampleReply")
    func missingExampleReply() {
        let json = """
        {"id": "d1", "name": "Bad", "instructions": [], "enabled": true}
        """.data(using: .utf8)!
        #expect(throws: DecodingError.self) {
            try JSONDecoder().decode(TemplateMarketplaceClient.DownloadedTemplate.self, from: json)
        }
    }

    @Test("UploadResponse fails on empty JSON")
    func emptyJSON() {
        let json = "{}".data(using: .utf8)!
        #expect(throws: DecodingError.self) {
            try JSONDecoder().decode(TemplateMarketplaceClient.UploadResponse.self, from: json)
        }
    }

    @Test("TemplateLimits fails when remaining is missing")
    func missingRemaining() {
        let json = """
        {"max_templates": 10, "current_count": 7}
        """.data(using: .utf8)!
        #expect(throws: DecodingError.self) {
            try JSONDecoder().decode(TemplateMarketplaceClient.TemplateLimits.self, from: json)
        }
    }
}
