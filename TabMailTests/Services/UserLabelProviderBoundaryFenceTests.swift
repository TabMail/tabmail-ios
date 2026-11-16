/* This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at https://mozilla.org/MPL/2.0/. */

import Foundation
import Testing

/// User-label rules live in the providers, never above them (ADR-IOS-060, #500).
///
/// The label menu, the sync's folder-list apply and the notification merge call
/// the providers' user-label requirements (`EmailProvider.userLabel(named:connected:)`,
/// `userLabelCatalog(from:)`, `storedUserLabelIds(fromPushed:accountId:db:)`)
/// and apply what they return. Before #500 each of them carried the rules
/// itself: the menu cast its provider to `GmailProvider` and switched on the
/// account kind to lowercase IMAP keywords, the sync imported labels only
/// `if account.provider == .gmail`, and the merge switched on the push
/// payload's provider name. This suite reads their source at run time, comments
/// removed, and fails if any of that comes back.
@Suite("User-label rules stay below the provider boundary")
struct UserLabelProviderBoundaryFenceTests {

    struct Rule: CustomStringConvertible {
        let pattern: String
        let why: String
        var description: String { "\(pattern) (\(why))" }
    }

    static let menuFile = "TabMail/Views/Inbox/UserLabelMenuView.swift"
    static let fullSyncFile = "TabMail/Services/Sync/SyncEngineFullSync.swift"
    static let syncDirectory = "TabMail/Services/Sync"
    static let mergeFile = "TabMail/Services/NSEDataBridge.swift"

