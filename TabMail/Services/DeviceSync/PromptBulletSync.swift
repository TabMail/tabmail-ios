/* This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at https://mozilla.org/MPL/2.0/. */

import Foundation
import Security

enum BulletSyncConfig {
    /// The relay's budget for one message, under its 128 KiB cap with room to spare (DS-CHUNK). The
    /// same number as Thunderbird's and Voice's.
    static let messageMaxBytes = 126_976
    /// A writer name's random bytes (DS-NAME): 8 bytes, 16 hex digits.
    static let writerNameBytes = 8
    /// A received message the prompt store refused as busy through every retry is applied again after
    /// this, and again while it stays busy, until it applies or the connection ends (R32). The same as
    /// Thunderbird's `SETTINGS.deviceSync.busyReapplyMs`.
    static let busyReapplySeconds: Double = 2
    /// Received messages waiting to be applied on one connection, at most (R32), each part held for an
    /// incomplete snapshot counting as one: a store held so long that more pile up, or a sender that keeps
    /// restarting with a part lost each time, ends the connection, which drops them all, and every peer
    /// sends its state again on the next connect (R12). A connect brings a few messages per peer and field.
    static let maxWaitingReceives = 256
}

/// The bullet fields kept in `UserDefaults`: all three in ONE value (`device_sync_bullets`), so a
/// commit of several fields is one write (DS-ATOMIC), and each field's rendered text in the key every
/// reader reads (`user_prompts:user_<field>.md`), written right after. The rendered text is derived:
/// the labelled state is what is kept.
@MainActor
final class UserDefaultsBulletStore: BulletStore {
    static let stateKey = "device_sync_bullets"
    static let renderedKeys: [BulletField: String] = [
        .kb: "user_prompts:user_kb.md",
        .composition: "user_prompts:user_composition.md",
        .action: "user_prompts:user_action.md",
    ]
    /// The released merge's state, discarded at DS-UPGRADE (step 5).
    static let legacyMergeKeys = [
        "device_peer_base:kb", "device_peer_base:composition", "device_peer_base:action",
        "device_peer_base_ts:kb", "device_peer_base_ts:composition", "device_peer_base_ts:action",
        "device_sync_base:kb", "device_sync_base:composition", "device_sync_base:action",
    ]

    private let defaults: UserDefaults
    /// Called before a commit is written, with the fields whose text it changes (prompt history). False
    /// stops the commit: it writes nothing and reports itself unsaved (DS-HISTORY).
    var willCommit: ((BulletCommitKind, [BulletField]) -> Bool)?
    /// Called once a commit is written.
    var didCommit: ((BulletCommitKind, [BulletField]) -> Void)?

    init(defaults: UserDefaults) {
        self.defaults = defaults
    }

    /// R28: a stored value that can't be read is read as absent, so DS-UPGRADE runs again from the field's
    /// rendered text. Every text is kept; only deletions this device had merged may come back.
    func read(_ field: BulletField) -> FieldState? {
        guard let value = stored()?[field.rawValue] as? [String: Any] else { return nil }
        guard let state = Self.decode(value) else {
            BackgroundSyncLogger.logDebug("[DeviceSync] stored \(field.rawValue) bullets unreadable; read from its text")
            return nil
        }
        return state
    }

    func legacyText(_ field: BulletField) -> String? {
        defaults.string(forKey: Self.renderedKeys[field] ?? "")
    }

    func write(_ states: [BulletField: FieldState], kind: BulletCommitKind) -> Bool {
        let fields = BulletField.allCases.filter { states[$0] != nil }
        var texts: [BulletField: String] = [:]
        for field in fields { texts[field] = states[field].map { Bullets.render(field, $0) } }
        if willCommit?(kind, fields.filter { field in !Bullets.same(texts[field] ?? "", legacyText(field) ?? "") }) == false {
            BackgroundSyncLogger.logDebug("[DeviceSync] a commit of \(fields.map(\.rawValue)) was stopped: its history entry was not saved")
            return false
        }
        var all = stored() ?? [:]
        for field in fields {
            guard let state = states[field] else { continue }
            all[field.rawValue] = Self.encode(state)
        }
        guard let data = try? JSONSerialization.data(withJSONObject: all) else {
            BackgroundSyncLogger.logDebug("[DeviceSync] bullets could not be encoded (\(fields.map(\.rawValue)))")
            return false
        }
        defaults.set(data, forKey: Self.stateKey)
        for field in fields {
            guard let text = texts[field], let key = Self.renderedKeys[field] else { continue }
            defaults.set(text, forKey: key)
        }
        if kind == .upgrade {
            for key in Self.legacyMergeKeys { defaults.removeObject(forKey: key) }
        }
        didCommit?(kind, fields)
        return true
    }

    private func stored() -> [String: Any]? {
        guard let data = defaults.data(forKey: Self.stateKey) else { return nil }
        guard let value = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else {
            BackgroundSyncLogger.logDebug("[DeviceSync] stored bullets unreadable; read from the texts")
            return nil
        }
        return value
    }

