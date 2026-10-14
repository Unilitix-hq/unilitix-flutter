import 'package:flutter_test/flutter_test.dart';
import 'package:unilitix/src/events/event_buffer.dart';
import 'package:unilitix/src/events/event.dart';
import 'package:unilitix/src/events/event_types.dart';

/// Consent regression tests (October 2026 audit): opting out must discard
/// buffered data rather than leaving it to be flushed later.
void main() {
  group('EventBuffer.clear', () {
    test('discards buffered events without flushing', () {
      var flushRequested = 0;
      final buf = EventBuffer(batchSize: 10, onFlushNeeded: () => flushRequested++);
      buf.emit(UnilitixEvent(type: EventTypes.tap, screen: '/home'));
      buf.emit(UnilitixEvent(type: EventTypes.navigate, screen: '/profile'));
      expect(buf.drain().length, 2);

      buf.emit(UnilitixEvent(type: EventTypes.tap, screen: '/home'));
      buf.clear();
      expect(buf.drain(), isEmpty);
      expect(flushRequested, 0);
    });
  });
}
