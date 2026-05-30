/* This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at https://mozilla.org/MPL/2.0/. */

import Testing
import Foundation
@testable import TabMail

/// Tests for the architectural contract of `EmailProvider.fetchMessagesBatch` default
/// implementation (used by Gmail and Exchange; IMAP overrides).
///
/// Contract: an ID missing from the returned dictionary means the server has
/// CONFIRMED the message is permanently gone (404/410/messageNotFound). Any
/// other error — 401, 429, 500, timeout, parse — re-throws so the caller
/// retries the entire batch. Without this contract, downstream code cannot
/// safely treat "absent from result" as a gone signal; a rate-limit episode
/// would otherwise look identical to a mass deletion.
@Suite("EmailProvider.fetchMessagesBatch — gone-vs-transient contract")
struct FetchMessagesBatchContractTests {

    /// Minimal actor mock that exposes per-ID fetch behavior so we can drive the
    /// default `fetchMessagesBatch` path through a variety of error shapes. Unlike
    /// `MockEmailProvider` which has a single `fetchMessageThrows`, this mock lets
    /// each ID produce a different outcome.
    actor PerIDFetchMock: EmailProvider {
        var perIDResult: [String: Result<FullMessageInfo, Error>] = [:]

        func setResult(id: String, _ result: Result<FullMessageInfo, Error>) {
            perIDResult[id] = result
        }

        // MARK: EmailProvider stubs (only fetchMessage is exercised)
        func connect() async throws {}
        func disconnect() async throws {}
        func fetchFolders() async throws -> [FolderInfo] { [] }
        func fetchMessages(folder: String, limit: Int, offset: Int) async throws -> [MessageHeaderInfo] { [] }

        func fetchMessage(id: String, folder: String) async throws -> FullMessageInfo {
            if let result = perIDResult[id] {
                return try result.get()
            }
            throw ProviderError.messageNotFound
        }

        func search(query: String, folder: String, after: Date?, before: Date?, from: String?, to: String?) async throws -> [MessageHeaderInfo] { [] }
        func markRead(ids: [String], folder: String) async throws {}
        func markUnread(ids: [String], folder: String) async throws {}
        func markFlagged(ids: [String], flagged: Bool, folder: String) async throws {}
        func move(ids: [String], from: String, to: String) async throws {}
        func send(draft: DraftMessage) async throws {}
        func appendToSentFolder(draft: DraftMessage, sentFolderPath: String, messageId: String) async throws -> Bool { true }
        func fetchHistory(since historyId: String) async throws -> HistoryResponse? { nil }
        func fetchMessageHeaders(ids: [String]) async throws -> [MessageHeaderInfo] { [] }
        func fetchTextBodies(ids: [String], folder: String) async throws -> [TextBodyFetchResult] { [] }

        func saveDraft(_ draft: DraftMessage, existingDraftId: String?, draftsFolderPath: String) async throws -> DraftSaveResult {
            DraftSaveResult(serverId: "mock")
        }
        func deleteDraft(draftId: String, draftsFolderPath: String) async throws {}
    }

    private func makeFullMessage(id: String) -> FullMessageInfo {
        let header = MessageHeaderInfo(
            messageId: id,
            rfc822MessageId: nil,
            inReplyTo: nil,
            references: [],
            threadId: nil,
            subject: "s",
            from: "a@example.com",
            fromAddress: "a@example.com",
            to: "b@example.com",
            cc: "",
            bcc: "",
            replyTo: nil,
            date: Date(),
            snippet: "",
            isRead: false,
            isFlagged: false,
            hasAttachments: false,
            isReplied: false,
            isForwarded: false,
            actionTag: nil
        )
        return FullMessageInfo(header: header, htmlBody: "<p>body</p>", textBody: nil)
    }

    // MARK: - Gone signals (omit from result)

