import Flutter
import UIKit
import CoreLocation

/// The iOS side of the Unilitix Flutter SDK (3.0.0): a thin bridge to
/// UnilitixCore (vendored in Classes/UnilitixCore by scripts/sync-ios-core.sh,
/// facade `Unilitix` included), which owns sessions, identity, consent, the
/// offline queue, uploads, device and network context, crashes (NSException,
/// fatal signals), app hangs, and taps.
///
/// Dart sends what only Dart can see: route names (`screen`), Dart errors
/// (`recordError` → `recordExternalError(platform: "dart")`), wireframe
/// snapshots of the widget tree (`addSnapshot` → `addExternalSnapshot`) and
/// masked screenshots, which this plugin draws and hands to
/// `captureExternalScreenshot`.
///
/// Channel `com.unilitix/sdk`; every reply is on the main thread.
public class UnilitixPlugin: NSObject, FlutterPlugin {
  private var channel: FlutterMethodChannel?

  /// Encoded frames waiting for Dart's commit or discard (main thread only).
  /// At most `maxPendingFrames`: Dart has one capture in flight at a time.
  private var pendingFrames: [Int: (jpeg: Data, width: Int, height: Int)] = [:]
  private var nextFrameId = 1
  private static let maxPendingFrames = 2

  // MARK: Power-outage contribution state (opt-in; all on the main thread)
  private var batteryObserver: NSObjectProtocol?
  /// True when this plugin turned battery monitoring on (so it only turns
  /// off what it turned on, never the host app's own monitoring).
  private var enabledBatteryMonitoring = false
  private var lastPluggedIn: Bool?
  /// Never used to request authorization or start updates; only its cached
  /// `location` is read, and only when the app already has authorization.
  private lazy var locationManager = CLLocationManager()

  public static func register(with registrar: FlutterPluginRegistrar) {
    let instance = UnilitixPlugin()
    let channel = FlutterMethodChannel(name: "com.unilitix/sdk", binaryMessenger: registrar.messenger())
    registrar.addMethodCallDelegate(instance, channel: channel)
    instance.channel = channel
  }

  public func handle(_ call: FlutterMethodCall, result: @escaping FlutterResult) {
    let args = (call.arguments as? [String: Any]) ?? [:]
    switch call.method {
    case "init":
      start(args, result: result)

    case "track":
      Unilitix.track(args["name"] as? String ?? "", properties: Self.nonNull(args["properties"]))
      result(nil)

    case "screen":
      if let name = args["name"] as? String { Unilitix.screen(name) }
      result(nil)

    case "identify":
      if let userId = args["userId"] as? String {
        Unilitix.identify(userId, traits: Self.nonNull(args["traits"]))
      }
      result(nil)

    case "reset":
      Unilitix.reset()
      result(nil)

    case "flush":
      Unilitix.flush()
      result(nil)

    case "startSession":
      Unilitix.startSession()
      result(nil)

    case "endSession":
      Unilitix.endSession()
      result(nil)

    case "setConsent":
      if let value = (args["consent"] as? String).flatMap(UnilitixConsent.init(rawValue:)) {
        Unilitix.setConsent(value)
      }
      result(nil)

    case "addBreadcrumb":
      Unilitix.addBreadcrumb(args["message"] as? String ?? "", category: args["category"] as? String)
      result(nil)

    case "recordError":
      let metadata = (args["metadata"] as? [String: Any]).flatMap { $0.isEmpty ? nil : $0 }
      Unilitix.recordExternalError(
        type: args["type"] as? String ?? "Error",
        message: args["message"] as? String ?? "",
        stackTrace: args["stackTrace"] as? String,
        fatal: (args["fatal"] as? Bool) ?? false,
        platform: args["platform"] as? String ?? "dart",
        fingerprint: args["fingerprint"] as? String,
        metadata: metadata)
      result(nil)

    // UnilitixCore records taps itself (UIWindow.sendEvent sees Flutter's
    // touches) on the route name Dart sent last; init answers dartTaps: false.
    case "recordTap":
      result(nil)

    case "replayState":
      result(state())

    case "addSnapshot":
      if let json = args["json"] as? String { Unilitix.addExternalSnapshot(json: json) }
      result(nil)

    case "captureScreenshot":
      captureScreenshot(args, result: result)

    case "commitScreenshot":
      if let id = (args["id"] as? NSNumber)?.intValue, let frame = pendingFrames.removeValue(forKey: id) {
        let width = (args["width"] as? NSNumber)?.intValue ?? frame.width
        let height = (args["height"] as? NSNumber)?.intValue ?? frame.height
        let ts = (args["timestampMs"] as? NSNumber)?.int64Value ?? Int64(Date().timeIntervalSince1970 * 1000)
        Unilitix.captureExternalScreenshot(
          frame.jpeg, width: numericCast(width), height: numericCast(height),
          timestampMs: numericCast(ts), screen: args["screen"] as? String)
      }
      result(nil)

    case "discardScreenshot":
      if let id = (args["id"] as? NSNumber)?.intValue { pendingFrames[id] = nil }
      result(nil)

    // Power-outage contribution (Flutter-only). Dart calls these only when
    // the app opted in and consent is granted.
    case "powerSetMonitoring":
      setPowerMonitoring((args["enabled"] as? Bool) ?? false)
      result(nil)

    case "powerIsCharging":
      result(pluggedIn())

    case "powerCoarseLocation":
      result(coarseLocation())

    default:
      result(FlutterMethodNotImplemented)
    }
  }

