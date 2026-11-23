import SwiftUI

/// Starts foreground polling for the screen: the one place the app's screens call
/// `SyncScheduler.startForegroundPolling` (Settings' database reset is the only
/// other caller). That call runs a return's stage 1, starts the 300 s poll timer
/// and starts IMAP IDLE (sync timing promises 4, 5 and 6).
///
/// One condition: the scene is active, at least one account exists, and the app
/// is not in screenshot mode. It is read when the view mounts and again whenever
/// any part of it changes; every change to true starts foreground polling. A
/// change to false does nothing here (RootView's scene-phase handler stops the
/// poll when the app goes to the background).
///
/// Why "when the view mounts" (`initial: true`): `TabMailApp` mounts `RootView`
/// only once the inbox is ready to paint (`AppStartup.isReady`, since v1.6.7). A
/// cold launch in the foreground is already active by then, and `onChange` does
/// not run for the value a view mounts with, so the poll, stage 1 and IDLE waited
/// for the next background-and-return (#1331). Adding the first account while the
/// app is open changed no phase either (#1327).
///
/// Screenshot mode never syncs: its seeded data is the whole content, as
/// RootView's account task and `InboxViewModel.performSync` already say. Demo mode
/// needs no term: the poll path skips sync itself while the demo is on.
///
/// Sync trigger site (a return to the app). Siblings: IMAP IDLE, silent push, the
/// open-app push, the poll's tick, pull-to-refresh. The trigger map and the
/// one-turn-per-account rule are ADR-IOS-104; the stages and the follow-up flag
/// are the sync design block in SyncEngineOneSyncAtATime.swift.
struct ForegroundPollStart: ViewModifier {
    let hasAccounts: Bool
    let screenshotMode: Bool
    let start: @MainActor () -> Void

    @Environment(\.scenePhase) private var scenePhase

    static func wanted(phase: ScenePhase, hasAccounts: Bool, screenshotMode: Bool) -> Bool {
        phase == .active && hasAccounts && !screenshotMode
    }

    func body(content: Content) -> some View {
        content.onChange(
            of: Self.wanted(phase: scenePhase, hasAccounts: hasAccounts, screenshotMode: screenshotMode),
            initial: true
        ) { _, wanted in
            guard wanted else { return }
            start()
        }
    }
}
