/* This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at https://mozilla.org/MPL/2.0/. */

import Testing
import Foundation
@testable import TabMail

@Suite("ProviderError extended")
struct ProviderErrorExtendedTests {

    // MARK: - LocalizedError conformance

    @Test("notConnected conforms to LocalizedError")
    func notConnectedIsLocalizedError() {
        let error: any LocalizedError = ProviderError.notConnected
        #expect(error.errorDescription != nil)
    }

    @Test("messageNotFound conforms to LocalizedError")
    func messageNotFoundIsLocalizedError() {
        let error: any LocalizedError = ProviderError.messageNotFound
        #expect(error.errorDescription != nil)
    }

    @Test("authenticationFailed conforms to LocalizedError")
    func authFailedIsLocalizedError() {
        let error: any LocalizedError = ProviderError.authenticationFailed
        #expect(error.errorDescription != nil)
    }

    @Test("All cases produce non-empty errorDescription")
    func allCasesNonEmptyDescription() {
        let errors: [ProviderError] = [
            .notConnected,
            .messageNotFound,
            .authenticationFailed,
            .networkError(underlying: NSError(domain: "test", code: 1)),
            .invalidURL("http://bad"),
            .syntheticPlaceholderId(["sent-abc"]),
        ]
        for error in errors {
            #expect(error.errorDescription != nil)
            #expect(!error.errorDescription!.isEmpty)
        }
    }

    // MARK: - Synthetic placeholder id detection

    @Test("isSyntheticPlaceholderId matches sent- and draft- prefixes")
    func syntheticPrefixesMatch() {
        #expect(isSyntheticPlaceholderId("sent-55A163A7-9B07-4086-AECD-C49351C97924"))
        #expect(isSyntheticPlaceholderId("draft-deadbeef"))
    }

    @Test("isSyntheticPlaceholderId rejects real provider ids")
    func realIdsDoNotMatch() {
        // Gmail uses hex thread ids, IMAP uses numeric UIDs, Exchange uses base64-ish
        // immutable ids. None should match the synthetic prefix shape.
        #expect(!isSyntheticPlaceholderId("19dea75bb00e913d"))
        #expect(!isSyntheticPlaceholderId("18055"))
        #expect(!isSyntheticPlaceholderId("AAMkADAw…ABKQ=="))
        #expect(!isSyntheticPlaceholderId(""))
        // A real subject-prefixed-with-"sent" or "draft" should not be present in
        // the messageId column, but be paranoid: the prefix MUST be followed by `-`
        // and our generators always emit `sent-` / `draft-` so substring "sentry"
        // shouldn't trip. Verify.
        #expect(!isSyntheticPlaceholderId("sentry-rollout"))
        #expect(!isSyntheticPlaceholderId("draftsmen-meeting"))
    }

    // MARK: - fetchMessagesBatch synthetic-id guard

    @Test("default fetchMessagesBatch throws when any id is synthetic")
    func defaultBatchThrowsOnSyntheticId() async throws {
        // The default `EmailProvider.fetchMessagesBatch` extension guards the
        // provider boundary so a synthetic placeholder id never reaches the
        // network. Throws rather than silently dropping — silent drop would
        // feed the caller's miss-counter and after threshold CASCADE-delete
        // the local row + cached body. See docstring on
        // ProviderError.syntheticPlaceholderId.
        let mock = MockEmailProvider()

        await #expect(throws: ProviderError.self) {
            _ = try await mock.fetchMessagesBatch(
                ids: ["sent-55A163A7-9B07-4086-AECD-C49351C97924"],
                folder: "Sent"
            )
        }

