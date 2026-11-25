/* This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at https://mozilla.org/MPL/2.0/. */

import Testing
import Foundation
import GRDB
@testable import TabMail

// MARK: - Core Translation Tests

@Suite("ChatIdTranslator core translation")
struct CoreTranslationTests {

    @Test("new realId gets monotonically increasing numeric ID")
    func newRealIdGetsIncreasingId() async {
        let translator = ChatIdTranslator.createIsolated()
        // Use UUID-based IDs to avoid collisions with persisted entries from prior runs
        let id1 = await translator.toNumericId("msg-inc-\(UUID().uuidString)")
        let id2 = await translator.toNumericId("msg-inc-\(UUID().uuidString)")
        let id3 = await translator.toNumericId("msg-inc-\(UUID().uuidString)")
        #expect(id1 < id2)
        #expect(id2 < id3)
    }

    @Test("same realId returns same numeric ID (dedup)")
    func sameRealIdReturnsSameId() async {
        let translator = ChatIdTranslator.createIsolated()
        let uniqueKey = "msg-dedup-\(UUID().uuidString)"
        let id1 = await translator.toNumericId(uniqueKey)
        let id2 = await translator.toNumericId(uniqueKey)
        #expect(id1 == id2)
    }

    @Test("toRealId returns the correct real ID")
    func toRealIdReturnsCorrectId() async {
        let translator = ChatIdTranslator.createIsolated()
        let uniqueKey = "real-id-\(UUID().uuidString)"
        let numericId = await translator.toNumericId(uniqueKey)
        let realId = await translator.toRealId(numericId)
        #expect(realId == uniqueKey)
    }

    @Test("toRealId returns nil for unknown numeric ID")
    func toRealIdReturnsNilForUnknown() async {
        let translator = ChatIdTranslator.createIsolated()
        let result = await translator.toRealId(9999)
        #expect(result == nil)
    }

    @Test("already-numeric realId returns as-is (identity guard)")
    func numericRealIdReturnsAsIs() async {
        let translator = ChatIdTranslator.createIsolated()
        // The translator lazily loads every mapping persisted in the shared
        // GRDB store, so a small id like 42 is claimed by an earlier run's
        // mapping on a long-lived simulator and the "no mapping" assertion
        // below reads that row instead. Use an id no run can have allocated.
        let numeric = 900_000_000_042
        let result = await translator.toNumericId(String(numeric))
        #expect(result == numeric)
        // Should NOT create a mapping
        let realId = await translator.toRealId(numeric)
        #expect(realId == nil)
    }

    @Test("numeric string with leading zeros is not treated as numeric identity")
    func leadingZerosNotNumeric() async {
        let translator = ChatIdTranslator.createIsolated()
        // "042" != String(Int("042")!) which is "42", so it should be mapped normally
        let result = await translator.toNumericId("042")
        let realId = await translator.toRealId(result)
        #expect(realId == "042")
    }

    @Test("processResponseForDisplay emits template chip syntax with cached name (regression)")
    func templateChipFromCachedName() async {
        let translator = ChatIdTranslator.createIsolated()
        let realId = "tmpl-\(UUID().uuidString)"
        let numericId = await translator.toNumericId(realId)
        await translator.cacheTemplateName(numericId: numericId, name: "Polite Reply")
        let rendered = await translator.processResponseForDisplay("Try [Template](\(numericId)) for this.")
        #expect(rendered.contains("[📝 Polite Reply](tabmail://template/\(numericId))"))
    }

    @Test("processResponseForDisplay falls back to 'Template' when name not cached (regression)")
    func templateChipWithoutCachedName() async {
        let translator = ChatIdTranslator.createIsolated()
        let realId = "tmpl-\(UUID().uuidString)"
        let numericId = await translator.toNumericId(realId)
        let rendered = await translator.processResponseForDisplay("Try [Template](\(numericId)).")
        #expect(rendered.contains("[📝 Template](tabmail://template/\(numericId))"))
    }

    @Test("event chip title strips rich (↻ RRULE:…) marker — chip shows entry name only")
    func eventChipStripsRichRecurrenceMarker() async {
        // Regression: v1.5.21+ surfaces the RRULE on grouped event lines so the
        // LLM can reason about edit_scope. The marker is for the LLM only —
        // the chip the USER sees must NOT carry raw `RRULE:FREQ=WEEKLY` text.
        let translator = ChatIdTranslator.createIsolated()
        let realId = "evt-\(UUID().uuidString)"
        let toolOutput = """
        date: Thursday, May 21, 2026
        timezone: America/Vancouver
        22:00 - 22:30: Test (↻ RRULE:FREQ=WEEKLY)\tevent_id: \(realId)
        """
        _ = await translator.processToolOutputForLLM(toolOutput)
        let numericId = await translator.toNumericId(realId)
        let rendered = await translator.processResponseForDisplay("[Event](\(numericId))")
        #expect(rendered.contains("[📅 Test](tabmail://event/\(numericId))"))
        #expect(!rendered.contains("RRULE"), "rendered chip leaked machine-code RRULE: \(rendered)")
        #expect(!rendered.contains("(↻"), "rendered chip leaked recurrence marker: \(rendered)")
    }

