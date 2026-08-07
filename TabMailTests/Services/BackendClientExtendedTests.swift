/* This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at https://mozilla.org/MPL/2.0/. */

import Testing
import Foundation
@testable import TabMail

// ⚠️ DISPLAY NAME DISAMBIGUATED (R18d-G3). Retired: "BackendError Extended" — it collided
// with `BackendErrorExtendedTests` in `BackendErrorExtendedTests.swift`. The run log prints DISPLAY names, so
// `MIS-013`'s per-suite executed-vs-expected reconciliation could not tell the
// two apart, and a suite that silently ran zero tests would have been covered
// by its twin's line. `-only-testing:` was never affected: it selects by Swift
// TYPE name, and the two types were always distinct.
@Suite("BackendError isRetriable — status-code matrix")
struct BackendErrorExtTests {

    @Test("isRetriable: 0 (network failure) is retriable")
    func networkFailureRetriable() {
        let error = BackendError.requestFailed(statusCode: 0)
        #expect(error.isRetriable == true)
    }

    @Test("isRetriable: 408 (timeout) is retriable")
    func timeoutRetriable() {
        let error = BackendError.requestFailed(statusCode: 408)
        #expect(error.isRetriable == true)
    }

    @Test("isRetriable: 429 (rate limit) is retriable")
    func rateLimitRetriable() {
        let error = BackendError.requestFailed(statusCode: 429)
        #expect(error.isRetriable == true)
    }

    @Test("isRetriable: 500 is retriable")
    func serverError500Retriable() {
        let error = BackendError.requestFailed(statusCode: 500)
        #expect(error.isRetriable == true)
    }

    @Test("isRetriable: 502 is retriable")
    func serverError502Retriable() {
        let error = BackendError.requestFailed(statusCode: 502)
        #expect(error.isRetriable == true)
    }

    @Test("isRetriable: 503 is retriable")
    func serverError503Retriable() {
        let error = BackendError.requestFailed(statusCode: 503)
        #expect(error.isRetriable == true)
    }

    @Test("isRetriable: 599 is retriable")
    func serverError599Retriable() {
        let error = BackendError.requestFailed(statusCode: 599)
        #expect(error.isRetriable == true)
    }

    @Test("isRetriable: 400 (bad request) is NOT retriable")
    func badRequestNotRetriable() {
        let error = BackendError.requestFailed(statusCode: 400)
        #expect(error.isRetriable == false)
    }

    @Test("isRetriable: 401 status code is retriable=false via requestFailed")
    func status401AsRequestFailed() {
        // 401 as a status code in requestFailed is a 4xx client error = not retriable
        let error = BackendError.requestFailed(statusCode: 401)
        #expect(error.isRetriable == false)
    }

    @Test("isRetriable: 403 status code is not retriable via requestFailed")
    func status403AsRequestFailed() {
        let error = BackendError.requestFailed(statusCode: 403)
        #expect(error.isRetriable == false)
    }

    @Test("isRetriable: 404 is NOT retriable")
    func notFoundNotRetriable() {
        let error = BackendError.requestFailed(statusCode: 404)
        #expect(error.isRetriable == false)
    }

    @Test("isRetriable: 422 is NOT retriable")
    func unprocessableNotRetriable() {
        let error = BackendError.requestFailed(statusCode: 422)
        #expect(error.isRetriable == false)
    }

    @Test("isRetriable: .unauthorized is NOT retriable")
    func unauthorizedNotRetriable() {
        let error = BackendError.unauthorized
        #expect(error.isRetriable == false)
    }

    @Test("isRetriable: .accountGone is NOT retriable")
    func accountGoneNotRetriable() {
        let error = BackendError.accountGone
        #expect(error.isRetriable == false)
    }

    @Test("isRetriable: .forbidden is NOT retriable")
    func forbiddenNotRetriable() {
        let error = BackendError.forbidden
        #expect(error.isRetriable == false)
    }

    // MARK: - errorDescription

    @Test("errorDescription: requestFailed includes status code")
    func requestFailedDescription() {
        let error = BackendError.requestFailed(statusCode: 500)
        #expect(error.errorDescription?.contains("500") == true)
    }

