/* This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at https://mozilla.org/MPL/2.0/. */

import SwiftUI
import Contacts
import GRDB
import PhotosUI
import TipKit
import UniformTypeIdentifiers

/// PORT — the v2final `ComposeDraftGuards` fail-closed family
/// (`v2final:TabMail/Views/Compose/ComposeView.swift`), carrying the decisions
/// this forward-port's compose load / save / send / close paths exercise.
///
/// Pure, testable decision seams: deliberately free of any SwiftUI or DB
/// dependency so the reopen / save / send / close fail-closed invariants can be
/// pinned without the live compose UI (Testing Rule 12).
enum ComposeDraftGuards {
    /// PORT — `v2final:ComposeDraftGuards.ReadState`.
    ///
    /// Outcome of a `Draft.fetchOne` on a compose path. A THROWN read (DB
    /// suspended on foreground / lock contention) is `.error` — categorically
    /// distinct from a genuine `.notFound` (nil) — and blocks EVERY mutation (no
    /// delete, no overwrite, no insert): the real draft merely failed to load and
    /// must never be deleted or clobbered because of it. **A thrown read is NOT
    /// absence.**
    enum ReadState: Equatable { case loaded, notFound, error }

    static func readState(_ result: Result<Draft?, Error>) -> ReadState {
        switch result {
        case .failure: return .error
        case .success(let draft): return draft == nil ? .notFound : .loaded
        }
    }

    /// PORT — `v2final:ComposeDraftGuards.effectiveMutationState`. The STICKY
    /// firewall: a failed INITIAL load (the compose never saw the existing draft)
    /// blocks every later mutation regardless of a later successful per-op read.
    static func effectiveMutationState(initialLoad: ReadState, perOp: ReadState) -> ReadState {
        initialLoad == .error || perOp == .error ? .error : perOp
    }

    /// PORT — `v2final:ComposeDraftGuards.hasContent`.
    ///
    /// Whether the compose holds ANY user content. Counts Cc/Bcc (not just To)
    /// AND the uncommitted in-progress recipient inputs, so a bodyless draft whose
    /// only content is a Cc address, a Bcc address, or a half-typed recipient is
    /// NOT read as empty and silently deleted on close.
    static func hasContent(
        subject: String, body: String,
        to: [String], cc: [String], bcc: [String],
        toInput: String, ccInput: String, bccInput: String,
        hasAttachments: Bool
    ) -> Bool {
        if !subject.isEmpty || !body.isEmpty || hasAttachments { return true }
        return !to.isEmpty || !cc.isEmpty || !bcc.isEmpty
            || !toInput.trimmingCharacters(in: .whitespaces).isEmpty
            || !ccInput.trimmingCharacters(in: .whitespaces).isEmpty
            || !bccInput.trimmingCharacters(in: .whitespaces).isEmpty
    }

    /// PORT — `v2final:ComposeDraftGuards.CloseAction`.
    enum CloseAction: Equatable {
        case promptSave        // unsaved changes → Save/Discard/Cancel prompt
        case dismiss           // nothing to persist / read-error → dismiss, no mutation
        case deleteThenDismiss // brand-new / absent empty draft → safe to delete on close
        case promptDelete      // loaded EXISTING draft cleared to nothing → confirm before delete
    }

    /// PORT — `v2final:ComposeDraftGuards.closeAction`.
    static func closeAction(readState: ReadState, hasContent: Bool, hasChanges: Bool) -> CloseAction {
        // .error blocks EVERY mutation — never delete/overwrite a draft that
        // merely failed to load. Dismiss, leaving the row intact.
        if readState == .error { return .dismiss }
        if hasContent && hasChanges { return .promptSave }
        if !hasContent {
            // Emptied to nothing: a LOADED existing row must PROMPT before delete
            // (never silently vanish a "clear everything" edit); a genuinely
            // absent / new draft is delete-eligible.
            return readState == .loaded ? .promptDelete : .deleteThenDismiss
        }
        return .dismiss // hasContent && !hasChanges
    }

    /// PORT — `v2final:ComposeDraftGuards.saveMayMutate`.
    ///
    /// Save-path preflight. `false` = FAIL CLOSED: a thrown read means the current
    /// on-disk state is unknown, so perform NO attachment-dir mutation and NO
    /// save-merge (which would clobber stored edit history / server linkage with a
    /// snapshot built from a read that never saw them). A genuine nil (absent) or a
    /// successful read may proceed — so an ordinary save the user asked for is
    /// never blocked by this guard.
    static func saveMayMutate(readState: ReadState) -> Bool {
        readState != .error
    }

    /// PORT — `v2final:ComposeDraftGuards.discardMayDelete`.
    ///
    /// Whether the discard path may delete the local draft. A THROWN metadata read
    /// means we cannot recover the server-draft identity for the remote cleanup;
    /// deleting locally anyway would leave the server copy to RE-SYNC and reappear.
    /// So on `.error` DEFER the discard (do not delete); a genuine nil / loaded row
    /// may proceed.
    static func discardMayDelete(readState: ReadState) -> Bool {
        readState != .error
    }

    /// PORT — `v2final:ComposeDraftGuards.committedRecipients`.
    ///
    /// Commit a pending (uncommitted) recipient input into its token array — the
    /// same "flush the in-progress text" transform `send()` applies inline — so
    /// close / save also SEE and PERSIST an in-progress recipient instead of
    /// dropping it. Empty / whitespace-only input leaves the tokens unchanged.
    static func committedRecipients(tokens: [String], input: String) -> [String] {
        let trimmed = input.trimmingCharacters(in: .whitespaces)
        return trimmed.isEmpty ? tokens : tokens + [trimmed]
    }

    /// PORT — `v2final:ComposeDraftGuards.runCheckedLocalDeleteThenDismiss` (R5).
    ///
    /// The CHECKED "local delete then dismiss" contract shared by every draft-close
    /// delete path. The local delete is CHECKED — `dismiss` runs ONLY when the
    /// delete SUCCEEDS. On a THROWN delete (DB busy / suspended) `onDeleteFailure`
    /// surfaces the error and the compose is KEPT OPEN: never dismiss-and-lose a
    /// draft that merely failed to delete locally.
    @MainActor
    static func runCheckedLocalDeleteThenDismiss(
        delete: () async throws -> Void,
        dismiss: () -> Void,
        onDeleteFailure: (Error) -> Void
    ) async {
        do {
            try await delete()
            dismiss()
        } catch {
            onDeleteFailure(error)
        }
    }

    /// PORT — `v2final:ServerDraftOpen.mayBindPersistedDraft` (commits `a8eb813b5`,
    /// `69a9bae88`), relocated here because this forward-port has no
    /// `ServerDraftOpen` enum.
    ///
    /// A successfully loaded persisted `Draft` may bind ONLY to the exact account
    /// that owns that row. There is no accounts-first, reply-derived or
    /// caller-snapshot fallback: binding a draft to a foreign account would send
    /// from the wrong address and queue the server draft into the wrong mailbox.
    static func mayBindPersistedDraft(draftAccountId: String, resolvedAccountId: String?) -> Bool {
        resolvedAccountId == draftAccountId
    }

    /// PORT — `v2final:ComposeDraftGuards.outboundQuoteBody(confirmedBodyHTML:capturedSnippet:)`
    /// (its C-FIX-1).
    ///
    /// The OUTBOUND quote body for a reply/forward. ONLY a positively
    /// identity-confirmed body (from `Draft.resolveReplyQuote`) may populate it.
    /// When there is no confirmed body the quote is OMITTED — the captured
    /// `MessageHeader.snippet` must NEVER enter the outbound message, because it is
    /// a *cached preview of whatever row the PK pointed at* and so bypasses the
    /// impostor guard entirely. The snippet is accepted as a parameter precisely to
    /// make its NON-use explicit and testable rather than invisible.
    static func outboundQuoteBody(confirmedBodyHTML: String?, capturedSnippet: String) -> String? {
        confirmedBodyHTML
    }

    /// ⚑ NO REFERENCE — INVENTED **shape**; the BEHAVIOUR is a PORT of
    /// `v2final:ComposeView.saveDraftAndDismiss`'s post-commit `switch saveResult`
    /// (F0d), which consumed `v2final:DraftStore.SaveResult.applied(previousDir:)`.
    ///
    /// This forward-port's `DraftStore.SaveResult` is a bare `.applied` /
    /// `.notApplied` and `DraftStore` is outside this change's scope, so the
    /// superseded directory is carried by the CALLER (read fail-closed from the row
    /// before the save) instead of being returned from inside the write
    /// transaction, and the disposition is decided by this pure function.
    ///
    /// The invariant is identical to the reference's: files are destroyed ONLY
    /// after the database has durably committed, and the directory destroyed is
    /// never the one the durable row now points at.
    enum AttachmentDisposition: Equatable {
        /// The save COMMITTED and the row now points at the staging dir (or at nil
        /// for a drop-all). The SUPERSEDED dir may be destroyed. Never emitted when
        /// it equals the dir the row adopted.
        case deleteSuperseded(dirName: String)
        /// The save did NOT adopt our snapshot (a newer snapshot won, or the write
        /// threw/rolled back). Destroy ONLY our own orphaned staging dir — NEVER
        /// the live dir, which the winner is still using.
        case deleteStaging(dirName: String)
        /// Nothing to destroy. Deliberately NOT spelled `none`: a bare `.none` in a
        /// `switch` over this type is ambiguous with `Optional.none` (a repeat trap
        /// in this codebase).
        case noCleanup
    }

    /// The post-save attachment-directory disposition. `stagingDir` is the fresh
    /// copy-on-write dir this save wrote (nil when the save carries no
    /// attachments); `previousDir` is the dir the row held BEFORE the save.
    static func attachmentDisposition(
        saveApplied: Bool, stagingDir: String?, previousDir: String?
    ) -> AttachmentDisposition {
        guard saveApplied else {
            // Not adopted: our staging dir is an orphan; the live dir is untouched.
            guard let stagingDir else { return .noCleanup }
            return .deleteStaging(dirName: stagingDir)
        }
        // Committed: the row now points at `stagingDir` (or nil). Anything the row
        // held before is superseded — unless it IS what the row now points at,
        // which `newStagingDirName()`'s fresh UUID makes impossible but which is
        // checked anyway so this can never destroy the live dir.
        guard let previousDir, previousDir != stagingDir else { return .noCleanup }
        return .deleteSuperseded(dirName: previousDir)
    }
}

struct ComposeView: View {
    /// Immutable authored values captured in one MainActor turn immediately
    /// before the agent-vs-Send claim. No live compose field is read afterward.
    private struct AuthoredSendSnapshot {
        let account: Account
        let draftId: String
        let instanceEpoch: String
        let to: [String]
        let cc: [String]
        let bcc: [String]
        let subject: String
        let authoredBody: String
        let attachments: [DraftAttachment]
        let replyToHeaderId: String?
        /// T5.8 — the reply target's PROVIDER id and observed UIDVALIDITY, captured
        /// in the SAME MainActor turn as `replyToHeaderId` so the durable address
        /// stamp can never describe a different message than the PK beside it.
        let replyToProviderMessageId: String?
        let replyToUidValidity: Int?
        let isForward: Bool
        let outbound: DraftMessage
    }
    @State private var toTokens: [String] = []
    @State private var ccTokens: [String] = []
    @State private var bccTokens: [String] = []
    @State private var toDisplayNames: [String: String] = [:]
    @State private var ccDisplayNames: [String: String] = [:]
    @State private var bccDisplayNames: [String: String] = [:]
    @State private var toInput = ""
    @State private var ccInput = ""
    @State private var bccInput = ""
    /// Identifies the chip currently revealing its full email address, as
    /// "<field>:<token>" (e.g. "to:alice@example.com"). nil means no chip is
    /// revealed. Shared across To/Cc/Bcc so only one chip reveals at a time;
    /// cleared when any text field is tapped so tap-anywhere-else hides it.
    @State private var revealedChipKey: String?
    @State private var subject = ""
    @State private var messageBody = ""
    @State private var showCc = false
    @State private var isSending = false
    @State private var sendError: String?
    @State private var contactSearch = ContactSearchService()
    @State private var activeField: ComposeField?
    @State private var chatExpanded = false
    @State private var quotedAttribution: String?
    @State private var quotedHTML: String?
    @State private var selectedAccount: Account?
    @State private var currentSignature = ""
    @State private var showFromPicker = false
    @State private var attachments: [DraftAttachment] = []
    @State private var photoPickerItems: [PhotosPickerItem] = []
    @State private var showPhotoPicker = false
    @State private var showFilePicker = false
    @State private var showCamera = false
    @State private var showingSuggestion = false
    @State private var currentSuggestion: String?
    @State private var isRecomputing = false
    @State private var isApplyingEdit = false
    @State private var aiWorking = false
    @State private var agentToast: String?
    @State private var agentToastDismiss: Task<Void, Never>?
    @State private var bodyBlink = false
    @State private var draftId: String = UUID().uuidString
    /// PORT — every save entry point in this compose instance shares one
    /// predecessor cursor (v2final `ComposeGenerationCursor`).
    @State private var admissionCursor = ComposeGenerationCursor(
        newEpoch: UUID().uuidString, initialExpectedPredecessor: nil)
    /// ⚑ NO REFERENCE — INVENTED minimum agent-vs-Send fence.
    @State private var agentSendFence = ComposeAgentSendFence()
    /// Per-instance identity token for diagnosing the black-screen-on-second-edit
    /// bug: a genuinely NEW SwiftUI identity gets a fresh token (a persisted
    /// `@State` default only "sticks" on first attach for that identity); a
    /// re-render of the SAME identity keeps the same token. Correlate with the
    /// onAppear/onDisappear pairs in logmain.log to distinguish "recreated struct,
    /// same identity" from "SwiftUI tore down and recreated the identity" (e.g.
    /// from a drafts-folder header rekey while this ComposeView is on-screen).
    @State private var instanceToken = String(UUID().uuidString.prefix(6))
    /// Cancelled/replaced whenever `isApplyingEdit` flips; detects a fade-in that
    /// never completes (the black-screen symptom: `isApplyingEdit` stuck `true`
    /// keeps the editor at opacity 0 indefinitely). Logging only.
    @State private var stuckFadeWatchTask: Task<Void, Never>?
    @State private var showDiscardPrompt = false
    /// PORT — v2final `ComposeView.showClearedDraftDeletePrompt` (N2), the
    /// confirmation for `ComposeDraftGuards.CloseAction.promptDelete`: a LOADED
    /// existing draft the user emptied to nothing. Closing must never make that row
    /// silently vanish — the user is asked first.
    @State private var showClearedDraftDeletePrompt = false
    @State private var showEmptyBodyPrompt = false
    @State private var isSavingDraft = false
    @State private var loadedDraft = false
    /// PORT — sticky initial-read state from v2final ComposeDraftGuards.
    /// `.error` is never reinterpreted as genuine absence later in this view.
    @State private var draftReadState: ComposeDraftGuards.ReadState = .notFound
    /// PORT — v2final `ComposeView.attachmentLoadFailed` (B1, commit `d2f0c96a3`).
    /// Set when the draft's attachments could not be loaded (fail-closed loader).
    /// While true, Send and save-to-server are BLOCKED so we never send/persist a
    /// silent subset of the user's attachments, and close never DELETES the row.
    /// Cleared only by a successful reload (reopen), never by proceeding with a
    /// partial set.
    @State private var attachmentLoadFailed = false
    /// Snapshot of draft state at load time — used to detect actual changes for "Save?" prompt
    @State private var initialSubject = ""
    @State private var initialBody = ""
    @State private var initialToTokens: [String] = []
    @State private var initialCcTokens: [String] = []
    @State private var initialBccTokens: [String] = []
    /// Fingerprint of initial attachments for hasChanges detection. Comparing
    /// full Data blobs would be slow for large attachments, so we use a cheap
    /// summary (count + filename + size per attachment).
    @State private var initialAttachmentsFingerprint: [String] = []
    @FocusState private var bodyFocused: Bool
    @Environment(\.dismiss) private var dismiss
    @Environment(NavigationStore.self) private var navigationStore
    @Environment(\.hasTabMailSession) private var hasTabMailSession