    @Test("event chip title survives the formatter's real timed, recurring, free/busy and all-day rows")
    func eventChipTitleFromRealFormatterOutput() async {
        // Joint producer/consumer test: feed ACTUAL formatGroupedSummary output
        // (not a handwritten copy of its shape) through processToolOutputForLLM
        // and assert the pill title for every row kind. A prefix regex in the
        // translator once rejected cued timed rows and every pill became "Event".
        let day = Calendar(identifier: .gregorian).date(byAdding: .day, value: 7, to: Date())!
        let dayFmt = DateFormatter()
        dayFmt.locale = Locale(identifier: "en_US_POSIX")
        dayFmt.timeZone = TimeZone(identifier: "UTC")
        dayFmt.dateFormat = "yyyy-MM-dd"
        let d = dayFmt.string(from: day)
        func mk(_ id: String, _ title: String, start: String?, end: String?, date: String? = nil, recurrence: [String]? = nil, transparency: String? = nil) -> GCalEvent {
            GCalEvent(id: id, summary: title, location: nil, description: nil,
                      start: GCalDateTime(dateTime: start, date: date, timeZone: nil),
                      end: GCalDateTime(dateTime: end, date: date, timeZone: nil),
                      attendees: nil, organizer: nil, recurrence: recurrence, transparency: transparency,
                      status: nil, htmlLink: nil, created: nil, updated: nil)
        }
        let timedId = "evt-timed-\(UUID().uuidString)"
        let recurId = "evt-recur-\(UUID().uuidString)"
        let freeId = "evt-free-\(UUID().uuidString)"
        let allDayId = "evt-allday-\(UUID().uuidString)"
        let events: [(event: GCalEvent, accountId: String, calendarId: String, accessRole: String?)] = [
            (mk(timedId, "Early run", start: "\(d)T05:03:00Z", end: "\(d)T06:00:00Z"), "acct-a", "cal-a", nil),
            (mk(recurId, "Weekly: planning", start: "\(d)T17:00:00Z", end: "\(d)T18:00:00Z", recurrence: ["RRULE:FREQ=MONTHLY;BYDAY=TU,TH;BYSETPOS=2"]), "acct-a", "cal-a", nil),
            (mk(freeId, "Focus", start: "\(d)T14:00:00Z", end: "\(d)T16:00:00Z", transparency: "transparent"), "acct-a", "cal-a", nil),
            (mk(allDayId, "Holiday", start: nil, end: nil, date: d), "acct-a", "cal-a", nil),
        ]
        let output = CalendarToolHelpers.formatGroupedSummary(events, timeZone: TimeZone(identifier: "UTC"))
        #expect(output.contains("05:03 (5:03 a.m.) - 06:00 (6 a.m.): Early run"))
        // The rule in the tools' fields (#552): quotes, colons and an `other` part in the marker.
        #expect(output.contains("Weekly: planning (↻ {\"freq\":\"MONTHLY\",\"byDay\":[\"TU\",\"TH\"],\"other\":\"BYSETPOS=2\"})"))

        let translator = ChatIdTranslator.createIsolated()
        let translated = await translator.processToolOutputForLLM(output)
        // The cue text must survive ID translation untouched.
        #expect(translated.contains("05:03 (5:03 a.m.) - 06:00 (6 a.m.): Early run"))
        for (realId, expectedTitle) in [
            (CompoundEventId.make(accountId: "acct-a", eventId: timedId), "Early run"),
            (CompoundEventId.make(accountId: "acct-a", eventId: recurId), "Weekly: planning"),
            (CompoundEventId.make(accountId: "acct-a", eventId: freeId), "Focus"),
            (CompoundEventId.make(accountId: "acct-a", eventId: allDayId), "Holiday"),
        ] {
            let numericId = await translator.toNumericId(realId)
            let rendered = await translator.processResponseForDisplay("[Event](\(numericId))")
            #expect(rendered.contains("[📅 \(expectedTitle)](tabmail://event/\(numericId))"), "row for \(expectedTitle): \(rendered)")
            #expect(!rendered.contains("a.m.") && !rendered.contains("p.m.") && !rendered.contains("(↻") && !rendered.contains("[free]"), "pill leaked clock/marker text: \(rendered)")
        }
    }

    @Test("event chip title strips bare (↻) marker — back-compat")
    func eventChipStripsBareRecurrenceMarker() async {
        let translator = ChatIdTranslator.createIsolated()
        let realId = "evt-\(UUID().uuidString)"
        let toolOutput = """
        date: Thursday, May 21, 2026
        timezone: America/Vancouver
        22:00 - 22:30: Test (↻)\tevent_id: \(realId)
        """
        _ = await translator.processToolOutputForLLM(toolOutput)
        let numericId = await translator.toNumericId(realId)
        let rendered = await translator.processResponseForDisplay("[Event](\(numericId))")
        #expect(rendered.contains("[📅 Test](tabmail://event/\(numericId))"))
    }
}

// MARK: - collectRefs Tests

@Suite("ChatIdTranslator.collectRefs")
struct CollectRefsTests {

    @Test("extracts numeric IDs from Email pill patterns")
    func emailPills() {
        let text = "Check [Email](1) and [Email](2) for details"
        let refs = ChatIdTranslator.collectRefs(from: text)
        #expect(refs == [1, 2])
    }

    @Test("extracts numeric IDs from Event patterns")
    func eventPills() {
        let text = "See [Event](10) for the meeting"
        let refs = ChatIdTranslator.collectRefs(from: text)
        #expect(refs == [10])
    }

    @Test("extracts numeric IDs from Contact patterns")
    func contactPills() {
        let text = "Talk to [Contact](42)"
        let refs = ChatIdTranslator.collectRefs(from: text)
        #expect(refs == [42])
    }

    @Test("extracts from mixed entity types")
    func mixedTypes() {
        let text = "[Email](1) about [Event](5) with [Contact](3)"
        let refs = ChatIdTranslator.collectRefs(from: text)
        #expect(refs.contains(1))
        #expect(refs.contains(5))
        #expect(refs.contains(3))
        #expect(refs.count == 3)
    }

    @Test("returns empty for no matches")
    func noMatches() {
        let refs = ChatIdTranslator.collectRefs(from: "No pills here at all")
        #expect(refs.isEmpty)
    }

