// VENDORED from UnilitixCore 0.7.0 (RageTapDetector.swift) by scripts/sync-ios-core.sh.
// Do not edit here; change UnilitixCore and re-run the script.

import Foundation

/// Detects rage taps: `SdkContract.rageTapMinTaps` taps within
/// `rageTapWindowMs` and `rageTapRadius` points (per axis) of each other on
/// one screen. Same algorithm as the Android and Flutter SDKs. Not thread-safe;
/// the engine calls it on its queue.
final class RageTapDetector {
    struct Hit: Equatable {
        let x: Double
        let y: Double
        let taps: Int
    }

    private struct Tap {
        let x: Double
        let y: Double
        let screen: String
        let at: TimeInterval
    }

    private let window = TimeInterval(SdkContract.rageTapWindowMs) / 1000
    private let radius = Double(SdkContract.rageTapRadius)
    private let minTaps = SdkContract.rageTapMinTaps
    private var recent: [Tap] = []

    /// Records a tap; returns the cluster's centre when it completes a rage tap.
    func record(x: Double, y: Double, screen: String, at time: TimeInterval) -> Hit? {
        recent.removeAll { time - $0.at > window }
        recent.append(Tap(x: x, y: y, screen: screen, at: time))
        let cluster = recent.filter { $0.screen == screen && abs($0.x - x) <= radius && abs($0.y - y) <= radius }
        guard cluster.count >= minTaps else { return nil }
        recent.removeAll { t in cluster.contains { $0.at == t.at && $0.x == t.x && $0.y == t.y } }
        let cx = cluster.map { $0.x }.reduce(0, +) / Double(cluster.count)
        let cy = cluster.map { $0.y }.reduce(0, +) / Double(cluster.count)
        return Hit(x: cx, y: cy, taps: cluster.count)
    }
}

/// Turns a view controller's type name into the screen name the dashboard
/// shows, or nil for system and container controllers that are not screens.
enum ScreenName {
    private static let ignoredPrefixes = [
        "UINavigationController", "UITabBarController", "UIPageViewController",
        "UISplitViewController", "UIInputWindowController", "UIAlertController",
        "UIEditingOverlayViewController", "UICompatibilityInputViewController",
        "UISystemKeyboardDockController", "UIPredictionViewController",
        "SFSafariViewController", "_",
    ]
    private static let swiftUIWrappers = ["UIHostingController<", "ModifiedContent<", "Optional<", "AnyView"]
    private static let identifier = Pattern(#"[A-Za-z_][A-Za-z0-9_]*"#)

    static func from(typeName raw: String) -> String? {
        // Drop the module prefix: "Shop.CheckoutViewController" -> "CheckoutViewController".
        var name = raw
        if !name.contains("<"), let dot = name.lastIndex(of: ".") {
            name = String(name[name.index(after: dot)...])
        }
        if ignoredPrefixes.contains(where: { name.hasPrefix($0) }) { return nil }
        if name.hasPrefix("UIHostingController<") {
            var inner = name
            var changed = true
            while changed {
                changed = false
                for w in swiftUIWrappers where inner.hasPrefix(w) {
                    inner = String(inner.dropFirst(w.count))
                    changed = true
                }
            }
            // "Shop.CartView>" -> "CartView"
            let parts = inner.split(whereSeparator: { "<>, ".contains($0) }).first.map(String.init) ?? ""
            let last = parts.split(separator: ".").last.map(String.init) ?? ""
            return identifier.firstMatch(last)?[0] ?? nil
        }
        if name.hasPrefix("UI") { return nil }  // other UIKit-provided controllers
        return name.isEmpty ? nil : name
    }
}
