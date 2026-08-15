/* This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at https://mozilla.org/MPL/2.0/. */

import Foundation
import GRDB
import SwiftUI
import Testing
import UIKit
import WebKit
@testable import TabMail

/// Issue #21 measurement fixture. This intentionally hosts the whole production
/// MessageDetailView hierarchy; a standalone List or AutoSizingHTMLView would not
/// measure the container that is reported to move.
@MainActor
@Suite("Issue 21 disclosure viewport measurement", .serialized, .processGlobalState)
struct MessageDisclosureViewportMeasurementTests {
    /// C1/C2 are no-later-message support coverage, C3 covers the production
    /// opening position, and C4 is the only leg that discriminates the opening
    /// re-anchor regression after a programmatic scroll. The separate C4
    /// sensitivity test below proves that discriminating precondition remains live.
    @Test("C1-C4 quote and invite keep their supported settled anchors stable")
    func productionDetailConfigurations() async throws {
        for disclosure in [DisclosureKind.quote, .invite] {
            for configuration in [
                MeasurementConfiguration.c1,
                .c2,
                .c3,
                .c4,
            ] {
                let result = try await measure(configuration: configuration, disclosure: disclosure)
                result.printSummary()
                try result.requireMaterialDisclosure()
                try result.requireUserVisibleAnchorStable()
            }
        }
    }

    @Test("C4 quote and invite sensitivity bypasses produce the known outer re-anchor movement")
    func productionDetailC4SensitivityControl() async throws {
        UserDisclosureViewportAnchorTestControl.reset(bypass: true)
        defer { UserDisclosureViewportAnchorTestControl.reset() }
        for disclosure in [DisclosureKind.quote, .invite] {
            let result = try await measure(
                configuration: .c4,
                disclosure: disclosure,
                testBypassesDisclosureOpenAnchorDisarm: true
            )
            result.printSummary()
            try result.requireMaterialDisclosure()
            try result.requireKnownBadOuterReanchorMovement()
        }
    }

    @Test("R2 production hierarchy row insertion, disclosure positioning, and cycles")
    func productionDetailStressTransitions() async throws {
        ScrollFreezeGate.shared.end()
        let fixture = try DetailDatabaseFixture(configuration: .stress, disclosure: .quote)
        defer {
            fixture.tearDown()
            ScrollFreezeGate.shared.end()
        }
        let host = try await ProductionDetailHost(messageId: fixture.focusedHeaderId)
        defer { host.tearDown() }

        let webView = try await host.webView(containing: fixture.sentinelId)
        let hierarchy = try ProductionHierarchy(webView: webView, window: host.window)
        try await waitForListItems(
            hierarchy.list,
            exactly: Issue21Geometry.singleMessageListItemCount
        )
        let ready = try await waitForDOM(webView, sentinelId: fixture.sentinelId)
        try require(ready.label == DisclosureKind.quote.showLabel, "stress quote was not collapsed")

        let initialSeries = try await settle(
            phase: "R2-initial",
            configuration: .stress,
            disclosure: .quote,
            webView: webView,
            hierarchy: hierarchy,
            sentinelId: fixture.sentinelId,
            required: nil
        )
        let initial = try requireLast(initialSeries, phase: "R2-initial")
        try hierarchy.requireHostedCellAgreesWithLayout()
        try require(
            initial.focusedCardHeight < initial.listHeight - Issue21Geometry.interiorMargin,
            "stress focused card was not shorter than the viewport before expansion"
        )
        try require(
            initial.bottomSpacer > Issue21Geometry.materialDynamicSpacer,
            "stress bottom spacer was not materially in its dynamic tall branch"
        )

        let insertion = try await captureTransition(
            name: "R2a-insert-and-expand-settled",
            webView: webView,
            hierarchy: hierarchy,
            sentinelId: fixture.sentinelId,
            configuration: .stress,
            disclosure: .quote,
            action: {
                try fixture.insertLaterMessages(count: Issue21Geometry.stressLaterMessageCount)
                NotificationCenter.default.post(name: .nseMergeDidCommit, object: nil)
                // Let the production List finish adopting the new focused-row
                // index before asking that hosted row to report a much larger
                // HTML height. The transition records both operations, but does
                // not depend on an unobservable overlap between their updates.
                _ = try await settle(
                    phase: "R2a-post-insert",
                    configuration: .stress,
                    disclosure: .quote,
                    webView: webView,
                    hierarchy: hierarchy,
                    sentinelId: fixture.sentinelId,
                    required: { sample in
                        sample.listItemCount == Issue21Geometry.stressListItemCount
                            && sample.label == DisclosureKind.quote.showLabel
                            && sample.collapsed
                            && !sample.sentinelVisible
                    }
                )
                try await clickDisclosure(webView)
            },
            required: { sample in
                sample.label == DisclosureKind.quote.hideLabel
                    && sample.sentinelVisible
                    && sample.listItemCount == Issue21Geometry.stressListItemCount
                    && sample.focusedCardHeight > Issue21Geometry.deviceScaleExpandedHeight
            }
        )
        try insertion.requireMaterialDisclosure()
        try insertion.requireRowInsertionVisibilityStable()

        try await positionInteriorToggle(
            webView: webView,
            hierarchy: hierarchy,
            sentinelId: fixture.sentinelId
        )

        let collapse = try await captureTransition(
            name: "R2b-collapse",
            webView: webView,
            hierarchy: hierarchy,
            sentinelId: fixture.sentinelId,
            configuration: .stress,
            disclosure: .quote,
            action: { try await clickDisclosure(webView) },
            required: { sample in
                sample.label == DisclosureKind.quote.showLabel
                    && sample.collapsed
                    && !sample.sentinelVisible
                    && sample.focusedCardHeight < sample.listHeight - Issue21Geometry.interiorMargin
            }
        )
        try collapse.requireAnchorStable()
        try hierarchy.requireHostedCellAgreesWithLayout()

        let reopen = try await captureTransition(
            name: "R2b-reopen",
            webView: webView,
            hierarchy: hierarchy,
            sentinelId: fixture.sentinelId,
            configuration: .stress,
            disclosure: .quote,
            action: { try await clickDisclosure(webView) },
            required: { sample in
                sample.label == DisclosureKind.quote.hideLabel
                    && sample.sentinelVisible
                    && sample.focusedCardHeight > Issue21Geometry.deviceScaleExpandedHeight
            }
        )
        try reopen.requireAnchorStable()
        try hierarchy.requireHostedCellAgreesWithLayout()
    }

    @Test("One retained quote stays fixed above, then below, the midpoint")
    func productionDetailAboveMidpointReproduction() async throws {
        UserDisclosureViewportAnchorTestControl.reset()
        defer { UserDisclosureViewportAnchorTestControl.reset() }
        let cycle = try await measureMidpointPlacement(
            .above,
            includeCollapse: true,
            includeRetainedBelowExpansion: true
        )
        try cycle.expansion.requireMidpointDisclosureStable(placement: .above)
        let witness = cycle.expansionWitness
        print(
            "[DisclosureViewportCorrectionWitness] settled=\(witness.settledCount) "
                + "appliedCount=\(witness.appliedCorrectionCount) "
                + "applied=\(f(witness.lastAppliedCorrection ?? .nan)) "
                + "netFromBaseline=\(f(witness.lastCorrectedNetOffsetFromLeaseBaseline ?? .nan))"
        )
        try require(
            witness.settledCount == 1 && witness.appliedCorrectionCount == 1,
            "above-midpoint expansion did not apply exactly one viewport correction: "
                + "settled=\(witness.settledCount) applied=\(witness.appliedCorrectionCount)"
        )
        try require(
            (witness.lastAppliedCorrection ?? .infinity)
                <= -Issue21Geometry.knownBadReanchorMovement,
            "above-midpoint expansion correction was not materially negative: "
                + "\(f(witness.lastAppliedCorrection ?? .infinity))pt"
        )
        try require(
            abs(witness.lastCorrectedNetOffsetFromLeaseBaseline ?? .infinity)
                <= Issue21Geometry.settledTolerance,
            "above-midpoint corrected offset did not return to its lease baseline: "
                + "\(f(witness.lastCorrectedNetOffsetFromLeaseBaseline ?? .infinity))pt"
        )

        guard let collapse = cycle.collapse, let collapseWitness = cycle.collapseWitness else {
            throw MeasurementFailure("above-midpoint production cycle did not capture collapse")
        }
        try collapse.requireAboveMidpointCollapseStable()
        print(
            "[DisclosureViewportCollapseWitness] settled=\(collapseWitness.settledCount) "
                + "appliedCount=\(collapseWitness.appliedCorrectionCount) "
                + "applied=\(f(collapseWitness.lastAppliedCorrection ?? .nan)) "
                + "netFromBaseline=\(f(collapseWitness.lastCorrectedNetOffsetFromLeaseBaseline ?? .nan)) "
                + "attribution=above-midpoint-collapse-lease-exercised-no-op"
        )
        try require(
            collapseWitness.settledCount == 1
                && collapseWitness.appliedCorrectionCount == 0,
            "above-midpoint collapse did not exercise exactly one no-op viewport lease: "
                + "settled=\(collapseWitness.settledCount) "
                + "applied=\(collapseWitness.appliedCorrectionCount)"
        )
        try require(
            collapseWitness.lastAppliedCorrection == nil
                && collapseWitness.lastCorrectedNetOffsetFromLeaseBaseline == nil,
            "above-midpoint no-op collapse unexpectedly recorded realized correction values"
        )

        guard let retainedBelowExpansion = cycle.retainedBelowExpansion,
              let retainedBelowWitness = cycle.retainedBelowWitness else {
            throw MeasurementFailure("production cycle did not capture retained below-midpoint expansion")
        }
        try retainedBelowExpansion.requireMidpointDisclosureStable(placement: .below)
        try require(
            retainedBelowWitness.settledCount == 1,
            "retained below-midpoint disclosure did not use the position-symmetric viewport anchor: "
                + "settled=\(retainedBelowWitness.settledCount) "
                + "applied=\(retainedBelowWitness.appliedCorrectionCount)"
        )
        print(
            "[DisclosureViewportRetainedBelowWitness] settled=\(retainedBelowWitness.settledCount) "
                + "appliedCount=\(retainedBelowWitness.appliedCorrectionCount) "
                + "applied=\(f(retainedBelowWitness.lastAppliedCorrection ?? .nan)) "
                + "netFromBaseline=\(f(retainedBelowWitness.lastCorrectedNetOffsetFromLeaseBaseline ?? .nan))"
        )
    }

    @Test("Above-midpoint viewport-correction sensitivity exposes the full outer row-bottom re-anchor")
    func productionDetailAboveMidpointViewportCorrectionSensitivityControl() async throws {
        UserDisclosureViewportAnchorTestControl.reset(bypass: true)
        defer { UserDisclosureViewportAnchorTestControl.reset() }
        let cycle = try await measureMidpointPlacement(.above)
        try cycle.expansion.requireKnownBadAboveMidpointOuterReanchor()
        let witness = UserDisclosureViewportAnchorTestControl.witness
        try require(
            witness.settledCount == 0 && witness.appliedCorrectionCount == 0,
            "bypassed viewport correction unexpectedly settled a lease"
        )
    }

    @Test("Below-midpoint collapsed quote remains the matched stable control")
    func productionDetailBelowMidpointControl() async throws {
        UserDisclosureViewportAnchorTestControl.reset()
        defer { UserDisclosureViewportAnchorTestControl.reset() }
        let cycle = try await measureMidpointPlacement(.below)
        try cycle.expansion.requireMidpointDisclosureStable(placement: .below)
        let witness = cycle.expansionWitness
        try require(
            witness.settledCount == 1 && witness.appliedCorrectionCount == 0,
            "below-midpoint control did not use the position-symmetric viewport anchor: "
                + "settled=\(witness.settledCount) applied=\(witness.appliedCorrectionCount)"
        )
    }

