/* This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at https://mozilla.org/MPL/2.0/. */

import Testing
import Foundation
import GRDB
@testable import TabMail

// MARK: - R13-U3 — a 409 is not proof, and only proof may retire an intention
//
// INVARIANT (system property): **the durable `PendingCalendarOperation` row
// survives every create outcome except one the provider has POSITIVELY told us
// already landed.** The row IS the user's intention; deleting it is the exit,
// and never-drop clause 2 admits an exit only on a provider-AUTHORITATIVE
// stale/no-op result. *"We could not determine the answer"* is not that.
//
// What this pins, per provider:
//   * EXCHANGE — retires on NOTHING at 409. Microsoft documents no 409 for a
//     repeated `transactionId`; the `event` resource defines it as a value "for
//     the server to AVOID REDUNDANT POST operations in case of client retries",
//     so a deduped retry receives the ORIGINAL success response and a 409 is
//     evidence against the dedup reading, not for it. Graph's observed
//     calendar-POST 409s are store-level save conflicts (`ConcurrentItemSave`,
//     `IrresolvableConflict`) that say nothing about whether the item exists.
//   * GOOGLE — retires ONLY on reason `"duplicate"` ("The requested identifier
//     already exists"), and only when we supplied the id. Google's other
//     documented 409, reason `"conflict"`, is an `events.batch` operational
//     conflict and is retryable by Google's own guidance.
//     (developers.google.com/workspace/calendar/api/guides/errors)
//
// ⚠️ THE ASSERTION IS ON THE DURABLE ROW, NOT ON A LOG LINE OR A RETURN VALUE.
// A wire count alone is defeatable and so is an outcome enum: what decides
// whether the user's create eventually happens is whether the row is still there
// for the next drain. Every test below reads it back out of the database.
//
// ⚠️ TWO-SIDED. `aSuccessfulCreateStillRetiresTheOp` is the control: without it
// "the row survives" is satisfiable by a drain that never deletes anything, and
// the four absences would be vacuous (`MIS-030`).

/// Shared by both suites in this file: a throwaway on-disk database with one
/// account installed as `AppDatabase.shared`, plus what the caller needs to put
/// the previous instance back.
fileprivate func makeCalendarConflictTestDB(accountId: String) throws -> (pool: DatabasePool, dir: URL, previous: AppDatabase?) {
    let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    var config = Configuration()
    config.foreignKeysEnabled = true
    let pool = try DatabasePool(path: dir.appendingPathComponent("test.sqlite").path, configuration: config)
    let appDb = try AppDatabase(dbPool: pool)
    let previous = AppDatabase.shared.withLock { current -> AppDatabase? in
        let prev = current; current = appDb; return prev
    }
    try pool.writeWithoutTransaction { db in
        var acc = Account(emailAddress: "cal@example.com", displayName: "Cal", provider: .gmail)
        acc.id = accountId
        try acc.insert(db)
    }
    return (pool, dir, previous)
}

@Suite("R13-U3 — calendar create conflict dispositions", .serialized, .processGlobalState)
struct CalendarConflictDispositionTests {

    private func makeTestDB(accountId: String) throws -> (pool: DatabasePool, dir: URL, previous: AppDatabase?) {
        try makeCalendarConflictTestDB(accountId: accountId)
    }

