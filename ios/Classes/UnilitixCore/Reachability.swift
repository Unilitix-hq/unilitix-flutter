// VENDORED from UnilitixCore 0.6.0 (Reachability.swift) by scripts/sync-ios-core.sh.
// Do not edit here; change UnilitixCore and re-run the script.

import Foundation
#if canImport(Network)
import Network
#endif

/// Whether screenshots may be uploaded under `uploadScreenshotsOnWifiOnly`.
/// A protocol so tests can switch networks.
protocol Reachability: AnyObject {
    /// True only while the device is known to be on Wi-Fi or wired Ethernet
    /// that is neither expensive (a personal hotspot) nor constrained (Low
    /// Data Mode). Unknown counts as false.
    var isOnUnmeteredNetwork: Bool { get }
}

/// `NWPathMonitor`-backed reachability. Starts as "unknown" (false) until the
/// first path update arrives.
final class PathReachability: Reachability {
    private let lock = NSLock()
    private var unmetered = false
    #if canImport(Network)
    private let monitor = NWPathMonitor()
    #endif

    init() {
        #if canImport(Network)
        monitor.pathUpdateHandler = { [weak self] path in
            let ok = path.status == .satisfied && !path.isExpensive && !path.isConstrained
                && (path.usesInterfaceType(.wifi) || path.usesInterfaceType(.wiredEthernet))
            self?.set(ok)
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
        return unmetered
    }

    private func set(_ value: Bool) {
        lock.lock(); unmetered = value; lock.unlock()
    }
}