    private func measureMidpointPlacement(
        _ placement: MidpointPlacement,
        includeCollapse: Bool = false,
        includeRetainedBelowExpansion: Bool = false
    ) async throws -> (
        expansion: CapturedTransition,
        expansionWitness: UserDisclosureViewportAnchorTestControl.Witness,
        collapse: CapturedTransition?,
        collapseWitness: UserDisclosureViewportAnchorTestControl.Witness?,
        retainedBelowExpansion: CapturedTransition?,
        retainedBelowWitness: UserDisclosureViewportAnchorTestControl.Witness?
    ) {
        ScrollFreezeGate.shared.end()
        let fixture = try DetailDatabaseFixture(configuration: .midpoint, disclosure: .quote)
        defer {
            fixture.tearDown()
            ScrollFreezeGate.shared.end()
        }
        let host = try await ProductionDetailHost(messageId: fixture.focusedHeaderId)
        defer { host.tearDown() }

        let webView = try await host.webView(containing: fixture.sentinelId)
        let hierarchy = try ProductionHierarchy(webView: webView, window: host.window)
        try await waitForListItems(hierarchy.list, exactly: Issue21Geometry.midpointListItemCount)
        let ready = try await waitForDOM(webView, sentinelId: fixture.sentinelId)
        try require(ready.label == DisclosureKind.quote.showLabel, "midpoint quote was not collapsed")
        try require(ready.collapsed, "midpoint quote did not begin collapsed")
        try require(!ready.sentinelVisible, "midpoint sentinel was visible before disclosure")
        let retainedWebView = ObjectIdentifier(webView)
        let retainedList = ObjectIdentifier(hierarchy.list)
        let retainedCell = try hierarchy.targetCell()
        let retainedDocumentEpoch = UUID().uuidString
        let stampedEpoch = await CanaryKit.eval(
            webView,
            "window.__tmIssue21RetainedEpoch = '\(retainedDocumentEpoch)'; window.__tmIssue21RetainedEpoch",
            in: RenderContentWorld.isolated
        )
        try require(
            stampedEpoch == retainedDocumentEpoch,
            "could not stamp retained midpoint document epoch"
        )

        let positioned = try await positionCollapsedToggle(
            placement: placement,
            webView: webView,
            hierarchy: hierarchy,
            sentinelId: fixture.sentinelId
        )
        try requireMidpointPreconditions(
            positioned,
            placement: placement,
            hierarchy: hierarchy
        )
        try await waitForScrollFreezeToBecomeIdle()

        let expansion = try await captureTransition(
            name: "R3-\(placement.rawValue)-midpoint-expand",
            webView: webView,
            hierarchy: hierarchy,
            sentinelId: fixture.sentinelId,
            configuration: .midpoint,
            disclosure: .quote,
            action: { try await clickDisclosure(webView) },
            required: { sample in
                sample.label == DisclosureKind.quote.hideLabel
                    && sample.sentinelVisible
                    && sample.sentinelAfterToggle
                    && sample.focusedCardHeight > Issue21Geometry.deviceScaleExpandedHeight
            }
        )
        try hierarchy.requireHostedCellAgreesWithLayout()
        let expansionWitness = UserDisclosureViewportAnchorTestControl.witness
        guard includeCollapse else {
            return (expansion, expansionWitness, nil, nil, nil, nil)
        }
        try require(placement == .above, "only the above-midpoint fixture may request a collapse leg")
        try requireAboveMidpointCollapsePreconditions(expansion.after, hierarchy: hierarchy)

        UserDisclosureViewportAnchorTestControl.reset()
        let collapse = try await captureTransition(
            name: "R3-above-midpoint-collapse",
            webView: webView,
            hierarchy: hierarchy,
            sentinelId: fixture.sentinelId,
            configuration: .midpoint,
            disclosure: .quote,
            action: { try await clickDisclosure(webView) },
            required: { sample in
                sample.label == DisclosureKind.quote.showLabel
                    && sample.collapsed
                    && !sample.sentinelVisible
                    && Issue21Geometry.realisticCollapsedCardRange
                        .contains(sample.focusedCardHeight)
            }
        )
        try hierarchy.requireHostedCellAgreesWithLayout()
        try requireInteriorScrollBounds(
            collapse.after,
            hierarchy: hierarchy,
            phase: "above-midpoint collapse after"
        )
        let collapseWitness = UserDisclosureViewportAnchorTestControl.witness

        guard includeRetainedBelowExpansion else {
            return (
                expansion,
                expansionWitness,
                collapse,
                collapseWitness,
                nil,
                nil
            )
        }
        try require(placement == .above, "retained below leg requires the preceding above cycle")
        let retainedBelow = try await positionCollapsedToggle(
            placement: .below,
            webView: webView,
            hierarchy: hierarchy,
            sentinelId: fixture.sentinelId
        )
        try requireMidpointPreconditions(
            retainedBelow,
            placement: .below,
            hierarchy: hierarchy
        )
        try require(
            abs(retainedBelow.toggleWindowY - collapse.after.toggleWindowY)
                >= Issue21Geometry.midpointTargetDistance * 1.5,
            "retained host did not move the collapsed toggle across the midpoint"
        )
        try require(
            ObjectIdentifier(webView) == retainedWebView
                && ObjectIdentifier(hierarchy.list) == retainedList,
            "retained below leg replaced its WebView or production List"
        )
        let repositionedCell = try hierarchy.targetCell()
        try require(
            repositionedCell === retainedCell,
            "retained below leg recycled the target UICollectionViewCell"
        )
        let liveEpoch = await CanaryKit.eval(
            webView,
            "String(window.__tmIssue21RetainedEpoch || '')",
            in: RenderContentWorld.isolated
        )
        try require(
            liveEpoch == retainedDocumentEpoch,
            "retained below leg replaced its committed WebKit document"
        )
        try await waitForScrollFreezeToBecomeIdle()

        UserDisclosureViewportAnchorTestControl.reset()
        let retainedBelowExpansion = try await captureTransition(
            name: "R3-retained-below-midpoint-expand",
            webView: webView,
            hierarchy: hierarchy,
            sentinelId: fixture.sentinelId,
            configuration: .midpoint,
            disclosure: .quote,
            action: { try await clickDisclosure(webView) },
            required: { sample in
                sample.label == DisclosureKind.quote.hideLabel
                    && sample.sentinelVisible
                    && sample.sentinelAfterToggle
                    && sample.focusedCardHeight > Issue21Geometry.deviceScaleExpandedHeight
            }
        )
        try hierarchy.requireHostedCellAgreesWithLayout()
        try require(
            ObjectIdentifier(webView) == retainedWebView
                && ObjectIdentifier(hierarchy.list) == retainedList,
            "retained below expansion replaced its WebView or production List"
        )
        let finalCell = try hierarchy.targetCell()
        try require(
            finalCell === retainedCell,
            "retained below expansion recycled the target UICollectionViewCell"
        )
        let finalEpoch = await CanaryKit.eval(
            webView,
            "String(window.__tmIssue21RetainedEpoch || '')",
            in: RenderContentWorld.isolated
        )
        try require(
            finalEpoch == retainedDocumentEpoch,
            "retained below expansion replaced its committed WebKit document"
        )
        return (
            expansion,
            expansionWitness,
            collapse,
            collapseWitness,
            retainedBelowExpansion,
            UserDisclosureViewportAnchorTestControl.witness
        )
    }

    private func measure(
        configuration: MeasurementConfiguration,
        disclosure: DisclosureKind,
        testBypassesDisclosureOpenAnchorDisarm: Bool = false
    ) async throws -> MeasurementResult {
        ScrollFreezeGate.shared.end()
        let fixture = try DetailDatabaseFixture(configuration: configuration, disclosure: disclosure)
        defer {
            fixture.tearDown()
            ScrollFreezeGate.shared.end()
        }
        let host = try await ProductionDetailHost(
            messageId: fixture.focusedHeaderId,
            testBypassesDisclosureOpenAnchorDisarm: testBypassesDisclosureOpenAnchorDisarm
        )
        defer { host.tearDown() }

        let webView = try await host.webView(containing: fixture.sentinelId)
        let hierarchy = try ProductionHierarchy(webView: webView, window: host.window)

        // A production List contains the focused row plus its real bottom-spacer row.
        // Later-message configurations add one row per native-thread member.
        try await waitForListItems(
            hierarchy.list,
            atLeast: configuration.laterMessageCount + Issue21Geometry.singleMessageListItemCount
        )

        let ready = try await waitForDOM(webView, sentinelId: fixture.sentinelId)
        try require(
            ready.label == disclosure.showLabel,
            "fixture never reached the expected collapsed label: \(ready.label)"
        )
        try require(ready.collapsed, "fixture disclosure was not initially collapsed")
        try require(!ready.sentinelVisible, "final sentinel was visible before disclosure")

        if configuration.usesScrolledToggle {
            try await positionScrolledToggle(
                configuration: configuration,
                webView: webView,
                hierarchy: hierarchy,
                sentinelId: fixture.sentinelId
            )
        }

        try await waitForScrollFreezeToBecomeIdle()
        let beforeSeries = try await settle(
            phase: "before",
            configuration: configuration,
            disclosure: disclosure,
            webView: webView,
            hierarchy: hierarchy,
            sentinelId: fixture.sentinelId,
            required: nil
        )
        try hierarchy.requireHostedCellAgreesWithLayout()

        try require(!ScrollFreezeGate.shared.isFrozen, "ScrollFreezeGate was not idle before click")
        let click = await CanaryKit.eval(
            webView,
            "document.querySelector('.tm-quote-toggle').click(); 'clicked'",
            in: RenderContentWorld.isolated
        )
        try require(click == "clicked", "production isolated-world disclosure click failed: \(click)")

        let afterSeries = try await settle(
            phase: "after",
            configuration: configuration,
            disclosure: disclosure,
            webView: webView,
            hierarchy: hierarchy,
            sentinelId: fixture.sentinelId
        ) { sample in
            sample.label == disclosure.hideLabel
                && sample.sentinelVisible
        }
        try hierarchy.requireHostedCellAgreesWithLayout()

        return MeasurementResult(
            configuration: configuration,
            disclosure: disclosure,
            beforeSeries: beforeSeries,
            afterSeries: afterSeries
        )
    }
}

// MARK: - Configuration and fixture

private enum MeasurementConfiguration: String, Sendable {
    case c1 = "C1"
    case c2 = "C2"
    case c3 = "C3"
    case c4 = "C4"
    case stress = "R2"
    case midpoint = "R3"

    var laterMessageCount: Int {
        switch self {
        case .c1, .c2, .stress: 0
        case .c3, .c4: 4
        case .midpoint: Issue21Geometry.stressLaterMessageCount
        }
    }

    var earlierMessageCount: Int {
        self == .midpoint ? Issue21Geometry.midpointEarlierMessageCount : 0
    }

    var visibleParagraphCount: Int {
        switch self {
        case .c1, .c3, .stress: 1
        case .c2, .c4: 16
        case .midpoint: 8
        }
    }

    var usesScrolledToggle: Bool { self == .c2 || self == .c4 }

    var hiddenParagraphCount: Int {
        self == .stress || self == .midpoint ? 150 : 32
    }
}

private enum MidpointPlacement: String, Sendable {
    case above
    case below
}

private enum Issue21Geometry {
    static let rowVerticalInsets: CGFloat = 12
    static let interiorMargin: CGFloat = 100
    static let materialDynamicSpacer: CGFloat = 300
    static let materialCardGrowth: CGFloat = 80
    static let deviceScaleExpandedHeight: CGFloat = 10_000
    static let stressLaterMessageCount = 40
    static let midpointEarlierMessageCount = 16
    static let singleMessageListItemCount = 2
    static let threadedMatrixListItemCount = 6
    static let stressListItemCount = stressLaterMessageCount + 2
    static let midpointListItemCount = stressLaterMessageCount + midpointEarlierMessageCount + 2
    static let knownBadReanchorMovement: CGFloat = 500
    static let settledTolerance: CGFloat = 2
    static let transientTolerance: CGFloat = 4
    static let hostedGeometryTolerance: CGFloat = 1
    static let minimumFrameCount = 10
    static let maximumWebToNativePairingGap: TimeInterval = 0.12
    static let visibleTopClearance: CGFloat = 60
    static let midpointSeparation: CGFloat = 100
    static let midpointTargetDistance: CGFloat = 160
    static let midpointTargetTolerance: CGFloat = 3
    static let midpointCardBottomAllowance: CGFloat = 50
    static let realisticCollapsedCardRange: ClosedRange<CGFloat> = 600...900
}

private enum DisclosureKind: String, Sendable {
    case quote
    case invite

    var showLabel: String {
        switch self {
        case .quote: "Show quoted text"
        case .invite: "Show invite details"
        }
    }

    var hideLabel: String {
        switch self {
        case .quote: "Hide quoted text"
        case .invite: "Hide invite details"
        }
    }
}

private final class DetailDatabaseFixture {
    let directory: URL
    let pool: DatabasePool
    let previousDatabase: AppDatabase?
    let focusedHeaderId: String
    let sentinelId: String
    private let nonce: String
    private let accountId: String
    private let threadId: String
    private let archive: Folder
    private let focusedDate: Date

