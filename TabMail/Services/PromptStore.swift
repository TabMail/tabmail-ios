/* This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at https://mozilla.org/MPL/2.0/. */

import Foundation

// MARK: - Prompt History Entry

struct PromptHistoryEntry: Codable, Identifiable, Hashable {
    let id: String
    let timestamp: String
    let source: String // "local_edit", "reset", "sync_receive"
    let fields: [String] // which fields changed
    let composition: String
    let action: String
    let kb: String
    let templatesJSON: String // JSON-encoded [ReplyTemplate]

    var date: Date {
        Date.fromISO8601(timestamp) ?? .distantPast
    }

    var sourceLabel: String {
        switch source {
        case "local_edit": return "Edit"
        case "reset": return "Reset"
        case "sync_receive": return "Sync"
        default: return source
        }
    }

    var decodedTemplates: [ReplyTemplate] {
        guard let data = templatesJSON.data(using: .utf8) else { return [] }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return (try? decoder.decode([ReplyTemplate].self, from: data)) ?? []
    }
}

// MARK: - Reply Template

struct ReplyTemplate: Identifiable, Codable, Hashable, Sendable {
    var id: String
    var name: String
    var enabled: Bool
    var instructions: [String]
    var exampleReply: String
    var createdAt: Date
    var updatedAt: Date
    /// Soft-delete flag for CRDT sync. Deleted templates are kept as tombstones
    /// so the delete propagates to other devices via per-template merge.
    var deleted: Bool
    var deletedAt: Date?

    init(
        id: String = UUID().uuidString,
        name: String = "New Template",
        enabled: Bool = true,
        instructions: [String] = [],
        exampleReply: String = "",
        createdAt: Date = .now,
        updatedAt: Date = .now,
        deleted: Bool = false,
        deletedAt: Date? = nil
    ) {
        self.id = id
        self.name = name
        self.enabled = enabled
        self.instructions = instructions
        self.exampleReply = exampleReply
        self.createdAt = createdAt
        self.updatedAt = updatedAt
        self.deleted = deleted
        self.deletedAt = deletedAt
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(String.self, forKey: .id)
        name = try container.decode(String.self, forKey: .name)
        enabled = try container.decodeIfPresent(Bool.self, forKey: .enabled) ?? true
        instructions = try container.decodeIfPresent([String].self, forKey: .instructions) ?? []
        exampleReply = try container.decodeIfPresent(String.self, forKey: .exampleReply) ?? ""
        createdAt = try container.decodeIfPresent(Date.self, forKey: .createdAt) ?? .now
        updatedAt = try container.decodeIfPresent(Date.self, forKey: .updatedAt) ?? .now
        deleted = try container.decodeIfPresent(Bool.self, forKey: .deleted) ?? false
        deletedAt = try container.decodeIfPresent(Date.self, forKey: .deletedAt)
    }
}

// MARK: - Prompt Store

/// The sections the Settings lists show, and where each one lives in its field (DS-SECTION).
enum PromptSection: CaseIterable, Sendable {
    case writingStyle, language, usefulLinks, deleteRules, archiveRules, replyRules, noneRules, knowledgeBase

    var field: BulletField {
        switch self {
        case .writingStyle, .language, .usefulLinks: return .composition
        case .deleteRules, .archiveRules, .replyRules, .noneRules: return .action
        case .knowledgeBase: return .kb
        }
    }

    /// The section's key (DS-SECTION).
    var key: String {
        switch self {
        case .writingStyle: return "general"
        case .language: return "language"
        case .usefulLinks: return "links"
        case .deleteRules: return "delete"
        case .archiveRules: return "archive"
        case .replyRules: return "reply"
        case .noneRules: return "none"
        case .knowledgeBase: return ""
        }
    }
}

/// A field as an editor read it, with the labels it showed (DS-CAPTURE, DS-DISPLAYED): `commitEdit`
/// deletes only those of them whose text the edit removed, so a bullet that arrives while it is open is
/// never deleted by it. It carries the store's change counter as it was read (DS-COUNTER): an AI writer's
/// commit (DS-AI) is refused once that moved. The demo flag is snapshotted here (DS-DEMO): a capture taken
/// in the demo commits only to the demo, and one taken outside it only outside.
struct PromptCapture: Sendable {
    let field: BulletField
    let text: String
    fileprivate let labels: [Bullet]
    fileprivate let demo: Bool
    fileprivate let counter: UUID
}

enum PromptEditOutcome: Equatable, Sendable {
    case saved, unchanged
    /// It couldn't be saved; nothing changed.
    case unsaved
    /// An AI writer's counter moved since its read (DS-AI), the hold ran past its lease (DS-LEASE), or demo
    /// mode started or ended since the read (DS-DEMO): the write is dropped.
    case dropped
    /// The prompt store stayed held for the whole wait (DS-SEMAPHORE): nothing changed; try again in a
    /// moment.
    case busy
}

/// What an AI writer's read gave (DS-AI step 1): the capture, or why there is none (`.unsaved` while the
/// field's upgrade is unsaved, DS-UNSAVED-UPGRADE; `.busy`).
enum PromptReadOutcome: Sendable {
    case read(PromptCapture)
    case refused(PromptEditOutcome)
}

/// The prompt store inside a hold (DS-SEMAPHORE), given to `PromptStore.withPromptStore`'s body: the only
/// way to read or write the three bullet fields and their history. Every call checks that the hold is
/// still the holder immediately before it reads or writes (DS-LEASE) and throws `PromptRefusal.changed`
/// when it is not.
@MainActor
struct PromptAccess {
    fileprivate let store: PromptStore
    let hold: PromptHold

    private func check() throws {
        guard hold.isHolder else { throw PromptRefusal.changed }
    }

    /// `field`'s text now, and the labels it shows, to change and pass to `commitEdit`. Nil while an
    /// upgrade is unsaved (DS-UNSAVED-UPGRADE).
    func readForEdit(_ field: BulletField) throws -> PromptCapture? {
        try check()
        return store.readForEdit(field, counter: hold.counter)
    }

