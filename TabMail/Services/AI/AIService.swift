/* This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at https://mozilla.org/MPL/2.0/. */

import Foundation

actor AIService {
    static let shared = AIService()
    private let backendClient = BackendClient()

    /// UserDefaults key for the privacy opt-out toggle (Settings → AI Settings → Privacy).
    /// When true, blocks ALL AI backend calls. Device Sync cache hits still work.
    /// Same literal as `SharedNSEData.aiOptOutAllKey` — see that declaration.
    static let optOutAllAIKey = "privacy_opt_out_all_ai"

    /// App Group suite used for the AI opt-out flag. The NSE runs in a
    /// separate process and has its own `UserDefaults.standard` namespace, so
    /// the flag lives in the shared group suite (`group.ai.tabmail`). All
    /// reads/writes of the flag — in Settings, in the consent view, here in
    /// AIService, and in `NSEState.isAIDisabled` — go through this store.
    static var optOutStore: UserDefaults {
        UserDefaults(suiteName: "group.ai.tabmail") ?? .standard
    }

    /// Write the opt-out flag. Views/settings call this instead of touching
    /// UserDefaults directly so the App Group suite is always updated.
    static func writeOptOutFlag(_ value: Bool) {
        optOutStore.set(value, forKey: optOutAllAIKey)
    }

    /// UserDefaults key for the web search toggle (Settings → AI Settings → Privacy).
    /// When true, allows the `search_web` server-side tool. Default: false (matching TB).
    static let webSearchEnabledKey = "privacy_web_search_enabled"

    /// Whether AI backend calls are disabled (privacy opt-out).
    var disableLLMCalls: Bool {
        Self.optOutStore.bool(forKey: Self.optOutAllAIKey)
    }

    /// Whether web search is enabled for the agent chat.
    /// `nonisolated` because the value lives in `UserDefaults` (thread-safe) and is read
    /// from `BackendClient` while augmenting outgoing completions requests with the user's
    /// global toggle. See `BackendClient.augmentRequestWithDefaults`.
    nonisolated var webSearchEnabled: Bool {
        UserDefaults.standard.bool(forKey: Self.webSearchEnabledKey)
    }

    // MARK: - BYOK (Bring Your Own Key) configuration

    /// UserDefaults key for the per-tier provider choice. Value is the
    /// `BYOKProvider` rawValue ("openai" | "anthropic" | "google") or the
    /// sentinel "tabmail" (default, fall through to our pool).
    static func byokProviderKey(tier: String) -> String { "byok.\(tier).provider" }

    /// UserDefaults key for the per-(tier, provider) model name. Storage is
    /// per-provider so switching providers within a tier preserves each
    /// provider's previously-selected model. Plain string; validated
    /// server-side against the allow-list.
    static func byokModelKey(tier: String, provider: String) -> String {
        "byok.\(tier).\(provider).model"
    }

    /// Resolve the user's BYOK config from `(UserDefaults provider/model) +
    /// (Keychain key)` per tier. Returns nil iff the bundle is empty (no tier
    /// configured for BYOK) OR the session is currently a demo session — demo
    /// + BYOK is rejected at the gateway, so we strip BYOK client-side too to
    /// keep the keys off the wire entirely.
    ///
    /// `nonisolated` so `BackendClient.augmentRequestWithDefaults` can attach
    /// the bundle synchronously, same pattern as `webSearchEnabled`.
    nonisolated var byokBundle: BYOKConfig? {
        // Demo defense-in-depth: never attach BYOK to demo-session requests
        // even if the user had keys configured in a prior paid session. Gateway
        // rejects them anyway (byok_skip_reason='demo_not_allowed'); skipping
        // client-side prevents keys from going over the wire to a demo path.
        if DemoTokenManager.hasSession() { return nil }

        let background = Self.resolveByokTier("background")
        let interactive = Self.resolveByokTier("interactive")
        let cfg = BYOKConfig(background: background, interactive: interactive)
        return cfg.hasAnyOverride ? cfg : nil
    }

    private nonisolated static func resolveByokTier(_ tier: String) -> BYOKTierConfig? {
        let store = UserDefaults.standard
        let provider = store.string(forKey: byokProviderKey(tier: tier)) ?? "tabmail"
        guard provider != "tabmail" else { return nil }
        guard let model = store.string(forKey: byokModelKey(tier: tier, provider: provider)), !model.isEmpty else { return nil }
        // Keys are per-provider (shared across tiers). One OpenAI key services
        // both background and interactive when both route to OpenAI.
        guard let key = KeychainHelper.loadBYOK(provider: provider), !key.isEmpty else { return nil }
        return BYOKTierConfig(provider: provider, api_key: key, model: model)
    }

    // Per-message dedup is handled by queue dedup (QueueStorage per-job-type) and GRDB
    // field checks (non-nil = already done). The direct path (AccountManagerAI) relies
    // on GRDB checks; the queue path uses QueueStorage's enqueued set.

    /// Internal access to backendClient for extensions in other files.
    var backend: BackendClient { backendClient }

    // MARK: - Combined Processing

    /// Process summary + action for a message. Returns nil only if LLM is disabled
    /// and no Device Sync result is available.
    ///
    /// Per-message dedup is handled by queue dedup (QueueStorage) and GRDB field checks.
    ///
    /// Design: one Device Sync probe, then each LLM call independently checks peer result.
    /// If peer has it → use it. If not → run LLM. No early returns or combined logic.
    func process(
        messageId: String,
        rfc822MessageId: String?,
        accountEmail: String,
        subject: String,
        from: String,
        fromAddress: String,
        date: Date,
        bodyText: String,
        htmlContent: String?,
        hasExistingAction: Bool,
        userName: String,
        kbText: String,
        actionPrompt: String,
        recipientStatus: String = ""
    ) async throws -> (summary: SummaryResult, action: ActionTag?, reply: String?)? {
        // Device Sync probe (single roundtrip, results used independently below)
        // rfc822MessageId is already stored normalized (no angle brackets/whitespace)
        var peerSummary: SummaryResult?
        var peerAction: ActionTag?
        var peerReply: String?
        if rfc822MessageId == nil {
            DeviceSyncLogger.log("AI_PROBE SKIP msgId=\(messageId.prefix(30)) — rfc822MessageId is nil")
            print("[AIService] Device Sync probe SKIPPED for \(messageId) — rfc822MessageId is nil")
        }
        // Safety: strip any stray angle brackets (should already be clean, but belt-and-suspenders)
        let probeKey = rfc822MessageId?
            .replacingOccurrences(of: "<", with: "")
            .replacingOccurrences(of: ">", with: "")
            .trimmingCharacters(in: .whitespaces)
        if let probeKey, !probeKey.isEmpty {
            let wsConnected = DeviceSyncService.checkConnected()
            DeviceSyncLogger.log("AI_PROBE START msgId=\(messageId.prefix(30)) key=\"\(probeKey)\" wsConnected=\(wsConnected)")
        }
        if let probeKey, !probeKey.isEmpty,
           let probeResults = await DeviceSyncService.shared.probeAICache(keys: [probeKey]),
           let cached = probeResults[probeKey] {
            if let ps = cached.summary {
                print("[AIService] Device Sync summary HIT for \(messageId)")
                // Convert empty strings to nil — TB uses || which treats "" as falsy,
                // so action payload gets "Not Available" instead of "" for empty Device Sync values
                peerSummary = SummaryResult(
                    blurb: ps.blurb.isEmpty ? nil : ps.blurb,
                    todos: ps.todos?.isEmpty == true ? nil : ps.todos,
                    reminderDate: ps.reminderDate?.isEmpty == true ? nil : ps.reminderDate,
                    reminderTime: ps.reminderTime?.isEmpty == true ? nil : ps.reminderTime,
                    reminderContent: ps.reminderContent?.isEmpty == true ? nil : ps.reminderContent
                )
            }
            if let pa = cached.action {
                peerAction = ActionTag(rawValue: pa)
                print("[AIService] Device Sync action HIT for \(messageId): \(peerAction?.displayName ?? pa)")
            }
            if let pr = cached.reply, !pr.isEmpty {
                peerReply = pr
                print("[AIService] Device Sync reply HIT for \(messageId)")
            }
        } else if let probeKey, !probeKey.isEmpty {
            DeviceSyncLogger.log("AI_PROBE MISS msgId=\(messageId.prefix(30)) key=\"\(probeKey)\"")
        }

        // Every seeded inbox message has its
        // summary/action/cachedReply pre-baked in DemoSeed. If we reach this
        // method for a demo session, something is wrong upstream (the GRDB
        // short-circuit in `AccountManager.processOpenedMessage` at line
        // 113 should have caught it). Hard-fail to empty results rather than
        // spending a real LLM round-trip — this keeps the budget invariant.
        let inDemo = await MainActor.run { DemoModeStore.shared.isActive }
        let demoBlock = inDemo

        // --- Summary: use Device Sync result or run LLM ---
        let summary: SummaryResult
        if let peerSummary {
            summary = peerSummary
        } else if !disableLLMCalls && !demoBlock {
            summary = try await generateSummary(
                subject: subject, from: from, fromAddress: fromAddress,
                date: date, bodyText: bodyText, htmlContent: htmlContent,
                userName: userName, kbText: kbText, recipientStatus: recipientStatus
            )
            print("[AIService] Summary generated for \(messageId): blurb=\(summary.blurb?.prefix(50) ?? "nil")")
        } else {
            if demoBlock {
                print("[AIService] Demo mode — summary LLM blocked for \(messageId)")
            } else {
                print("[AIService] No summary for \(messageId) — LLM disabled, no Device Sync result")
            }
            summary = SummaryResult(blurb: nil, todos: nil, reminderDate: nil, reminderTime: nil, reminderContent: nil)
        }

        // --- Action: use Device Sync result or run LLM (skip if IMAP tag exists) ---
        let action: ActionTag?
        if let peerAction {
            action = peerAction
        } else if !hasExistingAction && !disableLLMCalls && !demoBlock {
            action = try await classifyAction(
                subject: subject, from: from, fromAddress: fromAddress,
                bodyText: bodyText, htmlContent: htmlContent,
                summary: summary, userName: userName, actionPrompt: actionPrompt
            )
            print("[AIService] Action classified for \(messageId): \(action?.displayName ?? "nil")")
        } else {
            action = nil
        }

        return (summary, action, peerReply)
    }

    // MARK: - Tool-Enabled Completions (for chat, reply precompute, etc.)

    /// Send a completions request with full tool execution support.
    /// Used by features that need multi-turn tool loops (agent chat, reply precompute).
    /// Summary/action classification continue using the simpler `sendCompletions` path.
    ///
    /// The `onSSEEvent` callback allows callers to observe server-side tool progress
    /// (e.g., for displaying activity bubbles in the chat UI).
    func sendWithTools(
        messages: [CompletionsMessage],
        disableTools: Bool = false,
        onSSEEvent: BackendClient.SSEEventHandler? = nil,
        invocation: ToolInvocation = .noninteractive
    ) async throws -> CompletionsResponse {
        guard !disableLLMCalls else {
            return CompletionsResponse(assistant: nil, token_usage: nil, error: "AI calls disabled")
        }

        // `web_search_enabled` is stamped centrally by BackendClient.augmentRequestWithDefaults.
        let request = CompletionsRequest(
            messages: messages,
            client_timezone: TimeZone.current.identifier,
            disable_tools: disableTools ? true : nil
        )

        return try await backendClient.sendCompletionsWithTools(
            request,
            onSSEEvent: onSSEEvent,
            invocation: invocation
        )
    }

    /// Direct variant — bypasses the LLM semaphore. Use for user-initiated calls
    /// (agent chat, inline edit) that should not wait behind background AI processing.
    func sendWithToolsDirect(
        messages: [CompletionsMessage],
        disableTools: Bool = false,
        onSSEEvent: BackendClient.SSEEventHandler? = nil,
        invocation: ToolInvocation = .noninteractive
    ) async throws -> CompletionsResponse {
        guard !disableLLMCalls else {
            return CompletionsResponse(assistant: nil, token_usage: nil, error: "AI calls disabled")
        }

        // `web_search_enabled` is stamped centrally by BackendClient.augmentRequestWithDefaults.
        let request = CompletionsRequest(
            messages: messages,
            client_timezone: TimeZone.current.identifier,
            disable_tools: disableTools ? true : nil
        )

        return try await backendClient.sendCompletionsWithToolsDirect(
            request,
            onSSEEvent: onSSEEvent,
            invocation: invocation
        )
    }

    /// Resume variant — sends an ALREADY-BUILT request (carrying a saved
    /// `conversation_state`) straight through the tool loop, without rebuilding
    /// messages. Used by `resumeChatMessage` to continue a turn that was cut off in
    /// transit, so completed tool rounds are reused. Lives here (not in the AIChat
    /// extension) because `backendClient` is file-private to AIService.
    func sendWithToolsDirect(
        request: CompletionsRequest,
        onSSEEvent: BackendClient.SSEEventHandler? = nil,
        invocation: ToolInvocation = .noninteractive
    ) async throws -> CompletionsResponse {
        guard !disableLLMCalls else {
            return CompletionsResponse(assistant: nil, token_usage: nil, error: "AI calls disabled")
        }
        return try await backendClient.sendCompletionsWithToolsDirect(request, onSSEEvent: onSSEEvent, invocation: invocation)
    }
}
