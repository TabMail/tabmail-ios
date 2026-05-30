/* This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at https://mozilla.org/MPL/2.0/. */

import Testing
import UserNotifications
@testable import TabMail

struct NotificationCleanupServiceTests {

    // MARK: - Helpers

    private func snap(
        id: String,
        secondsAgo: TimeInterval,
        level: UNNotificationInterruptionLevel = .active,
        provider: String? = nil,
        accountEmail: String? = nil,
        reconnectState: String? = nil,
        relativeTo now: Date
    ) -> DeliveredNotificationSnapshot {
        DeliveredNotificationSnapshot(
            identifier: id,
            date: now.addingTimeInterval(-secondsAgo),
            interruptionLevel: level,
            providerTag: provider,
            accountEmail: accountEmail,
            reconnectState: reconnectState
        )
    }

    private let now = Date()
    private let noPushHealth: [String: Date] = [:]

    // MARK: - Active bucket

    @Test func activeUnderTTL_keptInBothModes() {
        let s = snap(id: "a", secondsAgo: 60, level: .active, relativeTo: now)
        #expect(NotificationCleanupService.identifiersToRemove([s], now: now, passiveAllAges: false, lastNonReconnectPushAt: noPushHealth).isEmpty)
        #expect(NotificationCleanupService.identifiersToRemove([s], now: now, passiveAllAges: true, lastNonReconnectPushAt: noPushHealth).isEmpty)
    }

    @Test func activeOverTTL_removedInBothModes() {
        let s = snap(id: "a", secondsAgo: NotificationCleanupConfig.activeTTLSeconds + 1, level: .active, relativeTo: now)
        #expect(NotificationCleanupService.identifiersToRemove([s], now: now, passiveAllAges: false, lastNonReconnectPushAt: noPushHealth) == ["a"])
        #expect(NotificationCleanupService.identifiersToRemove([s], now: now, passiveAllAges: true, lastNonReconnectPushAt: noPushHealth) == ["a"])
    }

    @Test func activeAtExactTTLBoundary_removed() {
        let s = snap(id: "edge", secondsAgo: NotificationCleanupConfig.activeTTLSeconds, level: .active, relativeTo: now)
        #expect(NotificationCleanupService.identifiersToRemove([s], now: now, passiveAllAges: false, lastNonReconnectPushAt: noPushHealth) == ["edge"])
    }

    // MARK: - Passive bucket

    @Test func passiveUnderTTL_keptInTimeMode_removedInForegroundMode() {
        let s = snap(id: "p", secondsAgo: 60, level: .passive, relativeTo: now)
        #expect(NotificationCleanupService.identifiersToRemove([s], now: now, passiveAllAges: false, lastNonReconnectPushAt: noPushHealth).isEmpty)
        #expect(NotificationCleanupService.identifiersToRemove([s], now: now, passiveAllAges: true, lastNonReconnectPushAt: noPushHealth) == ["p"])
    }

    @Test func passiveOverTTL_removedInBothModes() {
        let s = snap(id: "p", secondsAgo: NotificationCleanupConfig.passiveTTLSeconds + 1, level: .passive, relativeTo: now)
        #expect(NotificationCleanupService.identifiersToRemove([s], now: now, passiveAllAges: false, lastNonReconnectPushAt: noPushHealth) == ["p"])
        #expect(NotificationCleanupService.identifiersToRemove([s], now: now, passiveAllAges: true, lastNonReconnectPushAt: noPushHealth) == ["p"])
    }

    // MARK: - Denylist: consent_error

    @Test func consentErrorActive_neverRemoved_evenWhenAged() {
        let s = snap(id: "c", secondsAgo: 999_999, level: .active, provider: "consent_error", relativeTo: now)
        #expect(NotificationCleanupService.identifiersToRemove([s], now: now, passiveAllAges: false, lastNonReconnectPushAt: noPushHealth).isEmpty)
        #expect(NotificationCleanupService.identifiersToRemove([s], now: now, passiveAllAges: true, lastNonReconnectPushAt: noPushHealth).isEmpty)
    }

    @Test func consentErrorPassive_neverRemoved_evenOnForeground() {
        let s = snap(id: "c", secondsAgo: 60, level: .passive, provider: "consent_error", relativeTo: now)
        #expect(NotificationCleanupService.identifiersToRemove([s], now: now, passiveAllAges: true, lastNonReconnectPushAt: noPushHealth).isEmpty)
    }

