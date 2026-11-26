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
    /// A slice of an other-folder run (#1110, `SyncEngine.readOtherFolders`): the
    /// request names only the run's folders, outside the syncable set, in the
    /// order to read them. No folder list, no account part, no re-read list. A
    /// reader that reads folder by folder reads them in that order and reports a
    /// folder it sent nothing for (out of time, or its session ended before it)
    /// as `.notRun`, so the run reads it in a later slice, and a folder whose
    /// read it started and that did not move with `FolderChanges.readCut`
    /// (#1358). A provider whose
    /// changes come in one account-wide read reads nothing: every pass already
    /// reads every folder.
    case otherFolders
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
    /// The folder's changes are read: on a pass, a folder of the full sync's
    /// syncable set (`SyncEngine.syncableFoldersInOrder`); on an other-folder run
    /// (`ChangeScope.otherFolders`, #1110), every folder of the request. A
    /// per-folder reader reads changes only for these. A folder's re-read list
    /// (`ChangeRequest.recheck`) is read whatever this says.
    /// *Superseded (#1110):* "The folder is in the full sync's syncable set".
    var isSynced: Bool
    /// The start of the folder's held range (`Folder.oldestSyncedDate`). A hint
    /// only: the apply checks the range again inside the folder's transaction, so
    /// a stale value costs at most a wasted read.
    var heldSince: Date?
    /// The generation of the folder's id space as the device stores it
    /// (`Folder.lastKnownUidValidity`), nil when none is known. A reader whose ids
    /// carry a generation starts no bookmark for a folder that holds rows under an
    /// unknown one (IOS-EPOCH-001); the apply checks it again inside the folder's
    /// transaction.
    var addressEpoch: Int?
    /// How far the folder's older-mail download has come, as the device stores
    /// it (`Folder.backfillComplete`, `Folder.backfillUidCursor`): the range of
    /// ids the device holds the folder in, whatever rows it holds now. A reader
    /// with numeric ids takes the start of the held range from this, never from
    /// the rows: a removal moves the lowest row, and a message restored on the
    /// server later must still come back.
    var olderMailComplete: Bool
    /// The older-mail walk's position: it walks down from the top, so every id
    /// above this one has been downloaded. Nil = the walk has not started (or
    /// has completed, `olderMailComplete`).
    var olderMailCursor: Int?

    init(id: String, path: String, role: FolderRole,
         cursor: String? = nil, isSynced: Bool = false, heldSince: Date? = nil, addressEpoch: Int? = nil,
         olderMailComplete: Bool = false, olderMailCursor: Int? = nil) {
        self.id = id
        self.path = path
        self.role = role
        self.cursor = cursor
        self.isSynced = isSynced
        self.heldSince = heldSince
        self.addressEpoch = addressEpoch
        self.olderMailComplete = olderMailComplete
        self.olderMailCursor = olderMailCursor
    }
}

/// What one read may spend and on what kind of network: a value snapshot taken
/// by the engine when the pass's turn starts (root rule: snapshot settings at
/// operation start). The reader never re-reads the network state itself.
struct ChangeContext: Sendable {
    /// No new unit of reading may START at or after this instant: a request, or
    /// on Gmail a history page or record. Gmail finishes the reads of a record
    /// it has taken, and of the messages still queued, past it (ADR-IOS-111,
    /// #491). The engine sets it from the caller's own deadline, leaving room for
    /// one round of requests to finish and for the apply
    /// (`SyncEngine.changeReadEnd`), so what a pass reads lands before the
    /// caller gives up on it.
    let deadline: Date
    /// The clock the budget is measured on; injectable for tests.
    let clock: @Sendable () -> Date
    /// In a slice of an other-folder run (#1110), the slice's end. The read's
    /// FIRST folder is read in the slice's whole time: its requests start while
    /// the clock is before this instant (each bounded as usual, none after it),
    /// so a slow check of the session before it (IMAP's NOOP) cannot spend the
    /// read's share and leave the slice with no folder read. Every later folder
    /// starts only within `deadline`. Nil: every folder reads within `deadline`.
    let firstFolderDeadline: Date?
    /// The reader calls this with the number of messages it is about to fetch,
    /// so the engine can show "downloading N".
    let onProgress: @Sendable (Int) -> Void

