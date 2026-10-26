/* This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at https://mozilla.org/MPL/2.0/. */

import Foundation
import GRDB
import Observation

/// The guided tutorial (owner V5, 2026-10-20): three short parts on the demo
/// inbox (ADR-IOS-038). A thin state machine over the real mail screens:
/// steps advance only on real events in the demo database or the prompt
/// store, never on a timer or tap count. Scripted, with no AI call and no
/// consent screen (owner 2026-10-21): the chat input is filled in and
/// read-only, and `TutorialChatScript` answers it on the device.
@MainActor
@Observable
final class TutorialCoordinator {
    static let shared = TutorialCoordinator()

    enum Step: Hashable {
        /// Demo entry and seeding.
        case starting
        // Part 1, act on email.
        case archiveReceipt
        /// The receipt left the inbox: the result and Undo, then "Next".
        case receiptArchived
        case retagDailyTech
        case actOnEmailDone
        // Part 2, reuse a reply.
        case replyToPriya
        case makeTemplate
        case reuseReplyDone
        // Part 3, ask anything.
        case askFlights
        /// The source email is open: "There's your answer".
        case askAnythingDone
        /// Back in Chat: what else to ask, and "What can you do?".
        case moreToAsk
        /// The closing recap; its button ends the tutorial.
        case finished
    }

    /// What the inbox chat's read-only input holds at a step. Sending it runs
    /// the matching `TutorialChatScript` answer.
    enum ChatPrompt: String, CaseIterable {
        case makeTemplate = "Make my most recent reply a template"
        case flights = "What flight times did Jordan suggest?"
        case whatCanYouDo = "What can you do?"
    }

    private(set) var lesson: TutorialLesson?
    private(set) var step: Step?
    var isRunning: Bool { lesson != nil }

    /// The flight question was sent: the chat card moves on to "Check the original".
    private(set) var flightsAsked = false
    /// "What can you do?" was sent: nothing more to send, Finish is on the card.
    private(set) var whatCanYouDoAsked = false
    /// The practice reply's scripted edit ran: compose moves on to Use Suggestion.
    private(set) var replyEdited = false
    /// "See rule" opened the Action Classification sheet with the sample rule.
    var showsActionRule = false
    /// The template the practice reply became, for "See template".
    private(set) var savedTemplateId: String?
    /// The text of the practice reply as written in compose (no quote or
    /// signature): the example of the template made from it.
    private(set) var practiceReplyText: String?

    /// Whether this run started for a signed-in user (exit restores their inbox).
    private(set) var startedSignedIn = false

    /// Why the last start failed (RootView's "Could not start demo" alert).
    var startError: String?

    /// Shown briefly after a mail action the step does not ask for was
    /// refused (`TutorialLockedToast`).
    private(set) var lockedNotice: String?
    private var lockedNoticeGeneration = 0
    static let lockedNoticeText = "Other actions are off during the tutorial."
    static let lockedNoticeDuration: Duration = .seconds(2.5)

    private let progress = TutorialProgress()
    /// Observable copy of the durable completion set (drives the sidebar row).
    private(set) var completedLessons: Set<TutorialLesson>

    private var isEnding = false
    private var observationTask: Task<Void, Never>?
    /// Bumped per mail observation: an older template-observation chain
    /// (`withObservationTracking` cannot be cancelled) stops re-arming.
    private var templateObservationGeneration = 0
    /// The latest demo mail facts, re-applied when a "Next" button moves the
    /// step on (the facts may already satisfy the new step).
    private var lastFacts: MailFacts?
    private var sentBaseline: Set<String> = []
    private var templateBaseline: Set<String> = []

    private init() {
        completedLessons = progress.completedLessons
    }

    // MARK: - Entry and exit

    /// Start (or resume at) `lesson` on a fresh demo inbox.
    func start(_ lesson: TutorialLesson, hasTabMailSession: Bool) async {
        guard !isRunning else { return }
        let demoStore = DemoModeStore.shared
        // A plain demo is replaced: the tutorial needs the fresh seed.
        if demoStore.isActive { await DemoModeService.shared.exit() }

        self.lesson = lesson
        step = .starting
        startedSignedIn = hasTabMailSession
        // Before the demo is active: no backend call can slip in between.
        demoStore.isTutorialPractice = true
        do {
            try await DemoModeService.shared.start(mintToken: false)
        } catch {
            BackgroundSyncLogger.logDebug("[Tutorial] demo start failed: \(error)")
            resetRunState()
            startError = error.localizedDescription
            return
        }
        // RootView seeds behind the splash and calls `seedingFinished()`.
    }

