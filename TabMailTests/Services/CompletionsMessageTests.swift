/* This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at https://mozilla.org/MPL/2.0/. */

import Testing
import Foundation
@testable import TabMail

@Suite("CompletionsMessage Encoding")
struct CompletionsMessageTests {

    @Test("Encodes role and content")
    func encodesRoleAndContent() throws {
        let msg = CompletionsMessage(role: "user", content: "Hello", vars: [:])
        let data = try JSONEncoder().encode(msg)
        let dict = try JSONSerialization.jsonObject(with: data) as! [String: Any]
        #expect(dict["role"] as? String == "user")
        #expect(dict["content"] as? String == "Hello")
    }

    @Test("Flattens vars into top-level keys")
    func flattensVars() throws {
        let msg = CompletionsMessage(
            role: "system",
            content: "prompt",
            vars: [
                "template_id": .string("summary_v2"),
                "max_tokens": .int(100),
                "verbose": .bool(true)
            ]
        )
        let data = try JSONEncoder().encode(msg)
        let dict = try JSONSerialization.jsonObject(with: data) as! [String: Any]
        #expect(dict["template_id"] as? String == "summary_v2")
        #expect(dict["max_tokens"] as? Int == 100)
        #expect(dict["verbose"] as? Bool == true)
        #expect(dict["role"] as? String == "system")
    }

    @Test("Empty vars produces only role and content")
    func emptyVars() throws {
        let msg = CompletionsMessage(role: "assistant", content: "reply", vars: [:])
        let data = try JSONEncoder().encode(msg)
        let dict = try JSONSerialization.jsonObject(with: data) as! [String: Any]
        #expect(dict.count == 2)
        #expect(dict["role"] != nil)
        #expect(dict["content"] != nil)
    }

    @Test("Thinking var is flattened into top-level key")
    func thinkingVarFlattened() throws {
        let msg = CompletionsMessage(
            role: "assistant",
            content: "Hi",
            vars: ["thinking": .string("deep thought")]
        )
        let data = try JSONEncoder().encode(msg)
        let dict = try JSONSerialization.jsonObject(with: data) as! [String: Any]
        #expect(dict["thinking"] as? String == "deep thought")
        #expect(dict["role"] as? String == "assistant")
        #expect(dict["content"] as? String == "Hi")
    }

    @Test("No thinking var produces no thinking key")
    func noThinkingVar() throws {
        let msg = CompletionsMessage(role: "assistant", content: "Hi", vars: [:])
        let data = try JSONEncoder().encode(msg)
        let dict = try JSONSerialization.jsonObject(with: data) as! [String: Any]
        #expect(dict["thinking"] == nil)
        #expect(dict.count == 2)
    }
}

@Suite("JSONValue Encoding")
struct JSONValueTests {

    @Test("String encoding")
    func stringEncoding() throws {
        let val = JSONValue.string("hello")
        let data = try JSONEncoder().encode(val)
        let str = String(data: data, encoding: .utf8)!
        #expect(str.contains("hello"))
    }

    @Test("Bool encoding")
    func boolEncoding() throws {
        let val = JSONValue.bool(true)
        let data = try JSONEncoder().encode(val)
        let str = String(data: data, encoding: .utf8)!
        #expect(str == "true")
    }

    @Test("Int encoding")
    func intEncoding() throws {
        let val = JSONValue.int(42)
        let data = try JSONEncoder().encode(val)
        let str = String(data: data, encoding: .utf8)!
        #expect(str == "42")
    }

    @Test("Double encoding")
    func doubleEncoding() throws {
        let val = JSONValue.double(3.14)
        let data = try JSONEncoder().encode(val)
        let str = String(data: data, encoding: .utf8)!
        #expect(str.contains("3.14"))
    }

    @Test("Array encoding")
    func arrayEncoding() throws {
        let val = JSONValue.array([.string("a"), .int(1)])
        let data = try JSONEncoder().encode(val)
        let arr = try JSONSerialization.jsonObject(with: data) as! [Any]
        #expect(arr.count == 2)
    }

