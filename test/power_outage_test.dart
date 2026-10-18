import 'dart:convert';
import 'dart:io' show GZipCodec;

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:unilitix/src/config.dart';
import 'package:unilitix/src/network/api_client.dart';
import 'package:unilitix/src/power/h3.dart';
import 'package:unilitix/src/power/power_contribution.dart';
import 'package:unilitix/src/power/power_signals.dart';
import 'package:unilitix/src/power/sha256.dart';
import 'package:unilitix/src/privacy/opt_manager.dart';

// 2025-10-09T08:53:20Z
final DateTime _now = DateTime.utc(2025, 10, 9, 8, 53, 20);
final int _nowMs = _now.millisecondsSinceEpoch;
const int _hour = 3600 * 1000;

/// Records every native call; answers with scripted values.
class _FakeChannel extends PowerChannel {
  final List<String> calls = [];
  final List<Map<String, Object?>> androidConfigs = [];
  bool? charging = true;
  PowerLocation? location;
  void Function(bool)? listener;

  _FakeChannel({this.location});

  @override
  Future<void> configureAndroid(Map<String, Object?> args) async {
    calls.add('configureAndroid');
    androidConfigs.add(args);
  }

  @override
  Future<String?> uploadNowAndroid() async {
    calls.add('uploadNowAndroid');
    return 'SENT';
  }

  @override
  Future<void> setMonitoringIos(bool enabled) async =>
      calls.add('setMonitoringIos($enabled)');

  @override
  Future<bool?> isChargingIos() async {
    calls.add('isChargingIos');
    return charging;
  }

  @override
  Future<PowerLocation?> coarseLocationIos() async {
    calls.add('coarseLocationIos');
    return location;
  }

  @override
  void setChargingListenerIos(void Function(bool charging)? l) => listener = l;
}

class _Harness {
  UnilitixConsent consent;
  final _FakeChannel channel;
  final List<Map<String, dynamic>> bodies = [];
  final List<int> statuses;
  late final PowerContribution power;

  _Harness({
    required bool optedIn,
    required PowerPlatformKind platform,
    this.consent = UnilitixConsent.granted,
    PowerLocation? location = const PowerLocation(6.5244, 3.3792, 0),
    this.statuses = const [],
  }) : channel = _FakeChannel(location: location) {
    power = PowerContribution(
      optedIn: optedIn,
      consent: () => consent,
      installId: '1700000000000',
      apiKey: 'k',
      apiUrl: 'https://api.example',
      sdkVersion: '2.2.0',
      post: (body) async {
        // Round-trip through JSON so the test sees exactly the wire body.
        bodies.add(jsonDecode(jsonEncode(body)) as Map<String, dynamic>);
        final i = bodies.length - 1;
        return ApiResult(status: i < statuses.length ? statuses[i] : 202);
      },
      channel: channel,
      platform: platform,
      clock: () => _now,
      observeLifecycle: false,
    );
  }
}

