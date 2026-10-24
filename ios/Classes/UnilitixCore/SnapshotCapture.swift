// VENDORED from UnilitixCore 0.7.0 (SnapshotCapture.swift) by scripts/sync-ios-core.sh.
// Do not edit here; change UnilitixCore and re-run the script.

#if canImport(UIKit) && os(iOS)
import UIKit

/// View-tree snapshots for UIKit (and SwiftUI and React Native, which render
/// into UIKit windows).
///
/// A main-run-loop timer ticks four times a second. While the app is active
/// and `Engine.snapshotGate()` is open, the key window's view tree is walked
/// once per `snapshotIntervalMs` (clamped to 1–60 s), and as soon as the
/// interval allows after a navigation (a new screen name, an appearing view
/// controller, a return to the foreground). `SnapshotScheduler` decides; a
/// tree identical to the last one taken in the session is dropped.
///
/// The walk (`SnapshotBuilder` over `UIKitSnapshotNode`) runs on the main
/// thread, as UIKit requires, and masks text as it goes, so the tree never
/// holds text a screenshot would mask. It is capped at
/// `SnapshotBuilder.maxNodes` nodes and `maxDepth` levels. Encoding and
/// storage happen on the engine queue.
@MainActor
enum SnapshotCapture {
    private static weak var engine: Engine?
    private static var scheduler = SnapshotScheduler(intervalMs: 1000)
    private static var rules = MaskRules()
    private static var ticker: ReplayTicker?
    private static var lastScreen: String?
    private static var wasActive = false

    /// Call on the main thread, once `AutoCapture` is installed with `snapshots: true`.
    static func install(_ e: Engine, config: UnilitixConfig) {
        engine = e
        scheduler = SnapshotScheduler(intervalMs: config.snapshotIntervalMs)
        rules = MaskRules.forSnapshots(config)
        if ticker == nil {
            let t = ReplayTicker { SnapshotCapture.tick() }
            t.start(interval: ScreenshotCapture.tickInterval)
            ticker = t
        }
    }

    /// A view controller appeared: walk as soon as the interval allows.
    static func markNavigation() {
        scheduler.markNavigation()
    }

    fileprivate static func tick() {
        guard let e = engine else { return }
        let active = UIApplication.shared.applicationState == .active
        defer { wasActive = active }
        guard active else { return }
        if !wasActive { scheduler.markNavigation() }  // back from the background
        guard let gate = e.snapshotGate() else { return }
        if gate.screen != lastScreen {
            lastScreen = gate.screen
            scheduler.markNavigation()
        }
        let now = ProcessInfo.processInfo.systemUptime
        guard scheduler.shouldWalk(at: now, sessionId: gate.sessionId) else { return }
        guard let window = ScreenshotCapture.captureWindow() else { return }
        let viewport = window.bounds
        guard viewport.width >= 1, viewport.height >= 1,
              let tree = SnapshotBuilder.build(UIKitSnapshotNode(view: window, window: window),
                                               viewport: viewport, rules: rules) else { return }
        let width = Int(viewport.width.rounded())
        let height = Int(viewport.height.rounded())
        guard scheduler.accept(tree, screen: gate.screen, viewportWidth: width, viewportHeight: height,
                               at: now) else { return }
        let sessionId = gate.sessionId
        let screen = gate.screen
        let capturedAt = Date()
        e.queue.async {
            e.addSnapshot(tree, sessionId: sessionId, screen: screen, capturedAt: capturedAt,
                          viewportWidth: width, viewportHeight: height)
        }
    }
}

/// `SnapshotViewNode` over a live `UIView`. Read on the main thread only,
/// during the walk; properties are computed on demand so text is read only
/// for text and input views.
@MainActor
struct UIKitSnapshotNode: SnapshotViewNode {
    let view: UIView
    let window: UIWindow

    var typeName: String {
        let name = String(describing: type(of: view))
        // Generic classes ("_UIHostingView<ModifiedContent<…>>") keep their base name.
        if let i = name.firstIndex(of: "<") { return String(name[..<i]) }
        return name
    }

    var kind: ReplayNodeKind { ScreenMasker.classify(view) }

    var isVisible: Bool { !view.isHidden && view.alpha >= 0.01 }

    var frame: CGRect { view.convert(view.bounds, to: window) }

    var clipsToBounds: Bool { view.clipsToBounds }

    var isPrivate: Bool { view.unilitixPrivate }

    var isUnmasked: Bool { view.unilitixUnmasked }

    var text: String? {
        switch view {
        case let field as UITextField: return field.text
        case let textView as UITextView: return textView.text
        case let label as UILabel: return label.text
        default: return nil  // React Native text: not readable here; no text is sent
        }
    }

    var textColor: String? {
        switch view {
        case let field as UITextField: return UIKitSnapshotNode.hex(field.textColor, view.traitCollection)
        case let textView as UITextView: return UIKitSnapshotNode.hex(textView.textColor, view.traitCollection)
        case let label as UILabel: return UIKitSnapshotNode.hex(label.textColor, view.traitCollection)
        default: return nil
        }
    }

    var backgroundColor: String? { UIKitSnapshotNode.hex(view.backgroundColor, view.traitCollection) }

    var isInteractive: Bool {
        guard view.isUserInteractionEnabled else { return false }
        if let control = view as? UIControl { return control.isEnabled }
        return view.gestureRecognizers?.contains { $0 is UITapGestureRecognizer && $0.isEnabled } ?? false
    }

    var children: [any SnapshotViewNode] {
        view.subviews.map { UIKitSnapshotNode(view: $0, window: window) }
    }

    /// "#RRGGBB" for a colour that is at least slightly opaque; dynamic
    /// colours are resolved for the view's appearance.
    static func hex(_ color: UIColor?, _ traits: UITraitCollection) -> String? {
        guard let resolved = color?.resolvedColor(with: traits) else { return nil }
        var r: CGFloat = 0, g: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
        guard resolved.getRed(&r, green: &g, blue: &b, alpha: &a), a >= 0.05 else { return nil }
        func byte(_ v: CGFloat) -> Int { Int((min(max(v, 0), 1) * 255).rounded()) }
        return String(format: "#%02X%02X%02X", byte(r), byte(g), byte(b))
    }
}
#endif
