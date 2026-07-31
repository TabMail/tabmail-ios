/* This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at https://mozilla.org/MPL/2.0/. */

import Testing
import Foundation
@testable import TabMail

/// Per-entry expiry semantics for `AccountManager.recentlyCompleted`.
///
/// Fixes the push-merge stale-detection race: a message that becomes durable via
/// the NSE push-merge was only ever protected for the default 30s
/// action-completion TTL, but boot-log forensics showed a transient server-fetch
/// miss can arrive MORE than 30s after the last protection refresh, stale-deleting
/// a real message. `recordRecentlyCompleted` now stores an EXPIRY date per entry
/// (not an insertion date), so the same shared map can serve two callers with
/// different TTLs: the default `SyncConfig.recentlyCompletedTTLSeconds` (30s, action
/// completion) and the longer `SyncConfig.pushMergeStaleProtectionTTLSeconds` (120s,
/// push-merge arrival — see NSEDataBridge's registration call).
@Suite("AccountManager.recentlyCompleted per-entry TTL", .processGlobalState)
struct RecentlyCompletedTTLTests {

    /// Unique key per test — `AccountManager.shared` is a live singleton shared
    /// across the whole test process (other suites also write into
    /// `recentlyCompleted`), so tests must never assert on the map's total
    /// contents, only on presence/absence of their own uniquely-named keys.
    private func uniqueKey(_ label: String) -> String {
        "\(label)-\(UUID().uuidString)"
    }

    @Test("default-TTL entry is recognized as recently completed immediately after recording")
    @MainActor
    func defaultTTLEntryIsRecent() async {
        let key = uniqueKey("default-live")

        await AccountManager.shared.recordRecentlyCompleted(messageIds: [key])

        let isRecent = await AccountManager.shared.isRecentlyCompleted(key)
        #expect(isRecent, "an entry recorded with the default TTL must be recognized as recently completed")
    }

    @Test("expired entry (negative ttl) reads as not-recent and is pruned")
    @MainActor
    func expiredEntryIsPrunedAway() async {
        let key = uniqueKey("expired")
        // ttl: -1 backdates the expiry into the past. AccountManager has no
        // injectable clock, so this is the supported way to simulate an
        // already-expired entry without sleeping in a test.
        await AccountManager.shared.recordRecentlyCompleted(messageIds: [key], ttl: -1)

        let isRecentBeforePrune = await AccountManager.shared.isRecentlyCompleted(key)
        #expect(!isRecentBeforePrune, "a negative-ttl entry must read as already expired")

        await AccountManager.shared.pruneRecentlyCompleted()

        let mapAfterPrune = await AccountManager.shared.recentlyCompleted
        #expect(mapAfterPrune[key] == nil, "pruneRecentlyCompleted must remove expired entries from the map")
    }

    @Test("long-TTL (push-merge) entry survives a prune pass and reads as recent")
    @MainActor
    func longTTLEntrySurvivesPrune() async {
        let key = uniqueKey("push-merge-live")

        await AccountManager.shared.recordRecentlyCompleted(
            messageIds: [key], ttl: SyncConfig.pushMergeStaleProtectionTTLSeconds
        )
        await AccountManager.shared.pruneRecentlyCompleted()

        let mapAfterPrune = await AccountManager.shared.recentlyCompleted
        #expect(mapAfterPrune[key] != nil, "a live 120s-TTL entry must survive pruneRecentlyCompleted")

        let isRecent = await AccountManager.shared.isRecentlyCompleted(key)
        #expect(isRecent, "a live long-TTL entry must read as recently completed")
    }

    @Test("mixed prune: expired entry removed, live entry kept")
    @MainActor
    func pruneKeepsOnlyLiveEntry() async {
        let expiredKey = uniqueKey("mixed-expired")
        let liveKey = uniqueKey("mixed-live")

        await AccountManager.shared.recordRecentlyCompleted(messageIds: [expiredKey], ttl: -1)
        await AccountManager.shared.recordRecentlyCompleted(messageIds: [liveKey]) // default TTL

        await AccountManager.shared.pruneRecentlyCompleted()

        let mapAfterPrune = await AccountManager.shared.recentlyCompleted
        #expect(mapAfterPrune[expiredKey] == nil, "the expired entry must be pruned")
        #expect(mapAfterPrune[liveKey] != nil, "the live entry must survive the same prune pass")
    }
}
