/* This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at https://mozilla.org/MPL/2.0/. */

import Contacts
import Foundation
import GRDB
import ObjectiveC.runtime
import Synchronization
import SwiftUI
import Testing
import UIKit
import UserNotifications
@testable import TabMail

/// A throwaway UserDefaults suite, so no test touches the app's real state.
private func isolatedDefaults() -> UserDefaults {
    let name = "TutorialTests.\(UUID().uuidString)"
    let defaults = UserDefaults(suiteName: name)!
    defaults.removePersistentDomain(forName: name)
    return defaults
}

// MARK: - Progress and the sidebar row

@Suite("Tutorial progress — parts done, welcome, sidebar row")
struct TutorialProgressTests {
    @Test("Completed parts persist and a tutorial version bump forgets them")
    func completionPersistsPerVersion() {
        let defaults = isolatedDefaults()
        let progress = TutorialProgress(defaults: defaults)
        #expect(progress.completedLessons.isEmpty)

        progress.markCompleted(.actOnEmail)
        progress.markCompleted(.askAnything)
        progress.markCompleted(.actOnEmail)
        #expect(TutorialProgress(defaults: defaults).completedLessons == [.actOnEmail, .askAnything])

        defaults.set(TutorialProgress.version - 1, forKey: "tutorial.version")
        #expect(TutorialProgress(defaults: defaults).completedLessons.isEmpty)
    }

    @Test("Part 1 needs both a tag tap and a tag change; a template and an inbox chat each finish theirs")
    func discoveriesCompleteParts() {
        let defaults = isolatedDefaults()
        let progress = TutorialProgress(defaults: defaults)
        progress.markDiscovered(.tagTap)
        progress.markDiscovered(.tagTap)
        #expect(progress.completedLessons.isEmpty, "a tag tap alone is half of part 1")
        progress.markDiscovered(.retag)
        #expect(progress.completedLessons == [.actOnEmail])
        progress.markDiscovered(.inboxChat)
        #expect(progress.completedLessons == [.actOnEmail, .askAnything])
        progress.markDiscovered(.template)
        #expect(TutorialProgress(defaults: defaults).completedLessons == Set(TutorialLesson.allCases))
        #expect(TutorialProgress(defaults: defaults).discoveries == Set(TutorialDiscovery.allCases))
    }

    @Test("A write after a tutorial version bump does not revive the older version's progress")
    func versionBumpForgetsOnWrite() {
        let defaults = isolatedDefaults()
        let progress = TutorialProgress(defaults: defaults)
        for lesson in TutorialLesson.allCases { progress.markCompleted(lesson) }
        progress.markDiscovered(.retag)
        defaults.set(TutorialProgress.version - 1, forKey: "tutorial.version")

        progress.markDiscovered(.tagTap)
        #expect(progress.completedLessons.isEmpty, "the old retag does not pair with the new tag tap")
        #expect(progress.discoveries == [.tagTap])

        defaults.set(TutorialProgress.version - 1, forKey: "tutorial.version")
        progress.markCompleted(.reuseReply)
        #expect(progress.completedLessons == [.reuseReply])
        #expect(progress.discoveries.isEmpty)
    }

    @Test("The welcome is pending only between the fresh-install mark and a choice")
    func welcomeLifecycle() {
        let progress = TutorialProgress(defaults: isolatedDefaults())
        #expect(!progress.isWelcomePending)
        progress.markWelcomePending()
        #expect(progress.isWelcomePending)
        progress.dismissWelcome()
        #expect(!progress.isWelcomePending)
    }

    @Test("The row resumes the first unfinished part and is gone when all are done")
    func rowState() {
        #expect(TutorialProgress.rowState(completed: []) == TutorialRowState(done: 0, total: 3, next: .actOnEmail))
        #expect(TutorialProgress.rowState(completed: [.actOnEmail]) == TutorialRowState(done: 1, total: 3, next: .reuseReply))
        // Out-of-order completion still resumes the earliest open part.
        #expect(TutorialProgress.rowState(completed: [.actOnEmail, .askAnything])
            == TutorialRowState(done: 2, total: 3, next: .reuseReply))
        // Replay lives in the debug menu, not the sidebar (owner 2026-10-21).
        #expect(TutorialProgress.rowState(completed: Set(TutorialLesson.allCases)) == nil)
    }
}

// MARK: - Coach cards

@Suite("Tutorial coach cards — every step has its card where the user is")
struct TutorialCoachContentTests {
    typealias Step = TutorialCoordinator.Step

    private static let hosts: [TutorialCoachHost] = [
        .inbox, .compose(showingSuggestion: true), .compose(showingSuggestion: false), .message, .actionRules,
    ]

    private static let allSteps: [Step] = [
        .starting, .archiveReceipt, .receiptArchived, .retagDailyTech, .actOnEmailDone,
        .replyToPriya, .makeTemplate, .reuseReplyDone, .askFlights, .askAnythingDone, .moreToAsk, .finished,
    ]

    private func cards(_ step: Step, _ lesson: TutorialLesson, flightsAsked: Bool = false)
        -> [TutorialCoachContent] {
        Self.hosts.compactMap {
            TutorialCoachContent.make(step: step, lesson: lesson, host: $0, flightsAsked: flightsAsked)
        }
    }

    @Test("Every in-mail step shows a card on some screen; full-screen steps show none")
    func everyStepIsCovered() {
        let inMail: [(Step, TutorialLesson)] = [
            (.archiveReceipt, .actOnEmail), (.receiptArchived, .actOnEmail), (.retagDailyTech, .actOnEmail),
            (.actOnEmailDone, .actOnEmail),
            (.replyToPriya, .reuseReply), (.makeTemplate, .reuseReply), (.reuseReplyDone, .reuseReply),
            (.askFlights, .askAnything), (.askAnythingDone, .askAnything), (.moreToAsk, .askAnything),
        ]
        for (step, lesson) in inMail {
            #expect(!cards(step, lesson).isEmpty, "no card for \(step)")
        }
        for step in [Step.starting, .finished] {
            #expect(cards(step, .reuseReply).isEmpty, "\(step) is a full-screen step")
        }
    }

