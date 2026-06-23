/* This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at https://mozilla.org/MPL/2.0/. */

import SwiftUI
import Contacts
import GRDB
import PhotosUI
import TipKit
import UniformTypeIdentifiers

struct ComposeView: View {
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
    @State private var showDiscardPrompt = false
    @State private var showEmptyBodyPrompt = false
    @State private var isSavingDraft = false
    @State private var loadedDraft = false
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
    /// Server draft header info for cleanup on send. Set when opening a server draft
    /// that has no matching local Draft record (e.g., draft created by another client).
    var serverDraftHeader: MessageHeader?
    /// Fires when the user either sends, fails to persist, or dismisses —
    /// exactly once per compose session, via `ComposeOutcomeState.tryResolve`
    /// upstream. Non-agent compose entry points leave this `nil` and the
    /// calls below become no-ops.
    var onAgentOutcome: (@MainActor (ComposeOutcome) -> Void)? = nil

    /// Defense against any path that destroys the view without firing
    /// `.onDisappear` — SwiftUI doesn't formally guarantee `.onDisappear`
    /// fires in every edge case (memory-pressure view reclamation,
    /// unexpected hierarchy tear-downs). If the tracker's `deinit` runs
    /// without `.onDisappear` having cleared the flag, the fallback fires
    /// `.cancelled` + `composePresentationDidEnd()` on the MainActor so the
    /// agent continuation never hangs. Always safe — `tryResolve` + the
    /// `didEndPresentationScope` flag make duplicate calls no-ops.
    @State private var lifecycleTracker = ComposeLifecycleTracker()

