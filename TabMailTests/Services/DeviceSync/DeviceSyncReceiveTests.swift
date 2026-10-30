/* This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at https://mozilla.org/MPL/2.0/. */

import Foundation
import Testing
@testable import TabMail

// DS-RECEIVE: messages for the prompt store apply one after another in arrival order, a busy one is
// applied again (holding nothing while it waits), the connection's end drops what waits, and a stale
// prompt_state never lands over a newer local edit (the iOS side of TB #194).

@MainActor
@Suite("Device Sync receive", .serialized, .processGlobalState)
struct DeviceSyncReceiveTests {
    private let store = PromptStore.shared
    private let sync = DeviceSyncService.shared

    /// A short wait so a busy refusal comes in milliseconds; the 2 s re-apply is the production value.
    private func shortRetries() -> PromptSemaphore.Config {
        let config = store.semaphore.config
        store.semaphore.config = PromptSemaphore.Config(leaseSeconds: 15, acquireWaitSeconds: 0.05)
        return config
    }

    private func has(_ text: String) -> Bool {
        store.rawKB.contains(text)
    }

    private func waitUntil(_ seconds: Double, _ condition: () -> Bool) async throws -> Bool {
        let deadline = ContinuousClock.now + .seconds(seconds)
        while ContinuousClock.now < deadline {
            if condition() { return true }
            try await Task.sleep(for: .milliseconds(20))
        }
        return condition()
    }

    private func quietDevice() {
        UserDefaults.standard.set(false, forKey: "device_sync_auto_enabled")
        sync.disconnect()
    }

    @Test("A busy store applies the waiting messages in arrival order once it is free (DS-RECEIVE)")
    func busyMessagesApplyInArrivalOrder() async throws {
        quietDevice()
        let config = shortRetries()
        defer { store.semaphore.config = config }
        let tag = PromptStoreTestCleanup.tag()
        let holder = await PromptStoreHolder(store)
        sync.handleMessage(ForeignBulletMessage.kb("\(tag) first"))
        sync.handleMessage(ForeignBulletMessage.kb("\(tag) second"))
        sync.handleMessage(ForeignBulletMessage.kb("\(tag) third"))
        try await Task.sleep(for: .milliseconds(300))
        #expect(!has(tag), "nothing applies while the store is held")
        try await holder.end()
        let applied = try await waitUntil(8) { has("\(tag) first") && has("\(tag) second") && has("\(tag) third") }
        #expect(applied, "each is applied again after busy")
        let kb = store.rawKB
        if let a = kb.range(of: "\(tag) first"), let b = kb.range(of: "\(tag) second"), let c = kb.range(of: "\(tag) third") {
            #expect(a.lowerBound < b.lowerBound && b.lowerBound < c.lowerBound, "in arrival order")
        }
        await PromptStoreTestCleanup.remove(tag: tag, from: store)
    }

    @Test("A connection that ends drops the messages waiting on it; a message after it applies (DS-RECEIVE)")
    func connectionEndDropsWaitingMessages() async throws {
        quietDevice()
        let config = shortRetries()
        defer { store.semaphore.config = config }
        let tag = PromptStoreTestCleanup.tag()
        let holder = await PromptStoreHolder(store)
        sync.handleMessage(ForeignBulletMessage.kb("\(tag) before the end"))
        try await Task.sleep(for: .milliseconds(100))
        sync.disconnect()
        try await holder.end()
        try await Task.sleep(for: .seconds(3))
        #expect(!has("\(tag) before the end"), "the dropped message never applies")

        sync.handleMessage(ForeignBulletMessage.kb("\(tag) after the end"))
        #expect(try await waitUntil(3) { has("\(tag) after the end") }, "the control after the end applies")
        await PromptStoreTestCleanup.remove(tag: tag, from: store)
    }

    @Test("More than the bound of waiting messages renews the connection and drops them all (DS-RECEIVE)")
    func boundRenewsTheConnection() async throws {
        quietDevice()
        let config = shortRetries()
        defer { store.semaphore.config = config }
        let tag = PromptStoreTestCleanup.tag()
        let holder = await PromptStoreHolder(store)
        for index in 0...BulletSyncConfig.maxWaitingReceives {
            sync.handleMessage(ForeignBulletMessage.kb("\(tag) waiting \(index)"))
        }
        try await holder.end()
        try await Task.sleep(for: .seconds(3))
        #expect(!has("\(tag) waiting 0"), "the messages waiting when the bound was passed are dropped")
        sync.handleMessage(ForeignBulletMessage.kb("\(tag) fresh"))
        #expect(try await waitUntil(3) { has("\(tag) fresh") }, "the connection that replaced it applies")
        await PromptStoreTestCleanup.remove(tag: tag, from: store)
    }

