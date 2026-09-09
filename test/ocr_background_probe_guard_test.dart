import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter_test/flutter_test.dart';
import 'package:venera/foundation/image_translation/page_renderer.dart';
import 'package:venera/foundation/image_translation/translation_types.dart';

/// S3 — the buffer guard in `backgroundReadsDark` did not cover its own probe.
///
/// The sampling path reads more than the box. Each sample calls `_blurredLum`,
/// which averages a ±[kSolidBackgroundProbe] (2 px) window, so a box ending at
/// `bottom` reads through row `bottom + 2` — clamped to the image's own last
/// row, `h - 1`. The old guard was
///
/// ```dart
/// if (pixels.length < (bottom * w) * 4) return false;
/// ```
///
/// which only proved the box's *own* rows fit. `decoded.pixels` can be shorter
/// than the declared `width * height` (the `keptBadBuffer` case `inpaint.dart`
/// documents), and then a box that stopped two rows short of the end passed the
/// guard and the probe walked past the end of the buffer: `RangeError`, on the
/// main-isolate render path. The guard is now
/// `min(bottom + kSolidBackgroundProbe, image.height) * w * 4`, so a truncated
/// buffer answers "no evidence" — the light branch — instead of throwing.
///
/// The red assertions below are the middle two: under the old guard the
/// truncated fixture passed the check and the probe threw `RangeError`, so
/// neither `isFalse` nor the "no throw" expectation held. The full-buffer
/// controls keep the guard from being "fixed" by always answering light.
///
/// NOT VERIFIED LOCALLY (no `flutter test` in this workspace) — see the
/// "待云端 Test job 验证" list in the hand-off report.
RgbaImage _darkRows(int declaredW, int declaredH, int rowsInBuffer) {
  final px = Uint8List(declaredW * rowsInBuffer * 4);
  for (var i = 0; i < px.length; i += 4) {
    px[i] = 8;
    px[i + 1] = 8;
    px[i + 2] = 8;
    px[i + 3] = 255;
  }
  return RgbaImage(declaredW, declaredH, px);
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('a buffer shorter than the declared page is never read past', () {
    test('a box two rows above the truncation answers false, not RangeError',
        () {
      // 40x40 declared, only 24 rows present. The box is rows 0..22, so the
      // 5x5 probe needs row 24 — the first row the buffer does not have.
      final truncated = _darkRows(40, 40, 24);
      final box = const ui.Rect.fromLTRB(0, 0, 40, 23);
      expect(
        () => backgroundReadsDark(truncated, box),
        returnsNormally,
        reason: 'the guard must answer before the probe can read past the end',
      );
      expect(backgroundReadsDark(truncated, box), isFalse);
    });

    test('the same box on a complete dark buffer is dark (control)', () {
      // Same box, same pixels, full buffer: the measurement itself is
      // unchanged by the guard, so the fixture is known-dark and the test
      // above is proving the guard, not the luminance rule.
      expect(backgroundReadsDark(_darkRows(40, 40, 40), const ui.Rect.fromLTRB(0, 0, 40, 23)),
          isTrue);
    });

    test('a box that touches the truncated edge still answers false', () {
      // bottom == h clamps the probe to row h-1, which the buffer does not
      // have either; this is the case the old guard also rejected, kept so a
      // future tightening cannot start throwing here instead.
      final truncated = _darkRows(40, 40, 24);
      expect(
        () => backgroundReadsDark(truncated, const ui.Rect.fromLTRB(0, 0, 40, 40)),
        returnsNormally,
      );
      expect(
        backgroundReadsDark(truncated, const ui.Rect.fromLTRB(0, 0, 40, 40)),
        isFalse,
      );
    });

    test('a full buffer at the same declared size is unaffected', () {
      expect(
        backgroundReadsDark(
          _darkRows(40, 40, 40),
          const ui.Rect.fromLTRB(0, 0, 40, 40),
        ),
        isTrue,
      );
    });
  });
}