    /// Insert one `.create` against a mock whose `createEvent` behaves as
    /// configured, drain once, and report how many durable rows are left.
    ///
    /// The row is inserted DIRECTLY rather than through `queueCalendarOperation`,
    /// which fires its own `Task { await drainCalendarQueue() }`: that background
    /// drain wins the `!isDrainingCalendar` guard, the test's explicit drain
    /// returns immediately ("Skipped drain — already draining"), and the durable
    /// row is read while the real drain is still mid-flight. Same shape and same
    /// reason as `CalendarQueueOutcomeTests.unexecutableOpIsNotReportedAsSuccess`.
    private func drainOneCreate(
        accountId: String,
        pregenEventId: String?,
        configure: (MockCalendarProvider) async -> Void
    ) async throws -> (remaining: Int, createAttempts: Int, outcome: CalendarOpOutcome) {
        let (pool, dir, previous) = try makeTestDB(accountId: accountId)
        let mock = MockCalendarProvider()
        await configure(mock)
        await AccountManager.shared.registerCalendarProviderForTesting(accountId: accountId, provider: mock)
        defer {
            Task { await AccountManager.shared.unregisterCalendarProviderForTesting(accountId: accountId) }
            InstalledTestDatabaseLifetime.finish(previous: previous, pool: pool, directory: dir)
        }

        let op = PendingCalendarOperation(
            operationType: .create,
            accountId: accountId,
            eventId: pregenEventId,
            calendarId: "primary",
            arguments: ["summary": .string("Quarterly review")]
        )
        try await pool.write { db in try op.insert(db) }

        async let outcome = AccountManager.shared.awaitCalendarOpOutcome(opId: op.id, timeoutSeconds: 5.0)
        // Let the awaiter register before the drain can signal it.
        try? await Task.sleep(nanoseconds: 300_000_000)
        await AccountManager.shared.drainCalendarQueue()
        let result = await outcome

        let remaining = try await pool.read { db in try PendingCalendarOperation.fetchCount(db) }
        let attempts = await mock.createdEvents.count
        return (remaining, attempts, result)
    }

    private func isStillQueued(_ o: CalendarOpOutcome) -> Bool {
        if case .stillQueued = o { return true }
        return false
    }

    private func isSuccess(_ o: CalendarOpOutcome) -> Bool {
        if case .success = o { return true }
        return false
    }

    // MARK: Exchange