PowerLocation _freshLocation() => PowerLocation(6.5244, 3.3792, _nowMs - _hour);

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('H3 latLngToCell', () {
    // Expected values from the reference library (h3-py 4.5.0):
    //   h3.latlng_to_cell(lat, lng, res)
    const vectors = <(String, double, double, int, String)>[
      ('Lagos', 6.5244, 3.3792, 7, '87589c984ffffff'),
      ('Nairobi', -1.2921, 36.8219, 7, '877a6e42cffffff'),
      ('Accra', 5.6037, -0.187, 7, '877576970ffffff'),
      ('Abuja', 9.0765, 7.3986, 7, '8758f4691ffffff'),
      ('Johannesburg', -26.2041, 28.0473, 7, '87bcc352cffffff'),
      ('Cairo', 30.0444, 31.2357, 7, '873e628e6ffffff'),
      ('Kinshasa', -4.4419, 15.2663, 7, '87838eae6ffffff'),
      ('New York', 40.7128, -74.006, 7, '872a1072cffffff'),
      ('Lagos res 0', 6.5244, 3.3792, 0, '8059fffffffffff'),
      ('Lagos res 1', 6.5244, 3.3792, 1, '8158bffffffffff'),
      ('Lagos res 9', 6.5244, 3.3792, 9, '89589c984c7ffff'),
      ('Lagos res 15', 6.5244, 3.3792, 15, '8f589c984c5532d'),
      ('Nairobi res 8', -1.2921, 36.8219, 8, '887a6e42cbfffff'),
      ('origin', 0.0, 0.0, 7, '87754e64dffffff'),
      ('antimeridian', 0.0, 180.0, 7, '877eb5722ffffff'),
      ('south pole', -90.0, 0.0, 7, '87f29380effffff'),
      ('north pole', 90.0, 0.0, 7, '870326233ffffff'),
      ('Reykjavik', 64.1466, -21.9426, 7, '87075dd4bffffff'),
      ('Sydney', -33.8688, 151.2093, 7, '87be0e35cffffff'),
      (
        'pentagon 870800000ffffff centre',
        64.7,
        10.536199,
        7,
        '870800000ffffff'
      ),
      ('near pentagon 870800000ffffff', 64.73, 10.516199, 7, '87080002effffff'),
      (
        'pentagon 871c00000ffffff centre',
        50.103201,
        -143.47849,
        7,
        '871c00000ffffff'
      ),
      (
        'near pentagon 871c00000ffffff',
        50.133201,
        -143.49849,
        7,
        '871c00030ffffff'
      ),
      ('pentagon 873000000ffffff centre', 39.1, 122.3, 7, '873000000ffffff'),
      ('near pentagon 873000000ffffff', 39.13, 122.28, 7, '873000022ffffff'),
      (
        'pentagon 874c00000ffffff centre',
        23.717925,
        -67.132326,
        7,
        '874c00000ffffff'
      ),
      (
        'near pentagon 874c00000ffffff',
        23.747925,
        -67.152326,
        7,
        '874c00033ffffff'
      ),
    ];

    for (final (name, lat, lng, res, cell) in vectors) {
      test(name, () => expect(latLngToCell(lat, lng, res), cell));
    }

    test('Lagos and Nairobi at resolution 7', () {
      expect(latLngToCell(6.5244, 3.3792, 7), '87589c984ffffff');
      expect(latLngToCell(-1.2921, 36.8219, 7), '877a6e42cffffff');
    });

    test('invalid input gives null', () {
      expect(latLngToCell(double.nan, 0, 7), isNull);
      expect(latLngToCell(91, 0, 7), isNull);
      expect(latLngToCell(0, 181, 7), isNull);
      expect(latLngToCell(0, 0, 16), isNull);
    });
  });

  group('sha256Hex', () {
    test('matches FIPS 180-4 / hashlib vectors', () {
      expect(sha256Hex(utf8.encode('')),
          'e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855');
      expect(sha256Hex(utf8.encode('abc')),
          'ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad');
      expect(sha256Hex(utf8.encode('a' * 1000)),
          '41edece42d63e8d9bf515a9ba6932e1c20cbc9f5a5d134645adb5db1b9737ea3');
    });
  });

  group('powerDeviceHash', () {
    test('is a salted daily hash, never the install id', () {
      final h = powerDeviceHash('1700000000000', 'salt', _now);
      // sha256("unilitix-power-v1|1700000000000|salt|2025-10-09")[:32];
      // the Android implementation asserts the same vector.
      expect(h, '27042224245e18fcd6d8999c93dbef66');
      expect(h, matches(RegExp(r'^[0-9a-f]{32}$')));
      expect(h, isNot(contains('1700000000000')));
    });

    test('rotates at the UTC day boundary, not before', () {
      final h = powerDeviceHash('1700000000000', 'salt', _now);
      expect(
          powerDeviceHash(
              '1700000000000', 'salt', DateTime.utc(2025, 10, 9, 23, 59, 59)),
          h);
      expect(
          powerDeviceHash('1700000000000', 'salt', DateTime.utc(2025, 10, 10)),
          'b259447563f41ae81eeae899b99a49fe');
      // Local-time DateTimes are converted to UTC first.
      expect(powerDeviceHash('1700000000000', 'salt', _now.toLocal()), h);
    });

    test('depends on the salt', () {
      expect(powerDeviceHash('1700000000000', 'other', _now),
          isNot(powerDeviceHash('1700000000000', 'salt', _now)));
    });
  });

  group('PowerSignal', () {
    test('wire format', () {
      expect(const PowerSignal.disconnect(1760000000000).toJson(),
          {'type': 'disconnect', 'ts': '2025-10-09T08:53:20.000Z'});
      expect(const PowerSignal.sample(1760000060000, charging: true).toJson(), {
        'type': 'sample',
        'charging': true,
        'ts': '2025-10-09T08:54:20.000Z',
      });
      expect(
          powerRequestBody('87589c984ffffff', 'abc',
              const [PowerSignal.connect(1760000000000)]),
          {
            'cell': '87589c984ffffff',
            'device': 'abc',
            'events': [
              {'type': 'connect', 'ts': '2025-10-09T08:53:20.000Z'}
            ],
          });
    });

    test('line round trip and malformed lines', () {
      for (final s in const [
        PowerSignal.connect(1),
        PowerSignal.disconnect(2),
        PowerSignal.sample(3, charging: false),
      ]) {
        final back = PowerSignal.parse(s.toLine())!;
        expect((back.type, back.tsMs, back.charging),
            (s.type, s.tsMs, s.charging));
      }
      for (final bad in [
        'connect',
        'connect,x',
        'connect,1,1',
        'sample,1',
        'sample,1,2',
        'reboot,1'
      ]) {
        expect(PowerSignal.parse(bad), isNull, reason: bad);
      }
    });
  });

  group('PowerSignalQueue', () {
    test('keeps the newest 500', () {
      final q = PowerSignalQueue();
      for (var i = 0; i < 520; i++) {
        q.add(PowerSignal.sample(_nowMs + i, charging: i.isEven));
      }
      expect(q.length, PowerLimits.maxQueued);
      expect(q.lines.first, 'sample,${_nowMs + 20},1');
    });

    test('drops a repeated transition within 2 s', () {
      final q = PowerSignalQueue()
        ..add(PowerSignal.disconnect(_nowMs))
        ..add(PowerSignal.disconnect(_nowMs + 500))
        ..add(PowerSignal.connect(_nowMs + 600))
        ..add(PowerSignal.disconnect(_nowMs + 5000));
      expect(q.lines, [
        'disconnect,$_nowMs',
        'connect,${_nowMs + 600}',
        'disconnect,${_nowMs + 5000}',
      ]);
    });

    test('batches: 48 h window, clock skew, oldest first, 200 per request', () {
      final q = PowerSignalQueue([
        'connect,${_nowMs - 49 * _hour}', // too old
        'connect,${_nowMs + _hour}', // future: bad clock
        'garbage',
        for (var i = 450; i > 0; i--) 'sample,${_nowMs - i * 1000},0',
      ]);
      final b = q.batches(_nowMs);
      expect(b.map((x) => x.length), [200, 200, 50]);
      expect(b.first.first.tsMs, _nowMs - 450000);
      expect(b.last.last.tsMs, _nowMs - 1000);

      q.prune(_nowMs);
      expect(q.length, 450);
    });

    test('an event exactly 48 h old is still sent; older is not', () {
      final q = PowerSignalQueue([
        'connect,${_nowMs - 48 * _hour}',
        'connect,${_nowMs - 48 * _hour - 1}',
      ]);
      expect(q.batches(_nowMs).single.single.tsMs, _nowMs - 48 * _hour);
    });

    test('remove takes out delivered events only', () {
      final q = PowerSignalQueue()
        ..add(PowerSignal.connect(_nowMs - 3000))
        ..add(PowerSignal.disconnect(_nowMs - 1000));
      q.remove([PowerSignal.connect(_nowMs - 3000)]);
      expect(q.lines, ['disconnect,${_nowMs - 1000}']);
    });
  });

  group('UnilitixConfig.powerOutageContribution', () {
    test('is off by default', () {
      expect(
          const UnilitixConfig(apiKey: 'k').powerOutageContribution, isFalse);
    });

    test('copyWith carries it', () {
      const c = UnilitixConfig(apiKey: 'k');
      expect(c.copyWith(powerOutageContribution: true).powerOutageContribution,
          isTrue);
      expect(
          c
              .copyWith(powerOutageContribution: true)
              .copyWith(debug: true)
              .powerOutageContribution,
          isTrue);
    });
  });

  group('ApiClient.postPowerSignals', () {
    test('one gzip POST to /v1/signals/power with the key header', () async {
      late http.Request seen;
      final client = MockClient((req) async {
        seen = req;
        return http.Response('', 202);
      });
      final api = ApiClient(
          apiKey: 'k',
          apiUrl: 'https://api.example',
          sdkVersion: '2.2.0',
          client: client);
      final r = await api.postPowerSignals(powerRequestBody('87589c984ffffff',
          'abc', const [PowerSignal.connect(1760000000000)]));
      expect(r.ok, isTrue);
      expect(seen.method, 'POST');
      expect(seen.url.toString(), 'https://api.example/v1/signals/power');
      expect(seen.headers['x-unilitix-key'], 'k');
      expect(seen.headers['Content-Encoding'], 'gzip');
      final body = jsonDecode(utf8.decode(GZipCodec().decode(seen.bodyBytes)));
      expect(body['cell'], '87589c984ffffff');
      expect(body['events'], hasLength(1));
    });
  });

  group('PowerContribution gating', () {
    setUp(() => SharedPreferences.setMockInitialValues({}));

    test('an app that did not opt in makes no platform call and stores nothing',
        () async {
      for (final platform in [
        PowerPlatformKind.android,
        PowerPlatformKind.ios
      ]) {
        final h = _Harness(optedIn: false, platform: platform);
        await h.power.start();
        await h.power.onConsentChanged();
        expect(h.channel.calls, isEmpty);
        expect(h.bodies, isEmpty);
      }
      final prefs = await SharedPreferences.getInstance();
      expect(prefs.getKeys(), isEmpty);
    });

    test('opted in but consent pending or denied: nothing collected or sent',
        () async {
      for (final c in [UnilitixConsent.pending, UnilitixConsent.denied]) {
        for (final platform in [
          PowerPlatformKind.android,
          PowerPlatformKind.ios
        ]) {
          final h = _Harness(optedIn: true, platform: platform, consent: c);
          await h.power.start();
          expect(h.power.active, isFalse);
          expect(h.channel.calls, isEmpty, reason: '$c $platform');
          h.power.debugChargingChanged(false);
          expect(h.power.queue.isEmpty, isTrue);
          expect(h.bodies, isEmpty);
        }
      }
    });

    test('unsupported platforms (web, desktop) do nothing', () async {
      final h =
          _Harness(optedIn: true, platform: PowerPlatformKind.unsupported);
      await h.power.start();
      expect(h.power.active, isFalse);
      expect(h.channel.calls, isEmpty);
    });

    test(
        'Android: granted enables natively with a salt; denied disables and forgets it',
        () async {
      final h = _Harness(optedIn: true, platform: PowerPlatformKind.android);
      await h.power.start();
      expect(h.channel.calls, ['configureAndroid', 'uploadNowAndroid']);
      final cfg = h.channel.androidConfigs.single;
      expect(cfg['enabled'], isTrue);
      expect(cfg['installId'], '1700000000000');
      expect(cfg['salt'], isA<String>());
      final salt = cfg['salt'];

      h.consent = UnilitixConsent.denied;
      await h.power.onConsentChanged();
      expect(h.channel.androidConfigs.last, {'enabled': false});
      final prefs = await SharedPreferences.getInstance();
      expect(prefs.containsKey('unilitix_power_salt'), isFalse);

      // Granting again starts over with a new, unlinkable salt.
      h.consent = UnilitixConsent.granted;
      await h.power.onConsentChanged();
      expect(h.channel.androidConfigs.last['enabled'], isTrue);
      expect(h.channel.androidConfigs.last['salt'], isNot(salt));
    });

    test('Android: pending also disables (pending holds nothing)', () async {
      final h = _Harness(optedIn: true, platform: PowerPlatformKind.android);
      await h.power.start();
      h.consent = UnilitixConsent.pending;
      await h.power.onConsentChanged();
      expect(h.channel.androidConfigs.last, {'enabled': false});
    });

    test('iOS: granted samples and uploads a cell, never coordinates',
        () async {
      final h = _Harness(
          optedIn: true,
          platform: PowerPlatformKind.ios,
          location: _freshLocation());
      await h.power.start();
      expect(h.channel.calls, contains('setMonitoringIos(true)'));
      expect(h.bodies, hasLength(1));
      final body = h.bodies.single;
      expect(body.keys.toSet(), {'cell', 'device', 'events'});
      expect(body['cell'], '87589c984ffffff');
      expect(body['device'], matches(RegExp(r'^[0-9a-f]{32}$')));
      expect(body['events'], [
        {'type': 'sample', 'charging': true, 'ts': '2025-10-09T08:53:20.000Z'}
      ]);
      final wire = jsonEncode(body);
      expect(wire, isNot(contains('6.52')));
      expect(wire, isNot(contains('3.37')));
      expect(wire, isNot(contains('1700000000000')));
      expect(h.power.queue.isEmpty, isTrue);
    });

    test('iOS: plug changes become transitions; charging -> full is not one',
        () async {
      final h = _Harness(
          optedIn: true, platform: PowerPlatformKind.ios, location: null);
      await h.power.start(); // sample: charging (true)
      h.channel.listener!(true); // e.g. charging -> full
      h.channel.listener!(false);
      h.channel.listener!(true);
      expect(h.power.queue.lines.map((l) => l.split(',').first),
          ['sample', 'disconnect', 'connect']);
    });

    test('iOS: no location, or a stale one, sends nothing and keeps the events',
        () async {
      final h = _Harness(
          optedIn: true, platform: PowerPlatformKind.ios, location: null);
      await h.power.start();
      expect(h.bodies, isEmpty);
      expect(h.power.queue.length, 1);

      h.channel.location = PowerLocation(6.5, 3.3, _nowMs - 25 * _hour);
      await h.power.debugUpload();
      expect(h.bodies, isEmpty);
      expect(h.power.queue.length, 1);

      h.channel.location = _freshLocation();
      await h.power.debugUpload();
      expect(h.bodies, hasLength(1));
      expect(h.power.queue.isEmpty, isTrue);
    });

    test('iOS: retryable failure keeps events, rejection drops them', () async {
      final h = _Harness(
          optedIn: true,
          platform: PowerPlatformKind.ios,
          location: _freshLocation(),
          statuses: [503, 401, 400]);
      await h.power.start(); // 503
      expect(h.power.queue.length, 1);
      await h.power.debugUpload(); // 401
      expect(h.power.queue.length, 1);
      await h.power.debugUpload(); // 400: never retried
      expect(h.power.queue.isEmpty, isTrue);
      expect(h.bodies, hasLength(3));
    });

    test('iOS: 450 queued events go out as 200 + 200 + 50', () async {
      SharedPreferences.setMockInitialValues({
        'unilitix_power_salt': 'salt',
        'unilitix_power_queue': [
          for (var i = 450; i > 0; i--) 'sample,${_nowMs - i * 1000},0'
        ],
      });
      final h = _Harness(
          optedIn: true,
          platform: PowerPlatformKind.ios,
          location: _freshLocation());
      await h.power.start();
      expect(h.bodies.map((b) => (b['events'] as List).length), [200, 200, 51]);
      expect(h.bodies.first['device'],
          powerDeviceHash('1700000000000', 'salt', _now));
    });

    test('iOS: denied stops monitoring and deletes the queue and salt',
        () async {
      final h = _Harness(
          optedIn: true, platform: PowerPlatformKind.ios, location: null);
      await h.power.start();
      expect(h.power.queue.length, 1);
      h.consent = UnilitixConsent.denied;
      await h.power.onConsentChanged();
      expect(h.channel.calls.last, 'setMonitoringIos(false)');
      expect(h.channel.listener, isNull);
      expect(h.power.queue.isEmpty, isTrue);
      final prefs = await SharedPreferences.getInstance();
      expect(prefs.containsKey('unilitix_power_queue'), isFalse);
      expect(prefs.containsKey('unilitix_power_salt'), isFalse);
    });

    test(
        'opting out in a later app version tears down what an earlier one left',
        () async {
      SharedPreferences.setMockInitialValues({'unilitix_power_salt': 'salt'});
      final h = _Harness(optedIn: false, platform: PowerPlatformKind.android);
      await h.power.start();
      expect(h.channel.androidConfigs.single, {'enabled': false});
      final prefs = await SharedPreferences.getInstance();
      expect(prefs.containsKey('unilitix_power_salt'), isFalse);
    });
  });
}
