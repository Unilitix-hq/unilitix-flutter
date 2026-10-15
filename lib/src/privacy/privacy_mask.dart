import 'package:flutter/widgets.dart';

/// Marks a widget subtree as sensitive.
///
/// In wireframe snapshots the subtree is replaced by a single `masked` node.
/// In pixel screenshots its on-screen bounds are painted over with an opaque
/// box before the frame is encoded, so the pixels never leave the device
/// (requires `maskScreenshots: true`, the default).
///
/// ```dart
/// UnilitixPrivate(
///   child: Text(formatCurrency(balance)),
/// )
/// ```
///
/// Text everywhere else is redacted by default (`maskAllText`), so this widget
/// is for content that must not even reach a screenshot: balances, card
/// numbers, chat bubbles, documents.
class UnilitixPrivate extends StatefulWidget {
  final Widget child;

  const UnilitixPrivate({required this.child, super.key});

  @override
  State<UnilitixPrivate> createState() => _UnilitixPrivateState();
}

class _UnilitixPrivateState extends State<UnilitixPrivate> {
  @override
  void initState() {
    super.initState();
    PrivacyRegistry.register(this);
  }

  @override
  void dispose() {
    PrivacyRegistry.unregister(this);
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => widget.child;
}

/// Tracks every mounted [UnilitixPrivate] so screenshot capture can find the
/// regions to occlude without walking the whole element tree each frame.
class PrivacyRegistry {
  PrivacyRegistry._();

  static final Set<State> _mounted = {};

  static void register(State s) => _mounted.add(s);
  static void unregister(State s) => _mounted.remove(s);

  static int get mountedCount => _mounted.length;

  /// Global (logical-pixel) bounds of every mounted private subtree.
  static List<Rect> privateRects() {
    final out = <Rect>[];
    for (final s in _mounted) {
      if (!s.mounted) continue;
      final ro = s.context.findRenderObject();
      if (ro is RenderBox && ro.hasSize && ro.attached) {
        try {
          final origin = ro.localToGlobal(Offset.zero);
          out.add(origin & ro.size);
        } catch (_) {
          // Detached mid-frame; skip.
        }
      }
    }
    return out;
  }

  /// Widget types treated as images for `maskImages`.
  static const Set<String> imageTypes = {
    'Image',
    'RawImage',
    'FadeInImage',
    'CircleAvatar',
    'CachedNetworkImage',
    'SvgPicture',
  };

  /// Global bounds of every image widget currently in the tree. Walks the
  /// element tree, so only call it when `maskImages` is on.
  static List<Rect> imageRects() {
    final root = WidgetsBinding.instance.rootElement;
    if (root == null) return const [];
    final out = <Rect>[];
    void visit(Element e) {
      if (imageTypes.contains(e.widget.runtimeType.toString())) {
        final ro = e.renderObject;
        if (ro is RenderBox && ro.hasSize && ro.attached) {
          try {
            out.add(ro.localToGlobal(Offset.zero) & ro.size);
          } catch (_) {}
        }
        return; // nested images are covered by the parent box
      }
      e.visitChildren(visit);
    }

    visit(root);
    return out;
  }
}

/// Replaces every non-whitespace character with a bullet, so the redacted
/// string has the same length and word shape as the original. Used for
/// `maskAllText` in wireframe snapshots.
String redactText(String text) {
  if (text.isEmpty) return text;
  final buf = StringBuffer();
  for (final rune in text.runes) {
    final ch = String.fromCharCode(rune);
    buf.write(ch.trim().isEmpty ? ch : '•');
  }
  return buf.toString();
}
