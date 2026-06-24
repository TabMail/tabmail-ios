/* This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at https://mozilla.org/MPL/2.0/. */

import Testing
import Foundation
import Synchronization
@testable import TabMail

@Suite("BackendClient SSE Parsing")
struct BackendClientSSETests {

    // MARK: - extractSSEFinalData

    @Test("extractSSEFinalData: simple SSE with final event extracts data")
    func extractSimpleFinal() async {
        let client = BackendClient()
        let text = """
        event: final
        data: {"assistant":"Hello"}

        """
        let result = await client.extractSSEFinalData(text)
        #expect(result == "{\"assistant\":\"Hello\"}")
    }

    @Test("extractSSEFinalData: multiple events, final in middle extracts final data")
    func extractFinalInMiddle() async {
        let client = BackendClient()
        let text = """
        event: keepalive
        data: {}

        event: final
        data: {"assistant":"Result"}

        event: keepalive
        data: {}

        """
        let result = await client.extractSSEFinalData(text)
        #expect(result == "{\"assistant\":\"Result\"}")
    }

    @Test("extractSSEFinalData: no final event returns nil")
    func extractNoFinal() async {
        let client = BackendClient()
        let text = """
        event: keepalive
        data: {}

        event: tool_started
        data: {"tool_name":"search"}

        """
        let result = await client.extractSSEFinalData(text)
        #expect(result == nil)
    }

    @Test("extractSSEFinalData: empty string returns nil")
    func extractEmpty() async {
        let client = BackendClient()
        let result = await client.extractSSEFinalData("")
        #expect(result == nil)
    }

    @Test("extractSSEFinalData: data lines in non-final events ignored")
    func extractNonFinalIgnored() async {
        let client = BackendClient()
        let text = """
        event: tool_completed
        data: {"tool_name":"search","success":true}

        """
        let result = await client.extractSSEFinalData(text)
        #expect(result == nil)
    }

    @Test("extractSSEFinalData: final event with complex JSON data")
    func extractComplexJson() async {
        let client = BackendClient()
        let text = """
        event: final
        data: {"assistant":"Hello","token_usage":{"input":100,"output":50},"tool_calls":[{"id":"tc1","function":{"name":"search","arguments":"{}"}}]}

        """
        let result = await client.extractSSEFinalData(text)
        #expect(result != nil)
        #expect(result!.contains("token_usage"))
        #expect(result!.contains("tool_calls"))
    }

    @Test("extractSSEFinalData: event reset on empty line")
    func extractEventReset() async {
        let client = BackendClient()
        // After empty line, the event type resets. So data after blank line without new event: should not match.
        let text = """
        event: tool_started
        data: {"tool_name":"x"}

        data: should-be-ignored

        event: final
        data: {"assistant":"OK"}

        """
        let result = await client.extractSSEFinalData(text)
        #expect(result == "{\"assistant\":\"OK\"}")
    }

    // MARK: - jsonValueFromAny

    @Test("jsonValueFromAny: String")
    func jsonString() {
        let result = BackendClient.jsonValueFromAny("hello")
        #expect(result == .string("hello"))
    }

    @Test("jsonValueFromAny: Int")
    func jsonInt() {
        let result = BackendClient.jsonValueFromAny(42)
        #expect(result == .int(42))
    }

    @Test("jsonValueFromAny: Double")
    func jsonDouble() {
        let result = BackendClient.jsonValueFromAny(3.14)
        #expect(result == .double(3.14))
    }

    @Test("jsonValueFromAny: Bool true")
    func jsonBoolTrue() {
        let result = BackendClient.jsonValueFromAny(true)
        #expect(result == .bool(true))
    }

    @Test("jsonValueFromAny: Bool false")
    func jsonBoolFalse() {
        let result = BackendClient.jsonValueFromAny(false)
        #expect(result == .bool(false))
    }

    @Test("jsonValueFromAny: Array")
    func jsonArray() {
        let result = BackendClient.jsonValueFromAny(["a", "b"])
        #expect(result == .array([.string("a"), .string("b")]))
    }

