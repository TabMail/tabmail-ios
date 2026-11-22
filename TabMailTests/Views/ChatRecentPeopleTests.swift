/* This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at https://mozilla.org/MPL/2.0/. */

import Foundation
import GRDB
import SwiftUI
import Testing
import UIKit
@testable import TabMail

/// A new email's "Add recipient" sheet lists the people the user recently sent email to
/// (ADR-IOS-114 decision 24): who they are, read from the Sent folders as the sheet opens, and
/// what a tap on one does.
@Suite("Recent people for a new email")
struct ChatRecentPeopleTests {
    static let account = "chat-recent-people"
    static let own: Set<String> = ["me@example.com", "me@company.com"]

    /// An email from the user, `minutesAgo` before now.
    static func email(
        _ id: String, to: String, cc: String = "", minutesAgo: Double,
        accountId: String = Self.account, folder: String = "Sent"
    ) -> MessageHeader {
        var header = MessageHeader(
            messageId: id, subject: "Note \(id)", from: "Me", fromAddress: "me@example.com", to: to,
            date: Date().addingTimeInterval(-minutesAgo * 60), snippet: "Note \(id)",
            folderId: MessageIdentity.folderId(accountId: accountId, folderPath: folder),
            accountId: accountId, folderPath: folder, isInInbox: folder == "INBOX")
        header.cc = cc
        header.rfc822MessageId = "\(id)@example.com"
        header.headerComplete = true
        return header
    }

    @Test("Newest email first, To before Cc, each person once whatever the case, never the user")
    func orderAndOnce() {
        let sent = [
            Self.email("3", to: "Maria Lopez <maria@example.com>, me@company.com", cc: "sam@example.com", minutesAgo: 1),
            Self.email("2", to: "SAM@example.com", cc: "Jordan Lee <jordan@example.com>, me@example.com", minutesAgo: 10),
            Self.email("1", to: "maria@example.com, kim@example.com", minutesAgo: 100),
        ]
        let people = ChatRecentPeople.people(sentNewestFirst: sent, ownAddresses: Self.own, limit: 10)
        #expect(people.map(\.address) == ["maria@example.com", "sam@example.com", "jordan@example.com", "kim@example.com"])
    }

    @Test("At most the limit: the newest people are kept")
    func limit() {
        let sent = [
            Self.email("2", to: "a@example.com, b@example.com", minutesAgo: 1),
            Self.email("1", to: "c@example.com", minutesAgo: 10),
        ]
        let two = ChatRecentPeople.people(sentNewestFirst: sent, ownAddresses: Self.own, limit: 2)
        #expect(two.map(\.address) == ["a@example.com", "b@example.com"])
        let none = ChatRecentPeople.people(sentNewestFirst: sent, ownAddresses: Self.own, limit: 0)
        #expect(none.isEmpty)
    }

    @Test("A person goes by the newest name an email gives them, an older one when the newest gives none, else the address's own")
    func names() {
        let sent = [
            Self.email("3", to: "maria@example.com, Sam P <sam@example.com>", minutesAgo: 1),
            Self.email("2", to: "Maria Lopez <maria@example.com>, Samuel Patel <sam@example.com>", minutesAgo: 10),
            Self.email("1", to: "Maria L <maria@example.com>, kim@example.com", minutesAgo: 100),
        ]
        let people = ChatRecentPeople.people(sentNewestFirst: sent, ownAddresses: Self.own, limit: 10)
        #expect(people.map(\.name) == ["Maria Lopez", "Sam P", ChatThread.fallbackName("kim@example.com")])
    }

