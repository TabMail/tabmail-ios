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

/// Stores user prompts as raw markdown strings matching TB's `browser.storage.local` format.
/// The raw markdown is the source of truth — UI sections are parsed from and reconstructed into it.
/// This makes cross-platform sync trivial: just push/pull the raw strings.
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

    /// When true, incoming sync is being applied — suppress broadcasting back to peers.
    private(set) var isSyncApplying = false

    /// Debounce task for recording history on local edits (2s quiet period).
    private var historyDebounceTask: Task<Void, Never>?
    private var pendingHistoryFields: Set<String> = []

    // MARK: - Raw markdown (source of truth, sync-compatible with TB)

    /// Full composition markdown (writing style + language + links).
    /// Set this directly when receiving sync data from another TabMail instance.
    var rawComposition: String {
        didSet {
            defaults.set(rawComposition, forKey: Self.storageKey(Keys.composition))
            // Demo overlay (ADR-IOS-038): demo writes go to the demo key only —
            // no NSE mirror, no Device Sync broadcast/timestamps, no history.
            guard !DemoModeStore.isDemoActive else { return }
            NSEDataBridge.mirrorPrompts()
            if !isSyncApplying {
                DeviceSyncService.shared.debouncedBroadcast(fields: [.composition])
                debouncedRecordHistory(field: "composition")
            }
        }
    }

    /// Full action classification markdown (delete/archive/reply/none rules).
    /// Set this directly when receiving sync data from another TabMail instance.
    var rawAction: String {
        didSet {
            defaults.set(rawAction, forKey: Self.storageKey(Keys.action))
            // Demo overlay — see rawComposition.
            guard !DemoModeStore.isDemoActive else { return }
            NSEDataBridge.mirrorPrompts()
            if !isSyncApplying {
                DeviceSyncService.shared.debouncedBroadcast(fields: [.action])
                debouncedRecordHistory(field: "action")
            }
        }
    }

    /// Knowledge base text.
    /// Set this directly when receiving sync data from another TabMail instance.
    var rawKB: String {
        didSet {
            ReminderBuilder.invalidateCache()
            defaults.set(rawKB, forKey: Self.storageKey(Keys.kb))
            // Demo overlay — see rawComposition.
            guard !DemoModeStore.isDemoActive else { return }
            NSEDataBridge.mirrorPrompts()
            if !isSyncApplying {
                DeviceSyncService.shared.debouncedBroadcast(fields: [.kb])
                debouncedRecordHistory(field: "kb")
            }
        }
    }

    /// Reply templates (JSON-encoded, same format as TB's `user_templates`).
    var templates: [ReplyTemplate] {
        didSet {
            saveTemplates()
            // Demo overlay — see rawComposition.
            guard !DemoModeStore.isDemoActive else { return }
            if !isSyncApplying {
                DeviceSyncService.shared.debouncedBroadcast(fields: [.templates])
                debouncedRecordHistory(field: "templates")
            }
        }
    }

    // MARK: - Parsed section accessors (for UI bindings)
    // These parse from / reconstruct into the raw markdown.

    var writingStyle: String {
        get { PromptParser.extractSection(from: rawComposition, header: SectionHeaders.writingStyle) }
        set { rawComposition = PromptParser.replaceSection(in: rawComposition, header: SectionHeaders.writingStyle, with: newValue) }
    }

    var language: String {
        get { PromptParser.extractSection(from: rawComposition, header: SectionHeaders.language) }
        set { rawComposition = PromptParser.replaceSection(in: rawComposition, header: SectionHeaders.language, with: newValue) }
    }

    var usefulLinks: String {
        get { PromptParser.extractSection(from: rawComposition, header: SectionHeaders.usefulLinks) }
        set { rawComposition = PromptParser.replaceSection(in: rawComposition, header: SectionHeaders.usefulLinks, with: newValue) }
    }

    var deleteRules: String {
        get { PromptParser.extractSection(from: rawAction, header: SectionHeaders.deleteRules) }
        set { rawAction = PromptParser.replaceSection(in: rawAction, header: SectionHeaders.deleteRules, with: newValue) }
    }

    var archiveRules: String {
        get { PromptParser.extractSection(from: rawAction, header: SectionHeaders.archiveRules) }
        set { rawAction = PromptParser.replaceSection(in: rawAction, header: SectionHeaders.archiveRules, with: newValue) }
    }

    var replyRules: String {
        get { PromptParser.extractSection(from: rawAction, header: SectionHeaders.replyRules) }
        set { rawAction = PromptParser.replaceSection(in: rawAction, header: SectionHeaders.replyRules, with: newValue) }
    }

    var noneRules: String {
        get { PromptParser.extractSection(from: rawAction, header: SectionHeaders.noneRules) }
        set { rawAction = PromptParser.replaceSection(in: rawAction, header: SectionHeaders.noneRules, with: newValue) }
    }

    var knowledgeBase: String {
        get { rawKB }
        set { rawKB = newValue }
    }

    // MARK: - Init

    private init() {
        let d = UserDefaults.standard

        // Flush defaults to UserDefaults on first run — didSet does not fire in init,
        // so without this, nonisolated snapshot readers (actionMarkdownSnapshot,
        // kbTextSnapshot) and the NSE mirror see "" until the user first edits.
        let storedComposition = d.string(forKey: Keys.composition)
        let storedAction = d.string(forKey: Keys.action)
        let storedKB = d.string(forKey: Keys.kb)
        self.rawComposition = storedComposition ?? Defaults.composition
        self.rawAction = storedAction ?? Defaults.action
        self.rawKB = storedKB ?? Defaults.kb
        if storedComposition == nil { d.set(Defaults.composition, forKey: Keys.composition) }
        if storedAction == nil { d.set(Defaults.action, forKey: Keys.action) }
        if storedKB == nil { d.set(Defaults.kb, forKey: Keys.kb) }

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

        // Migrate old sync base → peer base (one-time, from v1 3-way merge era)
        migrateSyncBaseToPeerBase()
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
    // Records pre-reset state in history, then resets with epoch-zero timestamps
    // so defaults never overwrite customized rules on other devices via Device Sync.

    func resetComposition() {
        // Demo overlay: reset the overlay only — no history, no sync-reset
        // timestamps (those belong to the real prompts).
        if DemoModeStore.isDemoActive { rawComposition = Defaults.composition; return }
        recordHistory(source: "reset", fields: ["composition"])
        isSyncApplying = true
        rawComposition = Defaults.composition
        isSyncApplying = false
        DeviceSyncService.shared.markFieldAsReset(.composition)
    }

    func resetAction() {
        if DemoModeStore.isDemoActive { rawAction = Defaults.action; return }
        recordHistory(source: "reset", fields: ["action"])
        isSyncApplying = true
        rawAction = Defaults.action
        isSyncApplying = false
        DeviceSyncService.shared.markFieldAsReset(.action)
    }

    func resetKB() {
        if DemoModeStore.isDemoActive { rawKB = Defaults.kb; return }
        recordHistory(source: "reset", fields: ["kb"])
        isSyncApplying = true
        rawKB = Defaults.kb
        isSyncApplying = false
        DeviceSyncService.shared.markFieldAsReset(.kb)
    }

    func resetTemplates() {
        if DemoModeStore.isDemoActive { templates = Defaults.templates; return }
        recordHistory(source: "reset", fields: ["templates"])
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

    func addTemplate(_ template: ReplyTemplate = ReplyTemplate()) {
        templates.append(template)
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
        print("[PromptStore] CRDT template merge: \(merged) adopted from \(incoming.count) incoming (total: \(localMap.count))")
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
            print("[PromptStore] GC removed \(removed) deleted template tombstones older than \(gcAgeDays) days")
        }
    }

    // MARK: - Device Sync Sync

    /// Apply incoming sync data from another TabMail instance.
    /// Only non-nil fields are applied, allowing per-item sync.
    /// Wrapped in `isSyncApplying` to prevent echo broadcasting.
    /// Records pre-sync state in history for rollback.
    func applySync(composition: String? = nil, action: String? = nil, kb: String? = nil, templates: [ReplyTemplate]? = nil, skipHistory: Bool = false) {
        // Demo overlay: incoming sync must never be applied while demo is
        // active — it would land in the demo keys and be deleted on exit.
        // Device Sync is disconnected on demo entry, so this is defensive.
        guard !DemoModeStore.isDemoActive else {
            print("[PromptStore] applySync ignored during demo mode")
            return
        }
        if !skipHistory {
            // Only record fields that actually differ from current state
            var changedFields: [String] = []
            if let composition, composition != rawComposition { changedFields.append("composition") }
            if let action, action != rawAction { changedFields.append("action") }
            if let kb, kb != rawKB { changedFields.append("kb") }
            if let templates, templates != self.templates { changedFields.append("templates") }
            if !changedFields.isEmpty {
                recordHistory(source: "sync_receive", fields: changedFields)
            }
        }

        isSyncApplying = true
        defer {
            isSyncApplying = false
            // didSet handlers are suppressed during sync — mirror explicitly
            NSEDataBridge.mirrorPrompts()
        }
        if let composition { rawComposition = composition }
        if let action { rawAction = action }
        if let kb { rawKB = kb }
        if let templates { self.templates = templates }
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
        print("[PromptStore] Demo prompt overlay ACTIVE (defaults seeded)")
    }

    /// Exit the demo prompt overlay: restore the real values from the real
    /// keys and delete the demo keys. MUST be called while demo is STILL
    /// active (before `DemoModeStore.isActive` flips false) — the restore
    /// writes then route to the about-to-be-deleted demo keys instead of
    /// re-firing NSE mirror / Device Sync / history with unchanged real values.
    func exitDemoOverlay() {
        assert(DemoModeStore.isDemoActive, "exitDemoOverlay requires demo still active")
        rawComposition = defaults.string(forKey: Keys.composition) ?? Defaults.composition
        rawAction = defaults.string(forKey: Keys.action) ?? Defaults.action
        rawKB = defaults.string(forKey: Keys.kb) ?? Defaults.kb
        if let data = defaults.data(forKey: Keys.templates),
           let decoded = try? JSONDecoder().decode([ReplyTemplate].self, from: data) {
            templates = decoded
        } else {
            templates = []
        }
        Self.removeDemoOverlayKeys()
        print("[PromptStore] Demo prompt overlay REMOVED (real prompts restored)")
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

    /// Debounced history recording for local edits — waits 2s of quiet before creating entry.
    private func debouncedRecordHistory(field: String) {
        pendingHistoryFields.insert(field)
        historyDebounceTask?.cancel()
        historyDebounceTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(2000))
            guard !Task.isCancelled, let self else { return }
            let fields = Array(self.pendingHistoryFields)
            self.pendingHistoryFields = []
            self.recordHistory(source: "local_edit", fields: fields)
        }
    }

    /// Record a snapshot of current state in history.
    func recordHistory(source: String, fields: [String]) {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let templatesStr = (try? encoder.encode(templates)).flatMap { String(data: $0, encoding: .utf8) } ?? "[]"

        let entry = PromptHistoryEntry(
            id: UUID().uuidString,
            timestamp: Date().ISO8601Format(),
            source: source,
            fields: fields,
            composition: rawComposition,
            action: rawAction,
            kb: rawKB,
            templatesJSON: templatesStr
        )

        var history = loadHistory()
        history.append(entry)
        if history.count > Self.maxHistoryEntries {
            history = Array(history.suffix(Self.maxHistoryEntries))
        }
        saveHistory(history)
    }

    /// Load all history entries (newest last).
    /// Empty during demo — the real prompt history must not be visible (or
    /// restorable) from a demo recording.
    func loadHistory() -> [PromptHistoryEntry] {
        guard !DemoModeStore.isDemoActive else { return [] }
        migrateBackupsIfNeeded()
        guard let data = defaults.data(forKey: Self.historyKey),
              let entries = try? JSONDecoder().decode([PromptHistoryEntry].self, from: data) else {
            return []
        }
        return entries
    }

    /// Restore all prompt fields from a history entry.
    /// Applies as a sync (suppresses broadcast), then writes fresh timestamps
    /// so the restore propagates to other devices as a normal edit.
    func restoreFromHistory(_ entry: PromptHistoryEntry) {
        // Demo overlay: unreachable in practice (loadHistory is empty in demo)
        // but guard anyway — a restore would write real timestamps + broadcast.
        guard !DemoModeStore.isDemoActive else { return }
        recordHistory(source: "reset", fields: ["composition", "action", "kb", "templates"])
        applySync(
            composition: entry.composition,
            action: entry.action,
            kb: entry.kb,
            templates: entry.decodedTemplates,
            skipHistory: true
        )
        // Write fresh timestamps so the restore syncs to peers (prompt fields only)
        let now = Date().ISO8601Format()
        for field in SyncField.promptFields {
            DeviceSyncService.shared.writeTimestampPublic(now, for: field)
        }
        DeviceSyncService.shared.debouncedBroadcast(fields: Set(SyncField.promptFields))
    }

    // MARK: - Private

    private func saveTemplates() {
        if let data = try? JSONEncoder().encode(templates) {
            defaults.set(data, forKey: Self.storageKey(Keys.templates))
        }
    }

    func saveHistory(_ entries: [PromptHistoryEntry]) {
        if let data = try? JSONEncoder().encode(entries) {
            defaults.set(data, forKey: Self.historyKey)
        }
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
        print("[PromptStore] Migrated \(entries.count) backup(s) to prompt history")
    }
}

