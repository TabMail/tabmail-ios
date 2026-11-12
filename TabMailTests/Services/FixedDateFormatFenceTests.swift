/* This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at https://mozilla.org/MPL/2.0/. */

import Foundation
import Testing

/// Dates are formatted and parsed in the Gregorian calendar, whatever the phone's
/// calendar is, and only `FixedDateFormat` builds the formatters that do it.
///
/// A `DateFormatter` given a `dateFormat` without the `en_US_POSIX` locale and the
/// Gregorian calendar follows the phone's calendar, so on a phone set to the
/// Buddhist calendar every event the app writes lands 543 years late on the
/// server. This suite reads the source of every app and extension target listed
/// in `project.yml` at run time and fails on:
///
/// - a fixed format set anywhere but `FixedDateFormat`: a `dateFormat` assignment
///   (`=` or `+=`, also across lines), an `override var dateFormat`, a key-value or
///   key-path write of `dateFormat`, or a localized template
///   (`setLocalizedDateFormatFromTemplate`, `dateFormat(fromTemplate:…)`);
/// - a `DateFormatter` built (also `= .init()`), subclassed or used through
///   `DateFormatter.localizedString`, or a `DateIntervalFormatter`, outside
///   `FixedDateFormat`, except at the named display-only sites below, which set
///   only `dateStyle`/`timeStyle` and follow the phone;
/// - a date `FormatStyle` (`.formatted(date:time:)`, `.dateTime`, `.interval`,
///   `Date.FormatStyle`, `IntervalFormatStyle`, `VerbatimFormatStyle`), which takes
///   the phone's calendar unless one is pinned, except at the named display-only
///   sites below;
/// - on the stored reminder due-date paths, the phone's calendar or a hand-built
///   `DateComponents` year instead of `FixedDateFormat.gregorianDay`.
///
/// Not flagged: SwiftUI `Text(date, style:)` (on-device display), a bare
/// `.formatted()` (lexically the same as a number's), and `ISO8601DateFormatter`,
/// which is always Gregorian.
@Suite("Dates are formatted only by FixedDateFormat, in the Gregorian calendar")
struct FixedDateFormatFenceTests {

    static let helperFile = "Shared/FixedDateFormat.swift"
    /// Source roots that must be among the scanned ones, so a moved tree or a
    /// misread `project.yml` cannot make the fence vacuous.
    static let requiredSourceRoots: Set<String> = ["TabMail", "Shared", "TabMailNotificationService"]
    /// `project.yml` target types that ship no product code.
    static let testTargetTypes: Set<String> = ["bundle.unit-test", "bundle.ui-testing"]

    /// Display-only `DateFormatter`s: on-device text in the phone's own style and
    /// calendar (`dateStyle`/`timeStyle` only), never sent, stored or parsed.
    /// File → exact count, so a new site, or a removed one, fails until listed here.
    static let displayFormatterSites: [String: Int] = [
        "Shared/DateFormatting.swift": 1,                          // inbox row time today
        "TabMail/Views/Account/SubscriptionStatusView.swift": 1,   // renewal date
        "TabMail/Views/Account/PlanPickerView.swift": 1,           // renewal date
        "TabMail/Views/Account/AccountDashboardView.swift": 2,     // billing dates
        "TabMail/Views/Message/MessageDetailView+Helpers.swift": 2, // message header time
        "TabMail/Views/Agent/AgentChatSheet.swift": 3,             // event card times
        "TabMail/Views/Agent/MarkdownChatText.swift": 1,           // event card day
        "TabMail/Views/Settings/PromptHistoryView.swift": 1,       // prompt history stamp
    ]

    /// Display-only date `FormatStyle`s, as above.
    static let displayFormatStyleSites: [String: Int] = [
        "TabMail/Views/RootView.swift": 1,                         // account deletion date
        "TabMail/Views/Settings/AccountDeletionView.swift": 1,     // account deletion date
        "TabMail/Views/Settings/AccountDetailView.swift": 1,       // oldest synced month
    ]

