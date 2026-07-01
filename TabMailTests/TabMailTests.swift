/* This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at https://mozilla.org/MPL/2.0/. */

import Testing
@testable import TabMail

@Test func draftMessageDefaults() {
    let draft = DraftMessage()
    #expect(draft.to.isEmpty)
    #expect(draft.subject.isEmpty)
    #expect(draft.body.isEmpty)
    #expect(!draft.isHTML)
    #expect(draft.inReplyTo == nil)
}

@Test func folderRoleMapping() {
    // Verify all roles have valid rawValues
    let roles: [FolderRole] = [.inbox, .sent, .drafts, .trash, .archive, .spam, .custom]
    for role in roles {
        #expect(!role.rawValue.isEmpty)
    }
}

// MARK: - EmailHTMLWrapper

@Test @MainActor func wrapHTMLProducesValidStructure() {
    let html = EmailHTMLWrapper.wrapHTML("<p>Hello</p>")
    // Must contain DOCTYPE and essential HTML structure
    #expect(html.contains("<!DOCTYPE html>"))
    #expect(html.contains("<html>"))
    #expect(html.contains("</html>"))
    #expect(html.contains("<body>"))
    #expect(html.contains("</body>"))
    // Must contain viewport meta for proper WKWebView sizing
    #expect(html.contains("name=\"viewport\""))
    #expect(html.contains("width=device-width"))
    // Must contain the original body content
    #expect(html.contains("<p>Hello</p>"))
    // Must contain dark mode media query (critical for readability)
    #expect(html.contains("prefers-color-scheme: dark"))
    // Must contain CSP upgrade-insecure-requests
    #expect(html.contains("upgrade-insecure-requests"))
}

@Test @MainActor func wrapHTMLPreservesSpecialCharacters() {
    // Ensure HTML with special content isn't mangled
    let html = EmailHTMLWrapper.wrapHTML("<div style=\"color: red;\">Test &amp; &lt;tag&gt;</div>")
    #expect(html.contains("color: red;"))
    #expect(html.contains("&amp;"))
    #expect(html.contains("&lt;tag&gt;"))
}

@Test @MainActor func wrapHTMLHandlesEmptyBody() {
    let html = EmailHTMLWrapper.wrapHTML("")
    #expect(html.contains("<body></body>"))
    #expect(html.contains("<!DOCTYPE html>"))
}

// MARK: - wrapHTML: Full HTML Document Unwrapping

@Test @MainActor func wrapHTMLUnwrapsFullHTMLDocument() {
    // Exchange/Outlook emails often arrive as full HTML documents.
    // wrapHTML must not create nested <html> which breaks WebView height measurement.
    let emailBody = """
    <html style="padding:0; margin:0;">
    <head><style>.hello { color: blue; }</style></head>
    <body><p>Hello world</p></body>
    </html>
    """
    let wrapped = EmailHTMLWrapper.wrapHTML(emailBody)

    // Must have exactly one <html> tag (our wrapper's)
    let htmlTagCount = wrapped.components(separatedBy: "<html>").count - 1
    #expect(htmlTagCount == 1, "Should have exactly one <html> tag, got \(htmlTagCount)")

    // Must NOT contain nested <html (would be the email's original tag)
    #expect(!wrapped.contains("<html style="), "Should not contain the email's <html> tag")

    // Email's inline style on <html> must be preserved (converted to <div>)
    #expect(wrapped.contains("<div style=\"padding:0; margin:0;\">"))

    // Email's <style> block must be preserved
    #expect(wrapped.contains(".hello { color: blue; }"))

    // Email content must be present
    #expect(wrapped.contains("<p>Hello world</p>"))

    // Our wrapper's essentials must be present
    #expect(wrapped.contains("<!DOCTYPE html>"))
    #expect(wrapped.contains("name=\"viewport\""))
    #expect(wrapped.contains("prefers-color-scheme: dark"))
}

