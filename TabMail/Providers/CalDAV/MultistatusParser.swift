/* This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at https://mozilla.org/MPL/2.0/. */

import Foundation

/// Parses WebDAV multistatus XML responses.
/// Handles the two-layer parsing: XML multistatus → extract href, etag, calendar-data, and properties.
enum MultistatusParser {

    struct Response {
        var href: String
        var properties: [String: String] = [:]
        var calendarData: String?
        var etag: String?
        var resourceType: Set<String> = []
        /// Calendar component types (VEVENT, VTODO, VJOURNAL) from supported-calendar-component-set.
        var supportedComponents: Set<String> = []
    }

    static func parse(data: Data) throws -> [Response] {
        let delegate = MultistatusXMLDelegate()
        let parser = XMLParser(data: data)
        parser.delegate = delegate
        parser.shouldProcessNamespaces = true
        guard parser.parse() else {
            throw CalDAVError.parseError("Failed to parse multistatus XML: \(parser.parserError?.localizedDescription ?? "unknown")")
        }
        return delegate.responses
    }
}

// MARK: - XMLParser Delegate

private final class MultistatusXMLDelegate: NSObject, XMLParserDelegate {
    var responses: [MultistatusParser.Response] = []

    private var currentResponse: MultistatusParser.Response?
    private var currentText = ""
    private var elementStack: [String] = []
    private var inResourceType = false
    private var inSupportedComponents = false

    func parser(_ parser: XMLParser, didStartElement elementName: String,
                namespaceURI: String?, qualifiedName: String?,
                attributes: [String: String]) {
        let localName = localElementName(elementName)
        elementStack.append(localName)
        currentText = ""

        if localName == "response" {
            currentResponse = MultistatusParser.Response(href: "")
        } else if localName == "resourcetype" {
            inResourceType = true
        } else if inResourceType {
            currentResponse?.resourceType.insert(localName)
        } else if localName == "supported-calendar-component-set" {
            inSupportedComponents = true
        } else if inSupportedComponents && localName == "comp" {
            // <comp name="VEVENT"/> or <comp name="VTODO"/>
            if let name = attributes["name"] {
                currentResponse?.supportedComponents.insert(name)
            }
        }
    }

    func parser(_ parser: XMLParser, foundCharacters string: String) {
        currentText += string
    }

    func parser(_ parser: XMLParser, didEndElement elementName: String,
                namespaceURI: String?, qualifiedName: String?) {
        let localName = localElementName(elementName)
        let text = currentText.trimmingCharacters(in: .whitespacesAndNewlines)

        if localName == "resourcetype" {
            inResourceType = false
        } else if localName == "supported-calendar-component-set" {
            inSupportedComponents = false
        }

        if localName == "response" {
            if let resp = currentResponse {
                responses.append(resp)
            }
            currentResponse = nil
        } else if localName == "href" && parentElement() == "response" {
            currentResponse?.href = text
        } else if localName == "href" {
            // href inside a property (e.g., current-user-principal, calendar-home-set)
            if let parent = elementStack.dropLast().last {
                currentResponse?.properties[parent] = text
            }
        } else if localName == "calendar-data" {
            currentResponse?.calendarData = text
        } else if localName == "getetag" {
            currentResponse?.etag = text
        } else if localName == "displayname" {
            currentResponse?.properties["displayname"] = text
        } else if localName == "getctag" {
            currentResponse?.properties["getctag"] = text
        } else if localName == "calendar-color" {
            currentResponse?.properties["calendar-color"] = text
        } else if localName == "calendar-order" {
            currentResponse?.properties["calendar-order"] = text
        } else if localName == "current-user-privilege-set" {
            // Handled by child elements
        } else if localName == "write" || localName == "write-content" {
            currentResponse?.properties["writable"] = "true"
        }

        if !elementStack.isEmpty {
            elementStack.removeLast()
        }
        currentText = ""
    }

    private func parentElement() -> String? {
        elementStack.dropLast().last
    }

    /// Strip namespace prefix from element name.
    private func localElementName(_ name: String) -> String {
        if let idx = name.lastIndex(of: ":") {
            return String(name[name.index(after: idx)...])
        }
        return name
    }
}