    @Test("A Recent row offers only someone not in the list; once added they are in the list, ticked")
    func recentRowsAreTheUnlisted() {
        let maria = ChatThread.Person(address: "maria@example.com", name: "Maria")
        let sam = ChatThread.Person(address: "sam@example.com", name: "Sam")
        let jordan = ChatThread.Person(address: "jordan@example.com", name: "Jordan")
        var choice = ChatReplyToChoice(replyPeople: [maria], target: .replyAll)
        #expect(choice.unlisted([maria, sam, jordan]) == [sam, jordan], "Maria is picked already")
        choice.toggle(maria)
        #expect(choice.unlisted([maria, sam]) == [sam], "an unticked person is still in the list")
        let added = choice.add(sam.address, name: sam.name, ownAddresses: Self.own)
        #expect(added)
        #expect(choice.isTicked(sam), "added ticked, as a search result")
        #expect(choice.people.last == sam, "under the name the Recent row shows")
        #expect(choice.unlisted([maria, sam, jordan]) == [jordan])
    }

    @Test("Only the new email's sheet reads recent people; an email's Reply to sheet has none")
    func wiring() throws {
        let view = try Self.source("TabMail/Views/Chat/ChatNewThreadView.swift")
        #expect(view.contains("title: ChatReplyToSheet.addRecipientTitle, recentPeople: { await ChatRecentPeople.load(pool: AppDatabase.dbPool, ownAddresses: ownAddresses) }) { done in"),
                "the new email's sheet reads them with the user's own addresses")
        let thread = try Self.source("TabMail/Views/Chat/ChatThreadView.swift")
        #expect(thread.contains("ChatReplyToSheet("), "control: the email's chat opens the sheet")
        #expect(!thread.contains("recentPeople"), "the Reply to sheet has no Recent section")
        let reader = try Self.source("TabMail/Views/Chat/ChatRecentPeople.swift")
        #expect(reader.contains("try await pool.read { db in"), "control: the reader reads")
        #expect(!reader.contains("write") && !reader.contains("UserDefaults"), "nothing is stored")
    }

    private static func source(_ path: String) throws -> String {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        return try String(contentsOf: root.appendingPathComponent(path), encoding: .utf8)
            .split(whereSeparator: \.isWhitespace).joined(separator: " ")
    }
}

/// The recent people against a real database: only the Sent folders, every account, newest first,
/// within the scan, at most the configured count.
@Suite("Recent people read from the Sent folders", .serialized, .processGlobalState)
struct ChatRecentPeopleLoadTests {
    private static let other = "chat-recent-people-other"

    private struct Fixture {
        let pool: DatabasePool
        let directory: URL
        let previous: AppDatabase?
    }

    private func fixture() throws -> Fixture {
        let (pool, directory, previous) = try FolderEpochTestFixture.makeAppDB()
        for account in [ChatRecentPeopleTests.account, Self.other] {
            _ = try FolderEpochTestFixture.makeAccount(id: account, provider: .imap, pool: pool)
            try FolderEpochTestFixture.insertFolder(accountId: account, path: "INBOX", role: .inbox, pool: pool)
            try FolderEpochTestFixture.insertFolder(accountId: account, path: "Sent", role: .sent, pool: pool)
            try FolderEpochTestFixture.insertFolder(accountId: account, path: "Drafts", role: .drafts, pool: pool)
            try FolderEpochTestFixture.insertFolder(accountId: account, path: "Archive", role: .archive, pool: pool)
        }
        return Fixture(pool: pool, directory: directory, previous: previous)
    }

    private func finish(_ fixture: Fixture) {
        AppDatabase.shared.withLock { $0 = fixture.previous }
        TestDatabaseTeardown.retire(pool: fixture.pool, directory: fixture.directory)
    }

    private func insert(_ headers: [MessageHeader], _ fixture: Fixture) async throws {
        try await fixture.pool.write { db in for header in headers { try header.insert(db) } }
    }