    /// Saves `text` as the captured field's new text (DS-CAPTURE).
    func commitEdit(_ capture: PromptCapture, text: String) throws -> PromptEditOutcome {
        try check()
        return store.commitEdit(capture, text: text)
    }

    /// DS-AI step 3: as `commitEdit`, refused with nothing written when the counter moved since the read.
    func commitAIEdit(_ capture: PromptCapture, text: String) throws -> PromptEditOutcome {
        try hold.requireUnchanged(since: capture.counter)
        return store.commitEdit(capture, text: text)
    }

    /// One read-change-save of `field`'s text: `transform` gets the text as it is now and returns the new
    /// one, or nil to leave it.
    func editText(_ field: BulletField, _ transform: (String) -> String?) throws -> PromptEditOutcome {
        try check()
        guard let capture = store.readForEdit(field, counter: hold.counter) else { return .unsaved }
        guard let updated = transform(capture.text) else { return .unchanged }
        return store.commitEdit(capture, text: updated)
    }

    func addBullet(_ text: String, to section: PromptSection) throws -> PromptEditOutcome {
        try check()
        return store.addBullet(text, to: section)
    }

    /// DS-DISPLAYED: deletes exactly the labels `shown` carried when it was displayed, those still live.
    /// `.unchanged` means they were already removed.
    func deleteShown(_ shown: ShownBullet, from section: PromptSection) throws -> PromptEditOutcome {
        try check()
        return store.deleteShown(shown, from: section)
    }

    /// DS-RESET of `field`.
    func reset(_ field: BulletField) throws {
        try check()
        store.resetBullets(field)
    }

    /// A history entry of the stored values now (DS-HISTORY).
    func recordHistory(source: String, fields: [String]) throws {
        try check()
        store.recordHistory(source: source, fields: fields)
    }

    func loadHistory() throws -> [PromptHistoryEntry] {
        try check()
        return store.loadHistory()
    }

    func saveHistory(_ entries: [PromptHistoryEntry]) throws {
        try check()
        store.saveHistory(entries)
    }

    /// DS-RESTORE.
    func restoreFromHistory(_ entry: PromptHistoryEntry) throws {
        try check()
        store.restoreFromHistory(entry)
    }

    /// A message from the connection (DS-VALIDATE): a `bullet_state` merged, a released device's
    /// `prompt_state` bullet texts imported (DS-LEGACY-IN).
    @discardableResult
    func receive(_ message: [String: Any]) throws -> BulletReceiveResult {
        try check()
        return store.bullets.receive(message)
    }

    /// Connected: every bullet field's state goes out (DS-SEND).
    func sendAll() throws {
        try check()
        store.bullets.connected()
    }
}

/// The knowledge base, the composition rules and the action rules, and the reply templates.
///
/// The three bullet fields are kept as labelled bullets by Device Sync's engine (`PromptBulletSync`),
/// which is the one way they change: every edit, reset, restore and merge is one read-change-save commit
/// of their bullets and, in the same commit, of their rendered markdown in TB's keys (DS-ATOMIC), which
/// every reader reads. `rawComposition`, `rawAction` and `rawKB` are that text. Every commit runs in a
/// hold of the device's one semaphore (`withPromptStore`, DS-LOCK).
///
/// Storage keys mirror TB's:
///   - `user_prompts:user_composition.md`
///   - `user_prompts:user_action.md`
///   - `user_prompts:user_kb.md`
///   - `user_templates` (JSON array)
@MainActor @Observable
final class PromptStore {
    static let shared = PromptStore()

    private let defaults = UserDefaults.standard

    @ObservationIgnored private let bulletStore: UserDefaultsBulletStore
    /// Device Sync of the three bullet fields; DeviceSyncService connects it.
    @ObservationIgnored let bullets: PromptBulletSync
    @ObservationIgnored private let catalog: DefaultCatalog
    /// DS-SEMAPHORE: this device's one semaphore for the knowledge base, writing style and action rules.
    @ObservationIgnored let semaphore: PromptSemaphore

    /// When true, incoming template sync is being applied — suppress broadcasting back to peers.
    private(set) var isSyncApplying = false

    /// Debounce task for recording history on local edits (2s quiet period).
    private var historyDebounceTask: Task<Void, Never>?
    private var pendingHistoryFields: Set<String> = []

    // MARK: - Rendered markdown (TB's format)

    /// Full composition markdown (writing style + language + links).
    private(set) var rawComposition: String

    /// Full action classification markdown (delete/archive/reply/none rules).
    private(set) var rawAction: String

    /// Knowledge base text.
    private(set) var rawKB: String

    /// Reply templates (JSON-encoded, same format as TB's `user_templates`).
    var templates: [ReplyTemplate] {
        didSet {
            saveTemplates()
            // Demo overlay (ADR-IOS-038): demo writes go to the demo key only —
            // no Device Sync broadcast/timestamps, no history.
            guard !DemoModeStore.isDemoActive else { return }
            if !isSyncApplying {
                DeviceSyncService.shared.debouncedBroadcast(fields: [.templates])
                debouncedRecordHistory(field: "templates")
            }
        }
    }

    // MARK: - Sections (for Settings)

    /// The bullets of `section` as shown.
    func bullets(_ section: PromptSection) -> [String] {
        Bullets.parse(section.field, raw(section.field)).bullets
            .filter { Bullets.same($0.section, section.key) }
            .map(\.text)
    }

    /// The bullets of `section` as a screen shows them, each with the labels it carries now
    /// (DS-DISPLAYED). In demo the overlay has no labels.
    func shown(_ section: PromptSection) -> [ShownBullet] {
        if DemoModeStore.isDemoActive { return bullets(section).map { ShownBullet(text: $0, labels: []) } }
        return bullets.shown(section.field, section: section.key)
    }

