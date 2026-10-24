import Flutter
import Foundation
import UIKit

// iOS app hangs (ANR) for the Flutter plugin.
//
// UnilitixCore's `AppHangWatchdog` reports to its `Engine`, which this plugin
// does not have (Dart is the engine here), so this file is the plugin's own
// thin loop around UnilitixCore's pieces: `AppHangTracker` (the detection
// state machine), `ThreadSampler` (main-thread stack, debug images, debugger
// check), `AppHangRecord` (what a hang captured) and `Engine.appHangEvent`
// (message, fingerprint and metadata of the `ANR` event, so a hang reads the
// same as one from the native iOS SDK).
//
// Flow: the watchdog thread pings the main thread every `interval`. A ping
// left unanswered for `timeoutMs` while the app is in the foreground is a
// hang: the main thread's stack is captured and written to `path`
// (`Application Support/unilitix_app_hang.json`, next to `CrashFile`'s
// record), and the file's duration is brought up to date about once a
// second. When the main thread answers again the hang is over: the file is
// marked recovered and the record is sent to Dart on the
// `com.unilitix/app_hang` channel (`onAppHang`). Dart answers true once it
// has dealt with it (reported, held for consent, or dropped), and the file is
// deleted. A hang the process did not survive, or one Dart never
// acknowledged, stays in the file and `readNativeCrash` returns it on the
// next launch (`appTerminated` unless it had recovered). The record's id is
// also the event id, so the server keeps one event even if both paths ran.
//
// All of it is the plugin's (UnilitixCore is vendored unchanged).

/// What the plugin keeps in its hang file: UnilitixCore's record, and
/// whether the main thread recovered (the hang was then waiting for Dart).
struct PluginAppHang: Codable, Equatable {
  var hang: AppHangRecord
  var recovered: Bool
}

enum PluginAppHangFile {
  static let fileName = "unilitix_app_hang.json"

  /// `Application Support/unilitix_app_hang.json`, next to
  /// `CrashFile.defaultPath`. Apart from `AppHangFile.enginePath`, so an app
  /// that also embeds the native SDK never reports the other's hang.
  static var defaultPath: String {
    let dir = NSSearchPathForDirectoriesInDomains(.applicationSupportDirectory, .userDomainMask, true).first
      ?? NSTemporaryDirectory()
    try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
    return (dir as NSString).appendingPathComponent(fileName)
  }

  @discardableResult
  static func write(_ value: PluginAppHang, to path: String) -> Bool {
    guard let data = try? JSONEncoder().encode(value) else { return false }
    return (try? data.write(to: URL(fileURLWithPath: path), options: .atomic)) != nil
  }

  static func read(path: String) -> PluginAppHang? {
    guard let data = FileManager.default.contents(atPath: path) else { return nil }
    return try? JSONDecoder().decode(PluginAppHang.self, from: data)
  }

  /// Deletes the file if it still holds hang `id`.
  static func remove(path: String, id: String) {
    guard let value = read(path: path), value.hang.id == id else { return }
    try? FileManager.default.removeItem(atPath: path)
  }

  /// The record Dart reads (`readNativeCrash`, `onAppHang`), as JSON:
  /// `type` `ANR`, `platform`, `id` (the event id), `timestamp` (when the
  /// hang began, ms since 1970), `exceptionMessage`, `stackTrace`,
  /// `fingerprint` and `metadata` (`fingerprint`, `platform`,
  /// `hangDurationMs`, `appHangTimeoutMs`, `appTerminated`, `debugImages`),
  /// all as `Engine.appHangEvent` builds them for the native SDK.
  static func record(_ value: PluginAppHang) -> String? {
    let event = Engine.appHangEvent(value.hang, terminated: !value.recovered)
    var r: [String: Any] = [
      "type": "ANR",
      "exceptionType": "ANR",
      "platform": value.hang.platform,
      "id": value.hang.id,
      "timestamp": value.hang.startedAtMs,
    ]
    if let m = event.exceptionMessage { r["exceptionMessage"] = m }
    if let s = event.stackTrace { r["stackTrace"] = s }
    if let metadata = event.metadata,
       let data = try? JSONEncoder().encode(metadata),
       let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] {
      r["metadata"] = object
      if let fp = object["fingerprint"] as? String { r["fingerprint"] = fp }
    }
    guard let out = try? JSONSerialization.data(withJSONObject: r, options: [.sortedKeys]) else { return nil }
    return String(data: out, encoding: .utf8)
  }
}

