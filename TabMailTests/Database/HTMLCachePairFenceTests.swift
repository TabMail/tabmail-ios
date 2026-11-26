/* This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at https://mozilla.org/MPL/2.0/. */

import Foundation
import Testing
@testable import TabMail

/// #1433: "is this message's HTML cached?" is asked through `HTMLCachePair`, which
/// reads one header row; a probe of `messageBody` itself reads the body row, HTML
/// included, and is what the pair replaced at five sites. So every query site that
/// names `messageBody` outside `HTMLCachePair` and the registered migrations is
/// listed here with the reason it needs the body row, by file and enclosing
/// declaration with its count of sites (the census of `QueryCensusScanner`). A new
/// site fails until it is listed with its reason, or asks `HTMLCachePair` instead.
///
/// And `messageHeader.htmlCachedAt` is written only by v116's triggers and the
/// deferred fill (`HTMLCachePair.fillSQL`), and read only through `HTMLCachePair`: no
/// other production code names it.
@Suite("HTML-cache pair fence")
struct HTMLCachePairFenceTests {

    struct Allowed {
        let count: Int
        let reason: String
    }

    static let readsHTML = "reads the HTML itself, not whether it is cached"
    static let writesHTML = "writes the HTML cache; v116's triggers keep the pair"
    static let deletesHTML = "deletes cached HTML; v116's triggers keep the pair"
    static let carries = "carries a body through an id rename (reads it, deletes the old row, writes it under the new id)"