    static func encode(_ state: FieldState) -> [String: Any] {
        [
            "head": state.head,
            "tail": state.tail,
            "bullets": state.bullets.map { [$0.section, $0.text, $0.name, $0.n] as [Any] },
            "seen": state.seen,
        ]
    }

    static func decode(_ value: [String: Any]) -> FieldState? {
        guard let head = value["head"] as? [String], let tail = value["tail"] as? [String],
              let tuples = value["bullets"] as? [[Any]], let seenValue = value["seen"] as? [String: Any] else { return nil }
        var bullets: [Bullet] = []
        for tuple in tuples {
            guard tuple.count == 4, let section = tuple[0] as? String, let text = tuple[1] as? String,
                  let name = tuple[2] as? String, let n = BulletJSON.count(tuple[3], least: 1) else { return nil }
            bullets.append(Bullet(section: section, text: text, name: name, n: n))
        }
        var seen: [String: Int] = [:]
        for (name, raw) in seenValue {
            guard let n = BulletJSON.count(raw, least: 0) else { return nil }
            seen[name] = n
        }
        return FieldState(head: head, tail: tail, bullets: bullets, seen: seen)
    }
}

/// A bullet as a screen shows it, with the labels it read in the same hold (DS-DISPLAYED).
struct ShownBullet: Identifiable, Sendable {
    let text: String
    fileprivate(set) var labels: [Bullet]

    /// Exact UTF-8 bytes, not the text as a `String`, whose equality treats canonically equivalent texts as
    /// one: two bullets whose texts differ only that way are two rows (`Bullets.same` keeps them apart).
    var id: [UInt8] { Array(text.utf8) }

    init(text: String, labels: [Bullet]) {
        self.text = text
        self.labels = labels
    }
}

/// A device's Device Sync of its three bullet fields, between the engine and the connection: what is
/// sent on connect, after a local change and after a merge that differed (DS-SEND), and what is done
/// with what arrives. Also the one way the app changes the fields (DS-LOCK): every edit, reset and
/// restore goes through here.
@MainActor
final class PromptBulletSync {
    let engine: BulletSync
    /// Sends a message on the connection: nil until the first connect, and kept after it, since
    /// `DeviceSyncService.sendBulletMessage` sends nothing while disconnected.
    var send: ((String) -> Void)?

    init(store: BulletStore, catalog: DefaultCatalog, skeleton: @escaping (BulletField) -> FieldSkeleton,
         newName: @escaping () -> String = PromptBulletSync.writerName,
         newID: @escaping () -> String = { UUID().uuidString.lowercased() },
         budget: @escaping () -> Int = { BulletSyncConfig.messageMaxBytes }) {
        engine = BulletSync(store: store, options: BulletSync.Options(
            fields: BulletField.allCases,
            skeleton: skeleton,
            newName: newName,
            newID: newID,
            budget: budget,
            error: { DeviceSyncLogger.log($0) },
            catalog: catalog
        ))
        engine.upgrade()
        engine.upgradeSaved = { [unowned self] fields in sendBulletState(fields) }
    }

