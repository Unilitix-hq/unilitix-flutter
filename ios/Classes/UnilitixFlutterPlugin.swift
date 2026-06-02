import Flutter
import UIKit
import CoreTelephony

public class UnilitixPlugin: NSObject, FlutterPlugin {
  private var networkEventSink: FlutterEventSink?

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
      if let carrier = info.serviceSubscriberCellularProviders?.values.first {
        result(carrier.carrierName ?? "")
      } else {
        result("")
      }
    case "getBatteryLevel":
      UIDevice.current.isBatteryMonitoringEnabled = true
      let level = UIDevice.current.batteryLevel
      result(level < 0 ? -1.0 : Double(level))
    default:
      result(FlutterMethodNotImplemented)
    }
  }
}

extension UnilitixPlugin: FlutterStreamHandler {
  public func onListen(
    withArguments arguments: Any?,
    eventSink events: @escaping FlutterEventSink
  ) -> FlutterError? {
    networkEventSink = events
    // iOS doesn't expose WiFi vs cellular without Network.framework entitlements.
    // Emit WIFI as initial state; the Dart side falls back to polling for finer resolution.
    events("WIFI")
    return nil
  }

  public func onCancel(withArguments arguments: Any?) -> FlutterError? {
    networkEventSink = nil
    return nil
  }
}
