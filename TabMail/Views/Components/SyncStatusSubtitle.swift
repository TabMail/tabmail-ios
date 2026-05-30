/* This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at https://mozilla.org/MPL/2.0/. */

import SwiftUI

/// Global "UI is frozen" gate used while a system-presented sheet (currently the
/// QuickLook PDF preview in `AttachmentListView`) is on screen. While active,
/// `SyncStatusObservationModifier.refresh` bails — env values don't mutate, so the
/// whole chain that cascades through `MailNavigationView` → navigation destination
/// → `MessageCardView` → `.quickLookPreview`'s UIKit bridge stays quiet. Release
/// triggers one refresh to catch up.
///
/// Driver: `AttachmentListView` calls `begin()` BEFORE presenting the preview and
/// `end()` when the preview dismisses (via `.onChange(of: previewURL)` going nil).
/// Uses `defer` in the download Task to guarantee release on error/cancel paths.
@MainActor @Observable
final class PreviewFreezeGate {
    static let shared = PreviewFreezeGate()
    private(set) var isFrozen = false

    func begin() {
        guard !isFrozen else { return }
        print("[PreviewFreeze] begin")
        isFrozen = true
    }

    func end() {
        guard isFrozen else { return }
        print("[PreviewFreeze] end")
        isFrozen = false
        // Wake any non-Observation consumers (e.g. NotificationCenter-driven VMs)
        // so they can flush buffered work. Observation consumers (SyncStatusObs)
        // wake through the `_ = isFrozen` read in their tracking block.
        NotificationCenter.default.post(name: .previewFreezeReleased, object: nil)
    }
}

extension Notification.Name {
    /// Posted by `PreviewFreezeGate.end()`. Listeners should re-apply any buffered
    /// state that arrived while the gate was active.
    static let previewFreezeReleased = Notification.Name("previewFreezeReleased")
}

/// Computes the sync status string from AccountManagerState.
@MainActor
enum SyncStatusFormatter {
    static func statusText(syncPhase: SyncPhase?, lastSyncCompletedAt: Date?, lastSyncFailed: Bool, now: Date) -> String {
        if let phase = syncPhase {
            return phase.displayText
        }
        guard let lastSync = lastSyncCompletedAt else {
            return "Checking for mail..."
        }
        let elapsed = now.timeIntervalSince(lastSync)
        let minutes = Int(elapsed / 60)
        // After failure, always show "Last updated ..." (never "less than a minute ago")
        if !lastSyncFailed && minutes < 1 {
            return "Updated less than a minute ago"
        }
        let prefix = lastSyncFailed ? "Last updated" : "Updated"
        if minutes < 1 {
            return "\(prefix) less than a minute ago"
        } else if minutes == 1 {
            return "\(prefix) 1 min ago"
        } else if minutes < 60 {
            return "\(prefix) \(minutes) min ago"
        } else {
            let hours = minutes / 60
            return "\(prefix) \(hours)h ago"
        }
    }
}

/// Drives @State bindings from `AccountManagerState` via raw Observation tracking.
///
/// Why a ViewModifier rather than embedding the observation inside a single View:
/// some surfaces (e.g. `.navigationSubtitle(Text)`) only accept a `Text`, not a
/// `View`, so they can't host a child view that owns the state. Hosting the
/// observation as a modifier lets callers keep their own `@State` and pass
/// bindings, while sharing the one observation loop everywhere.
///
/// Why raw Observation: a ToolbarItem-hosted view does not reliably invalidate
/// through the UIKit-backed nav-bar host when an @Observable singleton it reads
/// mutates. Driving local @State from `withObservationTracking` bypasses that
/// quirk — @State mutation always invalidates.
///
/// No throttle: every transition flashes through. SwiftUI's frame coalescing
/// (60fps) is the implicit upper bound. Sub-frame bursts collapse to one render.
struct SyncStatusObservationModifier: ViewModifier {
    @Binding var phase: SyncPhase?
    @Binding var last: Date?
    @Binding var failed: Bool
    @Binding var now: Date
    /// Caller-supplied tag to disambiguate multiple instances in logs (e.g. "Inbox", "Mailboxes").
    let tag: String

    /// Relative-time tick for "Updated N min ago".
    private static let tickSeconds: TimeInterval = 60
    private let minuteTimer = Timer.publish(every: tickSeconds, on: .main, in: .common).autoconnect()

    func body(content: Content) -> some View {
        content
            .task {
                let id = String(UUID().uuidString.prefix(4))
                print("[SyncStatusObs:\(tag):\(id)] task START — seeding from current state")
                refresh(id: id, reason: "seed")
                while !Task.isCancelled {
                    await waitForStatusChange(id: id)
                    refresh(id: id, reason: "wake")
                }
                print("[SyncStatusObs:\(tag):\(id)] task END (cancelled=\(Task.isCancelled))")
            }
            // Immediate catch-up refresh on preview-freeze release. Without this we
            // would still catch up via the observation tracker, but only after a
            // `Task.yield()` hop — user-perceivable as a one-tick stale subtitle at
            // the moment QL dismisses. The observation-path refresh still fires
            // shortly after and is a harmless no-op (reads same current state).
            .onReceive(NotificationCenter.default.publisher(for: .previewFreezeReleased).receive(on: DispatchQueue.main)) { _ in
                refresh(id: "notify", reason: "unfreeze-sync")
            }
            .onReceive(minuteTimer) { now = $0 }
    }

