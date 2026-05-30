/* This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at https://mozilla.org/MPL/2.0/. */

import Testing
import Foundation
@testable import TabMail

@Suite("MultistatusParser")
struct MultistatusParserTests {

    @Test("Parse simple multistatus response")
    func parseSimple() throws {
        let xml = """
        <?xml version="1.0" encoding="UTF-8"?>
        <multistatus xmlns="DAV:" xmlns:C="urn:ietf:params:xml:ns:caldav">
          <response>
            <href>/cal/event1.ics</href>
            <propstat>
              <prop>
                <getetag>"abc123"</getetag>
              </prop>
            </propstat>
          </response>
        </multistatus>
        """
        let responses = try MultistatusParser.parse(data: Data(xml.utf8))
        #expect(responses.count == 1)
        #expect(responses[0].href == "/cal/event1.ics")
        #expect(responses[0].etag == "\"abc123\"")
    }

    @Test("Parse multiple responses")
    func parseMultiple() throws {
        let xml = """
        <?xml version="1.0" encoding="UTF-8"?>
        <multistatus xmlns="DAV:">
          <response>
            <href>/cal/event1.ics</href>
            <propstat><prop><getetag>"aaa"</getetag></prop></propstat>
          </response>
          <response>
            <href>/cal/event2.ics</href>
            <propstat><prop><getetag>"bbb"</getetag></prop></propstat>
          </response>
        </multistatus>
        """
        let responses = try MultistatusParser.parse(data: Data(xml.utf8))
        #expect(responses.count == 2)
        #expect(responses[0].href == "/cal/event1.ics")
        #expect(responses[1].href == "/cal/event2.ics")
    }

    @Test("Parse displayname property")
    func parseDisplayName() throws {
        let xml = """
        <?xml version="1.0" encoding="UTF-8"?>
        <multistatus xmlns="DAV:">
          <response>
            <href>/cal/</href>
            <propstat>
              <prop>
                <displayname>My Calendar</displayname>
              </prop>
            </propstat>
          </response>
        </multistatus>
        """
        let responses = try MultistatusParser.parse(data: Data(xml.utf8))
        #expect(responses[0].properties["displayname"] == "My Calendar")
    }

    @Test("Parse calendar-data")
    func parseCalendarData() throws {
        let icsData = "BEGIN:VCALENDAR\\nBEGIN:VEVENT\\nSUMMARY:Test\\nEND:VEVENT\\nEND:VCALENDAR"
        let xml = """
        <?xml version="1.0" encoding="UTF-8"?>
        <multistatus xmlns="DAV:" xmlns:C="urn:ietf:params:xml:ns:caldav">
          <response>
            <href>/cal/event.ics</href>
            <propstat>
              <prop>
                <C:calendar-data>\(icsData)</C:calendar-data>
              </prop>
            </propstat>
          </response>
        </multistatus>
        """
        let responses = try MultistatusParser.parse(data: Data(xml.utf8))
        #expect(responses[0].calendarData != nil)
        #expect(responses[0].calendarData?.contains("VCALENDAR") == true)
    }

    @Test("Parse resourcetype with calendar")
    func parseResourceType() throws {
        let xml = """
        <?xml version="1.0" encoding="UTF-8"?>
        <multistatus xmlns="DAV:" xmlns:C="urn:ietf:params:xml:ns:caldav">
          <response>
            <href>/cal/</href>
            <propstat>
              <prop>
                <resourcetype>
                  <collection/>
                  <C:calendar/>
                </resourcetype>
              </prop>
            </propstat>
          </response>
        </multistatus>
        """
        let responses = try MultistatusParser.parse(data: Data(xml.utf8))
        #expect(responses[0].resourceType.contains("collection"))
        #expect(responses[0].resourceType.contains("calendar"))
    }

