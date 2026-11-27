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
  The first attempted fix moved the closure's statements into a private method (`followMoves`), called in one line.
  **That was not the cause either: the third build failed the same way.** A one-file typecheck (below) found it by
  bisection: the culprit was the argument `NotificationCenter.default.publisher(for: .mailPointersMoved)`, the
  implicit member `.mailPointersMoved`. Removing that one modifier, spelling the name's type out
  (`publisher(for: Notification.Name.mailPointersMoved)`), or moving the publisher into a computed property each
  type-checked the whole file in about 5 s; a typed closure parameter (`{ (notification: Notification) in ... }`)
  still failed. Likely reason (not proven): `NotificationCenter` is an `NSObject`, so `publisher(for:)` also has
  the key-path observing overload, and an implicit member leaves both open to the whole chain. The chain's other
  receivers use the same implicit form but add `.receive(on:)`, and they type-check. The split was kept: with the
  fix, the unsplit chain still type-checks, but the file then takes about 19 s against about 5 s split (a failing
  run took about 20 s), so the split is the headroom. The method extraction stays too (house rule below).

## Find the cause with a one-file typecheck, not builds

The error's location says nothing, and each build to test a guess costs a build slot and minutes. After a failed
build (so after the review is clean), the build log holds the failed compile job's command under "Failed frontend
command:" (`swift-frontend -frontend -c -filelist … -primary-file … …`). Run that command again with `-c` replaced by
`-typecheck`, only the file in question as `-primary-file`, and the output flags dropped (`-o`,
`-supplementary-output-file-map`, `-index-unit-output-path`, `-index-store-path`, `-index-system-modules`,
`-const-gather-protocols-file`). It reuses the failed build's DerivedData (its module dependencies and file list) and
reproduces the error in about 20 s on one core. Then bisect: write a variant of the file (one modifier removed or
rewritten), typecheck it, restore the file, and repeat. A variant that passes in a few seconds names the cause; one
that passes only near the failing time has no headroom. `-debug-time-expression-type-checking` adds timings per
expression. Restore the file after every variant (check `git diff`) before committing.

## The rule

- In such a body, a new modifier carries no logic inline: its closure calls a private method
  (`{ followMoves($0) }`, `{ _, _ in adoptReopened() }`), and an argument that needs inference
  (`map` with a closure, a chained publisher, an overloaded initializer) becomes a computed property.
- An implicit member passed to an overloaded call (`publisher(for: .someName)`) is such an argument: spell its type
  out (`publisher(for: Notification.Name.someName)`) or move it into a computed property.
- A build that fails with this error: find the cause with a one-file typecheck (above) before the next build.
- Better still, fold new receivers into an extracted `ViewModifier` (`NavigationNotificationHandlers`,
  `StagedRowsReceiver`, `CollapseChatOnNavigateModifier`), or the new sheet's content into an existing sheet.
- Splitting the chain into helpers helps only together with the above; it does not make room for an inline closure.
- Such a change is a compile fix with no logic change: the same statements in the same order, run on the same
  `self`.
