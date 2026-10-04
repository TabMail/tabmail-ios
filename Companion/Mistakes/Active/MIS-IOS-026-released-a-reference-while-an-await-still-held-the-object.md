# MIS-IOS-026 — I "released" a web view by clearing my reference while an in-flight await still held it

**Class:** resource lifetime · concurrency
**Severity:** low (found writing the backstop test, before merge; no release shipped it)
**First seen:** 2026-10-04 · **Recurrences:** 1 · **Status:** Active
**Related:** ADR-IOS-088 · memory topic 131 · `PDFTextHost.readPages` / `PDFTextHost.finish`

## The tell

A `finish`/`cancel`/`teardown` method sets `self.thing = nil` and its doc says "releases the
thing", while some other path started `Task { await thing.call() }` or `try await thing.call()`
on the same object. An `await` keeps its receiver (and every captured value) alive until the call
returns; clearing the property releases nothing while that call is pending, and if it never
returns, nothing ever does.

## What actually happened

`PDFTextHost` ran the page's pdf.js call from `webView(_:didFinish:)` as
`Task { await readPages(webView) }`, an `async` method awaiting `callAsyncJavaScript`. `finish`
nilled `self.webView` and the docs said a cancelled call or a backstop timeout "releases the web
view at once". The round-1 reviewer measured the web view deallocating 9.36 s after a cancel (when
pdf.js answered). Writing the backstop test with a wedged page showed the worse case: the page
never answers, so the web view and its WebContent process lived for the rest of the process, and
the old code's test run could not even exit.

Fixed by calling the completion-handler form of `callAsyncJavaScript` with `[weak self]` and no
reference to the web view, so the host's property is the only owner; tests now assert a weak
reference to the web view goes nil after a mid-read cancel and after the backstop, each red on the
`Task` version.

## The rule

When a method claims to release an object, list every live owner, including pending `await`s on
it and closures that capture it, and test the claim with a weak reference that must go nil within
a bound, against a peer that never answers. Start long calls with a completion handler that
captures nothing but `[weak self]` when the caller must be able to drop the object mid-call.
