// VENDORED from UnilitixCore 0.6.0 (CrashFile.swift) by scripts/sync-ios-core.sh.
// Do not edit here; change UnilitixCore and re-run the script.

import Foundation

/// A native crash written to a file by the dying process, for the SDK to
/// report on the next launch: uncaught Objective-C exceptions and fatal
/// signals (SIGABRT, SIGBUS, SIGFPE, SIGILL, SIGSEGV, SIGTRAP).
///
/// Two users:
/// - The Flutter SDK (`install()`, `consume()` at `defaultPath`): exceptions
///   and signals go to the file; its Dart side reports the record as a fatal
///   CRASH against the session that was running.
/// - `Engine` (native apps through `Unilitix`, React Native through its
///   bridge): `CrashReporter` records exceptions in the event store directly
///   (with the full stack, synchronously), so only the signal handlers write
///   here (`installSignalHandlers(path:)`, at `enginePath`), and the engine
///   reports the record when it starts on the next launch.
///
/// The file holds one JSON object, the format the Flutter SDK's Android
/// plugin writes too:
///
///     {"exceptionMessage":"…","exceptionType":"NSInvalidArgumentException",
///      "platform":"ios","stackTrace":"…","timestamp":1760700000000}
///     {"platform":"ios","exceptionType":"SIGNAL","signal":11,"timestamp":1760700000000}
///
/// `timestamp` is milliseconds since 1970 (whole seconds for a signal).
/// `consume` adds `fingerprint` (see `fingerprint(of:)`).
enum CrashFile {
    static let fileName = "unilitix_native_crash.json"
    /// Same cap as `Engine`'s stack traces.
    static let maxStackLength = 16 * 1024

    /// `Application Support/unilitix_native_crash.json`, where the Flutter
    /// plugin has always kept it, so a record left by an older version is
    /// still read.
    static var defaultPath: String {
        let dir = NSSearchPathForDirectoriesInDomains(.applicationSupportDirectory, .userDomainMask, true).first
            ?? NSTemporaryDirectory()
        try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        return (dir as NSString).appendingPathComponent(fileName)
    }

    /// `Application Support/Unilitix/native_crash.json`: the engine's file,
    /// next to its event queue. Kept apart from `defaultPath` so an app that
    /// embeds both the Flutter SDK and the native engine never has one
    /// consume (and report against its own sessions) the other's record.
    static var enginePath: String {
        let dir = EventStore.defaultDirectory?.path
            ?? (NSTemporaryDirectory() as NSString).appendingPathComponent("Unilitix")
        try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        return (dir as NSString).appendingPathComponent("native_crash.json")
    }

    // MARK: Format

    /// The record for an uncaught exception.
    static func exceptionRecord(type: String, message: String, stack: String, timestampMs: Int64) -> Data? {
        let record: [String: Any] = [
            "platform": "ios",
            "exceptionType": type,
            "exceptionMessage": message,
            "stackTrace": String(stack.prefix(maxStackLength)),
            "timestamp": timestampMs,
        ]
        return try? JSONSerialization.data(withJSONObject: record, options: [.sortedKeys])
    }

    /// Writes the record for `signal` to `fd` using write(2) and stack memory
    /// only, so it is async-signal-safe.
    static func writeSignalRecord(fd: Int32, signal: Int32, seconds: Int) {
        let prefix: StaticString = "{\"platform\":\"ios\",\"exceptionType\":\"SIGNAL\",\"signal\":"
        let middle: StaticString = ",\"timestamp\":"
        // Seconds → milliseconds by appending "000"; a zero (clock unavailable)
        // stays "0" so the JSON never has a number with a leading zero.
        let suffix: StaticString = seconds > 0 ? "000}" : "}"
        prefix.withUTF8Buffer { _ = write(fd, $0.baseAddress, $0.count) }
        writeDecimal(fd, Int(signal))
        middle.withUTF8Buffer { _ = write(fd, $0.baseAddress, $0.count) }
        writeDecimal(fd, seconds)
        suffix.withUTF8Buffer { _ = write(fd, $0.baseAddress, $0.count) }
    }

    /// Stack-only decimal formatting (no Foundation, no allocation).
    private static func writeDecimal(_ fd: Int32, _ value: Int) {
        withUnsafeTemporaryAllocation(of: UInt8.self, capacity: 24) { digits in
            var n = value < 0 ? 0 : value
            var i = 24
            repeat { i -= 1; digits[i] = UInt8(48 + n % 10); n /= 10 } while n > 0
            _ = write(fd, digits.baseAddress! + i, 24 - i)
        }
    }