    /// Owner 2026-10-25: forward buttons say "Next", and no card offers a
    /// stop (Skip tutorial is always at the top right).
    @Test("A finished part says so and offers what it made plus Next; the last one leads to the recap")
    func partEnds() throws {
        let ends: [(Step, TutorialLesson, TutorialCoachContent.Action)] = [
            (.actOnEmailDone, .actOnEmail, .seeRule), (.reuseReplyDone, .reuseReply, .seeTemplate),
        ]
        for (step, lesson, see) in ends {
            let card = try #require(TutorialCoachContent.make(step: step, lesson: lesson, host: .inbox, flightsAsked: false))
            #expect(card.progressLine.hasSuffix("· done"))
            #expect(card.buttons.map(\.action) == [see, .nextLesson])
        }
        let received = try #require(TutorialCoachContent.make(
            step: .receiptArchived, lesson: .actOnEmail, host: .inbox, flightsAsked: false))
        #expect(received.buttons.map(\.label) == ["Next"])
        let rule = try #require(TutorialCoachContent.make(
            step: .actOnEmailDone, lesson: .actOnEmail, host: .actionRules, flightsAsked: false))
        #expect(rule.buttons.isEmpty, "the sheet closes with Done")
        let last = try #require(TutorialCoachContent.make(step: .moreToAsk, lesson: .askAnything, host: .inbox, flightsAsked: true))
        #expect(last.buttons.map(\.action) == [.showRecap])
        #expect(!last.examples.isEmpty)
    }

    @Test("Compose asks for the Edit first, then Use Suggestion, then Send")
    func composeFollowsTheSuggestion() throws {
        func compose(showingSuggestion: Bool, edited: Bool) throws -> TutorialCoachContent {
            try #require(TutorialCoachContent.make(
                step: .replyToPriya, lesson: .reuseReply, host: .compose(showingSuggestion: showingSuggestion),
                flightsAsked: false, replyEdited: edited))
        }
        #expect(try compose(showingSuggestion: true, edited: false).message.contains("Edit"))
        #expect(try compose(showingSuggestion: true, edited: true).message.contains("Use Suggestion"))
        #expect(try compose(showingSuggestion: false, edited: true).title.contains("Send"))
    }


    @Test("The chat input is filled in only at the chat steps, and the flight question only until it was asked")
    func chatPrompts() {
        typealias C = TutorialCoordinator
        #expect(C.chatPrompt(for: .makeTemplate, flightsAsked: false) == .makeTemplate)
        #expect(C.chatPrompt(for: .askFlights, flightsAsked: false) == .flights)
        #expect(C.chatPrompt(for: .askFlights, flightsAsked: true) == nil)
        #expect(C.chatPrompt(for: .moreToAsk, flightsAsked: true) == .whatCanYouDo)
        #expect(C.chatPrompt(for: .moreToAsk, flightsAsked: true, whatCanYouDoAsked: true) == nil)
        let withPrompt: Set<Step> = [.makeTemplate, .askFlights, .moreToAsk]
        for step in Self.allSteps where !withPrompt.contains(step) {
            #expect(C.chatPrompt(for: step, flightsAsked: false) == nil, "\(step) has nothing to send")
        }
        #expect(C.chatPrompt(for: nil, flightsAsked: false) == nil)
    }

    /// The open chat covers the card (owner 2026-10-25), so a closed chat's
    /// card must still say where the next tap is after the question was asked.
    @Test("After the flight question, the inbox card points back at the answer in Chat")
    func inboxCardAfterTheQuestion() throws {
        let before = try #require(TutorialCoachContent.make(
            step: .askFlights, lesson: .askAnything, host: .inbox, flightsAsked: false))
        let after = try #require(TutorialCoachContent.make(
            step: .askFlights, lesson: .askAnything, host: .inbox, flightsAsked: true))
        #expect(before.title != after.title)
        #expect(after.message.contains("email reference"))
    }

    @Test("A card asks for Send only on a screen that has a Send button")
    func sendOnlyWhereItExists() {
        for lesson in TutorialLesson.allCases {
            for step in Self.allSteps {
                for flightsAsked in [false, true] {
                    for host in [TutorialCoachHost.inbox, .message, .actionRules] {
                        guard let card = TutorialCoachContent.make(
                            step: step, lesson: lesson, host: host, flightsAsked: flightsAsked) else { continue }
                        #expect(!(card.title + " " + card.message).contains("Tap Send"), "\(step) on \(host)")
                    }
                }
            }
        }
    }

    @Test("While the practice reply waits out undo-send, the inbox says it is sending")
    func sendingWindow() throws {
        let sending = try #require(TutorialCoachContent.make(
            step: .replyToPriya, lesson: .reuseReply, host: .inbox, flightsAsked: false, isSending: true))
        #expect(sending.showsProgress)
        let idle = try #require(TutorialCoachContent.make(
            step: .replyToPriya, lesson: .reuseReply, host: .inbox, flightsAsked: false))
        #expect(idle.title != sending.title)
    }

    @Test("Only the tag a step asks for is highlighted")
    func tagTargets() {
        #expect(TutorialCoordinator.tagTarget(for: .archiveReceipt) == DemoSeed.TutorialFixture.receipt)
        #expect(TutorialCoordinator.tagTarget(for: .retagDailyTech) == DemoSeed.TutorialFixture.dailyTech)
        #expect(TutorialCoordinator.tagTarget(for: .replyToPriya) == DemoSeed.TutorialFixture.priyaOffsite)
        for step in [Step.receiptArchived, .actOnEmailDone, .makeTemplate, .askFlights, .moreToAsk] {
            #expect(TutorialCoordinator.tagTarget(for: step) == nil)
        }
        #expect(TutorialCoordinator.tagTarget(for: nil) == nil)
    }

    /// Owner 2026-10-21: a stray tap must not act on the sample mail the
    /// steps need. Exactly three gestures run, each on its own message.
    @Test("Only the gesture a step asks for runs, and only on its message")
    func lockedGestures() {
        let fixture = DemoSeed.TutorialFixture.self
        let allowed: Set<String> = [
            "\(Step.archiveReceipt) tagTap \(fixture.receipt)",
            "\(Step.replyToPriya) tagTap \(fixture.priyaOffsite)",
            "\(Step.retagDailyTech) retag \(fixture.dailyTech)",
        ]
        let gestures: [(TutorialCoordinator.MailGesture, String)] = [
            (.tagTap, "tagTap"), (.retag, "retag"), (.useSuggestion, "useSuggestion"), (.other, "other"),
        ]
        let ids: [String?] = [fixture.receipt, fixture.dailyTech, fixture.priyaOffsite, fixture.jordanFlights, nil]
        var admitted: Set<String> = []
        for step in Self.allSteps.map(Optional.some) + [nil] {
            for (gesture, name) in gestures {
                for id in ids where TutorialCoordinator.allows(gesture, messageId: id, step: step) {
                    admitted.insert("\(step.map { "\($0)" } ?? "nil") \(name) \(id ?? "nil")")
                }
            }
        }
        #expect(admitted == allowed)
        // Use Suggestion comes after the practice reply's edit, never before.
        #expect(TutorialCoordinator.allows(.useSuggestion, messageId: fixture.priyaOffsite, step: .replyToPriya, replyEdited: true))
        for step in Self.allSteps where step != .replyToPriya {
            #expect(!TutorialCoordinator.allows(.useSuggestion, messageId: fixture.priyaOffsite, step: step, replyEdited: true))
        }
    }

    @Test("Every card says which part it belongs to, as \"n of 3\", and no card says \"lesson\"")
    func progressLinesAndNoLessonWording() {
        for lesson in TutorialLesson.allCases {
            for step in Self.allSteps {
                for flightsAsked in [false, true] {
                    for card in cards(step, lesson, flightsAsked: flightsAsked) {
                        #expect(card.progressLine.hasPrefix("\(lesson.rawValue) of \(TutorialLesson.allCases.count) · \(lesson.title)"))
                        let text = ([card.progressLine, card.title, card.message] + card.examples + card.buttons.map(\.label))
                            .joined(separator: " ").lowercased()
                        #expect(!text.contains("lesson"), "\(step): \(text)")
                    }
                }
            }
        }
    }
}

// MARK: - Scripted chat and no network

/// Mutates `DemoModeStore.shared` (a global), so `.serialized` and `.processGlobalState`.
@Suite("Tutorial practice — scripted chat, nothing sent", .serialized, .processGlobalState)
@MainActor
struct TutorialPracticeTests {
    @MainActor
    final class RecordingSink: AgentUISink {
        private(set) var delivered: [AgentToolRouter.ActionConfirmation] = []
        func deliverConfirmation(_ confirmation: AgentToolRouter.ActionConfirmation) {
            delivered.append(confirmation)
            // The person taps Cancel: nothing is saved to the prompt store.
            confirmation.onRespond(false)
        }
    }

    @Test("The template step shows the real Create card for the reply as written")
    func templateCardUsesThePracticeReply() async throws {
        let sink = RecordingSink()
        let reply = "Count me in, see you at the offsite."
        let answer = await TutorialChatScript.answer(
            .makeTemplate, practiceReply: reply, invocation: ToolInvocation(uiSink: sink))
        try #require(sink.delivered.count == 1)
        let card = sink.delivered[0]
        #expect(card.action == .templateCreate)
        try #require(card.templates.count == 1)
        #expect(card.templates[0].name == TutorialChatScript.templateName)
        #expect(card.templates[0].exampleReplyPreview.contains("Count me in"))
        #expect(answer.contains("No template made"))
    }

    @Test("A tutorial prompt is answered by the script and never reaches the model; a typed turn does")
    func scriptedTurnsNeverReachTheModel() async throws {
        var modelCalls = 0
        let scripted = try await TutorialChatScript.response(for: .flights, invocation: ToolInvocation()) {
            modelCalls += 1
            return ChatResponse(text: "model", thinking: nil)
        }
        #expect(modelCalls == 0, "a scripted turn makes no AI call")
        #expect(scripted?.text.contains("[Email](") == true, "the scripted flight answer")
        let typed = try await TutorialChatScript.response(for: nil, invocation: ToolInvocation()) {
            modelCalls += 1
            return ChatResponse(text: "model", thinking: nil)
        }
        #expect(modelCalls == 1)
        #expect(typed?.text == "model")
    }

    @Test("The flight answer cites Jordan's email for its pill")
    func flightAnswerCitesTheSource() async {
        let answer = await TutorialChatScript.answer(.flights, practiceReply: nil, invocation: ToolInvocation())
        #expect(answer.contains("[Email]("))
    }

    @Test("Tutorial practice shows the seeded AI content even with demo AI off")
    func practiceShowsSeededContent() {
        let store = DemoModeStore.shared
        defer { store._resetForTests() }
        store._resetForTests()
        store.isActive = true
        store.aiEnabled = false
        #expect(store.hidesAIContent)
        store.isTutorialPractice = true
        #expect(!store.hidesAIContent)
    }

