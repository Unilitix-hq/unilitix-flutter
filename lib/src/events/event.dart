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

  Map<String, dynamic> toJson() => {
        'type': type,
        if (screen != null) 'screen': screen,
        if (x != null) 'x': x,
        if (y != null) 'y': y,
        'properties': properties,
        'timestamp': timestamp,
        'capturedOffline': capturedOffline,
        'networkAtCapture': networkAtCapture,
        if (memoryUsageMb != null) 'memoryUsageMb': memoryUsageMb,
        if (cpuUsagePct != null) 'cpuUsagePct': cpuUsagePct,
        if (frameDrops != null) 'frameDrops': frameDrops,
        if (stackTrace != null) 'stackTrace': stackTrace,
        if (exceptionType != null) 'exceptionType': exceptionType,
        if (exceptionMessage != null) 'exceptionMessage': exceptionMessage,
        if (breadcrumbs != null) 'breadcrumbs': breadcrumbs,
        if (eventName != null) 'eventName': eventName,
      };
}