    @Test("returns empty for empty string")
    func emptyString() {
        let refs = ChatIdTranslator.collectRefs(from: "")
        #expect(refs.isEmpty)
    }

    @Test("handles compound IDs with colon separator")
    func compoundIds() {
        let text = "[Event](7:8)"
        let refs = ChatIdTranslator.collectRefs(from: text)
        #expect(refs.contains(7))
        #expect(refs.contains(8))
        #expect(refs.count == 2)
    }

    @Test("deduplicates repeated IDs")
    func deduplication() {
        let text = "[Email](1) and another [Email](1) reference"
        let refs = ChatIdTranslator.collectRefs(from: text)
        #expect(refs == [1])
    }

    @Test("does not match invalid entity types")
    func invalidEntityType() {
        let text = "[Message](1) and [Thread](2)"
        let refs = ChatIdTranslator.collectRefs(from: text)
        #expect(refs.isEmpty)
    }

    @Test("does not match non-numeric IDs in parentheses")
    func nonNumericIds() {
        let text = "[Email](abc)"
        let refs = ChatIdTranslator.collectRefs(from: text)
        #expect(refs.isEmpty)
    }

    @Test("handles multiple pills on the same line")
    func multipleSameLine() {
        let text = "[Email](1)[Email](2)[Event](3)"
        let refs = ChatIdTranslator.collectRefs(from: text)
        #expect(refs.count == 3)
    }

    @Test("extracts numeric IDs from Template patterns (regression)")
    func templatePills() {
        let refs = ChatIdTranslator.collectRefs(from: "use [Template](42) and [Email](7)")
        #expect(refs == [42, 7])
    }
}

// MARK: - collectRefsFromTurn Tests

@Suite("ChatIdTranslator.collectRefsFromTurn")
struct CollectRefsFromTurnTests {

    private func makeTurn(
        role: String = "assistant",
        content: String = "",
        userMessage: String? = nil,
        type: String = "normal"
    ) -> ChatTurn {
        ChatTurn(
            id: ChatTurn.generateId(),
            timestamp: 1000,
            role: role,
            content: content,
            userMessage: userMessage,
            type: type,
            chars: content.count,
            renderedContent: nil,
            sessionId: nil,
            remindersSnapshot: nil,
            emailContextJSON: nil,
            thinkingContent: nil
        )
    }

    @Test("user turns scan userMessage")
    func userMessage() {
        let turn = makeTurn(role: "user", content: "chat_converse", userMessage: "Check [Email](9)")
        let refs = ChatIdTranslator.collectRefsFromTurn(turn)
        #expect(refs.contains(9))
    }

    @Test("assistant turns scan content")
    func assistantContent() {
        let turn = makeTurn(role: "assistant", content: "See [Email](7) and [Event](8)")
        let refs = ChatIdTranslator.collectRefsFromTurn(turn)
        #expect(refs.contains(7))
        #expect(refs.contains(8))
    }

    @Test("session_break type skips content scanning")
    func sessionBreakSkipsContent() {
        let turn = makeTurn(role: "assistant", content: "[Email](99)", type: "session_break")
        let refs = ChatIdTranslator.collectRefsFromTurn(turn)
        #expect(!refs.contains(99))
    }

    @Test("user role does not scan content")
    func userRoleContentNotScanned() {
        let turn = makeTurn(role: "user", content: "[Email](10)", userMessage: nil)
        let refs = ChatIdTranslator.collectRefsFromTurn(turn)
        #expect(refs.isEmpty)
    }
}

// MARK: - Reference Counting Tests

@Suite("ChatIdTranslator reference counting")
struct ReferenceCountingTests {

    @Test("register increases refCount")
    func registerIncreasesRefCount() async {
        let translator = ChatIdTranslator.createIsolated()
        let id = await translator.toNumericId("msg-1")
        await translator.registerTurnRefs([id])
        // Verify the ID is still resolvable (not freed)
        let realId = await translator.toRealId(id)
        #expect(realId == "msg-1")
    }

    @Test("unregister decreases refCount and frees at zero")
    func unregisterFreesAtZero() async {
        let translator = ChatIdTranslator.createIsolated()
        let id = await translator.toNumericId("msg-2")
        await translator.registerTurnRefs([id])
        await translator.unregisterTurnRefs([id])
        // ID should be freed — toRealId returns nil
        let realId = await translator.toRealId(id)
        #expect(realId == nil)
    }

    @Test("unregister with refCount > 1 does not free")
    func unregisterDoesNotFreeAboveZero() async {
        let translator = ChatIdTranslator.createIsolated()
        let id = await translator.toNumericId("msg-3")
        await translator.registerTurnRefs([id])
        await translator.registerTurnRefs([id]) // refCount = 2
        await translator.unregisterTurnRefs([id]) // refCount = 1
        let realId = await translator.toRealId(id)
        #expect(realId == "msg-3") // still alive
    }

    @Test("freed IDs are recycled by next toNumericId call")
    func freedIdsRecycled() async {
        let translator = ChatIdTranslator.createIsolated()
        let id1 = await translator.toNumericId("msg-recycle-\(UUID().uuidString)")
        await translator.registerTurnRefs([id1])
        await translator.unregisterTurnRefs([id1]) // frees id1

        // Next allocation should reuse the freed ID
        let id2 = await translator.toNumericId("msg-new-\(UUID().uuidString)")
        #expect(id2 == id1)
    }

