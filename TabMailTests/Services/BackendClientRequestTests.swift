/* This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at https://mozilla.org/MPL/2.0/. */

import Testing
import Foundation
@testable import TabMail

@Suite("CompletionsRequest Encoding")
struct CompletionsRequestEncodingTests {

    @Test("Encodes messages array with vars")
    func encodesMessagesWithVars() throws {
        let msg = CompletionsMessage(
            role: "system",
            content: "system_prompt_summary",
            vars: [
                "user_name": .string("Alice"),
                "subject": .string("Budget Review"),
                "body": .string("Please review the attached budget."),
            ]
        )
        let request = CompletionsRequest(
            messages: [msg],
            client_timezone: "America/Los_Angeles",
            disable_tools: nil
        )
        let data = try JSONEncoder().encode(request)
        let dict = try JSONSerialization.jsonObject(with: data) as! [String: Any]
        let messages = dict["messages"] as! [[String: Any]]
        #expect(messages.count == 1)
        #expect(messages[0]["role"] as? String == "system")
        #expect(messages[0]["user_name"] as? String == "Alice")
        #expect(messages[0]["subject"] as? String == "Budget Review")
    }

    @Test("Encodes client_timestamp_ms as current epoch milliseconds")
    func encodesTimestamp() throws {
        let before = Int(Date().timeIntervalSince1970 * 1000)
        let request = CompletionsRequest(
            messages: [],
            client_timezone: nil,
            disable_tools: nil
        )
        let after = Int(Date().timeIntervalSince1970 * 1000)
        #expect(request.client_timestamp_ms >= before)
        #expect(request.client_timestamp_ms <= after)

        let data = try JSONEncoder().encode(request)
        let dict = try JSONSerialization.jsonObject(with: data) as! [String: Any]
        let ts = dict["client_timestamp_ms"] as? Int
        #expect(ts != nil)
        #expect(ts! >= before)
    }

    @Test("Encodes client_timezone when present")
    func encodesTimezone() throws {
        let request = CompletionsRequest(
            messages: [],
            client_timezone: "Europe/London",
            disable_tools: nil
        )
        let data = try JSONEncoder().encode(request)
        let dict = try JSONSerialization.jsonObject(with: data) as! [String: Any]
        let tz = dict["client_timezone"] as? String
        #expect(tz == "Europe/London")
    }

    @Test("Omits client_timezone when nil")
    func omitsTimezoneWhenNil() throws {
        let request = CompletionsRequest(
            messages: [],
            client_timezone: nil,
            disable_tools: nil
        )
        let data = try JSONEncoder().encode(request)
        let dict = try JSONSerialization.jsonObject(with: data) as! [String: Any]
        // nil optionals should not appear in encoded JSON
        // (default JSONEncoder behavior encodes nil as null)
        let tz = dict["client_timezone"]
        #expect(tz == nil || tz is NSNull)
    }

    @Test("Encodes disable_tools when true")
    func encodesDisableToolsTrue() throws {
        let request = CompletionsRequest(
            messages: [],
            client_timezone: nil,
            disable_tools: true
        )
        let data = try JSONEncoder().encode(request)
        let dict = try JSONSerialization.jsonObject(with: data) as! [String: Any]
        #expect(dict["disable_tools"] as? Bool == true)
    }

    @Test("Encodes disable_tools when false")
    func encodesDisableToolsFalse() throws {
        let request = CompletionsRequest(
            messages: [],
            client_timezone: nil,
            disable_tools: false
        )
        let data = try JSONEncoder().encode(request)
        let dict = try JSONSerialization.jsonObject(with: data) as! [String: Any]
        #expect(dict["disable_tools"] as? Bool == false)
    }

    @Test("Encodes web_search_enabled when set")
    func encodesWebSearchEnabled() throws {
        let request = CompletionsRequest(
            messages: [],
            client_timezone: nil,
            disable_tools: nil,
            web_search_enabled: true
        )
        let data = try JSONEncoder().encode(request)
        let dict = try JSONSerialization.jsonObject(with: data) as! [String: Any]
        #expect(dict["web_search_enabled"] as? Bool == true)
    }

