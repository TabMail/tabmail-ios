/* This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at https://mozilla.org/MPL/2.0/. */

import Testing
import Foundation
import GRDB
@testable import TabMail

// A chat turn whose calendar change stays queued because the Outlook mailbox is full is told why
// (#865): the tool's "queued" result reads the reason the drain stored on the account's first queued
// change and adds "waiting because the Outlook mailbox is full", so the model does not tell the user
// the change is simply on its way. A change queued behind that one, which the drain never tries,
// waits for the same space and says so; a change still queued for any other passing reason gets no
// such line. Each case runs the real tool, confirmed, against the real queue, the real
// `ExchangeCalendarProvider` and the fake Graph calendar.

/// Confirms every card.
@MainActor
private final class ConfirmEveryCard: AgentUISink {
    nonisolated init() {}
    func deliverConfirmation(_ confirmation: AgentToolRouter.ActionConfirmation) {
        confirmation.onRespond(true)
    }
}

@Suite("A calendar tool whose change waits for a full Outlook mailbox says so (#865)", .serialized, .processGlobalState)
struct CalendarToolMailboxFullTests {

    static let clause = "waiting because the Outlook mailbox is full"

    enum Tool: String, CaseIterable, CustomTestStringConvertible, Sendable {
        case create, edit, delete

        var testDescription: String { rawValue }

        /// The fake's name for the write the mailbox refuses.
        var refused: String {
            switch self {
            case .create: "POST"
            case .edit: "PATCH"
            case .delete: "DELETE"
            }
        }
    }

    private static let preferenceKeys = [
        CalendarProviderDispatch.preferredCalendarAccountKey,
        CalendarProviderDispatch.preferredGoogleAccountKey,
        CalendarProviderDispatch.preferredCalendarKey,
        CalendarProviderDispatch.preferredGoogleCalendarKey,
    ]

    /// Runs `tool` on the Outlook account `account` as its preferred calendar, confirmed, and
    /// returns what it told the model.
    private static func run(_ tool: Tool, account: String, pool: DatabasePool) async throws -> String {
        let sink = ConfirmEveryCard()
        let invocation = ToolInvocation(uiSink: sink, sessionKey: "mailbox-full-\(account)")
        if tool == .create {
            let start = Date().addingTimeInterval(3 * 86_400)
            let zone = TimeZone.current
            return try await CalendarEventCreateTool(context: ToolContext(db: pool, translator: MockChatIdTranslator(), deviceZone: zone))
                .execute(arguments: [
                    "title": .string("Planning"),
                    "start_iso": .string(EKEventStoreHelper.toNaiveISO(start, timeZone: zone)),
                    "end_iso": .string(EKEventStoreHelper.toNaiveISO(start.addingTimeInterval(3_600), timeZone: zone)),
                ], invocation: invocation)
        }
        // The model names the event by the number a listing gave it.
        let translator = ChatIdTranslator.createIsolated()
        let forModel = await translator.processToolOutputForLLM("event_id: \(CompoundEventId.make(accountId: account, eventId: "ev-1"))")
        let numericId = try #require(CalDAVToolWire.eventIds(in: forModel).first.flatMap { Int($0) }, "no numeric id: \(forModel)")
        await translator.cacheEventDetail(
            realId: "ev-1", accountId: account, calendarId: "primary", calendarName: "Calendar",
            title: "Planning", startDate: nil, endDate: nil, isAllDay: false,
            location: nil, notes: nil, attendees: [], isRecurring: false, recurrenceRule: nil,
            availability: "busy", htmlLink: nil, eventTimeZone: nil)
        let context = ToolContext(db: pool, translator: translator, deviceZone: .current)
        if tool == .edit {
            return try await CalendarEventEditTool(context: context).execute(
                arguments: ["event_id": .string(String(numericId)), "title": .string("Planning (moved rooms)")], invocation: invocation)
        }
        return try await CalendarEventDeleteTool(context: context).execute(
            arguments: ["event_id": .string(String(numericId))], invocation: invocation)
    }

    /// Installs a fresh database holding the Outlook account `account`, registers a provider talking
    /// to `graph` as its preferred calendar, runs `body`, then restores every global it touched.
    private static func withOutlook(
        _ account: String, graph: FakeGraphCalendar, _ body: (FakeHTTP.Scenario, DatabasePool) async throws -> Void
    ) async throws {
        let http = FakeHTTP.Scenario()
        defer { http.close() }
        graph.install(on: http)
        let provider = ExchangeCalendarProvider(mailbox: "calendar@example.com", accessToken: { _ in "test-token" }, session: http.session)
        let db = try CalendarQueueTestDatabase(accountId: account)
        let defaults = UserDefaults.standard
        let priorPreferences = preferenceKeys.map { defaults.string(forKey: $0) }
        let priorDemoActive = await MainActor.run { DemoModeStore.shared.isActive }
        await AccountManager.shared.registerCalendarProviderForTesting(accountId: account, provider: provider)
        await MainActor.run { DemoModeStore.shared.isActive = false }
        for key in preferenceKeys { defaults.removeObject(forKey: key) }
        defaults.set(account, forKey: CalendarProviderDispatch.preferredCalendarAccountKey)
        var failure: Error?
        do {
            try await body(http, db.pool)
        } catch {
            failure = error
        }
        for (key, value) in zip(preferenceKeys, priorPreferences) {
            if let value { defaults.set(value, forKey: key) } else { defaults.removeObject(forKey: key) }
        }
        await MainActor.run { DemoModeStore.shared.isActive = priorDemoActive }
        await AccountManager.shared.clearAuthFailed(account)
        await AccountManager.shared.unregisterCalendarProviderForTesting(accountId: account)
        db.finish()
        if let failure { throw failure }
    }

