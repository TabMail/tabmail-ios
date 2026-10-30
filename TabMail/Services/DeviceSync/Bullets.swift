/* This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at https://mozilla.org/MPL/2.0/. */

import Foundation

/// Device Sync's labelled bullets: the knowledge base's, the composition rules' and the action rules'
/// bullets, each carrying a label (writer name, counter), and per field the highest counter seen of
/// every name. The same rules run in TabMail for Thunderbird and in TabMail Voice, pinned by the
/// shared conformance vectors (`TabMailTests/Fixtures/DeviceSync/device-sync-vectors.json`); each
/// rule's ID is named where it is implemented. Pure functions: storage, writer names and messages are
/// the engine's (`BulletSync`).
///
/// Texts are compared as their exact Unicode scalars, never as Swift `String`s (which treat
/// canonically equivalent texts as equal): the other apps compare them code unit by code unit, and two
/// devices that disagree on whether two texts are the same would keep or delete different bullets.

/// The fields, in the order every app handles them (upgrade, connect).
enum BulletField: String, CaseIterable, Sendable {
    case kb, composition, action
}

struct BulletItem: Sendable {
    var section: String
    var text: String
}

struct Bullet: Sendable {
    var section: String
    var text: String
    var name: String
    var n: Int
}

/// The lines around a field's sections, never synced (DS-SKELETON).
struct FieldSkeleton: Sendable {
    var head: [String]
    var tail: [String]

    static let none = FieldSkeleton(head: [], tail: [])
}

/// A field's state: its skeleton, its live bullets in local order and its seen map.
struct FieldState: Sendable {
    var head: [String]
    var tail: [String]
    var bullets: [Bullet]
    var seen: [String: Int]
}

/// The shared default catalog (DS-DEFAULT): `device-sync-default-catalog.json`, byte-identical in
/// the three apps.
struct DefaultCatalog: Sendable {
    struct Entry: Sendable {
        var id: String
        var field: String
        var section: String
        var text: String
    }

    var defaults: [Entry]

    /// Reads the catalog file's JSON.
    static func decode(_ data: Data) throws -> DefaultCatalog {
        struct File: Decodable {
            struct Entry: Decodable { let id, field, section, text: String }
            let defaults: [Entry]
        }
        let file = try JSONDecoder().decode(File.self, from: data)
        return DefaultCatalog(defaults: file.defaults.map { Entry(id: $0.id, field: $0.field, section: $0.section, text: $0.text) })
    }
}

/// A (section, text) compared by exact scalars.
struct BulletTextKey: Hashable {
    let section: [UInt8]
    let text: [UInt8]

    init(_ section: String, _ text: String) {
        self.section = Array(section.utf8)
        self.text = Array(text.utf8)
    }

    init(_ bullet: Bullet) { self.init(bullet.section, bullet.text) }
    init(_ item: BulletItem) { self.init(item.section, item.text) }
}

/// A label (writer name, counter).
struct BulletLabelKey: Hashable {
    let name: String
    let n: Int

    init(_ bullet: Bullet) {
        name = bullet.name
        n = bullet.n
    }
}

/// Hands out labels under this process's writer name (DS-NAME, DS-ORDER, R7).
struct BulletLabels {
    let next: () -> (name: String, n: Int)
}

enum Bullets {
    /// The composition and action rules' sections: key, then the header name (DS-SECTION). The
    /// knowledge base has the one section "" and no header (R1).
    static func sectionHeaders(_ field: BulletField) -> [(key: String, name: String)] {
        switch field {
        case .kb:
            return []
        case .composition:
            return [
                ("general", "General writing style"),
                ("language", "Language"),
                ("links", "Useful links to personal website and other resources"),
            ]
        case .action:
            return [
                ("delete", "Emails to be marked as `delete`"),
                ("archive", "Emails to be marked as `archive`"),
                ("reply", "Emails to be marked as `reply`"),
                ("none", "Emails to be marked as `none`"),
            ]
        }
    }