    /// RootView finished `DemoModeService.completeSetup()`.
    func seedingFinished() {
        guard let lesson, step == .starting else { return }
        begin(lesson)
    }

    /// Finish and Skip tutorial both end here: canonical demo
    /// cleanup, then RootView routes to sign-in or the restored inbox. The
    /// run state is cleared only after the demo is gone, so RootView never
    /// shows the plain demo's consent screens in between.
    func end() async {
        guard isRunning, !isEnding else { return }
        isEnding = true
        observationTask?.cancel()
        observationTask = nil
        await DemoModeService.shared.exit()
        resetRunState()
    }

    /// The demo ended from outside (seeding failure, a failed age check).
    func demoDidExit() {
        guard isRunning else { return }
        resetRunState()
    }

    private func resetRunState() {
        observationTask?.cancel()
        observationTask = nil
        templateObservationGeneration += 1
        lesson = nil
        step = nil
        isEnding = false
        flightsAsked = false
        whatCanYouDoAsked = false
        replyEdited = false
        showsActionRule = false
        savedTemplateId = nil
        practiceReplyText = nil
        lastFacts = nil
        lockedNotice = nil
        DemoModeStore.shared.isTutorialPractice = false
    }

    // MARK: - Flow

    func nextLesson() {
        guard let next = lesson?.next else { return }
        lesson = next
        begin(next)
    }

    /// "Next" on the receipt result.
    func continueToRetag() {
        guard step == .receiptArchived else { return }
        step = .retagDailyTech
        if let lastFacts { apply(lastFacts) }
    }

    /// "Next" on the source email: back to Chat for what else to ask.
    func showMoreToAsk() {
        guard step == .askAnythingDone else { return }
        step = .moreToAsk
    }

    /// "Finish" in Chat: the closing recap.
    func showRecap() {
        guard step == .moreToAsk else { return }
        step = .finished
    }

    private func begin(_ lesson: TutorialLesson) {
        replyEdited = false
        switch lesson {
        case .actOnEmail: step = .archiveReceipt
        case .reuseReply: step = .replyToPriya
        case .askAnything: step = .askFlights
        }
        startObservingMail()
    }

    /// "See rule" on the part 1 result.
    func showActionRule() {
        guard step == .actOnEmailDone else { return }
        showsActionRule = true
    }

    /// The rule part 1 shows as learned from the DailyTech change. A sample:
    /// the demo never runs the AI refinement (re-tags of demo samples never
    /// teach), and the demo's prompt overlay drops it on exit.
    static let sampleDeleteRule = "Tech news digests like DailyTech Digest"

    private func addSampleRule() {
        guard DemoModeStore.isDemoActive else { return }
        let store = PromptStore.shared
        let line = "- \(Self.sampleDeleteRule)"
        guard !store.deleteRules.contains(line) else { return }
        store.deleteRules = store.deleteRules.isEmpty ? line : store.deleteRules + "\n" + line
    }

    private func complete(_ finished: TutorialLesson, step done: Step) {
        progress.markCompleted(finished)
        completedLessons = progress.completedLessons
        step = done
    }

    // MARK: - Events

    /// A message detail opened (part 3's source email).
    func messageOpened(accountId: String, messageId: String) {
        guard step == .askFlights,
              accountId == DemoSeed.demoAccountId,
              messageId == DemoSeed.TutorialFixture.jordanFlights else { return }
        complete(.askAnything, step: .askAnythingDone)
    }

    /// The inbox chat's filled-in input now, if this step has one.
    var chatPrompt: ChatPrompt? {
        Self.chatPrompt(for: step, flightsAsked: flightsAsked, whatCanYouDoAsked: whatCanYouDoAsked)
    }

    nonisolated static func chatPrompt(
        for step: Step?, flightsAsked: Bool, whatCanYouDoAsked: Bool = false
    ) -> ChatPrompt? {
        switch step {
        case .makeTemplate: return .makeTemplate
        case .askFlights where !flightsAsked: return .flights
        case .moreToAsk where !whatCanYouDoAsked: return .whatCanYouDo
        default: return nil
        }
    }

