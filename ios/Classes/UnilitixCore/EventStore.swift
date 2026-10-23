// VENDORED from UnilitixCore 0.4.1 (EventStore.swift) by scripts/sync-ios-core.sh.
// Do not edit here; change UnilitixCore and re-run the script.

import Foundation

/// The on-device queue: sessions and their not-yet-acknowledged events,
/// persisted to one JSON file so data survives offline periods, app kills
/// and crashes. Thread-safe; the crash handler writes through it directly.
final class EventStore {

    struct Batch {
        let session: SessionInfo
        let events: [IngestEvent]
        /// Revision of the session record when the batch was taken; an
        /// acknowledgement only clears `dirty` if nothing changed since.
        let revision: Int
    }

    private struct StoredSession: Codable {
        var info: SessionInfo
        var events: [IngestEvent]
        /// The session record changed since the server last acknowledged it.
        var dirty: Bool
        var revision: Int
    }

    private let fileURL: URL?
    private let maxEvents: Int
    private let lock = NSLock()
    private var sessions: [StoredSession] = []  // oldest first
    private var saveScheduled = false
    private let ioQueue = DispatchQueue(label: "io.unilitix.store", qos: .utility)

    /// `directory` nil keeps everything in memory (tests).
    init(directory: URL?, maxEvents: Int) {
        self.maxEvents = max(1, maxEvents)
        if let dir = directory {
            try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            fileURL = dir.appendingPathComponent("queue.json")
            load()
        } else {
            fileURL = nil
        }
    }

    static var defaultDirectory: URL? {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first?
            .appendingPathComponent("Unilitix", isDirectory: true)
    }

    // MARK: Writes

    func upsertSession(_ info: SessionInfo) {
        withLock {
            if let i = sessions.firstIndex(where: { $0.info.id == info.id }) {
                var merged = info
                // A crash recorded through `append` (possibly by the crash
                // handler) must not be undone by a later record update.
                merged.crashed = merged.crashed || sessions[i].info.crashed
                if sessions[i].info != merged {
                    sessions[i].info = merged
                    sessions[i].dirty = true
                    sessions[i].revision += 1
                }
            } else {
                sessions.append(StoredSession(info: info, events: [], dirty: true, revision: 0))
            }
        }
        scheduleSave()
    }

    /// Appends an event to its session. `waitUpTo` bounds how long to wait for
    /// the lock (the crash handler must not hang); false means it was not stored.
    @discardableResult
    func append(_ event: IngestEvent, sessionId: String, waitUpTo: TimeInterval? = nil) -> Bool {
        if let wait = waitUpTo {
            guard lock.lock(before: Date().addingTimeInterval(wait)) else { return false }
        } else {
            lock.lock()
        }
        defer { lock.unlock() }
        guard let i = sessions.firstIndex(where: { $0.info.id == sessionId }) else { return false }
        sessions[i].events.append(event)
        if event.type == "CRASH" && !sessions[i].info.crashed {
            sessions[i].info.crashed = true
            sessions[i].dirty = true
            sessions[i].revision += 1
        }
        trimLocked()
        if waitUpTo == nil { scheduleSaveLocked() }
        return true
    }

    // MARK: Reads

    var eventCount: Int { withLock { sessions.reduce(0) { $0 + $1.events.count } } }

    func session(_ id: String) -> SessionInfo? {
        withLock { sessions.first(where: { $0.info.id == id })?.info }
    }

    /// The oldest session that has events or an unacknowledged record, with
    /// up to `limit` of its events.
    func nextBatch(limit: Int) -> Batch? {
        withLock { () -> Batch? in
            guard let s = sessions.first(where: { $0.dirty || !$0.events.isEmpty }) else { return nil }
            return Batch(session: s.info, events: Array(s.events.prefix(max(1, limit))), revision: s.revision)
        }
    }

    // MARK: Acknowledgement

    /// The server has these events (or rejected them for good): forget them.
    /// Sessions that are acknowledged, empty and not `keep` are dropped.
    func acknowledge(_ batch: Batch, eventIds: Set<String>, keep currentSessionId: String?) {
        withLock {
            guard let i = sessions.firstIndex(where: { $0.info.id == batch.session.id }) else { return }
            sessions[i].events.removeAll { eventIds.contains($0.eventId) }
            if sessions[i].revision == batch.revision { sessions[i].dirty = false }
            sessions.removeAll { !$0.dirty && $0.events.isEmpty && $0.info.id != currentSessionId }
        }
        scheduleSave()
    }

    /// Drops one event that can never be sent (e.g. larger than the API accepts).
    func drop(eventId: String, sessionId: String) {
        withLock {
            if let i = sessions.firstIndex(where: { $0.info.id == sessionId }) {
                sessions[i].events.removeAll { $0.eventId == eventId }
            }
        }
        scheduleSave()
    }

    /// Consent denied or reset: delete everything.
    func purge() {
        withLock { sessions.removeAll() }
        saveNow()
    }

    // MARK: Persistence

    /// Writes synchronously. Used by the crash handler and on backgrounding.
    func saveNow() {
        guard let url = fileURL else { return }
        let data = withLock { () -> Data? in
            saveScheduled = false
            return try? JSONEncoder().encode(sessions)
        }
        if let data = data { try? data.write(to: url, options: .atomic) }
    }

    private func scheduleSave() {
        withLock { scheduleSaveLocked() }
    }

    private func scheduleSaveLocked() {
        guard fileURL != nil, !saveScheduled else { return }
        saveScheduled = true
        ioQueue.asyncAfter(deadline: .now() + 1) { [weak self] in self?.saveNow() }
    }

    private func load() {
        guard let url = fileURL, let data = try? Data(contentsOf: url),
              let stored = try? JSONDecoder().decode([StoredSession].self, from: data) else { return }
        sessions = stored
        trimLocked()
    }

    private func trimLocked() {
        var total = sessions.reduce(0) { $0 + $1.events.count }
        var i = 0
        while total > maxEvents && i < sessions.count {
            let drop = min(sessions[i].events.count, total - maxEvents)
            sessions[i].events.removeFirst(drop)
            total -= drop
            i += 1
        }
    }

    private func withLock<T>(_ body: () -> T) -> T {
        lock.lock(); defer { lock.unlock() }
        return body()
    }
}
