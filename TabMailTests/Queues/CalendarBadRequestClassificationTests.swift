/* This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at https://mozilla.org/MPL/2.0/. */

import Testing
import Foundation
@testable import TabMail

// MARK: - R11-C — the calendar queue's bad-request classifier
//
// INVARIANT (system property): a queued calendar operation is RETIRED only on a
// provider-AUTHORITATIVE refusal, and RETRIED on an indeterminate one.
// `CLAUDE.md`'s never-drop clause 2 states it directly — *"we could not determine
// the answer" is NOT a provider-authoritative stale result*; a thrown read, an
// unresolvable identity and an unknown outcome are all retryable, and conflating
// the two is the single most repeated defect in this codebase's history.
//
// `isCalendarBadRequestError` is the predicate that decides retirement for the
// malformed-payload arm: `true` deletes the `PendingCalendarOperation` outright,
// `false` falls through to the transient arm that requeues with `retryCount + 1`.
// So every `true` here is a user intention leaving the queue forever.
//
// ⚠️ TWO-SIDED, deliberately. The mirror-image fix — delete the classifier so
// nothing is ever retired — would make a genuinely malformed 400/415/422 retry
// forever and WEDGE the calendar lane behind it (the drain is serial per account;
// the user sees the chat hang on the next create's `awaitCalendarOpOutcome`
// timeout). A wedge is in the same non-recoverable set as a dropped intention.
// Both halves are asserted: the malformed codes must still be retired.
//
// 401/403/404 are absent from the Google/Exchange arms because dedicated earlier
// arms claim them — but ⚠️ **CORRECTED CLAUSE BY CLAUSE (R12-T1, 2026-08-06); the
// version of this paragraph that shipped with the R11-C fix was wrong about two of
// the three codes, and one of those errors was a live lane wedge.**
//
//   * **404 — TRUE as originally written.** `isCalendarNotFoundError` matches the
//     RAW HTTP form on both providers (`GoogleCalendarError.httpError(404, _)`,
//     `ExchangeCalendarError.httpError(404, _)`) as well as the typed
//     `.eventNotFound` and CalDAV's `.notFound`, so every spelling is claimed.
//   * **403 — TRUE, but the original REASON was wrong, and the wrong reason hid a
//     wedge.** The claim used to be that `isCalendarMissingScopeError` claims it.
//     It did not: that predicate matched only the TYPED `.missingScope`. What
//     actually converts a 403 is the PROVIDER — `GoogleCalendarProvider.request`
//     and `ExchangeCalendarProvider.request` map `statusCode == 403` to
//     `.missingScope` before throwing. ⚠️ But they do that only on the FIRST
//     response: after a 401 both force a token refresh, re-issue, and rethrow the
//     retry's status RAW (`httpError(retry.statusCode, retry.errorBody)` — a
//     literal `nil` payload until R14-F1). A 401-then-403 therefore arrived as
//     `httpError(403, …)`, which no arm claimed.
//     `isCalendarMissingScopeError` now matches the raw form too.
//   * **401 — FALSE as originally written.** `isCalendarAuthError` was CalDAV-only
//     (`CalDAVError.authFailed`), so a POST-REFRESH Google/Exchange 401 was not an
//     auth error, not a bad request, and not a not-found: it fell through to the
//     TRANSIENT arm, which requeues and inserts the account into `failedAccounts`
//     — and the drain's `if failedAccounts.contains(…) { continue }` then skips
//     every later op for that account on every subsequent drain. No retry can ever
//     clear a revoked grant, so that is a permanent starvation, i.e. a wedge.
//     `isCalendarAuthError` now claims the raw 401 on both providers.
//
// CalDAV's 403 is deliberately retired by `isCalendarBadRequestError`, because
// iCloud returns an opaque 403 for permanent policy refusals
// (attendee-without-organizer, shared-calendar writes) that no retry fixes. That
// asymmetry is pinned below so a future "tidy-up" cannot collapse it.

@Suite("Calendar queue — bad-request classification")
struct CalendarBadRequestClassificationTests {

    /// The same HTTP status, expressed as each of the three provider error types
    /// the classifier actually receives.
    private func errors(_ code: Int) -> [(label: String, error: Error)] {
        [
            ("Google", GoogleCalendarError.httpError(code, nil)),
            ("Exchange", ExchangeCalendarError.httpError(code, nil)),
            ("CalDAV", CalDAVError.httpError(code, nil)),
        ]
    }

