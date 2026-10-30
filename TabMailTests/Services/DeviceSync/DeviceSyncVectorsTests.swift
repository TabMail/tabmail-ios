/* This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at https://mozilla.org/MPL/2.0/. */

import CryptoKit
import Foundation
import Testing
@testable import TabMail

// The shared Device Sync conformance vectors, run on simulated iOS devices (BulletDevices.swift)
// connected through a relay the scenario delivers, reorders and drops messages on. The vectors and the
// default catalog are byte-identical in TabMail for Thunderbird, iOS and Voice: a change to either is
// made in all three, and the hashes in DeviceSyncSharedFiles with it.

/// What iOS syncs, and can do.
private let iosFields: Set<String> = ["kb", "composition", "action"]
private let iosCapabilities: Set<String> = ["legacy_out"]
/// More deliveries than any scenario needs: messages that never stop.
private let maxDeliveries = 100_000

/// A string's bytes: the vectors compare texts as JavaScript does, code unit by code unit, never by
/// canonical equivalence.
private func bytes(_ text: String) -> Data {
    Data(text.utf8)
}

private func sortedBytes(_ values: [Data]) -> [Data] {
    values.sorted { $0.lexicographicallyPrecedes($1) }
}

private func hex8(_ value: Int) -> String {
    let digits = String(value, radix: 16)
    return String(repeating: "0", count: max(0, 8 - digits.count)) + digits
}

private func bulletField(_ value: Any?) throws -> BulletField {
    guard let name = value as? String, let field = BulletField(rawValue: name) else { throw DeviceSyncTestError("no field \(String(describing: value))") }
    return field
}

private func pair(_ value: Any?) throws -> (section: String, text: String) {
    guard let pair = value as? [String], pair.count == 2 else { throw DeviceSyncTestError("not a [section, text]: \(String(describing: value))") }
    return (pair[0], pair[1])
}

private func tuple(_ value: Any?) throws -> Bullet {
    guard let tuple = value as? [Any], tuple.count == 4, let section = tuple[0] as? String, let text = tuple[1] as? String,
          let name = tuple[2] as? String, let n = tuple[3] as? Int else { throw DeviceSyncTestError("not a bullet tuple: \(String(describing: value))") }
    return Bullet(section: section, text: text, name: name, n: n)
}

private func seenMap(_ value: Any?) throws -> [String: Int] {
    guard let map = value as? [String: Any] else { throw DeviceSyncTestError("not a seen map") }
    var seen: [String: Int] = [:]
    for (name, raw) in map {
        guard let n = raw as? Int else { throw DeviceSyncTestError("seen \(name) isn't a count") }
        seen[name] = n
    }
    return seen
}

private func seenBytes(_ seen: [String: Int]) -> [Data] {
    sortedBytes(seen.map { bytes(BulletJSON.string($0.key) + ":\($0.value)") })
}

@MainActor
private final class ScenarioRun {
    let scenario: [String: Any]
    let relay = BulletRelay()
    var devices: [String: BulletDevice] = [:]
    var stores: [DeviceDefaults] = []
    var backups: [String: DeviceDefaults] = [:]
    var captures: [String: (device: BulletDevice, field: BulletField, section: String, read: (text: String, captured: [Bullet]?))] = [:]
    let specs: [String: (index: Int, spec: [String: Any])]
    /// The step running, for the expectations' messages.
    var at = ""

    init(_ scenario: [String: Any]) {
        self.scenario = scenario
        let devices = scenario["devices"] as! [[String: Any]]
        var specs: [String: (index: Int, spec: [String: Any])] = [:]
        for (index, spec) in devices.enumerated() { specs[spec["id"] as! String] = (index + 1, spec) }
        self.specs = specs
    }

    func start() throws {
        for spec in scenario["devices"] as! [[String: Any]] {
            let init_ = spec["init"]
            if init_ as? String == "later" { continue }
            let store = init_ as? String == "shared" ? try named(spec["store"]).store : try initialStore(init_)
            try create(spec["id"] as! String, store)
        }
    }

    /// Removes every device's defaults.
    func dispose() {
        for store in stores { store.dispose() }
        for backup in backups.values { backup.dispose() }
    }

    func track(_ store: DeviceDefaults) -> DeviceDefaults {
        stores.append(store)
        return store
    }

