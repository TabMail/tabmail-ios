import Foundation
import Testing
@testable import TabMail

/// Source fence: no route publishes a folder listing's rows or counters outside
/// the one classifier (`SyncEngine.runListing` → `ListingOutcome`). The merge
/// (`runSyncMessages`) is private and called only by the classifier; the
/// publishing step only by `listFolder`; folder counters are written only by
/// the listing's own transaction (plus synthetic seeds, through the same
/// writer); and every on-demand listing (folder open, after a send, after a
/// move, epoch-rebuild step 6) goes through `syncFolderMessages` → `listFolder`.
/// Reads the working tree at run time.
@Suite("Listing route fence: one classifier, no other door")
struct ListingRouteFenceTests {

    private static var repoRoot: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent() // Sync
            .deletingLastPathComponent() // TabMailTests
            .deletingLastPathComponent() // repo root
    }

    /// Every production Swift file (app, NSE, Shared), path relative to the root.
    private static func productionSources() throws -> [(path: String, text: String)] {
        var out: [(String, String)] = []
        for dir in ["TabMail", "TabMailNotificationService", "Shared"] {
            let base = repoRoot.appendingPathComponent(dir)
            guard let walker = FileManager.default.enumerator(at: base, includingPropertiesForKeys: nil) else { continue }
            for case let url as URL in walker where url.pathExtension == "swift" {
                let rel = String(url.path.dropFirst(repoRoot.path.count + 1))
                out.append((rel, try String(contentsOf: url, encoding: .utf8)))
            }
        }
        return out
    }

    /// Occurrences of `token` per file, comment lines excluded.
    private static func hits(_ token: String, in sources: [(path: String, text: String)]) -> [String: Int] {
        var result: [String: Int] = [:]
        for source in sources {
            let count = source.text.components(separatedBy: "\n")
                .filter { !$0.trimmingCharacters(in: .whitespaces).hasPrefix("//") }
                .reduce(0) { $0 + $1.components(separatedBy: token).count - 1 }
            if count > 0 { result[source.path] = count }
        }
        return result
    }

    static let engineFile = "TabMail/Services/Sync/SyncEngineFullSync.swift"

    @Test("The merge is private and called once, by the classifier")
    func mergeOnlyThroughTheClassifier() throws {
        let sources = try Self.productionSources()
        #expect(Self.hits("runSyncMessages(", in: sources) == [Self.engineFile: 2],
                "runSyncMessages: its definition and the one call in runListing, nothing else")
        let engine = try #require(sources.first { $0.path == Self.engineFile }?.text)
        #expect(engine.contains("private nonisolated static func runSyncMessages("), "the merge stays private")
    }

    @Test("A listing's result is published only by listFolder, which classifies it first")
    func publishOnlyThroughListFolder() throws {
        let sources = try Self.productionSources()
        #expect(Self.hits("publishListingResult(", in: sources) == [Self.engineFile: 2],
                "publishListingResult: its definition and the one call in listFolder")
        #expect(Self.hits("runListing(", in: sources).keys.allSatisfy { $0 == Self.engineFile },
                "the classifier is called only by the engine's listing routes")
    }

    @Test("Folder counters: the listing's writer, the invalidation owner, and synthetic seeds through the writer; nothing else")
    func countersOnlyThroughTheirOwners() throws {
        let sources = try Self.productionSources()
        let seeds: Set<String> = [
            "TabMail/Services/Demo/DemoSeed.swift", "TabMail/App/ScreenshotMode.swift",
            "TabMail/Views/Compose/ServerDraftCloseTestScene.swift", "TabMail/Views/Previews/PreviewMocks.swift",
        ]
        let writers = Self.hits("writeListingCounters(", in: sources)
        #expect(writers[Self.engineFile] == 2, "the writer's definition and the listing transaction's one call")
        #expect(Set(writers.keys).subtracting([Self.engineFile]).isSubset(of: seeds), "only synthetic seeds besides: \(writers)")
        for column in ["\"totalCount\"", "\"lastKnownUidNext\"", "\"lastKnownHighestModSeq\""] {
            let assigned = Self.hits("Column(\(column)).set(", in: sources)
            #expect(assigned.keys.allSatisfy { $0 == Self.engineFile }, "\(column) assigned outside the owners: \(assigned)")
        }
    }

    @Test("Every on-demand listing goes through syncFolderMessages (folder open, after a send, after a move, epoch-rebuild step 6)")
    func onDemandListingsThroughTheClassifier() throws {
        let sources = try Self.productionSources()
        let callers = Set(Self.hits("syncFolderMessages(", in: sources).keys)
        #expect(callers == [
            Self.engineFile,
            "TabMail/Services/Account/AccountManagerFetch.swift",
            "TabMail/ViewModels/MessageDetailViewModel.swift",
            "TabMail/Services/Account/AccountManagerUidValidityReset.swift",
            "TabMail/Services/Account/AccountManagerOutbox.swift",
            "TabMail/Services/Account/AccountOperationExecutor.swift",
        ], "a new caller is reviewed against the one classifier: \(callers.sorted())")
    }

    /// Both stale-sweep branches build the coverage they judge with through the
    /// one builder (`sweepCoverage`), so the listing's own SELECT bound reaches
    /// whichever branch runs; and the windowed candidate load and the removal
    /// decision take their UID window from the same helper.
    @Test("The stale sweep's coverage has one builder, used by both branches")
    func sweepCoverageHasOneBuilder() throws {
        let sources = try Self.productionSources()
        let engine = try #require(sources.first { $0.path == Self.engineFile }?.text)
        let assignments = engine.components(separatedBy: "\n")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { $0.hasPrefix("effectiveCoverage = ") }
        #expect(assignments.count == 3, "the unproven arm and the two sweep branches: \(assignments)")
        #expect(assignments.allSatisfy { $0 == "effectiveCoverage = .unproven" || $0.hasPrefix("effectiveCoverage = Self.sweepCoverage(") },
                "every sweep branch builds its coverage through sweepCoverage: \(assignments)")
        #expect(engine.contains("Self.sweepCoverage(coverage, wholeFolder: true)"))
        #expect(engine.contains("Self.sweepCoverage(coverage, wholeFolder: false)"))
        #expect(Self.hits("windowedSweepUIDBounds(", in: sources) == [Self.engineFile: 3],
                "definition, the windowed candidate load and selectStaleHeaders' windowed arm")
    }
}
