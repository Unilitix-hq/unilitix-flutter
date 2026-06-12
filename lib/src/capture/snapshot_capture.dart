import 'dart:async';
import 'package:flutter/widgets.dart';

import 'snapshot_buffer.dart';
import '../core/sdk_scope.dart';
import '../logger/logger.dart';
import '../util/json_util.dart';

/// Renderable widget types — only these are included in the output.
/// Everything else is traversed but not serialized (UXCam-style view pruning).
const Set<String> _kRenderableTypes = {
  // Text
  'Text', 'RichText', 'SelectableText',
  // Layout
  'Container', 'SizedBox', 'Padding', 'Align', 'Center',
  'ConstrainedBox', 'FractionallySizedBox', 'AspectRatio',
  'Expanded', 'Flexible', 'Spacer',
  // Structure
  'Column', 'Row', 'Stack', 'Flex', 'Wrap',
  'ListView', 'GridView', 'CustomScrollView', 'SingleChildScrollView',
  'Scaffold', 'AppBar', 'BottomNavigationBar', 'Drawer',
  'TabBar', 'TabBarView', 'BottomAppBar',
  // Visual
  'Image', 'Icon', 'CircleAvatar', 'DecoratedBox',
  'Card', 'Divider', 'VerticalDivider',
  'ClipRRect', 'ClipOval', 'ClipRect',
  // Interactive
  'GestureDetector', 'InkWell', 'InkResponse',
  'ElevatedButton', 'TextButton', 'OutlinedButton', 'IconButton',
  'FloatingActionButton', 'CupertinoButton',
  'Switch', 'Checkbox', 'Radio', 'Slider',
  'DropdownButton', 'PopupMenuButton',
  // Inputs
  'TextField', 'TextFormField', 'EditableText', 'CupertinoTextField',
  // Feedback
  'CircularProgressIndicator', 'LinearProgressIndicator',
  'RefreshIndicator', 'SnackBar',
  // Overlays
  'Dialog', 'AlertDialog', 'SimpleDialog',
  'BottomSheet', 'Tooltip',
  // List items
  'ListTile', 'CheckboxListTile', 'SwitchListTile', 'RadioListTile',
  // Navigation
  'NavigationBar', 'NavigationRail', 'NavigationDrawer',
};

/// Input types to mask
const Set<String> _kInputTypes = {
  'TextField', 'TextFormField', 'EditableText', 'CupertinoTextField',
};

/// Pure layout nodes — localToGlobal is skipped for these types.
/// They have no meaningful screen position independent of their children.
const Set<String> _kSkipPositionTypes = {
  'Padding', 'Align', 'Center', 'Column', 'Row', 'Stack',
  'Flex', 'Wrap', 'Expanded', 'Flexible', 'SizedBox',
  'ConstrainedBox', 'FractionallySizedBox',
};

class SnapshotCapture with WidgetsBindingObserver {
  final SnapshotBuffer buffer;
  final int intervalMs;
  final bool maskInputs;

  int _ordinal = 0;
  Timer? _timer;
  bool _capturing = false;
  bool _active = false;

  SnapshotCapture({
    required this.buffer,
    required this.intervalMs,
    required this.maskInputs,
  });

  void start() {
    _active = true;
    WidgetsBinding.instance.addObserver(this);
    final clamped = intervalMs.clamp(1000, 60000);
    _timer = Timer.periodic(Duration(milliseconds: clamped), (_) => _scheduledCapture());
  }

  void stop() {
    _active = false;
    WidgetsBinding.instance.removeObserver(this);
    _timer?.cancel();
    _timer = null;
  }