    /// A fresh writer name: 8 random bytes as 16 lowercase hex digits (DS-NAME).
    nonisolated static func writerName() -> String {
        var bytes = [UInt8](repeating: 0, count: BulletSyncConfig.writerNameBytes)
        let status = SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes)
        precondition(status == errSecSuccess, "no random bytes for a writer name")
        return bytes.map { String(format: "%02x", $0) }.joined()
    }

    // MARK: - The connection

    /// Connected: every field's state goes out.
    func connected() {
        sendBulletState(BulletField.allCases)
    }

    func disconnected() {
        engine.disconnected()
    }

    /// The parts held for incomplete snapshots now (DS-RECEIVE, Bound).
    var heldParts: Int { engine.heldParts() }

    /// Sends `fields`' full state (DS-SEND). A field with one bullet over the relay's budget is not
    /// sent (logged by the engine).
    func sendBulletState(_ fields: [BulletField]) {
        guard let send else { return }
        for field in fields {
            guard case .messages(let messages) = engine.outgoing(field) else { continue }
            for message in messages { send(message) }
            BackgroundSyncLogger.logDebug("[DeviceSync] Sent bullet_state \(field.rawValue) (\(messages.count) part(s))")
        }
    }

    /// A message from the connection, as JSON values (DS-VALIDATE): a `bullet_state` merged, the bullet
    /// texts of a released device's `prompt_state` imported (DS-LEGACY-IN). Any other message isn't
    /// for the bullet fields. Returns what became of a `bullet_state` (ignored for anything else).
    @discardableResult
    func receive(_ message: [String: Any]) -> BulletReceiveResult {
        switch message["type"] as? String {
        case "bullet_state":
            return receiveBulletState(message)
        case "prompt_state":
            if let data = message["data"] as? [String: Any] { receiveLegacy(data) }
            return .ignored
        default:
            return .ignored
        }
    }

    /// A received `bullet_state` message (§6).
    private func receiveBulletState(_ message: [String: Any]) -> BulletReceiveResult {
        let result = engine.receive(message)
        if case .merged(let field, _, let differed) = result, differed { sendBulletState([field]) }
        return result
    }

    /// DS-LEGACY-IN of a released device's `prompt_state` data: additions only (never a deletion, never
    /// ordered by its timestamp; skipped at epoch zero). A changed field is shown and sent.
    private func receiveLegacy(_ data: [String: Any]) {
        let fields = engine.receiveLegacy(data)
        guard !fields.isEmpty else { return }
        BackgroundSyncLogger.logDebug("[DeviceSync] Imported additions from a released device (\(fields.map(\.rawValue)))")
        sendBulletState(fields)
    }

    // MARK: - Changes

    /// `field`'s text as the app shows it, and the labels it shows (DS-CAPTURE), to pass to
    /// `commitEdit`; no labels while an upgrade is unsaved (R22), when nothing may be committed.
    func readForEdit(_ field: BulletField) -> (text: String, captured: [Bullet]?) {
        let (state, captured) = engine.capture(field, sections: Bullets.displayedSections(field))
        return (Bullets.render(field, state), captured)
    }

    /// Saves `text` as `field`'s new text, deleting only the `captured` labels whose text it lacks
    /// (DS-CAPTURE).
    @discardableResult
    func commitEdit(_ field: BulletField, captured: [Bullet], text: String) -> BulletCommitResult {
        commit(engine.commitCapture([change(field, captured: captured, text: text)]))
    }

    /// DS-ADD of `items`.
    @discardableResult
    func add(_ field: BulletField, _ items: [BulletItem]) -> BulletCommitResult {
        commit(engine.add(field, items))
    }

    /// DS-DISPLAYED: the labels a screen showed deleted, those still live and no others.
    @discardableResult
    func deleteShown(_ field: BulletField, labels: [Bullet]) -> BulletCommitResult {
        commit(engine.delete(field, labels: labels))
    }

    /// The live bullets of `section` as a screen shows them (DS-RENDER: each text once), each with the
    /// labels it carries now (DS-DISPLAYED).
    func shown(_ field: BulletField, section: String) -> [ShownBullet] {
        var result: [ShownBullet] = []
        for bullet in engine.state(field).bullets where Bullets.same(bullet.section, section) {
            if let at = result.firstIndex(where: { Bullets.same($0.text, bullet.text) }) {
                result[at].labels.append(bullet)
            } else {
                result.append(ShownBullet(text: bullet.text, labels: [bullet]))
            }
        }
        return result
    }

    /// The bullets of one displayed section replaced by `texts`, in one read-change-save.
    @discardableResult
    func editSection(_ field: BulletField, section: String, texts: [String]) -> BulletCommitResult {
        guard let captured = engine.capture(field, sections: [section]).captured else {
            return BulletCommitResult(outcome: .unsaved, fields: [])
        }
        let result = texts.map { BulletItem(section: section, text: $0) }
        return commit(engine.commitCapture([BulletChange(field: field, captured: captured, result: result, skeleton: nil)]))
    }

    /// DS-RESET of `fields`.
    @discardableResult
    func reset(_ fields: [BulletField]) -> BulletCommitResult {
        commit(engine.reset(fields))
    }

    /// R13: a history entry's texts put back as one captured edit, in the sections this app shows (R6):
    /// labels whose text the entry lacks are deleted, its texts added, the writer name kept.
    @discardableResult
    func restore(_ texts: [BulletField: String]) -> BulletCommitResult {
        var changes: [BulletChange] = []
        for field in BulletField.allCases {
            guard let text = texts[field] else { continue }
            let shown = Bullets.displayedSections(field)
            guard let captured = engine.capture(field, sections: shown).captured else {
                return BulletCommitResult(outcome: .unsaved, fields: [])
            }
            let result = Bullets.parse(field, text).bullets.filter { item in shown.contains { Bullets.same($0, item.section) } }
            changes.append(BulletChange(field: field, captured: captured, result: result, skeleton: nil))
        }
        return commit(engine.commitCapture(changes))
    }

    func rendered(_ field: BulletField) -> String {
        Bullets.render(field, engine.state(field))
    }

    private func change(_ field: BulletField, captured: [Bullet], text: String) -> BulletChange {
        let parsed = Bullets.parse(field, text)
        let shown = Bullets.displayedSections(field)
        let result = parsed.bullets.filter { item in shown.contains { Bullets.same($0, item.section) } }
        let skeleton = field == .kb ? nil : FieldSkeleton(head: parsed.head, tail: parsed.tail)
        return BulletChange(field: field, captured: captured, result: result, skeleton: skeleton)
    }

    /// A local commit saved: the fields it changed go out (DS-SEND).
    private func commit(_ result: BulletCommitResult) -> BulletCommitResult {
        if result.outcome == .saved { sendBulletState(result.fields) }
        return result
    }
}
