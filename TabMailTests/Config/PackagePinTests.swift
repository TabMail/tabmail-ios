/* This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at https://mozilla.org/MPL/2.0/. */

import Foundation
import Testing
@testable import TabMail

/// Every package version is pinned by the tracked `Package.resolved` at the repository root, which
/// `Scripts/xcodegen.sh` copies into the generated project (ADR-IOS-102): every clone and every
/// release then builds the same versions.
struct PackagePinTests {
    private var root: URL {
        URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
    }

    private func read(_ path: String) throws -> String {
        try String(contentsOf: root.appendingPathComponent(path), encoding: .utf8)
    }

    private struct Pin {
        let identity: String
        let revision: String
        let version: String?
    }

    private func pins() throws -> [Pin] {
        let data = try Data(contentsOf: root.appendingPathComponent("Package.resolved"))
        let object = try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        let list = try #require(object["pins"] as? [[String: Any]])
        return try list.map { entry in
            let state = try #require(entry["state"] as? [String: Any])
            return Pin(
                identity: try #require(entry["identity"] as? String),
                revision: try #require(state["revision"] as? String),
                version: state["version"] as? String
            )
        }
    }

    /// The packages `project.yml` names, as SwiftPM identities (the repository name, lowercased).
    private func declaredIdentities() throws -> [String] {
        try read("project.yml").split(separator: "\n").compactMap { line in
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard trimmed.hasPrefix("url: https://github.com/") else { return nil }
            let name = trimmed.split(separator: "/").last.map(String.init) ?? ""
            return name.replacingOccurrences(of: ".git", with: "").lowercased()
        }
    }

    @Test func theFileIsTrackedNotIgnored() throws {
        let ignore = try read(".gitignore").split(separator: "\n").map { $0.trimmingCharacters(in: .whitespaces) }
        #expect(!ignore.contains("Package.resolved"))
        #expect(!ignore.contains("/Package.resolved"))
        #expect(FileManager.default.fileExists(atPath: root.appendingPathComponent("Package.resolved").path))
    }

    @Test func everyPinNamesOneRevisionAndEveryDeclaredPackageIsPinned() throws {
        let pinned = try pins()
        #expect(pinned.count > 10)
        #expect(Set(pinned.map(\.identity)).count == pinned.count)
        for pin in pinned {
            #expect(pin.revision.count == 40, "\(pin.identity)")
        }
        let declared = try declaredIdentities()
        #expect(declared.count >= 3)
        for identity in declared {
            #expect(pinned.contains { $0.identity == identity }, "\(identity) is declared in project.yml but not pinned")
        }
    }

    /// `project.yml` names SwiftMail's exact revision; the pin file must say the same one.
    @Test func swiftMailIsPinnedToTheRevisionProjectYMLNames() throws {
        let yml = try read("project.yml")
        let lines = yml.split(separator: "\n").map { $0.trimmingCharacters(in: .whitespaces) }
        let start = try #require(lines.firstIndex { $0 == "SwiftMail:" })
        let revisionLine = try #require(lines[start...].first { $0.hasPrefix("revision:") })
        let revision = revisionLine.replacingOccurrences(of: "revision:", with: "").trimmingCharacters(in: .whitespaces)
        let pin = try #require(try pins().first { $0.identity == "swiftmail" })
        #expect(pin.revision == revision)
    }

    /// The Acknowledgments screen shows the license of the BoringSSL a pinned NIOSSL carries: from
    /// 2.37.6 on it is Apache 2.0, and the pin keeps it from moving back.
    @Test func swiftNIOSSLIsAtOrAboveTheReleaseWithTheApacheBoringSSL() throws {
        let pin = try #require(try pins().first { $0.identity == "swift-nio-ssl" })
        let parts = try #require(pin.version).split(separator: ".").compactMap { Int($0) }
        #expect(parts.count == 3)
        guard parts.count == 3 else { return }
        #expect((parts[0], parts[1], parts[2]) >= (2, 37, 6))
    }

    /// The generated project is rewritten on every generation, so the script puts the pins in after it.
    @Test func theGeneratorCopiesThePinsIntoTheProject() throws {
        let script = try read("Scripts/xcodegen.sh")
        let generate = try #require(script.range(of: "xcodegen generate"))
        let copy = try #require(script.range(of: "cp Package.resolved"))
        #expect(generate.lowerBound < copy.lowerBound)
        #expect(!script.contains("exec xcodegen"))
        #expect(script.contains("xcshareddata/swiftpm"))
    }
}
