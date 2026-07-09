/* This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at https://mozilla.org/MPL/2.0/. */

import Foundation

enum BackendNSEClient {

    struct CompletionsResponse: Sendable {
        let assistant: String
    }

    /// Wrapper around `[String: Any]` so it can cross concurrent task boundaries.
    /// Safe because callers only ever put JSON-primitive values (String, Bool,
    /// Int, Double) into `raw`, and the dictionary is read-only after construction.
    struct Vars: @unchecked Sendable {
        let raw: [String: Any]
        init(_ raw: [String: Any]) { self.raw = raw }
    }

    /// Single completions call (summary or chat)
    static func sendCompletions(
        promptAlias: String,
        variables: Vars,
        authToken: String?,
        timeout: TimeInterval = NSEConfig.summaryTimeoutSeconds
    ) async -> CompletionsResponse? {
        guard let authToken else { return nil }
        let baseURL = NSEState.getBackendBaseURL()
        guard let url = URL(string: "\(baseURL)/completions/chat") else { return nil }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("Bearer \(authToken)", forHTTPHeaderField: "Authorization")
        request.setValue("ios", forHTTPHeaderField: "X-Client-Type")
        request.timeoutInterval = timeout

        var systemMsg: [String: Any] = ["role": "system", "content": promptAlias]
        for (k, v) in variables.raw { systemMsg[k] = v }
        let messages: [[String: Any]] = [systemMsg]

        let body: [String: Any] = [
            "messages": messages,
            "client_timestamp_ms": Date().timeIntervalSince1970 * 1000,
            "client_timezone": TimeZone.current.identifier,
        ]

        request.httpBody = try? JSONSerialization.data(withJSONObject: body)

        guard let data = await performRequestWithDeadline(request, timeout: timeout) else { return nil }

        // Parse response — may be SSE or plain JSON
        guard let text = String(data: data, encoding: .utf8) else { return nil }

        if text.contains("event: final") {
            // SSE format — extract final event data
            if let finalData = extractSSEFinalData(text),
               let json = try? JSONSerialization.jsonObject(with: Data(finalData.utf8)) as? [String: Any],
               let assistant = json["assistant"] as? String {
                return CompletionsResponse(assistant: assistant)
            }
        } else {
            // Plain JSON
            if let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
               let assistant = json["assistant"] as? String {
                return CompletionsResponse(assistant: assistant)
            }
        }

        return nil
    }

    /// Action classification with N-vote (parallel calls, take mode)
    static func sendActionVote(
        promptAlias: String,
        variables: Vars,
        authToken: String?,
        voteCount: Int = NSEConfig.actionVoteCount,
        timeout: TimeInterval = NSEConfig.actionTimeoutSeconds
    ) async -> String? {
        guard let authToken else { return nil }

        // Launch N parallel calls
        let results = await withTaskGroup(of: String?.self, returning: [String].self) { group in
            for _ in 0..<voteCount {
                group.addTask {
                    let resp = await sendCompletions(
                        promptAlias: promptAlias,
                        variables: variables,
                        authToken: authToken,
                        timeout: timeout
                    )
                    guard let text = resp?.assistant else { return nil }
                    return parseActionTag(from: text)
                }
            }
            var votes: [String] = []
            for await result in group {
                if let r = result { votes.append(r) }
            }
            return votes
        }

        guard !results.isEmpty else { return nil }

        // Take mode (most common)
        let counts = Dictionary(grouping: results, by: { $0 }).mapValues { $0.count }
        return counts.max(by: { $0.value < $1.value })?.key
    }

    // MARK: - Wall-clock-bounded request

    /// Outcome of racing the network call against the wall-clock deadline.
    /// A plain `Data?` can't distinguish "server responded non-200 / request
    /// threw" from "deadline won the race" — this enum keeps that distinction
    /// so the deadline branch can log without the HTTP-failure branch also
    /// tripping it (and to satisfy Swift 6 strict concurrency: only Sendable
    /// values may cross the `withTaskGroup` boundary).
    private enum CallOutcome: Sendable {
        case success(Data)
        case httpFailure
        case deadline
    }

    /// Enforces `timeout` as a TRUE wall-clock cap, not the idle timer
    /// `URLRequest.timeoutInterval` provides. `timeoutInterval` resets on
    /// every received byte, and `/completions/chat` streams SSE frames — a
    /// trickling response can hold the connection open indefinitely.
    /// Production evidence (field nse.log, 2026-07-09): a summary call ran
    /// 26.4s under the nominal 12s idle timeout, missing the 27s graceful-exit
    /// watchdog by 9ms; action calls were observed at 16.8s/17.4s/19s+.
    ///
    /// Races `URLSession.shared.data(for:)` against `Task.sleep` for
    /// `timeout` seconds; first finisher wins, then `group.cancelAll()` —
    /// `data(for:)` is cancellation-aware and aborts the in-flight HTTP
    /// request, so the loser doesn't linger. `request.timeoutInterval` is
    /// left set by the caller as the connection-level layer underneath this.
    private static func performRequestWithDeadline(_ request: URLRequest, timeout: TimeInterval) async -> Data? {
        let outcome = await withTaskGroup(of: CallOutcome.self) { group -> CallOutcome in
            group.addTask {
                guard let (data, response) = try? await URLSession.shared.data(for: request),
                      let httpResponse = response as? HTTPURLResponse,
                      httpResponse.statusCode == 200 else { return .httpFailure }
                return .success(data)
            }
            group.addTask {
                try? await Task.sleep(for: .seconds(timeout))
                return .deadline
            }
            let first = await group.next() ?? .httpFailure
            group.cancelAll()
            return first
        }

        switch outcome {
        case .success(let data):
            return data
        case .httpFailure:
            return nil
        case .deadline:
            NSELog.step("NSE LLM call DEADLINE (\(Int(timeout))s wall-clock) — abandoning")
            return nil
        }
    }

    // MARK: - Parsing

    /// Delegates to shared AIResponseParser — single source of truth.
    private static func parseActionTag(from text: String) -> String? {
        AIResponseParser.parseActionTag(from: text)
    }

    private static func extractSSEFinalData(_ text: String) -> String? {
        let lines = text.components(separatedBy: "\n")
        var foundFinal = false
        for line in lines {
            if line.hasPrefix("event: final") {
                foundFinal = true
                continue
            }
            if foundFinal && line.hasPrefix("data: ") {
                return String(line.dropFirst(6))
            }
        }
        return nil
    }
}