    func initialStore(_ value: Any?) throws -> DeviceDefaults {
        let store = track(DeviceDefaults())
        if value as? String == "new" { return store }
        if value as? String == "empty" {
            store.storeStates([:])
            return store
        }
        if let object = value as? [String: Any], let legacy = object["legacy"] as? [String: String] {
            for (name, text) in legacy { store.defaults.set(text, forKey: UserDefaultsBulletStore.renderedKeys[try bulletField(name)]!) }
            return store
        }
        if let object = value as? [String: Any], let states = object["state"] as? [String: [String: Any]] {
            var given: [BulletField: (bullets: [Bullet], seen: [String: Int])] = [:]
            for (name, state) in states {
                given[try bulletField(name)] = (try (state["bullets"] as? [Any] ?? []).map(tuple), try seenMap(state["seen"] ?? [String: Any]()))
            }
            store.storeStates(given)
            return store
        }
        throw DeviceSyncTestError("unknown init \(String(describing: value))")
    }

    @discardableResult
    func create(_ id: String, _ store: DeviceDefaults) throws -> BulletDevice {
        guard let (index, spec) = specs[id] else { throw DeviceSyncTestError("no device spec \(id)") }
        var catalog = DeviceSyncSharedFiles.catalog
        for extra in spec["catalogExtra"] as? [[String: String]] ?? [] {
            catalog.defaults.append(DefaultCatalog.Entry(id: extra["id"]!, field: extra["field"]!, section: extra["section"]!, text: extra["text"]!))
        }
        let device = BulletDevice(id: id, store: store, relay: relay, name: { "\(hex8(index))\(hex8($0))" },
                                  budget: scenario["budget"] as? Int ?? BulletSyncConfig.messageMaxBytes, catalog: catalog)
        devices[id] = device
        device.start()
        return device
    }

    func named(_ id: Any?) throws -> BulletDevice {
        guard let id = id as? String, let device = devices[id] else { throw DeviceSyncTestError("no device \(String(describing: id))") }
        return device
    }

    /// Every pending part delivered to the devices that have yet to get it, oldest first.
    func quiesce() throws {
        var deliveries = 0
        while try relay.deliverOldest() {
            deliveries += 1
            if deliveries > maxDeliveries { throw DeviceSyncTestError("the devices never stop sending") }
        }
    }

    func run(_ step: [String: Any]) throws {
        switch step["op"] as? String {
        case "connect":
            try named(step["device"]).connect()
        case "disconnect":
            try named(step["device"]).disconnect()
        case "restart":
            try named(step["device"]).restart()
        case "add":
            try named(step["device"]).add(try bulletField(step["field"]), step["section"] as! String, step["text"] as! String)
        case "delete":
            try named(step["device"]).delete(try bulletField(step["field"]), step["section"] as! String, step["text"] as! String)
        case "edit":
            let from = try pair(step["from"])
            let to = try pair(step["to"])
            let device = try named(step["device"])
            let field = try bulletField(step["field"])
            if from.section == to.section {
                device.editSection(field, from.section) { texts in texts.map { Bullets.same($0, from.text) ? to.text : $0 } }
            } else {
                device.delete(field, from.section, from.text)
                device.add(field, to.section, to.text)
            }
        case "capture":
            let device = try named(step["device"])
            let field = try bulletField(step["field"])
            captures[step["as"] as! String] = (device, field, step["section"] as! String, device.prompts.readForEdit(field))
        case "commit":
            guard let capture = captures[step["capture"] as? String ?? ""] else { throw DeviceSyncTestError("no capture \(String(describing: step["capture"]))") }
            capture.device.commitRead(capture.field, capture.section, capture.read, step["result"] as! [String])
        case "reset":
            try named(step["device"]).reset(try bulletField(step["field"]))
        case "fail_next_save":
            try named(step["device"]).store.failNext = true
        case "copy":
            try create(step["to"] as! String, track(try named(step["from"]).store.copy()))
        case "backup":
            backups[step["as"] as! String] = try named(step["device"]).store.copy()
        case "restore":
            let device = try named(step["device"])
            guard let backup = backups[step["from"] as? String ?? ""] else { throw DeviceSyncTestError("no backup") }
            device.disconnect()
            device.store.replace(with: backup)
            device.restart()
        case "deliver":
            let id = step["msg"] as! String
            guard let snapshot = relay.snapshots[id] else { throw DeviceSyncTestError("no message \(id)") }
            var to = step["to"] as? [String] ?? []
            if step["to"] == nil {
                for entry in relay.pending where entry.snapshot === snapshot && !to.contains(entry.to) { to.append(entry.to) }
            }
            let parts = step["parts"] as? [Int] ?? snapshot.parts.keys.sorted()
            for device in to {
                for part in parts { try relay.deliver(id, to: device, part: part) }
            }
        case "drop":
            relay.drop(step["msg"] as! String, to: step["to"] as? [String], parts: step["parts"] as? [Int])
        case "quiesce":
            try quiesce()
        case "raw":
            try named(step["to"]).receive(step["message"] as! [String: Any])
        case "legacy":
            try named(step["to"]).receive(["type": "prompt_state", "data": step["data"] as! [String: Any]])
        case "expect":
            try expectState(step)
        case "expect_sent":
            let device = step["device"] as! String
            let field = step["field"] as! String
            #expect(relay.sent(device, field) == step["count"] as? Int, "\(at): \(device) \(field) snapshots sent")
        case "expect_quiet":
            #expect(relay.pending.map { "\($0.snapshot.id)/\($0.part) to \($0.to)" } == [], "\(at): quiet")
        case "expect_oversize":
            let device = try named(step["device"])
            let field = try bulletField(step["field"])
            let oversize: Bool
            if case .oversize = device.prompts.engine.outgoing(field) { oversize = true } else { oversize = false }
            #expect(oversize == step["value"] as? Bool, "\(at): \(device.id) \(field.rawValue) oversize")
        case "expect_legacy_out":
            expectLegacyOut()
        default:
            throw DeviceSyncTestError("unknown op \(String(describing: step["op"]))")
        }
    }