    init(configuration: MeasurementConfiguration, disclosure: DisclosureKind) throws {
        let fixtureNonce = UUID().uuidString.lowercased()
        let fixtureSentinelId = "tm-issue21-final-\(fixtureNonce)"
        let fixtureDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("tabmail-issue21-\(fixtureNonce)", isDirectory: true)
        let fixtureAccountId = "issue21-account-\(fixtureNonce)"
        let fixtureThreadId = "issue21-native-thread-\(fixtureNonce)"
        let fixtureArchive = Folder(
            name: "Archive",
            path: "Archive",
            role: .archive,
            accountId: fixtureAccountId
        )
        let fixtureDate = Self.makeFocusedDate()
        var focused = MessageHeader(
            messageId: "focused-\(fixtureNonce)",
            subject: "Issue 21 disclosure fixture",
            from: "Anonymous Fixture",
            fromAddress: "anonymous@example.com",
            to: "reader@example.com",
            date: fixtureDate,
            snippet: "Short visible body",
            folderId: fixtureArchive.id,
            accountId: fixtureAccountId,
            folderPath: fixtureArchive.path,
            isInInbox: false
        )
        focused.rfc822MessageId = "<focused-\(fixtureNonce)@example.com>"
        focused.threadId = fixtureThreadId
        focused.computedThreadId = fixtureThreadId
        focused.isRead = true
        focused.hasAttachments = false
        focused.headerComplete = true

        let bodyHTML = Self.bodyHTML(
            visibleParagraphs: configuration.visibleParagraphCount,
            hiddenParagraphs: configuration.hiddenParagraphCount,
            disclosure: disclosure,
            sentinelId: fixtureSentinelId,
            nonce: fixtureNonce,
            focusedDate: fixtureDate
        )
        var openedPool: DatabasePool?
        let fixturePool: DatabasePool
        let appDatabase: AppDatabase
        do {
            try FileManager.default.createDirectory(
                at: fixtureDirectory,
                withIntermediateDirectories: true
            )
            var databaseConfiguration = Configuration()
            databaseConfiguration.foreignKeysEnabled = true
            fixturePool = try DatabasePool(
                path: fixtureDirectory.appendingPathComponent("fixture.sqlite").path,
                configuration: databaseConfiguration
            )
            openedPool = fixturePool
            appDatabase = try AppDatabase(dbPool: fixturePool)
            try fixturePool.writeWithoutTransaction { db in
                var account = Account(
                    emailAddress: "reader@example.com",
                    displayName: "Issue 21 Fixture",
                    provider: .gmail
                )
                account.id = fixtureAccountId
                try account.insert(db)
                try fixtureArchive.insert(db)
                try focused.insert(db)
                let body = MessageBody(
                    contentKey: ContentKey(rawValue: focused.id),
                    htmlContent: bodyHTML
                )
                try body.insert(db)

                for index in 0..<configuration.laterMessageCount {
                    var later = MessageHeader(
                        messageId: "later-\(index)-\(fixtureNonce)",
                        subject: "Issue 21 later message \(index)",
                        from: "Anonymous Fixture",
                        fromAddress: "anonymous@example.com",
                        to: "reader@example.com",
                        date: focused.date.addingTimeInterval(TimeInterval((index + 1) * 60)),
                        snippet: "Later native-thread fixture \(index)",
                        folderId: fixtureArchive.id,
                        accountId: fixtureAccountId,
                        folderPath: fixtureArchive.path,
                        isInInbox: false
                    )
                    later.rfc822MessageId = "<later-\(index)-\(fixtureNonce)@example.com>"
                    later.threadId = fixtureThreadId
                    later.computedThreadId = fixtureThreadId
                    later.isRead = true
                    later.hasAttachments = false
                    later.headerComplete = true
                    try later.insert(db)
                }
                for index in 0..<configuration.earlierMessageCount {
                    var earlier = MessageHeader(
                        messageId: "earlier-\(index)-\(fixtureNonce)",
                        subject: "Issue 21 earlier message \(index)",
                        from: "Anonymous Fixture",
                        fromAddress: "anonymous@example.com",
                        to: "reader@example.com",
                        date: focused.date.addingTimeInterval(TimeInterval(-((index + 1) * 60))),
                        snippet: "Earlier native-thread fixture \(index)",
                        folderId: fixtureArchive.id,
                        accountId: fixtureAccountId,
                        folderPath: fixtureArchive.path,
                        isInInbox: false
                    )
                    earlier.rfc822MessageId = "<earlier-\(index)-\(fixtureNonce)@example.com>"
                    earlier.threadId = fixtureThreadId
                    earlier.computedThreadId = fixtureThreadId
                    earlier.isRead = true
                    earlier.hasAttachments = false
                    earlier.headerComplete = true
                    try earlier.insert(db)
                }
            }
        } catch {
            if let openedPool {
                TestDatabaseTeardown.retire(pool: openedPool, directory: fixtureDirectory)
            } else if FileManager.default.fileExists(atPath: fixtureDirectory.path) {
                try? FileManager.default.removeItem(at: fixtureDirectory)
            }
            throw error
        }

        nonce = fixtureNonce
        sentinelId = fixtureSentinelId
        directory = fixtureDirectory
        pool = fixturePool
        accountId = fixtureAccountId
        threadId = fixtureThreadId
        archive = fixtureArchive
        focusedDate = fixtureDate
        focusedHeaderId = focused.id
        previousDatabase = AppDatabase.shared.withLock { current -> AppDatabase? in
            let previous = current
            current = appDatabase
            return previous
        }
    }

    func tearDown() {
        AppDatabase.shared.withLock { $0 = previousDatabase }
        TestDatabaseTeardown.retire(pool: pool, directory: directory)
    }

    func insertLaterMessages(count: Int) throws {
        try require(count > 0, "stress fixture needs at least one later message")
        try pool.writeWithoutTransaction { db in
            for offset in 1...count {
                var related = MessageHeader(
                    messageId: "later-\(offset)-\(nonce)",
                    subject: "Issue 21 stress later \(offset)",
                    from: "Anonymous Fixture",
                    fromAddress: "anonymous@example.com",
                    to: "reader@example.com",
                    date: focusedDate.addingTimeInterval(TimeInterval(offset * 60)),
                    snippet: "Stress native-thread fixture later \(offset)",
                    folderId: archive.id,
                    accountId: accountId,
                    folderPath: archive.path,
                    isInInbox: false
                )
                related.rfc822MessageId = "<later-\(offset)-\(nonce)@example.com>"
                related.threadId = threadId
                related.computedThreadId = threadId
                related.isRead = true
                related.hasAttachments = false
                related.headerComplete = true
                try related.insert(db)
            }
        }
    }

    private static func bodyHTML(
        visibleParagraphs: Int,
        hiddenParagraphs: Int,
        disclosure: DisclosureKind,
        sentinelId: String,
        nonce: String,
        focusedDate: Date
    ) -> String {
        let visible = (0..<visibleParagraphs)
            .map { "<p>Visible fixture paragraph \($0 + 1), nonce \(nonce).</p>" }
            .joined()
        let hidden = (0..<hiddenParagraphs)
            .map { "<p>Hidden fixture paragraph \($0 + 1) is long enough to force a material height change.</p>" }
            .joined()
            + "<p id=\"\(sentinelId)\">Unique final sentinel \(nonce)</p>"

        switch disclosure {
        case .quote:
            let formatter = DateFormatter()
            formatter.locale = Locale(identifier: "en_US_POSIX")
            formatter.timeZone = TimeZone(secondsFromGMT: 0)
            formatter.dateFormat = "EEEE, MMMM d, yyyy 'at' h:mm a"
            let attributionDate = formatter.string(from: focusedDate)
            return """
            \(visible)
            <p>On \(attributionDate), Anonymous Fixture &lt;anonymous@example.com&gt; wrote:</p>
            <blockquote>\(hidden)</blockquote>
            """
        case .invite:
            // This literal marker deliberately bypasses BodyRenderer's marker
            // emission. The production collapseICSJS transform, ownership list,
            // disclosure bridge, List, card, and sizing pipeline remain real.
            return """
            \(visible)
            <div class="tm-ics-collapsible">\(hidden)</div>
            """
        }
    }

    private static func makeFocusedDate() -> Date {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        return calendar.date(from: DateComponents(
            year: 2026,
            month: 8,
            day: 14,
            hour: 9
        ))!
    }
}

// MARK: - Production host and hierarchy gates

@MainActor
private final class ProductionDetailHost {
    let window: UIWindow
    let controller: UIViewController
    let previousKeyWindow: UIWindow?

    init(
        messageId: String,
        testBypassesDisclosureOpenAnchorDisarm: Bool = false
    ) async throws {
        guard let scene = UIApplication.shared.connectedScenes
            .compactMap({ $0 as? UIWindowScene })
            .first else {
            throw MeasurementFailure("no UIWindowScene is available to host MessageDetailView")
        }
        let previousKeyWindow = scene.windows.first(where: \.isKeyWindow)
        let root = NavigationStack {
            MessageDetailView(
                messageId: messageId,
                testBypassesDisclosureOpenAnchorDisarm: testBypassesDisclosureOpenAnchorDisarm
            )
        }
        let controller = UIHostingController(rootView: root)
        let window = UIWindow(windowScene: scene)
        window.frame = CGRect(x: 0, y: 0, width: 390, height: 844)
        window.rootViewController = controller
        window.isHidden = false
        window.makeKeyAndVisible()
        window.layoutIfNeeded()
        self.window = window
        self.controller = controller
        self.previousKeyWindow = previousKeyWindow
    }

    func webView(containing sentinelId: String) async throws -> WKWebView {
        let deadline = Date().addingTimeInterval(12)
        while Date() < deadline {
            window.layoutIfNeeded()
            for candidate in Self.allWebViews(in: window) {
                let result = await CanaryKit.eval(
                    candidate,
                    "String(document.getElementById('\(sentinelId)') !== null)",
                    in: RenderContentWorld.isolated
                )
                if result == "true" {
                    return candidate
                }
            }
            try? await Task.sleep(for: .milliseconds(50))
        }
        throw MeasurementFailure("no hosted WKWebView contained fixture sentinel \(sentinelId)")
    }

    func tearDown() {
        window.isHidden = true
        window.rootViewController = nil
        previousKeyWindow?.makeKeyAndVisible()
    }

    private static func allWebViews(in view: UIView) -> [WKWebView] {
        var result = view as? WKWebView == nil ? [] : [view as! WKWebView]
        for child in view.subviews {
            result.append(contentsOf: allWebViews(in: child))
        }
        return result
    }

}

@MainActor
private struct ProductionHierarchy {
    let window: UIWindow
    let list: UICollectionView
    let webView: WKWebView
    let webViewTopWithinTargetCard: CGFloat

    init(webView: WKWebView, window: UIWindow) throws {
        var ancestor = webView.superview
        var list: UICollectionView?
        while let view = ancestor {
            if let collection = view as? UICollectionView {
                list = collection
                break
            }
            ancestor = view.superview
        }
        guard let list else {
            throw MeasurementFailure("sentinel WKWebView is not inside the production List UICollectionView")
        }
        var cellAncestor = webView.superview
        var focusedCell: UICollectionViewCell?
        while let view = cellAncestor {
            if let cell = view as? UICollectionViewCell {
                focusedCell = cell
                break
            }
            cellAncestor = view.superview
        }
        guard let focusedCell else {
            throw MeasurementFailure("sentinel WKWebView has no initial focused UICollectionViewCell ancestor")
        }
        let initialCardTop = focusedCell.convert(focusedCell.bounds, to: window).minY
            + Issue21Geometry.rowVerticalInsets / 2
        self.window = window
        self.list = list
        self.webView = webView
        webViewTopWithinTargetCard = webView.convert(webView.bounds.origin, to: window).y - initialCardTop
    }

    func targetCell() throws -> UICollectionViewCell {
        var ancestor = webView.superview
        while let view = ancestor {
            if let cell = view as? UICollectionViewCell { return cell }
            ancestor = view.superview
        }
        throw MeasurementFailure("sentinel WKWebView has no target UICollectionViewCell ancestor")
    }