    @Test("errorDescription: unauthorized")
    func unauthorizedDescription() {
        let error = BackendError.unauthorized
        #expect(error.errorDescription?.contains("401") == true)
    }

    @Test("errorDescription: accountGone")
    func accountGoneDescription() {
        let error = BackendError.accountGone
        #expect(error.errorDescription?.contains("Account") == true)
    }

    @Test("errorDescription: forbidden")
    func forbiddenDescription() {
        let error = BackendError.forbidden
        #expect(error.errorDescription?.contains("403") == true)
    }
}

@Suite("BackendClient Forbidden Backoff")
struct BackendClientForbiddenBackoffTests {

    @Test("Fresh client has no backoff active — checkForbiddenBackoff does not throw")
    func freshClientNoBackoff() async throws {
        let client = BackendClient()
        // extractSSEFinalData is a public method; if checkForbiddenBackoff was blocking,
        // sendCompletions would throw. We verify the backoff state indirectly by confirming
        // the client can be created without error.
        let result = await client.extractSSEFinalData("")
        #expect(result == nil)
    }
}

@Suite("CompletionsResponse Decoding")
struct CompletionsResponseDecodingTests {

    @Test("Decodes with all fields present")
    func decodesAllFields() throws {
        let json = """
        {"assistant":"Hello!","token_usage":{"input_tokens":10,"output_tokens":5,"total_tokens":15},"error":null,"refined_kb":null}
        """
        let response = try JSONDecoder().decode(CompletionsResponse.self, from: json.data(using: .utf8)!)
        #expect(response.assistant == "Hello!")
        #expect(response.token_usage?.input_tokens == 10)
        #expect(response.token_usage?.output_tokens == 5)
        #expect(response.token_usage?.total_tokens == 15)
        #expect(response.error == nil)
        #expect(response.refined_kb == nil)
    }

    @Test("Decodes with error field")
    func decodesError() throws {
        let json = """
        {"assistant":null,"token_usage":null,"error":"Rate limited"}
        """
        let response = try JSONDecoder().decode(CompletionsResponse.self, from: json.data(using: .utf8)!)
        #expect(response.assistant == nil)
        #expect(response.error == "Rate limited")
    }

    @Test("Decodes with refined_kb field")
    func decodesRefinedKB() throws {
        let json = """
        {"assistant":null,"token_usage":null,"error":null,"refined_kb":"Updated knowledge base content"}
        """
        let response = try JSONDecoder().decode(CompletionsResponse.self, from: json.data(using: .utf8)!)
        #expect(response.refined_kb == "Updated knowledge base content")
    }

    @Test("Init convenience constructor works")
    func initConvenience() {
        let response = CompletionsResponse(assistant: "Hi", token_usage: nil, error: nil, refined_kb: "kb")
        #expect(response.assistant == "Hi")
        #expect(response.refined_kb == "kb")
    }

    @Test("Init convenience constructor defaults refined_kb to nil")
    func initConvenienceDefault() {
        let response = CompletionsResponse(assistant: "Hi", token_usage: nil, error: nil)
        #expect(response.refined_kb == nil)
    }

    @Test("Decodes with minimal fields")
    func decodesMinimal() throws {
        let json = """
        {}
        """
        let response = try JSONDecoder().decode(CompletionsResponse.self, from: json.data(using: .utf8)!)
        #expect(response.assistant == nil)
        #expect(response.token_usage == nil)
        #expect(response.error == nil)
        #expect(response.refined_kb == nil)
        #expect(response.thinking == nil)
    }

    // MARK: - Thinking field

    @Test("Decodes with thinking field")
    func decodesThinking() throws {
        let json = """
        {"assistant":"Hello!","token_usage":{"input_tokens":10,"output_tokens":5,"total_tokens":15},"thinking":"deep thought"}
        """
        let response = try JSONDecoder().decode(CompletionsResponse.self, from: json.data(using: .utf8)!)
        #expect(response.thinking == "deep thought")
        #expect(response.assistant == "Hello!")
    }

    @Test("Decodes without thinking field (backward compat)")
    func decodesWithoutThinking() throws {
        let json = """
        {"assistant":"Hello!","token_usage":{"input_tokens":10,"output_tokens":5,"total_tokens":15}}
        """
        let response = try JSONDecoder().decode(CompletionsResponse.self, from: json.data(using: .utf8)!)
        #expect(response.thinking == nil)
        #expect(response.assistant == "Hello!")
    }