    @Test("ProviderError.messageNotFound — RE-THROWS (not omitted), because providers overload it for parse failures")
    func messageNotFoundRethrows() async throws {
        // Subtle but critical contract: in this codebase Gmail/Exchange providers
        // throw `ProviderError.messageNotFound` on PARSE FAILURES (malformed JSON,
        // unreadable base64), NOT on 404s — which come through the HTTPError path.
        // If the default `fetchMessagesBatch` swallowed `.messageNotFound` like it
        // does 404s, a parse-failure episode would look identical to the message
        // being gone, and the backfill miss counter would delete the header after
        // 5 failures. We deliberately re-throw here so a parse blip retries
        // instead of silently data-lossing.
        let mock = PerIDFetchMock()
        await mock.setResult(id: "ok", .success(makeFullMessage(id: "ok")))
        await mock.setResult(id: "parse-fail", .failure(ProviderError.messageNotFound))

        await #expect(throws: Error.self) {
            _ = try await mock.fetchMessagesBatch(ids: ["ok", "parse-fail"], folder: "INBOX")
        }
    }

    @Test("HTTPError(404) wrapped in ProviderError.networkError — omitted from result")
    func http404Omitted() async throws {
        let mock = PerIDFetchMock()
        await mock.setResult(id: "ok", .success(makeFullMessage(id: "ok")))
        await mock.setResult(id: "gone", .failure(ProviderError.networkError(underlying: HTTPError.networkError(statusCode: 404))))

        let result = try await mock.fetchMessagesBatch(ids: ["ok", "gone"], folder: "INBOX")
        #expect(result.keys.sorted() == ["ok"])
    }

    @Test("HTTPError(410 Gone) — omitted from result")
    func http410Omitted() async throws {
        let mock = PerIDFetchMock()
        await mock.setResult(id: "ok", .success(makeFullMessage(id: "ok")))
        await mock.setResult(id: "gone", .failure(ProviderError.networkError(underlying: HTTPError.networkError(statusCode: 410))))

        let result = try await mock.fetchMessagesBatch(ids: ["ok", "gone"], folder: "INBOX")
        #expect(result.keys.sorted() == ["ok"])
    }

    // MARK: - Transient errors (entire batch throws)

    @Test("HTTPError(500) — transient, re-throws entire batch (the architectural fix)")
    func http500Throws() async {
        let mock = PerIDFetchMock()
        await mock.setResult(id: "ok", .success(makeFullMessage(id: "ok")))
        await mock.setResult(id: "bad", .failure(ProviderError.networkError(underlying: HTTPError.networkError(statusCode: 500))))

        await #expect(throws: Error.self) {
            _ = try await mock.fetchMessagesBatch(ids: ["ok", "bad"], folder: "INBOX")
        }
    }

    @Test("HTTPError(429 rate limit) — transient, re-throws entire batch")
    func http429Throws() async {
        let mock = PerIDFetchMock()
        await mock.setResult(id: "ok", .success(makeFullMessage(id: "ok")))
        await mock.setResult(id: "throttled", .failure(ProviderError.networkError(underlying: HTTPError.networkError(statusCode: 429))))

        await #expect(throws: Error.self) {
            _ = try await mock.fetchMessagesBatch(ids: ["ok", "throttled"], folder: "INBOX")
        }
    }

    @Test("HTTPError(401 auth refresh in flight) — transient, re-throws")
    func http401Throws() async {
        let mock = PerIDFetchMock()
        await mock.setResult(id: "ok", .success(makeFullMessage(id: "ok")))
        await mock.setResult(id: "auth", .failure(ProviderError.networkError(underlying: HTTPError.networkError(statusCode: 401))))

        await #expect(throws: Error.self) {
            _ = try await mock.fetchMessagesBatch(ids: ["ok", "auth"], folder: "INBOX")
        }
    }

    @Test("ProviderError.notConnected — transient, re-throws")
    func notConnectedThrows() async {
        let mock = PerIDFetchMock()
        await mock.setResult(id: "ok", .success(makeFullMessage(id: "ok")))
        await mock.setResult(id: "offline", .failure(ProviderError.notConnected))

        await #expect(throws: Error.self) {
            _ = try await mock.fetchMessagesBatch(ids: ["ok", "offline"], folder: "INBOX")
        }
    }

    @Test("URLError(.timedOut) — transient, re-throws")
    func timedOutThrows() async {
        let mock = PerIDFetchMock()
        await mock.setResult(id: "ok", .success(makeFullMessage(id: "ok")))
        await mock.setResult(id: "slow", .failure(URLError(.timedOut)))

        await #expect(throws: Error.self) {
            _ = try await mock.fetchMessagesBatch(ids: ["ok", "slow"], folder: "INBOX")
        }
    }

    // MARK: - All-success paths

    @Test("All IDs succeed — all returned in result")
    func allSucceed() async throws {
        let mock = PerIDFetchMock()
        await mock.setResult(id: "a", .success(makeFullMessage(id: "a")))
        await mock.setResult(id: "b", .success(makeFullMessage(id: "b")))

        let result = try await mock.fetchMessagesBatch(ids: ["a", "b"], folder: "INBOX")
        #expect(result.keys.sorted() == ["a", "b"])
    }

    @Test("Empty input — returns empty dictionary, does not throw")
    func emptyInput() async throws {
        let mock = PerIDFetchMock()
        let result = try await mock.fetchMessagesBatch(ids: [], folder: "INBOX")
        #expect(result.isEmpty)
    }

    @Test("Mix of success + HTTP 404 + unrelated success — 404 omitted, successes returned")
    func mixedSuccessAnd404() async throws {
        // HTTPError(404) is the true "server confirmed gone" signal (not
        // `.messageNotFound`, which this codebase overloads for parse failures).
        let mock = PerIDFetchMock()
        await mock.setResult(id: "a", .success(makeFullMessage(id: "a")))
        await mock.setResult(id: "gone", .failure(ProviderError.networkError(underlying: HTTPError.networkError(statusCode: 404))))
        await mock.setResult(id: "c", .success(makeFullMessage(id: "c")))

        let result = try await mock.fetchMessagesBatch(ids: ["a", "gone", "c"], folder: "INBOX")
        #expect(result.keys.sorted() == ["a", "c"])
    }

    @Test("Transient error is NOT caught by the 404 swallow path — re-thrown even alongside successes")
    func transientStillThrowsAmidstSuccesses() async {
        // This is the regression guard: the OLD default impl swallowed every error,
        // causing a rate-limit mid-batch to look identical to a 404 mass-deletion.
        // The fix re-throws non-404s even when preceded by successes.
        let mock = PerIDFetchMock()
        await mock.setResult(id: "a", .success(makeFullMessage(id: "a")))
        await mock.setResult(id: "b", .failure(ProviderError.networkError(underlying: HTTPError.networkError(statusCode: 500))))
        await mock.setResult(id: "c", .success(makeFullMessage(id: "c")))

        await #expect(throws: Error.self) {
            _ = try await mock.fetchMessagesBatch(ids: ["a", "b", "c"], folder: "INBOX")
        }
    }
}
