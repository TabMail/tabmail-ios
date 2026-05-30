/* This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at https://mozilla.org/MPL/2.0/. */

import Foundation

/// Discovers CalDAV principal URL and calendar-home-set for a given server.
/// iCloud: direct PROPFIND on caldav.icloud.com (NOT .well-known — unreliable).
/// Other servers: RFC 6764 .well-known/caldav → follow redirect → PROPFIND.
enum CalDAVDiscovery {

    struct DiscoveryResult {
        let principalURL: URL
        let calendarHomeURL: URL
    }

    static func discover(serverURL: URL, client: CalDAVClient) async throws -> DiscoveryResult {
        let isICloud = serverURL.host?.contains("icloud.com") == true

        // Step 1: Find principal URL
        let principalURL: URL
        if isICloud {
            principalURL = try await discoverPrincipal(baseURL: serverURL, client: client)
        } else {
            // Try .well-known first
            let wellKnownURL = serverURL.appendingPathComponent(".well-known/caldav")
            do {
                principalURL = try await discoverPrincipal(baseURL: wellKnownURL, client: client)
            } catch {
                // Fall back to direct PROPFIND on server URL
                print("[CalDAVDiscovery] .well-known failed, trying direct PROPFIND: \(error)")
                principalURL = try await discoverPrincipal(baseURL: serverURL, client: client)
            }
        }

        // Step 2: Get calendar-home-set from principal
        let calendarHomeURL = try await discoverCalendarHome(principalURL: principalURL, client: client)

        print("[CalDAVDiscovery] principal=\(principalURL), home=\(calendarHomeURL)")
        return DiscoveryResult(principalURL: principalURL, calendarHomeURL: calendarHomeURL)
    }

    // MARK: - Private

    private static func discoverPrincipal(baseURL: URL, client: CalDAVClient) async throws -> URL {
        let body = """
        <?xml version="1.0" encoding="utf-8"?>
        <d:propfind xmlns:d="DAV:">
          <d:prop>
            <d:current-user-principal/>
          </d:prop>
        </d:propfind>
        """

        let (data, response) = try await client.propfind(url: baseURL, body: body, depth: 0)
        let parsed = try MultistatusParser.parse(data: data)

        for resp in parsed {
            if let principalPath = resp.properties["current-user-principal"] {
                guard let url = URL(string: principalPath, relativeTo: resolveBaseURL(response, originalURL: baseURL)) else {
                    throw CalDAVError.discoveryFailed("Invalid principal URL: \(principalPath)")
                }
                return url.absoluteURL
            }
        }

        throw CalDAVError.discoveryFailed("No current-user-principal found")
    }

    private static func discoverCalendarHome(principalURL: URL, client: CalDAVClient) async throws -> URL {
        let body = """
        <?xml version="1.0" encoding="utf-8"?>
        <d:propfind xmlns:d="DAV:" xmlns:c="urn:ietf:params:xml:ns:caldav">
          <d:prop>
            <c:calendar-home-set/>
          </d:prop>
        </d:propfind>
        """

        let (data, _) = try await client.propfind(url: principalURL, body: body, depth: 0)
        let parsed = try MultistatusParser.parse(data: data)

        for resp in parsed {
            if let homePath = resp.properties["calendar-home-set"] {
                guard let url = URL(string: homePath, relativeTo: principalURL) else {
                    throw CalDAVError.discoveryFailed("Invalid calendar-home-set URL: \(homePath)")
                }
                return url.absoluteURL
            }
        }

        throw CalDAVError.discoveryFailed("No calendar-home-set found")
    }

    /// Resolve the base URL from the response (handles iCloud redirects).
    private static func resolveBaseURL(_ response: HTTPURLResponse, originalURL: URL) -> URL {
        if let responseURL = response.url {
            // Use the final URL after redirects
            return responseURL
        }
        return originalURL
    }
}
