/* This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at https://mozilla.org/MPL/2.0/. */

import Testing
import Foundation
@testable import TabMail

@Suite("SyncConfig Constants")
struct SyncConfigConstantsTests {

    // MARK: - Exact Value Tests (prevent accidental changes to critical tuning params)

    @Test("syncMessageLimit is 50")
    func syncMessageLimitValue() {
        #expect(SyncConfig.syncMessageLimit == 50)
    }

    @Test("inboxPageSize is 50")
    func inboxPageSizeValue() {
        #expect(SyncConfig.inboxPageSize == 50)
    }

    @Test("bodyFetchChunkSize is 20")
    func bodyFetchChunkSizeValue() {
        #expect(SyncConfig.bodyFetchChunkSize == 20)
    }

    @Test("bodyFetchConcurrency is 10")
    func bodyFetchConcurrencyValue() {
        #expect(SyncConfig.bodyFetchConcurrency == 10)
    }

    // bodyRenderConcurrency removed

    @Test("maxQueueRetries is 3")
    func maxQueueRetriesValue() {
        #expect(SyncConfig.maxQueueRetries == 3)
    }

    @Test("maxConcurrentLLMCalls is 32 (matches TB maxAgentWorkers)")
    func maxConcurrentLLMCallsValue() {
        #expect(SyncConfig.maxConcurrentLLMCalls == 32)
    }

    @Test("backfillChunkSize is 500")
    func backfillChunkSizeValue() {
        #expect(SyncConfig.backfillChunkSize == 500)
    }

    @Test("pruneChunkSize is 50")
    func pruneChunkSizeValue() {
        #expect(SyncConfig.pruneChunkSize == 50)
    }

    @Test("ftsIndexBatchSize is 200")
    func ftsIndexBatchSizeValue() {
        #expect(SyncConfig.ftsIndexBatchSize == 200)
    }

    @Test("ftsBodyYieldInterval is 50")
    func ftsBodyYieldIntervalValue() {
        #expect(SyncConfig.ftsBodyYieldInterval == 50)
    }

    @Test("ftsWriteBatchSize is 50")
    func ftsWriteBatchSizeValue() {
        #expect(SyncConfig.ftsWriteBatchSize == 50)
    }

    @Test("embeddingBatchSize is 50")
    func embeddingBatchSizeValue() {
        #expect(SyncConfig.embeddingBatchSize == 50)
    }

    @Test("snippetOnDemandChunkSize is 15")
    func snippetOnDemandChunkSizeValue() {
        #expect(SyncConfig.snippetOnDemandChunkSize == 15)
    }

    @Test("snippetPrefetchLookahead is 30")
    func snippetPrefetchLookaheadValue() {
        #expect(SyncConfig.snippetPrefetchLookahead == 30)
    }

    @Test("maxLoadedMessages is 500")
    func maxLoadedMessagesValue() {
        #expect(SyncConfig.maxLoadedMessages == 500)
    }

    @Test("gmailBackfillIdCap is 1_000_000")
    func gmailBackfillIdCapValue() {
        #expect(SyncConfig.gmailBackfillIdCap == 1_000_000)
    }

    @Test("bodyCacheTTLHours is 72")
    func bodyCacheTTLHoursValue() {
        #expect(SyncConfig.bodyCacheTTLHours == 72)
    }

    @Test("bodyCacheRecentPerFolder is 50")
    func bodyCacheRecentPerFolderValue() {
        #expect(SyncConfig.bodyCacheRecentPerFolder == 50)
    }

    @Test("replyTTLSeconds is 604800 (1 week)")
    func replyTTLSecondsValue() {
        #expect(SyncConfig.replyTTLSeconds == 604_800)
    }

    @Test("aiCacheTTLDays is 7")
    func aiCacheTTLDaysValue() {
        #expect(SyncConfig.aiCacheTTLDays == 7)
    }

    @Test("threadQueryLimit is 100")
    func threadQueryLimitValue() {
        #expect(SyncConfig.threadQueryLimit == 100)
    }

    @Test("maxInlineImages is 20")
    func maxInlineImagesValue() {
        #expect(SyncConfig.maxInlineImages == 20)
    }

    @Test("maxInlineImageBytes is 1_000_000 (1 MB)")
    func maxInlineImageBytesValue() {
        #expect(SyncConfig.maxInlineImageBytes == 1_000_000)
    }

    @Test("undoStackMaxSize is 20")
    func undoStackMaxSizeValue() {
        #expect(SyncConfig.undoStackMaxSize == 20)
    }

    @Test("bodyFetchRepopulateLimit is 500")
    func bodyFetchRepopulateLimitValue() {
        #expect(SyncConfig.bodyFetchRepopulateLimit == 500)
    }

    @Test("unreadRecountDebounceSeconds is 0.2")
    func unreadRecountDebounceSecondsValue() {
        #expect(SyncConfig.unreadRecountDebounceSeconds == 0.2)
    }

