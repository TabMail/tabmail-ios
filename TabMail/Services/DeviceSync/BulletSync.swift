/* This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at https://mozilla.org/MPL/2.0/. */

import Foundation

/// Where a device keeps its labelled bullets.
@MainActor
protocol BulletStore: AnyObject {
    /// The field as stored, nil when there is none yet.
    func read(_ field: BulletField) -> FieldState?
    /// The text kept before labelled bullets (DS-UPGRADE), nil when there is none.
    func legacyText(_ field: BulletField) -> String?
    /// Every state given, in one atomic write (DS-ATOMIC); false when it couldn't be saved, nothing
    /// changed then.
    func write(_ states: [BulletField: FieldState], kind: BulletCommitKind) -> Bool
}

enum BulletCommitKind: Sendable {
    case edit, reset, sync, upgrade
}

struct BulletCommitResult: Equatable, Sendable {
    enum Outcome: Sendable { case saved, unchanged, unsaved }
    var outcome: Outcome
    /// The fields the commit changed, saved.
    var fields: [BulletField]
}

enum BulletReceiveResult: Equatable, Sendable {
    case ignored
    case invalid(reason: String)
    case partial
    case conflict(BulletField)
    case unsaved(BulletField)
    case merged(BulletField, changed: Bool, send: Bool)
}

enum BulletOutgoing: Equatable, Sendable {
    case messages([String])
    /// One bullet alone, or the message with no bullet in it (the seen list alone), is over the budget (DS-OVERSIZE).
    case oversize(bytes: Int, budget: Int)
}

/// One field's change in a DS-CAPTURE commit: `result` the operation's bullets for what it captured,
/// and `skeleton` the field's new skeleton lines when the operation edited them.
struct BulletChange: Sendable {
    var field: BulletField
    var captured: [Bullet]
    var result: [BulletItem]
    var skeleton: FieldSkeleton?
}

/// One device's Device Sync of its labelled bullets: the local operations, each one read-change-save
/// commit (DS-LOCK: everything runs on the main actor and no operation suspends between its read and
/// its write, so each one sees the store as the one before it left it), the messages it sends and the
/// merge of those it receives. Free of the transport and of storage: the caller sends what `outgoing`
/// gives, passes `receive` what arrives, and supplies the store.
@MainActor
final class BulletSync {
    struct Options {
        /// The fields this app syncs.
        var fields: [BulletField]
        /// The built-in skeleton (DS-SKELETON).
        var skeleton: (BulletField) -> FieldSkeleton
        /// A fresh writer name: 16 lowercase hex from a cryptographic source.
        var newName: () -> String
        /// A random id for the sender and each snapshot.
        var newID: () -> String
        /// The relay's budget for one message, in bytes (DS-CHUNK).
        var budget: () -> Int
        /// Logs an error: field and reason, label or sizes, never a text.
        var error: (String) -> Void
        var catalog: DefaultCatalog
    }

    private struct BufferKey: Hashable {
        let sender: String
        let field: BulletField
    }

    private struct Buffer {
        var snap: String
        var parts: Int
        var seen: [String: Int]
        var received: [Int: String] = [:]
        var bullets: [Int: [Bullet]] = [:]
    }

    private let store: BulletStore
    let options: Options
    /// This process's sender id (DS-WIRE), never persisted.
    let sender: String
    /// The current writer name and its last counter: memory only (DS-NAME).
    private var writer: (name: String, n: Int)?
    /// The names on the bullets of the last complete snapshot merged for each field (DS-SEEN-OUT).
    private var lastMerged: [BulletField: [String]] = [:]
    /// Parts of incomplete snapshots, per sender and field (DS-CHUNK).
    private var buffers: [BufferKey: Buffer] = [:]
    /// Called with the fields an upgrade saved, whichever read or commit ran it (R20: they are sent).
    var upgradeSaved: (([BulletField]) -> Void)?

    init(store: BulletStore, options: Options) {
        self.store = store
        self.options = options
        sender = options.newID()
    }

    /// `field` as it is now, after DS-UPGRADE when it hasn't run; a new install's defaults when nothing
    /// is stored (DS-DEFAULT).
    func state(_ field: BulletField) -> FieldState {
        upgraded()[field] ?? stored(field)
    }

    /// DS-UPGRADE of every field that needs it, in one commit.
    func upgrade() {
        _ = upgraded()
    }

    /// DS-ADD of `items`.
    func add(_ field: BulletField, _ items: [BulletItem]) -> BulletCommitResult {
        commit([(field, { Bullets.add($0, items, self.labels()) })], kind: .edit)
    }

