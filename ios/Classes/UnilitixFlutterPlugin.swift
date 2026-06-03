import Flutter
import UIKit
import CoreTelephony
import Network

public class UnilitixPlugin: NSObject, FlutterPlugin {
  private var networkEventSink: FlutterEventSink?
  private var pathMonitor: NWPathMonitor?
  private let monitorQueue = DispatchQueue(label: "com.unilitix.network")

  public static func register(with registrar: FlutterPluginRegistrar) {
    let methodChannel = FlutterMethodChannel(
      name: "com.unilitix/sdk",
      binaryMessenger: registrar.messenger()
    )
    let instance = UnilitixPlugin()
    registrar.addMethodCallDelegate(instance, channel: methodChannel)

    let eventChannel = FlutterEventChannel(
      name: "com.unilitix/network",
      binaryMessenger: registrar.messenger()
    )
    eventChannel.setStreamHandler(instance)
  }

  public func handle(_ call: FlutterMethodCall, result: @escaping FlutterResult) {
    switch call.method {
    case "getCarrierName":
      let info = CTTelephonyNetworkInfo()
      let carriers = info.serviceSubscriberCellularProviders ?? [:]
      let orderedKeys = info.serviceOrder ?? Array(carriers.keys)
      let carrier = orderedKeys.compactMap { carriers[$0] }.first
      result(carrier?.carrierName ?? "")

    case "getBatteryLevel":
      UIDevice.current.isBatteryMonitoringEnabled = true
      let level = UIDevice.current.batteryLevel
      UIDevice.current.isBatteryMonitoringEnabled = false // cleanup
      result(level < 0 ? -1.0 : Double(level))

    default:
      result(FlutterMethodNotImplemented)
    }
  }

  private func resolveNetworkType(_ path: NWPath) -> String {
    guard path.status == .satisfied else { return "OFFLINE" }

    if path.usesInterfaceType(.wifi) { return "WIFI" }
    if path.usesInterfaceType(.wiredEthernet) { return "ETHERNET" }

    if path.usesInterfaceType(.cellular) {
      // Resolve cellular generation via CTTelephonyNetworkInfo
      let info = CTTelephonyNetworkInfo()
      let radioTech = info.serviceCurrentRadioAccessTechnology?.values.first ?? ""
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
           CTRadioAccessTechnologyHSPA,
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
    // Emit current state immediately
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
