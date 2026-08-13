/* This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at https://mozilla.org/MPL/2.0/. */

import Testing
import Foundation
@testable import TabMail

@Suite("PushConfig")
struct PushConfigTests {

    @Test("baseURL is https")
    func baseURLIsHTTPS() {
        #expect(PushConfig.baseURL.hasPrefix("https://"))
    }

    @Test("baseURL contains tabmail.ai domain")
    func baseURLDomain() {
        #expect(PushConfig.baseURL.contains("tabmail.ai"))
    }

    @Test("silentPushDeadlineSeconds is under iOS 30s limit")
    func deadlineUnder30s() {
        #expect(PushConfig.silentPushDeadlineSeconds < 30)
        #expect(PushConfig.silentPushDeadlineSeconds > 0)
    }

    @Test("silentPushDeadlineSeconds is 25 (5s headroom)")
    func deadlineIs25() {
        #expect(PushConfig.silentPushDeadlineSeconds == 25)
    }

    @Test("UserDefaults keys are unique")
    func uniqueKeys() {
        let keys = [PushConfig.deviceIdKey, PushConfig.lastDeviceTokenKey, PushConfig.registeredEmailsKey]
        #expect(Set(keys).count == keys.count)
    }

    @Test("UserDefaults keys have push_ prefix")
    func keyPrefix() {
        #expect(PushConfig.deviceIdKey.hasPrefix("push_"))
        #expect(PushConfig.lastDeviceTokenKey.hasPrefix("push_"))
        #expect(PushConfig.registeredEmailsKey.hasPrefix("push_"))
    }
}

/// `PushConfig.apsEnvironment(fromProfileBytes:)` slices the plaintext plist out
/// of the CMS-signed provisioning profile using two bounds that used to be
/// searched INDEPENDENTLY — `<plist` and `</plist>`, both forward. `<plist`
/// cannot match inside `</plist>` (the `/` blocks it), so the two can cross, and
/// a `</plist>` that ENDS before `<plist` begins produced a reversed `Range`,
/// which `String` subscripting TRAPS on: an uncatchable precondition failure.
///
/// ⚠️ **This is NOT a security fix, and the tests should not be read as one.**
/// The input is the app's own `embedded.mobileprovision` inside the signed
/// bundle — not attacker-controlled, and not reachable by any remote party. It
/// is covered only because leaving one member of a defect class unfixed is how
/// the class comes back; the sibling members (`EmlMarker.extractBodyContent`,
/// `EmailHTMLWrapper.unwrapFullHTMLDocument`) DO take sender-authored input.
///
/// The invariant pinned is *for any bytes, the extraction either slices
/// correctly-ordered bounds or returns nil; it never traps.*
@Suite("PushConfig.apsEnvironment — plist bound-pair invariant")
struct PushConfigPlistBoundPairTests {

    struct Shape: CustomStringConvertible, Sendable {
        let name: String
        let raw: String
        /// Every shape here is malformed or non-conforming, so the function must
        /// return nil — the point is that it RETURNS at all.
        var description: String { name }
    }

    static let shapes: [Shape] = [
        // --- close ends before open begins: the reversed-Range family ---
        Shape(name: "close before open, gap wider than the </plist> token",
              raw: "</plist>XXXXXXXX<plist version=\"1.0\"><dict/>"),
        Shape(name: "close before open, long binary-ish preamble",
              raw: "</plist>\u{01}\u{02}\u{03}\u{04}\u{05}\u{06}\u{07}\u{08}<plist><dict/>"),
        // Adjacent is NOT a reversed range — the bounds land equal (8/8), an
        // empty slice. Included because the boundary between "equal" and
        // "reversed" is exactly what a fix must not get wrong.
        Shape(name: "close immediately before open (equal bounds, not reversed)",
              raw: "</plist><plist version=\"1.0\"><dict/>"),

        // --- one bound only ---
        Shape(name: "close only", raw: "</plist>only"),
        Shape(name: "open only", raw: "<plist>only"),
        Shape(name: "neither bound", raw: "no markup at all"),
        Shape(name: "empty", raw: ""),

        // --- multiplicity ---
        Shape(name: "multiple closes", raw: "<plist><dict/></plist></plist>"),
        Shape(name: "multiple opens", raw: "<plist><plist><dict/></plist>"),
    ]

    @Test("Any plist bound-pair shape returns nil and never traps", arguments: shapes)
    func plistBoundPairNeverTraps(shape: Shape) {
        let data = shape.raw.data(using: .isoLatin1) ?? Data()
        // Reaching this line IS the invariant: a reversed Range is a
        // `fatalError`, which Swift Testing cannot catch — a regression kills
        // the test host rather than recording a failure here.
        let out = PushConfig.apsEnvironment(fromProfileBytes: data)
        #expect(out == nil, "\(shape.name): expected nil for malformed input")
    }

    // MARK: - Benign control (a real profile shape must still parse)

    @Test("A well-formed profile still yields its aps-environment")
    func benignProfileStillParses() {
        // Mimics the real file: binary CMS noise on both sides of a plaintext
        // plist. If the bound were mis-placed, this returns nil instead.
        let plist = """
        <plist version="1.0"><dict>\
        <key>Entitlements</key><dict>\
        <key>aps-environment</key><string>development</string>\
        </dict></dict></plist>
        """
        let raw = "\u{30}\u{82}\u{01}CMS-NOISE" + plist + "\u{00}\u{01}trailing"
        let out = PushConfig.apsEnvironment(fromProfileBytes: raw.data(using: .isoLatin1)!)
        #expect(out == "development")
    }

    @Test("A well-formed profile with no aps-environment yields nil")
    func benignProfileWithoutEntitlementYieldsNil() {
        let raw = "NOISE<plist version=\"1.0\"><dict><key>Other</key><string>v</string></dict></plist>TAIL"
        let out = PushConfig.apsEnvironment(fromProfileBytes: raw.data(using: .isoLatin1)!)
        #expect(out == nil)
    }
}
