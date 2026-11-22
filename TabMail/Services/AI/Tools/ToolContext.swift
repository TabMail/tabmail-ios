/* This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at https://mozilla.org/MPL/2.0/. */

import Foundation
import GRDB

/// Protocol for bidirectional ID translation (real IDs ↔ numeric IDs for LLM).
/// Extracted from `ChatIdTranslator` to enable testing with mock translators.
protocol ChatIdTranslating: Sendable {
    func toNumericId(_ realId: String) async -> Int
    func toRealId(_ numericId: Int) async -> String?
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
        eventTimeZone: String?
    ) async
    func resolveEventDetail(_ numericId: Int) async -> EventPillDetail?
    func resolveEventCalendarInfo(_ numericId: Int) async -> EventCalendarInfo?
    func evictEventDetail(realId: String) async
    func cacheTemplateName(numericId: Int, name: String) async
    func resolveTemplateDetail(_ numericId: Int) async -> TemplatePillDetail?
}

/// Make ChatIdTranslator conform to the protocol (production implementation).
extension ChatIdTranslator: ChatIdTranslating {}

/// Injectable dependency container for agent tools.
/// Tools use this instead of accessing singletons directly, enabling unit testing.
///
/// Production: `ToolContext()` — uses `AppDatabase.dbPool`, `ChatIdTranslator.shared`,
/// and `AgentToolRouter.shared`.
/// Tests: `ToolContext(db: testDb, translator: mockTranslator, router: AgentToolRouter())`
/// — fully isolated, including per-test compose queue / dedup cache.
struct ToolContext: Sendable {
    let db: any DatabaseReader & Sendable
    let translator: any ChatIdTranslating

    /// Optional router override. `nil` → resolve to `AgentToolRouter.shared` lazily on
    /// the MainActor via `router`. Set to a fresh `AgentToolRouter()` in tests so each
    /// test gets isolated compose-queue and dedup-cache state — eliminates the cross-suite
    /// contention that made `EmailReplyToolTests` / `EmailComposeToolOutcomeTests` flaky
    /// when run in parallel with each other or with `AgentToolRouterTests`.
    private let routerOverride: AgentToolRouter?

    /// MainActor-isolated accessor. Returns the override when one was injected, otherwise
    /// `AgentToolRouter.shared`. Production tools see byte-identical behavior to the
    /// previous direct `AgentToolRouter.shared` access.
    @MainActor
    var router: AgentToolRouter { routerOverride ?? AgentToolRouter.shared }

    /// Test-only device zone. `nil` in production: `deviceZone` is the device's zone.
    private let deviceZoneOverride: TimeZone?

    /// The device's time zone, as a calendar write tool snapshots it once, as the first step of
    /// its operation (root rule "snapshot settings at operation start", #753): the card, the
    /// queued arguments and the result all use that one value, never the device's zone read again
    /// later. Tests set a zone that is not the host's, so the queue's drain (which runs in the
    /// host's zone) stands for a device whose zone changed between the card and the drain.
    var deviceZone: TimeZone { deviceZoneOverride ?? .current }

    /// Production default: uses app singletons.
    init() {
        self.db = AppDatabase.rawPool
        self.translator = ChatIdTranslator.shared
        self.routerOverride = nil
        self.deviceZoneOverride = nil
    }

    /// Test injection: provide custom DB, translator, and (optionally) router and device zone.
    /// Pass an explicit `AgentToolRouter()` to isolate the test from any other suite
    /// that touches the singleton in parallel.
    init(
        db: any DatabaseReader & Sendable,
        translator: any ChatIdTranslating,
        router: AgentToolRouter? = nil,
        deviceZone: TimeZone? = nil
    ) {
        self.db = db
        self.translator = translator
        self.routerOverride = router
        self.deviceZoneOverride = deviceZone
    }
}