    var writingStyle: String { sectionText(.writingStyle) }
    var language: String { sectionText(.language) }
    var usefulLinks: String { sectionText(.usefulLinks) }
    var deleteRules: String { sectionText(.deleteRules) }
    var archiveRules: String { sectionText(.archiveRules) }
    var replyRules: String { sectionText(.replyRules) }
    var noneRules: String { sectionText(.noneRules) }
    var knowledgeBase: String { rawKB }

    private func sectionText(_ section: PromptSection) -> String {
        bullets(section).map { "- " + $0 }.joined(separator: "\n")
    }

    // MARK: - Init

    private init() {
        guard let url = Bundle.main.url(forResource: "device-sync-default-catalog", withExtension: "json"),
              let data = try? Data(contentsOf: url), let catalog = try? DefaultCatalog.decode(data) else {
            fatalError("The bundled Device Sync default catalog is missing or unreadable")
        }
        let bulletStore = UserDefaultsBulletStore(defaults: defaults)
        Self.writeMissingDefaults(bulletStore, defaults: defaults, catalog: catalog)
        let bullets = PromptBulletSync(store: bulletStore, catalog: catalog, skeleton: Self.skeleton)
        self.catalog = catalog
        self.bulletStore = bulletStore
        self.bullets = bullets
        semaphore = PromptSemaphore()
        rawComposition = bullets.rendered(.composition)
        rawAction = bullets.rendered(.action)
        rawKB = bullets.rendered(.kb)

        let d = UserDefaults.standard
        if let data = d.data(forKey: Keys.templates),
           let decoded = try? JSONDecoder().decode([ReplyTemplate].self, from: data) {
            self.templates = decoded
        } else if !d.bool(forKey: Keys.templatesInitialized) {
            self.templates = Defaults.templates
            // Set initialized flag AFTER successful encoding — prevents permanent
            // template loss if encoding fails (flag=true but no data persisted).
            if let data = try? JSONEncoder().encode(Defaults.templates) {
                d.set(data, forKey: Keys.templates)
                d.set(true, forKey: Keys.templatesInitialized)
            }
        } else {
            self.templates = []
        }

        bulletStore.willCommit = { [unowned self] kind, changedText in
            self.willCommitBullets(kind, changedText: changedText)
        }
        bulletStore.didCommit = { [unowned self] kind, fields in
            self.didCommitBullets(kind, fields: fields)
        }
        NSEDataBridge.mirrorPrompts()
    }

    /// A field with no stored text gets the defaults' text, which DS-UPGRADE then labels as the catalog
    /// defaults (DS-DEFAULT): the state a new install or a reset holds.
    static func writeMissingDefaults(_ store: UserDefaultsBulletStore, defaults: UserDefaults, catalog: DefaultCatalog) {
        for field in BulletField.allCases where store.read(field) == nil && store.legacyText(field) == nil {
            guard let key = UserDefaultsBulletStore.renderedKeys[field] else { continue }
            defaults.set(defaultText(field, catalog: catalog), forKey: key)
        }
    }

    /// The built-in skeleton (DS-SKELETON): the lines around the sections of TB's bundled prompt files.
    static func skeleton(_ field: BulletField) -> FieldSkeleton {
        let parsed: Bullets.Parsed
        switch field {
        case .kb: return .none
        case .composition: parsed = Bullets.parse(field, Defaults.composition)
        case .action: parsed = Bullets.parse(field, Defaults.action)
        }
        return FieldSkeleton(head: parsed.head, tail: parsed.tail)
    }

    /// `field`'s text as a new install holds it.
    static func defaultText(_ field: BulletField, catalog: DefaultCatalog) -> String {
        Bullets.render(field, Bullets.defaultState(field, skeleton: skeleton(field), catalog: catalog))
    }

    private func raw(_ field: BulletField) -> String {
        switch field {
        case .kb: return rawKB
        case .composition: return rawComposition
        case .action: return rawAction
        }
    }

    private func setRaw(_ field: BulletField, _ text: String) {
        switch field {
        case .kb: rawKB = text
        case .composition: rawComposition = text
        case .action: rawAction = text
        }
    }

    // MARK: - Bullet commits

    /// False vetoes the commit: DS-HISTORY, a history save that fails fails the reset or merge it comes
    /// before, so nothing is replaced without its record.
    private func willCommitBullets(_ kind: BulletCommitKind, changedText: [BulletField]) -> Bool {
        guard !changedText.isEmpty else { return true }
        // DS-HISTORY: a reset records the text it replaces, a merge the text before the merge, in the
        // committing hold and before the commit.
        switch kind {
        case .reset: return recordHistory(source: "reset", fields: changedText.map(\.rawValue))
        case .sync: return recordHistory(source: "sync_receive", fields: changedText.map(\.rawValue))
        case .edit, .upgrade: return true
        }
    }

    private func didCommitBullets(_ kind: BulletCommitKind, fields: [BulletField]) {
        // DS-COUNTER: an upgrade's save does not renew the counter.
        if kind != .upgrade { semaphore.renewCounter() }
        if fields.contains(.kb) { ReminderBuilder.invalidateCache() }
        NSEDataBridge.mirrorPrompts()
        // The demo shows its overlay; the real text is shown again on exit.
        guard !DemoModeStore.isDemoActive else { return }
        for field in fields {
            setRaw(field, UserDefaultsBulletStore.renderedKeys[field].flatMap { defaults.string(forKey: $0) } ?? "")
        }
        if kind == .edit {
            for field in fields { debouncedRecordHistory(field: field.rawValue) }
        }
    }

    // MARK: - The one way in (DS-SEMAPHORE)

