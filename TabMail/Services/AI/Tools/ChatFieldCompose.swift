/* This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at https://mozilla.org/MPL/2.0/. */

import Foundation
import GRDB

/// Send in the chat view's closed field (ADR-IOS-114 decision 10, amended 2026-11-26): the words,
/// typed or said, are the user's own message, never a request to the agent and never an edit
/// instruction. The email that says them is written by the compose-text request
/// (`AIService.performComposeText`), the user's bubble having gone up with the words at once; once
/// written, the bubble stays to be read (`ToolInvocation.fieldWritten`) and the compose card opens
/// with the email, its text version the words themselves. Nothing is stored: the AI Suggestion the
/// chat showed is neither edited nor replaced in the database, and no edit history is kept.
struct ChatFieldCompose: Sendable {
    private let ctx: ToolContext
    /// The compose-text request: the email for the draft in `context` with `subject`, saying `words`.
    /// Tests answer it as the backend would (precedent: `ToolContext`'s injected database).
    typealias ComposeText = @Sendable (
        _ mode: ComposeTextMode, _ words: String, _ subject: String, _ context: ComposeEditContext
    ) async throws -> InlineEditResult
    private let composeText: ComposeText

    init(context: ToolContext? = nil, composeText: ComposeText? = nil) {
        self.ctx = context ?? ToolContext()
        self.composeText = composeText ?? Self.chatComposeText
    }

    /// The production request: the chat's one AI service, the one the card's edits use.
    static let chatComposeText: ComposeText = { mode, words, subject, context in
        let aiService = await MainActor.run { ChatPillState.shared.aiService }
        return try await aiService.performComposeText(mode, userText: words, subject: subject, context: context)
    }

    /// What a Send from the field came to. The field has no agent to tell, so when nothing was
    /// written it keeps the user's words (`DynamicIslandChat.composeFromField`). `text` says why,
    /// for the debug log.
    enum Written: Equatable {
        /// The compose card opened and closed unsent.
        case done(String)
        /// The compose card sent the email. The card reports it before it closes, so a field whose
        /// words the card owns empties them at once (`DynamicIslandChat.composeNewEmailFromField`).
        case sent(String)
        /// Nothing was written: no card opened.
        case nothing(String)

        var text: String {
            switch self {
            case .done(let text), .sent(let text), .nothing(let text): text
            }
        }

        /// Nothing written, for `reason`.
        static func failed(_ reason: String) -> Written {
            .nothing(ComposeOutcome.failed(reason).describeForLLM)
        }

        /// The compose card's outcome: nothing written only when the card never opened.
        static func card(_ outcome: ComposeOutcome) -> Written {
            switch outcome {
            case .failed: .nothing(outcome.describeForLLM)
            case .sent: .sent(outcome.describeForLLM)
            case .cancelled: .done(outcome.describeForLLM)
            }
        }
    }

    // MARK: - A thread's chat

    /// The email the field showed (`invocation.fieldReply`), read once: its row only while that row is
    /// still that email, with its body, the accounts, and whether the user wrote it.
    private struct Shown {
        let header: MessageHeader
        let bodyText: String?
        let accounts: [Account]
        let sentByUser: Bool
    }

    /// The field's Send in a thread's chat: a reply to the email the field showed when the user wrote
    /// it to someone else, a follow-up to the same people when it is the user's own
    /// (`ComposeTextMode.thread`). It goes to whom the field's reply goes as it was sent: everyone on
    /// that email (the AI Suggestion's envelope, `ChatReplyCompose.suggestionEnvelope`), or only the
    /// people chosen in Reply to (`ChatReplyCompose.onlyTo`); a change the words clearly ask for
    /// applies by the one step the reply tool shares (`ChatReplyCompose.applying`). The card saves to a draft of its
    /// own, as every chat card does, never over a reply draft already saved for this email.
    ///
    /// The row the field showed is bound to the email it showed: a UIDVALIDITY reset can seat another
    /// email at its address, and the Send then writes nothing, never a reply to that other email.
    /// A request that fails, or answers with no email, opens nothing: a card without the user's
    /// words is not what was asked.
    func reply(_ words: String, invocation: ToolInvocation) async -> Written {
        guard let field = invocation.fieldReply else { return .failed("no reply field sent this request") }
        guard let origin = invocation.composeOrigin else { return .failed(ComposeOrigin.noScreenReason) }
        let shown: Shown?
        do {
            shown = try await ctx.db.read { db -> Shown? in
                guard case .some(let bodyText) = try ComposeEditContext.relatedBodyText(of: field.email, db: db),
                      let header = try MessageHeader.fetchOne(db, key: field.email.id) else { return nil }
                let accounts = try Account.fetchAll(db)
                let inSent = try Folder.fetchOne(db, key: header.folderId)?.role == .sent
                return Shown(
                    header: header, bodyText: bodyText, accounts: accounts,
                    sentByUser: PromptVariables.isSentByUser(
                        fromAddress: header.fromAddress, userAddresses: accounts.map(\.emailAddress), inSentFolder: inSent))
            }
        } catch {
            return .failed("the email could not be read; nothing was done")
        }
        guard let shown else { return .failed("the email changed since the message was sent; nothing was done") }
        let header = shown.header
        let start = field.onlyTo.map { ChatReplyCompose.onlyTo($0, replying: header) }
            ?? ChatReplyCompose.suggestionEnvelope(for: header, accounts: shown.accounts)
        let mode = ComposeTextMode.thread(sentByUser: shown.sentByUser)
        let context = await Self.context(
            recipients: start.recipients, account: shown.accounts.first { $0.id == header.accountId },
            mode: mode, related: header, relatedBodyText: shown.bodyText)
        guard let written = await write(words, mode: mode, subject: start.subject, context: context) else {
            return .failed("the reply could not be written; nothing was done")
        }
        let envelope = Self.envelope(start, after: written.result, accounts: shown.accounts)
        await held(invocation)
        let outcome = await ctx.router.enqueueComposeAndAwaitOutcome(fieldWordsKey: invocation.fieldWordsKey) { onOutcome, state in
            AgentToolRouter.ComposeRequest(
                mode: .reply, replyTo: header, to: envelope.to, cc: envelope.cc, bcc: envelope.bcc,
                subject: envelope.subject, body: written.email.body, origin: origin, suggestion: written.email,
                // A Reply All while the recipients hold the whole Reply All audience, so the send
                // records reply-all on the original (#915).
                isReplyAll: envelope.isReplyAll, fieldReply: field, isFieldsOwnReply: true,
                draftId: Draft.separateReplyKey(replyTo: "\(header.accountId):\(header.stableId)"),
                onOutcome: onOutcome, outcomeState: state)
        }
        return .card(outcome)
    }

