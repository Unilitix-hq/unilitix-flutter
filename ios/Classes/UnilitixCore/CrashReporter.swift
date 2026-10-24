// VENDORED from UnilitixCore 0.7.0 (CrashReporter.swift) by scripts/sync-ios-core.sh.
// Do not edit here; change UnilitixCore and re-run the script.

import Foundation

/// Reports uncaught Objective-C exceptions, then hands over to the handler
/// that was installed before (another SDK's or the system's).
///
/// Fatal signals are `CrashFile`'s (installed alongside with
/// `CrashFile.installSignalHandlers(path:)`). An uncaught exception ends in
/// abort(), so every exception seen here, reported or ignored, is marked
/// handled there: the SIGABRT that follows is not reported a second time.
enum CrashReporter {
    private static weak var engine: Engine?
    private static var previous: (@convention(c) (NSException) -> Void)?
    private static var installed = false

    /// Exceptions whose name starts with one of these are not reported because
    /// a higher layer already reported the error that caused them (React
    /// Native raises `RCTFatalException` after its JS handler has run).
    static var ignoredNamePrefixes: [String] = []

    static func install(_ e: Engine) {
        guard !installed else { return }
        installed = true
        #if canImport(Darwin)
        BinaryImages.install()  // so the handler only looks images up
        #endif
        engine = e
        previous = NSGetUncaughtExceptionHandler()
        NSSetUncaughtExceptionHandler { exception in
            CrashReporter.handle(exception, engine: CrashReporter.engine)
            CrashReporter.previous?(exception)
        }
    }

    /// Reports `exception` to `engine` unless its name is ignored, and keeps
    /// the signal handlers from recording the abort that follows. When the
    /// store cannot take the report within the fatal budget, it goes to the
    /// crash file instead (if signal capture is installed), to be reported
    /// on the next launch. Returns false when the exception was ignored or
    /// could be kept neither in the store nor in the file.
    @discardableResult
    static func handle(_ exception: NSException, engine: Engine?) -> Bool {
        #if canImport(Darwin)
        CrashFile.markExceptionHandled()
        #endif
        let name = exception.name.rawValue
        if ignoredNamePrefixes.contains(where: { name.hasPrefix($0) }) { return false }
        let stack = exception.callStackSymbols.joined(separator: "\n")
        // The images of the stack's return addresses (a lookup in the table
        // BinaryImages keeps), for exact symbolication.
        #if canImport(Darwin)
        let images = BinaryImages.debugImages(
            returnAddresses: exception.callStackReturnAddresses.map { $0.uintValue })
        #else
        let images: [DebugImage] = []
        #endif
        let stored = engine?.recordFatalSynchronously(type: name, message: exception.reason ?? "", stack: stack,
                                                      debugImages: images)
        #if canImport(Darwin)
        if stored == false { return CrashFile.record(exception) }
        #endif
        return stored ?? false
    }
}
