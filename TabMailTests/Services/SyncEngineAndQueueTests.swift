/* This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at https://mozilla.org/MPL/2.0/. */

import Testing
import Foundation
@testable import TabMail

// MARK: - ActiveBodyQueue.Item

@Suite("ActiveBodyQueue.Item")
struct ActiveBodyQueueItemTests {

    @Test("Item conforms to Hashable — same values are equal")
    func itemEquality() {
        let a = ActiveBodyQueue.Item(headerId: "h1", accountId: "a1", folderPath: "INBOX", messageId: "m1", isInInbox: true)
        let b = ActiveBodyQueue.Item(headerId: "h1", accountId: "a1", folderPath: "INBOX", messageId: "m1", isInInbox: true)
        #expect(a == b)
        #expect(a.hashValue == b.hashValue)
    }

    @Test("Item — different headerIds are not equal")
    func itemInequalityHeaderId() {
        let a = ActiveBodyQueue.Item(headerId: "h1", accountId: "a1", folderPath: "INBOX", messageId: "m1", isInInbox: true)
        let b = ActiveBodyQueue.Item(headerId: "h2", accountId: "a1", folderPath: "INBOX", messageId: "m1", isInInbox: true)
        #expect(a != b)
    }

    @Test("Item stores all fields correctly")
    func itemFields() {
        let item = ActiveBodyQueue.Item(headerId: "hdr", accountId: "acc", folderPath: "Sent", messageId: "msg", isInInbox: false)
        #expect(item.headerId == "hdr")
        #expect(item.accountId == "acc")
        #expect(item.folderPath == "Sent")
        #expect(item.messageId == "msg")
        #expect(item.isInInbox == false)
    }

    @Test("Item can be used in a Set for dedup")
    func itemSetDedup() {
        let a = ActiveBodyQueue.Item(headerId: "h1", accountId: "a1", folderPath: "INBOX", messageId: "m1", isInInbox: true)
        let b = ActiveBodyQueue.Item(headerId: "h1", accountId: "a1", folderPath: "INBOX", messageId: "m1", isInInbox: true)
        let c = ActiveBodyQueue.Item(headerId: "h2", accountId: "a1", folderPath: "INBOX", messageId: "m2", isInInbox: true)
        let set: Set<ActiveBodyQueue.Item> = [a, b, c]
        #expect(set.count == 2)
    }
}

// MARK: - BackfillEmbeddingQueue.Item

@Suite("BackfillEmbeddingQueue.Item")
struct BackfillEmbeddingQueueItemTests {

    @Test("Item conforms to Hashable — same headerId equal")
    func itemEquality() {
        let a = BackfillEmbeddingQueue.Item(headerId: "h1")
        let b = BackfillEmbeddingQueue.Item(headerId: "h1")
        #expect(a == b)
    }

    @Test("Item — different headerIds not equal")
    func itemInequality() {
        let a = BackfillEmbeddingQueue.Item(headerId: "h1")
        let b = BackfillEmbeddingQueue.Item(headerId: "h2")
        #expect(a != b)
    }

    @Test("Item stores headerId correctly")
    func itemField() {
        let item = BackfillEmbeddingQueue.Item(headerId: "my-header-id")
        #expect(item.headerId == "my-header-id")
    }

    @Test("Item can be used in a Set for dedup")
    func itemSetDedup() {
        let a = BackfillEmbeddingQueue.Item(headerId: "h1")
        let b = BackfillEmbeddingQueue.Item(headerId: "h1")
        let c = BackfillEmbeddingQueue.Item(headerId: "h2")
        let set: Set<BackfillEmbeddingQueue.Item> = [a, b, c]
        #expect(set.count == 2)
    }
}

// MARK: - BackfillProfile

@Suite("BackfillProfile Tiers")
struct BackfillProfileTierTests {