    static let headerMark = "DO NOT EDIT/DELETE THIS SECTION HEADER"
    static let instructionsEnd = "====END USER INSTRUCTIONS===="

    /// Released apps' time of a text never edited, or reset (DS-LEGACY-IN, DS-LEGACY-OUT).
    static let epochZero = "1970-01-01T00:00:00.000Z"

    /// The section keys this app shows for `field`.
    static func displayedSections(_ field: BulletField) -> [String] {
        field == .kb ? [""] : sectionHeaders(field).map(\.key)
    }

    // MARK: - Text (R2)

    /// ECMAScript WhiteSpace and LineTerminator, listed (R2): what "trimmed" strips at both ends.
    private static let trimmed: Set<UInt32> = [
        0x09, 0x0B, 0x0C, 0x20, 0xA0, 0xFEFF, 0x1680, 0x2000, 0x2001, 0x2002, 0x2003, 0x2004, 0x2005, 0x2006,
        0x2007, 0x2008, 0x2009, 0x200A, 0x202F, 0x205F, 0x3000, 0x2028, 0x2029, 0x0D, 0x0A,
    ]

    /// `text` without R2's whitespace at either end.
    static func trim(_ text: String) -> String {
        let scalars = text.unicodeScalars
        var start = scalars.startIndex
        var end = scalars.endIndex
        while start < end, trimmed.contains(scalars[start].value) { start = scalars.index(after: start) }
        while end > start, trimmed.contains(scalars[scalars.index(before: end)].value) { end = scalars.index(before: end) }
        return String(String.UnicodeScalarView(scalars[start..<end]))
    }

    /// The lines of `text`, split on "\r\n", "\r" and "\n" (R2).
    static func lines(_ text: String) -> [String] {
        var result: [String] = []
        var line = String.UnicodeScalarView()
        var previousCR = false
        for scalar in text.unicodeScalars {
            if scalar == "\n" {
                if previousCR {
                    previousCR = false
                    continue
                }
                result.append(String(line))
                line = String.UnicodeScalarView()
            } else if scalar == "\r" {
                result.append(String(line))
                line = String.UnicodeScalarView()
                previousCR = true
                continue
            } else {
                line.append(scalar)
            }
            previousCR = false
        }
        result.append(String(line))
        return result
    }

    /// Whether `text` holds a line break as DS-VALIDATE means it (R2).
    static func hasLineBreak(_ text: String) -> Bool {
        text.utf8.contains(0x0A) || text.utf8.contains(0x0D)
    }

    /// Whether two texts are the same, scalar for scalar.
    static func same(_ a: String, _ b: String) -> Bool {
        a.utf8.elementsEqual(b.utf8)
    }

    static func sameLines(_ a: [String], _ b: [String]) -> Bool {
        a.count == b.count && zip(a, b).allSatisfy { same($0, $1) }
    }

    /// Whether `text` holds `needle`, as bytes.
    static func contains(_ text: String, _ needle: String) -> Bool {
        let haystack = Array(text.utf8)
        let pattern = Array(needle.utf8)
        guard !pattern.isEmpty else { return true }
        guard haystack.count >= pattern.count else { return false }
        for start in 0...(haystack.count - pattern.count) where haystack[start] == pattern[0] {
            if haystack[start..<(start + pattern.count)].elementsEqual(pattern) { return true }
        }
        return false
    }

    /// A trimmed, non-empty line inside a section as a bullet's text: without its "- ", trimmed again;
    /// any other line as it is (DS-PARSE, R3).
    private static func bulletText(_ line: String) -> String {
        guard line.utf8.starts(with: [0x2D, 0x20]) else { return line }
        let scalars = line.unicodeScalars
        return trim(String(String.UnicodeScalarView(scalars[scalars.index(scalars.startIndex, offsetBy: 2)...])))
    }

