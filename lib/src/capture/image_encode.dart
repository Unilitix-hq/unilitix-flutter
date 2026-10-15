import 'dart:typed_data';

import 'package:image/image.dart' as img;

/// Arguments for [encodeFrame], which runs in a background isolate via
/// `compute()`. Everything here must be sendable between isolates.
class EncodeRequest {
  final Uint8List rgba;
  final int width;
  final int height;
  final int maxWidth;
  final int quality;

  /// Occlusion rectangles in image pixels (already scaled by the caller):
  /// [left, top, right, bottom].
  final List<List<double>> masks;

  const EncodeRequest({
    required this.rgba,
    required this.width,
    required this.height,
    required this.maxWidth,
    required this.quality,
    required this.masks,
  });
}

/// Downscales, paints occlusion boxes and JPEG-encodes a raw RGBA frame.
/// Pure Dart, CPU-bound: always call through `compute()` so the UI isolate
/// never pays for it.
Uint8List encodeFrame(EncodeRequest req) {
  var image = img.Image.fromBytes(
    width: req.width,
    height: req.height,
    bytes: req.rgba.buffer,
    numChannels: 4,
    order: img.ChannelOrder.rgba,
  );
  var factor = 1.0;
  if (req.maxWidth > 0 && image.width > req.maxWidth) {
    factor = req.maxWidth / image.width;
    image = img.copyResize(image, width: req.maxWidth);
  }
  if (req.masks.isNotEmpty) {
    final black = img.ColorRgb8(0, 0, 0);
    for (final m in req.masks) {
      if (m.length < 4) continue;
      final x1 = ((m[0] * factor) - 1).floor().clamp(0, image.width - 1);
      final y1 = ((m[1] * factor) - 1).floor().clamp(0, image.height - 1);
      final x2 = ((m[2] * factor) + 1).ceil().clamp(0, image.width - 1);
      final y2 = ((m[3] * factor) + 1).ceil().clamp(0, image.height - 1);
      if (x2 <= x1 || y2 <= y1) continue;
      img.fillRect(image, x1: x1, y1: y1, x2: x2, y2: y2, color: black);
    }
  }
  return Uint8List.fromList(img.encodeJpg(image, quality: req.quality));
}
