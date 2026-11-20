/* This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at https://mozilla.org/MPL/2.0/. */

import Foundation
import Testing
@testable import TabMail

/// #1064: older-mail body downloads (BackfillBodyQueue) follow the backfill walk's
/// download gates (Wi-Fi-only on an expensive network, battery below 20% off
/// power, Low Power Mode off power). ActiveBodyQueue (new mail and mail the user
/// opens) is not gated. The observable is the provider: a held download never
/// reaches it.
@Suite("Older-mail body downloads follow the walk gate", .serialized)
struct BackfillBodyDownloadGateTests {
    private static let settle: Duration = .milliseconds(600)

    /// Installs `provider` as the account's provider in AccountManager (where the
    /// body queues resolve it), runs `body` under `gate`, then removes it.
    private func withAccount(
        _ accountId: String, provider: MockEmailProvider, gate: DownloadGate?,
        _ body: () async throws -> Void
    ) async throws {
        await AccountManager.shared.installBodyGateTestProvider(
            accountId: accountId, provider: provider, queue: ProviderWorkQueue(provider: provider, maxConcurrency: 1))
        let power = gate.map(DownloadGateHarness.power)
            ?? (fastSync: false, lowPowerMode: false, onPower: false, batteryLevel: 0.8)
        SyncEngine.backfillPowerStateForTesting.withLock { $0 = power }
        defer { SyncEngine.backfillPowerStateForTesting.withLock { $0 = nil } }
        NetworkMonitor.setConnectedForTesting(true)
        do {
            try await DownloadGateHarness.withNetwork(expensive: gate == .expensiveNetwork) { try await body() }
        } catch {
            await AccountManager.shared.removeBodyGateTestProvider(accountId: accountId)
            throw error
        }
        await AccountManager.shared.removeBodyGateTestProvider(accountId: accountId)
    }

    private func fetchCount(_ provider: MockEmailProvider) async -> Int {
        await provider.callLog.filter { $0.hasPrefix("fetchMessage(") }.count
    }

    private func backfillItem(_ accountId: String) -> BackfillBodyQueue.Item {
        BackfillBodyQueue.Item(
            headerId: "\(accountId):Archive:7", accountId: accountId,
            folderPath: "Archive", messageId: "7", isInInbox: false)
    }

    @Test("an older-mail body download does not start while the walk gate refuses", arguments: DownloadGate.allCases)
    func heldUnderEveryGate(_ gate: DownloadGate) async throws {
        let accountId = "gate1064-held-\(gate.rawValue)"
        let provider = MockEmailProvider()
        let queue = BackfillBodyQueue()
        try await withAccount(accountId, provider: provider, gate: gate) {
            await queue.enqueue([backfillItem(accountId)])
            try await Task.sleep(for: Self.settle)
            #expect(await fetchCount(provider) == 0, "the body was downloaded under \(gate)")
            #expect(await queue.heldByDownloadGate)
            // awaitDrain must not hang on held work (the background job awaits it).
            await queue.awaitDrain()
        }
        await queue.cancelAllInFlight()
    }

    @Test("with no gate shut, the older-mail body downloads (the harness is live)")
    func downloadsWithNoGate() async throws {
        let accountId = "gate1064-open"
        let provider = MockEmailProvider()
        let queue = BackfillBodyQueue()
        try await withAccount(accountId, provider: provider, gate: nil) {
            await queue.enqueue([backfillItem(accountId)])
            try await Task.sleep(for: Self.settle)
            #expect(await fetchCount(provider) > 0)
        }
        await queue.cancelAllInFlight()
    }

    @Test("ActiveBodyQueue is not gated", arguments: DownloadGate.allCases)
    func activeQueueUngated(_ gate: DownloadGate) async throws {
        let accountId = "gate1064-active-\(gate.rawValue)"
        let provider = MockEmailProvider()
        let queue = ActiveBodyQueue()
        try await withAccount(accountId, provider: provider, gate: gate) {
            await queue.enqueue(header: MessageHeader(
                messageId: "9", subject: "gate", from: "Sender", fromAddress: "sender@example.com",
                to: "user@example.com", date: Date(), snippet: "",
                folderId: MessageIdentity.folderId(accountId: accountId, folderPath: "INBOX"),
                accountId: accountId, folderPath: "INBOX", isInInbox: true))
            try await Task.sleep(for: Self.settle)
            #expect(await fetchCount(provider) > 0, "the inbox body was held under \(gate)")
        }
        await queue.cancelAllInFlight()
    }
}

private extension AccountManager {
    func installBodyGateTestProvider(accountId: String, provider: any EmailProvider, queue: ProviderWorkQueue) {
        providers[accountId] = provider
        workQueues[accountId] = queue
    }

    func removeBodyGateTestProvider(accountId: String) {
        providers.removeValue(forKey: accountId)
        workQueues.removeValue(forKey: accountId)
    }
}