    /// R23: in the sectioned fields a text holding the header mark or the END marker would be read back
    /// as a header or the skeleton, so it is not a bullet: no writer makes one, and a snapshot carrying
    /// one is dropped. The knowledge base has neither (R1).
    static func isMarkerText(_ field: BulletField, _ text: String) -> Bool {
        field != .kb && (contains(text, headerMark) || contains(text, instructionsEnd))
    }

    /// The section key whose header `line` is (R3): it holds the header's name and the marker; the
    /// first in order when several match.
    private static func headerOf(_ field: BulletField, _ line: String) -> String? {
        guard contains(line, headerMark) else { return nil }
        return sectionHeaders(field).first { contains(line, $0.name) }?.key
    }

    // MARK: - Parse and render

    struct Parsed: Sendable {
        var head: [String]
        var tail: [String]
        var bullets: [BulletItem]
    }

    /// DS-PARSE, DS-SKELETON: the shared reader. Lines before the first section header, and from the
    /// END marker on, are the skeleton, kept verbatim; in a section an empty line is skipped and every
    /// other line is a bullet. The knowledge base has no skeleton (R1).
    static func parse(_ field: BulletField, _ text: String) -> Parsed {
        var parsed = Parsed(head: [], tail: [], bullets: [])
        var section: String? = field == .kb ? "" : nil
        var ended = false
        for line in lines(text) {
            if field != .kb {
                if ended || contains(line, instructionsEnd) {
                    ended = true
                    parsed.tail.append(line)
                    continue
                }
                if let header = headerOf(field, line) {
                    section = header
                    continue
                }
                if section == nil {
                    parsed.head.append(line)
                    continue
                }
            }
            let content = trim(line)
            if !content.isEmpty { parsed.bullets.append(BulletItem(section: section ?? "", text: bulletText(content))) }
        }
        return parsed
    }

    /// DS-RENDER: the field's text, from its skeleton and its live bullets in local order, each section
    /// under its header. Bullets in a section this app doesn't know are kept but not shown.
    static func render(_ field: BulletField, head: [String], tail: [String], bullets: [Bullet]) -> String {
        func of(_ section: String) -> [String] {
            bullets.filter { same($0.section, section) }.map { "- " + $0.text }
        }
        if field == .kb { return of("").joined(separator: "\n") }
        var rendered = head
        for header in sectionHeaders(field) {
            rendered.append("# \(header.name) (\(headerMark))")
            rendered.append(contentsOf: of(header.key))
            rendered.append("")
        }
        rendered.append(contentsOf: tail)
        return rendered.joined(separator: "\n")
    }

    static func render(_ field: BulletField, _ state: FieldState) -> String {
        render(field, head: state.head, tail: state.tail, bullets: state.bullets)
    }

    // MARK: - Labels

    /// DS-DEDUP's order: the name as a byte string, then the counter.
    static func precedes(_ a: Bullet, _ b: Bullet) -> Bool {
        if a.name != b.name { return a.name.utf8.lexicographicallyPrecedes(b.name.utf8) }
        return a.n < b.n
    }

    static func isLive(_ state: FieldState, _ item: BulletItem) -> Bool {
        state.bullets.contains { same($0.section, item.section) && same($0.text, item.text) }
    }

    /// DS-LABEL, R4: a writer name (16 lowercase hex) or a default's (`default:<id>`).
    static func isName(_ value: String) -> Bool {
        let bytes = Array(value.utf8)
        if bytes.count == 16, bytes.allSatisfy({ (0x30...0x39).contains($0) || (0x61...0x66).contains($0) }) { return true }
        let prefix = Array("default:".utf8)
        guard bytes.count > prefix.count, bytes.starts(with: prefix) else { return false }
        return bytes[prefix.count...].allSatisfy { (0x61...0x7A).contains($0) || (0x30...0x39).contains($0) || $0 == 0x2D }
    }

