/* This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at https://mozilla.org/MPL/2.0/. */

import Testing
import Foundation
@testable import TabMail

@Suite("TemplateMarketplaceClient Codable Types")
struct TemplateMarketplaceTypesTests {

    // MARK: - MarketplaceTemplate

    @Test("MarketplaceTemplate decodes all fields")
    func decodeMarketplaceTemplate() throws {
        let json = """
        {
            "id": "tmpl-001",
            "name": "Professional Reply",
            "description": "A professional tone template",
            "instructions": ["Be polite", "Use formal language"],
            "example_reply": "Dear Sir/Madam,",
            "download_count": 42,
            "is_featured": true,
            "is_official": false,
            "status": "approved",
            "category": "business",
            "tags": ["formal", "professional"],
            "created_at": "2024-01-01T00:00:00Z",
            "updated_at": "2024-03-15T12:00:00Z"
        }
        """.data(using: .utf8)!
        let template = try JSONDecoder().decode(TemplateMarketplaceClient.MarketplaceTemplate.self, from: json)
        #expect(template.id == "tmpl-001")
        #expect(template.name == "Professional Reply")
        #expect(template.description == "A professional tone template")
        #expect(template.instructions == ["Be polite", "Use formal language"])
        #expect(template.example_reply == "Dear Sir/Madam,")
        #expect(template.download_count == 42)
        #expect(template.is_featured == true)
        #expect(template.is_official == false)
        #expect(template.status == "approved")
        #expect(template.category == "business")
        #expect(template.tags == ["formal", "professional"])
        #expect(template.created_at == "2024-01-01T00:00:00Z")
        #expect(template.updated_at == "2024-03-15T12:00:00Z")
    }

    @Test("MarketplaceTemplate decodes with null optional fields")
    func decodeMarketplaceTemplateNulls() throws {
        let json = """
        {
            "id": "t2",
            "name": "Casual",
            "description": null,
            "instructions": [],
            "example_reply": "Hey!",
            "download_count": 0,
            "is_featured": false,
            "is_official": true,
            "status": "pending",
            "category": null,
            "tags": null,
            "created_at": "2024-01-01T00:00:00Z",
            "updated_at": "2024-01-01T00:00:00Z"
        }
        """.data(using: .utf8)!
        let template = try JSONDecoder().decode(TemplateMarketplaceClient.MarketplaceTemplate.self, from: json)
        #expect(template.description == nil)
        #expect(template.category == nil)
        #expect(template.tags == nil)
        #expect(template.instructions.isEmpty)
    }

    // MARK: - Pagination

    @Test("Pagination decodes correctly")
    func decodePagination() throws {
        let json = """
        {"limit": 20, "offset": 0, "total": 100, "has_more": true}
        """.data(using: .utf8)!
        let p = try JSONDecoder().decode(TemplateMarketplaceClient.Pagination.self, from: json)
        #expect(p.limit == 20)
        #expect(p.offset == 0)
        #expect(p.total == 100)
        #expect(p.has_more == true)
    }

    @Test("Pagination with has_more false")
    func decodePaginationNoMore() throws {
        let json = """
        {"limit": 10, "offset": 90, "total": 95, "has_more": false}
        """.data(using: .utf8)!
        let p = try JSONDecoder().decode(TemplateMarketplaceClient.Pagination.self, from: json)
        #expect(p.has_more == false)
        #expect(p.offset == 90)
    }

    // MARK: - ListResponse

    @Test("ListResponse decodes templates and pagination")
    func decodeListResponse() throws {
        let json = """
        {
            "templates": [{
                "id": "t1", "name": "T1", "description": null,
                "instructions": ["a"], "example_reply": "Hi",
                "download_count": 5, "is_featured": false, "is_official": false,
                "status": "approved", "category": null, "tags": null,
                "created_at": "2024-01-01T00:00:00Z", "updated_at": "2024-01-01T00:00:00Z"
            }],
            "pagination": {"limit": 20, "offset": 0, "total": 1, "has_more": false}
        }
        """.data(using: .utf8)!
        let response = try JSONDecoder().decode(TemplateMarketplaceClient.ListResponse.self, from: json)
        #expect(response.templates.count == 1)
        #expect(response.templates[0].id == "t1")
        #expect(response.pagination.total == 1)
    }

    // MARK: - DownloadedTemplate

    @Test("DownloadedTemplate decodes correctly")
    func decodeDownloadedTemplate() throws {
        let json = """
        {"id": "d1", "name": "Downloaded", "instructions": ["x", "y"], "exampleReply": "Hello!", "enabled": true}
        """.data(using: .utf8)!
        let t = try JSONDecoder().decode(TemplateMarketplaceClient.DownloadedTemplate.self, from: json)
        #expect(t.id == "d1")
        #expect(t.name == "Downloaded")
        #expect(t.instructions == ["x", "y"])
        #expect(t.exampleReply == "Hello!")
        #expect(t.enabled == true)
    }