    /// The draft `start` after the email written: its recipient changes applied by the one step the
    /// reply tool shares (`ChatReplyCompose.applying`, with the user's `accounts`), and a subject it wrote in
    /// place of the start's (none, the model's blank subject, keeps the start's). With no recipient
    /// change the envelope keeps its kind as it is.
    static func envelope(_ start: ChatReplyCompose, after result: InlineEditResult, accounts: [Account]) -> ChatReplyCompose {
        let subject = result.subject ?? start.subject
        guard result.toDelta != nil || result.ccDelta != nil || result.bccDelta != nil else {
            return start.with(subject: subject)
        }
        return start.applying(
            to: result.toDelta, cc: result.ccDelta, bcc: result.bccDelta, subject: subject, accounts: accounts)
    }

    // MARK: - A new email's chat

    /// The field's Send in a new email's chat: a new email to `to`, the people picked in the chat,
    /// from the account bound as the Send started (`ComposeOrigin.fromAccountId`), under the chat's
    /// subject when it shows one (`subject`; empty: the email written gives one). The card opens where
    /// the chat that asked opens it.
    func newEmail(_ words: String, to: [String], subject: String, invocation: ToolInvocation) async -> Written {
        guard let origin = invocation.composeOrigin else { return .failed(ComposeOrigin.noScreenReason) }
        let accounts: [Account]
        do {
            accounts = try await ctx.db.read { db in try Account.fetchAll(db) }
        } catch {
            return .failed("the email could not be written; nothing was done")
        }
        let recipients = ComposeDraftGuards.Recipients()
            .filling(to: RecipientEntry(to), cc: RecipientEntry([]), bcc: RecipientEntry([]))
        let context = await Self.context(
            recipients: recipients, account: accounts.first { $0.id == origin.fromAccountId },
            mode: .new, related: nil, relatedBodyText: nil)
        guard let written = await write(words, mode: .new, subject: subject, context: context) else {
            return .failed("the email could not be written; nothing was done")
        }
        await held(invocation)
        let outcome = await ctx.router.enqueueComposeAndAwaitOutcome(fieldWordsKey: invocation.fieldWordsKey) { onOutcome, state in
            AgentToolRouter.ComposeRequest(
                mode: .compose, replyTo: nil, to: to, cc: [], bcc: [], subject: written.result.subject ?? subject,
                body: written.email.body, origin: origin, suggestion: written.email,
                onOutcome: onOutcome, outcomeState: state)
        }
        return .card(outcome)
    }

    // MARK: - Shared

    /// The request's answer and the email it wrote: its body, the words as its text version (the
    /// bubble the user sent, so the chat shows the sent email as exactly that), and its alternative.
    private struct WrittenEmail {
        let result: InlineEditResult
        let email: ReplyResult
    }

    /// The compose-text request; nil when it failed or wrote no email.
    private func write(
        _ words: String, mode: ComposeTextMode, subject: String, context: ComposeEditContext
    ) async -> WrittenEmail? {
        let result: InlineEditResult
        do {
            result = try await composeText(mode, words, subject, context)
        } catch {
            if DebugModeManager.isLoggingEnabled() {
                BackgroundSyncLogger.logDebug("[ChatFieldCompose] \(mode.rawValue) failed: \(error)")
            }
            return nil
        }
        guard let body = result.body else { return nil }
        if DebugModeManager.isLoggingEnabled() {
            BackgroundSyncLogger.logDebug("[ChatFieldCompose] \(mode.rawValue) wrote bodyLen=\(body.count) alt=\(result.changeCommand != nil)")
        }
        return WrittenEmail(result: result, email: ReplyResult(body: body, textMessage: words, changeCommand: result.changeCommand))
    }

    /// The email is written: the user's bubble stays up to be read before the card opens. Stop
    /// during the hold cancels the task, and the card then opens nothing
    /// (`enqueueComposeAndAwaitOutcome`).
    private func held(_ invocation: ToolInvocation) async {
        await invocation.fieldWritten?()
    }

    /// The request's context for a draft with `recipients`, sent from `account`, as every compose
    /// edit's (`ComposeEditContext.make`).
    private static func context(
        recipients: ComposeDraftGuards.Recipients, account: Account?, mode: ComposeTextMode,
        related: MessageHeader?, relatedBodyText: String?
    ) async -> ComposeEditContext {
        let (kbText, compositionPrompt) = await MainActor.run {
            (PromptStore.shared.kbText(), PromptStore.shared.compositionMarkdown())
        }
        return ComposeEditContext.make(
            recipients: recipients, account: account, mode: mode.rawValue, related: related,
            relatedBodyText: relatedBodyText, compositionPrompt: compositionPrompt, kbText: kbText)
    }
}
