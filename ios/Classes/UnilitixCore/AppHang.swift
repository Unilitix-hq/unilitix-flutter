// VENDORED from UnilitixCore 0.7.0 (AppHang.swift) by scripts/sync-ios-core.sh.
// Do not edit here; change UnilitixCore and re-run the script.

import Foundation
#if canImport(UIKit) && os(iOS)
import UIKit
#endif

// App hangs, reported as the contract's `ANR` event.
//
// A watchdog thread asks the main thread to run a tiny block every
// `AppHangWatchdog.interval` (0.5 s). When one has not run within
// `UnilitixConfig.appHangTimeoutMs` (2 s), the main thread is hanging: its
// stack is captured (`ThreadSampler`) and written to `AppHangFile`, so the
// hang is reported on the next launch even if the system or the user kills
// the app before it recovers. When the main thread runs the block, the hang
// is over: the engine records one ANR (non-fatal; the session is not marked
// crashed) with the measured duration and deletes the file. One hang is
// reported once, however long it lasts.

/// One hang: what the watchdog captured when it detected it, kept in
/// `AppHangFile` while it lasts. The JSON form is the file's format.
struct AppHangRecord: Codable, Equatable {
    /// Ties the file to the hang, so recovering from one hang never deletes
    /// the file of the next.
    var id: String
    var platform: String
    /// The engine session that was running (`Engine.hangCaptureSessionId()`).
    var sessionId: String?
    /// When the main thread stopped answering, at the latest (ms since 1970).
    var startedAtMs: Int64
    /// How long the main thread was blocked: the final duration once it
    /// recovered, else the time it had been blocked at the last update of
    /// the file (updated about once a second while the hang lasts).
    var durationMs: Int64
    var timeoutMs: Int
    /// The main thread's stack when the hang was detected, in
    /// `callStackSymbols` format (`StackFormat.frame`).
    var stackTrace: String?
    /// The images of the frames in `stackTrace`, for exact symbolication.
    var debugImages: [DebugImage]
    var screen: String
    var breadcrumbs: [[String: JSONValue]]?

    init(id: String = UUID().uuidString.lowercased(), platform: String = "ios", sessionId: String?,
         startedAtMs: Int64, durationMs: Int64, timeoutMs: Int, stackTrace: String?,
         debugImages: [DebugImage] = [], screen: String = "", breadcrumbs: [[String: JSONValue]]? = nil) {
        self.id = id
        self.platform = platform
        self.sessionId = sessionId
        self.startedAtMs = startedAtMs
        self.durationMs = durationMs
        self.timeoutMs = timeoutMs
        self.stackTrace = stackTrace
        self.debugImages = debugImages
        self.screen = screen
        self.breadcrumbs = breadcrumbs
    }
}

/// A loaded binary, as the API's symbolication reads `metadata.debugImages`
/// (docs/symbolication.md in the api repo): `name` as printed in the stack's
/// frames, `uuid` its `LC_UUID`, `loadAddress` the address of its Mach-O
/// header. With it the server picks the dSYM by UUID and uses each frame's
/// absolute address.
struct DebugImage: Codable, Equatable {
    var name: String
    var uuid: String
    var loadAddress: String
    var arch: String?

    var json: JSONValue {
        var m: [String: JSONValue] = [
            "name": .string(name),
            "uuid": .string(uuid),
            "loadAddress": .string(loadAddress),
        ]
        if let a = arch { m["arch"] = .string(a) }
        return .object(m)
    }

    /// The same object for `JSONSerialization` (the crash file).
    var dictionary: [String: Any] {
        var m: [String: Any] = ["name": name, "uuid": uuid, "loadAddress": loadAddress]
        if let a = arch { m["arch"] = a }
        return m
    }

    /// `6F1E2D3C-4B5A-6978-8796-A5B4C3D2E1F0` for the 16 bytes of an
    /// `LC_UUID`; nil for any other length.
    static func formatUUID(_ bytes: [UInt8]) -> String? {
        guard bytes.count == 16 else { return nil }
        let hex = bytes.map { String(format: "%02X", $0) }
        return [hex[0..<4], hex[4..<6], hex[6..<8], hex[8..<10], hex[10..<16]]
            .map { $0.joined() }.joined(separator: "-")
    }