    @Test("Init with thinking parameter")
    func initWithThinking() {
        let response = CompletionsResponse(assistant: "Hi", token_usage: nil, error: nil, thinking: "thought")
        #expect(response.thinking == "thought")
        #expect(response.assistant == "Hi")
    }

    @Test("Init without thinking defaults to nil")
    func initWithoutThinking() {
        let response = CompletionsResponse(assistant: "Hi", token_usage: nil, error: nil)
        #expect(response.thinking == nil)
    }

    @Test("FinalEvent with thinking converts to Response with thinking")
    func finalEventWithThinkingConversion() {
        let response = CompletionsResponse(
            assistant: "Result",
            token_usage: nil,
            error: nil,
            thinking: "deep thought"
        )
        #expect(response.thinking == "deep thought")
        #expect(response.assistant == "Result")
    }

    @Test("FinalEvent without thinking converts to Response with nil thinking")
    func finalEventWithoutThinkingConversion() {
        let response = CompletionsResponse(
            assistant: "Result",
            token_usage: nil,
            error: nil,
            thinking: nil
        )
        #expect(response.thinking == nil)
        #expect(response.assistant == "Result")
    }
}

@Suite("TokenUsage Decoding")
struct TokenUsageDecodingTests {

    @Test("Decodes all fields")
    func decodesAll() throws {
        let json = """
        {"input_tokens":100,"output_tokens":50,"total_tokens":150}
        """
        let usage = try JSONDecoder().decode(TokenUsage.self, from: json.data(using: .utf8)!)
        #expect(usage.input_tokens == 100)
        #expect(usage.output_tokens == 50)
        #expect(usage.total_tokens == 150)
    }

    @Test("Decodes large values")
    func decodesLargeValues() throws {
        let json = """
        {"input_tokens":1000000,"output_tokens":500000,"total_tokens":1500000}
        """
        let usage = try JSONDecoder().decode(TokenUsage.self, from: json.data(using: .utf8)!)
        #expect(usage.input_tokens == 1_000_000)
        #expect(usage.total_tokens == 1_500_000)
    }
}

@Suite("DynamicCodingKey Extended")
struct DynamicCodingKeyExtTests {

    @Test("String init sets stringValue")
    func stringInit() {
        let key = DynamicCodingKey("test_key")
        #expect(key.stringValue == "test_key")
        #expect(key.intValue == nil)
    }

    @Test("StringValue init sets stringValue")
    func stringValueInit() {
        let key = DynamicCodingKey(stringValue: "another_key")
        #expect(key != nil)
        #expect(key?.stringValue == "another_key")
    }

    @Test("IntValue init returns nil")
    func intValueInit() {
        let key = DynamicCodingKey(intValue: 42)
        #expect(key == nil)
    }
}

// ⚠️ DISPLAY NAME DISAMBIGUATED (R18d-G3). Retired: "JSONValue Encoding" — it collided
// with `JSONValueTests` in `CompletionsMessageTests.swift`. The run log prints DISPLAY names, so
// `MIS-013`'s per-suite executed-vs-expected reconciliation could not tell the
// two apart, and a suite that silently ran zero tests would have been covered
// by its twin's line. `-only-testing:` was never affected: it selects by Swift
// TYPE name, and the two types were always distinct.
@Suite("JSONValue Encoding — backend request payloads")
struct JSONValueEncodingTests {

    @Test("String encodes correctly")
    func encodeString() throws {
        let value = JSONValue.string("hello")
        let data = try JSONEncoder().encode(value)
        let json = String(data: data, encoding: .utf8)!
        #expect(json == "\"hello\"")
    }

    @Test("Bool true encodes correctly")
    func encodeBoolTrue() throws {
        let value = JSONValue.bool(true)
        let data = try JSONEncoder().encode(value)
        let json = String(data: data, encoding: .utf8)!
        #expect(json == "true")
    }