    @Test("Throws on invalid XML")
    func throwsOnInvalidXML() {
        let xml = "this is not xml"
        #expect(throws: CalDAVError.self) {
            _ = try MultistatusParser.parse(data: Data(xml.utf8))
        }
    }

    @Test("Parse empty multistatus returns empty array")
    func parseEmptyMultistatus() throws {
        let xml = """
        <?xml version="1.0" encoding="UTF-8"?>
        <multistatus xmlns="DAV:">
        </multistatus>
        """
        let responses = try MultistatusParser.parse(data: Data(xml.utf8))
        #expect(responses.isEmpty)
    }

    @Test("Parse supported-calendar-component-set with VEVENT and VTODO")
    func parseSupportedComponents() throws {
        let xml = """
        <?xml version="1.0" encoding="UTF-8"?>
        <multistatus xmlns="DAV:" xmlns:C="urn:ietf:params:xml:ns:caldav">
          <response>
            <href>/cal/</href>
            <propstat>
              <prop>
                <C:supported-calendar-component-set>
                  <C:comp name="VEVENT"/>
                  <C:comp name="VTODO"/>
                </C:supported-calendar-component-set>
              </prop>
            </propstat>
          </response>
        </multistatus>
        """
        let responses = try MultistatusParser.parse(data: Data(xml.utf8))
        #expect(responses.count == 1)
        #expect(responses[0].supportedComponents.contains("VEVENT"))
        #expect(responses[0].supportedComponents.contains("VTODO"))
        #expect(responses[0].supportedComponents.count == 2)
    }

    @Test("Parse href inside property (calendar-home-set)")
    func parseHrefInsideProperty() throws {
        let xml = """
        <?xml version="1.0" encoding="UTF-8"?>
        <multistatus xmlns="DAV:">
          <response>
            <href>/principals/user/</href>
            <propstat>
              <prop>
                <calendar-home-set>
                  <href>/calendars/user/</href>
                </calendar-home-set>
              </prop>
            </propstat>
          </response>
        </multistatus>
        """
        let responses = try MultistatusParser.parse(data: Data(xml.utf8))
        #expect(responses[0].href == "/principals/user/")
        #expect(responses[0].properties["calendar-home-set"] == "/calendars/user/")
    }

    @Test("Parse getctag property")
    func parseGetctag() throws {
        let xml = """
        <?xml version="1.0" encoding="UTF-8"?>
        <multistatus xmlns="DAV:" xmlns:CS="http://calendarserver.org/ns/">
          <response>
            <href>/cal/</href>
            <propstat>
              <prop>
                <CS:getctag>ctag-value-123</CS:getctag>
              </prop>
            </propstat>
          </response>
        </multistatus>
        """
        let responses = try MultistatusParser.parse(data: Data(xml.utf8))
        #expect(responses[0].properties["getctag"] == "ctag-value-123")
    }

    @Test("Parse calendar-color property")
    func parseCalendarColor() throws {
        let xml = """
        <?xml version="1.0" encoding="UTF-8"?>
        <multistatus xmlns="DAV:" xmlns:A="http://apple.com/ns/ical/">
          <response>
            <href>/cal/</href>
            <propstat>
              <prop>
                <A:calendar-color>#FF5733FF</A:calendar-color>
              </prop>
            </propstat>
          </response>
        </multistatus>
        """
        let responses = try MultistatusParser.parse(data: Data(xml.utf8))
        #expect(responses[0].properties["calendar-color"] == "#FF5733FF")
    }

    @Test("Parse calendar-order property")
    func parseCalendarOrder() throws {
        let xml = """
        <?xml version="1.0" encoding="UTF-8"?>
        <multistatus xmlns="DAV:" xmlns:A="http://apple.com/ns/ical/">
          <response>
            <href>/cal/</href>
            <propstat>
              <prop>
                <A:calendar-order>3</A:calendar-order>
              </prop>
            </propstat>
          </response>
        </multistatus>
        """
        let responses = try MultistatusParser.parse(data: Data(xml.utf8))
        #expect(responses[0].properties["calendar-order"] == "3")
    }

    @Test("Parse write privilege sets writable property")
    func parseWritePrivilege() throws {
        let xml = """
        <?xml version="1.0" encoding="UTF-8"?>
        <multistatus xmlns="DAV:">
          <response>
            <href>/cal/</href>
            <propstat>
              <prop>
                <current-user-privilege-set>
                  <privilege><read/></privilege>
                  <privilege><write/></privilege>
                </current-user-privilege-set>
              </prop>
            </propstat>
          </response>
        </multistatus>
        """
        let responses = try MultistatusParser.parse(data: Data(xml.utf8))
        #expect(responses[0].properties["writable"] == "true")
    }

    @Test("Parse write-content privilege sets writable property")
    func parseWriteContentPrivilege() throws {
        let xml = """
        <?xml version="1.0" encoding="UTF-8"?>
        <multistatus xmlns="DAV:">
          <response>
            <href>/cal/</href>
            <propstat>
              <prop>
                <current-user-privilege-set>
                  <privilege><read/></privilege>
                  <privilege><write-content/></privilege>
                </current-user-privilege-set>
              </prop>
            </propstat>
          </response>
        </multistatus>
        """
        let responses = try MultistatusParser.parse(data: Data(xml.utf8))
        #expect(responses[0].properties["writable"] == "true")
    }

    @Test("Parse full calendar discovery response with all properties")
    func parseFullCalendarDiscovery() throws {
        let xml = """
        <?xml version="1.0" encoding="UTF-8"?>
        <multistatus xmlns="DAV:" xmlns:C="urn:ietf:params:xml:ns:caldav" xmlns:CS="http://calendarserver.org/ns/" xmlns:A="http://apple.com/ns/ical/">
          <response>
            <href>/cal/personal/</href>
            <propstat>
              <prop>
                <displayname>Personal</displayname>
                <resourcetype>
                  <collection/>
                  <C:calendar/>
                </resourcetype>
                <CS:getctag>ctag-abc</CS:getctag>
                <A:calendar-color>#0000FFFF</A:calendar-color>
                <A:calendar-order>1</A:calendar-order>
                <C:supported-calendar-component-set>
                  <C:comp name="VEVENT"/>
                  <C:comp name="VJOURNAL"/>
                </C:supported-calendar-component-set>
                <current-user-privilege-set>
                  <privilege><read/></privilege>
                  <privilege><write/></privilege>
                </current-user-privilege-set>
              </prop>
            </propstat>
          </response>
        </multistatus>
        """
        let responses = try MultistatusParser.parse(data: Data(xml.utf8))
        #expect(responses.count == 1)
        let r = responses[0]
        #expect(r.href == "/cal/personal/")
        #expect(r.properties["displayname"] == "Personal")
        #expect(r.resourceType.contains("collection"))
        #expect(r.resourceType.contains("calendar"))
        #expect(r.properties["getctag"] == "ctag-abc")
        #expect(r.properties["calendar-color"] == "#0000FFFF")
        #expect(r.properties["calendar-order"] == "1")
        #expect(r.supportedComponents == Set(["VEVENT", "VJOURNAL"]))
        #expect(r.properties["writable"] == "true")
    }

    @Test("Parse current-user-principal href inside property")
    func parseCurrentUserPrincipal() throws {
        let xml = """
        <?xml version="1.0" encoding="UTF-8"?>
        <multistatus xmlns="DAV:">
          <response>
            <href>/</href>
            <propstat>
              <prop>
                <current-user-principal>
                  <href>/principals/users/admin/</href>
                </current-user-principal>
              </prop>
            </propstat>
          </response>
        </multistatus>
        """
        let responses = try MultistatusParser.parse(data: Data(xml.utf8))
        #expect(responses[0].href == "/")
        #expect(responses[0].properties["current-user-principal"] == "/principals/users/admin/")
    }
}
