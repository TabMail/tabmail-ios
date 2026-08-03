
### Stale Message Detection (syncMessages)
- If `messages.count < limit`, we fetched ALL messages in the folder — any local message not in the remote set is stale
- If `messages.count == limit`, only delete local messages with `date >= oldestFetchedDate` (within fetch window)
- Prevents archived/deleted messages from persisting locally in IMAP accounts
