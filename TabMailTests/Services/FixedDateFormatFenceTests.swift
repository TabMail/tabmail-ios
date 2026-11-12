/* This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at https://mozilla.org/MPL/2.0/. */

import Foundation
import Testing

/// No fixed-format `DateFormatter` is built outside `FixedDateFormat`.
///
/// A `DateFormatter` given a `dateFormat` without the `en_US_POSIX` locale and the
/// Gregorian calendar follows the phone's calendar, so on a phone set to the
/// Buddhist calendar every event the app writes lands 543 years late on the
/// server. `FixedDateFormat` is the one builder that pins both; this suite reads
/// the source of every target (the app, `Shared`, the notification extension and
/// any other top-level target folder) at run time and fails on a `dateFormat`
/// assignment anywhere else. Display formatting through `dateStyle`, `timeStyle`
/// or a localized template sets no `dateFormat` and is not affected.
@Suite("Fixed-format date formatters are built only by FixedDateFormat")
struct FixedDateFormatFenceTests {

    static let helperFile = "Shared/FixedDateFormat.swift"
    /// Top-level folders that hold no target source.
    static let skippedTopLevel: Set<String> = ["TabMailTests", "TabMail.xcodeproj", "Companion", "Scripts"]
    /// Folders that must be among the scanned ones, so a moved tree cannot make the
    /// fence vacuous.
    static let requiredTopLevel: Set<String> = ["TabMail", "Shared", "TabMailNotificationService"]

    static func repositoryRoot() -> URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()   // Services
            .deletingLastPathComponent()   // TabMailTests
            .deletingLastPathComponent()   // repository root
    }

    /// `source` with comments and string literal contents blanked to spaces
    /// (newlines kept, so line numbers hold). Handles `//`, nested `/* */`,
    /// `"…"` with escapes, `"""…"""`, and raw strings `#"…"#` / `#"""…"""#`.
    static func codeOnly(_ source: String) -> [Character] {
        let chars = Array(source)
        var out = chars
        var i = 0
        func blank(_ from: Int, _ to: Int) {
            var k = from
            while k < to && k < out.count {
                if out[k] != "\n" { out[k] = " " }
                k += 1
            }
        }
        func matches(_ s: String, at index: Int) -> Bool {
            let pattern = Array(s)
            guard index + pattern.count <= chars.count else { return false }
            return Array(chars[index..<index + pattern.count]) == pattern
        }
        while i < chars.count {
            if matches("//", at: i) {
                let start = i
                while i < chars.count && chars[i] != "\n" { i += 1 }
                blank(start, i)
                continue
            }
            if matches("/*", at: i) {
                let start = i
                var depth = 0
                while i < chars.count {
                    if matches("/*", at: i) { depth += 1; i += 2; continue }
                    if matches("*/", at: i) { depth -= 1; i += 2; if depth == 0 { break }; continue }
                    i += 1
                }
                blank(start, i)
                continue
            }
            if chars[i] == "#" || chars[i] == "\"" {
                var hashes = 0
                var j = i
                while j < chars.count && chars[j] == "#" { hashes += 1; j += 1 }
                guard j < chars.count, chars[j] == "\"" else { i += 1; continue }
                let multiline = matches("\"\"\"", at: j)
                let quote = multiline ? "\"\"\"" : "\""
                let closer = quote + String(repeating: "#", count: hashes)
                var k = j + quote.count
                while k < chars.count {
                    if hashes == 0 && chars[k] == "\\" { k += 2; continue }
                    if !multiline && chars[k] == "\n" { break }
                    if matches(closer, at: k) { k += closer.count; break }
                    k += 1
                }
                blank(j + quote.count, max(j + quote.count, k - closer.count))
                i = k
                continue
            }
            i += 1
        }
        return out
    }

    /// 1-based lines of `source` that assign a `dateFormat` in code.
    static func dateFormatAssignmentLines(in source: String) -> [Int] {
        let code = String(codeOnly(source))
        let regex = try! NSRegularExpression(pattern: #"(?<![A-Za-z0-9_])dateFormat\s*=(?!=)"#)
        let ns = code as NSString
        return regex.matches(in: code, range: NSRange(location: 0, length: ns.length)).map { match in
            ns.substring(to: match.range.location).reduce(1) { $1 == "\n" ? $0 + 1 : $0 }
        }
    }

    struct Scan {
        var files = 0
        var topLevel: Set<String> = []
        var helperAssignments = 0
        var violations: [String] = []
    }

    static func scanTargets() throws -> Scan {
        let root = repositoryRoot().standardizedFileURL
        var scan = Scan()
        let entries = try FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: [.isDirectoryKey])
        for entry in entries {
            let name = entry.lastPathComponent
            guard !name.hasPrefix("."), !skippedTopLevel.contains(name),
                  (try entry.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true,
                  let walker = FileManager.default.enumerator(at: entry, includingPropertiesForKeys: nil)
            else { continue }
            for case let url as URL in walker where url.pathExtension == "swift" {
                let relative = String(url.standardizedFileURL.path.dropFirst(root.path.count + 1))
                let lines = dateFormatAssignmentLines(in: try String(contentsOf: url, encoding: .utf8))
                scan.files += 1
                scan.topLevel.insert(name)
                if relative == helperFile {
                    scan.helperAssignments += lines.count
                } else {
                    scan.violations += lines.map { "\(relative):\($0)" }
                }
            }
        }
        return scan
    }

    @Test("the scanner: code assignments count; comments, strings and comparisons do not")
    func scannerIsSound() {
        let source = """
        let a = DateFormatter()
        a.dateFormat = "yyyy"
        // b.dateFormat = "yyyy"
        /* c.dateFormat = "yyyy" /* nested */ d.dateFormat = "x" */
        let s = "e.dateFormat = yyyy"
        let r = #"f.dateFormat = "yyyy""#
        if g.dateFormat == "yyyy" {}
        let h = DateFormatter(); h.dateFormat="HH"
        let dateFormatter = DateFormatter()
        """
        #expect(Self.dateFormatAssignmentLines(in: source) == [2, 8])
    }

    @Test("no dateFormat is set outside FixedDateFormat in any target")
    func noFixedFormatOutsideHelper() throws {
        let scan = try Self.scanTargets()
        #expect(Self.requiredTopLevel.isSubset(of: scan.topLevel),
                "scanned \(scan.topLevel.sorted()); a target folder is missing, so the fence is vacuous for it")
        #expect(scan.files > 100, "scanned only \(scan.files) Swift files")
        #expect(scan.helperAssignments == 1,
                "\(Self.helperFile) should set dateFormat exactly once; found \(scan.helperAssignments)")
        #expect(scan.violations.isEmpty,
                "fixed-format DateFormatter built outside FixedDateFormat (\(scan.violations.count)): \(scan.violations)")
    }
}
