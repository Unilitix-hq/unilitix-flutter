import Flutter
import UIKit
import CoreTelephony
import CoreLocation
import Network

public class UnilitixPlugin: NSObject, FlutterPlugin {
  private var networkEventSink: FlutterEventSink?
  private var pathMonitor: NWPathMonitor?
  private let monitorQueue = DispatchQueue(label: "com.unilitix.network")
  /// Serial queue for downscale / occlusion / JPEG work, off the main thread.
  private let imageQueue = DispatchQueue(label: "com.unilitix.image", qos: .utility)

  // MARK: Power-outage contribution state (opt-in; all on the main thread)
  private var sdkChannel: FlutterMethodChannel?
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

    NativeCrashHandler.install()
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
      var sys = utsname()
      uname(&sys)
      let machine = withUnsafePointer(to: &sys.machine) {
        $0.withMemoryRebound(to: CChar.self, capacity: 1) { String(validatingUTF8: $0) }
      } ?? ""
      result([
        "manufacturer": "Apple",
        "model": machine,
        "brand": "Apple",
        "osVersion": UIDevice.current.systemVersion,
        "timezone": TimeZone.current.identifier,
      ])

    // App fields the SDK used to get from package_info_plus.
    case "getPackageInfo":
      let b = Bundle.main
      func info(_ key: String) -> String { (b.object(forInfoDictionaryKey: key) as? String) ?? "" }
      let name = info("CFBundleDisplayName").isEmpty ? info("CFBundleName") : info("CFBundleDisplayName")
      result([
        "appName": name,
        "packageName": b.bundleIdentifier ?? "",
        "version": info("CFBundleShortVersionString"),
        "buildNumber": info("CFBundleVersion"),
      ])

    case "readNativeCrash":
      result(NativeCrashHandler.consume())

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
  // drawHierarchy must run on the main thread, but it is a single compositor
  // read; scaling, occlusion and JPEG encoding happen on imageQueue.
  // Arguments: maxWidth (Int), quality (Int 1..100), scale (Double, unused on
  // iOS because UIGraphics works in points), masks ([[l,t,r,b]] in points).

  private func captureScreenshot(_ call: FlutterMethodCall, result: @escaping FlutterResult) {
    guard let args = call.arguments as? [String: Any] else { result(nil); return }
    let maxWidth = CGFloat((args["maxWidth"] as? NSNumber)?.doubleValue ?? 480)
    let quality = CGFloat(min(max((args["quality"] as? NSNumber)?.doubleValue ?? 30, 1), 100)) / 100.0
    let masks = (args["masks"] as? [[NSNumber]]) ?? []

    DispatchQueue.main.async {
      guard let window = UIApplication.shared.windows.first(where: { $0.isKeyWindow }) ?? UIApplication.shared.windows.first,
            window.bounds.width > 0, window.bounds.height > 0 else {
        result(nil); return
      }
      let bounds = window.bounds
      // Render at 1x: the output is downscaled anyway and this keeps the
      // main-thread cost to a single composite.
      let format = UIGraphicsImageRendererFormat()
      format.scale = 1
      let renderer = UIGraphicsImageRenderer(bounds: bounds, format: format)
      let image = renderer.image { _ in
        window.drawHierarchy(in: bounds, afterScreenUpdates: false)
      }

      self.imageQueue.async {
        let bytes = self.process(image, maxWidth: maxWidth, quality: quality, masks: masks)
        DispatchQueue.main.async { result(bytes.map { FlutterStandardTypedData(bytes: $0) }) }
      }
    }
  }

