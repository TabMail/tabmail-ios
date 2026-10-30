/* This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at https://mozilla.org/MPL/2.0/. */

import Foundation
@testable import TabMail

// Simulated iOS devices for Device Sync tests. Each device is a UserDefaults suite of its own and the
// app process running on it: the real UserDefaultsBulletStore, PromptBulletSync, BulletSync and Bullets,
// started as PromptStore starts them, talking through a relay that forwards `bullet_state` between the
// connected devices and holds each message until the test delivers, reorders or drops it.

/// A device's UserDefaults: a suite of its own, removed by `dispose()`. The next save of the bullet
/// fields, or every one while `failing` is set, can be made to fail, as a full disk's would.
@MainActor
final class DeviceDefaults {
    let suiteName: String
    let defaults: UserDefaults
    var failNext = false
    var failing = false

    init(values: [String: Any] = [:]) {
        suiteName = "DeviceSyncTests.\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suiteName)!
        defaults.setPersistentDomain(values, forName: suiteName)
    }

    var values: [String: Any] {
        defaults.persistentDomain(forName: suiteName) ?? [:]
    }

    /// A copy of everything stored (the user moving to a new phone from a backup, or a backup taken).
    func copy() -> DeviceDefaults {
        DeviceDefaults(values: values)
    }

    /// Puts back everything `other` holds, as a restored backup does.
    func replace(with other: DeviceDefaults) {
        defaults.setPersistentDomain(other.values, forName: suiteName)
    }

    func dispose() {
        defaults.removePersistentDomain(forName: suiteName)
    }

    /// Writes `states` (field → state) as UserDefaultsBulletStore keeps them, with each field's rendered
    /// text; the fields not given stored empty. The built-in skeletons.
    func storeStates(_ states: [BulletField: (bullets: [Bullet], seen: [String: Int])]) {
        var all: [String: Any] = [:]
        for field in BulletField.allCases {
            let skeleton = PromptStore.skeleton(field)
            let given = states[field]
            let state = FieldState(head: skeleton.head, tail: skeleton.tail, bullets: given?.bullets ?? [], seen: given?.seen ?? [:])
            all[field.rawValue] = UserDefaultsBulletStore.encode(state)
            defaults.set(Bullets.render(field, state), forKey: UserDefaultsBulletStore.renderedKeys[field]!)
        }
        defaults.set(try! JSONSerialization.data(withJSONObject: all), forKey: UserDefaultsBulletStore.stateKey)
    }

    /// `field`'s stored state, nil when none is.
    func storedState(_ field: BulletField) -> FieldState? {
        guard let data = defaults.data(forKey: UserDefaultsBulletStore.stateKey),
              let all = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let value = all[field.rawValue] as? [String: Any] else { return nil }
        return UserDefaultsBulletStore.decode(value)
    }
}

/// The app's store, whose saves fail as the device's defaults say.
@MainActor
final class FailableBulletStore: BulletStore {
    let base: UserDefaultsBulletStore
    let device: DeviceDefaults

    init(base: UserDefaultsBulletStore, device: DeviceDefaults) {
        self.base = base
        self.device = device
    }

    func read(_ field: BulletField) -> FieldState? {
        base.read(field)
    }

    func legacyText(_ field: BulletField) -> String? {
        base.legacyText(field)
    }

    func write(_ states: [BulletField: FieldState], kind: BulletCommitKind) -> Bool {
        if device.failNext || device.failing {
            device.failNext = false
            return false
        }
        return base.write(states, kind: kind)
    }
}

/// The Device Sync relay between the test's devices: forwards each `bullet_state` part to every other
/// connected device, nothing kept. What is pending is delivered, reordered or lost as the test says.
@MainActor
final class BulletRelay {
    final class Snapshot {
        let id: String
        let from: String
        let field: String
        var parts: [Int: String] = [:]

        init(id: String, from: String, field: String) {
            self.id = id
            self.from = from
            self.field = field
        }
    }

    struct Entry {
        let snapshot: Snapshot
        let part: Int
        let to: String
    }

    /// Parts the relay holds undelivered, and messages it takes in all, before it stops taking more: a
    /// run whose devices never stop sending then fails at its next delivery rather than growing the
    /// queue, and every snapshot kept, without bound.
    static let maxPending = 10_000
    static let maxMessages = 100_000

