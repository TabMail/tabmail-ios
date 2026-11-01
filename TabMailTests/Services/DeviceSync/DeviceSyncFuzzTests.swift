/* This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at https://mozilla.org/MPL/2.0/. */

import Foundation
import Testing
@testable import TabMail

// Device Sync between three to six iOS devices (BulletDevices.swift), driven by a seeded generator:
// adds, deletions, rewords, moves between sections, edits committed from an older read, resets,
// restarts, failed saves, a copied device, a restored backup, a released device's texts,
// connections coming and going, and the relay delivering, reordering, repeating and losing parts. A
// model of every label checks these invariants:
//
// - I1 (no loss): when a delivery makes a bullet's text gone from every device, each label it had was
//   deleted by a user (its deletion travelled), or was put aside by DS-DEDUP for a label that was,
//   checked at every step; at the end every label still held somewhere is held everywhere.
// - I2 (convergence): connected and settled, every device holds the same labels.
// - I3 (bounded messages): each message's `seen` names every bullet it carries and, besides them, only
//   those of the last snapshot the sender merged (DS-SEEN-OUT), and settling ends.
//
// A failure names its seed and step; the DEVICE_SYNC_FUZZ_SEEDS environment variable runs more seeds.

private let steps = 120
private let defaultSeeds = 8
private let maxDevices = 6
/// More deliveries than settling ever needs: messages that never stop (I3).
private let maxDeliveries = 50_000
private let words = ["alpha", "beta", "gamma", "delta", "epsilon", "zeta", "eta", "theta", "iota", "kappa", "lambda", "mu"]
private let future = "2099-01-01T00:00:00.000Z"

/// A seeded generator (mulberry32): the same seed, the same run.
private struct SeededRandom {
    var state: UInt32

    mutating func next() -> Double {
        state = state &+ 0x6d2b_79f5
        var t = state
        t = (t ^ (t >> 15)) &* (t | 1)
        t ^= t &+ ((t ^ (t >> 7)) &* (t | 61))
        return Double(t ^ (t >> 14)) / 4_294_967_296
    }
}

private func hex8(_ value: Int) -> String {
    let digits = String(value, radix: 16)
    return String(repeating: "0", count: max(0, 8 - digits.count)) + digits
}

/// A label, with its field: one key across the fields.
private func key(_ field: BulletField, _ name: String, _ n: Int) -> String {
    "\(field.rawValue)|\(name)/\(n)"
}

private func key(_ field: BulletField, _ bullet: Bullet) -> String {
    key(field, bullet.name, bullet.n)
}

private func itemKey(_ field: BulletField, _ section: String, _ text: String) -> String {
    "\(field.rawValue)|\(section)|\(text)"
}

private func itemKey(_ field: BulletField, _ bullet: Bullet) -> String {
    itemKey(field, bullet.section, bullet.text)
}

private func object(_ text: String) -> [String: Any] {
    (try? JSONSerialization.jsonObject(with: Data(text.utf8))) as? [String: Any] ?? [:]
}

@MainActor
private final class Fuzz {
    let relay = BulletRelay()
    private(set) var devices: [BulletDevice] = []
    /// Labels a user deleted, by any device: a delete, a reword or move, an edit committed from a read.
    private var deleted = Set<String>()
    /// For a label a device dropped while its text stayed live there under another (DS-DEDUP), those
    /// others: the dropped label goes with a user's deletion of one of them.
    private var aliases: [String: Set<String>] = [:]
    /// For each device and field, the names on bullets in the last snapshot it merged since its process
    /// started or it forgot its texts: what its `seen` may name besides its own bullets (DS-SEEN-OUT).
    private var merged: [String: Set<String>] = [:]
    /// Parts each device has of a sender's snapshot: by device, the message's sender and field, as it
    /// buffers them.
    private var buffers: [String: (snap: String, parts: Set<Int>)] = [:]
    /// Whether this step put a device's texts aside (a reset, a restore): no dedup.
    private var cleared = false
    /// Messages whose `seen` broke DS-SEEN-OUT: kept for the test, as a throw would land in the sender.
    private(set) var violations: [String] = []
    private var reads: [String: (field: BulletField, section: String, read: (text: String, captured: [Bullet]?))] = [:]
    private var backups: [String: DeviceDefaults] = [:]
    private var stores: [DeviceDefaults] = []
    private var unique = 0
    private(set) var log: [String] = []
    private var random: SeededRandom
    private let budget: Int

