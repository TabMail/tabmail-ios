<!-- COMPANION-CURRENT-NOTE-BEGIN -->
> **Current amendment (2026-08-21):** Explicit **Save Draft** is also an adoption gesture when the
> suggestion bubble is actively visible. Close treats that visible, nonempty suggestion as unsaved
> content and offers Save/Discard/Cancel; Save synchronously applies the exact offered text through
> the same transition as **Use Suggestion** before taking the durable draft snapshot. Hidden/dismissed, nil,
> empty, or already-accepted suggestion state is never applied. Agent auto-save still skips the
> ephemeral bubble; only explicit Use or Save adopts it into `messageBody`. Current symbol authorities
> for the preserved historical citations below are `ComposeView.suggestionBubble(text:)`,
> `ComposeView.applyInlineEdit`, `ComposeView.prepopulate`, and `ComposeView.recomputeReply`; the
> frozen numeric line references remain provenance only.
>
> **Current amendment (2026-11-27, tabmail-ios #991): the reply's id is an address, so compose checks
> the email before it shows, gives the model or stores anything by it.** Compose resolves the reply
> once at open through `Draft.resolveReplyQuote` (`Draft.acceptsReplyTargetHit`: on IMAP and iCloud
> only positive proof that the row is still that email, else the account + Message-ID lookup) and
> keeps the result as `confirmedReply` (a `ComposeDraftGuards.RelatedEmail`: header, body, forward
> flag), in `prepopulate` and in the saved-draft path of `loadDraftOrPrepopulate`. A caller-supplied
> `suggestedBody` still wins at open (an agent reply without a request passes its held cached reply
> this way, even when the stored one is newer); otherwise the suggestion shown at open is the confirmed row's
> `cachedReply` (`ComposeDraftGuards.openingSuggestion`); with no confirmed row (gone, replaced, or
> nothing to prove it) it is the caller's `reply.cachedReply`; nothing is read again by `reply.id`.
> A saved draft reopened through `loadDraftOrPrepopulate` shows its stored body and no bubble.
> One email is chosen for everything after open, `ComposeView.relatedEmail`
> (`ComposeDraftGuards.relatedEmail`: `confirmedReply`, else the compose argument with its own
> snippet): the inline editor takes its header, body text and mode (`editorMode`), so a saved reply
> reopened with no caller header (Undo Send) keeps its email; Recompute tells the model its header and
> body text (`RelatedEmail.bodyText`: the confirmed body, else the snippet) and stores the answer on
> that same header (`ComposeView.recompute`, `storeRecomputedReply`); an inline edit of the visible
> suggestion is stored on that same header (`persistCachedReply(_:to:)`). Both stores run the guarded
> `storeCachedReply` (Recompute's through the prioritized writer), which writes only while the row at
> the header's id is still that email, so Recompute always sets its answer as the open compose's
> suggestion (seen while the bubble is up; `processReply` may answer from Device Sync without calling
> the model) but stores it only on the email it was about. The assistant's `email_reply` and `email_forward` read the
> source email's header and, for a content request, its body in one read
> (`EmailComposeTool.relatedEmail`); the body of an email outside the current demo/real mode is not
> read, and a failed body read leaves the request with the snippet instead of failing the tool.
> Limitations: an IMAP or iCloud email with neither a Message-ID nor a recorded numbering
> (`observedUidValidity`) is never confirmed, so compose shows the caller's suggestion, and the model
> and editor get its snippet even when its body is cached; a body that arrives after compose opened
> reaches them only when compose is reopened, the reply resolves and the body is cached. When the row
> at the reply's id is not provably that email, the confirmed row is the account's one email with the
> reply's Message-ID, as for the quote (IOS-DRAFT-009), so another copy carrying the same Message-ID
> stands in for it. Open: Recompute and an inline edit that overlap can overwrite each other's stored
> suggestion (tabmail-ios #1607); a saved reply reopened after its email is gone runs the assistant's
> edit as a new message (tabmail-ios #1608). Tests:
> `ComposeSuggestionPersistTests`, `ComposeEditRecipientRolesTests` (the source email),
> `WriteTierRoutingTests` (Recompute's store).
<!-- COMPANION-CURRENT-NOTE-END -->

### Compose AI Suggestion — chat pill edits suggestion in place when bubble is visible
- Reply suggestion bubble (`ComposeView.swift:307-335`) and the body TextEditor are mutually exclusive — while the bubble is up, `messageBody` is empty.
- Chat pill ("Edit Draft") routes by `showingSuggestion`:
  - **Bubble visible:** input = `currentSuggestion`, output writes back to `currentSuggestion` AND `messageHeader.cachedReply` (DB) so reopens show the edited version. Bubble stays up.
  - **After Use Reply / Dismiss:** input/output is `messageBody` (existing flow, unchanged).
- `prepopulate()` re-reads `cachedReply` fresh from DB so prior edits survive in-memory staleness of caller's `MessageHeader` snapshot.
- Recompute (`ComposeView.swift:825`) still overwrites `cachedReply` — by design, "give me a fresh AI draft" discards edits.
- Subject / recipient deltas always go to compose state, regardless of whether bubble is up.