    /// DS-DEDUP: one label for each (section, text), the smallest, where the first of them stood.
    static func dedup(_ bullets: [Bullet]) -> [Bullet] {
        var kept: [BulletTextKey: Int] = [:]
        var result: [Bullet] = []
        for bullet in bullets {
            let key = BulletTextKey(bullet)
            if let at = kept[key] {
                if precedes(bullet, result[at]) { result[at] = bullet }
            } else {
                kept[key] = result.count
                result.append(bullet)
            }
        }
        return result
    }

    // MARK: - Defaults (DS-DEFAULT)

    static func defaultName(_ entry: DefaultCatalog.Entry) -> String {
        "default:\(entry.id)"
    }

    /// DS-DEFAULT, DS-RESET: `field` as a new install or a reset holds it: every catalog default under
    /// its own label, each seen.
    static func defaultState(_ field: BulletField, skeleton: FieldSkeleton, catalog: DefaultCatalog) -> FieldState {
        let entries = catalog.defaults.filter { $0.field == field.rawValue }
        var seen: [String: Int] = [:]
        for entry in entries { seen[defaultName(entry)] = 1 }
        return FieldState(
            head: skeleton.head,
            tail: skeleton.tail,
            bullets: entries.map { Bullet(section: $0.section, text: $0.text, name: defaultName($0), n: 1) },
            seen: seen
        )
    }

    private static func catalogMatch(_ field: BulletField, _ item: BulletItem, _ catalog: DefaultCatalog) -> DefaultCatalog.Entry? {
        catalog.defaults.first { $0.field == field.rawValue && same($0.section, item.section) && same($0.text, item.text) }
    }

    // MARK: - Local operations

    private static func withLabel(_ state: inout FieldState, _ item: BulletItem, _ labels: BulletLabels) {
        let label = labels.next()
        state.bullets.append(Bullet(section: item.section, text: item.text, name: label.name, n: label.n))
        // DS-ORDER: seen in the same commit.
        state.seen[label.name] = max(state.seen[label.name] ?? 0, label.n)
    }

    /// DS-ADD: `items` added, each not already live, under fresh labels.
    static func add(_ state: FieldState, _ items: [BulletItem], _ labels: BulletLabels) -> FieldState {
        var next = state
        for item in items where !isLive(next, item) { withLabel(&next, item, labels) }
        return next
    }

    /// DS-CAPTURE commit, and with it DS-DELETE and DS-EDIT (a deleted or reworded bullet is a captured
    /// text `result` lacks; a reworded or moved one's new text is added under a new label): of the
    /// `captured` labels, those whose (section, text) `result` lacks are deleted when still live; a
    /// captured text `result` keeps its label; every other text of `result` is added (DS-ADD). A bullet
    /// that arrived since the capture is never deleted.
    static func commitCapture(_ state: FieldState, captured: [Bullet], result: [BulletItem], _ labels: BulletLabels) -> FieldState {
        let kept = Set(result.map(BulletTextKey.init))
        let capturedTexts = Set(captured.map(BulletTextKey.init))
        let deleted = Set(captured.filter { !kept.contains(BulletTextKey($0)) }.map(BulletLabelKey.init))
        var next = state
        next.bullets = state.bullets.filter { !deleted.contains(BulletLabelKey($0)) }
        return add(next, result.filter { !capturedTexts.contains(BulletTextKey($0)) }, labels)
    }

    /// DS-UPGRADE steps 1-4: `text` parsed; a catalog default under its label, every other bullet under
    /// a fresh one, in order; seen from those labels only; then DS-DEDUP. The device's own skeleton is
    /// kept.
    static func upgrade(_ field: BulletField, text: String, _ labels: BulletLabels, catalog: DefaultCatalog) -> FieldState {
        let parsed = parse(field, text)
        var state = FieldState(head: parsed.head, tail: parsed.tail, bullets: [], seen: [:])
        for item in parsed.bullets where !isMarkerText(field, item.text) {
            guard let entry = catalogMatch(field, item, catalog) else {
                withLabel(&state, item, labels)
                continue
            }
            let name = defaultName(entry)
            if !state.bullets.contains(where: { $0.name == name }) {
                state.bullets.append(Bullet(section: item.section, text: item.text, name: name, n: 1))
            }
            state.seen[name] = 1
        }
        state.bullets = dedup(state.bullets)
        return state
    }

