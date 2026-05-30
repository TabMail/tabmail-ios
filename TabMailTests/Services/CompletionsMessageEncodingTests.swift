/* This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at https://mozilla.org/MPL/2.0/. */

import Testing
import Foundation
@testable import TabMail

@Suite("CompletionsMessage Dynamic Encoding")
struct CompletionsMessageEncodingTests {

    @Test("CompletionsMessage with string vars encodes correctly")
    func stringVars() throws {
        let msg = CompletionsMessage(
            role: "user",
            content: "Summarize this email",
            vars: ["email_subject": .string("Budget Review")]
        )
        let data = try JSONEncoder().encode(msg)
        let json = String(data: data, encoding: .utf8)!
        #expect(json.contains("Budget Review"))
        #expect(json.contains("email_subject"))
    }

    @Test("CompletionsMessage with int vars encodes correctly")
    func intVars() throws {
        let msg = CompletionsMessage(
            role: "user",
            content: "Process",
            vars: ["count": .int(42)]
        )
        let data = try JSONEncoder().encode(msg)
        let json = String(data: data, encoding: .utf8)!
        #expect(json.contains("42"))
    }

    @Test("CompletionsMessage with bool vars encodes correctly")
    func boolVars() throws {
        let msg = CompletionsMessage(
            role: "user",
            content: "Process",
            vars: ["urgent": .bool(true)]
        )
        let data = try JSONEncoder().encode(msg)
        let json = String(data: data, encoding: .utf8)!
        #expect(json.contains("true"))
    }

    @Test("CompletionsMessage with empty content")
    func emptyContent() throws {
        let msg = CompletionsMessage(
            role: "assistant",
            content: "",
            vars: [:]
        )
        let data = try JSONEncoder().encode(msg)
        let decoded = try JSONSerialization.jsonObject(with: data) as! [String: Any]
        #expect(decoded["role"] as? String == "assistant")
    }

    @Test("CompletionsMessage with empty vars")
    func emptyVars() throws {
        let msg = CompletionsMessage(
            role: "user",
            content: "Hello",
            vars: [:]
        )
        let data = try JSONEncoder().encode(msg)
        let json = String(data: data, encoding: .utf8)!
        #expect(json.contains("role"))
        #expect(json.contains("Hello"))
    }

    @Test("CompletionsRequest encodes with all fields")
    func requestEncodesAll() throws {
        let msg = CompletionsMessage(role: "user", content: "Hi", vars: [:])
        let request = CompletionsRequest(
            messages: [msg],
            client_timezone: "America/New_York",
            disable_tools: false
        )
        let data = try JSONEncoder().encode(request)
        let json = String(data: data, encoding: .utf8)!
        // JSON may escape "/" as "\/"
        #expect(json.contains("America") && json.contains("New_York"))
        #expect(json.contains("messages"))
    }

    @Test("CompletionsResponse decodes assistant text")
    func responseDecodesAssistant() throws {
        let json = """
        {"assistant": "Here's the summary", "token_usage": {"input_tokens": 50, "output_tokens": 30, "total_tokens": 80}}
        """
        let response = try JSONDecoder().decode(CompletionsResponse.self, from: Data(json.utf8))
        #expect(response.assistant == "Here's the summary")
        #expect(response.token_usage?.input_tokens == 50)
    }

    @Test("CompletionsResponse decodes with error")
    func responseDecodesError() throws {
        let json = """
        {"error": "Rate limit exceeded"}
        """
        let response = try JSONDecoder().decode(CompletionsResponse.self, from: Data(json.utf8))
        #expect(response.error == "Rate limit exceeded")
        #expect(response.assistant == nil)
    }

    @Test("CompletionsResponse decodes refined_kb")
    func responseDecodesRefinedKB() throws {
        let json = """
        {"assistant": "Done", "refined_kb": "Updated knowledge base text"}
        """
        let response = try JSONDecoder().decode(CompletionsResponse.self, from: Data(json.utf8))
        #expect(response.refined_kb == "Updated knowledge base text")
    }

    @Test("JSONValue string encodes as string")
    func jsonValueString() throws {
        let val = JSONValue.string("hello")
        let data = try JSONEncoder().encode(val)
        let str = String(data: data, encoding: .utf8)!
        #expect(str.contains("hello"))
    }

    @Test("JSONValue int encodes as number")
    func jsonValueInt() throws {
        let val = JSONValue.int(42)
        let data = try JSONEncoder().encode(val)
        let str = String(data: data, encoding: .utf8)!
        #expect(str == "42")
    }

    @Test("JSONValue bool encodes as boolean")
    func jsonValueBool() throws {
        let val = JSONValue.bool(true)
        let data = try JSONEncoder().encode(val)
        let str = String(data: data, encoding: .utf8)!
        #expect(str == "true")
    }
}
