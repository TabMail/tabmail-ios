
### Manual Tag Teaching (Long-Press Context Menu)
- Long-press on message rows (both normal and triage view) shows "Tag as Reply/Archive/Delete" + "Remove Tag" context menu
- `InboxView.tagContextMenu(for:)` builds the menu; `InboxViewModel.applyManualTag()` dispatches to `AccountManager.applyManualTag()`
- `AccountManager.applyManualTag()` handles the full flow: optimistic UI → IMAP/Gmail write → AI cache update → fire-and-forget auto-prompt update
- **Auto-prompt refinement**: `AIService.autoUpdateUserPromptOnTag()` sends email metadata + summary + original action + user's correction to backend (`system_prompt_action_refine`), gets an ADD/DEL patch, applies it via `ActionPatchApplier` to `PromptStore.rawAction`
- `ActionPatchApplier` — port of TB's `patchApplier.js`: parses multi-operation patches, finds section headers, handles duplicate detection, case-insensitive DEL matching
- Self-sent emails are blocked from manual tagging (matches TB's `isInternalSender` check)
- Updated user_action.md auto-syncs to TB via Device Sync (PromptStore setter triggers `DeviceSyncService.debouncedBroadcast`)
