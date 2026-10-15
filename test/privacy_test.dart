import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:unilitix/src/config.dart';
import 'package:unilitix/src/privacy/privacy_mask.dart';

/// Privacy regression tests (October 2026 audit).
void main() {
  group('redactText', () {
    test('preserves length and whitespace, hides every other character', () {
      const input = 'Balance: NGN 1,250,000.00';
      final out = redactText(input);
      expect(out.length, input.length);
      expect(out.contains('1'), isFalse);
      expect(out.contains('N'), isFalse);
      expect(out.split(' ').length, input.split(' ').length);
      expect(out[8], ' ');
    });

    test('handles empty and multi-byte strings', () {
      expect(redactText(''), '');
      final out = redactText('Adé Ọlá');
      expect(out.runes.length, 'Adé Ọlá'.runes.length);
      expect(out.contains('é'), isFalse);
    });
  });

  group('UnilitixConfig privacy defaults', () {
    test('text redaction and screenshot masking are on by default', () {
      const cfg = UnilitixConfig(apiKey: 'k');
      expect(cfg.maskAllText, isTrue);
      expect(cfg.maskScreenshots, isTrue);
      expect(cfg.maskImages, isFalse);
      expect(cfg.copyWith(maskImages: true).maskImages, isTrue);
    });
  });

  group('PrivacyRegistry', () {
    testWidgets('tracks mounted UnilitixPrivate subtrees and their bounds', (tester) async {
      await tester.pumpWidget(
        const Directionality(
          textDirection: TextDirection.ltr,
          child: Center(
            child: UnilitixPrivate(
              child: SizedBox(width: 120, height: 40, child: Text('secret')),
            ),
          ),
        ),
      );
      expect(PrivacyRegistry.mountedCount, 1);
      final rects = PrivacyRegistry.privateRects();
      expect(rects.length, 1);
      expect(rects.single.width, 120);
      expect(rects.single.height, 40);

      await tester.pumpWidget(const SizedBox.shrink());
      expect(PrivacyRegistry.mountedCount, 0);
    });
  });
}