    /// The inbox chat sent `prompt` (its scripted answer follows).
    func chatPromptSent(_ prompt: ChatPrompt) {
        if prompt == .flights, step == .askFlights { flightsAsked = true }
        if prompt == .whatCanYouDo, step == .moreToAsk { whatCanYouDoAsked = true }
    }

    /// The open chat covers the coach card (owner 2026-10-25): when the step's
    /// next move is a card button, closing the chat is the next tap.
    var highlightsChatClose: Bool {
        step == .reuseReplyDone || (step == .moreToAsk && whatCanYouDoAsked)
    }

    /// The template proposal's Create is the next tap in part 2.
    var highlightsTemplateCreate: Bool { step == .makeTemplate }

    /// What the practice reply's draft chat holds before its edit ran.
    static let editPrompt = "Say I can’t make it"

    /// The practice reply's draft chat input now, if this step has one.
    var composeEditPrompt: String? { step == .replyToPriya && !replyEdited ? Self.editPrompt : nil }

    /// The draft chat's scripted edit rewrote the practice reply.
    func practiceReplyEdited() {
        guard step == .replyToPriya else { return }
        replyEdited = true
    }

    /// The step's email reference in the chat answer (and its Open Email) is
    /// the next tap.
    var highlightsEmailReference: Bool { step == .askFlights && flightsAsked }

    /// Compose is sending the practice reply to Priya with this text.
    func practiceReplyAuthored(_ text: String) {
        guard step == .replyToPriya else { return }
        practiceReplyText = text
    }

    /// The demo's mail state, the only facts parts 1 and 2 advance on.
    struct MailFacts: Equatable {
        var receiptInInbox: Bool
        var dailyTechTag: String?
        var sentMessageIds: Set<String>
    }

    /// Three lookups on `messageHeader_folderId_messageId` / `_folderId`
    /// prefixes. The observation re-runs them on every header commit, and
    /// `removeDuplicates` keeps unrelated writes from reaching the UI.
    nonisolated static func fetchMailFacts(_ db: Database) throws -> MailFacts {
        let account = DemoSeed.demoAccountId
        let inbox = "\(account):INBOX"
        let receiptInInbox = try Bool.fetchOne(db, sql: """
            SELECT EXISTS(SELECT 1 FROM messageHeader WHERE folderId = ? AND messageId = ?)
            """, arguments: [inbox, DemoSeed.TutorialFixture.receipt]) ?? false
        let dailyTechTag = try String.fetchOne(db, sql: """
            SELECT actionTag FROM messageHeader WHERE folderId = ? AND messageId = ?
            """, arguments: [inbox, DemoSeed.TutorialFixture.dailyTech])
        let sent = try String.fetchAll(db, sql: """
            SELECT messageId FROM messageHeader WHERE folderId = ?
            """, arguments: ["\(account):SENT"])
        return MailFacts(receiptInInbox: receiptInInbox, dailyTechTag: dailyTechTag, sentMessageIds: Set(sent))
    }

    private func startObservingMail() {
        observationTask?.cancel()
        sentBaseline = []
        templateBaseline = Set(PromptStore.shared.templates.map(\.id))
        observationTask = Task { [weak self] in
            var isFirst = true
            let observation = ValueObservation.tracking { db in
                try TutorialCoordinator.fetchMailFacts(db)
            }
            .removeDuplicates()
            do {
                for try await facts in observation.values(in: AppDatabase.rawPool) {
                    guard let self, !Task.isCancelled else { return }
                    if isFirst {
                        self.sentBaseline = facts.sentMessageIds
                        isFirst = false
                    }
                    self.lastFacts = facts
                    self.apply(facts)
                }
            } catch {
                BackgroundSyncLogger.logDebug("[Tutorial] mail observation ended: \(error)")
            }
        }
        observeTemplates()
    }

    private func apply(_ facts: MailFacts) {
        switch step {
        case .archiveReceipt where !facts.receiptInInbox:
            step = .receiptArchived
        case .retagDailyTech where facts.dailyTechTag == ActionTag.delete.rawValue:
            addSampleRule()
            complete(.actOnEmail, step: .actOnEmailDone)
        case .replyToPriya where !facts.sentMessageIds.subtracting(sentBaseline).isEmpty:
            templateBaseline = Set(PromptStore.shared.templates.map(\.id))
            step = .makeTemplate
        default:
            break
        }
    }