    @Test("Encodes conversation_state when provided")
    func encodesConversationState() throws {
        let state = ConversationState(
            harmony_messages: [
                HarmonyMessage(role: "user", content: "hello", thinking: nil, tool_calls: nil, tool_call_id: nil)
            ],
            current_round: 1
        )
        let request = CompletionsRequest(
            messages: [],
            client_timezone: nil,
            disable_tools: nil,
            conversation_state: state
        )
        let data = try JSONEncoder().encode(request)
        let dict = try JSONSerialization.jsonObject(with: data) as! [String: Any]
        let cs = dict["conversation_state"] as? [String: Any]
        #expect(cs != nil)
        #expect(cs?["current_round"] as? Int == 1)
        let msgs = cs?["harmony_messages"] as? [[String: Any]]
        #expect(msgs?.count == 1)
    }

    @Test("Multiple messages encode in order")
    func multipleMessagesInOrder() throws {
        let msgs = [
            CompletionsMessage(role: "system", content: "system_prompt", vars: [:]),
            CompletionsMessage(role: "user", content: "user_msg", vars: ["key": .string("val")]),
        ]
        let request = CompletionsRequest(
            messages: msgs,
            client_timezone: nil,
            disable_tools: nil
        )
        let data = try JSONEncoder().encode(request)
        let dict = try JSONSerialization.jsonObject(with: data) as! [String: Any]
        let encoded = dict["messages"] as! [[String: Any]]
        #expect(encoded.count == 2)
        #expect(encoded[0]["role"] as? String == "system")
        #expect(encoded[1]["role"] as? String == "user")
        #expect(encoded[1]["key"] as? String == "val")
    }
}

@Suite("ConversationState Encoding")
struct ConversationStateEncodingTests {

    @Test("Encodes harmony_messages and current_round")
    func encodesBasicFields() throws {
        let state = ConversationState(
            harmony_messages: [
                HarmonyMessage(role: "assistant", content: "Hello", thinking: nil, tool_calls: nil, tool_call_id: nil)
            ],
            current_round: 3
        )
        let data = try JSONEncoder().encode(state)
        let dict = try JSONSerialization.jsonObject(with: data) as! [String: Any]
        #expect(dict["current_round"] as? Int == 3)
        let msgs = dict["harmony_messages"] as? [[String: Any]]
        #expect(msgs?.count == 1)
        #expect(msgs?[0]["role"] as? String == "assistant")
    }

    @Test("Round-trip with tool_traces")
    func roundTripWithToolTraces() throws {
        var state = ConversationState(
            harmony_messages: [],
            current_round: 0
        )
        state.tool_traces = [
            ToolTrace(name: "search", call_id: "c1", execution_id: "e1", result: "found", success: true, server_side: true)
        ]
        let data = try JSONEncoder().encode(state)
        let decoded = try JSONDecoder().decode(ConversationState.self, from: data)
        #expect(decoded.tool_traces?.count == 1)
        #expect(decoded.tool_traces?[0].name == "search")
        #expect(decoded.tool_traces?[0].success == true)
    }

    @Test("Encodes ts_ms field")
    func encodesTsMs() throws {
        var state = ConversationState(harmony_messages: [], current_round: 0)
        state.ts_ms = 1234567890.123
        let data = try JSONEncoder().encode(state)
        let dict = try JSONSerialization.jsonObject(with: data) as! [String: Any]
        #expect(dict["ts_ms"] as? Double == 1234567890.123)
    }

    @Test("Encodes malformed_retry_count")
    func encodesMalformedRetryCount() throws {
        var state = ConversationState(harmony_messages: [], current_round: 0)
        state.malformed_retry_count = 2
        let data = try JSONEncoder().encode(state)
        let dict = try JSONSerialization.jsonObject(with: data) as! [String: Any]
        #expect(dict["malformed_retry_count"] as? Int == 2)
    }

    @Test("Encodes max_rounds_malformed_retry_count")
    func encodesMaxRoundsMalformedRetryCount() throws {
        var state = ConversationState(harmony_messages: [], current_round: 0)
        state.max_rounds_malformed_retry_count = 1
        let data = try JSONEncoder().encode(state)
        let dict = try JSONSerialization.jsonObject(with: data) as! [String: Any]
        #expect(dict["max_rounds_malformed_retry_count"] as? Int == 1)
    }
}

@Suite("BackendClient.clientVersion Extended")
struct BackendClientVersionExtendedTests {

