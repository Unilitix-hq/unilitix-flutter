// VENDORED from UnilitixCore 0.4.1 (AutoCapture.swift) by scripts/sync-ios-core.sh.
// Do not edit here; change UnilitixCore and re-run the script.

#if canImport(UIKit) && os(iOS)
import UIKit
import ObjectiveC

/// Automatic screen and tap capture for UIKit (and SwiftUI, whose screens are
/// hosted in UIKit controllers). Installs two method swizzles, once per
/// process, then forwards to the engine:
///
/// - `UIViewController.viewDidAppear(_:)`: a screen view for every top-level
///   controller (pushed, presented or a tab), named after its type.
/// - `UIWindow.sendEvent(_:)`: a tap for every short touch, at its position in
///   points. Touches in the keyboard and other system windows are ignored, so
///   nothing typed can be reconstructed from tap positions.
///
/// With session replay on, both also mark the screen as changed so the next
/// screenshot is taken (`ScreenshotCapture`); with view-tree snapshots on,
/// an appearing view controller asks for the next snapshot
/// (`SnapshotCapture`).
@MainActor
enum AutoCapture {
    private static weak var engine: Engine?
    private static var screens = false
    private static var taps = false
    private static var replay = false
    private static var snapshots = false
    private static var installedScreens = false
    private static var installedTaps = false
    /// Where each touch began, to tell a tap from a drag.
    private static var touchStarts: [ObjectIdentifier: CGPoint] = [:]
    private static let maxTapMovement: CGFloat = 10

    /// Call on the main thread.
    static func install(_ e: Engine, screens: Bool, taps: Bool, replay: Bool = false, snapshots: Bool = false) {
        engine = e
        self.screens = screens
        self.taps = taps
        self.replay = replay
        self.snapshots = snapshots
        if (screens || replay || snapshots) && !installedScreens {
            installedScreens = true
            swizzle(UIViewController.self,
                    #selector(UIViewController.viewDidAppear(_:)),
                    #selector(UIViewController.unilitix_viewDidAppear(_:)))
        }
        if (taps || replay) && !installedTaps {
            installedTaps = true
            swizzle(UIWindow.self,
                    #selector(UIWindow.sendEvent(_:)),
                    #selector(UIWindow.unilitix_sendEvent(_:)))
        }
    }

    fileprivate static func viewDidAppear(_ vc: UIViewController) {
        if replay { ScreenshotCapture.markDirty() }
        if snapshots { SnapshotCapture.markNavigation() }
        guard screens, let e = engine, isScreen(vc),
              let name = ScreenName.from(typeName: String(describing: type(of: vc))) else { return }
        e.queue.async { e.screenView(name, automatic: true) }
    }

    /// Top-level content: no parent, or a direct child of a container.
    private static func isScreen(_ vc: UIViewController) -> Bool {
        guard let parent = vc.parent else { return true }
        return parent is UINavigationController || parent is UITabBarController
            || parent is UIPageViewController || parent is UISplitViewController
    }

    fileprivate static func sendEvent(_ event: UIEvent, in window: UIWindow) {
        guard event.type == .touches, let touches = event.allTouches, !isSystemWindow(window) else { return }
        if replay { ScreenshotCapture.markDirty() }  // taps and scrolls change the screen
        guard taps, let e = engine else { return }
        for touch in touches {
            let id = ObjectIdentifier(touch)
            switch touch.phase {
            case .began:
                touchStarts[id] = touch.location(in: window)
            case .ended:
                let end = touch.location(in: window)
                defer { touchStarts[id] = nil }
                guard let start = touchStarts[id],
                      abs(end.x - start.x) <= maxTapMovement, abs(end.y - start.y) <= maxTapMovement else { continue }
                let view = describe(touch.view)
                let x = Double(end.x), y = Double(end.y)
                e.queue.async { e.recordTap(x: x, y: y, view: view) }
            case .cancelled:
                touchStarts[id] = nil
            default:
                break
            }
        }
    }

    /// The keyboard and other system windows.
    static func isSystemWindow(_ window: UIWindow) -> Bool {
        let name = NSStringFromClass(type(of: window))
        return name.contains("Keyboard") || name.contains("TextEffects") || name.contains("RemoteInput")
    }

    /// "UIButton#payButton": the view's class and accessibility identifier,
    /// never its text.
    private static func describe(_ view: UIView?) -> String {
        guard let view = view else { return "" }
        let cls = String(describing: type(of: view))
        if let id = view.accessibilityIdentifier, !id.isEmpty { return "\(cls)#\(id)" }
        return cls
    }

    private static func swizzle(_ cls: AnyClass, _ original: Selector, _ replacement: Selector) {
        guard let o = class_getInstanceMethod(cls, original),
              let r = class_getInstanceMethod(cls, replacement) else { return }
        if class_addMethod(cls, original, method_getImplementation(r), method_getTypeEncoding(r)) {
            class_replaceMethod(cls, replacement, method_getImplementation(o), method_getTypeEncoding(o))
        } else {
            method_exchangeImplementations(o, r)
        }
    }
}

extension UIViewController {
    @objc fileprivate func unilitix_viewDidAppear(_ animated: Bool) {
        unilitix_viewDidAppear(animated)  // the original, after the swizzle
        AutoCapture.viewDidAppear(self)
    }
}

extension UIWindow {
    @objc fileprivate func unilitix_sendEvent(_ event: UIEvent) {
        unilitix_sendEvent(event)  // the original, after the swizzle
        AutoCapture.sendEvent(event, in: self)
    }
}
#endif