    /// DS-DISPLAYED: the shown `labels` deleted when still live, nothing else; nothing changes (and
    /// `.unchanged` says "already removed") when none of them is live any more.
    func delete(_ field: BulletField, labels shown: [Bullet]) -> BulletCommitResult {
        let gone = Set(shown.map(BulletLabelKey.init))
        return commit([(field, { state in
            var next = state
            next.bullets.removeAll { gone.contains(BulletLabelKey($0)) }
            return next
        })], kind: .edit)
    }

    /// DS-CAPTURE: the field as it is now and the live labels of `sections` (all when nil), to commit
    /// against later. While a DS-UPGRADE is unsaved there are no labels to commit against (R22): the
    /// upgrade, once saved, names its bullets anew, so the state is for showing only.
    func capture(_ field: BulletField, sections: [String]? = nil) -> (state: FieldState, captured: [Bullet]?) {
        let pending = upgraded()
        let state = pending[field] ?? stored(field)
        guard pending.isEmpty else { return (state, nil) }
        let captured = state.bullets.filter { bullet in sections?.contains { Bullets.same($0, bullet.section) } ?? true }
        return (state, captured)
    }

    /// DS-CAPTURE's commit, of one or more fields in one write.
    func commitCapture(_ changes: [BulletChange]) -> BulletCommitResult {
        commit(changes.map { change in
            (change.field, { state in
                // R23: no writer makes a marker text a bullet.
                let result = change.result.filter { !Bullets.isMarkerText(change.field, $0.text) }
                var next = Bullets.commitCapture(state, captured: change.captured, result: result, self.labels())
                if let skeleton = change.skeleton {
                    next.head = skeleton.head
                    next.tail = skeleton.tail
                }
                return next
            })
        }, kind: .edit)
    }

    /// DS-RESET of `fields`, in one commit: bullets and seen map cleared together, the defaults added,
    /// the writer name abandoned.
    func reset(_ fields: [BulletField]) -> BulletCommitResult {
        abandonName()
        var states: [BulletField: FieldState] = [:]
        for field in fields {
            states[field] = Bullets.defaultState(field, skeleton: options.skeleton(field), catalog: options.catalog)
        }
        let ordered = BulletField.allCases.filter { states[$0] != nil }
        return write(states, kind: .reset) ? BulletCommitResult(outcome: .saved, fields: ordered) : BulletCommitResult(outcome: .unsaved, fields: [])
    }

    /// The parts held for incomplete snapshots (DS-CHUNK): each counts toward the receive bound
    /// (DS-RECEIVE, Bound) as one waiting message.
    func heldParts() -> Int {
        buffers.values.reduce(0) { $0 + $1.received.count }
    }

    /// The connection ended: incomplete snapshots are dropped (DS-CHUNK).
    func disconnected() {
        buffers.removeAll()
    }

    /// DS-LEGACY-IN: a released device's `prompt_state` data, additions only. Returns the fields it
    /// changed, saved.
    func receiveLegacy(_ data: [String: Any]) -> [BulletField] {
        var changed: [BulletField] = []
        for field in options.fields {
            guard let text = data[field.rawValue] as? String else { continue }
            // Released Thunderbird's and iOS's own reading of the time.
            let time = Self.legacyTime(data["\(field.rawValue)_updated_at"]) ?? Self.legacyTime(data["updatedAt"]) ?? Bullets.epochZero
            if time == Bullets.epochZero { continue }
            let result = commit([(field, { Bullets.importLegacy(field, $0, text: text, self.labels(), catalog: self.options.catalog) })], kind: .sync)
            if result.outcome == .saved { changed.append(field) }
        }
        return changed
    }

    /// A JavaScript `a || b` reading of a time: a non-empty string, else the next one.
    private static func legacyTime(_ value: Any?) -> String? {
        guard let text = value as? String, !text.isEmpty else { return nil }
        return text
    }

