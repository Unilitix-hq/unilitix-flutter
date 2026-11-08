// VENDORED from UnilitixCore 0.8.0 (Engine.swift) by scripts/sync-ios-core.sh.
// Do not edit here; change UnilitixCore and re-run the script.

import Foundation

/// The SDK's state machine. Everything except the crash path and
/// `replayGate()` runs on `queue`.
final class Engine {
    let config: UnilitixConfig
    let store: EventStore
    let screenshots: ScreenshotStore
    let snapshots: SnapshotStore
    let breadcrumbs = Breadcrumbs()
    let queue = DispatchQueue(label: "io.unilitix.engine", qos: .utility)

    private let transport: Transport
    private let prefs: Preferences
    private let device: DeviceInfo
    private let reachability: Reachability
    private let random: () -> Double
    private let now: () -> Date
    private let log: (String) -> Void

    private(set) var consent: UnilitixConsent
    private var session: SessionInfo? {
        // Published for `currentSessionId` (any thread).
        didSet {
            let id = session?.id
            sessionLock.lock(); publishedSessionId = id; sessionLock.unlock()
        }
    }
    private var backgroundedAt: Date?
    private var screen = ""
    private let rageTaps = RageTapDetector()
    private var seq = 0
    /// Identify requests not yet acknowledged (persisted in `prefs`), sent
    /// in order, one at a time.
    private var identifyInFlight = false
    /// Event batches sent in the current flush cycle (the cycle drains the
    /// queue while each request succeeds).
    private var batchPasses = 0
    /// The network was offline at the last change (`networkChanged`).
    private var wasOffline = false
    /// This flush cycle also sends session records without events.
    private var sendRecordUpdates = false
    static let maxBatchesPerCycle = 50
    /// Infers out-of-memory and watchdog terminations of the previous run
    /// (nil: off, e.g. in tests and app extensions).
    let terminationTracker: TerminationTracker?
    /// Frames from `addExternalScreenshot` in the last minute
    /// (`maxScreenshotsPerMinute` also applies to wrapper frames).
    private var externalFrameTimes: [Date] = []
    /// Largest wrapper-supplied frame or snapshot accepted.
    static let maxExternalFrameBytes = 4 * 1024 * 1024
    static let maxExternalSnapshotBytes = 1024 * 1024
    private let queueKey = DispatchSpecificKey<Bool>()

    // Upload state (contract: one request per cycle, backoff window, auth latch).
    // `inFlight` covers event batches and screenshot passes alike.
    private var inFlight = false
    private var failures = 0
    private(set) var backoffUntil: Date?
    private(set) var authRejected = false
    private var timer: DispatchSourceTimer?

    // Per-session error caps (contract limits).
    private var seenFingerprints: [String: Int] = [:]
    private var errorReports = 0

    // Session replay. `replaySampled`, `screenshotCount` and `snapshotCount`
    // belong to the current session; the gates are what the main-thread
    // capturers read. One sampling decision covers screenshots and snapshots.
    private var replaySampled = false {
        didSet { let v = replaySampled; replayLock.lock(); publishedReplaySampled = v; replayLock.unlock() }
    }
    private var publishedReplaySampled = false
    /// A wrapper supplies the frames (`setExternalScreenCapture`): the UIKit
    /// capturer stays idle. Under `replayLock`.
    private var externalScreenCapture = false
    private var screenshotCount = 0
    private var snapshotCount = 0
    private let replayLock = NSLock()
    private var gate: ReplayGate?
    private var snapGate: ReplayGate?
    private var snapshotPasses = 0
    // Storage PUT failures back off separately: a storage outage must not
    // hold back events.
    private var screenshotFailures = 0
    private(set) var screenshotBackoffUntil: Date?
    private var screenshotPasses = 0

    /// Frames per init request (the API accepts 1–200).
    static let screenshotsPerPass = 20
    /// Passes chained in one flush cycle while each one fully succeeds.
    static let maxScreenshotPassesPerCycle = 10
    /// Frames are JPEG (ScreenshotCapture). The init request declares the
    /// format so the API stores them as .jpg, and the PUT sends the matching
    /// type (0.3.0 sent JPEG bytes labelled image/webp).
    static let screenshotFormat = "jpeg"
    static let screenshotContentType = "image/jpeg"
    /// Snapshots per `/v1/ingest/snapshots` request (Android's chunk size).
    static let snapshotsPerRequest = 20
    /// Snapshot requests chained in one flush cycle while each one succeeds.
    static let maxSnapshotPassesPerCycle = 10

    /// Read by the crash handler without going through `queue`.
    private let sessionLock = NSLock()
    private var crashSessionId: String?
    /// `session?.id`, for `currentSessionId` on any thread.
    private var publishedSessionId: String?

    /// Where `CrashFile`'s signal handlers write; nil when not used.
    private let crashFilePath: String?
    /// The record those handlers left in the previous process, read (and
    /// deleted) by `loadPersistedState` on `queue` and reported by `start`.
    private var nativeCrash: String?

    /// Where the app-hang watchdog keeps the hang in progress
    /// (`AppHangFile`), nil when hangs are not persisted.
    let appHangFilePath: String?
    /// The hang the previous process did not survive, read (and deleted) by
    /// `loadPersistedState` and reported by `start`.
    private var pendingAppHang: AppHangRecord?
    private var persistedStateLoaded = false

    init(config: UnilitixConfig, transport: Transport, store: EventStore,
         prefs: Preferences, device: DeviceInfo, consent: UnilitixConsent,
         screenshots: ScreenshotStore = ScreenshotStore(directory: nil),
         snapshots: SnapshotStore = SnapshotStore(directory: nil),
         reachability: Reachability = PathReachability(),
         random: @escaping () -> Double = { Double.random(in: 0..<1) },
         now: @escaping () -> Date = Date.init,
         crashFilePath: String? = nil,
         appHangFilePath: String? = nil,
         terminationTracker: TerminationTracker? = nil,
         log: @escaping (String) -> Void = { _ in }) {
        self.config = config
        self.transport = transport
        self.store = store
        self.screenshots = screenshots
        self.snapshots = snapshots
        self.prefs = prefs
        self.device = device
        self.reachability = reachability
        self.random = random
        self.now = now
        self.log = log
        // A decision persisted from a previous launch wins over the argument.
        self.consent = prefs.consent ?? consent
        self.crashFilePath = crashFilePath
        self.appHangFilePath = appHangFilePath
        self.terminationTracker = terminationTracker
        store.log = log
        queue.setSpecific(key: queueKey, value: true)
    }

    /// True on `queue`.
    var isOnQueue: Bool { DispatchQueue.getSpecific(key: queueKey) == true }

    // MARK: Lifecycle

    /// Reads what earlier launches left on disk, once: the event queue,
    /// the replay stores' indexes, the previous crash record (with its
    /// backtrace symbolicated) and an unfinished app hang. Call on `queue`
    /// (0.7.2: no longer at init, so `Unilitix.start` does no file I/O on
    /// the caller's thread). `start` calls it first.
    func loadPersistedState() {
        guard !persistedStateLoaded else { return }
        persistedStateLoaded = true
        store.loadFromDisk()
        screenshots.loadFromDisk(now: now())
        snapshots.loadFromDisk(now: now())
        if let path = crashFilePath { nativeCrash = CrashFile.consume(path: path) }
        if let path = appHangFilePath { pendingAppHang = AppHangFile.consume(path: path) }
    }

