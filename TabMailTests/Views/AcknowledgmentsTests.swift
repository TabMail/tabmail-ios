/* This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at https://mozilla.org/MPL/2.0/. */

import Foundation
import Testing
@testable import TabMail

/// The Acknowledgments screen: MIT, BSD and Apache-2.0 each require the copyright notice and the
/// license text to go with the binary, so every credit shows its text, and every shipped component
/// is credited.
struct AcknowledgmentsTests {
    private var bundleRoot: URL { Bundle.main.resourceURL! }

    private var repositoryRoot: URL {
        URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
    }

    /// Every credit's license texts are in the app and say something.
    @Test func everyCreditsLicenseTextIsInTheApp() {
        for entry in AcknowledgmentEntry.all {
            #expect(!entry.texts.isEmpty, "\(entry.name) has no license text")
            for text in entry.texts {
                let shown = AcknowledgmentText.load(text.path)
                #expect(shown.count > 500, "\(entry.name): \(text.path) is missing or empty")
            }
        }
    }

    /// A license file in the bundled folder that no credit shows is a credit that was dropped.
    @Test func everyBundledLicenseFileIsShownByACredit() throws {
        let shown = Set(AcknowledgmentEntry.all.flatMap { $0.texts.map(\.path) })
        let folder = bundleRoot.appendingPathComponent("licenses")
        let files = try FileManager.default.contentsOfDirectory(atPath: folder.path)
        #expect(files.count == shown.filter { $0.hasPrefix("licenses/") }.count)
        #expect(files.count > 10)
        for file in files {
            #expect(shown.contains("licenses/\(file)"), "\(file) is bundled but shown by no credit")
        }
    }

    /// Everything compiled or bundled that asks for credit has one, and nothing that isn't shipped.
    @Test func theShippedComponentsAreCreditedAndTheStaleOnesAreNot() {
        let names = AcknowledgmentEntry.all.map(\.name)
        for required in [
            "SwiftMail", "SwiftCross", "SwiftSoup", "GRDB.swift", "SwiftNIO", "SwiftNIO SSL", "BoringSSL",
            "SwiftNIO IMAP", "Swift Log", "Swift Collections", "Swift Atomics", "sqlite-vec", "PDF.js", "PDF.js CMaps", "all-MiniLM-L6-v2", "MiniLM", "BERT", "FrequencyWords", "OpenSubtitles", "wordfreq", "OpenCC", "Unicode CLDR",
        ] {
            #expect(names.contains { $0.hasPrefix(required) }, "\(required) is not credited")
        }
        #expect(!names.contains { $0.contains("ZIPFoundation") })
        #expect(Set(names).count == names.count)
        let swiftMail = AcknowledgmentEntry.all.first { $0.name.hasPrefix("SwiftMail") }
        #expect(swiftMail?.url == "https://github.com/TabMail/SwiftMail")
        #expect(swiftMail?.copyright.contains("Oliver Drobnik") == true)
    }

    /// The copyright holders the licenses name are on the screen.
    @Test func theCopyrightHoldersAreNamed() {
        for entry in AcknowledgmentEntry.all {
            #expect(entry.copyright.count > 5, "\(entry.name)")
        }
        let soup = AcknowledgmentEntry.all.first { $0.name == "SwiftSoup" }
        #expect(soup?.copyright.contains("Jonathan Hedley") == true)
        #expect(soup?.copyright.contains("Nabil Chatbi") == true)
    }

    /// The converted model's Apache license asks that a change is stated.
    /// A credit line's copyright years must be the years its own shown notice carries, so one screen never
    /// states two different spans for the same holder.
    @Test func eachCreditLineYearsAppearInTheTextsItShows() throws {
        let yearPattern = try Regex(#"\d{4}(-\d{4})?"#)
        var checked = 0
        for entry in AcknowledgmentEntry.all {
            let shown = entry.texts.map { AcknowledgmentText.load($0.path) }
                .joined(separator: "\n")
                .replacingOccurrences(of: "\u{2013}", with: "-")
            let line = entry.copyright.replacingOccurrences(of: "\u{2013}", with: "-")
            for match in line.matches(of: yearPattern) {
                checked += 1
                #expect(shown.contains(String(match.output[0].substring ?? "")),
                        "\(entry.name): \(match.output[0].substring ?? "") is not in the text it shows")
            }
        }
        #expect(checked > 10)
    }

    @Test func theLinesALicenseAsksForAreShown() {
        let boring = AcknowledgmentEntry.all.first { $0.name.hasPrefix("BoringSSL") }
        // The package pins (Package.resolved) make the BoringSSL the Apache-2.0 one, which asks for no
        // acknowledgment sentence; its license is the only text.
        #expect(boring?.note == nil)
        #expect(boring?.texts.map(\.path) == ["licenses/boringssl.txt"])
        let boringText = AcknowledgmentText.load("licenses/boringssl.txt")
        #expect(boringText.contains("Apache License"))
        #expect(!boringText.contains("OpenSSL"))
        let model = AcknowledgmentEntry.all.first { $0.name == "all-MiniLM-L6-v2" }
        #expect(model?.note?.contains("Modified") == true)
        #expect(model?.note?.contains("Core ML") == true)
    }

