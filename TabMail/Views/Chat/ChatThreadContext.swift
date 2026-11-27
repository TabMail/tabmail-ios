/* This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at https://mozilla.org/MPL/2.0/. */

import Foundation
import GRDB

/// What a bubble shows beyond its header: attachment chips and an invite card.
struct ChatMemberExtras {
    let attachmentNames: [String]
    let invite: ChatInvite?
}

/// An invite read from the email's calendar file, not from AI.
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
    /// The thread's user labels, as the collapsed inbox row shows them.
    var labels: [UserLabel] = []
    var extras: [String: ChatMemberExtras] = [:]
    var isLoaded = false

    var ownAddresses: Set<String> { Set(accounts.map { $0.emailAddress.lowercased() }) }

    /// The name of each of the user's addresses whose account has one (`Account.displayName`), for
    /// a chat whose people are the user's own addresses (`ChatThread.replyPeople`).
    var ownNames: [String: String] {
        var names: [String: String] = [:]
        for account in accounts where !account.displayName.trimmingCharacters(in: .whitespaces).isEmpty {
            let address = account.emailAddress.lowercased()
            if names[address] == nil { names[address] = account.displayName }
        }
        return names
    }

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
                // Every member's attachment list and calendar file, never its HTML: the thread is
                // uncapped, so the stored bodies are not read here (the bubbles show text messages).
                let rows = try Row.fetchAll(db, MessageBody
                    .select(Column("id"), Column("attachmentsJSON"), Column("icsText"))
                    .filter(keys: ids))
                for row in rows {
                    var body = MessageBody(contentKey: ContentKey(rawValue: row["id"]), htmlContent: nil)
                    body.attachmentsJSON = row["attachmentsJSON"]
                    body.icsText = row["icsText"]
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
/// week, else "Mar 19, 09:12". Every date text is in the Gregorian calendar whatever
/// calendar the phone is set to, built by `FixedDateFormat` as the inbox row's
/// (`formattedForInbox`); the time keeps the phone's 12/24-hour setting. `calendar` (the phone's)
/// decides only the day boundaries, which fall at the same instants in every calendar.
enum ChatTimeStamp {
    static func text(for date: Date, now: Date = Date(), calendar: Calendar = .current) -> String {
        let zone = calendar.timeZone
        let time = FixedDateFormat.localized(dateStyle: .none, timeStyle: .short, timeZone: zone).string(from: date)
        if calendar.isDate(date, inSameDayAs: now) { return "Today \(time)" }
        if let yesterday = calendar.date(byAdding: .day, value: -1, to: now),
           calendar.isDate(date, inSameDayAs: yesterday) { return "Yesterday \(time)" }
        if let weekAgo = calendar.date(byAdding: .day, value: -6, to: calendar.startOfDay(for: now)),
           date >= weekAgo, date < now {
            return "\(FixedDateFormat.formatter("EEE", timeZone: zone).string(from: date)) \(time)"
        }
        // "This year" is the Gregorian year the text shows, not the phone calendar's year.
        var gregorian = Calendar(identifier: .gregorian)
        gregorian.timeZone = zone
        let format = gregorian.isDate(date, equalTo: now, toGranularity: .year) ? "MMM d" : "MMM d, yyyy"
        return "\(FixedDateFormat.formatter(format, timeZone: zone).string(from: date)), \(time)"
    }
}