    init(seed: Int) {
        var random = SeededRandom(state: UInt32(seed))
        budget = random.next() < 0.3 ? 1_500 + Int(random.next() * 1_500) : BulletSyncConfig.messageMaxBytes
        self.random = random
        let count = 3 + int(4)
        for _ in 0..<count { create(initialStore()) }
        relay.onSend = { [unowned self] from, text in checkSeen(from, text) }
        relay.onLeave = { [unowned self] device in
            // DS-CHUNK: incomplete snapshots are dropped on disconnect.
            forgetBuffers(device)
        }
    }

    func dispose() {
        for store in stores { store.dispose() }
    }

    func next() -> Double {
        random.next()
    }

    func int(_ below: Int) -> Int {
        min(below - 1, Int(next() * Double(below)))
    }

    func pick<T>(_ values: [T]) -> T? {
        values.isEmpty ? nil : values[int(values.count)]
    }

    /// DS-SEEN-OUT, I3: `seen` names every bullet the sender sends, and besides them only those of the
    /// last snapshot it merged.
    private func checkSeen(_ from: String, _ text: String) {
        let message = object(text)
        guard let device = devices.first(where: { $0.id == from }),
              let field = BulletField(rawValue: message["field"] as? String ?? ""),
              let seen = message["seen"] as? [String: Any] else {
            violations.append("\(from) sent a message the test can't read")
            return
        }
        let own = Set(device.state(field).bullets.map(\.name))
        let last = merged["\(from)|\(field.rawValue)"] ?? []
        let extra = seen.keys.filter { !own.contains($0) && !last.contains($0) }.sorted()
        if !extra.isEmpty {
            violations.append("I3: \(from)'s \(field.rawValue) message names \(extra) in seen, on no bullet it holds or merged last")
        }
        let missing = own.filter { seen[$0] == nil }.sorted()
        if !missing.isEmpty {
            violations.append("DS-SEEN-OUT: \(from)'s \(field.rawValue) message leaves \(missing) of its own bullets out of seen")
        }
    }

    /// Delivers a part, noting what the device keeps of it.
    func deliver(_ id: String, to: String, part: Int) throws {
        let device = devices.first { $0.id == to }
        let before = device.map(labelsOf)
        let whole = arrived(id, to: to, part: part)
        guard let device, let before, let whole else {
            try relay.deliver(id, to: to, part: part)
            if let device, let before { dropped(device, before) }
            return
        }
        // Its answer, sent during the delivery, names this snapshot's names once merged, the last one's
        // until then: either is allowed meanwhile, and after it, this one's only if it was merged.
        let mergedKey = "\(to)|\(whole.field.rawValue)"
        let last = merged[mergedKey] ?? []
        let names = Set(whole.bullets.map(\.name))
        merged[mergedKey] = last.union(names)
        try relay.deliver(id, to: to, part: part)
        if case .merged = device.lastReceived { merged[mergedKey] = names } else { merged[mergedKey] = last }
        dropped(device, before)
        mergedAside(device, whole)
    }

    /// A part arriving at `to`, buffered as the device buffers it: once its snapshot is whole, its field
    /// and bullets.
    private func arrived(_ id: String, to: String, part: Int) -> (field: BulletField, bullets: [Bullet])? {
        guard let snapshot = relay.snapshots[id], let text = snapshot.parts[part],
              let field = BulletField(rawValue: snapshot.field) else { return nil }
        let first = object(text)
        guard let sender = first["sender"] as? String, let snap = first["snap"] as? String, let parts = first["parts"] as? Int else { return nil }
        let bufferKey = "\(to)|\(sender)|\(snapshot.field)"
        var buffer = buffers[bufferKey]
        if buffer == nil || buffer?.snap != snap { buffer = (snap, []) }
        buffer?.parts.insert(part)
        guard let buffered = buffer, buffered.parts.count >= parts else {
            buffers[bufferKey] = buffer
            return nil
        }
        buffers[bufferKey] = nil
        var bullets: [Bullet] = []
        for index in 1...parts {
            let tuples = object(snapshot.parts[index] ?? "")["bullets"] as? [[Any]] ?? []
            for tuple in tuples {
                guard tuple.count == 4, let section = tuple[0] as? String, let text = tuple[1] as? String,
                      let name = tuple[2] as? String, let n = tuple[3] as? Int else { continue }
                bullets.append(Bullet(section: section, text: text, name: name, n: n))
            }
        }
        return (field, bullets)
    }

    private func forgetBuffers(_ device: String) {
        for bufferKey in buffers.keys where bufferKey.hasPrefix("\(device)|") { buffers[bufferKey] = nil }
    }

