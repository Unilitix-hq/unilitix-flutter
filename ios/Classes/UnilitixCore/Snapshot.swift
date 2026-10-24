// VENDORED from UnilitixCore 0.7.0 (Snapshot.swift) by scripts/sync-ios-core.sh.
// Do not edit here; change UnilitixCore and re-run the script.

import Foundation
#if canImport(CoreGraphics)
import CoreGraphics
#endif

// View-tree snapshots: the wire format, the masking tree walk and the
// capture schedule. Pure logic, unit-tested on macOS; the UIKit side is in
// SnapshotCapture.swift.

/// A view's frame in window coordinates, in points (the unit of
/// `viewportWidth`/`viewportHeight`, tap positions and screenshots).
/// `bounds` in the Android SDK's hierarchy JSON.
struct SnapshotBounds: Codable, Equatable {
    var x: Int
    var y: Int
    var w: Int
    var h: Int
}

/// One node of a snapshot's `hierarchy`. The API stores the hierarchy as raw
/// JSON (`SnapshotPayload.Hierarchy` is `json.RawMessage`); the field names
/// are the ones the Android SDK sends and the dashboard's `ReplayFrame`
/// renders. Nil fields are left out of the JSON.
struct SnapshotNode: Codable, Equatable {
    /// The view's class name without its module ("UILabel", "CheckoutButton").
    var type: String
    var bounds: SnapshotBounds
    /// Masked per `ReplayMasking.snapshotText`: `[MASKED]`, redacted
    /// (`•` per character) or, only where a screenshot would show it, as is.
    var text: String?
    /// The text's characters were replaced (`maskAllText`).
    var redacted: Bool?
    /// "#RRGGBB".
    var textColor: String?
    /// "#RRGGBB"; only for opaque-enough backgrounds.
    var bgColor: String?
    /// Inputs only: secure entry.
    var isPassword: Bool?
    /// Inputs only: "edit".
    var inputType: String?
    var interactive: Bool?
    var isImage: Bool?
    /// The view's content is withheld: a private view, an image with
    /// `maskImages`, a web view or SwiftUI-hosted content under text masking.
    var masked: Bool?
    var children: [SnapshotNode]?

    init(type: String, bounds: SnapshotBounds) {
        self.type = type
        self.bounds = bounds
    }

    /// Nodes in this tree, this one included.
    var nodeCount: Int {
        1 + (children ?? []).reduce(0) { $0 + $1.nodeCount }
    }
}

/// What the snapshot walk needs to know about one view. `UIKitSnapshotNode`
/// adapts `UIView` on the main thread; tests build trees of plain values.
/// Like Android's `MaskableNode`. Main-actor isolated because UIKit is.
@MainActor
protocol SnapshotViewNode {
    var typeName: String { get }
    var kind: ReplayNodeKind { get }
    /// False for hidden or fully transparent views: they and their subviews
    /// are not drawn.
    var isVisible: Bool { get }
    /// Frame in window coordinates, in points.
    var frame: CGRect { get }
    var clipsToBounds: Bool { get }
    /// `unilitixPrivate`.
    var isPrivate: Bool { get }
    /// `unilitixUnmasked`.
    var isUnmasked: Bool { get }
    /// The view's own text (label, field, text view). Read only when the node
    /// is a text or input kind.
    var text: String? { get }
    var textColor: String? { get }
    var backgroundColor: String? { get }
    var isInteractive: Bool { get }
    var children: [any SnapshotViewNode] { get }
}

/// Serializes a view tree into a `SnapshotNode` tree, applying the replay
/// masking rules on the way so no raw text that a screenshot would mask is
/// ever put in a node.
///
/// - Hidden, fully transparent and zero-size views are skipped with their
///   subviews. So are views entirely outside the viewport that clip their
///   subviews or have none.
/// - Inputs, text, web views and masked SwiftUI hosts are leaves: their
///   internal subviews (field editors, placeholder labels) are not visited.
/// - Private views become a `masked` node with no text and no children.
/// - At most `maxNodes` nodes and `maxDepth` levels, so a huge or deeply
///   nested screen cannot stall the main thread. (Android has no cap; UIKit
///   and SwiftUI trees are deeper.)
@MainActor
enum SnapshotBuilder {
    nonisolated static let maxNodes = 2000
    nonisolated static let maxDepth = 64

    static func build(_ root: any SnapshotViewNode, viewport: CGRect, rules: MaskRules,
                      maxNodes: Int = SnapshotBuilder.maxNodes,
                      maxDepth: Int = SnapshotBuilder.maxDepth) -> SnapshotNode? {
        var budget = max(1, maxNodes)
        return visit(root, depth: 0, unmasked: false, viewport: viewport, rules: rules,
                     maxDepth: maxDepth, budget: &budget)
    }

