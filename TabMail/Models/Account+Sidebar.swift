/* This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at https://mozilla.org/MPL/2.0/. */

import GRDB

extension Account {
    /// The sidebar / inbox account query.
    ///
    /// While demo mode is active the sidebar shows ONLY the seeded demo account;
    /// otherwise it shows real (active, non-calendar) accounts and ALWAYS excludes
    /// the demo account. This is what lets demo mode coexist with a logged-in user
    /// (e.g. entered from the debug menu) without exposing the user's real inboxes,
    /// and it cleanly hides any orphaned demo row when demo is inactive.
    ///
    /// It is a no-op for real users: when demo is inactive there is normally no
    /// `demo-account` row at all, so the only effective change is the exclusion
    /// filter (which matches nothing).
    static func sidebarRequest(demoActive: Bool) -> QueryInterfaceRequest<Account> {
        if demoActive {
            return Account
                .filter(Column("id") == DemoSeed.demoAccountId)
                .order(Column("createdAt"))
        }
        return Account
            .filter(Column("isActive") == true
                && Column("calendarOnly") == false
                && Column("id") != DemoSeed.demoAccountId)
            .order(Column("createdAt"))
    }
}
