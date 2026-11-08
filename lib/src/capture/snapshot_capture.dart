import 'dart:async';

import 'package:flutter/widgets.dart';

import 'widget_kind.dart';
import '../core/sdk_scope.dart';
import '../privacy/privacy_mask.dart';
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
  'TextField',
  'TextFormField',
  'EditableText',
  'CupertinoTextField',
};

/// Pure layout nodes — localToGlobal is skipped for these types.
/// They have no meaningful screen position independent of their children.
const Set<String> _kSkipPositionTypes = {
  'Padding',
  'Align',
  'Center',
  'Column',
  'Row',
  'Stack',
  'Flex',
  'Wrap',
  'Expanded',
  'Flexible',
  'SizedBox',
  'ConstrainedBox',
  'FractionallySizedBox',
};

/// Result of one wireframe walk.
class WireframeWalk {
  /// Serialised top-level nodes.
  final List<Map<String, dynamic>> children;

  /// Order-sensitive structural hash of the tree.
  final int hash;

  /// Approximate JSON size of [children], in bytes.
  final int approxBytes;

  /// How many times the walk gave the UI isolate back before finishing.
  final int yields;

  const WireframeWalk(this.children, this.hash, this.approxBytes, this.yields);
}

class _Pending {
  final Element element;
  final List<Map<String, dynamic>> output;
  const _Pending(this.element, this.output);
}

/// Walks the widget tree into masked wireframe snapshots for session replay
/// and hands each one to [onSnapshot] (since 3.0.0 the SDK passes it to the
/// native SDK's `addExternalSnapshot`, which assigns the ordinal, applies the
/// session's sampling and caps, stores and uploads it).
class SnapshotCapture with WidgetsBindingObserver {
  /// Receives each new snapshot: `capturedAt` (RFC 3339), `screenName`,
  /// `viewportWidth`, `viewportHeight` (logical pixels) and `hierarchy`.
  /// [approxBytes] is the walk's estimate of its JSON size.
  final void Function(Map<String, dynamic> snapshot, int approxBytes)
      onSnapshot;
  final int intervalMs;
  final bool maskInputs;

  /// Redact all text (length-preserving). Default on; see [UnilitixConfig].
  final bool maskAllText;

  /// Mark image nodes as masked.
  final bool maskImages;

  /// Longest stretch the walk runs on the UI isolate before it yields to the
  /// event loop, so frames and input are handled in between. At 4 ms a 60 Hz
  /// frame keeps three quarters of its budget even if a slice lands in it.
  final Duration sliceBudget;

  /// Notified when the structural hash of the tree changes between captures,
  /// so screenshot capture can take a frame only when the UI actually moved.
  void Function()? onChanged;

  Timer? _timer;
  bool _capturing = false;
  bool _active = false;
  int _lastHash = 0;
  int _hash = 0;
  int _approxBytes = 0;

  /// Frames drawn since the counter was installed. Read before and during a
  /// walk: a frame in between means the element tree may have changed.
  static int _framesDrawn = 0;
  static bool _frameCounterInstalled = false;

  /// [_framesDrawn] when the last completed walk started; -1 before the first.
  int _lastWalkFrame = -1;

  /// Consecutive walks abandoned because a frame landed mid-walk.
  int _abandoned = 0;

  /// After this many abandoned walks in a row (a screen that animates without
  /// pause), the next walk runs to completion across frames, skipping any
  /// element that was unmounted in between, rather than never finishing.
  static const int _kMaxAbandoned = 3;

  SnapshotCapture({
    required this.onSnapshot,
    required this.intervalMs,
    required this.maskInputs,
    this.maskAllText = true,
    this.maskImages = false,
    this.sliceBudget = const Duration(milliseconds: 4),
  });

  /// Counts frames with a persistent frame callback: it runs only inside
  /// frames the app draws anyway and never schedules one, so an idle app
  /// stays idle. Installed once per process (persistent callbacks cannot be
  /// removed).
  static void _installFrameCounter() {
    if (_frameCounterInstalled) return;
    _frameCounterInstalled = true;
    WidgetsBinding.instance.addPersistentFrameCallback((_) => _framesDrawn++);
  }

  /// Counts a frame as if one had been drawn; for tests.
  @visibleForTesting
  static void debugNoteFrame() => _framesDrawn++;

  void start() {
    if (_timer != null) return; // idempotent: consent changes call it again
    _active = true;
    _installFrameCounter();
    WidgetsBinding.instance.addObserver(this);
    final clamped = intervalMs.clamp(1000, 60000);
    _timer = Timer.periodic(
        Duration(milliseconds: clamped), (_) => _scheduledCapture());
  }