    @Test("Dictionary encoding")
    func dictionaryEncoding() throws {
        let val = JSONValue.dictionary(["key": .string("value")])
        let data = try JSONEncoder().encode(val)
        let dict = try JSONSerialization.jsonObject(with: data) as! [String: Any]
        #expect(dict["key"] as? String == "value")
    }

    @Test("Nested structure encoding")
    func nestedEncoding() throws {
        let val = JSONValue.dictionary([
            "items": .array([.string("a"), .string("b")]),
            "count": .int(2),
            "active": .bool(true)
        ])
        let data = try JSONEncoder().encode(val)
        let dict = try JSONSerialization.jsonObject(with: data) as! [String: Any]
        #expect((dict["items"] as? [Any])?.count == 2)
        #expect(dict["count"] as? Int == 2)
    }
}

@Suite("CompletionsRequest")
struct CompletionsRequestTests {

    @Test("client_timestamp_ms is set to current time")
    func timestampSet() {
        let before = Int(Date().timeIntervalSince1970 * 1000)
        let request = CompletionsRequest(
            messages: [],
            client_timezone: "America/Los_Angeles",
            disable_tools: nil
        )
        let after = Int(Date().timeIntervalSince1970 * 1000)
        #expect(request.client_timestamp_ms >= before)
        #expect(request.client_timestamp_ms <= after)
    }

    @Test("Encodes to valid JSON")
    func encodesToJSON() throws {
        let request = CompletionsRequest(
            messages: [CompletionsMessage(role: "user", content: "test", vars: [:])],
            client_timezone: "UTC",
            disable_tools: true,
            web_search_enabled: false
        )
        let data = try JSONEncoder().encode(request)
        let dict = try JSONSerialization.jsonObject(with: data) as! [String: Any]
        #expect(dict["client_timezone"] as? String == "UTC")
        #expect(dict["disable_tools"] as? Bool == true)
        #expect(dict["web_search_enabled"] as? Bool == false)
        #expect((dict["messages"] as? [Any])?.count == 1)
    }
}

@Suite("CompletionsResponse")
struct CompletionsResponseTests {

    @Test("Decodes full response")
    func decodesFull() throws {
        let json = """
        {"assistant":"Hello!","token_usage":{"input_tokens":10,"output_tokens":5,"total_tokens":15},"error":null}
        """
        let response = try JSONDecoder().decode(CompletionsResponse.self, from: json.data(using: .utf8)!)
        #expect(response.assistant == "Hello!")
        #expect(response.token_usage?.input_tokens == 10)
        #expect(response.token_usage?.output_tokens == 5)
        #expect(response.token_usage?.total_tokens == 15)
        #expect(response.error == nil)
    }

    @Test("Decodes response with error")
    func decodesError() throws {
        let json = """
        {"assistant":null,"token_usage":null,"error":"Rate limit exceeded"}
        """
        let response = try JSONDecoder().decode(CompletionsResponse.self, from: json.data(using: .utf8)!)
        #expect(response.assistant == nil)
        #expect(response.error == "Rate limit exceeded")
    }

    @Test("Decodes response with refined_kb")
    func decodesRefinedKB() throws {
        let json = """
        {"assistant":"Done","token_usage":null,"error":null,"refined_kb":"- User prefers formal tone"}
        """
        let response = try JSONDecoder().decode(CompletionsResponse.self, from: json.data(using: .utf8)!)
        #expect(response.refined_kb == "- User prefers formal tone")
    }

    @Test("Init convenience creates response")
    func initConvenience() {
        let response = CompletionsResponse(assistant: "test", token_usage: nil, error: nil, refined_kb: "kb")
        #expect(response.assistant == "test")
        #expect(response.refined_kb == "kb")
    }
}

@Suite("TokenUsage")
struct TokenUsageTests {

    @Test("Decodes from JSON")
    func decodesFromJSON() throws {
        let json = """
        {"input_tokens":100,"output_tokens":50,"total_tokens":150}
        """
        let usage = try JSONDecoder().decode(TokenUsage.self, from: json.data(using: .utf8)!)
        #expect(usage.input_tokens == 100)
        #expect(usage.output_tokens == 50)
        #expect(usage.total_tokens == 150)
    }
}
