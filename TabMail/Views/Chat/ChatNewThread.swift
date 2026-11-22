/* This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at https://mozilla.org/MPL/2.0/. */

import Foundation
import GRDB
import UIKit
import UniformTypeIdentifiers

/// Where a new email opens: with the chat view on, as a chat (`ChatNewThreadView`); off, in
/// today's compose. Decided once, with the chat view setting read at the tap or the open.
enum ChatNewThreadRoute: Equatable {
    case newThread
    case compose

    /// The inbox compose button.
    static func composeButton(opensInChat: Bool) -> ChatNewThreadRoute {
        opensInChat ? .newThread : .compose
    }

    /// A saved draft: a new email started in the chat (`Draft.isNewEmailKey`) reopens as its chat
    /// while the chat view is on; every other draft, and every draft with the chat view off, opens
    /// in compose.
    static func savedDraft(id draftId: String, opensInChat: Bool) -> ChatNewThreadRoute {
        opensInChat && Draft.isNewEmailKey(draftId) ? .newThread : .compose
    }
}

/// What a new email's chat holds and decides, free of the view so it is tested on its own.
enum ChatNewDraft {
    /// The chat's words, recipients and attachments as its draft stores them.
    struct Content: Equatable {
        var words: String
        /// The To entries a save writes (`toEntries`).
        var recipients: [String]
        /// The attachments themselves: a change is told by their bytes, never by name and size alone.
        var attachments: [DraftAttachment]

        /// Something the user would lose by leaving: words that are not only spaces, or an
        /// attachment. Recipients alone are not kept.
        var isWaiting: Bool {
            !words.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || !attachments.isEmpty
        }
    }

    /// Whether leaving (Back) or the app going to the background writes the draft. Nothing is
    /// asked. With no saved draft, only something waiting is saved: an empty chat leaves nothing
    /// in Drafts. A saved draft follows what the chat holds whenever it changed, emptied included:
    /// nothing here deletes a draft (a draft is removed only by compose's Discard).
    static func needsSave(current: Content, saved: Content?) -> Bool {
        guard let saved else { return current.isWaiting }
        return current != saved
    }

    /// What Send does in a new email's chat.
    enum SendAction: Equatable {
        /// No recipient yet: ask for one ("Who is this to?"); the words and attachments stay.
        case askForRecipient
        /// The email can be written for these recipients.
        case write(to: [String])
    }

    static func send(people: [ChatThread.Person]) -> SendAction {
        people.isEmpty ? .askForRecipient : .write(to: people.map(\.address))
    }

    /// Who the email goes to after Done in "Add recipient": the people ticked, or, when Done
    /// returns exactly the people already picked (`ChatReplyTarget.replyAll`), those unchanged.
    static func people(after done: ChatReplyTarget, current: [ChatThread.Person]) -> [ChatThread.Person] {
        done.only ?? current
    }

    /// The line the empty chat shows before anyone is picked.
    static let emptyHint = "New email. Type what you want to say, or ask TabMail to write it."

    /// The line the chat shows once people are picked: "New email to Maria and Sam."
    static func recipientsLine(_ people: [ChatThread.Person]) -> String? {
        let names = people.map(\.name)
        guard let last = names.last else { return nil }
        let joined = names.count == 1 ? last : names.dropLast().joined(separator: ", ") + " and " + last
        return "New email to \(joined)."
    }

    /// The line under a saved draft's chat: "Draft, saved 10:42", with the date when it was saved
    /// before today.
    static func savedLine(_ savedAt: Date, now: Date = Date(), calendar: Calendar = .current) -> String {
        let sameDay = calendar.isDate(savedAt, inSameDayAs: now)
        let time = savedAt.formatted(date: sameDay ? .omitted : .abbreviated, time: .shortened)
        return "Draft, saved \(time)"
    }

    /// The people a saved draft's To names, in order, each under the name its address gives, and
    /// the mailboxes as the draft wrote them (`authored`, for `toEntries`). Entries that name no
    /// address are kept apart (`leftovers`) so a save writes them back.
    static func people(fromTo to: [String]) -> (people: [ChatThread.Person], authored: [RecipientEntry.Recipient], leftovers: [String]) {
        let entry = RecipientEntry(to)
        let people = entry.recipients.map { recipient in
            let address = recipient.address.lowercased()
            let name = recipient.name.flatMap { $0.isEmpty ? nil : $0 } ?? ChatThread.fallbackName(address)
            return ChatThread.Person(address: address, name: name)
        }
        return (people, entry.recipients, entry.leftovers)
    }