    /// DS-DEDUP on merge: an incoming label `device` didn't keep, its text held there under another.
    private func mergedAside(_ device: BulletDevice, _ whole: (field: BulletField, bullets: [Bullet])) {
        var held: [String: String] = [:]
        for bullet in device.state(whole.field).bullets { held[itemKey(whole.field, bullet)] = key(whole.field, bullet) }
        for bullet in whole.bullets {
            let label = key(whole.field, bullet)
            if let other = held[itemKey(whole.field, bullet)], other != label { aliases[label, default: []].insert(other) }
        }
    }

    /// `device`'s process started afresh, or it forgot its texts: nothing merged since.
    private func forgetMerged(_ device: BulletDevice) {
        for field in BulletField.allCases { merged["\(device.id)|\(field.rawValue)"] = nil }
    }

    private func initialStore() -> DeviceDefaults {
        let store = DeviceDefaults()
        let kind = int(3)
        if kind == 1 { store.storeStates([:]) }
        if kind == 2 {
            let text = [text(), text(), "plain line"].map { "- \($0)" }.joined(separator: "\n")
            store.defaults.set(text, forKey: UserDefaultsBulletStore.renderedKeys[.kb]!)
        }
        return store
    }

    @discardableResult
    private func create(_ store: DeviceDefaults) -> BulletDevice {
        let index = devices.count + 1
        let device = BulletDevice(id: String(UnicodeScalar(UInt8(64 + index))), store: store, relay: relay,
                                  name: { hex8(index) + hex8($0) }, budget: budget, catalog: DeviceSyncSharedFiles.catalog)
        device.start()
        devices.append(device)
        stores.append(store)
        return device
    }

    private func text() -> String {
        if next() < 0.2 {
            unique += 1
            return "unique \(unique)"
        }
        return pick(words)!
    }

    private func section(_ field: BulletField) -> String {
        pick(Bullets.displayedSections(field))!
    }

    /// Every label held, with the devices holding it, and every text live on some device.
    func held() -> (labels: [String: Set<String>], items: Set<String>) {
        var labels: [String: Set<String>] = [:]
        var items = Set<String>()
        for device in devices {
            for field in BulletField.allCases {
                for bullet in device.state(field).bullets {
                    labels[key(field, bullet), default: []].insert(device.id)
                    items.insert(itemKey(field, bullet))
                }
            }
        }
        return (labels, items)
    }

    /// The bullet each label held names.
    func bulletsHeld() -> [String: (field: BulletField, bullet: Bullet)] {
        var all: [String: (field: BulletField, bullet: Bullet)] = [:]
        for device in devices {
            for field in BulletField.allCases {
                for bullet in device.state(field).bullets { all[key(field, bullet)] = (field, bullet) }
            }
        }
        return all
    }

    /// `device`'s labels, with their texts.
    private func labelsOf(_ device: BulletDevice) -> [String: String] {
        var labels: [String: String] = [:]
        for field in BulletField.allCases {
            for bullet in device.state(field).bullets { labels[key(field, bullet)] = itemKey(field, bullet) }
        }
        return labels
    }

    /// DS-DEDUP: a label `device` held `before` and dropped while its text stayed live there under another.
    private func dropped(_ device: BulletDevice, _ before: [String: String]) {
        let now = labelsOf(device)
        var byItem: [String: String] = [:]
        for (label, item) in now { byItem[item] = label }
        for (label, item) in before where now[label] == nil {
            if let other = byItem[item] { aliases[label, default: []].insert(other) }
        }
    }

    /// One step; true when it delivered parts (merges), whose disappearances I1 checks.
    func step() throws -> Bool {
        let before = devices.map { ($0, labelsOf($0)) }
        cleared = false
        let delivered = try act()
        if !cleared { for (device, labels) in before { dropped(device, labels) } }
        return delivered
    }

