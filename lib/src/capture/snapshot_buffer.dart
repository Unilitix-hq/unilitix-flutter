import 'dart:collection';

/// Circular buffer for widget-tree snapshots.
class SnapshotBuffer {
  final int capacity;
  final Queue<Map<String, dynamic>> _queue = Queue();

  SnapshotBuffer({required this.capacity});

  void add(Map<String, dynamic> snapshot) {
    if (_queue.length >= capacity) _queue.removeFirst();
    _queue.addLast(snapshot);
  }

  List<Map<String, dynamic>> drain() {
    final all = List<Map<String, dynamic>>.from(_queue);
    _queue.clear();
    return all;
  }

  void clear() => _queue.clear();
  int get length => _queue.length;
}
