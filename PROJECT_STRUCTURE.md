# TabMail iOS - Project Structure

> **Directory tree, entry points, and sub-component map.** Update when the structure changes.

**Last updated:** 2026-05-31

---

## Project Configuration

| Setting | Value |
|---------|-------|
| Min iOS | 26.0 |
| Swift | 6.0 |
| Xcode | 16.0 |
| Build system | XcodeGen (`project.yml`) |
| Persistence | GRDB (SQLite via `AppDatabase.swift`) |
| UI framework | SwiftUI |

---

## Directory Tree

```
tabmail-ios/
├── project.yml                  # XcodeGen project definition
├── Secrets.xcconfig             # OAuth & API credentials (gitignored)
├── Secrets.xcconfig.example     # Template for secrets
│
├── TabMail/                     # Main application target
│   ├── App/
│   │   └── TabMailApp.swift     # @main SwiftUI App entry point
│   │
│   ├── Models/                  # GRDB Record models (illustrative subset)
│   │   ├── Account.swift        # User account
│   │   ├── Folder.swift         # Email folder
│   │   ├── MessageHeader.swift  # Email header/metadata
│   │   ├── MessageBody.swift    # Email body content
│   │   ├── DraftMessage.swift   # Unsent draft
│   │   └── …                    # OutboxMessage, PendingOperation, MessageAICache, ChatTurn, UserLabel, …
│   │
│   ├── Providers/               # Email + calendar provider abstractions (illustrative)
│   │   ├── EmailProvider.swift  # Base mail protocol
│   │   ├── GmailProvider.swift  # Gmail API
│   │   ├── ExchangeProvider.swift  # Outlook / Microsoft Graph
│   │   ├── IMAPProvider.swift   # Generic IMAP (incl. iCloud)
│   │   ├── DemoProvider.swift   # Offline demo-mode provider
│   │   └── …                    # Google/Exchange calendar providers, CalDAV/
│   │
│   ├── Services/                # Business logic
│   │   ├── AccountManager.swift     # Account lifecycle
│   │   ├── BackendClient.swift      # Cloudflare Workers API client
│   │   ├── GoogleAuthService.swift  # Google OAuth 2.0
│   │   ├── TabMailAuthService.swift # TabMail native auth
│   │   ├── KeychainHelper.swift     # Secure credential storage
│   │   ├── SyncEngine.swift         # Email sync orchestration
│   │   ├── SyncScheduler.swift      # Background sync scheduling
│   │   └── UndoService.swift        # Undo/redo
│   │
│   ├── ViewModels/              # MVVM state management
│   │   ├── InboxViewModel.swift
│   │   └── MessageDetailViewModel.swift
│   │
│   ├── Views/                   # SwiftUI views by feature
│   │   ├── RootView.swift               # App root container
│   │   ├── MailNavigationView.swift     # Main navigation
│   │   ├── Account/                     # Account setup & management
│   │   │   ├── AccountSetupView.swift
│   │   │   ├── AccountDashboardView.swift
│   │   │   └── TabMailLoginView.swift
│   │   ├── Inbox/                       # Inbox & message list
│   │   │   ├── InboxView.swift
│   │   │   ├── MessageRowView.swift
│   │   │   └── TriageCardView.swift
│   │   ├── Message/                     # Message detail
│   │   │   └── MessageDetailView.swift
│   │   ├── Compose/                     # Email composition
│   │   │   └── ComposeView.swift
│   │   ├── Agent/                       # AI agent chat
│   │   │   └── AgentChatSheet.swift
│   │   ├── Settings/                    # Settings
│   │   │   ├── SettingsView.swift
│   │   │   └── AccountDetailView.swift
│   │   └── Shared/                      # Reusable components
│   │       ├── AutoSizingHTMLView.swift
│   │       ├── EmailHTMLWrapper.swift
│   │       ├── ShakeDetector.swift
│   │       └── UndoToast.swift
│   │
│   ├── Theme/                   # UI theming
│   │   ├── Palette.swift        # Color definitions
│   │   └── Theme.swift          # Theme application
│   │
│   ├── Storage/                 # (Currently empty)
│   │
│   └── Resources/
│       ├── Info.plist           # App metadata (reads from Secrets.xcconfig)
│       └── Assets.xcassets/     # Icons, logos, colors
│
└── TabMailTests/                # 400+ test files (Swift Testing), grouped by area:
    ├── Models/  Providers/  Services/  Search/  Tools/  ViewModels/  Views/
    ├── AI/  Auth/  Config/  Database/  Demo/  E2E/  NSE/  Notifications/  Queues/
    ├── Helpers/  Infrastructure/  Mocks/   # test scaffolding (fakes, mocks)
    └── Fixtures/                           # provider response fixtures (+ README.md)
```

---

## Database Schema (GRDB)

Managed via `AppDatabase.swift` migrations. Tables include `account`, `folder`, `messageHeader`, `messageBody`, `pendingOperation`, `messageAICache`, `outboxMessage`, `chatTurn`, and the demo calendar-event table. FTS lives in a separate SQLite database (`fts.db`) via `SearchIndex`; per-turn chat-memory search uses an isolated `memory.db` sidecar (see `MemoryIndex`).

---

## External Dependencies (SPM)

| Package | Purpose |
|---------|---------|
| SwiftMail (TabMail fork) | IMAP/SMTP via Swift NIO |
| SwiftSoup (2.6.0+) | HTML email parsing |
| GRDB (7.0.0+) | SQLite persistence (main DB + FTS) |

---

## Architecture Patterns

- **MVVM** — Views consume ViewModels for state
- **Protocol-based providers** — `EmailProvider` protocol with Gmail/IMAP implementations
- **Service layer** — Business logic isolated in Services/
- **Feature-organized views** — Views/ grouped by feature area
