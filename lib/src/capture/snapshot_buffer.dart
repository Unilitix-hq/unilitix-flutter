import 'dart:collection';

/// One buffered wireframe snapshot and its approximate JSON size in bytes.
class SnapshotEntry {
  final Map<String, dynamic> data;
  final int bytes;
  const SnapshotEntry(this.data, this.bytes);
}

/// Circular buffer for widget-tree snapshots, bounded by count and by
/// approximate bytes.
///
/// Snapshots wait here between flush cycles, and for as long as the device is
/// offline. Before 2.7.4 only the count was capped (1500 by default), so an
/// app left offline on a busy screen could hold tens of megabytes and then
/// send it in one request. The oldest snapshots are now dropped once the
/// buffer holds [maxBytes] (about 1.5 MB of JSON by default), and the flush
/// scheduler sends them in chunks ([takeChunk]).
class SnapshotBuffer {
  final int capacity;

  /// Upper bound on the summed size estimate of everything held.
  final int maxBytes;

  static const int defaultMaxBytes = 1536 * 1024;

  final Queue<SnapshotEntry> _queue = Queue();
  int _bytes = 0;

  SnapshotBuffer({required this.capacity, this.maxBytes = defaultMaxBytes});

  /// Adds a snapshot. [approxBytes] is the caller's size estimate (the
  /// wireframe walk computes one as it goes); without it the snapshot is
  /// measured with [estimateJsonBytes].
  void add(Map<String, dynamic> snapshot, {int? approxBytes}) {
    final bytes = approxBytes ?? estimateJsonBytes(snapshot);
    _queue.addLast(SnapshotEntry(snapshot, bytes));
    _bytes += bytes;
    _evict();
  }

  /// Puts entries that could not be sent back at the front, in their
  /// original order, then applies the caps (which drop the oldest first).
  void requeueFront(List<SnapshotEntry> entries) {
    for (final e in entries.reversed) {
      _queue.addFirst(e);
      _bytes += e.bytes;
    }
    _evict();
  }

  void _evict() {
    while (
        _queue.length > 1 && (_queue.length > capacity || _bytes > maxBytes)) {
      _bytes -= _queue.removeFirst().bytes;
    }
  }

  /// Removes and returns the oldest snapshots, up to [maxBytes] of estimated
  /// JSON or [maxCount] snapshots, whichever comes first. Always returns at
  /// least one entry when the buffer is not empty, so a single oversized
  /// snapshot cannot block the queue.
  List<SnapshotEntry> takeChunk(
      {required int maxBytes, required int maxCount}) {
    final out = <SnapshotEntry>[];
    var size = 0;
    while (_queue.isNotEmpty && out.length < maxCount) {
      final next = _queue.first;
      if (out.isNotEmpty && size + next.bytes > maxBytes) break;
      _queue.removeFirst();
      _bytes -= next.bytes;
      size += next.bytes;
      out.add(next);
    }
    return out;
  }

  List<Map<String, dynamic>> drain() {
    final all = _queue.map((e) => e.data).toList();
    clear();
    return all;
  }

  void clear() {
    _queue.clear();
    _bytes = 0;
  }

  int get length => _queue.length;

  bool get isEmpty => _queue.isEmpty;

  /// Summed size estimate of everything held.
  int get bytes => _bytes;
}

/// Rough size of [value] encoded as JSON, in UTF-8 bytes, without encoding
/// it. Strings count three bytes per code unit above ASCII (redacted text is
/// all `•`, three bytes each).
int estimateJsonBytes(Object? value) {
  if (value == null) return 4;
  if (value is String) {
    var n = 2;
    for (var i = 0; i < value.length; i++) {
      n += value.codeUnitAt(i) < 0x80 ? 1 : 3;
    }
    return n;
  }
  if (value is num || value is bool) return value.toString().length;
  if (value is Map) {
    var n = 2;
    value.forEach((k, v) {
      n += estimateJsonBytes(k.toString()) + 2 + estimateJsonBytes(v);
    });
    return n;
  }
  if (value is Iterable) {
    var n = 2;
    for (final v in value) {
      n += estimateJsonBytes(v) + 1;
    }
    return n;
  }
  return value.toString().length + 2;
}