    /// Starts the first session and the flush timer. Call on `queue`.
    ///
    /// Uploads happen on the contract's triggers only (the flush interval,
    /// `flushBatchSize` queued events, entering the background, `flush()`),
    /// plus once here when an earlier launch left data on the device (a
    /// crash report should not wait for the first interval). 0.7.x always
    /// flushed here.
    func start() {
        loadPersistedState()
        // Before the new session: the crash (or hang) belongs to the one that died.
        let hadHang = pendingAppHang != nil
        let hadCrash = nativeCrash != nil
        let unattributed = reportNativeCrash()
        let unattributedHang = reportPendingAppHang()
        let termination = reportPreviousTermination(crashed: hadCrash, hung: hadHang)
        // Events from earlier launches (including reports just filed against
        // their sessions) are sent right away.
        let backlog = store.nextBatch(limit: 1, includeRecordOnly: false) != nil
            || unattributed != nil || unattributedHang != nil || termination != nil
        if consent != .denied { startSession() }
        if let e = unattributed, var s = session {
            s.crashed = true
            session = s
            emit(e)
        }
        if let e = unattributedHang, session != nil { emit(e) }
        if let e = termination, session != nil { emit(e) }
        terminationTracker?.setSession(session?.id)
        wasOffline = reachability.isOffline
        reachability.setChangeHandler { [weak self] in
            guard let self = self else { return }
            self.queue.async { self.networkChanged() }
        }
        let t = DispatchSource.makeTimerSource(queue: queue)
        let interval = DispatchTimeInterval.seconds(max(1, config.flushIntervalSeconds))
        t.schedule(deadline: .now() + interval, repeating: interval)
        t.setEventHandler { [weak self] in self?.flush() }
        t.resume()
        timer = t
        if backlog { flush() }
    }

    /// Back online: send what was held. Call on `queue`.
    func networkChanged() {
        let offline = reachability.isOffline
        defer { wasOffline = offline }
        if wasOffline && !offline { flush() }
    }

    func stop() {
        timer?.cancel()
        timer = nil
    }

    func didEnterBackground() {
        backgroundedAt = now()
        terminationTracker?.setForeground(false)
        touchSession()
        flush(recordUpdates: true)
        store.saveNow()
    }

    /// The app is about to be terminated normally: persist the queue now,
    /// on the calling thread (the main thread has a few seconds).
    func willTerminate() {
        terminationTracker?.markCleanExit()
        store.saveNow()
    }

    /// Calls `done` on `queue` once no upload is in flight, or after
    /// `timeout` seconds. Call on `queue`.
    func whenUploadsIdle(timeout: TimeInterval, _ done: @escaping () -> Void) {
        guard inFlight || identifyInFlight, timeout > 0 else { done(); return }
        let step = 0.25
        queue.asyncAfter(deadline: .now() + step) { [weak self] in
            guard let self = self else { done(); return }
            self.whenUploadsIdle(timeout: timeout - step, done)
        }
    }

    func willEnterForeground() {
        let t = now()
        terminationTracker?.setForeground(true)
        // Contract: more than `sessionTimeoutSeconds` in the background.
        if let bg = backgroundedAt,
           t.timeIntervalSince(bg) > TimeInterval(config.sessionTimeoutSeconds) {
            startSession()
            terminationTracker?.setSession(session?.id)
        }
        backgroundedAt = nil
        flush()
    }

    var sessionId: String? { session?.id }

    /// The current session id, from any thread (nil before the first
    /// session, after `endSession` and with consent denied).
    var currentSessionId: String? {
        sessionLock.lock(); defer { sessionLock.unlock() }
        return publishedSessionId
    }

    /// Whether the current session records replay (screenshots and
    /// snapshots), from any thread. False without a session.
    var isReplaySampled: Bool {
        guard currentSessionId != nil else { return false }
        replayLock.lock(); defer { replayLock.unlock() }
        return publishedReplaySampled
    }

    // Read on `queue` by tests (the behaviour-fixture runner's state hook).
    var currentScreen: String { screen }
    var replaySampledNow: Bool { replaySampled }
    var anonymousIdNow: String { prefs.anonymousId }
    var userIdNow: String? { prefs.customUserId }

    /// Starts a new session now. Also used when the app returns after the timeout.
    func startSession() {
        guard consent != .denied else { return }
        let t = now()
        let info = SessionInfo(id: UUID().uuidString.lowercased(), startedAt: t, lastActivityAt: t,
                               crashed: false, customUserId: prefs.customUserId,
                               anonymousId: prefs.anonymousId)
        session = info
        seq = 0
        // Contract: a new session starts with no screen.
        screen = ""
        externalFrameTimes = []
        seenFingerprints = [:]
        errorReports = 0
        screenshotCount = 0
        snapshotCount = 0
        replaySampled = (config.captureScreenshots || config.captureSnapshots)
            && ReplaySampling.isSampled(rate: config.replaySampleRate, roll: random())
        breadcrumbs.clear()
        sessionLock.lock(); crashSessionId = info.id; sessionLock.unlock()
        store.upsertSession(info)
        emit(IngestEvent(type: "SESSION_START", screen: screen, at: t))
        publishReplayGate()
        let replayOn = config.captureScreenshots || config.captureSnapshots
        log("session \(info.id) started\(replayOn && !replaySampled ? " (replay not sampled)" : "")")
    }

    /// Ends the current session and uploads it; the next event starts a new one.
    func endSession() {
        touchSession()
        flush(recordUpdates: true)
        store.saveNow()
        session = nil
        publishReplayGate()
    }

    private func touchSession() {
        guard var s = session else { return }
        s.lastActivityAt = now()
        session = s
        store.upsertSession(s)
    }

    // MARK: Capture

    /// A CUSTOM event. The name and properties are normalised to the
    /// contract's limits (`PropertyNormalizer`).
    func track(_ name: String, properties: [String: Any]) {
        let n = PropertyNormalizer.string(name)
        var e = IngestEvent(type: "CUSTOM", screen: screen, at: now())
        e.metadata = ["name": .string(n)]
        if !properties.isEmpty { e.properties = PropertyNormalizer.properties(properties) }
        breadcrumbs.add(type: "CUSTOM", screen: screen, message: n)
        emit(e)
    }

    /// A NAVIGATE event, unless `name` is already the session's current
    /// screen (contract 1.4.0: consecutive duplicates are dropped, manual
    /// calls included; 0.7.x deduplicated automatic views only). A new
    /// session starts with no screen, so its first view always counts.
    /// `automatic` is kept for callers; both kinds dedupe.
    func screenView(_ name: String, automatic: Bool = false) {
        let n = PropertyNormalizer.string(name)
        if session == nil && consent != .denied { startSession() }  // after endSession()
        if n == screen { return }
        screen = n
        breadcrumbs.add(type: "NAVIGATE", screen: n)
        emit(IngestEvent(type: "NAVIGATE", screen: n, at: now()))
        publishReplayGate()
    }

