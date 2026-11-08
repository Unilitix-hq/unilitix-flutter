// VENDORED from UnilitixCore 0.8.0 (Unilitix.swift) by scripts/sync-ios-core.sh.
// Do not edit here; change UnilitixCore and re-run the script.

import Foundation
#if canImport(UIKit)
import UIKit
#endif

/// The Unilitix iOS SDK.
///
/// ```swift
/// Unilitix.start(apiKey: "ul_live_…")
/// Unilitix.screen("Checkout")
/// Unilitix.track("purchase_completed", properties: ["amount": 5000, "currency": "NGN"])
/// ```
///
/// Every method is safe to call from any thread and never throws into the
/// app. Calls made before `start` are buffered and replayed once it runs.
///
/// Session replay (masked screenshots and view-tree snapshots) is on by
/// default; see `UnilitixConfig.captureScreenshots`,
/// `UnilitixConfig.captureSnapshots` and `UIView.unilitixUnmasked`.
public enum Unilitix {

    /// The engine and the calls made before `start` (`EngineHost`).
    private static let host = EngineHost()
    private static let lock = NSLock()
    private static var observers: [NSObjectProtocol] = []
    /// `setExternalScreenCapture`, also when called before `start`.
    private static var externalScreenCapture = false

    /// True once `start` has been called.
    public static var isStarted: Bool { host.current != nil }

    /// The current consent state.
    public static var consent: UnilitixConsent {
        guard let e = host.current else { return .granted }
        if e.isOnQueue { return e.consent }
        return e.queue.sync { e.consent }
    }

    /// Starts the SDK. Calling it again is a no-op: the first key and config win.
    ///
    /// Apps that must ask before collecting (NDPR, GDPR) pass `.pending`:
    /// events are kept on the device and nothing is uploaded until
    /// `setConsent(.granted)` (which sends what was held) or `.denied`
    /// (which deletes it). A decision persisted from a previous launch always
    /// wins over `consent`.
    ///
    /// Only cheap setup and the crash handlers run on the calling thread; the
    /// on-device queue, replay stores and the previous launch's crash record
    /// are read on the SDK's own queue, before any call made from here on.
    ///
    /// In an app extension, events, errors and crashes are captured, but no
    /// automatic screen, tap or replay capture, app-hang watchdog or
    /// background task is installed.
    public static func start(apiKey: String,
                             config: UnilitixConfig = UnilitixConfig(),
                             consent: UnilitixConsent = .granted) {
        let debug = config.debug
        // Claim the start before building anything: a second call is a cheap no-op.
        guard host.claim() else {
            if debug { print("[Unilitix] start() called twice; ignored") }
            return
        }
        #if canImport(Darwin)
        let crashFile: String? = CrashFile.enginePath
        #else
        let crashFile: String? = nil
        #endif
        let isApp = !AppContext.isAppExtension
        // The hang the previous process did not survive is read by
        // `Engine.loadPersistedState`, on the engine's queue.
        let hangFile: String? = AppHangFile.enginePath
        let device = DeviceInfo.current()
        // Out-of-memory and watchdog terminations (apps only).
        let tracker: TerminationTracker? = config.autoTrackCrashes && isApp
            ? TerminationTracker(path: TerminationTracker.enginePath, device: device) : nil
        let e = Engine(
            config: config,
            transport: URLSessionTransport(baseURL: config.apiUrl, apiKey: apiKey),
            store: EventStore(directory: EventStore.defaultDirectory, maxEvents: config.maxOfflineEvents,
                              loadImmediately: false),
            prefs: Preferences(),
            device: device,
            consent: consent,
            screenshots: ScreenshotStore(directory: ScreenshotStore.defaultDirectory, loadImmediately: false),
            snapshots: SnapshotStore(directory: SnapshotStore.defaultDirectory, loadImmediately: false),
            reachability: PathReachability(),
            crashFilePath: crashFile,
            appHangFilePath: hangFile,
            terminationTracker: tracker,
            log: { if debug { print("[Unilitix] \($0)") } })
        let external = withLock { externalScreenCapture }
        e.setExternalScreenCapture(external)
        host.attach(e)

        if config.autoTrackCrashes {
            // Exceptions go to the store with their stack (CrashReporter);
            // fatal signals to the crash file, reported on the next launch.
            CrashReporter.install(e)
            #if canImport(Darwin)
            if let path = crashFile { CrashFile.installSignalHandlers(path: path) }
            #endif
            if isApp { MetricKitExits.install() }
        }
        #if canImport(UIKit) && os(iOS)
        let replay = config.captureScreenshots
        let snapshots = config.captureSnapshots
        if isApp && (config.autoTrackScreens || config.autoTrackTaps || replay || snapshots) {
            let screens = config.autoTrackScreens, taps = config.autoTrackTaps
            DispatchQueue.main.async {
                AutoCapture.install(e, screens: screens, taps: taps, replay: replay, snapshots: snapshots)
                if replay { ScreenshotCapture.install(e, config: config) }
                if snapshots { SnapshotCapture.install(e, config: config) }
            }
        }
        #endif
        #if canImport(Darwin)
        if isApp && config.autoTrackCrashes && config.appHangTimeoutMs > 0 {
            // Main-thread watchdog: hangs of appHangTimeoutMs or more become ANR events.
            AppHangWatchdog.install(e, timeoutMs: config.appHangTimeoutMs)
        }
        #endif
        let lifecycle = LifecycleObserver.install(e)
        withLock { observers = lifecycle }
        if debug { print("[Unilitix] ✅ SDK started (UnilitixCore \(UnilitixVersion.current))") }
    }

