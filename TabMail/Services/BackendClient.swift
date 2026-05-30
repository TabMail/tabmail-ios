/* This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at https://mozilla.org/MPL/2.0/. */

import Foundation
import Synchronization

actor BackendClient {
    // MARK: - LLM Semaphore (concurrency limiter for backend AI calls)

    /// Internal semaphore limiting concurrent LLM API calls.
    /// Matches TB's `_llmSemaphore` in llm.js — counter + FIFO waiter queue.
    /// All `sendCompletions` / `sendCompletionsWithTools` acquire a slot before the HTTP call.
    /// "Direct" variants bypass the semaphore for user-initiated calls (agent chat, inline edit).
    private let llmSemaphore = LLMSemaphore()
    static let clientVersion = Bundle.main.infoDictionary?["TabMailProtocolVersion"] as? String ?? "1.0.0"

    private var baseURL: URL { BackendConfig.apiBaseURL }

    // HTTP calls use sharedEphemeralSession (defined in HTTPProviderRequest.swift).
    // Recreated on session start via resetHTTPSession() to clear stale connections.

    /// Dedicated URLSession for LLM completions with timeoutIntervalForResource.
    /// timeoutIntervalForResource caps the TOTAL request time regardless of bytes received,
    /// preventing stalled connections from holding semaphore slots for 5-16 minutes.
    /// The shared ephemeral session doesn't have this because it serves all HTTP traffic.
    private let llmSession: URLSession = {
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForResource = SyncConfig.llmResourceTimeoutSeconds
        return URLSession(configuration: config)
    }()

    // 403 exponential backoff state — shared across all completions requests.
    // When the backend returns 403 (unauthorized/dev-access-denied), we back off
    // exponentially (1s → 2s → 4s → ... → 5min cap) to avoid hammering the server.
    private var forbiddenBackoffUntil: Date = .distantPast
    private var forbiddenBackoffDelay: TimeInterval = 0

    private static let forbiddenInitialDelay: TimeInterval = 1
    private static let forbiddenMaxDelay: TimeInterval = 300 // 5 minutes

    /// Check if we're in a 403 backoff window. Throws `.forbidden` if so.
    private func checkForbiddenBackoff() throws {
        let now = Date()
        if now < forbiddenBackoffUntil {
            let remaining = forbiddenBackoffUntil.timeIntervalSince(now)
            print("[BackendClient] 403 backoff active — \(String(format: "%.0f", remaining))s remaining, skipping request")
            throw BackendError.forbidden
        }
    }

    /// Record a 403 response — escalate the backoff delay.
    private func recordForbidden() {
        if forbiddenBackoffDelay == 0 {
            forbiddenBackoffDelay = Self.forbiddenInitialDelay
        } else {
            forbiddenBackoffDelay = min(forbiddenBackoffDelay * 2, Self.forbiddenMaxDelay)
        }
        forbiddenBackoffUntil = Date().addingTimeInterval(forbiddenBackoffDelay)
        print("[BackendClient] 403 received — backing off for \(String(format: "%.0f", forbiddenBackoffDelay))s")
    }

    /// Reset 403 backoff on any successful response.
    private func resetForbiddenBackoff() {
        if forbiddenBackoffDelay > 0 {
            print("[BackendClient] Resetting 403 backoff after successful response")
            forbiddenBackoffDelay = 0
            forbiddenBackoffUntil = .distantPast
        }
    }

    /// Fresh auth token, refreshing via shared coordinator if expired.
    /// In demo mode, pulls the demo JWT from `DemoTokenManager` instead of
    /// the Supabase session — the demo flow never has a Supabase user, so
    /// the production coordinator returns `.noSession` and chat 401s.
    private func currentAuthToken() async -> String? {
        let inDemo = await MainActor.run { DemoModeStore.shared.isActive }
        if inDemo {
            switch await DemoTokenManager.shared.validToken() {
            case .success(let token):
                return token
            case .configMissing, .transientFailure:
                return nil
            }
        }
        switch await TabMailTokenCoordinator.shared.validToken() {
        case .success(let token):
            return token
        case .permanentFailure, .transientFailure, .noSession:
            return nil
        }
    }

    struct ChatRequest: Encodable {
        let message: String
        let context: MessageContext?
        let conversationId: String?
    }

    struct MessageContext: Encodable {
        let messageId: String
        let subject: String
        let from: String
        let snippet: String
    }

    struct ChatResponse: Decodable {
        let reply: String
        let toolCalls: [ToolCall]?
        let conversationId: String
    }

    struct ToolCall: Decodable {
        let name: String
        let arguments: [String: String]
    }

    func sendChat(_ request: ChatRequest) async throws -> ChatResponse {
        var urlRequest = URLRequest(url: baseURL.appending(path: "/v1/chat"))
        urlRequest.httpMethod = "POST"
        urlRequest.setValue("application/json", forHTTPHeaderField: "Content-Type")
        urlRequest.setValue("ios", forHTTPHeaderField: "X-Client-Type")
        urlRequest.setValue(Self.clientVersion, forHTTPHeaderField: "X-Client-Version")
        if let token = await currentAuthToken() {
            urlRequest.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        }

        urlRequest.httpBody = try JSONEncoder().encode(request)

        let (data, response) = try await sharedEphemeralSession.data(for: urlRequest)
        guard let httpResponse = response as? HTTPURLResponse,
              200..<300 ~= httpResponse.statusCode else {
            throw BackendError.requestFailed(
                statusCode: (response as? HTTPURLResponse)?.statusCode ?? 0
            )
        }

        return try JSONDecoder().decode(ChatResponse.self, from: data)
    }
}

// MARK: - Report Concern

extension BackendClient {
    /// Submit a content concern report to the backend.
    func reportConcern(contentType: String, content: String, category: String?, reason: String?) async -> Bool {
        guard let token = await currentAuthToken() else { return false }

        let url = baseURL.appending(path: "/report-concern")
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("ios", forHTTPHeaderField: "X-Client-Type")
        request.setValue(Self.clientVersion, forHTTPHeaderField: "X-Client-Version")

        var body: [String: String] = [
            "content_type": contentType,
            "content": String(content.prefix(5000))
        ]
        if let category {
            body["category"] = category
        }
        if let reason {
            body["reason"] = String(reason.prefix(500))
        }
        request.httpBody = try? JSONSerialization.data(withJSONObject: body)

        do {
            let (_, response) = try await sharedEphemeralSession.data(for: request)
            return (response as? HTTPURLResponse)?.statusCode == 201
        } catch {
            print("[BackendClient] reportConcern failed: \(error)")
            return false
        }
    }
}

// MARK: - Completions API (summary/action generation)

/// Flexible coding key for dynamic JSON encoding.
struct DynamicCodingKey: CodingKey {
    var stringValue: String
    var intValue: Int?
    init(_ string: String) { self.stringValue = string; self.intValue = nil }
    init?(stringValue: String) { self.stringValue = stringValue; self.intValue = nil }
    init?(intValue: Int) { return nil }
}

/// A JSON value that can be String, Bool, Int, Double, Array, or Dictionary — for encoding template variables.
enum JSONValue: Sendable, Codable {
    case string(String)
    case bool(Bool)
    case int(Int)
    case double(Double)
    case array([JSONValue])
    case dictionary([String: JSONValue])
    case null

    /// Decodes arbitrary JSON into the opaque value tree. Order matters: `Bool`
    /// before the numeric cases (Foundation's JSONDecoder only matches a JSON
    /// boolean to `Bool`, never a number), and the containers last. Used so
    /// provider passthrough blobs (e.g. Gemini's `extra_content`) survive a
    /// decode→re-encode round-trip without any field being interpreted.
    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if container.decodeNil() {
            self = .null
        } else if let v = try? container.decode(Bool.self) {
            self = .bool(v)
        } else if let v = try? container.decode(Int.self) {
            self = .int(v)
        } else if let v = try? container.decode(Double.self) {
            self = .double(v)
        } else if let v = try? container.decode(String.self) {
            self = .string(v)
        } else if let v = try? container.decode([JSONValue].self) {
            self = .array(v)
        } else if let v = try? container.decode([String: JSONValue].self) {
            self = .dictionary(v)
        } else {
            throw DecodingError.dataCorruptedError(
                in: container,
                debugDescription: "Unsupported JSON value in opaque passthrough"
            )
        }
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .string(let v): try container.encode(v)
        case .bool(let v): try container.encode(v)
        case .int(let v): try container.encode(v)
        case .double(let v): try container.encode(v)
        case .array(let v): try container.encode(v)
        case .dictionary(let v): try container.encode(v)
        case .null: try container.encodeNil()
        }
    }

    func encode(to container: inout KeyedEncodingContainer<DynamicCodingKey>, forKey key: DynamicCodingKey) throws {
        switch self {
        case .string(let v): try container.encode(v, forKey: key)
        case .bool(let v): try container.encode(v, forKey: key)
        case .int(let v): try container.encode(v, forKey: key)
        case .double(let v): try container.encode(v, forKey: key)
        case .array(let v): try container.encode(v, forKey: key)
        case .dictionary(let v): try container.encode(v, forKey: key)
        case .null: try container.encodeNil(forKey: key)
        }
    }

    /// Convert an `Any` produced by `Shared/AI/PromptVariables` into a JSONValue for
    /// serialization. Supports the primitive set the builder emits: String, Bool,
    /// Int, Double. Falls back to string description for anything unexpected.
    static func fromAny(_ value: Any) -> JSONValue {
        switch value {
        case let s as String: return .string(s)
        case let b as Bool: return .bool(b)
        case let i as Int: return .int(i)
        case let d as Double: return .double(d)
        default: return .string(String(describing: value))
        }
    }
}