    /// DS-LEGACY-IN: a released device's `text` imported, additions only: each (section, text) not live
    /// here added, a catalog default under its own label unless it was seen (deleted here), any other
    /// under a fresh one. Nothing is deleted.
    static func importLegacy(_ field: BulletField, _ state: FieldState, text: String, _ labels: BulletLabels, catalog: DefaultCatalog) -> FieldState {
        var next = state
        for item in parse(field, text).bullets {
            if isLive(next, item) || isMarkerText(field, item.text) { continue }
            guard let entry = catalogMatch(field, item, catalog) else {
                withLabel(&next, item, labels)
                continue
            }
            let name = defaultName(entry)
            // DS-MERGE-1 for the default's label.
            if (next.seen[name] ?? 0) >= 1 { continue }
            next.bullets.append(Bullet(section: item.section, text: item.text, name: name, n: 1))
            next.seen[name] = 1
        }
        next.bullets = dedup(next.bullets)
        return next
    }

    // MARK: - Merge (§6)

    enum MergeResult {
        case merged(state: FieldState, differed: Bool)
        /// DS-MERGE-3: one label with another text or section here, or twice in the message.
        case conflict(name: String, n: Int)
    }

    /// DS-MERGE-1..5: an incoming complete snapshot (bullets, seen) merged into `local`.
    static func merge(_ local: FieldState, bullets incomingBullets: [Bullet], seen incomingSeen: [String: Int]) -> MergeResult {
        var localByLabel: [BulletLabelKey: Bullet] = [:]
        for bullet in local.bullets { localByLabel[BulletLabelKey(bullet)] = bullet }
        var incomingByLabel: [BulletLabelKey: Bullet] = [:]
        var incomingOrder: [BulletLabelKey] = []
        for bullet in incomingBullets {
            let key = BulletLabelKey(bullet)
            if let other = incomingByLabel[key] ?? localByLabel[key],
               !same(other.section, bullet.section) || !same(other.text, bullet.text) {
                return .conflict(name: bullet.name, n: bullet.n)
            }
            if incomingByLabel[key] == nil {
                incomingByLabel[key] = bullet
                incomingOrder.append(key)
            }
        }
        let before = local.seen
        // DS-MERGE-2 and -3: a local label the message lacks is dropped when the sender has seen it.
        var bullets = local.bullets.filter { incomingByLabel[BulletLabelKey($0)] != nil || (incomingSeen[$0.name] ?? 0) < $0.n }
        // DS-MERGE-1: an incoming label new here is rejected when the map BEFORE this merge has seen it.
        for key in incomingOrder {
            guard let bullet = incomingByLabel[key] else { continue }
            if localByLabel[key] == nil, (before[bullet.name] ?? 0) < bullet.n { bullets.append(bullet) }
        }
        // DS-MERGE-4.
        var seen = before
        for (name, n) in incomingSeen where (seen[name] ?? 0) < n { seen[name] = n }
        // DS-SEND's difference: the incoming labels against this device's before the merge.
        let differed = incomingByLabel.count != localByLabel.count || incomingOrder.contains { localByLabel[$0] == nil }
        // DS-MERGE-5.
        return .merged(state: FieldState(head: local.head, tail: local.tail, bullets: dedup(bullets), seen: seen), differed: differed)
    }

    /// Whether two states hold the same bullets in the same order, the same seen map and skeleton.
    static func sameState(_ a: FieldState, _ b: FieldState) -> Bool {
        a.bullets.count == b.bullets.count
            && zip(a.bullets, b.bullets).allSatisfy { same($0.section, $1.section) && same($0.text, $1.text) && $0.name == $1.name && $0.n == $1.n }
            && a.seen == b.seen
            && sameLines(a.head, b.head)
            && sameLines(a.tail, b.tail)
    }
}