    func targetLayoutGeometry() throws -> TargetLayoutGeometry {
        list.layoutIfNeeded()
        guard list.numberOfSections == 1 else {
            throw MeasurementFailure("production List unexpectedly has \(list.numberOfSections) sections")
        }
        let itemCount = list.numberOfItems(inSection: 0)
        guard itemCount == Issue21Geometry.singleMessageListItemCount
            || itemCount == Issue21Geometry.threadedMatrixListItemCount
            || itemCount == Issue21Geometry.stressListItemCount
            || itemCount == Issue21Geometry.midpointListItemCount else {
            throw MeasurementFailure("production List item count \(itemCount) was not a supported fixture shape")
        }
        let indexPath: IndexPath
        if itemCount == Issue21Geometry.midpointListItemCount {
            let cell = try targetCell()
            guard let hostedIndexPath = list.indexPath(for: cell) else {
                throw MeasurementFailure("midpoint sentinel target has no production List index path")
            }
            indexPath = hostedIndexPath
        } else {
            // All legacy fixtures have no earlier rows, so the focused row is
            // penultimate even when its hosted cell is temporarily stale.
            indexPath = IndexPath(item: itemCount - 2, section: 0)
        }
        let spacerIndexPath = IndexPath(item: itemCount - 1, section: 0)
        guard let attributes = list.layoutAttributesForItem(at: indexPath),
              let spacerAttributes = list.layoutAttributesForItem(at: spacerIndexPath) else {
            throw MeasurementFailure("sentinel target row has no layout attributes at \(indexPath)")
        }
        let targetFrame = list.convert(attributes.frame, to: window)
        let spacerFrame = list.convert(spacerAttributes.frame, to: window)
        return TargetLayoutGeometry(
            targetFrame: targetFrame,
            spacerFrame: spacerFrame,
            targetIndexPath: indexPath,
            itemCount: itemCount
        )
    }

    func requireHostedCellAgreesWithLayout() throws {
        try requireWebViewIsLive()
        let geometry = try targetLayoutGeometry()
        let listFrame = list.convert(list.bounds, to: window)
        guard geometry.targetFrame.intersects(listFrame) else { return }
        let cell = try targetCell()
        let targetIndexPath = geometry.targetIndexPath
        guard list.indexPath(for: cell) == targetIndexPath else {
            throw MeasurementFailure("visible hosted sentinel is not the production target item")
        }
        let cellFrame = cell.convert(cell.bounds, to: window)
        try require(
            abs(cellFrame.minY - geometry.targetFrame.minY) <= Issue21Geometry.hostedGeometryTolerance
                && abs(cellFrame.height - geometry.targetFrame.height) <= Issue21Geometry.hostedGeometryTolerance,
            "settled visible target cell disagrees with layout attributes: cell=\(cellFrame) attributes=\(geometry.targetFrame)"
        )
        try requireFrozenWebViewOriginIfHosted()
    }

    func requireFrozenWebViewOriginIfHosted() throws {
        try requireWebViewIsLive()
        let geometry = try targetLayoutGeometry()
        let listFrame = list.convert(list.bounds, to: window)
        guard geometry.targetFrame.intersects(listFrame) else { return }
        let cell = try targetCell()
        let targetIndexPath = geometry.targetIndexPath
        try require(
            list.indexPath(for: cell) == targetIndexPath,
            "hosted WKWebView belongs to a cell other than the sentinel target item"
        )
        let cellFrame = cell.convert(cell.bounds, to: window)
        let liveCardTop = cellFrame.minY + Issue21Geometry.rowVerticalInsets / 2
        let liveWebViewTopWithinCard = webView.convert(webView.bounds.origin, to: window).y - liveCardTop
        try require(
            abs(liveWebViewTopWithinCard - webViewTopWithinTargetCard)
                <= Issue21Geometry.hostedGeometryTolerance,
            "hosted WKWebView origin drifted within target card: initial=\(webViewTopWithinTargetCard) "
                + "live=\(liveWebViewTopWithinCard) cell=\(cellFrame) layout=\(geometry.targetFrame) "
                + "webFrame=\(webView.frame) webBounds=\(webView.bounds)"
        )
    }

    func requireWebViewIsLive() throws {
        try require(
            webView.window === window,
            "captured WKWebView is no longer hosted in the measured production window"
        )
    }
}

private struct TargetLayoutGeometry {
    let targetFrame: CGRect
    let spacerFrame: CGRect
    let targetIndexPath: IndexPath
    let itemCount: Int
}

// MARK: - Sampling

private struct DOMState: Decodable {
    let label: String
    let toggleTop: Double
    let sentinelTop: Double?
    let effectiveViewportWidth: Double
    let collapsed: Bool
    let sentinelVisible: Bool
    let sentinelAfterToggle: Bool
}

private struct ViewportSample {
    let elapsed: TimeInterval
    let outerOffsetY: CGFloat
    let outerContentHeight: CGFloat
    let toggleWindowY: CGFloat
    let layoutDerivedToggleWindowY: CGFloat
    let sentinelWindowY: CGFloat?
    let webViewWindowOriginY: CGFloat
    let webViewBoundsOriginY: CGFloat
    let webViewWindowFrame: CGRect
    let hostedCellWindowFrame: CGRect?
    let cardTopWindowY: CGFloat
    let focusedCardHeight: CGFloat
    let listHeight: CGFloat
    let listMidWindowY: CGFloat
    let bottomSpacer: CGFloat
    let listItemCount: Int
    let label: String
    let collapsed: Bool
    let sentinelVisible: Bool
    let sentinelAfterToggle: Bool

    var focusedCardBottomWindowY: CGFloat {
        cardTopWindowY + focusedCardHeight
    }

    func isStable(comparedWith other: Self) -> Bool {
        abs(outerOffsetY - other.outerOffsetY) < 0.5
            && abs(outerContentHeight - other.outerContentHeight) < 1
            && abs(toggleWindowY - other.toggleWindowY) < 1
            && abs(layoutDerivedToggleWindowY - other.layoutDerivedToggleWindowY) < 1
            && abs(cardTopWindowY - other.cardTopWindowY) < 1
            && abs(focusedCardHeight - other.focusedCardHeight) < 1
    }
}

private struct MeasurementResult {
    let configuration: MeasurementConfiguration
    let disclosure: DisclosureKind
    let beforeSeries: [ViewportSample]
    let afterSeries: [ViewportSample]

    func printSummary() {
        guard let before = beforeSeries.last, let after = afterSeries.last else { return }
        let offsetDelta = after.outerOffsetY - before.outerOffsetY
        let toggleDelta = after.toggleWindowY - before.toggleWindowY
        let cardDelta = after.cardTopWindowY - before.cardTopWindowY
        let webViewOriginDelta = after.webViewWindowOriginY - before.webViewWindowOriginY
        let hostedCellOriginDelta: CGFloat? = if let beforeCell = before.hostedCellWindowFrame,
                                                 let afterCell = after.hostedCellWindowFrame {
            afterCell.minY - beforeCell.minY
        } else {
            nil
        }
        let attribution: String
        if abs(toggleDelta - cardDelta) < 2, abs(cardDelta) >= 1 {
            attribution = "outer-container"
        } else if abs(toggleDelta) >= 1, abs(cardDelta) < 1 {
            attribution = "intra-card-or-WebKit"
        } else if abs(offsetDelta) >= 1,
                  abs(toggleDelta) < 1,
                  abs(cardDelta) < 1,
                  abs(webViewOriginDelta) < 1,
                  abs(hostedCellOriginDelta ?? .infinity) < 1 {
            attribution = "outer-offset-compensation-anchor-stable"
        } else if abs(offsetDelta) < 1, abs(toggleDelta) < 1, abs(cardDelta) < 1 {
            attribution = "no-drift"
        } else {
            attribution = "mixed"
        }
        print(
            "[DisclosureViewportResult] \(configuration.rawValue) \(disclosure.rawValue) "
                + "offsetBefore=\(f(before.outerOffsetY)) offsetAfter=\(f(after.outerOffsetY)) delta=\(f(offsetDelta)) "
                + "toggleDelta=\(f(toggleDelta)) cardDelta=\(f(cardDelta)) attribution=\(attribution)"
        )
    }

    func requireUserVisibleAnchorStable() throws {
        let before = try requireLast(beforeSeries, phase: "before")
        let after = try requireLast(afterSeries, phase: "after")
        try requireDirectToggleCrosscheck(before, phase: "before")
        try requireDirectToggleCrosscheck(after, phase: "after")
        let toggleDelta = after.toggleWindowY - before.toggleWindowY
        let cardDelta = after.cardTopWindowY - before.cardTopWindowY
        let offsetDelta = after.outerOffsetY - before.outerOffsetY
        let tolerance = Issue21Geometry.settledTolerance
        guard let beforeHostedCell = before.hostedCellWindowFrame,
              let afterHostedCell = after.hostedCellWindowFrame else {
            throw MeasurementFailure("settled disclosure did not retain a live hosted cell")
        }
        let hostedCellOriginDelta = afterHostedCell.minY - beforeHostedCell.minY
        let webViewOriginDelta = after.webViewWindowOriginY - before.webViewWindowOriginY
        try require(
            abs(toggleDelta) <= tolerance,
            "user-visible disclosure toggle moved by \(f(toggleDelta))pt (allowed \(f(tolerance))pt)"
        )
        try require(
            abs(cardDelta) <= tolerance,
            "focused card moved by \(f(cardDelta))pt while revealing below the toggle"
        )
        try require(
            abs(hostedCellOriginDelta) <= Issue21Geometry.hostedGeometryTolerance,
            "hosted cell origin moved by \(f(hostedCellOriginDelta))pt while revealing below the toggle"
        )
        try require(
            abs(webViewOriginDelta) <= Issue21Geometry.hostedGeometryTolerance,
            "hosted WebView origin moved by \(f(webViewOriginDelta))pt while revealing below the toggle"
        )
        if abs(offsetDelta) > tolerance {
            print(
                "[DisclosureViewportOracle] \(configuration.rawValue) \(disclosure.rawValue) "
                    + "rawOffsetDelta=\(f(offsetDelta)) "
                    + "attribution=outer-offset-compensation-anchor-stable "
                    + "toggleDelta=\(f(toggleDelta)) cardDelta=\(f(cardDelta)) "
                    + "hostedCellOriginDelta=\(f(hostedCellOriginDelta)) "
                    + "webViewOriginDelta=\(f(webViewOriginDelta))"
            )
        }
    }

    func requireMaterialDisclosure() throws {
        let before = try requireLast(beforeSeries, phase: "before")
        let after = try requireLast(afterSeries, phase: "after")
        try require(before.collapsed, "disclosure baseline was not collapsed")
        try require(!before.sentinelVisible, "disclosure sentinel started visible")
        try require(
            after.focusedCardHeight > before.focusedCardHeight + Issue21Geometry.materialCardGrowth,
            "focused row did not materially grow after disclosure"
        )
    }

    func requireKnownBadOuterReanchorMovement() throws {
        let before = try requireLast(beforeSeries, phase: "before")
        let after = try requireLast(afterSeries, phase: "after")
        try requireDirectToggleCrosscheck(before, phase: "before")
        try requireDirectToggleCrosscheck(after, phase: "after")
        let toggleDelta = after.toggleWindowY - before.toggleWindowY
        let cardDelta = after.cardTopWindowY - before.cardTopWindowY
        let offsetDelta = after.outerOffsetY - before.outerOffsetY
        let requiredMovement = Issue21Geometry.knownBadReanchorMovement
        try require(
            abs(toggleDelta) >= requiredMovement && abs(cardDelta) >= requiredMovement,
            "bypassed C4 did not expose the known outer movement: toggle=\(f(toggleDelta)) card=\(f(cardDelta))"
        )
        try require(
            abs(toggleDelta - cardDelta) <= Issue21Geometry.settledTolerance,
            "bypassed C4 movement was not attributable to the outer card: toggle=\(f(toggleDelta)) card=\(f(cardDelta))"
        )
        try require(
            abs(offsetDelta) >= requiredMovement,
            "bypassed C4 did not execute the opening re-anchor scroll: offset=\(f(offsetDelta))"
        )
    }

    private func requireDirectToggleCrosscheck(
        _ sample: ViewportSample,
        phase: String
    ) throws {
        let delta = sample.toggleWindowY - sample.layoutDerivedToggleWindowY
        try require(
            abs(delta) <= Issue21Geometry.hostedGeometryTolerance,
            "\(configuration.rawValue) \(disclosure.rawValue) \(phase) direct/layout toggle cross-check differed by \(f(delta))pt; "
                + "webFrame=\(sample.webViewWindowFrame) webBoundsOrigin=\(sample.webViewBoundsOriginY) "
                + "hostedCell=\(String(describing: sample.hostedCellWindowFrame))"
        )
    }
}

private struct NativeFrameSample {
    let epoch: TimeInterval
    let outerOffsetY: CGFloat
    let outerContentHeight: CGFloat
    let toggleWindowY: CGFloat
    let cardTopWindowY: CGFloat
    let focusedCardHeight: CGFloat
    let bottomSpacerHeight: CGFloat
    let listItemCount: Int
    let hostedCardTopWindowY: CGFloat?
    let hostedCardHeight: CGFloat?
}

private struct WebFrameSample {
    let epoch: TimeInterval
    let toggleOffsetY: CGFloat
    let label: String
    let collapsed: Bool
}

private struct WebFramePayload: Decodable {
    let epochMilliseconds: Double
    let toggleTop: Double
    let label: String
    let collapsed: Bool
}