/// A completions message with arbitrary extra variables for prompt expansion.
/// Variables are flattened into top-level JSON keys alongside `role` and `content`.
struct CompletionsMessage: Encodable, Sendable {
    let role: String
    let content: String
    let vars: [String: JSONValue]

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: DynamicCodingKey.self)
        try container.encode(role, forKey: DynamicCodingKey("role"))
        try container.encode(content, forKey: DynamicCodingKey("content"))
        for (key, value) in vars {
            try value.encode(to: &container, forKey: DynamicCodingKey(key))
        }
    }
}

struct CompletionsRequest: Encodable, Sendable {
    let messages: [CompletionsMessage]
    let client_timestamp_ms: Int  // TB sends Date.now() — required for time-relative reasoning
    let client_timezone: String?
    let disable_tools: Bool?
    let web_search_enabled: Bool?
    let conversation_state: ConversationState?
    // BYOK per-tier override. Nil → omitted from JSON, backend routes via our pool
    // (byte-identical to pre-BYOK behavior).
    let byok: BYOKConfig?

    init(
        messages: [CompletionsMessage],
        client_timezone: String?,
        disable_tools: Bool?,
        web_search_enabled: Bool? = nil,
        conversation_state: ConversationState? = nil,
        byok: BYOKConfig? = nil
    ) {
        self.messages = messages
        self.client_timestamp_ms = Int(Date().timeIntervalSince1970 * 1000)
        self.client_timezone = client_timezone
        self.disable_tools = disable_tools
        self.web_search_enabled = web_search_enabled
        self.conversation_state = conversation_state
        self.byok = byok
    }

    // Custom encoder uses encodeIfPresent for every Optional so nil fields are
    // *omitted* (not emitted as null). Required for the byte-identical guarantee:
    // a request with no `byok` must produce the same wire bytes as a pre-BYOK
    // client. Same reasoning applies to web_search_enabled / etc.
    enum CodingKeys: String, CodingKey {
        case messages, client_timestamp_ms, client_timezone, disable_tools
        case web_search_enabled, conversation_state, byok
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(messages, forKey: .messages)
        try c.encode(client_timestamp_ms, forKey: .client_timestamp_ms)
        try c.encodeIfPresent(client_timezone, forKey: .client_timezone)
        try c.encodeIfPresent(disable_tools, forKey: .disable_tools)
        try c.encodeIfPresent(web_search_enabled, forKey: .web_search_enabled)
        try c.encodeIfPresent(conversation_state, forKey: .conversation_state)
        try c.encodeIfPresent(byok, forKey: .byok)
    }
}

struct CompletionsResponse: Decodable, Sendable {
    let assistant: String?
    let token_usage: TokenUsage?
    let error: String?
    let refined_kb: String? // KB refine orchestrator returns refined KB here (system_prompt_kb_refine)
    let thinking: String?   // Extended thinking / reasoning content from the LLM
    // BYOK response flags. Emitted ONLY when the
    // request's resolved BYOK tier had an entry; otherwise all nil and the
    // response stays byte-identical to pre-BYOK behavior.
    let byok_routed: Bool?
    let byok_provider: String?      // "openai" | "anthropic" | "google"
    let byok_tier: String?          // "autocomplete" | "background" | "interactive"
    let byok_skip_reason: String?   // "tier_entry_invalid" | "demo_not_allowed"
    // BYOK provider-error envelope. Populated when
    // the provider rejected the request and we mapped its 4xx/5xx to a code.
    let error_code: String?         // "byok_key_rejected" | "byok_rate_limited" | "byok_provider_down" | "byok_other"
    let error_detail: String?
    let retry_after_seconds: Int?

    init(
        assistant: String?,
        token_usage: TokenUsage?,
        error: String?,
        refined_kb: String? = nil,
        thinking: String? = nil,
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
        self.refined_kb = refined_kb
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

// MARK: - BYOK wire types

/// Per-tier override for `CompletionsRequest.byok`. iOS only ever populates
/// `background` and `interactive` — autocomplete tier is TB-only.
struct BYOKConfig: Codable, Sendable {
    let background: BYOKTierConfig?
    let interactive: BYOKTierConfig?

    init(background: BYOKTierConfig? = nil, interactive: BYOKTierConfig? = nil) {
        self.background = background
        self.interactive = interactive
    }

    /// True iff at least one tier carries a non-pool provider. Used by the
    /// AIService resolver to avoid sending an empty `byok: {}` payload.
    var hasAnyOverride: Bool {
        background != nil || interactive != nil
    }

    enum CodingKeys: String, CodingKey { case background, interactive }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encodeIfPresent(background, forKey: .background)
        try c.encodeIfPresent(interactive, forKey: .interactive)
    }
}

struct BYOKTierConfig: Codable, Sendable {
    let provider: String   // "openai" | "anthropic" | "google" — pool sentinel "tabmail" is filtered before encode
    let api_key: String
    let model: String
}

/// 3-level catalog returned by `GET /byok/models`: provider → tier → [model].
typealias BYOKModelCatalog = [String: [String: [String]]]

/// Response shape of `POST /byok/list-models` — the model IDs the user's key
/// can actually access at the provider. `ok=false` carries a mapped error_code
/// (byok_key_rejected / byok_rate_limited / byok_provider_down / byok_other) +
/// a key-redacted detail.
struct BYOKListModelsResult: Decodable, Sendable {
    let ok: Bool
    let models: [String]?
    let error_code: String?
    let error_detail: String?
    let retry_after_seconds: Int?
}

/// One of the smoke profiles exercised by `runBYOKSmoke`. Each profile picks a
/// real production system prompt + a deterministic user message that forces a
/// specific tool sequence, so per-(tier, model, profile) coverage walks several
/// distinct code paths through the BYOK pipeline.
///
/// The chosen system prompts already live in `systemPromptTiers.json` with
/// their allow-listed tools — no new prompts shipped just for the smoke.
/// `byokTierFor()` on the backend determines which BYOK tier each system
/// prompt resolves to; `appliesTo(tier:)` mirrors that gate so the runner
/// doesn't issue requests that'd route to the wrong tier.
enum BYOKSmokeProfile: String, CaseIterable, Sendable {
    /// Single server-tool call (`date_to_day`) via `system_prompt_compose`
    /// (background tier) or `system_prompt_compose_interactive` (interactive
    /// tier). Both already allow `date_to_day`.
    case compose

    /// Single server-tool call (`time_delta`) via `system_prompt_summary`.
    /// Different tool, different prompt — exercises a separate allow-list and
    /// arithmetic codepath. Background tier only (system_prompt_summary is
    /// tabmail-tier=heavy → BYOK background).
    case summary

    /// Multi-tool sequence — `date_to_day` then `time_delta` via
    /// `system_prompt_agent`. Exercises the multi-turn tool loop end-to-end
    /// (two server-tool round-trips inside a single chat). Interactive tier
    /// only (system_prompt_agent is tabmail-tier=heaviest → BYOK interactive).
    case agentMultiTool

    var displayName: String {
        switch self {
        case .compose:        return "Compose tool"
        case .summary:        return "Summary tool"
        case .agentMultiTool: return "Agent multi-tool"
        }
    }

    func systemPromptName(tier: String) -> String {
        switch self {
        case .compose:
            return tier == "interactive" ? "system_prompt_compose_interactive" : "system_prompt_compose"
        case .summary:
            return "system_prompt_summary"
        case .agentMultiTool:
            return "system_prompt_agent"
        }
    }

    /// Whether this profile maps to the requested BYOK tier via byokTierFor.
    /// Issuing a profile against the wrong tier would route the request to the
    /// other tier's BYOK config — defeating the test's purpose. The runner
    /// must gate on this.
    func appliesTo(tier: String) -> Bool {
        switch self {
        case .compose:        return true
        case .summary:        return tier == "background"
        case .agentMultiTool: return tier == "interactive"
        }
    }

    /// The user message for this profile, built around a `BYOKSmokeFixture`.
    ///
    /// compose/agent are tool-calling prompts (per the prompt catalog), so they
    /// use an arbitrary FUTURE date the model can't guess + an explicit "you
    /// MUST call the tool" instruction — the only way to produce the expected
    /// fragment is to actually call the tool.
    ///
    /// summary is a SUMMARIZATION prompt (catalog: only time_delta, not its
    /// purpose). It does NO tool check — a "call this tool" instruction in a
    /// summarization context reads like a prompt-injection attack and gets
    /// refused (observed live with Claude Sonnet 2026-05-26). Instead it's a
    /// clean summarization task with a distinctive codename the summary must
    /// retain — verifying the BYOK summary path end-to-end without forcing tools.
    func userMessage(_ f: BYOKSmokeFixture) -> String {
        switch self {
        case .compose:
            return "Connectivity self-test. You MUST call the date_to_day tool with date \"\(f.date)\" — do NOT compute or guess the day yourself. After the tool result arrives, reply with exactly one short sentence stating the day of the week, using the exact day name from the tool result. Nothing else."
        case .summary:
            return "Summarize the following note in one short sentence, and keep the project codename exactly as written: \"The \(Self.summaryCodename) migration is on track; the team will finalize the rollout plan and budget next week.\""
        case .agentMultiTool:
            return "Connectivity self-test. You MUST use the tools (do NOT compute anything yourself). Do BOTH: (1) call date_to_day with date \"\(f.date)\". (2) call time_delta with reference \"\(f.date)\" and delta {\"days\": \(f.deltaDays)}. After both tool results arrive, reply with exactly one short sentence containing BOTH the day-of-the-week from (1) and the resulting YYYY-MM-DD date from (2). Nothing else."
        }
    }