    @Test("jsonValueFromAny: Dictionary")
    func jsonDict() {
        let result = BackendClient.jsonValueFromAny(["key": "value"])
        #expect(result == .dictionary(["key": .string("value")]))
    }

    @Test("jsonValueFromAny: Nested structures")
    func jsonNested() {
        let input: [String: Any] = ["items": [1, 2], "flag": true]
        let result = BackendClient.jsonValueFromAny(input)
        if case .dictionary(let dict) = result {
            #expect(dict["items"] == .array([.int(1), .int(2)]))
            #expect(dict["flag"] == .bool(true))
        } else {
            Issue.record("Expected dictionary")
        }
    }

    @Test("jsonValueFromAny: unknown type returns nil")
    func jsonUnknown() {
        let result = BackendClient.jsonValueFromAny(Date())
        #expect(result == nil)
    }

    // MARK: - parseSSEStream

    @Test("parseSSEStream: simple final event returns CompletionsFinalEvent")
    func parseSimpleFinal() async throws {
        let client = BackendClient()
        let text = """
        event: final
        data: {"assistant":"Hello world"}

        """
        let result = try await client.parseSSEStream(text, onSSEEvent: nil)
        #expect(result.assistant == "Hello world")
    }

    // MARK: - SSE primer (comment line) handling
    //
    // The backend prepends a ≥512-byte `:` comment line to every SSE stream
    // to cross iOS URLSession's initial-batch buffer (Apple Dev Forums thread
    // 64875). SSE comment lines are valid per spec and must be ignored by
    // parsers. These tests verify our parsers tolerate the primer.

    @Test("parseSSEStream: ignores leading SSE comment primer")
    func parseIgnoresPrimer() async throws {
        let client = BackendClient()
        let primer = ":" + String(repeating: " ", count: 1500)
        let text = """
        \(primer)

        event: keepalive
        data: {}

        event: final
        data: {"assistant":"ok"}

        """
        let result = try await client.parseSSEStream(text, onSSEEvent: nil)
        #expect(result.assistant == "ok")
    }

    @Test("parseSSEStream: ignores multiple comment lines per SSE spec")
    func parseIgnoresMultipleComments() async throws {
        let client = BackendClient()
        let text = """
        : first comment
        : second comment

        event: final
        data: {"assistant":"hi"}

        """
        let result = try await client.parseSSEStream(text, onSSEEvent: nil)
        #expect(result.assistant == "hi")
    }

    @Test("extractSSEFinalData: ignores leading primer")
    func extractIgnoresPrimer() async {
        let client = BackendClient()
        let primer = ":" + String(repeating: " ", count: 1500)
        let text = """
        \(primer)

        event: final
        data: {"assistant":"Result"}

        """
        let result = await client.extractSSEFinalData(text)
        #expect(result == "{\"assistant\":\"Result\"}")
    }

    @Test("parseSSEStream: flushes previous event when a new event: line arrives (no empty line between)")
    func parseFlushesOnNewEventLine() async throws {
        // URLSession.AsyncBytes.lines has been observed not to yield empty lines
        // between consecutive SSE events. The parser must flush the previous
        // event when it sees a new `event:` line, otherwise events get dropped
        // and the counter stays at 0 despite the stream working.
        let client = BackendClient()
        // No empty line between keepalive and final (CF/URLSession behavior)
        let text = "event: keepalive\ndata: {}\nevent: final\ndata: {\"assistant\":\"hi\"}\n"
        let collected = Mutex<[String]>([])
        let handler: BackendClient.SSEEventHandler = { event in
            let name: String
            switch event {
            case .keepalive: name = "keepalive"
            case .toolStarted: name = "tool_started"
            case .toolCompleted: name = "tool_completed"
            case .toolFailed: name = "tool_failed"
            case .final: name = "final"
            case .error: name = "error"
            case .throttled: name = "throttled"
            case .throttleEnded: name = "throttleEnded"
            }
            collected.withLock { $0.append(name) }
        }
        let result = try await client.parseSSEStream(text, onSSEEvent: handler)
        #expect(result.assistant == "hi")
        let events = collected.withLock { $0 }
        // Both keepalive and final should have fired
        #expect(events.contains("keepalive"))
        #expect(events.contains("final"))
    }

