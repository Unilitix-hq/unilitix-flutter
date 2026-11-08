// VENDORED from UnilitixCore 0.8.0 (TerminationTracker.swift) by scripts/sync-ios-core.sh.
// Do not edit here; change UnilitixCore and re-run the script.

import Foundation
#if canImport(MetricKit) && os(iOS) && !targetEnvironment(macCatalyst)
import MetricKit
#endif

/// What the previous run looked like when it was last seen, persisted as a
/// small JSON file next to the event queue.
struct RunState: Codable, Equatable {
    var appVersion: String
    var buildNumber: String
    var osVersion: String
    /// Wall-clock time minus system uptime, in seconds since 1970: changes
    /// when the device reboots. Never leaves the device.
    var bootTime: Double
    var foreground = false
    var cleanExit = false
    var crashed = false
    var debugger = false
    var sessionId: String?
    /// Last update, milliseconds since 1970.
    var updatedAtMs: Int64 = 0
    var memoryWarningAtMs: Int64?
}

/// An abnormal end of the previous run, inferred on this launch.
struct InferredTermination: Equatable {
    enum Kind: String {
        case outOfMemory = "oom"
        case watchdog
    }

    var kind: Kind
    var sessionId: String?
    /// When the previous run was last seen alive.
    var lastSeenAt: Date
    var screen: String?
    /// iOS sent a memory warning shortly before.
    var memoryWarning: Bool
    /// The latest MetricKit foreground exit counts (iOS 14+), when known.
    var metricKit: [String: JSONValue]?
}

/// Infers out-of-memory (jetsam) and watchdog terminations, which no
/// in-process handler can catch: on launch, the previous run ended in the
/// foreground with no crash record, no clean exit (`willTerminate`), no app
/// or OS update, no reboot in between, and no debugger attached. The same
/// heuristic as Bugsnag and Sentry. A hang the app did not survive is
/// reported as an `ANR` instead (`appTerminated`).
///
/// MetricKit (`MXAppExitMetric`, iOS 14+) cannot attribute one exit to one
/// run (its payloads are daily), so it only refines the kind: when the
/// cumulative foreground watchdog exit count grew since the previous payload
/// and the memory-limit count did not, the termination is reported as a
/// watchdog one; the counts go into the event's metadata.
///
/// Thread-safe. The state file is written on each transition (a few hundred
/// bytes, atomically).
final class TerminationTracker {
    private let path: String?
    private let lock = NSLock()
    private var state: RunState
    private let now: () -> Date
    private let uptime: () -> TimeInterval
    private let debuggerAttached: () -> Bool
    private var began = false
    /// Memory warnings this long before the end count.
    static let memoryWarningWindow: TimeInterval = 60
    /// A boot-time estimate that moved more than this means a reboot.
    static let rebootTolerance: TimeInterval = 120

    init(path: String?, device: DeviceInfo,
         now: @escaping () -> Date = Date.init,
         uptime: @escaping () -> TimeInterval = { ProcessInfo.processInfo.systemUptime },
         debuggerAttached: @escaping () -> Bool = TerminationTracker.isDebuggerAttached) {
        self.path = path
        self.now = now
        self.uptime = uptime
        self.debuggerAttached = debuggerAttached
        state = RunState(appVersion: device.appVersion, buildNumber: device.buildNumber,
                         osVersion: device.osVersion, bootTime: 0)
    }

    /// `Application Support/Unilitix/run_state.json`.
    static var enginePath: String? {
        guard let dir = EventStore.defaultDirectory else { return nil }
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("run_state.json").path
    }

    /// Reads the previous run's state, judges it, and starts this run's
    /// (in the background until `setForeground(true)`). Once per process;
    /// later calls return nil. `crashRecordFound`/`hangRecordFound`: the
    /// engine found a crash or hang record of the previous run.
    func begin(crashRecordFound: Bool, hangRecordFound: Bool) -> InferredTermination? {
        lock.lock()
        defer { lock.unlock() }
        guard !began else { return nil }
        began = true
        let previous = readLocked()
        let t = now()
        state.bootTime = t.timeIntervalSince1970 - uptime()
        state.debugger = debuggerAttached()
        state.updatedAtMs = TerminationTracker.ms(t)
        let current = state
        writeLocked()
        guard let p = previous else { return nil }
        guard let kind = TerminationTracker.judge(previous: p, current: current,
                                                  crashRecordFound: crashRecordFound,
                                                  hangRecordFound: hangRecordFound) else { return nil }
        let lastSeen = Date(timeIntervalSince1970: Double(p.updatedAtMs) / 1000)
        var warned = false
        if let w = p.memoryWarningAtMs {
            warned = Double(p.updatedAtMs - w) / 1000 <= TerminationTracker.memoryWarningWindow
        }
        var result = InferredTermination(kind: kind, sessionId: p.sessionId, lastSeenAt: lastSeen,
                                         screen: nil, memoryWarning: warned, metricKit: nil)
        if let exits = MetricKitExits.latest() {
            result.metricKit = exits.counts.mapValues { JSONValue.int(Int64($0)) }
            if exits.watchdogGrew && !exits.memoryGrew && !warned { result.kind = .watchdog }
        }
        return result
    }