private struct CapturedTransition {
    let name: String
    let before: ViewportSample
    let after: ViewportSample
    let frames: [NativeFrameSample]
    let webFrames: [WebFrameSample]
    let droppedNativeFrameCount: Int
    let nativeFrameViolation: String?

    private var maximumNativeFrameGap: TimeInterval {
        maximumGap(in: frames.map(\.epoch))
    }

    private var maximumWebFrameGap: TimeInterval {
        maximumGap(in: webFrames.map(\.epoch))
    }

    private var maximumPairingGap: TimeInterval {
        webFrames.compactMap { web in
            frames.map { abs($0.epoch - web.epoch) }.min()
        }.max() ?? .infinity
    }

    private var composedToggleWindowYs: [CGFloat] {
        guard let firstWeb = webFrames.first else { return frames.map(\.toggleWindowY) }
        return webFrames.compactMap { web in
            guard let native = frames.min(by: {
                abs($0.epoch - web.epoch) < abs($1.epoch - web.epoch)
            }) else { return nil }
            return native.toggleWindowY + web.toggleOffsetY - firstWeb.toggleOffsetY
        }
    }

    func printSummary() {
        let offsetDelta = after.outerOffsetY - before.outerOffsetY
        let toggleDelta = after.toggleWindowY - before.toggleWindowY
        let cardDelta = after.cardTopWindowY - before.cardTopWindowY
        let itemDelta = after.listItemCount - before.listItemCount
        let maxToggleExcursion = composedToggleWindowYs.map { abs($0 - before.toggleWindowY) }.max() ?? 0
        let maxCardExcursion = frames.map { abs($0.cardTopWindowY - before.cardTopWindowY) }.max() ?? 0
        let maxWebKitExcursion: CGFloat
        if let firstWeb = webFrames.first {
            maxWebKitExcursion = webFrames.map { abs($0.toggleOffsetY - firstWeb.toggleOffsetY) }.max() ?? 0
        } else {
            maxWebKitExcursion = 0
        }
        let attribution: String
        if itemDelta != 0 {
            attribution = "related-row-insertion-or-reanchor-see-DetailAnchor"
        } else if abs(cardDelta) >= 1, abs(toggleDelta - cardDelta) < 2 {
            attribution = "outer-list-clamp-or-scroll"
        } else if maxWebKitExcursion >= 1, maxCardExcursion < 1 {
            attribution = "webkit-internal"
        } else if abs(offsetDelta) >= 1, abs(toggleDelta) < 1, abs(cardDelta) < 1,
                  maxToggleExcursion < 1, maxCardExcursion < 1 {
            attribution = "outer-offset-compensation-anchor-stable"
        } else if abs(offsetDelta) < 1, abs(toggleDelta) < 1, abs(cardDelta) < 1,
                  maxToggleExcursion < 1, maxCardExcursion < 1 {
            attribution = "no-drift"
        } else {
            attribution = "mixed"
        }
        print(
            "[DisclosureViewportTransition] \(name) frames=\(frames.count) dropped=\(droppedNativeFrameCount) "
                + "nativeMaxGap=\(f(maximumNativeFrameGap)) webMaxGap=\(f(maximumWebFrameGap)) "
                + "pairMaxGap=\(f(maximumPairingGap)) "
                + "items=\(before.listItemCount)->\(after.listItemCount) "
                + "offsetDelta=\(f(offsetDelta)) toggleDelta=\(f(toggleDelta)) cardDelta=\(f(cardDelta)) "
                + "maxToggleExcursion=\(f(maxToggleExcursion)) maxCardExcursion=\(f(maxCardExcursion)) "
                + "maxWebKitExcursion=\(f(maxWebKitExcursion)) "
                + "attribution=\(attribution)"
        )
    }

    func requireMaterialDisclosure() throws {
        try require(before.collapsed, "row-insertion baseline was not collapsed")
        try require(
            after.bottomSpacer <= Issue21Geometry.interiorMargin
                && before.bottomSpacer - after.bottomSpacer >= Issue21Geometry.materialDynamicSpacer - Issue21Geometry.interiorMargin,
            "expanded stress card did not materially enter the small bottom-spacer branch"
        )
    }

    func requireRowInsertionVisibilityStable() throws {
        let toggleDelta = after.toggleWindowY - before.toggleWindowY
        let maxToggleExcursion = composedToggleWindowYs
            .map { abs($0 - before.toggleWindowY) }
            .max() ?? 0
        try require(
            abs(toggleDelta) <= Issue21Geometry.settledTolerance,
            "\(name) moved the directly hosted disclosure toggle by \(f(toggleDelta))pt"
        )
        try require(
            maxToggleExcursion <= Issue21Geometry.transientTolerance,
            "\(name) directly hosted toggle excursion was \(f(maxToggleExcursion))pt"
        )
    }

    func requireAnchorStable() throws {
        let tolerance = Issue21Geometry.settledTolerance
        let transientTolerance = Issue21Geometry.transientTolerance
        let toggleDelta = after.toggleWindowY - before.toggleWindowY
        let cardDelta = after.cardTopWindowY - before.cardTopWindowY
        let maxToggleExcursion = composedToggleWindowYs.map { abs($0 - before.toggleWindowY) }.max() ?? 0
        try requireSettledToggleCrosscheck(before, phase: "before")
        try requireSettledToggleCrosscheck(after, phase: "after")
        try require(
            before.listItemCount == Issue21Geometry.stressListItemCount
                && after.listItemCount == Issue21Geometry.stressListItemCount,
            "cycle changed related-row count"
        )
        try require(abs(toggleDelta) <= tolerance, "\(name) toggle net drift was \(f(toggleDelta))pt")
        try require(abs(cardDelta) <= tolerance, "\(name) card net drift was \(f(cardDelta))pt")
        try require(
            maxToggleExcursion <= transientTolerance,
            "\(name) transient toggle excursion was \(f(maxToggleExcursion))pt"
        )
    }

    func requireMidpointDisclosureStable(placement: MidpointPlacement) throws {
        let toggleDelta = after.toggleWindowY - before.toggleWindowY
        let cardDelta = after.cardTopWindowY - before.cardTopWindowY
        let offsetDelta = after.outerOffsetY - before.outerOffsetY
        let maxToggleExcursion = composedToggleWindowYs
            .map { abs($0 - before.toggleWindowY) }
            .max() ?? 0
        let sentinelY = after.sentinelWindowY.map { f($0) } ?? "none"
        print(
            "[DisclosureMidpointResult] placement=\(placement.rawValue) "
                + "mid=\(f(before.listMidWindowY)) "
                + "toggle=\(f(before.toggleWindowY))->\(f(after.toggleWindowY)) delta=\(f(toggleDelta)) "
                + "cardTop=\(f(before.cardTopWindowY))->\(f(after.cardTopWindowY)) delta=\(f(cardDelta)) "
                + "cardBottom=\(f(before.focusedCardBottomWindowY))->\(f(after.focusedCardBottomWindowY)) "
                + "offset=\(f(before.outerOffsetY))->\(f(after.outerOffsetY)) delta=\(f(offsetDelta)) "
                + "sentinelY=\(sentinelY) maxToggleExcursion=\(f(maxToggleExcursion))"
        )
        try requireSettledToggleCrosscheck(before, phase: "before")
        try requireSettledToggleCrosscheck(after, phase: "after")
        try require(after.sentinelVisible, "\(name) did not reveal the final quote sentinel")
        try require(after.sentinelAfterToggle, "\(name) revealed content was not after the toggle in the hosted DOM")
        if let sentinelWindowY = after.sentinelWindowY {
            try require(
                sentinelWindowY > after.toggleWindowY,
                "\(name) final revealed sentinel was not below the toggle: sentinel=\(f(sentinelWindowY)) toggle=\(f(after.toggleWindowY))"
            )
        } else {
            throw MeasurementFailure("\(name) had no visible sentinel window coordinate after expansion")
        }
        try require(
            abs(toggleDelta) <= Issue21Geometry.settledTolerance,
            "\(name) moved the directly hosted toggle by \(f(toggleDelta))pt"
        )
        try require(
            maxToggleExcursion <= Issue21Geometry.transientTolerance,
            "\(name) transient toggle excursion was \(f(maxToggleExcursion))pt"
        )
    }

    func requireAboveMidpointCollapseStable() throws {
        let tolerance = Issue21Geometry.settledTolerance
        let transientTolerance = Issue21Geometry.transientTolerance
        let toggleDelta = after.toggleWindowY - before.toggleWindowY
        let cardDelta = after.cardTopWindowY - before.cardTopWindowY
        let offsetDelta = after.outerOffsetY - before.outerOffsetY
        let cardHeightDelta = after.focusedCardHeight - before.focusedCardHeight
        let maxToggleExcursion = composedToggleWindowYs
            .map { abs($0 - before.toggleWindowY) }
            .max() ?? 0
        let maxCardExcursion = frames
            .map { abs($0.cardTopWindowY - before.cardTopWindowY) }
            .max() ?? 0
        guard let beforeCellFrame = before.hostedCellWindowFrame,
              let afterCellFrame = after.hostedCellWindowFrame else {
            throw MeasurementFailure("\(name) did not retain a live hosted cell through collapse")
        }
        let hostedCellHeightDelta = afterCellFrame.height - beforeCellFrame.height
        let expectedHostedCellHeight = beforeCellFrame.height
            + after.webViewWindowFrame.height - before.webViewWindowFrame.height
        print(
            "[DisclosureMidpointCollapse] offsetDelta=\(f(offsetDelta)) "
                + "toggleDelta=\(f(toggleDelta)) cardDelta=\(f(cardDelta)) "
                + "cardHeightDelta=\(f(cardHeightDelta)) "
                + "cellHeight=\(f(beforeCellFrame.height))->\(f(afterCellFrame.height)) "
                + "expectedCellHeight=\(f(expectedHostedCellHeight)) "
                + "maxToggleExcursion=\(f(maxToggleExcursion)) "
                + "maxCardExcursion=\(f(maxCardExcursion))"
        )
        try require(!before.collapsed && before.sentinelVisible, "\(name) baseline was not expanded")
        try require(after.collapsed && !after.sentinelVisible, "\(name) did not finish collapsed")
        try requireSettledToggleCrosscheck(before, phase: "before")
        try requireSettledToggleCrosscheck(after, phase: "after")
        try require(
            before.listItemCount == Issue21Geometry.midpointListItemCount
                && after.listItemCount == Issue21Geometry.midpointListItemCount,
            "\(name) did not retain the 16-below/40-above production List fixture"
        )
        try require(abs(offsetDelta) <= tolerance, "\(name) raw offset drift was \(f(offsetDelta))pt")
        try require(abs(toggleDelta) <= tolerance, "\(name) toggle net drift was \(f(toggleDelta))pt")
        try require(abs(cardDelta) <= tolerance, "\(name) card net drift was \(f(cardDelta))pt")
        try require(
            maxToggleExcursion <= transientTolerance,
            "\(name) transient toggle excursion was \(f(maxToggleExcursion))pt"
        )
        try require(
            maxCardExcursion <= transientTolerance,
            "\(name) transient card excursion was \(f(maxCardExcursion))pt"
        )
        try require(
            cardHeightDelta <= -Issue21Geometry.materialCardGrowth
                && hostedCellHeightDelta <= -Issue21Geometry.materialCardGrowth,
            "\(name) did not produce a material downward card/cell height delta: "
                + "card=\(f(cardHeightDelta)) cell=\(f(hostedCellHeightDelta))"
        )
        try require(
            expectedHostedCellHeight.isFinite && expectedHostedCellHeight >= 0,
            "\(name) produced an invalid expected hosted-cell height \(f(expectedHostedCellHeight))"
        )
        try require(
            abs(afterCellFrame.height - expectedHostedCellHeight)
                <= Issue21Geometry.hostedGeometryTolerance,
            "\(name) hosted-cell collapse height disagreed with the WebView height delta: "
                + "actual=\(f(afterCellFrame.height)) expected=\(f(expectedHostedCellHeight))"
        )
        try require(
            Issue21Geometry.realisticCollapsedCardRange.contains(after.focusedCardHeight),
            "\(name) final collapsed card height was \(f(after.focusedCardHeight))pt"
        )
    }