    @Test("An Exchange 409 leaves the create queued — Graph documents no 409 for a repeated transactionId, so it is not proof the event exists")
    func exchangeConflictKeepsTheIntentionQueued() async throws {
        let result = try await drainOneCreate(
            accountId: "cal-r13-u3-exchange-409", pregenEventId: "pre-ex-409"
        ) { mock in
            await mock.setCreateEventThrows(ExchangeCalendarError.httpError(409, nil))
        }
        #expect(result.createAttempts == 1, "setup: the drain never reached the provider")
        #expect(isStillQueued(result.outcome),
                "the agent was told the create had settled — got \(result.outcome)")
        #expect(result.remaining == 1,
                "the 409 was converted to success and the durable row was deleted — if the write never landed, the user's create is gone with no queued work to make it happen and nothing to sync it back. The retry is duplicate-safe because `createEventJSON` stamps `transactionId` from the durable op id.")
    }

    // MARK: Google

    /// Google's documented duplicate-identifier 409 payload shape.
    private func googleErrorBody(reason: String, message: String) -> Data {
        Data("""
        {"error":{"errors":[{"domain":"global","reason":"\(reason)","message":"\(message)"}],"code":409,"message":"\(message)"}}
        """.utf8)
    }

    @Test("A Google 409 that positively says the identifier already exists retires the op — the event is there")
    func googleDuplicateIdentifierRetiresTheOp() async throws {
        let result = try await drainOneCreate(
            accountId: "cal-r13-u3-google-dup", pregenEventId: "pre-goog-dup"
        ) { mock in
            await mock.setCreateEventThrows(GoogleCalendarError.httpError(
                409, googleErrorBody(reason: "duplicate", message: "The requested identifier already exists.")))
        }
        #expect(result.createAttempts == 1, "setup: the drain never reached the provider")
        #expect(isSuccess(result.outcome), "got \(result.outcome)")
        #expect(result.remaining == 0,
                "Google told us OUR client-supplied id is already on the calendar; requeueing that forever is the wedge, the mirror image of the drop this suite guards")
    }

    @Test("A Google 409 that is a BATCH conflict leaves the create queued — the same status code, a different fact")
    func googleBatchConflictKeepsTheIntentionQueued() async throws {
        let result = try await drainOneCreate(
            accountId: "cal-r13-u3-google-conflict", pregenEventId: "pre-goog-conflict"
        ) { mock in
            await mock.setCreateEventThrows(GoogleCalendarError.httpError(
                409, googleErrorBody(reason: "conflict", message: "Conflict")))
        }
        #expect(isStillQueued(result.outcome), "got \(result.outcome)")
        #expect(result.remaining == 1,
                "reason `conflict` is an events.batch operational conflict which Google's own guidance says to retry; it is not a statement that the event exists")
    }

    @Test("A Google 409 with no body leaves the create queued — an unreadable answer is not an authoritative one")
    func googleBodylessConflictKeepsTheIntentionQueued() async throws {
        let result = try await drainOneCreate(
            accountId: "cal-r13-u3-google-nobody", pregenEventId: "pre-goog-nobody"
        ) { mock in
            await mock.setCreateEventThrows(GoogleCalendarError.httpError(409, nil))
        }
        #expect(isStillQueued(result.outcome), "got \(result.outcome)")
        #expect(result.remaining == 1,
                "the discriminator must fail CLOSED: an unparseable body means we could not determine the answer, which clause 2 makes retryable, and the retry is duplicate-safe because Google rejects a second insert of the same client-supplied id")
    }

    @Test("A Google duplicate-identifier 409 for an op that supplied NO id leaves the create queued — 'the identifier exists' is not about our event")
    func googleDuplicateWithoutAPregeneratedIdKeepsTheIntentionQueued() async throws {
        let result = try await drainOneCreate(
            accountId: "cal-r13-u3-google-noid", pregenEventId: nil
        ) { mock in
            await mock.setCreateEventThrows(GoogleCalendarError.httpError(
                409, googleErrorBody(reason: "duplicate", message: "The requested identifier already exists.")))
        }
        #expect(isStillQueued(result.outcome), "got \(result.outcome)")
        #expect(result.remaining == 1,
                "with no client-supplied id the server minted its own, so a duplicate-identifier conflict cannot be evidence that OUR create landed")
    }

    // MARK: - R14-F1 — the same invariant, driven through the TRANSPORT SEAM
    //
    // 🚨 EVERY TEST ABOVE IS VACUOUS WITH RESPECT TO PRODUCTION, and that is the
    // defect this section closes rather than a criticism of them. They hand
    // `MockCalendarProvider` a `GoogleCalendarError.httpError(409, body)` that the
    // TEST authored, so they prove the classifier is correct given a body. In
    // production no body ever arrived: `performHTTPRequest` returns `data: nil` for
    // every non-2xx and puts the server's bytes in `errorBody`, while
    // `GoogleCalendarProvider.request` threw `httpError(status, result.data)` — a
    // line reachable ONLY when `result.data == nil`. So
    // the duplicate-id classifier (then `AccountManagerCalendarQueue.isGoogleDuplicateIdConflict`,
    // now `GoogleCalendarProvider.isDuplicateIdConflict`) returned `false` at its first `guard let body`
    // on every real 409, the arm could never fire, and a Google create whose
    // response was lost fell to the transient arm and head-of-line-blocked that
    // account's calendar lane forever.
    //
    // These two tests therefore assert the same system property as their siblings
    // — the durable row survives every outcome except a positively-proven one —
    // but they let the REAL provider parse a REAL HTTP response. They are the only
    // tests in this file that would notice `errorBody` being swapped back to
    // `data`, and the only ones that can, because a mock provider cannot express
    // the question.
    //
    // ⚠️ NON-VACUITY IS TWO-SIDED HERE TOO, and the wire half matters more than
    // usual: `servedCallSequence()` proves the POST reached the fake. Without it a
    // provider that never issued a request — or one that escaped to the live
    // internet, which leaves no record at all — would satisfy "the row survives".

    /// Google's `POST /calendar/v3/calendars/primary/events` path, as
    /// `GoogleCalendarProvider.baseURL + createEvent`'s path build it.
    private static let googleCreatePath = "/calendar/v3/calendars/primary/events"

    private func drainOneCreateThroughRealGoogleProvider(
        accountId: String,
        pregenEventId: String,
        conflictBody: Data
    ) async throws -> (remaining: Int, outcome: CalendarOpOutcome, wire: [String]) {
        let (pool, dir, previous) = try makeTestDB(accountId: accountId)
        let http = FakeHTTP.Scenario()
        http.register(
            path: Self.googleCreatePath, method: "POST",
            response: .raw(
                statusCode: 409,
                headers: ["Content-Type": "application/json"],
                body: conflictBody))
        // NON-OPTIONAL session — a dropped injection is a compile error here, not
        // a silent fallback to `sharedEphemeralSession` and the live internet
        // (`feedback_nil_defaulted_seam_is_fail_dangerous`).
        let provider = GoogleCalendarProvider(accessToken: { _ in "test-token" }, session: http.session)
        await AccountManager.shared.registerCalendarProviderForTesting(accountId: accountId, provider: provider)
        defer {
            Task { await AccountManager.shared.unregisterCalendarProviderForTesting(accountId: accountId) }
            http.close()
            InstalledTestDatabaseLifetime.finish(previous: previous, pool: pool, directory: dir)
        }

        let op = PendingCalendarOperation(
            operationType: .create,
            accountId: accountId,
            eventId: pregenEventId,
            calendarId: "primary",
            arguments: ["summary": .string("Quarterly review")]
        )
        try await pool.write { db in try op.insert(db) }

        async let outcome = AccountManager.shared.awaitCalendarOpOutcome(opId: op.id, timeoutSeconds: 5.0)
        try? await Task.sleep(nanoseconds: 300_000_000)
        await AccountManager.shared.drainCalendarQueue()
        let result = await outcome

        let remaining = try await pool.read { db in try PendingCalendarOperation.fetchCount(db) }
        return (remaining, result, http.servedCallSequence())
    }

    @Test("A REAL Google 409 whose body says `duplicate` retires the op — the error payload survives the transport seam")
    func googleDuplicateSurvivesTheTransportSeam() async throws {
        let result = try await drainOneCreateThroughRealGoogleProvider(
            accountId: "cal-r14-f1-seam-dup",
            pregenEventId: "pre-goog-seam-dup",
            conflictBody: googleErrorBody(
                reason: "duplicate", message: "The requested identifier already exists."))

        #expect(result.wire == ["POST \(Self.googleCreatePath)"],
                "the create never reached the stubbed transport, so nothing below is evidence about the seam — got \(result.wire)")
        #expect(isSuccess(result.outcome), "got \(result.outcome)")
        #expect(result.remaining == 0,
                "Google positively told us OUR client-supplied id is already on the calendar, and the queue could not hear it: the provider threw `result.data` (always nil on a non-2xx) instead of `result.errorBody`, so the duplicate-id classifier returned false at its first `guard let body` and the op fell to the transient arm — which requeues it AND inserts the account into `failedAccounts`, head-of-line-blocking every later calendar op on that account on every subsequent drain. That is a wedge, and the wedge corollary sits in the same non-recoverable set as a dropped intention.")
    }

    @Test("A REAL Google 409 whose body says `conflict` still leaves the create queued — carrying the body did not widen what counts as proof")
    func googleBatchConflictThroughTheTransportSeamStaysQueued() async throws {
        // ⚠️ THE MIRROR IMAGE, pinned at the seam. Making the body reach the
        // classifier must not make every 409 terminal: Google documents
        // reason `conflict` as an `events.batch` operational conflict its own
        // guidance says to retry, and retiring on it drops the user's create on
        // "we could not determine the answer" (never-drop clause 2). This is the
        // side that must stay GREEN when F1 is inverted.
        let result = try await drainOneCreateThroughRealGoogleProvider(
            accountId: "cal-r14-f1-seam-conflict",
            pregenEventId: "pre-goog-seam-conflict",
            conflictBody: googleErrorBody(reason: "conflict", message: "Conflict"))

        #expect(result.wire == ["POST \(Self.googleCreatePath)"],
                "the create never reached the stubbed transport — got \(result.wire)")
        #expect(isStillQueued(result.outcome), "got \(result.outcome)")
        #expect(result.remaining == 1,
                "a batch-operational conflict is not a statement that OUR event exists; retiring it drops the user's intention")
    }

    // MARK: Control

    @Test("CONTROL — an ordinary successful create still retires the op, so the four survivals above are not 'the drain never deletes'")
    func aSuccessfulCreateStillRetiresTheOp() async throws {
        let result = try await drainOneCreate(
            accountId: "cal-r13-u3-control", pregenEventId: "pre-ok"
        ) { mock in
            await mock.setCreateEventResult(GCalEvent(
                id: "server-assigned-id", summary: "Quarterly review", location: nil, description: nil,
                start: nil, end: nil, attendees: nil, organizer: nil, recurrence: nil,
                transparency: nil, status: "confirmed", htmlLink: nil, created: nil, updated: nil))
        }
        #expect(result.createAttempts == 1)
        #expect(isSuccess(result.outcome), "got \(result.outcome)")
        #expect(result.remaining == 0,
                "the fixture must be able to retire an op at all, or every 'the row survives' assertion above is vacuous (MIS-030)")
    }
}

