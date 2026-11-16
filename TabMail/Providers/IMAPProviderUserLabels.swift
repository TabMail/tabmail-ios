/* This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at https://mozilla.org/MPL/2.0/. */

import Foundation
import GRDB

/// IMAP's (and iCloud's) user-label rules (#500; `ProviderUserLabel`). An IMAP
/// user label is a custom keyword on the message: it needs no server call to
/// exist, and RFC 3501 keywords are case-INsensitive, so the lowercased keyword
/// IS the label id (`buildMessageHeaderInfo` lowercases what it reads the same
/// way). There is no label catalog in the folder list.
extension IMAPProvider {

    /// The lowercased keyword, minted locally; needs no connected provider.
    static func userLabel(named name: String, connected: (any EmailProvider)?) async throws -> ProviderUserLabel {
        // IMAP: keyword name (lowercased) IS the ID — no server call needed
        ProviderUserLabel(providerLabelId: name.lowercased(), name: name, isSystem: false)
    }

    /// No catalog: keywords are not folders.
    static func userLabelCatalog(from folders: [FolderInfo]) -> [ProviderUserLabel]? {
        nil
    }

    /// Plain custom-keyword names. Strip `tm_*` and every exclusion
    /// `UserLabelStore.isExcludedKeyword` knows about.
    static func storedUserLabelIds(fromPushed rawLabels: [String], accountId: String, db: Database) throws -> [String] {
        // IMAP: strip system flags + tm_* + any other excluded keyword.
        rawLabels.filter { !UserLabelStore.isExcludedKeyword($0) }
            .map { $0.lowercased() }  // Matches IMAPProvider's lowercase normalization.
    }
}
