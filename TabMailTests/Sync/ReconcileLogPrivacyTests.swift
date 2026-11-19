import Foundation
import GRDB
import Testing
@testable import TabMail

/// The always-on sync log never carries a user-named folder: the deletion path's
/// always-on line names the folder's role, and its name reaches only the
/// debug-gated line.
///
/// `.serialized, .processGlobalState`: rebinds `AppLogStore.fileURLOverride` and
/// `DebugModeManager.loggingEnabledOverrideForTesting`.
@Suite("Server-confirmed deletion: the always-on log keeps the folder name out", .serialized, .processGlobalState)
struct ReconcileLogPrivacyTests {

    private static let folderName = "Quarterly Planning Folder"

    private func withLog<T>(debug: Bool, _ body: () async throws -> T) async throws -> T {
        let logDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("reconcile_log_\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: logDir, withIntermediateDirectories: true)
        AppLogStore.fileURLOverride.withLock { $0 = logDir.appendingPathComponent("tabmail.log") }
        DebugModeManager.loggingEnabledOverrideForTesting.withLock { $0 = debug }
        defer {
            DebugModeManager.loggingEnabledOverrideForTesting.withLock { $0 = nil }
            AppLogStore._resetForTesting()
            try? FileManager.default.removeItem(at: logDir)
        }
        return try await body()
    }

    @Test("Debug logging off: a deletion is logged by role, the folder name nowhere in the log")
    func debugOffKeepsTheNameOut() async throws {
        try await ChangeApplyTests.withWorld { w in
            let folder = Folder(name: Self.folderName, path: Self.folderName, role: .custom, accountId: w.accountId)
            try await w.pool.write { db in try folder.insert(db) }
            try w.insertRow("gone1", in: folder.id, path: folder.path)
            let (removed, log) = try await withLog(debug: false) {
                let removed = try await SyncEngine().deleteServerConfirmedDeletions(
                    folder: folder, ids: ["gone1"], reason: "test")
                return (removed, AppLogStore.read(channel: .sync) + AppLogStore.read(channel: .debug))
            }
            #expect(removed == 1)
            #expect(log.contains("custom folder removed 1"), "the deletion is still logged, by role")
            #expect(!log.contains(Self.folderName), "the user's folder name never reaches the always-on log")
        }
    }
}
