/* This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at https://mozilla.org/MPL/2.0/. */

import Foundation

/// Detects `--screenshot-mode` launch argument (set by UI tests) and seeds
/// GRDB with realistic demo data so the app can render full App Store screenshots
/// without a real account or network access.
enum ScreenshotMode {
    static let isActive: Bool = ProcessInfo.processInfo.arguments.contains("--screenshot-mode")
    /// Also detects `--screenshot-splash` for capturing the login screen.
    static let isSplashMode: Bool = ProcessInfo.processInfo.arguments.contains("--screenshot-splash")
    /// Forces dark appearance for website screenshots (--screenshot-dark).
    /// Used by TabMailApp's `.preferredColorScheme()` modifier.
    static let isDarkMode: Bool = ProcessInfo.processInfo.arguments.contains("--screenshot-dark")

    /// The instance epoch the seeded compose chat session is keyed under (R16-11).
    /// A constant, because a fixture runs before any `ComposeGenerationCursor`
    /// exists and therefore cannot know the epoch a live compose session will mint.
    /// See the seeding site for why that means the session is not bindable today.
    private static let screenshotComposeEpoch = "screenshot-epoch"

    /// The draft id `ComposeView.onAppear` derives via `Draft.draftKey` for a reply
    /// to the seeded `msg001`.
    static let seededComposeDraftId = "reply:screenshot-account:msg001"

    /// The EXACT `ChatPillState` key the compose fixture seeds under, minted through
    /// `ActiveAgentTracker.composeSessionKey`. Hoisted out of the seeding site (not
    /// private) so a test can decode it back through the real parser: the fixture
    /// runs only under `--screenshot-mode`, so this constant is the only surface on
    /// which the round-trip is checkable, and checking a key the test mints itself
    /// would prove nothing about this producer.
    static let seededComposeSessionKey = ActiveAgentTracker.composeSessionKey(
        draftId: seededComposeDraftId, epoch: screenshotComposeEpoch)

    // MARK: - Mock data for AccountDashboardView

    static let mockAccountInfo: AccountInfo? = {
        let json: [String: Any] = [
            "logged_in": true,
            "has_subscription": true,
            "email": "alex@gmail.com",
            "plan_tier": "Pro",
            "subscription_status": "Active",
            "subscription_provider": "apple",
            "quota_percentage": 34.0,
            "used_cost_cents": 170.0,
            "limit_cost_cents": 499.0,
            "billing_period_start": Date().addingTimeInterval(-15 * 86400).timeIntervalSince1970,
            "billing_period_end": Date().addingTimeInterval(15 * 86400).timeIntervalSince1970,
            "max_monthly_cost_cents": 499.0,
        ]
        guard let data = try? JSONSerialization.data(withJSONObject: json) else { return nil }
        return try? JSONDecoder().decode(AccountInfo.self, from: data)
    }()

    static let mockUsageStats: UsageStats? = {
        var dailyStats: [[String: Any]] = []
        let cal = Calendar(identifier: .gregorian)
        for i in (0..<30).reversed() {
            let d = cal.date(byAdding: .day, value: -i, to: Date())!
            let dateStr = {
                let f = DateFormatter()
                f.dateFormat = "yyyy-MM-dd"
                return f.string(from: d)
            }()
            let calls = Double.random(in: 5...40)
            let input = Double.random(in: 800...4000)
            let output = Double.random(in: 200...1200)
            dailyStats.append([
                "date": dateStr,
                "calls": calls,
                "tokens_input": input,
                "tokens_output": output,
                "tokens_total": input + output,
                "cost_cents": Double.random(in: 2...18),
            ])
        }
        let json: [String: Any] = [
            "today": [
                "calls": 12.0,
                "tokens_input": 2450.0,
                "tokens_output": 680.0,
                "tokens_total": 3130.0,
                "cost_cents": 8.5,
            ] as [String: Any],
            "daily_stats": dailyStats,
        ]
        guard let data = try? JSONSerialization.data(withJSONObject: json) else { return nil }
        return try? JSONDecoder().decode(UsageStats.self, from: data)
    }()