    @Test func unknownProviderTag_treatedNormally() {
        let s = snap(id: "x", secondsAgo: NotificationCleanupConfig.activeTTLSeconds + 1, level: .active, provider: "some_future_tag", relativeTo: now)
        #expect(NotificationCleanupService.identifiersToRemove([s], now: now, passiveAllAges: false, lastNonReconnectPushAt: noPushHealth) == ["x"])
    }

    // MARK: - imap_reconnect: conditional exclusion

    @Test func reconnect_noPushHealth_kept() {
        let s = snap(id: "r", secondsAgo: NotificationCleanupConfig.activeTTLSeconds + 999,
                     level: .passive, provider: "imap_reconnect", accountEmail: "a@x.com", relativeTo: now)
        #expect(NotificationCleanupService.identifiersToRemove([s], now: now, passiveAllAges: false, lastNonReconnectPushAt: noPushHealth).isEmpty)
        #expect(NotificationCleanupService.identifiersToRemove([s], now: now, passiveAllAges: true, lastNonReconnectPushAt: noPushHealth).isEmpty)
    }

    @Test func reconnect_pushHealthOlderThanNotification_kept() {
        // Real push BEFORE this reconnect — doesn't prove current reconnect succeeded.
        let priorPush = now.addingTimeInterval(-300)
        let s = snap(id: "r", secondsAgo: 60, level: .passive, provider: "imap_reconnect",
                     accountEmail: "a@x.com", relativeTo: now)
        let health = ["a@x.com": priorPush]
        #expect(NotificationCleanupService.identifiersToRemove([s], now: now, passiveAllAges: true, lastNonReconnectPushAt: health).isEmpty)
    }

    @Test func reconnect_pushHealthAfterNotification_swept() {
        // Reconnect 5 min ago, real push 60s ago → push restored AFTER reconnect.
        let s = snap(id: "r", secondsAgo: 300, level: .passive, provider: "imap_reconnect",
                     accountEmail: "a@x.com", relativeTo: now)
        let realPushAt = now.addingTimeInterval(-60)
        let health = ["a@x.com": realPushAt]
        // Time-mode: exclusion released, but reconnect is 5min < 1h TTL → still kept.
        #expect(NotificationCleanupService.identifiersToRemove([s], now: now, passiveAllAges: false, lastNonReconnectPushAt: health).isEmpty)
        // FG-mode: exclusion released + passiveAllAges → swept.
        #expect(NotificationCleanupService.identifiersToRemove([s], now: now, passiveAllAges: true, lastNonReconnectPushAt: health) == ["r"])
    }

    @Test func reconnect_aged_pushHealthFresh_swept() {
        let s = snap(id: "r", secondsAgo: NotificationCleanupConfig.passiveTTLSeconds + 1,
                     level: .passive, provider: "imap_reconnect",
                     accountEmail: "a@x.com", relativeTo: now)
        let realPushAt = now.addingTimeInterval(-60)
        let health = ["a@x.com": realPushAt]
        #expect(NotificationCleanupService.identifiersToRemove([s], now: now, passiveAllAges: false, lastNonReconnectPushAt: health) == ["r"])
        #expect(NotificationCleanupService.identifiersToRemove([s], now: now, passiveAllAges: true, lastNonReconnectPushAt: health) == ["r"])
    }

    @Test func reconnect_perAccountIsolation() {
        let s = snap(id: "rA", secondsAgo: 60, level: .passive, provider: "imap_reconnect",
                     accountEmail: "a@x.com", relativeTo: now)
        let healthB = ["b@x.com": now.addingTimeInterval(-10)]
        #expect(NotificationCleanupService.identifiersToRemove([s], now: now, passiveAllAges: true, lastNonReconnectPushAt: healthB).isEmpty)
    }

    @Test func reconnect_missingAccountEmail_kept() {
        let s = snap(id: "r", secondsAgo: 99_999, level: .passive, provider: "imap_reconnect",
                     accountEmail: nil, relativeTo: now)
        let health = ["a@x.com": now]
        #expect(NotificationCleanupService.identifiersToRemove([s], now: now, passiveAllAges: false, lastNonReconnectPushAt: health).isEmpty)
        #expect(NotificationCleanupService.identifiersToRemove([s], now: now, passiveAllAges: true, lastNonReconnectPushAt: health).isEmpty)
    }