    // MARK: - Timeout Exact Values

    @Test("connectTimeoutSeconds is 15")
    func connectTimeoutValue() {
        #expect(SyncConfig.connectTimeoutSeconds == 15)
    }

    @Test("perAccountSyncTimeoutSeconds is 60")
    func perAccountSyncTimeoutValue() {
        #expect(SyncConfig.perAccountSyncTimeoutSeconds == 60)
    }

    @Test("wifiCheckTimeoutSeconds is 5")
    func wifiCheckTimeoutValue() {
        #expect(SyncConfig.wifiCheckTimeoutSeconds == 5)
    }

    @Test("backgroundPerAccountTimeoutSeconds is 10")
    func backgroundPerAccountTimeoutValue() {
        #expect(SyncConfig.backgroundPerAccountTimeoutSeconds == 10)
    }

    @Test("imapLockTimeoutSeconds is 30")
    func imapLockTimeoutValue() {
        #expect(SyncConfig.imapLockTimeoutSeconds == 30)
    }

    @Test("imapBatchOperationTimeoutSeconds is 30")
    func imapBatchOperationTimeoutValue() {
        #expect(SyncConfig.imapBatchOperationTimeoutSeconds == 30)
    }

    @Test("smtpSendTimeoutSeconds is 30")
    func smtpSendTimeoutValue() {
        #expect(SyncConfig.smtpSendTimeoutSeconds == 30)
    }

    @Test("pendingOperationTimeoutSeconds is 15")
    func pendingOperationTimeoutValue() {
        #expect(SyncConfig.pendingOperationTimeoutSeconds == 15)
    }

    // MARK: - IMAP Connection Pool Exact Values

    @Test("imapPoolLivenessCheckSeconds is 120")
    func imapPoolLivenessCheckValue() {
        #expect(SyncConfig.imapPoolLivenessCheckSeconds == 120)
    }

    @Test("imapPoolIdlePruneSeconds is 300")
    func imapPoolIdlePruneValue() {
        #expect(SyncConfig.imapPoolIdlePruneSeconds == 300)
    }

    @Test("imapPoolMinIdleConnections is 1")
    func imapPoolMinIdleValue() {
        #expect(SyncConfig.imapPoolMinIdleConnections == 1)
    }

    @Test("imapMaxConnectionCeiling is 20")
    func imapMaxConnectionCeilingValue() {
        #expect(SyncConfig.imapMaxConnectionCeiling == 20)
    }

    // MARK: - Relationship Tests

    @Test("snippetPrefetchLookahead >= snippetOnDemandChunkSize")
    func prefetchLookaheadCoversChunk() {
        #expect(SyncConfig.snippetPrefetchLookahead >= SyncConfig.snippetOnDemandChunkSize)
    }

    @Test("maxLoadedMessages is a multiple of inboxPageSize")
    func maxLoadedIsMultipleOfPageSize() {
        #expect(SyncConfig.maxLoadedMessages % SyncConfig.inboxPageSize == 0)
    }

    // bodyRenderConcurrency constraint test removed (member no longer exists)

    @Test("imapPoolLivenessCheck < imapPoolIdlePrune (check before prune)")
    func poolLivenessBeforePrune() {
        #expect(SyncConfig.imapPoolLivenessCheckSeconds < SyncConfig.imapPoolIdlePruneSeconds)
    }

    @Test("imapMaxConnectionCeiling is reasonable (10-50)")
    func poolCeilingReasonable() {
        #expect(SyncConfig.imapMaxConnectionCeiling >= 10)
        #expect(SyncConfig.imapMaxConnectionCeiling <= 50)
    }

    @Test("replyTTLSeconds equals exactly 7 days")
    func replyTTLIsOneWeek() {
        #expect(SyncConfig.replyTTLSeconds == 7 * 24 * 60 * 60)
    }

    @Test("ftsWriteBatchSize == ftsBodyYieldInterval")
    func ftsWriteAndYieldMatch() {
        #expect(SyncConfig.ftsWriteBatchSize == SyncConfig.ftsBodyYieldInterval)
    }

    @Test("bodyFetchRepopulateLimit == backfillChunkSize")
    func bodyFetchRepopulateMatchesBackfill() {
        #expect(SyncConfig.bodyFetchRepopulateLimit == SyncConfig.backfillChunkSize)
    }

    @Test("perAccountSyncTimeout > connectTimeout")
    func syncTimeoutExceedsConnect() {
        #expect(SyncConfig.perAccountSyncTimeoutSeconds > SyncConfig.connectTimeoutSeconds)
    }

    @Test("wifiCheckTimeout < connectTimeout")
    func wifiCheckShorterThanConnect() {
        #expect(SyncConfig.wifiCheckTimeoutSeconds < SyncConfig.connectTimeoutSeconds)
    }
}
