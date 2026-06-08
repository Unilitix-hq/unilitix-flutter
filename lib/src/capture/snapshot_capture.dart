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

      final children = <Map<String, dynamic>>[];
      _visitElement(element, children);

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
    } catch (e) {
      UnilitixLogger.e('Snapshot capture failed', e);
    }
  }

  /// Traverses the element tree. Renderable nodes are serialized and added
  /// to [output]. Non-renderable nodes are traversed transparently —
  /// their children are added to the same [output] list.
  void _visitElement(Element element, List<Map<String, dynamic>> output) {
    final type = element.widget.runtimeType.toString();

    // Always mask private subtrees
    if (type == 'UnilitixPrivate') {
      output.add({'type': 'masked'});
      return;
    }

    if (_kRenderableTypes.contains(type)) {
      final node = _serializeRenderable(element, type);
      if (node != null) {
        // Recurse children into this node
        final childOutput = <Map<String, dynamic>>[];
        element.visitChildren((child) => _visitElement(child, childOutput));
        if (childOutput.isNotEmpty) node['children'] = childOutput;
        output.add(node);
      }
    } else {
      // Framework/wrapper node — traverse transparently
      element.visitChildren((child) => _visitElement(child, output));
    }
  }

  Map<String, dynamic>? _serializeRenderable(Element element, String type) {
    final renderObject = element.renderObject;
    Size? size;
    Offset? offset;

    if (renderObject is RenderBox && renderObject.hasSize) {
      size = renderObject.size;
      try {
        offset = renderObject.localToGlobal(Offset.zero);
      } catch (_) {}
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

    // Extract text content
    final widget = element.widget;
    if (widget is Text && widget.data != null) {
      node['text'] = widget.data;
    } else if (widget is Text && widget.textSpan != null) {
      node['text'] = widget.textSpan!.toPlainText();
    }

    // Mask inputs
    if (maskInputs && _kInputTypes.contains(type)) {
      node['text'] = '[MASKED]';
    }

    // Extract icon name
    if (widget is Icon && widget.icon != null) {
      node['icon'] = widget.icon!.codePoint.toRadixString(16);
    }

    // Extract button label
    if (type == 'ElevatedButton' || type == 'TextButton' || type == 'OutlinedButton') {
      node['role'] = 'button';
    }

    // Visibility hint for images
    if (type == 'Image') node['role'] = 'image';

    return node;
  }
}
