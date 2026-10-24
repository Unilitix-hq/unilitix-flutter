// VENDORED from UnilitixCore 0.7.0 (CrashFile.swift) by scripts/sync-ios-core.sh.
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
///
/// 0.7.0 adds optional fields, for exact server-side symbolication
/// (`metadata.debugImages`, docs/symbolication.md in the api repo); records
/// without them are read as before:
/// - an exception record has `debugImages`, the images of its stack (from
///   `callStackReturnAddresses`);
/// - a signal record has the crashing thread's backtrace as raw addresses,
///   `frames` (and `linkRegister` on arm64), and the images they fall in,
///   `debugImages` with each one's `__TEXT` `size` (`SignalBacktrace`).
///   `consume` turns them into a `stackTrace` in `callStackSymbols` format
///   and `debugImages` in the event's format (`expandBacktrace`).
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

    /// The record for an uncaught exception; `debugImages` are its stack's
    /// images (left out when empty).
    static func exceptionRecord(type: String, message: String, stack: String, timestampMs: Int64,
                                debugImages: [DebugImage] = []) -> Data? {
        var record: [String: Any] = [
            "platform": "ios",
            "exceptionType": type,
            "exceptionMessage": message,
            "stackTrace": String(stack.prefix(maxStackLength)),
            "timestamp": timestampMs,
        ]
        if !debugImages.isEmpty { record["debugImages"] = debugImages.map { $0.dictionary } }
        return try? JSONSerialization.data(withJSONObject: record, options: [.sortedKeys])
    }

    /// Writes the record for `signal` to `fd` using write(2) and stack memory
    /// only, so it is async-signal-safe. The 0.5 format: no backtrace.
    static func writeSignalRecord(fd: Int32, signal: Int32, seconds: Int) {
        writeSignalFields(fd: fd, signal: signal, seconds: seconds)
        let end: StaticString = "}"
        end.withUTF8Buffer { _ = write(fd, $0.baseAddress, $0.count) }
    }

    /// The record without its closing brace. Async-signal-safe.
    private static func writeSignalFields(fd: Int32, signal: Int32, seconds: Int) {
        let prefix: StaticString = "{\"platform\":\"ios\",\"exceptionType\":\"SIGNAL\",\"signal\":"
        let middle: StaticString = ",\"timestamp\":"
        // Seconds → milliseconds by appending "000"; a zero (clock unavailable)
        // stays "0" so the JSON never has a number with a leading zero.
        let millis: StaticString = "000"
        prefix.withUTF8Buffer { _ = write(fd, $0.baseAddress, $0.count) }
        writeDecimal(fd, Int(signal))
        middle.withUTF8Buffer { _ = write(fd, $0.baseAddress, $0.count) }
        writeDecimal(fd, seconds)
        if seconds > 0 { millis.withUTF8Buffer { _ = write(fd, $0.baseAddress, $0.count) } }
    }

    #if canImport(Darwin)
    /// The signal record with the backtrace of the thread interrupted at
    /// `context` (the handler's ucontext) and its images
    /// (`SignalBacktrace`); without a readable context, the 0.5 record.
    /// Async-signal-safe.
    static func writeSignalRecord(fd: Int32, signal: Int32, seconds: Int, context: UnsafeMutableRawPointer?) {
        writeSignalFields(fd: fd, signal: signal, seconds: seconds)
        SignalBacktrace.write(fd: fd, context: context)
        let end: StaticString = "}"
        end.withUTF8Buffer { _ = write(fd, $0.baseAddress, $0.count) }
    }
    #endif

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
    /// signal, the key `SIGNAL:<n>` alone so each signal is its own group.
    /// The Dart SDK keys native records the same way. A signal's backtrace
    /// (0.7.0) is left out on purpose: signals grouped without a stack
    /// before, and symbolication must not change grouping.
    static func fingerprint(of record: [String: Any]) -> String {
        let type = record["exceptionType"] as? String ?? "NativeCrash"
        if let signal = intValue(record["signal"]) {
            return Fingerprint.of("\(type):\(signal)", stack: nil)
        }
        return Fingerprint.of(type, stack: record["stackTrace"] as? String)
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

    /// The record with `fingerprint` added and a signal's backtrace
    /// expanded (`expandBacktrace`); `symbols` names frames (default: this
    /// process's images, see `defaultSymbols`).
    static func withFingerprint(_ text: String, symbols: SymbolLookup? = CrashFile.defaultSymbols) -> String {
        guard let data = text.data(using: .utf8),
              var record = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else {
            return text
        }
        expandBacktrace(&record, symbols: symbols)
        record["fingerprint"] = fingerprint(of: record)
        guard let out = try? JSONSerialization.data(withJSONObject: record, options: [.sortedKeys]),
              let json = String(data: out, encoding: .utf8) else {
            return text
        }
        return json
    }

    // MARK: Signal backtraces (next launch)

    /// A symbol of an image: its name and its offset from the image's header.
    struct Symbol: Equatable {
        var name: String
        var start: UInt
    }

    /// Names the code at `offset` from the header of the image with LC_UUID
    /// `uuid`, or nil.
    typealias SymbolLookup = (_ uuid: String, _ offset: UInt) -> Symbol?

    /// This process's images (`BinaryImages.symbol`): a crashed frame gets a
    /// symbol name when the same binary is loaded now (same app build, same
    /// OS), as `callStackSymbols` would have printed it. Nil off Darwin.
    static var defaultSymbols: SymbolLookup? {
        #if canImport(Darwin)
        return { BinaryImages.symbol(uuid: $0, offset: $1) }
        #else
        return nil
        #endif
    }

    /// An image of the crashed process as the signal handler wrote it.
    struct CrashedImage: Equatable {
        var name: String
        /// "" when the image has no LC_UUID.
        var uuid: String
        var load: UInt
        var size: UInt
        var arch: String?

        func contains(_ address: UInt) -> Bool { address >= load && address - load < size }

        var debugImage: DebugImage? {
            uuid.isEmpty ? nil
                : DebugImage(name: name, uuid: uuid, loadAddress: DebugImage.formatAddress(load), arch: arch)
        }
    }

    /// Turns a signal record's raw backtrace (`frames`, `linkRegister`, and
    /// `debugImages` with sizes) into what an event carries: `stackTrace`,
    /// one `callStackSymbols`-format line per frame (`StackFormat.frame`,
    /// as `apple.go` and `Fingerprint` parse), mapped with the crashed
    /// process's images, never this one's; and `debugImages` in the event's
    /// format (`name`, `uuid`, `loadAddress`, `arch`), only the images that
    /// have frames and a UUID. A record without `frames` (0.5, or an
    /// exception) is left as is; so is an existing `stackTrace`.
    static func expandBacktrace(_ record: inout [String: Any], symbols: SymbolLookup?) {
        guard let raw = record["frames"] as? [Any] else { return }
        let frames = raw.compactMap { ($0 as? String).flatMap(hexValue) }
        guard let pc = frames.first else { return }
        let images = crashedImages(record["debugImages"])
        var addresses = [pc]
        let lr = (record["linkRegister"] as? String).flatMap(hexValue) ?? 0
        if lr != 0, lr != pc, frames.count < 2 || lr != frames[1],
           !sameFunction(pc, lr, images: images, symbols: symbols) {
            addresses.append(lr)
        }
        addresses.append(contentsOf: frames.dropFirst())

        if (record["stackTrace"] as? String ?? "").isEmpty {
            record["stackTrace"] = String(backtraceStack(addresses, images: images, symbols: symbols)
                .prefix(maxStackLength))
        }
        var used: [DebugImage] = []
        var seen = Set<UInt>()
        for (i, address) in addresses.enumerated() {
            let lookup = i == 0 ? address : address &- 1
            guard let image = images.first(where: { $0.contains(lookup) }), seen.insert(image.load).inserted,
                  let d = image.debugImage else { continue }
            used.append(d)
        }
        if used.isEmpty {
            record.removeValue(forKey: "debugImages")
        } else {
            record["debugImages"] = used.map { $0.dictionary }
        }
    }

    /// One line per address, `callStackSymbols` style: `Image 0x… symbol +
    /// offset` when `symbols` names it, else `Image 0x… Image + offset` (the
    /// offset from the image's header, which the server reads as
    /// `__TEXT.vmaddr + offset`), or `??? 0x… 0x0 + address` outside every
    /// image. The first address is the pc; the others are return addresses,
    /// looked up one byte back.
    static func backtraceStack(_ addresses: [UInt], images: [CrashedImage], symbols: SymbolLookup?) -> String {
        var lines: [String] = []
        for (i, address) in addresses.enumerated() {
            let lookup = i == 0 ? address : address &- 1
            guard let image = images.first(where: { $0.contains(lookup) }) else {
                lines.append(StackFormat.frame(index: i, image: "???", address: address, symbol: "0x0", offset: address))
                continue
            }
            let offset = address - image.load
            var symbol = image.name
            var symbolOffset = offset
            if !image.uuid.isEmpty, let s = symbols?(image.uuid, lookup - image.load), s.start <= offset {
                symbol = s.name
                symbolOffset = offset - s.start
            }
            lines.append(StackFormat.frame(index: i, image: image.name, address: address, symbol: symbol,
                                           offset: symbolOffset))
        }
        return lines.joined(separator: "\n")
    }

    /// True when the link register points into the function that crashed
    /// (the function had already saved it and made another call, so it is
    /// stale, not the caller). Only known when `symbols` names both;
    /// otherwise the link register is kept as a frame: in a leaf function,
    /// and in the `abort()`/`__pthread_kill` path of most SIGABRTs, it is
    /// the only record of the caller.
    private static func sameFunction(_ pc: UInt, _ lr: UInt, images: [CrashedImage], symbols: SymbolLookup?) -> Bool {
        guard let symbols = symbols,
              let image = images.first(where: { $0.contains(pc) }), image.contains(lr &- 1), !image.uuid.isEmpty,
              let a = symbols(image.uuid, pc - image.load),
              let b = symbols(image.uuid, lr &- 1 - image.load) else { return false }
        return a == b
    }

    /// The images of a signal record (`debugImages` with `size`); entries
    /// that cannot be read are skipped.
    static func crashedImages(_ value: Any?) -> [CrashedImage] {
        guard let list = value as? [Any] else { return [] }
        return list.compactMap { item in
            guard let m = item as? [String: Any], let name = m["name"] as? String, !name.isEmpty,
                  let load = (m["loadAddress"] as? String).flatMap(hexValue), load != 0,
                  let size = intValue(m["size"]), size > 0 else { return nil }
            return CrashedImage(name: name, uuid: (m["uuid"] as? String ?? "").uppercased(), load: load,
                                size: UInt(size), arch: m["arch"] as? String)
        }
    }

    /// `metadata.debugImages` of a record (exception or expanded signal):
    /// entries with a name, UUID and load address.
    static func debugImages(in record: [String: Any]) -> [DebugImage] {
        guard let list = record["debugImages"] as? [Any] else { return [] }
        return list.compactMap { item in
            guard let m = item as? [String: Any],
                  let name = m["name"] as? String, !name.isEmpty,
                  let uuid = m["uuid"] as? String, !uuid.isEmpty,
                  let load = m["loadAddress"] as? String, hexValue(load) != nil else { return nil }
            return DebugImage(name: name, uuid: uuid, loadAddress: load, arch: m["arch"] as? String)
        }
    }

    /// `0x1a2b` (or `1a2b`) → 0x1a2b.
    static func hexValue(_ s: String) -> UInt? {
        let digits = s.hasPrefix("0x") || s.hasPrefix("0X") ? String(s.dropFirst(2)) : s
        return digits.isEmpty ? nil : UInt(digits, radix: 16)
    }

    /// `s` as a JSON string literal, quotes included.
    static func jsonString(_ s: String) -> String {
        var out = "\""
        for u in s.unicodeScalars {
            switch u {
            case "\"": out += "\\\""
            case "\\": out += "\\\\"
            case "\n": out += "\\n"
            case "\r": out += "\\r"
            case "\t": out += "\\t"
            default:
                if u.value < 0x20 {
                    let hex = String(u.value, radix: 16)
                    out += "\\u" + String(repeating: "0", count: 4 - hex.count) + hex
                } else {
                    out.unicodeScalars.append(u)
                }
            }
        }
        return out + "\""
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
        installSignalHandlers(path: path)  // tracks the loaded images first
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
        // The image table the handler looks frames up in, complete before any
        // handler can run.
        BinaryImages.install()
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
            timestampMs: Int64(Date().timeIntervalSince1970 * 1000),
            debugImages: BinaryImages.debugImages(
                returnAddresses: exception.callStackReturnAddresses.map { $0.uintValue }))
        guard let d = data, (try? d.write(to: URL(fileURLWithPath: path))) != nil else { return false }
        exceptionRecorded = true
        return true
    }

    /// Async-signal-safe: open/write/close/time on pre-built buffers, the
    /// backtrace from `context` (`SignalBacktrace`), then the previous
    /// handler (or the default action).
    private static let handleSignal: @convention(c) (Int32, UnsafeMutablePointer<siginfo_t>?, UnsafeMutableRawPointer?) -> Void = { s, info, context in
        if let path = CrashFile.pathCString {
            _ = CrashFile.recordSignal(s, to: path, context: context)
        }
        CrashFile.chain(s, info, context)
    }

    /// The signal handler's write: the signal record to `path`, with the
    /// backtrace of the thread interrupted at `context` (the handler's
    /// ucontext; nil: none), unless an uncaught exception was already
    /// handled (`exceptionHandled`). Async-signal-safe. True when the record
    /// was written.
    static func recordSignal(_ s: Int32, to path: UnsafePointer<CChar>,
                             context: UnsafeMutableRawPointer? = nil) -> Bool {
        guard !exceptionRecorded else { return false }
        let fd = open(path, O_WRONLY | O_CREAT | O_TRUNC, 0o644)
        guard fd >= 0 else { return false }
        CrashFile.writeSignalRecord(fd: fd, signal: s, seconds: Int(time(nil)), context: context)
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
