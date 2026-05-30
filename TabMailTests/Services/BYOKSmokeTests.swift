/* This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at https://mozilla.org/MPL/2.0/. */

import Testing
import Foundation
@testable import TabMail

/// Unit tests for `BackendClient.runBYOKSmoke` — split into the pure
/// `assembleSmokeResult` static helper (drives the stage-list logic), the
/// `BYOKSmokeObserver` SSE-event aggregator, and `BYOKSmokeProfile` semantics
/// (system prompts, tools, fragments per profile). All offline, deterministic.

// MARK: - BYOKSmokeProfile

@Suite("BYOKSmokeProfile")
struct BYOKSmokeProfileTests {

    @Test("compose maps to system_prompt_compose for background")
    func composeBackgroundPrompt() {
        #expect(BYOKSmokeProfile.compose.systemPromptName(tier: "background") == "system_prompt_compose")
    }

    @Test("compose maps to system_prompt_compose_interactive for interactive")
    func composeInteractivePrompt() {
        #expect(BYOKSmokeProfile.compose.systemPromptName(tier: "interactive") == "system_prompt_compose_interactive")
    }

    @Test("summary always maps to system_prompt_summary")
    func summaryPrompt() {
        #expect(BYOKSmokeProfile.summary.systemPromptName(tier: "background") == "system_prompt_summary")
    }

    @Test("agentMultiTool maps to system_prompt_agent")
    func agentPrompt() {
        #expect(BYOKSmokeProfile.agentMultiTool.systemPromptName(tier: "interactive") == "system_prompt_agent")
    }

    @Test("compose applies to both tiers")
    func composeApplies() {
        #expect(BYOKSmokeProfile.compose.appliesTo(tier: "background") == true)
        #expect(BYOKSmokeProfile.compose.appliesTo(tier: "interactive") == true)
    }

    @Test("summary applies to background only — its system prompt resolves there")
    func summaryAppliesBackgroundOnly() {
        #expect(BYOKSmokeProfile.summary.appliesTo(tier: "background") == true)
        #expect(BYOKSmokeProfile.summary.appliesTo(tier: "interactive") == false)
    }

    @Test("agentMultiTool applies to interactive only — system_prompt_agent is heaviest")
    func agentAppliesInteractiveOnly() {
        #expect(BYOKSmokeProfile.agentMultiTool.appliesTo(tier: "background") == false)
        #expect(BYOKSmokeProfile.agentMultiTool.appliesTo(tier: "interactive") == true)
    }

    @Test("compose expected tools is just date_to_day")
    func composeTools() {
        #expect(BYOKSmokeProfile.compose.expectedTools == ["date_to_day"])
    }

    @Test("summary expects no tool calls — it's a pure summarization prompt")
    func summaryTools() {
        #expect(BYOKSmokeProfile.summary.expectedTools.isEmpty)
    }

    @Test("agentMultiTool expected tools is both date_to_day and time_delta")
    func agentTools() {
        #expect(BYOKSmokeProfile.agentMultiTool.expectedTools == ["date_to_day", "time_delta"])
    }

    // Fixed fixture for deterministic fragment/message assertions. (Production
    // uses BYOKSmokeFixture.make() with an arbitrary future date; here we pin
    // values so the asserts are stable.)
    private static let fx = BYOKSmokeFixture(
        date: "2031-07-19", dayName: "Saturday", deltaDays: 7, deltaResultDate: "2031-07-26"
    )

    @Test("compose fragment is the fixture's day name")
    func composeFragment() {
        #expect(BYOKSmokeProfile.compose.expectedTextFragments(Self.fx) == ["Saturday"])
    }

    @Test("summary fragment is the project codename that must survive summarization")
    func summaryFragment() {
        #expect(BYOKSmokeProfile.summary.expectedTextFragments(Self.fx) == [BYOKSmokeProfile.summaryCodename])
    }

    @Test("agentMultiTool checks BOTH the day name and the delta-result date")
    func agentFragments() {
        #expect(BYOKSmokeProfile.agentMultiTool.expectedTextFragments(Self.fx) == ["Saturday", "2031-07-26"])
    }

    @Test("User message for compose names date_to_day + the fixture date + forbids guessing")
    func composeUserMessage() {
        let msg = BYOKSmokeProfile.compose.userMessage(Self.fx)
        #expect(msg.contains("date_to_day"))
        #expect(msg.contains("2031-07-19"))
        #expect(msg.localizedCaseInsensitiveContains("must call"))
    }

