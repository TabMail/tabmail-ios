# TabMail for iOS

**An AI-native, open-source email client for iPhone.**

[![Download on the App Store](https://img.shields.io/badge/Download-App_Store-0D96F6?logo=apple&logoColor=white)](https://apps.apple.com/app/tabmail/id6759847858)
[![License: MPL 2.0](https://img.shields.io/badge/License-MPL_2.0-blue.svg)](./LICENSE)
![Swift 6](https://img.shields.io/badge/Swift-6-orange?logo=swift&logoColor=white)
![Platform: iOS 26+](https://img.shields.io/badge/platform-iOS_26+-lightgrey)

TabMail brings summaries, drafting, triage, and a chat agent to your existing
Gmail, Outlook/Microsoft, iCloud, and generic IMAP accounts. It is a native
SwiftUI app built for iOS 26 with Swift 6 strict concurrency.

> **License:** [Mozilla Public License 2.0](./LICENSE) (MPL-2.0).
> The "TabMail" name and logo are trademarks — see [TRADEMARKS.md](./TRADEMARKS.md).

---

## What's open, what's hosted

This repository is the **complete iOS client** — the full app, notification
service, on-device search, and tests. It is genuinely open source under MPL-2.0.

The app talks to the **TabMail backend** over HTTPS for AI orchestration, push
notifications, device sync, and billing. That hosted service (and its prompt
content) is a separate, closed-source product. Open-sourcing the client does not
expose it — but if you fork TabMail, you can point the app at your own backend
by changing the endpoints and supplying your own keys (see
[`Secrets.xcconfig.example`](./Secrets.xcconfig.example)).

The sibling components are open source too:

- **Thunderbird add-on** — https://github.com/TabMail/tabmail-thunderbird (MPL-2.0)
- **Native FTS host** — https://github.com/TabMail/tabmail-native-fts (MPL-2.0)

## Highlights

- **On-device search** — hybrid keyword + semantic search using a bundled
  Core ML embedding model and a vendored SQLite vector extension. No message
  bodies leave the device for indexing.
- **Optimistic, crash-safe sync** — user actions persist locally before the UI
  acknowledges them and replay across crashes, kills, and reconnects; the server
  remains the source of truth on conflict.
- **Bring Your Own Key (BYOK)** — route AI requests through your own OpenAI,
  Anthropic, or Google API key.
- **Push** for Gmail, Outlook, and generic IMAP (via IDLE), with an iOS
  Notification Service Extension that fetches new mail in the background.

## Building

Requirements:

- **Xcode 16+** (iOS 26 SDK)
- **[XcodeGen](https://github.com/yonaskolb/XcodeGen)** — `brew install xcodegen`.
  The `.xcodeproj` is generated from [`project.yml`](./project.yml) and is not
  committed.

Steps:

1. Clone this repository.
2. Package dependencies (SwiftMail, SwiftSoup, GRDB) are resolved automatically
   from GitHub by Swift Package Manager — no manual checkout needed. (TabMail uses
   a BSD-2-Clause fork of SwiftMail at github.com/TabMail/SwiftMail.)
3. Create your secrets file from the template and fill in your own values:
   ```bash
   cp Secrets.xcconfig.example Secrets.xcconfig
   ```
   `Secrets.xcconfig` is gitignored. The comments in the template explain how to
   obtain each OAuth client ID and how to generate the keys.
4. Generate and open the project:
   ```bash
   xcodegen generate
   open TabMail.xcodeproj
   ```
5. Build and run the **TabMail** scheme on an iOS 26 simulator or device.

Run the tests with `⌘U`, or:

```bash
xcodebuild -project TabMail.xcodeproj -scheme TabMail \
  -destination 'platform=iOS Simulator,name=iPhone 17 Pro' test
```

## Project layout

| Path | What |
|------|------|
| `TabMail/` | The main app (SwiftUI views, view models, services, on-device search) |
| `Shared/` | Code shared between the app and the notification service |
| `TabMailNotificationService/` | Notification Service Extension (background IMAP fetch) |
| `TabMailTests/` | Unit tests |
| `TabMailScreenshots/` | UI-test screenshot harness |
| `TabMail/Vendor/sqlite-vec/` | Vendored SQLite vector extension (third-party) |
| `Scripts/` | Developer utilities (e.g. Core ML model conversion) |

## Contributing

Contributions are welcome under MPL-2.0. We use the **Developer Certificate of
Origin** — every commit must be signed off with `git commit -s`. See
[CONTRIBUTING.md](./CONTRIBUTING.md) for setup and the full DCO text, and
[CODE_OF_CONDUCT.md](./CODE_OF_CONDUCT.md) for community expectations.

## Security

Found a vulnerability? Please report it privately per [SECURITY.md](./SECURITY.md)
— do not open a public issue.

## License

[MPL-2.0](./LICENSE). Third-party components retain their own licenses, listed in
[THIRD_PARTY_LICENSES.md](./THIRD_PARTY_LICENSES.md).