    @Test("Low profile has smallest chunk sizes")
    func lowIsSmallest() {
        let low = BackfillProfile.low
        let normal = BackfillProfile.normal
        #expect(low.backfillChunkSize < normal.backfillChunkSize)
        #expect(low.imapFetchBatchSize < normal.imapFetchBatchSize)
        #expect(low.gmailFetchBatchSize < normal.gmailFetchBatchSize)
        #expect(low.gmailHeaderConcurrency < normal.gmailHeaderConcurrency)
    }

    @Test("Turbo profile has largest chunk sizes")
    func turboIsLargest() {
        let turbo = BackfillProfile.turbo
        let aggressive = BackfillProfile.aggressive
        #expect(turbo.backfillChunkSize >= aggressive.backfillChunkSize)
        #expect(turbo.imapFetchBatchSize >= aggressive.imapFetchBatchSize)
        #expect(turbo.gmailFetchBatchSize >= aggressive.gmailFetchBatchSize)
        #expect(turbo.gmailHeaderConcurrency >= aggressive.gmailHeaderConcurrency)
    }

    @Test("Delays decrease from low to turbo")
    func delaysDecrease() {
        let low = BackfillProfile.low
        let normal = BackfillProfile.normal
        let aggressive = BackfillProfile.aggressive
        let turbo = BackfillProfile.turbo

        #expect(low.imapInterBatchDelay >= normal.imapInterBatchDelay)
        #expect(normal.imapInterBatchDelay >= aggressive.imapInterBatchDelay)
        #expect(aggressive.imapInterBatchDelay >= turbo.imapInterBatchDelay)
        #expect(turbo.imapInterBatchDelay == 0)
    }

    @Test("Turbo has zero delays")
    func turboZeroDelays() {
        let turbo = BackfillProfile.turbo
        #expect(turbo.imapInterBatchDelay == 0)
        #expect(turbo.gmailInterPageDelay == 0)
        #expect(turbo.gmailInterFetchDelay == 0)
        #expect(turbo.deepCrawlInterWindowDelay == 0)
        #expect(turbo.interFolderDelay == 0)
        #expect(turbo.interCycleActiveDelay == 0)
    }

    @Test("All profiles have positive chunk sizes")
    func allPositiveChunks() {
        let profiles: [BackfillProfile] = [.low, .normal, .aggressive, .turbo]
        for profile in profiles {
            #expect(profile.backfillChunkSize > 0)
            #expect(profile.imapFetchBatchSize > 0)
            #expect(profile.gmailFetchBatchSize > 0)
            #expect(profile.gmailPageSize > 0)
            #expect(profile.gmailHeaderConcurrency > 0)
            #expect(profile.bodyFetchChunkSize > 0)
            #expect(profile.imapBodyFetchBatchSize > 0)
            #expect(profile.imapBodyConcurrency > 0)
            #expect(profile.gmailBodyConcurrency > 0)
        }
    }

    @Test("All profiles have non-negative delays")
    func allNonNegativeDelays() {
        let profiles: [BackfillProfile] = [.low, .normal, .aggressive, .turbo]
        for profile in profiles {
            #expect(profile.imapInterBatchDelay >= 0)
            #expect(profile.gmailInterPageDelay >= 0)
            #expect(profile.gmailInterFetchDelay >= 0)
            #expect(profile.deepCrawlInterWindowDelay >= 0)
            #expect(profile.interFolderDelay >= 0)
            #expect(profile.interCycleActiveDelay >= 0)
            #expect(profile.interCycleIdleDelay >= 0)
        }
    }

    @Test("Idle delay is always >= active delay")
    func idleExceedsActive() {
        let profiles: [BackfillProfile] = [.low, .normal, .aggressive, .turbo]
        for profile in profiles {
            #expect(profile.interCycleIdleDelay >= profile.interCycleActiveDelay)
        }
    }