    @Test("Only emails in a Sent folder count, every account's, newest first")
    func onlySentEveryAccount() async throws {
        let fixture = try fixture()
        defer { finish(fixture) }
        typealias T = ChatRecentPeopleTests
        try await insert([
            T.email("s1", to: "maria@example.com", minutesAgo: 30),
            T.email("o1", to: "sam@example.com", minutesAgo: 5, accountId: Self.other),
            T.email("s2", to: "jordan@example.com", minutesAgo: 60),
            T.email("i1", to: "me@example.com", cc: "inbox-cc@example.com", minutesAgo: 1, folder: "INBOX"),
            T.email("d1", to: "draft@example.com", minutesAgo: 2, folder: "Drafts"),
            T.email("a1", to: "archived@example.com", minutesAgo: 3, folder: "Archive"),
        ], fixture)
        let people = await ChatRecentPeople.load(pool: PrioritizedDatabase(pool: fixture.pool), ownAddresses: T.own)
        #expect(people.map(\.address) == ["sam@example.com", "maria@example.com", "jordan@example.com"])
    }

    @Test("Only the newest emails of the scan are read")
    func scanBound() async throws {
        let fixture = try fixture()
        defer { finish(fixture) }
        typealias T = ChatRecentPeopleTests
        try await insert([
            T.email("s1", to: "maria@example.com", minutesAgo: 1),
            T.email("s2", to: "sam@example.com", minutesAgo: 2, accountId: Self.other),
            T.email("s3", to: "jordan@example.com", minutesAgo: 3),
        ], fixture)
        let pool = PrioritizedDatabase(pool: fixture.pool)
        let two = await ChatRecentPeople.load(pool: pool, ownAddresses: T.own, scanCount: 2)
        #expect(two.map(\.address) == ["maria@example.com", "sam@example.com"])
        let all = await ChatRecentPeople.load(pool: pool, ownAddresses: T.own, scanCount: 3)
        #expect(all.map(\.address) == ["maria@example.com", "sam@example.com", "jordan@example.com"], "control")
    }

    @Test("The sheet shows the configured number of people")
    func configuredCount() async throws {
        let fixture = try fixture()
        defer { finish(fixture) }
        typealias T = ChatRecentPeopleTests
        let count = ChatViewConfig.recentPeopleCount
        let headers = (0...count).map { T.email("s\($0)", to: "person\($0)@example.com", minutesAgo: Double($0 + 1)) }
        try await insert(headers, fixture)
        let people = await ChatRecentPeople.load(pool: PrioritizedDatabase(pool: fixture.pool), ownAddresses: T.own)
        #expect(people.map(\.address) == (0..<count).map { "person\($0)@example.com" })
    }

    @Test("A read that fails gives nobody")
    func failedRead() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("chat-recent-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        // A database with no tables: the read throws.
        let empty = try DatabasePool(path: directory.appendingPathComponent("empty.sqlite").path)
        let people = await ChatRecentPeople.load(pool: PrioritizedDatabase(pool: empty), ownAddresses: ChatRecentPeopleTests.own)
        #expect(people.isEmpty)
        try empty.close()
    }
}

/// The Recent section on screen, as VoiceOver reaches it.
@Suite("Recent people in the Add recipient sheet, on screen", .serialized, .processGlobalState)
@MainActor
struct ChatRecentPeopleHostedTests {
    private static let maria = ChatThread.Person(address: "maria@example.com", name: "Maria Lopez")
    private static let sam = ChatThread.Person(address: "sam@example.com", name: "Sam Patel")
    private static let jordan = ChatThread.Person(address: "jordan@example.com", name: "Jordan Lee")

    @Test("Recent lists the people not picked; a tap adds one to the list, ticked, and takes them off Recent")
    func hostedRecentTap() async throws {
        #expect(HostedAccessibility.isAvailable, "control: accessibility automation is available")
        try await HostedAccessibility.withAutomation { try await hostedRecentTapBody() }
    }

