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
// ⚠️ **AND THE CENSUS THAT PRODUCED THE THREE BULLETS ABOVE WAS ITSELF THE WRONG
// SHAPE (R14-F4, 2026-08-06).** It enumerated calendar auth failure BY HTTP STATUS.
// A token that is never MINTED carries no status at all: both providers' `request`
// call `accessToken(false)` and, on a 401, `accessToken(true)` — **uncaught** — and
// that closure raises `ProviderError.authenticationFailed` and
// `OAuthError.tokenExchangeFailed`, which no arm claimed and no status-shaped
// census could see. See `reachableErrorRoster` below, which is derived from the
// CALL GRAPH instead (`MIS-007`).
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

    // MARK: - R14-F4 — the credential failures that carried no HTTP status at all

    /// 🚨 **THE CENSUS SHAPE, not the finding, is what this section fixes
    /// (`MIS-007`).** R12-T1 enumerated calendar OAuth failure **by HTTP status**,
    /// because statuses were what was on screen. A token that is never MINTED
    /// carries no status. `GoogleCalendarProvider.request` opens with
    /// `try await accessToken(false)` and its 401 branch calls `accessToken(true)`,
    /// **both uncaught**, and that closure — `AccountManager.makeOAuthAccessor` →
    /// `OAuthRefreshCoordinator.refresh` → `refreshGoogleToken` /
    /// `refreshMicrosoftToken` — raises `ProviderError.authenticationFailed` and
    /// `OAuthError.tokenExchangeFailed`, neither of which any status-shaped census
    /// could see. `ExchangeCalendarProvider.request` has the identical shape.
    ///
    /// So this roster is derived from *"every error type that can propagate out of
    /// `executeCalendarOperation`"*, walking the call graph, rather than from the
    /// three calendar provider error enums. `CalDAVError.noWritableCalendar` and
    /// `.discoveryFailed` are deliberately absent: `rg 'primaryCalendarId|listCalendars'
    /// AccountManagerCalendarQueue.swift` returns nothing, so neither is reachable
    /// from the drain.
    ///
    /// Each row states the disposition AND why, because a roster whose entries are
    /// only `true`/`false` cannot be reviewed — a wrong entry looks exactly like a
    /// right one.
    private func reachableErrorRoster() -> [(label: String, error: Error, terminal: Bool)] {
        [
            // — Google: the provider's own enum, all four cases —
            ("Google missing scope", GoogleCalendarError.missingScope, true),
            ("Google post-refresh 401 (grant revoked)", GoogleCalendarError.httpError(401, nil), true),
            ("Google 400 (malformed payload)", GoogleCalendarError.httpError(400, nil), true),
            ("Google 500 (server could not answer)", GoogleCalendarError.httpError(500, nil), false),
            ("Google event not found", GoogleCalendarError.eventNotFound, true),
            ("Google unencodable path segment", GoogleCalendarError.invalidPathSegment("Google event id"), true),
            // — Exchange: same enum shape, asserted separately so a fix to one
            //   provider cannot be read as covering its sibling (`MIS-007`) —
            ("Exchange missing scope", ExchangeCalendarError.missingScope, true),
            ("Exchange post-refresh 401 (grant revoked)", ExchangeCalendarError.httpError(401, nil), true),
            ("Exchange 400 (malformed payload)", ExchangeCalendarError.httpError(400, nil), true),
            ("Exchange 503 (server could not answer)", ExchangeCalendarError.httpError(503, nil), false),
            ("Exchange event not found", ExchangeCalendarError.eventNotFound, true),
            ("Exchange unencodable path segment", ExchangeCalendarError.invalidPathSegment("Graph event id"), true),
            // — CalDAV —
            ("CalDAV credentials rejected", CalDAVError.authFailed, true),
            ("CalDAV not found", CalDAVError.notFound, true),
            ("CalDAV opaque 403 policy refusal", CalDAVError.httpError(403, nil), true),
            ("CalDAV 503 (server could not answer)", CalDAVError.httpError(503, nil), false),
            // 412 on an update means our ETag was stale — re-read and retry is
            // exactly the remedy, so terminalizing it would discard a live edit.
            ("CalDAV stale-ETag precondition", CalDAVError.preconditionFailed, false),
            ("CalDAV unreadable response body", CalDAVError.parseError("Empty response for event evt-1"), false),
            ("CalDAV half-landed split, rollback failed", CalDAVError.inconsistentState("capped, no successor"), true),
            // — Demo: a registered `CalendarProvider` like any other (R15-FIX-4).
            //   `DemoModeService` calls `AccountManager.registerDemoProviders`, which
            //   puts `DemoCalendarProvider` into `calendarProviders`, so this drain
            //   executes its errors. The roster omitted the whole provider, and that
            //   omission is why the classifier gap survived — the derivation rule
            //   above says "every error type that can propagate out of
            //   `executeCalendarOperation`", and it walked the three PROVIDER ENUMS
            //   instead of the providers (`MIS-007`, a census inheriting its search
            //   shape) —
            ("Demo event not found (stale edit)", DemoError.eventNotFound, true),
            ("Demo database not up", DemoError.notInDemo, false),
            // — Cross-provider —
            ("provider cannot perform this edit scope", CalendarProviderError.notSupported("this_and_following"), true),
            // — THE R14-F4 CLASS: raised before any request is issued —
            ("OAuth grant revoked (invalid_grant)", OAuthError.tokenExchangeFailed("invalid_grant"), true),
            ("OAuth client rejected (invalid_client)", OAuthError.tokenExchangeFailed("invalid_client"), true),
            ("OAuth client unauthorized", OAuthError.tokenExchangeFailed("unauthorized_client"), true),
            ("OAuth endpoint temporarily unavailable", OAuthError.tokenExchangeFailed("temporarily_unavailable"), false),
            ("OAuth endpoint 5xx", OAuthError.tokenExchangeFailed("server_error"), false),
            ("OAuth body carried no error code at all", OAuthError.tokenExchangeFailed("unknown"), false),
            ("OAuth wrong scope requested — our bug, not a dead grant", OAuthError.tokenExchangeFailed("invalid_scope"), false),
            ("credential could not be read", ProviderError.authenticationFailed, false),
            // — Transport / storage, on the same path —
            ("connection lost", URLError(.networkConnectionLost), false),
            ("keychain write failed", KeychainError.saveFailed(-25300), false),
        ]
    }

    @Test("Every error type reachable from executeCalendarOperation has an adjudicated disposition")
    func everyReachableErrorTypeIsAdjudicated() {
        let roster = reachableErrorRoster()
        // MIS-030: anchor the roster's own cardinality, so a future edit that
        // silently empties or truncates it cannot make every assertion below
        // pass over nothing.
        #expect(roster.count == 32, "the roster lost or gained entries — re-derive it from the call graph")
        for (label, error, terminal) in roster {
            #expect(
                claimedByATerminalArm(error) == terminal,
                terminal
                    ? "\(label): claimed by NO terminal arm, so the drain requeues it AND inserts the account into failedAccounts — every later calendar op on that account is skipped, on this drain and every subsequent one. A wedge sits in the same non-recoverable set as a dropped intention."
                    : "\(label): a terminal arm claims it, so the durable PendingCalendarOperation row is DELETED. This error is indeterminate or transient — retiring on it drops the user's intention on 'we could not determine the answer' (never-drop clause 2).")
        }
    }

    @Test("A revoked OAuth grant reaches a terminal arm instead of wedging the account's calendar lane")
    func revokedGrantIsTerminal() {
        // The exact values `refreshGoogleToken` / `refreshMicrosoftToken` raise:
        //     throw OAuthError.tokenExchangeFailed(response.error ?? "unknown")
        // where the payload is the token endpoint's own machine-readable code.
        // These three say the GRANT is dead, so every future drain reproduces the
        // failure identically and no retry can ever clear it.
        for code in ["invalid_grant", "invalid_client", "unauthorized_client"] {
            #expect(claimedByATerminalArm(OAuthError.tokenExchangeFailed(code)),
                    "\(code) is claimed by NO terminal arm — the op is requeued forever at the head of a createdAt-ASC queue and head-of-line-blocks the account's whole calendar lane")
        }
        #expect(claimedByATerminalArm(OAuthError.tokenExchangeFailed(" INVALID_GRANT ")),
                "case and surrounding whitespace come off the wire; failing to match on either is a wedge, so the classifier normalises before comparing")
    }

    @Test("A token endpoint that merely could not answer stays retryable")
    func indeterminateTokenFailuresAreStillRetryable() {
        // ⚠️ THE MIRROR IMAGE, pinned so it cannot be traded in. Blanket-
        // terminalizing `tokenExchangeFailed` is the obvious "fix" and it is wrong:
        // both endpoints raise the SAME case for reasons a retry resolves, and
        // `"unknown"` is the fallback for a response body with no `error` key at
        // all — the purest form of "we could not determine the answer".
        for code in ["temporarily_unavailable", "server_error", "unknown", "invalid_scope", ""] {
            #expect(claimedByATerminalArm(OAuthError.tokenExchangeFailed(code)) == false,
                    "'\(code)' is indeterminate or is our own request bug — retiring the op on it deletes the user's queued calendar operation for a condition that clears itself")
        }
    }

    // MARK: - R15-FIX-4 — the demo provider's stale edit

    /// 🚨 THE INVARIANT THIS PINS — the system property, not the mechanism
    /// (`MIS-015`): **a provider-authoritative "this event does not exist" retires
    /// the operation instead of wedging the lane.**
    ///
    /// The reachable sequence: an edit tool reads a Demo event and awaits user
    /// confirmation, another chat deletes it, the user confirms. `updateEvent`'s
    /// UPDATE matches zero rows and its confirming `getEvent` finds none — and for an
    /// edit carrying attendee deltas, `resolveAttendeeDelta` reaches `getEvent`
    /// before any update is attempted. Until R15-FIX-4 that was
    /// `DemoError.startFailed("event not found")`, claimed by NO terminal arm, so it
    /// fell to the transient arm: requeue, `retryCount += 1` (this file has no retry
    /// cap — one increment, zero comparisons) and `failedAccounts.insert`. The next
    /// drain's `if failedAccounts.contains(currentOp.accountId) { continue }` then
    /// skipped every later calendar op on that account, forever, with the wedged op
    /// reached first every time because ops are ordered `createdAt ASC`.
    ///
    /// `DemoCalendarProvider` reaches this drain like any other provider:
    /// `DemoModeService` → `AccountManager.registerDemoProviders` →
    /// `calendarProviders[accountId] = calendar`.
    @Test("A stale demo calendar edit is retired instead of wedging the account's calendar lane")
    func staleDemoEditIsTerminal() {
        #expect(AccountManager.isCalendarNotFoundError(DemoError.eventNotFound),
                "the demo store positively reported no such row — that is the same provider-authoritative fact Google's 404 and CalDAV's notFound carry")
        #expect(claimedByATerminalArm(DemoError.eventNotFound),
                "claimed by NO terminal arm, the op is requeued forever at the head of a createdAt-ASC queue and head-of-line-blocks the account's whole calendar lane — a wedge sits in the same non-recoverable set as a dropped intention")
    }

    /// END-TO-END, because the two assertions above are about the CLASSIFIER and a
    /// classifier test alone would stay green if the provider went on raising the
    /// unclassifiable spelling (`MIS-015`). This drives the REAL
    /// `DemoCalendarProvider` against the real database and asserts the value it
    /// actually throws is the one a terminal arm claims — the loop the wedge lived
    /// in. Read-only: it addresses an id no row can carry, so it needs no fixture
    /// and leaves nothing behind.
    @Test("The demo provider raises the classifiable signal for an event that is gone")
    func demoProviderRaisesTheClassifiableSignal() async {
        let provider = DemoCalendarProvider(accountId: DemoSeed.demoAccountId)
        do {
            _ = try await provider.getEvent(
                calendarId: "primary", eventId: "r15fix4-absent-\(UUID().uuidString)")
            Issue.record("reading an event that does not exist must throw")
        } catch {
            #expect(claimedByATerminalArm(error),
                    "the value the provider actually throws must reach a terminal arm — a classifier that claims a case nothing raises leaves the lane wedged exactly as before: \(error)")
            #expect(AccountManager.isCalendarNotFoundError(error),
                    "and it must be claimed as the provider-authoritative not-found, not by some unrelated terminal arm: \(error)")
        }
    }

    /// TWO-SIDED ANCHOR — the over-correction, pinned so it cannot be traded in
    /// (`MIS-026`). Blanket-terminalizing `DemoError` is the obvious "fix" and it is
    /// wrong: `.startFailed` also carries indeterminate demo INITIALIZATION failures
    /// (`DemoModeService.start` raises it twice), and `.notInDemo` means
    /// `AppDatabase.shared` was nil — the database was not up. Both are *"we could
    /// not determine the answer"*, which never-drop clause 2 keeps retryable forever.
    /// Retiring either deletes the user's queued calendar operation for a condition
    /// that clears itself.
    ///
    /// `.startFailed` is deliberately NOT in `reachableErrorRoster()`: giving the
    /// authoritative fact its own spelling is exactly what removed `.startFailed`
    /// from `DemoCalendarProvider`, so it is no longer reachable from
    /// `executeCalendarOperation` and the roster's stated derivation excludes it.
    /// It is anchored here instead, because "unreachable today" is a property of
    /// today's callers rather than an invariant.
    @Test("An indeterminate demo failure stays retryable")
    func indeterminateDemoFailuresAreStillRetryable() {
        for (label, error) in [
            ("demo could not start", DemoError.startFailed("Demo not available right now.")),
            ("demo record read failed for an unstated reason", DemoError.startFailed("event not found")),
            ("database not up", DemoError.notInDemo),
        ] {
            #expect(claimedByATerminalArm(error) == false,
                    "\(label): a terminal arm claims it, so the durable PendingCalendarOperation row is DELETED for a demo failure that says nothing about whether the event exists")
            #expect(AccountManager.isCalendarNotFoundError(error) == false,
                    "\(label): must not be read as the provider saying the event is gone")
        }
    }

    @Test("The re-auth signal is raised for a strictly larger set than the terminal arm claims")
    func reauthSignalCoversWhatTheTerminalArmDoesNot() {
        // 🚨 THE SIGNAL AND THE DISPOSITION ARE DIFFERENT QUESTIONS. Before R14-F4
        // this file's drain never touched `authFailedAccounts` at all
        // (`rg -c authFailedAccounts AccountManagerCalendarQueue.swift` → 0), so an
        // OAuth calendar account whose grant was revoked produced no persistent
        // user-visible prompt — only CalDAV accounts did, via `caldavConfig.needsReauth`.
        for (label, error) in [
            ("Google post-refresh 401", GoogleCalendarError.httpError(401, nil) as Error),
            ("Exchange post-refresh 401", ExchangeCalendarError.httpError(401, nil)),
            ("revoked grant", OAuthError.tokenExchangeFailed("invalid_grant")),
            ("credential could not be read", ProviderError.authenticationFailed),
        ] {
            #expect(AccountManager.isCalendarOAuthReauthRequired(error),
                    "\(label): the user is never told to sign in again, so nothing they can do clears the failure — that is what turns a fail-closed stop into an unrecoverable wedge")
        }

        // 🚨 THE ASYMMETRY THIS FIX RESTS ON. `ProviderError.authenticationFailed`
        // is SIGNALLED but NOT terminal. `OAuthRefreshCoordinator.refresh` raises it
        // from `guard let refreshToken = KeychainHelper.loadString(…)`, and
        // `KeychainHelper.load` returns nil for ANY SecItemCopyMatching failure —
        // an absence of evidence, not a provider refusal. Terminalizing it would
        // trade a wedge that one ordinary user gesture clears (re-authenticate,
        // prompted by the signal asserted above) for a permanently dropped
        // intention, which nothing recovers.
        #expect(claimedByATerminalArm(ProviderError.authenticationFailed) == false,
                "a credential we could not READ is not a credential the provider REFUSED; deleting the op on it drops the user's intention on 'we could not determine'")

        // And the signal is not a catch-all: an ordinary malformed payload or a
        // dropped connection must not tell the user their sign-in is broken.
        for (label, error) in [
            ("malformed payload", GoogleCalendarError.httpError(400, nil) as Error),
            ("missing scope", ExchangeCalendarError.missingScope),
            ("connection lost", URLError(.networkConnectionLost)),
            ("indeterminate token endpoint", OAuthError.tokenExchangeFailed("temporarily_unavailable")),
            ("CalDAV — has its own needsReauth column", CalDAVError.authFailed),
        ] {
            #expect(AccountManager.isCalendarOAuthReauthRequired(error) == false,
                    "\(label) must not raise the OAuth re-auth prompt")
        }
    }

    @Test("The terminal auth reason names the failure that actually happened")
    func authFailureReasonMatchesTheCause() {
        // `MIS-031` — the string is surfaced verbatim to the agent and through it to
        // the user, and the pre-fix two-way ternary asserted "refused again after a
        // token refresh" for a token that was never minted at all.
        #expect(AccountManager.calendarAuthFailureReason(CalDAVError.authFailed).hasPrefix("CalDAV"))
        let revoked = AccountManager.calendarAuthFailureReason(
            OAuthError.tokenExchangeFailed("invalid_grant"))
        #expect(revoked.contains("invalid_grant"),
                "the provider's own reason must survive into the message: \(revoked)")
        #expect(revoked.contains("after a token refresh") == false,
                "a token that was never minted was not 'refused again after a token refresh': \(revoked)")
        #expect(AccountManager.calendarAuthFailureReason(
            GoogleCalendarError.httpError(401, nil)).contains("after a token refresh"),
                "the post-refresh 401 message must keep describing what it is")
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