    /// Distinctive token the summary task asks the model to retain — used as the
    /// summary profile's text fragment to confirm a real (non-refusal) summary.
    static let summaryCodename = "Zephyr-9"

    /// Tool name(s) that MUST appear in `tool_started` + `tool_completed` events.
    /// EMPTY for summary — per the prompt catalog it's a summarization prompt,
    /// not a tool-calling one, so the runner does no tool check for it (tool
    /// checks live on compose + agent only). Order-insensitive.
    var expectedTools: Set<String> {
        switch self {
        case .compose:        return ["date_to_day"]
        case .summary:        return []
        case .agentMultiTool: return ["date_to_day", "time_delta"]
        }
    }

    /// Case-insensitive substring(s) that MUST appear in the final assistant
    /// text. compose/agent use the fixture date(s) — proving the tool result was
    /// used. summary uses the codename — proving a real summary (not a refusal).
    func expectedTextFragments(_ f: BYOKSmokeFixture) -> [String] {
        switch self {
        case .compose:        return [f.dayName]
        case .summary:        return [Self.summaryCodename]
        case .agentMultiTool: return [f.dayName, f.deltaResultDate]
        }
    }
}

/// Deterministic inputs for a smoke run. Built around an arbitrary FUTURE date
/// (so the model can't memorize the day-of-week) with the expected day and
/// time-delta result computed in UTC to match the server tools exactly
/// (`date_to_day` uses `getUTCDay`; `time_delta` does UTC calendar arithmetic).
struct BYOKSmokeFixture: Sendable {
    let date: String            // e.g. "2031-07-19"
    let dayName: String         // e.g. "Saturday" (UTC weekday of `date`)
    let deltaDays: Int          // e.g. 7
    let deltaResultDate: String // e.g. "2031-07-26" (date + deltaDays, UTC)

    /// Build a fixture from an arbitrary date a few years in the future. The
    /// exact date doesn't matter — only that it's far enough out that the model
    /// won't reliably know its weekday, and that day/result are computed the
    /// same way the server tools compute them (UTC, Gregorian).
    static func make(deltaDays: Int = 7) -> BYOKSmokeFixture {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(identifier: "UTC")!
        let nowYear = cal.component(.year, from: Date())
        // Arbitrary future date: ~5 years out, mid-July, 19th.
        var comps = DateComponents()
        comps.year = nowYear + 5
        comps.month = 7
        comps.day = 19
        let start = cal.date(from: comps)!
        let weekdayNames = ["Sunday", "Monday", "Tuesday", "Wednesday", "Thursday", "Friday", "Saturday"]
        let weekdayIdx = cal.component(.weekday, from: start) - 1 // Calendar: 1=Sun…7=Sat
        let result = cal.date(byAdding: .day, value: deltaDays, to: start)!
        let fmt = DateFormatter()
        fmt.calendar = cal
        fmt.timeZone = cal.timeZone
        fmt.locale = Locale(identifier: "en_US_POSIX")
        fmt.dateFormat = "yyyy-MM-dd"
        return BYOKSmokeFixture(
            date: fmt.string(from: start),
            dayName: weekdayNames[weekdayIdx],
            deltaDays: deltaDays,
            deltaResultDate: fmt.string(from: result)
        )
    }
}

/// A single stage of the in-app BYOK smoke test (see `BackendClient.runBYOKSmoke`).
/// Stages are evaluated client-side from the SSE stream of a real multi-turn
/// conversation routed through `/completions/chat` with the user's BYOK key —
/// there is no dedicated test endpoint.
struct BYOKSmokeStage: Sendable {
    let name: String
    let ok: Bool
    let detail: String?
    /// Fatal stages gate the overall `ok`. Non-fatal (informational) stages —
    /// e.g. "model called the tool" — are surfaced but DON'T fail the smoke:
    /// a capable model can answer correctly without calling a tool, which is
    /// still a successful BYOK round-trip. (Tool execution is also server-side
    /// and provider-independent.)
    var fatal: Bool = true
}

/// Verdict from `BackendClient.runBYOKSmoke`. `ok=true` iff every stage passed
/// AND no transport / backend / provider error surfaced. Detail fields are for
/// surfacing in the UI; the smoke is fail-loud on purpose so we surface every
/// distinguishable failure mode rather than collapsing them into a single bit.
struct BYOKSmokeResult: Sendable {
    let ok: Bool
    let stages: [BYOKSmokeStage]
    let latencyMs: Int
    let errorCode: String?
    let errorDetail: String?
    let finalText: String?
    let byokRouted: Bool?
    let byokProvider: String?
    let byokTier: String?
}

/// Cross-isolation SSE-event aggregator for `runBYOKSmoke`. The handler closure
/// is `@Sendable` and fires on a background URLSession thread; we accumulate
/// into a `Mutex`-protected snapshot and read it once after the call returns.
/// Kept here (not nested in `BackendClient`) so the assemble-from-snapshot
/// helper in tests can construct one without going through a real session.
///
/// Optionally emits per-event diagnostic logs through
/// `BackgroundSyncLogger.logAIProcessing` (debug-gated; safe in production
/// builds because the logger no-ops when DebugMode logging is disabled).
/// Pass a non-empty `logContext` (e.g. `"openai/gpt-5.5/interactive/compose"`)
/// to trace what each event belongs to when reading the log later.
final class BYOKSmokeObserver: Sendable {
    struct Snapshot: Sendable {
        var sawAnyEvent: Bool = false
        var toolStartedNames: Set<String> = []
        var toolCompletedNames: Set<String> = []
        var toolFailedNames: Set<String> = []
        var backendError: String? = nil
        var finalAssistant: String? = nil
        var eventCount: Int = 0
    }

    private let state = Mutex(Snapshot())
    private let logContext: String

    init(logContext: String = "") {
        self.logContext = logContext
    }

    private func log(_ msg: String) {
        guard !logContext.isEmpty else { return }
        BackgroundSyncLogger.logAIProcessing("[BYOK_SMOKE \(logContext)] \(msg)")
    }

    func record(_ event: CompletionsSSEEvent) {
        state.withLock { s in
            s.sawAnyEvent = true
            s.eventCount += 1
            switch event {
            case .keepalive:
                break
            case .toolStarted(let e):
                if let name = e.tool_name {
                    s.toolStartedNames.insert(name)
                    log("tool_started name=\(name) call_id=\(e.call_id ?? "-")")
                } else {
                    log("tool_started name=<missing>")
                }
            case .toolCompleted(let e):
                if let name = e.tool_name {
                    s.toolCompletedNames.insert(name)
                    let preview = (e.result ?? "").prefix(200)
                    log("tool_completed name=\(name) success=\(e.success ?? false) elapsed=\(e.elapsed_ms ?? -1)ms result=\(preview)")
                } else {
                    log("tool_completed name=<missing>")
                }
            case .toolFailed(let e):
                if let name = e.tool_name {
                    s.toolFailedNames.insert(name)
                    log("tool_failed name=\(name) error=\(e.error ?? "?")")
                } else {
                    log("tool_failed name=<missing>")
                }
            case .final(let f):
                s.finalAssistant = f.assistant
                let assistantLen = f.assistant?.count ?? 0
                let toolCallCount = f.tool_calls?.count ?? 0
                let preview = (f.assistant ?? "").prefix(300)
                log("final assistant_len=\(assistantLen) tool_calls=\(toolCallCount) text=\(preview)")
            case .error(let msg):
                s.backendError = msg
                log("error event: \(msg)")
            case .throttled:
                log("throttled")
            case .throttleEnded:
                log("throttle_ended")
            }
        }
    }

    func snapshot() -> Snapshot {
        state.withLock { $0 }
    }
}

struct TokenUsage: Decodable, Sendable {
    let input_tokens: Int
    let output_tokens: Int
    let total_tokens: Int
}

extension BackendClient {
    /// Stamp request-wide defaults sourced from app-level state (single source of truth).
    ///
    /// Currently augments `web_search_enabled` from `AIService.shared.webSearchEnabled`
    /// when the caller did not set it explicitly. This is the **only** place where
    /// the user's global web-search toggle is applied to outgoing completions
    /// requests — call sites must NOT pass `web_search_enabled` themselves.
    ///
    /// Idempotent: a non-nil value on the request is preserved as-is. This matters
    /// for the streaming tool loop, which forwards `request.web_search_enabled`
    /// across continuation rounds — the augmentation runs once on the first round
    /// and subsequent rounds see a non-nil value.
    nonisolated static func augmentRequestWithDefaults(_ request: CompletionsRequest) -> CompletionsRequest {
        // Idempotent for BOTH augmentations: a non-nil value on the request is
        // preserved as-is. The streaming tool loop reuses the augmented request
        // across continuation rounds and we don't want each round to re-read
        // (or re-decide) the user's state.
        if request.web_search_enabled != nil && request.byok != nil { return request }

        let webSearchEnabled = request.web_search_enabled ?? (AIService.shared.webSearchEnabled ? true : nil)
        let byok = request.byok ?? AIService.shared.byokBundle
        return CompletionsRequest(
            messages: request.messages,
            client_timezone: request.client_timezone,
            disable_tools: request.disable_tools,
            web_search_enabled: webSearchEnabled,
            conversation_state: request.conversation_state,
            byok: byok
        )
    }