    @Test("clientVersion is a non-empty string")
    func clientVersionNonEmpty() {
        let version = BackendClient.clientVersion
        #expect(!version.isEmpty)
    }

    @Test("clientVersion has semver-like format or default")
    func clientVersionFormat() {
        let version = BackendClient.clientVersion
        // Should be either a real version from bundle or the fallback "1.0.0"
        #expect(version.contains("."))
    }
}

@Suite("BackendConfig Constants")
struct BackendConfigConstantTests {

    @Test("apiBaseURL has HTTPS scheme")
    func apiBaseURLScheme() {
        #expect(BackendConfig.apiBaseURL.scheme == "https")
    }

    @Test("apiBaseURL contains tabmail.ai")
    func apiBaseURLDomain() {
        #expect(BackendConfig.apiBaseURL.host?.contains("tabmail.ai") == true)
    }

    @Test("syncBaseURL starts with https")
    func syncBaseURLHTTPS() {
        #expect(BackendConfig.syncBaseURL.hasPrefix("https://"))
    }

    @Test("syncWebSocketURL starts with wss")
    func syncWSS() {
        #expect(BackendConfig.syncWebSocketURL.hasPrefix("wss://"))
    }

    @Test("syncWebSocketURL ends with /ws")
    func syncWSPath() {
        #expect(BackendConfig.syncWebSocketURL.hasSuffix("/ws"))
    }

    @Test("templatesBaseURL has HTTPS scheme")
    func templatesScheme() {
        #expect(BackendConfig.templatesBaseURL.scheme == "https")
    }

    @Test("billingBaseURL has HTTPS scheme")
    func billingScheme() {
        #expect(BackendConfig.billingBaseURL.scheme == "https")
    }
}

// ⚠️ DISPLAY NAME DISAMBIGUATED (R18d-G3). Retired: "BackendError Extended" — it collided
// with `BackendErrorExtendedTests` in `BackendErrorExtendedTests.swift`. The run log prints DISPLAY names, so
// `MIS-013`'s per-suite executed-vs-expected reconciliation could not tell the
// two apart, and a suite that silently ran zero tests would have been covered
// by its twin's line. `-only-testing:` was never affected: it selects by Swift
// TYPE name, and the two types were always distinct.
@Suite("BackendError errorDescription and isRetriable — edge cases")
struct BackendErrorExtendedEdgeCaseTests {

    @Test("errorDescription for requestFailed includes code")
    func requestFailedDescription() {
        let error = BackendError.requestFailed(statusCode: 503)
        #expect(error.errorDescription?.contains("503") == true)
    }

    @Test("errorDescription for unauthorized")
    func unauthorizedDescription() {
        let error = BackendError.unauthorized
        #expect(error.errorDescription?.contains("401") == true)
    }

    @Test("errorDescription for accountGone")
    func accountGoneDescription() {
        let error = BackendError.accountGone
        #expect(error.errorDescription?.contains("Account") == true)
    }

    @Test("errorDescription for forbidden")
    func forbiddenDescription() {
        let error = BackendError.forbidden
        #expect(error.errorDescription?.contains("403") == true)
    }

    @Test("isRetriable for status code 0 (network failure)")
    func retriableStatusZero() {
        let error = BackendError.requestFailed(statusCode: 0)
        #expect(error.isRetriable == true)
    }

    @Test("isRetriable for 599 (5xx range)")
    func retriable599() {
        let error = BackendError.requestFailed(statusCode: 599)
        #expect(error.isRetriable == true)
    }

    @Test("isRetriable false for 200 (success code)")
    func notRetriable200() {
        let error = BackendError.requestFailed(statusCode: 200)
        #expect(error.isRetriable == false)
    }
}

@Suite("BackendClient.extractSSEFinalData")
struct ExtractSSEFinalDataTests {

    @Test("Extracts data from final event")
    func extractsFinalData() async {
        let client = BackendClient()
        let sse = """
        event: keepalive
        data: {}

        event: final
        data: {"assistant":"Hello","token_usage":null}

        """
        let result = await client.extractSSEFinalData(sse)
        #expect(result != nil)
        #expect(result!.contains("Hello"))
    }