    var replyTo: MessageHeader?
    var suggestedBody: String?
    var account: Account?
    var isForward: Bool = false
    var prefillTo: [String]?
    var prefillCc: [String]?
    var prefillBcc: [String]?
    var prefillSubject: String?
    var prefillBody: String?
    /// Pre-seeded attachments. Used by the Undo-Send reopen path
    /// (PendingSendService.undo) to restore attachments the user had when
    /// they tapped Send.
    var prefillAttachments: [DraftAttachment]?
    /// When true, the initial-state snapshot is taken BEFORE prefill values
    /// are applied, so any prefilled content counts as "unsaved changes" in
    /// closeCompose. This makes the Undo-Send reopen flow naturally ask the
    /// user to save the draft on close — they just undid a send and likely
    /// want to either re-edit or discard, not silently lose content.
    var prefillTreatAsUnsavedChanges: Bool = false
    /// When set, uses this draftId instead of generating a new one.
    /// Used by DraftComposeLoader to reopen an existing draft.
    var prefillDraftId: String?
    /// Exact locally-authored server-draft authority carried through loader and
    /// presenter. The inner compose repeats it after its own Draft read.
    var openAuthority: LocallyAuthoredDraftOpenAuthority?
    /// PORT — process-local Undo reopens only the retained exact Draft
    /// owner/generation reconstructed before confirmed Outbox cancellation.
    var retainedDraftAuthority: PendingSendService.RetainedDraftAuthority?
    /// Fires when the user either sends, fails to persist, or dismisses —
    /// exactly once per compose session, via `ComposeOutcomeState.tryResolve`
    /// upstream. Non-agent compose entry points leave this `nil` and the
    /// calls below become no-ops.
    var onAgentOutcome: (@MainActor (ComposeOutcome) -> Void)? = nil

    /// Custom init purely to log struct construction (diagnostic for the
    /// black-screen-on-second-edit bug — distinguishes "SwiftUI reconstructed the
    /// value struct" from "SwiftUI recreated the identity", the latter visible via
    /// a fresh `instanceToken` at the next `.onAppear`). Mirrors the compiler-
    /// synthesized memberwise init exactly (same params/defaults as the stored
    /// properties above); every `@State` property below keeps its own default.
    init(
        replyTo: MessageHeader? = nil,
        suggestedBody: String? = nil,
        account: Account? = nil,
        isForward: Bool = false,
        prefillTo: [String]? = nil,
        prefillCc: [String]? = nil,
        prefillBcc: [String]? = nil,
        prefillSubject: String? = nil,
        prefillBody: String? = nil,
        prefillAttachments: [DraftAttachment]? = nil,
        prefillTreatAsUnsavedChanges: Bool = false,
        prefillDraftId: String? = nil,
        openAuthority: LocallyAuthoredDraftOpenAuthority? = nil,
        retainedDraftAuthority: PendingSendService.RetainedDraftAuthority? = nil,
        onAgentOutcome: (@MainActor (ComposeOutcome) -> Void)? = nil
    ) {
        self.replyTo = replyTo
        self.suggestedBody = suggestedBody
        self.account = account
        self.isForward = isForward
        self.prefillTo = prefillTo
        self.prefillCc = prefillCc
        self.prefillBcc = prefillBcc
        self.prefillSubject = prefillSubject
        self.prefillBody = prefillBody
        self.prefillAttachments = prefillAttachments
        self.prefillTreatAsUnsavedChanges = prefillTreatAsUnsavedChanges
        self.prefillDraftId = prefillDraftId
        self.openAuthority = openAuthority
        self.retainedDraftAuthority = retainedDraftAuthority
        self.onAgentOutcome = onAgentOutcome
        if DebugModeManager.isLoggingEnabled() {
            print("[ComposeView] init: prefillDraftId=\(prefillDraftId ?? "nil") replyTo=\(replyTo?.stableId ?? "nil") isForward=\(isForward)")
        }
    }

    /// Defense against any path that destroys the view without firing
    /// `.onDisappear` — SwiftUI doesn't formally guarantee `.onDisappear`
    /// fires in every edge case (memory-pressure view reclamation,
    /// unexpected hierarchy tear-downs). If the tracker's `deinit` runs
    /// without `.onDisappear` having cleared the flag, the fallback fires
    /// `.cancelled` + `composePresentationDidEnd()` on the MainActor so the
    /// agent continuation never hangs. Always safe — `tryResolve` + the
    /// `didEndPresentationScope` flag make duplicate calls no-ops.
    @State private var lifecycleTracker = ComposeLifecycleTracker()

    private var dbPool: PrioritizedDatabase { AppDatabase.dbPool }

    private enum ComposeField {
        case to, cc, bcc, body
    }

    private var resolvedAccount: Account? {
        if let selected = selectedAccount { return selected }
        if let acct = account { return acct }
        if let replyTo {
            return try? dbPool.read { db in try Account.fetchOne(db, key: replyTo.accountId) }
        }
        return nil
    }

    // MARK: - Recipient cap
    /// Total recipients across To + Cc + Bcc. Tokens only; pending input text
    /// is NOT counted (still unresolved).
    private var totalRecipients: Int {
        toTokens.count + ccTokens.count + bccTokens.count
    }
    private var canAddRecipient: Bool {
        totalRecipients < SyncConfig.outboxMaxRecipients
    }

    /// Dedup-aware append: if `email` (case-insensitive) already exists in
    /// `tokens`, the existing entry is removed and a fresh one is appended at
    /// the end — this "moves" the duplicate to the new position the user is
    /// adding to, instead of creating two chips. The recipient cap is only
    /// enforced for genuinely-new additions; moves don't change the count.
    private func addRecipient(
        _ email: String,
        name: String?,
        tokens: inout [String],
        displayNames: inout [String: String]
    ) {
        let key = email.lowercased()
        let isMove = tokens.contains { $0.lowercased() == key }
        guard isMove || canAddRecipient else { return }
        tokens.removeAll { $0.lowercased() == key }
        tokens.append(email)
        if let name, !name.isEmpty { displayNames[email] = name }
    }

    /// Shown next to the Cc/Bcc button: "N/50" when ≥ 45, orange at cap.
    /// Extracted from body to keep the view expression inside SwiftUI's
    /// type-checker budget.
    @ViewBuilder
    private var recipientCounter: some View {
        if totalRecipients >= SyncConfig.outboxMaxRecipientsWarnThreshold {
            Text("\(totalRecipients)/\(SyncConfig.outboxMaxRecipients)")
                .font(.caption2)
                .monospacedDigit()
                .foregroundStyle(canAddRecipient ? Color.secondary : Color.orange)
        }
    }

    private let headerHeight: CGFloat = 66
    @State private var pillAppeared = false

    var body: some View {
        NavigationStack {
            ZStack(alignment: .top) {
                // Layer 1: Fields content with header spacer
                VStack(spacing: 0) {
                    Spacer().frame(height: headerHeight)
                    Divider()

                    // Demo notice — mock provider keeps the message local.
                    // Surface this so the user knows
                    // tapping send won't actually email anyone.
                    if DemoModeStore.shared.isActive {
                        HStack(spacing: 6) {
                            Image(systemName: "info.circle.fill")
                                .font(.caption)
                                .foregroundStyle(Theme.accent)
                            Text("Demo inbox — sending stays on your device, no email is delivered.")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.horizontal, 14)
                        .padding(.vertical, 6)
                        .background(Theme.accent.opacity(0.06))
                        Divider()
                    }

                    ScrollView {
                        VStack(alignment: .leading, spacing: 0) {
                            // From field (only when multiple accounts)
                            if navigationStore.accounts.count > 1 {
                                HStack(spacing: 4) {
                                    Text("From:")
                                        .font(.subheadline)
                                        .foregroundStyle(.secondary)
                                    fromPickerButton
                                }
                                .padding(.horizontal, 12)
                                .padding(.vertical, 6)
                                Divider().padding(.leading, 40)
                            }

                            // To field + Cc toggle
                            HStack(alignment: .firstTextBaseline, spacing: 4) {
                                Text("To:")
                                    .font(.subheadline)
                                    .foregroundStyle(.secondary)
                                TokenField(
                                    tokens: $toTokens,
                                    input: $toInput,
                                    displayNames: toDisplayNames,
                                    searchResults: activeField == .to ? contactSearch.search(toInput) : [],
                                    onFocus: { activeField = .to },
                                    onSelectContact: { contact in
                                        addRecipient(
                                            contact.email,
                                            name: contact.name,
                                            tokens: &toTokens,
                                            displayNames: &toDisplayNames
                                        )
                                        toInput = ""
                                    },
                                    canAddMore: { canAddRecipient },
                                    revealedChipKey: $revealedChipKey,
                                    fieldKey: "to"
                                )
                                recipientCounter
                                Button {
                                    withAnimation { showCc.toggle() }
                                } label: {
                                    Text("Cc/Bcc")
                                        .font(.caption)
                                        .foregroundStyle(Theme.accent)
                                }
                            }
                            .padding(.horizontal, 12)
                            .padding(.vertical, 6)
                            Divider().padding(.leading, 40)

                            // Cc field
                            if showCc {
                                HStack(alignment: .firstTextBaseline, spacing: 4) {
                                    Text("Cc:")
                                        .font(.subheadline)
                                        .foregroundStyle(.secondary)
                                    TokenField(
                                        tokens: $ccTokens,
                                        input: $ccInput,
                                        displayNames: ccDisplayNames,
                                        searchResults: activeField == .cc ? contactSearch.search(ccInput) : [],
                                        onFocus: { activeField = .cc },
                                        onSelectContact: { contact in
                                            addRecipient(
                                                contact.email,
                                                name: contact.name,
                                                tokens: &ccTokens,
                                                displayNames: &ccDisplayNames
                                            )
                                            ccInput = ""
                                        },
                                        canAddMore: { canAddRecipient },
                                        revealedChipKey: $revealedChipKey,
                                        fieldKey: "cc"
                                    )
                                }
                                .padding(.horizontal, 12)
                                .padding(.vertical, 6)
                                Divider().padding(.leading, 40)

                                // Bcc field
                                HStack(alignment: .firstTextBaseline, spacing: 4) {
                                    Text("Bcc:")
                                        .font(.subheadline)
                                        .foregroundStyle(.secondary)
                                    TokenField(
                                        tokens: $bccTokens,
                                        input: $bccInput,
                                        displayNames: bccDisplayNames,
                                        searchResults: activeField == .bcc ? contactSearch.search(bccInput) : [],
                                        onFocus: { activeField = .bcc },
                                        onSelectContact: { contact in
                                            addRecipient(
                                                contact.email,
                                                name: contact.name,
                                                tokens: &bccTokens,
                                                displayNames: &bccDisplayNames
                                            )
                                            bccInput = ""
                                        },
                                        canAddMore: { canAddRecipient },
                                        revealedChipKey: $revealedChipKey,
                                        fieldKey: "bcc"
                                    )
                                }
                                .padding(.horizontal, 12)
                                .padding(.vertical, 6)
                                Divider().padding(.leading, 40)
                            }

                            // Subject field
                            HStack(spacing: 4) {
                                Text("Subject:")
                                    .font(.subheadline)
                                    .foregroundStyle(.secondary)
                                TextField("", text: $subject)
                                    .onTapGesture {
                                        activeField = nil
                                        revealedChipKey = nil
                                    }
                            }
                            .padding(.horizontal, 12)
                            .padding(.vertical, 6)

                            Divider()

                            // Body + suggestion bubble + signature + quoted original
                            if showingSuggestion, let suggested = currentSuggestion, !suggested.isEmpty {
                                suggestionBubble(text: suggested)
                                    .transition(.scale(scale: 0.96).combined(with: .opacity))
                            } else {
                                TextEditor(text: $messageBody)
                                    .scrollDisabled(true)
                                    .scrollContentBackground(.hidden)
                                    .frame(minHeight: 60)
                                    .padding(.horizontal, 12)
                                    .padding(.top, 4)
                                    .focused($bodyFocused)
                                    .onTapGesture {
                                        activeField = .body
                                        revealedChipKey = nil
                                    }
                                    .opacity(isApplyingEdit ? 0 : (bodyBlink ? 0.35 : 1))

                            }

                            // Signature above quote (default)
                            if !currentSignature.isEmpty && !sigBelowQuote {
                                signatureView
                            }

                            // Quoted original message with blockquote styling
                            if let attribution = quotedAttribution, let html = quotedHTML {
                                Text(attribution)
                                    .font(.caption)
                                    .foregroundStyle(Color.blue.opacity(0.55))
                                    .padding(.horizontal, 16)
                                    .padding(.top, 20)

                                HStack(alignment: .top, spacing: 0) {
                                    RoundedRectangle(cornerRadius: 1.5)
                                        .fill(Color.blue.opacity(0.55))
                                        .frame(width: 3)
                                    AutoSizingHTMLView(html: html)
                                        .padding(.leading, 4)
                                }
                                .padding(.horizontal, 12)
                                .padding(.top, 4)
                                .padding(.bottom, 20)
                            }

                            // Signature below quote
                            if !currentSignature.isEmpty && sigBelowQuote {
                                signatureView
                            }
                        }
                        .background(DisableAutoScrollToVisible())
                    }
                    .scrollDismissesKeyboard(.immediately)

                    // Attachment chips — one per row, X on the left (so the
                    // floating paperclip bubble at bottom-right can't occlude
                    // the delete target). Middle-truncate filenames so the chip
                    // never exceeds the available width.
                    if !attachments.isEmpty {
                        Divider()
                        VStack(spacing: 6) {
                            ForEach(Array(attachments.enumerated()), id: \.offset) { index, attachment in
                                HStack(spacing: 6) {
                                    Button {
                                        attachments.remove(at: index)
                                    } label: {
                                        Image(systemName: "xmark.circle.fill")
                                            .font(.caption)
                                            .foregroundStyle(.secondary)
                                    }
                                    .buttonStyle(.plain)
                                    Image(systemName: "doc")
                                        .font(.caption2)
                                    Text(attachment.filename)
                                        .font(.caption)
                                        .lineLimit(1)
                                        .truncationMode(.middle)
                                        .frame(maxWidth: .infinity, alignment: .leading)
                                }
                                .padding(.horizontal, 10)
                                .padding(.vertical, 5)
                                .background(Color(.systemGray5))
                                .clipShape(Capsule())
                            }
                        }
                        .padding(.leading, 12)
                        .padding(.trailing, 80) // clear the floating paperclip bubble
                        .padding(.vertical, 6)
                    }
                }

                // Layer 2: Close/Send — below chat when expanded
                HStack {
                    Button("Close") { Task { await closeCompose() } }
                        .font(.subheadline)
                    Spacer()
                    if isSending {
                        ProgressView()
                    } else {
                        Button("Send") { trySend() }
                            .font(.subheadline)
                            .fontWeight(.semibold)
                            // B1: block Send while attachments failed to load —
                            // never send a silent subset of the user's files.
                            .disabled(toTokens.isEmpty || subject.isEmpty || attachmentLoadFailed)
                    }
                }
                .padding(.horizontal, 16)
                .frame(height: headerHeight, alignment: .center)
                .animation(nil, value: chatExpanded)

                // Layer 3: Floating attachment bubble (bottom-right, persistent)
                if !chatExpanded {
                    VStack {
                        Spacer()
                        HStack {
                            Spacer()
                            Menu {
                                Button { showPhotoPicker = true } label: {
                                    Label("Photos", systemImage: "photo")
                                }
                                Button { showFilePicker = true } label: {
                                    Label("Files", systemImage: "folder")
                                }
                                Button { showCamera = true } label: {
                                    Label("Camera", systemImage: "camera")
                                }
                            } label: {
                                Image(systemName: "paperclip")
                                    .font(.title3)
                                    .fontWeight(.medium)
                                    .foregroundStyle(.primary)
                                    .frame(width: 56, height: 56)
                                    .contentShape(Circle())
                                    .glassEffect(.regular.interactive(), in: .circle)
                            }
                            .tint(.primary)
                        }
                        .padding(.trailing, 16)
                        .padding(.bottom, 16)
                    }
                }

                // Layer 4: Scrim when chat expanded
                if chatExpanded {
                    Color.black.opacity(0.3)
                        .ignoresSafeArea()
                        .onTapGesture {
                            withAnimation(.spring(response: 0.45, dampingFraction: 0.82)) {
                                chatExpanded = false
                            }
                        }
                        .transition(.opacity)
                }

                // Layer 5: DynamicIslandChat — on top when expanded, ignores keyboard
                VStack(spacing: 0) {
                    DynamicIslandChat(
                        draftSubject: subject.isEmpty ? "New Message" : subject,
                        // Bubble visible → edit the suggestion; otherwise edit the body.
                        draftBody: showingSuggestion ? (currentSuggestion ?? "") : messageBody,
                        composeContext: buildComposeEditContext(),
                        draftId: draftId,
                        draftReplyToId: replyTo?.id,
                        // T5.8 — the reply target's ADDRESS travels with its PK, from
                        // the SAME header, so a Draft row first created by the agent's
                        // auto-save is stamped exactly like one created by Save/Send.
                        draftReplyToProviderMessageId: replyTo?.messageId,
                        draftReplyToUidValidity: replyTo?.observedUidValidity,
                        composeGenerationCursor: admissionCursor,
                        composeAgentSendFence: agentSendFence,
                        composeMutationAllowed: draftReadState != .error,
                        // Bubble showing → suggestion is ephemeral; no Draft row.
                        // Reply mode additionally persists edits to cachedReply.
                        skipDraftAutoSave: showingSuggestion,
                        isExpanded: $chatExpanded,
                        isWorking: $aiWorking,
                        onDraftUpdate: { newSubject, newBody, toDelta, ccDelta, bccDelta in
                            applyInlineEdit(subject: newSubject, body: newBody, toDelta: toDelta, ccDelta: ccDelta, bccDelta: bccDelta)
                        },
                        onAgentReply: { reply in
                            showAgentToast(reply)
                        }
                    )
                    .padding(.top, chatExpanded ? 0 : (headerHeight - 56) / 2)
                    .scaleEffect(pillAppeared ? 1 : 0.6)
                    .opacity(pillAppeared ? 1 : 0)
                    .popoverTip(ComposeSaveDraftTip(), arrowEdge: .top)
                    .onChange(of: chatExpanded) { wasExpanded, isExpanded in
                        // First time the compose chat collapses → unlock the
                        // ComposeSaveDraftTip on the (now-collapsed) pill.
                        if wasExpanded && !isExpanded {
                            ComposeSaveDraftTip.hasClosedComposeChat = true
                        }
                    }

                    if chatExpanded { Spacer() }
                }

                // Layer 6: Agent reply toast (bottom, undo-toast style)
                if let toast = agentToast, !chatExpanded {
                    VStack {
                        Spacer()
                        Button {
                            withAnimation(.spring(response: 0.45, dampingFraction: 0.82)) {
                                chatExpanded = true
                            }
                            dismissAgentToast()
                        } label: {
                            HStack(spacing: 10) {
                                Image(systemName: "wand.and.stars")
                                    .font(.system(size: 18, weight: .medium))
                                    .foregroundStyle(.primary)
                                Text(toast)
                                    .font(.subheadline)
                                    .foregroundStyle(.white)
                                    .lineLimit(1)
                                Spacer()
                                Image(systemName: "xmark")
                                    .font(.caption)
                                    .foregroundStyle(.white.opacity(0.6))
                            }
                            .padding(.horizontal, 16)
                            .padding(.vertical, 12)
                            .background(
                                Capsule()
                                    .fill(Color(hex: 0x323232))
                                    .shadow(color: .black.opacity(0.3), radius: 8, y: 4)
                            )
                            .padding(.horizontal, 16)
                        }
                        .buttonStyle(.plain)
                        .transition(.move(edge: .bottom).combined(with: .opacity))
                        .padding(.bottom, 8)
                    }
                }
            }
            .background(Palette.previewPaneBg)
            .toolbar(.hidden, for: .navigationBar)
            .animation(.spring(response: 0.45, dampingFraction: 0.82), value: chatExpanded)
            .onChange(of: chatExpanded) { _, expanded in handleChatExpandedChange(expanded) }
            // Pulse driver — hoisted off the editor so it runs while the bubble is up too.
            .onChange(of: aiWorking) { _, working in handleAIWorkingChange(working) }
            .onChange(of: isSavingDraft) { _, saving in handleSavingDraftChange(saving) }
            // Stuck-fade detector: `isApplyingEdit` is the black-screen suspect —
            // it drives the editor's opacity to 0 during applyInlineEdit's fade-out
            // and should flip back to false ~0.65s later. If it doesn't, the editor
            // stays invisible forever. Logging only — never force-resets state.
            .onChange(of: isApplyingEdit) { _, applying in handleApplyingEditChange(applying) }
            .overlay {
                if isSavingDraft {
                    Color.black.opacity(0.7)
                        .ignoresSafeArea()
                        .overlay {
                            VStack(spacing: 12) {
                                ProgressView()
                                    .tint(.white)
                                    .scaleEffect(1.2)
                                Text("Saving draft...")
                                    .font(.subheadline)
                                    .foregroundStyle(.white)
                            }
                        }
                        .transition(.opacity)
                }
            }
            .alert("Send Failed", isPresented: Binding(
                get: { sendError != nil },
                set: { if !$0 { sendError = nil } }
            )) {
                Button("OK") { sendError = nil }
            } message: {
                Text(sendError ?? "An unknown error occurred.")
            }
            .alert("Save Draft?", isPresented: $showDiscardPrompt) {
                Button("Save") { Task { await saveDraftAndDismiss() } }
                Button("Discard", role: .destructive) { Task { await discardDraftAndDismiss() } }
                Button("Cancel", role: .cancel) { }
            } message: {
                Text("You have unsaved changes. Save as draft?")
            }
            // PORT — v2final `ComposeView.showClearedDraftDeletePrompt` (N2). A
            // LOADED existing draft emptied to nothing: CONFIRM before deleting.
            // Cancel leaves the compose open and the row intact.
            .alert("Delete Draft?", isPresented: $showClearedDraftDeletePrompt) {
                Button("Delete", role: .destructive) { Task { await deleteClearedDraftAndDismiss() } }
                Button("Cancel", role: .cancel) { }
            } message: {
                Text("This draft is now empty. Delete it?")
            }
            .alert("Empty Body", isPresented: $showEmptyBodyPrompt) {
                if showingSuggestion, currentSuggestion != nil {
                    Button("Use Suggestion & Send") {
                        messageBody = currentSuggestion ?? ""
                        showingSuggestion = false
                        Task { await send() }
                    }
                }
                Button("Send Anyway") { Task { await send() } }
                Button("Cancel", role: .cancel) { }
            } message: {
                if showingSuggestion, currentSuggestion != nil {
                    Text("The message body is empty. You have an AI suggestion that hasn't been accepted.")
                } else {
                    Text("The message body is empty. Send anyway?")
                }
            }
            .onAppear { performInitialAppear() }
            // ADR-IOS-030: Track ComposeView lifecycle so AgentToolRouter's FIFO queue
            // knows when the compose UI is busy. Counts every presentation path
            // (manual New, contact, reply, replyAll, forward, agent compose, agent draft).
            .onAppear { performLifecycleAppear() }
            .onDisappear { performDisappear() }
            .onChange(of: selectedAccount) {
                currentSignature = selectedAccount?.signature ?? ""
            }
            .onChange(of: photoPickerItems) { _, items in handlePhotoPickerItemsChange(items) }
            .photosPicker(isPresented: $showPhotoPicker, selection: $photoPickerItems, matching: .any(of: [.images, .videos]))
            .fileImporter(isPresented: $showFilePicker, allowedContentTypes: [.item], allowsMultipleSelection: true) { result in
                handleFileImport(result)
            }
            .fullScreenCover(isPresented: $showCamera) {
                CameraPickerView { image in
                    if let data = image.jpegData(compressionQuality: 0.85) {
                        attachments.append(DraftAttachment(
                            filename: "photo_\(attachments.count + 1).jpg",
                            mimeType: "image/jpeg",
                            data: data
                        ))
                    }
                }
            }
            .dismissKeyboardOnTap()
        }
    }

