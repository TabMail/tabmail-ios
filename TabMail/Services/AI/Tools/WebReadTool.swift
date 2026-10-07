/* This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at https://mozilla.org/MPL/2.0/. */

import Foundation

/// Client-side `web_read` tool matching TB addon's `web_read.js`.
/// Fetches a URL, extracts text content from HTML, and returns it for LLM consumption.
/// It reads one page the user asked for, as a browser does, so robots.txt (written for crawlers,
/// RFC 9309) is not consulted; the User-Agent names TabMail so a site can tell it apart.
/// Registered in `ToolRegistry` at app startup.
struct WebReadTool: AgentTool, Sendable {
    let name = "web_read"

    private enum Config {
        static let timeoutSeconds: TimeInterval = 30
        static let maxContentLength = 500_000 // 500KB max
        static let userAgent = "TabMail/1.0 (iOS; +https://tabmail.app)"
    }

    func execute(arguments: [String: JSONValue]) async throws -> String {
        guard case .string(let urlString) = arguments["url"],
              !urlString.trimmingCharacters(in: .whitespaces).isEmpty else {
            return #"{"error": "invalid or missing url"}"#
        }

        guard let url = URL(string: urlString),
              let scheme = url.scheme?.lowercased(),
              scheme == "http" || scheme == "https" else {
            return #"{"error": "Only http:// and https:// URLs are supported"}"#
        }

        BackgroundSyncLogger.logDebug("[WebReadTool] Starting fetch for \(urlString)")

        // Fetch the content
        let (data, response): (Data, URLResponse)
        do {
            var request = URLRequest(url: url, timeoutInterval: Config.timeoutSeconds)
            request.setValue(Config.userAgent, forHTTPHeaderField: "User-Agent")
            (data, response) = try await sharedEphemeralSession.data(for: request)
        } catch {
            BackgroundSyncLogger.logDebug("[WebReadTool] Fetch failed: \(error)")
            return ToolJSON.string(from: ["error": "Failed to fetch URL: \(error.localizedDescription)"])
        }

        guard let httpResponse = response as? HTTPURLResponse else {
            return #"{"error": "Invalid response"}"#
        }

        guard httpResponse.statusCode == 200 else {
            BackgroundSyncLogger.logDebug("[WebReadTool] HTTP error \(httpResponse.statusCode)")
            return ToolJSON.string(from: ["error": "HTTP error: \(httpResponse.statusCode)"])
        }

        // Decode content as string
        let contentType = httpResponse.value(forHTTPHeaderField: "Content-Type") ?? "text/plain"
        let encoding = Self.encoding(from: contentType) ?? .utf8
        guard var content = String(data: data, encoding: encoding) ?? String(data: data, encoding: .utf8) else {
            return #"{"error": "Could not decode response content"}"#
        }

        // Truncate if too large
        if content.count > Config.maxContentLength {
            BackgroundSyncLogger.logDebug("[WebReadTool] Content too large (\(content.count) chars), truncating")
            content = String(content.prefix(Config.maxContentLength))
        }

        // Extract text if HTML
        var text = content
        if contentType.contains("text/html") || contentType.contains("application/xhtml") {
            BackgroundSyncLogger.logDebug("[WebReadTool] Extracting text from HTML")
            text = Self.extractTextFromHTML(content)
        }

        BackgroundSyncLogger.logDebug("[WebReadTool] Successfully fetched content (\(text.count) chars)")

        // Format response matching TB's web_read output
        var lines: [String] = []
        lines.append("URL: \(urlString)")
        lines.append("Content-Type: \(contentType)")
        lines.append("Content-Length: \(text.count) characters")
        lines.append("")
        lines.append("Content:")
        lines.append(text)

        return lines.joined(separator: "\n")
    }

    // MARK: - HTML Text Extraction

