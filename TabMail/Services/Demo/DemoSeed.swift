/* This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at https://mozilla.org/MPL/2.0/. */

import Foundation
import GRDB

/// Demo Mode seeded data — accounts, folders, messages, AI cache, calendar.
///
/// All seeded rows are tagged with `accountId == DemoSeed.demoAccountId` (or
/// `id == "demo-account"` for the Account row) so cleanup is deterministic.
/// AI cache fields (summaryBlurb, actionTag, cachedReply, MessageAICache rows)
/// are pre-baked for every inbox message — opening any seeded message MUST
/// NOT trigger an LLM round-trip (the master invariant).
enum DemoSeed {
    static let demoAccountId = "demo-account"
    static let demoEmail = "alex@demomail.example"
    static let demoDisplayName = "Alex Morgan"

    /// Run the full seed. Idempotent — wipes any prior demo rows first.
    /// Throws if AppDatabase isn't initialized or a write fails.
    static func seed() throws {
        guard let db = AppDatabase.shared.withLock({ $0 }) else {
            throw DemoSeedError.databaseUnavailable
        }
        try db.dbPool.write { dbConn in
            try wipe(dbConn)
            try seedAccount(dbConn)
            let folders = try seedFolders(dbConn)
            try seedMessages(dbConn, folders: folders)
            try seedCalendarEvents(dbConn)
        }
        print("[DemoSeed] Seeding complete")
    }

    /// Wipe all demo rows from GRDB. Mirrors the cleanup pass in
    /// `DemoModeService.exit()`. Idempotent.
    /// Cheap indexed existence check: is there any demo data to wipe?
    ///
    /// The demo account row is seeded FIRST and deleted LAST by `wipe`, so its
    /// presence ⟺ a demo seed exists or a prior `wipe` was interrupted (demo
    /// data may remain); its absence ⟺ a completed wipe or a never-seeded DB.
    /// A normal launch returns `false` on a single primary-key lookup, letting
    /// `AppStartup.ensureDatabaseReady` SKIP the `wipe` DELETEs entirely — several
    /// of which are unindexed `LIKE 'demo-account:%'` full table scans over
    /// messageHeader/messageBody and cost seconds on a large mailbox. Because the
    /// wipe runs before `dbReady`, those scans were directly gating FIRST PAINT
    /// (≈10s in the 2026-06-26 cold-boot trace).
    static func hasDemoData(_ db: Database) throws -> Bool {
        try Int.fetchOne(db, sql: "SELECT 1 FROM account WHERE id = ? LIMIT 1",
                         arguments: [demoAccountId]) != nil
    }

