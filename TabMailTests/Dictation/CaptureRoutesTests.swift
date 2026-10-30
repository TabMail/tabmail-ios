/* This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at https://mozilla.org/MPL/2.0/. */

import AVFoundation
import Foundation
import Synchronization
import Testing
@testable import TabMail

/// The capture's invariant (ADR-IOS-085 amendment 2026-10-29): the tap a start installed delivers
/// only to that start's handler. A tap that outlives its stop, because the capture queue tears it
/// down a moment later, can never feed the recording that started after it. Every consumer of
/// `MicrophoneCapture` (the backend dictation and the on-device recognizer) gets it from here.
struct CaptureRoutesTests {
    /// A buffer whose length is its tag.
    static func buffer(_ tag: Int) -> AVAudioPCMBuffer {
        let format = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 16_000, channels: 1, interleaved: false)!
        let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(tag))!
        buffer.frameLength = AVAudioFrameCount(tag)
        return buffer
    }

    private final class Tags: @unchecked Sendable {
        private let storage = Mutex<[Int]>([])
        var all: [Int] { storage.withLock { $0 } }
        func add(_ buffer: AVAudioPCMBuffer) { storage.withLock { $0.append(Int(buffer.frameLength)) } }
    }

    @Test func aRouteDeliversToItsOwnHandler() {
        let routes = CaptureRoutes()
        let tags = Tags()
        let route = routes.open { tags.add($0) }
        route.deliver(Self.buffer(1))
        route.deliver(Self.buffer(2))
        #expect(tags.all == [1, 2])
    }

    /// Start A, stop, start B: A's still-installed tap reaches nobody; B's tap reaches B.
    @Test func aTapThatOutlivesItsStopNeverFeedsTheNextStart() {
        let routes = CaptureRoutes()
        let a = Tags()
        let b = Tags()
        let tapA = routes.open { a.add($0) }
        routes.closeCurrent()
        let tapB = routes.open { b.add($0) }

        tapA.deliver(Self.buffer(11))
        tapB.deliver(Self.buffer(22))

        #expect(a.all.isEmpty)
        #expect(b.all == [22])
    }

    /// A start opened over a running one (no stop between) silences the older tap the same way.
    @Test func aNewStartSilencesTheOlderTapWithoutAStop() {
        let routes = CaptureRoutes()
        let a = Tags()
        let b = Tags()
        let tapA = routes.open { a.add($0) }
        let tapB = routes.open { b.add($0) }

        tapA.deliver(Self.buffer(11))
        tapB.deliver(Self.buffer(22))

        #expect(a.all.isEmpty)
        #expect(b.all == [22])
    }

    @Test func aStopSilencesTheRunningTap() {
        let routes = CaptureRoutes()
        let tags = Tags()
        let tap = routes.open { tags.add($0) }
        tap.deliver(Self.buffer(1))
        routes.closeCurrent()
        routes.closeCurrent()
        tap.deliver(Self.buffer(2))
        #expect(tags.all == [1])
    }

    /// The caller-independent half: the capture's tap closure delivers through the route its own
    /// start opened, and no shared mutable handler remains for a tap to read.
    @Test func theMicrophoneTapDeliversThroughItsOwnStartsRoute() throws {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let source = try String(contentsOf: root.appendingPathComponent("TabMail/Services/Dictation/MicrophoneCapture.swift"), encoding: .utf8)
        #expect(source.contains("let route = routes.open(onBuffer)"))
        #expect(source.contains("route.deliver(buffer)"))
        #expect(!source.contains("self?.handler"))
        #expect(!source.contains("self.handler"))
        #expect(source.contains("routes.closeCurrent()"))
    }
}
