/* This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at https://mozilla.org/MPL/2.0/. */

#if DEBUG
import SwiftUI
import GRDB

private struct DraftOpenResolverTestKey: EnvironmentKey {
    static let defaultValue: (@MainActor @Sendable () async throws -> LocallyAuthoredDraftOpenAuthority?)? = nil
}

extension EnvironmentValues {
    var draftOpenResolverForTesting: (@MainActor @Sendable () async throws -> LocallyAuthoredDraftOpenAuthority?)? {
        get { self[DraftOpenResolverTestKey.self] }
        set { self[DraftOpenResolverTestKey.self] = newValue }
    }
}

/// Disposable fixture data and input events only. MailNavigationView and InboxView
/// own every presentation, including the actual Drafts-row full-screen cover.
struct ServerDraftCloseTestScene: View {
    @State private var navigationStore = NavigationStore()
    @State private var ready = false
    @State private var status = "Preparing fixture"
    @State private var attempts = 0
    private static let accountID = "draft-close-fixture"
    private static let row = StagedInboxRow(
        accountId: accountID, folderPath: "Drafts", messageId: "1",
        rfc822MessageId: "<draft@example.com>", threadId: nil, inReplyTo: nil, references: [],
        subject: "Draft close fixture", senderName: "Sender", senderAddress: "sender@example.com",
        to: "recipient@example.com", snippet: "Draft close fixture", date: Date(),
        isRead: true, isFlagged: false, hasAttachments: false, isReplied: false,
        isForwarded: false, actionTag: nil, summaryBlurb: nil)

    var body: some View {
        Group {
            if ready {
                MailNavigationView(initialSelection: .unified(.drafts))
                    .environment(navigationStore)
                    .environment(\.draftOpenResolverForTesting, {
                        attempts += 1
                        // #309: the first open (a Drafts-row tap) is still preparing when a
                        // newer one (a pushed draft) starts and fails; the first then ends.
                        if Self.orderingFixture {
                            if attempts == 1 {
                                try await Task.sleep(for: .seconds(Self.orderingHoldSeconds))
                                return nil
                            }
                            throw FixtureReadFailure()
                        }
                        if Self.detailReadyFixture { return Self.detailAuthority }
                        if ProcessInfo.processInfo.arguments.contains("--draft-close-failure") {
                            throw FixtureReadFailure()
                        }
                        // The refusal a draft holding an attachment TabMail cannot
                        // carry gets (#241): final, so no Retry, but it still closes.
                        if ProcessInfo.processInfo.arguments.contains("--draft-close-unsupported") {
                            throw DraftCopyUnsupportedAttachment()
                        }
                        return nil
                    })
                    // The refused-deletion notice (#147) extends into the bottom
                    // safe area, exactly where a bottom control bar would sit on
                    // top of it and swallow the dismissing tap — so the refused
                    // fixture keeps the bar at the top.
                    .safeAreaInset(edge: ProcessInfo.processInfo.arguments.contains("--draft-delete-ui-test")
                                   && !Self.refusedFixture ? .bottom : .top) {
                        VStack {
                            HStack {
                                Button("Open push") {
                                    NotificationCenter.default.post(name: .emailPillTapped, object: nil,
                                        userInfo: ["realId": Self.orderingFixture ? Self.newerHeaderId : Self.row.headerId])
                                }
                                Button("Open detail") {
                                    NSEDataBridge.latestStagedRows.withLock { $0 = [Self.row] }
                                    NotificationCenter.default.post(name: .proactiveNotificationTapped, object: nil,
                                        userInfo: ["messageId": Self.row.messageId, "accountId": Self.accountID])
                                }
                                Button("Check rows") { checkRows() }
                            }
                            if Self.orderingFixture {
                                // The chat's "TabMail Account" button (`WarningBubble`).
                                Button("Open account") { NotificationCenter.default.post(name: .navigateToAccount, object: nil) }
                            }
                            if Self.orderingFixture && ProcessInfo.processInfo.arguments.contains("--draft-open-navigation") {
                                // A received message, from a chat's email pill and from its notification, and
                                // Settings (its own flag: a wider bar covers the list's triage button).
                                HStack {
                                    Button("Open message") {
                                        NotificationCenter.default.post(name: .emailPillTapped, object: nil,
                                            userInfo: ["realId": Self.inboxRow.headerId])
                                    }
                                    Button("Open notification") {
                                        NSEDataBridge.latestStagedRows.withLock { $0 = [Self.inboxRow] }
                                        NotificationCenter.default.post(name: .proactiveNotificationTapped, object: nil,
                                            userInfo: ["messageId": Self.inboxRow.messageId, "accountId": Self.accountID])
                                    }
                                    Button("Open settings") { NotificationCenter.default.post(name: .navigateToSettings, object: nil) }
                                }
                            }
                            if Self.agentFixture {
                                // A compose agent working on, then finishing, a saved draft.
                                HStack {
                                    Button("Agent working") { ActiveAgentTracker.shared.setWorking(Self.agentSessionKey) }
                                    Button("Agent finished") {
                                        ActiveAgentTracker.shared.setPendingResponse(Self.agentSessionKey, text: "Agent draft ready")
                                        ActiveAgentTracker.shared.clearWorking(Self.agentSessionKey)
                                    }
                                }
                            }
                            Text("Resolution attempts: \(attempts)")
                            Text(status)
                        }
                        .font(.caption)
                        .padding(8)
                        .background(Color(.systemBackground))
                    }
            } else {
                Text(status)
            }
        }
        .background(Color(.systemBackground))
        .task {
            do {
                let accountID = Self.accountID
                let fixtureRow = Self.row
                let orderingFixture = Self.orderingFixture
                let agentDraft = Self.agentFixture ? Self.agentDraft()
                    : Self.detailReadyFixture ? Self.detailDraft() : nil
                let newerHeaderId = Self.newerHeaderId
                let inboxRow = Self.inboxRow
                let deleteFixture = ProcessInfo.processInfo.arguments.contains("--draft-delete-ui-test")
                let deleteRows = deleteFixture ? Self.deleteRows(
                    thread: ProcessInfo.processInfo.arguments.contains("--draft-delete-thread"),
                    refused: Self.refusedFixture) : []
                try await AppDatabase.dbPool.write { db in
                    // Each launch owns only this synthetic account's fixture rows.
                    try Draft.filter(Column("accountId") == accountID).deleteAll(db)
                    try MessageHeader.filter(Column("accountId") == accountID).deleteAll(db)
                    var account = Account(emailAddress: "sender@example.com", displayName: "Draft fixture", provider: .imap)
                    account.id = accountID
                    try account.save(db)
                    for role in [FolderRole.drafts, .inbox] {
                        let path = role == .drafts ? "Drafts" : "INBOX"
                        var folder = Folder(name: path, path: path, role: role, accountId: accountID)
                        folder.totalCount = role == .drafts ? 1 : 0
                        try folder.save(db)
                    }
                    if deleteFixture {
                        for (draft, header) in deleteRows {
                            try draft.save(db)
                            try header.save(db)
                        }
                    } else {
                        var header = fixtureRow.toMessageHeader()
                        header.isInInbox = false
                        try header.save(db)
                        if orderingFixture {
                            var newer = header
                            newer.messageId = "2"
                            newer.id = newerHeaderId
                            newer.subject = "Newer draft"
                            newer.rfc822MessageId = "<newer-draft@example.com>"
                            try newer.save(db)
                            try inboxRow.toMessageHeader().save(db)
                        }
                        try agentDraft?.save(db)
                    }
                }
                if Self.detailReadyFixture {
                    // The open re-checks the authority against the account's runtime.
                    await AccountManager.shared.registerProviderForTesting(
                        accountId: accountID, provider: DemoProvider(accountId: accountID))
                }
                await navigationStore.refresh()
                status = "Fixture ready"
                ready = true
            } catch {
                status = "Fixture setup failed"
            }
        }
    }