    private func hostedRecentTapBody() async throws {
        let window = try Self.host(ChatReplyToSheet(
            replyPeople: [Self.maria], target: .replyAll, ownAddresses: ChatRecentPeopleTests.own,
            title: ChatReplyToSheet.addRecipientTitle,
            recentPeople: { [Self.maria, Self.sam, Self.jordan] }) { _ in })
        defer { window.isHidden = true }
        _ = await Self.waitUntil { Self.labels(ChatReplyToSheet.recentId, in: window).count == 2 }
        let recent = Self.labels(ChatReplyToSheet.recentId, in: window)
        #expect(recent.count == 2 && recent.first?.contains("Sam Patel") == true && recent.last?.contains("Jordan Lee") == true,
                "Recent shows Sam and Jordan, not Maria, who is picked: \(recent)")
        #expect(HostedAccessibility.labels(in: window).contains(ChatReplyToSheet.recentTitle), "the section is titled Recent")

        let sam = try #require(Self.elements(ChatReplyToSheet.recentId, in: window).first { ($0.accessibilityLabel ?? "").contains("Sam Patel") })
        let activated = sam.accessibilityActivate()
        #expect(activated)
        _ = await Self.waitUntil { Self.labels(ChatReplyToSheet.recentId, in: window).count == 1 }
        #expect(Self.labels(ChatReplyToSheet.recentId, in: window).map { $0.contains("Jordan Lee") } == [true],
                "Sam left Recent: \(Self.labels(ChatReplyToSheet.recentId, in: window))")
        let listed = Self.elements(ChatReplyToSheet.personId, in: window)
        let samRow = listed.first { ($0.accessibilityLabel ?? "").contains("Sam Patel") }
        #expect(samRow.map { $0.accessibilityTraits.contains(.isSelected) } == true,
                "Sam is in the list, ticked: \(listed.map { $0.accessibilityLabel ?? "" })")
    }

    @Test("The Reply to sheet, given no recent people, shows no Recent section")
    func hostedNoRecent() async throws {
        #expect(HostedAccessibility.isAvailable, "control: accessibility automation is available")
        try await HostedAccessibility.withAutomation { try await hostedNoRecentBody() }
    }

    private func hostedNoRecentBody() async throws {
        let window = try Self.host(ChatReplyToSheet(
            replyPeople: [Self.maria], target: .replyAll, ownAddresses: ChatRecentPeopleTests.own) { _ in })
        defer { window.isHidden = true }
        // Once the list's row is drawn, a Recent section would be drawn too.
        _ = await Self.waitUntil { !Self.elements(ChatReplyToSheet.personId, in: window).isEmpty }
        #expect(!Self.elements(ChatReplyToSheet.personId, in: window).isEmpty, "control: the list is drawn")
        #expect(Self.elements(ChatReplyToSheet.recentId, in: window).isEmpty)
        #expect(!HostedAccessibility.labels(in: window).contains(ChatReplyToSheet.recentTitle))
    }

    // MARK: - Helpers

    private struct HostingFailure: Error, CustomStringConvertible {
        let description: String
    }

    private static func host<V: View>(_ view: V) throws -> UIWindow {
        guard let scene = UIApplication.shared.connectedScenes.compactMap({ $0 as? UIWindowScene }).first else {
            throw HostingFailure(description: "no UIWindowScene is available to host the view")
        }
        let controller = UIHostingController(rootView: view)
        let window = UIWindow(windowScene: scene)
        window.frame = CGRect(x: 0, y: 0, width: 390, height: 800)
        window.rootViewController = controller
        window.isHidden = false
        window.makeKeyAndVisible()
        window.layoutIfNeeded()
        return window
    }

    private static func elements(_ identifier: String, in view: UIView) -> [NSObject] {
        HostedAccessibility.elements(under: view).filter { HostedAccessibility.identifier(of: $0) == identifier }
    }

    private static func labels(_ identifier: String, in view: UIView) -> [String] {
        elements(identifier, in: view).map { $0.accessibilityLabel ?? "" }
    }

    /// Bounded: a view that never shows the element fails the test rather than hanging it.
    private static func waitUntil(seconds: TimeInterval = 3, _ condition: () -> Bool) async -> Bool {
        let deadline = Date().addingTimeInterval(seconds)
        while Date() < deadline {
            if condition() { return true }
            try? await Task.sleep(for: .milliseconds(20))
        }
        return condition()
    }
}