    /// Part 2 finishes when the confirmed template is persisted.
    private func observeTemplates() {
        templateObservationGeneration += 1
        armTemplateObservation(generation: templateObservationGeneration)
    }

    private func armTemplateObservation(generation: Int) {
        withObservationTracking {
            _ = PromptStore.shared.templates
        } onChange: { [weak self] in
            Task { @MainActor [weak self] in
                guard let self, self.isRunning, generation == self.templateObservationGeneration else { return }
                self.templatesChanged()
                self.armTemplateObservation(generation: generation)
            }
        }
    }

    private func templatesChanged() {
        guard step == .makeTemplate else { return }
        let added = PromptStore.shared.visibleTemplates.first { !templateBaseline.contains($0.id) }
        guard let added else { return }
        savedTemplateId = added.id
        complete(.reuseReply, step: .reuseReplyDone)
    }

    // MARK: - Highlight

    /// The seeded message whose action tag the step asks the user to use.
    nonisolated static func tagTarget(for step: Step?) -> String? {
        switch step {
        case .archiveReceipt: return DemoSeed.TutorialFixture.receipt
        case .retagDailyTech: return DemoSeed.TutorialFixture.dailyTech
        case .replyToPriya: return DemoSeed.TutorialFixture.priyaOffsite
        default: return nil
        }
    }

    /// Whether a row's action tag gets the tutorial's highlight ring now.
    func highlightsTag(accountId: String, messageId: String) -> Bool {
        accountId == DemoSeed.demoAccountId && messageId == Self.tagTarget(for: step)
    }

    // MARK: - Locked actions

    /// A mail action the tutorial may run. Every other one is off while it
    /// runs (owner 2026-10-21), so a stray tap cannot act on the sample mail
    /// the steps need.
    enum MailGesture {
        /// Tapping an action tag, which runs its action.
        case tagTap
        /// Choosing a tag from the tag menu (teaching the right action).
        case retag
        /// Use Suggestion on the practice reply, once its edit ran.
        case useSuggestion
        /// Swipes, triage and every other mail action.
        case other
    }

    /// Whether the step asks for `gesture` on `messageId` (nil: no message).
    nonisolated static func allows(
        _ gesture: MailGesture, messageId: String?, step: Step?, replyEdited: Bool = false
    ) -> Bool {
        guard let messageId, messageId == tagTarget(for: step) else { return false }
        switch gesture {
        case .tagTap: return step == .archiveReceipt || step == .replyToPriya
        case .retag: return step == .retagDailyTech
        case .useSuggestion: return step == .replyToPriya && replyEdited
        case .other: return false
        }
    }

    /// Outside the tutorial, true. Inside it, true only for what the step
    /// asks for; otherwise shows the locked notice and returns false.
    func admits(_ gesture: MailGesture, accountId: String? = nil, messageId: String? = nil) -> Bool {
        guard isRunning else { return true }
        if accountId == DemoSeed.demoAccountId,
           Self.allows(gesture, messageId: messageId, step: step, replyEdited: replyEdited) {
            return true
        }
        showLockedNotice()
        return false
    }

    private func showLockedNotice() {
        lockedNoticeGeneration += 1
        let generation = lockedNoticeGeneration
        lockedNotice = Self.lockedNoticeText
        Task { @MainActor [weak self] in
            try? await Task.sleep(for: Self.lockedNoticeDuration)
            guard let self, generation == self.lockedNoticeGeneration else { return }
            self.lockedNotice = nil
        }
    }

    // MARK: - Found on their own

    /// The person did something a part teaches in the real app. Outside the
    /// tutorial, a part whose moves have all been found counts as done, as if
    /// they had taken it (owner 2026-10-25). The tutorial's own steps complete
    /// their parts themselves.
    func discovered(_ discovery: TutorialDiscovery) {
        guard !isRunning, !progress.completedLessons.contains(discovery.lesson) else { return }
        progress.markDiscovered(discovery)
        completedLessons = progress.completedLessons
    }

    // MARK: - Sidebar row

    var rowState: TutorialRowState? {
        TutorialProgress.rowState(completed: completedLessons)
    }
}
