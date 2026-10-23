// VENDORED from UnilitixCore 0.4.1 (ReplayMasking.swift) by scripts/sync-ios-core.sh.
// Do not edit here; change UnilitixCore and re-run the script.

import Foundation

/// What a view is, for replay masking. `ScreenMasker` (screenshots) and
/// `SnapshotCapture` (view-tree snapshots) classify UIKit views into these
/// with the same function, so both apply one set of rules.
enum ReplayNodeKind: Equatable {
    /// `UITextField`, editable `UITextView` (and React Native inputs).
    case input
    /// Secure text entry. Its text is never captured.
    case secureInput
    /// `UILabel` (and so button titles), read-only `UITextView`, React Native text.
    case text
    /// `WKWebView`: its text and inputs cannot be found.
    case web
    /// SwiftUI hosting view: SwiftUI draws text without UIKit views.
    case swiftUIHost
    /// `UIImageView`.
    case image
    case other
}

/// Which views are masked, from the config.
struct MaskRules: Equatable {
    var inputs = true
    var allText = true
    var images = false

    init() {}

    init(inputs: Bool, allText: Bool, images: Bool) {
        self.inputs = inputs
        self.allText = allText
        self.images = images
    }

    /// Screenshots: `maskInputsInScreenshots` is the master switch for the
    /// option-based masking.
    init(config: UnilitixConfig) {
        let on = config.maskInputsInScreenshots
        inputs = on && config.maskInputs
        allText = on && config.maskAllText
        images = on && config.maskImages
    }

    /// View-tree snapshots: `maskInputs`, `maskAllText` and `maskImages`
    /// apply as they are. `maskInputsInScreenshots` only concerns
    /// screenshots (as on Android), so a snapshot never masks less than a
    /// screenshot with the same options.
    static func forSnapshots(_ config: UnilitixConfig) -> MaskRules {
        MaskRules(inputs: config.maskInputs, allText: config.maskAllText, images: config.maskImages)
    }
}

/// Text for a snapshot node; `redacted` marks text whose characters were replaced.
struct MaskedText: Equatable {
    var text: String
    var redacted: Bool
}

/// Privacy rules for session replay, shared by screenshots (rects painted
/// over the frame) and view-tree snapshots (text replaced in the tree).
/// Same rules as the Android `ReplayMasking` and Flutter `PrivacyRegistry`:
///
/// - private views (`unilitixPrivate`): always masked, with everything inside;
/// - inputs: masked with `maskInputs`, also inside `unilitixUnmasked` views;
///   secure entry is never captured as text;
/// - text: masked with `maskAllText`, unless inside `unilitixUnmasked`;
/// - web views: masked with `maskAllText` or `maskInputs`, unless unmasked;
/// - SwiftUI-hosted content: masked as a whole with `maskAllText`, unless unmasked;
/// - images: masked with `maskImages`, unless unmasked.
///
/// Pure logic, unit-tested on macOS.
enum ReplayMasking {
    /// Replaces input text in snapshots (same marker as Android and Flutter).
    static let masked = "[MASKED]"
    static let redactedCharacter: Character = "•"
    /// Longest text kept in a snapshot node, before redaction (as Android).
    static let maxTextLength = 200

    /// Screenshots: true when the view's whole frame is blacked out (and its
    /// subviews need not be visited). `unmasked` is true when the view or an
    /// ancestor is `unilitixUnmasked`.
    static func masksInScreenshot(kind: ReplayNodeKind, isPrivate: Bool, unmasked: Bool, rules: MaskRules) -> Bool {
        if isPrivate { return true }
        switch kind {
        case .input, .secureInput:
            return rules.inputs
        case .text, .swiftUIHost:
            return rules.allText && !unmasked
        case .web:
            return (rules.allText || rules.inputs) && !unmasked
        case .image:
            return rules.images && !unmasked
        case .other:
            return false
        }
    }

    /// Text for a snapshot node.
    ///
    /// - secure entry: always `[MASKED]`;
    /// - other inputs: `[MASKED]` with `maskInputs` (also inside unmasked views);
    /// - with `maskAllText` (inputs included), outside unmasked views: the
    ///   word shapes and length, never the characters (see `redact`);
    /// - otherwise the text, cut to `maxTextLength` characters.
    static func snapshotText(_ raw: String, kind: ReplayNodeKind, unmasked: Bool, rules: MaskRules) -> MaskedText {
        if kind == .secureInput { return MaskedText(text: masked, redacted: false) }
        if kind == .input && rules.inputs { return MaskedText(text: masked, redacted: false) }
        let text = raw.count > maxTextLength ? String(raw.prefix(maxTextLength)) : raw
        if rules.allText && !unmasked { return MaskedText(text: redact(text), redacted: true) }
        return MaskedText(text: text, redacted: false)
    }

    /// Snapshots: true when an image node's content must be marked masked.
    static func masksSnapshotImage(unmasked: Bool, rules: MaskRules) -> Bool {
        rules.images && !unmasked
    }

    /// Replaces every non-whitespace character (Unicode scalar) with `•`,
    /// keeping whitespace, so the replay keeps layout (word lengths, line
    /// breaks) but never the characters. Same as Android's `redact` and
    /// Flutter's `redactText`.
    static func redact(_ text: String) -> String {
        var out = String.UnicodeScalarView()
        for scalar in text.unicodeScalars {
            if scalar.properties.isWhitespace {
                out.append(scalar)
            } else {
                out.append(contentsOf: String(redactedCharacter).unicodeScalars)
            }
        }
        return String(out)
    }
}
