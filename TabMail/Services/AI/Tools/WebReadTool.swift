/* This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at https://mozilla.org/MPL/2.0/. */

import Foundation

/// Client-side `web_read` tool matching TB addon's `web_read.js`.
/// Fetches a URL, extracts text content from HTML, and returns it for LLM consumption.
/// Respects robots.txt and standard web etiquette.
/// Registered in `ToolRegistry` at app startup.
struct WebReadTool: AgentTool, Sendable {
    let name = "web_read"

    private enum Config {
        static let timeoutSeconds: TimeInterval = 30
        static let robotsTimeoutSeconds: TimeInterval = 5
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

        print("[WebReadTool] Starting fetch for \(urlString)")

        // Check robots.txt
        let robotsAllowed = await checkRobotsTxt(url: url)
        if !robotsAllowed {
            print("[WebReadTool] Access disallowed by robots.txt")
            return #"{"error": "Access to this URL is disallowed by the site's robots.txt"}"#
        }

        // Fetch the content
        let (data, response): (Data, URLResponse)
        do {
            var request = URLRequest(url: url, timeoutInterval: Config.timeoutSeconds)
            request.setValue(Config.userAgent, forHTTPHeaderField: "User-Agent")
            (data, response) = try await sharedEphemeralSession.data(for: request)
        } catch {
            print("[WebReadTool] Fetch failed: \(error)")
            return ToolJSON.string(from: ["error": "Failed to fetch URL: \(error.localizedDescription)"])
        }

        guard let httpResponse = response as? HTTPURLResponse else {
            return #"{"error": "Invalid response"}"#
        }

        guard httpResponse.statusCode == 200 else {
            print("[WebReadTool] HTTP error \(httpResponse.statusCode)")
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
            print("[WebReadTool] Content too large (\(content.count) chars), truncating")
            content = String(content.prefix(Config.maxContentLength))
        }

        // Extract text if HTML
        var text = content
        if contentType.contains("text/html") || contentType.contains("application/xhtml") {
            print("[WebReadTool] Extracting text from HTML")
            text = Self.extractTextFromHTML(content)
        }

        print("[WebReadTool] Successfully fetched content (\(text.count) chars)")

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

    // MARK: - Robots.txt

    private func checkRobotsTxt(url: URL) async -> Bool {
        guard let host = url.host, let scheme = url.scheme else { return true }

        // Include port if non-standard (matches TB's urlObj.host which includes port)
        let hostWithPort: String
        if let port = url.port {
            hostWithPort = "\(host):\(port)"
        } else {
            hostWithPort = host
        }

        let robotsURLString = "\(scheme)://\(hostWithPort)/robots.txt"
        guard let robotsURL = URL(string: robotsURLString) else { return true }

        do {
            var request = URLRequest(url: robotsURL, timeoutInterval: Config.robotsTimeoutSeconds)
            request.setValue(Config.userAgent, forHTTPHeaderField: "User-Agent")
            let (data, response) = try await sharedEphemeralSession.data(for: request)

            guard let httpResponse = response as? HTTPURLResponse,
                  httpResponse.statusCode == 200,
                  let robotsTxt = String(data: data, encoding: .utf8) else {
                // No robots.txt or error → assume allowed
                return true
            }

            // url.path returns "" for root URLs; TB's pathname returns "/"
            let path = url.path.isEmpty ? "/" : url.path
            return Self.isPathAllowed(robotsTxt: robotsTxt, path: path, userAgent: Config.userAgent)
        } catch {
            // On error, be conservative and allow
            print("[WebReadTool] robots.txt check failed: \(error), assuming allowed")
            return true
        }
    }

    /// Parse robots.txt and check if the path is allowed. Matches TB's `isPathAllowedByRobots`.
    static func isPathAllowed(robotsTxt: String, path: String, userAgent: String) -> Bool {
        let lines = robotsTxt.components(separatedBy: "\n")
        var currentAgent: String?
        var disallowRules: [String] = []
        var allowRules: [String] = []

        for line in lines {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.isEmpty || trimmed.hasPrefix("#") { continue }

            let lower = trimmed.lowercased()
            if lower.hasPrefix("user-agent:") {
                let agent = String(trimmed.dropFirst(11)).trimmingCharacters(in: .whitespaces)
                currentAgent = agent
                if agent != "*" && agent != userAgent {
                    disallowRules = []
                    allowRules = []
                }
            } else if currentAgent == "*" || currentAgent == userAgent {
                if lower.hasPrefix("disallow:") {
                    let rule = String(trimmed.dropFirst(9)).trimmingCharacters(in: .whitespaces)
                    if !rule.isEmpty { disallowRules.append(rule) }
                } else if lower.hasPrefix("allow:") {
                    let rule = String(trimmed.dropFirst(6)).trimmingCharacters(in: .whitespaces)
                    if !rule.isEmpty { allowRules.append(rule) }
                }
            }
        }

        // Allow rules take precedence
        for rule in allowRules {
            if path.hasPrefix(rule) { return true }
        }

        for rule in disallowRules {
            if path.hasPrefix(rule) { return false }
        }

        return true
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