    @Test("No request leaves the device during the tutorial, even one sent without a token")
    func backendRefusesDuringPractice() async {
        let store = DemoModeStore.shared
        defer { store._resetForTests() }
        // A fake server, so a regressed refusal fails here rather than
        // reaching the real backend.
        let server = FakeHTTP.Scenario()
        defer { server.close() }
        store._resetForTests()
        store.isActive = true
        store.isTutorialPractice = true
        await #expect {
            _ = try await BackendClient(llmSession: server.session)
                .transcribeDictation(flac: Data([0]), language: nil, vocabulary: [])
        } throws: { error in
            if case BackendError.unauthorized = error { return true }
            return false
        }
        #expect(server.recordedCalls().isEmpty, "nothing may reach the server during the tutorial")
    }

    /// Every AI surface other than dictation (compose, inline edit, chat)
    /// goes through the completions request. Two-sided: the same call
    /// outside the tutorial reaches the fake server.
    @Test("No completions request leaves the device during the tutorial")
    func completionsRefusedDuringPractice() async throws {
        let store = DemoModeStore.shared
        defer { store._resetForTests() }
        let server = FakeHTTP.Scenario()
        defer { server.close() }
        server.register(
            path: "/completions/chat", method: "POST",
            response: .bytes(Data("event: final\ndata: {\"assistant\":\"ok\"}\n\n".utf8),
                             contentType: "text/event-stream"))
        let client = BackendClient(llmSession: server.session)
        let request = CompletionsRequest(messages: [], client_timezone: "UTC", disable_tools: nil)

        store._resetForTests()
        store.isActive = true
        store.isTutorialPractice = true
        await #expect {
            _ = try await client.sendCompletionsWithToolsDirect(request)
        } throws: { error in
            if case BackendError.unauthorized = error { return true }
            return false
        }
        #expect(server.recordedCalls().isEmpty, "nothing may reach the server during the tutorial")

        store._resetForTests()
        let answer = try await client.sendCompletionsWithToolsDirect(request)
        #expect(answer.assistant == "ok")
        #expect(server.servedCallSequence() == ["POST /completions/chat"],
                "control: outside the tutorial the same request is sent")
    }

    /// Callers that send only with a token (the dictation warm-up, account
    /// info, usage) get none during the tutorial, so no demo token is minted
    /// and nothing is sent. Two-sided: with a stored demo token, the plain
    /// demo sends the same warm-up.
    @Test("The tutorial has no token, even with a demo token stored")
    func noTokenDuringPractice() async throws {
        let store = DemoModeStore.shared
        defer {
            store._resetForTests()
            DemoTokenManager.clearSession()
        }
        let session = DemoTokenManager.DemoSession(
            accessToken: "test-demo-token", sub: "test",
            expiresAt: Int(Date().addingTimeInterval(3600).timeIntervalSince1970))
        try KeychainHelper.save(try JSONEncoder().encode(session), for: "demo_session")
        let server = FakeHTTP.Scenario()
        defer { server.close() }
        server.register(path: DictationConfig.warmUpPath, response: .status(200))
        let client = BackendClient(llmSession: server.session)

        store._resetForTests()
        store.isActive = true
        store.isTutorialPractice = true
        await client.warmUpDictation()
        #expect(server.recordedCalls().isEmpty, "nothing may reach the server during the tutorial")

        store.isTutorialPractice = false
        await client.warmUpDictation()
        #expect(server.servedCallSequence() == ["GET \(DictationConfig.warmUpPath)"],
                "control: the plain demo sends the warm-up with its token")
    }
}

// MARK: - Seeded demo: fixture ids and the facts the parts advance on

/// Seeds the real demo data into an installed `AppDatabase.shared` and registers
/// the demo providers, so it mutates global state: `.serialized` and `.processGlobalState`.
@Suite("Tutorial fixture — the seeded messages the parts point at", .serialized, .processGlobalState)
struct TutorialFixtureTests {
    private func install() throws -> (DatabasePool, URL, AppDatabase?) {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("tutorial-fixture-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        var configuration = Configuration()
        configuration.foreignKeysEnabled = true
        let pool = try DatabasePool(
            path: directory.appendingPathComponent("test.sqlite").path,
            configuration: configuration)
        let appDatabase = try AppDatabase(dbPool: pool)
        let previous = AppDatabase.shared.withLock { current -> AppDatabase? in
            let saved = current
            current = appDatabase
            return saved
        }
        return (pool, directory, previous)
    }

    private func finish(_ fixture: (DatabasePool, URL, AppDatabase?)) {
        InstalledTestDatabaseLifetime.finish(previous: fixture.2, pool: fixture.0, directory: fixture.1)
    }

    private func inboxHeader(_ db: Database, _ messageId: String) throws -> MessageHeader? {
        try MessageHeader
            .filter(Column("folderId") == "\(DemoSeed.demoAccountId):INBOX" && Column("messageId") == messageId)
            .fetchOne(db)
    }

    @Test("Each fixture id names the seeded message its part needs")
    func fixtureIdsMatchTheSeed() async throws {
        let fixture = try install()
        defer { finish(fixture) }
        try DemoSeed.seed()

        try await fixture.0.read { db in
            let receipt = try #require(try inboxHeader(db, DemoSeed.TutorialFixture.receipt))
            #expect(receipt.actionTag == .archive)
            #expect(receipt.fromAddress.hasSuffix("payflow.example"))

            let digest = try #require(try inboxHeader(db, DemoSeed.TutorialFixture.dailyTech))
            #expect(digest.actionTag == .archive)
            #expect(digest.subject.contains("DailyTech"))

            let priya = try #require(try inboxHeader(db, DemoSeed.TutorialFixture.priyaOffsite))
            #expect(priya.actionTag == .reply)
            #expect(!(priya.cachedReply ?? "").isEmpty)

            let jordan = try #require(try inboxHeader(db, DemoSeed.TutorialFixture.jordanFlights))
            let body = try #require(try MessageBody.fetchOne(db, key: ContentKey(rawValue: jordan.id)))
            // The scripted answer quotes the email's times.
            let scripted = TutorialChatScript.flightsAnswer(emailRef: 1)
            for time in ["5pm", "6:30pm", "$240"] {
                #expect(body.htmlContent?.contains(time) == true)
                #expect(scripted.contains(time))
            }
        }
    }

    /// The answer's email capsule opens the message it cites: the one whose
    /// text holds the times the answer quotes.
    @MainActor
    @Test("The flight answer's email capsule opens Jordan's email with the quoted times")
    func flightAnswerOpensItsSource() async throws {
        let fixture = try install()
        defer { finish(fixture) }
        try DemoSeed.seed()

        let answer = await TutorialChatScript.answer(.flights, practiceReply: nil, invocation: ToolInvocation())
        let reference = try #require(answer.firstMatch(of: #/\[Email\]\((\d+)\)/#))
        let numericId = try #require(Int(reference.1))
        let realId = try #require(await ChatIdTranslator.shared.toRealId(numericId))
        try await fixture.0.read { db in
            let source = try #require(try MessageHeader.fetchOne(db, key: realId), "the capsule names a seeded email")
            #expect(source.accountId == DemoSeed.demoAccountId)
            let body = try #require(try MessageBody.fetchOne(db, key: ContentKey(rawValue: source.id)))
            for time in ["5pm", "6:30pm", "$240"] {
                #expect(answer.contains(time))
                #expect(body.htmlContent?.contains(time) == true, "the cited email holds \(time)")
            }
        }
    }

    /// Registers the demo providers the way `DemoModeService.completeSetup` does.
    private func registerDemo() async {
        let accountId = DemoSeed.demoAccountId
        await AccountManager.shared.registerDemoProviders(
            email: DemoProvider(accountId: accountId),
            calendar: DemoCalendarProvider(accountId: accountId),
            accountId: accountId)
    }

    /// Runs the demo action queue until it is empty.
    private func drainActions(_ pool: DatabasePool) async throws {
        for _ in 0..<100 {
            await AccountManager.shared.drainPendingQueue()
            await AccountManager.shared.awaitWriteQueueDrain()
            if try await pool.read({ try PendingOperation.fetchCount($0) }) == 0 { return }
            try await Task.sleep(for: .milliseconds(50))
        }
        Issue.record("the demo action queue never drained")
    }

    @Test("Mail facts follow the demo mailbox: archive and retag")
    func mailFactsFollowTheMailbox() async throws {
        let fixture = try install()
        defer { finish(fixture) }
        try DemoSeed.seed()
        let pool = fixture.0

        let seeded = try await pool.read { try TutorialCoordinator.fetchMailFacts($0) }
        #expect(seeded.receiptInInbox)
        #expect(seeded.dailyTechTag == ActionTag.archive.rawValue)
        #expect(!seeded.sentMessageIds.isEmpty)

        // Part 1, tap: the Archive tag's real action takes the receipt out of the inbox.
        await registerDemo()
        let receipt = try #require(try await pool.read { try inboxHeader($0, DemoSeed.TutorialFixture.receipt) })
        await AccountManager.shared.archive([receipt])
        await AccountManager.shared.awaitWriteQueueDrain()
        try await drainActions(pool)
        await AccountManager.shared.unregisterDemoProviders(accountId: DemoSeed.demoAccountId)
        let archived = try await pool.read { try TutorialCoordinator.fetchMailFacts($0) }
        #expect(!archived.receiptInInbox)
        #expect(archived.dailyTechTag == ActionTag.archive.rawValue)

        // Part 1, hold: the digest's suggestion changes; the message stays.
        try await pool.write { db in
            try db.execute(
                sql: "UPDATE messageHeader SET actionTag = ? WHERE folderId = ? AND messageId = ?",
                arguments: [ActionTag.delete.rawValue, "\(DemoSeed.demoAccountId):INBOX", DemoSeed.TutorialFixture.dailyTech])
        }
        let retagged = try await pool.read { try TutorialCoordinator.fetchMailFacts($0) }
        #expect(retagged.dailyTechTag == ActionTag.delete.rawValue)
    }

    /// Part 1 shows the archived receipt with the existing Undo, and the demo
    /// queue drains the archive at once. Undo must still bring it back.
    @Test("Undo of a demo archive restores the message after the queue drained it")
    func demoArchiveUndoAfterDrain() async throws {
        let fixture = try install()
        defer { finish(fixture) }
        try DemoSeed.seed()
        let pool = fixture.0
        let accountId = DemoSeed.demoAccountId
        await registerDemo()

        let receipt = try #require(try await pool.read { try inboxHeader($0, DemoSeed.TutorialFixture.receipt) })
        let archivePath = try #require(try await pool.read { db in
            try Folder.filter(Column("accountId") == accountId && Column("role") == FolderRole.archive.rawValue)
                .fetchOne(db)?.path
        })
        await AccountManager.shared.archive([receipt])
        await AccountManager.shared.awaitWriteQueueDrain()
        try await drainActions(pool)
        #expect(!(try await pool.read { try TutorialCoordinator.fetchMailFacts($0) }).receiptInInbox,
                "setup: the archive must have landed")

        let restored = await AccountManager.shared.undoMove(
            accountId: accountId,
            forwardDestinationPath: archivePath,
            members: [UndoMember(header: receipt)])
        await AccountManager.shared.awaitWriteQueueDrain()
        try await drainActions(pool)
        await AccountManager.shared.unregisterDemoProviders(accountId: accountId)

        #expect(restored == [receipt.id], "Undo must accept the archive it is undoing")
        #expect(try await pool.read { try TutorialCoordinator.fetchMailFacts($0) }.receiptInInbox,
                "the receipt must be back in the inbox")
    }

    /// Part 2 advances only when the reply reaches Sent, and compose sends
    /// through the outbox. The demo account is registered the way
    /// `DemoModeService.completeSetup` does it, then the real drain runs.
    @Test("A demo send queued in the outbox reaches the demo Sent folder once")
    func demoOutboxSendReachesSent() async throws {
        let fixture = try install()
        defer { finish(fixture) }
        try DemoSeed.seed()
        let pool = fixture.0
        let accountId = DemoSeed.demoAccountId
        await registerDemo()
        let before = try await pool.read { try TutorialCoordinator.fetchMailFacts($0) }

        var queued = OutboxMessage(accountId: accountId, draft: DraftMessage(
            to: ["priya@company.com"], subject: "Re: Engineering offsite", body: "Count me in."))
        queued.holdUntil = Date().addingTimeInterval(-60)
        let row = queued
        try await pool.write { try row.insert($0) }
        await AccountManager.shared.drainOutbox()
        await AccountManager.shared.unregisterDemoProviders(accountId: accountId)

        let after = try await pool.read { try TutorialCoordinator.fetchMailFacts($0) }
        #expect(after.sentMessageIds.subtracting(before.sentMessageIds).count == 1)
        let remaining = try await pool.read { try OutboxMessage.fetchOne($0, key: row.id) }
        #expect(remaining == nil, "the sent message must leave the outbox")
    }
}

