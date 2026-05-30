/* This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at https://mozilla.org/MPL/2.0/. */

import Testing
import Foundation
@testable import TabMail

@Suite("WebReadTool Argument Validation")
struct WebReadToolArgumentTests {

    @Test("Tool name is web_read")
    func toolName() {
        let tool = WebReadTool()
        #expect(tool.name == "web_read")
    }

    @Test("Missing url returns error")
    func missingUrl() async throws {
        let tool = WebReadTool()
        let result = try await tool.execute(arguments: [:])
        #expect(result.contains("invalid or missing url"))
    }

    @Test("Non-string url (int) returns error")
    func intUrl() async throws {
        let tool = WebReadTool()
        let result = try await tool.execute(arguments: ["url": .int(42)])
        #expect(result.contains("invalid or missing url"))
    }

    @Test("Non-string url (bool) returns error")
    func boolUrl() async throws {
        let tool = WebReadTool()
        let result = try await tool.execute(arguments: ["url": .bool(true)])
        #expect(result.contains("invalid or missing url"))
    }

    @Test("Non-string url (array) returns error")
    func arrayUrl() async throws {
        let tool = WebReadTool()
        let result = try await tool.execute(arguments: ["url": .array([.string("http://example.com")])])
        #expect(result.contains("invalid or missing url"))
    }

    @Test("Non-string url (dictionary) returns error")
    func dictUrl() async throws {
        let tool = WebReadTool()
        let result = try await tool.execute(arguments: ["url": .dictionary(["k": .string("v")])])
        #expect(result.contains("invalid or missing url"))
    }

    @Test("Empty string url returns error")
    func emptyUrl() async throws {
        let tool = WebReadTool()
        let result = try await tool.execute(arguments: ["url": .string("")])
        #expect(result.contains("invalid or missing url"))
    }

    @Test("Whitespace-only url returns error")
    func whitespaceUrl() async throws {
        let tool = WebReadTool()
        let result = try await tool.execute(arguments: ["url": .string("   ")])
        #expect(result.contains("invalid or missing url"))
    }

    @Test("ftp:// scheme returns error")
    func ftpScheme() async throws {
        let tool = WebReadTool()
        let result = try await tool.execute(arguments: ["url": .string("ftp://example.com/file.txt")])
        #expect(result.contains("Only http:// and https:// URLs are supported"))
    }

    @Test("file:// scheme returns error")
    func fileScheme() async throws {
        let tool = WebReadTool()
        let result = try await tool.execute(arguments: ["url": .string("file:///etc/passwd")])
        #expect(result.contains("Only http:// and https:// URLs are supported"))
    }

    @Test("mailto: scheme returns error")
    func mailtoScheme() async throws {
        let tool = WebReadTool()
        let result = try await tool.execute(arguments: ["url": .string("mailto:user@example.com")])
        #expect(result.contains("Only http:// and https:// URLs are supported"))
    }

    @Test("URL without scheme returns error")
    func noScheme() async throws {
        let tool = WebReadTool()
        let result = try await tool.execute(arguments: ["url": .string("example.com/page")])
        #expect(result.contains("Only http:// and https:// URLs are supported"))
    }

    @Test("javascript: scheme returns error")
    func javascriptScheme() async throws {
        let tool = WebReadTool()
        let result = try await tool.execute(arguments: ["url": .string("javascript:alert(1)")])
        #expect(result.contains("Only http:// and https:// URLs are supported"))
    }

    @Test("data: scheme returns error")
    func dataScheme() async throws {
        let tool = WebReadTool()
        let result = try await tool.execute(arguments: ["url": .string("data:text/html,<h1>hello</h1>")])
        #expect(result.contains("Only http:// and https:// URLs are supported"))
    }
}

@Suite("WebReadTool robots.txt Parsing")
struct WebReadToolRobotsTests {

    @Test("Empty robots.txt allows all paths")
    func emptyRobotsTxt() {
        #expect(WebReadTool.isPathAllowed(robotsTxt: "", path: "/anything", userAgent: "TestBot"))
    }

    @Test("Disallow root blocks everything")
    func disallowRoot() {
        let robots = """
        User-agent: *
        Disallow: /
        """
        #expect(!WebReadTool.isPathAllowed(robotsTxt: robots, path: "/page", userAgent: "TestBot"))
    }

    @Test("Specific path disallowed")
    func specificPathDisallowed() {
        let robots = """
        User-agent: *
        Disallow: /private/
        """
        #expect(!WebReadTool.isPathAllowed(robotsTxt: robots, path: "/private/secret", userAgent: "TestBot"))
        #expect(WebReadTool.isPathAllowed(robotsTxt: robots, path: "/public/page", userAgent: "TestBot"))
    }