    /// A tap at (x, y) in points; becomes a RAGE_TAP when it completes one.
    func recordTap(x: Double, y: Double, view: String) {
        guard consent != .denied, config.autoTrackTaps else { return }
        let t = now()
        if config.autoTrackRageTaps,
           let hit = rageTaps.record(x: x, y: y, screen: screen, at: t.timeIntervalSince1970) {
            var e = IngestEvent(type: "RAGE_TAP", screen: screen, at: t)
            e.x = hit.x
            e.y = hit.y
            e.properties = ["taps": .int(Int64(hit.taps))]
            if !view.isEmpty { e.properties?["view"] = .string(view) }
            breadcrumbs.add(type: "RAGE_TAP", screen: screen, message: view.isEmpty ? nil : view, at: t)
            emit(e)
            return
        }
        var e = IngestEvent(type: "TAP", screen: screen, at: t)
        e.x = x
        e.y = y
        if !view.isEmpty { e.properties = ["view": .string(view)] }
        breadcrumbs.add(type: "TAP", screen: screen, message: view.isEmpty ? nil : view, at: t)
        emit(e)
    }

    func addBreadcrumb(_ message: String, category: String?) {
        breadcrumbs.add(type: category ?? "custom", screen: screen, message: message)
    }

    /// A handled error (EXCEPTION) or, with `fatal`, a crash (CRASH).
    /// `debugImages` are the images of the stack's frames
    /// (`metadata.debugImages`, for exact symbolication); nil looks them up
    /// from the stack's text in this process (`BinaryImages.debugImages(stack:)`).
    func recordError(type: String, message: String, stack: String?, fatal: Bool, platform: String = "ios",
                     debugImages: [DebugImage]? = nil) {
        guard let e = errorEvent(type: type, message: message, stack: stack, fatal: fatal, checkCaps: true,
                                 platform: platform, debugImages: debugImages) else {
            return
        }
        if fatal, var s = session {
            s.crashed = true
            session = s
        }
        emit(e)
        if fatal {
            terminationTracker?.markCrashed()
            store.saveNow()
            flush()
        }
    }

    /// Crash path: runs on the crashing thread, never touches `queue`, and
    /// waits at most the contract's fatal budget for the store. Returns false
    /// when the store could not take the report in time, has no record of
    /// the session, or no session started yet (0.7.2: the queue is still
    /// loading at launch), so `CrashReporter` keeps it in the crash file for
    /// the next launch; a report dropped on purpose (consent denied) returns
    /// true.
    /// `debugImages` as for `recordError`: `CrashReporter` passes the images
    /// of the exception's return addresses.
    @discardableResult
    func recordFatalSynchronously(type: String, message: String, stack: String?,
                                  debugImages: [DebugImage]? = nil) -> Bool {
        sessionLock.lock()
        let sid = crashSessionId
        sessionLock.unlock()
        guard consent != .denied else { return true }
        terminationTracker?.markCrashed()
        guard let sessionId = sid else { return false }
        guard let e = errorEvent(type: type, message: message, stack: stack, fatal: true, checkCaps: false,
                                 platform: "ios", debugImages: debugImages) else {
            return true
        }
        let budget = TimeInterval(SdkContract.fatalFlushBudgetMs) / 1000
        guard store.append(e, sessionId: sessionId, waitUpTo: budget) else { return false }
        store.saveNow()
        return true
    }

    // MARK: Native crash from the previous process

    /// Reports the record read at init as a fatal CRASH. Like the Flutter
    /// SDK (2.1.2+), it goes to the session that was running when the
    /// process died: the stored session with the latest `startedAt` at or
    /// before the record's timestamp (no timestamp: the latest), which is
    /// marked crashed. Returns the event when no stored session matches, for
    /// `start` to emit in the new session. Consent denied drops it; pending
    /// keeps it on the device like any other event. Call on `queue`, before
    /// the new session starts.
    private func reportNativeCrash() -> IngestEvent? {
        guard let text = nativeCrash else { return nil }
        nativeCrash = nil
        guard consent != .denied else {
            log("native crash from the previous launch dropped (consent denied)")
            return nil
        }
        guard let data = text.data(using: .utf8),
              let record = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let crash = Engine.nativeCrashEvent(record, now: now()) else {
            log("native crash record could not be read; dropped")
            return nil
        }
        // A signal's timestamp is in whole seconds: allow a session that
        // started within the second it died.
        let latestStart = crash.crashedAt.map { $0.addingTimeInterval(1) }
        guard var target = store.latestSession(startedAtOrBefore: latestStart) else {
            log("native crash from the previous launch: no stored session matches; reported in the new one")
            return crash.event
        }
        guard store.append(crash.event, sessionId: target.id) else { return crash.event }
        target.crashed = true
        if let at = crash.crashedAt, at > target.lastActivityAt { target.lastActivityAt = at }
        store.upsertSession(target)
        store.saveNow()
        log("native crash from the previous launch reported against session \(target.id)")
        return nil
    }

    /// The CRASH event for a `CrashFile` record, and when the process died
    /// (nil when the record has no usable timestamp). The same fields as
    /// the Flutter SDK reports for a native record: `exceptionType` as
    /// recorded (`SIGNAL` for a signal), `fatal`, the record's stack, and
    /// `metadata.fingerprint` from `CrashFile.fingerprint(of:)` (`SIGNAL:<n>`
    /// for a signal). A signal's message is `Fatal signal 11 (SIGSEGV)`;
    /// `metadata.signal` carries the number. `metadata.debugImages` is the
    /// record's (0.7.0: an exception's images, or a signal's once
    /// `CrashFile.consume` expanded its backtrace into `stackTrace`).
    static func nativeCrashEvent(_ record: [String: Any], now: Date) -> (event: IngestEvent, crashedAt: Date?)? {
        guard let type = record["exceptionType"] as? String, !type.isEmpty else { return nil }
        let signal = CrashFile.intValue(record["signal"])
        var message = record["exceptionMessage"] as? String ?? ""
        if message.isEmpty, let n = signal {
            message = CrashFile.signalName(n).map { "Fatal signal \(n) (\($0))" } ?? "Fatal signal \(n)"
        }
        var crashedAt: Date?
        if let ms = (record["timestamp"] as? NSNumber)?.doubleValue, ms > 0 {
            crashedAt = Date(timeIntervalSince1970: ms / 1000)
        }
        let stack = (record["stackTrace"] as? String).flatMap { $0.isEmpty ? nil : String($0.prefix(16 * 1024)) }
        let fp = (record["fingerprint"] as? String).flatMap { $0.isEmpty ? nil : $0 }
            ?? CrashFile.fingerprint(of: record)

        var e = IngestEvent(type: "CRASH", screen: "", at: crashedAt ?? now)
        e.fatal = true
        let title = message.isEmpty ? type : "\(type): \(message)"
        e.title = String(title.prefix(200))
        e.exceptionType = type
        e.exceptionMessage = message
        e.stackTrace = stack
        var metadata: [String: JSONValue] = [
            "fingerprint": .string(fp),
            "platform": .string(record["platform"] as? String ?? "ios"),
        ]
        if let n = signal { metadata["signal"] = .int(Int64(n)) }
        let images = CrashFile.debugImages(in: record)
        if !images.isEmpty { metadata["debugImages"] = .array(images.map { $0.json }) }
        e.metadata = metadata
        return (e, crashedAt)
    }

