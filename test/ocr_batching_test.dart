import 'dart:math' as math;
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:venera/foundation/image_translation/ocr_batching.dart';
import 'package:venera/foundation/image_translation/translation_types.dart';

void main() {
  group('quantizeUp', () {
    test('quantizes to stride multiples', () {
      expect(quantizeUp(0, 32), 0);
      expect(quantizeUp(1, 32), 32);
      expect(quantizeUp(32, 32), 32);
      expect(quantizeUp(33, 32), 64);
      expect(quantizeUp(100, 64), 128);
    });
  });

  group('recTargetWidth', () {
    test('scales width preserving aspect ratio to stride of 8', () {
      // 100 x 50 at target height 48 -> 100 * 48 / 50 = 96
      expect(recTargetWidth(rectW: 100, rectH: 50, height: 48), 96);
      // 10 x 50 at target height 48 -> 10 * 48 / 50 = 9.6 -> round = 10 -> quantize 8 = 16
      expect(recTargetWidth(rectW: 10, rectH: 50, height: 48), 16);
      // Clamped to minW and maxW
      expect(recTargetWidth(rectW: 2, rectH: 100, height: 48, minW: 16), 16);
      expect(recTargetWidth(rectW: 5000, rectH: 50, height: 48, maxW: 960), 960);
    });
  });

  group('planRecBatch', () {
    test('empty lines produces empty batches', () {
      final batches = planRecBatch(
        lines: [],
        height: 48,
        widthBuckets: [160, 256, 384, 512, 640, 768, 896, 960],
        maxBatch: 16,
      );
      expect(batches, isEmpty);
    });

    test('lines bucketed by width and respect maxBatch', () {
      final lines = [
        IntRect(0, 0, 100, 48), // target width 104 -> bucket 160
        IntRect(0, 0, 150, 48), // target width 152 -> bucket 160
        IntRect(0, 0, 200, 48), // target width 200 -> bucket 256
        IntRect(0, 0, 220, 48), // target width 224 -> bucket 256
        IntRect(0, 0, 230, 48), // target width 232 -> bucket 256
      ];

      final batches = planRecBatch(
        lines: lines,
        height: 48,
        widthBuckets: [160, 256, 384, 512, 640, 768, 896, 960],
        maxBatch: 2, // bucket 256 has 3 lines, should split into 2 batches
      );

      expect(batches.length, 3);
      expect(batches[0].maxWidth, 160);
      expect(batches[0].rows.length, 2);

      expect(batches[1].maxWidth, 256);
      expect(batches[1].rows.length, 2);

      expect(batches[2].maxWidth, 256);
      expect(batches[2].rows.length, 1);
    });
  });

  group('planDetBatch', () {
    test('groups tiles and aligns dimensions to stride 32', () {
      final tiles = [
        const DetTile(tileIndex: 0, w: 1000, h: 1200, top: 0),
        const DetTile(tileIndex: 1, w: 1000, h: 1250, top: 1000),
        const DetTile(tileIndex: 2, w: 1000, h: 800, top: 2000),
      ];

      final batches = planDetBatch(tiles: tiles, maxBatch: 2, stride: 32);
      expect(batches.length, 2);

      expect(batches[0].tiles.length, 2);
      expect(batches[0].w, 1024); // 1000 -> 1024
      expect(batches[0].h, 1280); // 1250 -> 1280

      expect(batches[1].tiles.length, 1);
      expect(batches[1].w, 1024);
      expect(batches[1].h, 800); // 800 is already multiple of 32
    });
  });

  group('ctcGreedyCollapse', () {
    test('single line CTC decoding matches batched collapse', () {
      final charset = ['<blank>', 'A', 'B', 'C', 'D', 'E'];
      // Batch = 2, steps = 6
      // Row 0: [0, 1, 1, 0, 2, 2] -> best classes: [blank, A, A, blank, B, B] -> collapsed "AB"
      // Row 1: [3, 0, 4, 4, 5, 0] -> best classes: [C, blank, D, D, E, blank] -> collapsed "CDE"
      final argmax = Int32List.fromList([
        0, 1, 1, 0, 2, 2,
        3, 0, 4, 4, 5, 0,
      ]);

      final texts = ctcGreedyCollapse(
        argmax: argmax,
        batch: 2,
        steps: 6,
        charset: charset,
      );

      expect(texts, ['AB', 'CDE']);
    });

    test('property test: 200 random sequences match single-line reference', () {
      final charset = ['<blank>', 'H', 'e', 'l', 'o', 'W', 'r', 'd', ' ', '!'];
      final rng = math.Random(42);

      for (var iter = 0; iter < 200; iter++) {
        final batch = rng.nextInt(4) + 1;
        final steps = rng.nextInt(30) + 5;
        final argmax = Int32List(batch * steps);
        for (var i = 0; i < argmax.length; i++) {
          argmax[i] = rng.nextInt(charset.length);
        }

        final batchResults = ctcGreedyCollapse(
          argmax: argmax,
          batch: batch,
          steps: steps,
          charset: charset,
        );

        // Reference single-line collapse
        for (var b = 0; b < batch; b++) {
          final sb = StringBuffer();
          var prev = 0;
          for (var t = 0; t < steps; t++) {
            final best = argmax[b * steps + t];
            if (best != 0 && best != prev && best < charset.length) {
              sb.write(charset[best]);
            }
            prev = best;
          }
          expect(batchResults[b], sb.toString().trim());
        }
      }
    });
  });

  group('BatchDecodeState', () {
    test('handles EOS and repetition loops in batch', () {
      final state = BatchDecodeState(
        batch: 3,
        maxTokens: 20,
        startToken: 2,
        eosToken: 3,
        padToken: 0,
      );

      expect(state.allDone, isFalse);

      // Step 1: row 0 gets 10, row 1 gets 20, row 2 gets 3 (EOS)
      state.appendAll([10, 20, 3]);
      expect(state.done[2], isTrue);
      expect(state.done[0], isFalse);
      expect(state.done[1], isFalse);

      // Step 2: row 0 gets 11, row 1 gets 21, row 2 done
      state.appendAll([11, 21, 0]);

      // Step 3: row 0 gets 3 (EOS), row 1 gets 21
      state.appendAll([3, 21, 0]);
      expect(state.done[0], isTrue);

      // Trigger repetition loop in row 1: [20, 21, 21, 21, 21] (4 identical 21s)
      state.appendAll([0, 21, 0]);
      state.appendAll([0, 21, 0]);
      expect(state.done[1], isTrue);
      expect(state.allDone, isTrue);

      final texts = state.textOf((tokens) => tokens.join('-'));
      expect(texts[0], '10-11');
      expect(texts[2], ''); // ended on EOS immediately
    });
  });

  group('planEngineGroups', () {
    test('routes auto vertical to ja and horizontal to zh', () {
      final bounds = [
        IntRect(0, 0, 50, 200), // h=200 > w*1.3 (vertical)
        IntRect(0, 0, 200, 50), // horizontal
      ];

      final groups = planEngineGroups(
        bounds: bounds,
        hasJa: true,
        recLangs: ['zh', 'en', 'ko'],
        sourceLang: 'auto',
      );

      expect(groups.length, 2);
      final jaGroup = groups.firstWhere((g) => g.engine == 'ja');
      final zhGroup = groups.firstWhere((g) => g.engine == 'zh');
      expect(jaGroup.clusterIndices, [0]);
      expect(zhGroup.clusterIndices, [1]);
    });

    test('explicit sourceLang routes all to designated engine', () {
      final bounds = [
        IntRect(0, 0, 50, 200),
        IntRect(0, 0, 200, 50),
      ];

      final groups = planEngineGroups(
        bounds: bounds,
        hasJa: true,
        recLangs: ['zh', 'en', 'ko'],
        sourceLang: 'en',
      );

      expect(groups.length, 1);
      expect(groups.first.engine, 'en');
      expect(groups.first.clusterIndices, [0, 1]);
    });
  });

  group('BatchProfile', () {
    test('halve reduces batches until 1', () {
      var profile = BatchProfile.directml; // det:2, rec:16, dec:16
      expect(profile.detBatch, 2);
      expect(profile.recBatch, 16);

      profile = profile.halve();
      expect(profile.detBatch, 1);
      expect(profile.recBatch, 8);

      profile = profile.halve();
      expect(profile.detBatch, 1);
      expect(profile.recBatch, 4);
    });
  });
}