    @Test("Parts held for incomplete snapshots count toward the bound: a sender that restarts with a part lost each time cannot grow the receiver without limit (DS-RECEIVE, Bound)")
    func heldPartsCountTowardTheBound() async throws {
        quietDevice()
        let tag = PromptStoreTestCleanup.tag()
        let restarts = BulletSyncConfig.maxWaitingReceives + 44
        // Fresh labels each run: a label this device saw and deleted in an earlier run is rejected (DS-MERGE-1).
        let base = UInt64.random(in: (1 << 40)..<(1 << 56))
        func id(_ index: Int) -> String { String(format: "%016llx", base + UInt64(index)) }
        for index in 0..<restarts {
            let id = id(index)
            sync.handleMessage(ForeignBulletMessage.kbPart(1, first: "\(tag) lost \(index)", second: "\(tag) never", sender: id, snap: id))
        }
        // Wait until the held count stops moving.
        var last = -1
        while true {
            try await Task.sleep(for: .milliseconds(400))
            let now = store.bullets.heldParts
            if now == last { break }
            last = now
        }
        let held = store.bullets.heldParts
        #expect(held < BulletSyncConfig.maxWaitingReceives, "the receiver holds fewer parts than the bound: \(held)")
        #expect(held > 0 && held < restarts, "the connection was renewed once and the parts after it are held again: \(held)")
        // A whole split snapshot sent after the renewal still lands.
        let whole = id(restarts + 1)
        sync.handleMessage(ForeignBulletMessage.kbPart(1, first: "\(tag) whole one", second: "\(tag) whole two", sender: whole, snap: whole))
        sync.handleMessage(ForeignBulletMessage.kbPart(2, first: "\(tag) whole one", second: "\(tag) whole two", sender: whole, snap: whole))
        #expect(try await waitUntil(5) { has("\(tag) whole one") && has("\(tag) whole two") })
        // The control: a snapshot whose parts all arrive holds nothing once it is complete.
        let before = store.bullets.heldParts
        let control = id(restarts + 2)
        sync.handleMessage(ForeignBulletMessage.kbPart(1, first: "\(tag) control one", second: "\(tag) control two", sender: control, snap: control))
        sync.handleMessage(ForeignBulletMessage.kbPart(2, first: "\(tag) control one", second: "\(tag) control two", sender: control, snap: control))
        #expect(try await waitUntil(5) { has("\(tag) control one") && has("\(tag) control two") })
        #expect(store.bullets.heldParts == before, "a complete snapshot leaves no part held")
        store.bullets.disconnected()
        await PromptStoreTestCleanup.remove(tag: tag, from: store)
    }

    private struct Unreadable: Error {}

    @Test("A message whose hold ended before it was applied is applied again; any other failure drops it (DS-RECEIVE, DS-LEASE)")
    func lapsedHoldIsReappliedOtherFailureDropped() async throws {
        quietDevice()
        var lapsed = 0
        var failed = 0
        sync.applyReceived("lapsed hold") { _ in
            lapsed += 1
            if lapsed == 1 { throw PromptRefusal.changed }
        }
        sync.applyReceived("failing apply") { _ in
            failed += 1
            throw Unreadable()
        }
        // The re-apply comes after BulletSyncConfig.busyReapplySeconds.
        #expect(try await waitUntil(BulletSyncConfig.busyReapplySeconds + 3) { lapsed == 2 }, "the message is applied again after its hold lapsed")
        try await Task.sleep(for: .milliseconds(300))
        #expect(lapsed == 2, "and only once more")
        #expect(failed == 1, "a failure that is not a refusal drops the message")
    }

    // MARK: - TB #194, on iOS: nothing older lands on a newer local edit

    private static let configKeys = [PromptStore.actionCompactThresholdKey, PromptStore.actionCompactThresholdCharsKey, ActionCompactConfig.updatedAtKey]

    private func promptState(rules: Int, chars: Int, at timestamp: String) throws -> String {
        var state = PromptStateData()
        state.actionConfig = ActionCompactConfig(compactThreshold: rules, compactThresholdChars: chars)
        state.actionConfigUpdatedAt = timestamp
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let data = try JSONSerialization.jsonObject(with: encoder.encode(state))
        return String(decoding: try JSONSerialization.data(withJSONObject: ["type": "prompt_state", "data": data]), as: UTF8.self)
    }

    private func stored() -> (rules: Int?, chars: Int?, updatedAt: String?) {
        let defaults = UserDefaults.standard
        return (defaults.object(forKey: Self.configKeys[0]) as? Int, defaults.object(forKey: Self.configKeys[1]) as? Int, defaults.string(forKey: Self.configKeys[2]))
    }

    @Test("A compaction edit made while a prompt_state waits is not replaced by the older value; a newer one is applied")
    func olderPromptStateNeverLandsOnANewerEdit() async throws {
        quietDevice()
        let defaults = UserDefaults.standard
        let saved = Self.configKeys.map { defaults.object(forKey: $0) }
        defer { for (key, value) in zip(Self.configKeys, saved) { defaults.set(value, forKey: key) } }
        let config = shortRetries()
        defer { store.semaphore.config = config }
        let old = Date().addingTimeInterval(-3_600).ISO8601Format()
        let middle = Date().addingTimeInterval(-1_800).ISO8601Format()
        defaults.set(300, forKey: Self.configKeys[0])
        defaults.set(40_000, forKey: Self.configKeys[1])
        defaults.set(old, forKey: Self.configKeys[2])

        let holder = await PromptStoreHolder(store)
        // The peer's value, older than the edit below, waits behind the held store.
        sync.handleMessage(try promptState(rules: 120, chars: 20_000, at: middle))
        try await Task.sleep(for: .milliseconds(200))
        // The user's slider edit: the values and their timestamp in one synchronous step.
        defaults.set(410, forKey: Self.configKeys[0])
        defaults.set(50_000, forKey: Self.configKeys[1])
        sync.debouncedBroadcast(fields: [.actionConfig])
        let editedAt = stored().updatedAt
        try await holder.end()
        try await Task.sleep(for: .seconds(3))
        let after = stored()
        #expect(after.rules == 410 && after.chars == 50_000, "the older peer value didn't replace the newer edit")
        #expect(after.updatedAt == editedAt)

        // Control: a peer value newer than the edit is applied.
        let newer = Date().addingTimeInterval(3_600).ISO8601Format()
        sync.handleMessage(try promptState(rules: 150, chars: 24_000, at: newer))
        #expect(try await waitUntil(3) { stored().rules == 150 }, "the newer peer value applies")
        #expect(stored().updatedAt == newer)
    }
}