    static func wipe(_ db: Database) throws {
        // Prefix matches use index-friendly half-open RANGE bounds
        // (`>= 'p' AND < 'p<next-byte>'`) instead of `LIKE 'p%'`. SQLite's default
        // LIKE is case-insensitive, so it can't use a TEXT PRIMARY KEY's (BINARY)
        // index and falls back to a full table scan — the cost that gated cold-boot
        // FIRST PAINT before `hasDemoData` short-circuited it (and the cost the wipe
        // would still pay every time it DID run). ';' (0x3B) is the byte after ':'
        // (0x3A), so `< 'demo-account;'` is the exclusive upper bound for the
        // `demo-account:` prefix. Demo ids are always lowercase, so the
        // (case-sensitive) range matches exactly the rows LIKE did.
        try db.execute(sql: "DELETE FROM messageBody WHERE id >= 'demo-account:' AND id < 'demo-account;'")
        try db.execute(sql: "DELETE FROM messageHeader WHERE accountId = ?", arguments: [demoAccountId])
        try db.execute(sql: "DELETE FROM folder WHERE accountId = ?", arguments: [demoAccountId])
        try db.execute(sql: "DELETE FROM messageAICache WHERE key >= 'demo-account:' AND key < 'demo-account;'")
        try db.execute(sql: "DELETE FROM chatTurn WHERE sessionId >= 'demo:' AND sessionId < 'demo;'")
        // chatHistory gets a parallel dereferenced copy of every turn
        // (ChatStore.appendTurn) — wipe it too, or demo turns would surface in
        // Settings > Chat History and Stage A self-heal would re-index them
        // into memory.db right after the exit purge.
        try db.execute(sql: "DELETE FROM chatHistory WHERE sessionId >= 'demo:' AND sessionId < 'demo;'")
        try db.execute(sql: "DELETE FROM outboxMessage WHERE accountId = ?", arguments: [demoAccountId])
        try db.execute(sql: "DELETE FROM pendingOperation WHERE accountId = ?", arguments: [demoAccountId])
        try db.execute(sql: "DELETE FROM pendingCalendarOperation WHERE accountId = ?", arguments: [demoAccountId])
        // ChatIdTranslator persists numeric-ID mappings; demo header ids are
        // 'demo-account:{folder}:{msgId}' so the same index-friendly range
        // form applies. Prevents dangling demo mappings after exit.
        try db.execute(sql: "DELETE FROM chatIdMapping WHERE realId >= 'demo-account:' AND realId < 'demo-account;'")
        try? db.execute(sql: "DELETE FROM demoCalendarEvent")
        try db.execute(sql: "DELETE FROM account WHERE id = ?", arguments: [demoAccountId])
    }

    // MARK: - Account

    private static func seedAccount(_ db: Database) throws {
        var account = Account(
            emailAddress: demoEmail,
            displayName: demoDisplayName,
            provider: .imap
        )
        account.id = demoAccountId
        account.isActive = true
        account.isPrimary = true
        account.calendarOnly = false
        try account.insert(db)
    }

    // MARK: - Folders

    private struct DemoFolder {
        let name: String
        let path: String
        let role: FolderRole
        var unreadCount: Int = 0
        var totalCount: Int = 0
    }

    private static let demoFolderSpecs: [DemoFolder] = [
        DemoFolder(name: "Inbox",      path: "INBOX",       role: .inbox),
        DemoFolder(name: "Sent",       path: "SENT",        role: .sent),
        DemoFolder(name: "Drafts",     path: "DRAFTS",      role: .drafts),
        DemoFolder(name: "Archive",    path: "ARCHIVE",     role: .archive),
        DemoFolder(name: "Trash",      path: "TRASH",       role: .trash),
        DemoFolder(name: "Spam",       path: "SPAM",        role: .spam),
        DemoFolder(name: "Newsletters", path: "Newsletters", role: .custom),
    ]

    private static func seedFolders(_ db: Database) throws -> [String: Folder] {
        var folders: [String: Folder] = [:]
        for spec in demoFolderSpecs {
            var folder = Folder(name: spec.name, path: spec.path, role: spec.role, accountId: demoAccountId)
            folder.unreadCount = spec.unreadCount
            folder.totalCount = spec.totalCount
            folder.backfillComplete = true
            folder.oldestSyncedDate = Calendar.current.date(byAdding: .day, value: -90, to: Date())
            try folder.insert(db)
            folders[spec.path] = folder
        }
        return folders
    }

    // MARK: - Messages (with pre-baked AI cache)

    /// Sample inbox messages. AI fields pre-populated so opening them never
    /// fires an LLM call. Hand-curated to feel realistic — work email,
    /// receipts, code-host notifications, family thread, calendar invite.
    private struct SeededMessage {
        let path: String                       // folder path
        let subject: String
        let fromName: String
        let fromAddress: String
        let to: String
        let body: String                       // HTML
        let isRead: Bool
        let isFlagged: Bool
        let action: ActionTag?
        let summaryBlurb: String?
        let cachedReply: String?
        let daysAgo: Int
        // Optional email reminder. Stored as a relative offset so the seed
        // produces a sensible "due Friday" / "due tonight" feel regardless of
        // when the user opens the demo. Date string ("YYYY-MM-DD") is computed
        // at insert time. nil means no reminder.
        var reminderDaysAhead: Int? = nil
        var reminderTime: String? = nil        // "HH:MM" 24-hour, optional
        var reminderContent: String? = nil
    }