    @Test("User message for summary is a summarization task carrying the codename")
    func summaryUserMessage() {
        let msg = BYOKSmokeProfile.summary.userMessage(Self.fx)
        #expect(msg.localizedCaseInsensitiveContains("summarize"))
        #expect(msg.contains(BYOKSmokeProfile.summaryCodename))
        // No tool name should be demanded — summary is not a tool-calling prompt.
        #expect(msg.contains("time_delta") == false)
    }

    @Test("User message for agentMultiTool names both tools")
    func agentUserMessage() {
        let msg = BYOKSmokeProfile.agentMultiTool.userMessage(Self.fx)
        #expect(msg.contains("date_to_day"))
        #expect(msg.contains("time_delta"))
    }

    @Test("BYOKSmokeFixture.make computes a future date with matching UTC weekday + delta")
    func fixtureMakeIsConsistent() {
        let f = BYOKSmokeFixture.make()
        // date is YYYY-MM-DD and in the future
        #expect(f.date.count == 10)
        let names: Set<String> = ["Sunday", "Monday", "Tuesday", "Wednesday", "Thursday", "Friday", "Saturday"]
        #expect(names.contains(f.dayName))
        // deltaResultDate is date + deltaDays in UTC; recompute to verify.
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(identifier: "UTC")!
        let fmt = DateFormatter()
        fmt.calendar = cal; fmt.timeZone = cal.timeZone
        fmt.locale = Locale(identifier: "en_US_POSIX"); fmt.dateFormat = "yyyy-MM-dd"
        let start = fmt.date(from: f.date)!
        let expectedResult = fmt.string(from: cal.date(byAdding: .day, value: f.deltaDays, to: start)!)
        #expect(f.deltaResultDate == expectedResult)
    }
}

// MARK: - BYOKSmokeObserver

@Suite("BYOKSmokeObserver")
struct BYOKSmokeObserverTests {

    @Test("Starts empty")
    func emptyOnInit() {
        let obs = BYOKSmokeObserver()
        let snap = obs.snapshot()
        #expect(snap.sawAnyEvent == false)
        #expect(snap.toolStartedNames.isEmpty)
        #expect(snap.toolCompletedNames.isEmpty)
        #expect(snap.toolFailedNames.isEmpty)
        #expect(snap.backendError == nil)
        #expect(snap.finalAssistant == nil)
    }

    @Test("Records tool_started by tool_name")
    func toolStarted() {
        let obs = BYOKSmokeObserver()
        let event = ToolStatusEvent(
            execution_id: "x", call_id: "c", display_label: "L",
            tool_name: "date_to_day", success: nil, elapsed_ms: nil,
            error: nil, result: nil
        )
        obs.record(.toolStarted(event))
        let snap = obs.snapshot()
        #expect(snap.sawAnyEvent == true)
        #expect(snap.toolStartedNames.contains("date_to_day"))
        #expect(snap.toolCompletedNames.isEmpty)
    }

    @Test("Records tool_completed by tool_name")
    func toolCompleted() {
        let obs = BYOKSmokeObserver()
        let event = ToolStatusEvent(
            execution_id: nil, call_id: nil, display_label: nil,
            tool_name: "date_to_day", success: true, elapsed_ms: 12,
            error: nil, result: "Thursday"
        )
        obs.record(.toolCompleted(event))
        #expect(obs.snapshot().toolCompletedNames.contains("date_to_day"))
    }

    @Test("Records tool_failed by tool_name")
    func toolFailed() {
        let obs = BYOKSmokeObserver()
        let event = ToolStatusEvent(
            execution_id: nil, call_id: nil, display_label: nil,
            tool_name: "date_to_day", success: false, elapsed_ms: nil,
            error: "Boom", result: nil
        )
        obs.record(.toolFailed(event))
        #expect(obs.snapshot().toolFailedNames.contains("date_to_day"))
    }

    @Test("Records backend error event")
    func backendError() {
        let obs = BYOKSmokeObserver()
        obs.record(.error("upstream timed out"))
        #expect(obs.snapshot().backendError == "upstream timed out")
    }

    @Test("Records final assistant text")
    func finalEvent() {
        let obs = BYOKSmokeObserver()
        let final = CompletionsFinalEvent(
            assistant: "2025-12-25 is a Thursday.",
            token_usage: nil, error: nil, tool_calls: nil,
            conversation_state: nil, thinking: nil
        )
        obs.record(.final(final))
        #expect(obs.snapshot().finalAssistant == "2025-12-25 is a Thursday.")
    }

