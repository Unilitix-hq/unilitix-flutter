// VENDORED from UnilitixCore 0.7.0 (ScreenshotCapture.swift) by scripts/sync-ios-core.sh.
// Do not edit here; change UnilitixCore and re-run the script.

#if canImport(UIKit) && os(iOS)
import UIKit

/// Session replay capture for UIKit, and for SwiftUI and React Native, which
/// render into UIKit windows.
///
/// A main-run-loop timer checks four times a second whether a frame is
/// wanted (`ReplayScheduler`: the screen changed and `screenshotIntervalMs`
/// passed, or `screenshotHeartbeatMs` passed on a static screen, within
/// `maxScreenshotsPerMinute`). `AutoCapture` marks the screen dirty on
/// touches (taps and scrolls) and appearing view controllers; a screen
/// change from `Unilitix.screen` does too.
///
/// On the main thread, a frame is drawn with `drawHierarchy(in:
/// afterScreenUpdates: false)` at a scale that makes it at most
/// `screenshotMaxWidth` pixels wide, and the mask boxes (`ScreenMasker`) are
/// painted over it in the same drawing pass, so no unmasked image is ever
/// kept. JPEG encoding happens on a background queue; the engine then
/// stores the frame with the session's next ordinal.
@MainActor
enum ScreenshotCapture {
    private static weak var engine: Engine?
    private static var scheduler = ReplayScheduler(intervalMs: 1000, heartbeatMs: 10000, maxPerMinute: 20)
    private static var rules = MaskRules()
    private static var maxWidth: CGFloat = 480
    private static var quality: CGFloat = 0.3
    private static var ticker: ReplayTicker?
    private static var encoding = false
    private static var lastScreen: String?
    private static var wasActive = false
    private static let encodeQueue = DispatchQueue(label: "io.unilitix.replay", qos: .utility)
    static let tickInterval: TimeInterval = 0.25

    /// Call on the main thread, once `AutoCapture` is installed with `replay: true`.
    static func install(_ e: Engine, config: UnilitixConfig) {
        engine = e
        scheduler = ReplayScheduler(intervalMs: config.screenshotIntervalMs,
                                    heartbeatMs: config.screenshotHeartbeatMs,
                                    maxPerMinute: config.maxScreenshotsPerMinute)
        rules = MaskRules(config: config)
        maxWidth = CGFloat(max(16, config.screenshotMaxWidth))
        quality = CGFloat(min(max(config.screenshotQuality, 1), 100)) / 100
        if ticker == nil {
            let t = ReplayTicker { ScreenshotCapture.tick() }
            t.start(interval: tickInterval)
            ticker = t
        }
    }

    /// The screen changed: the next tick after the interval captures.
    static func markDirty() {
        scheduler.markDirty()
    }

    fileprivate static func tick() {
        guard let e = engine, !encoding else { return }
        let active = UIApplication.shared.applicationState == .active
        defer { wasActive = active }
        guard active else { return }
        if !wasActive { scheduler.markDirty() }  // back from the background
        guard let gate = e.replayGate() else { return }
        if gate.screen != lastScreen {
            lastScreen = gate.screen
            scheduler.markDirty()
        }
        guard scheduler.shouldCapture(at: ProcessInfo.processInfo.systemUptime, sessionId: gate.sessionId) else {
            return
        }
        capture(e, gate)
    }

    private static func capture(_ e: Engine, _ gate: ReplayGate) {
        guard let window = captureWindow() else { return }
        let bounds = window.bounds
        guard bounds.width >= 1, bounds.height >= 1 else { return }
        // Nil: a password is being typed, or masking failed. No frame.
        guard let masks = ScreenMasker.masks(in: window, rules: rules) else { return }
        guard let image = render(window, maxWidth: maxWidth, masks: masks) else { return }

        encoding = true
        let sessionId = gate.sessionId
        let screen = gate.screen
        let capturedAt = Date()
        let width = Int(bounds.width.rounded())
        let height = Int(bounds.height.rounded())
        encode(image, quality: quality) { jpeg in
            DispatchQueue.main.async { ScreenshotCapture.encoding = false }
            guard let data = jpeg else { return }
            e.queue.async {
                e.addScreenshot(data, sessionId: sessionId, screen: screen, capturedAt: capturedAt,
                                viewportWidth: width, viewportHeight: height)
            }
        }
    }

    /// Draws `window` at most `maxWidth` pixels wide (never above the
    /// screen's scale) with `masks`, in window points, painted black in the
    /// same pass, each grown by a point on every side, so no unmasked image
    /// is ever kept. Nil when the window has no size or could not be drawn.
    ///
    /// Also used by wrappers that find the masks themselves (the Flutter
    /// plugin gets them from Dart).
    static func render(_ window: UIWindow, maxWidth: CGFloat, masks: [CGRect]) -> UIImage? {
        let bounds = window.bounds
        guard bounds.width >= 1, bounds.height >= 1 else { return nil }
        let format = UIGraphicsImageRendererFormat()
        format.scale = min(window.screen.scale, maxWidth / bounds.width)
        format.opaque = true
        var drawn = false
        let image = UIGraphicsImageRenderer(bounds: bounds, format: format).image { ctx in
            drawn = window.drawHierarchy(in: bounds, afterScreenUpdates: false)
            let cg = ctx.cgContext
            cg.setFillColor(UIColor.black.cgColor)
            for r in masks {
                cg.fill(r.insetBy(dx: -1, dy: -1))
            }
        }
        return drawn ? image : nil
    }