    /// The rule, pure: nil when the previous run ended normally or the end
    /// cannot be judged.
    static func judge(previous p: RunState, current c: RunState,
                      crashRecordFound: Bool, hangRecordFound: Bool) -> InferredTermination.Kind? {
        if p.cleanExit || p.crashed || crashRecordFound || hangRecordFound { return nil }
        if !p.foreground || p.debugger { return nil }
        if p.appVersion != c.appVersion || p.buildNumber != c.buildNumber { return nil }  // app update
        if p.osVersion != c.osVersion { return nil }  // OS update
        if p.bootTime == 0 || abs(p.bootTime - c.bootTime) > rebootTolerance { return nil }  // reboot
        return .outOfMemory
    }

    func setForeground(_ foreground: Bool) { update { $0.foreground = foreground } }
    func setSession(_ id: String?) { update { $0.sessionId = id } }
    /// A crash was recorded: whatever ends this run, it is not an OOM.
    func markCrashed() { update { $0.crashed = true } }
    /// `UIApplication.willTerminateNotification`.
    func markCleanExit() { update { $0.cleanExit = true } }
    func memoryWarning() {
        let t = TerminationTracker.ms(now())
        update { $0.memoryWarningAtMs = t }
    }

    /// The current run's state (tests).
    var current: RunState {
        lock.lock(); defer { lock.unlock() }
        return state
    }

    private func update(_ change: (inout RunState) -> Void) {
        lock.lock()
        defer { lock.unlock() }
        let before = state
        change(&state)
        state.updatedAtMs = TerminationTracker.ms(now())
        // Only after `begin`: before, the file still holds the previous run.
        if began && state != before { writeLocked() }
    }

    private func readLocked() -> RunState? {
        guard let p = path, let data = FileManager.default.contents(atPath: p) else { return nil }
        return try? JSONDecoder().decode(RunState.self, from: data)
    }

    private func writeLocked() {
        guard let p = path, let data = try? JSONEncoder().encode(state) else { return }
        try? data.write(to: URL(fileURLWithPath: p), options: .atomic)
    }

    static func ms(_ d: Date) -> Int64 { Int64((d.timeIntervalSince1970 * 1000).rounded()) }

    static func isDebuggerAttached() -> Bool {
        #if canImport(Darwin)
        return ThreadSampler.isDebuggerAttached()
        #else
        return false
        #endif
    }
}

/// The latest MetricKit foreground exit counts, kept between launches.
enum MetricKitExits {
    struct Snapshot: Codable, Equatable {
        var counts: [String: Int]
        var memoryGrew: Bool
        var watchdogGrew: Bool
    }

    private static let lock = NSLock()
    static var path: String? {
        EventStore.defaultDirectory?.appendingPathComponent("metrickit_exits.json").path
    }

    static func latest() -> Snapshot? {
        lock.lock(); defer { lock.unlock() }
        guard let p = path, let data = FileManager.default.contents(atPath: p) else { return nil }
        return try? JSONDecoder().decode(Snapshot.self, from: data)
    }

    /// Stores new cumulative counts and whether the memory-limit and
    /// watchdog counts grew since the previous ones.
    static func record(_ counts: [String: Int]) {
        lock.lock(); defer { lock.unlock() }
        guard let p = path else { return }
        var previous: [String: Int] = [:]
        if let data = FileManager.default.contents(atPath: p),
           let s = try? JSONDecoder().decode(Snapshot.self, from: data) { previous = s.counts }
        let grew = { (key: String) -> Bool in (counts[key] ?? 0) > (previous[key] ?? 0) }
        let snap = Snapshot(counts: counts, memoryGrew: grew("memoryResourceLimit"), watchdogGrew: grew("appWatchdog"))
        if let data = try? JSONEncoder().encode(snap) {
            try? data.write(to: URL(fileURLWithPath: p), options: .atomic)
        }
    }

    /// Subscribes to MetricKit payloads (iOS 14+, apps only). Once.
    static func install() {
        #if canImport(MetricKit) && os(iOS) && !targetEnvironment(macCatalyst)
        if #available(iOS 14.0, *) {
            MetricKitSubscriber.installOnce()
        }
        #endif
    }
}

#if canImport(MetricKit) && os(iOS) && !targetEnvironment(macCatalyst)
@available(iOS 14.0, *)
final class MetricKitSubscriber: NSObject, MXMetricManagerSubscriber {
    private static let lock = NSLock()
    private static var shared: MetricKitSubscriber?

    static func installOnce() {
        lock.lock(); defer { lock.unlock() }
        guard shared == nil else { return }
        let s = MetricKitSubscriber()
        shared = s
        MXMetricManager.shared.add(s)
    }

    func didReceive(_ payloads: [MXMetricPayload]) {
        for payload in payloads {
            guard let exits = payload.applicationExitMetrics?.foregroundExitData else { continue }
            MetricKitExits.record([
                "normal": exits.cumulativeNormalAppExitCount,
                "memoryResourceLimit": exits.cumulativeMemoryResourceLimitExitCount,
                "appWatchdog": exits.cumulativeAppWatchdogExitCount,
                "badAccess": exits.cumulativeBadAccessExitCount,
                "illegalInstruction": exits.cumulativeIllegalInstructionExitCount,
                "abnormal": exits.cumulativeAbnormalExitCount,
            ])
        }
    }
}
#endif