    @Test("Indeterminate 4xx codes are never treated as authoritative and stay retryable")
    func indeterminateCodesAreRetryable() {
        // 408 Request Timeout — the server gave up waiting; the write may or may
        // not have landed. 409 Conflict — concurrent modification, retry after a
        // re-read. 423 Locked — the WebDAV-native "busy, come back" code, which is
        // why the CalDAV arm needed this most. 425 Too Early — replay protection.
        // 429 was already excluded and is included to prove the set only grew.
        for code in [408, 409, 423, 425, 429] {
            for (label, error) in errors(code) {
                #expect(AccountManager.isCalendarBadRequestError(error) == false,
                        "\(label) HTTP \(code) is indeterminate — retiring the op drops the user's intention")
            }
        }
    }

    @Test("Genuinely malformed 4xx codes are still retired, so a broken payload cannot wedge the lane")
    func malformedCodesAreStillRetired() {
        // Retrying any of these with the SAME payload can never succeed.
        for code in [400, 405, 411, 413, 414, 415, 422, 431] {
            for (label, error) in errors(code) {
                #expect(AccountManager.isCalendarBadRequestError(error) == true,
                        "\(label) HTTP \(code) is authoritative — retrying forever wedges the calendar drain")
            }
        }
    }

    // MARK: - R12-T1 — no provider error may be left to starve in the transient arm

    /// The drain's terminal dispositions, in the order `drainCalendarQueue` tests
    /// them. Anything this returns `false` for takes the drain's LAST arm, which
    /// requeues the op AND does `failedAccounts.insert(currentOp.accountId)` — and
    /// the drain's `if failedAccounts.contains(currentOp.accountId) { continue }`
    /// then skips every later op for that account, on this drain and on every
    /// subsequent one.
    ///
    /// ⚠️ This roster MIRRORS the drain; if an arm is added to or removed from
    /// `drainCalendarQueue`, update it here. It is deliberately not an assertion
    /// about WHICH arm claims an error — that would pin a mechanism. The property
    /// under test is only *does the error reach a terminal disposition at all*.
    private func claimedByATerminalArm(_ error: Error) -> Bool {
        if AccountManager.isCalendarNotFoundError(error) { return true }
        if AccountManager.isCalendarMissingScopeError(error) { return true }
        if AccountManager.isCalendarAuthError(error) { return true }
        if AccountManager.isCalendarUnsupportedError(error) { return true }
        if case CalDAVError.inconsistentState = error { return true }
        if AccountManager.isCalendarBadRequestError(error) { return true }
        return false
    }

    @Test("A post-refresh 401/403 reaches a terminal arm instead of starving the account's calendar lane")
    func postRefreshAuthFailuresAreTerminal() {
        // These are the exact values `GoogleCalendarProvider.request` /
        // `ExchangeCalendarProvider.request` rethrow after they have ALREADY forced
        // a token refresh and re-issued the request:
        //     throw GoogleCalendarError.httpError(retry.statusCode, retry.errorBody)
        // so the grant is revoked and no retry can ever clear it. (The payload was
        // a literal `nil` until R14-F1; these arms match on the STATUS, so `nil` is
        // still a legal value here — an empty error body produces it.)
        let postRefresh: [(label: String, error: Error)] = [
            ("Google 401", GoogleCalendarError.httpError(401, nil)),
            ("Exchange 401", ExchangeCalendarError.httpError(401, nil)),
            ("Google 403", GoogleCalendarError.httpError(403, nil)),
            ("Exchange 403", ExchangeCalendarError.httpError(403, nil)),
        ]
        for (label, error) in postRefresh {
            #expect(claimedByATerminalArm(error),
                    "\(label) is claimed by NO terminal arm, so the drain requeues it and inserts the account into failedAccounts — every later calendar op on that account is skipped forever. A wedge is in the same non-recoverable set as a dropped intention.")
        }
    }

    @Test("A genuinely transient failure still reaches NO terminal arm, so it stays retryable")
    func transientFailuresAreStillRetryable() {
        // ⚠️ THE NEGATIVE CASE. The mirror-image "fix" — widening the terminal arms
        // until nothing falls through — would retire ops on failures a retry
        // resolves, which is the dropped-intention half of the same invariant. Both
        // directions are asserted so neither can be traded for the other.
        let transient: [(label: String, error: Error)] = [
            ("connection lost", URLError(.networkConnectionLost)),
            ("Google 500", GoogleCalendarError.httpError(500, nil)),
            ("Exchange 503", ExchangeCalendarError.httpError(503, nil)),
            ("CalDAV 503", CalDAVError.httpError(503, nil)),
            ("Google 408", GoogleCalendarError.httpError(408, nil)),
            ("Exchange 429", ExchangeCalendarError.httpError(429, nil)),
            ("CalDAV 423", CalDAVError.httpError(423, nil)),
        ]
        for (label, error) in transient {
            #expect(claimedByATerminalArm(error) == false,
                    "\(label) is indeterminate or transient — a terminal arm claiming it retires the user's intention on 'we could not determine the answer'")
        }
    }

    @Test("The auth/not-found codes stay with their own arms, and CalDAV's opaque 403 stays retired here")
    func dedicatedArmCodesAreUnchanged() {
        for code in [401, 403, 404] {
            #expect(AccountManager.isCalendarBadRequestError(
                GoogleCalendarError.httpError(code, nil)) == false)
            #expect(AccountManager.isCalendarBadRequestError(
                ExchangeCalendarError.httpError(code, nil)) == false)
        }
        // CalDAV: 401 and 404 arrive as dedicated cases, so an `httpError` with
        // those codes is not the live shape; 403 IS, and is deliberately permanent.
        #expect(AccountManager.isCalendarBadRequestError(CalDAVError.httpError(403, nil)) == true)
        #expect(AccountManager.isCalendarBadRequestError(CalDAVError.authFailed) == false)
        #expect(AccountManager.isCalendarBadRequestError(CalDAVError.notFound) == false)
    }

    // MARK: - R13-U2 / R13-U7 — the two errors that reached no terminal arm

    /// An ICS master VEVENT with `DTSTART` but neither `DTEND` nor `DURATION`.
    /// `CalDAVProvider.buildNewSeriesInput` cannot recover a duration from it,
    /// which is the production path this test drives.
    private func masterWithNoRecoverableDuration() -> String {
        [
            "BEGIN:VCALENDAR",
            "VERSION:2.0",
            "BEGIN:VEVENT",
            "UID:no-duration-master",
            "SUMMARY:Broken master",
            "RRULE:FREQ=WEEKLY",
            "END:VEVENT",
            "END:VCALENDAR",
        ].joined(separator: "\r\n") + "\r\n"
    }

    @Test("A split whose new series cannot be constructed reaches a terminal arm instead of wedging the account's lane")
    func unconstructibleSplitIsTerminal() throws {
        // SYSTEM PROPERTY, not mechanism: whatever error the REAL production
        // function emits when the requested work can never be executed, some
        // terminal arm must claim it. The test never names the error type —
        // `buildNewSeriesInput` is free to change which case it throws, and this
        // stays honest as long as the drain can retire it.
        //
        // Pre-fix this threw `CalDAVError.parseError`, which no arm claims
        // (`rg parseError AccountManagerCalendarQueue.swift` → rc=1), so the
        // drain requeued the op AND inserted the account into `failedAccounts`,
        // skipping every later calendar op on that account on every subsequent
        // drain, forever. `ops` is ordered `createdAt ASC`, so the wedged op is
        // first on every pass, and no UI clears a `pendingCalendarOperation`.
        var thrown: Error?
        do {
            _ = try CalDAVProvider.buildNewSeriesInput(
                masterICS: masterWithNoRecoverableDuration(),
                patch: GCalEventInput(),
                newStartNaiveISO: "2026-05-20T17:00:00",
                newRRule: "RRULE:FREQ=WEEKLY"
            )
        } catch {
            thrown = error
        }
        // MIS-030: anchor the PRESENCE the absence-free assertion depends on.
        // Without this, a `buildNewSeriesInput` that silently returned a
        // defaulted duration would make the assertion below unreachable rather
        // than false.
        let error = try #require(thrown, "buildNewSeriesInput must refuse to invent a duration it could not recover")
        #expect(claimedByATerminalArm(error),
                "an unexecutable split is claimed by NO terminal arm, so the drain requeues it forever and head-of-line blocks every later calendar op on the account — a wedge, which sits in the same non-recoverable set as a dropped intention")
    }

    @Test("An empty or truncated response body stays retryable — the terminal reclassification is scoped, not wholesale")
    func emptyResponseBodyIsStillTransient() {
        // ⚠️ THE MIRROR IMAGE OF THE FIX ABOVE, pinned so it cannot be traded in.
        // `CalDAVProvider.getEvent`, `updateEvent`, `updateOccurrence` and
        // `splitSeries` raise the SAME `CalDAVError.parseError` case for an
        // empty/unreadable response body. That is "we could not determine the
        // answer", which never-drop clause 2 makes retryable — so claiming
        // `parseError` terminal WHOLESALE would retire a user intention on an
        // indeterminate read. Only the deterministic construction failures moved.
        #expect(claimedByATerminalArm(CalDAVError.parseError("Empty response for event evt-1")) == false,
                "an empty response body is indeterminate; retiring the op on it drops the user's intention")
    }

    @Test("A Graph id that cannot be encoded as a path segment reaches a terminal arm")
    func invalidPathSegmentIsTerminal() {
        // R13-U7. Deterministic — a pure function of the persisted id — so if it
        // is ever reached, a retry reproduces it identically and the lane wedges.
        // It can never be transient, which is why the classification is free.
        #expect(claimedByATerminalArm(ExchangeCalendarError.invalidPathSegment("Graph event id")),
                "an id that can never be turned into a URL is unexecutable, not indeterminate — leaving it in the transient arm wedges the account's calendar lane")
    }

    @Test("Every id refused BEFORE the request is formed reaches a terminal arm — all three providers")
    func idsRefusedBeforeTheRequestIsFormedAreTerminal() {
        // R13-U1/U7. Enumerated by the PROPERTY — "the provider refused to build
        // the request out of an id it holds" — and NOT by provider name, which is
        // exactly the census shape that let `9c786c57d` fix Exchange while leaving
        // its two siblings building the same URLs from the same ids (`MIS-007`).
        // All three are pure functions of the stored id, so a retry reproduces
        // each one identically and forever: transient classification is a wedge.
        let refusals: [(label: String, error: Error)] = [
            ("Exchange — unencodable Graph path segment",
             ExchangeCalendarError.invalidPathSegment("Graph event id")),
            ("Google — id would not stay in one path segment",
             GoogleCalendarError.invalidPathSegment("Google event id")),
            ("CalDAV — id resolves to a different origin",
             CalendarProviderError.notSupported("CalDAV path '//attacker.example/x' resolves to a different origin than this account's calendar server; refusing to send the account credential there")),
        ]
        for (label, error) in refusals {
            #expect(claimedByATerminalArm(error),
                    "\(label): an id that can never be turned into a safe URL is unexecutable, not indeterminate — leaving it in the transient arm wedges the account's calendar lane")
        }
    }

    @Test("R13-U4 — a split whose ROLLBACK also failed never leaves through the malformed-payload door")
    func aFailedSplitRollbackDoesNotRetireAsABadRequest() {
        // SYSTEM PROPERTY: a series that has been CAPPED on the server, with no
        // successor created and no rollback, must not be retired by the arm that
        // exists for "your payload is broken" — because that arm deletes the
        // durable row silently, and the user is left with a recurring series that
        // ends early, no queued work to fix it, and no way for sync to know.
        //
        // The pre-fix shape reported both rollback outcomes identically
        // (`_ = try? await updateEvent(… revertInput …)` then `throw error`), so
        // whether the master was still capped made no difference to the queue's
        // disposition at all. This composes the real classifier used by BOTH
        // providers with the drain's real terminal roster.
        //
        // 400 is chosen deliberately: it is exactly the code that makes the
        // difference visible. `isCalendarBadRequestError` claims a bare 400, so
        // pre-fix the whole half-landed split vanished through it.
        let original = ExchangeCalendarError.httpError(400, nil)

        // ROLLBACK SUCCEEDED — the master is back to its pre-split state, so the
        // pre-existing disposition is still correct and must NOT change. Pinning
        // this side is what stops the fix from over-reaching into "every split
        // failure is now inconsistentState".
        let recovered = GoogleCalendarProvider.splitRollbackError(original: original, revertFailure: nil)
        #expect(AccountManager.isCalendarBadRequestError(recovered),
                "a split whose rollback succeeded leaves nothing half-written; retiring the malformed 400 is right and this fix must not have changed it")

        // ROLLBACK FAILED — the server is in a state no retry of this op can
        // repair (a retry re-caps an already-capped master), and no silent
        // deletion may claim it.
        let stranded = GoogleCalendarProvider.splitRollbackError(
            original: original, revertFailure: URLError(.timedOut))
        #expect(AccountManager.isCalendarBadRequestError(stranded) == false,
                "the half-landed split was retired as a malformed request — the durable row is deleted and the truncated master is left on the server with nothing queued to repair it")
        #expect(claimedByATerminalArm(stranded),
                "it must still reach SOME terminal arm — falling into the transient arm would head-of-line-block every later calendar op on the account, which is the wedge this suite's other tests guard against")

        // The user has to fix this by hand, so both causes must survive into the
        // reason string the drain surfaces.
        guard case CalDAVError.inconsistentState(let reason) = stranded else {
            Issue.record("expected inconsistentState, got \(stranded)")
            return
        }
        #expect(reason.contains("400"), "the original create failure must survive into the reason: \(reason)")
        #expect(reason.lowercased().contains("timed out") || reason.contains("-1001"),
                "the rollback failure must survive into the reason too, or the user is told only half the story: \(reason)")
    }

    @Test("Non-4xx statuses and non-HTTP errors are never classified as malformed")
    func nonClientErrorsAreNeverRetired() {
        for code in [200, 302, 500, 502, 503] {
            for (label, error) in errors(code) {
                #expect(AccountManager.isCalendarBadRequestError(error) == false,
                        "\(label) HTTP \(code) is not a client error")
            }
        }
        #expect(AccountManager.isCalendarBadRequestError(
            CalDAVError.inconsistentState("rollback failed")) == false)
        #expect(AccountManager.isCalendarBadRequestError(
            URLError(.networkConnectionLost)) == false)
    }
}
