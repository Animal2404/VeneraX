import 'package:flutter_test/flutter_test.dart';
import 'package:venera/foundation/image_translation/ocr_batching.dart';

void main() {
  group('manga_ocr_batch_equivalence', () {
    test('frozen rows with padding do not contaminate other rows in batch', () {
      // Mock vocab decoder: maps token id to string
      String mockDecode(List<int> tokens) => tokens.join('');

      // Define 3 test token sequences produced by hypothetical model
      // Row 0: short text -> [10, 11, 3(EOS)]
      // Row 1: longer text -> [20, 21, 22, 23, 3(EOS)]
      // Row 2: repetition loop -> [30, 31, 32, 33, 33, 33, 33] (4 identical 33s)
      final rowPredictions = [
        [10, 11, 3, 99, 99, 99, 99],
        [20, 21, 22, 23, 3, 99, 99],
        [30, 31, 32, 33, 33, 33, 33],
      ];

      // 1. Single-row independent reference decoding
      final referenceResults = <String>[];
      for (var b = 0; b < 3; b++) {
        final tokens = <int>[];
        for (var step = 0; step < rowPredictions[b].length; step++) {
          final next = rowPredictions[b][step];
          if (next == MangaOcrTokens.eos) break;
          tokens.add(next);
          if (BatchDecodeState.hasRepetitionLoop(tokens)) {
            tokens.removeRange(tokens.length - 3, tokens.length);
            break;
          }
        }
        referenceResults.add(mockDecode(tokens));
      }

      // 2. Batched decoding using BatchDecodeState
      final state = BatchDecodeState(
        batch: 3,
        maxTokens: 20,
        startToken: MangaOcrTokens.start,
        eosToken: MangaOcrTokens.eos,
        padToken: MangaOcrTokens.pad,
      );

      final maxSteps = rowPredictions[0].length;
      for (var step = 0; step < maxSteps; step++) {
        if (state.allDone) break;
        final nextPerRow = [for (var b = 0; b < 3; b++) rowPredictions[b][step]];
        state.appendAll(nextPerRow);
      }

      final batchResults = state.textOf(mockDecode);

      // 3. Equivalence assertion
      expect(batchResults.length, referenceResults.length);
      for (var b = 0; b < 3; b++) {
        expect(
          batchResults[b],
          referenceResults[b],
          reason: 'Row $b in batch must be 100% equivalent to single-row decode',
        );
      }
    });

    test('flatPrefix produces correct [batch, L] row-major matrix', () {
      final state = BatchDecodeState(batch: 2);
      // Starts with [2] for each row
      expect(state.currentStep, 1);
      var prefix = state.flatPrefix(1);
      expect(prefix, [2, 2]);

      state.appendAll([10, 20]);
      expect(state.currentStep, 2);
      prefix = state.flatPrefix(2);
      expect(prefix, [2, 10, 2, 20]);
    });
  });
}