    private func errorEvent(type: String, message: String, stack: String?, fatal: Bool,
                            checkCaps: Bool, platform: String, debugImages: [DebugImage]?,
                            fingerprint: String? = nil) -> IngestEvent? {
        let fp = fingerprint ?? Fingerprint.of(type, stack: stack)
        if checkCaps, !passesErrorCaps(fp) { return nil }
        var e = IngestEvent(type: fatal ? "CRASH" : "EXCEPTION", screen: breadcrumbs.lastScreen, at: now())
        e.fatal = fatal
        e.title = message.isEmpty ? type : "\(type): \(message)"
        e.exceptionType = type
        e.exceptionMessage = message
        if let stack = stack { e.stackTrace = String(stack.prefix(16 * 1024)) }
        e.breadcrumbs = breadcrumbs.toWire()
        var metadata: [String: JSONValue] = ["fingerprint": .string(fp), "platform": .string(platform)]
        // Metadata only: the fingerprint above is computed without it.
        let images = debugImages ?? Engine.debugImages(stack: stack)
        if !images.isEmpty { metadata["debugImages"] = .array(images.map { $0.json }) }
        e.metadata = metadata
        return e
    }

    /// The images of an Apple stack's frames in this process; empty for
    /// other stacks (JS, Dart, JVM) and off Darwin.
    static func debugImages(stack: String?) -> [DebugImage] {
        #if canImport(Darwin)
        guard let s = stack, !s.isEmpty else { return [] }
        return BinaryImages.debugImages(stack: s)
        #else
        return []
        #endif
    }

    /// Counts a report of `fp` against the per-session limits
    /// (`maxReportsPerFingerprint`, `maxErrorReportsPerSession`); false when
    /// it must not be sent.
    private func passesErrorCaps(_ fp: String) -> Bool {
        let n = (seenFingerprints[fp] ?? 0) + 1
        seenFingerprints[fp] = n
        if n > SdkContract.maxReportsPerFingerprint || errorReports >= SdkContract.maxErrorReportsPerSession {
            log("error \(fp) not sent (per-session cap)")
            return false
        }
        errorReports += 1
        return true
    }

    // MARK: App hangs (ANR)

    /// The session a hang detected now belongs to, or nil when it must not
    /// be captured (consent denied, or no session started yet). Any thread.
    func hangCaptureSessionId() -> String? {
        sessionLock.lock(); defer { sessionLock.unlock() }
        return crashSessionId
    }

    /// A hang that ended in this process (`AppHangWatchdog`): an `ANR` in the
    /// current session, under the per-session error caps. The pending file
    /// is deleted once the event is stored. Call on `queue`.
    func recordAppHang(_ hang: AppHangRecord) {
        defer { if let path = appHangFilePath { AppHangFile.remove(path: path, id: hang.id) } }
        guard consent != .denied else { return }
        let e = Engine.appHangEvent(hang, terminated: false)
        guard case .string(let fp)? = e.metadata?["fingerprint"], passesErrorCaps(fp) else { return }
        emit(e)
        store.saveNow()
        log("app hang of \(hang.durationMs) ms reported")
    }

    /// Reports the hang read at init: the process ended (killed by the
    /// system watchdog or the user) before the main thread recovered. Like
    /// a native crash it goes to the session that was running, but that
    /// session is not marked crashed (an ANR is not a crash); its duration
    /// is extended to the end of the hang as far as it was measured. Returns
    /// the event when that session is no longer stored, for `start` to emit
    /// in the new session. Consent denied drops it. Call on `queue`, before
    /// the new session starts.
    private func reportPendingAppHang() -> IngestEvent? {
        guard let hang = pendingAppHang else { return nil }
        pendingAppHang = nil
        guard consent != .denied else {
            log("app hang from the previous launch dropped (consent denied)")
            return nil
        }
        let e = Engine.appHangEvent(hang, terminated: true)
        let startedAt = Date(timeIntervalSince1970: Double(hang.startedAtMs) / 1000)
        let target: SessionInfo?
        if let id = hang.sessionId {
            target = store.session(id)
        } else {
            target = store.latestSession(startedAtOrBefore: startedAt)
        }
        guard var s = target, store.append(e, sessionId: s.id) else {
            log("app hang from the previous launch: its session is gone; reported in the new one")
            return e
        }
        let endedAt = startedAt.addingTimeInterval(Double(hang.durationMs) / 1000)
        if endedAt > s.lastActivityAt { s.lastActivityAt = endedAt }
        store.upsertSession(s)
        store.saveNow()
        log("app hang from the previous launch reported against session \(s.id)")
        return nil
    }

    /// The `ANR` event for a hang (contract 1.3.0): `exceptionType` `ANR`,
    /// not fatal, the main thread's stack, and `metadata.fingerprint` over
    /// it with type `ANR` (so hangs group by where the main thread was
    /// stuck). `metadata.hangDurationMs` is how long the main thread was
    /// blocked (a lower bound with `appTerminated`), `appHangTimeoutMs` the
    /// threshold, `debugImages` the stack's images. Timestamped when the
    /// hang began.
    static func appHangEvent(_ hang: AppHangRecord, terminated: Bool) -> IngestEvent {
        let stack = hang.stackTrace.flatMap { $0.isEmpty ? nil : String($0.prefix(CrashFile.maxStackLength)) }
        let message = terminated
            ? "The main thread was blocked for at least \(hang.durationMs) ms; the app was terminated before it recovered"
            : "The main thread was blocked for \(hang.durationMs) ms"
        let at = Date(timeIntervalSince1970: Double(hang.startedAtMs) / 1000)
        var e = IngestEvent(type: "ANR", screen: hang.screen, at: at)
        e.fatal = false
        e.title = "ANR: \(message)"
        e.exceptionType = "ANR"
        e.exceptionMessage = message
        e.stackTrace = stack
        if let crumbs = hang.breadcrumbs, !crumbs.isEmpty { e.breadcrumbs = crumbs }
        var metadata: [String: JSONValue] = [
            "fingerprint": .string(Fingerprint.of("ANR", stack: stack)),
            "platform": .string(hang.platform),
            "hangDurationMs": .int(hang.durationMs),
            "appHangTimeoutMs": .int(Int64(hang.timeoutMs)),
        ]
        if terminated { metadata["appTerminated"] = .bool(true) }
        if !hang.debugImages.isEmpty { metadata["debugImages"] = .array(hang.debugImages.map { $0.json }) }
        e.metadata = metadata
        return e
    }

    private func emit(_ event: IngestEvent) {
        guard consent != .denied else { return }
        if session == nil { startSession() }  // after endSession()
        guard let s = session else { return }
        var e = event
        e.seq = seq
        seq += 1
        // Contract 1.4.0: the network when the event was captured.
        let network = reachability.networkType
        if e.networkAtCapture == nil { e.networkAtCapture = network }
        if e.capturedOffline == nil { e.capturedOffline = network == NetworkType.offline }
        // JSON has no NaN or infinity (JSONEncoder throws on them).
        if let x = e.x, !x.isFinite { e.x = nil }
        if let y = e.y, !y.isFinite { e.y = nil }
        store.append(e, sessionId: s.id)
        if store.eventCount >= config.flushBatchSize { flush() }
    }

    // MARK: Session replay

    /// The session and screen a new frame belongs to, or nil when no frame is
    /// wanted. Safe to call from any thread (the capturer calls it on main).
    func replayGate() -> ReplayGate? {
        replayLock.lock(); defer { replayLock.unlock() }
        return gate
    }

    /// The session and screen a new view-tree snapshot belongs to, or nil
    /// when none is wanted (snapshots off, session not sampled, consent
    /// denied, or the session's cap reached). Safe to call from any thread.
    func snapshotGate() -> ReplayGate? {
        replayLock.lock(); defer { replayLock.unlock() }
        return snapGate
    }