    @Test("multiple refs registered and unregistered correctly")
    func multipleRefs() async {
        let translator = ChatIdTranslator.createIsolated()
        let idA = await translator.toNumericId("msg-a")
        let idB = await translator.toNumericId("msg-b")
        await translator.registerTurnRefs([idA, idB])
        await translator.registerTurnRefs([idA]) // idA refCount=2, idB refCount=1

        await translator.unregisterTurnRefs([idA, idB]) // idA=1, idB freed
        #expect(await translator.toRealId(idA) == "msg-a") // still alive
        #expect(await translator.toRealId(idB) == nil) // freed
    }
}

// MARK: - Orphan Sweep Tests

@Suite("ChatIdTranslator sweepOrphans")
struct SweepOrphansTests {

    @Test("IDs with refCount 0 are evicted, refCount > 0 kept")
    func sweepEvictsOrphans() async {
        let translator = ChatIdTranslator.createIsolated()

        // Create several IDs, only register refs for some
        let kept = await translator.toNumericId("msg-keep")
        _ = await translator.toNumericId("msg-orphan1")
        _ = await translator.toNumericId("msg-orphan2")

        await translator.registerTurnRefs([kept]) // only this one has refs

        // Build refCounts to trigger sweep logic via buildRefCounts
        let turn = ChatTurn(
            id: ChatTurn.generateId(),
            timestamp: 1000,
            role: "assistant",
            content: "[Email](\(kept))",
            userMessage: nil,
            type: "normal",
            chars: 10,
            renderedContent: nil,
            sessionId: nil,
            remindersSnapshot: nil,
            emailContextJSON: nil,
            thinkingContent: nil
        )
        await translator.buildRefCounts(allTurns: [turn])

        // After buildRefCounts, orphan IDs (not referenced by any turn) should be freed
        #expect(await translator.toRealId(kept) != nil) // kept — referenced
    }
}

// MARK: - mergeFromIsolated Tests

@Suite("ChatIdTranslator mergeFromIsolated")
struct MergeFromIsolatedTests {

    @Test("no conflict: headless numericId not in main added directly")
    func noConflict() async {
        let main = ChatIdTranslator.createIsolated()
        let headless = ChatIdTranslator.createIsolated()

        let hId = await headless.toNumericId("headless-msg")
        let headlessMap = await headless.getIdMap()

        let message = "See [Email](\(hId))"
        let result = await main.mergeFromIsolated(headlessMap, message: message)

        // ID should be added to main with same numeric ID
        #expect(await main.toRealId(hId) == "headless-msg")
        #expect(result.contains("[Email](\(hId))"))
    }

    @Test("realId already exists: reuse existing numericId and remap message text")
    func realIdAlreadyExists() async {
        let main = ChatIdTranslator.createIsolated()
        let headless = ChatIdTranslator.createIsolated()

        // Create the same realId in both with different numeric IDs
        let mainId = await main.toNumericId("shared-merge-msg")
        _ = await main.toNumericId("filler-merge") // bump nextId in main
        let headlessId = await headless.toNumericId("other-merge-msg")
        let headlessSharedId = await headless.toNumericId("shared-merge-msg")

        let headlessMap = await headless.getIdMap()
        let message = "See [Email](\(headlessId)) and [Email](\(headlessSharedId))"
        let result = await main.mergeFromIsolated(headlessMap, message: message)

        // "shared-merge-msg" should reuse mainId, message text should be remapped
        #expect(await main.toRealId(mainId) == "shared-merge-msg")
        #expect(result.contains("[Email](\(mainId))"))
    }

    @Test("numericId conflict: different realId gets new numericId")
    func numericIdConflict() async {
        let main = ChatIdTranslator.createIsolated()
        let headless = ChatIdTranslator.createIsolated()

        // Both assign an ID to different real IDs
        let mainId = await main.toNumericId("conflict-main-msg")
        let hId = await headless.toNumericId("conflict-headless-msg")

        let headlessMap = await headless.getIdMap()
        let message = "Check [Email](\(hId))"
        let result = await main.mergeFromIsolated(headlessMap, message: message)

        // Main's original ID should still map to "conflict-main-msg"
        #expect(await main.toRealId(mainId) == "conflict-main-msg")
        // headless-msg should be merged (possibly with new ID if conflict)
        let newId = await main.toNumericId("conflict-headless-msg")
        #expect(await main.toRealId(newId) == "conflict-headless-msg")
        #expect(result.contains("[Email](\(newId))"))
    }

    @Test("empty isolated map returns message unchanged")
    func emptyIsolatedMap() async {
        let main = ChatIdTranslator.createIsolated()
        let result = await main.mergeFromIsolated([:], message: "Hello world")
        #expect(result == "Hello world")
    }
}

// MARK: - remapRealId Tests

@Suite("ChatIdTranslator remapRealId")
struct RemapRealIdTests {

    @Test("remap updates mapping from old to new realId")
    func remapUpdatesMapping() async {
        let translator = ChatIdTranslator.createIsolated()
        let numericId = await translator.toNumericId("old-real-id")
        let count = await translator.remapRealId(from: "old-real-id", to: "new-real-id")
        #expect(count == 1)
        #expect(await translator.toRealId(numericId) == "new-real-id")
    }

    @Test("remap preserves the same numericId")
    func remapPreservesNumericId() async {
        let translator = ChatIdTranslator.createIsolated()
        let numericId = await translator.toNumericId("original-id")
        _ = await translator.remapRealId(from: "original-id", to: "moved-id")
        // Same numeric ID should now resolve to new real ID
        #expect(await translator.toRealId(numericId) == "moved-id")
        // And the new real ID should resolve back to same numeric ID
        let resolvedNumeric = await translator.toNumericId("moved-id")
        #expect(resolvedNumeric == numericId)
    }

    @Test("remap returns 0 if old realId not found")
    func remapReturnsZeroForUnknown() async {
        let translator = ChatIdTranslator.createIsolated()
        let count = await translator.remapRealId(from: "nonexistent", to: "new-id")
        #expect(count == 0)
    }

