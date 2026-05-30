/* This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at https://mozilla.org/MPL/2.0/. */

import SwiftMail

extension ExtendedSearchResult {
    /// Matched identifiers as a set, regardless of which result field the server populated.
    /// `extendedSearch` returns `.all` when ESEARCH is supported and `.ordered` when it falls
    /// back to plain SEARCH; both forms represent the same UID set for non-PARTIAL queries.
    var asSet: MessageIdentifierSet<T> {
        all ?? MessageIdentifierSet(ordered ?? [])
    }
}