    /// The To entries a save writes, each a mailbox that reads back as itself
    /// (`RecipientEntry.text`, as compose stores them). A person the reopened draft named keeps
    /// that draft's own name and address as written (`authored`); a person picked here is
    /// written under the name picked, or as the bare address when that name is only the
    /// address's own (`ChatThread.fallbackName`). The entries that name no address follow, as written.
    static func toEntries(people: [ChatThread.Person], authored: [RecipientEntry.Recipient], leftovers: [String]) -> [String] {
        var written: [String: RecipientEntry.Recipient] = [:]
        for mailbox in authored where written[mailbox.address.lowercased()] == nil {
            written[mailbox.address.lowercased()] = mailbox
        }
        let mailboxes = people.map { person -> String in
            if let mailbox = written[person.address.lowercased()] {
                return RecipientEntry.text(name: mailbox.name, address: mailbox.address)
            }
            let name = person.name == ChatThread.fallbackName(person.address) ? nil : person.name
            return RecipientEntry.text(name: name, address: person.address)
        }
        return mailboxes + leftovers
    }
}

/// Writes a new email's draft, as compose's Save does: one fail-closed read of the row, the
/// attachments staged in a fresh directory, the row saved through this chat's generation
/// (`ComposeGenerationCursor`), the staged or superseded directory removed only after the save
/// committed, then the push to the server's Drafts queued (`queueDraftSave`). Every refusal leaves
/// the saved row and its attachments as they were.
@MainActor
enum ChatNewDraftSave {
    enum Outcome: Equatable {
        case saved
        case refused(String)
    }

    static let busyMessage = "This draft couldn't be saved because the database was busy. Try again in a moment."
    static let notQueuedMessage = "This draft couldn't be saved to your Drafts folder. Your words are still here; try again."

    /// Queues a saved draft's push to the server's Drafts; false when the queue did not take it.
    typealias QueueDraftSave = @MainActor (_ draftId: String, _ accountId: String) async -> Bool

    /// The push compose's Save queues (`AccountManager.queueDraftSave`).
    static func queueThroughAccounts(_ draftId: String, _ accountId: String) async -> Bool {
        await AccountManager.shared.queueDraftSave(draftId: draftId, accountId: accountId)
    }

    /// `to` is the chat's recipients; a subject, Cc or Bcc the row already holds (written in
    /// compose) is kept, as the chat has none of its own.
    static func run(
        draftId: String,
        accountId: String,
        to: [String],
        body: String,
        attachments: [DraftAttachment],
        cursor: ComposeGenerationCursor,
        now: Double,
        queueDraftSave: QueueDraftSave = queueThroughAccounts
    ) async -> Outcome {
        // A thrown read is not absence: nothing is written.
        let readResult: Result<Draft?, Error>
        do {
            readResult = .success(try await AppDatabase.dbPool.read { db in
                try Draft.fetchOne(db, key: draftId)
            })
        } catch {
            readResult = .failure(error)
        }
        guard ComposeDraftGuards.saveMayMutate(readState: ComposeDraftGuards.readState(readResult)),
              case .success(let existing) = readResult else {
            if DebugModeManager.isLoggingEnabled() {
                BackgroundSyncLogger.logDebug("[ChatNewDraft] draft read threw for \(draftId); nothing written")
            }
            return .refused(busyMessage)
        }
        let previousDirName = existing?.attachmentsDirName

        let stagingDirName: String?
        if attachments.isEmpty {
            stagingDirName = nil
        } else {
            let staging = DraftAttachmentStorage.newStagingDirName()
            do {
                try DraftAttachmentStorage.saveAttachments(attachments, dirName: staging)
            } catch {
                DraftAttachmentStorage.deleteAttachments(dirName: staging)
                return .refused("The attachments couldn't be saved: \(error.localizedDescription)")
            }
            stagingDirName = staging
        }

        let draft = ComposeDraftGuards.draftToSave(
            existing: existing, id: draftId, accountId: accountId,
            recipients: (to, existing?.ccArray ?? [], existing?.bccArray ?? []),
            subject: existing?.subject ?? "", body: body, replyTo: nil,
            isForward: false, isReplyAll: false, attachmentsDirName: stagingDirName, now: now)

        let result: DraftStore.SaveResult
        do {
            result = try await cursor.admit { epoch, expectedPredecessor in
                try await DraftStore.shared.saveAsync(draft, epoch: epoch, expectedPredecessor: expectedPredecessor)
            }
        } catch {
            if case .deleteStaging(let dir) = ComposeDraftGuards.attachmentDisposition(
                saveApplied: false, stagingDir: stagingDirName, previousDir: previousDirName) {
                DraftAttachmentStorage.deleteAttachments(dirName: dir)
            }
            return .refused("This draft couldn't be saved: \(error.localizedDescription)")
        }
        switch ComposeDraftGuards.attachmentDisposition(
            saveApplied: result == .applied, stagingDir: stagingDirName, previousDir: previousDirName) {
        case .deleteSuperseded(let dir), .deleteStaging(let dir):
            DraftAttachmentStorage.deleteAttachments(dirName: dir)
        case .noCleanup:
            break
        }
        guard result == .applied else {
            return .refused("This draft couldn't be saved: \(DraftStore.DraftEpochAdmissionError.staleOrReserved.localizedDescription)")
        }
        guard await queueDraftSave(draftId, accountId) else {
            return .refused(notQueuedMessage)
        }
        return .saved
    }
}

