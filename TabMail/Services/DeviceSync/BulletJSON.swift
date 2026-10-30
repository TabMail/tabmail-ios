/* This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at https://mozilla.org/MPL/2.0/. */

import Foundation

/// The `bullet_state` wire as the other apps write and read it. A message is written exactly as
/// JavaScript's `JSON.stringify` writes it, so a message's size, and with it where the parts of a large
/// field are cut (DS-CHUNK), is the same on every device. Values read come from `JSONSerialization`.
enum BulletJSON {
    /// The largest integer a JavaScript number holds exactly (`Number.MAX_SAFE_INTEGER`).
    static let maxSafeInteger = 9_007_199_254_740_991

    /// `text` as a JSON string, escaped as `JSON.stringify` escapes it.
    static func string(_ text: String) -> String {
        var out = "\""
        for scalar in text.unicodeScalars {
            switch scalar {
            case "\"": out += "\\\""
            case "\\": out += "\\\\"
            case "\u{08}": out += "\\b"
            case "\u{0C}": out += "\\f"
            case "\n": out += "\\n"
            case "\r": out += "\\r"
            case "\t": out += "\\t"
            default:
                if scalar.value < 0x20 {
                    out += "\\u" + String(format: "%04x", scalar.value)
                } else {
                    out.unicodeScalars.append(scalar)
                }
            }
        }
        return out + "\""
    }

    static func tuple(_ bullet: Bullet) -> String {
        "[\(string(bullet.section)),\(string(bullet.text)),\(string(bullet.name)),\(bullet.n)]"
    }

    static func tuples(_ bullets: [Bullet]) -> String {
        "[" + bullets.map(tuple).joined(separator: ",") + "]"
    }

    /// A `bullet_state` message: its keys in the order the other apps write them.
    static func message(field: BulletField, sender: String, snap: String, part: Int, parts: Int, bullets: [Bullet], seen: [(name: String, n: Int)]) -> String {
        let seenText = "{" + seen.map { "\(string($0.name)):\($0.n)" }.joined(separator: ",") + "}"
        return "{\"type\":\"bullet_state\",\"v\":1,\"field\":\(string(field.rawValue)),\"sender\":\(string(sender)),\"snap\":\(string(snap)),\"part\":\(part),\"parts\":\(parts),\"bullets\":\(tuples(bullets)),\"seen\":\(seenText)}"
    }

    static func byteLength(_ text: String) -> Int {
        text.utf8.count
    }

    /// A JSON number that is a whole number a JavaScript number holds exactly
    /// (`Number.isSafeInteger`), at least `least`; never a JSON true or false.
    static func count(_ value: Any?, least: Int) -> Int? {
        guard let number = value as? NSNumber, CFGetTypeID(number) != CFBooleanGetTypeID() else { return nil }
        let double = number.doubleValue
        guard double.isFinite, double.rounded() == double, abs(double) <= Double(maxSafeInteger) else { return nil }
        let int = number.int64Value
        guard abs(int) <= Int64(maxSafeInteger), Double(int) == double, int >= Int64(least) else { return nil }
        return Int(int)
    }

    /// Whether `value` is the JSON number 1 (the wire version).
    static func isOne(_ value: Any?) -> Bool {
        count(value, least: 1) == 1
    }
}
