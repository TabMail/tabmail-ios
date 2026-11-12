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
}