// MARK: - Section Parser

/// Parses and reconstructs TB-format markdown prompt files.
/// Sections are identified by `# <title> (DO NOT EDIT/DELETE THIS SECTION HEADER)`.
/// Content between two section headers (or between a header and the end marker) is the section body.
enum PromptParser {

    /// Extract the content body of a section identified by its header text.
    static func extractSection(from markdown: String, header: String) -> String {
        let lines = markdown.components(separatedBy: "\n")
        var capturing = false
        var content: [String] = []

        for line in lines {
            if line.contains(header) && line.contains("DO NOT EDIT/DELETE THIS SECTION HEADER") {
                capturing = true
                continue
            }
            if capturing {
                // Stop at next section header or end marker
                if (line.hasPrefix("# ") && line.contains("DO NOT EDIT/DELETE THIS SECTION HEADER"))
                    || line.contains("====END USER INSTRUCTIONS====") {
                    break
                }
                content.append(line)
            }
        }

        // Trim leading/trailing blank lines
        while content.first?.trimmingCharacters(in: .whitespaces).isEmpty == true { content.removeFirst() }
        while content.last?.trimmingCharacters(in: .whitespaces).isEmpty == true { content.removeLast() }
        return content.joined(separator: "\n")
    }

    /// Section headers for composition markdown.
    static let compositionSectionHeaders = [
        "General writing style",
        "Language",
        "Useful links to personal website and other resources",
    ]

