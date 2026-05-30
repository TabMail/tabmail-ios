/* This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at https://mozilla.org/MPL/2.0/. */

import Testing
import Foundation
@testable import TabMail

@Suite("EmailFilter Extended - htmlToPlainText Edge Cases")
struct EmailFilterHTMLEdgeCaseTests {

    @Test("Nested tags: deeply nested divs and spans")
    func deeplyNestedTags() {
        let html = "<div><div><span><em><strong>Deep</strong></em></span></div></div>"
        let result = EmailFilter.htmlToPlainText(html)
        #expect(result.contains("Deep"))
        #expect(!result.contains("<"))
    }

    @Test("Multiple style blocks stripped")
    func multipleStyleBlocks() {
        let html = """
        <style>body { font-size: 14px; }</style>
        <p>Between</p>
        <style>.footer { display: none; }</style>
        <p>End</p>
        """
        let result = EmailFilter.htmlToPlainText(html)
        #expect(result.contains("Between"))
        #expect(result.contains("End"))
        #expect(!result.contains("font-size"))
        #expect(!result.contains("display"))
    }

    @Test("Script block with complex JS content stripped")
    func complexScriptBlock() {
        let html = """
        <script>
        var x = "<div>fake tag</div>";
        function test() { return x > 5 && y < 3; }
        </script>
        <p>Real content</p>
        """
        let result = EmailFilter.htmlToPlainText(html)
        #expect(result.contains("Real content"))
        #expect(!result.contains("function"))
        #expect(!result.contains("var x"))
    }

    @Test("Mixed style and script blocks with content between")
    func mixedStyleScriptBlocks() {
        let html = "<style>.x{}</style><p>A</p><script>alert(1)</script><p>B</p>"
        let result = EmailFilter.htmlToPlainText(html)
        #expect(result.contains("A"))
        #expect(result.contains("B"))
        #expect(!result.contains("alert"))
        #expect(!result.contains(".x"))
    }

    @Test("Head block with meta tags and title stripped")
    func headWithMetaAndTitle() {
        let html = """
        <html>
        <head>
        <meta charset="utf-8">
        <title>Email Subject</title>
        <link rel="stylesheet" href="style.css">
        </head>
        <body><p>Body content</p></body>
        </html>
        """
        let result = EmailFilter.htmlToPlainText(html)
        #expect(result.contains("Body content"))
        #expect(!result.contains("Email Subject"))
        #expect(!result.contains("meta"))
        #expect(!result.contains("charset"))
    }

    @Test("Self-closing tags handled")
    func selfClosingTags() {
        let result = EmailFilter.htmlToPlainText("Hello<br/>World<hr/>End")
        #expect(result.contains("Hello"))
        #expect(result.contains("World"))
        #expect(result.contains("End"))
    }

    @Test("Tags with attributes stripped cleanly")
    func tagsWithAttributes() {
        let html = """
        <a href="https://example.com" target="_blank" class="link">Click here</a>
        """
        let result = EmailFilter.htmlToPlainText(html)
        #expect(result.contains("Click here"))
        #expect(!result.contains("href"))
        #expect(!result.contains("example.com"))
    }

    @Test("HTML entities: ndash and mdash")
    func dashEntities() {
        let result = EmailFilter.htmlToPlainText("2020&ndash;2025 &mdash; a range")
        #expect(result.contains("\u{2013}"))
        #expect(result.contains("\u{2014}"))
    }

    @Test("HTML entities: smart quotes")
    func smartQuoteEntities() {
        let result = EmailFilter.htmlToPlainText("&ldquo;Hello&rdquo; &lsquo;World&rsquo;")
        #expect(result.contains("\u{201C}"))
        #expect(result.contains("\u{201D}"))
        #expect(result.contains("\u{2018}"))
        #expect(result.contains("\u{2019}"))
    }

    @Test("HTML entities: copyright, registered, trademark")
    func symbolEntities() {
        let result = EmailFilter.htmlToPlainText("&copy; &reg; &trade;")
        #expect(result.contains("\u{00A9}"))
        #expect(result.contains("\u{00AE}"))
        #expect(result.contains("\u{2122}"))
    }

    @Test("HTML entities: bullet and hellip")
    func bulletAndHellip() {
        let result = EmailFilter.htmlToPlainText("&bull; Item &hellip; more")
        #expect(result.contains("\u{2022}"))
        #expect(result.contains("\u{2026}"))
    }

    @Test("HTML entities: apos")
    func apostropheEntity() {
        let result = EmailFilter.htmlToPlainText("it&apos;s fine")
        #expect(result.contains("it's fine"))
    }

    @Test("Numeric decimal entity for arbitrary character")
    func numericDecimalEntity() {
        // &#65; = 'A'
        let result = EmailFilter.htmlToPlainText("&#65;BC")
        #expect(result.contains("ABC"))
    }