    @Test("Keepalive and throttle are no-ops beyond sawAnyEvent")
    func nonRecordedEvents() {
        let obs = BYOKSmokeObserver()
        obs.record(.keepalive)
        obs.record(.throttled)
        obs.record(.throttleEnded)
        let snap = obs.snapshot()
        #expect(snap.sawAnyEvent == true)
        #expect(snap.toolStartedNames.isEmpty)
        #expect(snap.finalAssistant == nil)
        #expect(snap.backendError == nil)
    }

    @Test("Multiple events accumulate")
    func multipleEvents() {
        let obs = BYOKSmokeObserver()
        let started = ToolStatusEvent(execution_id: nil, call_id: nil, display_label: nil, tool_name: "date_to_day", success: nil, elapsed_ms: nil, error: nil, result: nil)
        let completed = ToolStatusEvent(execution_id: nil, call_id: nil, display_label: nil, tool_name: "date_to_day", success: true, elapsed_ms: 8, error: nil, result: "Thursday")
        let final = CompletionsFinalEvent(assistant: "Thursday.", token_usage: nil, error: nil, tool_calls: nil, conversation_state: nil, thinking: nil)
        obs.record(.toolStarted(started))
        obs.record(.toolCompleted(completed))
        obs.record(.final(final))
        let snap = obs.snapshot()
        #expect(snap.toolStartedNames == ["date_to_day"])
        #expect(snap.toolCompletedNames == ["date_to_day"])
        #expect(snap.finalAssistant == "Thursday.")
    }
}

// MARK: - assembleSmokeResult

@Suite("BackendClient.assembleSmokeResult — compose profile")
struct AssembleSmokeResultComposeTests {

    private func happySnapshot(finalText: String = "2025-12-25 is a Thursday.") -> BYOKSmokeObserver.Snapshot {
        var s = BYOKSmokeObserver.Snapshot()
        s.sawAnyEvent = true
        s.toolStartedNames = ["date_to_day"]
        s.toolCompletedNames = ["date_to_day"]
        s.finalAssistant = finalText
        return s
    }

    private func happyResponse(text: String = "2025-12-25 is a Thursday.") -> CompletionsResponse {
        CompletionsResponse(
            assistant: text,
            token_usage: nil,
            error: nil,
            byok_routed: true,
            byok_provider: "openai",
            byok_tier: "background"
        )
    }

    @Test("Happy path — all six stages green, ok=true")
    func happy() {
        let result = BackendClient.assembleSmokeResult(
            response: happyResponse(),
            transportError: nil,
            snapshot: happySnapshot(),
            latencyMs: 8500,
            profile: .compose,
            expectedFragments: ["Thursday"]
        )
        #expect(result.ok == true)
        #expect(result.stages.count == 6)
        #expect(result.stages.allSatisfy { $0.ok })
        #expect(result.errorCode == nil)
        #expect(result.byokRouted == true)
        #expect(result.byokProvider == "openai")
        #expect(result.byokTier == "background")
        #expect(result.latencyMs == 8500)
    }

    @Test("Case-insensitive day match — 'thursday' lowercase passes")
    func lowercaseDay() {
        let result = BackendClient.assembleSmokeResult(
            response: happyResponse(text: "the day is thursday."),
            transportError: nil,
            snapshot: happySnapshot(finalText: "the day is thursday."),
            latencyMs: 1,
            profile: .compose,
            expectedFragments: ["Thursday"]
        )
        #expect(result.ok == true)
    }

    @Test("Model didn't call the tool — stage 2 fails and surfaces 'no tool'")
    func noToolCall() {
        var snap = BYOKSmokeObserver.Snapshot()
        snap.sawAnyEvent = true
        snap.finalAssistant = "Christmas 2025 is on a Wednesday I think."
        let result = BackendClient.assembleSmokeResult(
            response: CompletionsResponse(
                assistant: "Christmas 2025 is on a Wednesday I think.",
                token_usage: nil, error: nil,
                byok_routed: true, byok_provider: "openai", byok_tier: "background"
            ),
            transportError: nil,
            snapshot: snap,
            latencyMs: 4000,
            profile: .compose,
            expectedFragments: ["Thursday"]
        )
        #expect(result.ok == false)
        let toolStage = result.stages.first { $0.name.hasPrefix("Model called") }
        #expect(toolStage?.ok == false)
        #expect(toolStage?.detail?.contains("without invoking") == true)
        let dayStage = result.stages.first { $0.name.hasPrefix("Response mentions") }
        #expect(dayStage?.ok == false)
    }

