/* This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at https://mozilla.org/MPL/2.0/. */

import Testing
import Foundation
@testable import TabMail

@Suite("SyncConfig")
struct SyncConfigTests {

    @Test("All chunk sizes are positive")
    func chunkSizesPositive() {
        #expect(SyncConfig.syncMessageLimit > 0)
        #expect(SyncConfig.inboxPageSize > 0)
        #expect(SyncConfig.bodyFetchChunkSize > 0)
        #expect(SyncConfig.bodyFetchConcurrency > 0)
        #expect(SyncConfig.maxQueueRetries > 0)
        #expect(SyncConfig.maxConcurrentLLMCalls > 0)
        #expect(SyncConfig.backfillChunkSize > 0)
        #expect(SyncConfig.pruneChunkSize > 0)
        #expect(SyncConfig.ftsIndexBatchSize > 0)
        #expect(SyncConfig.embeddingBatchSize > 0)
        #expect(SyncConfig.snippetOnDemandChunkSize > 0)
        #expect(SyncConfig.maxLoadedMessages > 0)
    }

    @Test("TTL values are reasonable")
    func ttlValues() {
        #expect(SyncConfig.bodyCacheTTLHours >= 1)
        #expect(SyncConfig.replyTTLSeconds > 0)
        #expect(SyncConfig.aiCacheTTLDays >= 1)
    }

    @Test("Timeout values are positive")
    func timeoutsPositive() {
        #expect(SyncConfig.connectTimeoutSeconds > 0)
        #expect(SyncConfig.perAccountSyncTimeoutSeconds > 0)
        #expect(SyncConfig.imapLockTimeoutSeconds > 0)
        #expect(SyncConfig.smtpSendTimeoutSeconds > 0)
        #expect(SyncConfig.pendingOperationTimeoutSeconds > 0)
        #expect(SyncConfig.backgroundPerAccountTimeoutSeconds > 0)
    }

    @Test("Undo stack has reasonable size")
    func undoStackSize() {
        #expect(SyncConfig.undoStackMaxSize >= 5)
        #expect(SyncConfig.undoStackMaxSize <= 100)
    }

    @Test("Gmail backfill ID cap is bounded")
    func gmailBackfillIdCap() {
        #expect(SyncConfig.gmailBackfillIdCap > 0)
        #expect(SyncConfig.gmailBackfillIdCap <= 10_000_000)
    }

    @Test("Max inline images bounded")
    func maxInlineImages() {
        #expect(SyncConfig.maxInlineImages > 0)
        #expect(SyncConfig.maxInlineImageBytes > 0)
    }

    @Test("Large inbox management constants are positive and reasonable")
    func largeInboxManagement() {
        #expect(SyncConfig.maxRecentEmails > 0)
        #expect(SyncConfig.maxRecentEmails <= 1000)
        #expect(SyncConfig.archiveAgeDays > 0)
        #expect(SyncConfig.archiveAgeDays <= 90)
    }
}

@Suite("BackfillProfile")
struct BackfillProfileTests {

    @Test("All profiles return positive backfillChunkSize")
    func backfillChunkSize() {
        let profiles: [BackfillProfile] = [.low, .normal, .aggressive, .turbo]
        for profile in profiles {
            #expect(profile.backfillChunkSize > 0)
        }
    }

    @Test("Profiles are ordered by throughput: low < normal < aggressive < turbo")
    func profileOrdering() {
        #expect(BackfillProfile.low.backfillChunkSize < BackfillProfile.normal.backfillChunkSize)
        #expect(BackfillProfile.normal.backfillChunkSize < BackfillProfile.aggressive.backfillChunkSize)
        #expect(BackfillProfile.aggressive.backfillChunkSize <= BackfillProfile.turbo.backfillChunkSize)
    }

    @Test("IMAP fetch batch sizes increase with profile")
    func imapFetchBatchOrdering() {
        #expect(BackfillProfile.low.imapFetchBatchSize <= BackfillProfile.normal.imapFetchBatchSize)
        #expect(BackfillProfile.normal.imapFetchBatchSize <= BackfillProfile.aggressive.imapFetchBatchSize)
        #expect(BackfillProfile.aggressive.imapFetchBatchSize <= BackfillProfile.turbo.imapFetchBatchSize)
    }

    @Test("Inter-batch delays decrease with profile")
    func interBatchDelayOrdering() {
        #expect(BackfillProfile.low.imapInterBatchDelay >= BackfillProfile.normal.imapInterBatchDelay)
        #expect(BackfillProfile.normal.imapInterBatchDelay >= BackfillProfile.aggressive.imapInterBatchDelay)
        #expect(BackfillProfile.aggressive.imapInterBatchDelay >= BackfillProfile.turbo.imapInterBatchDelay)
    }

    @Test("Turbo has zero or minimal delays")
    func turboMinimalDelays() {
        #expect(BackfillProfile.turbo.imapInterBatchDelay == 0)
        #expect(BackfillProfile.turbo.deepCrawlInterWindowDelay == 0)
        #expect(BackfillProfile.turbo.interFolderDelay == 0)
        #expect(BackfillProfile.turbo.interCycleActiveDelay == 0)
    }

    @Test("Gmail concurrency increases with profile")
    func gmailConcurrency() {
        #expect(BackfillProfile.low.gmailHeaderConcurrency < BackfillProfile.turbo.gmailHeaderConcurrency)
    }

    @Test("IMAP body concurrency increases with profile")
    func imapBodyConcurrency() {
        #expect(BackfillProfile.low.imapBodyConcurrency < BackfillProfile.turbo.imapBodyConcurrency)
    }

    @Test("Gmail body concurrency increases with profile")
    func gmailBodyConcurrency() {
        #expect(BackfillProfile.low.gmailBodyConcurrency < BackfillProfile.turbo.gmailBodyConcurrency)
    }

    @Test("Low profile has non-zero delays for thermal throttling")
    func lowProfileDelays() {
        #expect(BackfillProfile.low.imapInterBatchDelay > 0)
        #expect(BackfillProfile.low.interFolderDelay > 0)
        #expect(BackfillProfile.low.interCycleActiveDelay > 0)
        #expect(BackfillProfile.low.interCycleIdleDelay > 0)
    }
}
