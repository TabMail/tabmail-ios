/* This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at https://mozilla.org/MPL/2.0/. */

import Foundation

/// Per-tool-call context carrying the invoking chat session's UI delivery
/// channel. Invocation-scoped — distinct from the construction-scoped
/// `ToolContext` (which holds global deps captured once when tools are built as
/// registry singletons). Threaded from the chat surface down to
/// `AgentTool.execute(arguments:invocation:)` so a confirmation tool delivers
/// its card to the exact session that launched it, not a global slot. See
/// ADR-IOS-053.
struct ToolInvocation: Sendable {
    /// Delivery channel bound to the invoking chat session. `nil` for
    /// non-interactive callers (reply precompute, inline edit, task eval, BYOK
    /// smoke). A confirmation tool invoked with a nil sink fast-fails
    /// (`ok:false`) instead of suspending — see
    /// `AgentToolRouter.ActionConfirmation.awaitConfirmation(..., via:)`.
    let uiSink: (any AgentUISink)?
    /// Invoking session key, for logging/correlation only.
    let sessionKey: String?
    /// Set when the request was sent from the chat's reply field: the email the field replies to
    /// and who the user chose in Reply to, as they were when it was sent (ADR-IOS-114 decision 11).
    /// The agent's reply to that email carries it (`ComposeRequest.fieldReply`); nil for every
    /// other request.
    let fieldReply: ChatFieldReply?
    /// The chat that sent the request, where a compose card the turn asks for opens (ADR-IOS-053
    /// Phase 2): only a screen of that kind showing that chat takes the request. Nil when no screen
    /// can open one; the compose tools then fail fast instead of waiting for a card.
    let composeOrigin: ComposeOrigin?

    init(
        uiSink: (any AgentUISink)? = nil, sessionKey: String? = nil, fieldReply: ChatFieldReply? = nil,
        composeOrigin: ComposeOrigin? = nil
    ) {
        self.uiSink = uiSink
        self.sessionKey = sessionKey
        self.fieldReply = fieldReply
        self.composeOrigin = composeOrigin
    }

    /// The no-UI invocation used by every non-interactive completion caller and
    /// as the `AgentTool` protocol/default fallback.
    static let noninteractive = ToolInvocation(uiSink: nil, sessionKey: nil)
}

/// Where an agent's compose card opens: the chat session that asked, and the kind of screen it was
/// asked on (ADR-IOS-053 Phase 2). Captured as the send starts; the compose tools stamp it on their
/// `AgentToolRouter.ComposeRequest`, and only a pill of that screen kind whose chat holds the session
/// key takes the request (`AgentToolRouter.takeCompose(for:)`). So the card opens on the screen that
/// asked, built by that screen, whichever other screens are mounted.
struct ComposeOrigin: Hashable, Sendable {
    enum Screen: Hashable, Sendable {
        /// The inbox's own chat.
        case inbox
        /// The email screen (`MessageDetailView`).
        case email
        /// The chat view (`ChatThreadView`), whose reply field's choice the card applies.
        case chat
    }

    let sessionKey: String
    let screen: Screen

    /// Why a compose tool invoked with no origin fails fast: no screen could ever take its card,
    /// so it never waits for one (as a confirmation tool with no sink, ADR-IOS-053).
    static let noScreenReason = "no chat screen to open the compose window on"
}

/// MainActor delivery channel owned by exactly one chat session. Replaces the
/// global `AgentToolRouter.pendingAction` slot (ADR-IOS-024): the confirmation
/// flow hands an `ActionConfirmation` to the invoking session's sink, which
/// appends it to that session's message list. Rendered level-triggered by the
/// pill bound to that session — no cross-view race, no edge-triggered
/// `.onChange`. See ADR-IOS-053.
protocol AgentUISink: Sendable {
    @MainActor func deliverConfirmation(_ confirmation: AgentToolRouter.ActionConfirmation)
}

/// Production `AgentUISink` bound to a `ChatPillState.Session`. Holds the session
/// reference captured at send time (not a key — a key re-lookup could resolve a
/// freshly-created empty session if the original was idle-evicted mid-turn,
/// silently dropping the card). `Session` is `@MainActor @Observable`, hence
/// implicitly `Sendable`, so this value type is `Sendable`.
struct SessionUISink: AgentUISink {
    let session: ChatPillState.Session

    @MainActor func deliverConfirmation(_ confirmation: AgentToolRouter.ActionConfirmation) {
        // Appending is SwiftUI-mutation-safe (new rows don't invalidate existing
        // layout) and drives the pill's `ChatBubble` → `ActionConfirmationCard`
        // renderer declaratively. Content is empty; the card IS the row.
        session.chatMessages.append(
            ChatMessage(role: .agent, content: "", timestamp: Date(), actionConfirmation: confirmation)
        )
    }
}
