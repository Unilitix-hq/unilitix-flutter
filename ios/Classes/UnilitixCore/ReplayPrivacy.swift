// VENDORED from UnilitixCore 0.6.0 (ReplayPrivacy.swift) by scripts/sync-ios-core.sh.
// Do not edit here; change UnilitixCore and re-run the script.

#if canImport(UIKit) && os(iOS)
import UIKit
import ObjectiveC
#if canImport(SwiftUI)
import SwiftUI
#endif

private var unilitixUnmaskedKey: UInt8 = 0
private var unilitixPrivateKey: UInt8 = 0

extension UIView {
    /// Shows this view and its subviews in session replay (screenshots and
    /// view-tree snapshots) even when `maskAllText` or `maskImages` is on. Use it for content with no
    /// personal data that is needed to understand the screen: headings,
    /// button labels, navigation, static copy.
    ///
    /// It never overrides `unilitixPrivate` or `maskInputs`: a text field
    /// inside an unmasked view is still masked.
    ///
    /// ```swift
    /// titleLabel.unilitixUnmasked = true
    /// hostingController.view.unilitixUnmasked = true  // show SwiftUI content
    /// ```
    @objc public var unilitixUnmasked: Bool {
        get { (objc_getAssociatedObject(self, &unilitixUnmaskedKey) as? NSNumber)?.boolValue ?? false }
        set {
            objc_setAssociatedObject(self, &unilitixUnmaskedKey, NSNumber(value: newValue),
                                     .OBJC_ASSOCIATION_RETAIN_NONATOMIC)
        }
    }

    /// Always blacks out this view (and everything inside it) in session
    /// replay screenshots, whatever the masking options say: balances, QR
    /// codes, documents, avatars. In view-tree snapshots it is a `masked`
    /// node with no text and no subviews.
    @objc public var unilitixPrivate: Bool {
        get { (objc_getAssociatedObject(self, &unilitixPrivateKey) as? NSNumber)?.boolValue ?? false }
        set {
            objc_setAssociatedObject(self, &unilitixPrivateKey, NSNumber(value: newValue),
                                     .OBJC_ASSOCIATION_RETAIN_NONATOMIC)
        }
    }
}

#if canImport(SwiftUI)
extension View {
    /// Blacks out this view in session replay screenshots, like
    /// `UIView.unilitixPrivate`. Implemented as a transparent UIKit overlay
    /// that covers the view's frame, so it works inside SwiftUI screens that
    /// are otherwise shown with `unilitixUnmasked`.
    public func unilitixPrivate() -> some View {
        overlay(UnilitixPrivateMarker().allowsHitTesting(false))
    }
}

/// A transparent, non-interactive UIKit view flagged `unilitixPrivate`.
private struct UnilitixPrivateMarker: UIViewRepresentable {
    func makeUIView(context: Context) -> UIView {
        let view = UIView()
        view.backgroundColor = .clear
        view.isUserInteractionEnabled = false
        view.isAccessibilityElement = false
        view.unilitixPrivate = true
        return view
    }

    func updateUIView(_ uiView: UIView, context: Context) {}
}
#endif
#endif