    private(set) var snapshots: [String: Snapshot] = [:]
    var pending: [Entry] = []
    /// Why the relay stopped taking messages, once it has.
    private(set) var overflow: String?
    private var messages = 0
    /// Called with each message a device sends, before it is forwarded (a test's check of it).
    var onSend: ((_ from: String, _ text: String) -> Void)?
    /// Called when a device's connection ends.
    var onLeave: ((_ device: String) -> Void)?
    /// The connected devices in the order they joined, each with how a message reaches it.
    private var connected: [(id: String, deliver: (String) -> Void)] = []
    private var counts: [String: Int] = [:]
    private var bySnap: [String: Snapshot] = [:]

    func isConnected(_ device: String) -> Bool {
        connected.contains { $0.id == device }
    }

    func join(_ device: String, deliver: @escaping (String) -> Void) {
        connected.append((device, deliver))
    }

    func leave(_ device: String) {
        connected.removeAll { $0.id == device }
        pending.removeAll { $0.to == device }
        onLeave?(device)
    }

    /// How many snapshots of `field` `device` has sent.
    func sent(_ device: String, _ field: String) -> Int {
        counts["\(device):\(field)"] ?? 0
    }

    func send(from: String, _ text: String) {
        guard let message = (try? JSONSerialization.jsonObject(with: Data(text.utf8))) as? [String: Any],
              message["type"] as? String == "bullet_state",
              let field = message["field"] as? String, let snap = message["snap"] as? String,
              let part = message["part"] as? Int else {
            preconditionFailure("a device sent something other than a bullet_state")
        }
        onSend?(from, text)
        messages += 1
        if overflow == nil, messages > Self.maxMessages { overflow = "the devices sent over \(Self.maxMessages) messages" }
        if overflow == nil, pending.count >= Self.maxPending { overflow = "over \(Self.maxPending) parts pending" }
        if overflow != nil { return }
        let key = "\(from):\(field)"
        let snapKey = "\(key):\(snap)"
        let snapshot: Snapshot
        if let known = bySnap[snapKey] {
            snapshot = known
        } else {
            let k = (counts[key] ?? 0) + 1
            counts[key] = k
            snapshot = Snapshot(id: "\(key)#\(k)", from: from, field: field)
            snapshots[snapshot.id] = snapshot
            bySnap[snapKey] = snapshot
        }
        snapshot.parts[part] = text
        for to in connected.map(\.id) where to != from {
            pending.append(Entry(snapshot: snapshot, part: part, to: to))
        }
    }

    /// Delivers `part` of `id` to `to` (again when it already was), and waits for it to be handled.
    func deliver(_ id: String, to: String, part: Int) throws {
        if let overflow { throw DeviceSyncTestError("the devices never stop sending: \(overflow)") }
        guard let snapshot = snapshots[id] else { throw DeviceSyncTestError("no snapshot \(id)") }
        if let index = pending.firstIndex(where: { $0.snapshot === snapshot && $0.to == to && $0.part == part }) {
            pending.remove(at: index)
        }
        guard let deliver = connected.first(where: { $0.id == to })?.deliver else { throw DeviceSyncTestError("\(to) isn't connected") }
        guard let text = snapshot.parts[part] else { throw DeviceSyncTestError("\(id) has no part \(part)") }
        deliver(text)
    }

    func drop(_ id: String, to: [String]?, parts: [Int]?) {
        pending.removeAll { entry in
            entry.snapshot.id == id && (to?.contains(entry.to) ?? true) && (parts?.contains(entry.part) ?? true)
        }
    }

    /// Delivers the oldest pending part; false when none is.
    func deliverOldest() throws -> Bool {
        guard let entry = pending.first else { return false }
        try deliver(entry.snapshot.id, to: entry.to, part: entry.part)
        return true
    }
}

/// An iOS device: its defaults, and the app process running on it, which restarts.
@MainActor
final class BulletDevice {
    let id: String
    private(set) var store: DeviceDefaults
    /// The relay of the signed-in account's Device Sync group.
    private(set) var relay: BulletRelay
    /// Its k-th fresh writer name (16 hex digits).
    let name: (Int) -> String
    let budget: Int
    let catalog: DefaultCatalog
    private var names = 0
    private(set) var prompts: PromptBulletSync!
    /// What became of the last message delivered from the network.
    private(set) var lastReceived: BulletReceiveResult?

