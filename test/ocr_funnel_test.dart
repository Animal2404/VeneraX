import 'package:flutter_test/flutter_test.dart';
import 'package:venera/foundation/image_translation/translation_types.dart';
import 'package:venera/foundation/image_translation/translation_worker.dart';

/// Locks the Phase 13 F13.5 / F13.6 instrumentation: the per-page discard
/// ledger in `translation_worker.dart`.
///
/// The task this serves is not "translate more" but "know where the text
/// died". Four places in the worker throw OCR candidates away, and before
/// this ledger existed all four produced the same observable outcome — a page
/// with fewer blocks than the user can see speech on — so any change to any
/// threshold was a blind bet. These tests hold two things fixed:
///
///  1. **No behaviour moved.** Every classifier here is a rename of an inline
///     `continue` chain. [legacyIsPlausible] and [legacyDetKeeps] below
///     re-implement the *original* code verbatim and are checked against the
///     extracted functions over a swept input space. If someone widens a gate
///     while "just adding a counter", these fail.
///  2. **The four drops stay distinguishable.** Three pages that each lose
///     twelve clusters — to the detector, to the crop budget, to the
///     plausibility gate — must render three different lines, and each line
///     must name its own layer. That property is the deliverable.
///
/// Pure Dart on purpose: no isolate, no ONNX session, no GPU (R3).
void main() {
  group('ocrPlausibility is the old boolean gate, split in half', () {
    /// The pre-instrumentation implementation, copied from the old
    /// `_WorkerState._isPlausible` (translation_worker.dart:1946-1952).
    bool legacyIsPlausible(String text) {
      if (text.length < 2) return false;
      var meaningful = text.runes
          .where((r) => r > 0x2E80 || (r >= 0x30 && r <= 0x7A))
          .length;
      return meaningful >= [2, text.length ~/ 2].reduce((a, b) => a > b ? a : b);
    }

    /// Corpus built around the shapes the manga OCR pipeline actually meets:
    /// clean CJK, single kana and interjections, punctuation runs, half-width
    /// forms, spaces, and long symbol strings of the kind a hallucinating
    /// decoder emits.
    const corpus = [
      '',
      ' ',
      'a',
      'ab',
      'ッ',
      '！',
      '!?!!',
      'あa',
      'こんにちは',
      '吾妻',
      '日本語です',
      '———',
      '…',
      '……',
      '「」',
      '「あ」',
      '1234',
      '1 2',
      'ZZZ ',
      '············',
      '\u3000\u3000',
      '漢字 and カナ',
      'ー',
      'ーーー',
      '。',
      '。。。。。',
      'OCR2',
      'ＨＫＭ',
      'ｱｲｳ',
    ];

    test('accepts exactly the strings the old gate accepted', () {
      for (final text in corpus) {
        expect(
          ocrPlausibility(text) == OcrReject.none,
          legacyIsPlausible(text),
          reason: 'accept/reject flipped for ${text.runes.toList()}',
        );
      }
    });

    test('a single kana or interjection is killed by the length rule', () {
      // F13.5: these are the casualties the report suspected and the old
      // boolean could not name. Both fail `length < 2`, and that is a
      // *different* fix from the character-ratio line.
      expect(ocrPlausibility('ッ'), OcrReject.short);
      expect(ocrPlausibility('！'), OcrReject.short);
      expect(ocrPlausibility('ー'), OcrReject.short);
    });

    test('a punctuation run long enough to pass the length rule dies on ratio',
        () {
      // U+2014 —, U+2026 …, U+00B7 · and ASCII punctuation all sit below the
      // CJK cut-off (0x2E80) and outside A-Za-z0-9, so they never count as
      // meaningful and a long run of them is rejected here.
      expect(ocrPlausibility('———'), OcrReject.ratio);
      expect(ocrPlausibility('……'), OcrReject.ratio);
      expect(ocrPlausibility('············'), OcrReject.ratio);
      expect(ocrPlausibility('!?!!'), OcrReject.ratio);
      // …while CJK punctuation (U+3002 。, U+300C 「) is ABOVE that cut-off and
      // so *does* count as meaningful: 「。。。」 passes the gate today. Stated
      // as a test because it bounds what `implausible=` can ever mean — the
      // counter does not fire on bracket/symbol soup in Japanese text, and
      // anyone choosing which half of the gate to widen needs that first.
      expect(ocrPlausibility('。。。。。'), OcrReject.none);
      expect(ocrPlausibility('「」'), OcrReject.none);
    });

    test('recognizer silence is its own bucket, not a length failure', () {
      // Blank crops mean the crop produced nothing (det/crop geometry), short
      // crops mean real glyphs were thrown away. One counter would merge two
      // different investigations.
      expect(ocrPlausibility(''), OcrReject.empty);
      // A lone space is not "nothing": it is a one-code-point string that
      // dies on `length < 2`, i.e. in the same class as "ッ".
      expect(ocrPlausibility(' '), OcrReject.short);
    });

    test('real text is accepted by both halves', () {
      expect(ocrPlausibility('こんにちは'), OcrReject.none);
      expect(ocrPlausibility('漢字 and カナ'), OcrReject.none);
      expect(ocrPlausibility('「あ」'), OcrReject.none);
    });
  });

  group('ocrDetReject preserves the original guard chain', () {
    /// The pre-instrumentation chain, copied from the three `continue`s that
    /// used to sit inline in `_detPostprocessBatchSingle`
    /// (translation_worker.dart:2029-2038). Returns true = box kept.
    bool legacyDetKeeps({
      required int pixels,
      required double scoreSum,
      required int boxWidth,
      required int boxHeight,
      required bool centerInsideRegion,
    }) {
      const binaryScoreThreshold = 0.5;
      if (!centerInsideRegion) return false;
      if (pixels < 12 || scoreSum / pixels < binaryScoreThreshold) return false;
      if (boxWidth < 3 || boxHeight < 3) return false;
      return true;
    }

    const pixelSweep = [0, 1, 5, 11, 12, 13, 40, 900];
    const sideSweep = [1, 2, 3, 4, 40];

    test('keep/drop decision is unchanged over the whole guard matrix', () {
      for (final pixels in pixelSweep) {
        for (final side in sideSweep) {
          for (final mean in [0.0, 0.29, 0.3, 0.49, 0.5, 0.51, 0.98]) {
            for (final inside in [true, false]) {
              final scoreSum = mean * pixels;
              expect(
                ocrDetReject(
                      pixels: pixels,
                      scoreSum: scoreSum,
                      boxWidth: side,
                      boxHeight: side,
                      centerInsideRegion: inside,
                    ) ==
                    OcrDetReject.none,
                legacyDetKeeps(
                  pixels: pixels,
                  scoreSum: scoreSum,
                  boxWidth: side,
                  boxHeight: side,
                  centerInsideRegion: inside,
                ),
                reason: 'det keep/drop flipped at pixels=$pixels side=$side '
                    'mean=$mean inside=$inside',
              );
            }
          }
        }
      }
    });

    test('the area gate is counted before the score gate, as it ran', () {
      // A 4-px region at mean 0.9 passes score and fails area; a 4-px region
      // at 0.1 fails *both*, and the original chain never reached the score
      // comparison. So `lowScore` means "passed area, failed score" — the
      // reading that makes the two numbers additive rather than overlapping.
      expect(
        ocrDetReject(
          pixels: 4,
          scoreSum: 0.4,
          boxWidth: 4,
          boxHeight: 4,
          centerInsideRegion: true,
        ),
        OcrDetReject.tiny,
      );
      expect(
        ocrDetReject(
          pixels: 40,
          scoreSum: 4, // mean 0.1
          boxWidth: 40,
          boxHeight: 40,
          centerInsideRegion: true,
        ),
        OcrDetReject.lowScore,
      );
      expect(
        ocrDetReject(
          pixels: 40,
          scoreSum: 20, // mean 0.5 — the threshold is `<`, not `<=`
          boxWidth: 40,
          boxHeight: 40,
          centerInsideRegion: true,
        ),
        OcrDetReject.none,
      );
    });

    test('a collapsed axis is a third, separate reason', () {
      expect(
        ocrDetReject(
          pixels: 40,
          scoreSum: 36,
          boxWidth: 2,
          boxHeight: 40,
          centerInsideRegion: true,
        ),
        OcrDetReject.sliver,
      );
    });

    test('an off-region centre outranks every other rule, as before', () {
      expect(
        ocrDetReject(
          pixels: 900,
          scoreSum: 900,
          boxWidth: 40,
          boxHeight: 40,
          centerInsideRegion: false,
        ),
        OcrDetReject.offRegion,
      );
    });

    test('the area floor is the 12 px the code always used', () {
      expect(DetParams.minAreaPixels, 12);
    });
  });

  group('OcrDetTally keeps the det layer additive', () {
    test('components split into rejects plus emissions, never twice', () {
      final tally = OcrDetTally()
        ..record(OcrDetReject.tiny)
        ..record(OcrDetReject.tiny)
        ..record(OcrDetReject.lowScore)
        ..record(OcrDetReject.sliver)
        ..record(OcrDetReject.offRegion)
        ..record(OcrDetReject.none)
        ..record(OcrDetReject.none)
        ..record(OcrDetReject.none);
      expect(tally.components, 8);
      expect(tally.dropped, 5);
      expect(tally.emitted, 3);
      expect(tally.components, tally.dropped + tally.emitted);
      // No region is counted in two reject buckets, so the parts sum.
      expect(tally.tiny + tally.lowScore + tally.sliver + tally.offRegion, 5);
    });

    test('the tile-stitch discard is added to droppedByDet but kept apart', () {
      // A duplicate of a line the neighbouring tile already produced is not a
      // miss; folding it into `tiny`/`lowScore` would send the next round of
      // tuning after a threshold that is not the problem.
      final tally = OcrDetTally()
        ..record(OcrDetReject.none)
        ..record(OcrDetReject.none)
        ..dupTile = 1;
      expect(tally.dropped, 0);
      expect(tally.droppedAll, 1);
      expect(tally.emitted - tally.dupTile, 1);
    });

    test('reset() clears every counter (the OOM replay path)', () {
      final tally = OcrDetTally()
        ..record(OcrDetReject.tiny)
        ..record(OcrDetReject.none)
        ..dupTile = 3;
      tally.reset();
      expect(tally.components, 0);
      expect(tally.droppedAll, 0);
      expect(tally.emitted, 0);
      expect(tally.dupTile, 0);
    });
  });

  group('the page crop budget (F13.6) is stated, not assumed', () {
    test('the cap is (recBatch * 4) clamped to 32..128', () {
      expect(ocrPageCropLimit(1), 32);
      expect(ocrPageCropLimit(8), 32);
      expect(ocrPageCropLimit(16), 64);
      expect(ocrPageCropLimit(32), 128);
      expect(ocrPageCropLimit(40), 128);
      expect(ocrPageCropLimit(0), 32);
    });

    test('today\'s policy keeps the reading-order prefix', () {
      // 200 clusters, 128 kept — and the kept ones are indices 0..127, i.e.
      // the *top* of the page in reading order. Asserted rather than implied,
      // because the consequence ("the bottom of a dense page vanishes as one
      // block") is only visible if the selection stays this honest.
      final kept = ocrCropSelection(clusterCount: 200, limit: 128);
      expect(kept, List.generate(128, (i) => i));
      expect(kept.length, 128);
      expect(kept.last, 127);
    });

    test('a page under the budget loses nothing to the budget', () {
      expect(ocrCropSelection(clusterCount: 5, limit: 128), [0, 1, 2, 3, 4]);
      expect(ocrCropSelection(clusterCount: 0, limit: 32), isEmpty);
      expect(
        ocrCropSelection(clusterCount: 128, limit: 128).length,
        128,
        reason: 'the cap is inclusive: 128 clusters in a 128 budget all live',
      );
    });

    test('clusters cut == clusterCount - kept', () {
      const total = 200, limit = 128;
      expect(
        total - ocrCropSelection(clusterCount: total, limit: limit).length,
        total - limit,
      );
    });
  });

  group('OcrPageFunnel.line is one greppable, self-checking line', () {
    /// A page as it looks when nothing went wrong.
    OcrPageFunnel healthy() {
      final f = OcrPageFunnel(3)
        ..det.components = 210
        ..det.tiny = 114
        ..det.emitted = 96
        ..det.dupTile = 12
        ..detBoxes = 84
        ..clusters = 40
        ..cropLimit = 128
        ..workItems = 40;
      for (var i = 0; i < 40; i++) {
        f.countOutcome(OcrReject.none);
      }
      return f;
    }

    test('is a single line carrying the agreed key names', () {
      final line = healthy().line();
      expect(line, isNot(contains('\n')), reason: 'one line per page');
      expect(line, startsWith('OcrFunnel page=3'));
      for (final key in [
        'clusters=',
        'droppedByDet=',
        'droppedByCropLimit=',
        'implausible=',
        'tooShort=',
        'blocks=',
      ]) {
        expect(line, contains(key), reason: '$key must stay in the line');
      }
      // Well inside Log.maxLogLength (3000), so it is never truncated away.
      expect(line.length, lessThan(1000));
    });

    test('the ledger closes on itself', () {
      final f = healthy();
      expectClosed(f);
      expect(f.blocks, f.workItems);
      expect(f.droppedFromCrops, 0);
      // 84 boxes reached clustering, 96 were emitted and 12 were the same
      // line seen in two overlapping tiles.
      expect(f.detBoxes, f.det.emitted - f.det.dupTile);
    });

    test('the same loss in three different layers gives three different lines',
        () {
      // This test *is* the deliverable: F13.5's complaint was that these
      // pages were indistinguishable in the log. Each one here "loses" twelve
      // candidate clusters; only the line says which layer did it.
      final byDet = OcrPageFunnel(1)
        ..det.components = 12
        ..det.lowScore = 12
        ..detBoxes = 0
        ..clusters = 0
        ..cropLimit = 128;

      final byCrop = OcrPageFunnel(1)
        ..det.components = 152
        ..det.emitted = 152
        ..detBoxes = 152
        ..clusters = 140
        ..cropLimit = 128
        ..droppedByCropLimit = 12
        ..cutAtPct = 74
        ..workItems = 128;
      for (var i = 0; i < 128; i++) {
        byCrop.countOutcome(OcrReject.none);
      }

      final byRatio = OcrPageFunnel(1)
        ..det.components = 12
        ..det.emitted = 12
        ..detBoxes = 12
        ..clusters = 12
        ..cropLimit = 128
        ..workItems = 12;
      for (var i = 0; i < 12; i++) {
        byRatio.countOutcome(OcrReject.ratio);
      }

      // The two halves of the *same* gate, which is the split the plan asked
      // for: widening `length < 2` and widening the character ratio are
      // different bets, and a page can now show which one is hurting it.
      final byLength = OcrPageFunnel(1)
        ..det.components = 12
        ..det.emitted = 12
        ..detBoxes = 12
        ..clusters = 12
        ..cropLimit = 128
        ..workItems = 12;
      for (var i = 0; i < 12; i++) {
        byLength.countOutcome(OcrReject.short);
      }

      for (final f in [byDet, byCrop, byRatio, byLength]) {
        expectClosed(f);
      }
      expect(byDet.blocks, 0);
      expect(byRatio.blocks, 0);
      expect(byLength.blocks, 0);
      expect(byCrop.blocks, 128, reason: 'the budget cut 12, the rest read fine');

      // …but each names its own killer.
      expect(byDet.line(), contains('droppedByDet=12'));
      expect(byDet.line(), contains('lowScore:12'));
      expect(byCrop.line(), contains('droppedByCropLimit=12'));
      expect(byCrop.line(), isNot(contains('droppedByDet=12')));
      expect(byRatio.line(), contains('implausible=12'));
      expect(byLength.line(), contains('tooShort=12'));
      expect(byRatio.line(), isNot(contains('tooShort=12')));
      expect(byLength.line(), isNot(contains('implausible=12')));

      final lines = [byDet, byCrop, byRatio, byLength]
          .map((f) => f.line())
          .toList();
      for (var i = 0; i < lines.length; i++) {
        for (var j = i + 1; j < lines.length; j++) {
          expect(lines[i], isNot(lines[j]), reason: 'rows $i and $j collide');
        }
      }
    });

    test('cutAtPct is reported only when the budget actually cut', () {
      final cut = OcrPageFunnel(2)
        ..clusters = 200
        ..cropLimit = 128
        ..droppedByCropLimit = 72
        ..cutAtPct = 61
        ..workItems = 128;
      expect(cut.line(), contains('cutAtPct=61'));

      final untouched = OcrPageFunnel(2)
        ..clusters = 20
        ..cropLimit = 128
        ..workItems = 20;
      expect(untouched.line(), isNot(contains('cutAtPct')));
    });

    test('cutAtPct is the page fraction where the loss begins', () {
      // 200 one-line clusters 10 px apart on a 2400 px page; the budget keeps
      // 128, so the first dropped cluster starts at y = 1280 → 53 % of the
      // page. Everything below that line is gone, which is the F13.6 claim
      // written as a number the log can be checked against.
      final boxes = [
        for (var i = 0; i < 200; i++) IntRect(0, i * 10, 100, i * 10 + 8),
      ];
      final clusters = [for (final b in boxes) [b]]
        ..sort((a, b) => _top(a).compareTo(_top(b)));
      final pageHeight = 2400;
      final limit = ocrPageCropLimit(32);
      final funnel = OcrPageFunnel(4)
        ..clusters = clusters.length
        ..cropLimit = limit;
      if (clusters.length > limit) {
        funnel.droppedByCropLimit = clusters.length - limit;
        funnel.cutAtPct = 100 * _top(clusters[limit]) ~/ pageHeight;
        final kept = ocrCropSelection(clusterCount: clusters.length, limit: limit);
        expect(kept.length, limit);
      }
      expect(funnel.droppedByCropLimit, 72);
      // cluster[128] starts at y = 1280 → 53%.
      expect(funnel.cutAtPct, 53);
      expect(funnel.line(), contains('droppedByCropLimit=72'));
    });

    test('a cluster that was never attempted is not blamed on the gate', () {
      final f = OcrPageFunnel(5)
        ..clusters = 3
        ..cropLimit = 128
        ..workItems = 3;
      f.countOutcome(null); // no model for the engine / no crop over 8 px
      f.countOutcome(OcrReject.empty); // sent, decoder came back blank
      f.countOutcome(OcrReject.none);
      expect(f.untried, 1);
      expect(f.empty, 1);
      expect(f.blocks, 1);
      expect(f.tooShort, 0);
      expect(f.implausible, 0);
      expect(f.line(), contains('untried=1'));
      expect(f.line(), contains('empty=1'));
    });

    test('droppedFromCrops accounts for every cluster that made no block', () {
      final f = OcrPageFunnel(6)
        ..clusters = 50
        ..cropLimit = 128
        ..droppedByCropLimit = 10
        ..droppedTinyBounds = 4
        ..workItems = 36;
      for (var i = 0; i < 20; i++) {
        f.countOutcome(OcrReject.none);
      }
      for (var i = 0; i < 6; i++) {
        f.countOutcome(OcrReject.short);
      }
      for (var i = 0; i < 5; i++) {
        f.countOutcome(OcrReject.ratio);
      }
      for (var i = 0; i < 3; i++) {
        f.countOutcome(OcrReject.empty);
      }
      f.countOutcome(null);
      f.countOutcome(null);
      expect(f.blocks, 20);
      expect(
        f.clusters,
        f.droppedFromCrops + f.blocks,
        reason: 'no cluster may vanish without being named',
      );
      expect(f.droppedFromCrops, 30);
    });

    test('a page the detector found nothing on still reports a line', () {
      // The literal user complaint: "there is Japanese here and it was not
      // recognized". `comps` > 0 with `emitted: 0` says the detector looked
      // and rejected; `comps: 0` says it never saw ink at all. Those two are
      // different investigations and this is where the line says which.
      final seenButRejected = OcrPageFunnel(7)
        ..det.components = 30
        ..det.tiny = 28
        ..det.lowScore = 2
        ..cropLimit = 128;
      expect(seenButRejected.droppedByDet, 30);
      expect(seenButRejected.det.emitted, 0);
      expect(seenButRejected.clusters, 0);
      expect(seenButRejected.line(), contains('comps:30'));

      final sawNothing = OcrPageFunnel(7)..cropLimit = 128;
      expect(sawNothing.droppedByDet, 0);
      expect(sawNothing.line(), contains('comps:0'));
      // The budget is still reported, so a zeroed `cropLimit` on an empty page
      // cannot be misread as "the cap crushed this page".
      expect(sawNothing.line(), contains('cropLimit=128'));
    });

    test('toString is the line, so a logged funnel cannot render differently',
        () {
      final f = healthy();
      expect(f.toString(), f.line());
    });
  });
}

int _top(List<IntRect> cluster) {
  var top = cluster.first.top;
  for (final box in cluster) {
    if (box.top < top) top = box.top;
  }
  return top;
}

/// The two identities the ledger exists to keep. Anything that stops holding
/// means a discard point was added (or a counter removed) without the funnel
/// being told — which is precisely the failure mode F13.5 was written about,
/// so it fails a test instead of silently eating a page of text.
void expectClosed(OcrPageFunnel f) {
  expect(
    f.det.components,
    f.det.dropped + f.det.emitted,
    reason: 'det layer does not close: ${f.line()}',
  );
  expect(
    f.clusters,
    f.droppedByCropLimit + f.droppedTinyBounds + f.workItems,
    reason: 'clustering → crops does not close: ${f.line()}',
  );
  expect(
    f.workItems,
    f.blocks + f.tooShort + f.implausible + f.empty + f.untried,
    reason: 'crops → blocks does not close: ${f.line()}',
  );
}