    static let allowed: [String: Allowed] = [
        "TabMail/App/ScreenshotMode.swift\tScreenshotMode.seedIfNeeded":
            Allowed(count: 4, reason: "debug screenshot scene: wipes the HTML cache and writes its fixtures"),
        "TabMail/Models/Draft.swift\tDraft.resolveReplyQuote": Allowed(count: 1, reason: readsHTML),
        "TabMail/Providers/DemoProvider.swift\tDemoProvider.deleteDraft": Allowed(count: 1, reason: "demo: " + deletesHTML),
        "TabMail/Providers/DemoProvider.swift\tDemoProvider.fetchMessage": Allowed(count: 1, reason: "demo: " + readsHTML),
        "TabMail/Providers/DemoProvider.swift\tDemoProvider.fetchTextBodies": Allowed(count: 1, reason: "demo: " + readsHTML),
        "TabMail/Providers/DemoProvider.swift\tDemoProvider.saveDraft": Allowed(count: 1, reason: "demo: " + writesHTML),
        "TabMail/Services/Account/AccountManagerActions.swift\tAccountManager.admitDraftToDrafts": Allowed(count: 1, reason: writesHTML),
        "TabMail/Services/Account/AccountManagerActions.swift\tAccountManager.queueDraftDelete": Allowed(count: 2, reason: deletesHTML),
        "TabMail/Services/Account/AccountManagerAI.swift\tOpenedAIProcessingSnapshot.capture": Allowed(count: 1, reason: readsHTML),
        "TabMail/Services/Account/AccountManagerOutbox.swift\tAccountManager.insertOptimisticSentHeader": Allowed(count: 2, reason: writesHTML),
        "TabMail/Services/Account/AccountManagerSetup.swift\tAccountManager.removeAccountRowsTxn":
            Allowed(count: 2, reason: "account removal: " + deletesHTML),
        "TabMail/Services/Account/AccountManagerUidValidityReset.swift\tAccountManager.uidValidityResetPurgeTxn":
            Allowed(count: 3, reason: "UIDVALIDITY reset: deletes every body in the folder's id range, with or without a header, and by key the bodies of its own headers whose id tail holds a ':'"),
        "TabMail/Services/AI/AIInlineEdit.swift\tComposeEditContext.relatedBodyText": Allowed(count: 1, reason: readsHTML),
        "TabMail/Services/AI/Tools/AttachmentReadPdfTool.swift\tAttachmentReadPdfTool.readBody": Allowed(count: 1, reason: readsHTML),
        "TabMail/Services/AI/Tools/EmailReadTool.swift\tEmailReadTool.execute": Allowed(count: 1, reason: readsHTML),
        "TabMail/Services/AppDataWiper.swift\tAppDataWiper.wipeRowsTxn": Allowed(count: 2, reason: "wipe: " + deletesHTML),
        "TabMail/Services/BodyAssetMaintenance.swift\tBodyAssetMaintenance.dropMessage": Allowed(count: 2, reason: deletesHTML),
        "TabMail/Services/BodyAssetMaintenance.swift\tBodyAssetMaintenance.wipeAll": Allowed(count: 2, reason: deletesHTML),
        "TabMail/Services/Demo/DemoModeService.swift\tDemoModeService.indexSeededFTS": Allowed(count: 1, reason: "demo: " + readsHTML),
        "TabMail/Services/Demo/DemoSeed.swift\tDemoSeed.seedMessages": Allowed(count: 1, reason: "demo: " + writesHTML),
        "TabMail/Services/Demo/DemoSeed.swift\tDemoSeed.wipe": Allowed(count: 2, reason: "demo: " + deletesHTML),
        "TabMail/Services/MessageContentStore.swift\tMessageContentStore.release": Allowed(count: 2, reason: deletesHTML),
        "TabMail/Services/MessageHeaderRekey.swift\tMessageHeaderRekey.apply": Allowed(count: 2, reason: carries),
        "TabMail/Services/NSEDataBridge.swift\tNSEDataBridge.persistRenderedBodyFromStaging": Allowed(count: 1, reason: writesHTML),
        "TabMail/Services/StartupMigrations.swift\tStartupMigrations.run":
            Allowed(count: 4, reason: "one-shot startup migrations: " + deletesHTML),
        "TabMail/Services/Sync/SyncEngineChangesApply.swift\tSyncEngine.insertChangeRecord": Allowed(count: 2, reason: carries),
        "TabMail/Services/Sync/SyncEngineFullSync.swift\tSyncEngine.canonicalizeLocalRows":
            Allowed(count: 4, reason: carries + "; the read before the insert is the insert's own guard: it needs the body row's absence (its primary key)"),
        "TabMail/Services/Sync/SyncEngineFullSync.swift\tSyncEngine.runSyncMessages":
            Allowed(count: 5, reason: carries + ", and deletes a duplicate's body"),
        "TabMail/Services/Sync/SyncEngineMaintenance.swift\tSyncEngine.pruneFolderBodies": Allowed(count: 1, reason: deletesHTML),
        "TabMail/Services/Sync/SyncEngineMaintenance.swift\tSyncEngine.runEvictStaleBodies":
            Allowed(count: 1, reason: "the evict: deletes each candidate's body; candidates come from HTMLCachePair"),
        "TabMail/Services/Sync/SyncEngineFTS.swift\tSyncEngine.oneTimeBodyCompleteRestore":
            Allowed(count: 2, reason: "runs once at startup, possibly before the deferred fill records the bodies cached before v116, so it asks messageBody itself (HTMLCachePair, \"Before the deferred index step\")"),
        "TabMail/Services/Sync/SyncEngineSettingsReset.swift\tSyncEngine": Allowed(count: 1, reason: "settings reset statement list: " + deletesHTML),
        "TabMail/Services/Sync/SyncEngineSettingsReset.swift\tSyncEngine.resetMessageDataTxn": Allowed(count: 2, reason: deletesHTML),
        "TabMail/ViewModels/InboxViewModel.swift\tInboxViewModel.deleteDraftMessage": Allowed(count: 1, reason: deletesHTML),
        "TabMail/ViewModels/MessageDetailViewModel.swift\tMessageDetailViewModel.adoptReadyBody": Allowed(count: 1, reason: readsHTML),
        "TabMail/ViewModels/MessageDetailViewModel.swift\tMessageDetailViewModel.bodyFor": Allowed(count: 1, reason: readsHTML),
        "TabMail/ViewModels/MessageDetailViewModel.swift\tMessageDetailViewModel.loadBody": Allowed(count: 2, reason: readsHTML),
        "TabMail/ViewModels/MessageDetailViewModel.swift\tMessageDetailViewModel.refetchBody": Allowed(count: 2, reason: readsHTML),
        "TabMail/ViewModels/MessageDetailViewModel.swift\tMessageDetailViewModel.startBodyPoll": Allowed(count: 1, reason: readsHTML),
        "TabMail/Views/Chat/ChatThreadContext.swift\tChatThreadContext.load":
            Allowed(count: 1, reason: "reads each member's attachment list and calendar file, never its HTML or whether it is cached"),
        "TabMail/Views/Compose/ComposeView.swift\tComposeView.recomputedReply": Allowed(count: 1, reason: readsHTML),
    ]

    static let pairFile = "TabMail/Services/HTMLCachePair.swift"
    static let migrationsFile = "TabMail/Services/AppDatabase.swift"
    static let migrationsContext = "AppDatabase.registerAllMigrations"