    private static let seededMessages: [SeededMessage] = [
        // Inbox — 8 hand-curated, all with pre-baked AI cache
        SeededMessage(
            path: "INBOX",
            subject: "Q1 budget review — your input needed by Friday",
            fromName: "Maya Chen",
            fromAddress: "maya.chen@workmail.example",
            to: demoEmail,
            body: "<p>Hi Alex,</p><p>I'm pulling together the Q1 budget review for the leadership sync next Wednesday. Could you forward me your team's actuals + projected spend for Q2 by EOD Friday?</p><p>Specifically I need:</p><ul><li>Headcount changes</li><li>Tooling spend (monitoring, source hosting, hosting platform)</li><li>Anticipated contractor costs</li></ul><p>Thanks!<br>Maya</p>",
            isRead: false, isFlagged: false,
            action: .reply,
            summaryBlurb: "Maya needs your Q1 actuals + Q2 projections by EOD Friday for the leadership sync. She wants headcount, tooling, and contractor numbers.",
            cachedReply: "Hi Maya,\n\nI'll pull these together and send by Thursday EOD so you have time to review. Will include headcount changes, tooling, and contractor costs broken out by team.\n\nAlex",
            daysAgo: 1,
            reminderDaysAhead: 3,
            reminderTime: "17:00",
            reminderContent: "Send Q1 actuals + Q2 projections to Maya"
        ),
        SeededMessage(
            path: "INBOX",
            subject: "Re: Weekend trip — flight options",
            fromName: "Jordan Park",
            fromAddress: "jordan@personal.example",
            to: demoEmail,
            body: "<p>Hey,</p><p>Found a few flight options for the weekend trip — a 5pm departure or a 6:30pm departure. Both ~$240 round trip. The earlier flight gets us in sooner; the later one has the better seats. What's your preference?</p><p>Also, the cabin host confirmed early check-in is fine.</p>",
            isRead: false, isFlagged: false,
            action: .reply,
            summaryBlurb: "Jordan found two flight options for the weekend — a 5pm or 6:30pm departure, both ~$240. Cabin early check-in confirmed.",
            cachedReply: "Let's do the earlier flight — earlier arrival means we can grab dinner downtown. I'll book my half tonight.",
            daysAgo: 2
        ),
        SeededMessage(
            path: "INBOX",
            subject: "Your PayFlow payment of $19.99 succeeded",
            fromName: "PayFlow",
            fromAddress: "no-reply@payflow.example",
            to: demoEmail,
            body: "<p>Receipt for your monthly subscription. <a>View invoice</a></p>",
            isRead: true, isFlagged: false,
            action: .archive,
            summaryBlurb: "Receipt — $19.99 monthly subscription charged successfully. No action needed.",
            cachedReply: nil,
            daysAgo: 3
        ),
        SeededMessage(
            path: "INBOX",
            subject: "[CodeHub] PR #1247 — needs your review",
            fromName: "CodeHub",
            fromAddress: "notifications@codehub.example",
            to: demoEmail,
            body: "<p>tabmail-ios PR #1247 — \"Refactor InboxViewModel actor isolation\" by @devuser is ready for review. <a>View PR</a></p>",
            isRead: false, isFlagged: false,
            action: .reply,
            summaryBlurb: "Sarah opened PR #1247 to refactor InboxViewModel actor isolation — ready for your review.",
            cachedReply: "Reviewed — looks great, just left two minor comments on the dispatch order. LGTM after those.",
            daysAgo: 1
        ),
        SeededMessage(
            path: "INBOX",
            subject: "DailyTech Digest: AI agents heat up",
            fromName: "DailyTech",
            fromAddress: "newsletter@dailytech.example",
            to: demoEmail,
            body: "<p>Today's headlines: a major model launch… a coding-tool startup raises a round… autonomous agents in production…</p>",
            isRead: true, isFlagged: false,
            action: .archive,
            summaryBlurb: "Daily DailyTech digest — a model launch, a startup funding round, autonomous agents.",
            cachedReply: nil,
            daysAgo: 1
        ),
        SeededMessage(
            path: "INBOX",
            subject: "Mom — call when you get a chance?",
            fromName: "Mom",
            fromAddress: "mom@family.example",
            to: demoEmail,
            body: "<p>Just thinking about you. Dad's surgery went well. Let me know when you have a free 20 minutes!</p><p>Love,<br>Mom</p>",
            isRead: false, isFlagged: false,
            action: .reply,
            summaryBlurb: "Mom asking for a 20-min call — Dad's surgery went well.",
            cachedReply: "Mom — so glad to hear about Dad. I'll call you tonight around 8 your time. Love you.",
            daysAgo: 0,
            reminderDaysAhead: 0,
            reminderTime: "20:00",
            reminderContent: "Call Mom (20 min)"
        ),
        SeededMessage(
            path: "INBOX",
            subject: "ACTION REQUIRED: 2-step verification code 847291",
            fromName: "Auth",
            fromAddress: "noreply@auth.example",
            to: demoEmail,
            body: "<p>Your verification code is <b>847291</b>. Code expires in 10 minutes.</p>",
            isRead: true, isFlagged: false,
            action: .delete,
            summaryBlurb: "OTP code — 847291. Expires in 10 minutes.",
            cachedReply: nil,
            daysAgo: 0
        ),
        SeededMessage(
            path: "INBOX",
            subject: "Engineering offsite — agenda + logistics",
            fromName: "Priya Vasanth",
            fromAddress: "priya@workmail.example",
            to: demoEmail,
            body: "<p>Final agenda for the offsite next month attached. Please RSVP by Wednesday.</p><p>Hotel block expires Friday.</p>",
            isRead: false, isFlagged: false,
            action: .reply,
            summaryBlurb: "Priya needs offsite RSVP by Wednesday; hotel block expires Friday. Agenda attached.",
            cachedReply: "Confirming attendance. I'll book the hotel today before the block expires.",
            daysAgo: 4,
            reminderDaysAhead: 2,
            reminderTime: nil,
            reminderContent: "RSVP for offsite + book hotel"
        ),

        // Sent
        SeededMessage(
            path: "SENT",
            subject: "Re: Q4 retro action items",
            fromName: demoDisplayName,
            fromAddress: demoEmail,
            to: "team@workmail.example",
            body: "<p>Sharing my notes from yesterday's retro. Top items: ramp up on-call rotation, ship the search hybrid, kill the deprecated metrics endpoint.</p>",
            isRead: true, isFlagged: false,
            action: nil,
            summaryBlurb: "Sent — Q4 retro action items: on-call rotation, hybrid search ship, kill deprecated endpoint.",
            cachedReply: nil,
            daysAgo: 5
        ),
        SeededMessage(
            path: "SENT",
            subject: "Updated proposal — happy to discuss",
            fromName: demoDisplayName,
            fromAddress: demoEmail,
            to: "client@partner.example",
            body: "<p>Attached is the revised proposal incorporating your team's feedback. Available for a call this week.</p>",
            isRead: true, isFlagged: false,
            action: nil,
            summaryBlurb: "Sent — revised proposal with feedback incorporated; offered call this week.",
            cachedReply: nil,
            daysAgo: 7
        ),

        // Drafts
        SeededMessage(
            path: "DRAFTS",
            subject: "[Draft] Performance review self-eval",
            fromName: demoDisplayName,
            fromAddress: demoEmail,
            to: "manager@workmail.example",
            body: "<p>(in progress)</p><p>Highlights: shipped hybrid search, mentored 2 new hires, owned the AI infra migration…</p>",
            isRead: true, isFlagged: false,
            action: nil,
            summaryBlurb: nil,
            cachedReply: nil,
            daysAgo: 6
        ),

        // Archive
        SeededMessage(
            path: "ARCHIVE",
            subject: "Onboarding paperwork complete",
            fromName: "HR",
            fromAddress: "hr@workmail.example",
            to: demoEmail,
            body: "<p>All paperwork on file. Welcome aboard!</p>",
            isRead: true, isFlagged: false,
            action: nil,
            summaryBlurb: "HR confirmed all onboarding paperwork is on file.",
            cachedReply: nil,
            daysAgo: 30
        ),

        // Newsletters
        SeededMessage(
            path: "Newsletters",
            subject: "The Weekly Byte: The Coming AI Stack Reset",
            fromName: "Sam Rivera",
            fromAddress: "sam@theweeklybyte.example",
            to: demoEmail,
            body: "<p>This week: vertical AI agents are the new SaaS unit of distribution…</p>",
            isRead: false, isFlagged: false,
            action: nil,
            summaryBlurb: "The Weekly Byte — vertical AI agents as the new SaaS unit of distribution.",
            cachedReply: nil,
            daysAgo: 2
        ),
    ]