    /// The label menu: no provider cast or type check, no concrete provider
    /// type, no branch on the account kind (whatever it is spelled as), no
    /// label-name normalization.
    static let menuRules: [Rule] = [
        Rule(pattern: #"\bas\s*[?!]"#, why: "a cast"),
        Rule(pattern: #"\bis\s+[A-Z]\w*"#, why: "a type check"),
        Rule(pattern: #"\btype\s*\(\s*of:"#, why: "a type check"),
        Rule(pattern: #"\b(Gmail|IMAP|Exchange|Demo|CalDAV)Provider\b"#, why: "a concrete provider type"),
        Rule(pattern: #"\baccount\.provider\s*(==|!=)|\bswitch\s+account\.provider\b"#, why: "a branch on the account kind"),
        // An account kind named at all: a `case` arm of a switch on any
        // spelling of the kind (an alias, a parameter), or a comparison with one.
        Rule(pattern: #"\.(gmail|outlook|imap|icloud|caldav)\b"#, why: "an account kind named"),
        Rule(pattern: #""(gmail|outlook|imap|imap_new_mail|icloud|caldav)""#, why: "an account kind named by its raw value"),
        Rule(pattern: #"\.(lowercased|uppercased)\s*\("#, why: "label-name normalization"),
    ]

    /// The sync: no Gmail-only label import, no Gmail system-label rule.
    static let fullSyncRules: [Rule] = [
        Rule(pattern: #"\.provider\s*==\s*\.gmail\b"#, why: "a Gmail-only branch"),
    ]
    static let syncDirectoryRules: [Rule] = [
        Rule(pattern: #"\bisGmailSystemLabel\b"#, why: "Gmail's system-label rule"),
    ]

    /// The merge: no switch on the payload's provider name.
    static let mergeRules: [Rule] = [
        Rule(pattern: #"\bcase\s+"(gmail|outlook|imap|imap_new_mail|icloud)""#, why: "a switch on the payload provider name"),
    ]

    static func repositoryRoot() -> URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()   // Services
            .deletingLastPathComponent()   // TabMailTests
            .deletingLastPathComponent()   // repository root
    }

    /// The source with block and line comments removed (a `//` after `:` is a
    /// URL and stays).
    static func code(of source: String) -> String {
        let noBlocks = source.replacingOccurrences(of: #"/\*[\s\S]*?\*/"#, with: "", options: .regularExpression)
        return noBlocks.split(separator: "\n", omittingEmptySubsequences: false)
            .map { $0.replacingOccurrences(of: #"(?<!:)//.*$"#, with: "", options: .regularExpression) }
            .joined(separator: "\n")
    }

    /// Each `file:line: text` in `code` that matches one of `rules`.
    static func violations(in code: String, file: String, rules: [Rule]) -> [String] {
        var found: [String] = []
        for (index, line) in code.split(separator: "\n", omittingEmptySubsequences: false).enumerated() {
            for rule in rules where line.range(of: rule.pattern, options: .regularExpression) != nil {
                found.append("\(file):\(index + 1): \(rule.why): \(line.trimmingCharacters(in: .whitespaces))")
            }
        }
        return found
    }

    static func load(_ relativePath: String) throws -> String {
        try String(contentsOf: repositoryRoot().appendingPathComponent(relativePath), encoding: .utf8)
    }

    @Test("The rules catch each pre-#500 shape, and only in code")
    func rulesCatchThePreviousShapes() {
        let menuShapes = [
            "guard let gmail = provider as? GmailProvider else { return false }",
            "if provider is GmailProvider { }",
            "switch account.provider {",
            "labelId = name.lowercased()",
            "case .gmail, .imap, .icloud, .outlook: return true",
            "let kind = account.provider; switch kind { case .caldav: return false }",
            "nonisolated static func supports(_ provider: AccountProvider) -> Bool { provider != .caldav }",
            #"if account.provider.rawValue == "gmail" { }"#,
        ]
        for shape in menuShapes {
            #expect(!Self.violations(in: Self.code(of: shape), file: "probe", rules: Self.menuRules).isEmpty, "not caught: \(shape)")
        }
        // The provider-blind capability check the menu does use is not caught.
        #expect(Self.violations(in: "guard let account, account.provider.emailProviderType != nil else { return false }", file: "probe", rules: Self.menuRules).isEmpty)
        #expect(!Self.violations(in: "if account.provider == .gmail {", file: "probe", rules: Self.fullSyncRules).isEmpty)
        #expect(!Self.violations(in: "let s = UserLabelStore.isGmailSystemLabel(id: a)", file: "probe", rules: Self.syncDirectoryRules).isEmpty)
        #expect(!Self.violations(in: #"case "imap_new_mail", "imap", "icloud":"#, file: "probe", rules: Self.mergeRules).isEmpty)
        #expect(Self.violations(in: Self.code(of: "// as? GmailProvider in a comment\n/// switch account.provider"), file: "probe", rules: Self.menuRules).isEmpty)
    }

    @Test("The label menu has no provider cast, type check, provider type, account-kind branch or name normalization")
    func menuStaysProviderBlind() throws {
        let code = Self.code(of: try Self.load(Self.menuFile))
        #expect(code.contains("userLabel(named:"), "the menu no longer asks the provider for the label; the fence would pass vacuously")
        let found = Self.violations(in: code, file: Self.menuFile, rules: Self.menuRules)
        #expect(found.isEmpty, "\(found.joined(separator: "\n"))")
    }

    @Test("The sync imports labels from the provider's catalog, with no Gmail-only branch or Gmail rule")
    func syncStaysProviderBlind() throws {
        let fullSync = Self.code(of: try Self.load(Self.fullSyncFile))
        #expect(fullSync.contains("userLabelCatalog(from:"), "the sync no longer asks the provider for its catalog; the fence would pass vacuously")
        var found = Self.violations(in: fullSync, file: Self.fullSyncFile, rules: Self.fullSyncRules)

        let directory = Self.repositoryRoot().appendingPathComponent(Self.syncDirectory)
        let files = try FileManager.default.contentsOfDirectory(atPath: directory.path)
            .filter { $0.hasSuffix(".swift") }.sorted()
        #expect(files.contains("SyncEngineFullSync.swift"), "the sync directory moved: \(files)")
        for file in files {
            let path = "\(Self.syncDirectory)/\(file)"
            found += Self.violations(in: Self.code(of: try Self.load(path)), file: path, rules: Self.syncDirectoryRules)
        }
        #expect(found.isEmpty, "\(found.joined(separator: "\n"))")
    }

    @Test("The notification merge takes pushed labels through the provider, with no switch on the provider name")
    func mergeStaysProviderBlind() throws {
        let code = Self.code(of: try Self.load(Self.mergeFile))
        #expect(code.contains("storedUserLabelIds(fromPushed:"), "the merge no longer asks the provider; the fence would pass vacuously")
        let found = Self.violations(in: code, file: Self.mergeFile, rules: Self.mergeRules)
        #expect(found.isEmpty, "\(found.joined(separator: "\n"))")
    }
}
