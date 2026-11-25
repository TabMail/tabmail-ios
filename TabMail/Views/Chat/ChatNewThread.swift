/* This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at https://mozilla.org/MPL/2.0/. */

import Foundation
import GRDB
import UIKit
import UniformTypeIdentifiers

/// Where a new email opens: with the chat view on and signed in to TabMail, as a chat
/// (`ChatNewThreadView`); otherwise in today's compose. Signed out (mail only), the chat's field
/// cannot send, so a new email is written in compose. Decided once, with the chat view setting and
/// the TabMail session read at the tap or the open.
enum ChatNewThreadRoute: Equatable {
    case newThread
    case compose

    /// A new email, from wherever one starts: the mailbox list's compose button, the email screen's
    /// compose button, a contact pill, a `mailto:` link in an email or from outside the app.
    static func newEmail(opensInChat: Bool, signedIn: Bool) -> ChatNewThreadRoute {
        opensInChat && signedIn ? .newThread : .compose
    }

    /// A saved draft: a new email started in the chat (`Draft.isNewEmailKey`) reopens as its chat
    /// while the chat view is on and the user is signed in; every other draft, and every draft
    /// with the chat view off or signed out, opens in compose.
    static func savedDraft(id draftId: String, opensInChat: Bool, signedIn: Bool) -> ChatNewThreadRoute {
        opensInChat && signedIn && Draft.isNewEmailKey(draftId) ? .newThread : .compose
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
    /// asked. With no saved draft, only something waiting that the user changed from what the chat
    /// opened with (`opened`, what a contact or a `mailto:` link brought) is saved: an empty chat,
    /// or one left as the link opened it, leaves nothing in Drafts. A saved draft follows what the
    /// chat holds whenever it changed, emptied included: nothing here deletes a draft (a draft is
    /// removed only by compose's Discard).
    static func needsSave(current: Content, saved: Content?, opened: Content? = nil) -> Bool {
        guard let saved else { return current.isWaiting && current != opened }
        return current != saved
    }

    /// What the chat keeps for its email but does not edit: the subject and the Cc and Bcc a
    /// `mailto:` link brought, or a reopened draft holds. Written into a new draft on its first
    /// save and shown in the chat; changed on the compose card. Bcc stays Bcc.
    struct Carried: Equatable {
        var subject: String?
        /// Mailboxes as a draft stores them (`RecipientEntry.draftEntries`).
        var cc: [String]
        var bcc: [String]

        static let empty = Carried(subject: nil, cc: [], bcc: [])

        /// The subject the chat shows in its subject slot: nil when there is none to show.
        var shownSubject: String? {
            guard let subject, !subject.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
            return subject
        }
    }

    /// The chat area's line for Cc or Bcc: "Cc: Sam and Alex." Nil when there is no one.
    static func copyLine(_ label: String, _ stored: [String]) -> String? {
        joinedNames(RecipientEntry(stored).recipients.map { person($0).name }).map { "\(label): \($0)." }
    }

    /// "Maria", "Maria and Sam", "Maria, Sam and Alex"; nil for no one.
    private static func joinedNames(_ names: [String]) -> String? {
        guard let last = names.last else { return nil }
        return names.count == 1 ? last : names.dropLast().joined(separator: ", ") + " and " + last
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
        joinedNames(people.map(\.name)).map { "New email to \($0)." }
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
        return (entry.recipients.map(person), entry.recipients, entry.leftovers)
    }

    /// The person a saved draft's mailbox names: its address, under the mailbox's own name, or
    /// the address's (`ChatThread.fallbackName`) when it has none.
    static func person(_ mailbox: RecipientEntry.Recipient) -> ChatThread.Person {
        let address = mailbox.address.lowercased()
        let name = mailbox.name.flatMap { $0.isEmpty ? nil : $0 } ?? ChatThread.fallbackName(address)
        return ChatThread.Person(address: address, name: name)
    }

    /// The To entries a save writes, each a mailbox that reads back as itself
    /// (`RecipientEntry.text`, as compose stores them). A person the reopened draft named, still
    /// under the name that draft gives them, keeps that draft's own name and address as written
    /// (`authored`); a person picked here, or picked again under another name, is written under
    /// the name picked, or as the bare address when that name is only the address's own
    /// (`ChatThread.fallbackName`). The entries that name no address follow, as written.
    static func toEntries(people: [ChatThread.Person], authored: [RecipientEntry.Recipient], leftovers: [String]) -> [String] {
        var written: [String: RecipientEntry.Recipient] = [:]
        for mailbox in authored where written[mailbox.address.lowercased()] == nil {
            written[mailbox.address.lowercased()] = mailbox
        }
        let mailboxes = people.map { person -> String in
            if let mailbox = written[person.address.lowercased()], Self.person(mailbox).name == person.name {
                return RecipientEntry.text(name: mailbox.name, address: mailbox.address)
            }
            let name = person.name == ChatThread.fallbackName(person.address) ? nil : person.name
            return RecipientEntry.text(name: name, address: person.address)
        }
        return mailboxes + leftovers
    }
}

/// Writes a new email's draft through compose's own writer (`ComposeDraftSave.run`: one
/// fail-closed read of the row, the attachments staged in a fresh directory, the row saved
/// through this chat's generation (`ComposeGenerationCursor`), the staged or superseded directory
/// removed only after the save committed), then queues the push to the server's Drafts
/// (`queueDraftSave`). A refusal before the commit leaves the saved row and its attachments as
/// they were; a queue refusal comes after it, so the new version stays saved on the device and
/// only its push is missing.
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
    /// compose, or by this chat's first save) is kept, as the chat does not edit them. A new row
    /// takes them from `carried`, what a `mailto:` link brought. `committed` says the row now
    /// holds this version on the device: true also when only the queue refused its push.
    static func run(
        draftId: String,
        accountId: String,
        to: [String],
        body: String,
        carried: ChatNewDraft.Carried = .empty,
        attachments: [DraftAttachment],
        cursor: ComposeGenerationCursor,
        now: Double,
        queueDraftSave: QueueDraftSave = queueThroughAccounts
    ) async -> (outcome: Outcome, committed: Bool) {
        let written = await ComposeDraftSave.run(
            draftId: draftId, accountId: accountId, attachments: attachments, now: now,
            fields: { existing in
                ComposeDraftSave.Fields(
                    to: to, cc: existing?.ccArray ?? carried.cc, bcc: existing?.bccArray ?? carried.bcc,
                    subject: existing?.subject ?? carried.subject ?? "", body: body, replyTo: nil,
                    isForward: false, isReplyAll: false)
            },
            admit: { draft in
                try await cursor.admit { epoch, expectedPredecessor in
                    try await DraftStore.shared.saveAsync(draft, epoch: epoch, expectedPredecessor: expectedPredecessor)
                }
            })
        switch written {
        case .committed:
            break
        case .readFailed:
            return (.refused(busyMessage), false)
        case .attachmentsNotStaged(let reason):
            return (.refused("The attachments couldn't be saved: \(reason)"), false)
        case .saveFailed(let reason):
            return (.refused("This draft couldn't be saved: \(reason)"), false)
        case .superseded:
            return (.refused("This draft couldn't be saved: \(DraftStore.DraftEpochAdmissionError.staleOrReserved.localizedDescription)"), false)
        }
        guard await queueDraftSave(draftId, accountId) else {
            return (.refused(notQueuedMessage), true)
        }
        return (.saved, true)
    }
}

