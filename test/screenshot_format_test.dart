import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:unilitix/src/generated/ingest_models.dart';
import 'package:unilitix/src/network/api_client.dart';

Uint8List _bytes(List<int> head) =>
    Uint8List.fromList([...head, ...List.filled(16, 0)]);

void main() {
  group('screenshotFormatOf', () {
    test('JPEG (native capture)', () {
      final b = _bytes([0xFF, 0xD8, 0xFF, 0xE0]);
      expect(screenshotFormatOf(b), 'jpeg');
      expect(screenshotContentType(b), 'image/jpeg');
    });
    test('PNG (Dart fallback)', () {
      final b = _bytes([0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A]);
      expect(screenshotFormatOf(b), 'png');
      expect(screenshotContentType(b), 'image/png');
    });
    test('WebP', () {
      final b = _bytes([
        0x52, 0x49, 0x46, 0x46, 0, 0, 0, 0, //
        0x57, 0x45, 0x42, 0x50,
      ]);
      expect(screenshotFormatOf(b), 'webp');
      expect(screenshotContentType(b), 'image/webp');
    });
    test('unknown or short bytes count as JPEG', () {
      expect(screenshotFormatOf(Uint8List(0)), 'jpeg');
      expect(screenshotFormatOf(Uint8List.fromList([1, 2, 3])), 'jpeg');
    });
  });

  test('init request carries the format', () {
    final json = const ScreenshotInitRequest(
      sessionId: 's',
      count: 1,
      ordinals: [0],
      format: 'png',
    ).toJson();
    expect(json['format'], 'png');
  });
}