    @Test("Hex entity for arbitrary character")
    func hexEntityArbitrary() {
        // &#x41; = 'A'
        let result = EmailFilter.htmlToPlainText("&#x41;BC")
        #expect(result.contains("ABC"))
    }

    @Test("Hex entity case insensitive (uppercase X)")
    func hexEntityUppercaseX() {
        let result = EmailFilter.htmlToPlainText("&#X41;BC")
        #expect(result.contains("ABC"))
    }

    @Test("Unknown named entity replaced with space")
    func unknownNamedEntity() {
        let result = EmailFilter.htmlToPlainText("before&foobar;after")
        #expect(result.contains("before"))
        #expect(result.contains("after"))
    }

    @Test("Entity without semicolon treated as literal ampersand")
    func entityWithoutSemicolon() {
        let result = EmailFilter.htmlToPlainText("A&B")
        // Should pass through '&' and 'B' as regular characters
        #expect(result.contains("A"))
        #expect(result.contains("B"))
    }

    @Test("Multiple non-breaking spaces collapsed")
    func multipleNbspCollapsed() {
        let result = EmailFilter.htmlToPlainText("A&nbsp;&nbsp;&nbsp;B")
        // Multiple nbsp should collapse to single space
        #expect(result == "A B")
    }

    @Test("3-byte UTF-8 characters preserved (CJK)")
    func threeByteUTF8() {
        let result = EmailFilter.htmlToPlainText("<div>中文测试</div>")
        #expect(result == "中文测试")
    }
}

@Suite("EmailFilter Extended - HTML-to-snippet Edge Cases")
struct EmailFilterSnippetEdgeCaseTests {

    @Test("Empty HTML returns empty snippet")
    func emptyHTMLReturnsEmpty() {
        let plain = EmailFilter.htmlToPlainText("")
        let result = EmailFilter.snippetFromPlainText(plain)
        #expect(result.isEmpty)
    }

    @Test("HTML with only tags returns empty snippet")
    func htmlWithOnlyTags() {
        let plain = EmailFilter.htmlToPlainText("<div><span><br><hr></span></div>")
        let result = EmailFilter.snippetFromPlainText(plain)
        #expect(result.isEmpty)
    }

    @Test("HTML with only whitespace and tags returns empty")
    func htmlWithWhitespaceAndTags() {
        let plain = EmailFilter.htmlToPlainText("<p>   </p><div>\n\t</div>")
        let result = EmailFilter.snippetFromPlainText(plain)
        #expect(result.isEmpty)
    }

    @Test("Snippet from HTML with style block skips style content")
    func snippetSkipsStyleBlock() {
        let html = "<style>body{color:red}</style><p>Visible content here</p>"
        let plain = EmailFilter.htmlToPlainText(html)
        let result = EmailFilter.snippetFromPlainText(plain)
        #expect(result.contains("Visible"))
        #expect(!result.contains("color"))
    }
}

@Suite("EmailFilter Extended - isNoReply Edge Cases")
struct EmailFilterIsNoReplyEdgeCaseTests {

    @Test("isNoReply detects do_not_reply")
    func detectsDoNotReplyUnderscore() {
        #expect(EmailFilter.isNoReply("do_not_reply@example.com") == true)
    }

    @Test("isNoReply detects invitations@")
    func detectsInvitations() {
        #expect(EmailFilter.isNoReply("invitations@example.com") == true)
    }

    @Test("isNoReply detects announcements@")
    func detectsAnnouncements() {
        #expect(EmailFilter.isNoReply("announcements@example.com") == true)
    }

    @Test("isNoReply detects updates@")
    func detectsUpdates() {
        #expect(EmailFilter.isNoReply("updates@example.com") == true)
    }

    @Test("isNoReply detects digest@")
    func detectsDigest() {
        #expect(EmailFilter.isNoReply("digest@example.com") == true)
    }

    @Test("isNoReply detects digests@")
    func detectsDigests() {
        #expect(EmailFilter.isNoReply("digests@example.com") == true)
    }

    @Test("isNoReply with mixed case AUTOMATED@")
    func mixedCaseAutomated() {
        #expect(EmailFilter.isNoReply("AUTOMATED@company.com") == true)
    }

    @Test("isNoReply with pattern in subdomain")
    func patternInSubdomain() {
        #expect(EmailFilter.isNoReply("user@noreply.example.com") == true)
    }

    @Test("isNoReply empty string returns false")
    func emptyString() {
        #expect(EmailFilter.isNoReply("") == false)
    }

    @Test("isNoReply with pattern as part of longer word")
    func patternInLongerWord() {
        // "updates" is in the patterns list, so this should match
        #expect(EmailFilter.isNoReply("weekly-updates@example.com") == true)
    }