    func sendCompletions(_ request: CompletionsRequest) async throws -> CompletionsResponse {
        await llmSemaphore.acquire()
        defer { llmSemaphore.release() }
        return try await sendCompletionsInternal(request)
    }

    /// Direct variant — bypasses the LLM semaphore. Use for user-initiated calls
    /// (agent chat, inline edit, KB refinement) that should not wait behind background AI.
    func sendCompletionsDirect(_ request: CompletionsRequest) async throws -> CompletionsResponse {
        return try await sendCompletionsInternal(request)
    }

    /// Shared implementation for both semaphore-gated and direct completions calls.
    /// Uses incremental SSE reader with heartbeat watchdog for stall detection.
    private func sendCompletionsInternal(_ request: CompletionsRequest) async throws -> CompletionsResponse {
        try checkForbiddenBackoff()

        let (urlRequest, body) = try await makeCompletionsRequest(request)
        print("[BackendClient] completions request: \(body.count) bytes")
        BackgroundSyncLogger.logAIProcessing("[HTTP] request START (completions, \(body.count) bytes)")

        let jsonData = try await readSSEStreamIncremental(urlRequest, onSSEEvent: nil)

        do {
            let response = try JSONDecoder().decode(CompletionsResponse.self, from: jsonData)
            #if DEBUG
            let assistantLen = response.assistant?.count ?? 0
            let thinkingLen = response.thinking?.count ?? 0
            let tokenInfo = response.token_usage.map { "in=\($0.input_tokens) out=\($0.output_tokens) total=\($0.total_tokens)" } ?? "nil"
            print("[BackendClient] completions response: assistant=\(assistantLen) chars, thinking=\(thinkingLen) chars, tokens=\(tokenInfo)")
            if assistantLen < 300, let assistant = response.assistant {
                print("[BackendClient] FULL assistant: \(assistant)")
            }
            #endif
            return response
        } catch {
            let raw = String(data: jsonData.prefix(500), encoding: .utf8) ?? "<binary>"
            print("[BackendClient] Failed to decode completions response: \(error)\n  Raw body (\(jsonData.count) bytes): \(raw)")
            throw error
        }
    }

    // MARK: - Incremental SSE Reader with Heartbeat Watchdog

    /// Build a URLRequest for the completions endpoint with standard headers.
    private func makeCompletionsRequest(_ request: CompletionsRequest) async throws -> (URLRequest, Data) {
        let request = Self.augmentRequestWithDefaults(request)
        var urlRequest = URLRequest(url: baseURL.appending(path: "/completions/chat"))
        urlRequest.httpMethod = "POST"
        urlRequest.timeoutInterval = 120
        urlRequest.setValue("application/json", forHTTPHeaderField: "Content-Type")
        urlRequest.setValue("ios", forHTTPHeaderField: "X-Client-Type")
        urlRequest.setValue(Self.clientVersion, forHTTPHeaderField: "X-Client-Version")
        if let token = await currentAuthToken() {
            urlRequest.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        }
        let body = try JSONEncoder().encode(request)
        urlRequest.httpBody = body
        return (urlRequest, body)
    }

    /// Incremental SSE reader using URLSession.bytes + AsyncLineSequence.
    /// Parses events as they arrive and enforces a heartbeat watchdog:
    /// if no SSE event arrives within `SyncConfig.sseHeartbeatTimeoutSeconds`,
    /// the connection is considered stalled and a retriable error is thrown.
    ///
    /// Returns the data payload from the `event: final` SSE event.
    /// Calls `onSSEEvent` for intermediate events (keepalive, tool_started, etc.).
    private func readSSEStreamIncremental(
        _ urlRequest: URLRequest,
        onSSEEvent: SSEEventHandler?
    ) async throws -> Data {
        let httpT0 = CFAbsoluteTimeGetCurrent()

        let (bytes, response) = try await llmSession.bytes(for: urlRequest)
        guard let httpResponse = response as? HTTPURLResponse else {
            BackgroundSyncLogger.logAIProcessing("[HTTP] SSE response — not HTTPURLResponse")
            throw BackendError.requestFailed(statusCode: 0)
        }

        let status = httpResponse.statusCode
        if status == 401 { throw BackendError.unauthorized }
        if status == 402 { throw BackendError.requestFailed(statusCode: 402) }
        if status == 403 {
            recordForbidden()
            throw BackendError.forbidden
        }
        guard 200..<300 ~= status else {
            BackgroundSyncLogger.logAIProcessing("[HTTP] SSE response status=\(status)")
            throw BackendError.requestFailed(statusCode: status)
        }
        resetForbiddenBackoff()

        BackgroundSyncLogger.logAIProcessing("[HTTP] SSE stream opened (status=\(status))")

        return try await Self.parseSSELines(
            lines: bytes.lines,
            heartbeatTimeout: SyncConfig.sseHeartbeatTimeoutSeconds,
            httpT0: httpT0,
            onSSEEvent: onSSEEvent,
            log: { BackgroundSyncLogger.logAIProcessing($0) }
        )
    }

    /// Core SSE stream parser. Generic over any `AsyncSequence` of `String` lines
    /// so it can be unit-tested with a mock stream without hitting the network.
    /// Enforces a heartbeat watchdog (throws retriable error on stall) and flushes
    /// events on: empty-line boundaries, new `event:` lines (handles missing empty
    /// lines between consecutive events), and end-of-stream.
    static func parseSSELines<S: AsyncSequence>(
        lines: S,
        heartbeatTimeout: TimeInterval,
        httpT0: CFAbsoluteTime,
        onSSEEvent: SSEEventHandler?,
        log: (String) -> Void
    ) async throws -> Data where S.Element == String {
        // SSE parser state
        var currentEvent: String?
        var currentDataLines: [String] = []
        var finalData: Data?
        var lastEventAt = CFAbsoluteTimeGetCurrent()
        var eventCount = 0

        var heartbeatCount = 0

        // Dispatch a complete SSE event. Called on empty-line boundaries, when
        // a new `event:` arrives (flushing any previous event), and at stream end.
        // URLSession.AsyncBytes.lines has been observed not to yield empty lines
        // between consecutive SSE events, so we can't rely on the empty-line
        // boundary alone — we also flush on event-boundary and end-of-stream.
        func flushEvent() {
            guard let eventType = currentEvent else { return }
            eventCount += 1
            let elapsedMs = Int((CFAbsoluteTimeGetCurrent() - httpT0) * 1000)

            switch eventType {
            case "keepalive":
                heartbeatCount += 1
                log("[SSE] heartbeat #\(heartbeatCount) received (elapsed=\(elapsedMs)ms)")
                onSSEEvent?(.keepalive)

            case "tool_started":
                let dataStr = currentDataLines.joined(separator: "\n")
                log("[SSE] tool_started (elapsed=\(elapsedMs)ms)")
                if let dataBytes = dataStr.data(using: .utf8),
                   let status = try? JSONDecoder().decode(ToolStatusEvent.self, from: dataBytes) {
                    onSSEEvent?(.toolStarted(status))
                }

            case "tool_completed":
                let dataStr = currentDataLines.joined(separator: "\n")
                log("[SSE] tool_completed (elapsed=\(elapsedMs)ms)")
                if let dataBytes = dataStr.data(using: .utf8),
                   let status = try? JSONDecoder().decode(ToolStatusEvent.self, from: dataBytes) {
                    onSSEEvent?(.toolCompleted(status))
                }

            case "tool_failed":
                let dataStr = currentDataLines.joined(separator: "\n")
                log("[SSE] tool_failed (elapsed=\(elapsedMs)ms)")
                if let dataBytes = dataStr.data(using: .utf8),
                   let status = try? JSONDecoder().decode(ToolStatusEvent.self, from: dataBytes) {
                    onSSEEvent?(.toolFailed(status))
                }

            case "error":
                let errorStr = currentDataLines.joined(separator: "\n").trimmingCharacters(in: .whitespaces)
                log("[SSE] error event (elapsed=\(elapsedMs)ms)")
                onSSEEvent?(.error(errorStr))

            case "final":
                let joined = currentDataLines.joined(separator: "\n")
                finalData = joined.data(using: .utf8)
                log("[SSE] final event received (elapsed=\(elapsedMs)ms, bytes=\(finalData?.count ?? 0))")
                if let data = finalData, let event = try? JSONDecoder().decode(CompletionsFinalEvent.self, from: data) {
                    onSSEEvent?(.final(event))
                }

            default:
                break
            }

            currentEvent = nil
            currentDataLines.removeAll()
        }

        for try await line in lines {
            // Heartbeat watchdog: check time since last line activity.
            // Update lastEventAt on ANY incoming line (not just complete events)
            // so late-arriving bursts from network/edge buffering don't false-positive.
            let now = CFAbsoluteTimeGetCurrent()
            if now - lastEventAt > heartbeatTimeout {
                let elapsed = Int((now - httpT0) * 1000)
                log("[SSE] heartbeat timeout — no line for \(Int(now - lastEventAt))s (elapsed=\(elapsed)ms, events=\(eventCount))")
                throw BackendError.requestFailed(statusCode: 0) // retriable
            }
            lastEventAt = now

            // SSE comment lines (prefix `:`) are valid per spec and must be ignored.
            // Backend sends a ≥512-byte `:` primer at stream start to cross iOS
            // URLSession's initial-batch buffer.
            if line.hasPrefix(":") {
                continue
            }

            if line.hasPrefix("event: ") {
                // Flush any previous event before starting a new one. This handles
                // cases where AsyncBytes.lines doesn't yield the empty line between
                // consecutive events.
                flushEvent()
                currentEvent = String(line.dropFirst(7)).trimmingCharacters(in: .whitespaces)
            } else if line.hasPrefix("data: ") {
                currentDataLines.append(String(line.dropFirst(6)))
            } else if line.isEmpty {
                // End of event block — flush (no-op if currentEvent is nil).
                flushEvent()
            }
        }

        // Handle stream ending without a trailing empty line for the last event.
        flushEvent()

        let elapsed = Int((CFAbsoluteTimeGetCurrent() - httpT0) * 1000)
        guard let result = finalData else {
            log("[SSE] stream ended without final event (events=\(eventCount), heartbeats=\(heartbeatCount), elapsed=\(elapsed)ms)")
            throw BackendError.requestFailed(statusCode: 0)
        }

        log("[HTTP] SSE complete (events=\(eventCount), heartbeats=\(heartbeatCount), bytes=\(result.count), elapsed=\(elapsed)ms)")
        return result
    }

