import 'dart:async';
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter_test/flutter_test.dart';
import 'package:unilitix/src/capture/image_encode.dart';
import 'package:unilitix/src/events/event.dart';

/// Performance / classification regression tests (October 2026 audit).
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  Future<ui.Image> whiteImage(int w, int h) async {
    final rgba = Uint8List(w * h * 4)..fillRange(0, w * h * 4, 255);
    final c = Completer<ui.Image>();
    ui.decodeImageFromPixels(rgba, w, h, ui.PixelFormat.rgba8888, c.complete);
    return c.future;
  }

  Future<Uint8List> rawPixels(Uint8List png) async {
    final codec = await ui.instantiateImageCodec(png);
    final frame = await codec.getNextFrame();
    final data =
        await frame.image.toByteData(format: ui.ImageByteFormat.rawRgba);
    expect(frame.image.width, 20);
    expect(frame.image.height, 10);
    return data!.buffer.asUint8List();
  }

  test('encodeFrameUi downscales, occludes and returns a PNG', () async {
    final src = await whiteImage(40, 20);
    final bytes = await encodeFrameUi(
      src,
      maxWidth: 20,
      masks: const [ui.Rect.fromLTRB(0, 0, 20, 20)], // left half, source px
    );
    expect(bytes, isNotNull);
    // PNG signature.
    expect(bytes!.sublist(0, 4), [0x89, 0x50, 0x4E, 0x47]);
    final px = await rawPixels(bytes);
    int red(int x, int y) => px[(y * 20 + x) * 4];
    expect(red(2, 5), lessThan(40), reason: 'masked half is black');
    expect(red(17, 5), greaterThan(200), reason: 'other half untouched');
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
