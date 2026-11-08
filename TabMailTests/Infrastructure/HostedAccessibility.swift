/* This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at https://mozilla.org/MPL/2.0/. */

import Darwin
import UIKit

/// Reads and presses a hosted SwiftUI view from a unit test, the way VoiceOver does.
///
/// SwiftUI gives a hosted view accessibility elements only while an accessibility client runs:
/// without one the hosting view has none, and a button cannot be reached. `withAutomation` turns
/// accessibility automation on for the test, as in-process UI test drivers do (libAccessibility's
/// `_AXSSetAutomationEnabled`; test code only), and puts the previous setting back after, because
/// the simulator keeps it across launches.
@MainActor
enum HostedAccessibility {
    private typealias Get = @convention(c) () -> Int32
    private typealias Set = @convention(c) (Int32) -> Void

    private static let library = dlopen("/usr/lib/libAccessibility.dylib", RTLD_NOW)

    private static func function<T>(_ name: String, as type: T.Type) -> T? {
        guard let library, let symbol = dlsym(library, name) else { return nil }
        return unsafeBitCast(symbol, to: type)
    }

    /// The automation switch and the application accessibility switch it turns on with it.
    private static let switches: [(get: Get, set: Set)] = [
        ("_AXSAutomationEnabled", "_AXSSetAutomationEnabled"),
        ("_AXSApplicationAccessibilityEnabled", "_AXSApplicationAccessibilitySetEnabled"),
    ].compactMap { names in
        guard let get = function(names.0, as: Get.self), let set = function(names.1, as: Set.self) else { return nil }
        return (get, set)
    }

    /// Whether automation can be turned on here; a test checks it as its first control.
    static var isAvailable: Bool { switches.count == 2 }

    /// Runs `body` with accessibility automation on, then restores both switches.
    static func withAutomation<T>(_ body: () async throws -> T) async rethrows -> T {
        let before = switches.map { $0.get() }
        if let automation = switches.first { automation.set(1) }
        defer { for (index, entry) in switches.enumerated() { entry.set(before[index]) } }
        return try await body()
    }

    /// Every accessibility element and view under `root`, depth first.
    static func elements(under root: NSObject) -> [NSObject] {
        var found: [NSObject] = []
        var seen = Swift.Set<ObjectIdentifier>()
        func walk(_ element: NSObject, depth: Int) {
            guard depth < 60, seen.insert(ObjectIdentifier(element)).inserted else { return }
            found.append(element)
            var children = (element.accessibilityElements as? [NSObject]) ?? []
            let count = element.accessibilityElementCount()
            if children.isEmpty, count != NSNotFound, count > 0 {
                children = (0..<count).compactMap { element.accessibilityElement(at: $0) as? NSObject }
            }
            if let view = element as? UIView { children += view.subviews }
            for child in children { walk(child, depth: depth + 1) }
        }
        walk(root, depth: 0)
        return found
    }

    /// The accessibility labels under `view`.
    static func labels(in view: UIView) -> [String] {
        elements(under: view).compactMap { $0.accessibilityLabel }.filter { !$0.isEmpty }
    }

    /// An element's identifier. SwiftUI's elements answer `accessibilityIdentifier` without
    /// declaring `UIAccessibilityIdentification`, so a protocol cast misses them: ask by selector.
    static func identifier(of element: NSObject) -> String? {
        let getter = #selector(getter: UIAccessibilityIdentification.accessibilityIdentifier)
        guard element.responds(to: getter) else { return nil }
        return element.perform(getter)?.takeUnretainedValue() as? String
    }

    /// The identifiers under `view`, for a failure message.
    static func identifiers(in view: UIView) -> [String] {
        elements(under: view).compactMap { identifier(of: $0) }.filter { !$0.isEmpty }
    }

    /// Activates the element `identifier` under `view`, as a VoiceOver double tap does: a SwiftUI
    /// button runs its action. Returns whether the element was found and took the activation.
    static func activate(_ identifier: String, in view: UIView) -> Bool {
        guard let element = elements(under: view).first(where: { Self.identifier(of: $0) == identifier })
        else { return false }
        return element.accessibilityActivate()
    }
}