    @Test("Model called the wrong tool — detail flags unexpected tool")
    func wrongToolCall() {
        var snap = BYOKSmokeObserver.Snapshot()
        snap.sawAnyEvent = true
        snap.toolStartedNames = ["search_web"]
        snap.finalAssistant = "Thursday."
        let result = BackendClient.assembleSmokeResult(
            response: happyResponse(text: "Thursday."),
            transportError: nil,
            snapshot: snap,
            latencyMs: 1,
            profile: .compose,
            expectedFragments: ["Thursday"]
        )
        let toolStage = result.stages.first { $0.name.hasPrefix("Model called") }
        #expect(toolStage?.ok == false)
        #expect(toolStage?.detail?.contains("unexpected") == true)
        #expect(toolStage?.detail?.contains("search_web") == true)
    }

    @Test("Tool failed — stage 3 detail reads tool_failed")
    func toolFailed() {
        var snap = BYOKSmokeObserver.Snapshot()
        snap.sawAnyEvent = true
        snap.toolStartedNames = ["date_to_day"]
        snap.toolFailedNames = ["date_to_day"]
        snap.finalAssistant = "Something went wrong."
        let result = BackendClient.assembleSmokeResult(
            response: happyResponse(text: "Something went wrong."),
            transportError: nil,
            snapshot: snap,
            latencyMs: 1,
            profile: .compose,
            expectedFragments: ["Thursday"]
        )
        let execStage = result.stages.first { $0.name.hasPrefix("Server executed") }
        #expect(execStage?.ok == false)
        #expect(execStage?.detail?.contains("tool_failed") == true)
    }

    @Test("BYOK not routed — backend skipped (e.g. demo gate)")
    func byokSkipped() {
        let result = BackendClient.assembleSmokeResult(
            response: CompletionsResponse(
                assistant: "Thursday.",
                token_usage: nil, error: nil,
                byok_routed: false, byok_provider: nil, byok_tier: nil,
                byok_skip_reason: "demo_not_allowed"
            ),
            transportError: nil,
            snapshot: happySnapshot(finalText: "Thursday."),
            latencyMs: 1,
            profile: .compose,
            expectedFragments: ["Thursday"]
        )
        let stage = result.stages.first { $0.name == "BYOK routing confirmed" }
        #expect(stage?.ok == false)
        #expect(stage?.detail == "skipped: demo_not_allowed")
        #expect(result.ok == false)
    }

    @Test("BYOK provider rejected the key — errorCode from response.error_code")
    func providerRejection() {
        let result = BackendClient.assembleSmokeResult(
            response: CompletionsResponse(
                assistant: nil,
                token_usage: nil, error: nil,
                byok_routed: false, byok_provider: "openai", byok_tier: "background",
                byok_skip_reason: nil,
                error_code: "byok_key_rejected",
                error_detail: "Incorrect API key"
            ),
            transportError: nil,
            snapshot: BYOKSmokeObserver.Snapshot(),
            latencyMs: 200,
            profile: .compose,
            expectedFragments: ["Thursday"]
        )
        #expect(result.ok == false)
        #expect(result.errorCode == "byok_key_rejected")
        #expect(result.errorDetail == "Incorrect API key")
    }

    @Test("Transport unauthorized — errorCode normalized to 'unauthorized'")
    func transportUnauthorized() {
        let result = BackendClient.assembleSmokeResult(
            response: nil,
            transportError: BackendError.unauthorized,
            snapshot: BYOKSmokeObserver.Snapshot(),
            latencyMs: 50,
            profile: .compose,
            expectedFragments: ["Thursday"]
        )
        #expect(result.ok == false)
        #expect(result.errorCode == "unauthorized")
    }

    @Test("Transport http_500 — errorCode formatted with status")
    func transport500() {
        let result = BackendClient.assembleSmokeResult(
            response: nil,
            transportError: BackendError.requestFailed(statusCode: 500),
            snapshot: BYOKSmokeObserver.Snapshot(),
            latencyMs: 50,
            profile: .compose,
            expectedFragments: ["Thursday"]
        )
        #expect(result.errorCode == "http_500")
    }