    /// Each credit shows ITS license: the file named for it holds its copyright holder and the clause
    /// that makes the license binding (MIT's retention clause, BSD's source and binary conditions).
    @Test func eachCreditShowsItsOwnLicenseWithTheClauseThatBindsIt() {
        let mit = "The above copyright notice and this permission notice shall be"
        let bsd = "Redistributions in binary form must reproduce the above copyright"
        let apacheEnd = "END OF TERMS AND CONDITIONS"
        let expected: [(credit: String, file: String, holder: String, clause: String)] = [
            ("SwiftMail", "swiftmail", "Oliver Drobnik", bsd),
            ("SwiftCross", "swiftcross", "Cocoanetics", mit),
            ("SwiftSoup", "swiftsoup", "Jonathan Hedley", mit),
            ("GRDB.swift", "grdb", "Gwendal Roué", mit),
            ("sqlite-vec", "sqlite-vec", "Alex Garcia", mit),
            ("SwiftNIO IMAP", "fastbase64", "Wojciech Muła", bsd),
            ("SwiftNIO IMAP", "stringencoders", "Nick Galbreath", mit),
            ("MiniLM", "minilm-base", "Microsoft Corporation", mit),
            ("PDF.js", "core-js", "Denis Pushkarev", mit),
            ("SwiftNIO IMAP", "swift-nio-imap", "Copyright 2020 The SwiftNIO Project", apacheEnd),
            ("SwiftNIO SSL", "swift-nio-ssl", "boringssl", apacheEnd),
            ("SwiftNIO", "swift-nio", "llhttp", apacheEnd),
            ("SwiftNIO", "cpp-magic", "Thomas Nixon", mit),
            ("Swift Log", "swift-log", "The SwiftLog Project", apacheEnd),
            ("Swift Collections", "swift-collections", "Runtime Library Exception", apacheEnd),
            ("Swift Atomics", "swift-atomics", "Runtime Library Exception", apacheEnd),
            ("SwiftSoup", "lrucache", "Nick Lockwood", mit),
            ("GRDB.swift", "rails-inflections", "Heinemeier Hansson", "The above copyright notice and this permission notice shall be"),
            ("BoringSSL", "boringssl", "Apache License", apacheEnd),
            ("all-MiniLM-L6-v2", "apache-2.0", "Apache License", apacheEnd),
            ("BERT", "apache-2.0", "Apache License", apacheEnd),
        ]
        for item in expected {
            let credit = AcknowledgmentEntry.all.first { $0.name.hasPrefix(item.credit) }
            #expect(credit?.texts.contains { $0.path == "licenses/\(item.file).txt" } == true, "\(item.credit) does not show \(item.file)")
            let text = AcknowledgmentText.load("licenses/\(item.file).txt")
            #expect(text.contains(item.holder), "\(item.file) lacks \(item.holder)")
            #expect(text.contains(item.clause), "\(item.file) lacks its binding clause")
        }
    }

    /// A credit lists each of its texts once, and the load-bearing credits name what they must.
    @Test func eachCreditsTextsAreDistinctAndTheKeyOnesArePinned() {
        for entry in AcknowledgmentEntry.all {
            let paths = entry.texts.map(\.path)
            #expect(Set(paths).count == paths.count, "\(entry.name) lists a text twice")
        }
        func entry(_ name: String) -> AcknowledgmentEntry? { AcknowledgmentEntry.all.first { $0.name == name } }
        #expect(entry("PDF.js")?.texts.map(\.path) == ["pdfjs/LICENSE", "licenses/core-js.txt"])
        #expect(entry("PDF.js CMaps")?.texts.map(\.path) == ["pdfjs/cmaps/LICENSE"])
        #expect(entry("SwiftNIO")?.texts.map(\.path) == ["licenses/swift-nio.txt", "licenses/cpp-magic.txt"])
        #expect(entry("SwiftNIO")?.license == "Apache License 2.0")
        #expect(entry("Unicode CLDR")?.texts.map(\.path) == ["wordlist/README.md"])
        #expect(entry("Unicode CLDR")?.copyright.contains("Unicode, Inc.") == true)
        #expect(entry("FrequencyWords")?.texts.map(\.path) == ["wordlist/README.md"])
        #expect(entry("MiniLM (base model of all-MiniLM-L6-v2)")?.texts.map(\.path) == ["licenses/minilm-base.txt"])
    }

    /// Rows are told apart: no two credits share an identity, or a selection could open another.
    @Test func everyCreditHasItsOwnIdentity() {
        let ids = AcknowledgmentEntry.all.map(\.id)
        #expect(Set(ids).count == ids.count)
        #expect(ids.allSatisfy { !$0.isEmpty })
    }

    /// The text shown is the license as published: the one in the repository is the one shown.
    @Test func aLicenseTheRepositoryHoldsIsShownUnchanged() throws {
        let vec = try String(contentsOf: repositoryRoot.appendingPathComponent("TabMail/Vendor/sqlite-vec/LICENSE-MIT"), encoding: .utf8)
        #expect(AcknowledgmentText.load("licenses/sqlite-vec.txt").trimmingCharacters(in: .whitespacesAndNewlines) == vec.trimmingCharacters(in: .whitespacesAndNewlines))
        let pdf = try String(contentsOf: repositoryRoot.appendingPathComponent("TabMail/Vendor/pdfjs/LICENSE"), encoding: .utf8)
        #expect(AcknowledgmentText.load("pdfjs/LICENSE") == pdf)
    }

    /// The screen reads files of the bundle only: no network, no web view.
    @Test func theScreenReadsOnlyTheBundle() throws {
        let source = try String(contentsOf: repositoryRoot.appendingPathComponent("TabMail/Views/Settings/AcknowledgmentsView.swift"), encoding: .utf8)
        for forbidden in ["URLSession", "WKWebView", "ZIPFoundation"] {
            #expect(!source.contains(forbidden), "\(forbidden)")
        }
    }
}