    private func publishReplayGate() {
        var g: ReplayGate?
        var sg: ReplayGate?
        if consent != .denied, replaySampled, let s = session {
            if config.captureScreenshots, screenshotCount < config.maxScreenshotsPerSession {
                g = ReplayGate(sessionId: s.id, screen: screen)
            }
            if config.captureSnapshots, snapshotCount < config.maxSnapshotsPerSession {
                sg = ReplayGate(sessionId: s.id, screen: screen)
            }
        }
        replayLock.lock(); gate = g; snapGate = sg; replayLock.unlock()
    }

    /// A masked view tree from the capturer. Assigns the next snapshot
    /// ordinal of the session it was captured in, or drops it (returning nil)
    /// when that session has ended, is not sampled, or reached
    /// `maxSnapshotsPerSession`.
    @discardableResult
    func addSnapshot(_ hierarchy: SnapshotNode, sessionId: String, screen snapScreen: String, capturedAt: Date,
                     viewportWidth: Int, viewportHeight: Int) -> Int? {
        guard config.captureSnapshots, consent != .denied, replaySampled,
              let s = session, s.id == sessionId,
              snapshotCount < config.maxSnapshotsPerSession else { return nil }
        let ordinal = snapshotCount
        snapshotCount += 1
        let snap = PendingSnapshot(sessionId: sessionId, ordinal: ordinal, screenName: snapScreen,
                                   capturedAt: capturedAt, viewportWidth: viewportWidth,
                                   viewportHeight: viewportHeight, hierarchy: hierarchy)
        if !snapshots.add(snap) { log("snapshot \(ordinal) could not be stored") }
        if snapshotCount >= config.maxSnapshotsPerSession {
            log("snapshot cap (\(config.maxSnapshotsPerSession)) reached for this session")
            publishReplayGate()
        }
        return ordinal
    }

    /// A masked, encoded frame from the capturer. Assigns the next ordinal of
    /// the session it was captured in, or drops it (returning nil) when that
    /// session has ended, is not sampled, or reached its cap.
    @discardableResult
    func addScreenshot(_ jpeg: Data, sessionId: String, screen frameScreen: String, capturedAt: Date,
                       viewportWidth: Int, viewportHeight: Int) -> Int? {
        guard config.captureScreenshots, consent != .denied, replaySampled,
              let s = session, s.id == sessionId,
              screenshotCount < config.maxScreenshotsPerSession else { return nil }
        let ordinal = screenshotCount
        screenshotCount += 1
        let frame = PendingScreenshot(sessionId: sessionId, ordinal: ordinal, screenName: frameScreen,
                                      capturedAt: capturedAt, viewportWidth: viewportWidth,
                                      viewportHeight: viewportHeight, bytes: jpeg.count)
        if !screenshots.add(frame, jpeg: jpeg) { log("screenshot \(ordinal) could not be stored") }
        if screenshotCount >= config.maxScreenshotsPerSession {
            log("screenshot cap (\(config.maxScreenshotsPerSession)) reached for this session")
            publishReplayGate()
        }
        return ordinal
    }

    // MARK: Wrapper SDKs (Flutter, React Native)
    //
    // Engine-level entry points for plugins that vendor these sources and
    // drive the engine directly; the public `Unilitix` facade forwards to
    // them. See README "Wrapper SDKs".

    /// Names the SDK that embeds this engine (e.g. "flutter", "3.0.0"): the
    /// session's `sdkVersion` and the User-Agent carry the wrapper's version,
    /// `sessionData` both versions. Any thread; call before `start`.
    static func setWrapper(name: String, version: String) {
        UnilitixVersion.setWrapper(name: name, version: version)
    }

    /// A wrapper supplies replay frames (`addExternalScreenshot`): with
    /// `enabled`, the UIKit capturer takes no screenshots. Any thread.
    func setExternalScreenCapture(_ enabled: Bool) {
        replayLock.lock(); externalScreenCapture = enabled; replayLock.unlock()
    }

    /// Any thread.
    var isExternalScreenCaptureEnabled: Bool {
        replayLock.lock(); defer { replayLock.unlock() }
        return externalScreenCapture
    }

    /// A handled error (or, with `fatal`, a crash) raised in the wrapper's
    /// runtime (Dart, JavaScript): as `recordError`, plus the wrapper's own
    /// `fingerprint` (else computed from type and stack) and `metadata`
    /// (normalised; e.g. React Native's `jsBundleId`, `release`, `dist`).
    /// `fingerprint` and `platform` in `metadata` are ignored: the
    /// arguments win. Call on `queue`.
    func recordExternalError(type: String, message: String, stackTrace: String?, fatal: Bool, platform: String,
                             fingerprint: String? = nil, metadata: [String: Any]? = nil) {
        let fp = fingerprint.flatMap { $0.isEmpty ? nil : PropertyNormalizer.string($0) }
        let extra = metadata.map { PropertyNormalizer.properties($0) }
        guard var e = errorEvent(type: type, message: message, stack: stackTrace, fatal: fatal, checkCaps: true,
                                 platform: platform, debugImages: nil, fingerprint: fp) else { return }
        if let extra = extra, !extra.isEmpty {
            var m = extra
            for (k, v) in e.metadata ?? [:] { m[k] = v }
            e.metadata = m
        }
        if fatal, var s = session {
            s.crashed = true
            session = s
        }
        emit(e)
        if fatal {
            terminationTracker?.markCrashed()
            store.saveNow()
            flush()
        }
    }

    /// A replay frame the wrapper drew and masked itself (JPEG), through the
    /// normal pipeline: only when `captureScreenshots` is on, consent is not
    /// denied and the session is sampled, within `maxScreenshotsPerSession`
    /// and `maxScreenshotsPerMinute`; uploaded like native frames (Wi-Fi
    /// only by default). `width`/`height` are the viewport in points;
    /// `screen` nil uses the current screen. Returns the frame's ordinal, or
    /// nil when it was not kept. Call on `queue`.
    @discardableResult
    func addExternalScreenshot(_ jpeg: Data, width: Int, height: Int, capturedAt: Date,
                               screen frameScreen: String?) -> Int? {
        guard !jpeg.isEmpty, jpeg.count <= Engine.maxExternalFrameBytes,
              config.captureScreenshots, consent != .denied, replaySampled, let s = session else { return nil }
        let t = now()
        externalFrameTimes.removeAll { t.timeIntervalSince($0) >= 60 || $0 > t }
        guard externalFrameTimes.count < max(1, config.maxScreenshotsPerMinute) else {
            log("wrapper frame dropped (maxScreenshotsPerMinute)")
            return nil
        }
        let name = frameScreen.map { PropertyNormalizer.string($0) } ?? screen
        guard let ordinal = addScreenshot(jpeg, sessionId: s.id, screen: name, capturedAt: capturedAt,
                                          viewportWidth: max(0, width), viewportHeight: max(0, height)) else {
            return nil
        }
        externalFrameTimes.append(t)
        return ordinal
    }