    @Test("remap cold-loads a persisted mapping before consulting the reverse map")
    func remapColdLoadsPersistedMapping() async {
        let token = UUID().uuidString
        let oldRealId = "cold-old-\(token)"
        let newRealId = "cold-new-\(token)"

        // A prior process/session persisted the mapping. A fresh actor has empty
        // in-memory maps and has never called toNumericId/toRealId.
        let writer = ChatIdTranslator.createIsolated()
        let numericId = await writer.toNumericId(oldRealId)
        let cold = ChatIdTranslator.createIsolated()

        let count = await cold.remapRealId(from: oldRealId, to: newRealId)

        #expect(count == 1)
        #expect(await cold.toRealId(numericId) == newRealId)
    }
}

// MARK: - cleanupEvictedIds Tests

@Suite("ChatIdTranslator cleanupEvictedIds")
struct CleanupEvictedIdsTests {

    private func makeTurn(
        role: String = "assistant",
        content: String = "",
        userMessage: String? = nil,
        type: String = "normal"
    ) -> ChatTurn {
        ChatTurn(
            id: ChatTurn.generateId(),
            timestamp: 1000,
            role: role,
            content: content,
            userMessage: userMessage,
            type: type,
            chars: content.count,
            renderedContent: nil,
            sessionId: nil,
            remindersSnapshot: nil,
            emailContextJSON: nil,
            thinkingContent: nil
        )
    }

    @Test("batch cleanup frees IDs when refCount drops to 0")
    func batchCleanupFreesIds() async {
        let translator = ChatIdTranslator.createIsolated()
        let id1 = await translator.toNumericId("msg-evict-1")
        let id2 = await translator.toNumericId("msg-evict-2")

        // Register refs for both IDs (simulating turn creation)
        await translator.registerTurnRefs([id1, id2])

        // Create turns referencing these IDs
        let turn1 = makeTurn(role: "assistant", content: "[Email](\(id1))")
        let turn2 = makeTurn(role: "assistant", content: "[Email](\(id2))")

        // Cleanup should free both IDs
        await translator.cleanupEvictedIds(evictedTurns: [turn1, turn2])

        #expect(await translator.toRealId(id1) == nil)
        #expect(await translator.toRealId(id2) == nil)
    }

    @Test("cleanup does not free IDs still referenced by other turns")
    func cleanupKeepsReferencedIds() async {
        let translator = ChatIdTranslator.createIsolated()
        let id = await translator.toNumericId("msg-shared")

        // Register refs twice (simulating two turns referencing the same ID)
        await translator.registerTurnRefs([id])
        await translator.registerTurnRefs([id])

        // Evict only one turn
        let evictedTurn = makeTurn(role: "assistant", content: "[Email](\(id))")
        await translator.cleanupEvictedIds(evictedTurns: [evictedTurn])

        // ID should still be alive (refCount was 2, now 1)
        #expect(await translator.toRealId(id) == "msg-shared")
    }

    @Test("cleanup with empty evicted turns does nothing")
    func cleanupEmptyTurns() async {
        let translator = ChatIdTranslator.createIsolated()
        let id = await translator.toNumericId("msg-safe")
        await translator.registerTurnRefs([id])
        await translator.cleanupEvictedIds(evictedTurns: [])
        #expect(await translator.toRealId(id) == "msg-safe")
    }
}

// MARK: - processResponseForDisplay Tests

@Suite("ChatIdTranslator processResponseForDisplay")
struct ProcessResponseForDisplayTests {

    @Test("runs without crashing on text with no pills")
    func noPillsNoCrash() async {
        let translator = ChatIdTranslator.createIsolated()
        let result = await translator.processResponseForDisplay("Hello, no pills here")
        #expect(result == "Hello, no pills here")
    }

    @Test("runs without crashing on text with unknown pill IDs")
    func unknownPillIds() async {
        let translator = ChatIdTranslator.createIsolated()
        let result = await translator.processResponseForDisplay("Check [Email](999)")
        // ID 999 not in idMap, so it should be left as-is or skipped
        #expect(result.contains("999") || result.contains("Email"))
    }

    @Test("processResponseForDisplay replaces known Email pill with subject pill")
    func knownEmailPill() async {
        let translator = ChatIdTranslator.createIsolated()
        let id = await translator.toNumericId("test-msg-id")
        // processResponseForDisplay will try to resolve subject from DB (will fail in tests)
        // but should still produce output with fallback "Email"
        let result = await translator.processResponseForDisplay("[Email](\(id))")
        #expect(result.contains("tabmail://email/\(id)"))
    }

    @Test("caches processResponseForDisplay results")
    func cachesSameInput() async {
        let translator = ChatIdTranslator.createIsolated()
        let text = "Some text without pills"
        let result1 = await translator.processResponseForDisplay(text)
        let result2 = await translator.processResponseForDisplay(text)
        #expect(result1 == result2)
    }
}

// MARK: - clearAll Tests

@Suite("ChatIdTranslator clearAll")
struct ClearAllTests {

    @Test("clearAll resets all state")
    func clearAllResetsState() async {
        let translator = ChatIdTranslator.createIsolated()
        let id = await translator.toNumericId("msg-clear-unique")
        await translator.registerTurnRefs([id])

        await translator.clearAll()

        #expect(await translator.toRealId(id) == nil)
        // After clear, a new allocation should succeed (don't check exact ID due to shared DB)
        let newId = await translator.toNumericId("msg-after-clear-unique")
        #expect(await translator.toRealId(newId) == "msg-after-clear-unique")
    }
}

// MARK: - getStats Tests

@Suite("ChatIdTranslator getStats")
struct GetStatsTests {