// MARK: - R14-F2 — a split's successor-creation failure may not delete the intention
//
// INVARIANT (system property): **after a `this_and_following` split whose
// successor creation fails, either the master is UNCAPPED or a durable
// `PendingCalendarOperation` still exists.** Never both absent. A split is
// cap-then-create: if the create fails and the cap stays, the recurring series
// ends early on the server forever, and if the durable row is also gone there is
// no queued intention left to repair it — later sync imports the truncated master
// and cannot reconstruct the recurrence. That is a dropped user intention plus
// silent server-side data loss in one step.
//
// 🚨 WHAT WAS BROKEN (R14-F2). `GoogleCalendarProvider.splitSeries`'s step-6 catch
// was `catch GoogleCalendarError.httpError(409, _)` — ANY 409, body discarded. So a
// NON-duplicate 409 (Google's documented `conflict`, an `events.batch` operational
// conflict its own guidance says to retry) was read as "the create already landed",
// and the arm proved it by `getEvent(newSeriesId)` — which answered 404, because
// nothing was ever created. That 404 did NOT fall into the sibling rollback `catch`
// (a throw inside a `catch` clause is not claimed by a sibling `catch` of the same
// `do`), so it escaped to the drain, where `isCalendarNotFoundError` claims
// `httpError(404, _)`, DELETES the row and signals `.permanentFailure`.
//
// ⚠️ THE ASSERTIONS ARE THE TWO LEGS OF THE INVARIANT, NOT THE FIX'S MECHANISM.
// Nothing below looks at a `where` clause, an error case, or a log line: each test
// reads the durable row count back out of the database AND the `recurrence` array
// of every PATCH that reached the wire. A fix that satisfied one leg by breaking
// the other — e.g. uncapping a master whose successor DOES exist, which duplicates
// every future occurrence — fails `provenDuplicateWhoseProofReadFailsDoesNotUncapTheMaster`.
//
// ⚠️ TWO-SIDED (`MIS-026`, `MIS-030`). `provenDuplicateWhoseProofReadSucceedsRetiresTheOp`
// is the deliberately-held direction: gating the arm on positively-parsed proof must
// NOT make a genuine lost-ACK duplicate retry forever. It is also the control that
// keeps the two "the row survives" assertions from being satisfiable by a drain that
// never deletes anything.