  void stop() {
    _active = false;
    WidgetsBinding.instance.removeObserver(this);
    _timer?.cancel();
    _timer = null;
  }

  /// A new native session started: the first walk is sent even if the
  /// tree did not change.
  void resetSession() => _lastHash = 0;

  bool get isActive => _timer != null;

  /// Runs one walk now and delivers it if the tree changed; for tests.
  @visibleForTesting
  Future<void> captureNow() => _capture();

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.paused) {
      _active = false;
    } else if (state == AppLifecycleState.resumed && _timer != null) {
      _active = true;
    }
  }

  /// Timer tick. Nothing is walked unless a frame was drawn since the last
  /// walk: an unchanged screen cannot produce a different wireframe. The
  /// walk starts from the timer (between frames), not from a post-frame
  /// callback, so ticks on an idle screen leave nothing queued behind.
  void _scheduledCapture() {
    if (!_active || _capturing) return;
    if (_framesDrawn == _lastWalkFrame) return;
    unawaited(_capture());
  }

  Future<void> _capture() async {
    if (_capturing) return;
    _capturing = true;
    try {
      final element = WidgetsBinding.instance.rootElement;
      if (element == null) return;

      final result = await walk(element);
      if (result == null || !_active) return; // abandoned or stopped
      final children = result.children;
      if (children.isEmpty) return;

      // Identical tree to the previous capture: nothing to add. Replays
      // interpolate across the gap, and the session stays within its caps.
      if (result.hash == _lastHash) return;
      _lastHash = result.hash;
      onChanged?.call();

      final view = WidgetsBinding.instance.platformDispatcher.views.first;
      final w = (view.physicalSize.width / view.devicePixelRatio).round();
      final h = (view.physicalSize.height / view.devicePixelRatio).round();

      onSnapshot({
        'capturedAt': JsonUtil.toRfc3339(DateTime.now().millisecondsSinceEpoch),
        'screenName': SdkScope.currentScreen ?? 'unknown',
        'viewportWidth': w,
        'viewportHeight': h,
        'hierarchy': {'type': 'Root', 'w': w, 'h': h, 'children': children},
      }, result.approxBytes + 200);
    } catch (e, stack) {
      UnilitixLogger.e('Snapshot capture failed', e, stack);
    } finally {
      _capturing = false;
    }
  }

  /// Walks the element tree under [root] and serialises it, in slices of at
  /// most [sliceBudget] separated by a yield to the event loop.
  ///
  /// Returns null when the walk was abandoned: a frame was drawn between two
  /// slices (the tree may have changed, so the half-built wireframe would mix
  /// two screens) or an element was unmounted. The next timer tick retries.
  /// The output is identical to a single synchronous pre-order walk.
  @visibleForTesting
  Future<WireframeWalk?> walk(Element root) async {
    final startFrame = _framesDrawn;
    final tolerant = _abandoned >= _kMaxAbandoned;
    _hash = 17;
    _approxBytes = 0;
    final out = <Map<String, dynamic>>[];
    // Renderable nodes get their child list up front; empty ones are removed
    // at the end so the output matches the recursive serialiser's.
    final parents = <Map<String, dynamic>>[];
    final stack = <_Pending>[_Pending(root, out)];
    final sw = Stopwatch()..start();
    var yields = 0;

    while (stack.isNotEmpty) {
      if (sw.elapsed >= sliceBudget) {
        await Future<void>.delayed(Duration.zero);
        yields++;
        if (!tolerant && _framesDrawn != startFrame) {
          _abandoned++;
          return null;
        }
        sw
          ..reset()
          ..start();
      }
      final p = stack.removeLast();
      final element = p.element;
      if (!element.mounted) {
        if (tolerant) continue;
        _abandoned++;
        return null;
      }
      try {
        _visit(element, p.output, stack, parents);
      } catch (_) {
        // A defunct or mid-update element: leave it out of this wireframe.
      }
    }

    for (final node in parents) {
      if ((node['children'] as List).isEmpty) node.remove('children');
    }
    _abandoned = 0;
    _lastWalkFrame = startFrame;
    return WireframeWalk(out, _hash, _approxBytes, yields);
  }

  /// The pre-2.7.4 serialiser: one synchronous recursive walk. Kept as the
  /// reference the sliced [walk] is tested against; not used at runtime.
  @visibleForTesting
  WireframeWalk walkSync(Element root) {
    _hash = 17;
    _approxBytes = 0;
    final out = <Map<String, dynamic>>[];
    void visit(Element element, List<Map<String, dynamic>> output) {
      final type = widgetKind(element.widget);
      if (type == 'UnilitixPrivate') {
        output.add({'type': 'masked'});
        _approxBytes += 20;
        return;
      }
      if (type == kPlatformViewKind) {
        output.add(_platformViewNode(element));
        _approxBytes += 90;
        return;
      }
      if (_kRenderableTypes.contains(type)) {
        final node = _serializeRenderable(element, type);
        if (node != null) {
          final childOutput = <Map<String, dynamic>>[];
          element.visitChildren((child) => visit(child, childOutput));
          if (childOutput.isNotEmpty) node['children'] = childOutput;
          output.add(node);
        }
      } else {
        element.visitChildren((child) => visit(child, output));
      }
    }

    visit(root, out);
    return WireframeWalk(out, _hash, _approxBytes, 0);
  }

  /// Serialises one element into [output] and pushes its children (in
  /// reverse, so they pop in order) for the walk to continue with.
  void _visit(
    Element element,
    List<Map<String, dynamic>> output,
    List<_Pending> stack,
    List<Map<String, dynamic>> parents,
  ) {
    final type = widgetKind(element.widget);

    if (type == 'UnilitixPrivate') {
      output.add({'type': 'masked'});
      _approxBytes += 20;
      return;
    }
    if (type == kPlatformViewKind) {
      output.add(_platformViewNode(element));
      _approxBytes += 90;
      return;
    }

    var target = output;
    if (_kRenderableTypes.contains(type)) {
      final node = _serializeRenderable(element, type);
      if (node == null) return; // zero-size: the subtree is not drawn
      final childOutput = <Map<String, dynamic>>[];
      node['children'] = childOutput;
      output.add(node);
      parents.add(node);
      target = childOutput;
    }

    final children = <Element>[];
    element.visitChildren(children.add);
    for (var i = children.length - 1; i >= 0; i--) {
      stack.add(_Pending(children[i], target));
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
    _approxBytes += 56 + type.length;
    _mix(type.hashCode);
    if (size != null) _mix(size.width.round() * 7919 + size.height.round());
    if (offset != null) _mix(offset.dx.round() * 7919 + offset.dy.round());

    final widget = element.widget;
    String? text;
    if (widget is Text && widget.data != null) {
      text = widget.data;
    } else if (widget is Text && widget.textSpan != null) {
      text = widget.textSpan!.toPlainText();
    } else if (widget is RichText) {
      text = widget.text.toPlainText();
    }
    if (text != null) {
      // Default is to redact: the replay keeps word shapes and lengths for
      // layout fidelity but never carries the characters themselves.
      node['text'] = maskAllText ? redactText(text) : text;
      if (maskAllText) node['redacted'] = true;
      // Redacted text is all '•', three bytes each in UTF-8.
      _approxBytes += 24 + text.length * 3;
      _mix(text.hashCode);
    }

    if (maskInputs && _kInputTypes.contains(type)) {
      node['text'] = '[MASKED]';
    }

    if (maskImages && PrivacyRegistry.isImageWidget(widget)) {
      node['masked'] = true;
    }

    if (widget is Icon && widget.icon != null) {
      node['icon'] = widget.icon!.codePoint.toRadixString(16);
    }

    if (type == 'ElevatedButton' ||
        type == 'TextButton' ||
        type == 'OutlinedButton') {
      node['role'] = 'button';
    }

    if (type == 'Image') node['role'] = 'image';

    return node;
  }

  /// A platform view (WebView, map, video) as an opaque masked box: its
  /// content is not Flutter's and is never serialised.
  Map<String, dynamic> _platformViewNode(Element element) {
    final node = <String, dynamic>{'type': 'masked', 'role': 'platform-view'};
    final ro = element.renderObject;
    if (ro is RenderBox && ro.hasSize) {
      node['w'] = ro.size.width.round();
      node['h'] = ro.size.height.round();
      try {
        final o = ro.localToGlobal(Offset.zero);
        node['x'] = o.dx.round();
        node['y'] = o.dy.round();
      } catch (_) {}
      _mix(ro.size.width.round() * 7919 + ro.size.height.round());
    }
    _mix(kPlatformViewKind.hashCode);
    return node;
  }

  /// Order-sensitive structural hash; cheap enough to run on every node.
  void _mix(int v) {
    _hash = (_hash * 31 + v) & 0x3fffffff;
  }
}
