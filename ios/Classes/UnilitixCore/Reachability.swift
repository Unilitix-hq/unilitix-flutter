// VENDORED from UnilitixCore 0.8.0 (Reachability.swift) by scripts/sync-ios-core.sh.
// Do not edit here; change UnilitixCore and re-run the script.

import Foundation
#if canImport(Network)
import Network
#endif
#if canImport(CoreTelephony) && os(iOS) && !targetEnvironment(macCatalyst)
import CoreTelephony
#endif

/// The network as the platform reports it, before it is mapped to a
/// contract network type (`NetworkType.contract`).
struct NetworkState: Equatable {
    enum Interface: Equatable {
        case wifi, wiredEthernet, cellular, other, none
    }

    var interface: Interface
    /// The cellular radio access technology (`CTRadioAccessTechnology…`
    /// strings), nil when unknown or not on cellular.
    var radioTechnology: String?
    /// NWPath `.satisfied`.
    var satisfied: Bool
    /// A personal hotspot or other metered link.
    var expensive = false
    /// Low Data Mode.
    var constrained = false

    /// The contract network type (`SdkContract.networkTypes`).
    var contractType: String {
        NetworkType.contract(interface: interface, radioTechnology: radioTechnology, satisfied: satisfied)
    }

    /// Wi-Fi or wired, neither expensive nor constrained.
    var isUnmetered: Bool {
        satisfied && !expensive && !constrained && (interface == .wifi || interface == .wiredEthernet)
    }
}

/// Contract 1.4.0 network types (`SdkContract.networkTypeRules`): the same
/// value on events (`networkAtCapture`) on every SDK.
enum NetworkType {
    static let offline = "OFFLINE"
    static let unknown = "UNKNOWN"

    static func contract(interface: NetworkState.Interface, radioTechnology: String?, satisfied: Bool) -> String {
        guard satisfied else { return offline }
        switch interface {
        case .wifi: return "WIFI"
        case .wiredEthernet: return "ETHERNET"
        case .cellular: return cellularGeneration(radioTechnology)
        case .other: return unknown
        case .none: return offline
        }
    }

    /// `CTRadioAccessTechnology…` → 5G / 4G / 3G / 2G, CELLULAR when unknown.
    /// Matched as strings so no constant needs a newer SDK (NR is iOS 14.1).
    static func cellularGeneration(_ tech: String?) -> String {
        guard let t = tech, !t.isEmpty else { return "CELLULAR" }
        let name = t.hasPrefix("CTRadioAccessTechnology") ? String(t.dropFirst("CTRadioAccessTechnology".count)) : t
        switch name {
        case "NR", "NRNSA": return "5G"
        case "LTE": return "4G"
        case "WCDMA", "HSDPA", "HSUPA", "CDMAEVDORev0", "CDMAEVDORevA", "CDMAEVDORevB", "eHRPD": return "3G"
        case "Edge", "GPRS", "CDMA1x": return "2G"
        default: return "CELLULAR"
        }
    }
}

/// The device's network, for `networkAtCapture`/`capturedOffline`, for not
/// attempting uploads while offline, and for `uploadScreenshotsOnWifiOnly`.
/// A protocol so tests can switch networks.
protocol Reachability: AnyObject {
    /// True only while the device is known to be on Wi-Fi or wired Ethernet
    /// that is neither expensive (a personal hotspot) nor constrained (Low
    /// Data Mode). Unknown counts as false.
    var isOnUnmeteredNetwork: Bool { get }
    /// The current network, nil until the platform reported one.
    var state: NetworkState? { get }
    /// Called (on any thread) when `state` changes.
    func setChangeHandler(_ handler: @escaping () -> Void)
}

extension Reachability {
    /// Fakes that only model Wi-Fi: no state, no notifications.
    var state: NetworkState? { nil }
    func setChangeHandler(_ handler: @escaping () -> Void) {}

    /// The contract network type now; `UNKNOWN` before the first report.
    var networkType: String { state?.contractType ?? NetworkType.unknown }

    /// Known to be offline. Unknown is not offline: uploads are attempted.
    var isOffline: Bool { state.map { $0.contractType == NetworkType.offline } ?? false }
}

/// `NWPathMonitor` (interface, satisfied, expensive, constrained) plus
/// `CTTelephonyNetworkInfo` (the cellular generation). Starts as unknown
/// until the first path update arrives.
final class PathReachability: Reachability {
    private let lock = NSLock()
    private var current: NetworkState?
    private var onChange: (() -> Void)?
    #if canImport(Network)
    private let monitor = NWPathMonitor()
    #endif
    #if canImport(CoreTelephony) && os(iOS) && !targetEnvironment(macCatalyst)
    private let telephony = CTTelephonyNetworkInfo()
    #endif

    init() {
        #if canImport(Network)
        monitor.pathUpdateHandler = { [weak self] path in
            self?.update(path)
        }
        monitor.start(queue: DispatchQueue(label: "io.unilitix.reachability", qos: .utility))
        #endif
    }

    deinit {
        #if canImport(Network)
        monitor.cancel()
        #endif
    }

    var isOnUnmeteredNetwork: Bool {
        lock.lock(); defer { lock.unlock() }
        return current?.isUnmetered ?? false
    }

    var state: NetworkState? {
        lock.lock(); defer { lock.unlock() }
        return current
    }

    func setChangeHandler(_ handler: @escaping () -> Void) {
        lock.lock(); onChange = handler; lock.unlock()
    }

    #if canImport(Network)
    private func update(_ path: NWPath) {
        let interface: NetworkState.Interface
        if path.status != .satisfied {
            interface = .none
        } else if path.usesInterfaceType(.wifi) {
            interface = .wifi
        } else if path.usesInterfaceType(.wiredEthernet) {
            interface = .wiredEthernet
        } else if path.usesInterfaceType(.cellular) {
            interface = .cellular
        } else {
            interface = .other
        }
        var s = NetworkState(interface: interface, radioTechnology: nil, satisfied: path.status == .satisfied)
        s.expensive = path.isExpensive
        if #available(iOS 13.0, macOS 10.15, tvOS 13.0, watchOS 6.0, *) { s.constrained = path.isConstrained }
        if interface == .cellular { s.radioTechnology = radioTechnology() }
        lock.lock()
        let changed = current != s
        current = s
        let handler = onChange
        lock.unlock()
        if changed { handler?() }
    }
    #endif

    /// The data service's radio access technology, or any one reported.
    private func radioTechnology() -> String? {
        #if canImport(CoreTelephony) && os(iOS) && !targetEnvironment(macCatalyst)
        guard let all = telephony.serviceCurrentRadioAccessTechnology, !all.isEmpty else { return nil }
        if #available(iOS 13.0, *), let id = telephony.dataServiceIdentifier, let tech = all[id] {
            return tech
        }
        return all.values.sorted().first
        #else
        return nil
        #endif
    }
}