    /// A view-tree snapshot the wrapper built (and masked) itself, as JSON:
    /// either the snapshot, `{"hierarchy": {…}, "screenName"?: "…",
    /// "viewportWidth"?: n, "viewportHeight"?: n, "capturedAt"?: "<RFC 3339>"
    /// | "timestampMs"?: n}`, or the bare hierarchy (its `bounds.w`/`bounds.h`
    /// give the viewport). The hierarchy is sent as given. Same gates as
    /// native snapshots. Returns the ordinal, or nil when it was not kept.
    /// Call on `queue`.
    @discardableResult
    func addExternalSnapshot(json: String) -> Int? {
        guard config.captureSnapshots, consent != .denied, replaySampled, let s = session,
              snapshotCount < config.maxSnapshotsPerSession else { return nil }
        let data = Data(json.utf8)
        guard data.count <= Engine.maxExternalSnapshotBytes,
              let parsed = try? JSONDecoder().decode(JSONValue.self, from: data),
              case .object(let root) = parsed else {
            log("wrapper snapshot is not a JSON object; dropped")
            return nil
        }
        let hierarchy: [String: JSONValue]
        if case .object(let h)? = root["hierarchy"] { hierarchy = h } else { hierarchy = root }
        func int(_ v: JSONValue?) -> Int? {
            switch v {
            case .int(let n)?: return Int(clamping: n)
            case .number(let d)? where d.isFinite && abs(d) < 1e9: return Int(d)
            default: return nil
            }
        }
        var bounds: [String: JSONValue] = [:]
        if case .object(let b)? = hierarchy["bounds"] { bounds = b }
        let width = int(root["viewportWidth"]) ?? int(bounds["w"]) ?? 0
        let height = int(root["viewportHeight"]) ?? int(bounds["h"]) ?? 0
        var capturedAt = now()
        if case .string(let iso)? = root["capturedAt"], let d = ISO8601.date(from: iso) { capturedAt = d }
        if let ms = int(root["timestampMs"]) ?? int(root["timestamp"]) {
            capturedAt = Date(timeIntervalSince1970: Double(ms) / 1000)
        }
        var name = screen
        if case .string(let n)? = root["screenName"] ?? root["screen"] { name = PropertyNormalizer.string(n) }
        let ordinal = snapshotCount
        snapshotCount += 1
        var snap = PendingSnapshot(sessionId: s.id, ordinal: ordinal, screenName: name, capturedAt: capturedAt,
                                   viewportWidth: max(0, width), viewportHeight: max(0, height),
                                   hierarchy: SnapshotNode(type: "External",
                                                           bounds: SnapshotBounds(x: 0, y: 0, w: width, h: height)))
        snap.rawHierarchy = .object(hierarchy)
        if !snapshots.add(snap) { log("snapshot \(ordinal) could not be stored") }
        if snapshotCount >= config.maxSnapshotsPerSession { publishReplayGate() }
        return ordinal
    }

    // MARK: Out-of-memory and watchdog terminations

    /// The previous run ended in the foreground without a crash record, a
    /// clean exit, an app or OS update, a reboot or a debugger
    /// (`TerminationTracker`): reported as a non-fatal `EXCEPTION`, type
    /// `OutOfMemory` (or `WatchdogTermination` when MetricKit points that
    /// way), `metadata.inferredTermination`. The contract has no event type
    /// for it yet. A hang the app did not survive is already reported as an
    /// `ANR` with `appTerminated`, so it is not reported twice. Goes to the
    /// session that was running when it is still stored; otherwise returned
    /// for `start` to emit in the new session. Call on `queue`, before the
    /// new session starts.
    private func reportPreviousTermination(crashed: Bool, hung: Bool) -> IngestEvent? {
        guard let tracker = terminationTracker else { return nil }
        guard let t = tracker.begin(crashRecordFound: crashed, hangRecordFound: hung) else { return nil }
        guard consent != .denied else { return nil }
        let e = Engine.terminationEvent(t)
        guard let id = t.sessionId, store.append(e, sessionId: id) else { return e }
        store.saveNow()
        log("\(t.kind.rawValue) termination of the previous run reported against session \(id)")
        return nil
    }

    static func terminationEvent(_ t: InferredTermination) -> IngestEvent {
        let type = t.kind == .watchdog ? "WatchdogTermination" : "OutOfMemory"
        let message = t.kind == .watchdog
            ? "The system terminated the app in the foreground (watchdog), inferred on the next launch"
            : "The system terminated the app in the foreground, most likely for using too much memory; inferred on the next launch"
        var e = IngestEvent(type: "EXCEPTION", screen: t.screen ?? "", at: t.lastSeenAt)
        e.fatal = false
        e.title = "\(type): \(message)"
        e.exceptionType = type
        e.exceptionMessage = message
        var metadata: [String: JSONValue] = [
            "fingerprint": .string(Fingerprint.of(type, stack: nil)),
            "platform": .string("ios"),
            "inferredTermination": .string(t.kind.rawValue),
            "appTerminated": .bool(true),
        ]
        if t.memoryWarning { metadata["memoryWarning"] = .bool(true) }
        if let mk = t.metricKit { metadata["metricKitForegroundExits"] = .object(mk) }
        e.metadata = metadata
        return e
    }

    // MARK: Identity and consent

    /// Links the anonymous id to `userId` (normalised, like `traits`):
    /// `POST /v1/ingest/identify`, once. The request is kept on the device
    /// (`Preferences.pendingIdentifies`) until the API answers it: held while
    /// consent is pending, offline, paused or backing off, resent after a
    /// retryable failure, dropped with consent denied.
    func identify(_ userId: String, traits: [String: Any]) {
        guard consent != .denied else { return }
        let uid = PropertyNormalizer.string(userId)
        prefs.customUserId = uid
        if var s = session {
            s.customUserId = uid
            session = s
            store.upsertSession(s)
        }
        let body = IdentifyRequest(anonymousId: prefs.anonymousId, customUserId: uid,
                                   traits: traits.isEmpty ? nil : PropertyNormalizer.properties(traits))
        var pending = prefs.pendingIdentifies
        pending.append(body)
        // Bounded: the latest links matter most.
        if pending.count > Engine.maxPendingIdentifies { pending.removeFirst(pending.count - Engine.maxPendingIdentifies) }
        prefs.pendingIdentifies = pending
        sendPendingIdentifies()
    }

    static let maxPendingIdentifies = 20

    /// Sends the oldest held identify request, then the next once it is
    /// answered. Same gates as event uploads. Call on `queue`.
    private func sendPendingIdentifies() {
        guard !identifyInFlight, canUpload(now()), let next = prefs.pendingIdentifies.first,
              let data = try? JSONEncoder().encode(next) else { return }
        identifyInFlight = true
        transport.post("/v1/ingest/identify", body: data) { [weak self] status, headers in
            self?.queue.async { self?.handleIdentify(status: status, headers: headers, sent: next) }
        }
    }

    private func handleIdentify(status: Int?, headers: [String: String], sent: IdentifyRequest) {
        identifyInFlight = false
        switch note(status: status, headers: headers, what: "identify") {
        case .accepted, .rejected:
            var pending = prefs.pendingIdentifies
            if let i = pending.firstIndex(of: sent) { pending.remove(at: i) }
            prefs.pendingIdentifies = pending
            sendPendingIdentifies()
        case .retry, .paused, .authFailure:
            break  // kept for the next flush
        }
    }

    func setConsent(_ value: UnilitixConsent) {
        let previous = consent
        consent = value
        prefs.consent = value
        switch value {
        case .denied:
            store.purge()
            screenshots.purge()
            snapshots.purge()
            prefs.pendingIdentifies = []
            // The user id identify() stored goes with the data; a later
            // grant starts unidentified until the app calls identify again.
            prefs.customUserId = nil
            session = nil
            sessionLock.lock(); crashSessionId = nil; sessionLock.unlock()
            if let path = appHangFilePath { AppHangFile.remove(path: path) }
        case .granted:
            if session == nil { startSession() }
            flush()
        case .pending:
            if previous == .denied { startSession() }
        }
        publishReplayGate()
    }

