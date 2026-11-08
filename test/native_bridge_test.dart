import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:unilitix/src/core/native_bridge.dart';
import 'package:unilitix/src/generated/sdk_contract.dart';

import 'support/fake_native.dart';

/// The Dart pre-init buffer: calls before the native init are kept (at most
/// preInitBufferSize, oldest dropped) and sent in order right after it.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late FakeNative native;
  setUp(() => native = FakeNative()..install());
  tearDown(() => native.uninstall());

  test('calls before init are buffered and replayed in order after it',
      () async {
    final bridge = NativeBridge();
    bridge.send('track', {'name': 'a'});
    bridge.send('screen', {'name': 'Home'});
    bridge.send('identify', {'userId': 'u1'});
    expect(native.calls, isEmpty, reason: 'nothing crosses before init');
    expect(bridge.pending, hasLength(3));

    final answer = await bridge.start({'apiKey': 'k'});
    expect(answer?['sessionId'], 'native-session-1');
    bridge.send('track', {'name': 'b'});

    expect(native.methods, ['init', 'track', 'screen', 'identify', 'track']);
    expect(native.calls[1].arguments, {'name': 'a'});
    expect(native.calls.last.arguments, {'name': 'b'});
    expect(bridge.pending, isEmpty);
  });

  test('leading calls go before the buffered ones', () async {
    final bridge = NativeBridge();
    bridge.send('track', {'name': 'a'});
    await bridge.start({
      'apiKey': 'k'
    }, first: const [
      PendingNativeCall('setConsent', {'consent': 'denied'})
    ]);
    expect(native.methods, ['init', 'setConsent', 'track']);
  });

  test('the buffer keeps the newest preInitBufferSize calls', () async {
    final bridge = NativeBridge();
    const extra = 5;
    for (var i = 0; i < SdkContract.preInitBufferSize + extra; i++) {
      bridge.send('track', {'name': 'e$i'});
    }
    expect(bridge.pending, hasLength(SdkContract.preInitBufferSize));
    expect(bridge.droppedBeforeInit, extra);
    await bridge.start({'apiKey': 'k'});
    final tracks = native.named('track');
    expect(tracks, hasLength(SdkContract.preInitBufferSize));
    expect((tracks.first.arguments as Map)['name'], 'e$extra');
    expect((tracks.last.arguments as Map)['name'],
        'e${SdkContract.preInitBufferSize + extra - 1}');
  });

  test('a failed init throws to the caller; disable drops everything',
      () async {
    native.failInit = true;
    final bridge = NativeBridge();
    bridge.send('track', {'name': 'a'});
    await expectLater(bridge.start({'apiKey': 'k'}), throwsA(anything));
    bridge.disable();
    bridge.send('track', {'name': 'b'});
    expect(native.methods, ['init']);
    expect(bridge.isDisabled, isTrue);
    expect(await bridge.query<Object>('replayState'), isNull);
  });

  test('query returns null before init and the answer after', () async {
    final bridge = NativeBridge();
    expect(await bridge.query<Object>('replayState'), isNull);
    await bridge.start({'apiKey': 'k'});
    final m = await bridge.query<Map<Object?, Object?>>('replayState');
    expect(m?['replaySampled'], isTrue);
  });

  group('codecSafe', () {
    test('keeps codec types and converts the rest', () {
      final when = DateTime.utc(2026, 1, 5, 9);
      final out = codecSafe({
        'n': 1,
        'd': double.nan,
        's': 'x',
        'b': true,
        'nil': null,
        'list': [1, 'a', when],
        'set': {1, 2},
        'nested': {
          3: {'deep': Uri.parse('https://a.b')}
        },
        'bytes': Uint8List.fromList([1, 2]),
      }) as Map;
      expect((out['d'] as double).isNaN, isTrue,
          reason: 'normalisation (NaN -> null) is the native SDK\'s');
      expect(out['list'], [1, 'a', '2026-01-05T09:00:00.000Z']);
      expect(out['set'], [1, 2]);
      expect(out['nested'], {
        '3': {'deep': 'https://a.b'}
      });
      expect(out['bytes'], isA<Uint8List>());
    });

    test('a reference cycle ends in the truncation marker', () {
      final cyclic = <String, Object?>{};
      cyclic['self'] = cyclic;
      var v = codecSafe(cyclic, maxDepth: 4);
      for (var i = 0; i < 4; i++) {
        v = (v as Map)['self'];
      }
      expect(v, SdkContract.truncatedMarker);
    });
  });
}
