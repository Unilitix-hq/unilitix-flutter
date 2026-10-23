// VENDORED from UnilitixCore 0.4.1 (CrashReporter.swift) by scripts/sync-ios-core.sh.
// Do not edit here; change UnilitixCore and re-run the script.

import Foundation

/// Reports uncaught Objective-C exceptions, then hands over to the handler
/// that was installed before (another SDK's or the system's).
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
        engine = e
        previous = NSGetUncaughtExceptionHandler()
        NSSetUncaughtExceptionHandler { exception in
            let name = exception.name.rawValue
            if !CrashReporter.ignoredNamePrefixes.contains(where: { name.hasPrefix($0) }) {
                CrashReporter.engine?.recordFatalSynchronously(
                    type: name,
                    message: exception.reason ?? "",
                    stack: exception.callStackSymbols.joined(separator: "\n"))
            }
            CrashReporter.previous?(exception)
        }
    }
}
