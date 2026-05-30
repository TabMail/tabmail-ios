/* This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at https://mozilla.org/MPL/2.0/. */

import Foundation

// MARK: - Tool Protocol & Registry

/// A client-side tool that can be executed by the AI agent.
/// Matches TB addon's tool pattern: name, schema, execute function.
///
/// Tools are registered in `ToolRegistry` and invoked by the multi-turn
/// tool execution loop in `BackendClient.sendCompletionsWithTools()`.
protocol AgentTool: Sendable {
    /// Unique tool name matching the backend tool definition (e.g., "email_search").
    var name: String { get }

    /// Execute the tool with the given arguments.
    /// Returns a JSON-encodable result string, matching TB's `{ call_id, output, ok }` pattern.
    func execute(arguments: [String: JSONValue]) async throws -> String
}

/// Central registry for client-side tools available to the AI agent.
/// Matches TB addon's `core.js` tool registry pattern.
///
/// Tools are registered at app startup. The tool execution loop in
/// `BackendClient.sendCompletionsWithTools()` looks up tools by name
/// and invokes them when the backend returns `tool_calls`.
///
/// All client-side tools are registered at startup (TabMailApp.swift).
/// Reply precompute, inline edit, and agent chat all use tools via sendCompletionsWithTools().
actor ToolRegistry {
    static let shared = ToolRegistry()

    private var tools: [String: any AgentTool] = [:]

    /// Register a tool. Overwrites any existing tool with the same name.
    func register(_ tool: any AgentTool) {
        tools[tool.name] = tool
        print("[ToolRegistry] Registered tool: \(tool.name)")
    }

    /// Register all tools in a single actor call (avoids per-tool main→actor→main hops).
    func registerAll(_ tools: [any AgentTool]) {
        for tool in tools {
            self.tools[tool.name] = tool
            print("[ToolRegistry] Registered tool: \(tool.name)")
        }
    }

    /// Look up a tool by name.
    func tool(named name: String) -> (any AgentTool)? {
        tools[name]
    }

    /// All registered tool names (for debugging/logging).
    func registeredNames() -> [String] {
        Array(tools.keys).sorted()
    }

    /// Execute a tool call. Returns the result string and success flag.
    /// Matches TB's `executeToolByName()` in `core.js`.
    func execute(name: String, arguments: [String: JSONValue]) async -> ToolExecutionResult {
        guard let tool = tools[name] else {
            print("[ToolRegistry] Unknown tool: \(name)")
            return ToolExecutionResult(output: "Error: unknown tool '\(name)'", ok: false)
        }

        do {
            let output = try await tool.execute(arguments: arguments)
            return ToolExecutionResult(output: output, ok: true)
        } catch let declined as ToolDeclinedError {
            print("[ToolRegistry] Tool '\(name)' declined by user")
            return ToolExecutionResult(output: declined.output, ok: false)
        } catch {
            print("[ToolRegistry] Tool '\(name)' failed: \(error)")
            return ToolExecutionResult(output: "Error executing \(name): \(error.localizedDescription)", ok: false)
        }
    }
}

// MARK: - Tool JSON Helper

/// Safely encode a `[String: Any]` dictionary to a JSON string.
/// Works around Swift-to-ObjC bridging issues where `__SwiftValue` wrapping
/// causes `JSONSerialization` to throw "Invalid type in JSON write".
/// Explicitly bridges Int/Double/Bool/String/Array values to Foundation types.
enum ToolJSON {
    static func string(from dict: [String: Any]) -> String {
        let nsDict = NSMutableDictionary(capacity: dict.count)
        for (key, value) in dict {
            nsDict[key] = bridgeValue(value)
        }
        guard let data = try? JSONSerialization.data(withJSONObject: nsDict),
              let json = String(data: data, encoding: .utf8) else { return "{}" }
        return json
    }

    private static func bridgeValue(_ value: Any) -> Any {
        switch value {
        case let s as String: return s as NSString
        case let b as Bool: return NSNumber(value: b)
        case let i as Int: return NSNumber(value: i)
        case let d as Double: return NSNumber(value: d)
        case let arr as [String]: return arr as NSArray
        case let arr as [Int]: return arr.map { NSNumber(value: $0) } as NSArray
        case let arr as [Any]: return arr.map { bridgeValue($0) } as NSArray
        default: return "\(value)" as NSString
        }
    }
}

// MARK: - Tool Execution Types

/// Result of a single tool execution, matching TB's `{ call_id, output, ok }`.
struct ToolExecutionResult: Sendable {
    let output: String
    let ok: Bool
}

/// Thrown by tools when the user declines a confirmation prompt.
/// Carries the structured JSON output so the LLM gets a meaningful error message.
/// The ToolRegistry catches this and returns `ok: false` with the output.
struct ToolDeclinedError: Error {
    let output: String
}

// MARK: - SSE Event Types (matching TB's backend SSE protocol)

/// Parsed SSE event from the completions endpoint.
/// Matches TB's `readSSEStream()` event types in `llm.js`.
enum CompletionsSSEEvent: Sendable {
    /// Connection keepalive (no-op).
    case keepalive

    /// Server-side tool execution started.
    case toolStarted(ToolStatusEvent)

    /// Server-side tool execution completed.
    case toolCompleted(ToolStatusEvent)

