/* This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at https://mozilla.org/MPL/2.0/. */

import Testing
import Foundation
import Synchronization
@testable import TabMail

/// `LoggableURL`: the short, fixed form a URL takes in a log line. Every fixture
/// puts the marker `Qz7k` in each part a log line must leave out (user info,
/// query, fragment, and for `origin` the path), so an exact match
/// shows both what is kept and that nothing else got through.
@Suite("LoggableURL log forms")
struct LoggableURLTests {

    @Test("address: scheme, host, port and path; a query and a fragment are only marked", arguments: [
        ("https://userQz7k:pwQz7k@api.example.com:8443/v1/items?id=Qz7k#Qz7k", "https://api.example.com:8443/v1/items?…#…"),
        ("HTTPS://cal.example.com/dav/calendars/", "https://cal.example.com/dav/calendars/"),
        ("https://example.com", "https://example.com"),
        ("tabmail://auth?code=Qz7k&state=Qz7k", "tabmail://auth?…"),
        ("", "(not a URL, 0 bytes)"),
        ("http://[bad/Qz7k", "(not a URL, 16 bytes)"),
    ])
    func addressForm(input: String, expected: String) {
        #expect(LoggableURL.address(input) == expected)
        if let url = URL(string: input) {
            #expect(LoggableURL.address(url) == expected)
        }
    }

    @Test("origin: scheme, host and port; a path, a query and a fragment are only marked", arguments: [
        ("https://userQz7k:pwQz7k@example.com:8443/reset/Qz7k?id=Qz7k#Qz7k", "https://example.com:8443/…?…#…"),
        ("HTTPS://Example.COM/reset/Qz7k", "https://Example.COM/…"),
        ("https://example.com/", "https://example.com"),
        ("https://example.com", "https://example.com"),
        ("https://example.com?code=Qz7k", "https://example.com?…"),
        ("mailto:someoneQz7k@example.com?subject=Qz7k", "mailto:…?…"),
        ("http://[bad/Qz7k", "(not a URL, 16 bytes)"),
    ])
    func originForm(input: String, expected: String) {
        #expect(LoggableURL.origin(input) == expected)
        if let url = URL(string: input) {
            #expect(LoggableURL.origin(url) == expected)
        }
    }

    @Test("No URL renders as (none)")
    func noURL() {
        #expect(LoggableURL.address(nil as URL?) == "(none)")
        #expect(LoggableURL.origin(nil as URL?) == "(none)")
    }
}

/// What the debug log holds after a request to a URL. Every case points the app
/// log at a temp file and turns debug logging on: process-global seams, hence
/// `.serialized, .processGlobalState` (see `BackgroundSyncLoggerTests`).
@Suite("Debug log lines that name a URL", .serialized, .processGlobalState)
struct URLDebugLogTests {

    /// Port 1 on the loopback address refuses at once, so the fetch takes its
    /// failure path without leaving the machine.
    private static let link = "http://127.0.0.1:1/reset/Qz7k?id=Qz7k#Qz7k"
    private static let marker = "Qz7k"

    private func withDebugLog<T>(_ body: () async throws -> T) async rethrows -> T {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("linklog_\(UUID().uuidString).log")
        AppLogStore.fileURLOverride.withLock { $0 = url }
        DebugModeManager.loggingEnabledOverrideForTesting.withLock { $0 = true }
        defer {
            DebugModeManager.loggingEnabledOverrideForTesting.withLock { $0 = nil }
            AppLogStore._resetForTesting()
            try? FileManager.default.removeItem(at: url)
        }
        return try await body()
    }

    @Test("A failed fetch logs the link's origin and the error's domain and code, nothing more")
    func failedFetchLogsOriginOnly() async throws {
        let log = try await withDebugLog {
            let result = try await WebReadTool().execute(arguments: ["url": .string(Self.link)])
            #expect(result.contains("Failed to fetch URL"))
            return AppLogStore.read()
        }
        #expect(log.contains("[WebReadTool] Starting fetch for http://127.0.0.1:1/…?…#…"))
        #expect(log.contains("[WebReadTool] Fetch failed: NSURLErrorDomain code="))
        #expect(!log.contains(Self.marker))
    }