    init(deadline: Date = .distantFuture, clock: @escaping @Sendable () -> Date = { Date() },
         firstFolderDeadline: Date? = nil, onProgress: @escaping @Sendable (Int) -> Void) {
        self.deadline = deadline
        self.clock = clock
        self.firstFolderDeadline = firstFolderDeadline
        self.onProgress = onProgress
    }

    /// Checked before every new unit of reading: false once the read budget is
    /// spent.
    func hasBudget() -> Bool { clock() < deadline }

    /// The read budget left, in seconds (never negative).
    var secondsLeft: TimeInterval { max(0, deadline.timeIntervalSince(clock())) }
}

/// Built ONCE at the start of a pass; nothing in it is re-read during the pass.
struct ChangeRequest: Sendable {
    /// Every local folder of the account; on an other-folder run
    /// (`ChangeScope.otherFolders`, #1110), the run's folders only, in the order
    /// to read them.
    let folders: [ChangeFolder]
    let scope: ChangeScope
    /// Folder id -> message ids a change was declined for under the user's own
    /// action on an earlier pass, or that an action retired at the release
    /// boundary named. The reader reads their current state again and reports
    /// them as ordinary records or removals, for every listed folder (synced or
    /// not; a per-folder reader on a `.all` pass), and the apply takes such a
    /// record whatever the folder's held range.
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

    /// This request with the time its first folder is read in
    /// (`ChangeContext.firstFolderDeadline`) as its deadline, or nil when it
    /// has none.
    func forFirstFolder() -> ChangeRequest? {
        guard let end = context.firstFolderDeadline else { return nil }
        return ChangeRequest(
            folders: folders, scope: scope, recheck: recheck,
            context: ChangeContext(deadline: end, clock: context.clock, onProgress: context.onProgress),
            localRows: localRows)
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
    /// The folder's id space was renumbered: the server now serves this
    /// generation (an IMAP UIDVALIDITY), not the one the bookmark was read in.
    /// Nothing read under it applies; the apply arms the folder's turnover
    /// reaction (ADR-IOS-061) in the same transaction.
    case addressEpochChanged(Int)
}

/// What a reader observed about a folder it cannot track (a server without
/// change tracking, or a mailbox that keeps none): the folder's counters as the
/// server reported them, so the engine can tell whether the folder changed and
/// list it.
struct UntrackedObservation: Sendable, Equatable {
    let messageCount: Int
    let uidNext: Int
    let highestModSeq: Int?
    /// Nil when the server did not report one.
    let uidValidity: Int?
    /// List this folder this pass whatever the counters say: the reader stopped
    /// a check it owes for want of budget (#755).
    var mustList = false
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
    /// The folder cannot be tracked by a bookmark: the engine lists it when the
    /// observation says it changed. Its coverage is cleared; a bookmark it holds
    /// is kept for the next read that can track it.
    case untracked(UntrackedObservation)

    var isTrackable: Bool {
        switch self {
        case .tracked, .baselineReady: return true
        case .baselining, .refused, .failed, .notRun, .untracked: return false
        }
    }

