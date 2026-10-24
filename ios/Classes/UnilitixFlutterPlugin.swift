import Flutter
import UIKit
import CoreTelephony
import CoreLocation
import Network

public class UnilitixPlugin: NSObject, FlutterPlugin {
  private var networkEventSink: FlutterEventSink?
  private var pathMonitor: NWPathMonitor?
  private let monitorQueue = DispatchQueue(label: "com.unilitix.network")

  // MARK: Power-outage contribution state (opt-in; all on the main thread)
  private var sdkChannel: FlutterMethodChannel?
  /// Hangs that recovered go to Dart here (`onAppHang`); a channel of its
  /// own so it never competes with another Dart handler on the sdk channel.
  private var appHangChannel: FlutterMethodChannel?
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

    let methodChannel = FlutterMethodChannel(
      name: "com.unilitix/sdk",
      binaryMessenger: registrar.messenger()
    )
    registrar.addMethodCallDelegate(instance, channel: methodChannel)
    instance.sdkChannel = methodChannel
    instance.appHangChannel = FlutterMethodChannel(
      name: "com.unilitix/app_hang",
      binaryMessenger: registrar.messenger()
    )

    let eventChannel = FlutterEventChannel(
      name: "com.unilitix/network",
      binaryMessenger: registrar.messenger()
    )
    eventChannel.setStreamHandler(instance)

    let screenshotChannel = FlutterMethodChannel(
      name: "unilitix/screenshot",
      binaryMessenger: registrar.messenger()
    )
    screenshotChannel.setMethodCallHandler { call, result in
      if call.method == "captureScreenshot" {
        instance.captureScreenshot(call, result: result)
      } else {
        result(FlutterMethodNotImplemented)
      }
    }

