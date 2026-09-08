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
                    .safeAreaInset(edge: ProcessInfo.processInfo.arguments.contains("--draft-delete-ui-test") ? .bottom : .top) {
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
                let deleteRows = deleteFixture ? Self.deleteRows(
                    thread: ProcessInfo.processInfo.arguments.contains("--draft-delete-thread")) : []
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
                    }
                }
                await navigationStore.refresh()
                status = "Fixture ready"
                ready = true
            } catch {
                status = "Fixture setup failed"
            }
        }
    }

    private static func deleteRows(thread: Bool) -> [(Draft, MessageHeader)] {
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
                draftId: id, instanceEpoch: draft.instanceEpoch)
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
                            draftId: $0.id, instanceEpoch: $0.instanceEpoch)
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
