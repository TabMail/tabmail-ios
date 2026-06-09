/* This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at https://mozilla.org/MPL/2.0/. */

import SwiftUI
import UIKit

/// Reference-counted wrapper around `UIApplication.isIdleTimerDisabled`.
///
/// The idle timer is a single global flag, so holders must be counted —
/// otherwise one view releasing would clobber another view's hold. iOS only
/// honors the flag while the app is foreground; no scenePhase handling is
/// needed (backgrounding locks normally, the hold resumes on return).
@MainActor
enum ScreenKeepAwake {
    private static var count = 0

    static func acquire() {
        count += 1
        UIApplication.shared.isIdleTimerDisabled = true
        if DebugModeManager.isLoggingEnabled() {
            print("[ScreenKeepAwake] acquire (count=\(count))")
        }
    }

    static func release() {
        count = max(0, count - 1)
        if count == 0 {
            UIApplication.shared.isIdleTimerDisabled = false
        }
        if DebugModeManager.isLoggingEnabled() {
            print("[ScreenKeepAwake] release (count=\(count))")
        }
    }
}

/// Keeps the screen from auto-locking while `active` is true.
///
/// Tracks its own held state so acquire/release fire exactly once per
/// transition, regardless of the ordering of `onChange` vs `onDisappear`
/// during view teardown (host views collapse state in their own
/// `onDisappear`, which may or may not reach this view's `onChange`).
private struct KeepScreenAwakeModifier: ViewModifier {
    let active: Bool
    @State private var holding = false

    func body(content: Content) -> some View {
        content
            .onChange(of: active) { _, now in sync(now) }
            .onAppear { sync(active) }
            .onDisappear { sync(false) }
    }

    private func sync(_ shouldHold: Bool) {
        guard shouldHold != holding else { return }
        holding = shouldHold
        if shouldHold {
            ScreenKeepAwake.acquire()
        } else {
            ScreenKeepAwake.release()
        }
    }
}

extension View {
    /// Prevent the screen from auto-locking while `active` is true
    /// (YouTube-style keep-awake, e.g. while the chat pill is expanded,
    /// the agent is working, or dictation is listening).
    func keepScreenAwake(while active: Bool) -> some View {
        modifier(KeepScreenAwakeModifier(active: active))
    }
}