    private func act() throws -> Bool {
        let device = pick(devices)!
        let field = pick(BulletField.allCases)!
        let roll = next()
        if roll < 0.3 {
            let count = 1 + int(4)
            for _ in 0..<count where !relay.pending.isEmpty {
                guard let entry = next() < 0.7 ? relay.pending.first : pick(relay.pending) else { break }
                log.append("deliver \(entry.snapshot.id)/\(entry.part) to \(entry.to)")
                try deliver(entry.snapshot.id, to: entry.to, part: entry.part)
            }
            return true
        }
        if roll < 0.33 {
            // A part delivered again.
            let snapshots = relay.snapshots.values.sorted { $0.id < $1.id }
            guard let snapshot = pick(snapshots), let to = pick(devices) else { return false }
            guard snapshot.from != to.id, relay.isConnected(to.id) else { return false }
            let part = 1 + int(snapshot.parts.count)
            log.append("repeat \(snapshot.id)/\(part) to \(to.id)")
            try deliver(snapshot.id, to: to.id, part: part)
            return true
        }
        if roll < 0.36 {
            guard let entry = pick(relay.pending) else { return false }
            log.append("lose \(entry.snapshot.id)/\(entry.part) to \(entry.to)")
            relay.drop(entry.snapshot.id, to: [entry.to], parts: [entry.part])
            return false
        }
        if roll < 0.48 {
            log.append("\(device.id) connect")
            device.connect()
            return false
        }
        if roll < 0.53 {
            log.append("\(device.id) disconnect")
            device.disconnect()
            return false
        }
        if roll < 0.65 {
            let section = section(field)
            let text = text()
            log.append("\(device.id) add \(field.rawValue)/\(section) \(text)")
            device.add(field, section, text)
            return false
        }
        let shown = Bullets.displayedSections(field)
        let victims = device.state(field).bullets.filter { bullet in shown.contains { Bullets.same($0, bullet.section) } }
        if roll < 0.73 {
            guard let victim = pick(victims) else { return false }
            log.append("\(device.id) delete \(field.rawValue)/\(victim.section) \(victim.text)")
            markDeleted(device, field, victim.section, victim.text)
            device.delete(field, victim.section, victim.text)
            return false
        }
        if roll < 0.78 {
            guard let victim = pick(victims) else { return false }
            let to = text()
            let section = field != .kb && next() < 0.3 ? section(field) : victim.section
            log.append("\(device.id) edit \(field.rawValue)/\(victim.section) \(victim.text) -> \(section) \(to)")
            markDeleted(device, field, victim.section, victim.text)
            if section == victim.section {
                device.editSection(field, section) { texts in texts.map { Bullets.same($0, victim.text) ? to : $0 } }
            } else {
                device.delete(field, victim.section, victim.text)
                device.add(field, section, to)
            }
            return false
        }
        if roll < 0.82 {
            guard let pending = reads[device.id] else {
                let section = section(field)
                log.append("\(device.id) read \(field.rawValue)/\(section)")
                reads[device.id] = (field, section, device.prompts.readForEdit(field))
                return false
            }
            reads[device.id] = nil
            let inSection = (pending.read.captured ?? []).filter { Bullets.same($0.section, pending.section) }
            var result = inSection.filter { _ in next() < 0.6 }.map(\.text)
            if next() < 0.5 { result.append(text()) }
            log.append("\(device.id) commit \(pending.field.rawValue)/\(pending.section) \(result)")
            for bullet in inSection where !result.contains(where: { Bullets.same($0, bullet.text) }) {
                deleted.insert(key(pending.field, bullet))
            }
            device.commitRead(pending.field, pending.section, pending.read, result)
            return false
        }
        if roll < 0.85 {
            log.append("\(device.id) reset \(field.rawValue)")
            cleared = true
            device.reset(field)
            return false
        }
        if roll < 0.88 {
            log.append("\(device.id) restart")
            reads[device.id] = nil
            forgetMerged(device)
            device.restart()
            return false
        }
        if roll < 0.9 {
            log.append("\(device.id) next save fails")
            device.store.failNext = true
            return false
        }
        if roll < 0.92 {
            guard devices.count < maxDevices else { return false }
            let copy = create(device.store.copy())
            log.append("\(device.id) copied to \(copy.id)")
            return false
        }
        if roll < 0.95 {
            guard let backup = backups[device.id], next() >= 0.5 else {
                log.append("\(device.id) backup")
                let copy = device.store.copy()
                stores.append(copy)
                backups[device.id] = copy
                return false
            }
            log.append("\(device.id) restore")
            cleared = true
            reads[device.id] = nil
            forgetMerged(device)
            device.disconnect()
            device.store.replace(with: backup)
            device.restart()
            return false
        }
        guard field != .action else { return false }
        let texts = [text(), text()]
        log.append("\(device.id) legacy \(field.rawValue) \(texts)")
        let lines = texts.map { "- \($0)" }.joined(separator: "\n")
        let legacy = field == .kb ? lines : "# Language (\(Bullets.headerMark))\n\(lines)"
        device.receive(["type": "prompt_state", "data": [field.rawValue: legacy, "\(field.rawValue)_updated_at": future]])
        return false
    }

    /// The labels `device` shows for a text a user deletes there.
    private func markDeleted(_ device: BulletDevice, _ field: BulletField, _ section: String, _ text: String) {
        for bullet in device.state(field).bullets where Bullets.same(bullet.section, section) && Bullets.same(bullet.text, text) {
            deleted.insert(key(field, bullet))
        }
    }