/// The watchdog: `tick` runs on its thread, `answer` on the main thread,
/// the setters on any thread. Mirrors `AppHangWatchdog`, minus the engine.
final class PluginAppHangWatchdog {
  let timeoutMs: Int
  let interval: TimeInterval
  let path: String
  /// Sends ping `id` to the main thread, which calls `answer(id, at:)`.
  var ping: (Int) -> Void = { _ in }
  /// A hang was detected (watchdog thread), before its file is written.
  var onStarted: (String) -> Void = { _ in }
  /// A hang ended (watchdog thread); its file is marked recovered.
  var onRecovered: (AppHangRecord) -> Void = { _ in }

  private let capture: () -> (stack: String?, images: [DebugImage])
  private let isDebugged: () -> Bool
  private let wallClock: () -> Date

  private let lock = NSLock()
  private var lastAnswer: (id: Int, at: Double)?
  private var foreground = true
  private var captureAllowed = true

  // Watchdog thread only.
  private var tracker: AppHangTracker
  private var current: AppHangRecord?
  private var currentSince: Double = 0
  private var lastFileUpdate: Double = 0

  init(timeoutMs: Int, path: String,
       capture: @escaping () -> (stack: String?, images: [DebugImage]),
       isDebugged: @escaping () -> Bool,
       wallClock: @escaping () -> Date = Date.init) {
    self.timeoutMs = max(1, timeoutMs)
    self.path = path
    self.capture = capture
    self.isDebugged = isDebugged
    self.wallClock = wallClock
    let timeout = Double(self.timeoutMs) / 1000
    interval = min(AppHangWatchdog.maxInterval, max(0.05, timeout / 4))
    tracker = AppHangTracker(timeout: timeout)
  }

  func answer(_ id: Int, at: Double) {
    lock.lock(); lastAnswer = (id, at); lock.unlock()
  }

  func setForeground(_ value: Bool) {
    lock.lock(); foreground = value; lock.unlock()
  }

  /// False while consent is denied: a hang is then not captured at all.
  func setCaptureAllowed(_ value: Bool) {
    lock.lock(); captureAllowed = value; lock.unlock()
  }

  func tick(now: Double) {
    lock.lock()
    let answer = lastAnswer
    let fg = foreground
    let allowed = captureAllowed
    lock.unlock()
    for action in tracker.tick(now: now, answer: answer, foreground: fg) {
      switch action {
      case .ping(let id):
        ping(id)
      case .hangStarted(let since):
        hangStarted(since: since, now: now, allowed: allowed)
      case .hangEnded(_, let duration):
        hangEnded(duration: duration)
      }
    }
    if tracker.hanging, var hang = current, now - lastFileUpdate >= AppHangWatchdog.fileUpdateInterval {
      hang.durationMs = AppHangWatchdog.ms(now - currentSince)
      current = hang
      lastFileUpdate = now
      PluginAppHangFile.write(PluginAppHang(hang: hang, recovered: false), to: path)
    }
  }

  private func hangStarted(since: Double, now: Double, allowed: Bool) {
    current = nil
    // Consent denied: nothing may be recorded. Paused at a breakpoint is not
    // a hang.
    guard allowed, !isDebugged() else { return }
    let c = capture()
    let blocked = now - since
    let startedAt = wallClock().addingTimeInterval(-blocked)
    let hang = AppHangRecord(
      sessionId: nil,  // Dart attributes it (live: current session; later: by timestamp)
      startedAtMs: Int64((startedAt.timeIntervalSince1970 * 1000).rounded()),
      durationMs: AppHangWatchdog.ms(blocked),
      timeoutMs: timeoutMs,
      stackTrace: c.stack.flatMap { $0.isEmpty ? nil : String($0.prefix(CrashFile.maxStackLength)) },
      debugImages: c.images)
    onStarted(hang.id)
    current = hang
    currentSince = since
    lastFileUpdate = now
    PluginAppHangFile.write(PluginAppHang(hang: hang, recovered: false), to: path)
  }

  private func hangEnded(duration: Double) {
    guard var hang = current else { return }
    current = nil
    hang.durationMs = AppHangWatchdog.ms(duration)
    PluginAppHangFile.write(PluginAppHang(hang: hang, recovered: true), to: path)
    onRecovered(hang)
  }
}

/// The process's hang monitor: owns the watchdog, delivers hangs to Dart and
/// serves the file to `readNativeCrash`. Main thread only, except where noted.
final class UnilitixAppHangs {
  static let shared = UnilitixAppHangs()

