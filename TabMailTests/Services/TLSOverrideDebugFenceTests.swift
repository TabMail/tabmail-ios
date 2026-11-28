/* This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at https://mozilla.org/MPL/2.0/. */

import Foundation
import Testing

/// The IMAP TLS override lets tests reach a plain-TCP fake server through the real
/// provider factory, and the CalDAV session override lets them reach a
/// `URLProtocol` fake through `makeCalDAVClient`, and the Keychain save fault
/// lets them fail one save. None may exist in a release build: their names may
/// appear in shipped source only inside the `#if DEBUG` branch of a conditional.
@Suite("IMAP TLS, CalDAV session and Keychain save test overrides are fenced to DEBUG builds")
struct TLSOverrideDebugFenceTests {

    private static let fencedNames = [
        "setIMAPUseTLSOverrideForTesting", "imapUseTLSOverrideBox",
        "setCalDAVSessionOverrideForTesting", "calDAVSessionOverrideBox",
        "failNextSaveForTesting", "failNextSaveKeyForTesting",
        // The plain-TCP transport the IMAP override selects: release builds
        // always use an encrypted connection (`MailTransportPolicy`).
        "MailTransportSecurity.plainText",
    ]

    private static var repoRoot: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent() // Services
            .deletingLastPathComponent() // TabMailTests
            .deletingLastPathComponent() // repo root
    }

    /// The source shipped in release builds: the app, the code it shares with
    /// its extensions, and the notification service extension.
    private static let shippedFolders = ["TabMail", "Shared", "TabMailNotificationService"]

    /// The files that build mail connections and choose their transport.
    private static let transportFiles = [
        "TabMail/Providers/IMAPProvider.swift",
        "TabMailNotificationService/NSEIMAPConnection.swift",
        "Shared/API/MailTransportPolicy.swift",
    ]

    /// Lines (1-based) where a fenced name appears outside a `#if DEBUG` branch.
    static func unfencedLines(in source: String) -> [Int] {
        unfencedLines(in: source) { line in fencedNames.contains(where: { line.contains($0) }) }
    }

    /// Lines (1-based) of a transport file that name the unencrypted transport
    /// in any spelling (`.plainText`) outside a `#if DEBUG` branch, comments
    /// skipped.
    static func unfencedPlainTextLines(in source: String) -> [Int] {
        unfencedLines(in: source) { !$0.hasPrefix("//") && $0.contains(".plainText") }
    }

    /// Lines (1-based) of a transport file that use SwiftMail's
    /// upgrade-only-if-offered transport (`.automatic`) anywhere, DEBUG
    /// included, comments skipped.
    static func automaticLines(in source: String) -> [Int] {
        source.components(separatedBy: "\n").enumerated().compactMap { index, raw in
            let line = raw.trimmingCharacters(in: .whitespaces)
            return !line.hasPrefix("//") && line.contains(".automatic") ? index + 1 : nil
        }
    }

    /// Lines (1-based) matching `matches` outside a `#if DEBUG` branch. A branch
    /// is DEBUG when its `#if`/`#elseif` condition is exactly `DEBUG`; `#else`
    /// of such a conditional is not. `matches` gets the line trimmed.
    static func unfencedLines(in source: String, where matches: (String) -> Bool) -> [Int] {
        var stack: [Bool] = [] // whether the current branch of each open conditional is DEBUG
        var hits: [Int] = []
        for (index, raw) in source.components(separatedBy: "\n").enumerated() {
            let line = raw.trimmingCharacters(in: .whitespaces)
            if line.hasPrefix("#if ") {
                stack.append(line.dropFirst(4).trimmingCharacters(in: .whitespaces) == "DEBUG")
                continue
            }
            if line.hasPrefix("#elseif "), !stack.isEmpty {
                stack[stack.count - 1] = line.dropFirst(8).trimmingCharacters(in: .whitespaces) == "DEBUG"
                continue
            }
            if line == "#else", !stack.isEmpty {
                stack[stack.count - 1] = false
                continue
            }
            if line.hasPrefix("#endif"), !stack.isEmpty {
                stack.removeLast()
                continue
            }
            if matches(line), !stack.contains(true) {
                hits.append(index + 1)
            }
        }
        return hits
    }

    @Test("the fence check itself: inside DEBUG passes, #else and bare code fail")
    func fenceCheckIsSound() {
        let fenced = "#if DEBUG\nlet imapUseTLSOverrideBox = 1\n#else\nlet x = 1\n#endif\n"
        #expect(Self.unfencedLines(in: fenced).isEmpty)
        let inElse = "#if DEBUG\nlet x = 1\n#else\nsetIMAPUseTLSOverrideForTesting(nil)\n#endif\n"
        #expect(Self.unfencedLines(in: inElse) == [4])
        #expect(Self.unfencedLines(in: "setIMAPUseTLSOverrideForTesting(false)\n") == [1])
    }

    @Test("the transport checks themselves: the shorthand counts, a comment does not, DEBUG fences only plainText")
    func transportChecksAreSound() {
        #expect(Self.unfencedPlainTextLines(in: "return .plainText\n") == [1])
        #expect(Self.unfencedPlainTextLines(in: "#if DEBUG\nreturn .plainText\n#endif\n").isEmpty)
        #expect(Self.unfencedPlainTextLines(in: "/// `.plainText` is never used\n").isEmpty)
        #expect(Self.automaticLines(in: "let s: MailTransportSecurity = .automatic\n") == [1])
        #expect(Self.automaticLines(in: "#if DEBUG\nreturn .automatic\n#endif\n") == [2])
        #expect(Self.automaticLines(in: "/// SwiftMail's `.automatic` is never used\n").isEmpty)
    }

    @Test("every appearance in shipped source (app, shared code, notification service) is inside a #if DEBUG branch")
    func appSourceIsFenced() throws {
        var appearances = 0
        var violations: [String] = []
        var sources: [String] = []
        for folder in Self.shippedFolders {
            let root = Self.repoRoot.appendingPathComponent(folder)
            let enumerator = try #require(FileManager.default.enumerator(at: root, includingPropertiesForKeys: nil))
            for case let url as URL in enumerator where url.pathExtension == "swift" {
                let source = try String(contentsOf: url, encoding: .utf8)
                guard Self.fencedNames.contains(where: { source.contains($0) }) else { continue }
                sources.append(source)
                appearances += 1
                for line in Self.unfencedLines(in: source) {
                    violations.append("\(folder)/\(url.lastPathComponent):\(line)")
                }
            }
        }
        #expect(appearances > 0, "the fence scanned no file that defines the override; the check is vacuous")
        for name in Self.fencedNames {
            #expect(sources.contains { $0.contains(name) }, "no app source names \(name); the check is vacuous for it")
        }
        #expect(violations.isEmpty, "test override outside #if DEBUG: \(violations)")
    }

    @Test("the transport files never pick the unencrypted transport outside DEBUG, nor the upgrade-if-offered one at all")
    func transportFilesAreEncryptedOnly() throws {
        var violations: [String] = []
        for path in Self.transportFiles {
            let source = try String(contentsOf: Self.repoRoot.appendingPathComponent(path), encoding: .utf8)
            violations += Self.unfencedPlainTextLines(in: source).map { "\(path):\($0) plainText" }
            violations += Self.automaticLines(in: source).map { "\(path):\($0) automatic" }
        }
        #expect(violations.isEmpty, "\(violations)")
    }
}
