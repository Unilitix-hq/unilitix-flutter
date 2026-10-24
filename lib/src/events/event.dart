import '../util/ids.dart';
import '../util/json_util.dart';
import 'event_types.dart';

export 'event_types.dart';

/// A single tracked event.
class UnilitixEvent {
  /// Client-generated UUID v4. Stable across retries so the server can
  /// deduplicate; also the key of the on-device write-ahead row.
  final String id;

  /// Per-session capture order, assigned when the event is emitted. Null until
  /// the SDK attaches the event to a session.
  int? seq;

  final String type;
  final String? screen;
  final double? x;
  final double? y;
  final Map<String, dynamic> properties;
  final int timestamp;

  bool capturedOffline = false;
  String networkAtCapture = 'UNKNOWN';
  double? memoryUsageMb;
  double? cpuUsagePct;
  int? frameDrops;

  // CRASH / EXCEPTION / ANR fields
  /// True when the process could not continue (native crash, signal). Dart
  /// errors are non-fatal: the app keeps running.
  bool fatal = false;
  String? title;
  String? stackTrace;
  String? exceptionType;
  String? exceptionMessage;
  List<Map<String, dynamic>>? breadcrumbs;

  /// Grouping and symbolication data for CRASH / EXCEPTION events, sent as
  /// the event's `metadata`: `fingerprint`, `occurrence`, and for obfuscated
  /// builds `buildId` / `isolateDsoBase`. For ANR events: `fingerprint`,
  /// `platform`, and `importance` / `foreground` when known.
  Map<String, dynamic>? crashMetadata;

  // CUSTOM fields
  String? eventName;

  UnilitixEvent({
    required this.type,
    this.screen,
    this.x,
    this.y,
    Map<String, dynamic>? properties,
  })  : id = generateUuidV4(),
        properties = properties ?? {},
        timestamp = DateTime.now().millisecondsSinceEpoch;

  Map<String, dynamic> toJson() {
    final map = <String, dynamic>{
      'eventId': id,
      if (seq != null) 'seq': seq,
      'type': type,
      if (screen != null) 'screen': screen,
      if (x != null) 'x': x,
      if (y != null) 'y': y,
      'timestamp': JsonUtil.toRfc3339(timestamp),
      'capturedOffline': capturedOffline,
      'networkAtCapture': networkAtCapture,
      if (memoryUsageMb != null) 'memoryUsageMb': memoryUsageMb,
      if (cpuUsagePct != null) 'cpuUsagePct': cpuUsagePct,
      if (frameDrops != null) 'frameDrops': frameDrops,
    };

    if (type == EventTypes.crash || type == EventTypes.exception) {
      map['fatal'] = fatal;
      if (title != null) map['title'] = title;
      if (stackTrace != null) map['stackTrace'] = stackTrace;
      if (exceptionType != null) map['exceptionType'] = exceptionType;
      if (exceptionMessage != null) map['exceptionMessage'] = exceptionMessage;
      if (breadcrumbs != null) map['breadcrumbs'] = breadcrumbs;
      if (crashMetadata != null) map['metadata'] = crashMetadata;
    }

    // An ANR is not a crash: no `fatal`, and no `title` (the server titles
    // ANR issues from the main thread's first app frame).
    if (type == EventTypes.anr) {
      if (stackTrace != null) map['stackTrace'] = stackTrace;
      if (exceptionType != null) map['exceptionType'] = exceptionType;
      if (exceptionMessage != null) map['exceptionMessage'] = exceptionMessage;
      if (breadcrumbs != null) map['breadcrumbs'] = breadcrumbs;
      if (crashMetadata != null) map['metadata'] = crashMetadata;
    }

    if (type == EventTypes.custom) {
      map['metadata'] = {'name': eventName};
      if (properties.isNotEmpty) {
        map['properties'] = properties;
      }
    }

    return map;
  }

  Map<String, dynamic> toMap() => toJson();
}