    @Test("Returns nil when no final event")
    func returnsNilWithoutFinal() async {
        let client = BackendClient()
        let sse = """
        event: keepalive
        data: {}

        event: tool_started
        data: {"tool_name":"search"}

        """
        let result = await client.extractSSEFinalData(sse)
        #expect(result == nil)
    }

    @Test("Ignores non-final event data")
    func ignoresNonFinalData() async {
        let client = BackendClient()
        let sse = """
        event: tool_completed
        data: {"tool_name":"search","success":true}

        event: final
        data: {"assistant":"Result"}

        """
        let result = await client.extractSSEFinalData(sse)
        #expect(result != nil)
        #expect(result!.contains("Result"))
        #expect(!result!.contains("search"))
    }

    @Test("Handles empty SSE text")
    func handlesEmptySSE() async {
        let client = BackendClient()
        let result = await client.extractSSEFinalData("")
        #expect(result == nil)
    }

    @Test("Handles SSE with only keepalive events")
    func handlesOnlyKeepalive() async {
        let client = BackendClient()
        let sse = """
        event: keepalive
        data: {}

        event: keepalive
        data: {}

        """
        let result = await client.extractSSEFinalData(sse)
        #expect(result == nil)
    }
}

// All tests mutate the shared UserDefaults web-search toggle — must run serially.
@Suite("BackendClient.augmentRequestWithDefaults", .serialized)
struct BackendClientAugmentRequestTests {

    private static func setWebSearchEnabled(_ value: Bool) {
        UserDefaults.standard.set(value, forKey: AIService.webSearchEnabledKey)
        UserDefaults.standard.synchronize()
    }

    private static func clearWebSearchToggle() {
        UserDefaults.standard.removeObject(forKey: AIService.webSearchEnabledKey)
        UserDefaults.standard.synchronize()
    }

    @Test("Stamps web_search_enabled=true when toggle is on and caller passes nil")
    func stampsTrueWhenToggleOnAndCallerNil() throws {
        Self.setWebSearchEnabled(true)
        defer { Self.clearWebSearchToggle() }

        let request = CompletionsRequest(
            messages: [],
            client_timezone: nil,
            disable_tools: nil
        )
        #expect(request.web_search_enabled == nil)

        let augmented = BackendClient.augmentRequestWithDefaults(request)
        #expect(augmented.web_search_enabled == true)
    }

    @Test("Leaves web_search_enabled nil when toggle is off and caller passes nil")
    func leavesNilWhenToggleOffAndCallerNil() throws {
        Self.setWebSearchEnabled(false)
        defer { Self.clearWebSearchToggle() }

        let request = CompletionsRequest(
            messages: [],
            client_timezone: nil,
            disable_tools: nil
        )
        let augmented = BackendClient.augmentRequestWithDefaults(request)
        // Off → nil (matches the on-the-wire convention: omit the field rather than send false)
        #expect(augmented.web_search_enabled == nil)
    }

    @Test("Preserves caller-provided web_search_enabled=true regardless of toggle")
    func preservesExplicitTrue() throws {
        // Toggle off, but caller explicitly opted in — caller wins.
        Self.setWebSearchEnabled(false)
        defer { Self.clearWebSearchToggle() }

        let request = CompletionsRequest(
            messages: [],
            client_timezone: nil,
            disable_tools: nil,
            web_search_enabled: true
        )
        let augmented = BackendClient.augmentRequestWithDefaults(request)
        #expect(augmented.web_search_enabled == true)
    }

    @Test("Preserves caller-provided web_search_enabled=false regardless of toggle")
    func preservesExplicitFalse() throws {
        // Toggle on, but caller explicitly opted out — caller wins.
        Self.setWebSearchEnabled(true)
        defer { Self.clearWebSearchToggle() }

        let request = CompletionsRequest(
            messages: [],
            client_timezone: nil,
            disable_tools: nil,
            web_search_enabled: false
        )
        let augmented = BackendClient.augmentRequestWithDefaults(request)
        #expect(augmented.web_search_enabled == false)
    }

    @Test("Augmentation is idempotent")
    func idempotent() throws {
        Self.setWebSearchEnabled(true)
        defer { Self.clearWebSearchToggle() }

        let request = CompletionsRequest(
            messages: [],
            client_timezone: nil,
            disable_tools: nil
        )
        let once = BackendClient.augmentRequestWithDefaults(request)
        let twice = BackendClient.augmentRequestWithDefaults(once)
        #expect(once.web_search_enabled == true)
        #expect(twice.web_search_enabled == true)
    }