    @Test("parseSSEStream: flushes final event at stream end without trailing empty line")
    func parseFlushesAtStreamEnd() async throws {
        // Stream ends right after `data:` line with no trailing newlines.
        // AsyncBytes.lines won't yield an empty terminator — parser must
        // flush at end-of-iteration.
        let client = BackendClient()
        let text = "event: final\ndata: {\"assistant\":\"done\"}"
        let collected = Mutex<[String]>([])
        let handler: BackendClient.SSEEventHandler = { event in
            if case .final = event {
                collected.withLock { $0.append("final") }
            }
        }
        let result = try await client.parseSSEStream(text, onSSEEvent: handler)
        #expect(result.assistant == "done")
        #expect(collected.withLock { $0 } == ["final"])
    }

    // MARK: - parseSSELines (real streaming via mock AsyncSequence)
    //
    // These tests exercise the incremental SSE reader end-to-end by feeding
    // it a mock AsyncSequence<String> of lines. They verify heartbeat
    // accounting, primer handling, watchdog timeout, and missing-empty-line
    // tolerance under realistic streaming conditions.

    @Test("parseSSELines: counts every keepalive heartbeat as it arrives")
    func parseSSELinesCountsHeartbeats() async throws {
        // Simulates backend sending: primer, 3 heartbeats with small delays, final.
        let logs = Mutex<[String]>([])
        let stream = MockLineStream(lines: [
            (delay: 0.00, line: ":" + String(repeating: " ", count: 1500)),
            (delay: 0.00, line: ""),
            (delay: 0.01, line: "event: keepalive"),
            (delay: 0.00, line: "data: {}"),
            (delay: 0.00, line: ""),
            (delay: 0.02, line: "event: keepalive"),
            (delay: 0.00, line: "data: {}"),
            (delay: 0.00, line: ""),
            (delay: 0.02, line: "event: keepalive"),
            (delay: 0.00, line: "data: {}"),
            (delay: 0.00, line: ""),
            (delay: 0.02, line: "event: final"),
            (delay: 0.00, line: "data: {\"assistant\":\"hi\"}"),
            (delay: 0.00, line: ""),
        ])
        let data = try await BackendClient.parseSSELines(
            lines: stream,
            heartbeatTimeout: 2.0,
            httpT0: CFAbsoluteTimeGetCurrent(),
            onSSEEvent: nil,
            log: { msg in logs.withLock { $0.append(msg) } }
        )
        let decoded = try JSONDecoder().decode(CompletionsFinalEvent.self, from: data)
        #expect(decoded.assistant == "hi")

        let logList = logs.withLock { $0 }
        // Should have logged exactly 3 heartbeats
        let heartbeats = logList.filter { $0.contains("heartbeat #") }
        #expect(heartbeats.count == 3)
        // And a final event
        #expect(logList.contains { $0.contains("final event received") })
        // Completion log
        #expect(logList.contains { $0.contains("SSE complete") })
    }

    @Test("parseSSELines: tolerates missing empty lines between events")
    func parseSSELinesToleratesMissingEmptyLines() async throws {
        // AsyncBytes.lines sometimes doesn't yield the empty line between events.
        // The parser should still dispatch each event on the next `event:` line.
        let logs = Mutex<[String]>([])
        let stream = MockLineStream(lines: [
            (delay: 0.0, line: "event: keepalive"),
            (delay: 0.0, line: "data: {}"),
            // NO empty line here
            (delay: 0.0, line: "event: keepalive"),
            (delay: 0.0, line: "data: {}"),
            // NO empty line here either
            (delay: 0.0, line: "event: final"),
            (delay: 0.0, line: "data: {\"assistant\":\"ok\"}"),
            // And none at the end
        ])
        let data = try await BackendClient.parseSSELines(
            lines: stream,
            heartbeatTimeout: 2.0,
            httpT0: CFAbsoluteTimeGetCurrent(),
            onSSEEvent: nil,
            log: { msg in logs.withLock { $0.append(msg) } }
        )
        let decoded = try JSONDecoder().decode(CompletionsFinalEvent.self, from: data)
        #expect(decoded.assistant == "ok")
        let logList = logs.withLock { $0 }
        // Both heartbeats should have been counted even without boundary empty lines
        let heartbeats = logList.filter { $0.contains("heartbeat #") }
        #expect(heartbeats.count == 2)
    }