    /// The one way to read or write the three bullet fields and their history (DS-SEMAPHORE): `body` runs
    /// holding this device's prompt semaphore, waiting for it in request order for a capped time
    /// (`PromptSemaphore.Config`), and releases it on every exit. It must be brief and must never wait on
    /// the AI: an AI writer reads with `readBeforeAI`, calls the AI holding nothing, and writes with
    /// `writeAfterRead`. Throws `PromptRefusal` (busy, or the hold lost the semaphore).
    func withPromptStore<T>(_ label: String, _ body: @MainActor (PromptAccess) async throws -> T) async throws -> T {
        try await semaphore.hold(label) { hold in
            try await body(PromptAccess(store: self, hold: hold))
        }
    }

    /// One brief read-change-save through `withPromptStore`, its refusal as the outcome.
    func edit(_ label: String, _ body: @MainActor (PromptAccess) throws -> PromptEditOutcome) async -> PromptEditOutcome {
        do {
            return try await withPromptStore(label) { try body($0) }
        } catch {
            return Self.outcome(error)
        }
    }

    /// An edit a gesture (a tap, a swipe, a confirmation) starts: it runs in a task, so the gesture's
    /// handler stays synchronous.
    @discardableResult
    func gesture(_ label: String, _ body: @escaping @MainActor (PromptAccess) throws -> PromptEditOutcome) -> Task<PromptEditOutcome, Never> {
        Task { await self.edit(label, body) }
    }

    /// An AI writer's read (DS-AI step 1), in one brief hold: `field` now and the labels it shows, with
    /// the change counter as read.
    func readBeforeAI(_ field: BulletField, _ label: String) async -> PromptReadOutcome {
        do {
            return try await withPromptStore(label) { access in
                guard let capture = try access.readForEdit(field) else { return .refused(.unsaved) }
                return .read(capture)
            }
        } catch {
            return .refused(Self.outcome(error))
        }
    }

    /// An AI writer's write (DS-AI step 3), in a second brief hold: refused with nothing written when the
    /// counter moved since `readBeforeAI`. The result is then dropped.
    func writeAfterRead(_ capture: PromptCapture, text: String, _ label: String) async -> PromptEditOutcome {
        await edit(label) { try $0.commitAIEdit(capture, text: text) }
    }

    /// A refusal as an edit's outcome.
    static func outcome(_ error: Error) -> PromptEditOutcome {
        switch error as? PromptRefusal {
        case .busy: return .busy
        case .changed: return .dropped
        case nil:
            BackgroundSyncLogger.logDebug("[PromptStore] unexpected error: \(error)")
            return .unsaved
        }
    }

    /// The change counter now, read with what a person sees (DS-COUNTER). Synchronous MainActor code that
    /// reads and writes with no await between needs nothing more.
    var changeSeen: UUID { semaphore.counter }

    // MARK: - Edits

    /// `field`'s text now, and the labels it shows, to change and pass to `commitEdit`. Nil while an
    /// upgrade is unsaved (DS-UNSAVED-UPGRADE): the field can't be saved, so the caller reports that and
    /// stops.
    fileprivate func readForEdit(_ field: BulletField, counter: UUID) -> PromptCapture? {
        if DemoModeStore.isDemoActive {
            return PromptCapture(field: field, text: raw(field), labels: [], demo: true, counter: counter)
        }
        let (text, captured) = bullets.readForEdit(field)
        guard let captured else {
            BackgroundSyncLogger.logDebug("[PromptStore] \(field.rawValue) read for editing refused: its upgrade is unsaved")
            return nil
        }
        return PromptCapture(field: field, text: text, labels: captured, demo: false, counter: counter)
    }

    /// Saves `text` as the captured field's new text (DS-CAPTURE). Device Sync sends it.
    fileprivate func commitEdit(_ capture: PromptCapture, text: String) -> PromptEditOutcome {
        guard capture.demo == DemoModeStore.isDemoActive else {
            BackgroundSyncLogger.logDebug("[PromptStore] \(capture.field.rawValue) edit dropped: demo mode \(capture.demo ? "ended" : "started") since it was read")
            return .dropped
        }
        if capture.demo {
            guard !Bullets.same(text, raw(capture.field)) else { return .unchanged }
            setDemoText(capture.field, text)
            return .saved
        }
        return Self.outcome(bullets.commitEdit(capture.field, captured: capture.labels, text: text))
    }

    /// What Settings says when a line holds a section-header mark or the END marker.
    static let sectionMarkerRefusal = "A line can't contain \"DO NOT EDIT/DELETE THIS SECTION HEADER\" or \"====END USER INSTRUCTIONS====\", so nothing changed."

    /// Whether `text` holds a line with the section-header mark or the END marker, which `section`'s
    /// field would read back as a header or the skeleton: Settings refuses it.
    static func holdsSectionMarker(_ text: String, in section: PromptSection) -> Bool {
        Bullets.parse(.kb, text).bullets.contains { Bullets.isMarkerText(section.field, $0.text) }
    }

    /// DS-ADD of `text`'s lines to `section`, each not already there; nothing when a line holds a
    /// section marker.
    fileprivate func addBullet(_ text: String, to section: PromptSection) -> PromptEditOutcome {
        let items = Bullets.parse(.kb, text).bullets.map { BulletItem(section: section.key, text: $0.text) }
        guard !items.isEmpty else { return .unchanged }
        guard !Self.holdsSectionMarker(text, in: section) else {
            BackgroundSyncLogger.logDebug("[PromptStore] \(section.key) line refused: it holds a section marker")
            return .unchanged
        }
        if DemoModeStore.isDemoActive {
            return editSectionInDemo(section) { texts in
                texts + items.map(\.text).filter { text in !texts.contains { Bullets.same($0, text) } }
            }
        }
        return Self.outcome(bullets.add(section.field, items))
    }

    /// DS-DISPLAYED of a shown bullet: exactly its labels, never a re-capture by text.
    fileprivate func deleteShown(_ shown: ShownBullet, from section: PromptSection) -> PromptEditOutcome {
        if DemoModeStore.isDemoActive {
            return editSectionInDemo(section) { texts in texts.filter { !Bullets.same($0, shown.text) } }
        }
        return Self.outcome(bullets.deleteShown(section.field, labels: shown.labels))
    }