    /// The crash's `Fingerprint`: the exception type and stack, or, for a
    /// signal (no stack), the key `SIGNAL:<n>` so each signal is its own
    /// group. The Dart SDK keys native records the same way.
    static func fingerprint(of record: [String: Any]) -> String {
        let type = record["exceptionType"] as? String ?? "NativeCrash"
        let stack = record["stackTrace"] as? String
        if let signal = intValue(record["signal"]) {
            return Fingerprint.of("\(type):\(signal)", stack: stack)
        }
        return Fingerprint.of(type, stack: stack)
    }

    /// `SIGSEGV` for 11 and so on, for the signals the handlers catch.
    static func signalName(_ signal: Int) -> String? {
        switch Int32(truncatingIfNeeded: signal) {
        case SIGABRT: return "SIGABRT"
        case SIGBUS: return "SIGBUS"
        case SIGFPE: return "SIGFPE"
        case SIGILL: return "SIGILL"
        case SIGSEGV: return "SIGSEGV"
        case SIGTRAP: return "SIGTRAP"
        default: return nil
        }
    }

    static func intValue(_ v: Any?) -> Int? {
        if let i = v as? Int { return i }
        if let n = v as? NSNumber { return n.intValue }
        return nil
    }

    // MARK: Reading

    /// Reads and deletes the pending record. Returns it with `fingerprint`
    /// added, the text as read when it is not a JSON object, or nil when
    /// there is none.
    static func consume(path: String = defaultPath) -> String? {
        guard FileManager.default.fileExists(atPath: path),
              let text = try? String(contentsOfFile: path, encoding: .utf8) else { return nil }
        try? FileManager.default.removeItem(atPath: path)
        return withFingerprint(text)
    }

    static func withFingerprint(_ text: String) -> String {
        guard let data = text.data(using: .utf8),
              var record = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else {
            return text
        }
        record["fingerprint"] = fingerprint(of: record)
        guard let out = try? JSONSerialization.data(withJSONObject: record, options: [.sortedKeys]),
              let json = String(data: out, encoding: .utf8) else {
            return text
        }
        return json
    }

    // MARK: Capture

    #if canImport(Darwin)
    static let signals: [Int32] = [SIGABRT, SIGBUS, SIGFPE, SIGILL, SIGSEGV, SIGTRAP]
    private static var signalsInstalled = false
    private static var exceptionHandlerInstalled = false
    private static var path = ""
    private static var previousHandler: (@convention(c) (NSException) -> Void)?
    /// Previous `sigaction` per signal, restored and chained from the handler.
    /// Never mutated after `installSignalHandlers`.
    private static var previousActions: [Int32: sigaction] = [:]
    /// Resolved at install so the signal handler never touches Foundation.
    private static var pathCString: UnsafeMutablePointer<CChar>?
    private static var altStack: UnsafeMutableRawPointer?
    /// Set once an uncaught exception has been reported (to this file, or by
    /// `CrashReporter` to the event store): the SIGABRT that follows it must
    /// not be reported again as a bare signal record.
    private static var exceptionRecorded = false

    /// The Flutter plugin's entry point: exceptions and signals, both to
    /// `path`, once. Handlers installed before (Crashlytics, Sentry, the
    /// app's own) are chained: they run after ours, and with none the
    /// default action is restored and the signal re-raised, so the process
    /// dies as it would have.
    static func install(path: String = defaultPath) {
        installSignalHandlers(path: path)
        guard !exceptionHandlerInstalled else { return }
        exceptionHandlerInstalled = true
        previousHandler = NSGetUncaughtExceptionHandler()
        NSSetUncaughtExceptionHandler { exception in
            _ = CrashFile.record(exception)
            CrashFile.previousHandler?(exception)
        }
    }