    /// Retry wrapper matching TB's `retryWithBackoff()` + 429 throttle loop pattern.
    ///
    /// - General errors (network, 5xx, 408): retry up to `maxRetries` times with exponential backoff.
    ///   On exhaustion, throw — the message stays as `summaryBlurb == nil` and will be retried
    ///   on the next sync cycle (system-level "never quit").
    /// - 429 rate limit: retry indefinitely with gentle backoff capped at 5s (matches TB's throttle loop).
    /// - Non-retriable (401, 4xx, decode): throw immediately.
    func sendCompletionsWithRetry(_ request: CompletionsRequest, maxRetries: Int = 5) async throws -> CompletionsResponse {
        await llmSemaphore.acquire()
        defer { llmSemaphore.release() }

        var attempt = 0
        let maxDelay: Double = 10

        while true {
            try Task.checkCancellation()
            do {
                let response = try await sendCompletionsInternal(request)
                if attempt > 0 {
                    print("[BackendClient] Succeeded after \(attempt) retries")
                }
                return response
            } catch is CancellationError {
                throw CancellationError()
            } catch let error as BackendError {
                if case .requestFailed(statusCode: 429) = error {
                    // 429 rate limit: retry indefinitely with gentle backoff (matches TB's throttle loop)
                    attempt += 1
                    let delay = min(1.5 * pow(1.5, Double(attempt - 1)) + Double.random(in: 0...0.5), 5.0)
                    print("[BackendClient] Rate limited, retry #\(attempt) after \(String(format: "%.1f", delay))s")
                    try await Task.sleep(for: .seconds(delay))
                } else if error.isRetriable {
                    // Other retriable errors (5xx, 408, 0): retry up to maxRetries
                    attempt += 1
                    guard attempt <= maxRetries else {
                        print("[BackendClient] Exhausted \(maxRetries) retries: \(error)")
                        throw error
                    }
                    let delay = min(pow(2.0, Double(attempt - 1)) + Double.random(in: 0...1), maxDelay)
                    print("[BackendClient] Retry #\(attempt)/\(maxRetries) after \(String(format: "%.1f", delay))s: \(error)")
                    try await Task.sleep(for: .seconds(delay))
                } else {
                    throw error
                }
            } catch let error as URLError {
                // Network errors: retry up to maxRetries
                BackgroundSyncLogger.logAIProcessing("[HTTP] URLError code=\(error.code.rawValue) (\(error.localizedDescription))")
                attempt += 1
                guard attempt <= maxRetries else {
                    print("[BackendClient] Exhausted \(maxRetries) retries: \(error.localizedDescription)")
                    throw error
                }
                let delay = min(pow(2.0, Double(attempt - 1)) + Double.random(in: 0...1), maxDelay)
                print("[BackendClient] Retry #\(attempt)/\(maxRetries) after \(String(format: "%.1f", delay))s: \(error.localizedDescription)")
                try await Task.sleep(for: .seconds(delay))
            } catch {
                throw error
            }
        }
    }

    /// Parse SSE text and extract the JSON data from the "event: final" event.
    /// SSE format: "event: <name>\ndata: <json>\n\n"
    func extractSSEFinalData(_ text: String) -> String? {
        let lines = text.components(separatedBy: "\n")
        var currentEvent: String?
        var finalDataLines: [String] = []

        for line in lines {
            if line.hasPrefix("event: ") {
                currentEvent = String(line.dropFirst(7)).trimmingCharacters(in: .whitespaces)
            } else if line.hasPrefix("data: "), currentEvent == "final" {
                // SSE spec: multi-line data is split across multiple "data:" lines.
                // Concatenate all data lines in the final event (joined with newlines).
                finalDataLines.append(String(line.dropFirst(6)))
            } else if line.isEmpty {
                // Empty line = end of event block
                if currentEvent == "final" && !finalDataLines.isEmpty {
                    return finalDataLines.joined(separator: "\n")
                }
                currentEvent = nil
            }
        }
        // Handle case where stream ends without trailing empty line
        if currentEvent == "final" && !finalDataLines.isEmpty {
            return finalDataLines.joined(separator: "\n")
        }
        return nil
    }
}

// MARK: - Streaming Completions with Tool Execution Loop

extension BackendClient {
    /// Callback for SSE events during streaming completions.
    /// Allows callers to observe server-side tool progress (for UI updates, logging, etc.).
    typealias SSEEventHandler = @Sendable (CompletionsSSEEvent) -> Void

    /// Send completions with full SSE streaming and multi-turn tool execution loop.
    /// Matches TB's `sendChatCompletions()` + `onToolExecution` pattern in `llm.js`/`converse.js`.
    ///
    /// Flow:
    /// 1. Send initial request
    /// 2. Parse SSE stream for server-side tool events + final response
    /// 3. If `final` contains `tool_calls`: execute client-side tools via `ToolRegistry`
    /// 4. Append tool results to `conversation_state.harmony_messages`
    /// 5. Recursive call with updated `conversation_state` (increment `current_round`)
    /// 6. Repeat until `final` has no `tool_calls` (pure assistant response)
    ///
    /// Returns the final `CompletionsResponse` after all tool rounds complete.
    func sendCompletionsWithTools(
        _ request: CompletionsRequest,
        onSSEEvent: SSEEventHandler? = nil
    ) async throws -> CompletionsResponse {
        await llmSemaphore.acquire()
        defer { llmSemaphore.release() }
        return try await sendCompletionsWithToolsInternal(request, onSSEEvent: onSSEEvent)
    }

    /// Direct variant — bypasses the LLM semaphore. Use for user-initiated calls
    /// (agent chat, inline edit) that should not wait behind background AI.
    func sendCompletionsWithToolsDirect(
        _ request: CompletionsRequest,
        onSSEEvent: SSEEventHandler? = nil
    ) async throws -> CompletionsResponse {
        return try await sendCompletionsWithToolsInternal(request, onSSEEvent: onSSEEvent)
    }

    /// Build the terminal `CompletionsResponse` from a tool-loop `finalEvent`,
    /// carrying through the BYOK envelope fields (error_code/error_detail/
    /// retry_after_seconds + byok_routed/provider/tier/skip_reason). Without
    /// this the tool-loop path silently dropped them — so BYOK error codes
    /// never reached the client on the agent/compose paths (fixed 2026-05-22).
    static func responseFromFinalEvent(_ finalEvent: CompletionsFinalEvent) -> CompletionsResponse {
        CompletionsResponse(
            assistant: finalEvent.assistant,
            token_usage: finalEvent.token_usage,
            error: finalEvent.error,
            thinking: finalEvent.thinking,
            byok_routed: finalEvent.byok_routed,
            byok_provider: finalEvent.byok_provider,
            byok_tier: finalEvent.byok_tier,
            byok_skip_reason: finalEvent.byok_skip_reason,
            error_code: finalEvent.error_code,
            error_detail: finalEvent.error_detail,
            retry_after_seconds: finalEvent.retry_after_seconds
        )
    }

