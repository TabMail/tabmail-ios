/* This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at https://mozilla.org/MPL/2.0/. */

import Testing
import Foundation
@testable import TabMail

@Suite("SyncConfig Boundary Checks")
struct SyncConfigBoundaryTests {

    @Test("All chunk sizes are positive")
    func allChunkSizesPositive() {
        #expect(SyncConfig.syncMessageLimit > 0)
        #expect(SyncConfig.inboxPageSize > 0)
        #expect(SyncConfig.bodyFetchChunkSize > 0)
        #expect(SyncConfig.bodyFetchConcurrency > 0)
        #expect(SyncConfig.backfillChunkSize > 0)
        #expect(SyncConfig.pruneChunkSize > 0)
        #expect(SyncConfig.ftsIndexBatchSize > 0)
        #expect(SyncConfig.ftsBodyYieldInterval > 0)
        #expect(SyncConfig.ftsWriteBatchSize > 0)
        #expect(SyncConfig.embeddingBatchSize > 0)
        #expect(SyncConfig.snippetOnDemandChunkSize > 0)
        #expect(SyncConfig.snippetPrefetchLookahead > 0)
    }

    @Test("All timeouts are positive and reasonable")
    func allTimeoutsPositive() {
        #expect(SyncConfig.connectTimeoutSeconds > 0)
        #expect(SyncConfig.perAccountSyncTimeoutSeconds > 0)
        #expect(SyncConfig.imapLockTimeoutSeconds > 0)
        #expect(SyncConfig.imapBatchOperationTimeoutSeconds > 0)
        #expect(SyncConfig.smtpSendTimeoutSeconds > 0)
        #expect(SyncConfig.pendingOperationTimeoutSeconds > 0)
    }

    @Test("Background timeout fits within silent push deadline")
    func backgroundTimeoutFitsDeadline() {
        // Silent push has ~30s deadline; per-account must be less
        #expect(SyncConfig.backgroundPerAccountTimeoutSeconds <= 30)
    }

    @Test("IMAP lock timeout >= batch operation timeout")
    func lockTimeoutCoversBatch() {
        // Lock must last long enough for a batch to complete
        #expect(SyncConfig.imapLockTimeoutSeconds >= SyncConfig.imapBatchOperationTimeoutSeconds)
    }

    @Test("maxQueueRetries is reasonable (not infinite)")
    func maxRetriesReasonable() {
        #expect(SyncConfig.maxQueueRetries >= 1)
        #expect(SyncConfig.maxQueueRetries <= 10)
    }

    @Test("maxConcurrentLLMCalls matches TB addon limit")
    func llmCallsMatchesTB() {
        // TB addon maxAgentWorkers = 32 — gates concurrent sendChat calls via LLMSemaphore
        #expect(SyncConfig.maxConcurrentLLMCalls == 32)
    }

    @Test("maxLoadedMessages > inboxPageSize for smooth pagination")
    func loadedMessagesExceedsPageSize() {
        #expect(SyncConfig.maxLoadedMessages > SyncConfig.inboxPageSize)
    }

    @Test("bodyCacheTTLHours is at least 24 hours")
    func bodyCacheTTLReasonable() {
        #expect(SyncConfig.bodyCacheTTLHours >= 24)
    }

    @Test("undoStackMaxSize reasonable range")
    func undoStackRange() {
        #expect(SyncConfig.undoStackMaxSize >= 5)
        #expect(SyncConfig.undoStackMaxSize <= 50)
    }

    @Test("unreadRecountDebounceSeconds is short")
    func unreadDebounceShort() {
        #expect(SyncConfig.unreadRecountDebounceSeconds > 0)
        #expect(SyncConfig.unreadRecountDebounceSeconds <= 5)
    }

    @Test("Inline image limits prevent memory explosion")
    func inlineImageLimits() {
        #expect(SyncConfig.maxInlineImages > 0)
        #expect(SyncConfig.maxInlineImages <= 50)
        #expect(SyncConfig.maxInlineImageBytes > 0)
        #expect(SyncConfig.maxInlineImageBytes <= 10_000_000) // Max 10MB per image
    }

