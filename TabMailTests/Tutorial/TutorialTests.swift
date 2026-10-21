/* This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at https://mozilla.org/MPL/2.0/. */

import Foundation
import GRDB
import Testing
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

    @Test("The welcome is pending only between the fresh-install mark and a choice")
    func welcomeLifecycle() {
        let progress = TutorialProgress(defaults: isolatedDefaults())
        #expect(!progress.isWelcomePending)
        progress.markWelcomePending()
        #expect(progress.isWelcomePending)
        progress.dismissWelcome()
        #expect(!progress.isWelcomePending)
    }

    @Test("The row resumes the first unfinished part and turns into Replay when all are done")
    func rowState() {
        #expect(TutorialProgress.rowState(completed: []) == .progress(done: 0, total: 3, next: .actOnEmail))
        #expect(TutorialProgress.rowState(completed: [.actOnEmail]) == .progress(done: 1, total: 3, next: .reuseReply))
        // Out-of-order completion still resumes the earliest open part.
        #expect(TutorialProgress.rowState(completed: [.actOnEmail, .askAnything])
            == .progress(done: 2, total: 3, next: .reuseReply))
        #expect(TutorialProgress.rowState(completed: Set(TutorialLesson.allCases)) == .replay)
    }
}

// MARK: - Coach cards

@Suite("Tutorial coach cards — every step has its card where the user is")
struct TutorialCoachContentTests {
    typealias Step = TutorialCoordinator.Step

    private static let hosts: [TutorialCoachHost] = [
        .inbox, .chat, .compose(showingSuggestion: true), .compose(showingSuggestion: false), .message,
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

    @Test("A finished part says so and offers Next or a stop; the last one leads to the recap")
    func partEnds() throws {
        for (step, lesson) in [(Step.actOnEmailDone, TutorialLesson.actOnEmail), (.reuseReplyDone, .reuseReply)] {
            let card = try #require(TutorialCoachContent.make(step: step, lesson: lesson, host: .inbox, flightsAsked: false))
            #expect(card.progressLine.hasSuffix("· done"))
            let actions = card.buttons.map(\.action)
            #expect(actions.contains(.nextLesson) && actions.contains(.finishLater))
        }
        let last = try #require(TutorialCoachContent.make(step: .moreToAsk, lesson: .askAnything, host: .chat, flightsAsked: true))
        #expect(last.buttons.map(\.action) == [.showRecap])
        #expect(!last.examples.isEmpty)
    }

    @Test("Compose asks for Use Suggestion first, then Send")
    func composeFollowsTheSuggestion() throws {
        let before = try #require(TutorialCoachContent.make(
            step: .replyToPriya, lesson: .reuseReply, host: .compose(showingSuggestion: true), flightsAsked: false))
        let after = try #require(TutorialCoachContent.make(
            step: .replyToPriya, lesson: .reuseReply, host: .compose(showingSuggestion: false), flightsAsked: false))
        #expect(before.message.contains("Use Suggestion"))
        #expect(after.title.contains("Send"))
    }

    @Test("The chat input is filled in only at the chat steps, and the flight question only until it was asked")
    func chatPrompts() {
        typealias C = TutorialCoordinator
        #expect(C.chatPrompt(for: .makeTemplate, flightsAsked: false) == .makeTemplate)
        #expect(C.chatPrompt(for: .askFlights, flightsAsked: false) == .flights)
        #expect(C.chatPrompt(for: .askFlights, flightsAsked: true) == nil)
        #expect(C.chatPrompt(for: .moreToAsk, flightsAsked: true) == .whatCanYouDo)
        let withPrompt: Set<Step> = [.makeTemplate, .askFlights, .moreToAsk]
        for step in Self.allSteps where !withPrompt.contains(step) {
            #expect(C.chatPrompt(for: step, flightsAsked: false) == nil, "\(step) has nothing to send")
        }
        #expect(C.chatPrompt(for: nil, flightsAsked: false) == nil)
    }

    @Test("A card asks for Send only on a screen that has a Send button")
    func sendOnlyWhereItExists() {
        for lesson in TutorialLesson.allCases {
            for step in Self.allSteps {
                for flightsAsked in [false, true] {
                    for host in [TutorialCoachHost.inbox, .message] {
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
        store._resetForTests()
        store.isActive = true
        store.isTutorialPractice = true
        await #expect {
            _ = try await BackendClient().transcribeDictation(flac: Data([0]), language: nil, vocabulary: [])
        } throws: { error in
            if case BackendError.unauthorized = error { return true }
            return false
        }
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

        // Part 1, tap: the receipt really leaves the inbox (the demo move re-keys it).
        let provider = DemoProvider(accountId: DemoSeed.demoAccountId)
        _ = try await provider.performMessageAction(
            .move(destination: "ARCHIVE"),
            at: ProviderMessageSource(memberIds: [DemoSeed.TutorialFixture.receipt], folderPath: "INBOX", admittedUidValidity: nil))
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
        await AccountManager.shared.registerDemoProviders(
            email: DemoProvider(accountId: accountId),
            calendar: DemoCalendarProvider(accountId: accountId),
            accountId: accountId)
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