    // MARK: - Lifecycle / onChange handlers
    //
    // COMPILE REPAIR (build gate): the bodies below were multi-statement closures
    // inline in `body`'s modifier chain. Under SE-0326 a multi-statement closure is
    // type-checked as PART OF its enclosing expression, so every statement here was
    // spending `body`'s single solver budget. Once this file grew, that budget ran
    // out and the compiler reported "unable to type-check this expression in
    // reasonable time" — landing on whichever statement happened to cross the line
    // (it migrated from `.onAppear` to `.onDisappear` as each was moved out). Calling
    // a method takes the statements out of that constraint system. Every body below
    // is its original text, verbatim and in order; no statement was added, removed,
    // reordered or altered, and each is still invoked from the same modifier.

    private func handleChatExpandedChange(_ expanded: Bool) {
        if DebugModeManager.isLoggingEnabled() {
            print("[ComposeView] chatExpanded -> \(expanded) instance=\(instanceToken) draftId=\(draftId)")
        }
        if expanded {
            bodyFocused = false
            UIApplication.shared.sendAction(#selector(UIResponder.resignFirstResponder), to: nil, from: nil, for: nil)
        }
    }

    private func handleAIWorkingChange(_ working: Bool) {
        if working {
            withAnimation(.easeInOut(duration: 0.8).repeatForever(autoreverses: true)) {
                bodyBlink = true
            }
        } else {
            withAnimation(.easeInOut(duration: 0.3)) {
                bodyBlink = false
            }
        }
    }

    private func handleSavingDraftChange(_ saving: Bool) {
        if DebugModeManager.isLoggingEnabled() {
            print("[ComposeView] isSavingDraft -> \(saving) instance=\(instanceToken) draftId=\(draftId)")
        }
    }

    private func handleApplyingEditChange(_ applying: Bool) {
        if DebugModeManager.isLoggingEnabled() {
            print("[ComposeView] isApplyingEdit -> \(applying) instance=\(instanceToken) draftId=\(draftId) chatExpanded=\(chatExpanded) isSavingDraft=\(isSavingDraft)")
        }
        stuckFadeWatchTask?.cancel()
        stuckFadeWatchTask = nil
        guard applying else { return }
        stuckFadeWatchTask = Task { @MainActor in
            var elapsedSeconds = 0
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(3))
                if Task.isCancelled { return }
                elapsedSeconds += 3
                guard isApplyingEdit else { return }
                if DebugModeManager.isLoggingEnabled() {
                    print("[ComposeView] ⚠ STUCK FADE: isApplyingEdit still true after \(elapsedSeconds)s — editor invisible; chatExpanded=\(chatExpanded) isSavingDraft=\(isSavingDraft) instance=\(instanceToken) draftId=\(draftId)")
                }
            }
        }
    }

    private func handlePhotoPickerItemsChange(_ items: [PhotosPickerItem]) {
        Task {
            for item in items {
                if let data = try? await item.loadTransferable(type: Data.self) {
                    let mimeType = item.supportedContentTypes.first?.preferredMIMEType ?? "application/octet-stream"
                    let ext = item.supportedContentTypes.first?.preferredFilenameExtension ?? "dat"
                    let filename = "photo_\(attachments.count + 1).\(ext)"
                    attachments.append(DraftAttachment(filename: filename, mimeType: mimeType, data: data))
                }
            }
            photoPickerItems = []
        }
    }

    /// ADR-IOS-030: Track ComposeView lifecycle so AgentToolRouter's FIFO queue
    /// knows when the compose UI is busy. Counts every presentation path
    /// (manual New, contact, reply, replyAll, forward, agent compose, agent draft).
    private func performLifecycleAppear() {
        AgentToolRouter.shared.composePresentationDidBegin()
        // Arm the deinit fallback with the compose-scope outcome
        // closure. Captured by value so it stays alive even if
        // `onAgentOutcome` is later nil'd by the view graph.
        let outcomeAtAppear = onAgentOutcome
        lifecycleTracker.armFallback {
            // Deinit runs on the thread that releases the tracker.
            // Dispatch to MainActor for router + closure access.
            Task { @MainActor in
                AgentToolRouter.shared.composePresentationDidEnd()
                outcomeAtAppear?(.cancelled)
            }
        }
    }

    private func performDisappear() {
        if DebugModeManager.isLoggingEnabled() {
            print("[ComposeView] onDisappear instance=\(instanceToken) draftId=\(draftId)")
        }
        // PORT — this compose closed; drop its eviction guard (refcounted, so
        // a sibling view replying to the same message stays protected). A
        // missed `.onDisappear` over-RETAINS, which is the safe direction, and
        // self-heals at launch when the registry starts empty.
        DraftSessionRegistry.shared.unregister(draftId)
        // Normal teardown path: mark the tracker so its deinit
        // fallback is a no-op, then fire the outcome/hooks directly
        // (synchronous — faster than the deinit path).
        lifecycleTracker.markDisappearedNormally()
        AgentToolRouter.shared.composePresentationDidEnd()
        // Default outcome for agent-initiated compose. No-op if
        // `.sent` or `.failed(...)` already fired inside `send()` —
        // `ComposeOutcomeState.tryResolve` guards against re-entry.
        onAgentOutcome?(.cancelled)
    }

    /// COMPILE REPAIR (build gate): this is the FIRST `.onAppear` closure body,
    /// moved out of `body` verbatim. Under SE-0326 a multi-statement closure is
    /// type-checked as part of its enclosing expression, so these statements were
    /// spending `body`'s solver budget; once this file grew, the budget ran out and
    /// the compiler reported "unable to type-check this expression in reasonable
    /// time" on whichever statement happened to cross the line. Calling a method
    /// takes the statements out of that constraint system. Behaviour is unchanged:
    /// same statements, same order, still on `.onAppear`, still on the MainActor.
    private func performInitialAppear() {
        // Use prefillDraftId if provided (reopening an existing draft).
        if let prefillDraftId {
            draftId = prefillDraftId
        } else if let reply = replyTo {
            // Compute deterministic draftKey for reply/forward (new compose keeps UUID).
            // Uses stableId (rfc822MessageId for IMAP, messageId for Gmail/Exchange)
            // so the draft key survives IMAP folder moves.
            let stableKey = "\(reply.accountId):\(reply.stableId)"
            draftId = Draft.draftKey(replyTo: stableKey, isForward: isForward, newId: nil)
        }
        // PORT — mark this compose OPEN so background maintenance (draft
        // eviction, orphan compose-session cleanup) never deletes it or its
        // authored chat turns while it is on screen. Refcounted; balanced by
        // the `.onDisappear` unregister. Registered AFTER `draftId` is
        // resolved above, and `draftId` is never reassigned outside this
        // block, so the two calls always name the same id.
        DraftSessionRegistry.shared.register(draftId)
        if DebugModeManager.isLoggingEnabled() {
            print("[ComposeView] onAppear instance=\(instanceToken) draftId=\(draftId)")
        }
        contactSearch.requestAccess()
        Task { await loadDraftOrPrepopulate() }
        resolveContactNames()
        withAnimation(.spring(response: 0.5, dampingFraction: 0.7).delay(0.15)) {
            pillAppeared = true
        }
    }

    // MARK: - Signature

    private var sigBelowQuote: Bool {
        resolvedAccount?.signatureBelowQuote ?? false
    }

    private var signatureView: some View {
        Text("-- \n" + currentSignature)
            .font(.body)
            .foregroundStyle(.secondary)
            .padding(.horizontal, 16)
    }

    // MARK: - Suggestion Bubble

    private func suggestionBubble(text: String) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            // Header label
            HStack(spacing: 4) {
                Image(systemName: "wand.and.sparkles")
                    .font(.caption2)
                    .foregroundStyle(Theme.accent)
                Text("AI Suggestion")
                    .font(.caption)
                    .fontWeight(.medium)
                    .foregroundStyle(Theme.textSecondary)
            }

            // Same opacity formula as the body editor — pulse + apply-edit fade.
            Text(text)
                .font(.body)
                .foregroundStyle(Theme.textPrimary)
                .fixedSize(horizontal: false, vertical: true)
                .multilineTextAlignment(.leading)
                .opacity(isApplyingEdit ? 0 : (bodyBlink ? 0.35 : 1))

            // Recompute (reply mode only) + Dismiss / Use Suggestion (bottom-right)
            HStack(spacing: 12) {
                if replyTo != nil && !isForward {
                    Button {
                        recomputeReply()
                    } label: {
                        if isRecomputing {
                            ProgressView()
                                .controlSize(.mini)
                        } else {
                            Image(systemName: "arrow.trianglehead.2.counterclockwise")
                                .font(.caption)
                                .foregroundStyle(Theme.textSecondary)
                        }
                    }
                    .buttonStyle(.plain)
                    .disabled(isRecomputing)
                }

                Spacer()

                Button {
                    withAnimation(.easeOut(duration: 0.2)) {
                        showingSuggestion = false
                    }
                } label: {
                    Text("Dismiss")
                        .font(.caption)
                        .foregroundStyle(Theme.textSecondary)
                }
                .buttonStyle(.plain)

                Button {
                    withAnimation(.easeInOut(duration: 0.35)) {
                        messageBody = text
                        showingSuggestion = false
                    }
                } label: {
                    Text("Use Suggestion")
                        .font(.caption)
                        .fontWeight(.semibold)
                        .foregroundStyle(.white)
                        .padding(.horizontal, 12)
                        .padding(.vertical, 6)
                        .background(Theme.accent)
                        .clipShape(RoundedRectangle(cornerRadius: 6))
                }
                .buttonStyle(.plain)
            }
        }
        .padding(12)
        .background(Theme.accent.opacity(0.08))
        .clipShape(RoundedRectangle(cornerRadius: 10))
        .overlay(
            RoundedRectangle(cornerRadius: 10)
                .stroke(Theme.accent.opacity(0.2), lineWidth: 1)
        )
        .reportConcern(contentType: .suggestedReply, content: text)
        .padding(.horizontal, 12)
        .padding(.top, 4)
    }

    // MARK: - Recompute reply (debug — direct LLM, skips Device Sync)

    private func recomputeReply() {
        guard let reply = replyTo, let account = resolvedAccount else { return }
        isRecomputing = true

        Task {
            let body = try? await dbPool.read { db in try MessageBody.fetchOne(db, key: reply.id) }
            let bodyText: String
            if let html = body?.htmlContent, !html.isEmpty {
                // Strip embedded .eml sections so the reply context is only the
                // primary message body, not forwarded-as-attachment emails.
                bodyText = EmailFilter.htmlToPlainText(EmailFilter.stripEmbeddedEmlSections(html))
            } else {
                bodyText = reply.snippet
            }

            do {
                let result = try await AIService.shared.processReply(
                    messageId: reply.messageId,
                    rfc822MessageId: reply.rfc822MessageId,
                    accountEmail: account.emailAddress,
                    subject: reply.subject,
                    from: reply.from,
                    fromAddress: reply.fromAddress,
                    to: reply.to,
                    date: reply.date,
                    bodyText: bodyText,
                    htmlContent: body?.htmlContent,
                    userName: account.displayName,
                    kbText: PromptStore.shared.kbText(),
                    compositionPrompt: PromptStore.shared.compositionMarkdown()
                )
                if let result, !result.isEmpty {
                    currentSuggestion = result
                    try? await dbPool.write { db in
                        try db.execute(
                            sql: "UPDATE messageHeader SET cachedReply = ? WHERE id = ?",
                            arguments: [result, reply.id]
                        )
                    }
                    print("[Compose] Recomputed reply for \(reply.messageId)")
                } else {
                    print("[Compose] Recompute returned nil/empty for \(reply.messageId)")
                }
            } catch {
                print("[Compose] Recompute reply failed: \(error)")
            }
            isRecomputing = false
        }
    }

    // MARK: - Agent Toast

    private func showAgentToast(_ text: String) {
        agentToastDismiss?.cancel()
        withAnimation(.spring(response: 0.35, dampingFraction: 0.8)) {
            agentToast = text
        }
        agentToastDismiss = Task {
            try? await Task.sleep(for: .seconds(4))
            guard !Task.isCancelled else { return }
            dismissAgentToast()
        }
    }

    private func dismissAgentToast() {
        agentToastDismiss?.cancel()
        agentToastDismiss = nil
        withAnimation(.easeOut(duration: 0.25)) {
            agentToast = nil
        }
    }

    // MARK: - Inline Edit

    /// Build the compose edit context for the DynamicIslandChat inline editor.
    private func buildComposeEditContext() -> ComposeEditContext {
        let account = resolvedAccount
        let mode: String
        if isForward {
            mode = "edit_forward"
        } else if replyTo != nil {
            mode = "edit_reply"
        } else {
            mode = "edit_new"
        }

        // Build related email info for reply mode
        let relatedDate: String
        let relatedSubject: String
        let relatedFrom: String
        let relatedTo: String
        let relatedCc: String
        let bodyText: String

        if let reply = replyTo {
            relatedDate = AIService.formatTimestampForAgent(reply.date)
            relatedSubject = reply.subject
            let fromFormatted = reply.fromAddress.isEmpty ? reply.from : "\(reply.from) <\(reply.fromAddress)>"
            relatedFrom = fromFormatted
            relatedTo = reply.to
            relatedCc = reply.cc

            let body = try? dbPool.read { db in try MessageBody.fetchOne(db, key: reply.id) }
            if let html = body?.htmlContent, !html.isEmpty {
                // Strip embedded .eml sections — AI edit context is the primary
                // message body, not forwarded-as-attachment emails.
                bodyText = EmailFilter.htmlToPlainText(EmailFilter.stripEmbeddedEmlSections(html))
            } else {
                bodyText = reply.snippet
            }
        } else {
            relatedDate = ""
            relatedSubject = ""
            relatedFrom = ""
            relatedTo = ""
            relatedCc = ""
            bodyText = ""
        }

        return ComposeEditContext(
            recipients: toTokens,
            toRecipients: toTokens,
            ccRecipients: ccTokens,
            bccRecipients: bccTokens,
            toDisplayNames: toDisplayNames,
            ccDisplayNames: ccDisplayNames,
            bccDisplayNames: bccDisplayNames,
            senderName: account?.displayName ?? "",
            senderEmail: account?.emailAddress ?? "",
            mode: mode,
            compositionPrompt: PromptStore.shared.compositionMarkdown(),
            kbText: PromptStore.shared.kbText(),
            relatedDate: relatedDate,
            relatedSubject: relatedSubject,
            relatedFrom: relatedFrom,
            relatedTo: relatedTo,
            relatedCc: relatedCc,
            bodyText: bodyText
        )
    }

    /// Apply an inline edit result: dissolve out old text, swap, dissolve in new text.
    /// Recipient deltas (to/cc/bcc) are `nil` when the LLM did not emit any `+X:`/`-X:` line for
    /// that field (keep current). Non-nil deltas are applied as: removes → adds (deduped).
    /// A delta whose `clearsField` is true wipes the field before adding. See
    /// email_edit_response_format-v1.5.16.md.
    private func applyInlineEdit(
        subject newSubject: String?,
        body newBody: String?,
        toDelta: RecipientDelta?,
        ccDelta: RecipientDelta?,
        bccDelta: RecipientDelta?
    ) {
        func desc(_ d: RecipientDelta?) -> String {
            guard let d else { return "nil" }
            return "+\(d.adds.count)/-\(d.removes.count)\(d.clearsField ? "*" : "")"
        }
        print("[ComposeView] applyInlineEdit: subject=\(newSubject?.prefix(40) ?? "nil") bodyLen=\(newBody?.count ?? 0) to=\(desc(toDelta)) cc=\(desc(ccDelta)) bcc=\(desc(bccDelta))")
        // Phase 1: fade text out completely
        withAnimation(.easeIn(duration: 0.25)) {
            isApplyingEdit = true
        }
        if DebugModeManager.isLoggingEnabled() {
            print("[ComposeView] applyInlineEdit: fade-out begin instance=\(instanceToken) draftId=\(draftId)")
        }
        Task { @MainActor in
            // Wait for fade-out to finish
            try? await Task.sleep(for: .milliseconds(280))
            // Phase 2: swap text while invisible
            if let s = newSubject {
                print("[ComposeView] applyInlineEdit: updating subject to '\(s.prefix(40))'")
                subject = s
            }
            if let b = newBody {
                if showingSuggestion {
                    print("[ComposeView] applyInlineEdit: updating suggestion (len=\(b.count))")
                    currentSuggestion = b
                    // Only persist to messageHeader.cachedReply in reply mode.
                    // Compose has no source message; forward would write to the
                    // wrong target (the email being forwarded, not the draft).
                    if replyTo != nil && !isForward {
                        persistCachedReply(b)
                    }
                } else {
                    print("[ComposeView] applyInlineEdit: updating body (len=\(b.count))")
                    messageBody = b
                }
            }
            applyRecipientDelta(field: .to, delta: toDelta)
            applyRecipientDelta(field: .cc, delta: ccDelta)
            applyRecipientDelta(field: .bcc, delta: bccDelta)
            if DebugModeManager.isLoggingEnabled() {
                print("[ComposeView] applyInlineEdit: mutation applied instance=\(instanceToken) draftId=\(draftId)")
            }
            // Phase 3: dissolve back in with new text
            withAnimation(.easeOut(duration: 0.4)) {
                isApplyingEdit = false
            }
            if DebugModeManager.isLoggingEnabled() {
                print("[ComposeView] applyInlineEdit: fade-in begin instance=\(instanceToken) draftId=\(draftId)")
            }
            print("[ComposeView] applyInlineEdit: done, isApplyingEdit=false")
        }
    }

    /// Write the edited suggestion to `messageHeader.cachedReply` so reopens see it.
    private func persistCachedReply(_ text: String) {
        guard let reply = replyTo else { return }
        Task { await Self.writeCachedReplyToDB(text, headerId: reply.id, db: dbPool.pool) }
    }

    /// Internal for testability — exact SQL used by `persistCachedReply`.
    static func writeCachedReplyToDB(_ text: String, headerId: String, db: any DatabaseWriter) async {
        try? await db.write { db in
            try db.execute(
                sql: "UPDATE messageHeader SET cachedReply = ? WHERE id = ?",
                arguments: [text, headerId]
            )
        }
    }

    private enum RecipientEditField { case to, cc, bcc }

    /// Apply one field's delta to the matching token array. Removes are applied first
    /// (including the `*` clear-all sentinel), then adds are appended deduped on email
    /// (case-insensitive). Display names from adds are merged into the lookup map.
    private func applyRecipientDelta(field: RecipientEditField, delta: RecipientDelta?) {
        guard let delta, !delta.isEmpty else { return }

        func mutateTokens(_ tokens: inout [String], _ names: inout [String: String]) {
            if delta.clearsField {
                tokens = []
            } else if !delta.removes.isEmpty {
                let removeSet = Set(delta.removes.map { $0.lowercased() })
                tokens = tokens.filter { !removeSet.contains($0.lowercased()) }
            }
            var seen = Set(tokens.map { $0.lowercased() })
            for add in delta.adds {
                let email = add.email
                guard !email.isEmpty, email != "*" else { continue }
                let key = email.lowercased()
                if seen.insert(key).inserted {
                    tokens.append(email)
                }
                if !add.name.isEmpty { names[email] = add.name }
            }
        }

        switch field {
        case .to:
            mutateTokens(&toTokens, &toDisplayNames)
        case .cc:
            mutateTokens(&ccTokens, &ccDisplayNames)
            if !ccTokens.isEmpty { showCc = true }
        case .bcc:
            mutateTokens(&bccTokens, &bccDisplayNames)
            if !bccTokens.isEmpty { showCc = true }
        }
    }

    // MARK: - From picker

    private var fromPickerButton: some View {
        Button {
            showFromPicker.toggle()
        } label: {
            HStack {
                Text(selectedAccount?.emailAddress ?? "")
                    .lineLimit(1)
                    .truncationMode(.middle)
                Spacer()
                Image(systemName: "chevron.up.chevron.down")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
        }
        .tint(.primary)
        .popover(isPresented: $showFromPicker, arrowEdge: .top) {
            fromPickerPopover
                .presentationCompactAdaptation(.popover)
        }
    }

    private var fromPickerPopover: some View {
        ScrollView(.vertical, showsIndicators: false) {
            VStack(alignment: .leading, spacing: 0) {
                ForEach(navigationStore.accounts, id: \.id) { acct in
                    Button {
                        selectedAccount = acct
                        showFromPicker = false
                    } label: {
                        HStack(spacing: 8) {
                            Image(systemName: "checkmark")
                                .font(.caption)
                                .foregroundStyle(Color.accentColor)
                                .opacity(acct.id == selectedAccount?.id ? 1 : 0)
                                .frame(width: 16)
                            ScrollView(.horizontal, showsIndicators: false) {
                                Text(acct.emailAddress)
                                    .lineLimit(1)
                                    .fixedSize()
                            }
                        }
                        .padding(.horizontal, 16)
                        .padding(.vertical, 12)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                }
            }
        }
        .frame(minWidth: 250, maxHeight: 300)
    }

    // MARK: - Draft Load / Resume

    /// Load existing draft from GRDB if available, otherwise fall back to normal prepopulate.
    /// For reply/forward: if a draft exists, restore its subject/body (skip AI suggestion).
    private func loadDraftOrPrepopulate() async {
        guard !loadedDraft else { return }
        loadedDraft = true

        // Try loading persisted draft
        print("[ComposeView] loadDraftOrPrepopulate: draftId=\(draftId) prefillDraftId=\(prefillDraftId ?? "nil")")
        let draftKey = draftId
        let readResult: Result<Draft?, Error>
        do {
            readResult = .success(try await AppDatabase.dbPool.read { db in
                try Draft.fetchOne(db, key: draftKey)
            })
        } catch {
            readResult = .failure(error)
        }
        draftReadState = ComposeDraftGuards.readState(readResult)
        guard case .success(let loaded) = readResult else {
            draftReadState = .error
            sendError = "This draft did not finish loading. Close and reopen it to try again."
            return
        }
        if let draft = loaded {
            if let retainedDraftAuthority {
                guard retainedDraftAuthority.draftId == draftId,
                      retainedDraftAuthority.matches(draft) else {
                    draftReadState = .error
                    sendError = "This draft changed while it was opening. Close and reopen it to try again."
                    return
                }
            }
            if let openAuthority {
                guard openAuthority.draftId == draftId,
                      let runtimeKind = await AccountManager.shared.draftRuntimeIdentityKind(
                          accountId: openAuthority.accountId),
                      openAuthority.matches(draft, runtimeKind: runtimeKind) else {
                    draftReadState = .error
                    sendError = "This draft changed while it was opening. Close and reopen it to try again."
                    return
                }
            }
            // PORT — v2final `loadDraftOrPrepopulate`'s persisted-draft account bind
            // (`ServerDraftOpen.mayBindPersistedDraft`, commits `a8eb813b5` /
            // `69a9bae88`). The presenter and this inner view are SEPARATE SwiftUI
            // handoffs, so the binding is repeated here against the row this view
            // actually read. `resolvedAccount` is deliberately NOT authority here:
            // it derives from the mutable From picker, the reply parent's account,
            // or a caller snapshot, and the two `resolvedAccount ??
            // navigationStore.accounts.first` assignments this branch used to make
            // could land on an ARBITRARY account — which for a persisted draft means
            // composing, saving and SENDING from an address that does not own the
            // row. An unresolvable owner FAILS CLOSED: the row is left completely
            // untouched and the user retries by reopening.
            let persistedDraftAccount = account?.id == draft.accountId
                ? account
                : navigationStore.accounts.first(where: { $0.id == draft.accountId })
            guard ComposeDraftGuards.mayBindPersistedDraft(
                draftAccountId: draft.accountId,
                resolvedAccountId: persistedDraftAccount?.id
            ), let persistedDraftAccount else {
                draftReadState = .error
                sendError = "This draft's account couldn't be verified. Close and reopen it to try again."
                if DebugModeManager.isLoggingEnabled() {
                    print("[ComposeView] ⚠ Persisted-draft account bind FAILED for draftId=\(draftId) accountId=\(draft.accountId.prefix(20)) — failing closed, binding nothing")
                }
                return
            }
            selectedAccount = persistedDraftAccount
            currentSignature = persistedDraftAccount.signature ?? ""
            let observed = draft.instanceEpoch.flatMap { $0.isEmpty ? nil : $0 }
            let epoch = observed ?? UUID().uuidString
            admissionCursor = ComposeGenerationCursor(
                newEpoch: epoch, initialExpectedPredecessor: observed)
            print("[ComposeView] Found draft: subject=\(draft.subject.prefix(40)) editHistory=\(draft.editHistoryJSON?.prefix(40) ?? "nil")")
            // Restore draft state
            subject = draft.subject
            messageBody = draft.body
            toTokens = draft.toArray
            ccTokens = draft.ccArray
            bccTokens = draft.bccArray
            if !ccTokens.isEmpty || !bccTokens.isEmpty { showCc = true }
            // Load attachments from disk (saveDraftAndDismiss writes them via
            // DraftAttachmentStorage.saveAttachments; reopen restores them so
            // user sees what was saved). B1: the loader FAILS CLOSED — if a
            // referenced attachment is unreadable/missing (or the dir is gone) it
            // THROWS rather than returning a silent subset. On failure we DO NOT
            // open compose with a partial set: enter the blocking state that
            // disables Send + save-to-server until the user resolves it (discard,
            // or reopen to retry the load). A nil dirName is the only clean
            // attachment-less case and returns [] without throwing.
            do {
                attachments = try DraftAttachmentStorage.loadAttachments(dirName: draft.attachmentsDirName)
            } catch {
                attachmentLoadFailed = true
                sendError = "Some attachments couldn't be loaded, so this draft can't be sent or saved to the server. Close and reopen the draft to retry, or discard it."
                if DebugModeManager.isLoggingEnabled() {
                    print("[ComposeView] ⚠ Draft attachment load FAILED for draftId=\(draftId) — blocking Send/save-to-server: \(error)")
                }
            }

            // For reply/forward: set up quoted text and attribution (but NOT AI suggestion).
            //
            // T5.8: resolve the reply header AND fetch its quoted body in ONE DB
            // snapshot through the GUARDED resolver, keyed on the draft's own stored
            // reply-target ADDRESS (`replyToProviderMessageId` + `replyToUidValidity`,
            // v80) and the RFC baseline encoded in the draft KEY. The superseded code
            // did three unsafe things at once: it preferred the pre-captured `replyTo`
            // param (which may be STALE — the reference's own call sites say "do NOT
            // trust" it), it accepted the `replyToId` PK hit UNCONDITIONALLY, and it
            // then read the body in a SECOND, independent `dbPool.read` that a
            // concurrent purge-and-resync could interleave with. Any of the three can
            // quote a different correspondent's mail into the user's outgoing reply.
            // Hoisted into locals so the `@Sendable` read closure captures plain
            // values instead of `self`.
            let quoteDraftKey = draftId
            let quoteReplyToId = draft.replyToId
            let quoteIsForward = draft.isForward
            let quoteExpectedProviderMessageId = draft.replyToProviderMessageId
            let quoteExpectedUidValidity = draft.replyToUidValidity
            let quote: Draft.ReplyQuote? = try? await AppDatabase.dbPool.read { db in
                try Draft.resolveReplyQuote(
                    draftKey: quoteDraftKey, replyToId: quoteReplyToId,
                    isForward: quoteIsForward,
                    expectedProviderMessageId: quoteExpectedProviderMessageId,
                    expectedUidValidity: quoteExpectedUidValidity,
                    db: db)
            }
            // D8: the From account is ALREADY bound above, to the exact owner of the
            // row this view read. The two `resolvedAccount ?? navigationStore
            // .accounts.first` assignments that stood here are deliberately gone —
            // for a persisted draft they could silently REBIND the compose to an
            // arbitrary account (the fallback fires whenever `account`, the picker
            // and the reply parent all fail to resolve), which is the exact
            // wrong-account send this item exists to prevent.
            if let quote {
                let reply = quote.header
                let resolvedForward = replyTo != nil ? isForward : draft.isForward
                let dateStr = reply.date.formatted(date: .abbreviated, time: .shortened)
                if resolvedForward {
                    quotedAttribution = "---------- Forwarded message ----------\nFrom: \(reply.from)\nDate: \(dateStr)\nSubject: \(reply.subject)"
                } else {
                    quotedAttribution = "On \(dateStr), \(reply.from) wrote:"
                }
                // ONLY an identity-confirmed body may populate the OUTBOUND quote. The
                // superseded `else if !reply.snippet.isEmpty` snippet fallback is
                // deliberately gone: a snippet is a cached preview of whatever row the
                // PK named, so it re-opens the exact hole the guard just closed.
                if let html = ComposeDraftGuards.outboundQuoteBody(
                    confirmedBodyHTML: quote.bodyHTML, capturedSnippet: reply.snippet
                ) {
                    quotedHTML = EmailFilter.stripEmbeddedEmlSections(html)
                }
            } else if draft.isReplyOrForward, DebugModeManager.isLoggingEnabled() {
                print("[ComposeView] ⚠ T5.8: reply target for draftId=\(draftId) could not be identity-confirmed — quote OMITTED (authored body untouched)")
            }

            print("[ComposeView] Loaded draft: id=\(draftId) subject=\(subject.prefix(40))")
            snapshotInitialState()
            return
        }

        // No draft found — normal prepopulate
        if openAuthority != nil || retainedDraftAuthority != nil {
            draftReadState = .error
            sendError = "This draft changed while it was opening. Close and reopen it to try again."
            return
        }
        print("[ComposeView] No draft found for draftId=\(draftId), falling back to prepopulate")
        prepopulate()
    }

    /// Snapshot current field values so closeCompose can detect actual changes.
    private func snapshotInitialState() {
        initialSubject = subject
        initialBody = messageBody
        initialToTokens = toTokens
        initialCcTokens = ccTokens
        initialBccTokens = bccTokens
        initialAttachmentsFingerprint = attachmentsFingerprint(attachments)
    }

    @discardableResult
    private func saveThroughGeneration(_ draft: Draft) async throws -> DraftStore.SaveResult {
        try await admissionCursor.admit { newEpoch, expectedPredecessor in
            try await DraftStore.shared.saveAsync(
                draft,
                epoch: newEpoch,
                expectedPredecessor: expectedPredecessor)
        }
    }

    /// Cheap summary used to detect attachment changes without comparing raw
    /// Data blobs. Two attachment lists are equal iff their fingerprints match.
    private func attachmentsFingerprint(_ list: [DraftAttachment]) -> [String] {
        list.map { "\($0.filename)|\($0.data.count)|\($0.mimeType)|\($0.isAlternative)" }
    }

    // MARK: - Close / Discard

    /// PORT — v2final `ComposeView.commitPendingRecipientInput` (F3).
    ///
    /// Flush any uncommitted in-progress recipient text (`toInput`/`ccInput`/
    /// `bccInput`) into the token arrays — the same flush `send()` applies to its
    /// outbound payload — so close / save also SEE it (`hasChanges`) and PERSIST it
    /// instead of silently dropping the address the user was mid-way through
    /// typing. Empty / whitespace-only input is a no-op on the tokens.
    private func commitPendingRecipientInput() {
        toTokens = ComposeDraftGuards.committedRecipients(tokens: toTokens, input: toInput)
        toInput = ""
        ccTokens = ComposeDraftGuards.committedRecipients(tokens: ccTokens, input: ccInput)
        ccInput = ""
        bccTokens = ComposeDraftGuards.committedRecipients(tokens: bccTokens, input: bccInput)
        bccInput = ""
    }

    /// PORT — v2final `ComposeView.closeCompose` + `applyCloseDecision`, routed
    /// through `ComposeDraftGuards.hasContent` / `.closeAction` instead of the
    /// inline emptiness test this forward-port carried.
    ///
    /// Handle close button: prompt Save/Discard/Cancel when there are actual
    /// changes. Draft is saved BEFORE dismiss (persist before acknowledge).
    private func closeCompose() async {
        // F3: commit any pending in-progress recipient BEFORE the emptiness /
        // changes checks, so it is seen (hasChanges) and later persisted (save).
        commitPendingRecipientInput()
        // B1: an attachment-load failure leaves `attachments` EMPTY in memory, so a
        // draft whose only content WAS its attachments would read as empty and be
        // routed to a delete — destroying the very files we failed to read. The row
        // genuinely HAS attachments; we merely could not read them, so report
        // `hasAttachments: true` and let the unchanged-content branch dismiss with
        // the row intact.
        let hasContent = ComposeDraftGuards.hasContent(
            subject: subject, body: messageBody,
            to: toTokens, cc: ccTokens, bcc: bccTokens,
            toInput: toInput, ccInput: ccInput, bccInput: bccInput,
            hasAttachments: !attachments.isEmpty || attachmentLoadFailed)
        let hasChanges = subject != initialSubject || messageBody != initialBody
            || toTokens != initialToTokens || ccTokens != initialCcTokens || bccTokens != initialBccTokens
            || attachmentsFingerprint(attachments) != initialAttachmentsFingerprint
        switch ComposeDraftGuards.closeAction(
            readState: draftReadState, hasContent: hasContent, hasChanges: hasChanges
        ) {
        case .promptSave:
            showDiscardPrompt = true
        case .promptDelete:
            // A LOADED existing draft cleared to nothing — confirm before delete.
            showClearedDraftDeletePrompt = true
        case .deleteThenDismiss:
            // Brand-new / absent empty draft — safe to delete on close. R5: the
            // delete is CHECKED and `dismiss` runs only after it lands. `false`
            // (no row under this generation — the ordinary "opened New, typed
            // nothing, closed" case) is not a failure: there is nothing to lose,
            // so dismiss. Only a THROWN delete keeps the compose open.
            await ComposeDraftGuards.runCheckedLocalDeleteThenDismiss(
                delete: {
                    _ = try await DraftStore.shared.deleteAsync(
                        id: draftId, expectedInstanceEpoch: admissionCursor.newEpoch)
                },
                dismiss: { dismiss() },
                onDeleteFailure: { error in
                    sendError = "The draft could not be deleted: \(error.localizedDescription)"
                    if DebugModeManager.isLoggingEnabled() {
                        print("[ComposeView] R5: deleteAsync failed on close for draftId=\(draftId): \(error)")
                    }
                })
        case .dismiss:
            // Nothing to persist, no changes, OR a read-error (every mutation
            // blocked) — dismiss, leaving any on-disk draft intact.
            dismiss()
        }
    }

    /// PORT — v2final `ComposeView.deleteClearedDraftAndDismiss` (N2/F5).
    ///
    /// The confirmed-delete arm of the "cleared draft" prompt. Routed through the
    /// SAME safe path as an explicit Discard: a cleared LOADED draft may already
    /// have been pushed to the server, so the durable row must be read fail-closed
    /// and the remote server-draft cleanup queued. A local-only delete would let
    /// the server copy re-sync and REAPPEAR.
    private func deleteClearedDraftAndDismiss() async {
        await discardDraftAndDismiss()
    }

    private func saveDraftAndDismiss() async {
        // B1: refuse to save-to-server while attachments failed to load. Saving
        // here would (a) queue a push of a partial set to the server draft and
        // (b) rewrite the on-disk attachments dir from the empty in-memory list
        // (the deleteAttachments+saveAttachments below), turning a recoverable
        // read failure into permanent loss. Keep compose open and surface the
        // block; the user can discard, or reopen to retry the load.
        guard !attachmentLoadFailed else {
            sendError = "Some attachments couldn't be loaded, so this draft can't be saved to the server. Reopen the draft to retry, or discard it."
            return
        }
        guard draftReadState != .error else {
            sendError = "This draft did not finish loading. Close and reopen it before saving."
            return
        }
        guard let account = resolvedAccount else { dismiss(); return }
        // F3: commit any pending in-progress recipient so it is PERSISTED (not
        // dropped) by this save. Reached directly from the close prompt's "Save",
        // which does not go back through `closeCompose`.
        commitPendingRecipientInput()
        let now = Date().timeIntervalSince1970
        // Capture MainActor-isolated properties before entering Sendable closure
        let capDraftId = draftId
        let capTo = toTokens
        let capCc = ccTokens
        let capBcc = bccTokens
        let capSubject = subject
        let capBody = messageBody
        let capAttachments = attachments

        // PORT — v2final `saveDraftAndDismiss`'s "N2: ONE throwing draft read at
        // the TOP, BEFORE any disk or DB mutation". This replaces the TWO separate
        // `try?` reads this forward-port carried (one for `attachmentsDirName`, one
        // for the merge base), each of which turned a THROWN read into "absent":
        //   - the dir read fell through to the raw `draftId` path and DELETED the
        //     live attachment directory it had merely failed to see;
        //   - the merge read fell through to the INSERT branch, whose
        //     `editHistoryJSON: nil` then clobbered the row's stored AI edit history
        //     through `DraftStore.applySave`'s merge.
        // A thrown read is NOT absence: FAIL CLOSED with nothing written, and let
        // the user retry. A genuine nil still takes the normal first-save path.
        let readResult: Result<Draft?, Error>
        do {
            readResult = .success(try await AppDatabase.dbPool.read { db in
                try Draft.fetchOne(db, key: capDraftId)
            })
        } catch {
            readResult = .failure(error)
        }
        guard ComposeDraftGuards.saveMayMutate(
            readState: ComposeDraftGuards.readState(readResult)) else {
            sendError = "Couldn't save this draft — the database was busy. Try again in a moment."
            if DebugModeManager.isLoggingEnabled() {
                print("[ComposeView] ⚠ Save-path draft read THREW for draftId=\(capDraftId) — failing closed (no disk/DB write)")
            }
            return
        }
        let existing: Draft?
        if case .success(let value) = readResult { existing = value } else { existing = nil }
        let previousDirName = existing?.attachmentsDirName

        withAnimation(.easeIn(duration: 0.15)) { isSavingDraft = true }

        // PORT — v2final `saveDraftAndDismiss`'s F0d COPY-ON-WRITE attachment
        // staging. Persist attachments to disk BEFORE the DB write (file I/O
        // outside GRDB transactions), but into a FRESH, opaque-UUID staging dir —
        // NEVER the live dir. The superseded call site wrote into
        // `existingDirName ?? capDraftId`, which (a) DELETED the live set before
        // rewriting it, so a failed/rolled-back save left the row pointing at
        // destroyed or half-written files, and (b) used the raw `draftId` as a path
        // component — and a draftId may contain `/` (a `reply:<acct>:<Message-ID>`
        // key, an Exchange base64 id), which `appendingPathComponent` treats as a
        // SEPARATOR and silently nests outside the intended slot. See
        // `DraftAttachmentStorage.newStagingDirName()`.
        //
        // ORPHAN-ON-CRASH: a kill after this staging write but before the row adopts
        // it leaves an unreferenced opaque-UUID dir. That is a bounded disk leak —
        // never data loss — and does not grow during crash-free operation.
        let stagingDirName: String?
        if capAttachments.isEmpty {
            // N→0 (drop-all) or 0→0: the row will carry a nil dir; the OLD dir (if
            // any) is destroyed ONLY post-commit. No staging dir here.
            stagingDirName = nil
        } else {
            let staging = DraftAttachmentStorage.newStagingDirName()
            do {
                try DraftAttachmentStorage.saveAttachments(capAttachments, dirName: staging)
            } catch {
                // Staging write failed — nothing durable changed. Best-effort clean
                // the partial staging dir; the live dir is UNTOUCHED.
                DraftAttachmentStorage.deleteAttachments(dirName: staging)
                isSavingDraft = false
                sendError = "Failed to save attachments: \(error.localizedDescription)"
                return
            }
            stagingDirName = staging
        }

        // Persist before dismiss — if save fails, show error and do NOT dismiss.
        // This follows the "persist before acknowledge" principle (CLAUDE.md).
        //
        // Route through DraftStore.shared.save (NOT raw GRDB write): the store's
        // save() marks serverPushStatus "pushed" → "dirty" so pushDraftToServer
        // doesn't early-return. Without this, a 2nd-save-onwards draft never
        // actually reaches the server — queueDraftSave drains but pushDraft
        // sees `serverPushStatus == "pushed"` (from the previous push) and
        // bails before sending the update. `existing` was read fail-closed above.
        let draftToSave: Draft = {
            if var e = existing {
                e.toJSON = Draft.encodeStringArray(capTo)
                e.ccJSON = Draft.encodeStringArray(capCc)
                e.bccJSON = Draft.encodeStringArray(capBcc)
                e.subject = capSubject
                e.body = capBody
                e.updatedAt = now
                e.attachmentsDirName = stagingDirName
                return e
            }
            var d = Draft(
                id: capDraftId,
                accountId: account.id,
                toJSON: Draft.encodeStringArray(capTo),
                ccJSON: Draft.encodeStringArray(capCc),
                bccJSON: Draft.encodeStringArray(capBcc),
                subject: capSubject,
                body: capBody,
                replyToId: replyTo?.id,
                isForward: isForward,
                editHistoryJSON: nil,
                createdAt: now,
                updatedAt: now
            )
            d.attachmentsDirName = stagingDirName
            // T5.8 — stamp the reply target's ADDRESS beside its (mutable) PK, from
            // the SAME header `replyToId` was taken from one line above. Written only
            // on the INSERT branch: the `existing` branch above carries the original
            // stamp forward untouched, which is correct — the address the user
            // actually replied to is decided once, at creation, and never re-derived
            // from whatever happens to sit at that PK later.
            d.replyToProviderMessageId = replyTo?.messageId
            d.replyToUidValidity = replyTo?.observedUidValidity
            return d
        }()

        // The staging-cleanup catch covers ONLY the save. Once the save has
        // COMMITTED (either result), the staging dir's fate is decided by the
        // disposition below and NOTHING afterward (queueDraftSave, dismiss…) may
        // delete it — deleting it post-commit would destroy the now-LIVE dir.
        let saveResult: DraftStore.SaveResult
        do {
            saveResult = try await saveThroughGeneration(draftToSave)
        } catch {
            // The save threw / rolled back — nothing durable adopted our staging
            // dir. Delete ONLY the staging dir; leave the live dir UNTOUCHED
            // (persist-before-destroy).
            if case .deleteStaging(let dir) = ComposeDraftGuards.attachmentDisposition(
                saveApplied: false, stagingDir: stagingDirName, previousDir: previousDirName) {
                DraftAttachmentStorage.deleteAttachments(dirName: dir)
            }
            isSavingDraft = false
            sendError = "Failed to save draft: \(error.localizedDescription)"
            return
        }
        // Disposition-driven attachment cleanup (persist-before-destroy). The DB
        // has durably committed; only NOW is it safe to destroy files.
        switch ComposeDraftGuards.attachmentDisposition(
            saveApplied: saveResult == .applied,
            stagingDir: stagingDirName, previousDir: previousDirName
        ) {
        case .deleteSuperseded(let dir), .deleteStaging(let dir):
            DraftAttachmentStorage.deleteAttachments(dirName: dir)
        case .noCleanup:
            break
        }
        guard saveResult == .applied else {
            // A newer snapshot already won on disk — our snapshot was NOT adopted.
            // Its staging dir was destroyed above; the live dir is intact.
            isSavingDraft = false
            sendError = "Failed to save draft: \(DraftStore.DraftEpochAdmissionError.staleOrReserved.localizedDescription)"
            return
        }
        if DebugModeManager.isLoggingEnabled() {
            print("[ComposeView] Saved draft on cancel: id=\(draftId) prevStatus=\(existing?.serverPushStatus ?? "nil")")
        }
        // POST-COMMIT (outside the staging-cleanup catch). A throw here must NOT
        // reach any attachment-dir delete. Queue server push via PendingOperation
        // (crash-safe, retries on failure); queueDraftSave also refreshes the
        // Drafts-folder MessageHeader's snippet so the row preview reflects the body.
        await AccountManager.shared.queueDraftSave(draftId: draftId, accountId: account.id)
        isSavingDraft = false
        dismiss()
    }

    private func discardDraftAndDismiss() async {
        guard draftReadState != .error else {
            sendError = "This draft did not finish loading. Close and reopen it before discarding."
            return
        }

        // Load draft info before deleting — needed for server-side cleanup + optimistic UI removal.
        // Async read/write so the main actor isn't blocked behind a busy writer (compose-dismiss
        // freeze class) — this delete was a synchronous main-actor write on the discard path.
        // `draftId` (MainActor-isolated) is captured into a local for the @Sendable closure.
        //
        // PORT — v2final `discardDraftAndDismiss`'s F4 rule, now stated through
        // `ComposeDraftGuards.discardMayDelete`: a THROWN metadata read is NOT
        // absence. We need serverDraftId / folder / uidValidity to queue the remote
        // cleanup; without them a local delete would let the server copy re-sync and
        // REAPPEAR. DEFER the discard (row intact) and surface the error.
        let draftKey = draftId
        let readResult: Result<Draft?, Error>
        do {
            readResult = .success(try await AppDatabase.dbPool.read { db in
                try Draft.fetchOne(db, key: draftKey)
            })
        } catch {
            readResult = .failure(error)
        }
        guard ComposeDraftGuards.discardMayDelete(
            readState: ComposeDraftGuards.readState(readResult)) else {
            sendError = "The draft could not be verified, so it was not discarded."
            return
        }
        guard case .success(let loadedRecord) = readResult, let draftRecord = loadedRecord else {
            dismiss()
            return
        }
        let epoch = admissionCursor.newEpoch
        guard draftRecord.instanceEpoch == epoch else {
            sendError = "This draft changed in another compose window and was not discarded."
            return
        }

        // PORT 3f2cc4c34: cancel only this exact generation after authority
        // has been re-read and verified.
        let sessionKey = ActiveAgentTracker.composeSessionKey(
            draftId: draftRecord.id, epoch: epoch)
        let session = ChatPillState.shared.session(for: sessionKey)
        session.activeChatTask?.cancel()
        session.activeChatTask = nil
        ActiveAgentTracker.shared.clearWorking(sessionKey)
        ChatPillState.shared.removeSession(for: sessionKey)

        if draftRecord.serverDraftId != nil {
            guard let identity = await typedDeleteIdentity(for: draftRecord) else {
                sendError = "The server draft could not be safely identified, so it was not discarded."
                return
            }
            guard await AccountManager.shared.queueDraftDelete(
                identity: identity,
                accountId: draftRecord.accountId,
                folderPath: draftRecord.serverDraftFolderPath,
                draftId: draftRecord.id,
                instanceEpoch: epoch,
                deleteOwnedLocalDraft: true) else {
                sendError = "The server draft delete could not be saved, so the draft was not discarded."
                return
            }
        } else {
            do {
                guard try await DraftStore.shared.deleteAsync(
                    id: draftRecord.id, expectedInstanceEpoch: epoch) else {
                    sendError = "This draft changed in another compose window and was not discarded."
                    return
                }
                // MATCHED-DIR cleanup (v2final F0f, applied at the caller). Under
                // copy-on-write staging the on-disk directory is an opaque UUID, no
                // longer the draftId, so `DraftStore.deleteAsync`'s own
                // `deleteAttachments(dirName: id)` no longer names it. Destroy the
                // dir the ROW actually pointed at, and only AFTER the row delete has
                // committed (persist-before-destroy). Every other draft-delete site
                // (`AccountManagerActions` queueDraftDelete drain,
                // `AccountManagerOutbox` send finalize, `InboxViewModel` swipe,
                // `DraftStore.evictImpl`) already deletes by the row's own
                // `attachmentsDirName`, so this is the only gap.
                if let dir = draftRecord.attachmentsDirName {
                    DraftAttachmentStorage.deleteAttachments(dirName: dir)
                }
            } catch {
                sendError = "The draft could not be discarded: \(error.localizedDescription)"
                return
            }
        }
        dismiss()
    }

    private func typedDeleteIdentity(for draft: Draft) async -> DraftDeleteIdentity? {
        guard let serverId = draft.serverDraftId,
              !serverId.isEmpty,
              let kind = await AccountManager.shared.draftRuntimeIdentityKind(
                accountId: draft.accountId) else { return nil }
        switch kind {
        case .gmail:
            return .gmail(resourceId: serverId)
        case .outlook:
            return .outlook(graphId: serverId)
        case .demo:
            return .demo(localId: serverId)
        case .imap:
            guard let folder = draft.serverDraftFolderPath,
                  let epoch = draft.serverDraftUidValidity,
                  let uid = Int(serverId), uid > 0 else { return nil }
            return .imap(folder: folder, uidValidity: epoch, uid: uid)
        case .unknown:
            return nil
        }
    }

    // MARK: - Prepopulate

    private func prepopulate() {
        // Set initial From account
        if selectedAccount == nil {
            selectedAccount = resolvedAccount ?? navigationStore.accounts.first
        }

        // Apply prefill overrides (from agent tools)
        if let prefillTo { toTokens = prefillTo }
        if let prefillCc {
            ccTokens = prefillCc
            if !prefillCc.isEmpty { showCc = true }
        }
        if let prefillBcc {
            bccTokens = prefillBcc
            if !prefillBcc.isEmpty { showCc = true }
        }
        if let prefillSubject { subject = prefillSubject }
        if let prefillBody { messageBody = prefillBody }
        if let prefillAttachments, !prefillAttachments.isEmpty {
            attachments = prefillAttachments
        }

        if let reply = replyTo {
            if isForward {
                // Forward mode: empty To (unless prefilled), "Fwd:" subject, quoted body
                if prefillTo == nil { toTokens = [] }
                if prefillSubject == nil {
                    subject = ThreadUtils.forwardSubject(for: reply.subject)
                }
            } else {
                // Reply mode: To = reply address, "Re:" subject
                if prefillTo == nil {
                    let replyEmail = reply.replyTo ?? reply.fromAddress
                    toTokens = [replyEmail]
                    if !reply.from.isEmpty { toDisplayNames[replyEmail] = reply.from }
                }
                if prefillSubject == nil {
                    subject = ThreadUtils.replySubject(for: reply.subject)
                }
            }

            // Signature displayed separately below TextEditor
            currentSignature = resolvedAccount?.signature ?? ""

            // Quote shown separately below TextEditor
            let dateStr = reply.date.formatted(date: .abbreviated, time: .shortened)
            if isForward {
                quotedAttribution = "---------- Forwarded message ----------\nFrom: \(reply.from)\nDate: \(dateStr)\nSubject: \(reply.subject)"
            } else {
                quotedAttribution = "On \(dateStr), \(reply.from) wrote:"
            }

            // T5.8: fetch the quote body (and any forward attachments) through the
            // GUARDED atomic resolver, NOT a direct PK body fetch on the MUTABLE
            // `reply.id`. On a fresh compose the in-hand `reply` IS the user's
            // intent, so it supplies the expected address; a re-key or
            // purge-and-resync that has since put a different physical message at
            // that PK is then a positive mismatch and the body is DROPPED.
            let quote: Draft.ReplyQuote? = try? dbPool.read { db in
                try Draft.resolveReplyQuote(
                    draftKey: draftId, replyToId: reply.id, isForward: isForward,
                    expectedProviderMessageId: reply.messageId,
                    expectedUidValidity: reply.observedUidValidity,
                    db: db)
            }
            // ONLY a positively identity-confirmed body may populate the OUTBOUND
            // quote. The superseded `else` branch rendered `reply.snippet` — a cached
            // preview of whatever row the PK named — which bypasses the guard, so it
            // is deliberately gone. No confirmed body ⇒ no quote (`quotedHTML` stays
            // nil ⇒ `buildSendBody` emits the plain authored body).
            if let html = ComposeDraftGuards.outboundQuoteBody(
                confirmedBodyHTML: quote?.bodyHTML, capturedSnippet: reply.snippet
            ) {
                // Strip embedded .eml sections so reply/forward quotes only the
                // primary body — nested attached emails should not leak into the
                // quote (they're recipients' copies won't have our hide-CSS).
                quotedHTML = EmailFilter.stripEmbeddedEmlSections(html)
            }

            // Forward: carry original attachments over. Users expect Forward to include
            // the original attachments (not just .eml — PDFs, images, anything). Inline
            // CID images aren't in `attachmentsJSON` (they're tracked separately in
            // InlineImage by the provider), so no extra filtering is needed here.
            // FILTER OUT nested attachments (parentEmlSection != nil): those live
            // inside a `.eml` that we're ALSO carrying, so re-attaching them would
            // duplicate (recipient gets the PDF standalone AND inside the .eml).
            //
            // T5.8: the metadata AND the fetch target both come from the CONFIRMED
            // `quote`, never from the captured `reply` whose PK may now name an
            // impostor — attaching the old occupant's FILES to an outgoing forward is
            // the same leak as quoting its body, one step worse.
            if isForward, let confirmed = quote, let atts = confirmed.body?.attachments, !atts.isEmpty {
                let topLevel = atts.filter { $0.parentEmlSection == nil }
                if !topLevel.isEmpty {
                    carryForwardAttachments(from: confirmed.header, attachments: topLevel)
                }
            }
        } else {
            // New message — signature displayed separately
            currentSignature = resolvedAccount?.signature ?? ""
        }

        // Unified suggestion-bubble setup. Caller-supplied suggestedBody (agent
        // paths) always wins. For reply mode, fall back to fresh cachedReply
        // from DB — protects against caller-side staleness when background AI,
        // P2P sync, or a prior in-place edit updated cachedReply after the
        // caller's snapshot was captured.
        let suggestionToShow: String?
        if let suggestedBody, !suggestedBody.isEmpty {
            suggestionToShow = suggestedBody
        } else if let reply = replyTo, !isForward {
            let freshHeader = try? dbPool.read { db in
                try MessageHeader.fetchOne(db, key: reply.id)
            }
            suggestionToShow = freshHeader?.cachedReply
        } else {
            suggestionToShow = nil
        }
        if let suggested = suggestionToShow, !suggested.isEmpty {
            currentSuggestion = suggested
            withAnimation(.easeInOut(duration: 0.3)) {
                showingSuggestion = true
            }
        }

        // Undo-Send reopen path: DON'T snapshot initial state, so prefill
        // content appears as "unsaved changes" and close → save prompt fires.
        if !prefillTreatAsUnsavedChanges {
            snapshotInitialState()
        }
    }

    /// Download and re-attach the original message's attachments. Runs asynchronously;
    /// chips appear in the attachment list as downloads complete. Failures are logged
    /// and skipped — they do not block composing or surface errors to the user (the
    /// user can still manually attach files if needed).
    private func carryForwardAttachments(from reply: MessageHeader, attachments atts: [AttachmentInfo]) {
        print("[ComposeForward] Carrying over \(atts.count) attachment(s) from \(reply.id)")
        for att in atts {
            Task { @MainActor in
                do {
                    let data = try await AccountManager.shared.fetchAttachment(
                        for: reply, section: att.section, encoding: att.encoding
                    )
                    let draftAtt = DraftAttachment(
                        filename: att.filename,
                        mimeType: att.contentType,
                        data: data
                    )
                    self.attachments.append(draftAtt)
                    print("[ComposeForward] Attached \(att.filename) (\(data.count) bytes)")
                } catch {
                    print("[ComposeForward] Failed to carry \(att.filename): \(error)")
                }
            }
        }
    }

    /// Resolve contact display names for all current recipient tokens.
    /// Called after prepopulate() so agent-prefilled emails show contact names.
    private func resolveContactNames() {
        let allEmails = toTokens + ccTokens + bccTokens
        guard !allEmails.isEmpty else { return }
        let store = CNContactStore()
        let keys: [CNKeyDescriptor] = [
            CNContactGivenNameKey as CNKeyDescriptor,
            CNContactFamilyNameKey as CNKeyDescriptor,
            CNContactEmailAddressesKey as CNKeyDescriptor,
        ]
        for email in allEmails {
            // Skip if already resolved
            if toDisplayNames[email] != nil || ccDisplayNames[email] != nil || bccDisplayNames[email] != nil { continue }
            guard let contacts = try? store.unifiedContacts(
                matching: CNContact.predicateForContacts(matchingEmailAddress: email),
                keysToFetch: keys
            ), let contact = contacts.first else { continue }
            let name = [contact.givenName, contact.familyName]
                .filter { !$0.isEmpty }
                .joined(separator: " ")
            guard !name.isEmpty else { continue }
            if toTokens.contains(email) { toDisplayNames[email] = name }
            if ccTokens.contains(email) { ccDisplayNames[email] = name }
            if bccTokens.contains(email) { bccDisplayNames[email] = name }
        }
    }

    // MARK: - Build send body

    private func buildSendBody() -> (body: String, isHTML: Bool) {
        // RFC 3676 §4.3: signature separator is "-- \r\n" (CRLF for wire, \n for local)
        let sigText = currentSignature.isEmpty ? "" : "\n\n-- \n\(currentSignature)"

        guard let attribution = quotedAttribution, let html = quotedHTML else {
            // No quote — plain text with signature
            return (messageBody + sigText, false)
        }

        func escapeHTML(_ text: String) -> String {
            text.replacingOccurrences(of: "&", with: "&amp;")
                .replacingOccurrences(of: "<", with: "&lt;")
                .replacingOccurrences(of: ">", with: "&gt;")
                .replacingOccurrences(of: "\n", with: "<br>")
        }

        let aboveSig = sigBelowQuote ? "" : sigText
        let belowSig = sigBelowQuote ? sigText : ""

        func signatureHTML(_ sig: String) -> String {
            guard !sig.isEmpty else { return "" }
            let escapedSig = escapeHTML(currentSignature)
            return "<div class=\"signature\">-- <br>\(escapedSig)</div>"
        }

        let userText = escapeHTML(messageBody)
        let escapedAttribution = escapeHTML(attribution)
        let aboveSigHTML = sigBelowQuote ? "" : signatureHTML(aboveSig)
        let belowSigHTML = sigBelowQuote ? signatureHTML(belowSig) : ""

        return ("""
        <div style="font-family: -apple-system, sans-serif; font-size: 16px; line-height: 1.5;">
        \(userText)
        </div>
        \(aboveSigHTML)
        <br>
        <div style="font-size: 13px; color: #888;">\(escapedAttribution)</div>
        <blockquote style="border-left: 3px solid #ccc; margin: 8px 0 0 0; padding: 0 0 0 12px;">
        \(html)
        </blockquote>
        \(belowSigHTML)
        """, true)
    }

    // MARK: - File Import

    private func handleFileImport(_ result: Result<[URL], Error>) {
        switch result {
        case .success(let urls):
            for url in urls {
                guard url.startAccessingSecurityScopedResource() else { continue }
                defer { url.stopAccessingSecurityScopedResource() }
                if let data = try? Data(contentsOf: url) {
                    let mimeType = UTType(filenameExtension: url.pathExtension)?.preferredMIMEType ?? "application/octet-stream"
                    attachments.append(DraftAttachment(filename: url.lastPathComponent, mimeType: mimeType, data: data))
                }
            }
        case .failure(let error):
            sendError = "Failed to import files: \(error.localizedDescription)"
        }
    }

    // MARK: - Send

    private func trySend() {
        let bodyEmpty = messageBody.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        if bodyEmpty {
            showEmptyBodyPrompt = true
            return
        }
        Task { await send() }
    }

    private func send() async {
        // Reentrancy / double-send guard. Once we commit to sending we flip
        // `isSending` (swaps the Send button for a spinner), so a second tap
        // cannot fire a second send during the now-SUSPENDING async persistence.
        // Before the async conversion, the synchronous writes blocked the main
        // thread, which implicitly prevented a second tap; suspending the main
        // actor reopens that window, so the guard is mandatory. The persistence
        // firewall (queueSend dedups on draftId) is the backstop. `isSending` is
        // reset on every early-return / error path below so the user can retry.
        guard !isSending else { return }
        // B1 defense-in-depth: the Send button is disabled while
        // `attachmentLoadFailed`, but guard the action too so no alternate path
        // (e.g. the empty-body prompt) can send a silent subset of attachments.
        guard !attachmentLoadFailed else {
            sendError = "Some attachments couldn't be loaded. Reopen the draft to retry, or discard it, before sending."
            return
        }
        guard draftReadState != .error else {
            sendError = "This draft did not finish loading. Close and reopen it before sending."
            return
        }
        guard let account = resolvedAccount else {
            sendError = "No account available to send from."
            return
        }

        // Commit any pending input
        var finalTo = toTokens
        let pendingTo = toInput.trimmingCharacters(in: .whitespaces)
        if !pendingTo.isEmpty { finalTo.append(pendingTo) }

        var finalCc = ccTokens
        let pendingCc = ccInput.trimmingCharacters(in: .whitespaces)
        if !pendingCc.isEmpty { finalCc.append(pendingCc) }

        var finalBcc = bccTokens
        let pendingBcc = bccInput.trimmingCharacters(in: .whitespaces)
        if !pendingBcc.isEmpty { finalBcc.append(pendingBcc) }

        // Recipient cap — defense in depth. TokenField/picker guards usually
        // prevent reaching this, but reply-all prefill can exceed the cap.
        let totalFinal = finalTo.count + finalCc.count + finalBcc.count
        if totalFinal > SyncConfig.outboxMaxRecipients {
            sendError = "Too many recipients. Limit is \(SyncConfig.outboxMaxRecipients) total across To, Cc, and Bcc."
            return
        }

        let (sendBody, isHTML) = buildSendBody()
        // Threading headers for reply / reply-all / forward. Single source of
        // truth (ThreadUtils) builds the In-Reply-To + full References chain and,
        // for Gmail, the conversation threadId (guarded by account + subject
        // match). Forward threads like reply per Gmail convention. See ADR-IOS-043.
        let threadHeaders = ThreadUtils.outgoingThreadHeaders(
            replyTo: replyTo,
            sendAccountId: account.id,
            sendSubject: subject,
            providerKind: account.provider
        )
        let outbound = DraftMessage(
            to: finalTo,
            cc: finalCc,
            bcc: finalBcc,
            subject: subject,
            body: sendBody,
            isHTML: isHTML,
            inReplyTo: threadHeaders.inReplyTo,
            references: threadHeaders.references,
            attachments: attachments,
            threadId: threadHeaders.threadId
        )
        let snapshot = AuthoredSendSnapshot(
            account: account,
            draftId: draftId,
            instanceEpoch: admissionCursor.newEpoch,
            to: finalTo,
            cc: finalCc,
            bcc: finalBcc,
            subject: subject,
            authoredBody: messageBody,
            attachments: attachments,
            replyToHeaderId: replyTo?.id,
            replyToProviderMessageId: replyTo?.messageId,
            replyToUidValidity: replyTo?.observedUidValidity,
            isForward: isForward,
            outbound: outbound)

        guard agentSendFence.claimSend() else {
            sendError = "Wait for the draft edit to finish before sending."
            return
        }
        var sendWasAdmitted = false
        defer {
            if !sendWasAdmitted { agentSendFence.releaseFailedSend() }
        }
        isSending = true

        // Capture existing draft (server-side metadata preserved through save-before-send).
        // Async read so the main actor isn't blocked behind a busy writer. `draftId`
        // (MainActor-isolated) is captured into a local for the @Sendable closure.
        let sendReadResult: Result<Draft?, Error>
        do {
            sendReadResult = .success(try await AppDatabase.dbPool.read { db in
                try Draft.fetchOne(db, key: snapshot.draftId)
            })
        } catch {
            sendReadResult = .failure(error)
        }
        let sendReadState = ComposeDraftGuards.effectiveMutationState(
            initialLoad: draftReadState,
            perOp: ComposeDraftGuards.readState(sendReadResult))
        guard sendReadState != .error else {
            isSending = false
            sendError = "The draft could not be verified before sending."
            return
        }
        let draftRecord: Draft?
        if case .success(let value) = sendReadResult {
            draftRecord = value
        } else {
            draftRecord = nil
        }

        // Save-before-send — uses the existing draft infra so Undo-Send can
        // reopen compose with the exact contents (subject, body, recipients,
        // attachments). Flow: user hits Send → save draft → queue send.
        // The local draft is deleted on send COMPLETION
        // (AccountManagerOutbox.finalizeOutboxMessage), NOT at claim time —
        // transient SMTP failures leave the draft available for retry/edit.
        // PORT — v2final `send()`'s F0d COPY-ON-WRITE staging. The superseded form
        // wrote into `draftRecord?.attachmentsDirName ?? snapshot.draftId`: the LIVE
        // directory, so a save that then failed left the row pointing at files this
        // write had already overwritten, and the `?? snapshot.draftId` fallback used
        // a raw draftId as a path component — a `reply:<acct>:<Message-ID>` key or an
        // Exchange base64 id may contain `/`, which `appendingPathComponent` treats
        // as a SEPARATOR, nesting the "directory" outside its intended slot. The
        // staging name is now an opaque UUID (no separators; see
        // `DraftAttachmentStorage.newStagingDirName()`), written fresh, adopted only
        // by a committed save.
        //
        // The SEND itself never depends on this directory: the outbound attachment
        // bytes travel in `snapshot.outbound` and `AccountManagerOutbox
        // .persistQueuedSend` stages its OWN outbox copy. This staging exists solely
        // so an Undo-Send reopen finds the attachments on the retained Draft row.
        let previousDirName = draftRecord?.attachmentsDirName
        let stagingDirName: String?
        if snapshot.attachments.isEmpty {
            stagingDirName = nil
        } else {
            let staging = DraftAttachmentStorage.newStagingDirName()
            do {
                try DraftAttachmentStorage.saveAttachments(
                    snapshot.attachments, dirName: staging)
            } catch {
                // Nothing durable changed; the live dir is UNTOUCHED.
                DraftAttachmentStorage.deleteAttachments(dirName: staging)
                isSending = false
                sendError = "The draft could not be saved before sending: \(error.localizedDescription)"
                return
            }
            stagingDirName = staging
        }
        do {
            let nowEpoch = Date().timeIntervalSince1970

            var ownedDraft = Draft(
                id: snapshot.draftId,
                accountId: snapshot.account.id,
                toJSON: Draft.encodeStringArray(snapshot.to),
                ccJSON: Draft.encodeStringArray(snapshot.cc),
                bccJSON: Draft.encodeStringArray(snapshot.bcc),
                subject: snapshot.subject,
                body: snapshot.authoredBody,
                replyToId: snapshot.replyToHeaderId ?? draftRecord?.replyToId,
                isForward: snapshot.isForward,
                editHistoryJSON: draftRecord?.editHistoryJSON,
                createdAt: draftRecord?.createdAt ?? nowEpoch,
                updatedAt: nowEpoch
            )
            // Preserve v24 server-sync fields if present.
            ownedDraft.serverDraftId = draftRecord?.serverDraftId
            ownedDraft.serverPushStatus = draftRecord?.serverPushStatus
            ownedDraft.rfc822MessageId = draftRecord?.rfc822MessageId
            // …and v72's epoch, which travels with `serverDraftId` and is meaningless
            // apart from it. Carrying the address forward while dropping the numbering
            // it belongs to would leave a UID nothing can trust, silently demoting every
            // later delete of this draft to the Message-ID-search arm.
            ownedDraft.serverDraftUidValidity = draftRecord?.serverDraftUidValidity
            ownedDraft.serverDraftFolderPath = draftRecord?.serverDraftFolderPath
            // T5.8 — the reply-target ADDRESS stamp must be taken from the SAME
            // source that supplied `replyToId` just above, branch for branch. An
            // independent `snapshot.x ?? draftRecord?.x` coalesce could pair the
            // snapshot's PK with the stored row's stamp (or the reverse), i.e. an
            // address describing a DIFFERENT message than the PK beside it — which
            // silently disarms the guard instead of tightening it.
            if snapshot.replyToHeaderId != nil {
                ownedDraft.replyToProviderMessageId = snapshot.replyToProviderMessageId
                ownedDraft.replyToUidValidity = snapshot.replyToUidValidity
            } else {
                ownedDraft.replyToProviderMessageId = draftRecord?.replyToProviderMessageId
                ownedDraft.replyToUidValidity = draftRecord?.replyToUidValidity
            }
            // N→0 leaves this nil and the superseded dir is destroyed post-commit.
            ownedDraft.attachmentsDirName = stagingDirName

            guard try await saveThroughGeneration(ownedDraft) == .applied else {
                throw DraftStore.DraftEpochAdmissionError.staleOrReserved
            }
            // Disposition-driven cleanup, AFTER the durable commit
            // (persist-before-destroy). `.applied` ⇒ the row now points at the
            // staging dir (or nil), so the SUPERSEDED dir is safe to destroy and can
            // never be the live one.
            if case .deleteSuperseded(let dir) = ComposeDraftGuards.attachmentDisposition(
                saveApplied: true, stagingDir: stagingDirName, previousDir: previousDirName) {
                DraftAttachmentStorage.deleteAttachments(dirName: dir)
            }
        } catch {
            // The save threw / was not adopted — nothing durable references our
            // staging dir. Destroy ONLY it; the live dir is UNTOUCHED.
            if case .deleteStaging(let dir) = ComposeDraftGuards.attachmentDisposition(
                saveApplied: false, stagingDir: stagingDirName, previousDir: previousDirName) {
                DraftAttachmentStorage.deleteAttachments(dirName: dir)
            }
            isSending = false
            sendError = "The draft could not be saved before sending: \(error.localizedDescription)"
            return
        }

        // Queue to outbox (persists to GRDB + disk, then drains async).
        // If persistence fails, show error — do NOT dismiss or the message is lost.
        let outboxId: String
        do {
            outboxId = try await AccountManager.shared.queueSend(
                draft: snapshot.outbound,
                from: snapshot.account,
                replyToHeaderId: snapshot.replyToHeaderId,
                isForward: snapshot.isForward,
                serverDraftId: draftRecord?.serverDraftId,
                draftUidValidity: draftRecord?.serverDraftUidValidity,
                draftServerFolderPath: draftRecord?.serverDraftFolderPath,
                serverDraftGmailMessageId: {
                    guard case .gmail(_, let containedMessageId)? = openAuthority?.address else {
                        return nil
                    }
                    return containedMessageId
                }(),
                draftId: snapshot.draftId,
                instanceEpoch: snapshot.instanceEpoch
            )
        } catch {
            // Persistence failed — the message is NOT queued. Re-enable Send so the
            // user can retry (their last chance to preserve the message; never
            // dismiss on failure — Outbox Reliability Rule 1).
            isSending = false
            sendError = "Failed to save message to outbox: \(error.localizedDescription)"
            // Report to the agent tool (if any) before returning so the LLM
            // sees the structured failure instead of the eventual `.cancelled`
            // that `.onDisappear` would fire when the user eventually closes.
            onAgentOutcome?(.failed("queueSend: \(error.localizedDescription)"))
            return
        }
        // Present the Gmail-style undo-send toast. Shown at RootView scope, so
        // it persists after this compose view dismisses.
        let toSummary: String
        if snapshot.to.isEmpty {
            toSummary = snapshot.cc.isEmpty ? "" : "Cc: \(snapshot.cc.first ?? "")"
        } else {
            let head = snapshot.to.prefix(2).joined(separator: ", ")
            let tail = snapshot.to.count > 2 ? " +\(snapshot.to.count - 2)" : ""
            toSummary = "To: \(head)\(tail)"
        }
        PendingSendService.shared.present(
            outboxId: outboxId,
            draftId: snapshot.draftId,
            instanceEpoch: snapshot.instanceEpoch,
            toSummary: toSummary
        )
        sendWasAdmitted = true

        // Report success to the agent tool (if any) before dismissing. Fires
        // at outbox-persistence granularity, not SMTP — this is the
        // trade-off for the 5-second undo window. `.onDisappear` will fire
        // `.cancelled` after dismiss, but
        // `ComposeOutcomeState.tryResolve` makes that a no-op.
        onAgentOutcome?(.sent)

        dismiss()
    }

}

// MARK: - Token Field (email chips with search dropdown)

private struct TokenField: View {
    @Binding var tokens: [String]
    @Binding var input: String
    let displayNames: [String: String]
    let searchResults: [ContactResult]
    let onFocus: () -> Void
    let onSelectContact: (ContactResult) -> Void
    /// Closure that returns whether the combined To+Cc+Bcc recipient count is
    /// under the hard cap (outboxMaxRecipients). When false, TextField is
    /// disabled and commitInput is a no-op — user must delete a chip to add
    /// another. Passed in from ComposeView so it sees the combined count
    /// across all three fields, not just this TokenField's tokens.
    let canAddMore: () -> Bool
    /// Shared across To/Cc/Bcc so only one chip reveals its full address at a
    /// time. Set to "<fieldKey>:<token>" on tap; nil to hide.
    @Binding var revealedChipKey: String?
    /// Field identifier used to namespace `revealedChipKey` (e.g. "to", "cc",
    /// "bcc") so the same email appearing in multiple fields is unambiguous.
    let fieldKey: String
    @FocusState private var isFocused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            // Tokens + inline input
            VStack(alignment: .leading, spacing: 4) {
                // All tokens except the last — each on its own line
                if tokens.count > 1 {
                    ForEach(tokens.dropLast(), id: \.self) { token in
                        tokenChip(token)
                    }
                }

                // Last token + inline TextField on the same line
                HStack(spacing: 4) {
                    if let lastToken = tokens.last {
                        tokenChip(lastToken)
                    }
                    TextField("", text: $input)
                        .font(.subheadline)
                        .textContentType(.emailAddress)
                        .keyboardType(.emailAddress)
                        .autocorrectionDisabled()
                        .textInputAutocapitalization(.never)
                        .focused($isFocused)
                        .disabled(!canAddMore())
                        .onSubmit {
                            commitInput()
                        }
                        .onChange(of: isFocused) { _, focused in
                            if focused {
                                onFocus()
                                revealedChipKey = nil
                            }
                            if !focused { commitInput() }
                        }
                }
            }

            // Contact search dropdown — scrollable
            if !searchResults.isEmpty && isFocused {
                ScrollView {
                    VStack(alignment: .leading, spacing: 0) {
                        ForEach(searchResults.prefix(5)) { contact in
                            Button {
                                onSelectContact(contact)
                            } label: {
                                VStack(alignment: .leading, spacing: 2) {
                                    if !contact.name.isEmpty {
                                        Text(contact.name)
                                            .font(.subheadline)
                                            .foregroundStyle(.primary)
                                    }
                                    Text(contact.email)
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                }
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .padding(.horizontal, 8)
                                .padding(.vertical, 6)
                            }
                            if contact.id != searchResults.prefix(5).last?.id {
                                Divider()
                            }
                        }
                    }
                }
                .frame(maxHeight: 200)
                .background(Color(.systemGray6))
                .clipShape(RoundedRectangle(cornerRadius: 8))
                .padding(.top, 4)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func tokenChip(_ token: String) -> some View {
        let key = "\(fieldKey):\(token)"
        let isRevealed = revealedChipKey == key
        let displayText = isRevealed ? token : (displayNames[token] ?? token)
        return HStack(spacing: 4) {
            Text(displayText)
                .font(.subheadline)
                .lineLimit(1)
                .fixedSize(horizontal: displayText.count <= 20, vertical: false)
            Button {
                tokens.removeAll { $0 == token }
                revealedChipKey = nil
            } label: {
                Image(systemName: "xmark.circle.fill")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .background(isRevealed ? Theme.accent.opacity(0.18) : Color(.systemGray5))
        .clipShape(Capsule())
        .layoutPriority(1)
        .contentShape(Capsule())
        .onTapGesture {
            revealedChipKey = isRevealed ? nil : key
        }
    }

    private func commitInput() {
        let trimmed = input.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return }
        // Dedup: if a case-insensitive match already exists, move it to the
        // end (the position the user is adding to) instead of creating two
        // chips. Moves don't change the count, so the cap only gates genuinely
        // new additions — when the cap blocks, keep the text in the field so
        // the user sees why and can delete a chip to make room.
        let key = trimmed.lowercased()
        let isMove = tokens.contains { $0.lowercased() == key }
        guard isMove || canAddMore() else { return }
        tokens.removeAll { $0.lowercased() == key }
        tokens.append(trimmed)
        input = ""
    }
}

// MARK: - Smart UIScrollView auto-scroll override

/// UIScrollView subclass that rewrites `scrollRectToVisible(_:animated:)` to be
/// caret-aware, keyboard-aware, and smoothly animated.
///
/// **Problem:** When a UIKit `UITextView` (the backing view for SwiftUI `TextEditor`) has
/// `isScrollEnabled = false` (SwiftUI's `.scrollDisabled(true)`), UIKit propagates
/// scroll-to-cursor requests to the enclosing `UIScrollView` by calling
/// `scrollRectToVisible`. The rect it passes is the **whole text view frame** — often
/// hundreds of points tall. `adjustedContentInset` does NOT include the keyboard in
/// modern iOS, so the default behavior performs large, wrong-direction scrolls that
/// leave the cursor near/behind the keyboard.
///
/// **Fix:**
/// 1. Track the current keyboard frame via `UIResponder.keyboardWillChangeFrameNotification`.
/// 2. Compute the real visible area by subtracting the keyboard intersection.
/// 3. If the incoming rect is larger than the visible area, substitute the caret rect
///    of the first-responder UITextView inside this scroll view.
/// 4. If the caret is already fully visible (in the real, keyboard-aware visible area),
///    do nothing — no scroll at all.
/// 5. Otherwise, pad the caret rect with comfortable breathing room and animate the
///    scroll with a `UIViewPropertyAnimator` for a smoother feel than the default.
///
/// No stored properties are added because `object_setClass` cannot change instance
/// size. State is held in `static` members.
final class CaretAwareUIScrollView: UIScrollView {
    /// Current on-screen keyboard frame (in screen coordinates), or `.zero` if hidden.
    /// Exposed as `internal` so tests can simulate keyboard frames without
    /// posting real UIKit notifications.
    static var currentKeyboardFrame: CGRect = .zero
    private static var keyboardObservers: [NSObjectProtocol] = []
    private static var scrollAnimator: UIViewPropertyAnimator?

    private static func ensureKeyboardObservation() {
        guard keyboardObservers.isEmpty else { return }
        let center = NotificationCenter.default
        keyboardObservers.append(
            center.addObserver(
                forName: UIResponder.keyboardWillChangeFrameNotification,
                object: nil,
                queue: .main
            ) { notification in
                // Extract the Sendable CGRect outside the MainActor block so we don't
                // need to send the non-Sendable Notification across the isolation boundary.
                let frame = notification.userInfo?[UIResponder.keyboardFrameEndUserInfoKey] as? CGRect
                // queue: .main guarantees execution on the main thread; the assumeIsolated
                // call lets us mutate main-actor-isolated static state from a @Sendable closure.
                MainActor.assumeIsolated {
                    if let frame {
                        currentKeyboardFrame = frame
                    }
                }
            }
        )
        keyboardObservers.append(
            center.addObserver(
                forName: UIResponder.keyboardWillHideNotification,
                object: nil,
                queue: .main
            ) { _ in
                MainActor.assumeIsolated {
                    currentKeyboardFrame = .zero
                }
            }
        )
    }

    override func scrollRectToVisible(_ rect: CGRect, animated: Bool) {
        Self.ensureKeyboardObservation()

        let visibleRect = visibleAreaAboveKeyboard()
        let firstResponderTextView = Self.findFirstResponderTextView(in: self)

        // If the incoming rect is taller than the visible area, it's the whole TextEditor
        // frame rather than a caret. Substitute the caret rect of the first-responder
        // UITextView inside this scroll view so we scroll minimally to the cursor.
        let focusRect: CGRect
        if rect.height > visibleRect.height, let textView = firstResponderTextView {
            let position = textView.selectedTextRange?.start ?? textView.beginningOfDocument
            let caretRect = textView.caretRect(for: position)
            if !caretRect.isNull && !caretRect.isInfinite {
                focusRect = convert(caretRect, from: textView)
            } else {
                focusRect = rect
            }
        } else {
            focusRect = rect
        }

        // If the focus rect is already fully inside the real visible area (above the
        // keyboard), do nothing. This is the main guard against unnecessary jumps.
        if visibleRect.contains(focusRect) {
            return
        }

        // Pad the focus rect so the cursor lands with comfortable breathing room,
        // not right at the edge of the keyboard. ~80pt ≈ 4 lines of body text.
        let paddedRect = focusRect.insetBy(dx: 0, dy: -80)

        // Compute the target content offset manually so we can drive the animation
        // ourselves via a UIViewPropertyAnimator (smoother than UIKit's default curve).
        let targetOffset = Self.contentOffsetThatShows(
            target: paddedRect,
            within: visibleRect,
            currentOffset: contentOffset,
            contentSize: contentSize,
            boundsHeight: bounds.height,
            insets: adjustedContentInset
        )

        Self.scrollAnimator?.stopAnimation(true)
        let animator = UIViewPropertyAnimator(duration: 0.28, dampingRatio: 0.9) { [weak self] in
            self?.contentOffset = targetOffset
        }
        animator.startAnimation()
        Self.scrollAnimator = animator
    }

    /// Computes the scroll view's visible content area, subtracting any intersecting
    /// keyboard (tracked via `currentKeyboardFrame`). `internal` for testability.
    func visibleAreaAboveKeyboard() -> CGRect {
        var rect = bounds.inset(by: adjustedContentInset)
        guard Self.currentKeyboardFrame != .zero, window != nil else {
            return rect
        }
        // Keyboard frame is in window/screen coordinates; convert into our own.
        let keyboardInSelf = convert(Self.currentKeyboardFrame, from: nil)
        if keyboardInSelf.minY > rect.minY && keyboardInSelf.minY < rect.maxY {
            rect.size.height = keyboardInSelf.minY - rect.minY
        }
        return rect
    }

    /// Pure math: compute the content offset that brings `target` into the `visible`
    /// area while clamping to the valid scroll range. Takes all dependencies as
    /// parameters so it can be unit-tested without constructing a UIScrollView.
    static func contentOffsetThatShows(
        target: CGRect,
        within visible: CGRect,
        currentOffset: CGPoint,
        contentSize: CGSize,
        boundsHeight: CGFloat,
        insets: UIEdgeInsets
    ) -> CGPoint {
        var offset = currentOffset
        if target.minY < visible.minY {
            offset.y -= (visible.minY - target.minY)
        } else if target.maxY > visible.maxY {
            offset.y += (target.maxY - visible.maxY)
        }
        // Clamp to the valid scroll range.
        let maxOffset = max(-insets.top, contentSize.height + insets.bottom - boundsHeight)
        let minOffset = -insets.top
        offset.y = max(minOffset, min(offset.y, maxOffset))
        return offset
    }

    private static func findFirstResponderTextView(in view: UIView) -> UITextView? {
        if let tv = view as? UITextView, tv.isFirstResponder {
            return tv
        }
        for sub in view.subviews {
            if let found = findFirstResponderTextView(in: sub) {
                return found
            }
        }
        return nil
    }
}

/// Invisible SwiftUI view that walks the UIKit view hierarchy to find the enclosing
/// `UIScrollView` and swaps its class to `CaretAwareUIScrollView` at runtime.
/// Use as a `.background` on the content of a SwiftUI `ScrollView`.
private struct DisableAutoScrollToVisible: UIViewRepresentable {
    func makeUIView(context: Context) -> UIView {
        let view = UIView()
        view.isUserInteractionEnabled = false
        view.backgroundColor = .clear
        return view
    }

    func updateUIView(_ uiView: UIView, context: Context) {
        DispatchQueue.main.async {
            guard let scrollView = uiView.enclosingUIScrollView() else { return }
            if !scrollView.isKind(of: CaretAwareUIScrollView.self) {
                object_setClass(scrollView, CaretAwareUIScrollView.self)
            }
        }
    }
}

extension UIView {
    /// Walks up the superview chain to find the first enclosing `UIScrollView`.
    /// Returns nil if no scroll view ancestor exists.
    func enclosingUIScrollView() -> UIScrollView? {
        var current: UIView? = self.superview
        while let view = current {
            if let scroll = view as? UIScrollView {
                return scroll
            }
            current = view.superview
        }
        return nil
    }
}

// MARK: - Lifecycle Tracker (agent-outcome fallback)

/// Tracks the ComposeView's lifetime via ARC so agent-tool continuations
/// cannot hang if `.onDisappear` misfires. On `deinit` (view released), if
/// `.onDisappear` didn't mark the tracker, runs the fallback on MainActor —
/// `composePresentationDidEnd()` + `onAgentOutcome?(.cancelled)`. Always
/// safe: the outcome's `ComposeOutcomeState.tryResolve` de-duplicates, and
/// `didEndPresentationScope` guards the router hook.
///
/// NSLock on the flag because deinit may run on any thread (ARC) while
/// `.onDisappear` always runs on MainActor.
final class ComposeLifecycleTracker: @unchecked Sendable {
    private let lock = NSLock()
    private var _disappearedNormally = false
    private var _fallback: (@Sendable () -> Void)?

    /// Called from `.onAppear` with a closure that fires the agent
    /// cancellation outcome + `composePresentationDidEnd` on MainActor.
    /// Multiple `armFallback` calls are allowed — only the latest survives
    /// (SwiftUI may re-fire `.onAppear` if the view is hidden + re-shown).
    func armFallback(_ fallback: @escaping @Sendable () -> Void) {
        lock.withLock {
            _disappearedNormally = false  // reset on each appearance
            _fallback = fallback
        }
    }

    /// Called from `.onDisappear`. Marks the tracker so its deinit skips the
    /// fallback — the synchronous path already fired the router hook + outcome.
    func markDisappearedNormally() {
        lock.withLock {
            _disappearedNormally = true
        }
    }

    deinit {
        let shouldFire: Bool
        let fallback: (@Sendable () -> Void)?
        (shouldFire, fallback) = lock.withLock {
            (!_disappearedNormally, _fallback)
        }
        if shouldFire, let fallback {
            fallback()
        }
    }
}