    @Test("Mid-stream backend error event — captured as backend_error")
    func midStreamError() {
        var snap = BYOKSmokeObserver.Snapshot()
        snap.sawAnyEvent = true
        snap.backendError = "internal_error"
        let result = BackendClient.assembleSmokeResult(
            response: nil,
            transportError: nil,
            snapshot: snap,
            latencyMs: 100,
            profile: .compose,
            expectedFragments: ["Thursday"]
        )
        #expect(result.errorCode == "backend_error")
        #expect(result.errorDetail == "internal_error")
    }

    @Test("Provider error_code wins over transport error in priority")
    func providerErrorWinsOverTransport() {
        let result = BackendClient.assembleSmokeResult(
            response: CompletionsResponse(
                assistant: nil, token_usage: nil, error: nil,
                byok_routed: false, byok_provider: nil, byok_tier: nil,
                byok_skip_reason: nil,
                error_code: "byok_rate_limited", error_detail: "slow down"
            ),
            transportError: BackendError.requestFailed(statusCode: 500),
            snapshot: BYOKSmokeObserver.Snapshot(),
            latencyMs: 0,
            profile: .compose,
            expectedFragments: ["Thursday"]
        )
        #expect(result.errorCode == "byok_rate_limited")
    }
}

@Suite("BackendClient.assembleSmokeResult — summary profile")
struct AssembleSmokeResultSummaryTests {

    // Summary is a pure summarization prompt — it does NOT demand any tools, so
    // the runner emits no "Model called …" / "Server executed …" stages for it.
    // A pass is routing-confirmed + non-empty response + the codename retained.
    private static let codename = BYOKSmokeProfile.summaryCodename

    @Test("Happy path — no tool stages, codename retained")
    func happy() {
        var snap = BYOKSmokeObserver.Snapshot()
        snap.sawAnyEvent = true
        snap.finalAssistant = "The \(Self.codename) migration is on track."
        let result = BackendClient.assembleSmokeResult(
            response: CompletionsResponse(
                assistant: "The \(Self.codename) migration is on track.",
                token_usage: nil, error: nil,
                byok_routed: true, byok_provider: "anthropic", byok_tier: "background"
            ),
            transportError: nil,
            snapshot: snap,
            latencyMs: 6000,
            profile: .summary,
            expectedFragments: [Self.codename]
        )
        #expect(result.ok == true)
        #expect(result.stages.allSatisfy { $0.ok })
    }

    @Test("Summary emits NO tool stages — tool checks live on compose/agent only")
    func noToolStages() {
        var snap = BYOKSmokeObserver.Snapshot()
        snap.sawAnyEvent = true
        // Even if the model gratuitously fired a tool, summary does not check it.
        snap.toolStartedNames = ["time_delta"]
        snap.toolCompletedNames = ["time_delta"]
        snap.finalAssistant = "The \(Self.codename) migration is on track."
        let result = BackendClient.assembleSmokeResult(
            response: CompletionsResponse(
                assistant: "The \(Self.codename) migration is on track.",
                token_usage: nil, error: nil,
                byok_routed: true, byok_provider: "anthropic", byok_tier: "background"
            ),
            transportError: nil,
            snapshot: snap,
            latencyMs: 1,
            profile: .summary,
            expectedFragments: [Self.codename]
        )
        #expect(result.ok == true)
        #expect(result.stages.contains { $0.name.hasPrefix("Model called") } == false)
        #expect(result.stages.contains { $0.name.hasPrefix("Server executed") } == false)
    }

    @Test("Final text missing the codename fails the fragment stage")
    func missingFragment() {
        var snap = BYOKSmokeObserver.Snapshot()
        snap.sawAnyEvent = true
        snap.finalAssistant = "The migration is on track."
        let result = BackendClient.assembleSmokeResult(
            response: CompletionsResponse(
                assistant: "The migration is on track.",
                token_usage: nil, error: nil,
                byok_routed: true, byok_provider: "anthropic", byok_tier: "background"
            ),
            transportError: nil,
            snapshot: snap,
            latencyMs: 1,
            profile: .summary,
            expectedFragments: [Self.codename]
        )
        let fragStage = result.stages.first { $0.name.hasPrefix("Response mentions") }
        #expect(fragStage?.ok == false)
        #expect(fragStage?.detail?.contains(Self.codename) == true)
    }
}

@Suite("BackendClient.assembleSmokeResult — agentMultiTool profile")
struct AssembleSmokeResultAgentMultiToolTests {