    private static func outcome(_ result: BulletCommitResult) -> PromptEditOutcome {
        switch result.outcome {
        case .saved: return .saved
        case .unchanged: return .unchanged
        case .unsaved: return .unsaved
        }
    }

    // MARK: - Full prompt output (for LLM calls)

    /// Full composition prompt including templates, ready to send to backend.
    func compositionMarkdown() -> String {
        let templatePrompt = templatesAsPrompt()
        guard !templatePrompt.isEmpty else { return rawComposition }

        // Insert templates before ====END USER INSTRUCTIONS====
        let endMarker = "====END USER INSTRUCTIONS===="
        guard let range = rawComposition.range(of: endMarker) else {
            return rawComposition + "\n\n" + templatePrompt
        }
        let before = rawComposition[rawComposition.startIndex..<range.lowerBound].dropLast() // trim trailing newline
        let after = rawComposition[range.lowerBound...]
        return String(before) + "\n\n" + templatePrompt + "\n\n" + String(after)
    }

    /// Full action prompt, ready to send to backend.
    func actionMarkdown() -> String {
        rawAction
    }

    /// KB text, ready to send to backend.
    func kbText() -> String {
        rawKB
    }

    // MARK: - Action Compaction Config

    // Must match TB `SETTINGS.actionCompaction` and the backend's actionRuleBudget.ts.
    // Defaults keep 160 chars per rule; read through `ActionCompactConfig.local()`.
    nonisolated static let actionCompactThresholdKey = "action.compact.threshold"
    nonisolated static let defaultActionCompactThreshold = 200
    nonisolated static let actionCompactThresholdRange = 100...500
    nonisolated static let actionCompactThresholdStep = 10
    nonisolated static let actionCompactThresholdCharsKey = "action.compact.threshold.chars"
    nonisolated static let defaultActionCompactThresholdChars = 32000
    nonisolated static let actionCompactThresholdCharsRange = 16000...80000
    nonisolated static let actionCompactThresholdCharsStep = 1000
    /// Previous defaults — too aggressive; migrated to the current defaults when never edited.
    nonisolated static let legacyDefaultActionCompactThreshold = 100
    nonisolated static let legacyDefaultActionCompactThresholdChars = 16000

    // MARK: - Demo overlay key redirection (ADR-IOS-038)

    /// Demo-scoped storage key: while demo mode is active every prompt field
    /// persists to (and snapshots read from) a `demo.`-prefixed key, so demo
    /// chat tools (kb_add, reminder_add, template edits, …) can never touch
    /// the real prompts, and the real prompts can never leak into a demo
    /// recording. Identity outside demo. Nonisolated so the static snapshot
    /// readers honor the overlay too (chat KB injection reads the snapshot,
    /// not the MainActor property).
    nonisolated static func storageKey(_ base: String) -> String {
        DemoModeStore.isDemoActive ? "demo.\(base)" : base
    }

    // MARK: - Nonisolated Read Accessors (for background actors)

    /// Read KB text from any isolation context without MainActor hop.
    /// Reads directly from UserDefaults (thread-safe). Demo-aware (storageKey).
    nonisolated static func kbTextSnapshot() -> String {
        UserDefaults.standard.string(forKey: storageKey("user_prompts:user_kb.md")) ?? ""
    }

    /// Read action prompt from any isolation context without MainActor hop.
    /// Demo-aware (storageKey).
    nonisolated static func actionMarkdownSnapshot() -> String {
        UserDefaults.standard.string(forKey: storageKey("user_prompts:user_action.md")) ?? ""
    }

    /// Note: compositionMarkdown() includes template injection and must stay on MainActor.
    /// Background callers use the cached DispatchConfig snapshot from ActiveAIQueue.

    /// Enabled templates formatted as markdown for LLM prompt injection.
    func templatesAsPrompt() -> String {
        let enabled = templates.filter { $0.enabled && !$0.deleted }
        guard !enabled.isEmpty else { return "" }

        var lines: [String] = []
        lines.append("# Email template for standard replies (DO NOT EDIT/DELETE THIS SECTION HEADER)")

        for template in enabled {
            lines.append("")
            lines.append("## \(template.name)")
            for instruction in template.instructions {
                lines.append("- \(instruction)")
            }
            if !template.exampleReply.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                lines.append("- Example reply:")
                lines.append("```")
                lines.append(template.exampleReply)
                lines.append("```")
            }
        }