    /// `0x104a18000`.
    static func formatAddress(_ address: UInt) -> String {
        "0x" + String(address, radix: 16)
    }

    /// The architecture of a Mach-O header's `cputype`/`cpusubtype`.
    static func archName(cpuType: Int32, cpuSubtype: Int32) -> String? {
        switch cpuType {
        case 0x0100_000C:  // CPU_TYPE_ARM64
            return cpuSubtype & 0x00FF_FFFF == 2 ? "arm64e" : "arm64"  // CPU_SUBTYPE_ARM64E
        case 0x0100_0007:  // CPU_TYPE_X86_64
            return "x86_64"
        default:
            return nil
        }
    }
}

/// Stack lines in the format of `NSException.callStackSymbols` /
/// `Thread.callStackSymbols` (backtrace_symbols(3)), which `Fingerprint`
/// and the API's symbolication parse:
///
///     2   Shop                                0x00000001043a81c4 -[CartViewController pay:] + 52
///     3   Shop                                0x00000001043a81c4 Shop + 70084
enum StackFormat {
    static func frame(index: Int, image: String, address: UInt, symbol: String, offset: UInt) -> String {
        let hex = String(address, radix: 16)
        let address16 = String(repeating: "0", count: max(0, 16 - hex.count)) + hex
        return pad(String(index), 4) + pad(image, 35) + " 0x" + address16 + " " + symbol + " + " + String(offset)
    }

    /// The image name for a frame: the file name of its path, with any
    /// whitespace replaced by `_` (frames are parsed with the image name as
    /// one word, so "My App" would not parse).
    static func imageName(_ path: String) -> String {
        let base = (path as NSString).lastPathComponent
        let name = base.split(whereSeparator: { $0.isWhitespace }).joined(separator: "_")
        return name.isEmpty ? "???" : name
    }

    private static func pad(_ s: String, _ width: Int) -> String {
        s.count >= width ? s : s + String(repeating: " ", count: width - s.count)
    }
}

/// The pending hang, in `Application Support/Unilitix/app_hang.json` (next
/// to the engine's crash file): written when a hang is detected, deleted when
/// it is reported. A file found at launch is a hang the process did not
/// survive.
enum AppHangFile {
    static let fileName = "app_hang.json"

    static var enginePath: String {
        let dir = EventStore.defaultDirectory?.path
            ?? (NSTemporaryDirectory() as NSString).appendingPathComponent("Unilitix")
        try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        return (dir as NSString).appendingPathComponent(fileName)
    }

    @discardableResult
    static func write(_ hang: AppHangRecord, to path: String) -> Bool {
        guard let data = try? JSONEncoder().encode(hang) else { return false }
        return (try? data.write(to: URL(fileURLWithPath: path), options: .atomic)) != nil
    }

    static func read(path: String) -> AppHangRecord? {
        guard let data = FileManager.default.contents(atPath: path) else { return nil }
        return try? JSONDecoder().decode(AppHangRecord.self, from: data)
    }

    /// Reads and deletes the pending hang (an unreadable file is deleted too).
    static func consume(path: String) -> AppHangRecord? {
        guard FileManager.default.fileExists(atPath: path) else { return nil }
        defer { try? FileManager.default.removeItem(atPath: path) }
        return read(path: path)
    }

    /// Deletes the file if it still holds hang `id`.
    static func remove(path: String, id: String) {
        guard let hang = read(path: path), hang.id == id else { return }
        try? FileManager.default.removeItem(atPath: path)
    }

    static func remove(path: String) {
        try? FileManager.default.removeItem(atPath: path)
    }
}

/// The watchdog's state machine, on a monotonic clock in seconds. Each
/// `tick` gets the latest answer from the main thread (the id of the ping it
/// ran and when) and returns what to do:
///
/// - `.ping(id)`: send a new ping (only in the foreground, and only once the
///   previous one was answered);
/// - `.hangStarted(since:)`: the ping sent at `since` has waited `timeout`;
///   reported once per hang (debounced until the main thread answers);
/// - `.hangEnded(since:duration:)`: the main thread answered after a hang.
///
/// A ping left unanswered while the app is in the background, or across a
/// gap of `timeout` or more between two ticks (the process was suspended or
/// the watchdog itself did not run), is dropped instead of reported.
struct AppHangTracker {
    enum Action: Equatable {
        case ping(Int)
        case hangStarted(since: Double)
        case hangEnded(since: Double, duration: Double)
    }

