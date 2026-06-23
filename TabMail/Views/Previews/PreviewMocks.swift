/* This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at https://mozilla.org/MPL/2.0/. */

#if DEBUG
import SwiftUI
import GRDB
import TipKit

/// Shared factory for SwiftUI Preview canvas mocks.
///
/// Usage: call `PreviewMocks.bootstrap*()` helpers inside a `#Preview` block,
/// then render the real host view. Rules:
/// - DEBUG-only (stripped from release).
/// - Never modify production initializers.
/// - Ephemeral on-disk SQLite (GRDB DatabasePool requires a file path for WAL).
enum PreviewMocks {

    // MARK: - Database bootstrap

    /// Initialize `AppDatabase.shared` with an ephemeral on-disk pool if not already set.
    /// Idempotent: safe to call from multiple previews.
    static func bootstrapAppDatabase() {
        AppDatabase.shared.withLock { slot in
            if slot != nil { return }
            let dir = FileManager.default.temporaryDirectory
                .appendingPathComponent("tabmail-preview-\(UUID().uuidString)", isDirectory: true)
            try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            let path = dir.appendingPathComponent("preview.sqlite").path
            var config = Configuration()
            config.journalMode = .wal
            config.foreignKeysEnabled = true
            do {
                let pool = try DatabasePool(path: path, configuration: config)
                slot = try AppDatabase(dbPool: pool)
            } catch {
                assertionFailure("PreviewMocks: failed to bootstrap AppDatabase — \(error)")
            }
        }
    }

    // MARK: - Seed scenarios

    struct InboxScenario {
        let account: Account
        let inbox: Folder
        let headers: [MessageHeader]
    }

