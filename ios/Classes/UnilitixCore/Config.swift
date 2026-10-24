// VENDORED from UnilitixCore 0.6.0 (Config.swift) by scripts/sync-ios-core.sh.
// Do not edit here; change UnilitixCore and re-run the script.

import Foundation

/// SDK configuration. Every default is the shared SDK contract's
/// (`SdkContract.defaults`); `SdkContractTests` fails if one drifts.
public struct UnilitixConfig {
    /// Ingest API base URL.
    public var apiUrl: String = "https://api.unilitix.com"
    /// Verbose logging to the console.
    public var debug: Bool = false
    /// Record a screen view when a view controller appears (UIKit and
    /// SwiftUI-hosted screens). Turn off if you call `Unilitix.screen` yourself.
    public var autoTrackScreens: Bool = true
    /// Record taps (position in points and the tapped view's class and
    /// accessibility identifier, never its text). Keyboard taps are ignored.
    public var autoTrackTaps: Bool = true
    /// Record rage taps: three or more taps close together within a second.
    public var autoTrackRageTaps: Bool = true
    /// Report uncaught Objective-C exceptions and fatal signals (SIGABRT,
    /// SIGBUS, SIGFPE, SIGILL, SIGSEGV, SIGTRAP) as CRASH events. A signal is
    /// reported on the next launch, against the session that crashed.
    /// Also turns on app-hang (`ANR`) detection; see `appHangTimeoutMs`.
    public var autoTrackCrashes: Bool = true
    /// With `autoTrackCrashes`, report an app hang (`ANR`) when the main
    /// thread does not respond for this long, in milliseconds, while the app
    /// is in the foreground. 0 turns hang detection off. iOS only: not a
    /// contract option (Sentry's `appHangTimeoutInterval` defaults to 2 s
    /// too). Hangs shorter than this are not reported.
    public var appHangTimeoutMs: Int = 2000
    /// Upload queued events at least this often, in seconds.
    public var flushIntervalSeconds: Int = 30
    /// Upload early once this many events are queued; also the most events
    /// sent in one request.
    public var flushBatchSize: Int = 100
    /// Events kept on the device while offline; the oldest are dropped first.
    public var maxOfflineEvents: Int = 1000
    /// Time in the background, in seconds, after which returning to the app
    /// starts a new session.
    public var sessionTimeoutSeconds: Int = 1800

    // MARK: Session replay (screenshots)

    /// Capture screenshots of the app's key window for session replay. They
    /// are masked on the device (see the `mask*` options), downscaled to
    /// `screenshotMaxWidth` and JPEG-encoded before they are stored.
    public var captureScreenshots: Bool = true
    /// Minimum gap between two screenshots, in milliseconds. A frame is taken
    /// only after the screen changed (a touch, a scroll, a new screen).
    public var screenshotIntervalMs: Int = 1000
    /// On a screen that does not change, take a frame at least this often,
    /// in milliseconds.
    public var screenshotHeartbeatMs: Int = 10000
    /// Rolling one-minute budget, so an animating screen cannot flood the session.
    public var maxScreenshotsPerMinute: Int = 20
    /// Stop capturing screenshots after this many in one session.
    public var maxScreenshotsPerSession: Int = 1500
    /// JPEG quality, 1–100.
    public var screenshotQuality: Int = 30
    /// Screenshots are downscaled to at most this width, in pixels.
    public var screenshotMaxWidth: Int = 480
    /// Hold screenshots on the device until it is on Wi-Fi (or wired, and
    /// not a personal hotspot or Low Data Mode). Events are never held.
    public var uploadScreenshotsOnWifiOnly: Bool = true
    /// Fraction of sessions (0–1) that capture replay (screenshots and
    /// view-tree snapshots), decided once per session. Events are always
    /// captured.
    public var replaySampleRate: Double = 1.0
    /// Black out text inputs (`UITextField`, `UITextView` and their
    /// subclasses, including secure entry) in screenshots. Applies even
    /// inside views marked `unilitixUnmasked`.
    public var maskInputs: Bool = true
    /// Black out all text in screenshots (`UILabel`, read-only
    /// `UITextView`, React Native text, web views and SwiftUI-hosted
    /// content). Opt a view and its subviews out with
    /// `view.unilitixUnmasked = true`.
    public var maskAllText: Bool = true
    /// Black out images (`UIImageView`) in screenshots.
    public var maskImages: Bool = false
    /// Master switch for masking in screenshots (Flutter's
    /// `maskScreenshots`). When false, only views marked `unilitixPrivate`
    /// are masked in screenshots; `maskInputs`, `maskAllText` and
    /// `maskImages` are ignored there. View-tree snapshots keep applying them.
    public var maskInputsInScreenshots: Bool = true

    // MARK: Session replay (view-tree snapshots)

    /// Capture view-tree snapshots of the key window for replay: each
    /// visible view's type, frame (in points) and colours, with text masked
    /// by the same rules as screenshots (`maskInputs`, `maskAllText`,
    /// `maskImages`, `unilitixUnmasked`, `unilitixPrivate`). Sampled with
    /// `replaySampleRate` together with screenshots.
    public var captureSnapshots: Bool = true
    /// Minimum gap between two snapshots, in milliseconds; clamped to
    /// 1000–60000. The tree is walked at most this often, and a snapshot is
    /// kept only when it differs from the previous one.
    public var snapshotIntervalMs: Int = 1000
    /// Stop capturing snapshots after this many in one session.
    public var maxSnapshotsPerSession: Int = 1500

    public init() {}
}

/// Whether the SDK may collect and upload.
public enum UnilitixConsent: String, CaseIterable {
    /// Capture and upload normally. Granting after `pending` uploads what was held.
    case granted
    /// Capture to the on-device queue but upload nothing until `setConsent`
    /// decides. For apps that must ask first (NDPR, GDPR).
    case pending
    /// Stop capture and delete everything queued on the device.
    case denied
}

/// Persists the consent decision and the device identity across launches.
final class Preferences {
    private let defaults: UserDefaults
    private enum Key {
        static let consent = "unilitix_consent"
        static let anonymousId = "unilitix_anonymous_id"
        static let installId = "unilitix_install_id"
        static let customUserId = "unilitix_custom_user_id"
    }

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    /// The decision the user made on a previous launch, if any. It always
    /// wins over the value the app passes to `start`.
    var consent: UnilitixConsent? {
        get { defaults.string(forKey: Key.consent).flatMap(UnilitixConsent.init(rawValue:)) }
        set { defaults.set(newValue?.rawValue, forKey: Key.consent) }
    }

    var anonymousId: String {
        get { stableId(Key.anonymousId) }
        set { defaults.set(newValue, forKey: Key.anonymousId) }
    }

    var installId: String { stableId(Key.installId) }

    var customUserId: String? {
        get { defaults.string(forKey: Key.customUserId) }
        set { defaults.set(newValue, forKey: Key.customUserId) }
    }

    private func stableId(_ key: String) -> String {
        if let id = defaults.string(forKey: key) { return id }
        let id = UUID().uuidString.lowercased()
        defaults.set(id, forKey: key)
        return id
    }
}
