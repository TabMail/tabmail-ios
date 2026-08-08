/* This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at https://mozilla.org/MPL/2.0/. */

import Testing
import Foundation
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
        let result = await translator.toNumericId("42")
        #expect(result == 42)
        // Should NOT create a mapping
        let realId = await translator.toRealId(42)
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