    @Test("Allow takes precedence over Disallow")
    func allowPrecedence() {
        let robots = """
        User-agent: *
        Disallow: /private/
        Allow: /private/public-page
        """
        #expect(WebReadTool.isPathAllowed(robotsTxt: robots, path: "/private/public-page", userAgent: "TestBot"))
    }

    @Test("Specific user-agent rules apply")
    func specificUserAgent() {
        let robots = """
        User-agent: *
        Disallow:

        User-agent: BadBot
        Disallow: /
        """
        #expect(!WebReadTool.isPathAllowed(robotsTxt: robots, path: "/page", userAgent: "BadBot"))
    }

    @Test("Comments and blank lines ignored")
    func commentsIgnored() {
        let robots = """
        # This is a comment
        User-agent: *

        # Another comment
        Disallow: /secret
        """
        #expect(!WebReadTool.isPathAllowed(robotsTxt: robots, path: "/secret", userAgent: "Bot"))
        #expect(WebReadTool.isPathAllowed(robotsTxt: robots, path: "/public", userAgent: "Bot"))
    }

    @Test("No matching disallow allows by default")
    func noMatchingDisallow() {
        let robots = """
        User-agent: *
        Disallow: /admin
        """
        #expect(WebReadTool.isPathAllowed(robotsTxt: robots, path: "/page", userAgent: "Bot"))
    }
}

@Suite("WebReadTool HTML Text Extraction")
struct WebReadToolHTMLTests {

    @Test("Strips HTML tags")
    func stripsHTMLTags() {
        let html = "<p>Hello <b>world</b></p>"
        let text = WebReadTool.extractTextFromHTML(html)
        #expect(text.contains("Hello"))
        #expect(text.contains("world"))
        #expect(!text.contains("<p>"))
        #expect(!text.contains("<b>"))
    }

    @Test("Removes script tags and content")
    func removesScriptTags() {
        let html = "<p>Keep this</p><script>var x = 1;</script><p>And this</p>"
        let text = WebReadTool.extractTextFromHTML(html)
        #expect(text.contains("Keep this"))
        #expect(text.contains("And this"))
        #expect(!text.contains("var x"))
    }

    @Test("Removes style tags and content")
    func removesStyleTags() {
        let html = "<style>.red { color: red; }</style><p>Visible</p>"
        let text = WebReadTool.extractTextFromHTML(html)
        #expect(text.contains("Visible"))
        #expect(!text.contains("color"))
    }

    @Test("br tags become newlines")
    func brBecomesNewline() {
        let html = "Line 1<br>Line 2<br/>Line 3"
        let text = WebReadTool.extractTextFromHTML(html)
        #expect(text.contains("Line 1"))
        #expect(text.contains("Line 2"))
        #expect(text.contains("Line 3"))
    }

    @Test("Decodes common HTML entities")
    func decodesHTMLEntities() {
        let html = "&amp; &lt; &gt; &quot; &#39; &nbsp;"
        let text = WebReadTool.extractTextFromHTML(html)
        #expect(text.contains("&"))
        #expect(text.contains("<"))
        #expect(text.contains(">"))
        #expect(text.contains("\""))
        #expect(text.contains("'"))
    }

    @Test("Decodes numeric HTML entities")
    func decodesNumericEntities() {
        let html = "&#65;&#66;&#67;"  // ABC
        let text = WebReadTool.extractTextFromHTML(html)
        #expect(text.contains("ABC"))
    }

    @Test("Decodes hex HTML entities")
    func decodesHexEntities() {
        let html = "&#x41;&#x42;&#x43;"  // ABC
        let text = WebReadTool.extractTextFromHTML(html)
        #expect(text.contains("ABC"))
    }

    @Test("Removes nav, footer, header, aside blocks")
    func removesLayoutBlocks() {
        let html = "<nav>Menu</nav><p>Content</p><footer>Footer</footer>"
        let text = WebReadTool.extractTextFromHTML(html)
        #expect(text.contains("Content"))
        #expect(!text.contains("Menu"))
        #expect(!text.contains("Footer"))
    }

    @Test("Collapses multiple newlines")
    func collapsesNewlines() {
        let html = "<p>A</p><p></p><p></p><p>B</p>"
        let text = WebReadTool.extractTextFromHTML(html)
        // Should not have more than 2 consecutive newlines
        #expect(!text.contains("\n\n\n"))
    }

    @Test("Empty HTML returns empty")
    func emptyHTML() {
        let text = WebReadTool.extractTextFromHTML("")
        #expect(text.isEmpty)
    }
}
