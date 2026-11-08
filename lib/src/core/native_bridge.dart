import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

import '../generated/sdk_contract.dart';
import '../logger/logger.dart';

/// One call waiting for the native SDK.
@immutable
class PendingNativeCall {
  const PendingNativeCall(this.method, this.arguments);
  final String method;
  final Object? arguments;
}

/// The only path from Dart to the native SDK (Android `unilitix-android`,
/// iOS UnilitixCore), over the `com.unilitix/sdk` method channel.
///
/// Calls made before the native `init` has returned are kept here, at most
/// [SdkContract.preInitBufferSize] (the oldest are dropped first), and sent
/// in call order right after it returns, before any later call. The native
/// cores buffer pre-init calls too; this buffer covers the time before the
/// channel itself is usable (calls from `main()` before `init`, or while
/// `init` is awaiting the platform).
///
/// Every send is fire-and-forget: method channel messages are delivered in
/// the order they are sent, so the native side sees calls in call order,
/// and a platform error is logged, never thrown into the app.
class NativeBridge {
  NativeBridge({MethodChannel? channel})
      : channel = channel ?? const MethodChannel(channelName);

  static const String channelName = 'com.unilitix/sdk';

  final MethodChannel channel;

  final List<PendingNativeCall> _pending = [];
  bool _ready = false;
  bool _disabled = false;

  /// Calls dropped because the pre-init buffer was full.
  int droppedBeforeInit = 0;

  /// True once the native `init` returned and the buffer was replayed.
  bool get isReady => _ready;

  /// True after a failed `init`: every call is dropped.
  bool get isDisabled => _disabled;

  /// Calls waiting for `init`; for tests.
  @visibleForTesting
  List<PendingNativeCall> get pending => List.unmodifiable(_pending);

  /// Sends [method] now, or buffers it until [start] has returned.
  void send(String method, [Object? arguments]) {
    if (_disabled) return;
    if (!_ready) {
      if (_pending.length >= SdkContract.preInitBufferSize) {
        _pending.removeAt(0);
        droppedBeforeInit++;
      }
      _pending.add(PendingNativeCall(method, arguments));
      return;
    }
    _invoke(method, arguments);
  }

  void _invoke(String method, Object? arguments) {
    try {
      unawaited(channel
          .invokeMethod<Object?>(method, arguments)
          .then<void>((_) {}, onError: (Object e) {
        UnilitixLogger.w('native $method failed: ${_describe(e)}');
      }));
    } catch (e) {
      // An argument the codec cannot encode; never thrown into the app.
      UnilitixLogger.w('native $method not sent: ${_describe(e)}');
    }
  }

  /// Calls the native `init` with [arguments] and returns its answer, then
  /// sends [first] and every buffered call, in order. Throws when the native
  /// side fails (the caller disables the SDK, see [disable]).
  Future<Map<Object?, Object?>?> start(Map<String, Object?> arguments,
      {List<PendingNativeCall> first = const []}) async {
    final answer =
        await channel.invokeMethod<Map<Object?, Object?>>('init', arguments);
    _ready = true;
    final calls = [...first, ..._pending];
    _pending.clear();
    for (final c in calls) {
      _invoke(c.method, c.arguments);
    }
    if (droppedBeforeInit > 0) {
      UnilitixLogger.w('$droppedBeforeInit call(s) made before init were '
          'dropped (more than ${SdkContract.preInitBufferSize})');
    }
    return answer;
  }

  /// After a failed init: drops the buffer and every later call.
  void disable() {
    _disabled = true;
    _pending.clear();
  }

  /// A call whose answer the SDK needs (replay state, screenshot handles).
  /// Null when the SDK is not started, on a platform error or without a
  /// native side (web, desktop).
  Future<T?> query<T>(String method, [Object? arguments]) async {
    if (!_ready || _disabled) return null;
    try {
      return await channel.invokeMethod<T>(method, arguments);
    } on MissingPluginException {
      return null;
    } catch (e) {
      UnilitixLogger.w('native $method failed: ${_describe(e)}');
      return null;
    }
  }

  static String _describe(Object e) =>
      e is PlatformException ? '${e.code} ${e.message ?? ''}' : '$e';
}

/// [value] converted to what the platform channel's codec can carry:
/// null, bool, num, String, typed data, and lists and string-keyed maps of
/// those. Anything else becomes its `toString()`; nesting deeper than
/// [maxDepth] becomes [SdkContract.truncatedMarker] (which also ends a
/// reference cycle). Normalisation itself (lengths, key counts, depth 5,
/// non-finite numbers) is the native SDK's job.
Object? codecSafe(Object? value, {int maxDepth = 32}) {
  Object? convert(Object? v, int depth) {
    if (v == null || v is bool || v is num || v is String) return v;
    if (v is Uint8List ||
        v is Int32List ||
        v is Int64List ||
        v is Float64List) {
      return v;
    }
    if (depth >= maxDepth) return SdkContract.truncatedMarker;
    if (v is Map) {
      final out = <String, Object?>{};
      v.forEach((k, e) => out['$k'] = convert(e, depth + 1));
      return out;
    }
    if (v is Iterable) {
      return [for (final e in v) convert(e, depth + 1)];
    }
    if (v is DateTime) return v.toUtc().toIso8601String();
    if (v is Enum) return v.name;
    return v.toString();
  }

  return convert(value, 0);
}