    /// A custom event. Calls before `start` are buffered (up to 200).
    /// The name and properties are normalised to the contract's limits:
    /// strings up to 1024 UTF-16 units, 100 keys or items per map or list,
    /// 5 levels of nesting (deeper values become "[Truncated]"), NaN and
    /// infinity as null.
    public static func track(_ name: String, properties: [String: Any] = [:]) {
        host.run { $0.track(name, properties: properties) }
    }

    /// The visible screen changed (sent as `NAVIGATE`). Calling it again
    /// with the current screen does nothing.
    public static func screen(_ name: String) {
        host.run { $0.screenView(name) }
    }

    /// Links this device's anonymous id to your user id.
    public static func identify(_ userId: String, traits: [String: Any] = [:]) {
        host.run { $0.identify(userId, traits: traits) }
    }

    /// Reports a handled error as `EXCEPTION`, or as `CRASH` when `fatal`.
    public static func captureError(_ error: Error, fatal: Bool = false) {
        let type = String(describing: Swift.type(of: error))
        let message = (error as NSError).localizedDescription
        let stack = Thread.callStackSymbols.joined(separator: "\n")
        #if canImport(Darwin)
        let images: [DebugImage]? = BinaryImages.debugImages(
            returnAddresses: Thread.callStackReturnAddresses.map { $0.uintValue })
        #else
        let images: [DebugImage]? = nil
        #endif
        host.run { $0.recordError(type: type, message: message, stack: stack, fatal: fatal, debugImages: images) }
    }

    /// Reports an error caught elsewhere (for example by a cross-platform
    /// bridge) with its own type, message and stack trace. An Apple stack
    /// (`callStackSymbols` lines) captured in this process gets
    /// `metadata.debugImages` for its frames.
    public static func recordException(type: String, message: String,
                                       stackTrace: String?, fatal: Bool = false) {
        host.run { $0.recordError(type: type, message: message, stack: stackTrace, fatal: fatal) }
    }

    /// Adds an entry to the trail attached to the next error report.
    public static func addBreadcrumb(_ message: String, category: String? = nil) {
        host.run { $0.addBreadcrumb(message, category: category) }
    }

    /// Records the user's decision and persists it across launches.
    public static func setConsent(_ consent: UnilitixConsent) {
        host.run { $0.setConsent(consent) }
    }

    /// Starts a new session now, ending the current one.
    public static func startSession() {
        host.run { $0.startSession() }
    }

