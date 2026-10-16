import 'package:flutter_test/flutter_test.dart';
import 'package:unilitix/src/events/event.dart';
import 'package:unilitix/src/session/session.dart';
import 'package:unilitix/src/util/ids.dart';

/// Durability regression tests (October 2026 audit): every event carries a
/// client id and a per-session sequence number so the server can deduplicate
/// retried batches and restore capture order.
void main() {
  final uuidV4 = RegExp(
      r'^[0-9a-f]{8}-[0-9a-f]{4}-4[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$');

  test('generateUuidV4 produces RFC 4122 v4 ids', () {
    final seen = <String>{};
    for (var i = 0; i < 1000; i++) {
      final id = generateUuidV4();
      expect(id, matches(uuidV4));
      expect(seen.add(id), isTrue, reason: 'duplicate uuid');
    }
  });

  test('every event gets a v4 id and serialises it as eventId', () {
    final e = UnilitixEvent(type: EventTypes.tap, screen: '/home', x: 1, y: 2);
    expect(e.id, matches(uuidV4));
    final j = e.toJson();
    expect(j['eventId'], e.id);
    expect(j.containsKey('seq'), isFalse,
        reason: 'seq is absent until attached');
    e.seq = 4;
    expect(e.toJson()['seq'], 4);
  });

  test('the same event serialises to the same eventId on retry', () {
    final e = UnilitixEvent(type: EventTypes.custom)..eventName = 'checkout';
    expect(e.toJson()['eventId'], e.toJson()['eventId']);
  });

  test('Session.takeSeq is monotonic from zero and per session', () {
    final a = Session();
    final b = Session();
    expect([a.takeSeq(), a.takeSeq(), a.takeSeq()], [0, 1, 2]);
    expect(b.takeSeq(), 0);
  });
}