    @Test("parseSSELines: watchdog fires when no line arrives within timeout")
    func parseSSELinesWatchdogFires() async {
        let stream = MockLineStream(lines: [
            (delay: 0.0, line: "event: keepalive"),
            (delay: 0.0, line: "data: {}"),
            (delay: 0.0, line: ""),
            // Then a long pause longer than heartbeatTimeout before next line
            (delay: 0.5, line: "event: final"),
            (delay: 0.0, line: "data: {\"assistant\":\"x\"}"),
            (delay: 0.0, line: ""),
        ])
        do {
            _ = try await BackendClient.parseSSELines(
                lines: stream,
                heartbeatTimeout: 0.2, // 200ms < 500ms gap → should fire
                httpT0: CFAbsoluteTimeGetCurrent(),
                onSSEEvent: nil,
                log: { _ in }
            )
            Issue.record("Expected watchdog to throw but stream completed")
        } catch {
            // Expected
        }
    }

    @Test("parseSSELines: primer is ignored and first heartbeat still counts correctly")
    func parseSSELinesPrimerIgnored() async throws {
        let logs = Mutex<[String]>([])
        let stream = MockLineStream(lines: [
            // Realistic production stream: primer chunk, then keepalive, then final.
            (delay: 0.0, line: ":" + String(repeating: " ", count: 1500)),
            (delay: 0.0, line: ""),
            (delay: 0.0, line: "event: keepalive"),
            (delay: 0.0, line: "data: {}"),
            (delay: 0.0, line: ""),
            (delay: 0.0, line: "event: final"),
            (delay: 0.0, line: "data: {\"assistant\":\"hello\"}"),
            (delay: 0.0, line: ""),
        ])
        let data = try await BackendClient.parseSSELines(
            lines: stream,
            heartbeatTimeout: 5.0,
            httpT0: CFAbsoluteTimeGetCurrent(),
            onSSEEvent: nil,
            log: { msg in logs.withLock { $0.append(msg) } }
        )
        let decoded = try JSONDecoder().decode(CompletionsFinalEvent.self, from: data)
        #expect(decoded.assistant == "hello")
        let logList = logs.withLock { $0 }
        let heartbeats = logList.filter { $0.contains("heartbeat #") }
        #expect(heartbeats.count == 1)
    }

    @Test("parseSSELines: stream ending without trailing empty line still flushes final event")
    func parseSSELinesFlushesOnEnd() async throws {
        let logs = Mutex<[String]>([])
        let stream = MockLineStream(lines: [
            (delay: 0.0, line: "event: final"),
            (delay: 0.0, line: "data: {\"assistant\":\"end\"}"),
            // No empty line — AsyncBytes.lines frequently does this at stream end
        ])
        let data = try await BackendClient.parseSSELines(
            lines: stream,
            heartbeatTimeout: 5.0,
            httpT0: CFAbsoluteTimeGetCurrent(),
            onSSEEvent: nil,
            log: { msg in logs.withLock { $0.append(msg) } }
        )
        let decoded = try JSONDecoder().decode(CompletionsFinalEvent.self, from: data)
        #expect(decoded.assistant == "end")
        // Final event should have been logged
        #expect(logs.withLock { $0 }.contains { $0.contains("final event received") })
    }

    @Test("parseSSEStream: multiple event types calls handler for each")
    func parseMultipleEvents() async throws {
        let client = BackendClient()
        let text = """
        event: keepalive
        data: {}

        event: tool_started
        data: {"tool_name":"search"}

        event: tool_completed
        data: {"tool_name":"search","success":true}

        event: final
        data: {"assistant":"Done"}

        """
        let collected = Mutex<[String]>([])
        let handler: BackendClient.SSEEventHandler = { event in
            let name: String
            switch event {
            case .keepalive: name = "keepalive"
            case .toolStarted: name = "tool_started"
            case .toolCompleted: name = "tool_completed"
            case .toolFailed: name = "tool_failed"
            case .final: name = "final"
            case .error: name = "error"
            case .throttled: name = "throttled"
            case .throttleEnded: name = "throttleEnded"
            }
            collected.withLock { $0.append(name) }
        }
        _ = try await client.parseSSEStream(text, onSSEEvent: handler)
        let events = collected.withLock { $0 }
        #expect(events.contains("keepalive"))
        #expect(events.contains("tool_started"))
        #expect(events.contains("tool_completed"))
        #expect(events.contains("final"))
    }

