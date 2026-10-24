// VENDORED from UnilitixCore 0.6.0 (Breadcrumbs.swift) by scripts/sync-ios-core.sh.
// Do not edit here; change UnilitixCore and re-run the script.

import Foundation

/// The trail attached to every CRASH and EXCEPTION: the last
/// `SdkContract.maxBreadcrumbs` events plus anything the app adds with
/// `Unilitix.addBreadcrumb`. Thread-safe.
final class Breadcrumbs {
    static let maxSize = SdkContract.maxBreadcrumbs

    private struct Crumb {
        let type: String
        let screen: String
        let message: String?
        let timestamp: Int64
    }

    private var buffer: [Crumb] = []
    private let lock = NSLock()

    func add(type: String, screen: String, message: String? = nil, at date: Date = Date()) {
        lock.lock(); defer { lock.unlock() }
        buffer.append(Crumb(type: type, screen: screen, message: message,
                            timestamp: Int64(date.timeIntervalSince1970 * 1000)))
        if buffer.count > Breadcrumbs.maxSize {
            buffer.removeFirst(buffer.count - Breadcrumbs.maxSize)
        }
    }

    var count: Int {
        lock.lock(); defer { lock.unlock() }
        return buffer.count
    }

    /// The screen of the most recent breadcrumb that had one.
    var lastScreen: String {
        lock.lock(); defer { lock.unlock() }
        return buffer.last(where: { !$0.screen.isEmpty })?.screen ?? ""
    }

    /// Wire form: the ingest contract's `breadcrumbs` array.
    func toWire() -> [[String: JSONValue]] {
        lock.lock(); defer { lock.unlock() }
        return buffer.map { c in
            var m: [String: JSONValue] = [
                "type": .string(c.type),
                "screen": .string(c.screen),
                "timestamp": .int(c.timestamp),
            ]
            if let message = c.message { m["message"] = .string(message) }
            return m
        }
    }

    func clear() {
        lock.lock(); defer { lock.unlock() }
        buffer.removeAll()
    }
}