    @Test("Happy path — both tools fire, both fragments present")
    func happy() {
        var snap = BYOKSmokeObserver.Snapshot()
        snap.sawAnyEvent = true
        snap.toolStartedNames = ["date_to_day", "time_delta"]
        snap.toolCompletedNames = ["date_to_day", "time_delta"]
        snap.finalAssistant = "2025-12-25 is Thursday; adding 7 days yields 2026-01-01."
        let result = BackendClient.assembleSmokeResult(
            response: CompletionsResponse(
                assistant: "2025-12-25 is Thursday; adding 7 days yields 2026-01-01.",
                token_usage: nil, error: nil,
                byok_routed: true, byok_provider: "google", byok_tier: "interactive"
            ),
            transportError: nil,
            snapshot: snap,
            latencyMs: 12000,
            profile: .agentMultiTool,
            expectedFragments: ["Thursday", "2026-01-01"]
        )
        #expect(result.ok == true)
        #expect(result.stages.allSatisfy { $0.ok })
    }

    @Test("Only one of two tools called — stage 2 surfaces missing tool (informational, non-fatal)")
    func partialToolCall() {
        var snap = BYOKSmokeObserver.Snapshot()
        snap.sawAnyEvent = true
        snap.toolStartedNames = ["date_to_day"] // missing time_delta
        snap.toolCompletedNames = ["date_to_day"]
        snap.finalAssistant = "Thursday, and probably 2026-01-01."
        let result = BackendClient.assembleSmokeResult(
            response: CompletionsResponse(
                assistant: "Thursday, and probably 2026-01-01.",
                token_usage: nil, error: nil,
                byok_routed: true, byok_provider: "google", byok_tier: "interactive"
            ),
            transportError: nil,
            snapshot: snap,
            latencyMs: 8000,
            profile: .agentMultiTool,
            expectedFragments: ["Thursday", "2026-01-01"]
        )
        // Both expected fragments are present + routing confirmed → PASS. The
        // missing time_delta tool call is flagged on the (non-fatal) tool stage.
        #expect(result.ok == true)
        let toolStage = result.stages.first { $0.name.hasPrefix("Model called") }
        #expect(toolStage?.ok == false)
        #expect(toolStage?.fatal == false)
        #expect(toolStage?.detail?.contains("time_delta") == true)
    }

    @Test("Both tools fire but only one completed — stage 3 fails")
    func partialToolCompleted() {
        var snap = BYOKSmokeObserver.Snapshot()
        snap.sawAnyEvent = true
        snap.toolStartedNames = ["date_to_day", "time_delta"]
        snap.toolCompletedNames = ["date_to_day"] // time_delta never completed
        snap.finalAssistant = "Thursday and 2026-01-01."
        let result = BackendClient.assembleSmokeResult(
            response: CompletionsResponse(
                assistant: "Thursday and 2026-01-01.",
                token_usage: nil, error: nil,
                byok_routed: true, byok_provider: "google", byok_tier: "interactive"
            ),
            transportError: nil,
            snapshot: snap,
            latencyMs: 8000,
            profile: .agentMultiTool,
            expectedFragments: ["Thursday", "2026-01-01"]
        )
        let execStage = result.stages.first { $0.name.hasPrefix("Server executed") }
        #expect(execStage?.ok == false)
        #expect(execStage?.detail?.contains("time_delta") == true)
    }

    @Test("Both tools complete, but final text only has one fragment — stage 6 lists missing")
    func partialFragments() {
        var snap = BYOKSmokeObserver.Snapshot()
        snap.sawAnyEvent = true
        snap.toolStartedNames = ["date_to_day", "time_delta"]
        snap.toolCompletedNames = ["date_to_day", "time_delta"]
        snap.finalAssistant = "Thursday. (date arithmetic done.)"
        let result = BackendClient.assembleSmokeResult(
            response: CompletionsResponse(
                assistant: "Thursday. (date arithmetic done.)",
                token_usage: nil, error: nil,
                byok_routed: true, byok_provider: "google", byok_tier: "interactive"
            ),
            transportError: nil,
            snapshot: snap,
            latencyMs: 1,
            profile: .agentMultiTool,
            expectedFragments: ["Thursday", "2026-01-01"]
        )
        let fragStage = result.stages.first { $0.name.hasPrefix("Response mentions") }
        #expect(fragStage?.ok == false)
        #expect(fragStage?.detail?.contains("2026-01-01") == true)
        // Thursday is present, so should NOT be in missing list.
        #expect(fragStage?.detail?.contains("Thursday") == false)
    }
}