    @MainActor private func refresh(id: String, reason: String) {
        // Preview-freeze gate: while the QL PDF preview is on screen, we hold the
        // env values steady so nothing cascades through the view tree and disturbs
        // QL's UIKit presentation. The waiter below observes `isFrozen` too, so a
        // release will wake us and this refresh will run with current state.
        if PreviewFreezeGate.shared.isFrozen {
            print("[SyncStatusObs:\(tag):\(id)] refresh(\(reason)) SKIPPED — preview frozen")
            return
        }
        let s = AccountManagerState.shared
        let newPhase = s.syncPhase
        let newLast = s.lastSyncCompletedAt
        let newFailed = s.lastSyncFailed
        let phaseStr = newPhase.map { String(describing: $0) } ?? "nil"
        let lastStr = newLast.map { "\(Int(Date().timeIntervalSince($0)))s ago" } ?? "nil"
        let changed = (phase != newPhase) || (last != newLast) || (failed != newFailed)
        print("[SyncStatusObs:\(tag):\(id)] refresh(\(reason)) phase=\(phaseStr) last=\(lastStr) failed=\(newFailed) changed=\(changed)")
        phase = newPhase
        last = newLast
        failed = newFailed
    }

    /// Suspends until any of the three tracked properties on AccountManagerState mutates.
    /// `withObservationTracking`'s onChange fires in the setter's `willSet` window;
    /// we yield once so the new value is observable on the next read.
    @MainActor private func waitForStatusChange(id: String) async {
        await withCheckedContinuation { (cont: CheckedContinuation<Void, Never>) in
            withObservationTracking {
                let s = AccountManagerState.shared
                _ = s.syncPhase
                _ = s.lastSyncCompletedAt
                _ = s.lastSyncFailed
                // Observe the freeze gate so a release wakes us and triggers one
                // catch-up refresh with current state.
                _ = PreviewFreezeGate.shared.isFrozen
            } onChange: {
                print("[SyncStatusObs:\(self.tag):\(id)] onChange fired")
                cont.resume()
            }
        }
        await Task.yield()
    }
}

extension View {
    /// Drives the supplied bindings from AccountManagerState's sync status fields.
    /// Attach ONCE at a stable ancestor (RootView) and fan out via Environment —
    /// this keeps the observation alive across sidebar collapses / NavigationSplitView
    /// column unmounts that would otherwise cancel the .task on subtitle views.
    func observeSyncStatus(
        phase: Binding<SyncPhase?>,
        last: Binding<Date?>,
        failed: Binding<Bool>,
        now: Binding<Date>,
        tag: String = "?"
    ) -> some View {
        modifier(SyncStatusObservationModifier(phase: phase, last: last, failed: failed, now: now, tag: tag))
    }
}

// MARK: - Environment fan-out
//
// RootView attaches `.observeSyncStatus` and publishes the four values via
// environment. Descendant subtitles read them with @Environment and render
// immediately — no per-view .task, no cancellation risk when a column gets
// unmounted. Environment changes reliably invalidate consumers, including
// ToolbarItem and .navigationSubtitle contents.

private struct SyncPhaseKey: EnvironmentKey {
    static let defaultValue: SyncPhase? = nil
}
private struct LastSyncKey: EnvironmentKey {
    static let defaultValue: Date? = nil
}
private struct SyncFailedKey: EnvironmentKey {
    static let defaultValue: Bool = false
}
private struct SyncNowKey: EnvironmentKey {
    // Computed so the fallback is "now" at read time, not frozen at type-init.
    // Otherwise a process that reads the default long after app start (or a test
    // run where type init happened far earlier) sees a stale Date.
    static var defaultValue: Date { Date() }
}

extension EnvironmentValues {
    var syncPhase: SyncPhase? {
        get { self[SyncPhaseKey.self] }
        set { self[SyncPhaseKey.self] = newValue }
    }
    var lastSync: Date? {
        get { self[LastSyncKey.self] }
        set { self[LastSyncKey.self] = newValue }
    }
    var syncFailed: Bool {
        get { self[SyncFailedKey.self] }
        set { self[SyncFailedKey.self] = newValue }
    }
    var syncNow: Date {
        get { self[SyncNowKey.self] }
        set { self[SyncNowKey.self] = newValue }
    }
}

extension View {
    /// Publish the sync-status values to the environment. Attach at the root of
    /// any tree whose descendants render sync-status text.
    func publishSyncStatusEnvironment(phase: SyncPhase?, last: Date?, failed: Bool, now: Date) -> some View {
        self
            .environment(\.syncPhase, phase)
            .environment(\.lastSync, last)
            .environment(\.syncFailed, failed)
            .environment(\.syncNow, now)
    }
}

/// Styled sync status subtitle for inline navigation bar use (InboxView toolbar).
///
/// Takes explicit parameters rather than reading @Environment internally. The
/// parent view (InboxView) reads @Environment at struct level and passes the
/// four values here. This matters because @Environment reads performed *inside*
/// a `ToolbarItem`-hosted subview do not reliably invalidate through UIKit's
/// `UINavigationBar` bridge — the re-render lands eventually (on the next
/// unrelated relayout) but appears "stale for a while". Reading env at the
/// parent's struct level forces the parent's body to re-run on env changes,
/// which re-invokes the `.toolbar { ... }` content closure and installs the
/// fresh subtitle — this path is reliably picked up by UIKit.
struct SyncStatusSubtitle: View {
    let phase: SyncPhase?
    let last: Date?
    let failed: Bool
    let now: Date

    var body: some View {
        Text(SyncStatusFormatter.statusText(syncPhase: phase, lastSyncCompletedAt: last, lastSyncFailed: failed, now: now))
            .font(.caption2)
            .foregroundStyle(.secondary)
            .lineLimit(1)
            .truncationMode(.tail)
            .frame(maxWidth: .infinity, alignment: .leading)
    }
}
