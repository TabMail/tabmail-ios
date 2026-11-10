/* This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at https://mozilla.org/MPL/2.0/. */

import Foundation

/// The value type an ICS property line states with its `VALUE` parameter
/// (RFC 5545 §3.2.20).
enum ICSValueType {

    /// True when `head` states `VALUE=DATE`. `head` is the text before the
    /// value's `:`, with or without the property name (`DTSTART;VALUE=DATE`
    /// or `VALUE=DATE;X-A=B`).
    ///
    /// The parameter is matched whole and without regard to case.
    /// `VALUE=DATE-TIME`, which a client may state although it is the default
    /// for DTSTART and DTEND, is a timed value. A substring test reads it as
    /// a date. A value with no `VALUE` parameter is not covered here; callers
    /// keep their own check of the value's form.
    static func statesDate(_ head: some StringProtocol) -> Bool {
        head.split(separator: ";").contains { parameter in
            parameter.trimmingCharacters(in: .whitespaces).uppercased() == "VALUE=DATE"
        }
    }
}
