import 'package:flutter/rendering.dart';
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
/// Text and inputs everywhere are already masked by default (`maskAllText`,
/// `maskInputs`); this widget is for non-text content that must not reach a
/// screenshot either: charts of balances, QR codes, documents, avatars.
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

/// Opts a widget subtree out of `maskAllText` in pixel screenshots, so the
/// replay shows the real text. Use it for content that carries no personal
/// data and is needed to understand the screen: headings, button labels,
/// navigation, static copy.
///
/// ```dart
/// UnilitixUnmasked(child: Text('Checkout'))
/// ```
///
/// It never overrides [UnilitixPrivate] or `maskInputs`: an input inside an
/// unmasked subtree stays masked.
class UnilitixUnmasked extends StatefulWidget {
  final Widget child;

  const UnilitixUnmasked({required this.child, super.key});

  @override
  State<UnilitixUnmasked> createState() => _UnilitixUnmaskedState();
}

class _UnilitixUnmaskedState extends State<UnilitixUnmasked> {
  @override
  void initState() {
    super.initState();
    PrivacyRegistry.registerUnmasked(this);
  }

  @override
  void dispose() {
    PrivacyRegistry.unregisterUnmasked(this);
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => widget.child;
}

/// Tracks every mounted [UnilitixPrivate] and [UnilitixUnmasked] so screenshot
/// capture can find the regions to occlude (or leave alone) cheaply, and walks
/// the tree for text and inputs when `maskAllText` / `maskInputs` are on.
class PrivacyRegistry {
  PrivacyRegistry._();

  static final Set<State> _mounted = {};
  static final Set<State> _unmasked = {};

  static void register(State s) => _mounted.add(s);
  static void unregister(State s) => _mounted.remove(s);
  static void registerUnmasked(State s) => _unmasked.add(s);
  static void unregisterUnmasked(State s) => _unmasked.remove(s);

  static int get mountedCount => _mounted.length;

  static Rect? _globalRect(RenderObject? ro) {
    if (ro is RenderBox && ro.hasSize && ro.attached) {
      try {
        final r = ro.localToGlobal(Offset.zero) & ro.size;
        if (r.width <= 0 || r.height <= 0) return null;
        return r;
      } catch (_) {
        // Detached mid-frame; skip.
      }
    }
    return null;
  }

  static List<Rect> _rectsOf(Set<State> states) {
    final out = <Rect>[];
    for (final s in states) {
      if (!s.mounted) continue;
      final r = _globalRect(s.context.findRenderObject());
      if (r != null) out.add(r);
    }
    return out;
  }

  /// Global (logical-pixel) bounds of every mounted private subtree.
  static List<Rect> privateRects() => _rectsOf(_mounted);

  /// Global bounds of every mounted [UnilitixUnmasked] subtree.
  static List<Rect> unmaskedRects() => _rectsOf(_unmasked);

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
        final r = _globalRect(e.renderObject);
        if (r != null) out.add(r);
        return; // nested images are covered by the parent box
      }
      e.visitChildren(visit);
    }

    visit(root);
    return out;
  }

  /// Global bounds of text on screen, for occlusion in pixel screenshots.
  ///
  /// With [inputs] every editable field ([RenderEditable], i.e. `TextField`,
  /// `TextFormField`, `CupertinoTextField`, `EditableText`) is included. With
  /// [allText] every [RenderParagraph] (`Text`, `RichText`, `SelectableText`)
  /// is included too, except paragraphs inside a [UnilitixUnmasked] subtree.
  /// Inputs are never exempted by [UnilitixUnmasked].
  ///
  /// This walks the render tree once per captured frame (at most
  /// `maxScreenshotsPerMinute` times a minute), not per build.
  static List<Rect> textRects({required bool inputs, required bool allText}) {
    if (!inputs && !allText) return const [];
    final root = WidgetsBinding.instance.rootElement?.renderObject;
    if (root == null) return const [];
    final exempt = allText ? unmaskedRects() : const <Rect>[];
    final out = <Rect>[];

    bool isExempt(Rect r) {
      final c = r.center;
      for (final u in exempt) {
        if (u.contains(c)) return true;
      }
      return false;
    }

    void visit(RenderObject ro) {
      if (ro is RenderEditable) {
        if (inputs || allText) {
          final r = _globalRect(ro);
          if (r != null) out.add(r);
        }
        return;
      }
      if (allText && ro is RenderParagraph) {
        final r = _globalRect(ro);
        if (r != null && !isExempt(r)) out.add(r);
        return;
      }
      ro.visitChildren(visit);
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
