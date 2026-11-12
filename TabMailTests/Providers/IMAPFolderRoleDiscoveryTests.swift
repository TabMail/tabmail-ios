/* This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at https://mozilla.org/MPL/2.0/. */

import Testing
import Foundation
@testable import TabMail

// The system property: the folder the SERVER says holds sent mail is the one
// `fetchFolders` gives the Sent role. Without a Sent role a successful send
// keeps no Sent copy anywhere (`AccountManagerOutbox.attemptSentAppend`).
//
// Each case runs the real `IMAPProvider.fetchFolders` against `FakeIMAPServer`
// so the wire shapes (namespace prefix, hierarchy delimiter, plain LIST vs.
// `LIST ... RETURN (SPECIAL-USE)`) are the ones a real server sends.

@Suite("IMAP folder role discovery (Sent copy kept)", .serialized)
struct IMAPFolderRoleDiscoveryTests {

    private static func uniqueUsername() -> String {
        "roles-\(UUID().uuidString.lowercased())"
    }

    private static func provider(for server: FakeIMAPServer) -> IMAPProvider {
        IMAPProvider(
            host: "127.0.0.1",
            port: server.port,
            username: server.username,
            password: server.password,
            smtpHost: "127.0.0.1",
            smtpPort: 587,
            useTLS: false
        )
    }

    private static func roles(on server: FakeIMAPServer) async throws -> [String: FolderRole] {
        let provider = provider(for: server)
        try await provider.connect()
        let folders: [FolderInfo]
        do {
            folders = try await provider.fetchFolders()
        } catch {
            try? await provider.disconnect()
            throw error
        }
        try? await provider.disconnect()
        return Dictionary(uniqueKeysWithValues: folders.map { ($0.path, $0.role) })
    }

    /// A server that keeps every folder under INBOX (`INBOX.` personal
    /// namespace, `.` delimiter) and sends no special-use attributes. Its
    /// Sent folder is English-named, yet the full name `INBOX.Sent` was matched
    /// against the name list and missed.
    @Test("A Sent folder under INBOX with no special-use attribute gets the Sent role")
    func sentUnderInboxNamespace() async throws {
        let server = FakeIMAPServer(
            username: Self.uniqueUsername(),
            mailboxes: [
                "INBOX": [], "INBOX.Sent": [], "INBOX.Drafts": [], "INBOX.Trash": [],
                "INBOX.Projects": [],
            ])
        server.setHierarchy(delimiter: ".", personalNamespacePrefix: "INBOX.")
        try server.start()
        defer { server.stop() }

        let roles = try await Self.roles(on: server)

        #expect(roles["INBOX.Sent"] == .sent, "the server's Sent folder must carry the Sent role")
        #expect(roles.values.filter { $0 == .sent }.count == 1, "exactly one Sent folder")
        #expect(roles["INBOX"] == .inbox)
        #expect(roles["INBOX.Drafts"] == .drafts)
        #expect(roles["INBOX.Trash"] == .trash)
        #expect(roles["INBOX.Projects"] == .custom)
    }

    /// A server that advertises SPECIAL-USE but, as RFC 6154 §2 allows, puts
    /// `\Sent` only on `LIST ... RETURN (SPECIAL-USE)`, not on a plain LIST. Its
    /// Sent folder's name is outside the English name list, so the attribute
    /// is the only evidence.
    @Test("A \\Sent that only LIST RETURN (SPECIAL-USE) reports gives the Sent role")
    func sentOnlyOnSpecialUseReturn() async throws {
        let server = FakeIMAPServer(
            username: Self.uniqueUsername(),
            capabilities: FakeIMAPServer.defaultCapabilities + ["SPECIAL-USE"],
            mailboxes: ["INBOX": [], "Envoyes": [], "Projects": []])
        server.setSpecialUse("\\Sent", for: "Envoyes", onPlainList: false)
        try server.start()
        defer { server.stop() }

        let roles = try await Self.roles(on: server)

        #expect(roles["Envoyes"] == .sent, "the folder the server marks \\Sent must carry the Sent role")
        #expect(roles.values.filter { $0 == .sent }.count == 1, "exactly one Sent folder")
        #expect(roles["INBOX"] == .inbox)
        #expect(roles["Projects"] == .custom)
    }

    /// A server WITHOUT the SPECIAL-USE capability must not be sent the
    /// RETURN option, and folder names that merely CONTAIN a role word must
    /// stay ordinary folders. (The fork's `listSpecialUseMailboxes()` guesses
    /// attributes from substrings on such a server, so it must not be called.)
    @Test("Without SPECIAL-USE: no RETURN option and no substring-guessed roles")
    func noSpecialUseCapabilityKeepsNameRoles() async throws {
        let server = FakeIMAPServer(
            username: Self.uniqueUsername(),
            mailboxes: [
                "INBOX": [], "Sent": [], "Unsent Ideas": [], "Consent Forms": [],
                "Draft Plans": [], "Small Mail": [],
            ])
        try server.start()
        defer { server.stop() }

        let roles = try await Self.roles(on: server)

        #expect(roles["Sent"] == .sent)
        #expect(roles["Unsent Ideas"] == .custom)
        #expect(roles["Consent Forms"] == .custom)
        #expect(roles["Draft Plans"] == .custom)
        #expect(roles["Small Mail"] == .custom)
        let listCommands = server.recordedCommands().filter { $0.hasPrefix("LIST") }
        #expect(!listCommands.isEmpty, "precondition: the folder list came from LIST")
        #expect(listCommands.allSatisfy { !$0.uppercased().contains("RETURN") },
                "a server without SPECIAL-USE must never be sent a RETURN option: \(listCommands)")
    }

    /// Nested folders whose LAST segment is a role name lose to the top-level
    /// role folder (shorter name, same canonical rank), and a nested `INBOX`
    /// is never the inbox.
    @Test("Leaf matching keeps the top-level role folder and never a nested INBOX")
    func nestedRoleNamesLoseToTopLevel() async throws {
        let server = FakeIMAPServer(
            username: Self.uniqueUsername(),
            mailboxes: ["INBOX": [], "Sent": [], "Clients/Sent": [], "Old/INBOX": []])
        try server.start()
        defer { server.stop() }

        let roles = try await Self.roles(on: server)

        #expect(roles["Sent"] == .sent)
        #expect(roles["Clients/Sent"] == .custom)
        #expect(roles["INBOX"] == .inbox)
        #expect(roles["Old/INBOX"] == .custom)
    }
}