    @Test("a change still queued says it waits for a full mailbox only when that is why", arguments: Tool.allCases, [true, false])
    func queuedResultSaysWhy(_ tool: Tool, mailboxFull: Bool) async throws {
        let account = "tool-full-\(tool.rawValue)-\(mailboxFull)"
        let graph = FakeGraphCalendar([GraphFixture.event(id: "ev-1", online: false)])
        try await Self.withOutlook(account, graph: graph) { http, pool in
            // Graph refuses the write for a full mailbox, or asks to come back later (409).
            if mailboxFull {
                graph.refuseWrites([tool.refused], code: FakeGraphCalendar.mailboxFullCode)
            } else {
                graph.refuseWrites([tool.refused], status: 409, code: "ErrorIrresolvableConflict")
            }
            let out = try await Self.run(tool, account: account, pool: pool)

            let rows = try await pool.read { db in try PendingCalendarOperation.fetchAll(db) }
            #expect(rows.count == 1 && rows.first?.status == PendingStatus.queued.rawValue,
                    "fixture check: the change is not the one still queued: \(rows.map { "\($0.status) \($0.failureReason ?? "")" }); \(out)")
            #expect(rows.first?.waitReason == (mailboxFull ? .mailboxFull : nil),
                    "fixture check: the queue stored \(String(describing: rows.first?.waitReason)); \(http.servedCallSequence())")
            #expect(out.contains("queued successfully"), "the tool did not say the change is queued: \(out)")
            #expect(out.contains(Self.clause) == mailboxFull,
                    mailboxFull ? "the tool did not say the change waits for a full mailbox: \(out)"
                                : "the tool blamed a full mailbox for another reason: \(out)")
        }
    }

    @Test("a change queued behind an older change refused for a full mailbox says so; once that change waits for another reason, it does not")
    func queuedBehindAFullMailbox() async throws {
        let account = "tool-full-behind"
        let graph = FakeGraphCalendar([GraphFixture.event(id: "ev-1", online: false)])
        try await Self.withOutlook(account, graph: graph) { http, pool in
            // An older edit finds the mailbox full and heads the account's calendar queue.
            let head = PendingCalendarOperation(
                operationType: .edit, accountId: account, eventId: "ev-1", calendarId: "primary",
                arguments: ["title": .string("Planning (moved rooms)")], eventTitle: "Planning")
            try await pool.write { db in try head.insert(db) }
            graph.refuseWrites(["PATCH"], code: FakeGraphCalendar.mailboxFullCode)
            await AccountManager.shared.drainCalendarQueue()
            let stored = try await pool.read { db in try PendingCalendarOperation.fetchOne(db, key: head.id) }
            #expect(stored?.waitReason == .mailboxFull, "fixture check: the head does not wait for space: \(http.servedCallSequence())")

            // A new event queued behind it: the drain stops the account at the head and never tries
            // it, so nothing is stored on its own row; the head's reason is still why it waits.
            let behind = try await Self.run(.create, account: account, pool: pool)
            let created = try await pool.read { db in
                try PendingCalendarOperation.filter(Column("id") != head.id).fetchAll(db)
            }
            #expect(created.count == 1 && created.first?.status == PendingStatus.queued.rawValue && created.first?.waitReason == nil,
                    "fixture check: \(created.map { "\($0.status) \(String(describing: $0.waitReason))" })")
            #expect(graph.created.isEmpty, "fixture check: the change behind was made: \(http.servedCallSequence())")
            #expect(behind.contains("queued successfully") && behind.contains(Self.clause),
                    "the change behind a full mailbox does not say why it waits: \(behind)")

            // The head is retried and Graph asks to come back later (409): its reason is cleared, and a
            // change queued now is no longer said to wait for space.
            graph.refuseWrites(["PATCH"], status: 409, code: "ErrorIrresolvableConflict")
            await AccountManager.shared.drainCalendarQueue()
            let cleared = try await pool.read { db in try PendingCalendarOperation.fetchOne(db, key: head.id) }
            #expect(cleared?.status == PendingStatus.queued.rawValue && cleared?.waitReason == nil,
                    "fixture check: the head's reason was not cleared: \(String(describing: cleared?.waitReason))")
            let after = try await Self.run(.create, account: account, pool: pool)
            #expect(after.contains("queued successfully") && !after.contains(Self.clause),
                    "a stale mailbox-full reason was given: \(after)")
        }
    }
}
