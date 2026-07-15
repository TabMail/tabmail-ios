/* This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at https://mozilla.org/MPL/2.0/. */

import Testing
import Foundation
@testable import TabMail

/// Round E / Law 4: a `saveDraft` UPDATE whose recorded `existingDraftId` is
/// authoritatively confirmed gone (404/410 — deleted directly, or
/// auto-deleted after the underlying message sent) must never drop the
/// user's edit. The provider falls back to CREATE within the same call
/// instead of throwing, so the queue never wedges retrying an update that
/// can never succeed.
@Suite("Draft update → create resurrection (Gmail/Exchange)")
struct DraftResurrectionTests {
    private func makeDraft() -> DraftMessage {
        DraftMessage(to: ["recipient@example.com"], subject: "Resurrection", body: "hello")
    }

    @Test("Gmail saveDraft UPDATE 404 falls back to CREATE and returns the new draft/message ids")
    func gmailSaveDraftResurrectsAfterGoneUpdate() async throws {
        let http = FakeHTTP.Scenario()
        defer { http.close() }
        let goneId = "gone-draft-id"
        let newDraftId = "fresh-draft-id"
        let newMessageId = "fresh-message-id"

        http.register(path: "/drafts/\(goneId)", method: "PUT", response: .status(404))
        let createResponseJSON = """
        {"id":"\(newDraftId)","message":{"id":"\(newMessageId)"}}
        """
        http.register(path: "/drafts", method: "POST", response: .json(raw: createResponseJSON))

        let provider = GmailProvider(
            userEmail: "test@example.com",
            accessToken: { _ in "fake-access-token" },
            session: http.session
        )

        let result = try await provider.saveDraft(makeDraft(), existingDraftId: goneId, draftsFolderPath: "DRAFT")

        #expect(result.serverId == newDraftId)
        #expect(result.messageId == newMessageId)

        let calls = http.recordedCalls()
        #expect(calls.contains { $0.method == "PUT" && $0.url.contains(goneId) }, "the update was attempted first")
        #expect(calls.contains { $0.method == "POST" && $0.url.hasSuffix("/drafts") }, "then fell back to create")
    }

    @Test("Gmail saveDraft UPDATE 410 (Gone) also falls back to CREATE")
    func gmailSaveDraftResurrectsAfter410() async throws {
        let http = FakeHTTP.Scenario()
        defer { http.close() }
        let goneId = "gone-draft-id-410"
        let newDraftId = "fresh-draft-id-410"

        http.register(path: "/drafts/\(goneId)", method: "PUT", response: .status(410))
        let createResponseJSON = """
        {"id":"\(newDraftId)","message":{"id":"fresh-message-id-410"}}
        """
        http.register(path: "/drafts", method: "POST", response: .json(raw: createResponseJSON))

        let provider = GmailProvider(
            userEmail: "test@example.com",
            accessToken: { _ in "fake-access-token" },
            session: http.session
        )

        let result = try await provider.saveDraft(makeDraft(), existingDraftId: goneId, draftsFolderPath: "DRAFT")
        #expect(result.serverId == newDraftId)
    }

    @Test("Gmail saveDraft UPDATE non-gone failure (500) keeps throwing — never silently creates a duplicate")
    func gmailSaveDraftDoesNotResurrectOnTransientFailure() async throws {
        let http = FakeHTTP.Scenario()
        defer { http.close() }
        let existingId = "existing-draft-id"

        http.register(path: "/drafts/\(existingId)", method: "PUT", response: .status(500))
        // No /drafts POST registered — if the provider incorrectly fell back
        // to create, the request would hit FakeHTTP's unmatched-request 599
        // path and still fail, but registering nothing here keeps the intent
        // explicit: CREATE must never be attempted for a non-gone failure.

        let provider = GmailProvider(
            userEmail: "test@example.com",
            accessToken: { _ in "fake-access-token" },
            session: http.session
        )

        await #expect(throws: ProviderError.self) {
            try await provider.saveDraft(makeDraft(), existingDraftId: existingId, draftsFolderPath: "DRAFT")
        }
        let calls = http.recordedCalls()
        #expect(!calls.contains { $0.method == "POST" && $0.url.hasSuffix("/drafts") }, "a transient 500 must never fall back to create")
    }

    @Test("Exchange saveDraft UPDATE 404 falls back to CREATE and returns the new message id")
    func exchangeSaveDraftResurrectsAfterGoneUpdate() async throws {
        let http = FakeHTTP.Scenario()
        defer { http.close() }
        let goneId = "gone-draft-id"
        let newMessageId = "fresh-message-id"

        http.register(path: "/messages/\(goneId)", method: "PATCH", response: .status(404))
        let createResponseJSON = """
        {"id":"\(newMessageId)"}
        """
        http.register(path: "/mailFolders/drafts/messages", method: "POST", response: .json(raw: createResponseJSON))

        let provider = ExchangeProvider(
            userEmail: "test@example.com",
            accessToken: { _ in "fake-graph-token" },
            session: http.session
        )

        let result = try await provider.saveDraft(makeDraft(), existingDraftId: goneId, draftsFolderPath: "drafts")

        #expect(result.serverId == newMessageId)
        let calls = http.recordedCalls()
        #expect(calls.contains { $0.method == "PATCH" && $0.url.contains(goneId) }, "the update was attempted first")
        #expect(calls.contains { $0.method == "POST" && $0.url.contains("/mailFolders/drafts/messages") }, "then fell back to create")
    }

    @Test("Exchange saveDraft UPDATE 410 (Gone) also falls back to CREATE")
    func exchangeSaveDraftResurrectsAfter410() async throws {
        let http = FakeHTTP.Scenario()
        defer { http.close() }
        let goneId = "gone-draft-id-410"
        let newMessageId = "fresh-message-id-410"

        http.register(path: "/messages/\(goneId)", method: "PATCH", response: .status(410))
        let createResponseJSON = """
        {"id":"\(newMessageId)"}
        """
        http.register(path: "/mailFolders/drafts/messages", method: "POST", response: .json(raw: createResponseJSON))

        let provider = ExchangeProvider(
            userEmail: "test@example.com",
            accessToken: { _ in "fake-graph-token" },
            session: http.session
        )

        let result = try await provider.saveDraft(makeDraft(), existingDraftId: goneId, draftsFolderPath: "drafts")
        #expect(result.serverId == newMessageId)
    }

    @Test("Exchange saveDraft UPDATE non-gone failure (500) keeps throwing — never silently creates a duplicate")
    func exchangeSaveDraftDoesNotResurrectOnTransientFailure() async throws {
        let http = FakeHTTP.Scenario()
        defer { http.close() }
        let existingId = "existing-draft-id"

        http.register(path: "/messages/\(existingId)", method: "PATCH", response: .status(500))

        let provider = ExchangeProvider(
            userEmail: "test@example.com",
            accessToken: { _ in "fake-graph-token" },
            session: http.session
        )

        await #expect(throws: ProviderError.self) {
            try await provider.saveDraft(makeDraft(), existingDraftId: existingId, draftsFolderPath: "drafts")
        }
        let calls = http.recordedCalls()
        #expect(!calls.contains { $0.method == "POST" && $0.url.contains("/mailFolders/drafts/messages") }, "a transient 500 must never fall back to create")
    }
}