@Test @MainActor func wrapHTMLUnwrapsDoctype() {
    let emailBody = """
    <!DOCTYPE html>
    <html>
    <head><meta charset="utf-8"><style>td { padding: 0; }</style></head>
    <body style="margin:0"><table><tr><td>Content</td></tr></table></body>
    </html>
    """
    let wrapped = EmailHTMLWrapper.wrapHTML(emailBody)

    // Only one DOCTYPE
    let doctypeCount = wrapped.lowercased().components(separatedBy: "<!doctype").count - 1
    #expect(doctypeCount == 1, "Should have exactly one DOCTYPE, got \(doctypeCount)")

    // <meta charset> from email should be removed (our wrapper provides metas)
    #expect(!wrapped.contains("charset=\"utf-8\""))

    // Email's <style> preserved
    #expect(wrapped.contains("td { padding: 0; }"))

    // Body inline style preserved as <div> with tm-email-body marker class
    #expect(wrapped.contains("<div class=\"tm-email-body\" style=\"margin:0\">"))

    // Content present
    #expect(wrapped.contains("<table><tr><td>Content</td></tr></table>"))
}

@Test @MainActor func wrapHTMLDoesNotUnwrapFragment() {
    // Regular HTML fragments should NOT be unwrapped
    let fragment = "<div><p>Just a fragment</p></div>"
    let wrapped = EmailHTMLWrapper.wrapHTML(fragment)

    // Fragment should be inserted as-is inside our <body>
    #expect(wrapped.contains("<body><div><p>Just a fragment</p></div></body>"))
}

@Test @MainActor func wrapHTMLUnwrapPreservesMultipleStyleBlocks() {
    let emailBody = """
    <html>
    <head>
    <style>.a { color: red; }</style>
    <style>.b { color: green; }</style>
    </head>
    <body>Content</body>
    </html>
    """
    let wrapped = EmailHTMLWrapper.wrapHTML(emailBody)
    #expect(wrapped.contains(".a { color: red; }"))
    #expect(wrapped.contains(".b { color: green; }"))
    #expect(wrapped.contains("Content"))
}

@Test @MainActor func wrapHTMLUnwrapHandlesNoHeadSection() {
    // Some simple HTML emails have <html><body> with no <head>
    let emailBody = "<html><body><p>Simple email</p></body></html>"
    let wrapped = EmailHTMLWrapper.wrapHTML(emailBody)

    let htmlTagCount = wrapped.components(separatedBy: "<html>").count - 1
    #expect(htmlTagCount == 1)
    #expect(wrapped.contains("<p>Simple email</p>"))
    #expect(!wrapped.contains("<html><body>"))
}

@Test @MainActor func wrapHTMLUnwrapHandlesBodyWithoutHtml() {
    // Edge case: starts with <html but has no <body> tag
    let emailBody = "<html><div>Content without body tag</div></html>"
    let wrapped = EmailHTMLWrapper.wrapHTML(emailBody)

    #expect(wrapped.contains("Content without body tag"))
    let htmlTagCount = wrapped.components(separatedBy: "<html>").count - 1
    #expect(htmlTagCount == 1)
}

