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
// arms (`isCalendarAuthError`, `isCalendarMissingScopeError`,
// `isCalendarNotFoundError`) already claim them; CalDAV's 403 is deliberately
// retired HERE, because iCloud returns an opaque 403 for permanent policy
// refusals (attendee-without-organizer, shared-calendar writes) that no retry
// fixes. That asymmetry is pinned below so a future "tidy-up" cannot collapse it.

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
