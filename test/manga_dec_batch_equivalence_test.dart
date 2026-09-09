import 'dart:math' as math;
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:venera/foundation/image_translation/ocr_batching.dart';
import 'package:venera/foundation/image_translation/translation_types.dart';

/// Golden-standard equivalence tests for the manga-ocr (ja) decode
/// scheduling changes (resolveDecBatch / decDecodeOrder / driveDecode).
///
/// ⚠️ 状态：本文件 **未在本地运行过**（受任务约束禁止本地 `flutter test`）。
/// 它照 `ocr_oom_shrink_test.dart` 的口径写：被测对象是纯函数 + 注入的
/// fake forward，不需要 GPU、模型文件或原生运行时。
///
/// What "equivalence" means here, precisely:
/// * The shipped `decoder.onnx` (mayocream/manga-ocr-onnx, SHA pinned in
///   tool/model_export/ASSETS.md) exposes exactly `input_ids` +
///   `encoder_hidden_states` → `logits`. Its self-attention is causal per
///   row and its cross-attention reads only that row's own encoder states,
///   so a row's logits are a pure function of *that row's own prefix*.
/// * Therefore, if batched+reordered execution feeds every row the SAME
///   prefix that serial per-row execution feeds at the same step — which
///   [BatchedVsSerialFeedsIdenticalPrefixes] below asserts step-by-step on
///   the *production* loop ([driveDecode]) — the sampled tokens, and hence
///   the decoded text, are identical. (Any residual difference could only
///   come from batch-size-dependent float reduction order inside the
///   runtime, which predates this change: chunk sizes already vary via the
///   tail chunk and the OOM ladder. Real-device confirmation is the cloud
///   G1 gate: 4 batch tiers × pages, text all-equal.)

String fakeDecode(List<int> tokens) => tokens.join(',');

/// A deterministic fake "model": row `g` replays [script] token by token,
/// then returns EOS forever. Predictions depend on the step index only —
/// equivalently, on that row's own prefix — mirroring the per-row
/// independence of the real graph.
List<int> scriptedForward(List<int> script, int seqLen) {
  final i = seqLen - 1;
  return [i < script.length ? script[i] : MangaOcrTokens.eos];
}

/// Serial per-row reference: one [BatchDecodeState] per row, driven by the
/// production [driveDecode]. Returns (text, prefixes seen per step).
({String text, List<List<int>> seen}) decodeRowSerial(List<int> script) {
  final state = BatchDecodeState(batch: 1);
  final seen = <List<int>>[];
  driveDecode(state: state, forward: (flat, batch, len) {
    seen.add(List<int>.from(flat));
    return scriptedForward(script, len);
  });
  return (text: state.textOf(fakeDecode).single, seen: seen);
}

/// Mirrors the worker's chunked orchestration (`_mangaOcrBatchMulti`) in
/// pure code: permutation from [decDecodeOrder], one [BatchDecodeState] per
/// chunk of `decBatch`, production [driveDecode], slot writes back to the
/// original row order. While driving, it records — per global row and step —
/// the exact prefix slice that was fed, so the test can compare it against
/// the serial reference.
({List<String> texts, int steps, List<List<List<int>>> seenByRow})
    decodeRowsBatched({
  required List<List<int>> scripts,
  required List<IntRect> bounds,
  required int decBatch,
}) {
  final order = decDecodeOrder(bounds);
  final texts = List<String?>.filled(scripts.length, null);
  final seenByRow = [for (var g = 0; g < scripts.length; g++) <List<int>>[]];
  var totalSteps = 0;
  var cursor = 0;
  while (cursor < order.length) {
    final chunkSize = math.min(decBatch, order.length - cursor);
    final chunk = order.sublist(cursor, cursor + chunkSize);
    final B = chunk.length;
    final state = BatchDecodeState(batch: B);
    totalSteps += driveDecode(state: state, forward: (flat, batch, len) {
      final preds = Int32List(batch);
      for (var b = 0; b < batch; b++) {
        if (!state.done[b]) {
          // Slice for row b must be exactly its own history so far —
          // byte-identical to what serial decoding feeds at this step.
          seenByRow[chunk[b]].add(List<int>.from(
            flat.sublist(b * len, (b + 1) * len),
          ));
        }
        final i = len - 1;
        final sc = scripts[chunk[b]];
        preds[b] = i < sc.length ? sc[i] : MangaOcrTokens.eos;
      }
      return preds.toList();
    });
    final chunkTexts = state.textOf(fakeDecode);
    for (var b = 0; b < B; b++) {
      texts[chunk[b]] = chunkTexts[b];
    }
    cursor += chunkSize;
  }
  return (
    texts: [for (final t in texts) t ?? ''],
    steps: totalSteps,
    seenByRow: seenByRow,
  );
}

