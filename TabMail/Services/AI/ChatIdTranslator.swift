/* This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at https://mozilla.org/MPL/2.0/. */

import Foundation
import GRDB
import Contacts

/// Detail info for an email pill popover (matches TB's tooltip on click).
struct EmailPillDetail: Identifiable {
    let id: Int // numericId
    let realId: String
    let subject: String
    let from: String
    let to: String
    let date: Date?
    let snippet: String?
}

/// Detail info for a contact pill popover (matches TB's contact tooltip).
struct ContactPillDetail: Identifiable {
    let id: Int // numericId
    let realId: String
    let name: String
    let emails: [String] // up to 4, matching TB
}

/// Attendee info for event pill popover.
struct EventPillAttendee: Identifiable {
    let email: String
    let name: String?
    let status: String // accepted, declined, tentative, needsAction
    var id: String { email }
}

/// Detail info for an event pill popover.
struct EventPillDetail: Identifiable {
    let id: Int // numericId
    let realId: String
    let title: String
    let startDate: Date?
    let endDate: Date?
    let isAllDay: Bool
    let location: String?
    /// The event's free-text notes/description (Google `description`, CalDAV
    /// `DESCRIPTION`, Exchange `body`). Carries Zoom/Meet links and agendas.
    /// Nil when the event has no notes.
    let notes: String?
    let attendees: [EventPillAttendee]
    let isRecurring: Bool
    /// The event's `RRULE:...` string when known. Used to render a human-friendly
    /// recurrence description (e.g. "Repeats weekly") in the popover. Nil when
    /// the event is non-recurring, or recurring but the master's rule wasn't
    /// available to the caller — in that case `isRecurring` still drives a
    /// generic "Recurring" badge.
    let recurrenceRule: String?
    let availability: String // "free" or "busy"
    let htmlLink: String?
    let calendarName: String?
    /// IANA identifier the event is stored in (e.g., "Asia/Seoul"). Nil when
    /// the event has no explicit timezone and floats in the user's local zone.
    let eventTimeZone: String?
}

/// Calendar provenance for a cached event — stores which account and calendar
/// an event belongs to so edit/delete tools can route to the correct provider.
struct EventCalendarInfo: Sendable {
    let accountId: String
    let calendarId: String
    let calendarName: String?
}

/// Detail info for a template pill popover (tap on `[📝 Name](tabmail://template/N)`).
/// Snapshot read live from `PromptStore` at tap time.
struct TemplatePillDetail: Identifiable, Sendable {
    let id: Int           // numericId
    let realId: String    // template UUID
    let name: String
    let instructionCount: Int
    let examplePreview: String?  // nil if exampleReply is empty
}

/// Compound event ID helper. Combines accountId and raw event ID into a single
/// string for collision-safe storage in idMap (persisted to GRDB).
/// Format: "accountId:rawEventId". CalDAV IDs contain `/` but not `:`, so `:` is safe.
enum CompoundEventId {
    static func make(accountId: String, eventId: String) -> String { "\(accountId):\(eventId)" }
    static func split(_ compoundId: String) -> (accountId: String, eventId: String)? {
        guard let idx = compoundId.firstIndex(of: ":") else { return nil }
        return (String(compoundId[..<idx]), String(compoundId[compoundId.index(after: idx)...]))
    }
}

