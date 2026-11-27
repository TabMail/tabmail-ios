# 163 — Some SwiftUI body chains are at the type checker's limit: add no logic inline

**Status:** Current (2026-11-27). Applies to every large SwiftUI `body` modifier chain, and today in particular to
`InboxView`, `MailNavigationView` and `ChatThreadView`.

## What happens

A view's `body` that is one long modifier chain (dozens of `.onChange`, `.onReceive`, `.task`, `.sheet`,
`.fullScreenCover`) is one expression to the Swift type checker, closures included. Some of these chains sit at its
limit: one more inline closure with real logic, or one inference-heavy argument, fails the build with "the compiler
is unable to type-check this expression in reasonable time". The error names an unrelated, unchanged line of the
chain (for example an existing `.onReceive`'s `guard`), and that line moves from build to build, so it says nothing
about which addition did it. Nothing compiles before a review is clean, so the failure shows up only in the first
build after it.

Seen on:

- `InboxView.body` and `MailNavigationView.body` (memories 061 and 074, ADR-IOS-044 item 5): one more inline
  `.onReceive` or `.sheet`.
- `ChatThreadView.body`, 2026-11-26: `.onChange(of: reopened.map { ObjectIdentifier($0.viewModel) })` failed; the
  same modifier with the argument moved into a computed property (`reopenedKey`) built.
- `ChatThreadView.body`, 2026-11-27: two modifiers for the send bubbles, one an `.onReceive` with a three-statement
  closure, failed. Splitting the chain in two (the container with its lifecycle modifiers, then
  `presentations(on:)` for the sheets and covers) was not enough: the inline closure still failed the shorter chain.
  The fix moved the closure's statements into a private method (`followMoves`), called in one line.

## The rule

- In such a body, a new modifier carries no logic inline: its closure calls a private method
  (`{ followMoves($0) }`, `{ _, _ in adoptReopened() }`), and an argument that needs inference
  (`map` with a closure, a chained publisher, an overloaded initializer) becomes a computed property.
- Better still, fold new receivers into an extracted `ViewModifier` (`NavigationNotificationHandlers`,
  `StagedRowsReceiver`, `CollapseChatOnNavigateModifier`), or the new sheet's content into an existing sheet.
- Splitting the chain into helpers helps only together with the above; it does not make room for an inline closure.
- Such a change is a compile fix with no logic change: the same statements in the same order, run on the same
  `self`.
