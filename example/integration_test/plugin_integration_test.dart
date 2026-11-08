// End to end on a device or emulator: the Dart layer, the platform channel,
// the plugin and the native SDK, uploading to a fake ingest server that runs
// inside the test (http://127.0.0.1). Run with:
//
//   cd example && flutter test integration_test
//
// CI runs it on an Android emulator (.github/workflows/ci.yml,
// `integration-test-android`).
import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:unilitix/unilitix.dart';

/// One request the fake server received.
class _Request {
  _Request(this.path, this.headers, this.body);
  final String path;
  final HttpHeaders headers;
  final Object? body;
}

/// A minimal ingest API: answers 202 to everything and records it.
class _FakeIngest {
  late final HttpServer _server;
  final List<_Request> requests = [];

  String get url => 'http://127.0.0.1:${_server.port}';

  Future<void> start() async {
    _server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    _server.listen((req) async {
      var bytes = await req.fold<List<int>>([], (a, b) => a..addAll(b));
      if (req.headers.value('content-encoding') == 'gzip') {
        bytes = gzip.decode(bytes);
      }
      Object? body;
      try {
        body = bytes.isEmpty ? null : jsonDecode(utf8.decode(bytes));
      } catch (_) {
        body = null; // screenshots and other binary uploads
      }
      requests.add(_Request(req.uri.path, req.headers, body));
      final events = body is Map ? body['events'] : null;
      req.response
        ..statusCode = 202
        ..headers.contentType = ContentType.json
        ..write(jsonEncode({
          'received': events is List ? events.length : 0,
          'sessionId': body is Map ? body['sessionId'] : null,
        }));
      await req.response.close();
    });
  }

  Future<void> stop() => _server.close(force: true);

  /// Every event uploaded so far (session and events endpoints).
  List<Map<String, dynamic>> get events => [
        for (final r in requests)
          if ((r.path == '/v1/ingest/session' ||
                  r.path == '/v1/ingest/events') &&
              r.body is Map &&
              (r.body as Map)['events'] is List)
            ...((r.body as Map)['events'] as List)
                .whereType<Map<String, dynamic>>(),
      ];
}

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('the plugin boots the native SDK and uploads to the API',
      (tester) async {
    expect(Unilitix.isInitialized, isFalse);
    final server = _FakeIngest();
    await server.start();
    addTearDown(server.stop);

    // Before init: buffered in Dart, sent after the native init.
    await Unilitix.track('before_init', {'n': 0});

    await Unilitix.init(
      'ul_test_integration',
      config: UnilitixConfig(
        apiKey: 'ul_test_integration',
        apiUrl: server.url,
        debug: true,
        flushIntervalSeconds: 2,
        uploadScreenshotsOnWifiOnly: false,
      ),
    );
    expect(Unilitix.isInitialized, isTrue);
    expect(Unilitix.consent, UnilitixConsent.granted);

    await tester.pumpWidget(MaterialApp(
      navigatorObservers: [Unilitix.observer],
      builder: (context, child) => UnilitixWidget(child: child!),
      home: const Scaffold(body: Center(child: Text('Integration'))),
    ));
    await tester.pumpAndSettle();

    await Unilitix.screen('IntegrationHome');
    await Unilitix.track('integration_event', {'n': 1, 'ok': true});
    await Unilitix.identify('integration_user', {'plan': 'test'});
    Unilitix.captureException(StateError('integration handled error'),
        stackTrace: StackTrace.current);

    bool has(bool Function(Map<String, dynamic> e) test) =>
        server.events.any(test);
    String? name(Map<String, dynamic> e) =>
        (e['metadata'] as Map?)?['name'] as String?;

    final deadline = DateTime.now().add(const Duration(seconds: 60));
    while (DateTime.now().isBefore(deadline)) {
      await Unilitix.flush();
      await tester.pump(const Duration(milliseconds: 500));
      await Future<void>.delayed(const Duration(seconds: 1));
      if (has((e) => name(e) == 'integration_event') &&
          has((e) => e['type'] == 'EXCEPTION')) {
        break;
      }
    }

    expect(has((e) => e['type'] == 'SESSION_START'), isTrue,
        reason: 'events: ${server.events}');
    expect(has((e) => name(e) == 'before_init'), isTrue,
        reason: 'the pre-init call was replayed');
    expect(has((e) => name(e) == 'integration_event'), isTrue);
    expect(
        has((e) => e['type'] == 'NAVIGATE' && e['screen'] == 'IntegrationHome'),
        isTrue);
    final exception =
        server.events.firstWhere((e) => e['type'] == 'EXCEPTION');
    expect(exception['exceptionType'], 'StateError');
    expect((exception['metadata'] as Map)['fingerprint'], hasLength(16));

    final sessionRequest = server.requests
        .firstWhere((r) => r.path == '/v1/ingest/session');
    expect(sessionRequest.headers.value('x-unilitix-key'),
        'ul_test_integration');
  });
}