    /// Seed a minimal inbox: 1 account, 1 inbox folder, 5 messages.
    /// Idempotent per preview process (will duplicate on repeat calls;
    /// acceptable for preview canvas since DB is ephemeral per UUID dir).
    @discardableResult
    static func seedInbox() -> InboxScenario {
        bootstrapAppDatabase()
        let pool = AppDatabase.dbPool

        let account = Account(
            emailAddress: "demo@tabmail.ai",
            displayName: "Demo",
            provider: .imap
        )
        var inbox = Folder(name: "Inbox", path: "INBOX", role: .inbox, accountId: account.id)
        inbox.totalCount = 5
        inbox.unreadCount = 3

        let now = Date()
        let samples: [(String, String, String, String)] = [
            ("Alice Chen", "alice@example.com", "Weekly team sync notes",
             "Here's the summary from today's meeting — action items are highlighted and owners assigned."),
            ("Bob Martinez", "bob@example.com", "Re: Project Kraken timeline",
             "Can we push the milestone by a week? The vendor delivery slipped."),
            ("CodeHub", "noreply@codehub.example", "[tabmail/ios] PR #42 merged",
             "Your pull request was successfully merged into main."),
            ("Carol Wu", "carol@example.com", "Dinner Friday?",
             "Free around 7? Thinking the new ramen place downtown."),
            ("Swift Weekly", "news@swiftweekly.example", "This week in Swift",
             "SE-0433 lands in 6.0, TipKit updates, and a deep dive on strict concurrency."),
        ]

        // Action tags per-row so previews show the colored tag badges that the
        // real app renders (triage classification). Roughly mirrors a classified inbox.
        let tags: [ActionTag] = [.reply, .none, .archive, .reply, .archive]

        var headers: [MessageHeader] = []
        for (i, s) in samples.enumerated() {
            var h = MessageHeader(
                messageId: "\(1000 + i)",
                subject: s.2,
                from: s.0,
                fromAddress: s.1,
                to: "demo@tabmail.ai",
                date: now.addingTimeInterval(TimeInterval(-i * 3600)),
                snippet: s.3,
                folderId: inbox.id,
                accountId: account.id,
                folderPath: inbox.path,
                isInInbox: true
            )
            h.isRead = i >= 3
            h.headerComplete = true
            h.bodyComplete = true
            h.actionTag = tags[i]
            h.tagSortOrder = tags[i].sortOrder
            // AI-generated chrome: populate summary + reply on every row so the
            // AI summary bubble and reply pill render in the real state (not
            // loading/failed). Matches a fully-classified inbox.
            h.summaryBlurb = [
                "Alice shared team-sync notes; action items are assigned with owners.",
                "Bob wants to push the Kraken milestone by a week due to vendor slippage.",
                "CodeHub notification: pull request #42 has been merged into main.",
                "Carol proposes dinner at the new ramen place Friday around 7pm.",
                "Swift Weekly roundup: SE-0433 lands, TipKit updates, strict concurrency deep dive.",
            ][i]
            h.summaryTodos = [
                "Review action items\nConfirm ownership with Alice",
                "Decide on new milestone date\nReply to Bob",
                nil,
                "Reply to Carol with availability",
                nil,
            ][i]
            // cachedReply populated on every row (even archive-tagged) so no
            // row shows the reply-loading shimmer. The shimmer is intended for
            // rows where AI hasn't finished yet, which isn't a useful preview state.
            h.cachedReply = [
                "Thanks for sharing — I'll review the action items and follow up by EOW.",
                "Agreed, let's push by a week. I'll update the tracker.",
                "Thanks for the heads-up — archiving.",
                "Sounds great! 7pm Friday works.",
                "Thanks, archiving for later reading.",
            ][i]
            headers.append(h)
        }

        // User-defined labels (Gmail labels / IMAP keywords), distinct from
        // TabMail's internal ActionTag. Mirrors what a real inbox looks like
        // after classification + user tagging.
        let labels = [
            UserLabel(id: "lbl_work", accountId: account.id, name: "Work", isSystem: false),
            UserLabel(id: "lbl_personal", accountId: account.id, name: "Personal", isSystem: false),
            UserLabel(id: "lbl_urgent", accountId: account.id, name: "Urgent", isSystem: false),
        ]
        // Row 0 → Work; row 1 → Work + Urgent; row 3 → Personal; row 4 → Work.
        let messageLabels: [MessageUserLabel] = [
            MessageUserLabel(messageId: headers[0].id, userLabelId: "lbl_work"),
            MessageUserLabel(messageId: headers[1].id, userLabelId: "lbl_work"),
            MessageUserLabel(messageId: headers[1].id, userLabelId: "lbl_urgent"),
            MessageUserLabel(messageId: headers[3].id, userLabelId: "lbl_personal"),
            MessageUserLabel(messageId: headers[4].id, userLabelId: "lbl_work"),
        ]

        // Message bodies so MessageDetailView can render full content.
        // Per-row unique HTML (short, realistic) keyed by header ID.
        let bodies: [MessageBody] = zip(headers, [
            "<p>Hi team,</p><p>Here are the notes from today's sync. Action items are highlighted and owners assigned.</p><ul><li>Alice — draft proposal by Friday</li><li>Bob — vendor follow-up</li><li>Carol — design review</li></ul><p>Thanks,<br>Alice</p>",
            "<p>Hey,</p><p>Can we push the Kraken milestone by a week? The vendor delivery slipped and we need buffer for QA.</p><p>— Bob</p>",
            "<p>Your pull request <strong>#42</strong> was successfully merged into <code>main</code>.</p><p>View the merge commit <a href=\"#\">on CodeHub</a>.</p>",
            "<p>Hi!</p><p>Free around 7 on Friday? Thinking the new ramen place downtown — heard the tonkotsu is great.</p><p>xo Carol</p>",
            "<h2>This Week in Swift</h2><p>SE-0433 lands in Swift 6.0, TipKit gets new APIs for testing, and a deep dive on strict concurrency warnings.</p><p><a href=\"#\">Read the full issue →</a></p>",
        ]).map { header, html in
            MessageBody(headerId: header.id, htmlContent: html)
        }

        do {
            try pool.write { db in
                try account.save(db)
                try inbox.save(db)
                for h in headers { try h.save(db) }
                for b in bodies { try b.save(db) }
                for l in labels { try l.save(db) }
                for ml in messageLabels { try ml.save(db) }
            }
        } catch {
            assertionFailure("PreviewMocks.seedInbox write failed: \(error)")
        }

        return InboxScenario(account: account, inbox: inbox, headers: headers)
    }

    /// Seed one failed + one queued outbox message against the seeded account.
    /// Idempotent: call `seedInbox()` first (same DB).
    @discardableResult
    static func seedOutbox(account: Account) -> [OutboxMessage] {
        bootstrapAppDatabase()
        let pool = AppDatabase.dbPool

        var queued = OutboxMessage(
            accountId: account.id,
            draft: DraftMessage(
                to: ["alice@example.com"],
                subject: "Re: Weekly team sync notes",
                body: "Thanks for the summary — action items look good.",
                isHTML: false
            )
        )
        queued.status = OutboxStatus.queued.rawValue

        var failed = OutboxMessage(
            accountId: account.id,
            draft: DraftMessage(
                to: ["bob@example.com"],
                subject: "Re: Project Kraken timeline",
                body: "Let's push by a week. Vendor confirmed.",
                isHTML: false
            )
        )
        failed.status = OutboxStatus.failed.rawValue
        failed.errorMessage = "SMTP connection refused"
        failed.retryCount = 3

        do {
            try pool.write { db in
                try queued.save(db)
                try failed.save(db)
            }
        } catch {
            assertionFailure("PreviewMocks.seedOutbox write failed: \(error)")
        }
        return [queued, failed]
    }