    /// Ends the current session and uploads it. The next event starts a new one.
    public static func endSession() {
        host.run { $0.endSession() }
    }

    /// Uploads queued events now (subject to consent, network and backoff).
    public static func flush() {
        host.run { $0.flush() }
    }

    /// Forgets the user: new anonymous id, no user id, new session.
    public static func reset() {
        host.run { $0.reset() }
    }

    // MARK: Wrapper SDKs
    //
    // For SDKs that embed UnilitixCore (Flutter, React Native). Plugins
    // that vendor the sources without this file call the same `Engine`
    // methods directly; see README "Wrapper SDKs". None of these throw.

    /// Names the wrapper SDK and its version (e.g. "flutter", "3.0.0"):
    /// reported as the session's `sdkVersion` and in the User-Agent, with
    /// both versions in `sessionData`. Call before `start`.
    public static func setWrapper(name: String, version: String) {
        Engine.setWrapper(name: name, version: version)
    }

    /// Reports an error raised in the wrapper's runtime (Dart, JavaScript):
    /// `EXCEPTION`, or `CRASH` when `fatal`, with `metadata.platform` =
    /// `platform` (e.g. "flutter", "react-native"). `fingerprint` replaces
    /// the computed one when given; `metadata` is added to the event's
    /// metadata (normalised; `fingerprint` and `platform` keys are ignored).
    /// A fatal report is stored before this returns (at most 2 s).
    public static func recordExternalError(type: String, message: String, stackTrace: String?, fatal: Bool,
                                           platform: String, fingerprint: String? = nil,
                                           metadata: [String: Any]? = nil) {
        let call: (Engine) -> Void = {
            $0.recordExternalError(type: type, message: message, stackTrace: stackTrace, fatal: fatal,
                                   platform: platform, fingerprint: fingerprint, metadata: metadata)
        }
        if fatal {
            host.runAndWait(timeout: TimeInterval(SdkContract.fatalFlushBudgetMs) / 1000, call)
        } else {
            host.run(call)
        }
    }

    /// A replay frame the wrapper drew and masked itself: JPEG bytes,
    /// viewport `width`×`height` in points, captured at `timestampMs`
    /// (milliseconds since 1970), on `screen` (nil: the current screen).
    /// Goes through the normal screenshot pipeline: replay sampling,
    /// `maxScreenshotsPerSession`/`maxScreenshotsPerMinute`, consent and
    /// `uploadScreenshotsOnWifiOnly`. Dropped before `start`.
    public static func captureExternalScreenshot(_ image: Data, width: Int, height: Int, timestampMs: Int64,
                                                 screen: String?) {
        let at = Date(timeIntervalSince1970: Double(timestampMs) / 1000)
        host.run(buffered: false) {
            $0.addExternalScreenshot(image, width: width, height: height, capturedAt: at, screen: screen)
        }
    }

    /// A view-tree snapshot the wrapper built and masked itself, as JSON
    /// (see `Engine.addExternalSnapshot` for the accepted shapes). Same
    /// gates as native snapshots. Dropped before `start`.
    public static func addExternalSnapshot(json: String) {
        host.run(buffered: false) { $0.addExternalSnapshot(json: json) }
    }

    /// With `enabled`, the SDK's own UIKit screenshot capture stays idle
    /// because the wrapper supplies frames (`captureExternalScreenshot`).
    /// May be called before `start`.
    public static func setExternalScreenCapture(_ enabled: Bool) {
        withLock { externalScreenCapture = enabled }
        host.current?.setExternalScreenCapture(enabled)
    }

    /// The current session id; nil before `start`, between `endSession` and
    /// the next event, and with consent denied.
    public static var currentSessionId: String? { host.current?.currentSessionId }

    /// Whether the current session records replay (decided once per session
    /// with `replaySampleRate`); false without a session.
    public static var isReplaySampled: Bool { host.current?.isReplaySampled ?? false }

    // MARK: Internals

    private static func withLock<T>(_ body: () -> T) -> T {
        lock.lock(); defer { lock.unlock() }
        return body()
    }
}