    @Test("parseSSEStream: no final event throws")
    func parseNoFinalThrows() async {
        let client = BackendClient()
        let text = """
        event: keepalive
        data: {}

        """
        do {
            _ = try await client.parseSSEStream(text, onSSEEvent: nil)
            Issue.record("Expected error")
        } catch {
            // Expected -- BackendError.requestFailed
        }
    }

    @Test("parseSSEStream: error event calls handler")
    func parseErrorEvent() async throws {
        let client = BackendClient()
        let text = """
        event: error
        data: Something went wrong

        event: final
        data: {"error":"Something went wrong"}

        """
        let collected = Mutex<String?>(nil)
        let handler: BackendClient.SSEEventHandler = { event in
            if case .error(let msg) = event {
                collected.withLock { $0 = msg }
            }
        }
        _ = try await client.parseSSEStream(text, onSSEEvent: handler)
        let errorMessage = collected.withLock { $0 }
        #expect(errorMessage == "Something went wrong")
    }

    @Test("parseSSEStream: tool_failed event calls handler")
    func parseToolFailed() async throws {
        let client = BackendClient()
        let text = """
        event: tool_failed
        data: {"tool_name":"search","success":false,"error":"timeout"}

        event: final
        data: {"assistant":"Sorry"}

        """
        let collected = Mutex<String?>(nil)
        let handler: BackendClient.SSEEventHandler = { event in
            if case .toolFailed(let status) = event {
                collected.withLock { $0 = status.tool_name }
            }
        }
        _ = try await client.parseSSEStream(text, onSSEEvent: handler)
        let failedTool = collected.withLock { $0 }
        #expect(failedTool == "search")
    }
}

// MARK: - Mock AsyncSequence for streaming tests

/// Mock AsyncSequence that yields pre-recorded lines with optional delays between them.
/// Mirrors URLSession.AsyncBytes.lines behavior for testing the SSE parser without
/// hitting the network.
struct MockLineStream: AsyncSequence {
    typealias Element = String
    let lines: [(delay: TimeInterval, line: String)]

    func makeAsyncIterator() -> Iterator {
        Iterator(lines: lines)
    }

    struct Iterator: AsyncIteratorProtocol {
        var lines: [(delay: TimeInterval, line: String)]
        var index = 0

        mutating func next() async throws -> String? {
            guard index < lines.count else { return nil }
            let entry = lines[index]
            index += 1
            if entry.delay > 0 {
                try await Task.sleep(for: .seconds(entry.delay))
            }
            return entry.line
        }
    }
}

@Suite("BackendClient final-event truncation discriminator")
struct BackendClientFinalDecodeTests {

    @Test("complete valid final JSON decodes")
    func completeDecodes() throws {
        let json = #"{"assistant":"Hello there","token_usage":null}"#
        let event = try BackendClient.decodeFinalEvent(Data(json.utf8))
        #expect(event.assistant == "Hello there")
    }