    /// `--draft-delete-refused` keys every Drafts header on a STALE epoch, so
    /// `InboxViewModel.deleteDraftMessage` finds no placeholder match for the
    /// draft's current epoch and fails closed (#147). This is the real-world
    /// shape a reopened draft leaves behind, not an invented one.
    private static var orderingFixture: Bool {
        ProcessInfo.processInfo.arguments.contains("--draft-open-ordering")
    }

    /// Long enough for the newer open (a pushed draft, or a new compose opened and
    /// closed) to start and finish first.
    private static let orderingHoldSeconds = 12
    private static let newerHeaderId = MessageIdentity.headerId(accountId: accountID, folderPath: "Drafts", messageId: "2")
    /// The ordering fixture's received message, left with Back while a draft is prepared.
    private static let inboxRow = StagedInboxRow(
        accountId: accountID, folderPath: "INBOX", messageId: "3",
        rfc822MessageId: "<received@example.com>", threadId: nil, inReplyTo: nil, references: [],
        subject: "Received fixture", senderName: "Sender", senderAddress: "sender@example.com",
        to: "recipient@example.com", snippet: "Received fixture", date: Date(),
        isRead: true, isFlagged: false, hasAttachments: false, isReplied: false,
        isForwarded: false, actionTag: nil, summaryBlurb: nil)

    private static var agentFixture: Bool {
        ProcessInfo.processInfo.arguments.contains("--draft-open-agent")
    }

    private static let agentDraftID = "agent-working-draft"
    private static let agentEpoch = "agent-fixture-generation"
    private static let agentSessionKey = ActiveAgentTracker.composeSessionKey(draftId: agentDraftID, epoch: agentEpoch)

    /// The saved draft the fixture's compose agent works on.
    private static func agentDraft() -> Draft {
        let now = Date().timeIntervalSince1970
        var draft = Draft(id: agentDraftID, accountId: accountID,
            toJSON: Draft.encodeStringArray(["agent-to@example.com"]),
            ccJSON: Draft.encodeStringArray([]), bccJSON: Draft.encodeStringArray([]),
            subject: "Agent working draft", body: "Agent written body", replyToId: nil,
            isForward: false, editHistoryJSON: nil, createdAt: now, updatedAt: now,
            serverDraftId: nil, serverPushStatus: nil, rfc822MessageId: nil, attachmentsDirName: nil)
        draft.instanceEpoch = agentEpoch
        return draft
    }