    /// Shared implementation for both semaphore-gated and direct tool-loop completions calls.
    private func sendCompletionsWithToolsInternal(
        _ request: CompletionsRequest,
        onSSEEvent: SSEEventHandler?
    ) async throws -> CompletionsResponse {
        // Stamp app-level defaults (e.g., user's global web-search toggle) once on
        // the entry request. The tool loop's continuation rounds rebuild
        // `currentRequest` from `request.web_search_enabled`, so the augmentation
        // here also covers every subsequent round. See augmentRequestWithDefaults.
        let request = Self.augmentRequestWithDefaults(request)

        var currentRequest = request
        var round = 0

        while true {
            try Task.checkCancellation()
            round += 1

            print("[BackendClient] Tool round \(round) starting...")

            // 429 throttle retry loop (matches TB's throttle loop in llm.js)
            var throttleAttempt = 0
            var wasThrottled = false
            let finalEvent: CompletionsFinalEvent
            while true {
                try Task.checkCancellation()
                do {
                    finalEvent = try await sendStreamingCompletions(currentRequest, onSSEEvent: onSSEEvent)
                    break
                } catch let error as BackendError {
                    guard case .requestFailed(statusCode: 429) = error else { throw error }
                    wasThrottled = true
                    throttleAttempt += 1
                    if throttleAttempt == 1 {
                        onSSEEvent?(.throttled)
                    }
                    let backoff = min(1.5 * pow(1.5, Double(throttleAttempt - 1)) + Double.random(in: 0...0.5), 5.0)
                    print("[BackendClient] Throttled (429), retry #\(throttleAttempt) after \(String(format: "%.1f", backoff))s")
                    try await Task.sleep(for: .seconds(backoff))
                }
            }
            if wasThrottled {
                onSSEEvent?(.throttleEnded)
            }

            // If no tool_calls in the final event, we're done — return the response
            guard let toolCalls = finalEvent.tool_calls, !toolCalls.isEmpty else {
                print("[BackendClient] Round \(round): no tool_calls — done")
                return Self.responseFromFinalEvent(finalEvent)
            }

            // Execute client-side tools
            guard var conversationState = finalEvent.conversation_state else {
                print("[BackendClient] tool_calls received but no conversation_state — returning as-is")
                return Self.responseFromFinalEvent(finalEvent)
            }

            print("[BackendClient] Round \(round): \(toolCalls.count) tool_calls, harmony_messages=\(conversationState.harmony_messages.count)")

            let toolRegistry = ToolRegistry.shared
            var toolResults: [ToolResult] = []

            for toolCall in toolCalls {
                try Task.checkCancellation()

                let toolName = toolCall.function.name
                print("[AIChatDebug] Executing client-side tool: \(toolName) (call_id=\(toolCall.id.prefix(8)))")
                print("[AIChatDebug]   args: \(toolCall.function.arguments.prefix(200))")

                // Fire tool-started event for client-side tools (matching server-side SSE events)
                onSSEEvent?(.toolStarted(ToolStatusEvent(
                    execution_id: nil, call_id: toolCall.id,
                    display_label: toolName, tool_name: toolName,
                    success: nil, elapsed_ms: nil, error: nil, result: nil
                )))

                // Parse arguments from JSON string
                let arguments: [String: JSONValue]
                if let argsData = toolCall.function.arguments.data(using: .utf8),
                   let argsDict = try? JSONSerialization.jsonObject(with: argsData) as? [String: Any] {
                    arguments = argsDict.compactMapValues { Self.jsonValueFromAny($0) }
                } else {
                    arguments = [:]
                }

                let result = await toolRegistry.execute(name: toolName, arguments: arguments)
                toolResults.append(ToolResult(call_id: toolCall.id, output: result.output, ok: result.ok))

                // Fire tool-completed event for client-side tools
                onSSEEvent?(.toolCompleted(ToolStatusEvent(
                    execution_id: nil, call_id: toolCall.id,
                    display_label: toolName, tool_name: toolName,
                    success: result.ok, elapsed_ms: nil, error: nil, result: nil
                )))

                // Translate real IDs → numeric IDs in tool output (matching TB's processStringTBtoLLM)
                let translatedOutput = await ChatIdTranslator.shared.processToolOutputForLLM(result.output)

                // Append tool result to harmony_messages (matching TB's pattern)
                let toolMessage = HarmonyMessage(
                    role: "tool",
                    content: translatedOutput,
                    thinking: nil,
                    tool_calls: nil,
                    tool_call_id: toolCall.id
                )
                conversationState.harmony_messages.append(toolMessage)
            }

            conversationState.current_round = round

            // Continue to next round with updated conversation state
            currentRequest = CompletionsRequest(
                messages: request.messages,
                client_timezone: request.client_timezone,
                disable_tools: request.disable_tools,
                web_search_enabled: request.web_search_enabled,
                conversation_state: conversationState,
                byok: request.byok
            )

            print("[BackendClient] Tool round \(round) complete (\(toolResults.count) tools, harmony_messages=\(conversationState.harmony_messages.count))")
        }
    }

    /// Recursively convert `Any` from JSONSerialization to `JSONValue`.
    static func jsonValueFromAny(_ value: Any) -> JSONValue? {
        if let s = value as? String { return .string(s) }
        // Check Bool before Int/Double — JSON bools deserialize as NSNumber.
        // CFBooleanGetTypeID() distinguishes true booleans from numeric NSNumbers.
        if let n = value as? NSNumber, CFBooleanGetTypeID() == CFGetTypeID(n) {
            return .bool(n.boolValue)
        }
        if let i = value as? Int { return .int(i) }
        if let d = value as? Double { return .double(d) }
        if let arr = value as? [Any] { return .array(arr.compactMap { jsonValueFromAny($0) }) }
        if let dict = value as? [String: Any] { return .dictionary(dict.compactMapValues { jsonValueFromAny($0) }) }
        return nil
    }

    /// Send a single completions request and parse the SSE stream incrementally.
    /// Returns the `CompletionsFinalEvent` from the `event: final` SSE event.
    /// Calls `onSSEEvent` for intermediate events (tool_started, tool_completed, etc.).
    /// Uses heartbeat watchdog for stall detection.
    private func sendStreamingCompletions(
        _ request: CompletionsRequest,
        onSSEEvent: SSEEventHandler?
    ) async throws -> CompletionsFinalEvent {
        try checkForbiddenBackoff()

        let (urlRequest, body) = try await makeCompletionsRequest(request)
        print("[BackendClient] completions (streaming) request: \(body.count) bytes")
        BackgroundSyncLogger.logAIProcessing("[HTTP] request START (streaming, \(body.count) bytes)")

        let finalData = try await readSSEStreamIncremental(urlRequest, onSSEEvent: onSSEEvent)
        return try JSONDecoder().decode(CompletionsFinalEvent.self, from: finalData)
    }

    /// Parse a full SSE text into structured events, calling the handler for each.
    /// Returns the final event. Matches TB's `readSSEStream()` in `llm.js`.
    func parseSSEStream(
        _ text: String,
        onSSEEvent: SSEEventHandler?
    ) throws -> CompletionsFinalEvent {
        let lines = text.components(separatedBy: "\n")
        var currentEvent: String?
        var currentDataLines: [String] = []
        var finalEvent: CompletionsFinalEvent?

        for line in lines {
            if line.hasPrefix("event: ") {
                currentEvent = String(line.dropFirst(7)).trimmingCharacters(in: .whitespaces)
                currentDataLines.removeAll()
            } else if line.hasPrefix("data: "), let eventType = currentEvent {
                let dataStr = String(line.dropFirst(6))
                // SSE spec: multi-line data is split across multiple "data:" lines.
                // Accumulate all data lines for the current event.
                currentDataLines.append(dataStr)

                // For non-final events, process immediately (they're single-line).
                // Final event is processed on the empty-line boundary to collect all data lines.
                switch eventType {
                case "keepalive":
                    onSSEEvent?(.keepalive)

                case "tool_started":
                    let dataBytes = dataStr.data(using: .utf8) ?? Data()
                    if let status = try? JSONDecoder().decode(ToolStatusEvent.self, from: dataBytes) {
                        print("[AIChatDebug] SSE tool_started: \(status.display_label ?? status.tool_name ?? "unknown")")
                        onSSEEvent?(.toolStarted(status))
                    }

                case "tool_completed":
                    let dataBytes = dataStr.data(using: .utf8) ?? Data()
                    if let status = try? JSONDecoder().decode(ToolStatusEvent.self, from: dataBytes) {
                        print("[AIChatDebug] SSE tool_completed: \(status.display_label ?? status.tool_name ?? "unknown") success=\(status.success ?? true)")
                        onSSEEvent?(.toolCompleted(status))
                    }

                case "tool_failed":
                    let dataBytes = dataStr.data(using: .utf8) ?? Data()
                    if let status = try? JSONDecoder().decode(ToolStatusEvent.self, from: dataBytes) {
                        onSSEEvent?(.toolFailed(status))
                    }

                case "error":
                    let errorStr = dataStr.trimmingCharacters(in: .whitespaces)
                    onSSEEvent?(.error(errorStr))

                default:
                    break
                }
            } else if line.isEmpty {
                // Empty line = end of event block.
                // Process accumulated multi-line data for final events.
                if currentEvent == "final" && !currentDataLines.isEmpty {
                    let joined = currentDataLines.joined(separator: "\n")
                    let dataBytes = joined.data(using: .utf8) ?? Data()
                    let event = try JSONDecoder().decode(CompletionsFinalEvent.self, from: dataBytes)
                    onSSEEvent?(.final(event))
                    finalEvent = event
                }
                currentEvent = nil
                currentDataLines.removeAll()
            }
        }

        // Handle stream ending without trailing empty line
        if currentEvent == "final" && !currentDataLines.isEmpty {
            let joined = currentDataLines.joined(separator: "\n")
            let dataBytes = joined.data(using: .utf8) ?? Data()
            let event = try JSONDecoder().decode(CompletionsFinalEvent.self, from: dataBytes)
            onSSEEvent?(.final(event))
            finalEvent = event
        }

        guard let result = finalEvent else {
            BackgroundSyncLogger.logChatError("SSE stream ended without final event (no result parsed)")
            throw BackendError.requestFailed(statusCode: 0)
        }
        return result
    }
}

// MARK: - Sync Relay: HTTPS AI Cache Probe

extension BackendClient {
    /// HTTPS-based AI cache probe for background tasks (BGProcessingTask).
    /// Bridges HTTP → WSS via the sync relay Durable Object.
    /// Used when WebSocket isn't available (app in background).
    private static var relayBaseURL: String { BackendConfig.syncBaseURL }

