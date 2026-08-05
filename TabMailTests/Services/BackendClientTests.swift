/* This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at https://mozilla.org/MPL/2.0/. */

import Testing
import Foundation
@testable import TabMail

// NOTE — there is deliberately NO test here for the 403 backoff constants.
// `BackendClient.forbiddenInitialDelay` / `forbiddenMaxDelay` are
// `private static let`, and `@testable import` raises `internal` to public,
// not `private`. Two tests named after those values used to live here and
// asserted `#expect(true)`; a green test named "Max backoff delay is 300
// seconds" reads as coverage to the next reader and to the next audit while
// measuring nothing, so they were deleted rather than repaired. Do NOT loosen
// the production access level to make them assertable — the constants are
// exercised through the backoff BEHAVIOUR (`recordForbidden` /
// `checkForbiddenBackoff`), which is where a real test belongs.
@Suite("BackendClient Construction")
struct BackendClientConstructionTests {

    @Test("BackendClient() constructs without trapping")
    func defaultInit() {
        // THE ASSERTION IS THE CONSTRUCTION ITSELF. `init` builds the ephemeral
        // LLM URLSession and the actor's stored state; reaching the line after
        // it is the property under test, and `#expect(Bool(true))` is the
        // compiler's own remedy for an assertion whose subject is "we got here"
        // (a bare `#expect(true)` is diagnosed as always-passing).
        //
        // Deliberately NOT asserting on `BackendConfig.apiBaseURL`: it branches
        // on `UserDefaults.standard` (`debug_mode_unlocked` +
        // `debug_use_dev_servers`), a process-global any sibling suite can have
        // flipped, so a value assertion would be environment-dependent and would
        // print the configured endpoint into the failure message.
        _ = BackendClient()
        #expect(Bool(true))
    }
}

@Suite("BackendClient Request Types")
struct BackendClientRequestTypeTests {

    @Test("ChatRequest encodes correctly")
    func chatRequestEncodes() throws {
        let request = BackendClient.ChatRequest(
            message: "Hello",
            context: BackendClient.MessageContext(
                messageId: "123",
                subject: "Test",
                from: "alice@test.com",
                snippet: "Preview text"
            ),
            conversationId: "conv-1"
        )
        let data = try JSONEncoder().encode(request)
        let json = try JSONSerialization.jsonObject(with: data) as! [String: Any]
        #expect(json["message"] as? String == "Hello")
        #expect(json["conversationId"] as? String == "conv-1")
        let ctx = json["context"] as? [String: Any]
        #expect(ctx?["messageId"] as? String == "123")
    }

    @Test("ChatRequest without context")
    func chatRequestNoContext() throws {
        let request = BackendClient.ChatRequest(
            message: "Hi",
            context: nil,
            conversationId: nil
        )
        let data = try JSONEncoder().encode(request)
        let json = try JSONSerialization.jsonObject(with: data) as! [String: Any]
        #expect(json["message"] as? String == "Hi")
    }

    @Test("ChatResponse decodes correctly")
    func chatResponseDecodes() throws {
        let json = """
        {"reply": "Hello!", "conversationId": "conv-1"}
        """
        let response = try JSONDecoder().decode(BackendClient.ChatResponse.self, from: Data(json.utf8))
        #expect(response.reply == "Hello!")
        #expect(response.conversationId == "conv-1")
        #expect(response.toolCalls == nil)
    }

    @Test("ChatResponse with tool calls")
    func chatResponseWithToolCalls() throws {
        let json = """
        {
            "reply": "Let me check",
            "conversationId": "c1",
            "toolCalls": [{"name": "search", "arguments": {"query": "budget"}}]
        }
        """
        let response = try JSONDecoder().decode(BackendClient.ChatResponse.self, from: Data(json.utf8))
        #expect(response.toolCalls?.count == 1)
        #expect(response.toolCalls?.first?.name == "search")
        #expect(response.toolCalls?.first?.arguments["query"] == "budget")
    }

    @Test("ToolCall decodes")
    func toolCallDecodes() throws {
        let json = """
        {"name": "archive_email", "arguments": {"id": "123"}}
        """
        let tc = try JSONDecoder().decode(BackendClient.ToolCall.self, from: Data(json.utf8))
        #expect(tc.name == "archive_email")
        #expect(tc.arguments["id"] == "123")
    }
}

@Suite("BackendClient clientVersion")
struct BackendClientVersionTests {

    @Test("clientVersion is non-empty string")
    func clientVersionNonEmpty() {
        let version = BackendClient.clientVersion
        #expect(!version.isEmpty)
    }
}
