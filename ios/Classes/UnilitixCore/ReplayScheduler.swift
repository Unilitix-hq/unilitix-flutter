// VENDORED from UnilitixCore 0.7.0 (ReplayScheduler.swift) by scripts/sync-ios-core.sh.
// Do not edit here; change UnilitixCore and re-run the script.

import Foundation

/// Decides when the next screenshot is taken. Same rules as the Flutter
/// SDK's `ScreenshotCapture`: capture is change-driven, not timer-driven.
///
/// - A frame is wanted when the screen was marked dirty (a touch, a scroll,
///   a new screen) and at least `interval` passed since the last frame, or
///   when `heartbeat` passed on a static screen.
/// - A rolling one-minute budget (`maxPerMinute`) stops a screen that
///   redraws continuously from flooding the session.
/// - The first frame of every session is wanted immediately.
///
/// Pure logic with an injected clock, so it is unit-tested on macOS. Not
/// thread-safe; the capturer uses it on the main thread.
struct ReplayScheduler {
    let interval: TimeInterval
    /// `.infinity` when the heartbeat is off (`screenshotHeartbeatMs <= 0`).
    let heartbeat: TimeInterval
    let maxPerMinute: Int

    private(set) var dirty = true
    private var lastCapture: TimeInterval?
    private var recent: [TimeInterval] = []
    private var session: String?

    init(intervalMs: Int, heartbeatMs: Int, maxPerMinute: Int) {
        interval = TimeInterval(max(0, intervalMs)) / 1000
        heartbeat = heartbeatMs > 0 ? TimeInterval(max(heartbeatMs, intervalMs)) / 1000 : .infinity
        self.maxPerMinute = max(0, maxPerMinute)
    }

    /// The screen changed; the next check after `interval` captures.
    mutating func markDirty() {
        dirty = true
    }

    /// True when a frame should be taken now for `sessionId`. A true answer
    /// spends one unit of the per-minute budget and clears the dirty flag.
    /// `now` is any monotonic clock in seconds.
    mutating func shouldCapture(at now: TimeInterval, sessionId: String) -> Bool {
        if sessionId != session {
            session = sessionId
            dirty = true
            lastCapture = nil
            recent.removeAll()
        }
        let since = lastCapture.map { now - $0 } ?? .infinity
        let wanted = (dirty && since >= interval) || since >= heartbeat
        guard wanted else { return false }
        recent.removeAll { now - $0 >= 60 }
        guard recent.count < maxPerMinute else { return false }
        recent.append(now)
        dirty = false
        lastCapture = now
        return true
    }
}

/// `replaySampleRate`: whether a session captures replay, decided once when
/// the session starts.
enum ReplaySampling {
    /// `roll` is uniform in [0, 1).
    static func isSampled(rate: Double, roll: Double) -> Bool {
        guard rate.isFinite, rate > 0 else { return false }
        if rate >= 1 { return true }
        return roll < rate
    }
}

/// What the capturer needs to know on the main thread: the session frames
/// belong to and the current screen name. Nil from `Engine.replayGate()`
/// means no frame is wanted (replay off, session not sampled, consent
/// denied, or the session's cap reached).
struct ReplayGate: Equatable {
    let sessionId: String
    let screen: String
}
