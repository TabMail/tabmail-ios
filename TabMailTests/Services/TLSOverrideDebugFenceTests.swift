/* This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at https://mozilla.org/MPL/2.0/. */

import Foundation
import Testing

/// The IMAP TLS override lets tests reach a plain-TCP fake server through the real
/// provider factory, and the CalDAV session override lets them reach a
/// `URLProtocol` fake through `makeCalDAVClient`, and the Keychain save fault
/// lets them fail one save. None may exist in a release build: their names may
/// appear in app source only inside the `#if DEBUG` branch of a conditional.
@Suite("IMAP TLS, CalDAV session and Keychain save test overrides are fenced to DEBUG builds")
struct TLSOverrideDebugFenceTests {

    private static let fencedNames = [
        "setIMAPUseTLSOverrideForTesting", "imapUseTLSOverrideBox",
        "setCalDAVSessionOverrideForTesting", "calDAVSessionOverrideBox",
        "failNextSaveForTesting", "failNextSaveKeyForTesting",
    ]

    private static var appSourceRoot: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent() // Services
            .deletingLastPathComponent() // TabMailTests
            .deletingLastPathComponent() // repo root
            .appendingPathComponent("TabMail")
    }

    /// Lines (1-based) where a fenced name appears outside a `#if DEBUG` branch.
    /// A branch is DEBUG when its `#if`/`#elseif` condition is exactly `DEBUG`;
    /// `#else` of such a conditional is not.
    static func unfencedLines(in source: String) -> [Int] {
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
            if fencedNames.contains(where: { line.contains($0) }), !stack.contains(true) {
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

    @Test("every appearance in app source is inside a #if DEBUG branch")
    func appSourceIsFenced() throws {
        let root = Self.appSourceRoot
        let enumerator = try #require(FileManager.default.enumerator(at: root, includingPropertiesForKeys: nil))
        var appearances = 0
        var violations: [String] = []
        var sources: [String] = []
        for case let url as URL in enumerator where url.pathExtension == "swift" {
            let source = try String(contentsOf: url, encoding: .utf8)
            guard Self.fencedNames.contains(where: { source.contains($0) }) else { continue }
            sources.append(source)
            appearances += 1
            for line in Self.unfencedLines(in: source) {
                violations.append("\(url.lastPathComponent):\(line)")
            }
        }
        #expect(appearances > 0, "the fence scanned no file that defines the override; the check is vacuous")
        for name in Self.fencedNames {
            #expect(sources.contains { $0.contains(name) }, "no app source names \(name); the check is vacuous for it")
        }
        #expect(violations.isEmpty, "test override outside #if DEBUG: \(violations)")
    }
}