@Test @MainActor func wrapHTMLUnwrapNeverProducesNestedHtmlOrBody() {
    // The core invariant: wrapped output must never contain <html or <body
    // inside the wrapper's <body>, regardless of input structure.
    let inputs = [
        "<html><head></head><body><p>A</p></body></html>",
        "<!DOCTYPE html><html lang=\"en\"><head><style>x{}</style></head><body class=\"foo\"><p>B</p></body></html>",
        "<HTML><HEAD></HEAD><BODY>C</BODY></HTML>",
        "<html style=\"margin:0\"><body style=\"padding:0\">D</body></html>",
    ]
    for input in inputs {
        // Strip CSS (/* */) and HTML (<!-- -->) comments BEFORE locating the wrapper
        // body: the wrapper's own stylesheet mentions tags like "<body>" in explanatory
        // comments, which are inert — but the naive range(of: "<body>") below would
        // otherwise latch onto the comment's "<body>", mis-extract, and then flag the
        // real body tag as "nested".
        let wrapped = EmailHTMLWrapper.wrapHTML(input)
            .replacingOccurrences(of: #"/\*[\s\S]*?\*/"#, with: "", options: .regularExpression)
            .replacingOccurrences(of: #"<!--[\s\S]*?-->"#, with: "", options: .regularExpression)
        // Extract content between our wrapper's <body> and </body>
        guard let bodyStart = wrapped.range(of: "<body>"),
              let bodyEnd = wrapped.range(of: "</body>", options: .backwards) else {
            Issue.record("Missing <body> tags in wrapped output for input: \(input.prefix(40))")
            continue
        }
        let innerContent = String(wrapped[bodyStart.upperBound..<bodyEnd.lowerBound]).lowercased()
        #expect(!innerContent.contains("<html"), "Nested <html> found for input: \(input.prefix(40))")
        #expect(!innerContent.contains("<body"), "Nested <body> found for input: \(input.prefix(40))")
        #expect(!innerContent.contains("</html>"), "Nested </html> found for input: \(input.prefix(40))")
        #expect(!innerContent.contains("</body>"), "Nested </body> found for input: \(input.prefix(40))")
        #expect(!innerContent.contains("<!doctype"), "Nested DOCTYPE found for input: \(input.prefix(40))")
    }
}

@Test @MainActor func wrapHTMLUnwrapPreservesOutlookAgendaCSS() {
    // Real-world Outlook daily agenda email structure (simplified)
    let emailBody = """
    <html style="padding:0; margin:0; font-family:Segoe UI">
    <head>
    <meta http-equiv="Content-Type" content="text/html; charset=utf-8">
    <style>
    .hello { text-align:left }
    .event-list { width:100% }
    .footer { border-top:1px solid #eaeaea }
    </style>
    </head>
    <body style="padding:0; margin:0">
    <table><tr><td>Hello User,</td></tr></table>
    </body>
    </html>
    """
    let wrapped = EmailHTMLWrapper.wrapHTML(emailBody)

    // Email CSS classes must be preserved
    #expect(wrapped.contains(".hello { text-align:left }"))
    #expect(wrapped.contains(".event-list { width:100% }"))
    #expect(wrapped.contains(".footer { border-top:1px solid #eaeaea }"))

    // Content preserved
    #expect(wrapped.contains("Hello User,"))

    // Inline styles preserved on converted divs (body gets tm-email-body marker class)
    #expect(wrapped.contains("<div style=\"padding:0; margin:0; font-family:Segoe UI\">"))
    #expect(wrapped.contains("<div class=\"tm-email-body\" style=\"padding:0; margin:0\">"))

    // No meta tags from email (stripped)
    #expect(!wrapped.contains("charset="))
}

@Test @MainActor func wrapHTMLUnwrapCaseInsensitive() {
    // HTML tags can be uppercase
    let emailBody = "<HTML><HEAD><STYLE>.x{}</STYLE></HEAD><BODY>Test</BODY></HTML>"
    let wrapped = EmailHTMLWrapper.wrapHTML(emailBody)

    let htmlTagCount = wrapped.components(separatedBy: "<html>").count - 1
    #expect(htmlTagCount == 1)
    #expect(wrapped.contains(".x{}"))
    #expect(wrapped.contains("Test"))
}

// MARK: - CSS Root Selector Neutralization

@Test @MainActor func wrapHTMLNeutralizesRootOnlyRule() {
    // CSS rules targeting only html/body/:root must be removed entirely
    let emailBody = """
    <html>
    <head><style>:root, html, body { padding:0; margin:0; }</style></head>
    <body><p>Content</p></body>
    </html>
    """
    let wrapped = EmailHTMLWrapper.wrapHTML(emailBody)

    // The root-only rule should be gone (no padding:0 from email CSS)
    #expect(!wrapped.contains(":root, html, body"))
    // Content preserved
    #expect(wrapped.contains("<p>Content</p>"))
    // Our wrapper's body padding is now 0 — all gutters live in the SwiftUI
    // container on AutoSizingHTMLView, not in body CSS (they'd otherwise
    // get scaled by fitViewportJS's widening factor).
    #expect(wrapped.contains("padding: 0;"))
}

@Test @MainActor func wrapHTMLNeutralizesMixedSelectors() {
    // Mixed selectors: root selectors removed, others preserved
    let emailBody = """
    <html>
    <head><style>html, .hello { color: blue; }</style></head>
    <body><p>Content</p></body>
    </html>
    """
    let wrapped = EmailHTMLWrapper.wrapHTML(emailBody)

    // .hello rule preserved with its body
    #expect(wrapped.contains(".hello"))
    #expect(wrapped.contains("color: blue"))
    // "html" selector should not appear in a CSS rule context
    // (the only "html" should be our wrapper's <html> tag)
}

@Test @MainActor func wrapHTMLPreservesNonRootCSS() {
    // Non-root CSS rules must be completely untouched
    let emailBody = """
    <html>
    <head><style>
    .event-list { width:100% }
    .footer { border-top:1px solid #eaeaea }
    td { padding:5px }
    </style></head>
    <body><p>Content</p></body>
    </html>
    """
    let wrapped = EmailHTMLWrapper.wrapHTML(emailBody)

    #expect(wrapped.contains(".event-list { width:100% }"))
    #expect(wrapped.contains(".footer { border-top:1px solid #eaeaea }"))
    #expect(wrapped.contains("td { padding:5px }"))
}

@Test @MainActor func wrapHTMLNeutralizesOutlookAgendaRootCSS() {
    // Real Outlook agenda email pattern: HTML comments wrapping CSS + :root,html,body
    let emailBody = """
    <html style="padding:0; margin:0">
    <head><style>
    <!--
    :root, html, body
        {padding:0;
        margin:0;
        font-family:"Segoe UI"}
    .hello
        {text-align:left}
    .hello h1
        {font-size:24px}
    -->
    </style></head>
    <body style="padding:0; margin:0"><p>Hello</p></body>
    </html>
    """
    let wrapped = EmailHTMLWrapper.wrapHTML(emailBody)

    // :root and html selectors removed; body remapped to .tm-email-body
    // so the CSS body (font-family etc.) is preserved under .tm-email-body selector
    #expect(!wrapped.contains(":root"), "':root' selector should be removed")
    #expect(wrapped.contains(".tm-email-body"), "body selector should be remapped to .tm-email-body")
    // HTML comments themselves should be stripped from CSS
    #expect(!wrapped.contains("<!--"))
    #expect(!wrapped.contains("-->"))
    // Class rules preserved
    #expect(wrapped.contains(".hello"))
    #expect(wrapped.contains("text-align:left"))
    #expect(wrapped.contains("font-size:24px"))
    // Inline styles on converted divs preserved (body gets tm-email-body class)
    #expect(wrapped.contains("<div class=\"tm-email-body\" style=\"padding:0; margin:0\">"))
    // Our wrapper forces transparent background on .tm-email-body
    #expect(wrapped.contains(".tm-email-body { background: transparent !important"))
}

@Test @MainActor func wrapHTMLNeutralizesStyleInsideBody() {
    // Some Outlook emails have <style> inside <body>, not <head>.
    // Root selectors there must also be neutralized.
    let emailBody = """
    <html>
    <body>
    <style>
    <!--
    :root, html, body { padding:0; margin:0; background:#fff; }
    .content { color: red; }
    -->
    </style>
    <div class="content">Hello</div>
    </body>
    </html>
    """
    let wrapped = EmailHTMLWrapper.wrapHTML(emailBody)

    // :root and html selectors removed; body remapped to .tm-email-body
    // background:#fff is now under .tm-email-body rule (overridden by wrapper's !important transparent)
    #expect(!wrapped.contains(":root"), "':root' selector should be removed from body style blocks too")
    #expect(wrapped.contains(".tm-email-body"), "body selector remapped to .tm-email-body")
    // Class rule preserved
    #expect(wrapped.contains(".content { color: red; }"))
    // Content present
    #expect(wrapped.contains("Hello"))
}

@Test @MainActor func wrapHTMLNeutralizesStyleInBodyNoHead() {
    // Email with no <head> section at all — style directly inside body
    let emailBody = """
    <html style="margin:0">
    <body style="margin:0">
    <style>body { background-color: white; font-family: Arial; }</style>
    <p>Test</p>
    </body>
    </html>
    """
    let wrapped = EmailHTMLWrapper.wrapHTML(emailBody)

    // body selector remapped to .tm-email-body (background overridden by wrapper's !important)
    #expect(!wrapped.contains("body { background-color"), "bare body selector should be remapped")
    #expect(wrapped.contains(".tm-email-body{ background-color: white"), "body rules redirected to .tm-email-body")
    #expect(wrapped.contains("Test"))
}