    /// New anonymous identity and a new session (e.g. on logout). Events
    /// already captured keep their session and ids (each stored session
    /// carries the anonymous and user id it started with).
    func reset() {
        prefs.customUserId = nil
        prefs.anonymousId = UUID().uuidString.lowercased()
        startSession()
        terminationTracker?.setSession(session?.id)
    }

    // MARK: Upload

    /// Contract gates for any upload: consent granted, not paused by
    /// 401/403, online (unknown counts as online), outside the backoff
    /// window (402 pauses use it too).
    private func canUpload(_ t: Date) -> Bool {
        guard consent == .granted, !authRejected, !reachability.isOffline else { return false }
        if let until = backoffUntil, t < until { return false }
        return true
    }

    /// One upload cycle: held identify requests, then the event queue
    /// (drained batch by batch while each request succeeds), then
    /// snapshots and screenshots.
    ///
    /// A session request carries events: a change to a session record alone
    /// (its duration, the user id) rides with the next events, and is sent
    /// on its own only with `recordUpdates` (entering the background,
    /// `endSession`), as in the contract's reference model.
    func flush(recordUpdates: Bool = false) {
        guard canUpload(now()) else { return }
        sendPendingIdentifies()
        guard !inFlight else { return }
        screenshotPasses = 0
        snapshotPasses = 0
        batchPasses = 0
        sendRecordUpdates = recordUpdates
        touchSession()
        uploadNextBatch()
    }

    private func uploadNextBatch() {
        guard !inFlight, canUpload(now()) else { return }
        guard batchPasses < Engine.maxBatchesPerCycle,
              let batch = store.nextBatch(limit: config.flushBatchSize, includeRecordOnly: sendRecordUpdates) else {
            uploadSnapshots()
            return
        }

        var events = batch.events
        var body = encode(batch.session, events)
        while let b = body, b.count > SdkContract.maxRequestBytes, events.count > 1 {
            events = Array(events.prefix(events.count / 2))
            body = encode(batch.session, events)
        }
        guard let data = body else {
            // An event JSON cannot represent must not stall the queue: drop
            // the events that fail on their own and try again.
            let encoder = JSONEncoder()
            let bad = events.filter { (try? encoder.encode($0)) == nil }
            guard !bad.isEmpty else {
                log("batch for session \(batch.session.id) could not be encoded; kept")
                return
            }
            for e in bad { store.drop(eventId: e.eventId, sessionId: batch.session.id) }
            log("\(bad.count) event(s) could not be encoded as JSON; dropped")
            uploadNextBatch()
            return
        }
        if data.count > SdkContract.maxRequestBytes, let only = events.first {
            log("event \(only.eventId) is larger than the API accepts; dropped")
            store.drop(eventId: only.eventId, sessionId: batch.session.id)
            return
        }

        batchPasses += 1
        inFlight = true
        let sent = Batch(batch: batch, events: events)
        transport.post("/v1/ingest/session", body: data) { [weak self] status, headers in
            self?.queue.async { self?.handle(status: status, headers: headers, sent: sent) }
        }
    }

    private struct Batch {
        let batch: EventStore.Batch
        let events: [IngestEvent]
    }

    private func handle(status: Int?, headers: [String: String], sent: Batch) {
        inFlight = false
        switch note(status: status, headers: headers, what: "upload") {
        case .accepted:
            store.acknowledge(sent.batch, eventIds: Set(sent.events.map { $0.eventId }), keep: session?.id)
            uploadNextBatch()  // the rest of the queue, then replay
        case .retry, .paused, .authFailure:
            break
        case .rejected:
            log("batch rejected by the API (\(status ?? 0)); dropped")
            store.acknowledge(sent.batch, eventIds: Set(sent.events.map { $0.eventId }), keep: session?.id)
            uploadNextBatch()
        }
    }

    /// Applies an API response to the shared backoff and auth state.
    private func note(status: Int?, headers: [String: String], what: String) -> UploadOutcome {
        let outcome = RetryPolicy.classify(status: status, headers: headers, attempt: failures)
        switch outcome {
        case .accepted:
            failures = 0
            backoffUntil = nil
        case .retry(let after):
            failures += 1
            backoffUntil = now().addingTimeInterval(after)
            log("\(what) failed (\(status.map { "HTTP \($0)" } ?? "no response")); retrying in \(Int(after))s")
        case .paused(let after):
            // 402: the data stays; uploads pause. Not counted as a failure.
            backoffUntil = now().addingTimeInterval(after)
            log("\(what): HTTP 402 (quota); uploads paused for \(Int(after))s")
        case .authFailure:
            authRejected = true
            log("API key rejected (\(status ?? 0)). Uploads paused until the app restarts; data stays on the device.")
        case .rejected:
            break
        }
        return outcome
    }

    private func encode(_ s: SessionInfo, _ events: [IngestEvent]) -> Data? {
        let req = IngestSessionRequest(
            sessionId: s.id,
            anonymousId: s.anonymousId ?? prefs.anonymousId,
            installId: prefs.installId,
            customUserId: s.customUserId,
            sdkVersion: UnilitixVersion.reported,
            os: device.os,
            osVersion: device.osVersion,
            deviceModel: device.deviceModel,
            manufacturer: "Apple",
            deviceType: device.deviceType,
            appVersion: device.appVersion,
            buildNumber: device.buildNumber,
            packageName: device.packageName,
            screenWidth: device.screenWidth,
            screenHeight: device.screenHeight,
            screenDensity: device.screenDensity,
            locale: device.locale,
            timezone: device.timezone,
            startedAt: ISO8601.string(from: s.startedAt),
            durationMs: Int64(max(0, s.lastActivityAt.timeIntervalSince(s.startedAt)) * 1000),
            crashed: s.crashed,
            sessionData: UnilitixVersion.sessionData,
            events: events)
        return try? JSONEncoder().encode(req)
    }

    // MARK: Snapshot upload
    //
    // After the events: up to `snapshotsPerRequest` snapshots of the oldest
    // session per `POST /v1/ingest/snapshots`, chained while each request
    // succeeds, then the screenshots. Same rules as events (RetryPolicy):
    // consent granted, the shared backoff and auth latch, and any other 4xx
    // drops what was sent. Snapshots are small JSON, so they are not held
    // for Wi-Fi.

    func uploadSnapshots() {
        guard !inFlight, canUpload(now()) else { return }
        guard snapshotPasses < Engine.maxSnapshotPassesPerCycle,
              let next = snapshots.nextUpload(limit: Engine.snapshotsPerRequest) else {
            uploadScreenshots()
            return
        }
        var sent = next.snapshots
        var body = encodeSnapshots(next.sessionId, sent)
        while let b = body, b.count > SdkContract.maxRequestBytes, sent.count > 1 {
            sent = Array(sent.prefix(sent.count / 2))
            body = encodeSnapshots(next.sessionId, sent)
        }
        guard let data = body else {
            snapshots.remove(sent)  // cannot be encoded; never will be
            uploadScreenshots()
            return
        }
        if data.count > SdkContract.maxRequestBytes {
            log("snapshot \(sent[0].ordinal) is larger than the API accepts; dropped")
            snapshots.remove(sent)
            uploadSnapshots()
            return
        }
        snapshotPasses += 1
        inFlight = true
        let batch = sent
        transport.post("/v1/ingest/snapshots", body: data) { [weak self] status, headers in
            self?.queue.async { self?.handleSnapshots(status: status, headers: headers, sent: batch) }
        }
    }