    /// Section headers for action markdown.
    static let actionSectionHeaders = [
        "Emails to be marked as `delete`",
        "Emails to be marked as `archive`",
        "Emails to be marked as `reply`",
        "Emails to be marked as `none`",
    ]

    // MARK: - 3-Way Bullet Merge (with peer-received base)

    /// Extract bullets from a section's content text.
    /// Bullets are lines starting with `- `, trimmed.
    static func extractBullets(from text: String) -> [String] {
        text.components(separatedBy: "\n")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { $0.hasPrefix("- ") }
            .map { String($0.dropFirst(2)) }
    }

    /// 3-way merge for a flat bullet list.
    /// Uses set-based merge: local ordering preserved, remote removals applied, remote additions appended.
    static func mergeBullets(base: [String], local: [String], remote: [String]) -> [String] {
        let baseSet = Set(base)
        let remoteSet = Set(remote)

        let remoteRemoved = baseSet.subtracting(remoteSet)
        let remoteAdded = remoteSet.subtracting(baseSet)

        // Start with local (preserves local ordering + local changes)
        var result = local.filter { !remoteRemoved.contains($0) }

        // Append remote additions not already present
        let resultSet = Set(result)
        for bullet in remote where remoteAdded.contains(bullet) && !resultSet.contains(bullet) {
            result.append(bullet)
        }

        return result
    }