    /// JPEG-encodes `image` at `quality` (0...1) on the replay encode queue
    /// and calls `completion` there with the bytes, or nil on failure.
    static func encode(_ image: UIImage, quality: CGFloat, completion: @escaping @Sendable (Data?) -> Void) {
        encodeQueue.async {
            completion(image.jpegData(compressionQuality: quality))
        }
    }

    /// The app's key window in a foreground scene. Nil while the key window
    /// is a system window (keyboard, text effects): such frames are skipped.
    /// Also used by `SnapshotCapture`.
    static func captureWindow() -> UIWindow? {
        let windows = UIApplication.shared.connectedScenes
            .compactMap { $0 as? UIWindowScene }
            .filter { $0.activationState == .foregroundActive }
            .flatMap { $0.windows }
        if let key = windows.first(where: { $0.isKeyWindow }) {
            return AutoCapture.isSystemWindow(key) ? nil : key
        }
        return windows.first { !$0.isHidden && $0.windowLevel == .normal && !AutoCapture.isSystemWindow($0) }
    }
}

/// Fires a replay capturer's tick on the main run loop, also while scrolling.
@MainActor
final class ReplayTicker: NSObject {
    private var timer: Timer?
    private let onFire: @MainActor () -> Void

    init(_ onFire: @escaping @MainActor () -> Void) {
        self.onFire = onFire
        super.init()
    }

    func start(interval: TimeInterval) {
        let t = Timer(timeInterval: interval, target: self, selector: #selector(fire), userInfo: nil, repeats: true)
        t.tolerance = interval / 2
        RunLoop.main.add(t, forMode: .common)
        timer = t
    }

    @objc private func fire() {
        onFire()
    }
}

/// Finds the regions to black out, in window coordinates, by walking the
/// window's view tree at capture time:
///
/// - views marked `unilitixPrivate`: always;
/// - text inputs (`UITextField`, editable `UITextView`, secure entry,
///   React Native's inputs, which subclass them): with `maskInputs`, also
///   inside `unilitixUnmasked` views;
/// - text (`UILabel` and so button titles, read-only `UITextView`, React
///   Native text views): with `maskAllText`, unless inside `unilitixUnmasked`;
/// - web views: with `maskAllText` or `maskInputs` (their text and inputs
///   cannot be found), unless marked `unilitixUnmasked`;
/// - SwiftUI-hosted content: SwiftUI draws text without UIKit views, so with
///   `maskAllText` the whole hosting view is masked unless it (or an
///   ancestor) is `unilitixUnmasked`; inside an unmasked hosting view,
///   UIKit-backed inputs (`TextField`, `SecureField`) are still masked and
///   `.unilitixPrivate()` regions are honoured;
/// - images (`UIImageView`): with `maskImages`, unless inside `unilitixUnmasked`.
///
/// Hidden and fully transparent views are skipped with their subviews: they
/// are not drawn. Returns nil, so no frame is taken, while a secure text
/// field is being edited.
///
/// The rules themselves are `ReplayMasking.masksInScreenshot`, shared with
/// view-tree snapshots; `classify` is shared too.
@MainActor
enum ScreenMasker {
    static func masks(in window: UIWindow, rules: MaskRules) -> [CGRect]? {
        var out: [CGRect] = []
        guard visit(window, window: window, unmasked: false, rules: rules, into: &out) else { return nil }
        return out
    }

    /// False: abort the frame.
    private static func visit(_ view: UIView, window: UIWindow, unmasked inherited: Bool,
                              rules: MaskRules, into out: inout [CGRect]) -> Bool {
        if view.isHidden || view.alpha < 0.01 { return true }
        let unmasked = inherited || view.unilitixUnmasked
        let kind = classify(view)
        if kind == .secureInput && view.isFirstResponder { return false }
        if ReplayMasking.masksInScreenshot(kind: kind, isPrivate: view.unilitixPrivate,
                                           unmasked: unmasked, rules: rules) {
            add(view, window, &out)
            return true
        }
        for sub in view.subviews {
            if !visit(sub, window: window, unmasked: unmasked, rules: rules, into: &out) { return false }
        }
        return true
    }

    /// What `view` is for masking. Also used by `SnapshotCapture`.
    static func classify(_ view: UIView) -> ReplayNodeKind {
        if let field = view as? UITextField {
            return field.isSecureTextEntry ? .secureInput : .input
        }
        if let textView = view as? UITextView {
            if textView.isSecureTextEntry { return .secureInput }
            return textView.isEditable ? .input : .text
        }
        if view is UILabel { return .text }
        if view is UIImageView { return .image }
        let name = NSStringFromClass(type(of: view))
        if name.contains("WKWebView") { return .web }
        if name.contains("HostingView") || name.contains("HostingContentView") { return .swiftUIHost }
        // React Native text: RCTTextView (Paper), RCTParagraphComponentView (Fabric).
        if name.hasPrefix("RCTText") || name.hasPrefix("RCTParagraph") { return .text }
        return .other
    }

    private static func add(_ view: UIView, _ window: UIWindow, _ out: inout [CGRect]) {
        let r = view.convert(view.bounds, to: window)
        if !r.isNull, !r.isInfinite, r.width > 0, r.height > 0 { out.append(r) }
    }
}
#endif