    /// A `bullet_state` message: validated (DS-VALIDATE), buffered until complete (DS-CHUNK-APPLY),
    /// then merged (§6).
    func receive(_ message: [String: Any]) -> BulletReceiveResult {
        guard (message["type"] as? String) == "bullet_state" else { return .ignored }
        guard let fieldName = message["field"] as? String, let field = BulletField(rawValue: fieldName) else {
            return invalid(message["field"] is String ? "unknown" : "non-string", "field")
        }
        guard options.fields.contains(field) else { return .ignored }
        // R27: a sender or snap that is not a string fails DS-VALIDATE, and nothing buffered is dropped.
        guard let sender = message["sender"] as? String else { return invalid(field.rawValue, "sender") }
        guard let snap = message["snap"] as? String else { return invalid(field.rawValue, "snap") }
        let key = BufferKey(sender: sender, field: field)
        // R19: a refused part drops the incomplete snapshot buffered for its sender and field, whatever
        // its snap.
        func refuse(_ reason: String) -> BulletReceiveResult {
            buffers[key] = nil
            return invalid(field.rawValue, reason)
        }
        guard BulletJSON.isOne(message["v"]) else { return refuse("version") }
        guard let parts = BulletJSON.count(message["parts"], least: 1),
              let part = BulletJSON.count(message["part"], least: 1), part <= parts else {
            return refuse("part")
        }
        let bullets: [Bullet]
        switch Self.validBullets(field, message["bullets"]) {
        case .failure(let reason): return refuse(reason.rawValue)
        case .success(let valid): bullets = valid
        }
        guard let seen = Self.validSeen(message["seen"]) else { return refuse("seen") }

        var buffer = buffers[key] ?? Buffer(snap: snap, parts: parts, seen: seen)
        // A part of another snapshot from the same sender for the field replaces what was buffered.
        if buffers[key] == nil || !Bullets.same(buffer.snap, snap) {
            buffer = Buffer(snap: snap, parts: parts, seen: seen)
        }
        let content = BulletJSON.tuples(bullets)
        // R5: parts that disagree drop the snapshot; an identical duplicate part is ignored.
        if buffer.parts != parts || buffer.seen != seen || (buffer.received[part].map { !Bullets.same($0, content) } ?? false) {
            buffers[key] = nil
            return invalid(field.rawValue, "part")
        }
        buffer.received[part] = content
        buffer.bullets[part] = bullets
        guard buffer.received.count >= parts else {
            buffers[key] = buffer
            return .partial
        }
        buffers[key] = nil
        var all: [Bullet] = []
        for index in 1...parts { all.append(contentsOf: buffer.bullets[index] ?? []) }
        return mergeSnapshot(field, bullets: all, seen: seen)
    }

    /// What to send for `field` now (DS-WIRE, DS-SEEN-OUT, DS-CHUNK).
    func outgoing(_ field: BulletField) -> BulletOutgoing {
        // DS-UPGRADE step 6: commit, then send. An upgrade not saved yet is shown, never sent.
        if !upgraded().isEmpty { return .messages([]) }
        let state = stored(field)
        var names: [String] = []
        var listed = Set<String>()
        for name in state.bullets.map(\.name) + (lastMerged[field] ?? []) where !listed.contains(name) {
            listed.insert(name)
            names.append(name)
        }
        let seen = names.compactMap { name in state.seen[name].map { (name: name, n: $0) } }
        let snap = options.newID()
        let budget = options.budget()
        func message(_ part: Int, _ parts: Int, _ bullets: [Bullet]) -> String {
            BulletJSON.message(field: field, sender: sender, snap: snap, part: part, parts: parts, bullets: bullets, seen: seen)
        }
        let whole = message(1, 1, state.bullets)
        if BulletJSON.byteLength(whole) <= budget { return .messages([whole]) }
        // Measured with the largest part number there can be, so a part's number never takes it over.
        let most = max(1, state.bullets.count)
        let envelope = BulletJSON.byteLength(message(most, most, []))
        // The seen list alone can make the envelope too big for the relay (a field with no live bullet left
        // sends one empty group): nothing is sent, as when one bullet is too big.
        if envelope > budget {
            options.error("DeviceSync: \(field.rawValue) not sent: the message with no bullet is \(envelope) bytes, over the relay's \(budget)")
            return .oversize(bytes: envelope, budget: budget)
        }
        var groups: [[Bullet]] = []
        var group: [Bullet] = []
        var size = envelope
        for bullet in state.bullets {
            let bytes = BulletJSON.byteLength(BulletJSON.tuple(bullet))
            if envelope + bytes > budget {
                options.error("DeviceSync: \(field.rawValue) not sent: one bullet makes a \(envelope + bytes)-byte message, over the relay's \(budget)")
                return .oversize(bytes: envelope + bytes, budget: budget)
            }
            let added = group.isEmpty ? bytes : bytes + 1
            if size + added > budget {
                groups.append(group)
                group = []
                size = envelope
            }
            size += group.isEmpty ? bytes : bytes + 1
            group.append(bullet)
        }
        groups.append(group)
        return .messages(groups.enumerated().map { message($0.offset + 1, groups.count, $0.element) })
    }

    private func mergeSnapshot(_ field: BulletField, bullets: [Bullet], seen: [String: Int]) -> BulletReceiveResult {
        // Nothing is merged into an upgrade not saved yet: the upgrade commits all its fields at once.
        if !upgraded().isEmpty { return .unsaved(field) }
        let local = stored(field)
        switch Bullets.merge(local, bullets: bullets, seen: seen) {
        case .conflict(let name, let n):
            options.error("DeviceSync: \(field.rawValue) refused: label \(name)/\(n) holds another text or section")
            return .conflict(field)
        case .merged(let state, let differed):
            let changed = !Bullets.sameState(local, state)
            if changed, !write([field: state], kind: .sync) { return .unsaved(field) }
            var names: [String] = []
            var listed = Set<String>()
            for bullet in bullets where !listed.contains(bullet.name) {
                listed.insert(bullet.name)
                names.append(bullet.name)
            }
            lastMerged[field] = names
            return .merged(field, changed: changed, send: differed)
        }
    }

