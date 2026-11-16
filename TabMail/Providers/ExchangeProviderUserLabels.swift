/* This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at https://mozilla.org/MPL/2.0/. */

import Foundation
import GRDB

/// Outlook's user-label rules (#500; `ProviderUserLabel`). An Outlook user label
/// is a Graph message `category`, and the category's DISPLAY NAME is the id.
/// There is no label catalog in the folder list.
extension ExchangeProvider {

    /// Mints locally like IMAP rather than blocking on a catalog round-trip like
    /// Gmail, because Graph has no catalog to call: PATCHing a category name onto
    /// a message is what makes it exist there (`ExchangeProvider.setUserLabel`).
    /// Needs no connected provider.
    ///
    /// 🚨 VERBATIM — deliberately NOT `.lowercased()`, the one place this
    /// diverges from IMAP's rule it otherwise copies. IMAP lowercases because
    /// RFC 3501 keywords are case-INsensitive; Graph category names are
    /// case-SENSITIVE display strings that must round-trip byte-identically. The
    /// read path (`ExchangeProvider.parseGraphMessage`) maps the server's
    /// `categories` strings verbatim into `userLabelIds`, and the sync arms mint
    /// a `UserLabel` from each, so lowercasing here would make the user's
    /// `Receipts` and the server's echoed `Receipts` derive two different
    /// `UserLabel.id`s — one category, two menu rows.
    ///
    /// `tm_*` never reaches here: `UserLabelStore.isReservedName` refuses that
    /// prefix at the menu's only caller, which is deliberate — the server would
    /// accept such a category and `ExchangeProvider.stripLegacyCategories` would
    /// later silently delete it.
    static func userLabel(named name: String, connected: (any EmailProvider)?) async throws -> ProviderUserLabel {
        ProviderUserLabel(providerLabelId: name, name: name, isSystem: false)
    }

    /// No catalog: categories are not folders.
    static func userLabelCatalog(from folders: [FolderInfo]) -> [ProviderUserLabel]? {
        nil
    }

    /// Keep every category except the reserved `tm_*` namespace, through the
    /// SAME predicate `ExchangeProvider.parseGraphMessage` filters with and
    /// `stripLegacyCategories` DELETES with (ADR-IOS-036: action tags are
    /// local-only). Names are kept VERBATIM, unlike IMAP's lowercasing.
    static func storedUserLabelIds(fromPushed rawLabels: [String], accountId: String, db: Database) throws -> [String] {
        // Parity with `ExchangeProvider.parseGraphMessage`, which maps
        // `categories` straight into `userLabelIds` through this same
        // predicate (`e265428ff`). Before that commit both sides returned
        // `[]` and this arm was correct; afterwards it was the only path
        // still dropping them, so an NSE-delivered Outlook message carried
        // no label rows until the next main-app sync.
        //
        // ONE predicate, not a second copy: `isLegacyActionTagCategory` is
        // also what `stripLegacyCategories` uses to DELETE `tm_*`
        // categories from the server, so a category that path erases can
        // never be surfaced here as a label the user owns.
        //
        // 🚨 VERBATIM — do NOT lowercase. IMAP lowercases
        // because RFC 3501 keywords are case-INsensitive; Graph category
        // names are case-SENSITIVE display strings, and the main-app read
        // and write paths both keep them unchanged. Lowercasing here would
        // mint a second `UserLabel.id` for one category.
        rawLabels.filter { !isLegacyActionTagCategory($0) }
    }
}