    private static func seedMessages(_ db: Database, folders: [String: Folder]) throws {
        let now = Date()
        for (idx, m) in seededMessages.enumerated() {
            guard let folder = folders[m.path] else { continue }
            let date = Calendar.current.date(byAdding: .day, value: -m.daysAgo, to: now) ?? now
            let messageId = "demo-msg-\(idx + 1)"
            let rfc822 = "<demo-msg-\(idx + 1)@demomail.example>"

            var header = MessageHeader(
                messageId: messageId,
                subject: m.subject,
                from: m.fromName,
                fromAddress: m.fromAddress,
                to: m.to,
                date: date,
                snippet: stripHTML(m.body).prefix(160).description,
                folderId: folder.id,
                accountId: demoAccountId,
                folderPath: folder.path,
                isInInbox: folder.role == .inbox
            )
            header.rfc822MessageId = rfc822
            header.isRead = m.isRead
            header.isFlagged = m.isFlagged
            header.actionTag = m.action
            header.tagSortOrder = m.action?.sortOrder ?? 99
            header.summaryBlurb = m.summaryBlurb
            // Empty-string sentinel = "reply pipeline ran, no reply needed"
            // (MessageSnapshot.swift:32). Without this, a tagged demo message
            // (e.g. .archive / .delete) with no precomputed reply has
            // `cachedReply == nil` → MessageRowView.showShimmer treats it as
            // "still computing reply" and renders the AI shimmer forever.
            header.cachedReply = m.cachedReply ?? (m.action != nil ? "" : nil)
            // Email reminders — ReminderBuilder picks these up and renders
            // them as inbox cards. Date is computed as a relative offset so
            // demo always shows fresh-looking due dates.
            if let daysAhead = m.reminderDaysAhead, m.reminderContent != nil {
                let due = Calendar.current.date(byAdding: .day, value: daysAhead, to: now) ?? now
                let formatter = DateFormatter()
                formatter.dateFormat = "yyyy-MM-dd"
                formatter.calendar = Calendar(identifier: .gregorian)
                formatter.locale = Locale(identifier: "en_US_POSIX")
                header.reminderDate = formatter.string(from: due)
                header.reminderTime = m.reminderTime
                header.reminderContent = m.reminderContent
            }
            header.headerComplete = true
            header.bodyComplete = true
            try header.insert(db)

            let body = MessageBody(headerId: header.id, htmlContent: m.body)
            try body.insert(db)

            // Pre-bake AI cache row so the production short-circuit (which
            // checks MessageAICache via Device Sync probe) finds a match for
            // any path that bypasses the GRDB header check.
            if m.summaryBlurb != nil || m.action != nil || m.cachedReply != nil,
               let cacheKey = MessageAICache.cacheKey(
                accountId: demoAccountId,
                folderPath: folder.path,
                rfc822MessageId: rfc822
               ) {
                var cache = MessageAICache(key: cacheKey, rfc822MessageId: rfc822)
                cache.summaryBlurb = m.summaryBlurb
                cache.actionTag = m.action
                cache.cachedReply = m.cachedReply
                cache.replyGeneratedAt = m.cachedReply != nil ? date : nil
                cache.updatedAt = date
                try cache.insert(db)
            }
        }
    }

