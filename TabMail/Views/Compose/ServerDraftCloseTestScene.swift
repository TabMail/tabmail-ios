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
                        if ProcessInfo.processInfo.arguments.contains("--draft-close-failure") {
                            throw FixtureReadFailure()
                        }
                        return nil
                    })
                    .safeAreaInset(edge: .top) {
                        VStack {
                            HStack {
                                Button("Open push") {
                                    NotificationCenter.default.post(name: .emailPillTapped, object: nil,
                                        userInfo: ["realId": Self.row.headerId])
                                }
                                Button("Open detail") {
                                    NSEDataBridge.latestStagedRows.withLock { $0 = [Self.row] }
                                    NotificationCenter.default.post(name: .proactiveNotificationTapped, object: nil,
                                        userInfo: ["messageId": Self.row.messageId, "accountId": Self.accountID])
                                }
                                Button("Check rows") { checkRows() }
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
                let deleteFixture = ProcessInfo.processInfo.arguments.contains("--draft-delete-ui-test")
                try await AppDatabase.dbPool.write { db in
                    var account = Account(emailAddress: "sender@example.com", displayName: "Draft fixture", provider: .imap)
                    account.id = accountID
                    try account.save(db)
                    for role in [FolderRole.drafts, .inbox] {
                        let path = role == .drafts ? "Drafts" : "INBOX"
                        var folder = Folder(name: path, path: path, role: role, accountId: accountID)
                        folder.totalCount = role == .drafts ? 1 : 0
                        try folder.save(db)
                    }
                    var header = fixtureRow.toMessageHeader()
                    if deleteFixture {
                        let now = Date().timeIntervalSince1970
                        var draft = Draft(
                            id: "swipe-delete-fixture", accountId: accountID,
                            toJSON: "[]", ccJSON: "[]", bccJSON: "[]",
                            subject: fixtureRow.subject, body: "Authored text", replyToId: nil,
                            isForward: false, editHistoryJSON: nil, createdAt: now, updatedAt: now,
                            serverDraftId: nil, serverPushStatus: nil,
                            rfc822MessageId: nil, attachmentsDirName: nil)
                        draft.instanceEpoch = "swipe-generation"
                        try draft.save(db)
                        header.messageId = PendingOperation.draftPlaceholderMessageId(
                            draftId: draft.id, instanceEpoch: draft.instanceEpoch)
                        header.id = "\(accountID):Drafts:\(header.messageId)"
                    }
                    header.isInInbox = false
                    try header.save(db)
                }
                await navigationStore.refresh()
                status = "Fixture ready"
                ready = true
            } catch {
                status = "Fixture setup failed"
            }
        }
    }

    private func checkRows() {
        do {
            if ProcessInfo.processInfo.arguments.contains("--draft-delete-ui-test") {
                let deleted = try AppDatabase.dbPool.read { db in
                    try Draft.filter(Column("accountId") == Self.accountID).fetchCount(db) == 0
                        && MessageHeader.filter(Column("accountId") == Self.accountID).fetchCount(db) == 0
                }
                status = deleted ? "Draft deleted" : "Draft remains"
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