    @Test("Normal profile exact values")
    func normalExactValues() {
        let normal = BackfillProfile.normal
        #expect(normal.backfillChunkSize == 500)
        #expect(normal.imapFetchBatchSize == 100)
        #expect(normal.gmailFetchBatchSize == 50)
        #expect(normal.gmailPageSize == 500)
        #expect(normal.imapInterBatchDelay == 0.5)
        #expect(normal.gmailHeaderConcurrency == 5)
        #expect(normal.bodyFetchChunkSize == 50)
    }

    @Test("Aggressive profile exact values")
    func aggressiveExactValues() {
        let agg = BackfillProfile.aggressive
        #expect(agg.backfillChunkSize == 1000)
        #expect(agg.imapFetchBatchSize == 200)
        #expect(agg.gmailFetchBatchSize == 100)
        #expect(agg.imapInterBatchDelay == 0.1)
        #expect(agg.gmailHeaderConcurrency == 10)
    }
}

// MARK: - SyncEngine Static Error Classification

@Suite("SyncEngine.isSelectFailedError")
struct SyncEngineSelectFailedErrorTests {

    @Test("Detects 'Select mailbox failed' error")
    func detectsSelectFailed() {
        let error = NSError(domain: "IMAP", code: 0, userInfo: [NSLocalizedDescriptionKey: "Select mailbox failed for INBOX"])
        #expect(SyncEngine.isSelectFailedError(error) == true)
    }

    @Test("Returns false for unrelated errors")
    func returnsFalseForUnrelated() {
        let error = NSError(domain: "IMAP", code: 0, userInfo: [NSLocalizedDescriptionKey: "Connection timeout"])
        #expect(SyncEngine.isSelectFailedError(error) == false)
    }

    @Test("Returns false for empty error description")
    func returnsFalseForEmpty() {
        let error = NSError(domain: "Test", code: 0, userInfo: nil)
        #expect(SyncEngine.isSelectFailedError(error) == false)
    }
}

@Suite("SyncEngine.isConnectionError")
struct SyncEngineConnectionErrorTests {

    @Test("Detects 'notConnected' in error string")
    func detectsNotConnected() {
        let error = NSError(domain: "IMAP", code: 0, userInfo: [NSLocalizedDescriptionKey: "notConnected: server unreachable"])
        #expect(SyncEngine.isConnectionError(error) == true)
    }

    @Test("Detects 'Connection reset'")
    func detectsConnectionReset() {
        let error = NSError(domain: "IMAP", code: 0, userInfo: [NSLocalizedDescriptionKey: "Connection reset by peer"])
        #expect(SyncEngine.isConnectionError(error) == true)
    }

    @Test("Detects 'broken pipe'")
    func detectsBrokenPipe() {
        let error = NSError(domain: "IMAP", code: 0, userInfo: [NSLocalizedDescriptionKey: "broken pipe"])
        #expect(SyncEngine.isConnectionError(error) == true)
    }

    @Test("Detects 'timed out'")
    func detectsTimedOut() {
        let error = NSError(domain: "IMAP", code: 0, userInfo: [NSLocalizedDescriptionKey: "Operation timed out"])
        #expect(SyncEngine.isConnectionError(error) == true)
    }

    @Test("Detects 'closed channel'")
    func detectsClosedChannel() {
        let error = NSError(domain: "IMAP", code: 0, userInfo: [NSLocalizedDescriptionKey: "closed channel"])
        #expect(SyncEngine.isConnectionError(error) == true)
    }

    @Test("Detects 'I/O on closed'")
    func detectsIOOnClosed() {
        let error = NSError(domain: "IMAP", code: 0, userInfo: [NSLocalizedDescriptionKey: "I/O on closed channel"])
        #expect(SyncEngine.isConnectionError(error) == true)
    }

    @Test("Detects 'EPIPE'")
    func detectsEPIPE() {
        let error = NSError(domain: "IMAP", code: 0, userInfo: [NSLocalizedDescriptionKey: "EPIPE error"])
        #expect(SyncEngine.isConnectionError(error) == true)
    }