    // MARK: - DownloadResponse

    @Test("DownloadResponse wraps DownloadedTemplate")
    func decodeDownloadResponse() throws {
        let json = """
        {"template": {"id": "d2", "name": "Wrap", "instructions": [], "exampleReply": "R", "enabled": false}}
        """.data(using: .utf8)!
        let r = try JSONDecoder().decode(TemplateMarketplaceClient.DownloadResponse.self, from: json)
        #expect(r.template.id == "d2")
        #expect(r.template.enabled == false)
    }

    // MARK: - MyTemplate

    @Test("MyTemplate decodes with rejection fields")
    func decodeMyTemplate() throws {
        let json = """
        {
            "id": "my1", "name": "My Template", "description": "desc",
            "instructions": ["i"], "example_reply": "e",
            "download_count": 10, "is_featured": false, "is_official": false,
            "status": "rejected", "category": "personal", "tags": ["tag1"],
            "created_at": "2024-01-01T00:00:00Z", "updated_at": "2024-02-01T00:00:00Z",
            "rejection_reason": "Inappropriate content",
            "reviewed_at": "2024-01-15T00:00:00Z"
        }
        """.data(using: .utf8)!
        let t = try JSONDecoder().decode(TemplateMarketplaceClient.MyTemplate.self, from: json)
        #expect(t.id == "my1")
        #expect(t.rejection_reason == "Inappropriate content")
        #expect(t.reviewed_at == "2024-01-15T00:00:00Z")
        #expect(t.status == "rejected")
    }

    @Test("MyTemplate decodes with null rejection fields")
    func decodeMyTemplateNoRejection() throws {
        let json = """
        {
            "id": "my2", "name": "OK", "description": null,
            "instructions": [], "example_reply": "",
            "download_count": 0, "is_featured": false, "is_official": false,
            "status": "approved", "category": null, "tags": null,
            "created_at": "2024-01-01T00:00:00Z", "updated_at": "2024-01-01T00:00:00Z",
            "rejection_reason": null, "reviewed_at": null
        }
        """.data(using: .utf8)!
        let t = try JSONDecoder().decode(TemplateMarketplaceClient.MyTemplate.self, from: json)
        #expect(t.rejection_reason == nil)
        #expect(t.reviewed_at == nil)
    }

    // MARK: - MyTemplatesResponse

    @Test("MyTemplatesResponse decodes templates and limits")
    func decodeMyTemplatesResponse() throws {
        let json = """
        {
            "templates": [],
            "limits": {"max_templates": 5, "current_count": 2, "remaining": 3}
        }
        """.data(using: .utf8)!
        let r = try JSONDecoder().decode(TemplateMarketplaceClient.MyTemplatesResponse.self, from: json)
        #expect(r.templates.isEmpty)
        #expect(r.limits.max_templates == 5)
        #expect(r.limits.current_count == 2)
        #expect(r.limits.remaining == 3)
    }

    // MARK: - TemplateLimits

    @Test("TemplateLimits decodes all fields")
    func decodeTemplateLimits() throws {
        let json = """
        {"max_templates": 10, "current_count": 7, "remaining": 3}
        """.data(using: .utf8)!
        let l = try JSONDecoder().decode(TemplateMarketplaceClient.TemplateLimits.self, from: json)
        #expect(l.max_templates == 10)
        #expect(l.current_count == 7)
        #expect(l.remaining == 3)
    }

    // MARK: - UploadResponse

    @Test("UploadResponse decodes all fields")
    func decodeUploadResponse() throws {
        let json = """
        {"success": true, "message": "Template uploaded", "template_id": "up1", "status": "pending_review"}
        """.data(using: .utf8)!
        let r = try JSONDecoder().decode(TemplateMarketplaceClient.UploadResponse.self, from: json)
        #expect(r.success == true)
        #expect(r.message == "Template uploaded")
        #expect(r.template_id == "up1")
        #expect(r.status == "pending_review")
    }

    @Test("UploadResponse with failure")
    func decodeUploadResponseFailure() throws {
        let json = """
        {"success": false, "message": "Duplicate name", "template_id": "", "status": "rejected"}
        """.data(using: .utf8)!
        let r = try JSONDecoder().decode(TemplateMarketplaceClient.UploadResponse.self, from: json)
        #expect(r.success == false)
        #expect(r.message == "Duplicate name")
    }
}