@Suite("R14-F2 — recurring-split conflict dispositions", .serialized, .processGlobalState)
struct CalendarSplitConflictDispositionTests {

    private static let masterId = "master-1"
    private static let recurrenceId = "2026-05-20T17:00:00"
    private static let originalRRule = "RRULE:FREQ=WEEKLY;BYDAY=WE"
    private static let createPath = "/calendar/v3/calendars/primary/events"
    private static let masterPath = "/calendar/v3/calendars/primary/events/master-1"

    /// The id `splitSeries` pins on the successor so a retry after a lost ACK
    /// re-targets the same series. Computed with the production helper rather
    /// than hardcoded, so the fixture cannot drift away from the code.
    private static var successorPath: String {
        createPath + "/" + GoogleCalendarProvider.deterministicSplitEventId(
            masterId: masterId, recurrenceId: recurrenceId)
    }

    private static let masterJSON = Data("""
    {"id":"master-1","summary":"Weekly sync","status":"confirmed",
     "start":{"dateTime":"2026-04-01T17:00:00Z","timeZone":"UTC"},
     "end":{"dateTime":"2026-04-01T18:00:00Z","timeZone":"UTC"},
     "recurrence":["RRULE:FREQ=WEEKLY;BYDAY=WE"]}
    """.utf8)

