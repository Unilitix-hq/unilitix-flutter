import 'dart:typed_data';
import 'dart:ui' as ui;

/// Downscales a captured frame, paints occlusion boxes over [masks] (given in
/// source pixels) and PNG-encodes it, using nothing but `dart:ui`.
///
/// This is the fallback for platforms without the native plugin (web,
/// desktop, Android < 26); Android and iOS encode JPEG natively off the UI
/// thread. Until 2.1.0 this path used the pure-Dart `image` package, which
/// added ~1 MB of Dart to every host app's dependency tree for a path most
/// of them never execute. PNG frames are larger than JPEG, but the only
/// screens that take this route are not on metered links.
///
/// Returns null if the engine cannot rasterise (headless embedder).
Future<Uint8List?> encodeFrameUi(
  ui.Image src, {
  required int maxWidth,
  required List<ui.Rect> masks,
}) async {
  final factor =
      (maxWidth > 0 && src.width > maxWidth) ? maxWidth / src.width : 1.0;
  final w = (src.width * factor).round().clamp(1, 1 << 14);
  final h = (src.height * factor).round().clamp(1, 1 << 14);

  final recorder = ui.PictureRecorder();
  final canvas = ui.Canvas(recorder);
  canvas.drawImageRect(
    src,
    ui.Rect.fromLTWH(0, 0, src.width.toDouble(), src.height.toDouble()),
    ui.Rect.fromLTWH(0, 0, w.toDouble(), h.toDouble()),
    ui.Paint()..filterQuality = ui.FilterQuality.low,
  );
  if (masks.isNotEmpty) {
    final black = ui.Paint()..color = const ui.Color(0xFF000000);
    for (final m in masks) {
      final r = ui.Rect.fromLTRB(
        m.left * factor - 1,
        m.top * factor - 1,
        m.right * factor + 1,
        m.bottom * factor + 1,
      );
      if (r.width > 0 && r.height > 0) canvas.drawRect(r, black);
    }
  }
  final picture = recorder.endRecording();
  ui.Image? out;
  try {
    out = await picture.toImage(w, h);
    final data = await out.toByteData(format: ui.ImageByteFormat.png);
    return data?.buffer.asUint8List();
  } catch (_) {
    return null;
  } finally {
    out?.dispose();
    picture.dispose();
  }
}