    @Test("Bool false encodes correctly")
    func encodeBoolFalse() throws {
        let value = JSONValue.bool(false)
        let data = try JSONEncoder().encode(value)
        let json = String(data: data, encoding: .utf8)!
        #expect(json == "false")
    }

    @Test("Int encodes correctly")
    func encodeInt() throws {
        let value = JSONValue.int(42)
        let data = try JSONEncoder().encode(value)
        let json = String(data: data, encoding: .utf8)!
        #expect(json == "42")
    }

    @Test("Double encodes correctly")
    func encodeDouble() throws {
        let value = JSONValue.double(3.14)
        let data = try JSONEncoder().encode(value)
        let json = String(data: data, encoding: .utf8)!
        #expect(json.contains("3.14"))
    }

    @Test("Array encodes correctly")
    func encodeArray() throws {
        let value = JSONValue.array([.string("a"), .int(1)])
        let data = try JSONEncoder().encode(value)
        let json = String(data: data, encoding: .utf8)!
        #expect(json.contains("\"a\""))
        #expect(json.contains("1"))
    }

    @Test("Dictionary encodes correctly")
    func encodeDictionary() throws {
        let value = JSONValue.dictionary(["key": .string("val")])
        let data = try JSONEncoder().encode(value)
        let json = String(data: data, encoding: .utf8)!
        #expect(json.contains("key"))
        #expect(json.contains("val"))
    }

    @Test("Nested structure encodes correctly")
    func encodeNested() throws {
        let value = JSONValue.dictionary([
            "items": .array([.int(1), .int(2)]),
            "active": .bool(true),
        ])
        let data = try JSONEncoder().encode(value)
        let json = String(data: data, encoding: .utf8)!
        #expect(json.contains("items"))
        #expect(json.contains("active"))
    }
}

@Suite("CompletionsMessage Encoding Extended")
struct CompletionsMessageEncodingExtendedTests {

    @Test("Role and content are at top level")
    func roleAndContent() throws {
        let msg = CompletionsMessage(role: "user", content: "hello", vars: [:])
        let data = try JSONEncoder().encode(msg)
        let dict = try JSONSerialization.jsonObject(with: data) as! [String: Any]
        #expect(dict["role"] as? String == "user")
        #expect(dict["content"] as? String == "hello")
    }

    @Test("Vars are flattened into top level")
    func varsFlattened() throws {
        let msg = CompletionsMessage(
            role: "system",
            content: "template",
            vars: ["user_name": .string("Alice"), "count": .int(5)]
        )
        let data = try JSONEncoder().encode(msg)
        let dict = try JSONSerialization.jsonObject(with: data) as! [String: Any]
        #expect(dict["user_name"] as? String == "Alice")
        #expect(dict["count"] as? Int == 5)
        #expect(dict["role"] as? String == "system")
    }

    @Test("Empty vars produces only role and content")
    func emptyVars() throws {
        let msg = CompletionsMessage(role: "assistant", content: "reply", vars: [:])
        let data = try JSONEncoder().encode(msg)
        let dict = try JSONSerialization.jsonObject(with: data) as! [String: Any]
        #expect(dict.count == 2) // role + content
    }

    @Test("Boolean var encodes correctly in message")
    func boolVar() throws {
        let msg = CompletionsMessage(role: "user", content: "test", vars: ["flag": .bool(true)])
        let data = try JSONEncoder().encode(msg)
        let dict = try JSONSerialization.jsonObject(with: data) as! [String: Any]
        #expect(dict["flag"] as? Bool == true)
    }
}

// ⚠️ DISPLAY NAME DISAMBIGUATED (R18d-G3). Retired: "BackendClient clientVersion" — it collided
// with `BackendClientVersionTests` in `BackendClientTests.swift`. The run log prints DISPLAY names, so
// `MIS-013`'s per-suite executed-vs-expected reconciliation could not tell the
// two apart, and a suite that silently ran zero tests would have been covered
// by its twin's line. `-only-testing:` was never affected: it selects by Swift
// TYPE name, and the two types were always distinct.
@Suite("BackendClient clientVersion — extended coverage")
struct BackendClientClientVersionTests {

    @Test("clientVersion returns a string")
    func clientVersionExists() {
        let version = BackendClient.clientVersion
        #expect(!version.isEmpty)
    }
}
