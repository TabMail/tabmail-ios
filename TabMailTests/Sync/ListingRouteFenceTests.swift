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
/// The follow mark (#1109), column-scoped like the counters, has one writer too.
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

    /// The follow mark (`Folder.isFollowed`, #1109) is column-scoped like the
    /// counters: one writer, `SyncEngine.markFollowed`, which only ever sets it.
    /// No other code names the column to write it, no production code sets the
    /// record's field, and no whole record writes it (the encode fence in
    /// `FolderRoleTests`).
    @Test("The follow mark: one writer, which only sets it")
    func followMarkHasOneWriter() throws {
        let sources = try Self.productionSources()
        let followFile = "TabMail/Services/Sync/SyncEngineFollowedFolders.swift"
        #expect(Self.hits("markFollowed(", in: sources) == [followFile: 2],
                "the writer's definition and its one call, in followFolders")
        #expect(Self.hits("Column(Folder.followedColumn).set(", in: sources) == [followFile: 1],
                "the column is set by markFollowed alone")
        #expect(Self.hits("\"isFollowed\"", in: sources) == ["TabMail/Models/Folder.swift": 1, "TabMail/Services/AppDatabase.swift": 1],
                "the column's name appears only as its constant and in its migration")
        // Every mention of the field or column, however it is spelled (a Swift
        // assignment, SQL `SET isFollowed = 0`, `isFollowed=1`): its declaration,
        // its column constant, its migration and the one read, in `isSyncable`.
        // A new mention is reviewed against the one writer.
        let mentions = Self.hits("isFollowed", in: sources)
        #expect(mentions == [
            "TabMail/Models/Folder.swift": 2,
            "TabMail/Services/AppDatabase.swift": 1,
            Self.engineFile: 1,
        ], "no production code sets the record's mark or writes the column by name: \(mentions)")
        let follow = try #require(sources.first { $0.path == followFile }?.text)
        #expect(!follow.contains("set(to: false)"), "the mark is never cleared")
        // A message open in the app is a folder access: the production init of
        // the detail view model turns it on; only its test init leaves it off.
        let detailAccess = Self.hits("self.accessesFolder = true", in: sources)
        #expect(detailAccess == ["TabMail/ViewModels/MessageDetailViewModel.swift": 1],
                "the app's message open accesses its folder: \(detailAccess)")
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
        let engine = try #require(sources.first { $0.path == Self.engineFile }?.text)
        let body = try #require(engine.range(of: "func syncFolderMessages(").map { String(engine[$0.lowerBound...].prefix(4000)) })
        #expect(body.contains("listFolder(current, provider: provider"), "syncFolderMessages lists the re-read folder row through listFolder")
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
