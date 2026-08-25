/* This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at https://mozilla.org/MPL/2.0/. */

import Testing
@testable import TabMail

/// Inbox error details are diagnostics, so they are visible only while the
/// runtime Debug Mode logging switch is enabled. These tests exercise the pure
/// presentation decision; `InboxView` retains the single production call site.
@Suite("Inbox error banner — visible only with Debug Mode logging")
struct InboxErrorBannerTests {

    private static let representativeErrors = [
        "Network error: The operation couldn't be completed. (TabMail.HTTPError error 1.)",
        "Failed to load older messages: connection reset",
        "Authentication failed"
    ]

    @Test("non-nil errors are hidden when logging is disabled")
    func nonNilErrorsAreHiddenWhenLoggingIsDisabled() {
        for error in Self.representativeErrors {
            #expect(InboxErrorBanner.text(for: error, loggingEnabled: false) == nil)
        }
    }

    @Test("Debug Mode shows each raw error exactly")
    func debugModeShowsEachRawErrorExactly() {
        for error in Self.representativeErrors {
            #expect(InboxErrorBanner.text(for: error, loggingEnabled: true) == error)
        }
    }

    @Test("nil error is hidden under either logging state")
    func nilErrorIsHiddenUnderEitherLoggingState() {
        #expect(InboxErrorBanner.text(for: nil, loggingEnabled: true) == nil)
        #expect(InboxErrorBanner.text(for: nil, loggingEnabled: false) == nil)
    }
}