    private static func stripHTML(_ s: String) -> String {
        s.replacingOccurrences(of: "<[^>]+>", with: " ", options: .regularExpression)
            .replacingOccurrences(of: "&nbsp;", with: " ")
            .trimmingCharacters(in: .whitespaces)
    }

    // MARK: - Calendar (uses demoCalendarEvent table — see DemoCalendarProvider)

    private static func seedCalendarEvents(_ db: Database) throws {
        let now = Date()
        let cal = Calendar.current
        let demoEvents: [(title: String, startOffsetHours: Int, durationHours: Int, location: String)] = [
            ("Standup",                3,    1, "Video call"),
            ("Standup",                27,   1, "Video call"),
            ("Standup",                51,   1, "Video call"),
            ("Maya 1:1",               4,    1, "Coffee shop"),
            ("Engineering offsite",    24*7, 8, "San Francisco"),
            ("Dad's birthday dinner",  24*9, 3, "Mom's house"),
            ("Hybrid search ship",     24*3, 0, "All-day milestone"),
            ("Performance review",     24*5, 1, "Office"),
        ]
        for (idx, e) in demoEvents.enumerated() {
            let start = cal.date(byAdding: .hour, value: e.startOffsetHours, to: now) ?? now
            let end = cal.date(byAdding: .hour, value: max(1, e.durationHours), to: start) ?? start
            try db.execute(sql: """
                INSERT INTO demoCalendarEvent (id, accountId, calendarId, title, location, startMs, endMs, allDay)
                VALUES (?, ?, ?, ?, ?, ?, ?, ?)
            """, arguments: [
                "demo-event-\(idx + 1)",
                demoAccountId,
                "primary",
                e.title,
                e.location,
                Int64(start.timeIntervalSince1970 * 1000),
                Int64(end.timeIntervalSince1970 * 1000),
                e.durationHours == 0 ? 1 : 0,
            ])
        }
    }
}

