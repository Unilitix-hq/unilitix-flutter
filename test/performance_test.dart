import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:image/image.dart' as img;
import 'package:unilitix/src/capture/image_encode.dart';
import 'package:unilitix/src/events/event.dart';

/// Performance / classification regression tests (October 2026 audit).
void main() {
  test('encodeFrame downscales, occludes and returns a JPEG', () {
    // 40x20 white frame.
    final rgba = Uint8List(40 * 20 * 4)..fillRange(0, 40 * 20 * 4, 255);
    final bytes = encodeFrame(EncodeRequest(
      rgba: rgba,
      width: 40,
      height: 20,
      maxWidth: 20,
      quality: 90,
      masks: const [
        [0, 0, 20, 20] // left half, in source pixels
      ],
    ));
    final decoded = img.decodeJpg(bytes)!;
    expect(decoded.width, 20);
    expect(decoded.height, 10);
    // Left half masked black, right half still light.
    final left = decoded.getPixel(2, 5);
    final right = decoded.getPixel(17, 5);
    expect(left.r, lessThan(40));
    expect(right.r, greaterThan(200));
  });

  test('EXCEPTION and CRASH carry the fatal flag', () {
    final ex = UnilitixEvent(type: EventTypes.exception)..title = 'overflow';
    expect(ex.toJson()['fatal'], isFalse);
    final native = UnilitixEvent(type: EventTypes.crash)..fatal = true;
    expect(native.toJson()['fatal'], isTrue);
    final tap = UnilitixEvent(type: EventTypes.tap);
    expect(tap.toJson().containsKey('fatal'), isFalse);
  });
}