    func probeAICacheHTTPS(keys: [String]) async -> [String: AICacheResult]? {
        guard !keys.isEmpty else { return nil }

        guard let token = await currentAuthToken() else {
            print("[BackendClient] HTTPS probe skipped — no auth token")
            return nil
        }

        guard let url = URL(string: "\(Self.relayBaseURL)/ai-cache/probe") else { return nil }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.timeoutInterval = 2 // 2s to match TB's probe timeout
        request.httpBody = try? JSONSerialization.data(withJSONObject: ["keys": keys])

        do {
            let (data, response) = try await sharedEphemeralSession.data(for: request)
            guard let httpResponse = response as? HTTPURLResponse,
                  200..<300 ~= httpResponse.statusCode else {
                let code = (response as? HTTPURLResponse)?.statusCode ?? 0
                print("[BackendClient] HTTPS probe HTTP \(code)")
                return nil
            }

            struct ProbeResponse: Decodable {
                let results: [String: AICacheResult]
            }
            let probeResponse = try JSONDecoder().decode(ProbeResponse.self, from: data)
            let hitCount = probeResponse.results.count
            print("[BackendClient] HTTPS probe: \(hitCount) hit(s) for \(keys.count) key(s)")
            return probeResponse.results.isEmpty ? nil : probeResponse.results
        } catch {
            print("[BackendClient] HTTPS probe error: \(error)")
            return nil
        }
    }
}

// MARK: - Account & Usage API

extension BackendClient {
    func fetchAccountInfo() async throws -> AccountInfo {
        guard let token = await currentAuthToken() else {
            throw BackendError.unauthorized
        }

        var request = URLRequest(url: baseURL.appending(path: "/whoami"))
        request.httpMethod = "GET"
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("ios", forHTTPHeaderField: "X-Client-Type")
        request.setValue(Self.clientVersion, forHTTPHeaderField: "X-Client-Version")

        let (data, response) = try await sharedEphemeralSession.data(for: request)
        guard let httpResponse = response as? HTTPURLResponse,
              200..<300 ~= httpResponse.statusCode else {
            throw BackendError.requestFailed(
                statusCode: (response as? HTTPURLResponse)?.statusCode ?? 0
            )
        }

        let info = try JSONDecoder().decode(AccountInfo.self, from: data)
        if !info.loggedIn {
            throw BackendError.accountGone
        }
        return info
    }

    func fetchUsageStats() async throws -> UsageStats {
        guard let token = await currentAuthToken() else {
            throw BackendError.unauthorized
        }

        var request = URLRequest(url: baseURL.appending(path: "/usage/stats"))
        request.httpMethod = "GET"
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("ios", forHTTPHeaderField: "X-Client-Type")
        request.setValue(Self.clientVersion, forHTTPHeaderField: "X-Client-Version")

        let (data, response) = try await sharedEphemeralSession.data(for: request)
        guard let httpResponse = response as? HTTPURLResponse,
              200..<300 ~= httpResponse.statusCode else {
            throw BackendError.requestFailed(
                statusCode: (response as? HTTPURLResponse)?.statusCode ?? 0
            )
        }

        return try JSONDecoder().decode(UsageStats.self, from: data)
    }

    // MARK: - BYOK endpoints

    /// `GET /byok/models` — returns the 3-level allow-list catalog (provider → tier → [model]).
    /// Backend sets Cache-Control 24h; the iOS-side cache decision is up to the caller.
    func fetchBYOKModels() async throws -> BYOKModelCatalog {
        guard let token = await currentAuthToken() else {
            throw BackendError.unauthorized
        }

        var request = URLRequest(url: baseURL.appending(path: "/byok/models"))
        request.httpMethod = "GET"
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("ios", forHTTPHeaderField: "X-Client-Type")
        request.setValue(Self.clientVersion, forHTTPHeaderField: "X-Client-Version")

        let (data, response) = try await sharedEphemeralSession.data(for: request)
        guard let httpResponse = response as? HTTPURLResponse,
              200..<300 ~= httpResponse.statusCode else {
            throw BackendError.requestFailed(
                statusCode: (response as? HTTPURLResponse)?.statusCode ?? 0
            )
        }

        return try JSONDecoder().decode(BYOKModelCatalog.self, from: data)
    }

    /// `POST /byok/list-models` — list the model IDs the user's key can actually
    /// access at the provider. Diagnostic for "why does my BYOK smoke 404": the
    /// caller cross-references this against the catalog to show which models the
    /// key is entitled to. Relays the key through the backend (relay-not-store).
    /// Never throws on provider errors — returns a `BYOKListModelsResult` with
    /// `ok=false` + an error_code so callers can render the reason.
    func listBYOKModels(provider: String, apiKey: String) async -> BYOKListModelsResult {
        guard let token = await currentAuthToken() else {
            return BYOKListModelsResult(ok: false, models: nil, error_code: "unauthorized", error_detail: "Not signed in", retry_after_seconds: nil)
        }
        var request = URLRequest(url: baseURL.appending(path: "/byok/list-models"))
        request.httpMethod = "POST"
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("ios", forHTTPHeaderField: "X-Client-Type")
        request.setValue(Self.clientVersion, forHTTPHeaderField: "X-Client-Version")
        request.httpBody = try? JSONSerialization.data(withJSONObject: ["provider": provider, "api_key": apiKey])

        do {
            let (data, response) = try await sharedEphemeralSession.data(for: request)
            guard let http = response as? HTTPURLResponse else {
                return BYOKListModelsResult(ok: false, models: nil, error_code: "transport_error", error_detail: "No HTTP response", retry_after_seconds: nil)
            }
            if http.statusCode == 401 {
                return BYOKListModelsResult(ok: false, models: nil, error_code: "unauthorized", error_detail: "Authorization failed", retry_after_seconds: nil)
            }
            // 200 (ok=true) and 200-with-ok=false both decode the same shape.
            return try JSONDecoder().decode(BYOKListModelsResult.self, from: data)
        } catch {
            return BYOKListModelsResult(ok: false, models: nil, error_code: "transport_error", error_detail: error.localizedDescription, retry_after_seconds: nil)
        }
    }

    /// BYOK smoke test — drives a real production conversation through the
    /// normal `/completions/chat` endpoint with the user's BYOK key attached
    /// for the chosen tier. Validates the entire pipeline end-to-end: auth
    /// gateway → BYOK routing fork → provider adapter → SSE stream →
    /// server-side tool execution → final response.
    ///
    /// The exact conversation, tools, and validation pass are determined by
    /// `profile` — see `BYOKSmokeProfile`. Callers should run multiple profiles
    /// per (provider, tier, model) to cover divergent code paths.
    ///
    /// Never throws: any error is surfaced inside the returned `BYOKSmokeResult`
    /// (`ok=false`, populated `errorCode` + `errorDetail`). Callers render the
    /// stage list as a checklist.
    ///
    /// Cost: a single real LLM round-trip on the user's BYOK provider per
    /// profile (multi-tool profiles do TWO internal round-trips because of the
    /// tool loop, charged to the user's key).
    func runBYOKSmoke(
        tier: String,
        provider: String,
        model: String,
        apiKey: String,
        profile: BYOKSmokeProfile = .compose
    ) async -> BYOKSmokeResult {
        let t0 = CFAbsoluteTimeGetCurrent()
        let systemPromptName = profile.systemPromptName(tier: tier)
        let logCtx = "\(provider)/\(model)/\(tier)/\(profile.rawValue)"
        // Arbitrary future date so the model can't guess the day-of-week from
        // memory — the only way to produce the expected fragment is to call
        // the tool. Day/result computed in UTC to match the server tools.
        let fixture = BYOKSmokeFixture.make()
        let expectedFragments = profile.expectedTextFragments(fixture)

        // Don't ever log the apiKey itself — but everything else about the
        // request is useful for post-mortem debugging if a smoke fails.
        BackgroundSyncLogger.logAIProcessing(
            "[BYOK_SMOKE \(logCtx)] START prompt=\(systemPromptName) date=\(fixture.date) " +
            "expected_tools=\(profile.expectedTools.sorted().joined(separator: ",")) " +
            "expected_fragments=\(expectedFragments.joined(separator: ",")) " +
            "key_prefix=\(String(apiKey.prefix(7)))…"
        )

        let systemMessage = CompletionsMessage(
            role: "system",
            content: systemPromptName,
            vars: [:]
        )
        let userMessage = CompletionsMessage(
            role: "user",
            content: profile.userMessage(fixture),
            vars: [:]
        )

        let bundle = BYOKConfig(
            background: tier == "background" ? BYOKTierConfig(provider: provider, api_key: apiKey, model: model) : nil,
            interactive: tier == "interactive" ? BYOKTierConfig(provider: provider, api_key: apiKey, model: model) : nil
        )

        let request = CompletionsRequest(
            messages: [systemMessage, userMessage],
            client_timezone: TimeZone.current.identifier,
            disable_tools: false,
            web_search_enabled: false,
            conversation_state: nil,
            byok: bundle
        )

        let observer = BYOKSmokeObserver(logContext: logCtx)
        let handler: SSEEventHandler = { event in
            observer.record(event)
        }

        var response: CompletionsResponse?
        var transportError: Error?
        do {
            response = try await sendCompletionsWithToolsDirect(request, onSSEEvent: handler)
        } catch {
            transportError = error
            BackgroundSyncLogger.logAIProcessing(
                "[BYOK_SMOKE \(logCtx)] TRANSPORT_ERROR type=\(type(of: error)) " +
                "desc=\(error.localizedDescription)"
            )
        }

        let latencyMs = Int((CFAbsoluteTimeGetCurrent() - t0) * 1000)
        let snap = observer.snapshot()

        // Pre-assembly snapshot dump — useful when stages later report
        // "missing tool X" so we can see which tools actually fired.
        BackgroundSyncLogger.logAIProcessing(
            "[BYOK_SMOKE \(logCtx)] PRE_ASSEMBLE " +
            "events=\(snap.eventCount) " +
            "tool_started=[\(snap.toolStartedNames.sorted().joined(separator: ","))] " +
            "tool_completed=[\(snap.toolCompletedNames.sorted().joined(separator: ","))] " +
            "tool_failed=[\(snap.toolFailedNames.sorted().joined(separator: ","))] " +
            "backend_error=\(snap.backendError ?? "-") " +
            "byok_routed=\(response?.byok_routed.map(String.init(describing:)) ?? "nil") " +
            "byok_provider=\(response?.byok_provider ?? "-") " +
            "byok_tier=\(response?.byok_tier ?? "-") " +
            "byok_skip_reason=\(response?.byok_skip_reason ?? "-") " +
            "response_error_code=\(response?.error_code ?? "-") " +
            "response_error_detail=\(response?.error_detail ?? "-") " +
            "response_error=\(response?.error ?? "-") " +
            "assistant_len=\(response?.assistant?.count ?? 0)"
        )

        let result = Self.assembleSmokeResult(
            response: response,
            transportError: transportError,
            snapshot: snap,
            latencyMs: latencyMs,
            profile: profile,
            expectedFragments: expectedFragments
        )

        let stageLine = result.stages.map {
            "\($0.ok ? "+" : "-")\($0.name)\($0.detail.map { " (\($0))" } ?? "")"
        }.joined(separator: " | ")
        BackgroundSyncLogger.logAIProcessing(
            "[BYOK_SMOKE \(logCtx)] DONE ok=\(result.ok) latency=\(latencyMs)ms " +
            "stages: \(stageLine)"
        )

        return result
    }