    private func encodeSnapshots(_ sessionId: String, _ items: [PendingSnapshot]) -> Data? {
        try? JSONEncoder().encode(IngestSnapshotsRequest(sessionId: sessionId,
                                                         snapshots: items.map(SnapshotPayload.init)))
    }

    private func handleSnapshots(status: Int?, headers: [String: String], sent: [PendingSnapshot]) {
        inFlight = false
        switch note(status: status, headers: headers, what: "snapshot upload") {
        case .accepted:
            snapshots.remove(sent)
            uploadSnapshots()
        case .rejected:
            log("snapshots rejected by the API (\(status ?? 0)); \(sent.count) dropped")
            snapshots.remove(sent)
            uploadSnapshots()
        case .retry, .paused, .authFailure:
            break  // kept for the next flush
        }
    }

    // MARK: Screenshot upload
    //
    // One pass: POST /screenshots/init for up to `screenshotsPerPass` frames
    // of the oldest session, PUT each JPEG to its presigned URL, then one
    // POST /screenshots/confirm for the frames that went up. Frames are
    // deleted only once confirmed (or rejected for good). Runs only with
    // consent granted, outside any backoff, and on Wi-Fi when
    // `uploadScreenshotsOnWifiOnly`.

    private struct ScreenshotPass {
        let sessionId: String
        let frames: [PendingScreenshot]
        var urls: [Int: URL] = [:]
    }

    func uploadScreenshots() {
        let t = now()
        guard !inFlight, canUpload(t) else { return }
        if let until = screenshotBackoffUntil, t < until { return }
        if config.uploadScreenshotsOnWifiOnly && !reachability.isOnUnmeteredNetwork { return }
        guard screenshotPasses < Engine.maxScreenshotPassesPerCycle,
              let next = screenshots.nextUpload(limit: Engine.screenshotsPerPass) else { return }
        // `sizes` (0.8.0): the API signs each PUT's Content-Length.
        let req = ScreenshotInitRequest(sessionId: next.sessionId, count: next.frames.count,
                                        ordinals: next.frames.map { $0.ordinal },
                                        format: Engine.screenshotFormat,
                                        sizes: next.frames.map { $0.bytes })
        guard let body = try? JSONEncoder().encode(req) else { return }
        screenshotPasses += 1
        inFlight = true
        let pass = ScreenshotPass(sessionId: next.sessionId, frames: next.frames)
        transport.postForResponse("/v1/ingest/screenshots/init", body: body) { [weak self] status, headers, data in
            self?.queue.async { self?.handleInit(status: status, headers: headers, body: data, pass: pass) }
        }
    }

    private func handleInit(status: Int?, headers: [String: String], body: Data?, pass: ScreenshotPass) {
        switch note(status: status, headers: headers, what: "screenshot init") {
        case .accepted:
            guard let data = body,
                  let response = try? JSONDecoder().decode(ScreenshotInitResponse.self, from: data) else {
                log("screenshot init: unexpected response; retrying later")
                backOffScreenshots()
                inFlight = false
                return
            }
            var p = pass
            for slot in response.slots {
                if let url = URL(string: slot.presignedUrl) { p.urls[slot.ordinal] = url }
            }
            putScreenshot(0, p, uploaded: [])
        case .retry, .paused, .authFailure:
            inFlight = false
        case .rejected:
            log("screenshots rejected by the API (\(status ?? 0)); \(pass.frames.count) dropped")
            screenshots.remove(pass.frames)
            inFlight = false
        }
    }

    private func putScreenshot(_ index: Int, _ pass: ScreenshotPass, uploaded: [PendingScreenshot]) {
        guard consent == .granted, !authRejected else {
            inFlight = false
            return
        }
        guard index < pass.frames.count else {
            confirmScreenshots(uploaded, pass)
            return
        }
        let frame = pass.frames[index]
        guard let url = pass.urls[frame.ordinal] else {
            log("no upload slot for screenshot \(frame.ordinal); retrying later")
            putScreenshot(index + 1, pass, uploaded: uploaded)
            return
        }
        guard let data = screenshots.data(for: frame) else {
            screenshots.remove([frame])  // its file is gone
            putScreenshot(index + 1, pass, uploaded: uploaded)
            return
        }
        transport.put(url, body: data, contentType: Engine.screenshotContentType) { [weak self] status in
            self?.queue.async { self?.handlePut(status: status, index: index, pass: pass, uploaded: uploaded) }
        }
    }

    private func handlePut(status: Int?, index: Int, pass: ScreenshotPass, uploaded: [PendingScreenshot]) {
        let frame = pass.frames[index]
        if let s = status, (200..<300).contains(s) {
            screenshotFailures = 0
            screenshotBackoffUntil = nil
            putScreenshot(index + 1, pass, uploaded: uploaded + [frame])
            return
        }
        if let s = status, (400..<500).contains(s), s != 408, s != 429 {
            // Storage refused this request (expired or malformed URL). Never
            // a reason to pause the API key.
            let dropped = screenshots.recordFailedUpload(frame)
            log("screenshot \(frame.ordinal) upload refused (HTTP \(s))\(dropped ? "; dropped" : "")")
        } else {
            backOffScreenshots()
            log("screenshot upload failed (\(status.map { "HTTP \($0)" } ?? "no response")); retrying later")
        }
        // End the pass; confirm what already went up.
        confirmScreenshots(uploaded, pass)
    }

    private func confirmScreenshots(_ uploaded: [PendingScreenshot], _ pass: ScreenshotPass) {
        guard !uploaded.isEmpty, consent == .granted, !authRejected else {
            inFlight = false
            return
        }
        let req = ScreenshotConfirmRequest(sessionId: pass.sessionId, screenshots: uploaded.map {
            ScreenshotConfirmItem(ordinal: $0.ordinal, bytes: $0.bytes,
                                  capturedAt: ISO8601.string(from: $0.capturedAt),
                                  screenName: $0.screenName, viewportWidth: $0.viewportWidth,
                                  viewportHeight: $0.viewportHeight)
        })
        guard let body = try? JSONEncoder().encode(req) else {
            inFlight = false
            return
        }
        let complete = uploaded.count == pass.frames.count
        transport.post("/v1/ingest/screenshots/confirm", body: body) { [weak self] status, headers in
            self?.queue.async {
                self?.handleConfirm(status: status, headers: headers, uploaded: uploaded, complete: complete)
            }
        }
    }

    private func handleConfirm(status: Int?, headers: [String: String], uploaded: [PendingScreenshot],
                               complete: Bool) {
        inFlight = false
        switch note(status: status, headers: headers, what: "screenshot confirm") {
        case .accepted:
            screenshots.remove(uploaded)
            if complete { uploadScreenshots() }  // drain the backlog while all goes well
        case .rejected:
            log("screenshot confirm rejected by the API (\(status ?? 0)); \(uploaded.count) dropped")
            screenshots.remove(uploaded)
        case .retry, .paused, .authFailure:
            break  // kept; uploaded and confirmed again next time
        }
    }

    private func backOffScreenshots() {
        let after = RetryPolicy.delay(attempt: screenshotFailures)
        screenshotFailures += 1
        screenshotBackoffUntil = now().addingTimeInterval(after)
    }
}
