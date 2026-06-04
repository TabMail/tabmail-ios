/* This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at https://mozilla.org/MPL/2.0/. */

import GRDB

extension Folder {
    /// SQL predicate that scopes a folder query to the demo account (when demo is
    /// active) or to real accounts (when not).
    ///
    /// Filters on the existing `accountId` column — deliberately NOT a new `isDemo`
    /// flag/column, which would add an index/storage cost for a transient state.
    /// The `folder` table is tiny (≈5–50 rows), so this extra condition is a
    /// negligible scan, and any downstream message fetch still rides the existing
    /// `messageHeader.folderId` index (we resolve folder ids first, then query
    /// messages by `folderId`). Composable with other conditions, e.g.
    /// `Folder.filter(Column("role") == role.rawValue && Folder.demoScope(demoActive:))`.
    static func demoScope(demoActive: Bool) -> SQLExpression {
        demoActive
            ? Column("accountId") == DemoSeed.demoAccountId
            : Column("accountId") != DemoSeed.demoAccountId
    }

    /// The sidebar folder query, mirroring `Account.sidebarRequest`.
    ///
    /// Demo folders only while demo is active; real folders (excluding demo)
    /// otherwise. Account filtering alone isn't enough because the sidebar
    /// iterates folders independently of accounts in a couple of places —
    /// favorite folders and the unified-mailbox unread counts (`MailNavigationView`
    /// `favoriteFolders` / per-role aggregates). Without this filter those would
    /// surface the live user's folders inside the demo UI.
    static func sidebarRequest(demoActive: Bool) -> QueryInterfaceRequest<Folder> {
        Folder.filter(demoScope(demoActive: demoActive)).order(Column("name"))
    }
}