  // MARK: - Init

  private func start(_ args: [String: Any], result: @escaping FlutterResult) {
    guard let apiKey = args["apiKey"] as? String, !apiKey.isEmpty else {
      result(FlutterError(code: "MISSING_API_KEY", message: "apiKey is required", details: nil))
      return
    }
    let options = (args["config"] as? [String: Any]) ?? [:]
    let consent = (args["consent"] as? String).flatMap(UnilitixConsent.init(rawValue:)) ?? .granted

    // Before start: the first session reports the wrapper, and UnilitixCore
    // does not install its own screenshot and view-tree capture (UIKit
    // sees a single FlutterView); Dart supplies both.
    Unilitix.setWrapper(name: args["wrapperName"] as? String ?? "flutter",
                        version: args["wrapperVersion"] as? String ?? "")
    Unilitix.setExternalScreenCapture(true)
    Unilitix.start(apiKey: apiKey, config: Self.config(options), consent: consent)
    result(state())
  }

  /// Dart's options (SDK contract keys) as UnilitixCore's config.
  static func config(_ o: [String: Any]) -> UnilitixConfig {
    func bool(_ k: String) -> Bool? { o[k] as? Bool }
    func int(_ k: String) -> Int? { (o[k] as? NSNumber)?.intValue }
    var c = UnilitixConfig()
    if let v = o["apiUrl"] as? String, !v.isEmpty { c.apiUrl = v }
    if let v = bool("debug") { c.debug = v }
    // Route names come from Dart (Unilitix.screen): view controllers would
    // only ever report the FlutterViewController.
    c.autoTrackScreens = false
    if let v = bool("autoTrackTaps") { c.autoTrackTaps = v }
    if let v = bool("autoTrackRageTaps") { c.autoTrackRageTaps = v }
    if let v = bool("autoTrackCrashes") { c.autoTrackCrashes = v }
    if let v = int("appHangTimeoutMs") { c.appHangTimeoutMs = max(0, v) }
    if let v = int("flushIntervalSeconds") { c.flushIntervalSeconds = v }
    if let v = int("flushBatchSize") { c.flushBatchSize = v }
    if let v = int("maxOfflineEvents") { c.maxOfflineEvents = v }
    if let v = int("sessionTimeoutSeconds") { c.sessionTimeoutSeconds = v }
    if let v = bool("maskInputs") { c.maskInputs = v }
    if let v = bool("maskAllText") { c.maskAllText = v }
    if let v = bool("maskImages") { c.maskImages = v }
    if let v = bool("maskInputsInScreenshots") { c.maskInputsInScreenshots = v }
    if let v = (o["replaySampleRate"] as? NSNumber)?.doubleValue { c.replaySampleRate = v }
    if let v = bool("captureSnapshots") { c.captureSnapshots = v }
    if let v = int("snapshotIntervalMs") { c.snapshotIntervalMs = v }
    if let v = int("maxSnapshotsPerSession") { c.maxSnapshotsPerSession = v }
    if let v = bool("captureScreenshots") { c.captureScreenshots = v }
    if let v = int("screenshotIntervalMs") { c.screenshotIntervalMs = v }
    if let v = int("screenshotQuality") { c.screenshotQuality = v }
    if let v = int("screenshotMaxWidth") { c.screenshotMaxWidth = v }
    if let v = bool("uploadScreenshotsOnWifiOnly") { c.uploadScreenshotsOnWifiOnly = v }
    if let v = int("maxScreenshotsPerSession") { c.maxScreenshotsPerSession = v }
    if let v = int("maxScreenshotsPerMinute") { c.maxScreenshotsPerMinute = v }
    if let v = int("screenshotHeartbeatMs") { c.screenshotHeartbeatMs = v }
    return c
  }

  /// What Dart needs to drive capture.
  private func state() -> [String: Any] {
    var s: [String: Any] = [
      "consent": Unilitix.consent.rawValue,
      "replaySampled": Unilitix.isReplaySampled,
      "dartTaps": false,
    ]
    if let id = Unilitix.currentSessionId { s["sessionId"] = id }
    return s
  }

  /// String-keyed values without nulls (`NSNull` carries nothing on the wire).
  private static func nonNull(_ value: Any?) -> [String: Any] {
    guard let m = value as? [String: Any] else { return [:] }
    return m.filter { !($0.value is NSNull) }
  }