    /// 3-way merge for a sectioned markdown field (composition/action).
    /// Merges bullets per section independently, preserving markdown structure.
    static func mergeSectionedField(base: String, local: String, remote: String, sectionHeaders: [String]) -> String {
        var result = local
        for header in sectionHeaders {
            let baseBullets = extractBullets(from: extractSection(from: base, header: header))
            let localBullets = extractBullets(from: extractSection(from: local, header: header))
            let remoteBullets = extractBullets(from: extractSection(from: remote, header: header))

            let merged = mergeBullets(base: baseBullets, local: localBullets, remote: remoteBullets)

            if merged != localBullets {
                let newContent = merged.map { "- \($0)" }.joined(separator: "\n")
                result = replaceSection(in: result, header: header, with: newContent)
            }
        }
        return result
    }

    /// 3-way merge for a flat bullet field (kb).
    /// Merges the entire field as one bullet list.
    static func mergeFlatField(base: String, local: String, remote: String) -> String {
        let baseBullets = extractBullets(from: base)
        let localBullets = extractBullets(from: local)
        let remoteBullets = extractBullets(from: remote)

        let merged = mergeBullets(base: baseBullets, local: localBullets, remote: remoteBullets)

        if merged == localBullets { return local }
        return merged.map { "- \($0)" }.joined(separator: "\n")
    }