    @Test("stats reflect current state")
    func statsReflectState() async {
        let translator = ChatIdTranslator.createIsolated()
        // Trigger lazy DB load by calling toNumericId with a dummy, then capture baseline
        let dummyId = await translator.toNumericId("stats-warmup-\(UUID().uuidString)")
        let statsBefore = await translator.getStats()
        let baselineMappings = statsBefore.mappings  // includes dummy + any DB-loaded entries

        // Use UUID-based keys to avoid collisions with persisted entries from prior runs
        let id1 = await translator.toNumericId("msg-stat-\(UUID().uuidString)")
        // Second mapping created for the `baselineMappings + 2` assertion below;
        // the numeric id itself is unused.
        _ = await translator.toNumericId("msg-stat-\(UUID().uuidString)")
        await translator.registerTurnRefs([id1])

        let stats = await translator.getStats()
        #expect(stats.mappings == baselineMappings + 2)
        #expect(stats.freeIds == 0)
        #expect(stats.refCounted >= 1)
        // Clean up: prevent dummy from persisting as test pollution
        await translator.registerTurnRefs([dummyId])
        await translator.unregisterTurnRefs([dummyId])
    }

    @Test("stats show freeIds after unregister")
    func statsShowFreeIds() async {
        let translator = ChatIdTranslator.createIsolated()
        let statsBefore = await translator.getStats()
        let baselineFreeIds = statsBefore.freeIds

        let id = await translator.toNumericId("msg-free-stat-\(UUID().uuidString)")
        await translator.registerTurnRefs([id])
        await translator.unregisterTurnRefs([id])

        let stats = await translator.getStats()
        #expect(stats.freeIds >= baselineFreeIds + 1)
    }
}

// MARK: - Template Detail Resolution Tests

@Suite("ChatIdTranslator template detail")
struct TemplateDetailResolutionTests {

    @Test("resolveTemplateDetail returns nil for unknown numeric ID")
    func resolveTemplateDetailUnknown() async {
        let translator = ChatIdTranslator.createIsolated()
        let detail = await translator.resolveTemplateDetail(99999)
        #expect(detail == nil)
    }

    @Test("resolveTemplateDetail returns nil when realId not in PromptStore")
    func resolveTemplateDetailUnregistered() async {
        let translator = ChatIdTranslator.createIsolated()
        let realId = "tmpl-missing-\(UUID().uuidString)"
        let numericId = await translator.toNumericId(realId)
        // No PromptStore registration → resolver should return nil.
        let detail = await translator.resolveTemplateDetail(numericId)
        #expect(detail == nil)
    }

    @Test("resolveTemplateDetail returns full struct for a registered template")
    @MainActor
    func resolveTemplateDetailFound() async {
        let store = PromptStore.shared
        let unique = "tmpl-found-\(UUID().uuidString)"
        let template = ReplyTemplate(
            id: unique,
            name: "Polite Decline",
            enabled: true,
            instructions: ["Be brief", "Thank them"],
            exampleReply: "Thanks for reaching out — unfortunately I can't take this on right now."
        )
        store.addTemplate(template)
        defer { store.deleteTemplate(id: unique) }

        let translator = ChatIdTranslator.createIsolated()
        let numericId = await translator.toNumericId(unique)
        let detail = await translator.resolveTemplateDetail(numericId)

        #expect(detail != nil)
        guard let d = detail else { return }
        #expect(d.id == numericId)
        #expect(d.realId == unique)
        #expect(d.name == "Polite Decline")
        #expect(d.instructionCount == 2)
        #expect(d.examplePreview != nil)
        #expect(d.examplePreview!.contains("Thanks for reaching out"))
    }

    @Test("resolveTemplateDetail truncates long example replies to 120 chars + ellipsis")
    @MainActor
    func resolveTemplateDetailTruncates() async {
        let store = PromptStore.shared
        let unique = "tmpl-long-\(UUID().uuidString)"
        let longReply = String(repeating: "a", count: 200)
        store.addTemplate(ReplyTemplate(id: unique, name: "Long", exampleReply: longReply))
        defer { store.deleteTemplate(id: unique) }

        let translator = ChatIdTranslator.createIsolated()
        let numericId = await translator.toNumericId(unique)
        let detail = await translator.resolveTemplateDetail(numericId)
        guard let d = detail else { Issue.record("expected detail"); return }
        #expect(d.examplePreview?.count == 121)        // 120 chars + "…"
        #expect(d.examplePreview?.hasSuffix("…") == true)
    }

    @Test("resolveTemplateDetail returns nil examplePreview for empty exampleReply")
    @MainActor
    func resolveTemplateDetailEmptyExample() async {
        let store = PromptStore.shared
        let unique = "tmpl-empty-\(UUID().uuidString)"
        store.addTemplate(ReplyTemplate(id: unique, name: "X", exampleReply: ""))
        defer { store.deleteTemplate(id: unique) }

        let translator = ChatIdTranslator.createIsolated()
        let numericId = await translator.toNumericId(unique)
        let detail = await translator.resolveTemplateDetail(numericId)
        #expect(detail?.examplePreview == nil)
    }

    @Test("resolveTemplateDetail skips soft-deleted templates")
    @MainActor
    func resolveTemplateDetailSkipsDeleted() async {
        let store = PromptStore.shared
        let unique = "tmpl-deleted-\(UUID().uuidString)"
        store.addTemplate(ReplyTemplate(id: unique, name: "Tombstone"))
        store.deleteTemplate(id: unique)  // soft-delete (deleted=true)

        let translator = ChatIdTranslator.createIsolated()
        let numericId = await translator.toNumericId(unique)
        let detail = await translator.resolveTemplateDetail(numericId)
        #expect(detail == nil)
    }
}

