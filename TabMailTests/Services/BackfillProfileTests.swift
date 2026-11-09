/* This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at https://mozilla.org/MPL/2.0/. */

import Testing
import Foundation
@testable import TabMail

@Suite("BackfillProfile Body Concurrency")
struct BackfillProfileBodyTests {

    @Test("Body fetch chunk sizes increase with profile")
    func bodyFetchChunkSizeOrdering() {
        #expect(BackfillProfile.low.bodyFetchChunkSize <= BackfillProfile.normal.bodyFetchChunkSize)
        #expect(BackfillProfile.normal.bodyFetchChunkSize <= BackfillProfile.aggressive.bodyFetchChunkSize)
    }

    @Test("IMAP body fetch batch sizes increase with profile")
    func imapBodyFetchBatchOrdering() {
        #expect(BackfillProfile.low.imapBodyFetchBatchSize <= BackfillProfile.normal.imapBodyFetchBatchSize)
        #expect(BackfillProfile.normal.imapBodyFetchBatchSize <= BackfillProfile.aggressive.imapBodyFetchBatchSize)
        #expect(BackfillProfile.aggressive.imapBodyFetchBatchSize <= BackfillProfile.turbo.imapBodyFetchBatchSize)
    }

    @Test("Inter-cycle idle delay > active delay for all profiles")
    func idleDelayGreaterThanActive() {
        let profiles: [BackfillProfile] = [.low, .normal, .aggressive]
        for profile in profiles {
            #expect(profile.interCycleIdleDelay >= profile.interCycleActiveDelay)
        }
    }
}

@Suite("BackfillProfile Chunk Sizes")
struct BackfillProfileChunkSizeTests {

    @Test("backfillChunkSize non-decreasing across profiles (turbo caps at aggressive due to diminishing returns)")
    func chunkSizeNonDecreasing() {
        #expect(BackfillProfile.low.backfillChunkSize < BackfillProfile.normal.backfillChunkSize)
        #expect(BackfillProfile.normal.backfillChunkSize < BackfillProfile.aggressive.backfillChunkSize)
        #expect(BackfillProfile.aggressive.backfillChunkSize <= BackfillProfile.turbo.backfillChunkSize)
    }

    @Test("imapFetchBatchSize strictly increases across profiles")
    func imapBatchStrictlyIncreases() {
        #expect(BackfillProfile.low.imapFetchBatchSize < BackfillProfile.normal.imapFetchBatchSize)
        #expect(BackfillProfile.normal.imapFetchBatchSize < BackfillProfile.aggressive.imapFetchBatchSize)
        #expect(BackfillProfile.aggressive.imapFetchBatchSize < BackfillProfile.turbo.imapFetchBatchSize)
    }

    @Test("All chunk sizes are positive")
    func allChunkSizesPositive() {
        for p in [BackfillProfile.low, .normal, .aggressive, .turbo] {
            #expect(p.backfillChunkSize > 0)
            #expect(p.imapFetchBatchSize > 0)
            #expect(p.bodyFetchChunkSize > 0)
            #expect(p.imapBodyFetchBatchSize > 0)
        }
    }
}

@Suite("BackfillProfile Delays")
struct BackfillProfileDelayTests {

    @Test("imapInterBatchDelay decreases across profiles")
    func imapDelayDecreases() {
        #expect(BackfillProfile.low.imapInterBatchDelay > BackfillProfile.normal.imapInterBatchDelay)
        #expect(BackfillProfile.normal.imapInterBatchDelay > BackfillProfile.aggressive.imapInterBatchDelay)
        #expect(BackfillProfile.aggressive.imapInterBatchDelay > BackfillProfile.turbo.imapInterBatchDelay)
    }

    @Test("turbo has zero delays")
    func turboZeroDelays() {
        #expect(BackfillProfile.turbo.imapInterBatchDelay == 0)
        #expect(BackfillProfile.turbo.interFolderDelay == 0)
        #expect(BackfillProfile.turbo.interCycleActiveDelay == 0)
    }

    @Test("low profile delays are non-negative")
    func lowDelaysNonNegative() {
        let p = BackfillProfile.low
        #expect(p.imapInterBatchDelay >= 0)
        #expect(p.interFolderDelay >= 0)
        #expect(p.interCycleActiveDelay >= 0)
        #expect(p.interCycleIdleDelay >= 0)
    }