/// A new email's chat (`ChatNewThreadView`): its draft key and generation, who it goes to, the
/// field's words, the attachments waiting above the field, and when its draft was last saved.
/// Nothing of the agent's chat is kept here: each new email's chat starts its own session in memory.
///
/// Made once, where the chat is opened (a compose button's tap, a contact pill's or a link's
/// arrival, a reopened draft's preparation), and handed to the view, so the account and the draft
/// it was opened with are never read again.
/// Equal by identity, so it can drive a navigation push.
@MainActor @Observable
final class ChatNewThreadModel: Hashable {
    nonisolated static func == (lhs: ChatNewThreadModel, rhs: ChatNewThreadModel) -> Bool { lhs === rhs }
    nonisolated func hash(into hasher: inout Hasher) { hasher.combine(ObjectIdentifier(self)) }

    let draftId: String
    let account: Account?
    /// This chat's own agent session, in memory only (`ChatPillState`); the screen ends it as it
    /// closes (`ChatPillState.endSession`).
    let sessionKey = ChatNewEmailField.newSessionKey()
    /// The words a reopened draft or a `mailto:` link's body puts in the field; empty otherwise.
    let startWords: String
    /// The subject, Cc and Bcc the email keeps that the chat does not edit (`ChatNewDraft.Carried`).
    let carried: ChatNewDraft.Carried
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
    /// The row holds `saved` on the device but the queue refused its push: the next save writes
    /// and queues it again, changed or not.
    @ObservationIgnored private var pushPending = false
    /// What the chat opened with: a contact's or a link's people and words, or nothing. Left as
    /// it is, it is not saved (`ChatNewDraft.needsSave`).
    private let openedContent: ChatNewDraft.Content
    /// To entries of a reopened draft that name no address, written back on every save.
    private let toLeftovers: [String]
    /// The reopened draft's To mailboxes as it wrote them (`ChatNewDraft.toEntries`).
    private let authoredTo: [RecipientEntry.Recipient]
    @ObservationIgnored private var inFlight: Task<ChatNewDraftSave.Outcome, Never>?
    /// Queues each saved draft's push to the server (`ChatNewDraftSave.queueThroughAccounts`).
    private let queueDraftSave: ChatNewDraftSave.QueueDraftSave

