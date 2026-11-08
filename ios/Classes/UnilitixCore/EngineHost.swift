// VENDORED from UnilitixCore 0.8.0 (EngineHost.swift) by scripts/sync-ios-core.sh.
// Do not edit here; change UnilitixCore and re-run the script.

import Foundation

/// One engine per process, and the calls made before it exists: the
/// contract's pre-init buffer (`SdkContract.preInitBufferSize` calls, the
/// oldest dropped), replayed in order right after the first session starts.
///
/// The `Unilitix` facade keeps one in a static; wrapper plugins (which vendor
/// these sources without Unilitix.swift) and the behaviour-fixture runner
/// can keep their own.
final class EngineHost {
    private let lock = NSLock()
    private var engine: Engine?
    /// `claim` succeeded and `attach` has not run yet (calls still buffered).
    private var starting = false
    private var preStart: [(Engine) -> Void] = []
    let bufferSize: Int

    init(bufferSize: Int = SdkContract.preInitBufferSize) {
        self.bufferSize = max(0, bufferSize)
    }

    /// The engine once `attach` ran.
    var current: Engine? { withLock { engine } }

    /// True for the first caller: it builds the engine and calls `attach`.
    /// Later calls (a second `start`) get false.
    func claim() -> Bool {
        withLock {
            guard engine == nil, !starting else { return false }
            starting = true
            return true
        }
    }

    /// Publishes `e` and queues, in this order on its queue: `start()` (the
    /// persisted state, the first session), then the buffered calls. Enqueued
    /// under the lock, so it runs before any call that finds the engine.
    func attach(_ e: Engine, beforeStart: ((Engine) -> Void)? = nil) {
        withLock {
            engine = e
            starting = false
            let calls = preStart
            preStart = []
            e.queue.async {
                beforeStart?(e)
                e.start()
                calls.forEach { $0(e) }
            }
        }
    }

    /// Runs `call` on the engine's queue, or buffers it until `attach`
    /// (`buffered` false: dropped before then, e.g. replay frames).
    func run(buffered: Bool = true, _ call: @escaping (Engine) -> Void) {
        let e = withLock { () -> Engine? in
            if let e = engine { return e }
            guard buffered, bufferSize > 0 else { return nil }
            if preStart.count >= bufferSize { preStart.removeFirst(preStart.count - bufferSize + 1) }
            preStart.append(call)
            return nil
        }
        guard let engine = e else { return }
        engine.queue.async { call(engine) }
    }

    /// Runs `call` on the engine's queue and waits up to `timeout` for it
    /// (fatal errors, before the process ends). Runs inline when already on
    /// the queue; buffered like `run` before `attach`.
    func runAndWait(timeout: TimeInterval, _ call: @escaping (Engine) -> Void) {
        guard let e = current else { run(call); return }
        if e.isOnQueue { call(e); return }
        let done = DispatchSemaphore(value: 0)
        e.queue.async {
            call(e)
            done.signal()
        }
        _ = done.wait(timeout: .now() + timeout)
    }

    private func withLock<T>(_ body: () -> T) -> T {
        lock.lock(); defer { lock.unlock() }
        return body()
    }
}
