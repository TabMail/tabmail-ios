/* This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at https://mozilla.org/MPL/2.0/. */

import Foundation
import GRDB

/// The people the user recently sent email to, for a new email's "Add recipient" sheet
/// (ADR-IOS-114 decision 24). Read from mail already on the device each time the sheet opens: the
/// To and Cc of the newest emails in every account's Sent folder. Nothing is stored.
enum ChatRecentPeople {
    /// From sent emails, newest first: each To then Cc person once, in the order they first
    /// appear, never the user, at most `limit`. A person's name is the newest one an email gives
    /// them, else the part of the address before the @.
    static func people(
        sentNewestFirst headers: [MessageHeader], ownAddresses: Set<String>, limit: Int
    ) -> [ChatThread.Person] {
        // Oldest first, so the newest email's name for someone is the one kept.
        let names = ChatThread.names(in: Array(headers.reversed()))
        var seen = Set<String>()
        var people: [ChatThread.Person] = []
        for header in headers {
            for recipient in ChatThread.recipients(of: header)
            where !ownAddresses.contains(recipient.address) && seen.insert(recipient.address).inserted {
                guard people.count < limit else { return people }
                people.append(ChatThread.Person(
                    address: recipient.address,
                    name: names[recipient.address] ?? ChatThread.fallbackName(recipient.address)))
            }
        }
        return people
    }

    /// The recent people from the newest `scanCount` emails of every Sent folder. A read that
    /// fails gives nobody: the sheet then shows no Recent section.
    static func load(
        pool: PrioritizedDatabase,
        ownAddresses: Set<String>,
        limit: Int = ChatViewConfig.recentPeopleCount,
        scanCount: Int = ChatViewConfig.recentPeopleScanCount
    ) async -> [ChatThread.Person] {
        do {
            let sent = try await pool.read { db in
                let sentFolderIds = try Folder
                    .filter(Column("role") == FolderRole.sent.rawValue)
                    .fetchAll(db)
                    .map(\.id)
                return try MessageHeader
                    .filter(sentFolderIds.contains(Column("folderId")))
                    .order(Column("date").desc, Column("id").desc)
                    .limit(scanCount)
                    .fetchAll(db)
            }
            return people(sentNewestFirst: sent, ownAddresses: ownAddresses, limit: limit)
        } catch {
            if DebugModeManager.isLoggingEnabled() {
                BackgroundSyncLogger.logDebug("[ChatNewEmail] recent people read failed: \(error)")
            }
            return []
        }
    }
}