// MARK: - A whole run: start, real mail events, end

/// Drives `TutorialCoordinator.shared` through `DemoModeService` on an
/// installed database, as RootView does. Mutates the demo store, the
/// subscription gate and the shared coordinator: `.serialized` and
/// `.processGlobalState`.
@Suite("Tutorial run — starts offline, advances on mail events, ends clean", .serialized, .processGlobalState)
@MainActor
struct TutorialLifecycleTests {
    /// Taps Create on the template card.
    @MainActor
    final class AcceptingSink: AgentUISink {
        func deliverConfirmation(_ confirmation: AgentToolRouter.ActionConfirmation) {
            confirmation.onRespond(true)
        }
    }

    /// `readers` caps the pool's readers (one lets a test hold a read).
    private func install(readers: Int? = nil) throws -> (DatabasePool, URL, AppDatabase?) {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("tutorial-run-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        var configuration = Configuration()
        configuration.foreignKeysEnabled = true
        if let readers { configuration.maximumReaderCount = readers }
        let pool = try DatabasePool(
            path: directory.appendingPathComponent("test.sqlite").path,
            configuration: configuration)
        let appDatabase = try AppDatabase(dbPool: pool)
        let previous = AppDatabase.shared.withLock { current -> AppDatabase? in
            let saved = current
            current = appDatabase
            return saved
        }
        return (pool, directory, previous)
    }

    private func waitFor(_ step: TutorialCoordinator.Step) async throws {
        for _ in 0..<200 {
            if TutorialCoordinator.shared.step == step { return }
            try await Task.sleep(for: .milliseconds(25))
        }
        Issue.record("the tutorial never reached \(step); it is at \(String(describing: TutorialCoordinator.shared.step))")
    }

    @Test("A run opens the chat without AI, moves on real mail events, and its end switches the tutorial off")
    func runFromStartToEnd() async throws {
        let fixture = try install()
        let store = DemoModeStore.shared
        let gate = AISubscriptionGate.shared
        let gateWasActive = gate.isActive
        let progressKeys = ["tutorial.version", "tutorial.completedLessons", "tutorial.discoveries"]
        let savedProgress = progressKeys.map { UserDefaults.standard.object(forKey: $0) }
        defer {
            for (key, value) in zip(progressKeys, savedProgress) {
                UserDefaults.standard.set(value, forKey: key)
            }
            if gateWasActive { gate.openGate() } else { gate.closeGate() }
            store._resetForTests()
            InstalledTestDatabaseLifetime.finish(previous: fixture.2, pool: fixture.0, directory: fixture.1)
        }
        store._resetForTests()
        gate.closeGate()
        // No part done yet. Each completion re-reads these, so every
        // completed-part check below starts from nothing.
        for key in progressKeys { UserDefaults.standard.removeObject(forKey: key) }
        let pool = fixture.0
        let coordinator = TutorialCoordinator.shared
        try #require(!coordinator.isRunning)

        // Start: offline (no demo token), the tutorial switch on before the demo.
        await coordinator.start(.actOnEmail, hasTabMailSession: false)
        #expect(store.isTutorialPractice)
        #expect(store.isActive)
        #expect(coordinator.step == .starting)
        try await DemoModeService.shared.completeSetup()
        #expect(gate.isActive, "the scripted chat needs the pill even with demo AI off")
        coordinator.seedingFinished()
        #expect(coordinator.step == .archiveReceipt)
        // The mail observation has delivered the seeded inbox: no move yet.
        try await Task.sleep(for: .seconds(1))
        #expect(coordinator.step == .archiveReceipt, "the step waits for the archive itself")

        // Other mail actions are off, with a notice; the step's own tag runs.
        #expect(coordinator.lockedNotice == nil)
        #expect(!coordinator.admits(.tagTap, accountId: DemoSeed.demoAccountId, messageId: DemoSeed.TutorialFixture.dailyTech))
        #expect(coordinator.lockedNotice == TutorialCoordinator.lockedNoticeText)
        #expect(!coordinator.admits(.tagTap, accountId: "another-account", messageId: DemoSeed.TutorialFixture.receipt),
                "the demo's ids are not another account's")
        #expect(!coordinator.admits(.other))
        #expect(coordinator.admits(.tagTap, accountId: DemoSeed.demoAccountId, messageId: DemoSeed.TutorialFixture.receipt))

        // Part 1: the Archive tag, then the retag.
        let receipt = try #require(try await pool.read { db in
            try MessageHeader
                .filter(Column("folderId") == "\(DemoSeed.demoAccountId):INBOX"
                    && Column("messageId") == DemoSeed.TutorialFixture.receipt)
                .fetchOne(db)
        })
        await AccountManager.shared.archive([receipt])
        try await waitFor(.receiptArchived)
        coordinator.continueToRetag()
        #expect(coordinator.step == .retagDailyTech)
        try await pool.write { db in
            try db.execute(
                sql: "UPDATE messageHeader SET actionTag = ? WHERE folderId = ? AND messageId = ?",
                arguments: [ActionTag.delete.rawValue, "\(DemoSeed.demoAccountId):INBOX", DemoSeed.TutorialFixture.dailyTech])
        }
        try await waitFor(.actOnEmailDone)
        #expect(coordinator.completedLessons.contains(.actOnEmail))
        // "See rule": a sample rule, written only to the demo's prompt overlay.
        #expect(PromptStore.shared.deleteRules.contains(TutorialCoordinator.sampleDeleteRule))
        #expect(!coordinator.showsActionRule)
        coordinator.showActionRule()
        #expect(coordinator.showsActionRule)

        // Part 2: the reply reaches Sent, then Create saves the template.
        coordinator.nextLesson()
        #expect(coordinator.step == .replyToPriya)
        // The mail observation takes its Sent baseline from its first value,
        // and the seeded Sent folder is not empty.
        try await Task.sleep(for: .seconds(1))
        #expect(coordinator.step == .replyToPriya, "the step waits for the reply to reach Sent")
        #expect(!coordinator.highlightsTemplateCreate, "no proposal before the reply is sent")
        // The draft chat holds the edit; Use Suggestion waits for it.
        #expect(coordinator.composeEditPrompt == TutorialCoordinator.editPrompt)
        #expect(!coordinator.admits(.useSuggestion, accountId: DemoSeed.demoAccountId, messageId: DemoSeed.TutorialFixture.priyaOffsite))
        var edited: String?
        await coordinator.runPracticeReplyEdit { edited = $0 }
        #expect(edited == TutorialChatScript.declinedReply, "the draft receives the declined reply")
        #expect(coordinator.replyEdited)
        #expect(coordinator.composeEditPrompt == nil, "the edit is not offered again")
        #expect(coordinator.admits(.useSuggestion, accountId: DemoSeed.demoAccountId, messageId: DemoSeed.TutorialFixture.priyaOffsite))
        let reply = "Count me in."
        coordinator.practiceReplyAuthored(reply)
        // Sent the way compose sends the practice reply: no undo hold, so the
        // drain queueSend starts sends it at once (a held send would wait out
        // the hold, longer than `waitFor` waits).
        let draftId = "tutorial-practice-\(UUID().uuidString)"
        try await pool.write { db in
            var draft = Draft(
                id: draftId, accountId: DemoSeed.demoAccountId,
                toJSON: "[]", ccJSON: "[]", bccJSON: "[]",
                subject: "Re: Engineering offsite", body: reply, replyToId: nil,
                isForward: false, editHistoryJSON: nil,
                createdAt: Date().timeIntervalSince1970,
                updatedAt: Date().timeIntervalSince1970)
            draft.instanceEpoch = "E1"
            try draft.insert(db)
        }
        let demoAccount = try #require(try await pool.read { try Account.fetchOne($0, key: DemoSeed.demoAccountId) })
        let queued = try await AccountManager.shared.queueSend(
            draft: DraftMessage(to: ["priya@company.com"], subject: "Re: Engineering offsite", body: reply),
            from: demoAccount, draftId: draftId, instanceEpoch: "E1", holdsForUndo: false)
        #expect(queued.holdUntil == nil, "the practice reply has no undo hold")
        try await waitFor(.makeTemplate)
        #expect(coordinator.highlightsTemplateCreate, "the proposal's Create is the next tap")
        _ = await TutorialChatScript.answer(
            .makeTemplate, practiceReply: coordinator.practiceReplyText,
            invocation: ToolInvocation(uiSink: AcceptingSink()))
        try await waitFor(.reuseReplyDone)
        #expect(!coordinator.highlightsTemplateCreate, "the template is saved")
        #expect(coordinator.completedLessons.contains(.reuseReply))
        let templateId = try #require(coordinator.savedTemplateId)
        let template = try #require(PromptStore.shared.templates.first { $0.id == templateId })
        #expect(template.exampleReply == reply, "the template is made from the reply just sent")

        // Part 3: ask about the flights, then open the cited email.
        #expect(coordinator.highlightsChatClose, "the open chat covers the card with Next")
        coordinator.messageOpened(accountId: DemoSeed.demoAccountId, messageId: DemoSeed.TutorialFixture.jordanFlights)
        #expect(coordinator.step == .reuseReplyDone, "opening Jordan's email counts only in part 3")
        coordinator.nextLesson()
        #expect(coordinator.step == .askFlights)
        #expect(!coordinator.highlightsChatClose)
        #expect(coordinator.chatPrompt == .flights)
        #expect(!coordinator.highlightsEmailReference, "no answer to point at yet")
        coordinator.chatPromptSent(.flights)
        #expect(coordinator.chatPrompt == nil, "the asked question is not offered again")
        #expect(coordinator.highlightsEmailReference)
        #expect(!coordinator.highlightsChatClose, "the next tap is the email reference, not Close")
        coordinator.messageOpened(accountId: DemoSeed.demoAccountId, messageId: DemoSeed.TutorialFixture.receipt)
        #expect(coordinator.step == .askFlights, "only Jordan's email completes the part")
        coordinator.discovered(.inboxChat)
        #expect(!coordinator.completedLessons.contains(.askAnything), "inside the tutorial only its own steps complete a part")
        #expect(TutorialProgress().discoveries.isEmpty)
        coordinator.messageOpened(accountId: DemoSeed.demoAccountId, messageId: DemoSeed.TutorialFixture.jordanFlights)
        #expect(coordinator.step == .askAnythingDone)
        #expect(!coordinator.highlightsEmailReference)
        #expect(coordinator.completedLessons.contains(.askAnything))
        coordinator.showMoreToAsk()
        #expect(coordinator.step == .moreToAsk)
        #expect(coordinator.chatPrompt == .whatCanYouDo)
        #expect(!coordinator.highlightsChatClose, "Send is the next tap")
        coordinator.chatPromptSent(.whatCanYouDo)
        #expect(coordinator.chatPrompt == nil, "the question is not offered again")
        #expect(coordinator.highlightsChatClose, "Finish is on the card under the chat")
        coordinator.showRecap()
        #expect(coordinator.step == .finished)

        // End: the demo is gone and the backend is no longer refused.
        await coordinator.end()
        #expect(!coordinator.isRunning)
        #expect(coordinator.step == nil)
        #expect(!store.isActive)
        #expect(!store.isTutorialPractice, "a signed-in user's AI calls would stay refused until relaunch")
        #expect(!coordinator.showsActionRule)
        #expect(!PromptStore.shared.deleteRules.contains(TutorialCoordinator.sampleDeleteRule),
                "the sample rule leaves with the demo")
        #expect(coordinator.admits(.other), "outside the tutorial every mail action runs")
        #expect(coordinator.lockedNotice == nil)
    }

    @Test("Outside the tutorial, a part counts as done once its moves are found in the app")
    func discoveriesOutsideTheTutorial() throws {
        let progressKeys = ["tutorial.version", "tutorial.completedLessons", "tutorial.discoveries"]
        let savedProgress = progressKeys.map { UserDefaults.standard.object(forKey: $0) }
        let templateId = "tutorial-discovery-\(UUID().uuidString)"
        defer {
            PromptStore.shared.deleteTemplate(id: templateId)
            for (key, value) in zip(progressKeys, savedProgress) {
                UserDefaults.standard.set(value, forKey: key)
            }
        }
        for key in progressKeys { UserDefaults.standard.removeObject(forKey: key) }
        let coordinator = TutorialCoordinator.shared
        try #require(!coordinator.isRunning)

        // Creating a template anywhere goes through the store.
        PromptStore.shared.addTemplate(ReplyTemplate(id: templateId, name: "Discovery"))
        #expect(TutorialProgress().completedLessons.contains(.reuseReply))
        #expect(coordinator.completedLessons.contains(.reuseReply))

        coordinator.discovered(.retag)
        #expect(!coordinator.completedLessons.contains(.actOnEmail), "part 1 also needs a tag tap")
        coordinator.discovered(.tagTap)
        #expect(coordinator.completedLessons.contains(.actOnEmail))
        #expect(!coordinator.completedLessons.contains(.askAnything))
        coordinator.discovered(.inboxChat)
        #expect(coordinator.rowState == nil, "all three found: no sidebar row")
    }

    /// Starts a run at `lesson` and seeds it, as RootView does.
    private func startRun(_ lesson: TutorialLesson) async throws {
        await TutorialCoordinator.shared.start(lesson, hasTabMailSession: false)
        try await DemoModeService.shared.completeSetup()
        TutorialCoordinator.shared.seedingFinished()
    }

    /// The scripted edit waits before it lands. Skip and a new run during
    /// that wait must not let the old edit complete the new run's step.
    @Test("An edit begun in an ended run changes neither the draft nor the next run")
    func editFromAnEndedRunIsDropped() async throws {
        let fixture = try install()
        let store = DemoModeStore.shared
        let coordinator = TutorialCoordinator.shared
        defer {
            store._resetForTests()
            InstalledTestDatabaseLifetime.finish(previous: fixture.2, pool: fixture.0, directory: fixture.1)
        }
        store._resetForTests()
        try #require(!coordinator.isRunning)

        try await startRun(.reuseReply)
        try #require(coordinator.step == .replyToPriya)
        var edited: String?
        let edit = Task { await coordinator.runPracticeReplyEdit { edited = $0 } }
        await Task.yield()
        // Skip, then part 2 again, while the edit waits.
        await coordinator.end()
        try await startRun(.reuseReply)
        try #require(coordinator.step == .replyToPriya)
        await edit.value

        #expect(edited == nil, "the ended run's edit must not reach a draft")
        #expect(!coordinator.replyEdited, "the new run's reply is not edited")
        #expect(coordinator.composeEditPrompt == TutorialCoordinator.editPrompt, "the new run still offers its edit")
        #expect(!coordinator.admits(.useSuggestion, accountId: DemoSeed.demoAccountId, messageId: DemoSeed.TutorialFixture.priyaOffsite))
        await coordinator.end()
    }

    /// The debug menu offers Replay next to Enter Demo Mode. A Replay while an
    /// ordinary demo entry is still starting must not take the tutorial on.
    @Test("Replay while a demo is still starting leaves the tutorial off")
    func replayWhileADemoStartsIsRefused() async throws {
        let fixture = try install()
        let store = DemoModeStore.shared
        let coordinator = TutorialCoordinator.shared
        defer {
            store._resetForTests()
            InstalledTestDatabaseLifetime.finish(previous: fixture.2, pool: fixture.0, directory: fixture.1)
        }
        store._resetForTests()
        try #require(!coordinator.isRunning)

        // An ordinary demo start, still minting its token.
        store.startInProgress = true
        await coordinator.start(.actOnEmail, hasTabMailSession: true)
        #expect(!coordinator.isRunning)
        #expect(!store.isTutorialPractice, "the backend must not stay refused")
        #expect(coordinator.admits(.other), "real-mail actions must not stay locked")

        // Once that start is over, Replay runs.
        store.startInProgress = false
        await coordinator.start(.actOnEmail, hasTabMailSession: true)
        #expect(coordinator.isRunning)
        #expect(store.isActive)
        await coordinator.end()
    }

    /// RootView reports a demo exit it did not start (sign-in, the debug menu,
    /// a seeding failure) to the coordinator, which ends the run.
    @Test("A demo exit from outside the tutorial ends the run")
    func outsideDemoExitEndsTheRun() async throws {
        let fixture = try install()
        let store = DemoModeStore.shared
        let coordinator = TutorialCoordinator.shared
        defer {
            store._resetForTests()
            InstalledTestDatabaseLifetime.finish(previous: fixture.2, pool: fixture.0, directory: fixture.1)
        }
        store._resetForTests()
        try #require(!coordinator.isRunning)

        try await startRun(.actOnEmail)
        try #require(coordinator.isRunning)
        try #require(!coordinator.admits(.other))
        await DemoModeService.shared.exit()
        coordinator.demoDidExit()
        #expect(!coordinator.isRunning)
        #expect(coordinator.step == nil)
        #expect(!store.isTutorialPractice)
        #expect(coordinator.admits(.other), "real-mail actions are unlocked again")
    }

    /// The tutorial starts offline (no demo token) and its mail is local, so
    /// the practice reply must reach Sent with no network. A real account's
    /// send queued alongside it still waits for the network.
    @Test("Offline, the practice reply reaches Sent and moves part 2 on; a real send waits for the network")
    func practiceReplySendsOffline() async throws {
        let fixture = try install()
        let pool = fixture.0
        let store = DemoModeStore.shared
        let coordinator = TutorialCoordinator.shared
        let realAccountId = "acc-offline-\(UUID().uuidString)"
        let realProvider = MockEmailProvider()
        let wasConnected = NetworkMonitor.checkConnected()
        defer {
            NetworkMonitor.setConnectedForTesting(wasConnected)
            Task { await AccountManager.shared.unregisterProviderForTesting(accountId: realAccountId) }
            store._resetForTests()
            InstalledTestDatabaseLifetime.finish(previous: fixture.2, pool: fixture.0, directory: fixture.1)
        }
        store._resetForTests()
        try #require(!coordinator.isRunning)

        try await startRun(.reuseReply)
        try #require(coordinator.step == .replyToPriya)
        try await pool.write { db in
            var account = Account(emailAddress: "real@example.com", displayName: "Real", provider: .imap)
            account.id = realAccountId
            try account.insert(db)
        }
        // The test host's RootView starts the real path monitor for each new
        // database, and its first update sets the cached value back to
        // connected; a drain decides online or offline once, when it starts.
        // Hold offline until that update has landed and no drain begun online
        // is still running.
        let heldOffline = await eventually {
            NetworkMonitor.setConnectedForTesting(false)
            try? await Task.sleep(for: .milliseconds(250))
            let draining = await AccountManager.shared.isDrainingOutbox
            return !NetworkMonitor.checkConnected() && !draining
        }
        try #require(heldOffline)
        await AccountManager.shared.registerProviderForTesting(accountId: realAccountId, provider: realProvider)
        var realSend = OutboxMessage(accountId: realAccountId, draft: DraftMessage(
            to: ["someone@example.com"], subject: "Real mail", body: "Sent once online."))
        realSend.holdUntil = Date().addingTimeInterval(-60)
        let realRow = realSend
        try await pool.write { try realRow.insert($0) }
        let draftId = "tutorial-practice-\(UUID().uuidString)"
        try await pool.write { db in
            var draft = Draft(
                id: draftId, accountId: DemoSeed.demoAccountId,
                toJSON: "[]", ccJSON: "[]", bccJSON: "[]",
                subject: "Re: Engineering offsite", body: "Count me in.", replyToId: nil,
                isForward: false, editHistoryJSON: nil,
                createdAt: Date().timeIntervalSince1970,
                updatedAt: Date().timeIntervalSince1970)
            draft.instanceEpoch = "E1"
            try draft.insert(db)
        }
        let demoAccount = try #require(try await pool.read { try Account.fetchOne($0, key: DemoSeed.demoAccountId) })
        let queued = try await AccountManager.shared.queueSend(
            draft: DraftMessage(to: ["priya@company.com"], subject: "Re: Engineering offsite", body: "Count me in."),
            from: demoAccount, draftId: draftId, instanceEpoch: "E1", holdsForUndo: false)
        try await waitFor(.makeTemplate)
        // queueSend's own drain sends it; the row leaves once that send finalizes.
        let practiceLeft = try await eventually {
            try await pool.read { try OutboxMessage.fetchOne($0, key: queued.outboxId) } == nil
        }
        #expect(practiceLeft, "the practice reply left the outbox")
        #expect(!NetworkMonitor.checkConnected(), "the network stayed off through the drain")
        let waiting = try await pool.read { try OutboxMessage.fetchOne($0, key: realRow.id) }
        #expect(waiting?.status == OutboxStatus.queued.rawValue, "the real send waits for the network")
        #expect(await realProvider.sentDrafts.isEmpty, "nothing was sent through the real account offline")

        // Back online, the same real row sends (a drain still running returns
        // the next one at once, so drain until it has).
        NetworkMonitor.setConnectedForTesting(true)
        let realSent = await eventually {
            await AccountManager.shared.drainOutbox()
            return await !realProvider.sentDrafts.isEmpty
        }
        #expect(realSent)
        #expect(await realProvider.sentDrafts.map(\.subject) == ["Real mail"])
        await coordinator.end()
    }

    /// Polls `condition` for up to five seconds.
    private func eventually(_ condition: () async throws -> Bool) async rethrows -> Bool {
        for _ in 0..<200 {
            if try await condition() { return true }
            try? await Task.sleep(for: .milliseconds(25))
        }
        return false
    }

    /// A demo only turns on over a wiped memory index. When the last demo's
    /// memory turns cannot be deleted, the start fails: the tutorial must end
    /// up off and unlocked, not hold the failed run, and a later start runs.
    @Test("A failed start leaves the tutorial off and unlocked, and the next start runs")
    func failedStartRollsBackAndRetries() async throws {
        let fixture = try install()
        let store = DemoModeStore.shared
        let coordinator = TutorialCoordinator.shared
        await MemoryIndex.shared._testReset()
        await MemorySearchCache.shared.reset()
        let memDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("tutorial-memory-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: memDir, withIntermediateDirectories: true)
        var memConfig = Configuration()
        memConfig.prepareDatabase { db in
            if let sqliteConn = db.sqliteConnection {
                _ = tabmail_register_sqlite_vec_on_db(UnsafeMutableRawPointer(sqliteConn))
            }
            try db.execute(sql: "PRAGMA journal_mode = WAL")
        }
        let memPool = try DatabasePool(path: memDir.appendingPathComponent("memory.db").path, configuration: memConfig)
        try await MemoryIndex.shared._testInstallPool(memPool)
        defer {
            store._resetForTests()
            Task {
                await MemoryIndex.shared._testReset()
                await MemorySearchCache.shared.reset()
                TestDatabaseTeardown.retire(pool: memPool, directory: memDir)
            }
            InstalledTestDatabaseLifetime.finish(previous: fixture.2, pool: fixture.0, directory: fixture.1)
        }
        store._resetForTests()
        try #require(!coordinator.isRunning)
        let progressBefore = coordinator.completedLessons

        // A turn an earlier demo left behind, which cannot be deleted.
        await DemoRunFixture.indexTurn(
            chatHistoryId: "left-over", sessionId: "demo:left-over", role: "user",
            dateMs: Int64(Date().timeIntervalSince1970 * 1000), text: "left over")
        try #require(await MemoryIndex.shared.knownChatHistoryIds().contains("left-over"))
        try await memPool.write { db in
            try db.execute(sql: "CREATE TRIGGER refuse_demo_wipe BEFORE DELETE ON memory_meta BEGIN SELECT RAISE(ABORT, 'refused'); END")
        }

        await coordinator.start(.actOnEmail, hasTabMailSession: false)
        #expect(coordinator.startError != nil, "the failure is shown")
        #expect(!coordinator.isRunning, "the failed run is not kept")
        #expect(coordinator.step == nil)
        #expect(!store.isActive, "no demo runs over the old turns")
        #expect(!store.isTutorialPractice, "the backend is not left refused")
        #expect(coordinator.admits(.other), "real-mail actions are not left locked")
        #expect(coordinator.completedLessons == progressBefore, "progress is untouched")

        // Once the wipe works, the next start runs.
        try await memPool.write { db in try db.execute(sql: "DROP TRIGGER refuse_demo_wipe") }
        await coordinator.start(.actOnEmail, hasTabMailSession: false)
        #expect(coordinator.isRunning)
        #expect(store.isActive)
        #expect(!(await MemoryIndex.shared.knownChatHistoryIds().contains("left-over")))
        await coordinator.end()
    }

    /// The demo can end while its setup is suspended: a notification tap ends
    /// the tutorial during the seeding splash, which also runs next to a live
    /// account. The setup must not carry on after that exit: its prompt
    /// overlay would write the bundled defaults over the real prompts.
    @Test("A demo that ends during its setup leaves the real prompts and providers alone")
    func exitDuringSetupKeepsRealPrompts() async throws {
        let fixture = try install(readers: 1)
        let pool = fixture.0
        let store = DemoModeStore.shared
        let prompts = PromptStore.shared
        let kbKey = "user_prompts:user_kb.md"
        let savedKB = prompts.rawKB
        defer {
            store._resetForTests()
            prompts.rawKB = savedKB
            InstalledTestDatabaseLifetime.finish(previous: fixture.2, pool: fixture.0, directory: fixture.1)
        }
        store._resetForTests()
        let realKB = "- real kb \(UUID().uuidString)"
        prompts.rawKB = realKB
        let realTemplateIds = prompts.templates.map(\.id)

        try await DemoModeService.shared.start(mintToken: false)
        try #require(store.isActive)
        // Park the setup at its first read: the pool's one reader is held.
        let release = DispatchSemaphore(value: 0)
        let finished = DispatchSemaphore(value: 0)
        await withCheckedContinuation { (held: CheckedContinuation<Void, Never>) in
            DispatchQueue.global().async {
                _ = try? pool.read { _ in
                    held.resume()
                    release.wait()
                }
                finished.signal()
            }
        }
        let setup = Task { try await DemoModeService.shared.completeSetup() }
        let seeded = try await eventually {
            try await pool.write { try Account.fetchOne($0, key: DemoSeed.demoAccountId) } != nil
        }
        try #require(seeded, "the setup seeded, then waits on its read")

        // The demo ends while the setup waits.
        await DemoModeService.shared.exit()
        try #require(!store.isActive)
        release.signal()
        await withCheckedContinuation { (done: CheckedContinuation<Void, Never>) in
            DispatchQueue.global().async {
                finished.wait()
                done.resume()
            }
        }
        try await setup.value

        #expect(prompts.rawKB == realKB, "the real KB is not replaced")
        #expect(UserDefaults.standard.string(forKey: kbKey) == realKB, "the stored real KB is not replaced")
        #expect(prompts.templates.map(\.id) == realTemplateIds, "the real templates are not replaced")
        #expect(await AccountManager.shared.provider(accountId: DemoSeed.demoAccountId) == nil,
                "no demo provider is left registered")
        let demoAccount = try await pool.read { try Account.fetchOne($0, key: DemoSeed.demoAccountId) }
        #expect(demoAccount == nil, "no demo mail is left behind")
    }

    /// Waits on a background thread until `semaphore` is signalled.
    private func wait(for semaphore: DispatchSemaphore) async {
        await withCheckedContinuation { (done: CheckedContinuation<Void, Never>) in
            DispatchQueue.global().async {
                semaphore.wait()
                done.resume()
            }
        }
    }

    /// End (a notification tap) can come while the start is still wiping the
    /// last demo's leftovers, before the demo is on. The older start must not
    /// turn the demo on after the newer End.
    @Test("Ending a tutorial whose demo is still starting keeps it ended")
    func endWhileStartIsPending() async throws {
        let fixture = try install()
        let pool = fixture.0
        let store = DemoModeStore.shared
        let coordinator = TutorialCoordinator.shared
        let release = DispatchSemaphore(value: 0)
        let finished = DispatchSemaphore(value: 0)
        defer {
            release.signal()
            store._resetForTests()
            coordinator.demoDidExit()
            InstalledTestDatabaseLifetime.finish(previous: fixture.2, pool: fixture.0, directory: fixture.1)
        }
        store._resetForTests()
        try #require(!coordinator.isRunning)

        // Park the start's wipe: the pool's writer is held.
        await withCheckedContinuation { (held: CheckedContinuation<Void, Never>) in
            DispatchQueue.global().async {
                _ = try? pool.write { _ in
                    held.resume()
                    release.wait()
                }
                finished.signal()
            }
        }
        let start = Task { await coordinator.start(.actOnEmail, hasTabMailSession: true) }
        let pending = await eventually { coordinator.isRunning && store.startInProgress }
        try #require(pending, "the start is on its way")
        try #require(!store.isActive, "the demo is not on before its wipe")

        await coordinator.end()
        try #require(!coordinator.isRunning)
        release.signal()
        await wait(for: finished)
        await start.value

        #expect(!store.isActive, "the older start does not turn the demo on after End")
        #expect(!store.isTutorialPractice)
        #expect(!coordinator.isRunning)
        #expect(coordinator.admits(.other), "real-mail actions are unlocked")

        // The next start runs.
        try await startRun(.actOnEmail)
        #expect(store.isActive)
        #expect(coordinator.step == .archiveReceipt)
        await coordinator.end()
    }

    /// Stands in for `UNUserNotificationCenter.requestAuthorization`: answers
    /// "denied" with no system alert. RootView asks when a tutorial ends, and
    /// the alert leaves the test host's scene inactive, where a newly shown
    /// view's `.task` does not start.
    private static func silentNotificationRequest() -> IMP {
        typealias Completion = @convention(block) (Bool, NSError?) -> Void
        let block: @convention(block) (AnyObject, UInt, @escaping Completion) -> Void = { _, _, completion in
            completion(false, nil)
        }
        return imp_implementationWithBlock(block)
    }

    /// RootView sets the demo up behind a splash, where the inbox (and its
    /// notification handler) is not on screen. A notification tap there still
    /// ends the tutorial, and the next run gets its own setup.
    @Test("A notification tap during the setup splash ends the tutorial, and the next run is set up")
    func notificationDuringSplashEndsTheRun() async throws {
        let fixture = try install(readers: 1)
        let pool = fixture.0
        let store = DemoModeStore.shared
        let coordinator = TutorialCoordinator.shared
        let release = DispatchSemaphore(value: 0)
        let finished = DispatchSemaphore(value: 0)
        defer {
            release.signal()
            _ = PendingDeepLinkStore.consume()
            store._resetForTests()
            coordinator.demoDidExit()
            InstalledTestDatabaseLifetime.finish(previous: fixture.2, pool: fixture.0, directory: fixture.1)
        }
        store._resetForTests()
        try #require(!coordinator.isRunning)
        let request = try #require(class_getInstanceMethod(
            UNUserNotificationCenter.self, NSSelectorFromString("requestAuthorizationWithOptions:completionHandler:")))
        let silent = Self.silentNotificationRequest()
        let systemRequest = method_setImplementation(request, silent)
        defer {
            method_setImplementation(request, systemRequest)
            imp_removeBlock(silent)
        }

        // Park the setup at its first read: the pool's one reader is held.
        await withCheckedContinuation { (held: CheckedContinuation<Void, Never>) in
            DispatchQueue.global().async {
                _ = try? pool.read { _ in
                    held.resume()
                    release.wait()
                }
                finished.signal()
            }
        }
        // A fresh app root view in place of the test host's (two would both
        // set the demo up): it sets the demo up behind its splash, nothing
        // here calls the setup.
        let scene = try #require(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let window = try #require(scene.windows.first)
        let hostRoot = window.rootViewController
        window.rootViewController = UIHostingController(rootView: RootView().environment(NavigationStore()))
        window.makeKeyAndVisible()
        window.layoutIfNeeded()
        defer { window.rootViewController = hostRoot }

        await coordinator.start(.actOnEmail, hasTabMailSession: true)
        try #require(store.isActive)
        let seeded = try await eventually {
            try await pool.write { try Account.fetchOne($0, key: DemoSeed.demoAccountId) } != nil
        }
        try #require(seeded, "RootView is setting the demo up behind its splash")
        try #require(coordinator.step == .starting)

        PendingDeepLinkStore.store(.message(id: "tapped-message", accountId: "tapped-account"))
        NotificationCenter.default.post(
            name: .proactiveNotificationTapped, object: nil,
            userInfo: ["messageId": "tapped-message", "accountId": "tapped-account"])
        let ended = await eventually { !coordinator.isRunning && !store.isActive }
        #expect(ended, "the tap ends the tutorial during the splash")

        // The ended run's setup gets its read and stops.
        release.signal()
        await wait(for: finished)
        try await Task.sleep(for: .milliseconds(300))

        await coordinator.start(.actOnEmail, hasTabMailSession: true)
        let begun = await eventually { coordinator.step == .archiveReceipt }
        #expect(begun, "the next run is set up and begins")
        await coordinator.end()
    }

    /// The demo account's sends drain offline; a real message that was sent
    /// but whose Sent copy failed waits for the network, then is copied once.
    @Test("Offline, a real message's pending Sent copy waits, then is copied without a resend")
    func pendingRealSentCopyWaitsOffline() async throws {
        let fixture = try install()
        let pool = fixture.0
        let store = DemoModeStore.shared
        let coordinator = TutorialCoordinator.shared
        let provider = MockEmailProvider()
        let accountId = "acc-append-\(UUID().uuidString)"
        let wasConnected = NetworkMonitor.checkConnected()
        defer {
            NetworkMonitor.setConnectedForTesting(wasConnected)
            Task { await AccountManager.shared.unregisterProviderForTesting(accountId: accountId) }
            store._resetForTests()
            InstalledTestDatabaseLifetime.finish(previous: fixture.2, pool: fixture.0, directory: fixture.1)
        }
        store._resetForTests()
        try #require(!coordinator.isRunning)

        try await startRun(.reuseReply)
        let account = try await pool.write { db -> Account in
            var account = Account(emailAddress: "sender@example.com", displayName: "Sender", provider: .imap)
            account.id = accountId
            try account.insert(db)
            try Folder(name: "Sent", path: "SENT", role: .sent, accountId: accountId).insert(db)
            var draft = Draft(
                id: "append-draft", accountId: accountId,
                toJSON: "[]", ccJSON: "[]", bccJSON: "[]",
                subject: "Pending copy", body: "Copy this later.", replyToId: nil,
                isForward: false, editHistoryJSON: nil,
                createdAt: Date().timeIntervalSince1970,
                updatedAt: Date().timeIntervalSince1970)
            draft.instanceEpoch = "E1"
            try draft.insert(db)
            return account
        }
        await AccountManager.shared.registerProviderForTesting(accountId: accountId, provider: provider)
        // Online, the send goes out but its Sent copy fails: the row stays,
        // sent, for the copy to be retried.
        await provider.setAppendToSentResult(false)
        NetworkMonitor.setConnectedForTesting(true)
        let queued = try await AccountManager.shared.queueSend(
            draft: DraftMessage(to: ["recipient@example.com"], subject: "Pending copy", body: "Copy this later."),
            from: account, draftId: "append-draft", instanceEpoch: "E1", holdsForUndo: false)
        let awaitingCopy = try await eventually {
            let row = try await pool.read { try OutboxMessage.fetchOne($0, key: queued.outboxId) }
            let draining = await AccountManager.shared.isDrainingOutbox
            return row?.sentAt != nil && !draining
        }
        try #require(awaitingCopy, "the message was sent and its Sent copy is pending")
        try #require(await provider.sentDrafts.count == 1)
        try #require(await provider.appendedToSent.count == 1)

        // Offline (held as in `practiceReplySendsOffline`), the copy waits.
        let heldOffline = await eventually {
            NetworkMonitor.setConnectedForTesting(false)
            try? await Task.sleep(for: .milliseconds(250))
            let draining = await AccountManager.shared.isDrainingOutbox
            return !NetworkMonitor.checkConnected() && !draining
        }
        try #require(heldOffline)
        await provider.setAppendToSentResult(true)
        await AccountManager.shared.drainOutbox()
        #expect(!NetworkMonitor.checkConnected())
        #expect(await provider.appendedToSent.count == 1, "no Sent copy is attempted offline")
        let retained = try await pool.read { try OutboxMessage.fetchOne($0, key: queued.outboxId) }
        #expect(retained?.sentAt != nil && retained?.appendedToSent == false, "the pending copy is kept")

        // Back online, the copy is made once and the message is not resent.
        NetworkMonitor.setConnectedForTesting(true)
        let copied = try await eventually {
            await AccountManager.shared.drainOutbox()
            return try await pool.read { try OutboxMessage.fetchOne($0, key: queued.outboxId) } == nil
        }
        #expect(copied)
        #expect(await provider.appendedToSent.count == 2)
        #expect(await provider.sentDrafts.count == 1, "the message is not sent again")
        await coordinator.end()
    }

    private final class Calls: Sendable {
        let count = Mutex(0)
    }

    /// Stands in for `CNContactStore.requestAccess(for:completionHandler:)`:
    /// counts the request and answers "denied", with no system prompt.
    private static func countingContactsRequest(_ calls: Calls) -> IMP {
        typealias Completion = @convention(block) (Bool, NSError?) -> Void
        let block: @convention(block) (AnyObject, Int, @escaping Completion) -> Void = { _, _, completion in
            calls.count.withLock { $0 += 1 }
            completion(false, nil)
        }
        return imp_implementationWithBlock(block)
    }

    /// Compose asks for Contacts access when it opens; the tutorial's
    /// practice reply must not raise that prompt.
    @Test("Compose asks for Contacts access outside the tutorial, never during it")
    func noContactsPromptDuringTheTutorial() async throws {
        let fixture = try install()
        let store = DemoModeStore.shared
        let coordinator = TutorialCoordinator.shared
        let method = try #require(class_getInstanceMethod(
            CNContactStore.self, NSSelectorFromString("requestAccessForEntityType:completionHandler:")))
        let calls = Calls()
        let replacement = Self.countingContactsRequest(calls)
        let original = method_setImplementation(method, replacement)
        defer {
            method_setImplementation(method, original)
            imp_removeBlock(replacement)
            store._resetForTests()
            coordinator.demoDidExit()
            InstalledTestDatabaseLifetime.finish(previous: fixture.2, pool: fixture.0, directory: fixture.1)
        }
        store._resetForTests()
        try #require(!coordinator.isRunning)

        let contacts = ContactSearchService()
        contacts.requestAccess()
        let asked = await eventually { calls.count.withLock { $0 } == 1 }
        try #require(asked, "outside the tutorial the request reaches Contacts")

        try await startRun(.reuseReply)
        contacts.requestAccess()
        try await Task.sleep(for: .milliseconds(500))
        #expect(calls.count.withLock { $0 } == 1, "no Contacts request during the tutorial")
        await coordinator.end()
    }

    /// Every way out of the demo (sign-in, the debug menu, a seeding failure)
    /// goes through `DemoModeService.exit`, not only the coordinator's `end`.
    @Test("Leaving the demo by any route switches the tutorial off")
    func demoExitEndsPractice() async throws {
        let fixture = try install()
        let store = DemoModeStore.shared
        defer {
            store._resetForTests()
            InstalledTestDatabaseLifetime.finish(previous: fixture.2, pool: fixture.0, directory: fixture.1)
        }
        store._resetForTests()
        store.isTutorialPractice = true
        try await DemoModeService.shared.start(mintToken: false)
        try #require(store.isActive)
        await DemoModeService.shared.exit()
        #expect(!store.isActive)
        #expect(!store.isTutorialPractice, "a signed-in user's AI calls would stay refused until relaunch")
    }
}