/// Bidirectional translator between real MessageHeader.id strings
/// and simple numeric IDs for LLM interaction.
/// Matches TB addon's `idTranslator.js` architecture (ADR-IOS-008).
///
/// Features (matching TB):
/// - ID recycling via `freeIds` pool (freed IDs are reused before incrementing nextId)
/// - Reference counting per numeric ID (tracks which turns reference which IDs)
/// - Eviction cleanup (when turns are evicted, their referenced IDs are freed if refCount drops to 0)
/// - Isolated contexts for background sessions (separate instances, no cross-contamination)
/// - Merge from isolated sessions (remap conflicting IDs when merging back to main)
/// - Real ID remapping (when a message's real ID changes, e.g. folder move)
///
/// ID mappings are persisted to GRDB (`chatIdMapping` table, v12 migration) so pill
/// references in old chat sessions remain resolvable across app restarts.
actor ChatIdTranslator {
    static let shared = ChatIdTranslator()

    /// Config
    private enum Config {
        static let emailPillMaxSubjectLength = 30
        /// Max number of ID mappings before triggering orphan sweep.
        /// Bounded to prevent unbounded memory growth during long sessions
        /// with many searches. Orphan IDs (refCount == 0) are evicted FIFO
        /// when this cap is reached.
        static let maxMappings = 500
    }

    // Core bidirectional maps
    private var idMap: [Int: String] = [:]
    private var reverseMap: [String: Int] = [:]
    private var nextId = 1

    // ID recycling pool (matches TB's freeIds — freed IDs go here for reuse)
    private var freeIds: [Int] = []

    // Reference counting: numericId → number of turns that reference it (matches TB's refCounts)
    private var refCounts: [Int: Int] = [:]

    // Subject cache: avoids repeated synchronous GRDB reads on the main thread.
    // Populated on first resolve, invalidated on clearAll().
    private var subjectCache: [Int: String] = [:]

    // Event title cache: populated from tool output in processToolOutputForLLM.
    // Google Calendar events aren't in EventKit, so titles are extracted from tool output.
    private var eventTitleCache: [Int: String] = [:]

    // Template name cache: populated when template tools register numeric IDs.
    private var templateNameCache: [Int: String] = [:]

    // Event detail cache: keyed by compound ID "accountId:rawEventId", populated by calendar tools.
    // Used for event pill popovers — full structured data instead of parsing text output.
    private var eventDetailCache: [String: EventDetailCacheEntry] = [:]

    // Event calendar cache: keyed by compound ID "accountId:rawEventId".
    // Stores which account and calendar an event belongs to — used by edit/delete tools
    // to route to the correct provider without the LLM knowing about calendars.
    // Ephemeral, per-session (NOT persisted to GRDB).
    private var eventCalendarCache: [String: EventCalendarInfo] = [:]

    /// Internal cache entry for event details (keyed by realId, converted to EventPillDetail on resolve).
    /// Populated by calendar tools at action time and used to render the pill
    /// popover until the event has propagated to the provider's API. After that
    /// point, on cache miss we re-fetch live via `EventCalendarInfo` provenance.
    private struct EventDetailCacheEntry {
        let title: String
        let startDate: Date?
        let endDate: Date?
        let isAllDay: Bool
        let location: String?
        let notes: String?
        let attendees: [EventPillAttendee]
        let isRecurring: Bool
        let recurrenceRule: String?
        let availability: String
        let htmlLink: String?
        let eventTimeZone: String?
    }

    // processResponseForDisplay cache: same input text → same output.
    // Prevents duplicate DB-heavy processing when SwiftUI re-renders MarkdownChatText.
    private var displayCache: [String: String] = [:]

    private var lastAccessed = Date()

    // Lazy-load persisted ID mappings on first use (GRDB v12 chatIdMapping table).
    private var hasLoadedFromDB = false

    /// Load persisted ID mappings from GRDB. Called lazily on first `toNumericId` access.
    /// Synchronous GRDB read — safe inside actor isolation.
    private func ensureLoadedFromDB() {
        guard !hasLoadedFromDB else { return }
        hasLoadedFromDB = true
        do {
            let rows = try AppDatabase.dbPool.read { db in
                try Row.fetchAll(db, sql: "SELECT numericId, realId FROM chatIdMapping")
            }
            for row in rows {
                let numericId: Int = row["numericId"]
                let realId: String = row["realId"]
                idMap[numericId] = realId
                reverseMap[realId] = numericId
                nextId = max(nextId, numericId + 1)
            }
            if !idMap.isEmpty {
                print("[ChatIdTranslator] Loaded \(idMap.count) persisted ID mappings, nextId=\(nextId)")
            }
        } catch {
            print("[ChatIdTranslator] Failed to load persisted ID mappings: \(error)")
        }
    }

    /// Persist a single ID mapping to GRDB.
    private func persistMapping(numericId: Int, realId: String) {
        do {
            try AppDatabase.dbPool.write { db in
                try db.execute(
                    sql: "INSERT OR REPLACE INTO chatIdMapping (numericId, realId) VALUES (?, ?)",
                    arguments: [numericId, realId]
                )
            }
        } catch {
            print("[ChatIdTranslator] Failed to persist mapping \(numericId) → \(realId): \(error)")
        }
    }

    /// Delete ID mappings from GRDB.
    private func deletePersistedMappings(_ numericIds: [Int]) {
        guard !numericIds.isEmpty else { return }
        do {
            try AppDatabase.dbPool.write { db in
                let placeholders = numericIds.map { _ in "?" }.joined(separator: ",")
                try db.execute(
                    sql: "DELETE FROM chatIdMapping WHERE numericId IN (\(placeholders))",
                    arguments: StatementArguments(numericIds)
                )
            }
        } catch {
            print("[ChatIdTranslator] Failed to delete \(numericIds.count) persisted mappings: \(error)")
        }
    }

    // MARK: - Core Translation

    /// Assign or reuse a numeric ID for a real MessageHeader.id.
    /// Prefers recycled IDs from freeIds pool (matches TB's freeIds.pop()).
    /// Triggers orphan sweep when map exceeds `Config.maxMappings`.
    ///
    /// Matches TB's `toNumericId()`: if `realId` is already a pure numeric string,
    /// returns it as-is (identity, no mapping created). This is a defensive guard —
    /// tool output should never contain pre-translated numeric IDs for ID fields.
    func toNumericId(_ realId: String) -> Int {
        ensureLoadedFromDB()

        // TB parity: if realId is already numeric, return as-is (no mapping created).
        // This should never happen — tools should always output real IDs.
        if let asInt = Int(realId), realId == String(asInt) {
            print("[ChatIdTranslator] WARNING: toNumericId called with numeric value '\(realId)' — returning as-is (bug upstream?)")
            return asInt
        }

        if let existing = reverseMap[realId] {
            lastAccessed = Date()
            return existing
        }

        // Sweep unreferenced orphans if map is at capacity
        if idMap.count >= Config.maxMappings {
            sweepOrphans()
        }

        // Allocate: prefer recycled ID from freeIds pool
        let numericId: Int
        if let recycled = freeIds.popLast() {
            numericId = recycled
            print("[ChatIdTranslator] Reused free ID \(numericId) for: \(realId)")
        } else {
            numericId = nextId
            nextId += 1
        }

        idMap[numericId] = realId
        reverseMap[realId] = numericId
        persistMapping(numericId: numericId, realId: realId)
        lastAccessed = Date()
        return numericId
    }

    /// Look up real MessageHeader.id from numeric ID.
    func toRealId(_ numericId: Int) -> String? {
        ensureLoadedFromDB()
        lastAccessed = Date()
        return idMap[numericId]
    }

    // MARK: - Bounded Eviction

    /// Evict unreferenced (orphan) IDs when the map exceeds `Config.maxMappings`.
    /// Orphan IDs have refCount == 0 — they were registered by tool output
    /// but never referenced in the LLM's display response. Evicts lowest
    /// numeric IDs first (FIFO — lower IDs were allocated earlier).
    /// Also clears associated caches for evicted IDs.
    private func sweepOrphans() {
        // Collect unreferenced IDs, sorted ascending (FIFO: oldest allocated first)
        let orphans = idMap.keys.filter { (refCounts[$0] ?? 0) == 0 }.sorted()
        guard !orphans.isEmpty else {
            print("[ChatIdTranslator] sweepOrphans: no orphans to evict (all \(idMap.count) IDs are referenced)")
            return
        }

        var evicted = 0
        var evictedRealIds: [String] = []
        for numericId in orphans {
            if let realId = idMap.removeValue(forKey: numericId) {
                reverseMap.removeValue(forKey: realId)
                freeIds.append(numericId)
                subjectCache.removeValue(forKey: numericId)
                eventTitleCache.removeValue(forKey: numericId)
                eventDetailCache.removeValue(forKey: realId)
                eventCalendarCache.removeValue(forKey: realId)
                evictedRealIds.append(realId)
                evicted += 1
            }
        }
        // Invalidate display cache since evicted IDs would produce stale results
        if evicted > 0 {
            displayCache.removeAll()
            deletePersistedMappings(orphans)
            deletePersistedEventCalendars(evictedRealIds)
        }
        print("[ChatIdTranslator] sweepOrphans: evicted \(evicted) orphan IDs, map now \(idMap.count), freeIds pool \(freeIds.count)")
    }

    // MARK: - Reference Counting (matches TB's registerTurnRefs / unregisterTurnRefs / collectTurnRefs)

    /// Extract all numeric IDs referenced in text content.
    /// Pure function — scans for `[Email](N)`, `[Contact](N)`, and `[Event](N)` patterns.
    /// Also handles compound IDs like `[Event](cal:evt)` — extracts all numeric parts.
    /// Matches TB's `collectTurnRefs()`.
    static func collectRefs(from text: String) -> Set<Int> {
        var refs = Set<Int>()
        let entityPattern = /\[(Email|Contact|Event|Template)\]\((\d+(?::\d+)?)\)/
        for match in text.matches(of: entityPattern) {
            let idPart = String(match.2)
            if idPart.contains(":") {
                // Compound ID — extract all numeric parts
                for part in idPart.split(separator: ":") {
                    if let id = Int(part) { refs.insert(id) }
                }
            } else if let id = Int(idPart) {
                refs.insert(id)
            }
        }
        return refs
    }

    /// Collect refs from a ChatTurn's relevant text fields.
    /// User turns: scans userMessage. Assistant turns: scans content.
    static func collectRefsFromTurn(_ turn: ChatTurn) -> [Int] {
        var allRefs = Set<Int>()
        if let userMessage = turn.userMessage {
            allRefs.formUnion(collectRefs(from: userMessage))
        }
        if turn.role == "assistant" && turn.type != "session_break" {
            allRefs.formUnion(collectRefs(from: turn.content))
        }
        return Array(allRefs)
    }

    /// Register refs for a newly created turn. Increments refCounts.
    /// Matches TB's `registerTurnRefs()`.
    func registerTurnRefs(_ refs: [Int]) {
        guard !refs.isEmpty else { return }
        for id in refs {
            refCounts[id, default: 0] += 1
        }
        print("[ChatIdTranslator] Registered \(refs.count) refs: \(refs)")
    }

    /// Unregister refs for a removed/evicted turn. Decrements refCounts,
    /// frees IDs that drop to 0 (removed from idMap, added to freeIds pool).
    /// Matches TB's `unregisterTurnRefs()`.
    func unregisterTurnRefs(_ refs: [Int]) {
        guard !refs.isEmpty else { return }
        var freedIds: [Int] = []
        for id in refs {
            let current = refCounts[id, default: 0]
            if current <= 1 {
                refCounts.removeValue(forKey: id)
                if let realId = idMap.removeValue(forKey: id) {
                    reverseMap.removeValue(forKey: realId)
                    freeIds.append(id)
                    freedIds.append(id)
                }
            } else {
                refCounts[id] = current - 1
            }
        }
        if !freedIds.isEmpty {
            deletePersistedMappings(freedIds)
            print("[ChatIdTranslator] unregisterTurnRefs: freed \(freedIds.count) IDs, freeIds pool now \(freeIds.count)")
        }
    }

    /// Batch unregister refs for evicted turns. Matches TB's `cleanupEvictedIds()`.
    func cleanupEvictedIds(evictedTurns: [ChatTurn]) {
        var totalFreed = 0
        var freedIds: [Int] = []
        for turn in evictedTurns {
            let refs = Self.collectRefsFromTurn(turn)
            for id in refs {
                let current = refCounts[id, default: 0]
                if current <= 1 {
                    refCounts.removeValue(forKey: id)
                    if let realId = idMap.removeValue(forKey: id) {
                        reverseMap.removeValue(forKey: realId)
                        freeIds.append(id)
                        freedIds.append(id)
                        totalFreed += 1
                    }
                } else {
                    refCounts[id] = current - 1
                }
            }
        }
        if totalFreed > 0 {
            deletePersistedMappings(freedIds)
            print("[ChatIdTranslator] cleanupEvictedIds: freed \(totalFreed) IDs from \(evictedTurns.count) evicted turns, freeIds pool now \(freeIds.count)")
        }
    }

    /// Rebuild refCounts from all persisted turns. Sweeps orphan IDs.
    /// Called on startup/history load. Matches TB's `buildRefCounts()`.
    ///
    /// **Ordering note**: The `allTurns` array may not include turns inserted after it was loaded
    /// (e.g., a session_break inserted between loadTurns() and this call). This is safe because
    /// session_break turns have zero refs, and this actor serializes method calls so
    /// registerTurnRefs cannot interleave. Any IDs registered by concurrent registerTurnRefs
    /// calls are preserved because they queue behind this method in the actor mailbox.
    func buildRefCounts(allTurns: [ChatTurn]) {
        ensureLoadedFromDB()
        var newRefCounts: [Int: Int] = [:]
        for turn in allTurns {
            let refs = Self.collectRefsFromTurn(turn)
            for id in refs {
                newRefCounts[id, default: 0] += 1
            }
        }

        // Sweep orphan IDs (in idMap but not referenced by any turn)
        var orphanCount = 0
        var orphanIds: [Int] = []
        for numericId in Array(idMap.keys) {
            if newRefCounts[numericId] == nil {
                if let realId = idMap.removeValue(forKey: numericId) {
                    reverseMap.removeValue(forKey: realId)
                    freeIds.append(numericId)
                    orphanIds.append(numericId)
                    orphanCount += 1
                }
            }
        }

        refCounts = newRefCounts
        if !orphanIds.isEmpty {
            deletePersistedMappings(orphanIds)
        }
        if !idMap.isEmpty || orphanCount > 0 {
            print("[ChatIdTranslator] buildRefCounts: \(newRefCounts.count) IDs referenced, \(orphanCount) orphans freed, freeIds pool: \(freeIds.count)")
        }
    }

    // MARK: - Isolated Contexts (matches TB's createIsolatedContext)

    /// Create a new isolated translator for background sessions.
    /// Each headless session (proactive check-in, reply generation, etc.)
    /// should use its own translator to avoid cross-session contamination.
    /// Matches TB's `createIsolatedContext()`.
    static func createIsolated() -> ChatIdTranslator {
        ChatIdTranslator()
    }

    /// Get a copy of the current idMap (for merging).
    func getIdMap() -> [Int: String] {
        idMap
    }

    /// Merge mappings from an isolated translator into this one.
    /// Handles conflicts: if a headless numericId is already used for a different realId,
    /// assigns a new numericId and rewrites references in the message.
    /// Returns the message with numeric IDs remapped to this translator's namespace.
    /// Matches TB's `mergeIdMapFromHeadless()`.
    func mergeFromIsolated(_ isolatedMap: [Int: String], message: String) -> String {
        guard !isolatedMap.isEmpty else { return message }

        var remapTable: [Int: Int] = [:]

        for (headlessNumericId, realId) in isolatedMap {
            if let existingNumericId = reverseMap[realId] {
                // realId already mapped — reuse existing numeric ID
                remapTable[headlessNumericId] = existingNumericId
            } else if idMap[headlessNumericId] == nil {
                // No conflict — add directly with same numeric ID
                idMap[headlessNumericId] = realId
                reverseMap[realId] = headlessNumericId
                if headlessNumericId >= nextId {
                    nextId = headlessNumericId + 1
                }
                persistMapping(numericId: headlessNumericId, realId: realId)
                remapTable[headlessNumericId] = headlessNumericId
            } else {
                // Conflict: headlessNumericId already maps to a different realId
                let newNumericId: Int
                if let recycled = freeIds.popLast() {
                    newNumericId = recycled
                } else {
                    newNumericId = nextId
                    nextId += 1
                }
                idMap[newNumericId] = realId
                reverseMap[realId] = newNumericId
                persistMapping(numericId: newNumericId, realId: realId)
                remapTable[headlessNumericId] = newNumericId
            }
        }

        lastAccessed = Date()

        // Rewrite entity references in the message using the remap table
        let pattern = /\[(Email|Contact|Event|Template)\]\((\d+(?::\d+)?)\)/
        var result = message
        for match in Array(result.matches(of: pattern)).reversed() {
            let type = String(match.1)
            let idPart = String(match.2)

            if idPart.contains(":") {
                // Compound ID (e.g., calendar:event or addressbook:contact)
                let parts = idPart.split(separator: ":")
                let newParts = parts.map { p -> String in
                    if let oldNum = Int(p), let newNum = remapTable[oldNum] {
                        return String(newNum)
                    }
                    return String(p)
                }
                result.replaceSubrange(match.range, with: "[\(type)](\(newParts.joined(separator: ":")))")
            } else if let oldNum = Int(idPart), let newNum = remapTable[oldNum] {
                result.replaceSubrange(match.range, with: "[\(type)](\(newNum))")
            }
        }

        let remappedCount = remapTable.filter { $0.key != $0.value }.count
        print("[ChatIdTranslator] mergeFromIsolated: merged \(isolatedMap.count) entries, \(remappedCount) remapped, map now has \(idMap.count) entries")
        return result
    }

    // MARK: - Remap

    /// Remap any numeric IDs pointing to oldRealId to point to newRealId.
    /// Used when a message's real ID changes (e.g., folder move changes the key).
    /// Matches TB's `remapUniqueId()`.
    func remapRealId(from oldRealId: String, to newRealId: String) -> Int {
        guard let numericId = reverseMap.removeValue(forKey: oldRealId) else { return 0 }
        idMap[numericId] = newRealId
        reverseMap[newRealId] = numericId
        persistMapping(numericId: numericId, realId: newRealId)
        lastAccessed = Date()
        print("[ChatIdTranslator] Remapped id=\(numericId): \(oldRealId) → \(newRealId)")
        return 1
    }

    // MARK: - Email Subject Resolution

    /// Fetch email subject from GRDB for a numeric ID.
    /// Returns cached result if available (avoids blocking DB reads on re-render).
    func resolveEmailSubject(_ numericId: Int) -> String? {
        if let cached = subjectCache[numericId] { return cached }
        guard let realId = idMap[numericId] else { return nil }
        let subject = try? AppDatabase.dbPool.read { db in
            try MessageHeader.filter(Column("id") == realId).fetchOne(db)?.subject
        }
        if let subject { subjectCache[numericId] = subject }
        return subject
    }

    /// Fetch full email detail from GRDB for a numeric ID (used for pill popover).
    /// Returns nil if ID not found or message not in DB.
    func resolveEmailDetail(_ numericId: Int) -> EmailPillDetail? {
        ensureLoadedFromDB()
        guard let realId = idMap[numericId] else { return nil }
        guard let msg = try? AppDatabase.dbPool.read({ db in
            try MessageHeader.filter(Column("id") == realId).fetchOne(db)
        }) else { return nil }
        return EmailPillDetail(
            id: numericId,
            realId: realId,
            subject: msg.subject,
            from: msg.from,
            to: msg.to,
            date: msg.date,
            snippet: msg.snippet
        )
    }

    // MARK: - Tool Output Translation (TB → LLM)

    /// Translate real IDs in tool output to numeric IDs before sending to the LLM.
    /// Matches TB's `processStringTBtoLLM()` in `idTranslator.js`.
    ///
    /// All tool outputs use plain text `field: value` format (normalized to match TB).
    /// `unique_id:` is not in the pattern — email tools already output numeric IDs.
    /// Also extracts and caches event titles for pill display.
    ///
    /// **TB parity note**: TB's processStringTBtoLLM passes ALL matched values through
    /// `toNumericId()` without caller-level numeric skipping. The numeric guard lives
    /// inside `toNumericId()` itself (identity pass-through for numeric inputs).
    func processToolOutputForLLM(_ output: String) -> String {
        // `new_series_event_id` is emitted by `calendar_event_edit` after a
        // `this_and_following` split — the freshly-created series's id, which
        // the LLM needs to address occurrences past the split point. Treated
        // identically to `event_id` for translation.
        let pattern = /(event_id|new_series_event_id|calendar_id|contact_id|addressbook_id):\s+([^\n]+?)(?=\n|$)/
        let matches = Array(output.matches(of: pattern))
        guard !matches.isEmpty else { return output }

        // Extract event titles from the raw output before ID translation.
        // Maps realId → title for caching after numeric translation.
        let eventTitles = extractEventTitles(from: output)

        var translatedEventIds: [String: Int] = [:] // realId → numericId
        var result = output
        for match in matches.reversed() {
            let fieldName = String(match.1)
            let realId = String(match.2).trimmingCharacters(in: .whitespaces)
            guard !realId.isEmpty else { continue }
            // TB parity: pass ALL values through toNumericId() — numeric guard is inside toNumericId itself.
            let numericId = toNumericId(realId)
            // Both `event_id` and `new_series_event_id` lines refer to a
            // calendar event whose title we want cached against its numericId
            // so the chat pill renders the event name instead of the generic
            // "Event" fallback. Without including `new_series_event_id` here,
            // the post-split new series's numericId never gets a title and
            // the pill shows "[📅 Event](...)".
            if fieldName == "event_id" || fieldName == "new_series_event_id" {
                translatedEventIds[realId] = numericId
            }
            print("[AIChatDebug] processToolOutputForLLM: \(fieldName) '\(realId.prefix(30))...' → \(numericId)")
            result.replaceSubrange(match.range, with: "\(fieldName): \(numericId)")
        }

        // Populate event title cache with extracted titles
        for (realId, numericId) in translatedEventIds {
            if let title = eventTitles[realId], !title.isEmpty {
                eventTitleCache[numericId] = title
                print("[AIChatDebug] Cached event title id=\(numericId): '\(title.prefix(40))'")
            }
        }

        return result
    }

    /// Extract event titles from tool output text (before ID translation).
    /// Handles three output formats:
    /// 1. Detailed: `event_id: <id>\ntitle: <title>`
    /// 2. Create/edit result: `event_id: <id>\nevent_title: <title>`
    /// 3. Grouped summary: `<timeRange>: <title><markers>\tevent_id: <id>`
    private func extractEventTitles(from output: String) -> [String: String] {
        var titles: [String: String] = [:]
        let lines = output.components(separatedBy: "\n")
        var lastEventId: String?

        for line in lines {
            let trimmed = line.trimmingCharacters(in: .whitespaces)

            // Grouped format: "14:00 - 15:00: Title (↻) [free]\tevent_id: abc123"
            if trimmed.contains("\tevent_id: ") {
                let tabParts = trimmed.split(separator: "\t", maxSplits: 1)
                if tabParts.count == 2 {
                    let beforeTab = String(tabParts[0])
                    let afterTab = String(tabParts[1])
                    if afterTab.hasPrefix("event_id: ") {
                        let realId = String(afterTab.dropFirst("event_id: ".count)).trimmingCharacters(in: .whitespaces)
                        // Extract title: strip time prefix, then strip markers
                        let timePrefixPattern = /^(?:All day|\d{2}:\d{2}\s*-\s*\d{2}:\d{2}|\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}):\s+/
                        if let match = beforeTab.firstMatch(of: timePrefixPattern) {
                            var title = String(beforeTab[match.range.upperBound...])
                            // Strip the recurrence marker — both the bare `(↻)`
                            // and the richer `(↻ RRULE:…)` form added in v1.5.21
                            // so the LLM can reason about edit_scope. The chip
                            // title shown to the USER should never carry raw
                            // RRULE text.
                            title = title
                                .replacing(/\s*\(↻[^)]*\)/, with: "")
                                .replacingOccurrences(of: " [free]", with: "")
                                .trimmingCharacters(in: .whitespaces)
                            if !title.isEmpty && !realId.isEmpty {
                                titles[realId] = title
                            }
                        }
                    }
                }
                lastEventId = nil
                continue
            }

            // "event_id: abc123" on its own line
            if trimmed.hasPrefix("event_id: ") {
                lastEventId = String(trimmed.dropFirst("event_id: ".count)).trimmingCharacters(in: .whitespaces)
                continue
            }

            // "new_series_event_id: abc123" (post-split). Same shape as
            // event_id for title attribution — any following `event_title:` is
            // the new series's title, not the master's. Without this branch
            // the new-series pill resolves to "Event" (the default) because
            // its numeric id never gets a cached title.
            if trimmed.hasPrefix("new_series_event_id: ") {
                lastEventId = String(trimmed.dropFirst("new_series_event_id: ".count)).trimmingCharacters(in: .whitespaces)
                continue
            }

            // "title: Some Title" or "event_title: Some Title" (associated with previous event_id)
            if let eventId = lastEventId {
                if trimmed.hasPrefix("title: ") {
                    let title = String(trimmed.dropFirst("title: ".count)).trimmingCharacters(in: .whitespaces)
                    if !title.isEmpty { titles[eventId] = title }
                } else if trimmed.hasPrefix("event_title: ") {
                    let title = String(trimmed.dropFirst("event_title: ".count)).trimmingCharacters(in: .whitespaces)
                    if !title.isEmpty { titles[eventId] = title }
                }
            }
        }

        return titles
    }

    // MARK: - LLM Response Processing

    /// Process LLM response for display: replaces entity references with tappable pills.
    /// - `[Email](N)` → `[📧 Subject](tabmail://email/N)`
    /// - `[Event](N)` → `[📅 Title](tabmail://event/N)`
    /// - `[Contact](N)` → `[👤 Name](tabmail://contact/N)`
    /// Matches TB's `processLLMResponseLLMtoTB` in `idTranslator.js`.
    func processResponseForDisplay(_ text: String) -> String {
        // Return cached result if same input (avoids redundant DB reads on re-render)
        if let cached = displayCache[text] { return cached }
        ensureLoadedFromDB()

        print("[AIChatDebug] processResponseForDisplay: idMap has \(idMap.count) entries, nextId=\(nextId)")

        var result = text

        // Unified pattern: [Email|Contact|Event](numericId)
        // Also handle backtick-wrapped variants
        let entityPattern = /`?\[(Email|Contact|Event|Template)\]\((\d+)\)`?/
        let matches = Array(result.matches(of: entityPattern))
        print("[AIChatDebug] Entity pattern: \(matches.count) matches")

        // Process in reverse order to preserve indices
        for match in matches.reversed() {
            let entityType = String(match.1)
            guard let numericId = Int(match.2) else { continue }
            guard idMap[numericId] != nil else {
                print("[AIChatDebug]   skip \(entityType) id=\(numericId) — NOT in idMap")
                continue
            }

            let replacement: String
            switch entityType {
            case "Email":
                let subject = resolveEmailSubject(numericId)
                let truncated = truncateSubject(subject ?? "Email")
                replacement = "[📧 \(truncated)](tabmail://email/\(numericId))"
            case "Event":
                // Event IDs map to EKEvent identifiers — resolve title from EventKit
                let title = resolveEventTitle(numericId)
                let truncated = truncateSubject(title ?? "Event")
                replacement = "[📅 \(truncated)](tabmail://event/\(numericId))"
            case "Contact":
                // Contact IDs map to CNContact identifiers — resolve name from Contacts
                let name = resolveContactName(numericId)
                let truncated = truncateSubject(name ?? "Contact")
                replacement = "[👤 \(truncated)](tabmail://contact/\(numericId))"
            case "Template":
                let name = resolveTemplateName(numericId)
                let truncated = truncateSubject(name ?? "Template")
                replacement = "[📝 \(truncated)](tabmail://template/\(numericId))"
            default:
                continue
            }
            print("[AIChatDebug]   replacing \(entityType) id=\(numericId) → '\(replacement)'")
            result.replaceSubrange(match.range, with: replacement)
        }

        // Also handle shorthand patterns: (email N), unique_id N
        // Matching TB's exception patterns in idTranslator.js.
        // Only replace when the numeric ID is actually in our ID map (prevents false pills).
        let shorthandPatterns: [Regex<(Substring, Substring)>] = [
            /\(email (\d+)\)/,
            /unique_id:?\s*(\d+)/,
        ]

        for pattern in shorthandPatterns {
            let shorthandMatches = Array(result.matches(of: pattern))
            if !shorthandMatches.isEmpty {
                print("[AIChatDebug] Shorthand pattern matched \(shorthandMatches.count) times")
            }
            for match in shorthandMatches.reversed() {
                guard let numericId = Int(match.1), idMap[numericId] != nil else { continue }
                let subject = resolveEmailSubject(numericId)
                let truncated = truncateSubject(subject ?? "Email")
                let replacement = "[📧 \(truncated)](tabmail://email/\(numericId))"
                print("[AIChatDebug]   shorthand replacing id=\(numericId) → '\(replacement)'")
                result.replaceSubrange(match.range, with: replacement)
            }
        }

        displayCache[text] = result
        return result
    }

    // MARK: - Event/Contact Resolution

    /// Resolve calendar event title from cache (populated during processToolOutputForLLM).
    /// Google Calendar events aren't in EventKit, so titles are extracted from tool output.
    private func resolveEventTitle(_ numericId: Int) -> String? {
        return eventTitleCache[numericId]
    }

    /// Resolve contact display name from Contacts framework for a numeric ID.
    private func resolveContactName(_ numericId: Int) -> String? {
        guard let realId = idMap[numericId] else { return nil }
        guard let contact = try? CNContactStoreHelper.fetchContact(identifier: realId) else { return nil }
        return CNContactStoreHelper.displayName(contact)
    }

    /// Cache a template name for pill rendering.
    func cacheTemplateName(numericId: Int, name: String) {
        templateNameCache[numericId] = name
    }

    /// Resolve template name from PromptStore for a numeric ID.
    private func resolveTemplateName(_ numericId: Int) -> String? {
        guard idMap[numericId] != nil else { return nil }
        // PromptStore is @MainActor — since ChatIdTranslator is an actor, we access
        // the templates array via MainActor.assumeIsolated only if we're already on main.
        // For pill rendering (called during processResponseForDisplay which runs on the actor),
        // we use the cached template name if available, or fall back to generic label.
        return templateNameCache[numericId]
    }

    /// Fetch full template detail for a numeric ID (used for pill popover).
    /// Reads live from `PromptStore` (MainActor hop) — not cached, so renames are
    /// reflected immediately. Returns nil if the realId isn't in `idMap` or the
    /// template isn't in `PromptStore` (or is soft-deleted).
    func resolveTemplateDetail(_ numericId: Int) async -> TemplatePillDetail? {
        ensureLoadedFromDB()
        guard let realId = idMap[numericId] else { return nil }
        let template: ReplyTemplate? = await MainActor.run {
            PromptStore.shared.templates.first { $0.id == realId && !$0.deleted }
        }
        guard let t = template else { return nil }
        let preview: String? = {
            let trimmed = t.exampleReply.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { return nil }
            if trimmed.count <= 120 { return trimmed }
            return String(trimmed.prefix(120)) + "…"
        }()
        return TemplatePillDetail(
            id: numericId,
            realId: realId,
            name: t.name,
            instructionCount: t.instructions.count,
            examplePreview: preview
        )
    }

    /// Cache structured event detail for pill popover display.
    /// Called by calendar tools with full GCalEvent data before returning output.
    /// `realId` is the bare event ID from the provider (NOT compound).
    /// `accountId`/`calendarId`/`calendarName` provide calendar provenance.
    /// `eventTimeZone` is the IANA id stored on the event itself (Google's
    /// `start.timeZone`); pass nil for events that float in the user's local zone.
    /// Compound key is built internally from `accountId + realId`.
    ///
    /// Persistence model — symmetric with email/contact/template pills:
    ///   - In-memory snapshot of the detail (this session only) so popovers are
    ///     instant and a freshly-queued create renders before the server has it.
    ///   - GRDB persists ONLY the calendar provenance (`chatEventCalendar`, v55)
    ///     so a later `resolveEventDetail` from a past session can re-fetch the
    ///     authoritative event from the provider. We never persist title/dates/
    ///     attendees — those would go stale silently when other clients edit.
    func cacheEventDetail(
        realId: String,
        accountId: String?,
        calendarId: String?,
        calendarName: String?,
        title: String,
        startDate: Date?,
        endDate: Date?,
        isAllDay: Bool,
        location: String?,
        notes: String?,
        attendees: [EventPillAttendee],
        isRecurring: Bool,
        recurrenceRule: String?,
        availability: String,
        htmlLink: String?,
        eventTimeZone: String? = nil
    ) {
        let compoundKey = if let accountId, !accountId.isEmpty {
            CompoundEventId.make(accountId: accountId, eventId: realId)
        } else {
            realId // Fallback for legacy callers without accountId
        }
        eventDetailCache[compoundKey] = EventDetailCacheEntry(
            title: title,
            startDate: startDate,
            endDate: endDate,
            isAllDay: isAllDay,
            location: location,
            notes: notes,
            attendees: attendees,
            isRecurring: isRecurring,
            recurrenceRule: recurrenceRule,
            availability: availability,
            htmlLink: htmlLink,
            eventTimeZone: eventTimeZone
        )
        if let accountId, !accountId.isEmpty, let calendarId, !calendarId.isEmpty {
            let info = EventCalendarInfo(accountId: accountId, calendarId: calendarId, calendarName: calendarName)
            eventCalendarCache[compoundKey] = info
            persistEventCalendar(compoundKey: compoundKey, info: info)
        }
        print("[ChatIdTranslator] cacheEventDetail: key='\(compoundKey.prefix(50))' title='\(title.prefix(30))' (detail=\(eventDetailCache.count), cal=\(eventCalendarCache.count))")
    }

    /// After a calendar create succeeds on the server, repoint the numericId
    /// that was assigned to the optimistic pre-generated event id over to the
    /// REAL id the provider returned. Without this, the LLM's `event_id`
    /// (still mapped to the pre-id) causes the next edit/delete to send the
    /// server an id it doesn't recognize (Graph: HTTP 400
    /// `ErrorInvalidIdMalformed`; CalDAV: 404; Google ignores client-supplied
    /// ids except as idempotency keys, so the pre-id often happens to match).
    /// Updates idMap, reverseMap, AND the two event caches keyed by compound id.
    func remapEventRealId(from oldRealId: String, to newRealId: String, accountId: String?) {
        ensureLoadedFromDB()
        let oldKey = if let accountId, !accountId.isEmpty {
            CompoundEventId.make(accountId: accountId, eventId: oldRealId)
        } else { oldRealId }
        let newKey = if let accountId, !accountId.isEmpty {
            CompoundEventId.make(accountId: accountId, eventId: newRealId)
        } else { newRealId }
        if oldKey == newKey { return }
        // `remapRealId` (the existing message-side helper) handles idMap +
        // reverseMap + the `chatIdMapping` row update via `persistMapping`
        // (INSERT OR REPLACE keyed by numericId).
        _ = remapRealId(from: oldKey, to: newKey)
        displayCache.removeAll()
        // Move detail/calendar caches under the new key — these are event-only,
        // not handled by remapRealId.
        if let entry = eventDetailCache.removeValue(forKey: oldKey) {
            eventDetailCache[newKey] = entry
        }
        if let info = eventCalendarCache.removeValue(forKey: oldKey) {
            eventCalendarCache[newKey] = info
            deletePersistedEventCalendars([oldKey])
            persistEventCalendar(compoundKey: newKey, info: info)
        }
        print("[ChatIdTranslator] remapEventRealId: '\(oldKey.prefix(40))' → '\(newKey.prefix(40))'")
    }

    /// Evict cached event detail (e.g., after deletion).
    /// `realId` is the compound ID from `toRealId()` (e.g., "accountId:rawEventId").
    func evictEventDetail(realId: String) {
        eventDetailCache.removeValue(forKey: realId)
        eventCalendarCache.removeValue(forKey: realId)
        deletePersistedEventCalendars([realId])
        print("[ChatIdTranslator] evictEventDetail: realId='\(realId.prefix(40))' (detail=\(eventDetailCache.count), cal=\(eventCalendarCache.count))")
    }

    /// Fetch full event detail for a numeric ID (used for pill popover).
    /// Mirrors `resolveContactDetail`/`resolveEmailDetail`/`resolveTemplateDetail`:
    ///   1. Look up the realId via persisted `idMap`.
    ///   2. Try the in-memory snapshot first (only populated this session — used
    ///      for events that haven't drained to the server yet).
    ///   3. On miss, look up calendar provenance (in-memory or persisted v55) and
    ///      fetch the live event from the provider. No stale snapshots.
    /// Returns nil if the ID isn't known, the calendar is unrouteable, or the
    /// provider call fails.
    func resolveEventDetail(_ numericId: Int) async -> EventPillDetail? {
        ensureLoadedFromDB()
        guard let compoundId = idMap[numericId] else {
            print("[ChatIdTranslator] resolveEventDetail: numericId=\(numericId) NOT in idMap (idMap has \(idMap.count) entries)")
            return nil
        }
        if let cached = eventDetailCache[compoundId] {
            return makeEventPillDetail(numericId: numericId, compoundId: compoundId, entry: cached)
        }
        // In-memory miss: re-fetch live from the provider so the popover always
        // reflects current event state — the same pattern as the other pills.
        guard let info = resolveEventCalendarInfoLocked(compoundId: compoundId) else {
            print("[ChatIdTranslator] resolveEventDetail: no calendar provenance for compoundId='\(compoundId.prefix(50))'")
            return nil
        }
        guard let parts = CompoundEventId.split(compoundId) else { return nil }
        guard let provider = await AccountManager.shared.calendarProviders[info.accountId] else {
            print("[ChatIdTranslator] resolveEventDetail: provider unavailable for accountId='\(info.accountId.prefix(20))'")
            return nil
        }
        do {
            let event = try await provider.getEvent(calendarId: info.calendarId, eventId: parts.eventId)
            let attendees = (event.attendees ?? []).compactMap { att -> EventPillAttendee? in
                guard let email = att.email, !email.isEmpty else { return nil }
                return EventPillAttendee(email: email, name: att.displayName, status: att.responseStatus ?? "needsAction")
            }
            let rrule = (event.recurrence ?? []).first(where: { $0.uppercased().hasPrefix("RRULE:") })
            let entry = EventDetailCacheEntry(
                title: (event.summary ?? "").isEmpty ? "(No title)" : event.summary!,
                startDate: event.startDate,
                endDate: event.endDate,
                isAllDay: event.isAllDay,
                location: event.location,
                notes: event.description,
                attendees: attendees,
                isRecurring: !(event.recurrence ?? []).isEmpty,
                recurrenceRule: rrule,
                availability: event.transparency == "transparent" ? "free" : "busy",
                htmlLink: event.htmlLink,
                eventTimeZone: event.start?.timeZone ?? event.end?.timeZone
            )
            // Cache in-memory only — no GRDB write — so a subsequent edit from
            // another client invalidates after the next app launch.
            eventDetailCache[compoundId] = entry
            print("[ChatIdTranslator] resolveEventDetail: live-fetched compoundId='\(compoundId.prefix(50))' from provider")
            return makeEventPillDetail(numericId: numericId, compoundId: compoundId, entry: entry)
        } catch {
            print("[ChatIdTranslator] resolveEventDetail: provider.getEvent failed for compoundId='\(compoundId.prefix(50))': \(error)")
            return nil
        }
    }

    private func makeEventPillDetail(numericId: Int, compoundId: String, entry: EventDetailCacheEntry) -> EventPillDetail {
        let calendarName = eventCalendarCache[compoundId]?.calendarName
        return EventPillDetail(
            id: numericId,
            realId: compoundId,
            title: entry.title,
            startDate: entry.startDate,
            endDate: entry.endDate,
            isAllDay: entry.isAllDay,
            location: entry.location,
            notes: entry.notes,
            attendees: entry.attendees,
            isRecurring: entry.isRecurring,
            recurrenceRule: entry.recurrenceRule,
            availability: entry.availability,
            htmlLink: entry.htmlLink,
            calendarName: calendarName,
            eventTimeZone: entry.eventTimeZone
        )
    }

    /// Resolve calendar provenance for a numeric event ID.
    /// Returns (accountId, calendarId, calendarName) — used by edit/delete tools
    /// to route to the correct provider without the LLM passing calendar info.
    /// On in-memory miss, falls back to the persisted v55 row.
    func resolveEventCalendarInfo(_ numericId: Int) -> EventCalendarInfo? {
        ensureLoadedFromDB()
        guard let compoundId = idMap[numericId] else { return nil }
        return resolveEventCalendarInfoLocked(compoundId: compoundId)
    }

    /// Internal lookup keyed by compoundId — assumes `ensureLoadedFromDB()`
    /// has already run. Hits in-memory first, then GRDB, hydrating on success.
    private func resolveEventCalendarInfoLocked(compoundId: String) -> EventCalendarInfo? {
        if let cached = eventCalendarCache[compoundId] { return cached }
        if let loaded = loadEventCalendarFromDB(compoundKey: compoundId) {
            eventCalendarCache[compoundId] = loaded
            return loaded
        }
        return nil
    }

    // MARK: - GRDB Persistence (v55 chatEventCalendar)

    private func persistEventCalendar(compoundKey: String, info: EventCalendarInfo) {
        do {
            try AppDatabase.dbPool.write { db in
                try db.execute(sql: """
                    INSERT OR REPLACE INTO chatEventCalendar
                    (compoundId, accountId, calendarId, calendarName)
                    VALUES (?, ?, ?, ?)
                    """,
                    arguments: [compoundKey, info.accountId, info.calendarId, info.calendarName]
                )
            }
        } catch {
            print("[ChatIdTranslator] Failed to persist event calendar \(compoundKey.prefix(40)): \(error)")
        }
    }

    private func loadEventCalendarFromDB(compoundKey: String) -> EventCalendarInfo? {
        do {
            return try AppDatabase.dbPool.read { db -> EventCalendarInfo? in
                guard let row = try Row.fetchOne(db, sql: """
                    SELECT accountId, calendarId, calendarName
                    FROM chatEventCalendar WHERE compoundId = ?
                    """, arguments: [compoundKey]) else { return nil }
                let accountId: String = row["accountId"]
                let calendarId: String = row["calendarId"]
                let calendarName: String? = row["calendarName"]
                return EventCalendarInfo(accountId: accountId, calendarId: calendarId, calendarName: calendarName)
            }
        } catch {
            print("[ChatIdTranslator] Failed to load event calendar \(compoundKey.prefix(40)) from GRDB: \(error)")
            return nil
        }
    }

    private func deletePersistedEventCalendars(_ compoundKeys: [String]) {
        guard !compoundKeys.isEmpty else { return }
        do {
            try AppDatabase.dbPool.write { db in
                let placeholders = compoundKeys.map { _ in "?" }.joined(separator: ",")
                try db.execute(
                    sql: "DELETE FROM chatEventCalendar WHERE compoundId IN (\(placeholders))",
                    arguments: StatementArguments(compoundKeys)
                )
            }
        } catch {
            print("[ChatIdTranslator] Failed to delete \(compoundKeys.count) persisted event calendars: \(error)")
        }
    }

    /// Fetch full contact detail from Contacts framework for a numeric ID (used for pill popover).
    /// Returns nil if ID not found or contact not accessible.
    func resolveContactDetail(_ numericId: Int) -> ContactPillDetail? {
        ensureLoadedFromDB()
        guard let realId = idMap[numericId] else { return nil }
        guard let contact = try? CNContactStoreHelper.fetchContact(identifier: realId) else { return nil }
        let emails = contact.emailAddresses.prefix(4).map { $0.value as String }
        return ContactPillDetail(
            id: numericId,
            realId: realId,
            name: CNContactStoreHelper.displayName(contact),
            emails: Array(emails)
        )
    }

    // MARK: - Helpers

    private func truncateSubject(_ subject: String) -> String {
        if subject.count <= Config.emailPillMaxSubjectLength {
            return subject
        }
        return String(subject.prefix(Config.emailPillMaxSubjectLength - 1)) + "…"
    }

    // MARK: - Clear

    /// Clear all mappings (called when chat history is cleared).
    func clearAll() {
        idMap.removeAll()
        reverseMap.removeAll()
        nextId = 1
        freeIds.removeAll()
        refCounts.removeAll()
        subjectCache.removeAll()
        eventTitleCache.removeAll()
        templateNameCache.removeAll()
        eventDetailCache.removeAll()
        eventCalendarCache.removeAll()
        displayCache.removeAll()
        // Clear persisted mappings + event detail cache from GRDB
        do {
            try AppDatabase.dbPool.write { db in
                try db.execute(sql: "DELETE FROM chatIdMapping")
                try db.execute(sql: "DELETE FROM chatEventCalendar")
            }
        } catch {
            print("[ChatIdTranslator] Failed to clear persisted ID mappings: \(error)")
        }
        print("[ChatIdTranslator] Cleared all ID mappings")
    }

    // MARK: - Debug Stats (matches TB's getTranslationStats)

    func getStats() -> (mappings: Int, nextId: Int, freeIds: Int, refCounted: Int) {
        (idMap.count, nextId, freeIds.count, refCounts.count)
    }
}