    private func invalid(_ field: String, _ reason: String) -> BulletReceiveResult {
        options.error("DeviceSync: a \(field) snapshot dropped (\(reason))")
        return .invalid(reason: reason)
    }

    private func stored(_ field: BulletField) -> FieldState {
        store.read(field) ?? Bullets.defaultState(field, skeleton: options.skeleton(field), catalog: options.catalog)
    }

    /// DS-UPGRADE: each field with no labelled state yet but a text from before is parsed and
    /// labelled, all in one commit. Returns the states when that couldn't be saved, for reading until
    /// it can.
    private func upgraded() -> [BulletField: FieldState] {
        var states: [BulletField: FieldState] = [:]
        for field in options.fields where store.read(field) == nil {
            if let text = store.legacyText(field) {
                states[field] = Bullets.upgrade(field, text: text, labels(), catalog: options.catalog)
            }
        }
        if states.isEmpty { return [:] }
        guard write(states, kind: .upgrade) else { return states }
        upgradeSaved?(BulletField.allCases.filter { states[$0] != nil })
        return [:]
    }

    /// One read-change-save commit (DS-LOCK) of each field given, in one write, after DS-UPGRADE.
    private func commit(_ changes: [(BulletField, (FieldState) -> FieldState)], kind: BulletCommitKind) -> BulletCommitResult {
        if !upgraded().isEmpty { return BulletCommitResult(outcome: .unsaved, fields: []) }
        var states: [BulletField: FieldState] = [:]
        for (field, change) in changes {
            let before = states[field] ?? stored(field)
            let after = change(before)
            if !Bullets.sameState(before, after) { states[field] = after }
        }
        let fields = BulletField.allCases.filter { states[$0] != nil }
        if fields.isEmpty { return BulletCommitResult(outcome: .unchanged, fields: []) }
        return write(states, kind: kind) ? BulletCommitResult(outcome: .saved, fields: fields) : BulletCommitResult(outcome: .unsaved, fields: [])
    }

    /// Writes `states`; when that fails, the writer name is abandoned (DS-NAME-ABANDON, R7).
    private func write(_ states: [BulletField: FieldState], kind: BulletCommitKind) -> Bool {
        let saved = store.write(states, kind: kind)
        if !saved { abandonName() }
        return saved
    }

    private func abandonName() {
        writer = nil
    }

    /// Labels under the current writer name, a fresh one when there is none (DS-NAME, DS-ORDER).
    private func labels() -> BulletLabels {
        BulletLabels { [self] in
            var current = writer ?? (name: options.newName(), n: 0)
            current.n += 1
            writer = current
            return current
        }
    }

    // MARK: - Validation (DS-VALIDATE)

    private enum BulletsFault: String, Error {
        case bullets, bullet, section, text, marker, name, counter
    }

    /// The bullets of a part of `field`, or the reason they are dropped.
    private static func validBullets(_ field: BulletField, _ value: Any?) -> Result<[Bullet], BulletsFault> {
        guard let entries = value as? [Any] else { return .failure(.bullets) }
        var bullets: [Bullet] = []
        for entry in entries {
            guard let tuple = entry as? [Any], tuple.count == 4 else { return .failure(.bullet) }
            guard let section = tuple[0] as? String else { return .failure(.section) }
            guard let text = tuple[1] as? String, !text.isEmpty, Bullets.same(Bullets.trim(text), text), !Bullets.hasLineBreak(text) else {
                return .failure(.text)
            }
            guard !Bullets.isMarkerText(field, text) else { return .failure(.marker) }
            guard let name = tuple[2] as? String, Bullets.isName(name) else { return .failure(.name) }
            guard let n = BulletJSON.count(tuple[3], least: 1) else { return .failure(.counter) }
            bullets.append(Bullet(section: section, text: text, name: name, n: n))
        }
        return .success(bullets)
    }

    /// The seen map of a part, or nil when a key isn't a name (R18) or a value isn't an integer >= 0.
    private static func validSeen(_ value: Any?) -> [String: Int]? {
        guard let map = value as? [String: Any] else { return nil }
        var seen: [String: Int] = [:]
        for (name, raw) in map {
            guard Bullets.isName(name), let n = BulletJSON.count(raw, least: 0) else { return nil }
            seen[name] = n
        }
        return seen
    }
}