    @Test("Preserves all other fields (messages, timezone, disable_tools, conversation_state)")
    func preservesOtherFields() throws {
        Self.setWebSearchEnabled(true)
        defer { Self.clearWebSearchToggle() }

        let msg = CompletionsMessage(
            role: "system",
            content: "system_prompt_compose_interactive",
            vars: ["mode": .string("edit_new")]
        )
        let state = ConversationState(
            harmony_messages: [
                HarmonyMessage(role: "user", content: "hi", thinking: nil, tool_calls: nil, tool_call_id: nil)
            ],
            current_round: 2
        )
        let request = CompletionsRequest(
            messages: [msg],
            client_timezone: "America/New_York",
            disable_tools: false,
            conversation_state: state
        )
        let augmented = BackendClient.augmentRequestWithDefaults(request)

        #expect(augmented.web_search_enabled == true)
        #expect(augmented.messages.count == 1)
        #expect(augmented.messages[0].content == "system_prompt_compose_interactive")
        #expect(augmented.client_timezone == "America/New_York")
        #expect(augmented.disable_tools == false)
        #expect(augmented.conversation_state?.current_round == 2)
        #expect(augmented.conversation_state?.harmony_messages.count == 1)
    }

    @Test("Toggle responds to UserDefaults changes between calls")
    func reflectsLiveToggleChanges() throws {
        defer { Self.clearWebSearchToggle() }

        let request = CompletionsRequest(
            messages: [],
            client_timezone: nil,
            disable_tools: nil
        )

        Self.setWebSearchEnabled(false)
        let off = BackendClient.augmentRequestWithDefaults(request)
        #expect(off.web_search_enabled == nil)

        Self.setWebSearchEnabled(true)
        let on = BackendClient.augmentRequestWithDefaults(request)
        #expect(on.web_search_enabled == true)
    }

    @Test("AIService.webSearchEnabled property reads from UserDefaults")
    func aiServicePropertyReadsUserDefaults() throws {
        defer { Self.clearWebSearchToggle() }

        Self.setWebSearchEnabled(true)
        #expect(AIService.shared.webSearchEnabled == true)

        Self.setWebSearchEnabled(false)
        #expect(AIService.shared.webSearchEnabled == false)
    }
}

@Suite("BackendClient.jsonValueFromAny")
struct JsonValueFromAnyTests {

    @Test("Converts String to .string")
    func convertsString() {
        let result = BackendClient.jsonValueFromAny("hello")
        if case .string(let s) = result {
            #expect(s == "hello")
        } else {
            #expect(Bool(false), "Expected .string")
        }
    }

    @Test("Converts Int to .int")
    func convertsInt() {
        let result = BackendClient.jsonValueFromAny(42)
        if case .int(let i) = result {
            #expect(i == 42)
        } else {
            #expect(Bool(false), "Expected .int")
        }
    }

    @Test("Converts Double to .double")
    func convertsDouble() {
        let result = BackendClient.jsonValueFromAny(3.14 as Double)
        if case .double(let d) = result {
            #expect(abs(d - 3.14) < 0.001)
        } else {
            #expect(Bool(false), "Expected .double")
        }
    }

    @Test("Converts Array to .array")
    func convertsArray() {
        let result = BackendClient.jsonValueFromAny(["a", "b"] as [Any])
        if case .array(let arr) = result {
            #expect(arr.count == 2)
        } else {
            #expect(Bool(false), "Expected .array")
        }
    }

    @Test("Converts Dictionary to .dictionary")
    func convertsDictionary() {
        let result = BackendClient.jsonValueFromAny(["key": "value"] as [String: Any])
        if case .dictionary(let dict) = result {
            if case .string(let v) = dict["key"] {
                #expect(v == "value")
            } else {
                #expect(Bool(false), "Expected .string value")
            }
        } else {
            #expect(Bool(false), "Expected .dictionary")
        }
    }

    @Test("Returns nil for unsupported types")
    func returnsNilForUnsupported() {
        let result = BackendClient.jsonValueFromAny(Date())
        #expect(result == nil)
    }
}
