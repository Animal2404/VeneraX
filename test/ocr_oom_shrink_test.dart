import 'package:flutter_test/flutter_test.dart';
import 'package:venera/foundation/image_translation/ocr_batching.dart';
import 'package:venera/foundation/image_translation/ort_ffi.dart';
import 'package:venera/foundation/image_translation/translation_worker.dart';

/// Pure-function tests for the OOM shrink ladder (plan defect D-5 / §6.2.3).
/// The worker's retry loop wraps a live ONNX session and cannot run in unit
/// tests; the DECISION ("given this profile and this failure, what next?")
/// lives in [profileAfterOom] / [cappedBy] so it can be tested without a GPU
/// or the native runtime. The worker only ever consults these functions.
void main() {
  const buckets = [160, 256, 384, 512, 640, 768, 896, 960];
  BatchProfile p(int det, int rec, int dec) => BatchProfile(
    detBatch: det,
    recBatch: rec,
    decBatch: dec,
    widthQuantum: 64,
    widthBuckets: buckets,
  );

  group('profileAfterOom', () {
    test('OOM at recBatch 32 returns the halved profile', () {
      final next = profileAfterOom(p(4, 32, 32), OrtFfiErrorKind.outOfMemory);
      expect(next, isNotNull);
      expect(next!.recBatch, 16);
      expect(next.detBatch, 2);
      expect(next.decBatch, 16);
      // Shape choices are NOT part of the retreat: halving the buckets would
      // change which crops fit a batch, i.e. silently alter recognition.
      expect(next.widthQuantum, 64);
      expect(next.widthBuckets, buckets);
    });

    test('a non-OOM failure gives up at once — shrinking cannot fix it', () {
      for (final kind in [
        OrtFfiErrorKind.epUnavailable,
        OrtFfiErrorKind.shapeMismatch,
        OrtFfiErrorKind.deviceRemoved,
        OrtFfiErrorKind.invalidGraph,
        OrtFfiErrorKind.other,
      ]) {
        expect(
          profileAfterOom(p(2, 16, 16), kind),
          isNull,
          reason: 'shrink must not paper over ${kind.name}',
        );
      }
    });

    test('OOM with recBatch == 1 gives up (caller rethrows, never swallows)',
        () {
      expect(
        profileAfterOom(p(1, 1, 1), OrtFfiErrorKind.outOfMemory),
        isNull,
        reason: 'one crop is the floor; a page that cannot fit it must fail '
            'loudly, not loop on a clamped halve()',
      );
      // recBatch 2 still has one step left: halve reaches exactly 1.
      expect(
        profileAfterOom(p(2, 2, 2), OrtFfiErrorKind.outOfMemory)?.recBatch,
        1,
      );
    });

    test('the ladder walks 32→16→8→4→2→1→stop and strictly decreases', () {
      var profile = p(4, 32, 32);
      final recTrail = <int>[];
      while (true) {
        final next = profileAfterOom(profile, OrtFfiErrorKind.outOfMemory);
        if (next == null) break;
        expect(next.recBatch, lessThan(profile.recBatch));
        recTrail.add(next.recBatch);
        profile = next;
      }
      expect(recTrail, [16, 8, 4, 2, 1]);
      expect(profile.recBatch, 1);
    });
  });

  group('cappedBy (sticky ceiling across requests)', () {
    test('no ceiling yet: the requested profile passes through untouched', () {
      final wanted = p(4, 32, 32);
      final capped = cappedBy(wanted, null);
      expect(capped.detBatch, 4);
      expect(capped.recBatch, 32);
      expect(capped.decBatch, 32);
    });

    test('a smaller requested value stays below the ceiling', () {
      // The ceiling must cap, not raise: a user who configured recBatch 4 on
      // a machine that previously OOMed at 16 must keep their 4.
      final capped = cappedBy(p(1, 4, 4), p(2, 16, 16));
      expect(capped.recBatch, 4);
      expect(capped.detBatch, 1);
      expect(capped.decBatch, 4);
    });

    test('a larger requested value is pulled back to the ceiling', () {
      final capped = cappedBy(p(4, 32, 32), p(2, 16, 16));
      expect(capped.recBatch, 16);
      expect(capped.detBatch, 2);
      expect(capped.decBatch, 16);
    });

    test('successive shrinks compose to the lowest tier, not the last one',
        () {
      // OOM at 32 → ceiling 16; later OOM while running at 16 → ceiling 8.
      var ceiling = cappedBy(p(2, 16, 16), null);
      ceiling = cappedBy(p(1, 8, 8), ceiling);
      expect(cappedBy(p(4, 32, 32), ceiling).recBatch, 8);
    });
  });

  group('OCR_DEBUG_FORCE_OOM', () {
    test('off by default: the acceptance aid has zero production footprint',
        () {
      // If this ever fails, a build started passing
      // `--dart-define=OCR_DEBUG_FORCE_OOM=true` into production — every rec
      // run in it would fake an OOM once per worker.
      expect(ocrDebugForceOom, isFalse);
    });
  });
}