    /// Server-side tool execution failed.
    case toolFailed(ToolStatusEvent)

    /// Final response — either complete response or tool_calls for client execution.
    case final(CompletionsFinalEvent)

    /// Request throttled (429) — slow queue rate limited. UI should show upgrade hint.
    case throttled

    /// Throttle ended — request succeeded after being throttled.
    case throttleEnded

    /// Error from the backend.
    case error(String)
}

/// Server-side tool execution status event.
struct ToolStatusEvent: Sendable, Decodable {
    let execution_id: String?
    let call_id: String?
    let display_label: String?
    let tool_name: String?
    let success: Bool?
    let elapsed_ms: Int?
    let error: String?
    let result: String?
}

/// Final event data from completions SSE stream.
/// Can contain either a direct response or tool_calls for client execution.
struct CompletionsFinalEvent: Sendable, Decodable {
    /// Final assistant text (when no client-side tools needed).
    let assistant: String?

    /// Token usage statistics.
    let token_usage: TokenUsage?

    /// Error message from the backend.
    let error: String?

    /// Client-side tool calls to execute (multi-turn loop).
    let tool_calls: [CompletionsToolCall]?

    /// Conversation state for multi-turn tool loop continuation.
    let conversation_state: ConversationState?

    /// Extended thinking / reasoning content from the LLM.
    let thinking: String?

    // BYOK response envelope. The backend
    // sets these on the final event for BYOK requests; without decoding them
    // here the tool-loop path (sendCompletionsWithTools) silently drops them
    // when reconstructing CompletionsResponse — so BYOK error codes never
    // reach the client on the agent/compose paths. (Bug fixed 2026-05-22.)
    let byok_routed: Bool?
    let byok_provider: String?
    let byok_tier: String?
    let byok_skip_reason: String?
    let error_code: String?
    let error_detail: String?
    let retry_after_seconds: Int?

    init(
        assistant: String?,
        token_usage: TokenUsage?,
        error: String?,
        tool_calls: [CompletionsToolCall]?,
        conversation_state: ConversationState?,
        thinking: String?,
        byok_routed: Bool? = nil,
        byok_provider: String? = nil,
        byok_tier: String? = nil,
        byok_skip_reason: String? = nil,
        error_code: String? = nil,
        error_detail: String? = nil,
        retry_after_seconds: Int? = nil
    ) {
        self.assistant = assistant
        self.token_usage = token_usage
        self.error = error
        self.tool_calls = tool_calls
        self.conversation_state = conversation_state
        self.thinking = thinking
        self.byok_routed = byok_routed
        self.byok_provider = byok_provider
        self.byok_tier = byok_tier
        self.byok_skip_reason = byok_skip_reason
        self.error_code = error_code
        self.error_detail = error_detail
        self.retry_after_seconds = retry_after_seconds
    }
}

/// A tool call from the backend, matching OpenAI function calling format.
/// TB's `llm.js` parses these from the `final` SSE event.
struct CompletionsToolCall: Sendable, Codable {
    let id: String
    let function: ToolFunction

    /// Opaque provider passthrough. Gemini 3 (BYOK Google) attaches a
    /// `{ "google": { "thought_signature": "…" } }` envelope to each tool call
    /// and rejects the NEXT turn ("Function call is missing a thought_signature")
    /// unless it's echoed back verbatim on the same tool_call. This field carries
    /// it across the client-side multi-turn boundary: it lives inside
    /// `conversation_state.harmony_messages[].tool_calls[]`, which iOS decodes and
    /// re-encodes between rounds. We NEVER read into it — it is round-tripped as-is
    /// so the signature survives. Absent for every other provider (omitted on
    /// encode, so non-Gemini payloads are byte-identical). The backend analogue is
    /// `ToolCall.extra_content`; this is the iOS half of the same payload contract.
    let extra_content: JSONValue?

    init(id: String, function: ToolFunction, extra_content: JSONValue? = nil) {
        self.id = id
        self.function = function
        self.extra_content = extra_content
    }

    struct ToolFunction: Sendable, Codable {
        let name: String
        let arguments: String // JSON string — parsed by tool executor
    }
}

/// Conversation state passed between multi-turn tool execution rounds.
/// Matches TB's `conversationState` structure in `llm.js`.
struct ConversationState: Sendable, Codable {
    var harmony_messages: [HarmonyMessage]
    var tool_traces: [ToolTrace]?
    var current_round: Int
    var ts_ms: Double?
    var malformed_retry_count: Int?
    var max_rounds_malformed_retry_count: Int?
}

/// A message in the conversation state (system/user/assistant/tool).
struct HarmonyMessage: Sendable, Codable {
    let role: String
    let content: String?
    let thinking: String?
    let tool_calls: [CompletionsToolCall]?
    let tool_call_id: String?
}

/// Record of a tool execution for debugging/tracing.
struct ToolTrace: Sendable, Codable {
    let name: String
    let call_id: String
    let execution_id: String?
    let result: String?
    let success: Bool
    let server_side: Bool?
}

// MARK: - Tool Result (sent back to backend)

/// Tool result appended to conversation_state, matching TB's format.
struct ToolResult: Sendable, Codable {
    let call_id: String
    let output: String
    let ok: Bool
}
