/* This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at https://mozilla.org/MPL/2.0/. */

import Foundation
import Synchronization
import Testing
@testable import TabMail

/// A running tool shows a readable label, as Thunderbird's chat does (ADR-IOS-008): a server tool the
/// backend's own (`display_label`, "Searching the web: <query>"), which the tool's name, now sent in
/// production too, must not replace; a client tool ours, never its raw name ("inbox_read").
@Suite("Tool status label")
@MainActor
struct ToolStatusLabelTests {

    private static let primer = ":" + String(repeating: " ", count: 600) + "\n\n"

    private static let idle = "Thinking..."

    private func status(label: String?, name: String?) -> ToolStatusEvent {
        ToolStatusEvent(execution_id: "execution-1", call_id: "call-1", display_label: label, tool_name: name,
                        success: nil, elapsed_ms: nil, error: nil, result: nil)
    }

    /// What the chat shows for a tool that starts running.
    private func shown(label: String?, name: String?) -> String? {
        DynamicIslandChat.statusLabel(for: .toolStarted(status(label: label, name: name)), idleLabel: Self.idle)
    }

    @Test("the backend's label wins over the tool's name")
    func backendLabelWins() {
        #expect(shown(label: "Searching the web: launch plan", name: "search_web") == "Searching the web: launch plan")
        #expect(shown(label: "Checking day of week…", name: "date_to_day") == "Checking day of week…")
    }

    @Test("without a label, the tool's name, and without either, a generic label")
    func fallbacks() {
        #expect(shown(label: nil, name: "search_web") == "search_web")
        #expect(shown(label: nil, name: nil) == "Processing")
    }

    @Test("a finished tool shows the idle label, and other events leave the status alone")
    func otherEvents() {
        let finished = status(label: "Searching the web: launch plan", name: "search_web")
        #expect(DynamicIslandChat.statusLabel(for: .toolCompleted(finished), idleLabel: Self.idle) == Self.idle)
        #expect(DynamicIslandChat.statusLabel(for: .toolFailed(finished), idleLabel: Self.idle) == nil)
        #expect(DynamicIslandChat.statusLabel(for: .keepalive, idleLabel: Self.idle) == nil)
    }

    @Test("every client tool has a readable label, and nothing else does")
    func everyClientToolLabelled() {
        let names = Set(ToolRegistry.makeDefaultTools().map(\.name))
        #expect(Set(ToolRegistry.activityLabels.keys) == names)
        let raw = names.filter { ToolRegistry.activityLabel(for: $0) == $0 }.sorted()
        #expect(raw.isEmpty, "client tools shown by their raw name: \(raw)")
        #expect(ToolRegistry.activityLabel(for: "not_a_tool") == "not_a_tool")
    }

    @Test("a client tool the agent runs shows its label in the chat, not its name")
    func clientToolRoundShowsLabel() async throws {
        let http = FakeHTTP.Scenario()
        let calls = Mutex(0)
        let toolRound = Self.primer + "event: final\ndata: "
            + #"{"tool_calls":[{"id":"call-1","function":{"name":"inbox_read","arguments":"{}"}}],"conversation_state":{"harmony_messages":[],"current_round":1}}"#
            + "\n\n"
        let answer = Self.primer + "event: final\ndata: {\"assistant\":\"done\"}\n\n"
        http.register(path: "/completions/chat", method: "POST") { _ in
            let call = calls.withLock { $0 += 1; return $0 }
            return .bytes(Data((call == 1 ? toolRound : answer).utf8), contentType: "text/event-stream", statusCode: 200)
        }
        let client = BackendClient(llmSession: http.session)
        let events = Mutex<[CompletionsSSEEvent]>([])
        let request = CompletionsRequest(messages: [], client_timezone: "UTC", disable_tools: nil)

        let response = try await client.sendCompletionsWithToolsDirect(request, onSSEEvent: { event in
            events.withLock { $0.append(event) }
        })

        #expect(response.assistant == "done")
        let statuses = events.withLock { $0 }.compactMap { event -> ToolStatusEvent? in
            switch event {
            case .toolStarted(let status), .toolCompleted(let status): status
            default: nil
            }
        }
        #expect(statuses.count == 2)
        guard statuses.count == 2 else { return }
        for status in statuses {
            #expect(status.tool_name == "inbox_read")
            #expect(status.display_label == "Reading inbox")
        }
        let shown = events.withLock { $0 }.compactMap { DynamicIslandChat.statusLabel(for: $0, idleLabel: Self.idle) }
        #expect(shown == ["Reading inbox", Self.idle])
    }
}