    /// Signal handlers only, writing to `path`, once. For the engine, whose
    /// `CrashReporter` owns the uncaught-exception handler; it calls
    /// `markExceptionHandled()` so the SIGABRT after an exception is not
    /// recorded too. Signal handlers run on an alternate stack (installed for
    /// the calling thread, normally main) so a stack overflow can still be
    /// recorded.
    static func installSignalHandlers(path: String) {
        guard !signalsInstalled else { return }
        signalsInstalled = true
        CrashFile.path = path
        exceptionRecorded = false
        pathCString = strdup(path)

        // A stack-overflow SIGSEGV cannot run a handler on the stack that overflowed.
        let size = max(Int(SIGSTKSZ), 64 * 1024)
        if let mem = malloc(size) {
            altStack = mem
            var ss = stack_t(ss_sp: mem, ss_size: numericCast(size), ss_flags: 0)
            sigaltstack(&ss, nil)
        }

        for sig in signals {
            var action = sigaction()
            action.__sigaction_u.__sa_sigaction = CrashFile.handleSignal
            action.sa_flags = SA_SIGINFO | SA_ONSTACK
            sigemptyset(&action.sa_mask)
            var previous = sigaction()
            if sigaction(sig, &action, &previous) == 0 {
                previousActions[sig] = previous
            }
        }
    }

    /// The uncaught exception about to end the process has been dealt with
    /// (reported, or deliberately ignored because a higher layer reported its
    /// cause): the signal that follows (SIGABRT from abort()) is not recorded.
    static func markExceptionHandled() {
        exceptionRecorded = true
    }

    /// Writes the record for an uncaught exception to the installed path and
    /// marks it handled. False when signal capture is not installed or the
    /// write failed. Not async-signal-safe: exception handlers only.
    @discardableResult
    static func record(_ exception: NSException) -> Bool {
        guard signalsInstalled, !path.isEmpty else { return false }
        let data = CrashFile.exceptionRecord(
            type: exception.name.rawValue,
            message: exception.reason ?? "",
            stack: exception.callStackSymbols.joined(separator: "\n"),
            timestampMs: Int64(Date().timeIntervalSince1970 * 1000))
        guard let d = data, (try? d.write(to: URL(fileURLWithPath: path))) != nil else { return false }
        exceptionRecorded = true
        return true
    }

    /// Async-signal-safe: open/write/close/time on pre-built buffers, then
    /// the previous handler (or the default action).
    private static let handleSignal: @convention(c) (Int32, UnsafeMutablePointer<siginfo_t>?, UnsafeMutableRawPointer?) -> Void = { s, info, context in
        if let path = CrashFile.pathCString {
            _ = CrashFile.recordSignal(s, to: path)
        }
        CrashFile.chain(s, info, context)
    }

    /// The signal handler's write: the signal record to `path`, unless an
    /// uncaught exception was already handled (`exceptionHandled`).
    /// Async-signal-safe. True when the record was written.
    static func recordSignal(_ s: Int32, to path: UnsafePointer<CChar>) -> Bool {
        guard !exceptionRecorded else { return false }
        let fd = open(path, O_WRONLY | O_CREAT | O_TRUNC, 0o644)
        guard fd >= 0 else { return false }
        CrashFile.writeSignalRecord(fd: fd, signal: s, seconds: Int(time(nil)))
        close(fd)
        return true
    }

    /// True once `markExceptionHandled()` ran or an exception record was written.
    static var exceptionHandled: Bool { exceptionRecorded }

    /// Tests only: forget a handled exception.
    static func clearExceptionHandled() {
        exceptionRecorded = false
    }

    /// Runs the handler installed before ours, or restores the default action
    /// and re-raises. Reading the dictionary is not strictly
    /// async-signal-safe, but it is never mutated after `install`.
    private static func chain(_ s: Int32, _ info: UnsafeMutablePointer<siginfo_t>?, _ context: UnsafeMutableRawPointer?) {
        if var previous = previousActions[s] {
            if previous.sa_flags & SA_SIGINFO != 0 {
                if let handler = previous.__sigaction_u.__sa_sigaction {
                    // Reinstall theirs first so a crash inside it cannot loop back here.
                    sigaction(s, &previous, nil)
                    handler(s, info, context)
                    return
                }
            } else if let handler = previous.__sigaction_u.__sa_handler {
                // nil is SIG_DFL (handled below); bit pattern 1 is SIG_IGN.
                let raw = unsafeBitCast(handler, to: UnsafeRawPointer.self)
                if raw != UnsafeRawPointer(bitPattern: 1) {
                    sigaction(s, &previous, nil)
                    handler(s)
                    return
                }
            }
        }
        signal(s, SIG_DFL)
        raise(s)
    }
    #endif
}
