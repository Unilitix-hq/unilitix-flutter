import 'event.dart';

/// In-memory event queue. Thread-safe (single-isolate Dart).
class EventBuffer {
  final int batchSize;
  final void Function() onFlushNeeded;

  final List<UnilitixEvent> _buffer = [];

  EventBuffer({required this.batchSize, required this.onFlushNeeded});

  /// Add an event. Triggers [onFlushNeeded] when batch size is reached.
  void emit(UnilitixEvent event) {
    _buffer.add(event);
    if (_buffer.length >= batchSize) {
      onFlushNeeded();
    }
  }

  /// Atomically clear and return all buffered events.
  List<UnilitixEvent> drain() {
    final events = List<UnilitixEvent>.from(_buffer);
    _buffer.clear();
    return events;
  }

  int get length => _buffer.length;
  bool get isEmpty => _buffer.isEmpty;
}
