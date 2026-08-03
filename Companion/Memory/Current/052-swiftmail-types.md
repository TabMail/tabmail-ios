
### SwiftMail Types
- `Section` — top-level struct (NOT `MessagePart.Section`)
- `UID(_ value: UInt32)` — construct UID from UInt32
- `UIDSet(UID(...))` — construct from single UID
- `Mailbox.Selection` — returned by `server.selectMailbox()`
- `Mailbox.Info.Attributes` — folder attributes (`.inbox`, `.sent`, etc.)