    @Test("interCycleIdleDelay decreases across profiles")
    func idleDelayDecreases() {
        #expect(BackfillProfile.low.interCycleIdleDelay > BackfillProfile.normal.interCycleIdleDelay)
        #expect(BackfillProfile.normal.interCycleIdleDelay > BackfillProfile.aggressive.interCycleIdleDelay)
        #expect(BackfillProfile.aggressive.interCycleIdleDelay > BackfillProfile.turbo.interCycleIdleDelay)
    }
}

@Suite("BackfillProfile Concurrency")
struct BackfillProfileConcurrencyTests {

    @Test("gmailHeaderConcurrency increases across profiles")
    func gmailConcurrencyIncreases() {
        #expect(BackfillProfile.low.gmailHeaderConcurrency < BackfillProfile.normal.gmailHeaderConcurrency)
        #expect(BackfillProfile.normal.gmailHeaderConcurrency < BackfillProfile.aggressive.gmailHeaderConcurrency)
        #expect(BackfillProfile.aggressive.gmailHeaderConcurrency < BackfillProfile.turbo.gmailHeaderConcurrency)
    }

    @Test("imapBodyConcurrency increases across profiles")
    func imapBodyConcurrencyIncreases() {
        #expect(BackfillProfile.low.imapBodyConcurrency < BackfillProfile.normal.imapBodyConcurrency)
        #expect(BackfillProfile.normal.imapBodyConcurrency < BackfillProfile.aggressive.imapBodyConcurrency)
        #expect(BackfillProfile.aggressive.imapBodyConcurrency < BackfillProfile.turbo.imapBodyConcurrency)
    }

    @Test("gmailBodyConcurrency increases across profiles")
    func gmailBodyConcurrencyIncreases() {
        #expect(BackfillProfile.low.gmailBodyConcurrency < BackfillProfile.normal.gmailBodyConcurrency)
        #expect(BackfillProfile.normal.gmailBodyConcurrency < BackfillProfile.aggressive.gmailBodyConcurrency)
        #expect(BackfillProfile.aggressive.gmailBodyConcurrency <= BackfillProfile.turbo.gmailBodyConcurrency)
    }

    @Test("low profile has single IMAP connection")
    func lowSingleConnection() {
        #expect(BackfillProfile.low.imapBodyConcurrency == 1)
    }

    @Test("All concurrency values are at least 1")
    func allConcurrencyAtLeast1() {
        for p in [BackfillProfile.low, .normal, .aggressive, .turbo] {
            #expect(p.gmailHeaderConcurrency >= 1)
            #expect(p.imapBodyConcurrency >= 1)
            #expect(p.gmailBodyConcurrency >= 1)
        }
    }
}

@Suite("BackfillProfile Normal Defaults")
struct BackfillProfileNormalDefaultTests {

    @Test("normal profile regression values")
    func normalDefaults() {
        let p = BackfillProfile.normal
        #expect(p.backfillChunkSize == 500)
        #expect(p.imapFetchBatchSize == 100)
        #expect(p.imapInterBatchDelay == 0.5)
        #expect(p.bodyFetchChunkSize == 50)
        #expect(p.imapBodyFetchBatchSize == 10)
        #expect(p.imapBodyConcurrency == 4)
        #expect(p.gmailBodyConcurrency == 10)
    }

    @Test("low profile regression values")
    func lowDefaults() {
        let p = BackfillProfile.low
        #expect(p.backfillChunkSize == 200)
        #expect(p.imapFetchBatchSize == 50)
        #expect(p.imapInterBatchDelay == 1.0)
        #expect(p.imapBodyConcurrency == 1)
        #expect(p.gmailBodyConcurrency == 3)
    }
}

@Suite("StorageEstimator Constants")
struct StorageEstimatorConstantsTests {

    @Test("floorPerFolder is 50")
    func floorPerFolder() {
        #expect(StorageEstimator.floorPerFolder == 50)
    }

    @Test("storageBudgetKey is stable")
    func budgetKey() {
        #expect(StorageEstimator.storageBudgetKey == "globalStorageBudgetMB")
    }

    @Test("defaultBudgetMB is unlimited (Int.max)")
    func defaultBudget() {
        #expect(StorageEstimator.defaultBudgetMB == Int.max)
    }

    @Test("totalSizeMB returns non-negative value")
    func totalSizeNonNegative() {
        let size = StorageEstimator.totalSizeMB()
        #expect(size >= 0)
    }

    @Test("isOverBudget returns false with unlimited budget")
    func notOverBudgetWithUnlimited() {
        #expect(StorageEstimator.isOverBudget() == false)
    }
}
