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

/// One local folder the read is asked about, as it stood at the start of the
/// pass.
struct ChangeFolder: Sendable, Equatable {
    let id: String
    let path: String
    let role: FolderRole
    /// The folder's own bookmark (`Folder.changeCursor`), opaque and
    /// provider-owned, for a provider that reads changes folder by folder. Nil =
    /// none yet. The engine writes back what the reader returns in
    /// `FolderChanges.cursor`, in that folder's transaction.
    var cursor: String?
    /// The folder is in the full sync's syncable set
    /// (`SyncEngine.syncableFoldersInOrder`): a per-folder reader reads only these.
    var isSynced: Bool
    /// The start of the folder's held range (`Folder.oldestSyncedDate`). A hint
    /// only: the apply checks the range again inside the folder's transaction, so
    /// a stale value costs at most a wasted read.
    var heldSince: Date?

    init(id: String, path: String, role: FolderRole,
         cursor: String? = nil, isSynced: Bool = false, heldSince: Date? = nil) {
        self.id = id
        self.path = path
        self.role = role
        self.cursor = cursor
        self.isSynced = isSynced
        self.heldSince = heldSince
    }
}

/// What one read may spend and on what kind of network: a value snapshot taken
/// by the engine when the pass's turn starts (root rule: snapshot settings at
/// operation start). The reader never re-reads the network state itself.
struct ChangeContext: Sendable {
    /// No request may START at or after this instant. The engine sets it from
    /// the caller's own deadline, leaving room for one request to finish and for
    /// the apply (`SyncEngine.changeReadEnd`), so what a pass reads lands before
    /// the caller gives up on it.
    let deadline: Date
    /// The clock the budget is measured on; injectable for tests.
    let clock: @Sendable () -> Date
    /// `NetworkMonitor.checkExpensive()` (cellular or a hotspot) as it stood when
    /// the turn started.
    let isExpensiveNetwork: Bool
    /// The reader calls this with the number of messages it is about to fetch,
    /// so the engine can show "downloading N".
    let onProgress: @Sendable (Int) -> Void

    init(deadline: Date = .distantFuture, clock: @escaping @Sendable () -> Date = { Date() },
         isExpensiveNetwork: Bool = false, onProgress: @escaping @Sendable (Int) -> Void) {
        self.deadline = deadline
        self.clock = clock
        self.isExpensiveNetwork = isExpensiveNetwork
        self.onProgress = onProgress
    }

    /// Checked before EVERY request: false once the read budget is spent.
    func hasBudget() -> Bool { clock() < deadline }

    /// The read budget left, in seconds (never negative).
    var secondsLeft: TimeInterval { max(0, deadline.timeIntervalSince(clock())) }
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
    /// Which messages a folder holds: ids and the two flags, never content
    /// (ADR-004). A reader whose records may lack the header fields uses it to
    /// fetch headers only for messages the folder does not hold. Nil in a test
    /// that drives a reader with no store.
    var localRows: (any CatchUpLocalRowReader)?

    init(folders: [ChangeFolder], scope: ChangeScope, recheck: [String: [String]],
         context: ChangeContext, localRows: (any CatchUpLocalRowReader)? = nil) {
        self.folders = folders
        self.scope = scope
        self.recheck = recheck
        self.context = context
        self.localRows = localRows
    }
}

/// What the read did to the account's bookmark.
enum AccountCursorUpdate: Sendable, Equatable {
    /// Keep the stored bookmark (a failed read).
    case keep
    /// Store this bookmark once every folder's changes are applied.
    case set(String)
    /// The stored bookmark can no longer be read from; drop it.
    case clear
    /// A new bookmark read BEFORE any listing. The engine stores it after the
    /// foreground pass's listings; only the folders those listings finished
    /// become tracked.
    case candidate(String)
    /// The read completed and the stored account part needs no write (a provider
    /// whose bookmarks are per folder, on a pass with nothing to store there).
    case unchanged
}

enum ChangeRefusal: Sendable, Equatable {
    /// The provider no longer holds changes that old.
    case expired
    /// More changes than one pass takes on.
    case tooFarBehind
    /// The server refused the bookmark with this HTTP status.
    case rejected(Int)
    /// The folder's reads kept failing for longer than the provider waits
    /// before it starts the folder again.
    case failingTooLong
}

enum FolderChangeStatus: Sendable {
    /// Complete up to the new bookmark, or (a per-folder reader cut by its
    /// budget) up to the progress bookmark in `FolderChanges.cursor`.
    case tracked
    /// A per-folder reader is still reading the folder's first round (its
    /// baseline): the records are the folder's current messages, applied as a
    /// baseline (an insert only within the held range, never a removal), and
    /// the progress bookmark is in `FolderChanges.cursor`. The folder is not
    /// covered: the engine keeps it untracked.
    case baselining
    /// A candidate bookmark was read (or a per-folder baseline completed); the
    /// engine lists the folder, then commits.
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
        case .baselining, .refused, .failed, .notRun: return false
        }
    }

    /// The records come from a baseline: they are the folder's messages as they
    /// are, not changes, so the apply inserts only within the held range.
    var isBaseline: Bool {
        switch self {
        case .baselining, .baselineReady: return true
        case .tracked, .refused, .failed, .notRun: return false
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

    /// The record carries the message's read state AND its flag. Only such a
    /// record settles a message on the folder's re-read list
    /// (`FolderChangeState.recheck`): a change kept back there may be to either
    /// field, and a record without one says nothing about it, so the re-read
    /// reads the message in full. Only such a record inserts a message the
    /// folder does not hold; any other lists it for that re-read.
    var carriesReadAndFlag: Bool { isRead != nil && isFlagged != nil }
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
    /// The folder's new bookmark (`Folder.changeCursor`), written in the same
    /// transaction as its records, so a crash resumes from the last applied
    /// page. Nil = keep the stored one. A refusal clears it whatever this says.
    var cursor: String?

    init(folderId: String, status: FolderChangeStatus, addressEpoch: Int? = nil,
         records: [ChangeRecord] = [], removals: [String] = [], rereadLater: [String] = [],
         cursor: String? = nil) {
        self.folderId = folderId
        self.status = status
        self.addressEpoch = addressEpoch
        self.records = records
        self.removals = removals
        self.rereadLater = rereadLater
        self.cursor = cursor
    }
}

/// The folder list a read carries.
enum FolderListUpdate: Sendable {
    /// The provider's complete folder list: a stored folder not in it is gone.
    case complete([FolderInfo])
    /// Names and counts of folders already stored, matched by path. Never adds
    /// and never removes a folder; an empty list says "nothing changed".
    case updated([FolderInfo])

    var infos: [FolderInfo] {
        switch self {
        case .complete(let infos), .updated(let infos): return infos
        }
    }
}

struct ChangeSet: Sendable {
    var account: AccountCursorUpdate
    /// The folder list, read in the same pass. Nil = not read.
    var folderList: FolderListUpdate?
    var folders: [FolderChanges]
}

extension ChangeSet {
    /// Every requested folder with the same status and no changes.
    static func uniform(
        _ request: ChangeRequest, account: AccountCursorUpdate, status: FolderChangeStatus,
        folderList: FolderListUpdate? = nil
    ) -> ChangeSet {
        ChangeSet(
            account: account, folderList: folderList,
            folders: request.folders.map { FolderChanges(folderId: $0.id, status: status) })
    }
}

extension EmailProvider {
    /// Default: no change reader. IMAP keeps its own change path until its
    /// reader lands.
    func fetchChanges(since cursor: ChangeCursor, request: ChangeRequest) async throws -> ChangeSet? {
        nil
    }
}