    private static func googleErrorBody(code: Int, reason: String) -> Data {
        Data("""
        {"error":{"code":\(code),"message":"\(reason)","errors":[{"reason":"\(reason)","message":"\(reason)"}]}}
        """.utf8)
    }

    private struct SplitDrainResult {
        let remaining: Int
        let outcome: CalendarOpOutcome
        let wire: [String]
        /// The `recurrence` array of every PATCH that reached the wire, in order.
        /// One entry = the master was capped and left that way; two = capped then
        /// restored. This is how "the master is uncapped" is observed as a
        /// SERVER-SIDE fact rather than as a provider return value.
        let patchedRecurrences: [[String]]
    }

    private func drainOneSplitThroughRealGoogleProvider(
        accountId: String,
        createResponse: FakeHTTP.CannedResponse,
        successorGetResponse: FakeHTTP.CannedResponse
    ) async throws -> SplitDrainResult {
        let (pool, dir, previous) = try makeCalendarConflictTestDB(accountId: accountId)
        let http = FakeHTTP.Scenario()
        let ok = ["Content-Type": "application/json"]
        // Longest-prefix-wins + method scoping keeps these four apart: the
        // successor's GET path is longer than the master's, and `createPath`
        // is registered for POST only.
        http.register(path: Self.masterPath, method: "GET",
                      response: .raw(statusCode: 200, headers: ok, body: Self.masterJSON))
        http.register(path: Self.masterPath, method: "PATCH",
                      response: .raw(statusCode: 200, headers: ok, body: Self.masterJSON))
        http.register(path: Self.createPath, method: "POST", response: createResponse)
        http.register(path: Self.successorPath, method: "GET", response: successorGetResponse)

        // NON-OPTIONAL session — a dropped injection is a compile error here, not
        // a silent fallback to `sharedEphemeralSession` and the live internet
        // (`feedback_nil_defaulted_seam_is_fail_dangerous`).
        let provider = GoogleCalendarProvider(accessToken: { _ in "test-token" }, session: http.session)
        await AccountManager.shared.registerCalendarProviderForTesting(accountId: accountId, provider: provider)
        defer {
            Task { await AccountManager.shared.unregisterCalendarProviderForTesting(accountId: accountId) }
            http.close()
            InstalledTestDatabaseLifetime.finish(previous: previous, pool: pool, directory: dir)
        }

        let op = PendingCalendarOperation(
            operationType: .edit,
            accountId: accountId,
            eventId: Self.masterId,
            calendarId: "primary",
            arguments: [
                "summary": .string("Weekly sync (new room)"),
                "edit_scope": .string("this_and_following"),
                "recurrence_id": .string(Self.recurrenceId)
            ]
        )
        try await pool.write { db in try op.insert(db) }

        async let outcome = AccountManager.shared.awaitCalendarOpOutcome(opId: op.id, timeoutSeconds: 5.0)
        // Let the awaiter register before the drain can signal it.
        try? await Task.sleep(nanoseconds: 300_000_000)
        await AccountManager.shared.drainCalendarQueue()
        let result = await outcome

        let remaining = try await pool.read { db in try PendingCalendarOperation.fetchCount(db) }
        let patched: [[String]] = http.recordedCalls()
            .filter { $0.method == "PATCH" }
            .map { call in
                guard let body = call.body,
                      let json = try? JSONSerialization.jsonObject(with: body) as? [String: Any],
                      let rec = json["recurrence"] as? [String]
                else { return [] }
                return rec
            }
        return SplitDrainResult(
            remaining: remaining, outcome: result,
            wire: http.servedCallSequence(), patchedRecurrences: patched)
    }

