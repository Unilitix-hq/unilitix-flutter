import 'dart:async';
import 'package:flutter/widgets.dart';

import 'snapshot_buffer.dart';
import '../core/sdk_scope.dart';
import '../logger/logger.dart';
import '../util/json_util.dart';

/// Periodically serialises the widget tree as a JSON snapshot.
class SnapshotCapture {
  final SnapshotBuffer buffer;
  final int intervalMs;
  final bool maskInputs;

  int _ordinal = 0;
  Timer? _timer;

  SnapshotCapture({
    required this.buffer,
    required this.intervalMs,
    required this.maskInputs,
  });

  void start() {
    final clamped = intervalMs.clamp(1000, 60000);
    _timer = Timer.periodic(Duration(milliseconds: clamped), (_) => _capture());
  }

  void stop() {
    _timer?.cancel();
    _timer = null;
  }

  void resetOrdinal() => _ordinal = 0;

  void _capture() {
    try {
      final element = WidgetsBinding.instance.rootElement;
      if (element == null) return;
      final node = _serializeElement(element, 0);
      if (node != null) {
        final view = WidgetsBinding.instance.platformDispatcher.views.first;
        final w = (view.physicalSize.width / view.devicePixelRatio).round();
        final h = (view.physicalSize.height / view.devicePixelRatio).round();
        buffer.add({
          'capturedAt': JsonUtil.toRfc3339(DateTime.now().millisecondsSinceEpoch),
          'ordinal': _ordinal++,
          'screenName': SdkScope.currentScreen ?? 'unknown',
          'viewportWidth': w,
          'viewportHeight': h,
          'hierarchy': node,
        });
      }
    } catch (e) {
      UnilitixLogger.e('Snapshot capture failed', e);
    }
  }

  Map<String, dynamic>? _serializeElement(Element element, int depth) {
    if (depth > 20) return null;

    // Skip UnilitixPrivate subtrees
    if (element.widget.runtimeType.toString() == 'UnilitixPrivate') {
      return {'type': 'masked'};
    }

    final renderObject = element.renderObject;
    Size? size;
    Offset? offset;

    if (renderObject is RenderBox && renderObject.hasSize) {
      size = renderObject.size;
      try {
        offset = renderObject.localToGlobal(Offset.zero);
      } catch (_) {}
    }

    final Map<String, dynamic> node = {
      'type': element.widget.runtimeType.toString(),
      if (size != null) 'w': size.width.round(),
      if (size != null) 'h': size.height.round(),
      if (offset != null) 'x': offset.dx.round(),
      if (offset != null) 'y': offset.dy.round(),
    };

    // Mask text inputs when maskInputs = true
    if (maskInputs) {
      final type = element.widget.runtimeType.toString();
      if (type.contains('TextField') ||
          type.contains('EditableText') ||
          type.contains('TextFormField')) {
        node['text'] = '[MASKED]';
      }
    }

    final children = <Map<String, dynamic>>[];
    element.visitChildren((child) {
      final c = _serializeElement(child, depth + 1);
      if (c != null) children.add(c);
    });
    if (children.isNotEmpty) node['children'] = children;

    return node;
  }
}