/// A new email's chat (`ChatNewThreadView`): its draft key and generation, who it goes to, the
/// field's words, the attachments waiting above the field, and when its draft was last saved.
/// Nothing of the agent's chat is kept here: each new email's chat starts its own session in memory.
///
/// Made once, where the chat is opened (the compose button's tap, a reopened draft's preparation),
/// and handed to the view, so the account and the draft it was opened with are never read again.
/// Equal by identity, so it can drive a navigation push.
@MainActor @Observable
final class ChatNewThreadModel: Hashable {
    nonisolated static func == (lhs: ChatNewThreadModel, rhs: ChatNewThreadModel) -> Bool { lhs === rhs }
    nonisolated func hash(into hasher: inout Hasher) { hasher.combine(ObjectIdentifier(self)) }

    let draftId: String
    let account: Account?
    /// The words a reopened draft puts in the field; empty for a new chat.
    let startWords: String
    private(set) var people: [ChatThread.Person]
    /// The field's words, as the field reports each change.
    var words: String
    private(set) var attachments: [DraftAttachment]
    /// When this chat's draft was last saved; nil while it has none.
    private(set) var savedAt: Date?
    /// A reopened draft's attachments could not be read: the draft is not saved from here, so
    /// the files it points at are never replaced by an empty set.
    let attachmentLoadFailed: Bool
    /// Picked items that could not be added, by their labels, until the user has seen them.
    var failedImports: [String] = []
    private(set) var isSaving = false

    let cursor: ComposeGenerationCursor
    /// Picked photos still loading: a save waits for them.
    let carryGate = ComposeAttachmentCarryGate()
    /// What the saved row holds, as last read or written here; nil while there is no row.
    @ObservationIgnored private var saved: ChatNewDraft.Content?
    /// To entries of a reopened draft that name no address, written back on every save.
    private let toLeftovers: [String]
    /// The reopened draft's To mailboxes as it wrote them (`ChatNewDraft.toEntries`).
    private let authoredTo: [RecipientEntry.Recipient]
    @ObservationIgnored private var inFlight: Task<ChatNewDraftSave.Outcome, Never>?
    /// Queues each saved draft's push to the server (`ChatNewDraftSave.queueThroughAccounts`).
    private let queueDraftSave: ChatNewDraftSave.QueueDraftSave

    static let noAccountMessage = "There is no account to save this draft to."
    static let attachmentLoadMessage = "Some attachments couldn't be loaded, so this draft can't be saved from here. Your saved draft is unchanged."

    /// An empty chat from the compose button.
    init(account: Account?, queueDraftSave: @escaping ChatNewDraftSave.QueueDraftSave = ChatNewDraftSave.queueThroughAccounts) {
        draftId = Draft.newEmailKey()
        self.queueDraftSave = queueDraftSave
        self.account = account
        startWords = ""
        people = []
        words = ""
        attachments = []
        attachmentLoadFailed = false
        toLeftovers = []
        authoredTo = []
        cursor = ComposeGenerationCursor(newEpoch: UUID().uuidString, initialExpectedPredecessor: nil)
    }

    /// A saved draft, reopened: its words, recipients and attachments, in its own generation, as
    /// compose reopens a draft. Attachments that cannot be read block saving from here.
    init(
        reopening draft: Draft,
        account: Account,
        queueDraftSave: @escaping ChatNewDraftSave.QueueDraftSave = ChatNewDraftSave.queueThroughAccounts
    ) {
        draftId = draft.id
        self.queueDraftSave = queueDraftSave
        self.account = account
        startWords = draft.body
        words = draft.body
        let to = ChatNewDraft.people(fromTo: draft.toArray)
        people = to.people
        toLeftovers = to.leftovers
        authoredTo = to.authored
        var loaded: [DraftAttachment] = []
        var loadFailed = false
        do {
            loaded = try DraftAttachmentStorage.loadAttachments(dirName: draft.attachmentsDirName)
        } catch {
            loadFailed = true
            if DebugModeManager.isLoggingEnabled() {
                BackgroundSyncLogger.logDebug("[ChatNewDraft] attachment load failed for \(draft.id): \(error)")
            }
        }
        attachments = loaded
        attachmentLoadFailed = loadFailed
        savedAt = Date(timeIntervalSince1970: draft.updatedAt)
        let observed = draft.instanceEpoch.flatMap { $0.isEmpty ? nil : $0 }
        cursor = ComposeGenerationCursor(newEpoch: observed ?? UUID().uuidString, initialExpectedPredecessor: observed)
        saved = ChatNewDraft.Content(
            words: draft.body,
            recipients: ChatNewDraft.toEntries(people: to.people, authored: to.authored, leftovers: to.leftovers),
            attachments: loaded)
    }