    let timeout: Double
    private(set) var hanging = false
    private(set) var pending: (id: Int, sentAt: Double)?
    private var lastPingId = 0
    private var lastTick: Double?

    init(timeout: Double) {
        self.timeout = timeout
    }

    mutating func tick(now: Double, answer: (id: Int, at: Double)?, foreground: Bool) -> [Action] {
        let stalled = lastTick.map { now - $0 >= timeout } ?? false
        lastTick = now
        var out: [Action] = []
        if let p = pending {
            if let a = answer, a.id == p.id {
                if hanging { out.append(.hangEnded(since: p.sentAt, duration: max(0, a.at - p.sentAt))) }
                hanging = false
                pending = nil
            } else if hanging {
                return out  // still blocked: already reported
            } else if stalled || !foreground {
                pending = nil  // says nothing about the main thread
            } else if now - p.sentAt >= timeout {
                hanging = true
                out.append(.hangStarted(since: p.sentAt))
                return out
            } else {
                return out  // waiting for the answer
            }
        }
        if foreground {
            lastPingId += 1
            pending = (lastPingId, now)
            out.append(.ping(lastPingId))
        }
        return out
    }
}

/// Watches the main thread for `engine` (see the top of this file). `tick`
/// runs on the watchdog thread; `answer` on the main thread; the rest is set
/// up before the thread starts. Tests drive `tick` and `answer` directly.
final class AppHangWatchdog {
    struct Capture {
        var stack: String?
        var images: [DebugImage]
    }

    /// Pings at most this often (more often for timeouts under 2 s).
    static let maxInterval: TimeInterval = 0.5
    /// While a hang lasts, its file's duration is brought up to date this often.
    static let fileUpdateInterval: TimeInterval = 1

    let timeoutMs: Int
    let interval: TimeInterval
    /// Sends ping `id` to the main thread, which calls `answer(id, at:)`.
    var ping: (Int) -> Void = { _ in }

    private let engine: Engine
    private let path: String?
    private let capture: () -> Capture
    private let isDebugged: () -> Bool
    private let wallClock: () -> Date

    private let lock = NSLock()
    private var lastAnswer: (id: Int, at: Double)?
    private var foreground = true

    // Watchdog thread only.
    private var tracker: AppHangTracker
    private var current: AppHangRecord?
    private var currentSince: Double = 0
    private var lastFileUpdate: Double = 0

    init(engine: Engine, timeoutMs: Int, path: String?,
         capture: @escaping () -> Capture,
         isDebugged: @escaping () -> Bool,
         wallClock: @escaping () -> Date = Date.init) {
        self.engine = engine
        self.timeoutMs = max(1, timeoutMs)
        self.path = path
        self.capture = capture
        self.isDebugged = isDebugged
        self.wallClock = wallClock
        let timeout = Double(self.timeoutMs) / 1000
        interval = min(AppHangWatchdog.maxInterval, max(0.05, timeout / 4))
        tracker = AppHangTracker(timeout: timeout)
    }

    /// Seconds on a clock that does not jump with the wall clock.
    static func monotonicNow() -> Double {
        Double(DispatchTime.now().uptimeNanoseconds) / 1_000_000_000
    }

    /// The main thread ran ping `id` at `at` (monotonic seconds).
    func answer(_ id: Int, at: Double) {
        lock.lock(); lastAnswer = (id, at); lock.unlock()
    }

    /// The app moved to the background (false) or foreground (true). Hangs
    /// are only watched in the foreground.
    func setForeground(_ value: Bool) {
        lock.lock(); foreground = value; lock.unlock()
    }

    var isHanging: Bool { tracker.hanging }

    func tick(now: Double) {
        lock.lock()
        let answer = lastAnswer
        let fg = foreground
        lock.unlock()
        for action in tracker.tick(now: now, answer: answer, foreground: fg) {
            switch action {
            case .ping(let id):
                ping(id)
            case .hangStarted(let since):
                hangStarted(since: since, now: now)
            case .hangEnded(_, let duration):
                hangEnded(duration: duration)
            }
        }
        if tracker.hanging, var hang = current, now - lastFileUpdate >= AppHangWatchdog.fileUpdateInterval {
            hang.durationMs = AppHangWatchdog.ms(now - currentSince)
            current = hang
            lastFileUpdate = now
            if let p = path { AppHangFile.write(hang, to: p) }
        }
    }