  let path = PluginAppHangFile.defaultPath
  private var watchdog: PluginAppHangWatchdog?
  private var observers: [NSObjectProtocol] = []
  /// The channel of the engine that configured detection last.
  private weak var channel: FlutterMethodChannel?
  /// The hang sent to Dart and not yet acknowledged.
  private var inFlightId: String?
  /// Ids of hangs detected in this process (the watchdog thread inserts,
  /// before writing the file).
  private let idsLock = NSLock()
  private var ownIds = Set<String>()

  /// `configureAppHang` from Dart (`Unilitix.init`, after it read the earlier
  /// launch's records, and on every consent change). The first call with
  /// `timeoutMs` > 0 starts the watchdog for the life of the process; later
  /// calls only update `captureAllowed` and the channel, and resend a hang
  /// Dart did not acknowledge (after a hot restart, say).
  func configure(timeoutMs: Int, captureAllowed: Bool, channel: FlutterMethodChannel) {
    self.channel = channel
    if watchdog == nil, timeoutMs > 0 { start(timeoutMs: timeoutMs) }
    watchdog?.setCaptureAllowed(captureAllowed)
    if let pending = PluginAppHangFile.read(path: path), pending.recovered, owns(pending.hang.id) {
      deliver(id: pending.hang.id)
    }
  }

  private func start(timeoutMs: Int) {
    let main = ThreadSampler.Target.current()
    let w = PluginAppHangWatchdog(
      timeoutMs: timeoutMs, path: path,
      capture: {
        let s = ThreadSampler.symbolicate(ThreadSampler.backtrace(of: main))
        return (s.stack, s.images)
      },
      isDebugged: ThreadSampler.isDebuggerAttached)
    w.ping = { [weak w] id in
      DispatchQueue.main.async { w?.answer(id, at: AppHangWatchdog.monotonicNow()) }
    }
    w.onStarted = { [weak self] id in self?.markOwn(id) }
    w.onRecovered = { [weak self] hang in
      DispatchQueue.main.async { self?.deliver(id: hang.id) }
    }
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
    watchdog = w
    let thread = Thread {
      while true {
        autoreleasepool { w.tick(now: AppHangWatchdog.monotonicNow()) }
        Thread.sleep(forTimeInterval: w.interval)
      }
    }
    thread.name = "io.unilitix.flutter.app-hang-watchdog"
    thread.qualityOfService = .userInitiated
    thread.start()
  }

  private func markOwn(_ id: String) {
    idsLock.lock(); ownIds.insert(id); idsLock.unlock()
  }

  private func owns(_ id: String) -> Bool {
    idsLock.lock(); defer { idsLock.unlock() }
    return ownIds.contains(id)
  }

  /// Sends recovered hang `id` to Dart, if the file still holds it and it is
  /// not already on its way. Deleted once Dart answers true; kept otherwise
  /// (no Dart handler yet, an error): resent on the next `configure`, or
  /// read on the next launch.
  private func deliver(id: String) {
    guard inFlightId == nil, let channel = channel,
          let value = PluginAppHangFile.read(path: path), value.hang.id == id, value.recovered,
          let record = PluginAppHangFile.record(value) else { return }
    inFlightId = id
    channel.invokeMethod("onAppHang", arguments: record) { [weak self] result in
      guard let self = self else { return }
      self.inFlightId = nil
      guard (result as? Bool) == true else { return }
      PluginAppHangFile.remove(path: self.path, id: id)
      // Another hang that recovered while this one was on its way.
      if let next = PluginAppHangFile.read(path: self.path), next.recovered, self.owns(next.hang.id) {
        self.deliver(id: next.hang.id)
      }
    }
  }

  /// `readNativeCrash`: the hang an earlier process left, deleted on read,
  /// or nil. Hangs of this process are delivered live (`onAppHang`) only, so
  /// one is never returned twice.
  func consumeEarlierHang() -> String? {
    guard FileManager.default.fileExists(atPath: path) else { return nil }
    guard let value = PluginAppHangFile.read(path: path) else {
      try? FileManager.default.removeItem(atPath: path)  // unreadable
      return nil
    }
    // Detected in this process (recovered or still being recorded: the
    // watchdog may not have seen the main thread answer yet).
    if owns(value.hang.id) { return nil }
    try? FileManager.default.removeItem(atPath: path)
    return PluginAppHangFile.record(value)
  }
}
