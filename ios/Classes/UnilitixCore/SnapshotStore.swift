// VENDORED from UnilitixCore 0.6.0 (SnapshotStore.swift) by scripts/sync-ios-core.sh.
// Do not edit here; change UnilitixCore and re-run the script.

import Foundation

/// View-tree snapshots waiting for upload, persisted next to the event queue
/// as `<directory>/<sessionId>/<ordinal>.json` (one encoded
/// `PendingSnapshot` each, written atomically).
///
/// Only an index (session, ordinal, time, size) is kept in memory; trees are
/// read back when they are uploaded. Loading at launch reads directory
/// listings only, no file contents. Bounded by `maxCount` snapshots,
/// `maxBytes` and `maxAge`: the oldest go first. The directory is excluded
/// from backups. Thread-safe.
final class SnapshotStore {
    /// About 10 minutes of a changing screen at one snapshot a second
    /// (Android holds 300 in memory).
    static let defaultMaxCount = 600
    static let defaultMaxBytes = 20 * 1024 * 1024
    static let maxAge: TimeInterval = 7 * 24 * 3600

    struct Entry: Equatable {
        var sessionId: String
        var ordinal: Int
        var capturedAt: Date
        var bytes: Int
    }

    private let root: URL?
    private let maxCount: Int
    private let maxBytes: Int
    private let lock = NSLock()
    private let fm = FileManager.default
    /// Capture order: oldest first.
    private var entries: [Entry] = []
    private var totalBytes = 0
    /// Encoded snapshots when there is no directory (tests).
    private var memory: [String: Data] = [:]

    /// `directory` nil keeps everything in memory (tests).
    init(directory: URL?, maxCount: Int = SnapshotStore.defaultMaxCount,
         maxBytes: Int = SnapshotStore.defaultMaxBytes, now: Date = Date()) {
        self.maxCount = max(1, maxCount)
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
        EventStore.defaultDirectory?.appendingPathComponent("snapshots", isDirectory: true)
    }

    // MARK: Reads

    var count: Int { withLock { entries.count } }

    var byteCount: Int { withLock { totalBytes } }

    /// Up to `limit` snapshots of the oldest session that has any, in ordinal
    /// order. Snapshots that can no longer be read are forgotten.
    func nextUpload(limit: Int) -> (sessionId: String, snapshots: [PendingSnapshot])? {
        withLock { () -> (sessionId: String, snapshots: [PendingSnapshot])? in
            while let first = entries.first {
                let batch = entries.filter { $0.sessionId == first.sessionId }
                    .sorted { $0.ordinal < $1.ordinal }
                    .prefix(max(1, limit))
                var out: [PendingSnapshot] = []
                for e in batch {
                    if let data = readLocked(e),
                       let s = try? JSONDecoder().decode(PendingSnapshot.self, from: data),
                       s.sessionId == e.sessionId, s.ordinal == e.ordinal {
                        out.append(s)
                    } else {
                        deleteLocked(e)
                    }
                }
                recountLocked()
                if !out.isEmpty { return (first.sessionId, out) }
            }
            return nil
        }
    }

    // MARK: Writes

    /// Stores a snapshot. False when it could not be written.
    @discardableResult
    func add(_ snapshot: PendingSnapshot) -> Bool {
        guard ScreenshotStore.isSafe(snapshot.sessionId), snapshot.ordinal >= 0,
              let data = try? JSONEncoder().encode(snapshot) else { return false }
        let entry = Entry(sessionId: snapshot.sessionId, ordinal: snapshot.ordinal,
                          capturedAt: snapshot.capturedAt, bytes: data.count)
        return withLock { () -> Bool in
            if let dir = sessionDirectory(entry.sessionId), let url = fileURL(entry) {
                do {
                    try fm.createDirectory(at: dir, withIntermediateDirectories: true)
                    try data.write(to: url, options: SnapshotStore.writeOptions)
                } catch {
                    try? fm.removeItem(at: url)
                    return false
                }
            } else if root == nil {
                memory[key(entry)] = data
            } else {
                return false
            }
            entries.removeAll { $0.sessionId == entry.sessionId && $0.ordinal == entry.ordinal }
            entries.append(entry)
            recountLocked()
            trimLocked()
            return true
        }
    }

    /// Forgets snapshots that were uploaded, or can never be.
    func remove(_ done: [PendingSnapshot]) {
        withLock {
            for s in done {
                if let e = entries.first(where: { $0.sessionId == s.sessionId && $0.ordinal == s.ordinal }) {
                    deleteLocked(e)
                }
            }
            recountLocked()
        }
    }

    /// Consent denied: delete every snapshot.
    func purge() {
        withLock {
            for e in entries { deleteLocked(e) }
            entries.removeAll()
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

    private func key(_ e: Entry) -> String { "\(e.sessionId)/\(e.ordinal)" }

    private func sessionDirectory(_ sessionId: String) -> URL? {
        root?.appendingPathComponent(sessionId, isDirectory: true)
    }

    private func fileURL(_ e: Entry) -> URL? {
        sessionDirectory(e.sessionId)?.appendingPathComponent("\(e.ordinal).json")
    }

    private func readLocked(_ e: Entry) -> Data? {
        guard root != nil else { return memory[key(e)] }
        guard let url = fileURL(e) else { return nil }
        return try? Data(contentsOf: url)
    }

    private func deleteLocked(_ e: Entry) {
        entries.removeAll { $0.sessionId == e.sessionId && $0.ordinal == e.ordinal }
        memory[key(e)] = nil
        if let url = fileURL(e) { try? fm.removeItem(at: url) }
        if let dir = sessionDirectory(e.sessionId),
           let left = try? fm.contentsOfDirectory(atPath: dir.path), left.isEmpty {
            try? fm.removeItem(at: dir)
        }
    }

    private func recountLocked() {
        totalBytes = entries.reduce(0) { $0 + $1.bytes }
    }

    private func trimLocked() {
        while entries.count > 1, entries.count > maxCount || totalBytes > maxBytes {
            deleteLocked(entries[0])
            recountLocked()
        }
    }

    /// Rebuilds the index from file names, sizes and modification dates.
    private func load(now: Date) {
        guard let dir = root,
              let sessions = try? fm.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil) else { return }
        let keys: [URLResourceKey] = [.contentModificationDateKey, .fileSizeKey]
        var loaded: [Entry] = []
        for sessionDir in sessions {
            let sid = sessionDir.lastPathComponent
            guard ScreenshotStore.isSafe(sid),
                  let files = try? fm.contentsOfDirectory(at: sessionDir, includingPropertiesForKeys: keys) else {
                try? fm.removeItem(at: sessionDir)
                continue
            }
            for file in files {
                let values = try? file.resourceValues(forKeys: Set(keys))
                guard file.pathExtension == "json",
                      let ordinal = Int(file.deletingPathExtension().lastPathComponent), ordinal >= 0,
                      let date = values?.contentModificationDate, let size = values?.fileSize, size > 0,
                      now.timeIntervalSince(date) < SnapshotStore.maxAge else {
                    try? fm.removeItem(at: file)  // expired, or a temporary file of an interrupted write
                    continue
                }
                loaded.append(Entry(sessionId: sid, ordinal: ordinal, capturedAt: date, bytes: size))
            }
            if let left = try? fm.contentsOfDirectory(atPath: sessionDir.path), left.isEmpty {
                try? fm.removeItem(at: sessionDir)
            }
        }
        entries = loaded.sorted {
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
