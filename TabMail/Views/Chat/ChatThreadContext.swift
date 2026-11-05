/* This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at https://mozilla.org/MPL/2.0/. */

import Foundation
import GRDB

/// What a bubble shows beyond its header: attachment chips (N2.5) and an invite card (E3).
struct ChatMemberExtras {
    let attachmentNames: [String]
    let invite: ChatInvite?
}

/// An invite read from the email's calendar file, not from AI (E3.1).
struct ChatInvite {
    let parsed: ICSBuilder.ParsedInvite
    let icsText: String

    /// The calendar file holds an event the user can add: a request with a start time. Replies,
    /// refreshes and counters are refused, as by today's attachment tap.
    static func from(icsText: String) -> ChatInvite? {
        guard let parsed = ICSBuilder.parseIncoming(icsText), parsed.startDate != nil,
              ICSCalendarImporter.allowsAddToCalendar(Data(icsText.utf8)),
              parsed.method.uppercased() != "CANCEL" else { return nil }
        return ChatInvite(parsed: parsed, icsText: icsText)
    }
}

/// The database facts the chat needs besides its headers, read off the main thread.
struct ChatThreadContext {
    var accounts: [Account] = []
    var draftFolderIds: Set<String> = []
    var sentFolderIds: Set<String> = []
    /// The thread's user labels, as the collapsed inbox row shows them (N2.L).
    var labels: [UserLabel] = []
    var extras: [String: ChatMemberExtras] = [:]
    var isLoaded = false

    var ownAddresses: Set<String> { Set(accounts.map { $0.emailAddress.lowercased() }) }

    static func load(members: [MessageHeader], pool: PrioritizedDatabase) async -> ChatThreadContext {
        let ids = members.map(\.id)
        let accountIds = Set(members.map(\.accountId))
        do {
            return try await pool.read { db in
                var context = ChatThreadContext()
                context.accounts = try Account.fetchAll(db)
                let folders = try Folder
                    .filter(accountIds.contains(Column("accountId")))
                    .filter([FolderRole.drafts.rawValue, FolderRole.sent.rawValue].contains(Column("role")))
                    .fetchAll(db)
                context.draftFolderIds = Set(folders.filter { $0.role == .drafts }.map(\.id))
                context.sentFolderIds = Set(folders.filter { $0.role == .sent }.map(\.id))
                let labelsById = try UserLabelStore.loadLabels(for: ids, in: db)
                context.labels = UserLabel.union(ids.map { labelsById[$0] ?? [] })
                for body in try MessageBody.fetchAll(db, keys: ids) {
                    let invite = body.icsText.flatMap(ChatInvite.from(icsText:))
                    let names = body.attachments
                        .filter { $0.parentEmlSection == nil }
                        // The invite card stands for its calendar file.
                        .filter { invite == nil || !$0.contentType.lowercased().contains("text/calendar") }
                        .map(\.filename)
                    context.extras[body.id.rawValue] = ChatMemberExtras(attachmentNames: names, invite: invite)
                }
                context.isLoaded = true
                return context
            }
        } catch {
            if DebugModeManager.isLoggingEnabled() {
                BackgroundSyncLogger.logDebug("[ChatView] context load failed: \(error)")
            }
            // Shown without extras; the next member change reads again.
            var context = ChatThreadContext()
            context.isLoaded = true
            return context
        }
    }
}

/// The time stamp between bubbles: "Today 17:49", "Yesterday 09:02", "Mon 09:12" within the
/// week, else "Mar 19, 09:12" (mock N2).
enum ChatTimeStamp {
    static func text(for date: Date, now: Date = Date(), calendar: Calendar = .current) -> String {
        let time = date.formatted(date: .omitted, time: .shortened)
        if calendar.isDate(date, inSameDayAs: now) { return "Today \(time)" }
        if let yesterday = calendar.date(byAdding: .day, value: -1, to: now),
           calendar.isDate(date, inSameDayAs: yesterday) { return "Yesterday \(time)" }
        let formatter = DateFormatter()
        formatter.calendar = calendar
        formatter.timeZone = calendar.timeZone
        if let weekAgo = calendar.date(byAdding: .day, value: -6, to: calendar.startOfDay(for: now)),
           date >= weekAgo, date < now {
            formatter.dateFormat = "EEE"
            return "\(formatter.string(from: date)) \(time)"
        }
        formatter.dateFormat = calendar.isDate(date, equalTo: now, toGranularity: .year) ? "MMM d" : "MMM d, yyyy"
        return "\(formatter.string(from: date)), \(time)"
    }
}
