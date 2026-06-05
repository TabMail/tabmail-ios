/* This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at https://mozilla.org/MPL/2.0/. */

import UIKit

/// On-screen touch visualizer for recording demo videos.
///
/// Draws a translucent ring at every active touch point so taps and drags are
/// visible in a screen recording (essential when recording on a physical device,
/// where there's no cursor). Toggled from Settings → Debug → "Show Touch Rings";
/// the choice is persisted so it survives a relaunch during a recording session.
///
/// Intentionally NOT `#if DEBUG`-gated, so it ships in TestFlight/Release builds
/// too (demos are recorded from those). It's still only reachable behind the
/// hidden debug menu (10-tap unlock + allow-listed user via `DebugModeManager`),
/// and the swizzle is installed lazily only when the toggle is switched on — so
/// it is completely inert for normal users.
///
/// Implementation: a one-time swizzle of `UIWindow.sendEvent(_:)` (installed
/// lazily the first time rings are enabled) forwards every touch event here.
/// `UIWindow.sendEvent` is the single chokepoint every touch flows through, so
/// rings appear regardless of which view (button, scroll view, keyboard, etc.)
/// actually handles the touch. The ring views are `isUserInteractionEnabled =
/// false`, so they never intercept input.
@MainActor
final class TouchVisualizer {
    static let shared = TouchVisualizer()

    private static let enabledKey = "debug_touch_rings_enabled"

    /// Live touch → ring map, keyed by the `UITouch`'s object identity.
    private var rings: [ObjectIdentifier: TouchRingView] = [:]

    /// `sendEvent` is swizzled at most once per process; the swizzled body
    /// no-ops cheaply while `isEnabled` is false, so we never need to un-swizzle.
    private var didInstallSwizzle = false

    /// Whether rings are currently drawn. Persisted across launches.
    private(set) var isEnabled: Bool

    private init() {
        isEnabled = UserDefaults.standard.bool(forKey: Self.enabledKey)
        if isEnabled { installSwizzleIfNeeded() }
    }

    /// Called once at launch so a left-on toggle re-activates without the user
    /// having to open the debug menu. Referencing `.shared` runs `init`, which
    /// installs the swizzle when the persisted flag is set.
    func activateIfEnabled() {
        if isEnabled { installSwizzleIfNeeded() }
    }

    func setEnabled(_ enabled: Bool) {
        isEnabled = enabled
        UserDefaults.standard.set(enabled, forKey: Self.enabledKey)
        if enabled {
            installSwizzleIfNeeded()
        } else {
            for ring in rings.values { ring.removeFromSuperview() }
            rings.removeAll()
        }
    }

    private func installSwizzleIfNeeded() {
        guard !didInstallSwizzle else { return }
        didInstallSwizzle = true
        UIWindow.tm_installTouchVisualizerSwizzle()
    }

    /// Invoked from the swizzled `sendEvent` for every event delivered to a
    /// window. Cheap no-op when disabled or for non-touch events.
    fileprivate func handle(_ event: UIEvent, in window: UIWindow) {
        guard isEnabled, event.type == .touches, let touches = event.allTouches else { return }
        // Only handle touches that belong to this window — `allTouches` spans
        // every window (keyboard, alerts), and we draw in the touch's own window
        // so the coordinates and z-order are correct.
        for touch in touches where touch.window == window {
            let key = ObjectIdentifier(touch)
            let location = touch.location(in: window)
            switch touch.phase {
            case .began:
                let ring = TouchRingView()
                ring.center = location
                window.addSubview(ring)
                rings[key] = ring
                ring.animateIn()
            case .moved, .stationary:
                rings[key]?.center = location
            case .ended, .cancelled:
                if let ring = rings.removeValue(forKey: key) {
                    ring.animateOutAndRemove()
                }
            case .regionEntered, .regionMoved, .regionExited:
                break  // hover phases (no screen contact) — nothing to draw
            @unknown default:
                break
            }
        }
    }
}

/// A single translucent ring that follows one touch. Non-interactive overlay.
private final class TouchRingView: UIView {
    private static let diameter: CGFloat = 46

    init() {
        super.init(frame: CGRect(x: 0, y: 0, width: Self.diameter, height: Self.diameter))
        isUserInteractionEnabled = false
        layer.cornerRadius = Self.diameter / 2
        layer.borderWidth = 2
        layer.borderColor = UIColor.white.withAlphaComponent(0.9).cgColor
        backgroundColor = UIColor(white: 0.2, alpha: 0.35)
        // Subtle shadow so the ring reads on both light and dark backgrounds.
        layer.shadowColor = UIColor.black.cgColor
        layer.shadowOpacity = 0.35
        layer.shadowRadius = 3
        layer.shadowOffset = .zero
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    func animateIn() {
        transform = CGAffineTransform(scaleX: 0.5, y: 0.5)
        alpha = 0
        UIView.animate(withDuration: 0.12) {
            self.transform = .identity
            self.alpha = 1
        }
    }

    func animateOutAndRemove() {
        UIView.animate(withDuration: 0.2) {
            self.alpha = 0
            self.transform = CGAffineTransform(scaleX: 1.4, y: 1.4)
        } completion: { _ in
            self.removeFromSuperview()
        }
    }
}

private extension UIWindow {
    /// Exchanges `sendEvent(_:)` with `tm_sendEvent(_:)`. Idempotency is the
    /// caller's responsibility (`TouchVisualizer.didInstallSwizzle`).
    static func tm_installTouchVisualizerSwizzle() {
        guard
            let original = class_getInstanceMethod(UIWindow.self, #selector(UIWindow.sendEvent(_:))),
            let replacement = class_getInstanceMethod(UIWindow.self, #selector(UIWindow.tm_sendEvent(_:)))
        else { return }
        method_exchangeImplementations(original, replacement)
    }

    /// Swizzled stand-in for `sendEvent`. After the exchange, calling
    /// `tm_sendEvent` here invokes the ORIGINAL `sendEvent` implementation.
    /// `sendEvent` is always delivered on the main thread, so the `@MainActor`
    /// `TouchVisualizer` call is in-isolation.
    @objc func tm_sendEvent(_ event: UIEvent) {
        tm_sendEvent(event)  // original implementation (post-exchange)
        TouchVisualizer.shared.handle(event, in: self)
    }
}