    func expectState(_ step: [String: Any]) throws {
        let device = try named(step["device"])
        let field = try bulletField(step["field"])
        let state = device.state(field)
        let what = "\(at): \(device.id) \(field.rawValue)"
        let items = sortedBytes(state.bullets.map { bytes(BulletJSON.string($0.section) + "," + BulletJSON.string($0.text)) })
        func itemBytes(_ value: Any?) throws -> Data {
            let (section, text) = try pair(value)
            return bytes(BulletJSON.string(section) + "," + BulletJSON.string(text))
        }
        if let live = step["live"] as? [Any] {
            let expected = sortedBytes(try live.map { bytes(BulletJSON.tuple(try tuple($0))) })
            #expect(sortedBytes(state.bullets.map { bytes(BulletJSON.tuple($0)) }) == expected, "\(what) live")
        }
        if let texts = step["texts"] as? [Any] {
            #expect(items == sortedBytes(try texts.map(itemBytes)), "\(what) texts")
        }
        for item in step["has"] as? [Any] ?? [] {
            #expect(items.contains(try itemBytes(item)), "\(what) has \(item)")
        }
        for item in step["lacks"] as? [Any] ?? [] {
            #expect(!items.contains(try itemBytes(item)), "\(what) lacks \(item)")
        }
        if let seen = step["seen"] {
            #expect(seenBytes(state.seen) == seenBytes(try seenMap(seen)), "\(what) seen")
        }
        // Once stored, the rendered text every reader reads is the stored state's (DS-ATOMIC).
        if let stored = device.store.storedState(field) {
            let rendered = device.store.defaults.string(forKey: UserDefaultsBulletStore.renderedKeys[field]!) ?? ""
            #expect(bytes(rendered) == bytes(Bullets.render(field, stored)), "\(what) rendered")
        }
    }

    /// DS-LEGACY-OUT: every prompt_state this app sends, its own or in answer to a released device's
    /// request_state, carries the three bullet fields empty at epoch zero.
    func expectLegacyOut() {
        let sync = DeviceSyncService.shared
        for fields in [SyncField.allCases, [.kb, .composition, .action, .templates]] {
            let state = sync.promptState(for: fields)
            #expect(state.kb == "" && state.composition == "" && state.action == "")
            #expect(state.kbUpdatedAt == Bullets.epochZero)
            #expect(state.compositionUpdatedAt == Bullets.epochZero)
            #expect(state.actionUpdatedAt == Bullets.epochZero)
        }
    }
}

@MainActor
@Suite("Device Sync shared conformance vectors")
struct DeviceSyncVectorsTests {
    nonisolated static let parseIDs: [String] = DeviceSyncSharedFiles.parseCases.map { $0["id"] as! String }
    nonisolated static let scenarioIDs: [String] = DeviceSyncSharedFiles.scenarios.map { $0["id"] as! String }
    nonisolated static let trimCodes: [String] = (DeviceSyncSharedFiles.vectors["conventions"] as? [String: Any])?["trim"] as? [String] ?? []

    /// R2: the same characters are trimmed on every platform, or a text one stores is one another refuses.
    @Test("Trims each R2 character at both ends and keeps it inside", arguments: trimCodes)
    func trimsEachCharacter(_ hex: String) throws {
        let scalar = try #require(UInt32(hex, radix: 16).flatMap(Unicode.Scalar.init))
        let character = String(scalar)
        #expect(Bullets.trim("\(character)\(character)a\(character)b\(character)") == "a\(character)b")
    }