    @Test("Gmail backfill ID cap prevents unbounded memory")
    func gmailBackfillCap() {
        #expect(SyncConfig.gmailBackfillIdCap > 0)
        #expect(SyncConfig.gmailBackfillIdCap <= 10_000_000)
    }

    @Test("TTL values are positive")
    func ttlValuesPositive() {
        #expect(SyncConfig.replyTTLSeconds > 0)
        #expect(SyncConfig.aiCacheTTLDays > 0)
    }
}

@Suite("BackfillProfile Consistency")
struct BackfillProfileConsistencyTests {

    @Test("Chunk sizes increase with aggression")
    func chunkSizesIncrease() {
        let profiles: [BackfillProfile] = [.low, .normal, .aggressive, .turbo]
        for i in 1..<profiles.count {
            #expect(profiles[i].backfillChunkSize >= profiles[i - 1].backfillChunkSize)
            #expect(profiles[i].imapFetchBatchSize >= profiles[i - 1].imapFetchBatchSize)
            #expect(profiles[i].gmailFetchBatchSize >= profiles[i - 1].gmailFetchBatchSize)
        }
    }

    @Test("Inter-batch delays decrease with aggression")
    func delaysDecrease() {
        let profiles: [BackfillProfile] = [.low, .normal, .aggressive, .turbo]
        for i in 1..<profiles.count {
            #expect(profiles[i].imapInterBatchDelay <= profiles[i - 1].imapInterBatchDelay)
            #expect(profiles[i].gmailInterPageDelay <= profiles[i - 1].gmailInterPageDelay)
        }
    }

    @Test("Turbo has zero delays for maximum throughput")
    func turboZeroDelays() {
        #expect(BackfillProfile.turbo.imapInterBatchDelay == 0)
        #expect(BackfillProfile.turbo.gmailInterPageDelay == 0)
    }

    @Test("All profiles have positive chunk sizes")
    func allPositiveChunks() {
        for profile in [BackfillProfile.low, .normal, .aggressive, .turbo] {
            #expect(profile.backfillChunkSize > 0)
            #expect(profile.imapFetchBatchSize > 0)
            #expect(profile.gmailFetchBatchSize > 0)
            #expect(profile.gmailPageSize > 0)
        }
    }

    @Test("Gmail header concurrency increases with aggression")
    func gmailConcurrencyIncreases() {
        let profiles: [BackfillProfile] = [.low, .normal, .aggressive, .turbo]
        for i in 1..<profiles.count {
            #expect(profiles[i].gmailHeaderConcurrency >= profiles[i - 1].gmailHeaderConcurrency)
        }
    }

    @Test("Body fetch batch sizes increase with aggression")
    func bodyFetchIncreases() {
        let profiles: [BackfillProfile] = [.low, .normal, .aggressive, .turbo]
        for i in 1..<profiles.count {
            #expect(profiles[i].bodyFetchChunkSize >= profiles[i - 1].bodyFetchChunkSize)
        }
    }

    @Test("Low profile is most conservative")
    func lowIsMostConservative() {
        #expect(BackfillProfile.low.backfillChunkSize <= BackfillProfile.normal.backfillChunkSize)
        #expect(BackfillProfile.low.imapInterBatchDelay >= BackfillProfile.normal.imapInterBatchDelay)
    }

    @Test("Gmail inter-fetch delays decrease with aggression")
    func gmailInterFetchDelaysDecrease() {
        let profiles: [BackfillProfile] = [.low, .normal, .aggressive, .turbo]
        for i in 1..<profiles.count {
            #expect(profiles[i].gmailInterFetchDelay <= profiles[i - 1].gmailInterFetchDelay)
        }
    }

    @Test("Gmail inter-fetch delay values are correct")
    func gmailInterFetchDelayValues() {
        #expect(BackfillProfile.low.gmailInterFetchDelay == 1.0)
        #expect(BackfillProfile.normal.gmailInterFetchDelay == 0.5)
        #expect(BackfillProfile.aggressive.gmailInterFetchDelay == 0.1)
        #expect(BackfillProfile.turbo.gmailInterFetchDelay == 0)
    }

    @Test("Turbo has zero gmail inter-fetch delay")
    func turboZeroGmailInterFetchDelay() {
        #expect(BackfillProfile.turbo.gmailInterFetchDelay == 0)
    }
}
