/* This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at https://mozilla.org/MPL/2.0/. */

import Foundation

enum CalDAVError: Error {
    case authFailed
    case httpError(Int, Data?)
    case notFound
    case preconditionFailed
    case discoveryFailed(String)
    case parseError(String)
    case noWritableCalendar
    /// A multi-step write (e.g. a `this_and_following` series split) failed
    /// partway AND the best-effort revert of the already-applied step also
    /// failed — the calendar resource is left in an inconsistent state that
    /// needs manual attention. The associated string is a human-readable
    /// description for the user/LLM.
    case inconsistentState(String)
}