    /// The stored reminder due-date (`yyyy-MM-dd`) read paths → the number of
    /// phone-calendar uses allowed there. The one in `ProactiveNotifyService` splits
    /// a notification's fire instant into the components its
    /// `UNCalendarNotificationTrigger` matches in the phone's calendar.
    static let dueDatePathFiles: [String: Int] = [
        "Shared/Notifications/EmailNotificationBuilder.swift": 0,
        "TabMail/Services/AI/ReminderBuilder.swift": 0,
        "TabMail/Views/Settings/RemindersSettingsView.swift": 0,
        "TabMail/Services/AI/ProactiveNotifyService.swift": 1,
    ]

    enum Rule: String, CaseIterable {
        /// A fixed or template format set on a formatter.
        case fixedFormat
        /// A `DateFormatter` built or subclassed.
        case formatterBuilt
        /// A date `FormatStyle`.
        case formatStyle
        /// The phone's calendar (`Calendar.current` and its kin).
        case phoneCalendar
        /// A `DateComponents` year set by hand.
        case handBuiltYear
        /// A call of `FixedDateFormat.gregorianDay`.
        case gregorianDayCall
    }

    /// Patterns per rule. `true` marks a pattern matched against code with string
    /// contents kept (a key-value write names the key in a string); the rest see
    /// code with comments and strings blanked.
    static let patterns: [Rule: [(String, Bool)]] = [
        .fixedFormat: [
            (#"(?<![A-Za-z0-9_])dateFormat\s*\+?=(?!=)"#, false),
            (#"\boverride\s+(public\s+|open\s+)?var\s+dateFormat\b"#, false),
            (#"\\\s*(DateFormatter)?\s*\.\s*dateFormat\b"#, false),
            (#"setLocalizedDateFormatFromTemplate"#, false),
            (#"(?<![A-Za-z0-9_])dateFormat\s*\(\s*fromTemplate"#, false),
            (#"forKey(Path)?\s*:\s*"dateFormat""#, true),
        ],
        .formatterBuilt: [
            (#"(?<![A-Za-z0-9_])DateFormatter\s*(\(|\.\s*init\b)"#, false),
            (#"\bclass\s+\w+\s*:\s*([\w.]+\s*,\s*)*DateFormatter\b"#, false),
            (#":\s*DateFormatter\s*[!?]?\s*=\s*\.\s*init\b"#, false),
            (#"\bDateFormatter\s*\.\s*localizedString\b"#, false),
            (#"\bDateIntervalFormatter\b"#, false),
        ],
        .formatStyle: [
            (#"\bVerbatimFormatStyle\b"#, false),
            (#"\bDate\s*\.\s*FormatStyle\b"#, false),
            (#"\.formatted\s*\(\s*(date|time)\s*:"#, false),
            (#"\.formatted\s*\(\s*\.\s*(dateTime|verbatim)\b"#, false),
            (#"\bformat\s*:\s*\.\s*(dateTime|verbatim|interval)\b"#, false),
            (#"\.formatted\s*\(\s*\.\s*interval\b"#, false),
            (#"\bIntervalFormatStyle\b"#, false),
        ],
        .phoneCalendar: [
            (#"\bCalendar\s*\.\s*(current|autoupdatingCurrent)\b"#, false),
            (#"\bLocale\s*\.\s*(current|autoupdatingCurrent)\s*\.\s*calendar\b"#, false),
            (#"\bcalendar\s*[:=]\s*\.\s*(current|autoupdatingCurrent)\b"#, false),
        ],
        .handBuiltYear: [
            (#"\.\s*year\s*=(?!=)"#, false),
            (#"DateComponents\s*\([^)]*\byear\s*:"#, false),
        ],
        .gregorianDayCall: [
            (#"\bFixedDateFormat\s*\.\s*gregorianDay\s*\("#, false),
        ],
    ]

    static func repositoryRoot() -> URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()   // Services
            .deletingLastPathComponent()   // TabMailTests
            .deletingLastPathComponent()   // repository root
    }

    /// `source` with comments blanked to spaces and, unless `keepStrings`, string
    /// literal contents too (newlines kept, so line numbers hold). Handles `//`,
    /// nested `/* */`, `"…"` with escapes, `"""…"""`, and raw strings `#"…"#` /
    /// `#"""…"""#`. An interpolation (`\(…)`, `\#(…)` in a raw string) is code and
    /// stays; a string nested inside one stays too, so a match there over-reports.
    static func codeOnly(_ source: String, keepStrings: Bool = false) -> [Character] {
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
                let interpolation = "\\" + String(repeating: "#", count: hashes) + "("
                var k = j + quote.count
                var segmentStart = k
                while k < chars.count {
                    if matches(interpolation, at: k) {
                        if !keepStrings { blank(segmentStart, k) }
                        k += interpolation.count
                        var depth = 1
                        while k < chars.count && depth > 0 {
                            if chars[k] == "\"" {
                                k += 1
                                while k < chars.count && chars[k] != "\"" && chars[k] != "\n" {
                                    k += chars[k] == "\\" ? 2 : 1
                                }
                            } else if chars[k] == "(" {
                                depth += 1
                            } else if chars[k] == ")" {
                                depth -= 1
                            }
                            k += 1
                        }
                        segmentStart = k
                        continue
                    }
                    if hashes == 0 && chars[k] == "\\" { k += 2; continue }
                    if !multiline && chars[k] == "\n" { break }
                    if matches(closer, at: k) { break }
                    k += 1
                }
                if !keepStrings { blank(segmentStart, k) }
                if matches(closer, at: k) { k += closer.count }
                i = k
                continue
            }
            i += 1
        }
        return out
    }

    /// 1-based lines of `source` where each rule matches, one entry per match.
    static func findings(in source: String) -> [Rule: [Int]] {
        let code = String(codeOnly(source))
        let codeWithStrings = String(codeOnly(source, keepStrings: true))
        var result: [Rule: [Int]] = [:]
        for rule in Rule.allCases {
            var lines: [Int] = []
            for (pattern, keepStrings) in patterns[rule] ?? [] {
                let text = keepStrings ? codeWithStrings : code
                let ns = text as NSString
                let regex = try! NSRegularExpression(pattern: pattern)
                lines += regex.matches(in: text, range: NSRange(location: 0, length: ns.length)).map { match in
                    ns.substring(to: match.range.location).reduce(1) { $1 == "\n" ? $0 + 1 : $0 }
                }
            }
            result[rule] = lines.sorted()
        }
        return result
    }

    struct SourceRoots: Equatable {
        /// The `- path:` source roots of every app and extension target.
        var roots: Set<String> = []
        /// What the reader met and could not read: a source entry that is not `- path:`
        /// (a bare name), an inline `sources:`, target templates, an `include:`, a target
        /// with no type, or an app or extension target with no path read. Any entry
        /// fails the fence, so a target can never drop out of the scan silently.
        var unparsed: [String] = []
    }

    /// The source roots of every app and extension target in `project.yml` (test
    /// targets skipped). Reads the `targets:` block written as `- path:` lists only.
    static func productSourceRoots(projectYML: String) -> SourceRoots {
        var result = SourceRoots()
        var inTargets = false
        var targetName: String?
        var targetType: String?
        var targetPaths: [String] = []
        var inSources = false
        var itemIndent: Int?
        func closeTarget() {
            if let name = targetName {
                if let type = targetType {
                    if !testTargetTypes.contains(type) {
                        if targetPaths.isEmpty { result.unparsed.append("target \(name): no source path read") }
                        result.roots.formUnion(targetPaths)
                    }
                } else {
                    result.unparsed.append("target \(name): no type read")
                }
            }
            targetName = nil
            targetType = nil
            targetPaths = []
            inSources = false
            itemIndent = nil
        }
        for raw in projectYML.components(separatedBy: "\n") {
            let line = raw.replacingOccurrences(of: "\t", with: "    ")
            let indent = line.prefix { $0 == " " }.count
            let body = line.trimmingCharacters(in: .whitespaces)
            if body.isEmpty || body.hasPrefix("#") { continue }
            if indent == 0 {
                if inTargets { closeTarget() }
                inTargets = body == "targets:"
                if body.hasPrefix("targetTemplates:") || body.hasPrefix("include:") {
                    result.unparsed.append(body)
                }
                continue
            }
            guard inTargets else { continue }
            if indent == 2 {
                closeTarget()
                if body.hasSuffix(":") {
                    targetName = String(body.dropLast())
                } else {
                    result.unparsed.append(body)
                }
                continue
            }
            if indent == 4 && !body.hasPrefix("- ") {
                inSources = false
                if body.hasPrefix("type:") {
                    targetType = body.dropFirst("type:".count).trimmingCharacters(in: .whitespaces)
                } else if body.hasPrefix("sources:") {
                    inSources = true
                    itemIndent = nil
                    if body != "sources:" { result.unparsed.append("target \(targetName ?? "?"): \(body)") }
                } else if body.hasPrefix("templates:") {
                    result.unparsed.append("target \(targetName ?? "?"): \(body)")
                }
                continue
            }
            guard inSources else { continue }
            if itemIndent == nil && body.hasPrefix("- ") { itemIndent = indent }
            guard indent == itemIndent else { continue }   // a path's own settings
            if body.hasPrefix("- path:") {
                targetPaths.append(body.dropFirst("- path:".count)
                    .trimmingCharacters(in: CharacterSet.whitespaces.union(CharacterSet(charactersIn: "\"'"))))
            } else {
                result.unparsed.append("target \(targetName ?? "?") source: \(body)")
            }
        }
        if inTargets { closeTarget() }
        return result
    }

    struct Scan {
        var roots: Set<String> = []
        var unparsedProjectEntries: [String] = []
        /// Repository-relative path → findings, one entry per scanned Swift file.
        var files: [String: [Rule: [Int]]] = [:]
    }

    static func scanTargets() throws -> Scan {
        let root = repositoryRoot().standardizedFileURL
        let yml = try String(contentsOf: root.appendingPathComponent("project.yml"), encoding: .utf8)
        var scan = Scan()
        let sourceRoots = productSourceRoots(projectYML: yml)
        scan.roots = sourceRoots.roots
        scan.unparsedProjectEntries = sourceRoots.unparsed
        for sourceRoot in scan.roots {
            guard let walker = FileManager.default.enumerator(
                at: root.appendingPathComponent(sourceRoot), includingPropertiesForKeys: nil)
            else { continue }
            for case let url as URL in walker where url.pathExtension == "swift" {
                let relative = String(url.standardizedFileURL.path.dropFirst(root.path.count + 1))
                guard scan.files[relative] == nil else { continue }   // nested or shared roots
                scan.files[relative] = findings(in: try String(contentsOf: url, encoding: .utf8))
            }
        }
        return scan
    }

    @Test("the scanner: each pattern counts in code; comments, strings and comparisons do not")
    func scannerIsSound() {
        let source = ##"""
        let a = DateFormatter()
        a.dateFormat = "yyyy"
        // b.dateFormat = "yyyy"; let b = DateFormatter()
        /* c.dateFormat = "yyyy" /* nested */ d.dateFormat = "x" */
        let s = "e.dateFormat = yyyy DateFormatter() .formatted(date: .long)"
        let r = #"f.dateFormat = "yyyy""#
        if g.dateFormat == "yyyy" {}
        let h = DateFormatter(); h.dateFormat="HH"
        let dateFormatter = DateFormatter.init()
        i.dateFormat += "ss"
        j
            .dateFormat
            = "yyyy"
        let m = #"""
            n.dateFormat = "yyyy"
            DateFormatter()
            """#
        class P: DateFormatter { override var dateFormat: String! { get { "" } set {} } }
        q.setValue("yyyy", forKey: "dateFormat")
        q[keyPath: \DateFormatter.dateFormat] = "yyyy"
        q.setLocalizedDateFormatFromTemplate("yMMMd")
        let t = DateFormatter.dateFormat(fromTemplate: "yMMMd", options: 0, locale: nil)
        let u = date.formatted(date: .long, time: .omitted)
        let v = date.formatted(.dateTime.year())
        Text(date, format: .dateTime.month())
        let w = Date.VerbatimFormatStyle(format: "\(year: .defaultDigits)", timeZone: .gmt, calendar: cal)
        let x: Date.FormatStyle = .init()
        Text(date, style: .date)
        let y = ISO8601DateFormatter()
        let z = Calendar.current; let zz = Calendar.autoupdatingCurrent
        let k = Locale.current.calendar; f.calendar = .current
        comps.year = 2
        let dc = DateComponents(year: 1, month: 2, day: 3)
        if comps.year == 2 {}
        let day = FixedDateFormat.gregorianDay(s, timeZone: .gmt)
        Text("to \(oldest, format: .dateTime.month().year()) then .formatted(date: x) \(n)")
        let f: DateFormatter = .init()
        let ls = DateFormatter.localizedString(from: d, dateStyle: .long, timeStyle: .none)
        let di = DateIntervalFormatter()
        let iv = (a..<b).formatted(.interval.day())
        let ifs = Date.IntervalFormatStyle(date: .long, time: .omitted)
        Text(a..<b, format: .interval)
        """##
        let found = Self.findings(in: source)
        #expect(found[.fixedFormat] == [2, 8, 10, 12, 18, 19, 20, 21, 22])
        #expect(found[.formatterBuilt] == [1, 8, 9, 18, 37, 38, 39])
        #expect(found[.formatStyle] == [23, 24, 25, 26, 27, 36, 40, 41, 42])
        #expect(found[.phoneCalendar] == [30, 30, 31, 31])
        #expect(found[.handBuiltYear] == [32, 33])
        #expect(found[.gregorianDayCall] == [35])
    }

    @Test("project.yml parsing: app and extension source roots, test targets skipped")
    func projectSourceRootsParse() {
        let yml = """
        name: App
        targets:
          App:
            type: application
            sources:
              - path: App
                excludes:
                  - "**/*.md"
              - path: Shared
          Ext:
            type: app-extension
            sources:
              - path: Ext
          AppTests:
            type: bundle.unit-test
            sources:
              - path: AppTests
              - path: Ext
          AppUITests:
            type: bundle.ui-testing
            sources:
              - path: AppUITests
        schemes:
          App:
            build:
              targets:
                App: all
        """
        #expect(Self.productSourceRoots(projectYML: yml) == SourceRoots(roots: ["App", "Shared", "Ext"]))
    }

    @Test("project.yml parsing fails loudly on a source entry it cannot read")
    func projectSourceRootsFailLoudly() {
        let yml = """
        include:
          - base.yml
        targetTemplates:
          Base:
            type: framework
        targets:
          App:
            type: application
            sources:
              - path: App
              - Widgets
          Ext:
            type: app-extension
            sources: [Ext]
          Kit:
            type: framework
            templates:
              - Base
          Bare:
            sources:
              - path: Bare
          Tests:
            type: bundle.unit-test
            sources:
              - Tests
        """
        let parsed = Self.productSourceRoots(projectYML: yml)
        #expect(parsed.roots == ["App"])
        #expect(parsed.unparsed == [
            "include:",
            "targetTemplates:",
            "target App source: - Widgets",
            "target Ext: sources: [Ext]",
            "target Ext: no source path read",
            "target Kit: templates:",
            "target Kit: no source path read",
            "target Bare: no type read",
            "target Tests source: - Tests",
        ])
    }

    @Test("no fixed format, DateFormatter or date FormatStyle outside FixedDateFormat in any target")
    func noFormatterOutsideHelper() throws {
        let scan = try Self.scanTargets()
        #expect(scan.unparsedProjectEntries.isEmpty,
                "project.yml entries the fence cannot read, so their sources would go unscanned: \(scan.unparsedProjectEntries)")
        #expect(Self.requiredSourceRoots.isSubset(of: scan.roots),
                "project.yml source roots \(scan.roots.sorted()); a target is missing, so the fence is vacuous for it")
        #expect(scan.files.count > 100, "scanned only \(scan.files.count) Swift files")
        let helper = scan.files[Self.helperFile] ?? [:]
        #expect(helper[.fixedFormat]?.count == 1,
                "\(Self.helperFile) should set a format exactly once; found \(helper[.fixedFormat] ?? [])")
        // The simulator runs the Gregorian calendar and its calendar is never switched
        // here, so a helper that read the phone's calendar would pass every behaviour
        // test; this keeps the helper from reading it at all.
        #expect(helper[.phoneCalendar]?.isEmpty ?? false,
                "\(Self.helperFile) reads the phone's calendar at lines \(helper[.phoneCalendar] ?? [])")

        var fixed: [String] = []
        var built: [String] = []
        var styles: [String] = []
        for (path, found) in scan.files where path != Self.helperFile {
            fixed += (found[.fixedFormat] ?? []).map { "\(path):\($0)" }
            let builtLines = found[.formatterBuilt] ?? []
            if builtLines.count != Self.displayFormatterSites[path, default: 0] {
                built.append("\(path) \(builtLines) (listed: \(Self.displayFormatterSites[path, default: 0]))")
            }
            let styleLines = found[.formatStyle] ?? []
            if styleLines.count != Self.displayFormatStyleSites[path, default: 0] {
                styles.append("\(path) \(styleLines) (listed: \(Self.displayFormatStyleSites[path, default: 0]))")
            }
        }
        for path in Set(Self.displayFormatterSites.keys).union(Self.displayFormatStyleSites.keys)
        where scan.files[path] == nil {
            built.append("\(path) is listed but was not scanned")
        }
        #expect(fixed.isEmpty,
                "fixed-format DateFormatter built outside FixedDateFormat (\(fixed.count)): \(fixed.sorted())")
        #expect(built.isEmpty,
                "DateFormatter built outside FixedDateFormat at an unlisted site; use FixedDateFormat, or list a display-only site: \(built.sorted())")
        #expect(styles.isEmpty,
                "date FormatStyle at an unlisted site; use FixedDateFormat, or list a display-only site: \(styles.sorted())")
    }

    @Test("stored reminder due dates are read in the Gregorian calendar, never the phone's")
    func dueDatePathsAreGregorian() throws {
        let scan = try Self.scanTargets()
        for (path, allowedPhoneCalendar) in Self.dueDatePathFiles {
            let found = try #require(scan.files[path], "\(path) was not scanned")
            #expect((found[.phoneCalendar] ?? []).count == allowedPhoneCalendar,
                    "\(path): phone calendar at lines \(found[.phoneCalendar] ?? []), \(allowedPhoneCalendar) allowed")
            #expect(found[.handBuiltYear]?.isEmpty ?? true,
                    "\(path): a due date's year set by hand at lines \(found[.handBuiltYear] ?? []); use FixedDateFormat.gregorianDay")
            #expect(!(found[.gregorianDayCall]?.isEmpty ?? true),
                    "\(path) no longer reads its due date through FixedDateFormat.gregorianDay")
            #expect(found[.formatterBuilt]?.isEmpty ?? true,
                    "\(path): a DateFormatter built on a due-date path at lines \(found[.formatterBuilt] ?? [])")
        }
    }
}
