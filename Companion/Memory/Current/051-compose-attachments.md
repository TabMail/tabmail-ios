
### Compose Attachments
- `DraftAttachment` (filename, mimeType, data) in `DraftMessage.swift`
- ComposeView: bottom-right `Menu` with `PhotosPicker`, file importer (`.item`), camera (`CameraPickerView`)
- IMAP send: `DraftAttachment` → SwiftMail `Attachment(filename:mimeType:data:)` → `Email(... attachments:)` — SwiftMail `constructContent()` handles MIME multipart
- Gmail send: `buildMIMEMessage(draft:)` produces `multipart/mixed` with base64 attachment parts, base64url-encoded for `messages/send` API
- `CameraPickerView.swift`: `UIImagePickerController` wrapper via `UIViewControllerRepresentable`
- `NSCameraUsageDescription` in `Info.plist` for camera access