    /// Call once from TabMailApp.init, AFTER AppDatabase is created.
    static func seedIfNeeded() {
        guard isActive else { return }

        // Bypass all onboarding gates
        UserDefaults.standard.set(true, forKey: "hasLaunchedBefore")
        UserDefaults.standard.set(true, forKey: "hasCompletedConsentGate")
        UserDefaults.standard.set(true, forKey: "hasSeenAIConsent")
        UserDefaults.standard.set(true, forKey: "hasSeenPushConsent")
        UserDefaults.standard.set(true, forKey: "didMigrateHeaderIds_v2")
        UserDefaults.standard.set(true, forKey: "didClearBodiesForAttachmentEncoding_v1")
        UserDefaults.standard.set(true, forKey: "didResetImapDatesForInternalDate_v1")
        UserDefaults.standard.set(true, forKey: "didCleanResetMessageData_v1")
        UserDefaults.standard.set(true, forKey: "dictationPromptShown")

        // Seed GRDB with demo data
        do {
            try AppDatabase.dbPool.write { db in
                // Clear any existing data
                try db.execute(sql: "DELETE FROM messageBody")
                try db.execute(sql: "DELETE FROM messageHeader")
                try db.execute(sql: "DELETE FROM folder")
                try db.execute(sql: "DELETE FROM account")

                // --- Accounts (multiple providers for settings screenshot) ---
                let accountId = "screenshot-account"
                let accounts: [(id: String, email: String, name: String, provider: String, isPrimary: Bool)] = [
                    (accountId, "alex@gmail.com", "Alex Morgan", "gmail", true),
                    ("screenshot-outlook", "alex.morgan@outlook.com", "Alex Morgan", "outlook", false),
                    ("screenshot-imap", "alex@company.com", "Company Email", "imap", false),
                ]
                for acct in accounts {
                    try db.execute(
                        sql: """
                            INSERT INTO account (id, emailAddress, displayName, provider, isActive, isPrimary, createdAt)
                            VALUES (?, ?, ?, ?, ?, ?, ?)
                            """,
                        arguments: [acct.id, acct.email, acct.name, acct.provider, true, acct.isPrimary, Date()]
                    )
                }

                // --- Folders (for primary account + basic folders for others) ---
                let folders: [(id: String, accountId: String, name: String, path: String, role: String, unread: Int, total: Int)] = [
                    ("\(accountId):INBOX", accountId, "Inbox", "INBOX", "inbox", 4, 12),
                    ("\(accountId):SENT", accountId, "Sent", "SENT", "sent", 0, 45),
                    ("\(accountId):ARCHIVE", accountId, "Archive", "ARCHIVE", "archive", 0, 230),
                    ("\(accountId):TRASH", accountId, "Trash", "TRASH", "trash", 0, 3),
                    ("\(accountId):DRAFTS", accountId, "Drafts", "DRAFTS", "drafts", 0, 1),
                    ("\(accountId):SPAM", accountId, "Spam", "SPAM", "spam", 0, 7),
                    ("screenshot-outlook:INBOX", "screenshot-outlook", "Inbox", "INBOX", "inbox", 2, 38),
                    ("screenshot-outlook:SENT", "screenshot-outlook", "Sent", "SENT", "sent", 0, 22),
                    ("screenshot-imap:INBOX", "screenshot-imap", "Inbox", "INBOX", "inbox", 1, 56),
                    ("screenshot-imap:SENT", "screenshot-imap", "Sent", "SENT", "sent", 0, 18),
                ]
                for f in folders {
                    try db.execute(
                        sql: """
                            INSERT INTO folder (id, accountId, name, path, role, unreadCount, totalCount, backfillComplete)
                            VALUES (?, ?, ?, ?, ?, ?, ?, ?)
                            """,
                        arguments: [f.id, f.accountId, f.name, f.path, f.role, f.unread, f.total, true]
                    )
                }

                // --- Messages ---
                let inboxFolderId = "\(accountId):INBOX"
                let now = Date()

                struct DemoMessage {
                    let messageId: String
                    let from: String
                    let fromAddress: String
                    let subject: String
                    let snippet: String
                    let minutesAgo: Int
                    let isRead: Bool
                    let hasAttachments: Bool
                    let actionTag: String?
                    let tagSortOrder: Int
                    let summaryBlurb: String?
                    let summaryTodos: String?
                    let reminderContent: String?
                    let cachedReply: String?
                }

                let messages: [DemoMessage] = [
                    DemoMessage(
                        messageId: "msg001",
                        from: "Sarah Chen",
                        fromAddress: "sarah.chen@company.com",
                        subject: "Q1 Budget Review — Action Needed",
                        snippet: "Hi Alex, please review the attached Q1 budget and confirm the allocations by Friday...",
                        minutesAgo: 12,
                        isRead: false,
                        hasAttachments: true,
                        actionTag: "reply",
                        tagSortOrder: 0,
                        summaryBlurb: "Sarah needs you to review and confirm Q1 budget allocations. Two items flagged: marketing spend is 15% over projection, and the engineering headcount line needs your sign-off.",
                        summaryTodos: "- Review Q1 budget spreadsheet\n- Confirm marketing allocation adjustment\n- Sign off on engineering headcount",
                        reminderContent: "Respond to Sarah about Q1 budget by Friday",
                        cachedReply: "Hi Sarah,\n\nThanks for sending this over. I've reviewed the Q1 budget — the marketing adjustment looks reasonable given the campaign results. I'll sign off on the engineering headcount today.\n\nBest,\nAlex"
                    ),
                    DemoMessage(
                        messageId: "msg002",
                        from: "CodeHub",
                        fromAddress: "notifications@codehub.example",
                        subject: "[tabmail/backend] PR #247: Refactor auth middleware",
                        snippet: "david-kim requested your review on pull request #247...",
                        minutesAgo: 35,
                        isRead: false,
                        hasAttachments: false,
                        actionTag: "reply",
                        tagSortOrder: 0,
                        summaryBlurb: "David Kim requested your review on PR #247 which refactors the auth middleware to use JWT validation instead of session cookies. 12 files changed, adds rate limiting.",
                        summaryTodos: "- Review PR #247 on CodeHub",
                        reminderContent: nil,
                        cachedReply: "Looks good overall — left a few comments on the rate limiting config. Let's discuss the JWT expiry window in standup."
                    ),
                    DemoMessage(
                        messageId: "msg003",
                        from: "SkyJet Airways",
                        fromAddress: "confirmations@skyjet.example",
                        subject: "Flight Confirmation: SFO → JFK, Mar 22",
                        snippet: "Your upcoming flight SJ 2847 is confirmed. Departure: 8:15 AM PDT...",
                        minutesAgo: 120,
                        isRead: true,
                        hasAttachments: false,
                        actionTag: "archive",
                        tagSortOrder: 2,
                        summaryBlurb: "Flight SJ 2847 confirmed for March 22. Departs SFO 8:15 AM, arrives JFK 4:52 PM. Seat 14A (window). Check-in opens 24 hours before departure.",
                        summaryTodos: nil,
                        reminderContent: "Check in for SkyJet flight on March 21",
                        cachedReply: ""
                    ),
                    DemoMessage(
                        messageId: "msg004",
                        from: "David Kim",
                        fromAddress: "david.kim@company.com",
                        subject: "Weekly Team Update — Mar 16",
                        snippet: "Here's the weekly roundup. Highlights: shipped v2.3, onboarded 2 new clients...",
                        minutesAgo: 180,
                        isRead: false,
                        hasAttachments: false,
                        actionTag: "archive",
                        tagSortOrder: 2,
                        summaryBlurb: "Weekly team update: v2.3 shipped successfully, 2 new enterprise clients onboarded, sprint velocity up 12%. Next week: focus on mobile performance and the Q2 planning offsite.",
                        summaryTodos: nil,
                        reminderContent: nil,
                        cachedReply: ""
                    ),
                    DemoMessage(
                        messageId: "msg005",
                        from: "PayFlow",
                        fromAddress: "receipts@payflow.example",
                        subject: "Payment Receipt — Invoice #8834",
                        snippet: "Payment of $149.00 successfully processed for your Pro plan subscription...",
                        minutesAgo: 300,
                        isRead: true,
                        hasAttachments: false,
                        actionTag: "delete",
                        tagSortOrder: 3,
                        summaryBlurb: "Monthly Pro plan payment of $149.00 processed. Next billing date: April 16, 2026.",
                        summaryTodos: nil,
                        reminderContent: nil,
                        cachedReply: ""
                    ),
                    DemoMessage(
                        messageId: "msg006",
                        from: "Lisa Park",
                        fromAddress: "lisa.park@company.com",
                        subject: "Design Review: New Onboarding Flow",
                        snippet: "Hey Alex, I've attached the updated mockups for the onboarding redesign...",
                        minutesAgo: 420,
                        isRead: true,
                        hasAttachments: true,
                        actionTag: "reply",
                        tagSortOrder: 0,
                        summaryBlurb: "Lisa shared updated onboarding mockups with three variants. She's asking for your preference between the guided tour vs. progressive disclosure approaches before the design freeze on Wednesday.",
                        summaryTodos: "- Review onboarding mockups\n- Pick preferred variant by Wednesday",
                        reminderContent: "Give Lisa feedback on onboarding designs by Wednesday",
                        cachedReply: "Hi Lisa,\n\nGreat work on these! I prefer variant B (progressive disclosure) — it feels less heavy for new users. One small note: can we add a skip option on the first screen?\n\nLet's sync tomorrow to finalize.\n\nAlex"
                    ),
                    DemoMessage(
                        messageId: "msg007",
                        from: "Connectly",
                        fromAddress: "notifications@connectly.example",
                        subject: "5 people viewed your profile this week",
                        snippet: "Your profile was viewed by engineers at several companies...",
                        minutesAgo: 600,
                        isRead: true,
                        hasAttachments: false,
                        actionTag: "delete",
                        tagSortOrder: 3,
                        summaryBlurb: "Weekly Connectly profile views summary. No action needed.",
                        summaryTodos: nil,
                        reminderContent: nil,
                        cachedReply: ""
                    ),
                    DemoMessage(
                        messageId: "msg008",
                        from: "Emily Torres",
                        fromAddress: "emily.torres@client.com",
                        subject: "Re: Partnership Proposal — Next Steps",
                        snippet: "Thanks for the detailed proposal, Alex. Our team has reviewed it and we'd like to...",
                        minutesAgo: 45,
                        isRead: false,
                        hasAttachments: false,
                        actionTag: "reply",
                        tagSortOrder: 0,
                        summaryBlurb: "Emily's team reviewed your partnership proposal and wants to move forward. They're proposing a pilot program starting in April with 3 of their enterprise accounts. Asking for a call this week to discuss terms.",
                        summaryTodos: "- Schedule call with Emily this week\n- Prepare pilot program terms",
                        reminderContent: "Schedule partnership call with Emily Torres",
                        cachedReply: "Hi Emily,\n\nThat's great news! A pilot with 3 accounts sounds like the right scope to start. I'm free Thursday 2-4pm or Friday morning — would either work for a 30-minute call to go over the terms?\n\nLooking forward to it,\nAlex"
                    ),
                ]

                for msg in messages {
                    let headerId = "\(accountId):INBOX:\(msg.messageId)"
                    let msgDate = now.addingTimeInterval(-Double(msg.minutesAgo * 60))

                    try db.execute(
                        sql: """
                            INSERT INTO messageHeader (
                                id, folderId, accountId, folderPath, isInInbox,
                                messageId, subject, "from", fromAddress, "to",
                                date, snippet, isRead, isFlagged, hasAttachments,
                                actionTag, tagSortOrder,
                                summaryBlurb, summaryTodos, reminderContent, cachedReply
                            ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
                            """,
                        arguments: [
                            headerId, inboxFolderId, accountId, "INBOX", true,
                            msg.messageId, msg.subject, msg.from, msg.fromAddress, "alex@tabmail.ai",
                            msgDate, msg.snippet, msg.isRead, false, msg.hasAttachments,
                            msg.actionTag, msg.tagSortOrder,
                            msg.summaryBlurb, msg.summaryTodos, msg.reminderContent, msg.cachedReply
                        ]
                    )

                    // Add body for the first message (for detail view screenshot)
                    if msg.messageId == "msg001" {
                        try db.execute(
                            sql: """
                                INSERT INTO messageBody (id, htmlContent, fetchedAt)
                                VALUES (?, ?, ?)
                                """,
                            arguments: [
                                headerId,
                                """
                                <div style="font-family: -apple-system, system-ui; font-size: 16px; line-height: 1.5; color: #1a1a1a;">
                                <p>Hi Alex,</p>
                                <p>Please review the attached Q1 budget and confirm the allocations by Friday. Two items I wanted to flag:</p>
                                <ol>
                                <li><strong>Marketing spend</strong> is currently 15% over our initial projection, driven by the expanded social campaign. I think it's justified given the results, but need your sign-off.</li>
                                <li><strong>Engineering headcount</strong> — we have budget for 2 additional hires in Q2. The req is ready to go once you approve the line item.</li>
                                </ol>
                                <p>Let me know if you have any questions. Happy to jump on a quick call if easier.</p>
                                <p>Thanks,<br>Sarah</p>
                                </div>
                                """,
                                Date()
                            ]
                        )
                    }
                }

                // Chat turns are pre-populated in-memory via seedChatSessionsIfNeeded()
                // (NOT in GRDB — GRDB chatTurns create session history pages that land
                // on the "__new__" placeholder, hiding the pre-populated messages).
            }
            print("[ScreenshotMode] Demo data seeded successfully")
        } catch {
            print("[ScreenshotMode] Failed to seed demo data: \(error)")
        }

    }