  private func process(_ image: UIImage, maxWidth: CGFloat, quality: CGFloat, masks: [[NSNumber]]) -> Data? {
    let factor = (maxWidth > 0 && image.size.width > maxWidth) ? maxWidth / image.size.width : 1
    let target = CGSize(width: floor(image.size.width * factor), height: floor(image.size.height * factor))
    let format = UIGraphicsImageRendererFormat()
    format.scale = 1
    let out = UIGraphicsImageRenderer(size: target, format: format).image { ctx in
      image.draw(in: CGRect(origin: .zero, size: target))
      if !masks.isEmpty {
        ctx.cgContext.setFillColor(UIColor.black.cgColor)
        for m in masks where m.count >= 4 {
          let r = CGRect(
            x: CGFloat(m[0].doubleValue) * factor - 1,
            y: CGFloat(m[1].doubleValue) * factor - 1,
            width: CGFloat(m[2].doubleValue - m[0].doubleValue) * factor + 2,
            height: CGFloat(m[3].doubleValue - m[1].doubleValue) * factor + 2
          ).intersection(CGRect(origin: .zero, size: target))
          if !r.isNull && !r.isEmpty { ctx.cgContext.fill(r) }
        }
      }
    }
    return out.jpegData(compressionQuality: quality)
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

// MARK: - Native crash capture
//
// Records uncaught Objective-C exceptions and fatal signals to a marker file
// that the SDK reports as a fatal CRASH on the next launch, against the
// session that was running. Signal handlers are installed with `sigaction`
// on an alternate stack (`sigaltstack`), so a stack overflow can still be
// recorded, and they only call async-signal-safe functions (open/write/
// close/time) on pre-built buffers. Whatever handler was installed before
// (Crashlytics, Sentry, the app's own) is chained: it runs after ours, and
// if there was none the default action is restored and the signal re-raised
// so the process still dies the way it would have.

enum NativeCrashHandler {
  private static let fileName = "unilitix_native_crash.json"
  private static var previousHandler: (@convention(c) (NSException) -> Void)?
  private static var installed = false
  private static let signals: [Int32] = [SIGABRT, SIGBUS, SIGFPE, SIGILL, SIGSEGV, SIGTRAP]
  /// Previous `sigaction` per signal, restored and chained from the handler.
  private static var previousActions: [Int32: sigaction] = [:]
  /// Path resolved once at install so the signal handler never touches
  /// Foundation (which is not async-signal-safe).
  private static var pathCString: UnsafeMutablePointer<CChar>?
  private static var altStack: UnsafeMutableRawPointer?

  static var filePath: String {
    let dir = NSSearchPathForDirectoriesInDomains(.applicationSupportDirectory, .userDomainMask, true).first ?? NSTemporaryDirectory()
    try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
    return (dir as NSString).appendingPathComponent(fileName)
  }

  static func install() {
    guard !installed else { return }
    installed = true
    pathCString = strdup(filePath)

    previousHandler = NSGetUncaughtExceptionHandler()
    NSSetUncaughtExceptionHandler { exception in
      let payload: [String: Any] = [
        "platform": "ios",
        "exceptionType": exception.name.rawValue,
        "exceptionMessage": exception.reason ?? "",
        "stackTrace": String(exception.callStackSymbols.joined(separator: "\n").prefix(16_000)),
        "timestamp": Int(Date().timeIntervalSince1970 * 1000),
      ]
      if let data = try? JSONSerialization.data(withJSONObject: payload) {
        try? data.write(to: URL(fileURLWithPath: NativeCrashHandler.filePath))
      }
      NativeCrashHandler.previousHandler?(exception)
    }

    // Alternate signal stack: a stack-overflow SIGSEGV cannot run a handler
    // on the stack that overflowed.
    let size = max(Int(SIGSTKSZ), 64 * 1024)
    if let mem = malloc(size) {
      altStack = mem
      var ss = stack_t(ss_sp: mem, ss_size: UInt(size), ss_flags: 0)
      sigaltstack(&ss, nil)
    }

    for sig in signals {
      var action = sigaction()
      action.__sigaction_u.__sa_sigaction = NativeCrashHandler.handleSignal
      action.sa_flags = SA_SIGINFO | SA_ONSTACK
      sigemptyset(&action.sa_mask)
      var previous = sigaction()
      if sigaction(sig, &action, &previous) == 0 {
        previousActions[sig] = previous
      }
    }
  }

  /// Async-signal-safe: writes a fixed JSON record with the signal number
  /// and the wall-clock second using only open/write/close/time and stack
  /// memory, then hands the signal to the previous handler (or the default
  /// action) so the process terminates as it would have without us.
  private static let handleSignal: @convention(c) (Int32, UnsafeMutablePointer<siginfo_t>?, UnsafeMutableRawPointer?) -> Void = { s, info, context in
    if let path = NativeCrashHandler.pathCString {
      let prefix: StaticString = "{\"platform\":\"ios\",\"exceptionType\":\"SIGNAL\",\"signal\":"
      let middle: StaticString = ",\"timestamp\":"
      let suffix: StaticString = "000}"
      let fd = open(path, O_WRONLY | O_CREAT | O_TRUNC, 0o644)
      if fd >= 0 {
        prefix.withUTF8Buffer { _ = write(fd, $0.baseAddress, $0.count) }
        NativeCrashHandler.writeDecimal(fd, Int(s))
        middle.withUTF8Buffer { _ = write(fd, $0.baseAddress, $0.count) }
        NativeCrashHandler.writeDecimal(fd, Int(time(nil)))
        suffix.withUTF8Buffer { _ = write(fd, $0.baseAddress, $0.count) }
        close(fd)
      }
    }
    NativeCrashHandler.chain(s, info, context)
  }

  /// Stack-only decimal formatting (no Foundation, no allocation).
  private static func writeDecimal(_ fd: Int32, _ value: Int) {
    withUnsafeTemporaryAllocation(of: UInt8.self, capacity: 24) { digits in
      var n = value < 0 ? 0 : value
      var i = 24
      repeat { i -= 1; digits[i] = UInt8(48 + n % 10); n /= 10 } while n > 0
      _ = write(fd, digits.baseAddress! + i, 24 - i)
    }
  }

  /// Runs the handler that was installed before ours, or restores the default
  /// action and re-raises. Reading a Swift dictionary here is not strictly
  /// async-signal-safe, but it is never mutated after install().
  private static func chain(_ s: Int32, _ info: UnsafeMutablePointer<siginfo_t>?, _ context: UnsafeMutableRawPointer?) {
    if var previous = previousActions[s] {
      if previous.sa_flags & SA_SIGINFO != 0 {
        if let handler = previous.__sigaction_u.__sa_sigaction {
          // Reinstall theirs first so a crash inside it cannot loop back here.
          sigaction(s, &previous, nil)
          handler(s, info, context)
          return
        }
      } else if let handler = previous.__sigaction_u.__sa_handler {
        // nil is SIG_DFL (handled below); bit pattern 1 is SIG_IGN.
        let raw = unsafeBitCast(handler, to: UnsafeRawPointer.self)
        if raw != UnsafeRawPointer(bitPattern: 1) {
          sigaction(s, &previous, nil)
          handler(s)
          return
        }
      }
    }
    signal(s, SIG_DFL)
    raise(s)
  }

  static func consume() -> String? {
    let path = filePath
    guard FileManager.default.fileExists(atPath: path),
          let text = try? String(contentsOfFile: path, encoding: .utf8) else { return nil }
    try? FileManager.default.removeItem(atPath: path)
    return text
  }
}
