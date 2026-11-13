import SwiftUI

/// The one "Couldn't undo" notice RootView presents. Two services can each hold
/// a notice: `PendingSendService` (a refused Send Undo) and `UndoService` (a
/// refused move Undo). One is presented at a time, the Send one first, and each
/// source has its own alert (`UndoFailureAlertHost`): when the Send notice is
/// dismissed while a move notice waits, the move host's alert goes from hidden
/// to shown and is presented fresh, instead of not at all.
struct UndoFailureNotice: Identifiable, Equatable {
    /// Which service holds the notice. Each source is its own identity.
    enum Source: String, Equatable, Hashable {
        case send
        case move
    }

    let id: Source
    let message: String

    /// The notice presented now: the Send one when set, otherwise the move one,
    /// otherwise none.
    @MainActor
    static var current: UndoFailureNotice? {
        if let message = PendingSendService.shared.undoFailureMessage {
            return UndoFailureNotice(id: .send, message: message)
        }
        if let message = UndoService.shared.undoFailureMessage {
            return UndoFailureNotice(id: .move, message: message)
        }
        return nil
    }

    /// Ends the notice from `source`, and only that one. A move refusal that
    /// arrived while the Send notice was up stays set, and becomes `current`
    /// next. (A Send notice cannot arrive while the move notice is up: its only
    /// producer is the Send toast's Undo, which the alert covers.)
    @MainActor
    static func dismiss(_ source: Source) {
        switch source {
        case .send:
            PendingSendService.shared.dismissUndoFailure()
        case .move:
            UndoService.shared.dismissUndoFailure()
        }
    }
}

/// Shows the "Couldn't undo" alert for one source's notice. RootView keeps one
/// host per source, always in place; each binding is plain presence: shown
/// while its source's notice is the presented one. A Send notice and a move
/// notice therefore never share one alert, and the move host's binding turns
/// from false to true when the Send notice before it is dismissed, which
/// presents the move alert. Clearing a notice in code turns its host's binding
/// false on a view that stays, which takes the alert down.
struct UndoFailureAlertHost: View {
    let source: UndoFailureNotice.Source

    var body: some View {
        // Read while body runs, so this host observes both notices.
        let notice = UndoFailureNotice.current.flatMap { $0.id == source ? $0 : nil }
        Color.clear
            .allowsHitTesting(false)
            .accessibilityHidden(true)
            // OK has no action of its own: the binding clears this host's
            // notice once per dismissal, never the one waiting behind it.
            .alert("Couldn't undo", isPresented: Binding(
                get: {
                    let shown = UndoFailureNotice.current?.id == source
                    BackgroundSyncLogger.logDebug("[UndoNotice] \(source.rawValue) alert get -> \(shown)")
                    return shown
                },
                set: { newValue in
                    BackgroundSyncLogger.logDebug("[UndoNotice] \(source.rawValue) alert set \(newValue)")
                    if !newValue { UndoFailureNotice.dismiss(source) }
                }
            )) {
                Button("OK", role: .cancel) {}
            } message: {
                Text(notice?.message ?? "")
            }
    }
}