    @Test("A tool call logs the size of its arguments, not their text")
    func toolCallLogsArgumentSize() async throws {
        let arguments = #"{"url":"\#(Self.link)"}"#
        let toolCall: [String: Any] = ["id": "tc1", "function": ["name": "web_read", "arguments": arguments]]
        let state: [String: Any] = ["harmony_messages": [Any](), "current_round": 1]
        let firstAnswer: [String: Any] = ["assistant": "", "tool_calls": [toolCall], "conversation_state": state]
        let answers = [
            String(decoding: try JSONSerialization.data(withJSONObject: firstAnswer), as: UTF8.self),
            #"{"assistant":"done"}"#,
        ]
        let served = ServedCount()
        let http = FakeHTTP.Scenario()
        defer { http.close() }
        http.register(path: "/completions/chat", method: "POST") { _ in
            let index = served.next()
            // The SSE primer (a >=512-byte comment) the backend sends first.
            let body = ":" + String(repeating: " ", count: 600) + "\n\n"
                + "event: final\ndata: \(answers[min(index, answers.count - 1)])\n\n"
            return .bytes(Data(body.utf8), contentType: "text/event-stream", statusCode: 200)
        }
        let client = BackendClient(llmSession: http.session, isAIOff: { false })
        let request = CompletionsRequest(messages: [], client_timezone: "UTC", disable_tools: nil)

        let (response, log) = try await withDebugLog {
            let response = try await client.sendCompletionsWithToolsDirect(request)
            return (response, AppLogStore.read())
        }
        #expect(response.assistant == "done")
        #expect(served.count == 2)
        #expect(log.contains("[AIChatDebug] Executing client-side tool: web_read"))
        #expect(log.contains("[AIChatDebug]   args: \(arguments.utf8.count) bytes"))
        #expect(!log.contains(Self.marker))
    }

    private static let calendarHome = "https://cal.example.com/dav/calendars/home/?id=Qz7k#Qz7k"

    @Test("A calendar server's 401 logs the server address without its query or fragment")
    func calendarUnauthorizedLogsAddress() async throws {
        let http = FakeHTTP.Scenario()
        defer { http.close() }
        http.register(path: "/dav/calendars/home/", method: "GET", response: .status(401))
        let client = CalDAVClient(username: "user@example.com", password: "pw", session: http.session)
        let url = try #require(URL(string: Self.calendarHome))

        let log = await withDebugLog {
            await #expect(throws: CalDAVError.self) { _ = try await client.get(url: url) }
            return AppLogStore.read()
        }
        #expect(log.contains("[CalDAV] 401 Unauthorized for https://cal.example.com/dav/calendars/home/?…#…"))
        #expect(!log.contains(Self.marker))
    }

    @Test("A calendar server's error status logs the server address without its query or fragment")
    func calendarErrorStatusLogsAddress() async throws {
        let http = FakeHTTP.Scenario()
        defer { http.close() }
        http.register(path: "/dav/calendars/home/", method: "GET", response: .json(raw: "fixture failure", statusCode: 500))
        let client = CalDAVClient(username: "user@example.com", password: "pw", session: http.session)
        let url = try #require(URL(string: Self.calendarHome))

        let log = await withDebugLog {
            await #expect(throws: CalDAVError.self) { _ = try await client.get(url: url) }
            return AppLogStore.read()
        }
        #expect(log.contains("[CalDAV] HTTP 500 GET https://cal.example.com/dav/calendars/home/?…#…: fixture failure"))
        #expect(!log.contains(Self.marker))
    }
}

/// How many responses the fake backend has served.
private final class ServedCount: Sendable {
    private let served = Mutex(0)

    /// The index of this response, counting from 0.
    func next() -> Int {
        served.withLock { count in
            defer { count += 1 }
            return count
        }
    }

    var count: Int { served.withLock { $0 } }
}