    private static func visit(_ view: any SnapshotViewNode, depth: Int, unmasked inherited: Bool,
                              viewport: CGRect, rules: MaskRules, maxDepth: Int,
                              budget: inout Int) -> SnapshotNode? {
        guard budget > 0, view.isVisible else { return nil }
        let f = view.frame
        guard !f.isNull, !f.isInfinite, f.width.isFinite, f.height.isFinite,
              f.width >= 0.5, f.height >= 0.5 else { return nil }
        let kids = view.children
        if !f.intersects(viewport) && (view.clipsToBounds || kids.isEmpty) { return nil }
        budget -= 1

        var node = SnapshotNode(type: view.typeName, bounds: bounds(f))
        if view.isPrivate {
            node.masked = true
            return node
        }
        let unmasked = inherited || view.isUnmasked
        let kind = view.kind
        if view.isInteractive { node.interactive = true }
        node.bgColor = view.backgroundColor

        var descend = true
        switch kind {
        case .input, .secureInput:
            let masked = ReplayMasking.snapshotText(kind == .secureInput ? "" : (view.text ?? ""),
                                                    kind: kind, unmasked: unmasked, rules: rules)
            node.text = masked.text
            if masked.redacted { node.redacted = true }
            node.textColor = view.textColor
            node.isPassword = kind == .secureInput
            node.inputType = "edit"
            node.interactive = true
            descend = false
        case .text:
            if let raw = view.text, !raw.isEmpty {
                let masked = ReplayMasking.snapshotText(raw, kind: kind, unmasked: unmasked, rules: rules)
                node.text = masked.text
                if masked.redacted { node.redacted = true }
            }
            node.textColor = view.textColor
            descend = false
        case .web:
            if ReplayMasking.masksInScreenshot(kind: kind, isPrivate: false, unmasked: unmasked, rules: rules) {
                node.masked = true
            }
            descend = false
        case .swiftUIHost:
            if ReplayMasking.masksInScreenshot(kind: kind, isPrivate: false, unmasked: unmasked, rules: rules) {
                node.masked = true
                descend = false
            }
        case .image:
            node.isImage = true
            if ReplayMasking.masksSnapshotImage(unmasked: unmasked, rules: rules) { node.masked = true }
        case .other:
            break
        }

        if descend && depth < maxDepth && !kids.isEmpty {
            var children: [SnapshotNode] = []
            for child in kids {
                if budget <= 0 { break }
                if let c = visit(child, depth: depth + 1, unmasked: unmasked, viewport: viewport, rules: rules,
                                 maxDepth: maxDepth, budget: &budget) {
                    children.append(c)
                }
            }
            if !children.isEmpty { node.children = children }
        }
        return node
    }

    static func bounds(_ r: CGRect) -> SnapshotBounds {
        SnapshotBounds(x: Int(r.minX.rounded()), y: Int(r.minY.rounded()),
                       w: Int(r.width.rounded()), h: Int(r.height.rounded()))
    }
}

/// Decides when the view tree is walked and whether the result is kept.
///
/// - The first walk of every session, and the first after a navigation (a
///   new screen, a view controller appearing, a return to the foreground),
///   happen at the next tick, as long as `interval` passed since the last
///   snapshot taken.
/// - Otherwise the tree is walked once per `interval` (`snapshotIntervalMs`,
///   clamped to 1–60 s like Android and Flutter).
/// - A walk whose result equals the last snapshot taken in the session
///   (same screen, viewport and tree) is dropped, like Flutter's structural
///   hash: a static screen costs one snapshot, not one per second.
///
/// Not thread-safe; the capturer uses it on the main thread.
struct SnapshotScheduler {
    static let minIntervalMs = 1000
    static let maxIntervalMs = 60000

    let interval: TimeInterval

    private(set) var navigationPending = true
    private var lastWalk: TimeInterval?
    private var lastTaken: TimeInterval?
    private var last: Taken?
    private var session: String?

    private struct Taken: Equatable {
        var screen: String
        var viewportWidth: Int
        var viewportHeight: Int
        var tree: SnapshotNode
    }

    init(intervalMs: Int) {
        let ms = min(max(intervalMs, SnapshotScheduler.minIntervalMs), SnapshotScheduler.maxIntervalMs)
        interval = TimeInterval(ms) / 1000
    }

    /// A new screen: walk at the next tick the interval allows.
    mutating func markNavigation() {
        navigationPending = true
    }

    /// True when the tree should be walked now. `now` is any monotonic clock
    /// in seconds.
    mutating func shouldWalk(at now: TimeInterval, sessionId: String) -> Bool {
        if sessionId != session {
            session = sessionId
            navigationPending = true
            lastWalk = nil
            lastTaken = nil
            last = nil
        }
        let sinceTaken = lastTaken.map { now - $0 } ?? .infinity
        let sinceWalk = lastWalk.map { now - $0 } ?? .infinity
        let due = (navigationPending && sinceTaken >= interval) || sinceWalk >= interval
        guard due else { return false }
        navigationPending = false
        lastWalk = now
        return true
    }

    /// After a walk: true when the result differs from the last snapshot
    /// taken in this session, which it then replaces.
    mutating func accept(_ tree: SnapshotNode, screen: String, viewportWidth: Int, viewportHeight: Int,
                         at now: TimeInterval) -> Bool {
        let taken = Taken(screen: screen, viewportWidth: viewportWidth, viewportHeight: viewportHeight, tree: tree)
        if taken == last { return false }
        last = taken
        lastTaken = now
        return true
    }
}

/// A snapshot waiting to be uploaded.
struct PendingSnapshot: Codable, Equatable {
    var sessionId: String
    var ordinal: Int
    var screenName: String
    var capturedAt: Date
    /// Window size in points.
    var viewportWidth: Int
    var viewportHeight: Int
    var hierarchy: SnapshotNode
}

/// `SnapshotPayload` in the API (internal/model/types.go).
struct SnapshotPayload: Encodable {
    var capturedAt: String
    var ordinal: Int
    var screenName: String
    var viewportWidth: Int
    var viewportHeight: Int
    var hierarchy: SnapshotNode

    init(_ s: PendingSnapshot) {
        capturedAt = ISO8601.string(from: s.capturedAt)
        ordinal = s.ordinal
        screenName = s.screenName
        viewportWidth = s.viewportWidth
        viewportHeight = s.viewportHeight
        hierarchy = s.hierarchy
    }
}

/// `IngestSnapshotsRequest` in the API: `POST /v1/ingest/snapshots`.
struct IngestSnapshotsRequest: Encodable {
    var sessionId: String
    var snapshots: [SnapshotPayload]
}