    @Test("truncated final JSON throws streamTruncated (resumable)")
    func truncatedThrowsStreamTruncated() {
        // Tail cut mid-string — not parseable as JSON → resumable connection-lost.
        let json = #"{"assistant":"Hello there, here is the long ans"#
        #expect {
            _ = try BackendClient.decodeFinalEvent(Data(json.utf8))
        } throws: { error in
            guard case BackendError.streamTruncated = error else { return false }
            return true
        }
    }

    @Test("empty final body throws streamTruncated")
    func emptyThrowsStreamTruncated() {
        #expect {
            _ = try BackendClient.decodeFinalEvent(Data())
        } throws: { error in
            guard case BackendError.streamTruncated = error else { return false }
            return true
        }
    }

    @Test("well-formed JSON of the wrong shape is NOT treated as truncation")
    func wrongShapeIsNotTruncation() {
        // Valid JSON (an array), but not a CompletionsFinalEvent object. This is a
        // contract error, not a cut stream — it must surface as the real decode
        // error, NOT be silently classified as resumable truncation.
        #expect {
            _ = try BackendClient.decodeFinalEvent(Data("[1,2,3]".utf8))
        } throws: { error in
            if case BackendError.streamTruncated = error { return false }
            return true  // any other error (the real DecodingError) is correct
        }
    }
}

@Suite("BackendClient truncation → resumable (integration)")
struct BackendClientResumeIntegrationTests {

    /// SSE primer the backend prepends (≥512-byte `:` comment) — included so the
    /// mock streams match production framing.
    private static let primer = ":" + String(repeating: " ", count: 600) + "\n\n"

    @Test("truncated streaming final → ChatConnectionLostError carrying conversation_state")
    func truncatedYieldsResumable() async {
        FakeHTTP.reset()
        defer { FakeHTTP.reset() }
        // A `final` event whose JSON is cut mid-token, then the stream ends. The
        // parser flushes the partial final → decodeFinalEvent can't parse it →
        // streamTruncated → the tool loop converts it to ChatConnectionLostError.
        let body = Self.primer
            + "event: keepalive\ndata: {}\n\n"
            + "event: final\ndata: {\"assistant\":\"this got cut o"
        FakeHTTP.register(
            path: "/completions/chat", method: "POST",
            response: .bytes(Data(body.utf8), contentType: "text/event-stream", statusCode: 200)
        )
        let client = BackendClient(llmSession: FakeHTTP.makeSession())

        let msg = HarmonyMessage(role: "tool", content: "search result", thinking: nil, tool_calls: nil, tool_call_id: "call-1")
        let convState = ConversationState(harmony_messages: [msg], current_round: 3)
        let request = CompletionsRequest(messages: [], client_timezone: "UTC", disable_tools: nil, conversation_state: convState)

        do {
            _ = try await client.sendCompletionsWithToolsDirect(request)
            Issue.record("expected ChatConnectionLostError, but the call returned normally")
        } catch let error as ChatConnectionLostError {
            // The resumable error must carry the failed round's input — the saved
            // conversation_state — so resume continues from completed tool work.
            #expect(error.resumeRequest.conversation_state?.current_round == 3)
            #expect(error.resumeRequest.conversation_state?.harmony_messages.count == 1)
        } catch {
            Issue.record("expected ChatConnectionLostError, got \(error)")
        }
    }

    @Test("complete streaming final decodes — no false truncation")
    func completeFinalDecodes() async {
        FakeHTTP.reset()
        defer { FakeHTTP.reset() }
        let body = Self.primer + "event: final\ndata: {\"assistant\":\"all good\"}\n\n"
        FakeHTTP.register(
            path: "/completions/chat", method: "POST",
            response: .bytes(Data(body.utf8), contentType: "text/event-stream", statusCode: 200)
        )
        let client = BackendClient(llmSession: FakeHTTP.makeSession())
        let request = CompletionsRequest(messages: [], client_timezone: "UTC", disable_tools: nil)

        do {
            let resp = try await client.sendCompletionsWithToolsDirect(request)
            #expect(resp.assistant == "all good")
        } catch {
            Issue.record("expected a successful decode, got \(error)")
        }
    }
}

// JSONValue needs Equatable for test assertions
extension JSONValue: @retroactive Equatable {
    public static func == (lhs: JSONValue, rhs: JSONValue) -> Bool {
        switch (lhs, rhs) {
        case (.string(let a), .string(let b)): return a == b
        case (.bool(let a), .bool(let b)): return a == b
        case (.int(let a), .int(let b)): return a == b
        case (.double(let a), .double(let b)): return a == b
        case (.array(let a), .array(let b)): return a == b
        case (.dictionary(let a), .dictionary(let b)): return a == b
        default: return false
        }
    }
}