  // MARK: - Screenshot
  //
  // Drawing and encoding are UnilitixCore's (ScreenshotCapture.render /
  // encode, shared with the native iOS and React Native SDKs): on the main
  // thread the key window is drawn at most maxWidth pixels wide with the
  // masks painted in the same pass, so no unmasked image is kept; JPEG
  // encoding runs on a background queue. Dart finds the masks. The frame
  // stays here until Dart commits it (masks did not move) or discards it.
  // Arguments: maxWidth (Int, px), quality (Int 1..100), scale (Double,
  // unused on iOS: masks are in logical pixels, which are window points),
  // masks ([[l,t,r,b]] in points). Answers {id, width, height} or nil.

  private func captureScreenshot(_ args: [String: Any], result: @escaping FlutterResult) {
    let requested = CGFloat((args["maxWidth"] as? NSNumber)?.doubleValue ?? 480)
    // 0 or less: no limit (the screen's scale).
    let maxWidth = requested > 0 ? requested : .greatestFiniteMagnitude
    let quality = CGFloat(min(max((args["quality"] as? NSNumber)?.doubleValue ?? 30, 1), 100)) / 100.0
    let masks: [CGRect] = ((args["masks"] as? [[NSNumber]]) ?? []).compactMap { m in
      guard m.count >= 4 else { return nil }
      let l = CGFloat(m[0].doubleValue), t = CGFloat(m[1].doubleValue)
      let r = CGFloat(m[2].doubleValue), b = CGFloat(m[3].doubleValue)
      guard r > l, b > t else { return nil }
      return CGRect(x: l, y: t, width: r - l, height: b - t)
    }

    DispatchQueue.main.async {
      guard let window = ScreenshotCapture.captureWindow(),
            let image = ScreenshotCapture.render(window, maxWidth: maxWidth, masks: masks) else {
        result(nil); return
      }
      let width = Int(image.size.width * image.scale)
      let height = Int(image.size.height * image.scale)
      ScreenshotCapture.encode(image, quality: quality) { jpeg in
        DispatchQueue.main.async {
          guard let jpeg = jpeg else { result(nil); return }
          let id = self.nextFrameId
          self.nextFrameId += 1
          self.pendingFrames[id] = (jpeg, width, height)
          while self.pendingFrames.count > Self.maxPendingFrames, let oldest = self.pendingFrames.keys.min() {
            self.pendingFrames[oldest] = nil
          }
          result(["id": id, "width": width, "height": height])
        }
      }
    }
  }

  // MARK: - Power-outage contribution

  /// Plugged in (charging or full), unplugged, or nil when unknown.
  private func pluggedIn() -> Bool? {
    let device = UIDevice.current
    let wasMonitoring = device.isBatteryMonitoringEnabled
    if !wasMonitoring { device.isBatteryMonitoringEnabled = true }
    let state = device.batteryState
    if !wasMonitoring { device.isBatteryMonitoringEnabled = false }
    switch state {
    case .charging, .full: return true
    case .unplugged: return false
    default: return nil
    }
  }

  /// Observes battery-state changes while the app is in the foreground (iOS
  /// delivers none in the background) and forwards plug changes to Dart.
  private func setPowerMonitoring(_ enabled: Bool) {
    let device = UIDevice.current
    if enabled {
      guard batteryObserver == nil else { return }
      if !device.isBatteryMonitoringEnabled {
        device.isBatteryMonitoringEnabled = true
        enabledBatteryMonitoring = true
      }
      lastPluggedIn = pluggedIn()
      batteryObserver = NotificationCenter.default.addObserver(
        forName: UIDevice.batteryStateDidChangeNotification,
        object: nil,
        queue: .main
      ) { [weak self] _ in
        guard let self = self, let plugged = self.pluggedIn() else { return }
        // charging <-> full also notifies; only a plug change is forwarded.
        if plugged != self.lastPluggedIn {
          self.lastPluggedIn = plugged
          self.channel?.invokeMethod("powerChargingChanged", arguments: plugged)
        }
      }
    } else {
      if let observer = batteryObserver {
        NotificationCenter.default.removeObserver(observer)
        batteryObserver = nil
      }
      if enabledBatteryMonitoring {
        device.isBatteryMonitoringEnabled = false
        enabledBatteryMonitoring = false
      }
      lastPluggedIn = nil
    }
  }

  /// The system's cached location, only if the app already holds
  /// when-in-use or always authorization. Never requests authorization and
  /// never starts location updates. The coordinates stay on the device: Dart
  /// turns them into an H3 cell and drops them.
  private func coarseLocation() -> [String: Any]? {
    let status: CLAuthorizationStatus
    if #available(iOS 14.0, *) {
      status = locationManager.authorizationStatus
    } else {
      status = CLLocationManager.authorizationStatus()
    }
    guard status == .authorizedWhenInUse || status == .authorizedAlways,
          let location = locationManager.location else { return nil }
    return [
      "lat": location.coordinate.latitude,
      "lng": location.coordinate.longitude,
      "timeMs": Int64(location.timestamp.timeIntervalSince1970 * 1000),
    ]
  }
}
