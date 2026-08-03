
### Background AI Processing (Tier 3)
- **BGProcessingTask** (`ai.tabmail.ai-processing`) — long-running background task for AI processing (up to ~10 min)
- Requires `processing` in `UIBackgroundModes` and task ID in `BGTaskSchedulerPermittedIdentifiers`
- Registered in `TabMailApp.init`, handled in `SyncScheduler.handleBackgroundAIProcessing()`
- Scheduled on app background in `RootView.onChange(of: scenePhase)`, 5 min earliest begin date
- Flow: WiFi check → poll (sync) → processMessagesForAccount per active account → embeddings → badge update
- **`beginBackgroundTask`** protects in-flight AI calls in both `processMessagesForAccount` (queue path) and `processMessage` (priority path) — ~30s grace period when app backgrounds