        return lines.joined(separator: "\n")
    }

    // MARK: - Reset
    // A bullet field's reset is DS-RESET: its bullets and seen map cleared together, the defaults added,
    // then sent, so peers' bullets come back (DS-MERGE). The templates keep an epoch-zero timestamp and
    // ask peers.

    fileprivate func resetBullets(_ field: BulletField) {
        // Demo overlay: reset the overlay only — no history, no sync.
        if DemoModeStore.isDemoActive {
            setDemoText(field, Self.defaultText(field, catalog: catalog))
            return
        }
        bullets.reset([field])
    }

    func resetTemplates() {
        if DemoModeStore.isDemoActive { templates = Defaults.templates; return }
        guard recordHistory(source: "reset", fields: ["templates"]) else { return }
        isSyncApplying = true
        templates = Defaults.templates
        isSyncApplying = false
        DeviceSyncService.shared.markFieldAsReset(.templates)
    }

    // MARK: - Template CRUD

    /// Templates visible to the user (excludes soft-deleted tombstones).
    var visibleTemplates: [ReplyTemplate] {
        templates.filter { !$0.deleted }
    }

    /// Every template the person creates (settings, marketplace, chat) comes
    /// through here; Device Sync merges through `mergeTemplates` instead.
    func addTemplate(_ template: ReplyTemplate = ReplyTemplate()) {
        templates.append(template)
        TutorialCoordinator.shared.discovered(.template)
    }

    func deleteTemplate(id: String) {
        guard let index = templates.firstIndex(where: { $0.id == id }) else { return }
        var template = templates[index]
        template.deleted = true
        template.deletedAt = .now
        template.updatedAt = .now
        templates[index] = template
    }

    func updateTemplate(_ template: ReplyTemplate) {
        guard let index = templates.firstIndex(where: { $0.id == template.id }) else { return }
        var updated = template
        updated.updatedAt = .now
        templates[index] = updated
    }

    /// CRDT per-template merge: per-id, newer updatedAt wins.
    /// Used for incoming Device Sync instead of full-array replacement.
    func mergeTemplates(_ incoming: [ReplyTemplate]) {
        var localMap: [String: ReplyTemplate] = [:]
        for t in templates { localMap[t.id] = t }

        var merged = 0
        for inTemplate in incoming {
            if let localTemplate = localMap[inTemplate.id] {
                if inTemplate.updatedAt > localTemplate.updatedAt {
                    localMap[inTemplate.id] = inTemplate
                    merged += 1
                }
            } else {
                localMap[inTemplate.id] = inTemplate
                merged += 1
            }
        }

        if merged > 0 {
            templates = Array(localMap.values)
        }
        BackgroundSyncLogger.logDebug("[PromptStore] CRDT template merge: \(merged) adopted from \(incoming.count) incoming (total: \(localMap.count))")
    }

    /// GC deleted template tombstones older than 90 days.
    func gcDeletedTemplates() {
        let now = Date()
        let gcAgeDays = 90
        let before = templates.count
        templates.removeAll { t in
            guard t.deleted, let deletedAt = t.deletedAt else { return false }
            return now.timeIntervalSince(deletedAt) > Double(gcAgeDays * 86400)
        }
        let removed = before - templates.count
        if removed > 0 {
            BackgroundSyncLogger.logDebug("[PromptStore] GC removed \(removed) deleted template tombstones older than \(gcAgeDays) days")
        }
    }

    // MARK: - Device Sync of the templates

    /// Replaces the templates (a history restore, a received merge's result), wrapped in `isSyncApplying`
    /// to prevent echo broadcasting. The callers record the history entry (DS-HISTORY).
    func applySyncedTemplates(_ templates: [ReplyTemplate]) {
        guard !DemoModeStore.isDemoActive else {
            BackgroundSyncLogger.logDebug("[PromptStore] applySyncedTemplates ignored during demo mode")
            return
        }
        isSyncApplying = true
        self.templates = templates
        isSyncApplying = false
    }

    // MARK: - Demo overlay lifecycle (ADR-IOS-038)

    /// Enter the demo prompt overlay: swap all four prompt fields to the
    /// bundled defaults. MUST be called with demo already active
    /// (`DemoModeStore.isDemoActive == true`) so the `didSet`s persist to the
    /// demo keys and skip NSE mirror / Device Sync / history. The real values
    /// stay untouched in their real UserDefaults keys.
    func enterDemoOverlay() {
        assert(DemoModeStore.isDemoActive, "enterDemoOverlay requires demo active")
        rawComposition = Defaults.composition
        rawAction = Defaults.action
        rawKB = Defaults.kb
        templates = Defaults.templates
        BackgroundSyncLogger.logDebug("[PromptStore] Demo prompt overlay ACTIVE (defaults seeded)")
    }

    /// Exit the demo prompt overlay: restore the real values from the real keys and delete the demo keys.
    /// MUST be called while demo is STILL active (before `DemoModeStore.isActive` flips false).
    func exitDemoOverlay() {
        assert(DemoModeStore.isDemoActive, "exitDemoOverlay requires demo still active")
        rawComposition = bullets.rendered(.composition)
        rawAction = bullets.rendered(.action)
        rawKB = bullets.rendered(.kb)
        if let data = defaults.data(forKey: Keys.templates),
           let decoded = try? JSONDecoder().decode([ReplyTemplate].self, from: data) {
            templates = decoded
        } else {
            templates = []
        }
        Self.removeDemoOverlayKeys()
        BackgroundSyncLogger.logDebug("[PromptStore] Demo prompt overlay REMOVED (real prompts restored)")
    }

    /// A demo write of a bullet field (DS-DEMO): the shown text and the demo key only.
    private func setDemoText(_ field: BulletField, _ text: String) {
        guard let key = UserDefaultsBulletStore.renderedKeys[field] else { return }
        semaphore.renewCounter()
        setRaw(field, text)
        defaults.set(text, forKey: "demo.\(key)")
        if field == .kb { ReminderBuilder.invalidateCache() }
    }

    /// One section of the demo's text changed by `change` (its bullets' texts in, the new ones out).
    private func editSectionInDemo(_ section: PromptSection, _ change: ([String]) -> [String]) -> PromptEditOutcome {
        let field = section.field
        let parsed = Bullets.parse(field, raw(field))
        let shown = parsed.bullets.filter { Bullets.same($0.section, section.key) }.map(\.text)
        let changed = change(shown)
        guard !Bullets.sameLines(changed, shown) else { return .unchanged }
        // Render puts each section's bullets under its header; the order of the others is kept.
        var items = parsed.bullets.filter { !Bullets.same($0.section, section.key) }
        items.append(contentsOf: changed.map { BulletItem(section: section.key, text: $0) })
        let unlabelled = items.map { Bullet(section: $0.section, text: $0.text, name: "", n: 0) }
        setDemoText(field, Bullets.render(field, head: parsed.head, tail: parsed.tail, bullets: unlabelled))
        return .saved
    }

    /// Delete the demo overlay UserDefaults keys. Safe to call anytime —
    /// also used by `DemoModeService.purgeOrphanedDemoData` to clean up after
    /// a force-quit mid-demo.
    nonisolated static func removeDemoOverlayKeys() {
        let d = UserDefaults.standard
        for base in ["user_prompts:user_composition.md", "user_prompts:user_action.md",
                     "user_prompts:user_kb.md", "user_templates"] {
            d.removeObject(forKey: "demo.\(base)")
        }
    }

    // MARK: - History

    private static let historyKey = "prompt_history"
    private static let maxHistoryEntries = 100
    private static let historyMigratedKey = "prompt_history_migrated"

    /// Debounced history recording for local edits (DS-HISTORY): waits 2 s of quiet, then records the
    /// state in its own hold.
    private func debouncedRecordHistory(field: String) {
        pendingHistoryFields.insert(field)
        historyDebounceTask?.cancel()
        // Scheduled from inside the edit's hold: the timer runs outside it, so its own hold is not refused
        // as nested (a task inherits the holder's task-local mark, MIS-IOS-028).
        historyDebounceTask = PromptSemaphore.$holding.withValue(nil) { Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(2000))
            guard !Task.isCancelled, let self else { return }
            let fields = Array(self.pendingHistoryFields)
            self.pendingHistoryFields = []
            do {
                try await self.withPromptStore("history record") { access in
                    try access.recordHistory(source: "local_edit", fields: fields)
                }
            } catch {
                BackgroundSyncLogger.logDebug("[PromptStore] local edit history entry not recorded: \(error)")
            }
        } }
    }

    /// Record a snapshot of the current state in history: the bullet fields' stored text. Never in demo,
    /// whose history reads as empty: the real history is kept as it is.
    /// False when the entry could not be saved (DS-HISTORY).
    @discardableResult
    fileprivate func recordHistory(source: String, fields: [String]) -> Bool {
        guard !DemoModeStore.isDemoActive else { return true }
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        guard let templatesData = try? encoder.encode(templates), let templatesStr = String(data: templatesData, encoding: .utf8) else {
            BackgroundSyncLogger.logDebug("[PromptStore] history entry not recorded: the templates could not be encoded")
            return false
        }

        let entry = PromptHistoryEntry(
            id: UUID().uuidString,
            timestamp: Date().ISO8601Format(),
            source: source,
            fields: fields,
            composition: defaults.string(forKey: Keys.composition) ?? "",
            action: defaults.string(forKey: Keys.action) ?? "",
            kb: defaults.string(forKey: Keys.kb) ?? "",
            templatesJSON: templatesStr
        )

        var history = loadHistory()
        history.append(entry)
        if history.count > Self.maxHistoryEntries {
            history = Array(history.suffix(Self.maxHistoryEntries))
        }
        return saveHistory(history)
    }

    /// Load all history entries (newest last). Empty during demo — the real prompt history must not be
    /// visible (or restorable) from a demo recording.
    fileprivate func loadHistory() -> [PromptHistoryEntry] {
        guard !DemoModeStore.isDemoActive else { return [] }
        migrateBackupsIfNeeded()
        guard let data = defaults.data(forKey: Self.historyKey),
              let entries = try? JSONDecoder().decode([PromptHistoryEntry].self, from: data) else {
            return []
        }
        return entries
    }

    /// Restore all prompt fields from a history entry (DS-RESTORE): the bullet fields as one captured
    /// edit of the sections this app shows, keeping the writer name (Device Sync sends them); the
    /// templates as before, with a fresh timestamp so the restore propagates to other devices.
    fileprivate func restoreFromHistory(_ entry: PromptHistoryEntry) {
        guard !DemoModeStore.isDemoActive else { return }
        guard recordHistory(source: "reset", fields: ["composition", "action", "kb", "templates"]) else { return }
        bullets.restore([.composition: entry.composition, .action: entry.action, .kb: entry.kb])
        applySyncedTemplates(entry.decodedTemplates)
        DeviceSyncService.shared.debouncedBroadcast(fields: [.templates])
    }

    // MARK: - Private

    private func saveTemplates() {
        if let data = try? JSONEncoder().encode(templates) {
            defaults.set(data, forKey: Self.storageKey(Keys.templates))
        }
    }

    @discardableResult
    fileprivate func saveHistory(_ entries: [PromptHistoryEntry]) -> Bool {
        guard let data = try? JSONEncoder().encode(entries) else {
            BackgroundSyncLogger.logDebug("[PromptStore] history not saved: the entries could not be encoded")
            return false
        }
        defaults.set(data, forKey: Self.historyKey)
        return true
    }

    /// One-time migration of existing device_sync_backups into prompt_history.
    private func migrateBackupsIfNeeded() {
        guard !defaults.bool(forKey: Self.historyMigratedKey) else { return }
        defaults.set(true, forKey: Self.historyMigratedKey)

        guard let backups = defaults.array(forKey: "device_sync_backups") as? [[String: Any]], !backups.isEmpty else { return }

        var entries: [PromptHistoryEntry] = []
        for backup in backups {
            let entry = PromptHistoryEntry(
                id: UUID().uuidString,
                timestamp: backup["timestamp"] as? String ?? "1970-01-01T00:00:00.000Z",
                source: "sync_receive",
                fields: ["composition", "action", "kb", "templates"],
                composition: backup["composition"] as? String ?? "",
                action: backup["action"] as? String ?? "",
                kb: backup["kb"] as? String ?? "",
                templatesJSON: backup["templates"] as? String ?? "[]"
            )
            entries.append(entry)
        }

        saveHistory(entries)
        BackgroundSyncLogger.logDebug("[PromptStore] Migrated \(entries.count) backup(s) to prompt history")
    }
}

