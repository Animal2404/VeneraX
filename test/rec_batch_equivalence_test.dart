import 'dart:math' as math;
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:venera/foundation/image_translation/ocr_batching.dart';
import 'package:venera/foundation/image_translation/translation_types.dart';

void main() {
  group('rec_batch_equivalence', () {
    test('padding lines to maxWidth in a batch does not alter decoded text', () {
      final charset = [
        '<blank>',
        '日', '本', '語', '中', '文', 'O', 'C', 'R', '测', '试', '！', '？'
      ];

      // Simulate 3 lines of different widths: 160, 240, 320
      final lines = [
        IntRect(0, 0, 160, 48),
        IntRect(0, 50, 240, 98),
        IntRect(0, 100, 320, 148),
      ];

      final batches = planRecBatch(
        lines: lines,
        height: 48,
        widthBuckets: [384],
        maxBatch: 4,
      );

      expect(batches.length, 1);
      final batch = batches.first;
      expect(batch.maxWidth, 384);
      expect(batch.rows.length, 3);

      final totalSteps = batch.maxWidth ~/ 8; // 48 steps
      final n = batch.rows.length;

      // Deterministic synthetic argmax sequence:
      // Row 0 has real width 160 -> 20 steps of text, 28 steps of padding (0)
      // Row 1 has real width 240 -> 30 steps of text, 18 steps of padding (0)
      // Row 2 has real width 320 -> 40 steps of text, 8 steps of padding (0)
      final argmax = Int32List(n * totalSteps);

      final rng = math.Random(1337);
      final expectedTexts = <String>[];

      for (var b = 0; b < n; b++) {
        final realSteps = batch.rows[b].width ~/ 8;
        final rowOffset = b * totalSteps;

        // Generate synthetic sequence for valid region
        final singleLineArgmax = Int32List(realSteps);
        for (var t = 0; t < realSteps; t++) {
          final cls = rng.nextInt(charset.length);
          singleLineArgmax[t] = cls;
          argmax[rowOffset + t] = cls;
        }
        // Pad remainder with 0 (blank)
        for (var t = realSteps; t < totalSteps; t++) {
          argmax[rowOffset + t] = 0;
        }

        // Compute single-line expected text
        final singleDecoded = ctcGreedyCollapse(
          argmax: singleLineArgmax,
          batch: 1,
          steps: realSteps,
          charset: charset,
        );
        expectedTexts.add(singleDecoded.first);
      }

      // Run batched collapse
      final batchDecoded = ctcGreedyCollapse(
        argmax: argmax,
        batch: n,
        steps: totalSteps,
        charset: charset,
      );

      for (var b = 0; b < n; b++) {
        expect(
          batchDecoded[b],
          expectedTexts[b],
          reason: 'Batch row $b must match single-line reference',
        );
      }
    });

    test('different lines in the same batch do not leak tokens into each other', () {
      final charset = ['<blank>', 'A', 'B', 'C', 'X', 'Y', 'Z'];

      // Row 0 has "A", Row 1 has "Z"
      final argmax = Int32List.fromList([
        1, 1, 0, 0, // Row 0 -> "A"
        0, 6, 6, 0, // Row 1 -> "Z"
      ]);

      final texts = ctcGreedyCollapse(
        argmax: argmax,
        batch: 2,
        steps: 4,
        charset: charset,
      );

      expect(texts[0], 'A');
      expect(texts[1], 'Z');
    });
  });
}