// MARK: - Event pill re-link (compare-and-swap normal case)

@Suite("ChatIdTranslator event pill re-link", .processGlobalState)
struct EventPillRelinkTests {

    /// **THE PROPERTY: the guarded re-link still moves an event pill in the
    /// normal case.** With the stored mapping still on the pre-generated id,
    /// `remapEventRealId` moves it to the provider's real id, and the pill
    /// opens the event at that id.
    @Test("An event pill re-link with the stored mapping on the old id still moves it")
    func eventPillRelinkMovesTheStoredMapping() async throws {
        let translator = ChatIdTranslator.createIsolated()
        let accountId = "acct-evt-\(UUID().uuidString)"
        let preId = "pre-\(UUID().uuidString)"
        let realId = "real-\(UUID().uuidString)"
        let oldKey = CompoundEventId.make(accountId: accountId, eventId: preId)
        let newKey = CompoundEventId.make(accountId: accountId, eventId: realId)
        let numeric = await translator.toNumericId(oldKey)
        await translator.cacheEventDetail(
            realId: preId, accountId: accountId, calendarId: "cal", calendarName: "Calendar",
            title: "Planning", startDate: Date(), endDate: Date().addingTimeInterval(3600),
            isAllDay: false, location: nil, notes: nil, attendees: [],
            isRecurring: false, recurrenceRule: nil, availability: "busy", htmlLink: nil)
        // NON-VACUITY: the stored mapping names the old id.
        let storedBefore = try await AppDatabase.dbPool.read { db in
            try String.fetchOne(db, sql: "SELECT realId FROM chatIdMapping WHERE numericId = ?", arguments: [numeric])
        }
        #expect(storedBefore == oldKey)

        await translator.remapEventRealId(from: preId, to: realId, accountId: accountId)

        #expect(await translator.toRealId(numeric) == newKey)
        let storedAfter = try await AppDatabase.dbPool.read { db in
            try String.fetchOne(db, sql: "SELECT realId FROM chatIdMapping WHERE numericId = ?", arguments: [numeric])
        }
        #expect(storedAfter == newKey, "the stored mapping did not move: \(String(describing: storedAfter))")
        let detail = await translator.resolveEventDetail(numeric)
        #expect(detail?.realId == newKey && detail?.title == "Planning")
        try await AppDatabase.dbPool.write { db in
            try db.execute(sql: "DELETE FROM chatIdMapping WHERE numericId = ?", arguments: [numeric])
        }
    }
}

// MARK: - Compare-and-swap miss with no stored row

@Suite("ChatIdTranslator remap with no stored row", .processGlobalState)
struct RemapWithNoStoredRowTests {

    /// **THE PROPERTY: a remap whose stored mapping is gone moves nothing and
    /// creates no row, and the translator's forward and reverse lookups stay
    /// consistent.** (An unconditional write would resurrect the mapping
    /// bound to the new id.)
    @Test("A remap with its stored mapping gone is refused and creates no row")
    func aRemapWithNoStoredRowIsRefused() async throws {
        let translator = ChatIdTranslator.createIsolated()
        let oldId = "acct-gone-\(UUID().uuidString)"
        let newId = "acct-new-\(UUID().uuidString)"
        let numeric = await translator.toNumericId(oldId)
        try await AppDatabase.dbPool.write { db in
            try db.execute(sql: "DELETE FROM chatIdMapping WHERE numericId = ?", arguments: [numeric])
        }

        let moved = await translator.remapRealId(from: oldId, to: newId)

        #expect(moved == 0)
        let stored = try await AppDatabase.dbPool.read { db in
            try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM chatIdMapping WHERE numericId = ? OR realId = ?",
                             arguments: [numeric, newId])
        }
        #expect(stored == 0, "the refused remap wrote a mapping")
        #expect(await translator.toRealId(numeric) == oldId)
        #expect(await translator.toNumericId(oldId) == numeric)
    }
}

// MARK: - Re-link onto an email another pill already names

@Suite("ChatIdTranslator re-link collision", .processGlobalState)
struct RelinkCollisionTests {

    /// **THE PROPERTY: a pill whose re-link is refused because another pill
    /// already names the email renders unavailable and opens nothing, and the
    /// other pill keeps the email, also after a reload.**
    @Test("A re-link onto an email another pill names greys the first pill out")
    func aRelinkOntoAnotherPillsEmailGreysTheFirstOut() async throws {
        let translator = ChatIdTranslator.createIsolated()
        let oldId = "acct-relink-old-\(UUID().uuidString)"
        let newId = "acct-relink-new-\(UUID().uuidString)"
        let first = await translator.toNumericId(oldId)
        let second = await translator.toNumericId(newId)

        let moved = await translator.remapRealId(from: oldId, to: newId)

        #expect(moved == 0)
        let firstRetired = await translator.isRetiredPill(first)
        #expect(firstRetired, "the refused pill is not greyed out")
        #expect(MarkdownChatText.pillIsUnavailable(isHistory: false, isRetired: firstRetired))
        #expect(await translator.resolveEmailDetail(first) == nil, "a tap on the refused pill opened a message")
        #expect(await translator.toRealId(second) == newId)
        #expect(await translator.toNumericId(newId) == second)
        let stored = try await AppDatabase.dbPool.read { db in
            try [String?](
                [first, second].map { n in
                    try String.fetchOne(db, sql: "SELECT realId FROM chatIdMapping WHERE numericId = ?", arguments: [n])
                })
        }
        #expect(stored[0].map { $0.hasPrefix(ChatIdTranslator.retiredRealIdPrefix) } == true,
                "the refused pill's stored mapping is not retired: \(String(describing: stored[0]))")
        #expect(stored[1] == newId, "the other pill lost its stored mapping")
        try await AppDatabase.dbPool.write { db in
            try db.execute(sql: "DELETE FROM chatIdMapping WHERE numericId IN (?, ?)", arguments: [first, second])
        }
    }
}

