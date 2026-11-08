import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

/// A stand-in for the native plugin on `com.unilitix/sdk`: records every
/// call, in order, and answers like the plugins do.
class FakeNative {
  FakeNative({
    this.consent = 'granted',
    this.sessionId = 'native-session-1',
    this.replaySampled = true,
    this.dartTaps = true,
    this.failInit = false,
  });

  static const MethodChannel channel = MethodChannel('com.unilitix/sdk');

  /// The native consent state. Like the native SDKs, a decision made with
  /// `setConsent` is persisted ([consentPersisted]) and wins over the
  /// `consent` passed to later inits.
  String consent;
  bool consentPersisted = false;
  String? sessionId;
  bool replaySampled;
  bool dartTaps;
  bool failInit;

  /// Every call received, in order.
  final List<MethodCall> calls = [];

  /// Frames handed out by `captureScreenshot`, not yet committed/discarded.
  final Set<int> pendingFrames = {};
  int _nextFrame = 1;

  /// Answer for `captureScreenshot`; null makes the capture fail.
  bool screenshotsAvailable = true;

  /// Called before answering `captureScreenshot` (e.g. to move the masks).
  Future<void> Function()? onCapture;

  void install() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, _handle);
  }

  void uninstall() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, null);
  }

  Map<String, Object?> get state => {
        'consent': consent,
        'sessionId': sessionId,
        'replaySampled': replaySampled,
        'dartTaps': dartTaps,
      };

  Future<Object?> _handle(MethodCall call) async {
    calls.add(call);
    switch (call.method) {
      case 'init':
        if (failInit) {
          throw PlatformException(code: 'INIT_FAILED', message: 'test');
        }
        final initial = (call.arguments as Map)['consent'];
        if (!consentPersisted && initial is String) consent = initial;
        return state;
      case 'replayState':
        return state;
      case 'setConsent':
        consent = (call.arguments as Map)['consent'] as String;
        consentPersisted = true;
        return null;
      case 'reset':
      case 'startSession':
        sessionId = 'native-session-${calls.length}';
        return null;
      case 'captureScreenshot':
        await onCapture?.call();
        if (!screenshotsAvailable) return null;
        final id = _nextFrame++;
        pendingFrames.add(id);
        return {'id': id, 'width': 240, 'height': 427};
      case 'commitScreenshot':
      case 'discardScreenshot':
        pendingFrames.remove((call.arguments as Map)['id']);
        return null;
      default:
        return null;
    }
  }

  /// Calls named [method].
  List<MethodCall> named(String method) =>
      calls.where((c) => c.method == method).toList();

  /// The method names received, in order, without the queries the Dart
  /// layer makes for itself (`replayState`).
  List<String> get methods => [
        for (final c in calls)
          if (c.method != 'replayState') c.method
      ];

  /// Arguments of the only call named [method].
  Map<Object?, Object?> single(String method) {
    final c = named(method);
    expect(c, hasLength(1), reason: 'one $method call');
    return c.single.arguments as Map<Object?, Object?>;
  }

  void clear() => calls.clear();
}