    @Test("isNoReply regular business address")
    func regularBusinessAddress() {
        #expect(EmailFilter.isNoReply("sales@company.com") == false)
        #expect(EmailFilter.isNoReply("hr@company.com") == false)
        #expect(EmailFilter.isNoReply("billing@company.com") == false)
    }
}

@Suite("EmailFilter Extended - decodeHTMLEntities Edge Cases")
struct EmailFilterDecodeEntitiesEdgeCaseTests {

    @Test("decodeHTMLEntities with &#39; (numeric apostrophe)")
    func numericApostrophe() {
        #expect(EmailFilter.decodeHTMLEntities("don&#39;t") == "don't")
    }

    @Test("decodeHTMLEntities with &#x27; (hex apostrophe)")
    func hexApostrophe() {
        #expect(EmailFilter.decodeHTMLEntities("don&#x27;t") == "don't")
    }

    @Test("decodeHTMLEntities preserves already-decoded text")
    func preservesDecodedText() {
        #expect(EmailFilter.decodeHTMLEntities("no entities here") == "no entities here")
    }

    @Test("decodeHTMLEntities chained entities")
    func chainedEntities() {
        let result = EmailFilter.decodeHTMLEntities("&amp;&lt;&gt;&quot;")
        #expect(result == "&<>\"")
    }

    @Test("decodeHTMLEntities only handles known entities")
    func unknownEntitiesPassThrough() {
        // decodeHTMLEntities is a simple string replace, unlike htmlToPlainText
        let result = EmailFilter.decodeHTMLEntities("&foobar;")
        #expect(result == "&foobar;")
    }

    @Test("decodeHTMLEntities with &nbsp; and surrounding text")
    func nbspWithSurrounding() {
        let result = EmailFilter.decodeHTMLEntities("Hello&nbsp;World")
        #expect(result == "Hello World")
    }

    @Test("decodeHTMLEntities empty string")
    func emptyString() {
        #expect(EmailFilter.decodeHTMLEntities("") == "")
    }
}

@Suite("EmailFilter Extended - hasUnsubscribeLink Edge Cases")
struct EmailFilterUnsubscribeEdgeCaseTests {

    @Test("hasUnsubscribeLink with 'manage your subscription' + http")
    func manageSubscription() {
        let html = "Manage your subscription http://example.com/prefs"
        #expect(EmailFilter.hasUnsubscribeLink(html) == true)
    }

    @Test("hasUnsubscribeLink with 'manage subscription' + www")
    func manageSubscriptionWww() {
        let html = "manage subscription at www.example.com"
        #expect(EmailFilter.hasUnsubscribeLink(html) == true)
    }

    @Test("hasUnsubscribeLink with 'email preferences' + click")
    func emailPreferencesClick() {
        let html = "Click to update your email preferences"
        #expect(EmailFilter.hasUnsubscribeLink(html) == true)
    }

    @Test("hasUnsubscribeLink with 'update your preferences' + http")
    func updatePreferences() {
        let html = "update your preferences at http://example.com"
        #expect(EmailFilter.hasUnsubscribeLink(html) == true)
    }

    @Test("hasUnsubscribeLink with pattern but no link keyword returns false")
    func patternWithoutLinkKeyword() {
        let html = "You may unsubscribe from this mailing list"
        #expect(EmailFilter.hasUnsubscribeLink(html) == false)
    }

    @Test("hasUnsubscribeLink empty string returns false")
    func emptyStringReturnsFalse() {
        #expect(EmailFilter.hasUnsubscribeLink("") == false)
    }

    @Test("hasUnsubscribeLink with 'opt-out' + click")
    func optOutWithClick() {
        let html = "click here to opt-out of future emails"
        #expect(EmailFilter.hasUnsubscribeLink(html) == true)
    }
}

@Suite("EmailFilter Extended - snippetFromPlainText Edge Cases")
struct EmailFilterSnippetPlainTextEdgeCaseTests {

    @Test("Collapses repeated equals signs")
    func collapsesEquals() {
        let text = "Section\n========\nContent"
        let result = EmailFilter.snippetFromPlainText(text)
        #expect(!result.contains("=="))
    }

    @Test("Collapses repeated asterisks")
    func collapsesAsterisks() {
        let text = "***Important***"
        let result = EmailFilter.snippetFromPlainText(text)
        #expect(!result.contains("**"))
    }

    @Test("Collapses repeated underscores")
    func collapsesUnderscores() {
        let text = "Section\n___________\nContent"
        let result = EmailFilter.snippetFromPlainText(text)
        #expect(!result.contains("__"))
    }

    @Test("Tab characters collapsed to space")
    func tabsCollapsed() {
        let result = EmailFilter.snippetFromPlainText("Hello\tWorld")
        #expect(result == "Hello World")
    }

    @Test("Only whitespace returns empty")
    func onlyWhitespace() {
        let result = EmailFilter.snippetFromPlainText("   \n\n\t  ")
        #expect(result.isEmpty)
    }
}