    var content: ChatNewDraft.Content {
        ChatNewDraft.Content(
            words: words,
            recipients: ChatNewDraft.toEntries(people: people, authored: authoredTo, leftovers: toLeftovers),
            attachments: attachments)
    }

    var sendAction: ChatNewDraft.SendAction { ChatNewDraft.send(people: people) }

    /// The people picked in "Add recipient".
    func setPeople(_ picked: [ChatThread.Person]) {
        people = picked
    }

    func addAttachment(_ attachment: DraftAttachment) {
        attachments.append(attachment)
    }

    func addAttachments(_ added: [DraftAttachment]) {
        attachments.append(contentsOf: added)
    }

    func removeAttachment(at index: Int) {
        guard attachments.indices.contains(index) else { return }
        attachments.remove(at: index)
    }

    /// Picked photos and videos, added in order as each loads (`DraftAttachmentImport`), the ones
    /// that do not load reported in `failedImports`. Counted as loading at once, so a save started
    /// now waits for them. Returns the loading, nil for no items.
    @discardableResult
    func addPicked<Item>(
        _ items: [Item],
        load: @escaping @MainActor (Item) async throws -> (data: Data?, type: UTType?)
    ) -> Task<Void, Never>? {
        guard !items.isEmpty else { return nil }
        carryGate.begin(items.count)
        return Task { @MainActor in
            for (index, item) in items.enumerated() {
                var succeeded = false
                do {
                    let loaded = try await load(item)
                    if let data = loaded.data {
                        addAttachment(DraftAttachmentImport.pickedAttachment(
                            data: data, contentType: loaded.type, existingCount: attachments.count))
                        succeeded = true
                    } else {
                        failedImports.append(DraftAttachmentImport.pickedFailureLabel(index: index))
                    }
                } catch {
                    failedImports.append(DraftAttachmentImport.pickedFailureLabel(index: index))
                    if DebugModeManager.isLoggingEnabled() {
                        BackgroundSyncLogger.logDebug("[ChatNewDraft] picked item failed to load: \(error)")
                    }
                }
                carryGate.completeOne(succeeded: succeeded)
            }
        }
    }

    /// Files from the Files picker (`DraftAttachmentImport.importFiles`).
    func addFiles(_ urls: [URL], read: (URL) throws -> Data = DraftAttachmentImport.readSecurityScoped) {
        let imported = DraftAttachmentImport.importFiles(urls, read: read)
        addAttachments(imported.attachments)
        failedImports += imported.failures
    }

    /// The camera's photo (`DraftAttachmentImport.cameraAttachment`).
    func addCameraPhoto(_ image: UIImage) {
        guard let attachment = DraftAttachmentImport.cameraAttachment(image, existingCount: attachments.count) else {
            failedImports.append(DraftAttachmentImport.cameraFailureLabel)
            return
        }
        addAttachment(attachment)
    }

    /// Saves the draft when leaving or going to the background requires it (`needsSave`), after
    /// any picked photo still loading has landed. One save at a time: a second waits for the first
    /// and then decides again. Returns `.saved` when nothing needed saving.
    func saveIfNeeded(now: () -> Date = Date.init) async -> ChatNewDraftSave.Outcome {
        await carryGate.waitUntilSettled()
        // No suspension between this loop and the save's start below, so no two saves overlap.
        while let running = inFlight { _ = await running.value }
        let snapshot = content
        guard ChatNewDraft.needsSave(current: snapshot, saved: saved) else { return .saved }
        guard !attachmentLoadFailed else { return .refused(Self.attachmentLoadMessage) }
        guard let account else { return .refused(Self.noAccountMessage) }
        let to = snapshot.recipients
        let body = snapshot.words
        let files = snapshot.attachments
        let id = draftId
        let generation = cursor
        let queue = queueDraftSave
        let savedAt = now()
        let task = Task { @MainActor () -> ChatNewDraftSave.Outcome in
            let outcome = await ChatNewDraftSave.run(
                draftId: id, accountId: account.id, to: to, body: body, attachments: files,
                cursor: generation, now: savedAt.timeIntervalSince1970, queueDraftSave: queue)
            if outcome == .saved {
                self.saved = snapshot
                self.savedAt = savedAt
            }
            self.inFlight = nil
            self.isSaving = false
            return outcome
        }
        // The task starts only once this method suspends, so it is in flight before it can end.
        inFlight = task
        isSaving = true
        return await task.value
    }
}