    @Test func reconnect_successAck_treatedAsNormalActive() {
        let fresh = snap(id: "ackFresh", secondsAgo: 60, level: .passive,
                         provider: "imap_reconnect", accountEmail: "a@x.com",
                         reconnectState: "ok", relativeTo: now)
        let stale = snap(id: "ackStale", secondsAgo: NotificationCleanupConfig.activeTTLSeconds + 1,
                         level: .passive, provider: "imap_reconnect",
                         accountEmail: "a@x.com", reconnectState: "ok", relativeTo: now)
        // Time-mode: fresh kept, stale swept (no PushHealthStore involvement).
        #expect(NotificationCleanupService.identifiersToRemove([fresh, stale], now: now, passiveAllAges: false, lastNonReconnectPushAt: noPushHealth) == ["ackStale"])
        // FG-mode: success-ack delivered as .passive → both swept (passiveAllAges).
        #expect(Set(NotificationCleanupService.identifiersToRemove([fresh, stale], now: now, passiveAllAges: true, lastNonReconnectPushAt: noPushHealth)) == Set(["ackFresh", "ackStale"]))
    }

    @Test func reconnect_finalFailureFinal_followsSameRule() {
        let s = snap(id: "rFinal", secondsAgo: 60, level: .passive, provider: "imap_reconnect",
                     accountEmail: "a@x.com", relativeTo: now)
        let healthAfter = ["a@x.com": now.addingTimeInterval(-30)]
        let healthNone: [String: Date] = [:]
        #expect(NotificationCleanupService.identifiersToRemove([s], now: now, passiveAllAges: true, lastNonReconnectPushAt: healthAfter) == ["rFinal"])
        #expect(NotificationCleanupService.identifiersToRemove([s], now: now, passiveAllAges: true, lastNonReconnectPushAt: healthNone).isEmpty)
    }

    // MARK: - Mixed sets / edge cases

    @Test func mixedSet_timeMode_onlyAgedRemoved() {
        let snaps = [
            snap(id: "active-fresh",  secondsAgo: 60,    level: .active,  relativeTo: now),
            snap(id: "active-stale",  secondsAgo: NotificationCleanupConfig.activeTTLSeconds + 1,  level: .active,  relativeTo: now),
            snap(id: "passive-fresh", secondsAgo: 60,    level: .passive, relativeTo: now),
            snap(id: "passive-stale", secondsAgo: NotificationCleanupConfig.activeTTLSeconds + 1,  level: .passive, relativeTo: now),
            snap(id: "consent-stale", secondsAgo: NotificationCleanupConfig.activeTTLSeconds + 1,  level: .active,  provider: "consent_error", relativeTo: now),
        ]
        let result = Set(NotificationCleanupService.identifiersToRemove(snaps, now: now, passiveAllAges: false, lastNonReconnectPushAt: noPushHealth))
        #expect(result == Set(["active-stale", "passive-stale"]))
    }

    @Test func mixedSet_foregroundMode_addsAllPassives() {
        let snaps = [
            snap(id: "active-fresh",  secondsAgo: 60,    level: .active,  relativeTo: now),
            snap(id: "active-stale",  secondsAgo: NotificationCleanupConfig.activeTTLSeconds + 1,  level: .active,  relativeTo: now),
            snap(id: "passive-fresh", secondsAgo: 60,    level: .passive, relativeTo: now),
            snap(id: "passive-stale", secondsAgo: NotificationCleanupConfig.activeTTLSeconds + 1,  level: .passive, relativeTo: now),
            snap(id: "consent-stale", secondsAgo: NotificationCleanupConfig.activeTTLSeconds + 1,  level: .active,  provider: "consent_error", relativeTo: now),
        ]
        let result = Set(NotificationCleanupService.identifiersToRemove(snaps, now: now, passiveAllAges: true, lastNonReconnectPushAt: noPushHealth))
        #expect(result == Set(["active-stale", "passive-fresh", "passive-stale"]))
    }

    @Test func emptySnapshot_returnsEmpty() {
        #expect(NotificationCleanupService.identifiersToRemove([], now: now, passiveAllAges: false, lastNonReconnectPushAt: noPushHealth).isEmpty)
        #expect(NotificationCleanupService.identifiersToRemove([], now: now, passiveAllAges: true, lastNonReconnectPushAt: noPushHealth).isEmpty)
    }

    @Test func futureDated_notRemoved() {
        // Defensive: clock skew → notification "in the future" must not sweep.
        let s = snap(id: "future", secondsAgo: -3600, level: .active, relativeTo: now)
        #expect(NotificationCleanupService.identifiersToRemove([s], now: now, passiveAllAges: false, lastNonReconnectPushAt: noPushHealth).isEmpty)
        #expect(NotificationCleanupService.identifiersToRemove([s], now: now, passiveAllAges: true, lastNonReconnectPushAt: noPushHealth).isEmpty)
    }
}
