import '../util/json_util.dart';
import 'event_types.dart';

export 'event_types.dart';

/// A single tracked event.
class UnilitixEvent {
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

  // CRASH fields
  String? stackTrace;
  String? exceptionType;
  String? exceptionMessage;
  List<Map<String, dynamic>>? breadcrumbs;

  // CUSTOM fields
  String? eventName;

  UnilitixEvent({
    required this.type,
    this.screen,
    this.x,
    this.y,
    Map<String, dynamic>? properties,
  })  : properties = properties ?? {},
        timestamp = DateTime.now().millisecondsSinceEpoch;

  Map<String, dynamic> toJson() {
    final map = <String, dynamic>{
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

    if (type == EventTypes.crash) {
      if (stackTrace != null) map['stackTrace'] = stackTrace;
      if (exceptionType != null) map['exceptionType'] = exceptionType;
      if (exceptionMessage != null) map['exceptionMessage'] = exceptionMessage;
      if (breadcrumbs != null) map['breadcrumbs'] = breadcrumbs;
    }

    if (type == EventTypes.custom) {
      map['metadata'] = {
        if (eventName != null) 'name': eventName,
        ...properties,
      };
    }

    return map;
  }

  Map<String, dynamic> toMap() => toJson();
}