    private func isStillQueued(_ o: CalendarOpOutcome) -> Bool {
        if case .stillQueued = o { return true }
        return false
    }

    private func isSuccess(_ o: CalendarOpOutcome) -> Bool {
        if case .success = o { return true }
        return false
    }

    @Test("A split whose successor creation fails WITHOUT proof leaves the master uncapped AND the intention queued")
    func unprovenConflictLeavesTheMasterUncappedAndTheIntentionQueued() async throws {
        let result = try await drainOneSplitThroughRealGoogleProvider(
            accountId: "cal-r14-f2-unproven",
            // A body-less 409 — `performHTTPRequest` reports an empty body as
            // `errorBody == nil`, so there is nothing to parse and nothing is
            // proven. Google's other documented 409 (`conflict`) reaches the same
            // disposition by the same route.
            createResponse: .raw(statusCode: 409, headers: [:], body: Data()),
            // Registered because the PRE-FIX code reaches it; the fixed code
            // never issues this request, which the wire assertion below pins.
            successorGetResponse: .raw(
                statusCode: 404, headers: ["Content-Type": "application/json"],
                body: Self.googleErrorBody(code: 404, reason: "notFound")))

        #expect(result.wire == [
            "GET \(Self.masterPath)",     // resolveToMaster
            "GET \(Self.masterPath)",     // updateEvent's GET-then-PATCH (cap)
            "PATCH \(Self.masterPath)",   // the cap
            "POST \(Self.createPath)",    // the successor create → 409
            "GET \(Self.masterPath)",     // updateEvent's GET-then-PATCH (revert)
            "PATCH \(Self.masterPath)"    // the revert
        ], "got \(result.wire)")

        // BOTH LEGS ARE ASSERTED BEFORE THE ARRAY GUARD, deliberately. The durable
        // leg and the wire leg fail INDEPENDENTLY pre-fix, and a `guard … else
        // { return }` placed above `remaining` would report only the first
        // (testing rule 9 requires the guard, not that it sit before every
        // unrelated assertion).
        #expect(result.remaining == 1,
                "the durable row is the user's intention to split this series. An UNPROVEN 409 was read as 'the create already landed', the proof-GET answered 404 because nothing was created, and that 404 escaped to `isCalendarNotFoundError` — which deletes the row. Neither leg of the invariant survived: master capped, intention gone.")
        #expect(isStillQueued(result.outcome), "got \(result.outcome)")

        #expect(result.patchedRecurrences.count == 2,
                "the master must be PATCHed twice — capped, then restored. One PATCH means the series was left ending early on the server with no successor. got \(result.patchedRecurrences)")
        guard result.patchedRecurrences.count == 2 else { return }
        #expect(result.patchedRecurrences[0].contains { $0.uppercased().contains("UNTIL=") },
                "the fixture must actually cap the master first, or 'it was uncapped' is vacuous (MIS-030) — got \(result.patchedRecurrences[0])")
        #expect(result.patchedRecurrences[1] == [Self.originalRRule],
                "the master's ORIGINAL recurrence must be back on the server; anything else leaves the user's series truncated. got \(result.patchedRecurrences[1])")
    }

    @Test("A PROVEN duplicate whose proof read then fails keeps the intention queued and does NOT uncap the master")
    func provenDuplicateWhoseProofReadFailsDoesNotUncapTheMaster() async throws {
        let result = try await drainOneSplitThroughRealGoogleProvider(
            accountId: "cal-r14-f2-proven-unreadable",
            createResponse: .raw(
                statusCode: 409, headers: ["Content-Type": "application/json"],
                body: Self.googleErrorBody(code: 409, reason: "duplicate")),
            // Google positively said our id already exists, then would not hand
            // the resource back — read-after-write lag, a transient 404.
            successorGetResponse: .raw(
                statusCode: 404, headers: ["Content-Type": "application/json"],
                body: Self.googleErrorBody(code: 404, reason: "notFound")))

        #expect(result.wire == [
            "GET \(Self.masterPath)",
            "GET \(Self.masterPath)",
            "PATCH \(Self.masterPath)",
            "POST \(Self.createPath)",
            "GET \(Self.successorPath)"
        ], "got \(result.wire)")

        #expect(result.patchedRecurrences.count == 1,
                "THE MIRROR IMAGE. The successor EXISTS — Google said so — so rolling the cap back would leave the master repeating over the successor's occurrences and duplicate every one of them. Exactly one PATCH (the cap) may reach the wire. got \(result.patchedRecurrences)")

        #expect(result.remaining == 1,
                "'we could not read it back' is not a provider-authoritative statement that the work is done or inapplicable — never-drop clause 2. The proof-GET's 404 must not be allowed to masquerade as 'the original event is gone' and delete the row.")
        #expect(isStillQueued(result.outcome), "got \(result.outcome)")
    }

    @Test("CONTROL — a proven duplicate whose proof read SUCCEEDS still retires the op, so the two survivals above are not 'the drain never deletes'")
    func provenDuplicateWhoseProofReadSucceedsRetiresTheOp() async throws {
        let successorId = GoogleCalendarProvider.deterministicSplitEventId(
            masterId: Self.masterId, recurrenceId: Self.recurrenceId)
        let result = try await drainOneSplitThroughRealGoogleProvider(
            accountId: "cal-r14-f2-proven-readable",
            createResponse: .raw(
                statusCode: 409, headers: ["Content-Type": "application/json"],
                body: Self.googleErrorBody(code: 409, reason: "duplicate")),
            successorGetResponse: .raw(
                statusCode: 200, headers: ["Content-Type": "application/json"],
                body: Data("""
                {"id":"\(successorId)","summary":"Weekly sync (new room)","status":"confirmed",
                 "recurrence":["RRULE:FREQ=WEEKLY;BYDAY=WE"]}
                """.utf8)))

        #expect(result.wire == [
            "GET \(Self.masterPath)",
            "GET \(Self.masterPath)",
            "PATCH \(Self.masterPath)",
            "POST \(Self.createPath)",
            "GET \(Self.successorPath)"
        ], "got \(result.wire)")
        #expect(result.patchedRecurrences.count == 1,
                "the successor exists; the cap stays. got \(result.patchedRecurrences)")
        #expect(isSuccess(result.outcome), "got \(result.outcome)")
        #expect(result.remaining == 0,
                "a lost ACK on a create we can PROVE landed is exit 2 — provider-authoritative. Requiring proof must not make this case retry forever (MIS-026), and the fixture must be able to retire a split op at all or both survivals above are vacuous (MIS-030).")
    }
}

extension MockCalendarProvider {
    func setCreateEventThrows(_ e: Error) { createEventThrows = e }
    func setCreateEventResult(_ ev: GCalEvent) { createEventResult = ev }
}
