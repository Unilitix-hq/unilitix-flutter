// VENDORED from UnilitixCore 0.4.1 (ScreenshotStore.swift) by scripts/sync-ios-core.sh.
// Do not edit here; change UnilitixCore and re-run the script.

import Foundation

/// A screenshot waiting to be uploaded. The JPEG lives next to it on disk.
struct PendingScreenshot: Codable, Equatable {
    var sessionId: String
    var ordinal: Int
    var screenName: String
    var capturedAt: Date
    /// Window size in points.
    var viewportWidth: Int
    var viewportHeight: Int
    /// JPEG size.
    var bytes: Int
    /// PUTs to storage that were refused (4xx); the frame is dropped at
    /// `ScreenshotStore.maxFailedUploads`.
    var failedUploads: Int = 0
}

/// Screenshots waiting for upload, persisted as
/// `<directory>/<sessionId>/<ordinal>.jpg` plus `<ordinal>.json` (metadata,
/// written last, so a frame without it is incomplete and discarded on load).
///
/// Bounded by `maxBytes` of JPEG data and `maxAge`: the oldest frames go
/// first. The directory is excluded from backups. Thread-safe.
final class ScreenshotStore {
    static let defaultMaxBytes = 50 * 1024 * 1024
    static let maxAge: TimeInterval = 7 * 24 * 3600
    static let maxFailedUploads = 3

    private let root: URL?
    private let maxBytes: Int
    private let lock = NSLock()
    private let fm = FileManager.default
    /// Capture order: oldest first.
    private var frames: [PendingScreenshot] = []
    private var totalBytes = 0
    /// JPEG data when there is no directory (tests).
    private var memory: [String: Data] = [:]

    /// `directory` nil keeps everything in memory (tests).
    init(directory: URL?, maxBytes: Int = ScreenshotStore.defaultMaxBytes, now: Date = Date()) {
        self.maxBytes = max(1, maxBytes)
        root = directory
        if let dir = directory {
            try? fm.createDirectory(at: dir, withIntermediateDirectories: true)
            var url = dir
            var values = URLResourceValues()
            values.isExcludedFromBackup = true
            try? url.setResourceValues(values)
            load(now: now)
        }
    }

    static var defaultDirectory: URL? {
        EventStore.defaultDirectory?.appendingPathComponent("screenshots", isDirectory: true)
    }

    // MARK: Reads

    var count: Int { withLock { frames.count } }

    var byteCount: Int { withLock { totalBytes } }

    /// Up to `limit` frames of the oldest session that has any, in ordinal order.
    func nextUpload(limit: Int) -> (sessionId: String, frames: [PendingScreenshot])? {
        withLock { () -> (sessionId: String, frames: [PendingScreenshot])? in
            guard let first = frames.first else { return nil }
            let batch = frames.filter { $0.sessionId == first.sessionId }
                .sorted { $0.ordinal < $1.ordinal }
                .prefix(max(1, limit))
            return (first.sessionId, Array(batch))
        }
    }

    func data(for frame: PendingScreenshot) -> Data? {
        withLock { () -> Data? in
            guard root != nil else { return memory[key(frame)] }
            guard let url = imageURL(frame) else { return nil }
            return try? Data(contentsOf: url)
        }
    }

    // MARK: Writes

    /// Stores a frame. False when it could not be written.
    @discardableResult
    func add(_ frame: PendingScreenshot, jpeg: Data) -> Bool {
        guard ScreenshotStore.isSafe(frame.sessionId) else { return false }
        var meta = frame
        meta.bytes = jpeg.count
        return withLock { () -> Bool in
            if let dir = sessionDirectory(meta.sessionId), let img = imageURL(meta), let json = metaURL(meta) {
                do {
                    try fm.createDirectory(at: dir, withIntermediateDirectories: true)
                    try jpeg.write(to: img, options: ScreenshotStore.writeOptions)
                    try JSONEncoder().encode(meta).write(to: json, options: ScreenshotStore.writeOptions)
                } catch {
                    try? fm.removeItem(at: img)
                    try? fm.removeItem(at: json)
                    return false
                }
            } else if root == nil {
                memory[key(meta)] = jpeg
            } else {
                return false
            }
            frames.removeAll { $0.sessionId == meta.sessionId && $0.ordinal == meta.ordinal }
            frames.append(meta)
            recountLocked()
            trimLocked()
            return true
        }
    }

    /// Forgets frames that were uploaded and confirmed, or can never be.
    func remove(_ done: [PendingScreenshot]) {
        withLock {
            for f in done { deleteLocked(f) }
            recountLocked()
        }
    }