    private var dbPool: DatabasePool { AppDatabase.dbPool }

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
                            .disabled(toTokens.isEmpty || subject.isEmpty)
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
            .onChange(of: chatExpanded) { _, expanded in
                if expanded {
                    bodyFocused = false
                    UIApplication.shared.sendAction(#selector(UIResponder.resignFirstResponder), to: nil, from: nil, for: nil)
                }
            }
            // Pulse driver — hoisted off the editor so it runs while the bubble is up too.
            .onChange(of: aiWorking) { _, working in
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
            .onAppear {
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
                contactSearch.requestAccess()
                loadDraftOrPrepopulate()
                resolveContactNames()
                withAnimation(.spring(response: 0.5, dampingFraction: 0.7).delay(0.15)) {
                    pillAppeared = true
                }
            }
            // ADR-IOS-030: Track ComposeView lifecycle so AgentToolRouter's FIFO queue
            // knows when the compose UI is busy. Counts every presentation path
            // (manual New, contact, reply, replyAll, forward, agent compose, agent draft).
            .onAppear {
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
            .onDisappear {
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
            .onChange(of: selectedAccount) {
                currentSignature = selectedAccount?.signature ?? ""
            }
            .onChange(of: photoPickerItems) { _, items in
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
            // Phase 3: dissolve back in with new text
            withAnimation(.easeOut(duration: 0.4)) {
                isApplyingEdit = false
            }
            print("[ComposeView] applyInlineEdit: done, isApplyingEdit=false")
        }
    }

    /// Write the edited suggestion to `messageHeader.cachedReply` so reopens see it.
    private func persistCachedReply(_ text: String) {
        guard let reply = replyTo else { return }
        Task { await Self.writeCachedReplyToDB(text, headerId: reply.id, db: dbPool) }
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
    private func loadDraftOrPrepopulate() {
        guard !loadedDraft else { return }
        loadedDraft = true

        // Try loading persisted draft
        print("[ComposeView] loadDraftOrPrepopulate: draftId=\(draftId) prefillDraftId=\(prefillDraftId ?? "nil")")
        if let draft = try? AppDatabase.dbPool.read({ db in try Draft.fetchOne(db, key: draftId) }) {
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
            // user sees what was saved).
            if let dir = draft.attachmentsDirName {
                attachments = DraftAttachmentStorage.loadAttachments(dirName: dir)
            }

            // For reply/forward: set up quoted text and attribution (but NOT AI suggestion).
            // Resolve reply from replyTo param OR from draft record (PK + stableId fallback).
            let resolvedReply: MessageHeader? = replyTo
                ?? Draft.resolveReplyToHeader(draftKey: draftId, replyToId: draft.replyToId, isForward: draft.isForward)
            if let reply = resolvedReply {
                let resolvedForward = replyTo != nil ? isForward : draft.isForward
                selectedAccount = resolvedAccount ?? navigationStore.accounts.first
                currentSignature = resolvedAccount?.signature ?? ""
                let dateStr = reply.date.formatted(date: .abbreviated, time: .shortened)
                if resolvedForward {
                    quotedAttribution = "---------- Forwarded message ----------\nFrom: \(reply.from)\nDate: \(dateStr)\nSubject: \(reply.subject)"
                } else {
                    quotedAttribution = "On \(dateStr), \(reply.from) wrote:"
                }
                let body = try? AppDatabase.dbPool.read { db in try MessageBody.fetchOne(db, key: reply.id) }
                if let html = body?.htmlContent { quotedHTML = EmailFilter.stripEmbeddedEmlSections(html) }
                else if !reply.snippet.isEmpty { quotedHTML = "<p>\(reply.snippet)</p>" }
            } else {
                // New compose: restore account
                selectedAccount = resolvedAccount ?? navigationStore.accounts.first
                currentSignature = resolvedAccount?.signature ?? ""
            }

            print("[ComposeView] Loaded draft: id=\(draftId) subject=\(subject.prefix(40))")
            snapshotInitialState()
            return
        }

        // No draft found — normal prepopulate
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

    /// Cheap summary used to detect attachment changes without comparing raw
    /// Data blobs. Two attachment lists are equal iff their fingerprints match.
    private func attachmentsFingerprint(_ list: [DraftAttachment]) -> [String] {
        list.map { "\($0.filename)|\($0.data.count)|\($0.mimeType)|\($0.isAlternative)" }
    }

    // MARK: - Close / Discard

    /// Handle close button: prompt Save/Discard/Cancel when there are actual changes.
    /// Draft is saved BEFORE dismiss (persist before acknowledge).
    private func closeCompose() async {
        let hasContent = !subject.isEmpty || !messageBody.isEmpty || !toTokens.isEmpty
            || !attachments.isEmpty
        let hasChanges = subject != initialSubject || messageBody != initialBody
            || toTokens != initialToTokens || ccTokens != initialCcTokens || bccTokens != initialBccTokens
            || attachmentsFingerprint(attachments) != initialAttachmentsFingerprint
        if hasContent && hasChanges {
            showDiscardPrompt = true
        } else {
            // No content or no changes — just dismiss (delete empty draft if it exists).
            // Async delete so the main actor isn't blocked behind a busy writer.
            if !hasContent {
                do { try await DraftStore.shared.deleteAsync(id: draftId) }
                catch { print("[ComposeView] Failed to delete draft: \(error)") }
            }
            dismiss()
        }
    }

    private func saveDraftAndDismiss() async {
        guard let account = resolvedAccount else { dismiss(); return }
        withAnimation(.easeIn(duration: 0.15)) { isSavingDraft = true }
        let now = Date().timeIntervalSince1970
        // Capture MainActor-isolated properties before entering Sendable closure
        let capDraftId = draftId
        let capTo = toTokens
        let capCc = ccTokens
        let capBcc = bccTokens
        let capSubject = subject
        let capBody = messageBody
        let capAttachments = attachments

        // Persist attachments to disk BEFORE the DB write (file I/O outside
        // GRDB transactions; failure here shouldn't leave a Draft row pointing
        // at a half-written dir). Existing draft's attachmentsDirName is reused
        // if present; otherwise we use capDraftId for a deterministic path.
        let existingDirName: String? = (try? await AppDatabase.dbPool.read { db in
            try Draft.fetchOne(db, key: capDraftId)?.attachmentsDirName
        }) ?? nil
        let dirNameToUse: String? = {
            if capAttachments.isEmpty { return nil }
            return existingDirName ?? capDraftId
        }()
        do {
            if let dir = dirNameToUse {
                // Wipe previous attachments (user may have removed one) then rewrite all.
                DraftAttachmentStorage.deleteAttachments(dirName: dir)
                try DraftAttachmentStorage.saveAttachments(capAttachments, dirName: dir)
            } else if let oldDir = existingDirName {
                // Going from N attachments to zero — clean up the old dir.
                DraftAttachmentStorage.deleteAttachments(dirName: oldDir)
            }
        } catch {
            isSavingDraft = false
            sendError = "Failed to save attachments: \(error.localizedDescription)"
            return
        }

        // Persist before dismiss — if save fails, show error and do NOT dismiss.
        // This follows the "persist before acknowledge" principle (CLAUDE.md).
        //
        // Route through DraftStore.shared.save (NOT raw GRDB write): the store's
        // save() marks serverPushStatus "pushed" → "dirty" so pushDraftToServer
        // doesn't early-return. Without this, a 2nd-save-onwards draft never
        // actually reaches the server — queueDraftSave drains but pushDraft
        // sees `serverPushStatus == "pushed"` (from the previous push) and
        // bails before sending the update.
        do {
            // Load existing to preserve v24 server sync fields (serverDraftId,
            // serverPushStatus, rfc822MessageId) before we overwrite user content.
            let existing = try? await AppDatabase.dbPool.read { db in
                try Draft.fetchOne(db, key: capDraftId)
            }
            let draftToSave: Draft = {
                if var e = existing {
                    e.toJSON = Draft.encodeStringArray(capTo)
                    e.ccJSON = Draft.encodeStringArray(capCc)
                    e.bccJSON = Draft.encodeStringArray(capBcc)
                    e.subject = capSubject
                    e.body = capBody
                    e.updatedAt = now
                    e.attachmentsDirName = dirNameToUse
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
                d.attachmentsDirName = dirNameToUse
                return d
            }()

            try await DraftStore.shared.saveAsync(draftToSave)
            print("[ComposeView] Saved draft on cancel: id=\(draftId) prevStatus=\(existing?.serverPushStatus ?? "nil")")
            // Queue server push via PendingOperation (crash-safe, retries on failure).
            // queueDraftSave also refreshes the Drafts-folder MessageHeader's snippet
            // so the row preview reflects the new body.
            await AccountManager.shared.queueDraftSave(draftId: draftId, accountId: account.id)
            isSavingDraft = false
            dismiss()
        } catch {
            isSavingDraft = false
            sendError = "Failed to save draft: \(error.localizedDescription)"
        }
    }

    private func discardDraftAndDismiss() async {
        // Cancel any in-flight agent edit so autoSaveDraft doesn't recreate the draft.
        let sessionKey = "compose:\(draftId)"
        let session = ChatPillState.shared.session(for: sessionKey)
        session.activeChatTask?.cancel()
        session.activeChatTask = nil
        ActiveAgentTracker.shared.clearWorking(sessionKey)
        ChatPillState.shared.removeSession(for: sessionKey)

        // Load draft info before deleting — needed for server-side cleanup + optimistic UI removal.
        // Async read/write so the main actor isn't blocked behind a busy writer (compose-dismiss
        // freeze class) — this delete was a synchronous main-actor write on the discard path.
        // `draftId` (MainActor-isolated) is captured into a local for the @Sendable closure.
        let draftKey = draftId
        let draftRecord = try? await AppDatabase.dbPool.read { db in
            try Draft.fetchOne(db, key: draftKey)
        }

        do { try await DraftStore.shared.deleteAsync(id: draftId) }
        catch { print("[ComposeView] Failed to discard draft: \(error)") }
        // Optimistic removal + server cleanup
        if let draftRecord {
            if let serverId = draftRecord.serverDraftId {
                // Draft was pushed to server — queue server delete + optimistic removal
                Task {
                    await AccountManager.shared.queueDraftDelete(
                        serverDraftId: serverId,
                        accountId: draftRecord.accountId,
                        rfc822MessageId: draftRecord.rfc822MessageId
                    )
                }
            } else if let rfc822 = draftRecord.rfc822MessageId {
                // Draft has optimistic header but never pushed — just remove local header
                Task {
                    await AccountManager.shared.removeOptimisticDraftHeader(
                        accountId: draftRecord.accountId,
                        rfc822MessageId: rfc822
                    )
                }
            }
        }
        dismiss()
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

            let body = try? dbPool.read { db in try MessageBody.fetchOne(db, key: reply.id) }
            if let html = body?.htmlContent {
                // Strip embedded .eml sections so reply/forward quotes only the
                // primary body — nested attached emails should not leak into the
                // quote (they're recipients' copies won't have our hide-CSS).
                quotedHTML = EmailFilter.stripEmbeddedEmlSections(html)
            } else {
                let text = reply.snippet
                let escaped = text
                    .replacingOccurrences(of: "&", with: "&amp;")
                    .replacingOccurrences(of: "<", with: "&lt;")
                    .replacingOccurrences(of: ">", with: "&gt;")
                    .replacingOccurrences(of: "\n", with: "<br>")
                let quoteCSS = "<style>.tm-pq{color:rgba(0,122,255,0.55)!important}@media(prefers-color-scheme:dark){.tm-pq{color:rgba(10,132,255,0.6)!important}}</style>"
                quotedHTML = "\(quoteCSS)<div class=\"tm-pq\" style=\"font-family: -apple-system, sans-serif; font-size: 16px; line-height: 1.5;\">\(escaped)</div>"
            }

            // Forward: carry original attachments over. Users expect Forward to include
            // the original attachments (not just .eml — PDFs, images, anything). Inline
            // CID images aren't in `attachmentsJSON` (they're tracked separately in
            // InlineImage by the provider), so no extra filtering is needed here.
            // FILTER OUT nested attachments (parentEmlSection != nil): those live
            // inside a `.eml` that we're ALSO carrying, so re-attaching them would
            // duplicate (recipient gets the PDF standalone AND inside the .eml).
            if isForward, let atts = body?.attachments, !atts.isEmpty {
                let topLevel = atts.filter { $0.parentEmlSection == nil }
                if !topLevel.isEmpty {
                    carryForwardAttachments(from: reply, attachments: topLevel)
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

        // All synchronous validation passed — commit to sending. From here every
        // early return MUST reset `isSending` (only the success path keeps the
        // spinner, since the view then dismisses).
        isSending = true

        let (sendBody, isHTML) = buildSendBody()
        let draft = DraftMessage(
            to: finalTo,
            cc: finalCc,
            bcc: finalBcc,
            subject: subject,
            body: sendBody,
            isHTML: isHTML,
            inReplyTo: replyTo?.rfc822MessageId,
            attachments: attachments
        )

        // Capture existing draft (server-side metadata preserved through save-before-send).
        // Async read so the main actor isn't blocked behind a busy writer. `draftId`
        // (MainActor-isolated) is captured into a local for the @Sendable closure.
        let draftKey = draftId
        let draftRecord = try? await AppDatabase.dbPool.read { db in
            try Draft.fetchOne(db, key: draftKey)
        }

        // Save-before-send — uses the existing draft infra so Undo-Send can
        // reopen compose with the exact contents (subject, body, recipients,
        // attachments). Flow: user hits Send → save draft → queue send.
        // The local draft is deleted on send COMPLETION
        // (AccountManagerOutbox.finalizeOutboxMessage), NOT at claim time —
        // transient SMTP failures leave the draft available for retry/edit.
        do {
            let nowEpoch = Date().timeIntervalSince1970

            // Save attachments to disk first (outside DB txn — file I/O
            // failure shouldn't leave a Draft row pointing at a missing dir).
            let dirName: String?
            if !attachments.isEmpty {
                // Reuse existing dirName if set; else use draftId for a
                // deterministic, collision-free path.
                let target = draftRecord?.attachmentsDirName ?? draftId
                try DraftAttachmentStorage.saveAttachments(attachments, dirName: target)
                dirName = target
            } else {
                dirName = draftRecord?.attachmentsDirName
            }

            var draft = Draft(
                id: draftId,
                accountId: account.id,
                toJSON: Draft.encodeStringArray(finalTo),
                ccJSON: Draft.encodeStringArray(finalCc),
                bccJSON: Draft.encodeStringArray(finalBcc),
                subject: subject,
                body: messageBody,
                replyToId: replyTo?.id ?? draftRecord?.replyToId,
                isForward: isForward,
                editHistoryJSON: draftRecord?.editHistoryJSON,
                createdAt: draftRecord?.createdAt ?? nowEpoch,
                updatedAt: nowEpoch
            )
            // Preserve v24 server-sync fields if present.
            draft.serverDraftId = draftRecord?.serverDraftId
            draft.serverPushStatus = draftRecord?.serverPushStatus
            draft.rfc822MessageId = draftRecord?.rfc822MessageId
            draft.attachmentsDirName = dirName

            try await DraftStore.shared.saveAsync(draft)
        } catch {
            // Non-fatal: send still proceeds, but Undo-reopen may not work.
            print("[ComposeView] WARNING: Failed to save draft for Undo-reopen: \(error)")
        }

        // Queue to outbox (persists to GRDB + disk, then drains async).
        // If persistence fails, show error — do NOT dismiss or the message is lost.
        let outboxId: String
        do {
            outboxId = try await AccountManager.shared.queueSend(
                draft: draft,
                from: account,
                replyToHeaderId: replyTo?.id,
                isForward: isForward,
                serverDraftId: draftRecord?.serverDraftId ?? serverDraftHeader?.stableId,
                draftId: draftId
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
        // NOTE: DraftStore.delete is deferred to drain-claim time.
        // If the user taps Undo on the toast, the
        // Draft row is still there so DraftComposePresenter(draftId:) can
        // reopen compose with the original contents.
        // Optimistic removal of draft MessageHeader runs immediately — the
        // Drafts folder view stays clean during the 5 s undo window. If user
        // undos, first autosave after reopen recreates the header.
        if let draftRecord {
            if let serverId = draftRecord.serverDraftId {
                await optimisticDeleteDraftHeader(serverDraftId: serverId, accountId: draftRecord.accountId, rfc822MessageId: draftRecord.rfc822MessageId)
                Task { await AccountManager.shared.queueDraftDelete(serverDraftId: serverId, accountId: draftRecord.accountId, rfc822MessageId: draftRecord.rfc822MessageId) }
            } else if let rfc822 = draftRecord.rfc822MessageId {
                Task { await AccountManager.shared.removeOptimisticDraftHeader(accountId: draftRecord.accountId, rfc822MessageId: rfc822) }
            }
        } else if let serverHeader = serverDraftHeader {
            await optimisticDeleteDraftHeader(serverDraftId: serverHeader.stableId, accountId: serverHeader.accountId, rfc822MessageId: serverHeader.rfc822MessageId)
            Task { await AccountManager.shared.queueDraftDelete(serverDraftId: serverHeader.stableId, accountId: serverHeader.accountId, rfc822MessageId: serverHeader.rfc822MessageId) }
        }

        // Present the Gmail-style undo-send toast. Shown at RootView scope, so
        // it persists after this compose view dismisses.
        let toSummary: String
        if finalTo.isEmpty {
            toSummary = finalCc.isEmpty ? "" : "Cc: \(finalCc.first ?? "")"
        } else {
            let head = finalTo.prefix(2).joined(separator: ", ")
            let tail = finalTo.count > 2 ? " +\(finalTo.count - 2)" : ""
            toSummary = "To: \(head)\(tail)"
        }
        PendingSendService.shared.present(
            outboxId: outboxId,
            draftId: draftId,
            toSummary: toSummary
        )

        // Report success to the agent tool (if any) before dismissing. Fires
        // at outbox-persistence granularity, not SMTP — this is the
        // trade-off for the 5-second undo window. `.onDisappear` will fire
        // `.cancelled` after dismiss, but
        // `ComposeOutcomeState.tryResolve` makes that a no-op.
        onAgentOutcome?(.sent)

        dismiss()
    }

    /// Delete the draft's MessageHeader from the local DB and immediately dismiss it
    /// from the list (no debounce) so the draft is gone before compose closes.
    /// Tries multiple strategies: exact PK from serverDraftHeader, constructed PK from
    /// serverDraftId, and rfc822MessageId query. For Gmail, the serverDraftId (draft
    /// resource ID) differs from the MessageHeader's messageId (Gmail message ID), so
    /// the PK-based delete may miss — the rfc822MessageId fallback catches it.
    ///
    /// `async`: routes through the ASYNC `dbPool.write` overload so the `@MainActor`
    /// `send()` is suspended (not blocked) while the writer is busy — this was one of
    /// the three sequential synchronous writes that froze compose-dismiss for 2–3 s.
    /// The await still completes BEFORE `send()` calls `dismiss()`, preserving
    /// persist-before-acknowledge (no stale-row flash). The closure RETURNS the
    /// deleted ids (Sendable) rather than capturing-and-mutating a `var`, which the
    /// async/@Sendable closure forbids. The original `serverDraftHeader?.id` (a
    /// MainActor-isolated view property) is captured into a local before the await.
    private func optimisticDeleteDraftHeader(serverDraftId: String, accountId: String, rfc822MessageId: String?) async {
        let exactHeaderId = serverDraftHeader?.id
        let deletedIds: [String] = (try? await AppDatabase.dbPool.write { db -> [String] in
            var ids: [String] = []
            let draftsFolder = try Folder
                .filter(Column("accountId") == accountId && Column("role") == FolderRole.drafts.rawValue)
                .fetchOne(db)
            // Strategy 1: delete by exact header PK from the snapshot the user was viewing
            if let exactHeaderId {
                if try MessageHeader.deleteOne(db, key: exactHeaderId) {
                    _ = try? MessageBody.deleteOne(db, key: exactHeaderId)
                    ids.append(exactHeaderId)
                }
            }
            // Strategy 2: delete by constructed PK from serverDraftId
            if let folderPath = draftsFolder?.path {
                let headerId = "\(accountId):\(folderPath):\(serverDraftId)"
                if !ids.contains(headerId), try MessageHeader.deleteOne(db, key: headerId) {
                    _ = try? MessageBody.deleteOne(db, key: headerId)
                    ids.append(headerId)
                }
            }
            // Strategy 3: delete by rfc822MessageId (catches Gmail where serverDraftId
            // is a draft resource ID that doesn't match the header's messageId)
            if let rfc822 = rfc822MessageId, let folderId = draftsFolder?.id {
                let matches = try MessageHeader
                    .filter(Column("folderId") == folderId && Column("rfc822MessageId") == rfc822)
                    .fetchAll(db)
                for header in matches where !ids.contains(header.id) {
                    _ = try? MessageBody.deleteOne(db, key: header.id)
                    try header.delete(db)
                    ids.append(header.id)
                }
            }
            return ids
        }) ?? []
        // Immediate dismiss from list + trigger reload.
        for id in deletedIds {
            NotificationCenter.default.post(name: .messageDismissedFromDetail, object: id)
        }
        // Always trigger reload — even if no headers were found locally (they may have
        // been deleted by sync already), the reload ensures the list reflects current DB state.
        NotificationCenter.default.post(name: .inboxDataDidChange, object: nil)
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