    // Native crashes (uncaught NSException, fatal signals) go to a file
    // that Dart reports on the next launch: UnilitixCore's CrashFile.
    CrashFile.install()
  }

  public func handle(_ call: FlutterMethodCall, result: @escaping FlutterResult) {
    switch call.method {
    case "getCarrierName":
      // CTCarrier is deprecated and returns "--" on iOS 16+; report "" rather
      // than a placeholder so the dashboard shows "unknown" instead of "--".
      let info = CTTelephonyNetworkInfo()
      let carriers = info.serviceSubscriberCellularProviders ?? [:]
      // Prefer the SIM currently used for data (iOS 13+); fall back to any SIM.
      var name = ""
      if #available(iOS 13.0, *), let dataID = info.dataServiceIdentifier,
         let carrier = carriers[dataID] {
        name = carrier.carrierName ?? ""
      }
      if name.isEmpty {
        name = carriers.values.compactMap { $0.carrierName }.first ?? ""
      }
      result(name == "--" ? "" : name)

    case "getBatteryLevel":
      let wasMonitoring = UIDevice.current.isBatteryMonitoringEnabled
      if !wasMonitoring { UIDevice.current.isBatteryMonitoringEnabled = true }
      let level = UIDevice.current.batteryLevel
      if !wasMonitoring { UIDevice.current.isBatteryMonitoringEnabled = false }
      result(level < 0 ? -1.0 : Double(level))

    // Device fields the SDK used to get from device_info_plus.
    case "getDeviceInfo":
      let device = DeviceInfo.current()
      result([
        "manufacturer": "Apple",
        "model": device.deviceModel,
        "brand": "Apple",
        "osVersion": device.osVersion,
        "timezone": device.timezone,
      ])

    // App fields the SDK used to get from package_info_plus.
    case "getPackageInfo":
      let device = DeviceInfo.current()
      let b = Bundle.main
      func info(_ key: String) -> String { (b.object(forInfoDictionaryKey: key) as? String) ?? "" }
      let name = info("CFBundleDisplayName").isEmpty ? info("CFBundleName") : info("CFBundleDisplayName")
      result([
        "appName": name,
        "packageName": device.packageName,
        "version": device.appVersion,
        "buildNumber": device.buildNumber,
      ])

    // The record CrashFile wrote in a previous process (deleted on read),
    // with its contract fingerprint; then the app hang a previous process
    // left (a `type: "ANR"` record, see UnilitixAppHangMonitor.swift); then
    // nil. Dart reads until nil.
    case "readNativeCrash":
      result(CrashFile.consume() ?? UnilitixAppHangs.shared.consumeEarlierHang())

    // App-hang (ANR) detection. Dart calls it after reading the earlier
    // launch's records, when `autoTrackCrashes` is on and
    // `appHangTimeoutMs` > 0, and again on every consent change
    // (`capture` false while consent is denied).
    case "configureAppHang":
      let args = call.arguments as? [String: Any]
      let timeoutMs = (args?["timeoutMs"] as? NSNumber)?.intValue ?? 0
      let capture = (args?["capture"] as? Bool) ?? true
      if let channel = appHangChannel {
        UnilitixAppHangs.shared.configure(timeoutMs: timeoutMs, captureAllowed: capture, channel: channel)
      }
      result(nil)

    // Power-outage contribution. Dart calls these only when the app opted in
    // and consent is granted.
    case "powerSetMonitoring":
      let enabled = ((call.arguments as? [String: Any])?["enabled"] as? Bool) ?? false
      setPowerMonitoring(enabled)
      result(nil)

    case "powerIsCharging":
      result(pluggedIn())

    case "powerCoarseLocation":
      result(coarseLocation())

    default:
      result(FlutterMethodNotImplemented)
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
          self.sdkChannel?.invokeMethod("powerChargingChanged", arguments: plugged)
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

  // MARK: - Screenshot
  //
  // Drawing and encoding are UnilitixCore's (ScreenshotCapture.render /
  // encode, shared with the native iOS and React Native SDKs): on the main
  // thread the key window is drawn at most maxWidth pixels wide with the
  // masks painted in the same pass, so no unmasked image is kept; JPEG
  // encoding runs on a background queue. Dart finds the masks: Flutter draws
  // into one FlutterView, so UIKit's view tree has nothing to mask.
  // Arguments: maxWidth (Int, px), quality (Int 1..100), scale (Double,
  // unused on iOS: masks are in logical pixels, which are window points),
  // masks ([[l,t,r,b]] in points). Returns JPEG bytes, or nil.

  private func captureScreenshot(_ call: FlutterMethodCall, result: @escaping FlutterResult) {
    guard let args = call.arguments as? [String: Any] else { result(nil); return }
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
      ScreenshotCapture.encode(image, quality: quality) { jpeg in
        DispatchQueue.main.async { result(jpeg.map { FlutterStandardTypedData(bytes: $0) }) }
      }
    }
  }

  // MARK: - Network

  private func resolveNetworkType(_ path: NWPath) -> String {
    guard path.status == .satisfied else { return "OFFLINE" }

    if path.usesInterfaceType(.wifi) { return "WIFI" }
    if path.usesInterfaceType(.wiredEthernet) { return "ETHERNET" }

    if path.usesInterfaceType(.cellular) {
      let networkInfo = CTTelephonyNetworkInfo()
      let radioTech = networkInfo.serviceCurrentRadioAccessTechnology?.values.first ?? ""
      if #available(iOS 14.1, *) {
        if radioTech == CTRadioAccessTechnologyNRNSA ||
           radioTech == CTRadioAccessTechnologyNR {
          return "5G"
        }
      }
      switch radioTech {
      case CTRadioAccessTechnologyLTE:
        return "4G"
      case CTRadioAccessTechnologyHSDPA,
           CTRadioAccessTechnologyHSUPA,
           CTRadioAccessTechnologyCDMAEVDORev0,
           CTRadioAccessTechnologyCDMAEVDORevA,
           CTRadioAccessTechnologyCDMAEVDORevB,
           CTRadioAccessTechnologyeHRPD,
           CTRadioAccessTechnologyWCDMA:
        return "3G"
      case CTRadioAccessTechnologyEdge,
           CTRadioAccessTechnologyGPRS,
           CTRadioAccessTechnologyCDMA1x:
        return "2G"
      default:
        return "CELLULAR"
      }
    }
    return "OFFLINE"
  }
}

extension UnilitixPlugin: FlutterStreamHandler {
  public func onListen(
    withArguments arguments: Any?,
    eventSink events: @escaping FlutterEventSink
  ) -> FlutterError? {
    networkEventSink = events

    let monitor = NWPathMonitor()
    pathMonitor = monitor

    monitor.pathUpdateHandler = { [weak self] path in
      guard let self = self else { return }
      let type = self.resolveNetworkType(path)
      DispatchQueue.main.async {
        self.networkEventSink?(type)
      }
    }

    monitor.start(queue: monitorQueue)
    DispatchQueue.main.async {
      events(self.resolveNetworkType(monitor.currentPath))
    }
    return nil
  }

  public func onCancel(withArguments arguments: Any?) -> FlutterError? {
    pathMonitor?.cancel()
    pathMonitor = nil
    networkEventSink = nil
    return nil
  }
}