    static let noAccountMessage = "There is no account to save this draft to."
    static let attachmentLoadMessage = "Some attachments couldn't be loaded, so this draft can't be saved from here. Your saved draft is unchanged."

    /// A new email: empty from a compose button, or with what a contact pill or a `mailto:` link
    /// brought (`request`): its To as the picked people (a reopened draft's To is read the same
    /// way), its body as the field's starting words, its subject, Cc and Bcc carried to the draft.
    init(
        account: Account?,
        request: MailtoRequest? = nil,
        queueDraftSave: @escaping ChatNewDraftSave.QueueDraftSave = ChatNewDraftSave.queueThroughAccounts
    ) {
        draftId = Draft.newEmailKey()
        self.queueDraftSave = queueDraftSave
        self.account = account
        let to = ChatNewDraft.people(fromTo: request?.to ?? [])
        people = to.people
        toLeftovers = to.leftovers
        authoredTo = to.authored
        startWords = request?.body ?? ""
        words = startWords
        carried = ChatNewDraft.Carried(
            subject: request?.subject,
            cc: RecipientEntry(request?.cc ?? []).draftEntries,
            bcc: RecipientEntry(request?.bcc ?? []).draftEntries)
        attachments = []
        attachmentLoadFailed = false
        cursor = ComposeGenerationCursor(newEpoch: UUID().uuidString, initialExpectedPredecessor: nil)
        openedContent = ChatNewDraft.Content(
            words: startWords,
            recipients: ChatNewDraft.toEntries(people: to.people, authored: to.authored, leftovers: to.leftovers),
            attachments: [])
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
        carried = ChatNewDraft.Carried(subject: draft.subject, cc: draft.ccArray, bcc: draft.bccArray)
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
        let savedContent = ChatNewDraft.Content(
            words: draft.body,
            recipients: ChatNewDraft.toEntries(people: to.people, authored: to.authored, leftovers: to.leftovers),
            attachments: loaded)
        saved = savedContent
        openedContent = savedContent
    }

    /// The chat after its card sent the email (ADR-IOS-114): a new email to the same people, with
    /// the subject, Cc and Bcc the chat carries, from the same account, with an empty field and no
    /// attachments, in a draft and agent session of its own. Left as it is, it is not saved. Its own
    /// draft, not the sent chat's: that one's row was discarded at the send, and its generation
    /// with it.
    init(after sent: ChatNewThreadModel) {
        draftId = Draft.newEmailKey()
        queueDraftSave = sent.queueDraftSave
        account = sent.account
        people = sent.people
        toLeftovers = sent.toLeftovers
        authoredTo = sent.authoredTo
        startWords = ""
        words = ""
        carried = sent.carried
        attachments = []
        attachmentLoadFailed = false
        cursor = ComposeGenerationCursor(newEpoch: UUID().uuidString, initialExpectedPredecessor: nil)
        openedContent = ChatNewDraft.Content(
            words: "",
            recipients: ChatNewDraft.toEntries(people: sent.people, authored: sent.authoredTo, leftovers: sent.toLeftovers),
            attachments: [])
    }

    /// A new draft id for each compose card the chat opens (`card`), as compose gives a new email
    /// of its own: a card closed with Save is an ordinary draft, which reopens in compose.
    nonisolated static func newCardDraftId() -> String { UUID().uuidString }

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