// MARK: - Storage Keys (match TB's browser.storage.local keys for sync compatibility)

private extension PromptStore {
    enum Keys {
        static let composition = "user_prompts:user_composition.md"
        static let action = "user_prompts:user_action.md"
        static let kb = "user_prompts:user_kb.md"
        static let templates = "user_templates"
        static let templatesInitialized = "user_templates_initialized"
    }
}

// MARK: - Defaults (match TB's bundled prompt files)

private extension PromptStore {
    enum Defaults {
        static let composition = """
            # User provided composition instructions
            - Below are the user-defined instructions for composing emails.
            - Strictly follow these instructions in future responses.

            ====BEGIN USER INSTRUCTIONS====


            # General writing style (DO NOT EDIT/DELETE THIS SECTION HEADER)
            - ALWAYS sign off as the user using the **First Name Only**.
            - I want to sound friendly and professional, but not too formal.
            - ALWAYS start with a greeting.
            - I generally use Cheers or Best, depending on the context.

            # Language (DO NOT EDIT/DELETE THIS SECTION HEADER)
            - I write in English Only.

            # Useful links to personal website and other resources (DO NOT EDIT/DELETE THIS SECTION HEADER)


            ====END USER INSTRUCTIONS====

            Now, acknowledge these user instructions and do not deviate from them.
            """

