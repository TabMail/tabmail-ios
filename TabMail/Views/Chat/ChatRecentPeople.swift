/* This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at https://mozilla.org/MPL/2.0/. */

import Foundation
import GRDB

/// The people the user recently sent email to, for a new email's "Add recipient" sheet
/// (ADR-IOS-114 decision 24). Read from mail already on the device each time the sheet opens: the
/// To, Cc and Bcc of the newest emails in every account's Sent folder. Nothing is stored.
enum ChatRecentPeople {
    /// From sent emails, newest first: each To, Cc then Bcc person once, in the order they first
    /// appear, never the user, at most `limit`. A person's name is the newest one a sent email's
    /// recipient fields give them, else the part of the address before the @. A sent email's From
    /// is the user, so it names nobody here.
    static func people(
        sentNewestFirst headers: [MessageHeader], ownAddresses: Set<String>, limit: Int
    ) -> [ChatThread.Person] {
        var names: [String: String] = [:]
        var seen = Set<String>()
        var order: [String] = []
        for header in headers {
            for recipient in [header.to, header.cc, header.bcc].flatMap({ RecipientEntry($0).recipients }) {
                let address = recipient.address.lowercased()
                // Newest email first, so the first name found is the newest.
                if names[address] == nil, let name = recipient.name, !name.isEmpty { names[address] = name }
                if !ownAddresses.contains(address), seen.insert(address).inserted { order.append(address) }
            }
        }
        return order.prefix(limit).map { ChatThread.Person(address: $0, name: names[$0] ?? ChatThread.fallbackName($0)) }
    }

    /// The recent people from the newest `scanCount` emails of the Sent folders: the demo
    /// account's while demo is on, else every real account's (`demoActive`, read once by the
    /// caller as the sheet opens). A read that fails gives nobody: the sheet then shows no Recent
    /// section.
    static func load(
        pool: PrioritizedDatabase,
        ownAddresses: Set<String>,
        demoActive: Bool,
        limit: Int = ChatViewConfig.recentPeopleCount,
        scanCount: Int = ChatViewConfig.recentPeopleScanCount
    ) async -> [ChatThread.Person] {
        do {
            let sent = try await pool.read { db in
                let sentFolderIds = try Folder
                    .filter(Column("role") == FolderRole.sent.rawValue && Folder.demoScope(demoActive: demoActive))
                    .fetchAll(db)
                    .map(\.id)
                // The reader takes no folders as every folder, so no Sent folder reads nothing.
                guard !sentFolderIds.isEmpty else { return [MessageHeader]() }
                // Each Sent folder's newest on its own (folderId, date) index, then the newest of
                // those: no read sorts a whole Sent history.
                return try SearchView.recentHeaders(db, folderIds: sentFolderIds, budget: scanCount)
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