    init(id: String, store: DeviceDefaults, relay: BulletRelay, name: @escaping (Int) -> String, budget: Int, catalog: DefaultCatalog) {
        self.id = id
        self.store = store
        self.relay = relay
        self.name = name
        self.budget = budget
        self.catalog = catalog
    }

    /// Starts the process as PromptStore does: a field with no text gets the defaults', then DS-UPGRADE.
    func start() {
        let base = UserDefaultsBulletStore(defaults: store.defaults)
        PromptStore.writeMissingDefaults(base, defaults: store.defaults, catalog: catalog)
        let budget = budget
        prompts = PromptBulletSync(
            store: FailableBulletStore(base: base, device: store),
            catalog: catalog,
            skeleton: PromptStore.skeleton,
            newName: { [unowned self] in
                names += 1
                return name(names)
            },
            budget: { budget }
        )
    }

    /// Connected, as DeviceSyncService does on the relay's `connected`: every field goes out.
    func connect() {
        guard !relay.isConnected(id) else { return }
        relay.join(id) { [unowned self] text in receive(text: text) }
        prompts.send = { [unowned self] text in
            guard relay.isConnected(id) else { return }
            relay.send(from: id, text)
        }
        prompts.connected()
    }

    func disconnect() {
        relay.leave(id)
        prompts.disconnected()
    }

    /// The process ends and another opens the same defaults.
    func restart() {
        disconnect()
        start()
    }

    /// A message as the connection delivers it: parsed as DeviceSyncService parses it.
    func receive(text: String) {
        guard let object = (try? JSONSerialization.jsonObject(with: Data(text.utf8))) as? [String: Any] else { return }
        lastReceived = prompts.receive(object)
    }

    /// A message as JSON values (what DeviceSyncService parsed from the network).
    func receive(_ message: [String: Any]) {
        lastReceived = prompts.receive(message)
    }

    /// `field`'s state as the engine reads it.
    func state(_ field: BulletField) -> FieldState {
        prompts.engine.state(field)
    }

    /// The live texts of `section`, in local order.
    func shown(_ field: BulletField, _ section: String) -> [String] {
        state(field).bullets.filter { Bullets.same($0.section, section) }.map(\.text)
    }

    /// The Settings list's add (DS-ADD).
    @discardableResult
    func add(_ field: BulletField, _ section: String, _ text: String) -> BulletCommitResult {
        prompts.add(field, [BulletItem(section: section, text: text)])
    }

    /// The Settings list's swipe-delete (DS-DELETE of that section's bullet).
    @discardableResult
    func delete(_ field: BulletField, _ section: String, _ text: String) -> BulletCommitResult {
        prompts.editSection(field, section: section, texts: shown(field, section).filter { !Bullets.same($0, text) })
    }

    /// One section's bullets changed in one read-change-save.
    @discardableResult
    func editSection(_ field: BulletField, _ section: String, _ change: ([String]) -> [String]) -> BulletCommitResult {
        prompts.editSection(field, section: section, texts: change(shown(field, section)))
    }

    /// A text read (DS-CAPTURE), its `section` replaced by `texts`, saved: what the AI's KB and rule
    /// edits do with the text they read. A read refused while an upgrade was unsaved saves nothing (R22).
    @discardableResult
    func commitRead(_ field: BulletField, _ section: String, _ read: (text: String, captured: [Bullet]?), _ texts: [String]) -> BulletCommitResult {
        guard let captured = read.captured else { return BulletCommitResult(outcome: .unsaved, fields: []) }
        let parsed = Bullets.parse(field, read.text)
        let others = parsed.bullets.filter { !Bullets.same($0.section, section) }
        let items = others + texts.map { BulletItem(section: section, text: $0) }
        let text = Bullets.render(field, head: parsed.head, tail: parsed.tail,
                                  bullets: items.map { Bullet(section: $0.section, text: $0.text, name: "default:x", n: 1) })
        return prompts.commitEdit(field, captured: captured, text: text)
    }

    @discardableResult
    func reset(_ field: BulletField) -> BulletCommitResult {
        prompts.reset([field])
    }
}