    /// The detail column opens a saved draft the header names (#309): the
    /// resolver authorizes the fixture's row, which then opens filled.
    private static var detailReadyFixture: Bool {
        ProcessInfo.processInfo.arguments.contains("--draft-open-detail-ready")
    }

    private static let detailDraftID = "detail-ready-draft"
    private static let detailEpoch = "detail-fixture-generation"
    private static let detailAuthority = LocallyAuthoredDraftOpenAuthority(
        draftId: detailDraftID, accountId: accountID, instanceEpoch: detailEpoch, serverPushStatus: nil,
        runtimeKind: .demo,
        address: .placeholder(messageId: PendingOperation.draftPlaceholderMessageId(
            draftId: detailDraftID, instanceEpoch: detailEpoch)))

    private static func detailDraft() -> Draft {
        let now = Date().timeIntervalSince1970
        var draft = Draft(id: detailDraftID, accountId: accountID,
            toJSON: Draft.encodeStringArray(["detail-to@example.com"]),
            ccJSON: Draft.encodeStringArray([]), bccJSON: Draft.encodeStringArray([]),
            subject: "Detail ready draft", body: "Detail ready body", replyToId: nil,
            isForward: false, editHistoryJSON: nil, createdAt: now, updatedAt: now,
            serverDraftId: nil, serverPushStatus: nil, rfc822MessageId: nil, attachmentsDirName: nil)
        draft.instanceEpoch = detailEpoch
        return draft
    }

    private static var refusedFixture: Bool {
        ProcessInfo.processInfo.arguments.contains("--draft-delete-refused")
    }

    private static func headerEpoch(draftId: String, current: String?, refused: Bool) -> String? {
        refused ? "stale-\(draftId)" : current
    }

    private static func deleteRows(thread: Bool, refused: Bool) -> [(Draft, MessageHeader)] {
        let ids = thread ? ["target", "child", "bystander"] : ["target", "bystander"]
        return ids.enumerated().map { index, id in
            let date = Date().addingTimeInterval(Double(-60 * index))
            let subject = id == "target" ? "Draft close fixture" : "Draft \(id)"
            var draft = Draft(
                id: id, accountId: accountID, toJSON: "[]", ccJSON: "[]", bccJSON: "[]",
                subject: subject, body: "Authored \(id)", replyToId: nil,
                isForward: false, editHistoryJSON: nil,
                createdAt: date.timeIntervalSince1970, updatedAt: date.timeIntervalSince1970,
                serverDraftId: nil, serverPushStatus: nil,
                rfc822MessageId: nil, attachmentsDirName: nil)
            draft.instanceEpoch = "generation-\(id)"
            var header = row.toMessageHeader()
            header.messageId = PendingOperation.draftPlaceholderMessageId(
                draftId: id, instanceEpoch: headerEpoch(
                    draftId: id, current: draft.instanceEpoch, refused: refused))
            header.id = "\(accountID):Drafts:\(header.messageId)"
            header.subject = subject
            header.snippet = "Authored \(id)"
            header.date = date
            header.rfc822MessageId = "\(id)@example.com"
            header.computedThreadId = thread && id != "bystander" ? "draft-thread" : id
            header.isInInbox = false
            return (draft, header)
        }
    }

    private func checkRows() {
        do {
            if ProcessInfo.processInfo.arguments.contains("--draft-delete-ui-test") {
                let result = try AppDatabase.dbPool.read { db in
                    let drafts = try Draft.filter(Column("accountId") == Self.accountID).fetchAll(db)
                    let headers = try MessageHeader.filter(Column("accountId") == Self.accountID).fetchAll(db)
                    let expectedHeaders = Set(drafts.map {
                        PendingOperation.draftPlaceholderHeaderPK(
                            accountId: Self.accountID, draftsFolderPath: "Drafts",
                            draftId: $0.id, instanceEpoch: Self.headerEpoch(
                                draftId: $0.id, current: $0.instanceEpoch,
                                refused: Self.refusedFixture))
                    })
                    let intact = Set(headers.map(\.id)) == expectedHeaders
                        && headers.allSatisfy { $0.folderPath == "Drafts" && !$0.isInInbox }
                        && drafts.allSatisfy { $0.body == "Authored \($0.id)" }
                    return intact ? "Remaining: \(drafts.map(\.id).sorted().joined(separator: ","))" : "Unexpected mutation"
                }
                status = result
                return
            }
            let preserved = try AppDatabase.dbPool.read { db in
                let header = try MessageHeader.fetchOne(db, key: Self.row.headerId)
                let draftCount = try Draft.filter(Column("accountId") == Self.accountID).fetchCount(db)
                let account = try Account.fetchOne(db, key: Self.accountID)
                return header?.folderId == Self.row.folderId
                    && header?.subject == Self.row.subject
                    && draftCount == 0 && account != nil
            }
            status = preserved ? "Rows preserved" : "Rows changed"
        } catch {
            status = "Row check failed"
        }
    }

    private struct FixtureReadFailure: Error {}
}
#endif