    /// Pure assembly logic — kept separate so tests can feed in synthetic
    /// `BYOKSmokeObserver.Snapshot` + `CompletionsResponse` and assert the
    /// stage list, without spinning up URLSession.
    static func assembleSmokeResult(
        response: CompletionsResponse?,
        transportError: Error?,
        snapshot snap: BYOKSmokeObserver.Snapshot,
        latencyMs: Int,
        profile: BYOKSmokeProfile,
        expectedFragments: [String]
    ) -> BYOKSmokeResult {
        var stages: [BYOKSmokeStage] = []
        let expectedTools = profile.expectedTools
        let expectedToolsList = expectedTools.sorted().joined(separator: ", ")

        // Stage 1 — backend stream opened.
        let streamOpened = snap.sawAnyEvent || response != nil
        stages.append(BYOKSmokeStage(
            name: "Backend stream opened",
            ok: streamOpened,
            detail: streamOpened ? nil : "no events received before transport failure"
        ))

        // Stages 2 & 3 — tool call + execution. ONLY for tool-calling profiles
        // (compose, agent). Summary is a summarization prompt per the catalog —
        // it does no tool check (forcing one reads as prompt injection and gets
        // refused). When expectedTools is empty, skip both stages entirely.
        if !expectedTools.isEmpty {
            // Stage 2 — model invoked every expected tool (multi-tool profiles
            // require both). Surface which expected tools the model skipped and
            // which unexpected tools (if any) it called instead.
            let missingStarted = expectedTools.subtracting(snap.toolStartedNames)
            let extraStarted = snap.toolStartedNames.subtracting(expectedTools).sorted()
            let toolCalled = missingStarted.isEmpty
            let toolCalledDetail: String?
            if toolCalled {
                toolCalledDetail = "called \(expectedToolsList)"
            } else if snap.toolStartedNames.isEmpty {
                toolCalledDetail = "model returned without invoking any tool"
            } else if extraStarted.isEmpty {
                toolCalledDetail = "missing: \(missingStarted.sorted().joined(separator: ", "))"
            } else {
                toolCalledDetail = "missing: \(missingStarted.sorted().joined(separator: ", "))" +
                    "; unexpected: \(extraStarted.joined(separator: ", "))"
            }
            stages.append(BYOKSmokeStage(
                name: "Model called \(expectedToolsList)",
                ok: toolCalled,
                // Keep the specific reason (no tool / missing X / unexpected Y) — it's
                // useful for debugging. The stage is non-fatal (`fatal: false`), so it
                // never fails the smoke; a capable model answering directly is fine.
                detail: toolCalledDetail,
                fatal: false
            ))

            // Stage 3 — server executed every expected tool successfully. Any tool
            // in expected ∩ failed counts as a failure for stage 3.
            let missingCompleted = expectedTools.subtracting(snap.toolCompletedNames)
            let anyFailed = !expectedTools.intersection(snap.toolFailedNames).isEmpty
            let toolCompleted = missingCompleted.isEmpty && !anyFailed
            let toolCompletedDetail: String?
            if toolCompleted {
                toolCompletedDetail = nil
            } else if anyFailed {
                let failed = expectedTools.intersection(snap.toolFailedNames).sorted().joined(separator: ", ")
                toolCompletedDetail = "tool_failed for: \(failed)"
            } else if !missingStarted.isEmpty {
                toolCompletedDetail = "tools were never invoked"
            } else {
                toolCompletedDetail = "tool_started but no completion for: \(missingCompleted.sorted().joined(separator: ", "))"
            }
            stages.append(BYOKSmokeStage(
                name: "Server executed \(expectedToolsList)",
                ok: toolCompleted,
                detail: toolCompletedDetail,
                fatal: false
            ))
        }

        // Stage 4 — backend flagged the response as BYOK-routed. If false, the
        // request fell through to the TabMail pool.
        let byokRouted = response?.byok_routed ?? false
        let byokRoutedDetail: String?
        if byokRouted {
            byokRoutedDetail = "tier=\(response?.byok_tier ?? "?") provider=\(response?.byok_provider ?? "?")"
        } else if let skip = response?.byok_skip_reason {
            byokRoutedDetail = "skipped: \(skip)"
        } else {
            byokRoutedDetail = "backend did not set byok_routed=true"
        }
        stages.append(BYOKSmokeStage(
            name: "BYOK routing confirmed",
            ok: byokRouted,
            detail: byokRoutedDetail
        ))

        // Stage 5 — final response received with assistant text.
        let finalText = response?.assistant
        let hasFinal = !(finalText?.isEmpty ?? true)
        stages.append(BYOKSmokeStage(
            name: "Final response received",
            ok: hasFinal,
            detail: hasFinal ? String(finalText!.prefix(200)) : "no assistant text in final event"
        ))

        // Stage 6 — response contains every expected text fragment (case-
        // insensitive). For multi-tool profiles every fragment must appear.
        let fragments = expectedFragments
        let missingFragments = fragments.filter { frag in
            finalText?.range(of: frag, options: .caseInsensitive) == nil
        }
        let fragmentsOk = missingFragments.isEmpty && hasFinal
        let fragsLabel = fragments.joined(separator: " + ")
        stages.append(BYOKSmokeStage(
            name: "Response mentions \(fragsLabel)",
            ok: fragmentsOk,
            detail: fragmentsOk ? nil : "missing: \(missingFragments.joined(separator: ", "))"
        ))

        // Resolve a single error_code / error_detail. Priority order:
        //   1. Backend BYOK provider-error envelope (4xx/5xx mapped by gateway)
        //   2. Transport / HTTP error (auth, network)
        //   3. SSE `error` event (backend-internal failure mid-stream)
        var errorCode: String? = response?.error_code
        var errorDetail: String? = response?.error_detail ?? response?.error
        if errorCode == nil, let te = transportError {
            switch te {
            case BackendError.unauthorized: errorCode = "unauthorized"
            case BackendError.forbidden: errorCode = "forbidden"
            case BackendError.requestFailed(let st): errorCode = "http_\(st)"
            default: errorCode = "transport_error"
            }
            errorDetail = te.localizedDescription
        }
        if errorCode == nil, let backendErr = snap.backendError {
            errorCode = "backend_error"
            errorDetail = backendErr
        }

        // Only FATAL stages gate the verdict. Non-fatal (informational) stages —
        // model-called-tool / server-executed-tool — are surfaced but don't fail
        // the smoke (a capable model answering correctly without a tool is still
        // a successful BYOK round-trip).
        let allOk = stages.allSatisfy { $0.fatal ? $0.ok : true } && errorCode == nil

        return BYOKSmokeResult(
            ok: allOk,
            stages: stages,
            latencyMs: latencyMs,
            errorCode: errorCode,
            errorDetail: errorDetail,
            finalText: finalText,
            byokRouted: response?.byok_routed,
            byokProvider: response?.byok_provider,
            byokTier: response?.byok_tier
        )
    }
}

enum BackendError: Error, LocalizedError {
    case requestFailed(statusCode: Int)
    case unauthorized
    case accountGone  // Server confirmed user is not logged in (account deleted/token revoked)
    case forbidden    // 403 — dev access denied or feature disabled; exponential backoff active

    /// Whether this error is retriable (network errors, timeouts, 429, 5xx).
    var isRetriable: Bool {
        switch self {
        case .unauthorized, .accountGone, .forbidden: return false
        case .requestFailed(let code):
            // Retry: 0 (network failure), 408 (timeout), 429 (rate limit), 5xx (server error)
            // Don't retry: other 4xx (client error — our request is wrong)
            return code == 0 || code == 408 || code == 429 || (500...599).contains(code)
        }
    }

    var errorDescription: String? {
        switch self {
        case .requestFailed(let code): return "Request failed: \(code)"
        case .unauthorized: return "Unauthorized (401)"
        case .accountGone: return "Account no longer exists"
        case .forbidden: return "Forbidden (403) — backing off"
        }
    }
}
