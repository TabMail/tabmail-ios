/* This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at https://mozilla.org/MPL/2.0/. */

import Foundation
import GRDB
import SwiftUI
import Testing
import UIKit
@testable import TabMail

/// The real `ChatPillChip`, hosted in a window, greys out in place when its
/// mapping is retired. The test never registers the chips' observers or
/// binds their popovers itself: the chip's own `.task` and `.popover` do, so
/// removing either from the chip fails here.
@Suite("Chat pill chip, hosted", .serialized)
@MainActor
struct ChatPillChipHostingTests {

    enum Producer: String, CaseIterable, Sendable {
        case retireMappings
        case refusedRemap
    }

    /// **THE PROPERTY: two mounted occurrences of a moved pill turn
    /// unavailable and the open popover closes, by either producer; a live
    /// pill keeps its open popover and stays available.**
    @Test("Hosted chips grey out in place and close their popover; a live chip keeps its own",
          arguments: Producer.allCases)
    func hostedChipsGreyOutInPlace(producer: Producer) async throws {
        let translator = ChatIdTranslator.createIsolated()
        let liveId = "acct-live-\(UUID().uuidString)"
        let movedId = "acct-moved-\(UUID().uuidString)"
        let live = await translator.toNumericId(liveId)
        let moved = await translator.toNumericId(movedId)
        defer {
            _ = try? AppDatabase.dbPool.write { db in
                try db.execute(sql: "DELETE FROM chatIdMapping WHERE numericId IN (?, ?)", arguments: [live, moved])
            }
        }

        let first = ChatPillAvailability(numericId: moved, type: "email", isHistory: false, translator: translator)
        let second = ChatPillAvailability(numericId: moved, type: "email", isHistory: false, translator: translator)
        let control = ChatPillAvailability(numericId: live, type: "email", isHistory: false, translator: translator)
        let movedHost = try Self.host(HStack {
            ChatPillChip(numericId: moved, type: "email", label: "Moved", isHistory: false, availability: first)
            ChatPillChip(numericId: moved, type: "email", label: "Moved", isHistory: false, availability: second)
        })
        defer { movedHost.isHidden = true }
        let liveHost = try Self.host(
            ChatPillChip(numericId: live, type: "email", label: "Live", isHistory: false, availability: control))
        defer { liveHost.isHidden = true }

        // Open both popovers through the chips' own bindings.
        first.presentation = .email(Self.detail(id: moved, realId: movedId))
        control.presentation = .email(Self.detail(id: live, realId: liveId))
        let opened = await Self.waitUntil {
            Self.presented(movedHost) && Self.presented(liveHost)
        }
        // NON-VACUITY: both popovers are on screen and every chip is available.
        #expect(opened, "a chip did not present its popover")
        #expect(!first.isUnavailable && !second.isUnavailable && !control.isUnavailable)

        switch producer {
        case .retireMappings:
            await translator.retireMappings(realIds: [movedId])
        case .refusedRemap:
            try await AppDatabase.dbPool.write { db in
                try ChatIdTranslator.retireStoredMappings(db, realId: movedId)
            }
            let remapped = await translator.remapRealId(from: movedId, to: "acct-new-\(UUID().uuidString)")
            #expect(remapped == 0, "the remap of a retired mapping was not refused")
        }

        let greyed = await Self.waitUntil(seconds: 5) {
            first.isUnavailable && second.isUnavailable && !Self.presented(movedHost)
        }
        #expect(greyed, "a mounted occurrence did not grey out, or its popover stayed open")
        #expect(first.isUnavailable, "the first mounted occurrence did not grey out")
        #expect(second.isUnavailable, "the second mounted occurrence did not grey out")
        #expect(!Self.presented(movedHost), "the retired pill's popover stayed on screen")
        #expect(!control.isUnavailable, "a live pill turned grey")
        #expect(Self.presented(liveHost), "a live pill's popover was closed")
    }

    // MARK: - Hosting

    private struct HostingFailure: Error, CustomStringConvertible {
        let description: String
        init(_ description: String) { self.description = description }
    }

    private static func detail(id: Int, realId: String) -> EmailPillDetail {
        EmailPillDetail(id: id, realId: realId, subject: "Subject", from: "a@example.com",
                        to: "b@example.com", date: nil, snippet: nil)
    }

    private static func presented(_ window: UIWindow) -> Bool {
        window.rootViewController?.presentedViewController != nil
    }

    private static func host<V: View>(_ view: V) throws -> UIWindow {
        guard let scene = UIApplication.shared.connectedScenes
            .compactMap({ $0 as? UIWindowScene })
            .first else {
            throw HostingFailure("no UIWindowScene is available to host ChatPillChip")
        }
        let controller = UIHostingController(rootView: view)
        let window = UIWindow(windowScene: scene)
        window.frame = CGRect(x: 0, y: 0, width: 390, height: 300)
        window.rootViewController = controller
        window.isHidden = false
        window.makeKeyAndVisible()
        window.layoutIfNeeded()
        controller.view.layoutIfNeeded()
        return window
    }

    /// Polls on the main actor so SwiftUI applies its updates between
    /// checks; bounded, so a missing update fails instead of hanging.
    private static func waitUntil(seconds: TimeInterval = 3, _ condition: () -> Bool) async -> Bool {
        let deadline = Date().addingTimeInterval(seconds)
        while Date() < deadline {
            if condition() { return true }
            try? await Task.sleep(for: .milliseconds(20))
        }
        return condition()
    }
}
