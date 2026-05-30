/* This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at https://mozilla.org/MPL/2.0/. */

import Foundation
import GRDB

struct CalDAVConfig: Codable, FetchableRecord, PersistableRecord, Identifiable, Sendable {
    static let databaseTableName = "caldavConfig"

    var id: String
    var accountId: String
    var serverURL: String
    var principalURL: String?
    var calendarHomeURL: String?
    var username: String
    var displayName: String?
    var needsReauth: Bool
    var createdAt: Date

    init(
        accountId: String,
        serverURL: String,
        username: String,
        displayName: String? = nil
    ) {
        self.id = UUID().uuidString
        self.accountId = accountId
        self.serverURL = serverURL
        self.username = username
        self.displayName = displayName
        self.needsReauth = false
        self.createdAt = Date()
    }
}