    @Test("Detects 'IMAPDecoderError'")
    func detectsIMAPDecoderError() {
        let error = NSError(domain: "IMAP", code: 0, userInfo: [NSLocalizedDescriptionKey: "IMAPDecoderError: unexpected byte"])
        #expect(SyncEngine.isConnectionError(error) == true)
    }

    @Test("Detects 'IMAPDecodeError'")
    func detectsIMAPDecodeError() {
        let error = NSError(domain: "IMAP", code: 0, userInfo: [NSLocalizedDescriptionKey: "IMAPDecodeError: malformed response"])
        #expect(SyncEngine.isConnectionError(error) == true)
    }

    @Test("Detects URLError")
    func detectsURLError() {
        let error = URLError(.notConnectedToInternet)
        #expect(SyncEngine.isConnectionError(error) == true)
    }

    @Test("Returns false for auth errors")
    func returnsFalseForAuth() {
        let error = NSError(domain: "IMAP", code: 0, userInfo: [NSLocalizedDescriptionKey: "Authentication failed"])
        #expect(SyncEngine.isConnectionError(error) == false)
    }

    @Test("Returns false for unrelated errors")
    func returnsFalseForUnrelated() {
        let error = NSError(domain: "App", code: 0, userInfo: [NSLocalizedDescriptionKey: "Some other error"])
        #expect(SyncEngine.isConnectionError(error) == false)
    }
}

// MARK: - SearchConfig Additional Tests

@Suite("SearchConfig Extended")
struct SearchConfigExtendedTests {

    @Test("BM25 msgId weight is 0 (no matching on ID)")
    func bm25MsgIdWeightZero() {
        let weights = SearchConfig.bm25Weights.components(separatedBy: ",").compactMap {
            Double($0.trimmingCharacters(in: .whitespaces))
        }
        #expect(weights[0] == 0.0)
    }

    @Test("BM25 from weight > to weight")
    func bm25FromGtTo() {
        let weights = SearchConfig.bm25Weights.components(separatedBy: ",").compactMap {
            Double($0.trimmingCharacters(in: .whitespaces))
        }
        // from_=3.0 (index 2), to_=2.0 (index 3)
        #expect(weights[2] > weights[3])
    }

    @Test("Embedding dims matches MiniLM-L6-v2 (384)")
    func embeddingDimsMatchesMiniLM() {
        #expect(SearchConfig.embeddingDims == 384)
    }

    @Test("maxTokens is 256")
    func maxTokensValue() {
        #expect(SearchConfig.maxTokens == 256)
    }

    @Test("bodyMaxWords is 150")
    func bodyMaxWordsValue() {
        #expect(SearchConfig.bodyMaxWords == 150)
    }

    @Test("Vector weight dominates text weight")
    func vectorDominatesText() {
        #expect(SearchConfig.vectorWeight > SearchConfig.textWeight)
    }

    @Test("Candidate multiplier is 4")
    func candidateMultiplierValue() {
        #expect(SearchConfig.candidateMultiplier == 4)
    }

    @Test("FTS automerge is 8")
    func automergeValue() {
        #expect(SearchConfig.ftsAutomerge == 8)
    }

    @Test("Shard migration chunk size is 500")
    func shardMigrationChunkSize() {
        #expect(SearchConfig.shardMigrationChunkSize == 500)
    }

    @Test("Vector score threshold is 0.45")
    func vectorScoreThresholdExact() {
        #expect(SearchConfig.vectorScoreThreshold == 0.45)
    }

    @Test("Snippet tokens is 16")
    func snippetTokensValue() {
        #expect(SearchConfig.snippetTokens == 16)
    }