        static let action = """
            # User provided action classification guidelines
            - Below are the user-defined action classification guidelines.
            - Strictly follow these guidelines in future responses.

            ====BEGIN USER INSTRUCTIONS====

            # Emails to be marked as `delete` (DO NOT EDIT/DELETE THIS SECTION HEADER)
            - All emails from spammy senders.

            # Emails to be marked as `archive` (DO NOT EDIT/DELETE THIS SECTION HEADER)
            - Professional newsletters digests.
            - Bugzilla bug update notifications sent to CC lists.
            - Financial documents.
            - Bank account notifications.
            - Shipment notifications.

            # Emails to be marked as `reply` (DO NOT EDIT/DELETE THIS SECTION HEADER)
            - Urgent requests for action.
            - Notifications about account compromise or data breaches that ask the user to review breach details and secure accounts.

            # Emails to be marked as `none` (DO NOT EDIT/DELETE THIS SECTION HEADER)
            - Emails that do not clearly fit into any of the other categories.

            ====END USER INSTRUCTIONS====

            Now, acknowledge these user instructions and do not deviate from them.
            """

        static let kb = """
            - User is using TabMail as their AI assistant for emails.
            - TabMail documentation is available at [TabMail Website's help page](https://tabmail.ai/docs/).
            - TabMail support is available at [TabMail Support](https://tabmail.ai/support).
            """

        /// Epoch date for default templates — ensures defaults always lose to real edits
        /// in per-template CRDT merge (newer `updatedAt` wins).
        private static let epoch = Date(timeIntervalSince1970: 0)

        static let templates: [ReplyTemplate] = [
            ReplyTemplate(
                id: "daeec4f2-1d74-4756-b440-537b179cf151",
                name: "No positions available",
                instructions: [
                    "Reply as below ignoring most of the sender's email making it apparent that this is a standard reply and not a personal one.",
                    "Do not complement/comment/paraphrase on the sender's email contents.",
                    "For all position inquiries",
                    "Use user company info from either knowledgebase, or if possible, infer from user email address.",
                ],
                exampleReply: "Hi [sender's first name],\n\nWe regret to let you know that there are currently no openings in [User Company]\nThank you very much for your interest.\n\nThanks,\n[User Company]",
                createdAt: epoch,
                updatedAt: epoch
            ),
            ReplyTemplate(
                id: "a1b2c3d4-5678-4abc-9def-111111111111",
                name: "Out of Office Auto-Reply",
                instructions: [
                    "This is an automatic out-of-office reply.",
                    "Keep it brief and professional.",
                    "Include the return date and alternative contact if provided in knowledgebase.",
                    "Do not engage with the content of the sender's email.",
                    "Do not include alternate contact if not found in knowledgebase.",
                ],
                exampleReply: "Hi [sender's first name],\n\nThank you for your email. I am currently out of the office with limited access to email and will return on [return date].\n\nFor urgent matters, please contact [alternative contact name] at [alternative contact email].\n\nI will respond to your email upon my return.\n\nBest regards,\n[User Name]",
                createdAt: epoch,
                updatedAt: epoch
            ),
            ReplyTemplate(
                id: "a1b2c3d4-5678-4abc-9def-444444444444",
                name: "Quick Acknowledgment",
                instructions: [
                    "Acknowledge receipt of an email, document, or request.",
                    "Keep it very brief.",
                    "Indicate when a full response or action can be expected if applicable.",
                    "Professional but warm tone.",
                ],
                exampleReply: "Hi [sender's first name],\n\nThank you for sending this over. I have received [item/document/request] and will review it shortly.\n\nI will get back to you by [expected response timeframe] with my feedback/response.\n\nThanks,\n[User Name]",
                createdAt: epoch,
                updatedAt: epoch
            ),
            ReplyTemplate(
                id: "a089b3d6-6beb-4a0e-94f2-bf1e8e15622a",
                name: "Support request initial reply",
                instructions: [
                    "Reply to support requests.",
                    "Be professional, and be compassionate.",
                    "Acknowledge the user's request.",
                    "Mention that we will get back to the request within either 2 days, or days defined in knowledgebase.",
                ],
                exampleReply: "Hello [Sender name],\n\n[Greet politely]\n[Acknowledgement and do a compassionate reply]\n\nWe will do our best to resolve your issue. We will be back on your request within the next [X] business days.\n\nBest regards,\n[User Company Name]",
                createdAt: epoch,
                updatedAt: epoch
            ),
            ReplyTemplate(
                id: "b2c24934-07f3-405a-a81c-9df318b77213",
                name: "Technical support request redirect",
                instructions: [
                    "Use for emails requesting technical support",
                    "Redirect to official channel defined in the template, or in the knowledgebase (prefer knowledgebase)",
                    "Polite but sound professional",
                    "Acknowledge user problem first to look compassionate",
                ],
                exampleReply: "Dear [Sender Name],\n\n[Acknowledge user problem and greetings]\n\nFor these technical problems, it is best to use the official support channel at [official support link].\nWe will do our best to resolve [the problem] as quickly as possible.\n\nThank you for your understanding.\n\nBest regards,\n[Company Name]",
                createdAt: epoch,
                updatedAt: epoch
            ),
        ]
    }
}
