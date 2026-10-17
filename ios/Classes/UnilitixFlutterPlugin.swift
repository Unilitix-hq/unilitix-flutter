import Flutter
import UIKit
import CoreTelephony
import Network

public class UnilitixPlugin: NSObject, FlutterPlugin {
  private var networkEventSink: FlutterEventSink?
  private var pathMonitor: NWPathMonitor?
  private let monitorQueue = DispatchQueue(label: "com.unilitix.network")
  /// Serial queue for downscale / occlusion / JPEG work, off the main thread.
  private let imageQueue = DispatchQueue(label: "com.unilitix.image", qos: .utility)

  public static func register(with registrar: FlutterPluginRegistrar) {
    let instance = UnilitixPlugin()

    let methodChannel = FlutterMethodChannel(
      name: "com.unilitix/sdk",
      binaryMessenger: registrar.messenger()
    )
    registrar.addMethodCallDelegate(instance, channel: methodChannel)

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

    default:
      result(FlutterMethodNotImplemented)
    }
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
// that the SDK reports as a fatal CRASH on the next launch. Signal handlers
// only call async-signal-safe functions (open/write/close) on a pre-built
// buffer; the richer NSException path may allocate because the runtime is
// still consistent at that point.

enum NativeCrashHandler {
  private static let fileName = "unilitix_native_crash.json"
  private static var previousHandler: (@convention(c) (NSException) -> Void)?
  private static var installed = false
  private static let signals: [Int32] = [SIGABRT, SIGBUS, SIGFPE, SIGILL, SIGSEGV, SIGTRAP]
  /// Path resolved once at install so the signal handler never touches
  /// Foundation (which is not async-signal-safe).
  private static var pathCString: UnsafeMutablePointer<CChar>?

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

    for sig in signals {
      signal(sig, NativeCrashHandler.handleSignal)
    }
  }

  /// Async-signal-safe: writes a fixed JSON record with the signal number
  /// using only open/write/close and stack memory.
  private static let handleSignal: @convention(c) (Int32) -> Void = { s in
    guard let path = NativeCrashHandler.pathCString else {
      signal(s, SIG_DFL); raise(s); return
    }
    let prefix: StaticString = "{\"platform\":\"ios\",\"exceptionType\":\"SIGNAL\",\"signal\":"
    let suffix: StaticString = "}"
    let fd = open(path, O_WRONLY | O_CREAT | O_TRUNC, 0o644)
    if fd >= 0 {
      prefix.withUTF8Buffer { _ = write(fd, $0.baseAddress, $0.count) }
      // Stack-only decimal formatting of the signal number.
      withUnsafeTemporaryAllocation(of: UInt8.self, capacity: 12) { digits in
        var n = Int(s), i = 12
        repeat { i -= 1; digits[i] = UInt8(48 + n % 10); n /= 10 } while n > 0
        _ = write(fd, digits.baseAddress! + i, 12 - i)
      }
      suffix.withUTF8Buffer { _ = write(fd, $0.baseAddress, $0.count) }
      close(fd)
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
