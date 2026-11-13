/* This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at https://mozilla.org/MPL/2.0/. */

import Foundation

// MARK: - Provider-neutral change reading (ADR-IOS-111)
//
// One read call per provider: `EmailProvider.fetchChanges(since:request:)`
// answers "what changed since this bookmark" as a `ChangeSet`. It only reads;
// it never touches the local database. The sync engine applies every ChangeSet
// with one apply that knows no provider (`SyncEngineChanges*.swift`).
//
// A provider without a reader returns `nil` (the default below); the engine then
// keeps that provider's remaining change path.

/// The bookmark a read starts from. Opaque, provider-owned strings.
struct ChangeCursor: Sendable, Equatable {
    /// The account part (`Account.lastHistoryId`). Nil = no bookmark yet.
    let account: String?
}

enum ChangeScope: Sendable, Equatable {
    /// A foreground pass: every folder, and the folder list.
    case all
    /// A push or background pass: no folder list. A provider whose changes come
    /// in one account-wide read may still report every folder.
    case inboxOnly
}

/// One local folder the read is asked about.
struct ChangeFolder: Sendable, Equatable {
    let id: String
    let path: String
    let role: FolderRole
}

struct ChangeContext: Sendable {
    /// The reader calls this with the number of messages it is about to fetch,
    /// so the engine can show "downloading N".
    let onProgress: @Sendable (Int) -> Void
}

/// Built ONCE at the start of a pass; nothing in it is re-read during the pass.
struct ChangeRequest: Sendable {
    /// Every local folder of the account.
    let folders: [ChangeFolder]
    let scope: ChangeScope
    /// Folder id -> message ids a change was declined for under the user's own
    /// action on an earlier pass. The reader reads their current state again and
    /// reports them as ordinary records or removals.
    let recheck: [String: [String]]
    let context: ChangeContext
}

/// What the read did to the account's bookmark.
enum AccountCursorUpdate: Sendable, Equatable {
    /// Keep the stored bookmark (a failed read).
    case keep
    /// Store this bookmark once every folder's changes are applied.
    case set(String)
    /// The stored bookmark can no longer be read from; drop it.
    case clear
    /// A new bookmark read BEFORE any listing. The engine stores it only after
    /// the folders marked `.baselineReady` have been listed in full.
    case candidate(String)
}

enum ChangeRefusal: Sendable, Equatable {
    /// The provider no longer holds changes that old.
    case expired
    /// More changes than one pass takes on.
    case tooFarBehind
}

enum FolderChangeStatus: Sendable {
    /// Complete up to the new bookmark.
    case tracked
    /// A candidate bookmark was read; the engine lists the folder, then commits.
    case baselineReady
    /// The bookmark was refused; the folder needs a listing and a new bookmark.
    case refused(ChangeRefusal)
    /// A transient failure; the records and removals so far still apply, the
    /// bookmark is kept.
    case failed(any Error)
    /// The read skipped this folder.
    case notRun

    var isTrackable: Bool {
        switch self {
        case .tracked, .baselineReady: return true
        case .refused, .failed, .notRun: return false
        }
    }
}

/// A message as the folder holds it now. PARTIAL: an absent field never
/// overwrites a stored value. `header` present = a full record, which may insert.
struct ChangeRecord: Sendable {
    let messageId: String
    var header: MessageHeaderInfo?
    var isRead: Bool?
    var isFlagged: Bool?
    var serverTag: ActionTag?
    var userLabelIds: [String]?
    var rfc822MessageId: String?
    var references: [String]?

    /// A full record built from a fetched header.
    init(header: MessageHeaderInfo) {
        self.messageId = header.messageId
        self.header = header
        self.isRead = header.isRead
        self.isFlagged = header.isFlagged
        self.serverTag = header.actionTag
        self.userLabelIds = header.userLabelIds
        self.rfc822MessageId = header.rfc822MessageId
        self.references = header.references
    }

    init(messageId: String) {
        self.messageId = messageId
    }
}

struct FolderChanges: Sendable {
    let folderId: String
    var status: FolderChangeStatus
    /// The generation of the folder's id space (an IMAP UIDVALIDITY). Nil = the
    /// ids are stable and unique in the account, so the user's pending action on
    /// the same id in ANY folder protects a row here.
    var addressEpoch: Int?
    /// Collapsed by message id.
    var records: [ChangeRecord]
    /// "This folder no longer holds that message."
    var removals: [String]
    /// Messages the provider could not read this pass because the server's
    /// answer for that ONE message was unusable. The engine puts them on the
    /// folder's re-read list, so one such message never holds back the rest of
    /// the pass or the bookmark. A failure about the account (connection,
    /// credentials) is `.failed`, never this.
    var rereadLater: [String]

    init(folderId: String, status: FolderChangeStatus, addressEpoch: Int? = nil,
         records: [ChangeRecord] = [], removals: [String] = [], rereadLater: [String] = []) {
        self.folderId = folderId
        self.status = status
        self.addressEpoch = addressEpoch
        self.records = records
        self.removals = removals
        self.rereadLater = rereadLater
    }
}

struct ChangeSet: Sendable {
    var account: AccountCursorUpdate
    /// The provider's complete folder list, read in the same pass. Nil = not read.
    var folderList: [FolderInfo]?
    var folders: [FolderChanges]
}

extension ChangeSet {
    /// Every requested folder with the same status and no changes.
    static func uniform(
        _ request: ChangeRequest, account: AccountCursorUpdate, status: FolderChangeStatus,
        folderList: [FolderInfo]? = nil
    ) -> ChangeSet {
        ChangeSet(
            account: account, folderList: folderList,
            folders: request.folders.map { FolderChanges(folderId: $0.id, status: status) })
    }
}

extension EmailProvider {
    /// Default: no change reader. Outlook and IMAP keep their own change paths
    /// until their readers land.
    func fetchChanges(since cursor: ChangeCursor, request: ChangeRequest) async throws -> ChangeSet? {
        nil
    }
}