enum DemoSeedError: Error, LocalizedError {
    case databaseUnavailable
    case seedFailed(String)

    var errorDescription: String? {
        switch self {
        case .databaseUnavailable: return "Database not initialized."
        case .seedFailed(let msg): return "Seed failed: \(msg)"
        }
    }
}

// MARK: - Demo tool guard (ADR-IOS-038)

/// Shared demo-boundary primitives for the agent tool layer.
enum DemoToolGuard {
    /// Tool-result error returned by tools that are blocked in demo mode
    /// (contacts, settings). The LLM relays it to the demo user.
    static let blockedMessage = #"{"error": "This feature is not available in demo mode."}"#

    /// GRDB predicate scoping a table's `accountId` column per demo state:
    /// demo mode sees ONLY demo rows; normal mode NEVER sees them.
    static func accountScope(demoActive: Bool) -> SQLExpression {
        demoActive
            ? Column("accountId") == DemoSeed.demoAccountId
            : Column("accountId") != DemoSeed.demoAccountId
    }

    /// Whether an email tool may act on this header in the current mode.
    /// Blocks BOTH directions: a demo chat must never touch a real email
    /// (stale ChatIdTranslator numeric IDs can reference real headers), and
    /// a real chat must never touch a leftover demo row.
    static func headerAccessible(_ header: MessageHeader) -> Bool {
        (header.accountId == DemoSeed.demoAccountId) == DemoModeStore.isDemoActive
    }
}