    /// Picked photos and videos, added in order as each loads (`DraftAttachmentImport.loadPicked`),
    /// the ones that do not load reported in `failedImports`. Counted as loading at once, so a save
    /// started now waits for them. Returns the loading, nil for no items.
    @discardableResult
    func addPicked<Item>(
        _ items: [Item],
        load: @escaping @MainActor (Item) async throws -> (data: Data?, type: UTType?)
    ) -> Task<Void, Never>? {
        guard !items.isEmpty else { return nil }
        carryGate.begin(items.count)
        return Task { @MainActor in
            await DraftAttachmentImport.loadPicked(
                items, load: load,
                existingCount: { self.attachments.count },
                add: { self.addAttachment($0) },
                fail: { self.failedImports.append($0) },
                settled: { self.carryGate.completeOne(succeeded: $0) })
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

    /// The compose card for the new email written from the field's words (the field's compose
    /// edit, `EmailComposeTool.composeFromField`): today's compose, with the written subject and
    /// email and its text version (`ComposeRequest.suggestion`, as the reply field's card carries
    /// it), this chat's people as To (as a save writes them, `toEntries`), the subject, Cc and Bcc
    /// it carries (a link's or a reopened draft's subject wins over the written one), the
    /// attachments waiting above the field, and From `account`, changeable on the card as
    /// compose's From is. Only the card's Send sends.
    ///
    /// `draftId` is the card's own draft, new for each card (`newCardDraftId`): no row has it yet,
    /// so compose starts from these fields as any new email does, and its send's outbox row
    /// carries it, so the chat finds the send by it (`ChatNewEmailSend`). The card records this
    /// chat as its screen, so the send's Undo is on the chat's bubble
    /// (`PendingSendService.sendHasBubbleUndo`).
    func card(
        for req: AgentToolRouter.ComposeRequest, account: Account?, draftId: String,
        onOutcome: @escaping @MainActor (ComposeOutcome) -> Void
    ) -> ComposeView {
        ComposeView(
            suggestedBody: req.body, suggestion: req.suggestion, account: account,
            prefillTo: content.recipients, prefillCc: carried.cc, prefillBcc: carried.bcc,
            prefillSubject: carried.shownSubject ?? req.subject,
            prefillAttachments: attachments, prefillDraftId: draftId, openedOn: .newEmailChat,
            onAgentOutcome: onOutcome)
    }

    /// After the card's Send has its durable outbox row: this chat's saved draft, if it has one,
    /// is discarded through compose's own Discard (`ComposeDraftDiscard`, which also removes the
    /// server's copy), after any save of it in flight. With no saved draft there is nothing to do.
    func discardSavedDraft() async -> ComposeDraftDiscard.Outcome {
        while let running = inFlight { _ = await running.value }
        return await ComposeDraftDiscard.run(
            .wholeDraft, draftId: draftId, epoch: cursor.newEpoch, readState: .loaded,
            isSavingDraft: isSaving, isSending: false, agentSendFence: ComposeAgentSendFence())
    }

    /// Saves the draft when leaving or going to the background requires it (`needsSave`), after
    /// any picked photo still loading has landed, or when the last version saved on the device
    /// still waits for its push (`pushPending`). One save at a time: a second waits for the first
    /// and then decides again. Returns `.saved` when nothing needed saving.
    func saveIfNeeded(now: () -> Date = Date.init) async -> ChatNewDraftSave.Outcome {
        await carryGate.waitUntilSettled()
        // No suspension between this loop and the save's start below, so no two saves overlap.
        while let running = inFlight { _ = await running.value }
        let snapshot = content
        guard pushPending || ChatNewDraft.needsSave(current: snapshot, saved: saved, opened: openedContent) else { return .saved }
        guard !attachmentLoadFailed else { return .refused(Self.attachmentLoadMessage) }
        guard let account else { return .refused(Self.noAccountMessage) }
        let to = snapshot.recipients
        let body = snapshot.words
        let files = snapshot.attachments
        let kept = carried
        let id = draftId
        let generation = cursor
        let queue = queueDraftSave
        let savedAt = now()
        let task = Task { @MainActor () -> ChatNewDraftSave.Outcome in
            let (outcome, committed) = await ChatNewDraftSave.run(
                draftId: id, accountId: account.id, to: to, body: body, carried: kept, attachments: files,
                cursor: generation, now: savedAt.timeIntervalSince1970, queueDraftSave: queue)
            // A row written on the device is what later saves compare with, even when its push
            // was refused: a link's untouched words are then saved over it, not skipped.
            if committed {
                self.saved = snapshot
                self.pushPending = outcome != .saved
            }
            if outcome == .saved {
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