    /// The records come from a baseline: they are the folder's messages as they
    /// are, not changes, so the apply inserts only within the held range.
    var isBaseline: Bool {
        switch self {
        case .baselining, .baselineReady: return true
        case .tracked, .refused, .failed, .notRun, .untracked: return false
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
    /// The message's COMPLETE user-label set on the server (Gmail label ids,
    /// Graph category names), which replaces a stored row's set. Nil = not
    /// known this read (Graph left `categories` out, or Gmail's label catalog
    /// has not loaded), and then the stored set stays: an empty array is "no
    /// labels", never "unknown".
    var userLabelIds: [String]?
    var rfc822MessageId: String?
    var references: [String]?
    /// The server shows the message replied to / forwarded. Only true is news:
    /// the merge never clears a stored mark (the phone's own reply marks its
    /// parent before any server shows it, and Outlook keeps only the LAST verb,
    /// so a forward after a reply reads as "not replied").
    var isReplied = false
    var isForwarded = false

    /// A full record built from a fetched header. Its user labels are the
    /// message's whole set only when the header says so
    /// (`MessageHeaderInfo.userLabelIdsAreAuthoritative`); otherwise the record
    /// carries none and an insert takes the header's own list.
    init(header: MessageHeaderInfo) {
        self.messageId = header.messageId
        self.header = header
        self.isRead = header.isRead
        self.isFlagged = header.isFlagged
        self.serverTag = header.actionTag
        self.userLabelIds = header.userLabelIdsAreAuthoritative ? header.userLabelIds : nil
        self.rfc822MessageId = header.rfc822MessageId
        self.references = header.references
        self.isReplied = header.isReplied
        self.isForwarded = header.isForwarded
    }

    init(messageId: String) {
        self.messageId = messageId
    }

    /// The record carries the message's read state AND its flag. Only such a
    /// record inserts a message the folder does not hold; any other lists it for
    /// a re-read in full. (Settling the re-read list also needs the user labels:
    /// `carriesKeptBackFields`.)
    var carriesReadAndFlag: Bool { isRead != nil && isFlagged != nil }

    /// The record carries every field the apply keeps back under the user's own
    /// pending action: the read state, the flag and the user labels. Only such a
    /// record settles a message on the folder's re-read list; a record without
    /// one of them says nothing about a change kept back to it.
    var carriesKeptBackFields: Bool { carriesReadAndFlag && userLabelIds != nil }
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
    /// The folder's catch-up gets one whole-folder check, armed in the same
    /// transaction that stores this new bookmark (`SyncEngine.applyFolderChanges`):
    /// a bookmark that starts sees nothing older than itself (ADR-IOS-111),
    /// and once one is stored the catch-up runs no periodic check. Stored with
    /// the bookmark, so a pass with no listing, a failed listing or a crash
    /// before tracking starts never leaves the bookmark without its check.
    var armCatchUpWithBookmark = false
    /// A slice of an other-folder run (`ChangeScope.otherFolders`, #1110): the
    /// reader sent this folder a request, and the read ended before it moved
    /// the folder: the slice's read time ran out before the read could finish
    /// (`.notRun`, nothing of it to apply), or a baseline passed no page
    /// (`.baselining`: the held rows of the page it read apply, its place in
    /// the baseline stays). Kept apart from a folder the reader sent nothing
    /// for, and from a baseline that moved, so the run can count the folder as
    /// tried and go on to the next one (#1358). Never set on a pass.
    var readCut = false
    /// The folder's rows with numeric ids in `lowerId...upperId` the read
    /// checked: exactly `checkedIds` (bounded by the check's window). The apply
    /// reads the folder's held ids in that range again in its transaction; a
    /// held id the check never examined (a row that came meanwhile, even when
    /// another one left and the count is unchanged) keeps the stored bookmark.
    /// A checked row that left does not. Nil = nothing to verify.
    var heldRowsProof: HeldRowsProof?
    struct HeldRowsProof: Sendable, Equatable { let lowerId: Int; let upperId: Int; let checkedIds: Set<Int> }
    /// The same proof for the ids the new bookmark newly covers (an IMAP read's
    /// arrival range, the stored UIDNEXT up to the new one): the ids the read
    /// found on the server or held there when it looked. A row inserted in that
    /// range after the read looked (the notification merge, whose id the stored
    /// bookmark does not claim yet) was never checked, so the stored bookmark
    /// stays and the next read checks the row. Nil = nothing newly covered.
    var arrivalRowsProof: HeldRowsProof?
    /// Set by the engine, never by a reader: the folder bookmark the read was
    /// issued with. A bookmark dropped between the read and the apply
    /// (`SyncEngine.dropChangeBookmark`) is never written back. Nil = not
    /// checked.
    var readFrom: ReadFrom?
    struct ReadFrom: Sendable { let cursor: String? }

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
    /// Default: no change reader (Demo and test providers).
    func fetchChanges(since cursor: ChangeCursor, request: ChangeRequest) async throws -> ChangeSet? {
        nil
    }
}