    func requireKnownBadAboveMidpointOuterReanchor() throws {
        let toggleDelta = after.toggleWindowY - before.toggleWindowY
        let cardDelta = after.cardTopWindowY - before.cardTopWindowY
        let cardBottomDelta = after.focusedCardBottomWindowY - before.focusedCardBottomWindowY
        let offsetDelta = after.outerOffsetY - before.outerOffsetY
        let requiredMovement = Issue21Geometry.knownBadReanchorMovement
        let firstDOMToggle = webFrames.first?.toggleOffsetY ?? .nan
        let maxDOMExcursion = webFrames
            .map { abs($0.toggleOffsetY - firstDOMToggle) }
            .max() ?? .infinity
        print(
            "[DisclosureMidpointSensitivity] offsetDelta=\(f(offsetDelta)) "
                + "toggleDelta=\(f(toggleDelta)) cardDelta=\(f(cardDelta)) "
                + "cardBottomDelta=\(f(cardBottomDelta)) domExcursion=\(f(maxDOMExcursion))"
        )
        try require(before.collapsed && !before.sentinelVisible, "sensitivity baseline was not collapsed")
        try require(after.sentinelVisible && after.sentinelAfterToggle, "sensitivity did not reveal content after the toggle")
        try require(
            abs(toggleDelta) > requiredMovement && abs(cardDelta) > requiredMovement,
            "bypassed viewport correction did not expose material outer movement: toggle=\(f(toggleDelta)) card=\(f(cardDelta))"
        )
        try require(
            abs(offsetDelta) > requiredMovement && offsetDelta * toggleDelta < 0,
            "bypassed viewport correction did not move List offset opposite the toggle: offset=\(f(offsetDelta)) toggle=\(f(toggleDelta))"
        )
        try require(
            abs(toggleDelta - cardDelta) <= Issue21Geometry.settledTolerance,
            "known-bad toggle/card movement diverged: toggle=\(f(toggleDelta)) card=\(f(cardDelta))"
        )
        try require(
            abs(offsetDelta + toggleDelta) <= Issue21Geometry.settledTolerance,
            "known-bad List offset did not match opposite toggle movement: offset=\(f(offsetDelta)) toggle=\(f(toggleDelta))"
        )
        try require(
            abs(cardBottomDelta) <= Issue21Geometry.settledTolerance,
            "known-bad List behavior did not retain the row bottom: delta=\(f(cardBottomDelta))"
        )
        try require(
            maxDOMExcursion <= Issue21Geometry.hostedGeometryTolerance,
            "known-bad movement came from WebKit DOM geometry: excursion=\(f(maxDOMExcursion))"
        )
    }

    private func requireSettledToggleCrosscheck(
        _ sample: ViewportSample,
        phase: String
    ) throws {
        let delta = sample.toggleWindowY - sample.layoutDerivedToggleWindowY
        try require(
            abs(delta) <= Issue21Geometry.hostedGeometryTolerance,
            "\(name) \(phase) direct/layout toggle cross-check differed by \(f(delta))pt; "
                + "webFrame=\(sample.webViewWindowFrame) webBoundsOrigin=\(sample.webViewBoundsOriginY) "
                + "hostedCell=\(String(describing: sample.hostedCellWindowFrame))"
        )
    }

    func requireFrameCoverage() throws {
        try require(
            nativeFrameViolation == nil,
            nativeFrameViolation ?? "\(name) native frame liveness or geometry violation"
        )
        try require(
            droppedNativeFrameCount == 0,
            "\(name) dropped \(droppedNativeFrameCount) native frames"
        )
        try require(
            frames.count >= Issue21Geometry.minimumFrameCount,
            "\(name) captured only \(frames.count) native frames (dropped \(droppedNativeFrameCount))"
        )
        try require(
            webFrames.count >= Issue21Geometry.minimumFrameCount,
            "\(name) captured only \(webFrames.count) WebKit frames"
        )
        // CADisplayLink can miss callbacks while the app's main run loop is
        // starved, and WebKit requestAnimationFrame pauses with its content
        // process. Their individual gaps are scheduler diagnostics, not a fixed
        // sampling-density guarantee. Keep the shared-epoch accuracy bound:
        // every WebKit frame that was produced must still have a nearby native
        // geometry witness; native-produced frames retain their direct card-
        // geometry checks.
        try require(
            maximumPairingGap <= Issue21Geometry.maximumWebToNativePairingGap,
            "\(name) native/WebKit shared-epoch pairing gap was \(maximumPairingGap)s"
        )
        guard let firstWebFrame = webFrames.first, let lastWebFrame = webFrames.last else {
            throw MeasurementFailure("\(name) WebKit trace had no state witnesses")
        }
        try require(
            firstWebFrame.label == before.label && firstWebFrame.collapsed == before.collapsed,
            "\(name) WebKit trace did not begin in the sampled before state"
        )
        try require(
            lastWebFrame.label == after.label && lastWebFrame.collapsed == after.collapsed,
            "\(name) WebKit trace did not end in the sampled after state"
        )
    }

    private func maximumGap(in epochs: [TimeInterval]) -> TimeInterval {
        zip(epochs, epochs.dropFirst()).map { $1 - $0 }.max() ?? .infinity
    }
}

@MainActor
private final class NativeFrameRecorder: NSObject {
    private let hierarchy: ProductionHierarchy
    private let toggleTopInWebView: CGFloat
    private var displayLink: CADisplayLink?
    private(set) var samples: [NativeFrameSample] = []
    private(set) var droppedFrameCount = 0
    private(set) var firstViolation: String?

    init(hierarchy: ProductionHierarchy, dom: DOMState) {
        self.hierarchy = hierarchy
        let scale = productionViewportScale(webView: hierarchy.webView, dom: dom)
        toggleTopInWebView = CGFloat(dom.toggleTop) * scale
    }