  void resetOrdinal() => _ordinal = 0;

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.paused) {
      _active = false;
    } else if (state == AppLifecycleState.resumed) {
      _active = true;
    }
  }

  // Fix 1: defer capture to after the current frame is committed so the
  // traversal does not block rasterisation.
  void _scheduledCapture() {
    if (!_active) return;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _capture();
    });
  }

  Future<void> _capture() async {
    if (_capturing) return;
    _capturing = true;
    try {
      final element = WidgetsBinding.instance.rootElement;
      if (element == null) return;

      final children = <Map<String, dynamic>>[];
      // Fix 3: async traversal yields between top-level subtrees.
      await _visitElementAsync(element, children);

      if (children.isEmpty) return;

      final view = WidgetsBinding.instance.platformDispatcher.views.first;
      final w = (view.physicalSize.width / view.devicePixelRatio).round();
      final h = (view.physicalSize.height / view.devicePixelRatio).round();

      buffer.add({
        'capturedAt': JsonUtil.toRfc3339(DateTime.now().millisecondsSinceEpoch),
        'ordinal': _ordinal++,
        'screenName': SdkScope.currentScreen ?? 'unknown',
        'viewportWidth': w,
        'viewportHeight': h,
        'hierarchy': {'type': 'Root', 'w': w, 'h': h, 'children': children},
      });
    } catch (e, stack) {
      UnilitixLogger.e('Snapshot capture failed', e, stack);
    } finally {
      _capturing = false;
    }
  }

  /// Async top-level visitor — collects direct children then yields a
  /// microtask between each one so the event loop can process input and
  /// frames between major subtrees.
  Future<void> _visitElementAsync(
    Element element,
    List<Map<String, dynamic>> output,
  ) async {
    final type = element.widget.runtimeType.toString();

    if (type == 'UnilitixPrivate') {
      output.add({'type': 'masked'});
      return;
    }

    if (_kRenderableTypes.contains(type)) {
      final node = _serializeRenderable(element, type);
      if (node != null) {
        final childOutput = <Map<String, dynamic>>[];
        final childElements = <Element>[];
        element.visitChildren(childElements.add);
        for (final child in childElements) {
          await Future.microtask(() => _visitElement(child, childOutput));
        }
        if (childOutput.isNotEmpty) node['children'] = childOutput;
        output.add(node);
      }
    } else {
      final childElements = <Element>[];
      element.visitChildren(childElements.add);
      for (final child in childElements) {
        await Future.microtask(() => _visitElement(child, output));
      }
    }
  }

  /// Synchronous recursive visitor used within each microtask chunk.
  void _visitElement(Element element, List<Map<String, dynamic>> output) {
    final type = element.widget.runtimeType.toString();

    if (type == 'UnilitixPrivate') {
      output.add({'type': 'masked'});
      return;
    }

    if (_kRenderableTypes.contains(type)) {
      final node = _serializeRenderable(element, type);
      if (node != null) {
        final childOutput = <Map<String, dynamic>>[];
        element.visitChildren((child) => _visitElement(child, childOutput));
        if (childOutput.isNotEmpty) node['children'] = childOutput;
        output.add(node);
      }
    } else {
      element.visitChildren((child) => _visitElement(child, output));
    }
  }

  Map<String, dynamic>? _serializeRenderable(Element element, String type) {
    final renderObject = element.renderObject;
    Size? size;
    Offset? offset;

    if (renderObject is RenderBox && renderObject.hasSize) {
      size = renderObject.size;
      // Fix 2: skip localToGlobal for pure layout nodes — the matrix
      // multiplication up the render tree is expensive and position is
      // not meaningful for these container types.
      if (!_kSkipPositionTypes.contains(type)) {
        try {
          offset = renderObject.localToGlobal(Offset.zero);
        } catch (_) {}
      }
    }

    // Skip zero-size invisible nodes
    if (size != null && (size.width == 0 || size.height == 0)) return null;

    final node = <String, dynamic>{
      'type': type,
      if (size != null) 'w': size.width.round(),
      if (size != null) 'h': size.height.round(),
      if (offset != null) 'x': offset.dx.round(),
      if (offset != null) 'y': offset.dy.round(),
    };

    final widget = element.widget;
    if (widget is Text && widget.data != null) {
      node['text'] = widget.data;
    } else if (widget is Text && widget.textSpan != null) {
      node['text'] = widget.textSpan!.toPlainText();
    }

    if (maskInputs && _kInputTypes.contains(type)) {
      node['text'] = '[MASKED]';
    }

    if (widget is Icon && widget.icon != null) {
      node['icon'] = widget.icon!.codePoint.toRadixString(16);
    }

    if (type == 'ElevatedButton' || type == 'TextButton' || type == 'OutlinedButton') {
      node['role'] = 'button';
    }

    if (type == 'Image') node['role'] = 'image';

    return node;
  }
}