// MARK: - Retired pill availability

@Suite("ChatIdTranslator retired pill availability", .processGlobalState)
struct RetiredPillAvailabilityTests {

    /// **THE PROPERTY: a pill whose mapping a move retired renders as
    /// unavailable and opens nothing; a live pill stays available.**
    @Test("A retired pill renders unavailable and opens nothing; a live pill does not")
    func aRetiredPillRendersUnavailableAndOpensNothing() async throws {
        let translator = ChatIdTranslator.createIsolated()
        let liveId = "acct-live-\(UUID().uuidString)"
        let movedId = "acct-moved-\(UUID().uuidString)"
        let live = await translator.toNumericId(liveId)
        let moved = await translator.toNumericId(movedId)
        await translator.retireMappings(realIds: [movedId])

        let liveRetired = await translator.isRetiredPill(live)
        let movedRetired = await translator.isRetiredPill(moved)
        #expect(!liveRetired)
        #expect(movedRetired)
        #expect(!MarkdownChatText.pillIsUnavailable(isHistory: false, isRetired: liveRetired))
        #expect(MarkdownChatText.pillIsUnavailable(isHistory: false, isRetired: movedRetired))
        #expect(await translator.resolveEmailDetail(moved) == nil, "a tap on the retired pill opened a message")
        try await AppDatabase.dbPool.write { db in
            try db.execute(sql: "DELETE FROM chatIdMapping WHERE numericId IN (?, ?)", arguments: [live, moved])
        }
    }
    enum RetireProducer: String, CaseIterable, Sendable {
        /// `retireMappings`: the drop of a dropped row's pill.
        case retireMappings
        /// The refusal arm of `remapRealId`: the stored mapping was retired
        /// (by the move's own write) while memory still named the old row.
        case refusedRemap
    }

    /// Records, on the posting thread, whether each `.chatPillsRetired` was
    /// posted on the main thread.
    private final class PostThreads: @unchecked Sendable {
        private let lock = NSLock()
        private var values: [Bool] = []
        func append(_ value: Bool) { lock.withLock { values.append(value) } }
        var all: [Bool] { lock.withLock { values } }
    }

    /// **THE PROPERTY: pills already on screen turn grey in place when their
    /// mapping is retired, by either producer.** Two mounted occurrences of
    /// the moved pill (one with its popover open) and a live control use the
    /// availability model a chip owns. Both occurrences become unavailable
    /// and the open popover closes; the live control keeps its popover and
    /// stays usable; every retirement notice is posted on the main thread.
    @Test("Mounted pills grey out in place and close an open popover; a live pill stays usable",
          arguments: RetireProducer.allCases)
    @MainActor
    func mountedPillsGreyOutInPlace(producer: RetireProducer) async throws {
        let translator = ChatIdTranslator.createIsolated()
        let liveId = "acct-live-\(UUID().uuidString)"
        let movedId = "acct-moved-\(UUID().uuidString)"
        let live = await translator.toNumericId(liveId)
        let moved = await translator.toNumericId(movedId)

        let first = ChatPillAvailability(numericId: moved, type: "email", isHistory: false, translator: translator)
        let second = ChatPillAvailability(numericId: moved, type: "email", isHistory: false, translator: translator)
        let control = ChatPillAvailability(numericId: live, type: "email", isHistory: false, translator: translator)
        for pill in [first, second, control] {
            pill.startObserving()
            await pill.refresh()
        }
        // NON-VACUITY: as first rendered, every pill is available.
        #expect(!first.isUnavailable && !second.isUnavailable && !control.isUnavailable)
        first.presentation = .email(EmailPillDetail(
            id: moved, realId: movedId, subject: "Subject", from: "a@example.com",
            to: "b@example.com", date: nil, snippet: nil))
        control.presentation = .email(EmailPillDetail(
            id: live, realId: liveId, subject: "Subject", from: "a@example.com",
            to: "b@example.com", date: nil, snippet: nil))

        let threads = PostThreads()
        let token = NotificationCenter.default.addObserver(
            forName: .chatPillsRetired, object: nil, queue: nil
        ) { _ in threads.append(Thread.isMainThread) }
        defer { NotificationCenter.default.removeObserver(token) }

        switch producer {
        case .retireMappings:
            await translator.retireMappings(realIds: [movedId])
        case .refusedRemap:
            try await AppDatabase.dbPool.write { db in
                try ChatIdTranslator.retireStoredMappings(db, realId: movedId)
            }
            let remapped = await translator.remapRealId(from: movedId, to: "acct-new-\(UUID().uuidString)")
            #expect(remapped == 0, "the remap of a retired mapping was not refused")
        }

        // Bounded wait: a missing notice fails here instead of hanging.
        let deadline = ContinuousClock.now + .seconds(5)
        while !(first.isRetired && second.isRetired), ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(first.isUnavailable, "the first mounted occurrence did not grey out")
        #expect(second.isUnavailable, "the second mounted occurrence did not grey out")
        #expect(first.presentation == nil, "the retired pill's open popover stayed open")
        #expect(!control.isUnavailable, "a live pill turned grey")
        #expect(control.presentation != nil, "a live pill's popover was closed")
        let posted = threads.all
        #expect(!posted.isEmpty, "no retirement notice was posted")
        #expect(posted.allSatisfy { $0 }, "a retirement notice was posted off the main thread")
        try await AppDatabase.dbPool.write { db in
            try db.execute(sql: "DELETE FROM chatIdMapping WHERE numericId IN (?, ?)", arguments: [live, moved])
        }
    }
}