IntRect box(int areaSide) => IntRect(0, 0, areaSide, areaSide);

void main() {
  group('resolveDecBatch', () {
    test('the memory pin (user recBatch == 1) keeps the decoder serial', () {
      // saver preset / custom default: an explicit 1 is a request for
      // minimum footprint, honoured exactly — desktop GPU profiles do NOT
      // override it.
      expect(resolveDecBatch(userRecBatch: 1, baseProfile: BatchProfile.cuda),
          1);
      expect(
          resolveDecBatch(
              userRecBatch: 1, baseProfile: BatchProfile.directml),
          1);
      expect(resolveDecBatch(userRecBatch: 1, baseProfile: BatchProfile.single),
          1);
    });

    test('unset knob (<= 0) falls back to the EP profile, as before', () {
      expect(
          resolveDecBatch(userRecBatch: 0, baseProfile: BatchProfile.cuda), 32);
      expect(resolveDecBatch(
          userRecBatch: 0, baseProfile: BatchProfile.directml), 16);
      expect(resolveDecBatch(
          userRecBatch: 0, baseProfile: BatchProfile.desktopCpu), 4);
      expect(
          resolveDecBatch(userRecBatch: 0, baseProfile: BatchProfile.single), 1);
      expect(
          resolveDecBatch(userRecBatch: -3, baseProfile: BatchProfile.cuda), 32);
    });

    test('desktop GPU profiles lift the decoder above the rec slider', () {
      // The balanced desktop tier ships recBatch 8. That value was chosen
      // for 48×W crop staging and must not gag the autoregressive pass on a
      // card measured at 2473/6144 MB.
      expect(resolveDecBatch(userRecBatch: 8, baseProfile: BatchProfile.cuda),
          32);
      expect(
          resolveDecBatch(userRecBatch: 8, baseProfile: BatchProfile.directml),
          16);
      // fast tier (rec 16): cuda lifts to 32, directml keeps 16.
      expect(resolveDecBatch(userRecBatch: 16, baseProfile: BatchProfile.cuda),
          32);
      expect(
          resolveDecBatch(
              userRecBatch: 16, baseProfile: BatchProfile.directml),
          16);
    });

    test('never lowers below what the old wiring would have produced', () {
      // Old rule: userRecBatch > 0 ? userRecBatch : base.decBatch.
      // New rule must be >= old for every reachable combination, so no
      // existing configuration loses batching it has today.
      for (final base in [
        BatchProfile.cuda,
        BatchProfile.directml,
        BatchProfile.desktopCpu,
        BatchProfile.single,
      ]) {
        for (var user = -2; user <= 64; user++) {
          final old = user > 0 ? user : base.decBatch;
          final now =
              resolveDecBatch(userRecBatch: user, baseProfile: base);
          expect(now, greaterThanOrEqualTo(old),
              reason: 'base=${base.decBatch} user=$user');
        }
      }
      // And the equality cases are the pinned ones: mobile (single) and
      // desktop CPU at rec>=4 stay exactly where they are.
      expect(resolveDecBatch(userRecBatch: 4, baseProfile: BatchProfile.single),
          4);
      expect(
          resolveDecBatch(
              userRecBatch: 8, baseProfile: BatchProfile.desktopCpu),
          8);
    });

    test('a sticky OOM ceiling still caps the lifted value', () {
      // cappedBy() is applied to the whole profile after resolution in the
      // worker; verify the dec axis of the result really is min()'d.
      final lifted = resolveDecBatch(
          userRecBatch: 8, baseProfile: BatchProfile.cuda); // 32
      final capped = cappedBy(
        BatchProfile(
          detBatch: 2,
          recBatch: 8,
          decBatch: lifted,
          widthQuantum: 64,
          widthBuckets: [160],
        ),
        BatchProfile(
          detBatch: 1,
          recBatch: 4,
          decBatch: 8,
          widthQuantum: 64,
          widthBuckets: [160],
        ),
      );
      expect(capped.decBatch, 8);
      expect(capped.recBatch, 4);
    });
  });

  group('decDecodeOrder', () {
    test('returns a valid permutation, largest area first, ties stable', () {
      final bounds = [
        IntRect(0, 0, 10, 10), // 100
        IntRect(0, 0, 40, 40), // 1600
        IntRect(0, 0, 20, 20), // 400
        IntRect(0, 0, 40, 40), // 1600 (tie with index 1 → 1 first)
        IntRect(0, 0, 1, 5), // 5
      ];
      final order = decDecodeOrder(bounds);
      expect(order.toSet().length, bounds.length);
      expect(order, [1, 3, 2, 0, 4]);
    });

    test('empty and single inputs degenerate cleanly', () {
      expect(decDecodeOrder(const []), isEmpty);
      expect(decDecodeOrder([IntRect(0, 0, 3, 4)]), [0]);
    });

    test('is a deterministic total order (run twice, any insertion order)',
        () {
      final rng = math.Random(7);
      final bounds = [
        for (var i = 0; i < 60; i++)
          IntRect(0, 0, 8 + rng.nextInt(200), 8 + rng.nextInt(60)),
      ];
      expect(decDecodeOrder(bounds), decDecodeOrder(bounds));
    });
  });

  group('driveDecode', () {
    test('counts one forward per appended token and stops at EOS', () {
      final state = BatchDecodeState(batch: 2);
      final scripts = [
        [10, 11], // two tokens, then eos
        [12], // one token, then eos
      ];
      final steps = driveDecode(state: state, forward: (flat, batch, len) {
        return [
          for (var b = 0; b < batch; b++)
            scriptedForward(scripts[b], len).single,
        ];
      });
      // Longest row (2 tokens + eos) sets the chunk cost.
      expect(steps, 3);
      expect(state.allDone, isTrue);
      expect(state.textOf(fakeDecode), ['10,11', '12']);
    });

    test('never-eos never-repeating rows are capped by maxTokens', () {
      final state = BatchDecodeState(batch: 1, maxTokens: 12);
      var calls = 0;
      final steps = driveDecode(state: state, forward: (flat, batch, len) {
        calls++;
        return [len + 100]; // unique ids: no repetition loop triggers
      });
      // The guard is `currentStep < maxTokens` with currentStep starting at
      // 1 (the start token), so 11 forwards happen and the fed prefix tops
      // out at length 12 — byte-identical to the worker's old inline loop.
      expect(steps, 11);
      expect(calls, 11);
      expect(state.currentStep, 12);
      expect(state.textOf(fakeDecode).single.split(',').length, 11);
    });

    test('repetition-loop rows terminate early', () {
      final state = BatchDecodeState(batch: 1);
      final script = [5, 6, 5, 6, 5, 6]; // trigram '5,6,5' … twice-ish
      final steps = driveDecode(state: state, forward: (flat, batch, len) {
        return scriptedForward(script, len);
      });
      expect(state.allDone, isTrue);
      expect(steps, lessThan(MangaOcrTokens.maxTokens));
    });
  });

  group('batched+reordered decode ≡ serial per-row decode', () {
    test('every fed prefix is byte-identical to the serial run\'s', () {
      // Deterministic handcrafted corpus covering: immediate eos, single
      // token, repetition cuts (4-gram and trigram×2), long outlier,
      // pad-while-done steps, and mixed chunk tails.
      final scripts = <List<int>>[
        [], // eos at first step
        [42],
        [7, 7, 7, 7, 9, 9], // 4-gram repetition cut
        [3, 4, 5, 3, 4, 5, 99], // trigram×2 cut; 99 never reached
        [
          for (var i = 0; i < 30; i++) i + 10, // long outlier
        ],
        [11, 12, 13],
        [20],
        [30, 31],
        [40, 41, 42, 43, 44],
      ];
      final bounds = [
        IntRect(0, 0, 10, 10),
        IntRect(0, 0, 12, 10),
        IntRect(0, 0, 30, 20),
        IntRect(0, 0, 31, 20),
        IntRect(0, 0, 300, 120),
        IntRect(0, 0, 40, 40),
        IntRect(0, 0, 9, 9),
        IntRect(0, 0, 50, 12),
        IntRect(0, 0, 25, 25),
      ];
      for (final batch in [1, 2, 3, 4, 8, 16, 64]) {
        final serial = [for (final s in scripts) decodeRowSerial(s)];
        final batched =
            decodeRowsBatched(scripts: scripts, bounds: bounds, decBatch: batch);
        expect(batched.texts, [for (final s in serial) s.text],
            reason: 'decBatch=$batch: text must be verbatim-identical');
        // Prefix isolation: for each row, every step that row was alive
        // in, the batched run fed exactly the serial prefix.
        for (var g = 0; g < scripts.length; g++) {
          final serialSeen = serial[g].seen;
          final batchSeen = batched.seenByRow[g];
          for (var s = 0; s < batchSeen.length; s++) {
            expect(batchSeen[s], serialSeen[s],
                reason: 'row $g step $s at decBatch=$batch diverged');
          }
        }
      }
    });

    test('randomised fuzz: 200 seeds × assorted shapes and batch sizes', () {
      for (var seed = 0; seed < 200; seed++) {
        final rng = math.Random(seed);
        final n = 1 + rng.nextInt(23);
        final scripts = <List<int>>[];
        final bounds = <IntRect>[];
        for (var g = 0; g < n; g++) {
          final kind = rng.nextInt(6);
          final len = rng.nextInt(36);
          final List<int> sc;
          if (kind == 0) {
            sc = [for (var t = 0; t < len; t++) 100 + t]; // long unique
          } else if (kind == 1) {
            sc = [for (var t = 0; t < len; t++) 7]; // 4-gram cut
          } else if (kind == 2) {
            sc = [for (var t = 0; t < len; t++) (t % 3) + 20]; // trigram
          } else {
            sc = [for (var t = 0; t < len; t++) 30 + rng.nextInt(500)];
          }
          scripts.add(sc);
          final w = 8 + rng.nextInt(240);
          final h = 8 + rng.nextInt(120);
          bounds.add(IntRect(0, 0, w, h));
        }
        final decBatch = [1, 2, 3, 5, 8, 16][rng.nextInt(6)];
        final serial = [for (final s in scripts) decodeRowSerial(s)];
        final batched =
            decodeRowsBatched(scripts: scripts, bounds: bounds, decBatch: decBatch);
        expect(batched.texts, [for (final s in serial) s.text],
            reason: 'seed=$seed n=$n decBatch=$decBatch');
        for (var g = 0; g < n; g++) {
          final serialSeen = serial[g].seen;
          final batchSeen = batched.seenByRow[g];
          expect(batchSeen.length, serialSeen.length,
              reason: 'seed=$seed row=$g active-step count diverged');
          for (var s = 0; s < batchSeen.length; s++) {
            expect(batchSeen[s], serialSeen[s],
                reason: 'seed=$seed row $g step $s diverged');
          }
        }
      }
    });

    test('largest-first ordering costs fewer total steps than '
        'arrival order, for length-correlated bounds', () {
      // The win needs *heterogeneous* long rows: with one lone outlier both
      // orders pay its length exactly once. Four outliers of lengths
      // 60/50/40/30 scattered among short rows make arrival order pay
      // 61+51+41+31 across mixed chunks, while descending-area order
      // clusters them into the first chunk.
      final long = <List<int>>[
        [for (var i = 0; i < 60; i++) 1000 + i],
        [for (var i = 0; i < 50; i++) 2000 + i],
        [for (var i = 0; i < 40; i++) 3000 + i],
        [for (var i = 0; i < 30; i++) 4000 + i],
      ];
      final longAt = {3: 0, 9: 1, 15: 2, 22: 3};
      final scripts = <List<int>>[];
      final bounds = <IntRect>[];
      for (var g = 0; g < 32; g++) {
        final li = longAt[g];
        if (li != null) {
          scripts.add(long[li]);
          bounds.add(box(400 - li * 40));
        } else {
          scripts.add([100 + g % 5, 200 + g % 7]); // ~2 tokens
          bounds.add(box(30));
        }
      }
      int stepsWith(List<int> order, int decBatch) {
        // Same loop as decodeRowsBatched but with a fixed permutation, so
        // arrival order can be measured against decDecodeOrder's.
        var total = 0;
        var cursor = 0;
        while (cursor < order.length) {
          final chunk = order.sublist(
              cursor, cursor + math.min(decBatch, order.length - cursor));
          final state = BatchDecodeState(batch: chunk.length);
          total += driveDecode(state: state, forward: (flat, batch, len) {
            return [
              for (var b = 0; b < batch; b++)
                scriptedForward(scripts[chunk[b]], len).single,
            ];
          });
          cursor += chunk.length;
        }
        return total;
      }

      final arrival = List.generate(scripts.length, (i) => i);
      for (final decBatch in [2, 4, 8, 16, 32]) {
        final ordered = decDecodeOrder(bounds);
        expect(stepsWith(ordered, decBatch),
            lessThanOrEqualTo(stepsWith(arrival, decBatch)),
            reason: 'decBatch=$decBatch');
      }
      // And the batched result is still serial-identical either way.
      final serial = [for (final s in scripts) decodeRowSerial(s)];
      final batched =
          decodeRowsBatched(scripts: scripts, bounds: bounds, decBatch: 8);
      expect(batched.texts, [for (final s in serial) s.text]);
    });
  });
}