    @Test("Trims nothing outside the R2 list")
    func trimsNothingElse() {
        #expect(Self.trimCodes.count == 25)
        #expect(Bullets.trim("\u{200B}a\u{0085}\u{180E}") == "\u{200B}a\u{0085}\u{180E}")
    }

    /// DS-CHUNK cuts parts by the message's bytes, so a text is written as `JSON.stringify` writes it:
    /// a control character without a short escape as `\u` and four lowercase hex digits, DEL and
    /// everything above it as itself.
    @Test("A text is written as JSON.stringify writes it, and reads back as itself")
    func writesAsJSONStringify() throws {
        let text = "a\u{0B}b\u{1B}c\u{00}d\u{1F}e\u{7F}f\u{08}\u{0C}\n\r\t\"\\g\u{2028}h"
        let written = BulletJSON.string(text)
        #expect(written == #""a\u000bb\u001bc\u0000d\u001fe"# + "\u{7F}" + #"f\b\f\n\r\t\"\\g"# + "\u{2028}" + #"h""#)
        let read = try JSONSerialization.jsonObject(with: Data("[\(written)]".utf8)) as? [String]
        #expect(read == [text])
    }

    @Test("The vectors and the catalog are the shared files, byte for byte")
    func sharedFiles() {
        let vectors = SHA256.hash(data: DeviceSyncSharedFiles.vectorsData).map { String(format: "%02x", $0) }.joined()
        let catalog = SHA256.hash(data: DeviceSyncSharedFiles.catalogData).map { String(format: "%02x", $0) }.joined()
        #expect(vectors == DeviceSyncSharedFiles.vectorsSHA256)
        #expect(catalog == DeviceSyncSharedFiles.catalogSHA256)
        #expect(DeviceSyncSharedFiles.vectors["catalogSha256"] as? String == DeviceSyncSharedFiles.catalogSHA256)
    }

    @Test("iOS runs every scenario")
    func runsEveryScenario() {
        let skipped = DeviceSyncSharedFiles.scenarios.filter { scenario in
            let fields = scenario["fields"] as? [String] ?? []
            let requires = scenario["requires"] as? [String] ?? []
            return !fields.allSatisfy(iosFields.contains) || !requires.allSatisfy(iosCapabilities.contains)
        }
        #expect(skipped.map { $0["id"] as! String } == [])
    }

    @Test("parse", arguments: parseIDs)
    func parse(id: String) throws {
        let vector = try #require(DeviceSyncSharedFiles.parseCases.first { $0["id"] as? String == id })
        let field = try bulletField(vector["field"])
        let parsed = Bullets.parse(field, vector["text"] as! String)
        #expect(parsed.head.map(bytes) == (vector["head"] as! [String]).map(bytes), "head")
        #expect(parsed.tail.map(bytes) == (vector["tail"] as! [String]).map(bytes), "tail")
        let expected = try (vector["bullets"] as! [Any]).map(pair)
        #expect(parsed.bullets.map { bytes($0.section) + bytes("\u{0}") + bytes($0.text) }
                == expected.map { bytes($0.section) + bytes("\u{0}") + bytes($0.text) }, "bullets")
        func labelled(_ items: [BulletItem]) -> [Bullet] {
            items.map { Bullet(section: $0.section, text: $0.text, name: "default:x", n: 1) }
        }
        let rendered = Bullets.render(field, head: parsed.head, tail: parsed.tail, bullets: labelled(parsed.bullets))
        if let render = vector["render"] as? String {
            #expect(bytes(rendered) == bytes(render), "render")
        }
        // Stable after one round: the rendered text parses to the same bullets, each section's in order
        // (render puts a repeated section's bullets together), and renders the same.
        let again = Bullets.parse(field, rendered)
        func bySection(_ items: [BulletItem]) -> [Data: [Data]] {
            Dictionary(grouping: items, by: { bytes($0.section) }).mapValues { $0.map { bytes($0.text) } }
        }
        #expect(bySection(again.bullets) == bySection(parsed.bullets), "parsed again")
        #expect(bytes(Bullets.render(field, head: again.head, tail: again.tail, bullets: labelled(again.bullets))) == bytes(rendered), "rendered again")
    }

    @Test("scenario", arguments: scenarioIDs)
    func scenario(id: String) throws {
        let scenario = try #require(DeviceSyncSharedFiles.scenarios.first { $0["id"] as? String == id })
        let run = ScenarioRun(scenario)
        defer { run.dispose() }
        try run.start()
        for (index, step) in (scenario["steps"] as! [[String: Any]]).enumerated() {
            run.at = "\(id) step \(index + 1)"
            do {
                try run.run(step)
            } catch {
                Issue.record("step \(index + 1) (\(step)): \(error)")
                return
            }
        }
    }
}