    private func hangStarted(since: Double, now: Double) {
        current = nil
        // Paused at a breakpoint is not a hang.
        if isDebugged() { return }
        // Consent denied, or no session yet: nothing may be recorded.
        guard let sessionId = engine.hangCaptureSessionId() else { return }
        let c = capture()
        let blocked = now - since
        let startedAt = wallClock().addingTimeInterval(-blocked)
        let hang = AppHangRecord(
            sessionId: sessionId,
            startedAtMs: Int64((startedAt.timeIntervalSince1970 * 1000).rounded()),
            durationMs: AppHangWatchdog.ms(blocked),
            timeoutMs: timeoutMs,
            stackTrace: c.stack.flatMap { $0.isEmpty ? nil : String($0.prefix(CrashFile.maxStackLength)) },
            debugImages: c.images,
            screen: engine.breadcrumbs.lastScreen,
            breadcrumbs: engine.breadcrumbs.toWire())
        current = hang
        currentSince = since
        lastFileUpdate = now
        if let p = path { AppHangFile.write(hang, to: p) }
    }

    private func hangEnded(duration: Double) {
        guard var hang = current else { return }
        current = nil
        hang.durationMs = AppHangWatchdog.ms(duration)
        let ended = hang
        let e = engine
        e.queue.async { e.recordAppHang(ended) }
    }

    static func ms(_ seconds: Double) -> Int64 {
        Int64((max(0, seconds) * 1000).rounded())
    }
}

#if canImport(Darwin)
extension AppHangWatchdog {
    private static let installLock = NSLock()
    private static var installed = false
    private static var shared: AppHangWatchdog?
    private static var observers: [NSObjectProtocol] = []

    /// Starts watching the main thread for `engine`, once per process (later
    /// calls are ignored). `timeoutMs` <= 0 does nothing. Call after the
    /// engine was started; any thread (the setup itself runs on main, on its
    /// next run-loop pass). Hangs are recorded only while the engine has a
    /// session and consent is not denied.
    static func install(_ engine: Engine, timeoutMs: Int) {
        guard timeoutMs > 0 else { return }
        installLock.lock()
        let first = !installed
        installed = true
        installLock.unlock()
        guard first else { return }
        // Always async: `start` may run before UIApplication exists.
        DispatchQueue.main.async { begin(engine, timeoutMs: timeoutMs) }
    }

    /// Main thread: the main thread's identity and stack bounds are read
    /// here, for `ThreadSampler` to walk its stack from the watchdog thread.
    private static func begin(_ engine: Engine, timeoutMs: Int) {
        let main = ThreadSampler.Target.current()
        let w = AppHangWatchdog(
            engine: engine, timeoutMs: timeoutMs, path: engine.appHangFilePath,
            capture: {
                let s = ThreadSampler.symbolicate(ThreadSampler.backtrace(of: main))
                return Capture(stack: s.stack, images: s.images)
            },
            isDebugged: ThreadSampler.isDebuggerAttached)
        w.ping = { [weak w] id in
            DispatchQueue.main.async { w?.answer(id, at: AppHangWatchdog.monotonicNow()) }
        }
        #if canImport(UIKit) && os(iOS)
        w.setForeground(UIApplication.shared.applicationState != .background)
        let nc = NotificationCenter.default
        observers = [
            nc.addObserver(forName: UIApplication.didEnterBackgroundNotification, object: nil, queue: nil) { [weak w] _ in
                w?.setForeground(false)
            },
            nc.addObserver(forName: UIApplication.willEnterForegroundNotification, object: nil, queue: nil) { [weak w] _ in
                w?.setForeground(true)
            },
        ]
        #endif
        shared = w
        let thread = Thread { w.run() }
        thread.name = "io.unilitix.app-hang-watchdog"
        thread.qualityOfService = .userInitiated
        thread.start()
    }

    /// The watchdog thread's loop, for the life of the process.
    private func run() {
        while true {
            autoreleasepool { tick(now: AppHangWatchdog.monotonicNow()) }
            Thread.sleep(forTimeInterval: interval)
        }
    }
}
#endif