    /// Strip HTML tags and extract readable text. Matches TB's `extractTextFromHTML`.
    static func extractTextFromHTML(_ html: String) -> String {
        var text = html

        // Remove script/style/nav/footer/header/aside/iframe/noscript blocks
        let tagsToRemove = ["script", "style", "nav", "footer", "header", "aside", "iframe", "noscript"]
        for tag in tagsToRemove {
            // Pattern: <tag ...>...</tag> (non-greedy, case-insensitive)
            if let regex = try? NSRegularExpression(
                pattern: "<\(tag)\\b[^>]*>.*?</\(tag)>",
                options: [.caseInsensitive, .dotMatchesLineSeparators]
            ) {
                text = regex.stringByReplacingMatches(
                    in: text, range: NSRange(text.startIndex..., in: text), withTemplate: ""
                )
            }
        }

        // Replace <br>, <br/>, <p>, <div>, <li>, <tr> with newlines
        if let brRegex = try? NSRegularExpression(pattern: "<br\\s*/?>|</p>|</div>|</li>|</tr>", options: .caseInsensitive) {
            text = brRegex.stringByReplacingMatches(
                in: text, range: NSRange(text.startIndex..., in: text), withTemplate: "\n"
            )
        }

        // Strip remaining HTML tags
        if let tagRegex = try? NSRegularExpression(pattern: "<[^>]+>", options: []) {
            text = tagRegex.stringByReplacingMatches(
                in: text, range: NSRange(text.startIndex..., in: text), withTemplate: " "
            )
        }

        // Decode common HTML entities
        text = text
            .replacingOccurrences(of: "&amp;", with: "&")
            .replacingOccurrences(of: "&lt;", with: "<")
            .replacingOccurrences(of: "&gt;", with: ">")
            .replacingOccurrences(of: "&quot;", with: "\"")
            .replacingOccurrences(of: "&#39;", with: "'")
            .replacingOccurrences(of: "&apos;", with: "'")
            .replacingOccurrences(of: "&nbsp;", with: " ")

        // Decode numeric HTML entities (&#NNN; and &#xHHH;)
        if let numericRegex = try? NSRegularExpression(pattern: "&#(\\d+);") {
            let nsText = text as NSString
            let matches = numericRegex.matches(in: text, range: NSRange(location: 0, length: nsText.length))
            for match in matches.reversed() {
                let codeStr = nsText.substring(with: match.range(at: 1))
                if let code = UInt32(codeStr), let scalar = Unicode.Scalar(code) {
                    text = (text as NSString).replacingCharacters(in: match.range, with: String(scalar))
                }
            }
        }
        if let hexRegex = try? NSRegularExpression(pattern: "&#x([0-9a-fA-F]+);") {
            let nsText = text as NSString
            let matches = hexRegex.matches(in: text, range: NSRange(location: 0, length: nsText.length))
            for match in matches.reversed() {
                let codeStr = nsText.substring(with: match.range(at: 1))
                if let code = UInt32(codeStr, radix: 16), let scalar = Unicode.Scalar(code) {
                    text = (text as NSString).replacingCharacters(in: match.range, with: String(scalar))
                }
            }
        }

        // Collapse multiple newlines and spaces
        if let multiNewline = try? NSRegularExpression(pattern: "\\n\\s*\\n\\s*\\n") {
            text = multiNewline.stringByReplacingMatches(
                in: text, range: NSRange(text.startIndex..., in: text), withTemplate: "\n\n"
            )
        }
        if let multiSpace = try? NSRegularExpression(pattern: "[ \\t]+") {
            text = multiSpace.stringByReplacingMatches(
                in: text, range: NSRange(text.startIndex..., in: text), withTemplate: " "
            )
        }

        return text.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    // MARK: - Encoding

    /// Extract text encoding from Content-Type header.
    private static func encoding(from contentType: String) -> String.Encoding? {
        let lower = contentType.lowercased()
        if lower.contains("charset=utf-8") { return .utf8 }
        if lower.contains("charset=iso-8859-1") || lower.contains("charset=latin1") { return .isoLatin1 }
        if lower.contains("charset=ascii") { return .ascii }
        if lower.contains("charset=utf-16") { return .utf16 }
        return nil
    }
}