    // MARK: - NavigationStore

    /// A `NavigationStore` pre-populated from the mock DB via its real `loadInitialData()`.
    /// Also opens the AI subscription gate so AI-gated views (summary bubble, reply
    /// pills, chat) render their full state instead of the "Subscribe" placeholder.
    @MainActor
    static func navigationStore() -> NavigationStore {
        bootstrapAppDatabase()
        AISubscriptionGate.shared.openGate()
        let store = NavigationStore()
        store.loadInitialData()
        return store
    }

    // MARK: - TipKit

    /// All app tip types, used by `spotlight` to hide every tip except the target.
    /// Keep in sync with the types defined in `AppTips.swift`. `Tips.showTipsForTesting`
    /// does NOT suppress other tips — other tips can still fire once their rules pass,
    /// and `Tips.configure(.immediate)` after `resetDatastore()` lets them all qualify
    /// simultaneously. So we must explicitly hide the non-target tips.
    private static let allTipTypes: [any Tip.Type] = [
        SwipeActionsTip.self,
        TagTeachingTip.self,
        InboxTagTeachingTip.self,
        ArchiveOldEmailsTip.self,
        EnableInboxPushTip.self,
        TriageModeTip.self,
        SearchScopeTip.self,
        SummaryBubbleTip.self,
        InboxChatPillTip.self,
        ChatPillTip.self,
        ComposeChatPillTip.self,
        ChatForkTip.self,
        DeviceSyncTip.self,
        OutboxSwipeActionsTip.self,
        AgentBackgroundTip.self,
        ComposeSaveDraftTip.self,
        ComposeChatCollapseTip.self,
        InboxChatCollapseTip.self,
        MessageChatCollapseTip.self,
        RemindersMenuTip.self,
        UserLabelRowManageTip.self,
        UserLabelCardManageTip.self,
    ]

    /// Reset all tip `@Parameter` statics to their defaults. Call this from
    /// `spotlight` so a previous preview's set-to-true doesn't leak into the
    /// next preview's environment (Xcode's preview process reuses state across
    /// canvas reloads).
    @MainActor
    private static func resetAllTipParameters() {
        ArchiveOldEmailsTip.isLargeInbox = false
        EnableInboxPushTip.pushEnabled = false
        AgentBackgroundTip.hasNavigatedAwayDuringWork = false
        ComposeSaveDraftTip.hasClosedComposeChat = false
        ComposeChatCollapseTip.hasStartedComposeChat = false
        InboxChatCollapseTip.hasStartedInboxChat = false
        MessageChatCollapseTip.hasStartedMessageChat = false
    }

    /// Spotlight a single tip in preview: resets every tip `@Parameter`, resets
    /// the TipKit datastore, forces the target tip to display regardless of
    /// rules, and explicitly hides every other tip so adjacent `.popoverTip(...)`
    /// attachments in the host view don't steal focus.
    ///
    /// If the target tip has its own `@Parameter`, set it **after** calling this.
    @MainActor
    static func spotlight<T: Tip>(_ type: T.Type) {
        resetAllTipParameters()
        try? Tips.resetDatastore()
        try? Tips.configure([
            .displayFrequency(.immediate),
            .datastoreLocation(.applicationDefault)
        ])
        let others = allTipTypes.filter { ObjectIdentifier($0) != ObjectIdentifier(type) }
        Tips.hideTipsForTesting(others)
        Tips.showTipsForTesting([type])
    }

    /// Hide EVERY app tip in a preview — for host-view previews (e.g. a seeded
    /// `InboxView`) that aren't demonstrating a tip and shouldn't have tooltips
    /// popping in on interaction. Deterministic across Xcode's reused preview
    /// process (resets the datastore + parameters first, since a prior
    /// `spotlight` preview may have configured TipKit).
    @MainActor
    static func hideAllTips() {
        resetAllTipParameters()
        try? Tips.resetDatastore()
        try? Tips.configure([
            .displayFrequency(.immediate),
            .datastoreLocation(.applicationDefault)
        ])
        Tips.hideTipsForTesting(allTipTypes)
        Tips.showTipsForTesting([])
    }
}
#endif
