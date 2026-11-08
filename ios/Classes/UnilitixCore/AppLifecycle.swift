// VENDORED from UnilitixCore 0.8.0 (AppLifecycle.swift) by scripts/sync-ios-core.sh.
// Do not edit here; change UnilitixCore and re-run the script.

import Foundation
#if canImport(UIKit) && !os(watchOS)
import UIKit
#endif

/// Where the SDK runs: an app or an app extension (.appex).
///
/// App-extension safety (0.8.0): `UIApplication.shared` is unavailable to
/// app extensions, and a module that names it does not link into a target
/// built with "Require Only App-Extension-Safe API". The SDK never names it:
/// `application` looks the shared application up at run time and is nil
/// inside an extension. Marking the UIKit code
/// `@available(iOSApplicationExtension, unavailable)` instead would make
/// `Unilitix.start` itself unavailable to extensions, which may use the
/// SDK for events and crashes. In an extension, automatic capture (screens,
/// taps, replay), the app-hang watchdog, background tasks and termination
/// inference are not installed.
enum AppContext {
    static let isAppExtension: Bool = Bundle.main.bundlePath.hasSuffix(".appex")

    #if canImport(UIKit) && !os(watchOS)
    /// The shared application; nil in an app extension or before it exists.
    static var application: UIApplication? {
        guard !isAppExtension else { return nil }
        let selector = NSSelectorFromString("sharedApplication")
        guard UIApplication.responds(to: selector),
              let app = UIApplication.perform(selector)?.takeUnretainedValue() as? UIApplication else { return nil }
        return app
    }

    /// The application is in the foreground (active or inactive); false in
    /// an extension or when unknown. Main thread.
    static var isInForeground: Bool {
        guard let app = application else { return false }
        return app.applicationState != .background
    }
    #endif
}

#if canImport(UIKit) && !os(watchOS)
/// A UIKit background task around the flush on entering the background, so
/// the upload in flight and the queue write can finish before suspension.
/// Ended once the uploads are idle, after `maxSeconds`, or when iOS
/// expires it, whichever comes first. Moved here from Unilitix.swift in
/// 0.8.0 so wrapper plugins (which vendor every file but that one) can use it.
final class BackgroundFlushTask {
    /// Below the roughly 30 s iOS grants a background task.
    static let maxSeconds: TimeInterval = 25

    private let lock = NSLock()
    private var id: UIBackgroundTaskIdentifier = .invalid
    private var ended = false

    /// True in an app extension, where `UIApplication.shared` must not be used.
    static var isAppExtension: Bool { AppContext.isAppExtension }

    /// Begins a task; nil in an app extension or when iOS refuses one.
    static func begin() -> BackgroundFlushTask? {
        guard let app = AppContext.application else { return nil }
        let task = BackgroundFlushTask()
        let id = app.beginBackgroundTask(withName: "io.unilitix.flush") { [weak task] in
            task?.end()
        }
        guard id != .invalid else { return nil }
        task.lock.lock()
        let endNow = task.ended  // expired before we got here
        if !endNow { task.id = id }
        task.lock.unlock()
        if endNow { app.endBackgroundTask(id) }
        return task
    }

    /// Ends the task, once. Any thread.
    func end() {
        lock.lock()
        let t = id
        id = .invalid
        ended = true
        lock.unlock()
        guard t != .invalid else { return }
        if Thread.isMainThread {
            AppContext.application?.endBackgroundTask(t)
        } else {
            DispatchQueue.main.async { AppContext.application?.endBackgroundTask(t) }
        }
    }
}
#endif

/// The app-lifecycle hooks an engine needs, for the `Unilitix` facade and
/// for wrapper plugins that drive an `Engine` themselves:
///
/// - entering the background: flush inside a background task (apps), save
///   the queue; an app extension's host going to the background does the
///   same without the task;
/// - returning: a new session after `sessionTimeoutSeconds`;
/// - `willTerminate`: save the queue synchronously, mark a clean exit;
/// - memory warnings and foreground state for `TerminationTracker`.
enum LifecycleObserver {
    /// Installs the observers and returns them (keep them to stay subscribed).
    static func install(_ e: Engine) -> [NSObjectProtocol] {
        var observers: [NSObjectProtocol] = []
        let nc = NotificationCenter.default
        #if canImport(UIKit) && !os(watchOS)
        let background: (Notification) -> Void = { _ in
            // Asks iOS for time to finish the upload and the queue write
            // (apps only; nil in app extensions).
            let task = BackgroundFlushTask.begin()
            e.queue.async {
                e.didEnterBackground()
                e.whenUploadsIdle(timeout: BackgroundFlushTask.maxSeconds) { task?.end() }
            }
        }
        let foreground: (Notification) -> Void = { _ in e.queue.async { e.willEnterForeground() } }
        if AppContext.isAppExtension {
            #if os(iOS)
            observers.append(nc.addObserver(forName: .NSExtensionHostDidEnterBackground, object: nil, queue: nil,
                                            using: background))
            observers.append(nc.addObserver(forName: .NSExtensionHostWillEnterForeground, object: nil, queue: nil,
                                            using: foreground))
            #endif
        } else {
            observers.append(nc.addObserver(forName: UIApplication.didEnterBackgroundNotification, object: nil,
                                            queue: nil, using: background))
            observers.append(nc.addObserver(forName: UIApplication.willEnterForegroundNotification, object: nil,
                                            queue: nil, using: foreground))
            observers.append(nc.addObserver(forName: UIApplication.didBecomeActiveNotification, object: nil,
                                            queue: nil) { _ in e.terminationTracker?.setForeground(true) })
            observers.append(nc.addObserver(forName: UIApplication.willTerminateNotification, object: nil,
                                            queue: nil) { _ in e.willTerminate() })
            observers.append(nc.addObserver(forName: UIApplication.didReceiveMemoryWarningNotification,
                                            object: nil, queue: nil) { _ in e.terminationTracker?.memoryWarning() })
            if let tracker = e.terminationTracker {
                DispatchQueue.main.async { tracker.setForeground(AppContext.isInForeground) }
            }
        }
        #else
        _ = nc
        #endif
        return observers
    }
}