    /// The count of sites naming `messageBody`, by "file<TAB>declaration", outside the
    /// pair and the registered migrations.
    static func bodySites(_ sites: [QueryCensusScanner.Site]) -> [String: Int] {
        var counts: [String: Int] = [:]
        for site in sites where site.text.range(of: "messagebody", options: .caseInsensitive) != nil {
            if site.file == pairFile { continue }
            if site.file == migrationsFile && site.context == migrationsContext { continue }
            counts["\(site.file)\t\(site.context)", default: 0] += 1
        }
        return counts
    }

    @Test("Every messageBody site outside HTMLCachePair is listed, with its reason")
    func everyBodySiteIsListed() throws {
        let counts = Self.bodySites(try QueryCensusScanner.scan(root: DatabaseIndexTests.repositoryRoot))
        let unlisted = counts.keys.filter { Self.allowed[$0] == nil }.sorted()
        let recounted = counts.compactMap { key, count -> String? in
            guard let entry = Self.allowed[key], entry.count != count else { return nil }
            return "\(key): \(count) sites, listed as \(entry.count)"
        }.sorted()
        let gone = Self.allowed.keys.filter { counts[$0] == nil }.sorted()
        let unexplained = Self.allowed.filter { $0.value.reason.isEmpty || $0.value.count < 1 }.keys.sorted()
        #expect(unlisted.isEmpty,
                "messageBody sites not listed here: to ask whether HTML is cached, use HTMLCachePair; otherwise list the site with its reason: \(unlisted)")
        #expect(recounted.isEmpty, "a listed declaration gained or lost messageBody sites; re-check its reason: \(recounted)")
        #expect(gone.isEmpty, "listed declarations with no messageBody site left; remove them: \(gone)")
        #expect(unexplained.isEmpty, "every entry gives a reason and a count: \(unexplained)")
    }

    /// Non-vacuity: the census sees an existence probe of `messageBody` written as a
    /// record read and as SQL, neither is listed, and the same source inside
    /// `HTMLCachePair.swift` is exempt.
    @Test("The fence sees an existence probe outside HTMLCachePair, and exempts the pair itself")
    func theFenceSeesAProbe() {
        let source = """
            import GRDB

            enum Probe {
                static func hasBody(_ db: Database, id: String) throws -> Bool {
                    try MessageBody.fetchOne(db, key: id) != nil
                }

                static func bodyCount(_ db: Database, id: String) throws -> Int {
                    try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM messageBody WHERE id = ?", arguments: [id]) ?? 0
                }
            }
            """
        let elsewhere = Self.bodySites(QueryCensusScanner.scan(file: "TabMail/Probe.swift", source: source))
        let inThePair = Self.bodySites(QueryCensusScanner.scan(file: Self.pairFile, source: source))
        let total = elsewhere.values.reduce(0, +)
        let listed = elsewhere.keys.filter { Self.allowed[$0] != nil }
        #expect(total == 3, "the record read, the SQL call and its literal: \(elsewhere)")
        #expect(listed.isEmpty, "the probe's sites are not listed, so the fence fails on them: \(listed)")
        #expect(inThePair.isEmpty, "the same source in HTMLCachePair.swift is exempt: \(inThePair)")
    }

    @Test("Only the migrations and HTMLCachePair name htmlCachedAt in code")
    func onlyTheOwnersNameTheColumn() throws {
        let root = DatabaseIndexTests.repositoryRoot
        var namers: Set<String> = []
        var files = 0
        for directory in QueryCensusScanner.sourceDirectories {
            let walker = FileManager.default.enumerator(
                at: root.appendingPathComponent(directory), includingPropertiesForKeys: nil)
            while let url = walker?.nextObject() as? URL {
                guard url.pathExtension == "swift" else { continue }
                files += 1
                let source = try String(contentsOf: url, encoding: .utf8)
                let code = source.components(separatedBy: "\n")
                    .filter { !$0.trimmingCharacters(in: .whitespaces).hasPrefix("//") }
                if code.contains(where: { $0.contains("htmlCachedAt") }) {
                    namers.insert(url.lastPathComponent)
                }
            }
        }
        let owners: Set<String> = ["AppDatabase.swift", "HTMLCachePair.swift"]
        #expect(files > 100, "setup: the walk read the production sources: \(files) files")
        #expect(namers == owners, "htmlCachedAt is written by v116's triggers and the fill, and read through HTMLCachePair only: \(namers.sorted())")
    }
}