    /// Replace the content body of a section, preserving the markdown structure.
    static func replaceSection(in markdown: String, header: String, with newContent: String) -> String {
        let lines = markdown.components(separatedBy: "\n")
        var result: [String] = []
        var skipping = false

        for line in lines {
            if line.contains(header) && line.contains("DO NOT EDIT/DELETE THIS SECTION HEADER") {
                result.append(line)
                result.append(newContent)
                skipping = true
                continue
            }
            if skipping {
                // Resume at next section header or end marker
                if (line.hasPrefix("# ") && line.contains("DO NOT EDIT/DELETE THIS SECTION HEADER"))
                    || line.contains("====END USER INSTRUCTIONS====") {
                    result.append("")
                    result.append(line)
                    skipping = false
                }
                continue
            }
            result.append(line)
        }

        return result.joined(separator: "\n")
    }
}

// MARK: - Section Header Constants

private enum SectionHeaders {
    static let writingStyle = "General writing style"
    static let language = "Language"
    static let usefulLinks = "Useful links to personal website and other resources"
    static let deleteRules = "Emails to be marked as `delete`"
    static let archiveRules = "Emails to be marked as `archive`"
    static let replyRules = "Emails to be marked as `reply`"
    static let noneRules = "Emails to be marked as `none`"
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

// MARK: - Peer Base State (for delta merge)
//
// Stores the last STATE RECEIVED from any peer. This is the correct "common ancestor"
// for 3-way merge — unlike the old sync base which stored the merged result (wrong because
// the merged result includes local changes the peer hasn't seen).
//
// CRITICAL: peer_base is ALWAYS set to `incoming` (what the peer sent), NEVER to the
// merged result. This ensures the diff between peer_base and the next incoming accurately
// captures only the peer's new changes.

extension PromptStore {
    private enum PeerBaseKeys {
        static let composition = "device_peer_base:composition"
        static let action = "device_peer_base:action"
        static let kb = "device_peer_base:kb"
        static let compositionTs = "device_peer_base_ts:composition"
        static let actionTs = "device_peer_base_ts:action"
        static let kbTs = "device_peer_base_ts:kb"

        static func contentKey(for field: SyncField) -> String {
            switch field {
            case .composition: return composition
            case .action: return action
            case .kb: return kb
            default: fatalError("Peer base only for text fields")
            }
        }

        static func tsKey(for field: SyncField) -> String {
            switch field {
            case .composition: return compositionTs
            case .action: return actionTs
            case .kb: return kbTs
            default: fatalError("Peer base only for text fields")
            }
        }
    }

    /// Read the last-received peer state for a text field.
    /// Returns (content, timestamp) or (nil, epochZero) if never received.
    func readPeerBase(for field: SyncField) -> (content: String?, ts: String) {
        let content = defaults.string(forKey: PeerBaseKeys.contentKey(for: field))
        let ts = defaults.string(forKey: PeerBaseKeys.tsKey(for: field)) ?? "1970-01-01T00:00:00.000Z"
        return (content, ts)
    }

    /// Save the peer's incoming state as the new base.
    /// MUST be called with the raw incoming content (NOT the merged result).
    func savePeerBase(_ content: String, ts: String, for field: SyncField) {
        defaults.set(content, forKey: PeerBaseKeys.contentKey(for: field))
        defaults.set(ts, forKey: PeerBaseKeys.tsKey(for: field))
    }

    /// Migrate old sync base keys to new peer base keys (one-time).
    /// If old sync base exists but new peer base doesn't, adopt the old value.
    /// Then clean up old keys.
    func migrateSyncBaseToPeerBase() {
        let oldKeys = ["device_sync_base:composition", "device_sync_base:action", "device_sync_base:kb"]
        let fields: [SyncField] = [.composition, .action, .kb]
        for (oldKey, field) in zip(oldKeys, fields) {
            if let oldContent = defaults.string(forKey: oldKey),
               defaults.string(forKey: PeerBaseKeys.contentKey(for: field)) == nil {
                defaults.set(oldContent, forKey: PeerBaseKeys.contentKey(for: field))
            }
            defaults.removeObject(forKey: oldKey)
        }
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
