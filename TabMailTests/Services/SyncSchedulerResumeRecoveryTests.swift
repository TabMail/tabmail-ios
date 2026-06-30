/* This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at https://mozilla.org/MPL/2.0/. */

import Testing
import Foundation
@testable import TabMail

/// Foreground-push suspension-recovery decision (`SyncScheduler.shouldRunResumeRecovery`).
///
/// Background: a foreground new-mail push used to run the full suspension-recovery path
/// (`cancelAllInFlightQueues` + `markAllProvidersDirty`) on EVERY push while the app was
/// active, cancelling healthy in-flight AI LLM calls (forcing recompute) and firing
/// spurious DeviceSync reconnects. The fix gates recovery on this pure decision.
///
/// SAFETY INVARIANT under test: the default is ALWAYS recover; a foreground fast-path may
/// skip recovery ONLY when the app is provably continuous-foreground (active now AND not
/// backgrounded since the last recovery). Over-cancelling is safe; under-cancelling leaves
/// frozen tasks on dead sockets / races GRDB suspension and crashes — so every uncertain
/// combination MUST recover.
@Suite("SyncScheduler resume-recovery decision")
struct SyncSchedulerResumeRecoveryTests {

    @Test("Non-fast-path callers ALWAYS recover (genuine resume + all BG entry points)")
    func nonFastPathAlwaysRecovers() {
        // app-state / background flag are irrelevant when foregroundFastPath == false:
        // startForegroundPolling, BGAppRefresh, BGProcessing must never skip the cancel.
        for active in [true, false] {
            for bg in [true, false] {
                #expect(SyncScheduler.shouldRunResumeRecovery(
                    foregroundFastPath: false,
                    appIsActive: active,
                    backgroundedSinceRecovery: bg) == true)
            }
        }
    }

    @Test("Fast-path SKIPS recovery only when continuous-foreground (active AND no bg)")
    func fastPathSkipsOnlyWhenContinuousForeground() {
        #expect(SyncScheduler.shouldRunResumeRecovery(
            foregroundFastPath: true,
            appIsActive: true,
            backgroundedSinceRecovery: false) == false)
    }

    @Test("Fast-path RECOVERS when app is not active (push woke us from background)")
    func fastPathRecoversWhenNotActive() {
        #expect(SyncScheduler.shouldRunResumeRecovery(
            foregroundFastPath: true,
            appIsActive: false,
            backgroundedSinceRecovery: false) == true)
        #expect(SyncScheduler.shouldRunResumeRecovery(
            foregroundFastPath: true,
            appIsActive: false,
            backgroundedSinceRecovery: true) == true)
    }

    @Test("Fast-path RECOVERS when backgrounded since last recovery (suspension possible)")
    func fastPathRecoversAfterBackgrounding() {
        // Active NOW, but we passed through background since the last recovery → connections
        // may be stale → must cancel. This is the case that protects against under-cancelling.
        #expect(SyncScheduler.shouldRunResumeRecovery(
            foregroundFastPath: true,
            appIsActive: true,
            backgroundedSinceRecovery: true) == true)
    }

    @Test("Exhaustive: exactly ONE of the 8 combinations is allowed to skip")
    func onlyContinuousForegroundMaySkip() {
        var skipCount = 0
        for fast in [true, false] {
            for active in [true, false] {
                for bg in [true, false] {
                    let recover = SyncScheduler.shouldRunResumeRecovery(
                        foregroundFastPath: fast,
                        appIsActive: active,
                        backgroundedSinceRecovery: bg)
                    if !recover {
                        skipCount += 1
                        // The only legal skip: fast-path + active + not-backgrounded.
                        #expect(fast == true && active == true && bg == false)
                    }
                }
            }
        }
        #expect(skipCount == 1)
    }
}

/// `ActiveAIQueue.logId` — message-discriminating log id.
///
/// Regression: a `headerId` is `"accountId:folder:messageId"` and the accountId is a
/// 36-char UUID, so the old `headerId.prefix(30)` never reached the messageId and printed
/// the SAME string for every message in an account. Distinct messages looked like one
/// message processed repeatedly — the exact trap that read as a "double LLM call" bug.
@Suite("ActiveAIQueue.logId message discrimination")
struct ActiveAIQueueLogIdTests {

    private static let account = "4F6C94FE-EACD-467F-A967-BD6D2E7674D4"

    @Test("Distinct messages in the SAME account get distinct log ids")
    func distinctMessagesSameAccountDiffer() {
        let a = ActiveAIQueue.logId("\(Self.account):INBOX:0100019f17bfe021-50b07790@email.amazonses.com")
        let b = ActiveAIQueue.logId("\(Self.account):INBOX:19f17a90d7ed26fe")
        #expect(a != b)
    }

    @Test("Guards against regressing to prefix(30) (which collapsed same-account messages)")
    func prefix30WouldHaveCollapsed() {
        let id1 = "\(Self.account):INBOX:msg-one"
        let id2 = "\(Self.account):INBOX:msg-two"
        // The old behaviour: prefix(30) is identical for both (lands inside the account UUID).
        #expect(String(id1.prefix(30)) == String(id2.prefix(30)))
        // The fix: logId distinguishes them.
        #expect(ActiveAIQueue.logId(id1) != ActiveAIQueue.logId(id2))
    }

    @Test("logId carries both the account head and the message tail")
    func logIdContainsAccountAndMessage() {
        let out = ActiveAIQueue.logId("\(Self.account):INBOX:uniqueMessageTail123")
        #expect(out.contains("4F6C94FE"))             // account head, for context
        #expect(out.contains("uniqueMessageTail123"))  // message tail, the discriminator
    }

    @Test("Handles ids without folder:message structure without crashing")
    func logIdFallback() {
        let out = ActiveAIQueue.logId("noColonsHere")
        #expect(!out.isEmpty)
    }
}