    func start() {
        recordFrame()
        let link = CADisplayLink(target: self, selector: #selector(tick(_:)))
        link.add(to: .main, forMode: .common)
        displayLink = link
    }

    func stop() {
        displayLink?.invalidate()
        displayLink = nil
        recordFrame()
    }

    @objc private func tick(_ displayLink: CADisplayLink) {
        recordFrame()
    }

    private func recordFrame() {
        guard hierarchy.webView.window === hierarchy.window else {
            firstViolation = firstViolation
                ?? "captured WKWebView left the measured production window during frame recording"
            return
        }
        let geometry: TargetLayoutGeometry
        do {
            geometry = try hierarchy.targetLayoutGeometry()
        } catch {
            droppedFrameCount += 1
            return
        }
        guard geometry.itemCount == Issue21Geometry.singleMessageListItemCount
            || geometry.itemCount == Issue21Geometry.stressListItemCount
            || geometry.itemCount == Issue21Geometry.midpointListItemCount else {
            droppedFrameCount += 1
            return
        }
        let list = hierarchy.list
        let targetFrame = geometry.targetFrame
        let cardTop = targetFrame.minY + Issue21Geometry.rowVerticalInsets / 2
        let hostedCell = try? hierarchy.targetCell()
        let targetIndexPath = geometry.targetIndexPath
        let hostedFrame: CGRect? = if let hostedCell,
                                      list.indexPath(for: hostedCell) == targetIndexPath {
            hostedCell.convert(hostedCell.bounds, to: hierarchy.window)
        } else {
            nil
        }
        let webView = hierarchy.webView
        let togglePoint = CGPoint(
            x: webView.bounds.minX,
            y: webView.bounds.minY + toggleTopInWebView
        )
        samples.append(NativeFrameSample(
            epoch: Date().timeIntervalSince1970,
            outerOffsetY: list.contentOffset.y,
            outerContentHeight: list.contentSize.height,
            toggleWindowY: webView.convert(togglePoint, to: hierarchy.window).y,
            cardTopWindowY: cardTop,
            focusedCardHeight: max(0, targetFrame.height - Issue21Geometry.rowVerticalInsets),
            bottomSpacerHeight: geometry.spacerFrame.height,
            listItemCount: geometry.itemCount,
            hostedCardTopWindowY: hostedFrame.map { $0.minY + Issue21Geometry.rowVerticalInsets / 2 },
            hostedCardHeight: hostedFrame.map { max(0, $0.height - Issue21Geometry.rowVerticalInsets) }
        ))
    }
}

@MainActor
private func waitForListItems(_ list: UICollectionView, atLeast expected: Int) async throws {
    let deadline = Date().addingTimeInterval(12)
    while Date() < deadline {
        list.layoutIfNeeded()
        let count = (0..<list.numberOfSections).reduce(0) { $0 + list.numberOfItems(inSection: $1) }
        if count >= expected { return }
        try? await Task.sleep(for: .milliseconds(50))
    }
    let count = (0..<list.numberOfSections).reduce(0) { $0 + list.numberOfItems(inSection: $1) }
    throw MeasurementFailure("production List item count \(count) never reached \(expected)")
}

@MainActor
private func waitForListItems(_ list: UICollectionView, exactly expected: Int) async throws {
    let deadline = Date().addingTimeInterval(12)
    while Date() < deadline {
        list.layoutIfNeeded()
        let count = (0..<list.numberOfSections).reduce(0) { $0 + list.numberOfItems(inSection: $1) }
        if count == expected { return }
        try? await Task.sleep(for: .milliseconds(50))
    }
    let count = (0..<list.numberOfSections).reduce(0) { $0 + list.numberOfItems(inSection: $1) }
    throw MeasurementFailure("production List item count \(count) never became exactly \(expected)")
}

@MainActor
private func waitForDOM(_ webView: WKWebView, sentinelId: String) async throws -> DOMState {
    let deadline = Date().addingTimeInterval(12)
    while Date() < deadline {
        if let state = try? await readDOM(webView, sentinelId: sentinelId), !state.label.isEmpty {
            return state
        }
        try? await Task.sleep(for: .milliseconds(50))
    }
    throw MeasurementFailure("production disclosure DOM did not become ready")
}

@MainActor
private func readDOM(_ webView: WKWebView, sentinelId: String) async throws -> DOMState {
    let script = """
    (function() {
      var toggle = document.querySelector('.tm-quote-toggle');
      var wrapper = document.querySelector('.tm-quote-wrapper');
      var sentinel = document.getElementById('\(sentinelId)');
      if (!toggle || !wrapper || !sentinel) return '';
      var r = toggle.getBoundingClientRect();
      var sentinelRects = sentinel.getClientRects();
      return JSON.stringify({
        label: (toggle.textContent || '').trim(),
        toggleTop: r.top,
        sentinelTop: sentinelRects.length ? sentinelRects[0].top : null,
        effectiveViewportWidth: Number(window.__tmLayoutVp || window.__tmDeviceWidth || window.innerWidth),
        collapsed: wrapper.classList.contains('tm-collapsed'),
        sentinelVisible: sentinelRects.length > 0,
        sentinelAfterToggle: Boolean(toggle.compareDocumentPosition(sentinel) & Node.DOCUMENT_POSITION_FOLLOWING)
      });
    })()
    """
    let raw = await CanaryKit.eval(webView, script, in: RenderContentWorld.isolated)
    guard let data = raw.data(using: .utf8) else {
        throw MeasurementFailure("DOM state was not UTF-8")
    }
    do {
        return try JSONDecoder().decode(DOMState.self, from: data)
    } catch {
        throw MeasurementFailure("could not decode DOM state \(raw): \(error)")
    }
}

@MainActor
private func sample(
    start: Date,
    webView: WKWebView,
    hierarchy: ProductionHierarchy,
    sentinelId: String
) async throws -> ViewportSample {
    try hierarchy.requireWebViewIsLive()
    hierarchy.window.layoutIfNeeded()
    hierarchy.list.layoutIfNeeded()
    let dom = try await readDOM(webView, sentinelId: sentinelId)
    try hierarchy.requireWebViewIsLive()
    let geometry = try hierarchy.targetLayoutGeometry()
    let targetFrame = geometry.targetFrame
    let list = hierarchy.list
    let scale = productionViewportScale(webView: webView, dom: dom)
    // MessageDetailView measures cardView before the List's 6pt top/bottom row
    // insets. Use the focused row's layout attributes rather than the hosted
    // cell bounds: after 40 rows insert above it, the cell can be virtualized
    // while its layout attributes remain the authoritative production geometry.
    let focusedCardHeight = max(0, targetFrame.height - Issue21Geometry.rowVerticalInsets)
    let toggleOffsetWithinCard = hierarchy.webViewTopWithinTargetCard + CGFloat(dom.toggleTop) * scale
    let cardTop = targetFrame.minY + Issue21Geometry.rowVerticalInsets / 2
    let togglePoint = CGPoint(
        x: webView.bounds.minX,
        y: webView.bounds.minY + CGFloat(dom.toggleTop) * scale
    )
    let directToggleWindowY = webView.convert(togglePoint, to: hierarchy.window).y
    let sentinelWindowY = dom.sentinelTop.map { top in
        let point = CGPoint(
            x: webView.bounds.minX,
            y: webView.bounds.minY + CGFloat(top) * scale
        )
        return webView.convert(point, to: hierarchy.window).y
    }
    let webViewWindowOriginY = webView.convert(webView.bounds.origin, to: hierarchy.window).y
    let webViewWindowFrame = webView.convert(webView.bounds, to: hierarchy.window)
    let hostedCell = try? hierarchy.targetCell()
    let targetIndexPath = geometry.targetIndexPath
    let hostedCellWindowFrame: CGRect? = if let hostedCell,
                                           list.indexPath(for: hostedCell) == targetIndexPath {
        hostedCell.convert(hostedCell.bounds, to: hierarchy.window)
    } else {
        nil
    }
    return ViewportSample(
        elapsed: Date().timeIntervalSince(start),
        outerOffsetY: list.contentOffset.y,
        outerContentHeight: list.contentSize.height,
        toggleWindowY: directToggleWindowY,
        layoutDerivedToggleWindowY: cardTop + toggleOffsetWithinCard,
        sentinelWindowY: sentinelWindowY,
        webViewWindowOriginY: webViewWindowOriginY,
        webViewBoundsOriginY: webView.bounds.minY,
        webViewWindowFrame: webViewWindowFrame,
        hostedCellWindowFrame: hostedCellWindowFrame,
        cardTopWindowY: cardTop,
        focusedCardHeight: focusedCardHeight,
        listHeight: list.bounds.height,
        listMidWindowY: list.convert(list.bounds, to: hierarchy.window).midY,
        bottomSpacer: geometry.spacerFrame.height,
        listItemCount: geometry.itemCount,
        label: dom.label,
        collapsed: dom.collapsed,
        sentinelVisible: dom.sentinelVisible,
        sentinelAfterToggle: dom.sentinelAfterToggle
    )
}

@MainActor
private func captureTransition(
    name: String,
    webView: WKWebView,
    hierarchy: ProductionHierarchy,
    sentinelId: String,
    configuration: MeasurementConfiguration,
    disclosure: DisclosureKind,
    action: @MainActor () async throws -> Void,
    required: @escaping (ViewportSample) -> Bool
) async throws -> CapturedTransition {
    let before = try await sample(
        start: Date(),
        webView: webView,
        hierarchy: hierarchy,
        sentinelId: sentinelId
    )
    let dom = try await readDOM(webView, sentinelId: sentinelId)
    try await startWebFrameTrace(webView)
    let recorder = NativeFrameRecorder(hierarchy: hierarchy, dom: dom)
    recorder.start()
    do {
        try await action()
        let settled = try await settle(
            phase: name,
            configuration: configuration,
            disclosure: disclosure,
            webView: webView,
            hierarchy: hierarchy,
            sentinelId: sentinelId,
            required: required
        )
        recorder.stop()
        let webFrames = try await stopWebFrameTrace(
            webView,
            scale: productionViewportScale(webView: hierarchy.webView, dom: dom)
        )
        let after = try requireLast(settled, phase: name)
        let result = CapturedTransition(
            name: name,
            before: before,
            after: after,
            frames: recorder.samples,
            webFrames: webFrames,
            droppedNativeFrameCount: recorder.droppedFrameCount,
            nativeFrameViolation: recorder.firstViolation
        )
        let traceEpoch = min(
            result.frames.first?.epoch ?? .infinity,
            result.webFrames.first?.epoch ?? .infinity
        )
        for (index, frame) in result.frames.enumerated() {
            let hostedTop = frame.hostedCardTopWindowY.map { f($0) } ?? "none"
            let hostedHeight = frame.hostedCardHeight.map { f($0) } ?? "none"
            print(
                "[DisclosureViewportFrame] \(name) frame=\(index) t=\(f(frame.epoch - traceEpoch)) "
                    + "items=\(frame.listItemCount) offset=\(f(frame.outerOffsetY)) "
                    + "contentH=\(f(frame.outerContentHeight)) toggleY=\(f(frame.toggleWindowY)) "
                    + "cardTop=\(f(frame.cardTopWindowY)) cardH=\(f(frame.focusedCardHeight)) "
                    + "spacerH=\(f(frame.bottomSpacerHeight)) "
                    + "hostedCardTop=\(hostedTop) hostedCardH=\(hostedHeight)"
            )
        }
        for (index, frame) in result.webFrames.enumerated() {
            print(
                "[DisclosureWebFrame] \(name) frame=\(index) t=\(f(frame.epoch - traceEpoch)) "
                    + "toggleOffset=\(f(frame.toggleOffsetY)) label=\(frame.label.debugDescription) "
                    + "collapsed=\(frame.collapsed)"
            )
        }
        result.printSummary()
        try result.requireFrameCoverage()
        return result
    } catch {
        recorder.stop()
        _ = try? await stopWebFrameTrace(webView, scale: 1)
        throw error
    }
}

@MainActor
private func startWebFrameTrace(_ webView: WKWebView) async throws {
    let script = """
    (function() {
      var toggle = document.querySelector('.tm-quote-toggle');
      var wrapper = document.querySelector('.tm-quote-wrapper');
      if (!toggle || !wrapper) return 'missing';
      window.__tmIssue21FrameTrace = [];
      window.__tmIssue21FrameTraceActive = true;
      function capture(timestamp) {
        var current = document.querySelector('.tm-quote-toggle');
        var currentWrapper = document.querySelector('.tm-quote-wrapper');
        if (current && currentWrapper && window.__tmIssue21FrameTrace.length < 1500) {
          window.__tmIssue21FrameTrace.push({
            epochMilliseconds: performance.timeOrigin + timestamp,
            toggleTop: current.getBoundingClientRect().top,
            label: (current.textContent || '').trim(),
            collapsed: currentWrapper.classList.contains('tm-collapsed')
          });
        }
        if (window.__tmIssue21FrameTraceActive) requestAnimationFrame(capture);
      }
      capture(performance.now());
      return 'armed';
    })()
    """
    let result = await CanaryKit.eval(webView, script, in: RenderContentWorld.isolated)
    try require(result == "armed", "isolated-world WebKit frame trace did not arm: \(result)")
}

@MainActor
private func stopWebFrameTrace(_ webView: WKWebView, scale: CGFloat) async throws -> [WebFrameSample] {
    let script = """
    (function() {
      window.__tmIssue21FrameTraceActive = false;
      return JSON.stringify(window.__tmIssue21FrameTrace || []);
    })()
    """
    let raw = await CanaryKit.eval(webView, script, in: RenderContentWorld.isolated)
    guard let data = raw.data(using: .utf8) else {
        throw MeasurementFailure("WebKit frame trace was not UTF-8")
    }
    let payloads: [WebFramePayload]
    do {
        payloads = try JSONDecoder().decode([WebFramePayload].self, from: data)
    } catch {
        throw MeasurementFailure("could not decode WebKit frame trace: \(error)")
    }
    guard payloads.first != nil else {
        throw MeasurementFailure("WebKit requestAnimationFrame trace captured zero frames")
    }
    return payloads.map { payload in
        WebFrameSample(
            epoch: payload.epochMilliseconds / 1_000,
            toggleOffsetY: CGFloat(payload.toggleTop) * scale,
            label: payload.label,
            collapsed: payload.collapsed
        )
    }
}

@MainActor
private func clickDisclosure(_ webView: WKWebView) async throws {
    let result = await CanaryKit.eval(
        webView,
        "document.querySelector('.tm-quote-toggle').click(); 'clicked'",
        in: RenderContentWorld.isolated
    )
    try require(result == "clicked", "production isolated-world disclosure click failed: \(result)")
}

@MainActor
private func positionInteriorToggle(
    webView: WKWebView,
    hierarchy: ProductionHierarchy,
    sentinelId: String
) async throws {
    var positioned = try await sample(
        start: Date(),
        webView: webView,
        hierarchy: hierarchy,
        sentinelId: sentinelId
    )
    let list = hierarchy.list
    let listFrame = list.convert(list.bounds, to: hierarchy.window)
    let minimum = -list.adjustedContentInset.top
    for _ in 0..<3 {
        let maximum = max(
            minimum,
            list.contentSize.height - list.bounds.height + list.adjustedContentInset.bottom
        )
        // Row insertion can leave SwiftUI temporarily hosting the pre-insert
        // cell at its old screen position while List's authoritative layout
        // attributes already place the focused row below the inserted rows.
        // Scroll to the layout-derived toggle, then require the direct hosted
        // DOM coordinate to converge before exercising collapse/reopen.
        let desired = list.contentOffset.y
            + positioned.layoutDerivedToggleWindowY - listFrame.midY
        list.setContentOffset(
            CGPoint(x: list.contentOffset.x, y: min(max(desired, minimum), maximum)),
            animated: false
        )
        hierarchy.window.layoutIfNeeded()
        try? await Task.sleep(for: .milliseconds(300))
        ScrollFreezeGate.shared.end()
        positioned = try await sample(
            start: Date(),
            webView: webView,
            hierarchy: hierarchy,
            sentinelId: sentinelId
        )
        if abs(positioned.toggleWindowY - listFrame.midY) <= Issue21Geometry.settledTolerance,
           abs(positioned.toggleWindowY - positioned.layoutDerivedToggleWindowY)
            <= Issue21Geometry.hostedGeometryTolerance {
            break
        }
    }
    let updatedMaximum = max(
        minimum,
        list.contentSize.height - list.bounds.height + list.adjustedContentInset.bottom
    )
    try require(
        positioned.outerOffsetY > minimum + Issue21Geometry.interiorMargin,
        "stress toggle offset was not inside the leading scroll bound: \(positioned.outerOffsetY)"
    )
    try require(
        positioned.outerOffsetY < updatedMaximum - Issue21Geometry.interiorMargin,
        "stress toggle offset was not inside the trailing scroll bound: offset=\(positioned.outerOffsetY) max=\(updatedMaximum)"
    )
    try require(
        abs(positioned.toggleWindowY - listFrame.midY) <= Issue21Geometry.interiorMargin,
        "stress toggle was not visibly mid-viewport: toggle=\(positioned.toggleWindowY) listMid=\(listFrame.midY)"
    )
    try require(
        abs(positioned.toggleWindowY - positioned.layoutDerivedToggleWindowY)
            <= Issue21Geometry.hostedGeometryTolerance,
        "stress direct/layout toggle geometry did not converge after interior positioning"
    )
    try require(
        positioned.listItemCount == Issue21Geometry.stressListItemCount,
        "stress interior position lost related rows"
    )
    try hierarchy.requireHostedCellAgreesWithLayout()
    print(
        "[DisclosureViewportInterior] offset=\(f(positioned.outerOffsetY)) min=\(f(minimum)) "
            + "max=\(f(updatedMaximum)) toggleY=\(f(positioned.toggleWindowY)) listMid=\(f(listFrame.midY))"
    )
}

@MainActor
private func positionCollapsedToggle(
    placement: MidpointPlacement,
    webView: WKWebView,
    hierarchy: ProductionHierarchy,
    sentinelId: String
) async throws -> ViewportSample {
    var positioned = try await sample(
        start: Date(),
        webView: webView,
        hierarchy: hierarchy,
        sentinelId: sentinelId
    )
    let list = hierarchy.list
    let listFrame = list.convert(list.bounds, to: hierarchy.window)
    let targetY = listFrame.midY + (
        placement == .above
            ? -Issue21Geometry.midpointTargetDistance
            : Issue21Geometry.midpointTargetDistance
    )
    let minimum = -list.adjustedContentInset.top
    for _ in 0..<4 {
        let maximum = max(
            minimum,
            list.contentSize.height - list.bounds.height + list.adjustedContentInset.bottom
        )
        let desired = list.contentOffset.y + positioned.toggleWindowY - targetY
        list.setContentOffset(
            CGPoint(x: list.contentOffset.x, y: min(max(desired, minimum), maximum)),
            animated: false
        )
        hierarchy.window.layoutIfNeeded()
        try? await Task.sleep(for: .milliseconds(300))
        ScrollFreezeGate.shared.end()
        positioned = try await sample(
            start: Date(),
            webView: webView,
            hierarchy: hierarchy,
            sentinelId: sentinelId
        )
        if abs(positioned.toggleWindowY - targetY) <= Issue21Geometry.midpointTargetTolerance,
           abs(positioned.toggleWindowY - positioned.layoutDerivedToggleWindowY)
            <= Issue21Geometry.hostedGeometryTolerance {
            break
        }
    }
    return positioned
}

@MainActor
private func requireMidpointPreconditions(
    _ positioned: ViewportSample,
    placement: MidpointPlacement,
    hierarchy: ProductionHierarchy
) throws {
    let list = hierarchy.list
    let listFrame = list.convert(list.bounds, to: hierarchy.window)
    let minimum = -list.adjustedContentInset.top
    let maximum = max(
        minimum,
        list.contentSize.height - list.bounds.height + list.adjustedContentInset.bottom
    )
    let midpointDistance = positioned.toggleWindowY - listFrame.midY
    print(
        "[DisclosureMidpointPrecondition] placement=\(placement.rawValue) "
            + "offset=\(f(positioned.outerOffsetY)) min=\(f(minimum)) max=\(f(maximum)) "
            + "toggleY=\(f(positioned.toggleWindowY)) layoutToggleY=\(f(positioned.layoutDerivedToggleWindowY)) "
            + "mid=\(f(listFrame.midY)) midpointDistance=\(f(midpointDistance)) "
            + "cardTop=\(f(positioned.cardTopWindowY)) cardBottom=\(f(positioned.focusedCardBottomWindowY)) "
            + "cardH=\(f(positioned.focusedCardHeight))"
    )
    try require(positioned.collapsed, "midpoint fixture was not collapsed immediately before click")
    try require(!positioned.sentinelVisible, "midpoint sentinel was visible immediately before click")
    try require(
        Issue21Geometry.realisticCollapsedCardRange.contains(positioned.focusedCardHeight),
        "midpoint collapsed card height \(f(positioned.focusedCardHeight)) was outside the realistic 600...900pt range"
    )
    try require(
        positioned.toggleWindowY > listFrame.minY + Issue21Geometry.visibleTopClearance
            && positioned.toggleWindowY < listFrame.maxY - Issue21Geometry.visibleTopClearance,
        "midpoint toggle was not fully visible: toggle=\(f(positioned.toggleWindowY)) list=\(listFrame)"
    )
    try require(
        positioned.outerOffsetY > minimum + Issue21Geometry.interiorMargin,
        "midpoint outer offset was not 100pt inside the leading bound"
    )
    try require(
        positioned.outerOffsetY < maximum - Issue21Geometry.interiorMargin,
        "midpoint outer offset was not 100pt inside the trailing bound"
    )
    try require(
        abs(positioned.toggleWindowY - positioned.layoutDerivedToggleWindowY)
            <= Issue21Geometry.hostedGeometryTolerance,
        "midpoint direct hosted toggle disagreed with production layout geometry"
    )
    try require(
        abs(positioned.listMidWindowY - listFrame.midY) <= Issue21Geometry.hostedGeometryTolerance,
        "midpoint sample did not use the live production List midpoint"
    )
    switch placement {
    case .above:
        try require(
            midpointDistance <= -Issue21Geometry.midpointSeparation,
            "above control toggle was only \(f(abs(midpointDistance)))pt above the midpoint"
        )
        try require(
            positioned.focusedCardBottomWindowY
                <= listFrame.midY + Issue21Geometry.midpointCardBottomAllowance,
            "above control focused-card bottom was too far below midpoint: bottom=\(f(positioned.focusedCardBottomWindowY)) mid=\(f(listFrame.midY))"
        )
    case .below:
        try require(
            midpointDistance >= Issue21Geometry.midpointSeparation,
            "below control toggle was only \(f(abs(midpointDistance)))pt below the midpoint"
        )
        try require(
            positioned.focusedCardBottomWindowY >= listFrame.midY + Issue21Geometry.midpointSeparation,
            "below control focused-card bottom was not below midpoint"
        )
    }
    try hierarchy.requireHostedCellAgreesWithLayout()
}

@MainActor
private func requireAboveMidpointCollapsePreconditions(
    _ expanded: ViewportSample,
    hierarchy: ProductionHierarchy
) throws {
    let listFrame = hierarchy.list.convert(hierarchy.list.bounds, to: hierarchy.window)
    let midpointDistance = expanded.toggleWindowY - listFrame.midY
    let geometry = try hierarchy.targetLayoutGeometry()
    let rowsBelowTarget = geometry.itemCount - geometry.targetIndexPath.item - 2
    print(
        "[DisclosureMidpointCollapsePrecondition] offset=\(f(expanded.outerOffsetY)) "
            + "toggleY=\(f(expanded.toggleWindowY)) layoutToggleY=\(f(expanded.layoutDerivedToggleWindowY)) "
            + "mid=\(f(listFrame.midY)) midpointDistance=\(f(midpointDistance)) "
            + "cardTop=\(f(expanded.cardTopWindowY)) cardH=\(f(expanded.focusedCardHeight))"
    )
    try require(!expanded.collapsed, "above-midpoint collapse baseline was not expanded")
    try require(expanded.sentinelVisible, "above-midpoint collapse baseline hid the quote sentinel")
    try require(
        expanded.listItemCount == Issue21Geometry.midpointListItemCount,
        "above-midpoint collapse baseline lost the 16-below/40-above List fixture"
    )
    try require(
        rowsBelowTarget == Issue21Geometry.midpointEarlierMessageCount,
        "above-midpoint collapse target had \(rowsBelowTarget) rows below instead of the fixture's 16"
    )
    try require(
        expanded.toggleWindowY > listFrame.minY + Issue21Geometry.visibleTopClearance
            && expanded.toggleWindowY < listFrame.maxY - Issue21Geometry.visibleTopClearance,
        "above-midpoint collapse toggle was not fully visible"
    )
    try require(
        midpointDistance <= -Issue21Geometry.midpointSeparation,
        "expanded toggle no longer remained above midpoint: distance=\(f(midpointDistance))pt"
    )
    try require(
        abs(expanded.toggleWindowY - expanded.layoutDerivedToggleWindowY)
            <= Issue21Geometry.hostedGeometryTolerance,
        "above-midpoint collapse direct/layout toggle geometry disagreed"
    )
    try requireInteriorScrollBounds(
        expanded,
        hierarchy: hierarchy,
        phase: "above-midpoint collapse before"
    )
    try hierarchy.requireHostedCellAgreesWithLayout()
}

@MainActor
private func requireInteriorScrollBounds(
    _ sample: ViewportSample,
    hierarchy: ProductionHierarchy,
    phase: String
) throws {
    let list = hierarchy.list
    let minimum = -list.adjustedContentInset.top
    let maximum = max(
        minimum,
        list.contentSize.height - list.bounds.height + list.adjustedContentInset.bottom
    )
    try require(
        sample.outerOffsetY > minimum + Issue21Geometry.interiorMargin,
        "\(phase) offset \(f(sample.outerOffsetY)) was not 100pt inside leading bound \(f(minimum))"
    )
    try require(
        sample.outerOffsetY < maximum - Issue21Geometry.interiorMargin,
        "\(phase) offset \(f(sample.outerOffsetY)) was not 100pt inside trailing bound \(f(maximum))"
    )
}

@MainActor
private func settle(
    phase: String,
    configuration: MeasurementConfiguration,
    disclosure: DisclosureKind,
    webView: WKWebView,
    hierarchy: ProductionHierarchy,
    sentinelId: String,
    required: ((ViewportSample) -> Bool)?
) async throws -> [ViewportSample] {
    let start = Date()
    let deadline = start.addingTimeInterval(12)
    var samples: [ViewportSample] = []
    var stableCount = 0
    while Date() < deadline {
        let value = try await sample(
            start: start,
            webView: webView,
            hierarchy: hierarchy,
            sentinelId: sentinelId
        )
        samples.append(value)
        printSample(value, phase: phase, configuration: configuration, disclosure: disclosure)
        let transitioned = required?(value) ?? true
        if transitioned, let previous = samples.dropLast().last, value.isStable(comparedWith: previous) {
            stableCount += 1
        } else {
            stableCount = transitioned ? 1 : 0
        }
        if stableCount >= 3 { return samples }
        try? await Task.sleep(for: .milliseconds(250))
    }
    throw MeasurementFailure("\(configuration.rawValue) \(disclosure.rawValue) \(phase) did not settle; samples=\(samples.count)")
}

@MainActor
private func positionScrolledToggle(
    configuration: MeasurementConfiguration,
    webView: WKWebView,
    hierarchy: ProductionHierarchy,
    sentinelId: String
) async throws {
    let current = try await sample(
        start: Date(),
        webView: webView,
        hierarchy: hierarchy,
        sentinelId: sentinelId
    )
    let listFrame = hierarchy.list.convert(hierarchy.list.bounds, to: hierarchy.window)
    let desired = hierarchy.list.contentOffset.y + current.toggleWindowY - listFrame.midY
    let minimum = -hierarchy.list.adjustedContentInset.top
    let maximum = max(
        minimum,
        hierarchy.list.contentSize.height - hierarchy.list.bounds.height
            + hierarchy.list.adjustedContentInset.bottom
    )
    hierarchy.list.setContentOffset(
        CGPoint(x: hierarchy.list.contentOffset.x, y: min(max(desired, minimum), maximum)),
        animated: false
    )
    hierarchy.window.layoutIfNeeded()
    try? await Task.sleep(for: .milliseconds(300))
    ScrollFreezeGate.shared.end()
    let centered = try await sample(
        start: Date(),
        webView: webView,
        hierarchy: hierarchy,
        sentinelId: sentinelId
    )
    if configuration == .c2 || configuration == .c4 {
        // A trailing disclosure cannot be centered in this production
        // List: once the focused card is long, its real bottom spacer bottoms
        // out at 88pt. Rows later than the focused message sit above it, so C4
        // has the same limit. Both pin the honest strongest reachable shape:
        // actually scrolled, with the toggle fully visible above bottom chrome.
        try require(
            hierarchy.list.contentOffset.y > 0,
            "\(configuration.rawValue) did not reach a positive outer contentOffset (\(hierarchy.list.contentOffset.y))"
        )
        try require(
            centered.toggleWindowY > listFrame.minY + Issue21Geometry.visibleTopClearance
                && centered.toggleWindowY < listFrame.maxY - Issue21Geometry.interiorMargin,
            "\(configuration.rawValue) toggle is not safely visible (toggle=\(centered.toggleWindowY), list=\(listFrame))"
        )
    }
}

@MainActor
private func waitForScrollFreezeToBecomeIdle() async throws {
    let idle = await CanaryKit.waitUntil(3) { !ScrollFreezeGate.shared.isFrozen }
    try require(idle, "ScrollFreezeGate did not return to idle")
}

private func printSample(
    _ value: ViewportSample,
    phase: String,
    configuration: MeasurementConfiguration,
    disclosure: DisclosureKind
) {
    let hostedCell = value.hostedCellWindowFrame.map { String(describing: $0) } ?? "none"
    let sentinelY = value.sentinelWindowY.map { f($0) } ?? "none"
    print(
        "[DisclosureViewportSeries] \(configuration.rawValue) \(disclosure.rawValue) \(phase) "
            + "t=\(f(value.elapsed)) items=\(value.listItemCount) "
            + "offset=\(f(value.outerOffsetY)) contentH=\(f(value.outerContentHeight)) "
            + "toggleY=\(f(value.toggleWindowY)) layoutToggleY=\(f(value.layoutDerivedToggleWindowY)) "
            + "toggleCrosscheck=\(f(value.toggleWindowY - value.layoutDerivedToggleWindowY)) "
            + "cardTop=\(f(value.cardTopWindowY)) webOriginY=\(f(value.webViewWindowOriginY)) "
            + "webBoundsOriginY=\(f(value.webViewBoundsOriginY)) webFrame=\(value.webViewWindowFrame) "
            + "hostedCell=\(hostedCell) "
            + "cardH=\(f(value.focusedCardHeight)) cardBottom=\(f(value.focusedCardBottomWindowY)) "
            + "listH=\(f(value.listHeight)) listMid=\(f(value.listMidWindowY)) "
            + "spacer=\(f(value.bottomSpacer)) label=\(value.label.debugDescription) "
            + "collapsed=\(value.collapsed) sentinelVisible=\(value.sentinelVisible) "
            + "sentinelY=\(sentinelY) "
            + "sentinelAfterToggle=\(value.sentinelAfterToggle)"
    )
}

private func f(_ value: CGFloat) -> String { String(format: "%.2f", Double(value)) }
private func f(_ value: TimeInterval) -> String { String(format: "%.2f", value) }

@MainActor
private func productionViewportScale(webView: WKWebView, dom: DOMState) -> CGFloat {
    let effectiveViewportWidth = max(CGFloat(dom.effectiveViewportWidth), 1)
    return effectiveViewportWidth > webView.bounds.width
        ? webView.bounds.width / effectiveViewportWidth
        : 1
}

private struct MeasurementFailure: Error, CustomStringConvertible {
    let description: String
    init(_ description: String) { self.description = description }
}

private func require(_ condition: @autoclosure () -> Bool, _ message: String) throws {
    guard condition() else { throw MeasurementFailure(message) }
}

private func requireLast(_ samples: [ViewportSample], phase: String) throws -> ViewportSample {
    guard let value = samples.last else { throw MeasurementFailure("\(phase) produced no samples") }
    return value
}