    /// A label no device holds any more went with a user's deletion: its own, or that of a label DS-DEDUP
    /// kept in its place.
    func justified(_ field: BulletField, _ bullet: Bullet) -> Bool {
        var visited = Set<String>()
        var pending = [key(field, bullet)]
        while let label = pending.popLast() {
            if deleted.contains(label) { return true }
            guard visited.insert(label).inserted else { continue }
            pending.append(contentsOf: aliases[label] ?? [])
        }
        return false
    }

    /// Every device connected afresh, and everything delivered (I3).
    func settle() throws {
        for device in devices { device.store.failNext = false }
        for device in devices { device.disconnect() }
        for device in devices { device.connect() }
        var deliveries = 0
        while let entry = relay.pending.first {
            try autoreleasepool { try deliver(entry.snapshot.id, to: entry.to, part: entry.part) }
            deliveries += 1
            if deliveries > maxDeliveries { throw DeviceSyncTestError("I3: the devices never stop sending") }
        }
    }
}

@Suite("Device Sync fuzz")
@MainActor
struct DeviceSyncFuzzTests {
    @Test("Device Sync keeps every bullet no user deleted, converges, and goes quiet")
    func fuzz() throws {
        // Every check reads each device's state through its real UserDefaults store, so a seed takes seconds
        // on the simulator: the default keeps the suite short, and DEVICE_SYNC_FUZZ_SEEDS runs more.
        let seeds = Int(ProcessInfo.processInfo.environment["DEVICE_SYNC_FUZZ_SEEDS"] ?? "") ?? defaultSeeds
        #expect(seeds > 0)
        // The run never returns to a run loop, so nothing drains the autorelease pool: each seed and each
        // step drains its own, or the objects every JSONSerialization read leaves pile up for the whole run.
        for seed in 1...seeds { try autoreleasepool { try run(seed) } }
    }

    private func run(_ seed: Int) throws {
        let fuzz = Fuzz(seed: seed)
        defer { fuzz.dispose() }
        func fail(_ message: String) -> DeviceSyncTestError {
            DeviceSyncTestError("seed \(seed): \(message)\n\(fuzz.log.suffix(40).joined(separator: "\n"))")
        }
        for index in 1...steps {
            try autoreleasepool {
                let bullets = fuzz.bulletsHeld()
                let delivered: Bool
                do { delivered = try fuzz.step() } catch { throw fail("step \(index): \(error)") }
                if !fuzz.violations.isEmpty { throw fail("step \(index): \(fuzz.violations.joined(separator: "; "))") }
                guard delivered else { return }
                // I1 at every merge: a text gone from every device lost only labels a user deleted.
                let after = fuzz.held()
                for (label, held) in bullets.sorted(by: { $0.key < $1.key }) {
                    if after.labels[label] != nil || after.items.contains(itemKey(held.field, held.bullet)) { continue }
                    if !fuzz.justified(held.field, held.bullet) {
                        throw fail("step \(index): I1: \"\(held.bullet.text)\" (\(label)) gone from every device, and no user deleted it")
                    }
                }
            }
        }
        let bullets = fuzz.bulletsHeld()
        do { try fuzz.settle() } catch { throw fail("settling: \(error)") }
        if !fuzz.violations.isEmpty { throw fail("settling: \(fuzz.violations.joined(separator: "; "))") }
        let after = fuzz.held()
        for (label, held) in bullets.sorted(by: { $0.key < $1.key }) {
            if after.labels[label] != nil || after.items.contains(itemKey(held.field, held.bullet)) || fuzz.justified(held.field, held.bullet) { continue }
            throw fail("I1: \"\(held.bullet.text)\" (\(label)) gone after settling, and no user deleted it")
        }
        for device in fuzz.devices {
            for field in BulletField.allCases {
                // Each field fits the budget, so nothing is held back (DS-OVERSIZE).
                if case .oversize = device.prompts.engine.outgoing(field) { throw fail("\(device.id) held \(field.rawValue) back as oversize") }
            }
        }
        // I2: every device holds the same labels.
        for field in BulletField.allCases {
            let first = fuzz.devices.first.map { $0.state(field).bullets.map { key(field, $0) }.sorted() } ?? []
            for device in fuzz.devices {
                let labels = device.state(field).bullets.map { key(field, $0) }.sorted()
                if labels != first { throw fail("I2: \(device.id)'s \(field.rawValue) \(labels) differs from A's \(first)") }
            }
        }
    }
}