        // Verify the underlying fetchMessage was NOT called — guard fires before
        // any HTTP / IMAP work.
        let log = await mock.callLog
        #expect(!log.contains(where: { $0.hasPrefix("fetchMessage(") }))
    }

    @Test("default fetchMessagesBatch throws even when only one id in a mixed batch is synthetic")
    func defaultBatchThrowsOnMixedSyntheticBatch() async throws {
        // Mixed batches are still rejected — one bad id taints the whole call.
        // BackfillBodyQueue's catch path retries the whole batch (no miss-counter
        // increment), so the real ids stay queued and re-enqueued; after maxQueueRetries
        // the batch falls out of memory but local rows are untouched. Trade
        // throughput for safety.
        let mock = MockEmailProvider()

        await #expect(throws: ProviderError.self) {
            _ = try await mock.fetchMessagesBatch(
                ids: ["19dea75bb00e913d", "draft-abc-def", "another-real-id"],
                folder: "Drafts"
            )
        }
    }

    @Test("default fetchMessagesBatch does not flag real ids")
    func defaultBatchDoesNotFlagRealIds() async throws {
        // Sanity — empty batch and all-real batch don't trip the guard. (Empty
        // exits without calling fetchMessage; all-real proceeds normally.)
        let mock = MockEmailProvider()

        let empty = try await mock.fetchMessagesBatch(ids: [], folder: "Sent")
        #expect(empty.isEmpty)

        // All-real batch with no fetchMessageResult set throws .messageNotFound
        // from inside the loop, NOT .syntheticPlaceholderId.
        do {
            _ = try await mock.fetchMessagesBatch(ids: ["real-1"], folder: "Sent")
            Issue.record("expected throw")
        } catch ProviderError.syntheticPlaceholderId {
            Issue.record("real ids tripped the synthetic guard")
        } catch {
            // any other error (messageNotFound, etc.) is fine — the guard is
            // not the one throwing.
        }
    }

    // MARK: - Error protocol conformance

    @Test("Can be caught as generic Error")
    func catchAsError() {
        func throwingFunc() throws {
            throw ProviderError.notConnected
        }
        #expect(throws: (any Error).self) {
            try throwingFunc()
        }
    }

    @Test("localizedDescription available through Error protocol")
    func localizedDescriptionViaError() {
        let error: any Error = ProviderError.messageNotFound
        #expect(!error.localizedDescription.isEmpty)
    }

    @Test("networkError wraps NSError correctly")
    func networkErrorWrapsNSError() {
        let nsError = NSError(domain: NSURLErrorDomain, code: -1009, userInfo: [
            NSLocalizedDescriptionKey: "The Internet connection appears to be offline.",
        ])
        let error = ProviderError.networkError(underlying: nsError)
        #expect(error.errorDescription?.contains("offline") == true)
    }

    @Test("networkError wraps custom Error type")
    func networkErrorWrapsCustom() {
        struct CustomNetworkError: LocalizedError {
            var errorDescription: String? { "Custom: connection reset" }
        }
        let error = ProviderError.networkError(underlying: CustomNetworkError())
        #expect(error.errorDescription?.contains("Custom: connection reset") == true)
    }

    // MARK: - errorDescription content verification

    @Test("notConnected description mentions server")
    func notConnectedMentionsServer() {
        let error = ProviderError.notConnected
        #expect(error.errorDescription?.lowercased().contains("server") == true)
    }

    @Test("authenticationFailed description mentions credentials")
    func authFailedMentionsCredentials() {
        let error = ProviderError.authenticationFailed
        #expect(error.errorDescription?.lowercased().contains("credentials") == true)
    }

    @Test("invalidURL description contains the provided URL string")
    func invalidURLContainsURL() {
        let urlString = "https://not-a-real-endpoint.example.com/api"
        let error = ProviderError.invalidURL(urlString)
        #expect(error.errorDescription?.contains(urlString) == true)
    }

    @Test("networkError description contains 'Network error' prefix")
    func networkErrorPrefix() {
        let error = ProviderError.networkError(underlying: NSError(domain: "test", code: 0))
        #expect(error.errorDescription?.hasPrefix("Network error") == true)
    }

    // MARK: - Pattern matching

    @Test("Pattern matching works for simple cases")
    func patternMatchSimple() {
        let error = ProviderError.notConnected
        switch error {
        case .notConnected:
            // Expected path
            break
        default:
            Issue.record("Should match .notConnected")
        }
    }

    @Test("Pattern matching extracts associated value from invalidURL")
    func patternMatchInvalidURL() {
        let error = ProviderError.invalidURL("bad-url")
        switch error {
        case .invalidURL(let url):
            #expect(url == "bad-url")
        default:
            Issue.record("Should match .invalidURL")
        }
    }

    @Test("Pattern matching extracts underlying error from networkError")
    func patternMatchNetworkError() {
        let underlying = NSError(domain: "TestDomain", code: 42)
        let error = ProviderError.networkError(underlying: underlying)
        switch error {
        case .networkError(let wrapped):
            let nsErr = wrapped as NSError
            #expect(nsErr.code == 42)
            #expect(nsErr.domain == "TestDomain")
        default:
            Issue.record("Should match .networkError")
        }
    }

    // MARK: - Edge cases for associated values

    @Test("invalidURL with empty string")
    func invalidURLEmptyString() {
        let error = ProviderError.invalidURL("")
        #expect(error.errorDescription?.contains("Invalid URL") == true)
    }

    @Test("invalidURL with special characters")
    func invalidURLSpecialChars() {
        let error = ProviderError.invalidURL("http://example.com/path?q=a&b=c#fragment")
        #expect(error.errorDescription?.contains("q=a&b=c") == true)
    }

    // MARK: - Multiple networkError wrapping

    @Test("networkError with URLError timeout")
    func networkErrorURLTimeout() {
        let urlError = URLError(.timedOut)
        let error = ProviderError.networkError(underlying: urlError)
        #expect(error.errorDescription != nil)
        #expect(error.errorDescription?.hasPrefix("Network error") == true)
    }

    @Test("networkError with URLError not connected")
    func networkErrorURLNotConnected() {
        let urlError = URLError(.notConnectedToInternet)
        let error = ProviderError.networkError(underlying: urlError)
        #expect(error.errorDescription != nil)
    }

    // MARK: - Type identity

    @Test("Different cases are distinguishable")
    func casesDistinguishable() {
        let errors: [ProviderError] = [
            .notConnected,
            .messageNotFound,
            .authenticationFailed,
        ]
        // Each should have a unique description
        let descriptions = errors.compactMap(\.errorDescription)
        let uniqueDescriptions = Set(descriptions)
        #expect(uniqueDescriptions.count == 3)
    }

    @Test("Two invalidURL with different URLs have different descriptions")
    func differentURLsDifferentDescriptions() {
        let error1 = ProviderError.invalidURL("http://a.com")
        let error2 = ProviderError.invalidURL("http://b.com")
        #expect(error1.errorDescription != error2.errorDescription)
    }

}
