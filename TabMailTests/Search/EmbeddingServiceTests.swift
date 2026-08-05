/* This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at https://mozilla.org/MPL/2.0/. */

import Testing
import Foundation
import Synchronization
@testable import TabMail

@Suite("EmbeddingService.prepareEmailText")
struct EmbeddingServicePrepareTextTests {

    @Test("Subject repeated for emphasis")
    func subjectRepeated() {
        let text = EmbeddingService.prepareEmailText(subject: "Meeting tomorrow", from: "alice@example.com", to: "bob@example.com", body: "Let's meet at 2pm")
        let subjectCount = text.components(separatedBy: "Subject: Meeting tomorrow").count - 1
        #expect(subjectCount == 2)
    }

    @Test("From and To included")
    func fromToIncluded() {
        let text = EmbeddingService.prepareEmailText(subject: "Hi", from: "alice@example.com", to: "bob@example.com", body: "Hello")
        #expect(text.contains("From: alice@example.com"))
        #expect(text.contains("To: bob@example.com"))
    }

    @Test("Body truncated to max words")
    func bodyTruncated() {
        let longBody = (0..<500).map { "word\($0)" }.joined(separator: " ")
        let text = EmbeddingService.prepareEmailText(subject: "Test", from: "", to: "", body: longBody)
        let bodyPart = text.components(separatedBy: "\n\n").last ?? ""
        let wordCount = bodyPart.split(separator: " ").count
        #expect(wordCount <= SearchConfig.bodyMaxWords + 5) // small margin for splitting
    }

    @Test("Empty subject omitted")
    func emptySubjectOmitted() {
        let text = EmbeddingService.prepareEmailText(subject: "", from: "alice@example.com", to: "", body: "Hello")
        #expect(!text.contains("Subject:"))
    }

    @Test("Empty from omitted")
    func emptyFromOmitted() {
        let text = EmbeddingService.prepareEmailText(subject: "Hi", from: "", to: "", body: "Hello")
        #expect(!text.contains("From:"))
    }

    @Test("Empty body returns header only")
    func emptyBody() {
        let text = EmbeddingService.prepareEmailText(subject: "Hi", from: "a@b.com", to: "c@d.com", body: "")
        #expect(text.contains("Subject:"))
        #expect(!text.contains("\n\n"))
    }

    @Test("All empty returns empty string")
    func allEmpty() {
        let text = EmbeddingService.prepareEmailText(subject: "", from: "", to: "", body: "")
        #expect(text.isEmpty)
    }

    @Test("Whitespace-only inputs treated as empty")
    func whitespaceOnly() {
        let text = EmbeddingService.prepareEmailText(subject: "  ", from: "  ", to: "  ", body: "  ")
        #expect(text.isEmpty)
    }

    @Test("Short body not truncated")
    func shortBodyPreserved() {
        let text = EmbeddingService.prepareEmailText(subject: "Hi", from: "", to: "", body: "Short email body")
        #expect(text.contains("Short email body"))
    }
}

#if DEBUG
/// Restored from `v2final` (`e28dd4edb`,
/// `TabMailTests/Search/EmbeddingServiceTests.swift`) together with the
/// `EmbeddingStartupPolicy` seam it covers. Two-sided on purpose: the first test
/// proves the suppression fires in the process it exists for, the second proves it
/// does NOT fire for an ordinary DEBUG launch — a one-sided version would stay
/// green on a policy that had degenerated into "never initialize".
@Suite("EmbeddingService app-startup policy", .serialized)
struct EmbeddingServiceStartupPolicyTests {
    @Test("ordinary app-hosted unit-test startup skips CoreML initialization")
    func unitTestHostSkipsCoreMLInitialization() throws {
        let environment = ProcessInfo.processInfo.environment
        let isXCTestHost = environment["XCTestConfigurationFilePath"] != nil
            || environment["XCTestBundlePath"] != nil
        #expect(isXCTestHost, "this invariant must run in the ordinary XCTest app host")

        let initializerCalls = Mutex(0)
        let decision = EmbeddingStartupPolicy.initializeForAppStartup(
            environment: environment,
            initializer: { initializerCalls.withLock { $0 += 1 } }
        )

        #expect(decision == .skippedUnitTestHost)
        #expect(initializerCalls.withLock { $0 } == 0)
    }

    @Test("non-test DEBUG startup still initializes exactly once")
    func ordinaryDebugStartupInitializes() {
        let initializerCalls = Mutex(0)
        let decision = EmbeddingStartupPolicy.initializeForAppStartup(
            environment: [:],
            initializer: { initializerCalls.withLock { $0 += 1 } }
        )

        #expect(decision == .initialized)
        #expect(initializerCalls.withLock { $0 } == 1)
    }
}
#endif

@Suite("FTSHeaderRecord")
struct FTSHeaderRecordTests {

    @Test("Init with all fields")
    func initAllFields() {
        let record = FTSHeaderRecord( contentKey: ContentKey(rawValue: "acc1:INBOX:1"),
            headerId: "acc1:INBOX:1",
            messageId: "1",
            subject: "Test",
            from: "alice@example.com",
            to: "bob@example.com",
            cc: "carol@example.com",
            bcc: "dave@example.com",
            dateMs: 1000
        )
        #expect(record.headerId == "acc1:INBOX:1")
        #expect(record.cc == "carol@example.com")
        #expect(record.bcc == "dave@example.com")
    }

    @Test("Init with default cc/bcc empty")
    func initDefaultCcBcc() {
        let record = FTSHeaderRecord( contentKey: ContentKey(rawValue: "h1"),
            headerId: "h1",
            messageId: "m1",
            subject: "Sub",
            from: "a@b.com",
            to: "c@d.com",
            dateMs: 2000
        )
        #expect(record.cc == "")
        #expect(record.bcc == "")
    }
}

@Suite("FTSSearchResult")
struct FTSSearchResultTests {

    @Test("FTSSearchResult stores all fields")
    func storesAllFields() {
        let result = FTSSearchResult( contentKey: ContentKey(rawValue: "h1"),
            messageId: "m1",
            snippet: "...matching text...",
            rank: -5.0,
            dateMs: 1000
        )
        #expect(result.contentKey.rawValue == "h1")
        #expect(result.snippet == "...matching text...")
        #expect(result.rank == -5.0)
    }
}