    /// Pre-populate chat sessions with demo conversations for screenshots.
    /// Must be called from @MainActor context (ChatPillState is @MainActor).
    @MainActor static func seedChatSessionsIfNeeded() {
        guard isActive else { return }

        // Inbox chat: calendar scheduling conversation with FSM tool visuals
        let now = Date()
        let cal = Calendar(identifier: .gregorian)
        let thursdayComponents = DateComponents(year: 2026, month: 3, day: 19, hour: 14, minute: 0)
        let thursdayStart = cal.date(from: thursdayComponents)!
        let thursdayEnd30 = thursdayStart.addingTimeInterval(30 * 60)
        let thursdayEnd45 = thursdayStart.addingTimeInterval(45 * 60)

        // First message: user request
        let msg1 = ChatMessage(role: .user, content: "Schedule a call with Emily Torres this week to discuss the partnership pilot", timestamp: now.addingTimeInterval(-300))

        // Second message: agent proposes calendar event (ActionConfirmation card, accepted)
        let createConfirmation = AgentToolRouter.ActionConfirmation(
            action: .calendarEventCreate,
            emails: [],
            contacts: [],
            calendarEvents: [
                AgentToolRouter.ActionConfirmation.CalendarEventDetail(
                    eventId: "screenshot-event-1",
                    calendarId: "primary",
                    title: "Partnership Pilot Discussion",
                    startDate: thursdayStart,
                    endDate: thursdayEnd30,
                    isAllDay: false,
                    attendees: ["emily.torres@client.com"]
                )
            ],
            templates: [],
            onRespond: { _ in }
        )
        createConfirmation.responseState.responded = true
        createConfirmation.responseState.accepted = true
        var msg2 = ChatMessage(role: .agent, content: "I found Emily's email — she's free Thursday 2-4pm. Here's a 30-minute call:", timestamp: now.addingTimeInterval(-295))
        msg2.actionConfirmation = createConfirmation

        // Third message: user asks to modify
        let msg3 = ChatMessage(role: .user, content: "Make it 45 minutes and add a note about preparing the pilot terms", timestamp: now.addingTimeInterval(-270))

        // Fourth message: agent shows updated event (ActionConfirmation card, accepted)
        let editConfirmation = AgentToolRouter.ActionConfirmation(
            action: .calendarEventEdit,
            emails: [],
            contacts: [],
            calendarEvents: [
                AgentToolRouter.ActionConfirmation.CalendarEventDetail(
                    eventId: "screenshot-event-1",
                    calendarId: "primary",
                    title: "Partnership Pilot Discussion",
                    startDate: thursdayStart,
                    endDate: thursdayEnd45,
                    isAllDay: false,
                    changes: ["duration: 30 min → 45 min", "notes: Prepare pilot program terms for 3 enterprise accounts"],
                    attendees: ["emily.torres@client.com"]
                )
            ],
            templates: [],
            onRespond: { _ in }
        )
        editConfirmation.responseState.responded = true
        editConfirmation.responseState.accepted = true
        var msg4 = ChatMessage(role: .agent, content: "Updated and sent to Emily:", timestamp: now.addingTimeInterval(-265))
        msg4.actionConfirmation = editConfirmation

        // Fifth message: agent follow-up after create
        let msg2b = ChatMessage(role: .agent, content: "I've created the event and sent a calendar invite to Emily. She'll get a video call link automatically.", timestamp: now.addingTimeInterval(-290))

        // Sixth message: agent follow-up after edit
        let msg4b = ChatMessage(role: .agent, content: "Done — updated to 45 minutes with the prep note. Emily will get the updated invite. I also set a reminder for you Wednesday evening to prepare the pilot terms.", timestamp: now.addingTimeInterval(-260))

        let inboxSession = ChatPillState.shared.session(for: "inbox")
        inboxSession.chatMessages = [msg1, msg2, msg2b, msg3, msg4, msg4b]
        inboxSession.lastChatActivity = Date()

        // Detail chat: contextual discussion about the Q1 Budget Review email (msg001)
        // Session key = "msg:\(accountId):\(stableId)" where stableId = messageId for non-UID IDs
        let detailSession = ChatPillState.shared.session(for: "msg:screenshot-account:msg001")
        detailSession.chatMessages = [
            ChatMessage(role: .user, content: "Is the 15% marketing overspend normal for our industry?", timestamp: now.addingTimeInterval(-200)),
            ChatMessage(role: .agent, content: "Based on Sarah's email, marketing spend is 15% over projection due to an expanded social campaign.\n\nI searched for benchmarks — **SaaS companies typically budget 10-20% of revenue on marketing** (industry benchmark surveys). A 15% overshoot within an already allocated budget is within normal range, especially if the campaign ROI justifies it.\n\nSarah mentioned the results look good — you could approve and ask for a post-campaign ROI report.", timestamp: now.addingTimeInterval(-195)),
            ChatMessage(role: .user, content: "Good point. Draft a reply approving both the marketing spend and the 2 engineering hires", timestamp: now.addingTimeInterval(-170)),
            ChatMessage(role: .agent, content: "I've drafted a reply approving both items. You can review it by tapping Reply below — I've pre-filled it with your approval for the marketing allocation and sign-off on the Q2 engineering headcount.", timestamp: now.addingTimeInterval(-165)),
        ]
        detailSession.lastChatActivity = Date()

        // Compose chat: inline edit conversation.
        //
        // 🚨 R16-11 — A THIRD UNPORTED CONSUMER OF THE COMPOSE SESSION-KEY FORMAT.
        // This built the key by hand as `"compose:reply:screenshot-account:msg001"`,
        // and the comment above it asserted that bare shape as current. PORT
        // `3f2cc4c34` changed the format to `compose:<epochByteCount>:<epoch><draftId>`
        // and moved it behind `ActiveAgentTracker.composeSessionKey`, whose namespace
        // `ChatPillState.session(for:)` shares — `DynamicIslandChatButton.sessionKey`
        // and `ComposeView` both mint their `ChatPillState` key through that symbol.
        // R15-FIX-4b ported ONE of the two known consumers (`InboxView`'s
        // `.composeDraft` decode); this is a third that neither that fix nor its
        // review enumerated, because both greps were for the SYMBOL and this site
        // spells only the FORMAT. `MIS-018`: the unit of a port is the CONTRACT — so
        // the key is minted through the symbol here too, and cannot drift again.
        //
        // ⚠️ NEGATIVE CASE, stated because minting through the symbol makes this look
        // solved and it is not: this fixture still cannot BIND to a live compose
        // session. The epoch half of the key is minted at runtime by
        // `ComposeGenerationCursor`, so no fixture can predict it, and no screenshot
        // flow opens compose against a seeded epoch today. The seeded session is
        // retained as the content source for that flow if it is ever added; what R16
        // fixed is the false format claim and the hand-rolled key, not the binding.
        // ⚠️ Do NOT "fix" the binding by weakening `composeSessionKey` to accept a
        // fixture-supplied bare key — the length prefix is what makes the encoding
        // injective when a draft id or an epoch contains a colon (both can), and both
        // `DraftOptimisticSaveTests` round-trip suites anchor that.
        //
        // `ComposeView.onAppear` overrides draftId via `Draft.draftKey` — for a reply
        // to msg001 the draft id is `reply:screenshot-account:msg001`.
        let composeSession = ChatPillState.shared.session(for: Self.seededComposeSessionKey)
        composeSession.chatMessages = [
            ChatMessage(role: .user, content: "Make the tone more casual and suggest grabbing coffee Thursday to discuss", timestamp: now.addingTimeInterval(-120)),
            ChatMessage(role: .agent, content: "Done! I made the tone friendlier and suggested meeting over coffee Thursday afternoon.", timestamp: now.addingTimeInterval(-115)),
            ChatMessage(role: .user, content: "Find a good coffee shop near our office on Market St for the meeting", timestamp: now.addingTimeInterval(-90)),
            ChatMessage(role: .agent, content: "I searched nearby — **Corner Roasters** at 100 Market St is a 3-minute walk from your office. Great for a work chat. I've added it to the email: *\"Let's grab coffee at Corner Roasters on Market St, Thursday around 2pm?\"*", timestamp: now.addingTimeInterval(-85)),
            ChatMessage(role: .user, content: "Perfect, also add a line thanking her team for the detailed breakdown", timestamp: now.addingTimeInterval(-60)),
            ChatMessage(role: .agent, content: "Added! The reply now thanks Sarah's team for the thorough breakdown before your approval.", timestamp: now.addingTimeInterval(-55)),
        ]
        composeSession.lastChatActivity = Date()
        composeSession.editHistory = [
            InlineEditTurn(
                userRequest: "Make the tone more casual and suggest grabbing coffee Thursday to discuss",
                bodyAtRequest: "Hi Sarah,\n\nThanks for sending this over. I've reviewed the Q1 budget — the marketing adjustment looks reasonable given the campaign results. I'll sign off on the engineering headcount today.\n\nBest,\nAlex",
                subjectAtRequest: "Re: Q1 Budget Review — Action Needed",
                assistantResponse: "Done! I made the tone friendlier and suggested meeting over coffee Thursday afternoon."
            ),
            InlineEditTurn(
                userRequest: "Find a good coffee shop near our office on Market St for the meeting",
                bodyAtRequest: "",
                subjectAtRequest: "Re: Q1 Budget Review — Action Needed",
                assistantResponse: "I searched nearby — Corner Roasters at 100 Market St is a 3-minute walk from your office. I've added it to the email."
            ),
            InlineEditTurn(
                userRequest: "Perfect, also add a line thanking her team for the detailed breakdown",
                bodyAtRequest: "",
                subjectAtRequest: "Re: Q1 Budget Review — Action Needed",
                assistantResponse: "Added! The reply now thanks Sarah's team for the thorough breakdown before your approval."
            ),
        ]
    }
}