    /// Counts a refused upload; drops the frame at `maxFailedUploads`.
    /// Returns true when the frame was dropped.
    @discardableResult
    func recordFailedUpload(_ frame: PendingScreenshot) -> Bool {
        withLock { () -> Bool in
            guard let i = frames.firstIndex(where: { $0.sessionId == frame.sessionId && $0.ordinal == frame.ordinal })
            else { return false }
            frames[i].failedUploads += 1
            if frames[i].failedUploads >= ScreenshotStore.maxFailedUploads {
                deleteLocked(frames[i])
                recountLocked()
                return true
            }
            if let json = metaURL(frames[i]), let data = try? JSONEncoder().encode(frames[i]) {
                try? data.write(to: json, options: ScreenshotStore.writeOptions)
            }
            return false
        }
    }

    /// Consent denied: delete every frame.
    func purge() {
        withLock {
            for f in frames { deleteLocked(f) }
            frames.removeAll()
            memory.removeAll()
            totalBytes = 0
            if let dir = root, let sessions = try? fm.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil) {
                for s in sessions { try? fm.removeItem(at: s) }
            }
        }
    }

    // MARK: Internals

    private static var writeOptions: Data.WritingOptions {
        #if os(iOS)
        return [.atomic, .completeFileProtectionUntilFirstUserAuthentication]
        #else
        return [.atomic]
        #endif
    }

    /// Session ids name directories: lowercase UUIDs only, nothing that
    /// could escape the store.
    static func isSafe(_ sessionId: String) -> Bool {
        !sessionId.isEmpty && sessionId.count <= 64 && sessionId.allSatisfy { c in
            c.isASCII && (c.isLetter || c.isNumber || c == "-")
        }
    }

    private func key(_ f: PendingScreenshot) -> String { "\(f.sessionId)/\(f.ordinal)" }

    private func sessionDirectory(_ sessionId: String) -> URL? {
        root?.appendingPathComponent(sessionId, isDirectory: true)
    }

    private func imageURL(_ f: PendingScreenshot) -> URL? {
        sessionDirectory(f.sessionId)?.appendingPathComponent("\(f.ordinal).jpg")
    }

    private func metaURL(_ f: PendingScreenshot) -> URL? {
        sessionDirectory(f.sessionId)?.appendingPathComponent("\(f.ordinal).json")
    }

    private func deleteLocked(_ f: PendingScreenshot) {
        frames.removeAll { $0.sessionId == f.sessionId && $0.ordinal == f.ordinal }
        memory[key(f)] = nil
        if let img = imageURL(f) { try? fm.removeItem(at: img) }
        if let json = metaURL(f) { try? fm.removeItem(at: json) }
        if let dir = sessionDirectory(f.sessionId),
           let left = try? fm.contentsOfDirectory(atPath: dir.path), left.isEmpty {
            try? fm.removeItem(at: dir)
        }
    }

    private func recountLocked() {
        totalBytes = frames.reduce(0) { $0 + $1.bytes }
    }

    private func trimLocked() {
        while totalBytes > maxBytes, frames.count > 1 {
            deleteLocked(frames[0])
            recountLocked()
        }
    }

    private func load(now: Date) {
        guard let dir = root,
              let sessions = try? fm.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil) else { return }
        var loaded: [PendingScreenshot] = []
        for sessionDir in sessions {
            guard ScreenshotStore.isSafe(sessionDir.lastPathComponent),
                  let files = try? fm.contentsOfDirectory(at: sessionDir, includingPropertiesForKeys: nil) else {
                try? fm.removeItem(at: sessionDir)
                continue
            }
            var images = Set(files.filter { $0.pathExtension == "jpg" }.map { $0.deletingPathExtension().lastPathComponent })
            for json in files where json.pathExtension == "json" {
                let name = json.deletingPathExtension().lastPathComponent
                guard images.contains(name),
                      let data = try? Data(contentsOf: json),
                      let meta = try? JSONDecoder().decode(PendingScreenshot.self, from: data),
                      meta.sessionId == sessionDir.lastPathComponent, "\(meta.ordinal)" == name,
                      now.timeIntervalSince(meta.capturedAt) < ScreenshotStore.maxAge else {
                    try? fm.removeItem(at: json)
                    continue
                }
                images.remove(name)
                loaded.append(meta)
            }
            // Images without metadata are incomplete writes or expired frames.
            for name in images {
                try? fm.removeItem(at: sessionDir.appendingPathComponent("\(name).jpg"))
            }
            if let left = try? fm.contentsOfDirectory(atPath: sessionDir.path), left.isEmpty {
                try? fm.removeItem(at: sessionDir)
            }
        }
        frames = loaded.sorted {
            $0.capturedAt == $1.capturedAt ? $0.ordinal < $1.ordinal : $0.capturedAt < $1.capturedAt
        }
        recountLocked()
        trimLocked()
    }

    private func withLock<T>(_ body: () -> T) -> T {
        lock.lock(); defer { lock.unlock() }
        return body()
    }
}
