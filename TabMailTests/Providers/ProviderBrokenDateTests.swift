/* This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at https://mozilla.org/MPL/2.0/. */

import Testing
import Foundation
@testable import TabMail

/// Tests for provider-level "broken date = fetch failure" contract.
/// When a provider can't parse a message's date, the whole record is treated as
/// untrusted and parse functions return nil. Callers use compactMap to skip these.
/// This prevents transient 1970 dates from briefly leaking into the UI during
/// send→sync races (where a just-APPENDed message hasn't been indexed yet).

// MARK: - Gmail: parseGmailMessage

@Suite("GmailProvider parseGmailMessage broken date")
struct GmailProviderBrokenDateTests {

    /// Create a provider with dummy credentials — we never hit the network.
    private func makeProvider() -> GmailProvider {
        GmailProvider(
            userEmail: "test@example.com",
            accessToken: { _ in "dummy-token" }
        )
    }

    /// Decode a GmailMessage from a JSON string. Simulates what the REST layer does.
    private func decodeGmailMessage(_ json: String) throws -> GmailMessage {
        try JSONDecoder().decode(GmailMessage.self, from: Data(json.utf8))
    }

    @Test("Valid internalDate produces non-nil MessageHeaderInfo")
    func validInternalDate() async throws {
        let json = """
        {
            "id": "msg-1",
            "threadId": "thr-1",
            "labelIds": ["INBOX"],
            "snippet": "hello",
            "internalDate": "1700000000000",
            "payload": {
                "headers": [
                    {"name": "Subject", "value": "Test"},
                    {"name": "From", "value": "alice@example.com"},
                    {"name": "To", "value": "bob@example.com"}
                ]
            }
        }
        """
        let msg = try decodeGmailMessage(json)
        let provider = makeProvider()
        let result = await provider.parseGmailMessage(msg)
        #expect(result != nil)
        #expect(result?.messageId == "msg-1")
        #expect(result?.date.timeIntervalSince1970 == 1700000000)
    }

    @Test("Missing internalDate returns nil (fetch failure)")
    func missingInternalDate() async throws {
        let json = """
        {
            "id": "msg-1",
            "threadId": "thr-1",
            "labelIds": ["INBOX"],
            "snippet": "hello",
            "payload": {
                "headers": [
                    {"name": "Subject", "value": "Test"},
                    {"name": "From", "value": "alice@example.com"},
                    {"name": "To", "value": "bob@example.com"}
                ]
            }
        }
        """
        let msg = try decodeGmailMessage(json)
        let provider = makeProvider()
        let result = await provider.parseGmailMessage(msg)
        #expect(result == nil)
    }

    @Test("internalDate == \"0\" returns nil (treated as invalid)")
    func zeroInternalDate() async throws {
        let json = """
        {
            "id": "msg-1",
            "internalDate": "0",
            "payload": {
                "headers": [{"name": "Subject", "value": "Test"}]
            }
        }
        """
        let msg = try decodeGmailMessage(json)
        let provider = makeProvider()
        let result = await provider.parseGmailMessage(msg)
        #expect(result == nil)
    }

    @Test("Unparseable internalDate returns nil")
    func unparseableInternalDate() async throws {
        let json = """
        {
            "id": "msg-1",
            "internalDate": "not-a-number",
            "payload": {
                "headers": [{"name": "Subject", "value": "Test"}]
            }
        }
        """
        let msg = try decodeGmailMessage(json)
        let provider = makeProvider()
        let result = await provider.parseGmailMessage(msg)
        #expect(result == nil)
    }

    @Test("Empty string internalDate returns nil")
    func emptyInternalDate() async throws {
        let json = """
        {
            "id": "msg-1",
            "internalDate": "",
            "payload": {
                "headers": [{"name": "Subject", "value": "Test"}]
            }
        }
        """
        let msg = try decodeGmailMessage(json)
        let provider = makeProvider()
        let result = await provider.parseGmailMessage(msg)
        #expect(result == nil)
    }
}

// MARK: - Exchange: parseGraphMessage

@Suite("ExchangeProvider parseGraphMessage broken date")
struct ExchangeProviderBrokenDateTests {

    private func makeProvider() -> ExchangeProvider {
        ExchangeProvider(
            userEmail: "test@example.com",
            accessToken: { _ in "dummy-token" }
        )
    }

    private func decodeGraphMessage(_ json: String) throws -> GraphMessage {
        try JSONDecoder().decode(GraphMessage.self, from: Data(json.utf8))
    }

    @Test("Valid receivedDateTime produces non-nil MessageHeaderInfo")
    func validReceivedDateTime() async throws {
        let json = """
        {
            "id": "msg-1",
            "subject": "Test",
            "receivedDateTime": "2023-11-14T12:00:00Z",
            "isRead": false,
            "hasAttachments": false,
            "internetMessageId": "<abc@example.com>"
        }
        """
        let msg = try decodeGraphMessage(json)
        let provider = makeProvider()
        let result = await provider.parseGraphMessage(msg)
        #expect(result != nil)
        #expect(result?.messageId == "msg-1")
    }

    @Test("Missing receivedDateTime returns nil (fetch failure)")
    func missingReceivedDateTime() async throws {
        let json = """
        {
            "id": "msg-1",
            "subject": "Test",
            "isRead": false,
            "hasAttachments": false
        }
        """
        let msg = try decodeGraphMessage(json)
        let provider = makeProvider()
        let result = await provider.parseGraphMessage(msg)
        #expect(result == nil)
    }

    @Test("Empty string receivedDateTime returns nil")
    func emptyReceivedDateTime() async throws {
        let json = """
        {
            "id": "msg-1",
            "receivedDateTime": "",
            "isRead": false
        }
        """
        let msg = try decodeGraphMessage(json)
        let provider = makeProvider()
        let result = await provider.parseGraphMessage(msg)
        #expect(result == nil)
    }

    @Test("Unparseable receivedDateTime returns nil")
    func unparseableReceivedDateTime() async throws {
        let json = """
        {
            "id": "msg-1",
            "receivedDateTime": "not-a-date",
            "isRead": false
        }
        """
        let msg = try decodeGraphMessage(json)
        let provider = makeProvider()
        let result = await provider.parseGraphMessage(msg)
        #expect(result == nil)
    }
}