    @Test("FTS tokenize has NO tokenchars (ADR-024: addresses index as parts)")
    func ftsTokenizeNoTokenchars() {
        // tokenchars '-_.@' glued addresses into single tokens that could only be
        // prefix-matched from the token start — "dmarc-" never matched
        // "noreply-dmarc-support@…". Do not reintroduce without ADR-024 revisit.
        #expect(!SearchConfig.ftsTokenize.contains("tokenchars"))
        #expect(SearchConfig.ftsTokenize.contains("porter"))
    }

    @Test("FTS prefix lengths include 2, 3, 4")
    func ftsPrefixes() {
        #expect(SearchConfig.ftsPrefixes == "2 3 4")
    }

    @Test("SQLite busy timeout is 2000ms")
    func busyTimeout() {
        #expect(SearchConfig.busyTimeoutMs == 2000)
    }

    @Test("SQLite cache size is negative (KiB convention)")
    func cacheSizeNegative() {
        #expect(SearchConfig.cacheSizeKiB == -64000)
    }

    @Test("SQLite mmap size is 256 MB")
    func mmapSize() {
        #expect(SearchConfig.mmapSizeBytes == 268_435_456)
    }
}

// MARK: - EmbeddingService.prepareEmailText

@Suite("EmbeddingService.prepareEmailText")
struct EmbeddingServicePrepareEmailTextTests {

    @Test("Includes subject twice (intentional for embedding emphasis)")
    func subjectDuplicated() {
        let text = EmbeddingService.prepareEmailText(subject: "Hello", from: "", to: "", body: "")
        let subjectCount = text.components(separatedBy: "Subject: Hello").count - 1
        #expect(subjectCount == 2)
    }

    @Test("Includes from and to fields")
    func includesFromTo() {
        let text = EmbeddingService.prepareEmailText(subject: "", from: "alice@test.com", to: "bob@test.com", body: "")
        #expect(text.contains("From: alice@test.com"))
        #expect(text.contains("To: bob@test.com"))
    }

    @Test("Trims whitespace from inputs")
    func trimsWhitespace() {
        let text = EmbeddingService.prepareEmailText(subject: "  Hello  ", from: "  alice  ", to: "  bob  ", body: "  body  ")
        #expect(text.contains("Subject: Hello"))
        #expect(text.contains("From: alice"))
        #expect(text.contains("To: bob"))
    }

    @Test("Omits empty fields")
    func omitsEmptyFields() {
        let text = EmbeddingService.prepareEmailText(subject: "Test", from: "", to: "", body: "")
        #expect(!text.contains("From:"))
        #expect(!text.contains("To:"))
    }

    @Test("Includes body text")
    func includesBody() {
        let text = EmbeddingService.prepareEmailText(subject: "", from: "", to: "", body: "This is the email body content.")
        #expect(text.contains("This is the email body content."))
    }

    @Test("Truncates body to SearchConfig.bodyMaxWords")
    func truncatesBody() {
        let longBody = (0..<300).map { "word\($0)" }.joined(separator: " ")
        let text = EmbeddingService.prepareEmailText(subject: "", from: "", to: "", body: longBody)
        // Body should be truncated — the full 300-word body should not appear
        let bodyWords = text.components(separatedBy: .whitespaces).filter { !$0.isEmpty }
        #expect(bodyWords.count <= SearchConfig.bodyMaxWords + 10) // header parts + body words
    }

    @Test("All empty inputs produce empty or whitespace-only result")
    func allEmptyInputs() {
        let text = EmbeddingService.prepareEmailText(subject: "", from: "", to: "", body: "")
        #expect(text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
    }

    @Test("Full email with all fields populated")
    func fullEmail() {
        let text = EmbeddingService.prepareEmailText(
            subject: "Meeting Tomorrow",
            from: "alice@example.com",
            to: "bob@example.com",
            body: "Let's meet at 10am."
        )
        #expect(text.contains("Subject: Meeting Tomorrow"))
        #expect(text.contains("From: alice@example.com"))
        #expect(text.contains("To: bob@example.com"))
        #expect(text.contains("Let's meet at 10am."))
    }
}
