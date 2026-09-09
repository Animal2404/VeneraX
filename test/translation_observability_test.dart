import 'package:flutter_test/flutter_test.dart';
import 'package:venera/foundation/image_translation/translation_service.dart';
import 'package:venera/foundation/image_translation/translation_types.dart';
import 'package:venera/foundation/image_translation/translation_worker.dart';

/// Locks the F13.7 observability added for two user complaints that the
/// existing `OcrFunnel` line cannot name:
///
///  1. "two bubbles' translations were fused into one" — the clustering gate
///     can put two bubbles' lines in one cluster. [OcrClusterGeometry] measures
///     the cluster's band structure and the widest separation relative to the
///     widest separation a *direct* link can bridge. These tests pin both
///     directions of that measurement and, in the last group, pin the reason it
///     is a measurement and not a guard.
///  2. "one line of Japanese was not translated" — `OcrText` names every block
///     the worker kept, and `BlockFunnel` names the two silent downstream drops.
///
/// Nothing here changes recognition, clustering or translation behaviour: the
/// audit is pure arithmetic over boxes that were already computed.
void main() {
  group('OcrClusterGeometry measures bands, not a verdict', () {
    test('a tight single bubble: uniform gaps, no separation a link could not '
        'bridge', () {
      final geometry = ocrClusterGeometry([
        IntRect(20, 20, 100, 34),
        IntRect(24, 40, 104, 54),
        IntRect(22, 60, 102, 74),
      ]);
      expect(geometry.direction, 1, reason: 'horizontal lines');
      expect(geometry.members, 3);
      expect(geometry.medianThickness, 14);
      expect(geometry.stackGaps, [6, 6]);
      expect(geometry.runGaps, isEmpty);
      expect(geometry.span, 54);
      // 0.55 * 14 = 8 per side, so a direct link bridges at most 16 px.
      expect(geometry.maxLinkRatio, closeTo(6 / 16, 1e-9));
      expect(geometry.chained, isFalse);
    });

    test('one bubble with wide narration spacing is still one bubble', () {
      // Pitch 2.0 * thickness: the widest a same-bubble block can be and still
      // be merged by the gate (its gap equals the 1.1 * thickness ceiling).
      // This is the "do not split a sentence in half" direction.
      final boxes = [
        IntRect(20, 20, 140, 34),
        IntRect(24, 48, 144, 62),
        IntRect(22, 76, 142, 90),
      ];
      expect(clusterOcrBoxes(boxes, 200, 200), hasLength(1));
      final geometry = ocrClusterGeometry(boxes);
      expect(geometry.stackGaps, [14, 14]);
      expect(geometry.maxLinkRatio, closeTo(14 / 16, 1e-9));
      expect(geometry.chained, isFalse,
          reason: 'the audit must not call a legitimate narration block chained');
    });

    test('a gap exactly at the link ceiling is not chained (strict >)', () {
      final geometry = ocrClusterGeometry([
        IntRect(20, 20, 120, 34),
        IntRect(24, 50, 124, 64),
      ]);
      expect(geometry.stackGaps, [16]);
      expect(geometry.maxLinkRatio, closeTo(1.0, 1e-9));
      expect(geometry.chained, isFalse);
    });

    test('vertical columns measure their own axis', () {
      final geometry = ocrClusterGeometry([
        // Two columns side by side (the stacking axis is x)…
        IntRect(20, 20, 34, 120),
        IntRect(44, 24, 58, 124),
        // …and one column the detector split into two pieces (the run axis
        // is y), which is the vertical analogue of a split line.
        IntRect(44, 130, 58, 180),
        IntRect(44, 190, 58, 240),
      ]);
      expect(geometry.direction, -1);
      expect(geometry.members, 4);
      expect(geometry.stackGaps, [10]);
      expect(geometry.runGaps, [6, 10]);
      expect(geometry.chained, isFalse);
    });

    test('a mixed-direction cluster is reported, never measured as bands', () {
      final geometry = ocrClusterGeometry([
        IntRect(20, 20, 100, 34),
        IntRect(72, 16, 86, 70),
      ]);
      expect(geometry.direction, 0);
      expect(geometry.members, 2);
      expect(geometry.stackGaps, isEmpty);
      expect(geometry.runGaps, isEmpty);
      expect(geometry.maxLinkRatio, 0);
    });

    test('a chained span is exactly what the ratio above 1.0 names', () {
      // A wide box that reaches past a small band to the one beyond it: the two
      // small bands are consecutive after sorting and are NOT linked to each
      // other, so their separation exceeds what a direct link could bridge.
      // This pins the metric's semantics; the group below pins what real
      // clusters look like.
      final geometry = ocrClusterGeometry([
        IntRect(20, 0, 100, 10),
        IntRect(20, 30, 100, 40),
        IntRect(20, 36, 100, 76),
      ]);
      expect(geometry.members, 3);
      expect(geometry.stackGaps, [20, 0]);
      expect(geometry.maxLinkRatio, greaterThan(1.0));
      expect(geometry.chained, isTrue);
    });

    test('a single member has nothing to measure and no trace', () {
      final geometry = ocrClusterGeometry([IntRect(20, 20, 100, 34)]);
      expect(geometry.members, 1);
      expect(geometry.stackGaps, isEmpty);
      expect(ocrClusterTrace(0, 3, [IntRect(20, 20, 100, 34)]), isNull);
    });
  });

  group('two adjacent bubbles vs one bubble: both directions', () {
    test('① two stacked bubbles ARE fused today, and the fusion is a direct '
        'link — the audit says so', () {
      // Bubble A (two lines) over bubble B (two lines), 8 px apart: the facing
      // pair is inside the link ceiling, which is why they fuse.
      final boxes = [
        IntRect(20, 20, 120, 34),
        IntRect(24, 40, 124, 54),
        IntRect(20, 62, 120, 76),
        IntRect(24, 82, 124, 96),
      ];
      final groups = clusterOcrBoxes(boxes, 200, 200);
      expect(groups, hasLength(1), reason: 'the reported defect, reproduced');
      final geometry = ocrClusterGeometry(groups.single);
      expect(geometry.stackGaps, [6, 8, 6]);
      // 8 / (8 + 8) = 0.5: the inter-bubble separation is *smaller* than a
      // legitimate narration gap (0.875 in the test above). Any geometric guard
      // that rejects this one also rejects that one.
      expect(geometry.maxLinkRatio, closeTo(0.5, 1e-9));
      expect(geometry.chained, isFalse,
          reason: 'the fusion is one direct link, not transitive chaining');
    });

    test('② the same bubble with the widest mergeable spacing stays merged', () {
      final boxes = [
        IntRect(20, 20, 140, 34),
        IntRect(24, 48, 144, 62),
        IntRect(22, 76, 142, 90),
      ];
      expect(clusterOcrBoxes(boxes, 200, 200), hasLength(1));
      expect(ocrClusterGeometry(boxes).chained, isFalse);
    });

    test('② vertical text inside one bubble stays merged', () {
      final boxes = [
        IntRect(20, 20, 34, 120),
        IntRect(44, 24, 58, 124),
        IntRect(68, 22, 82, 122),
      ];
      expect(clusterOcrBoxes(boxes, 200, 200), hasLength(1));
      final geometry = ocrClusterGeometry(boxes);
      expect(geometry.direction, -1);
      expect(geometry.chained, isFalse);
    });

    test('geometry alone cannot separate a split line from two touching '
        'bubbles (known limitation, pinned)', () {
      // One physical line the detector cut in two, and two adjacent single-line
      // bubbles: the clustering pass receives the SAME two rectangles for both.
      // No function of the boxes can be right on both, which is why F13.7 ships
      // the measurement above and no guard. Only the page's ink (the bubble
      // outline inside the gap) separates them, and that is not an input of
      // `clusterOcrBoxes`.
      final splitLine = [IntRect(20, 20, 60, 34), IntRect(68, 20, 108, 34)];
      final touchingBubbles = [IntRect(20, 20, 60, 34), IntRect(68, 20, 108, 34)];
      expect(clusterOcrBoxes(splitLine, 200, 200), hasLength(1));
      expect(clusterOcrBoxes(touchingBubbles, 200, 200), hasLength(1));
      expect(
        ocrClusterGeometry(splitLine).maxLinkRatio,
        ocrClusterGeometry(touchingBubbles).maxLinkRatio,
      );
    });
  });

  group('ocrTextDigest names every kept block', () {
    OcrBlock block(String text, String language) => OcrBlock(
      rect: IntRect(20, 20, 100, 34),
      text: text,
      language: language,
      backgroundColor: 0,
      textColor: 0,
    );

    test('one line, language and bounded preview per block', () {
      final line = ocrTextDigest(3, [
        block('ああ', 'ja'),
        block('そうか', 'ja'),
      ]);
      expect(line, isNot(contains('\n')));
      expect(line, startsWith('OcrText page=3 n=2'));
      expect(line, contains('0:ja:"ああ"'));
      expect(line, contains('1:ja:"そうか"'));
    });

    test('quotes and control characters cannot break the line shape', () {
      final line = ocrTextDigest(0, [block('a\nb"c', 'ja')]);
      expect(line, isNot(contains('\n')));
      expect(line, contains('"a b\'c"'));
    });

    test('long text is cut, and a long page is capped', () {
      final long = ocrTextDigest(0, [
        block(List.filled(40, 'あ').join(), 'ja'),
      ]);
      expect(long, contains('…'));
      final many = ocrTextDigest(0, [
        for (var i = 0; i < 400; i++)
          block(List.filled(20, '漢').join(), 'ja'),
      ]);
      expect(many, contains('more'));
      expect(many!.length, lessThan(1600));
    });

    test('an empty page has no digest to print', () {
      expect(ocrTextDigest(0, const []), isNull);
    });
  });

  group('BlockFunnel closes the block ledger', () {
    test('skippedAsTarget is recovered from the votes', () {
      // 16 blocks passed _isTranslatable, 13 went pending, 1 was already in the
      // target language (dropped by translation_pipeline.dart:165-173), 1 the
      // model echoed back and 1 it answered (translation_pipeline.dart:213-214).
      final line = blockFunnelLine(
        page: '0',
        votes: 16,
        pending: 13,
        ready: 1,
        llmIn: 13,
        llmOut: 12,
        regions: 13,
        modelDropped: 1,
      );
      expect(line, contains('votes=16'));
      expect(line, contains('skippedAsTarget=2'));
      expect(line, contains('llm_in=13'));
      expect(line, contains('llm_out=12'));
      expect(line, contains('modelDropped=1'));
    });

    test('a field this path cannot measure prints ?, never 0', () {
      final line = blockFunnelLine(
        page: 'k',
        votes: 4,
        pending: null,
        ready: null,
        llmIn: null,
        llmOut: null,
        regions: 3,
        modelDropped: null,
      );
      expect(line, contains('pending=?'));
      expect(line, contains('skippedAsTarget=?'));
      expect(line, contains('modelDropped=?'));
      expect(line, contains('regions=3'));
    });
  });

  group('GroupPerf carries the request shape', () {
    GroupPerf group({
      int llmRequests = 0,
      int llmBlocks = 0,
      int startMs = 0,
      int endMs = 0,
    }) => GroupPerf(
      pages: 4,
      ocrCachedPages: 0,
      ocrRunPages: 4,
      llmPages: 4,
      renderPages: 4,
      resolveMs: 1,
      ocrMs: 2,
      llmMs: 3,
      renderMs: 4,
      totalMs: 10,
      bytesIn: 1024,
      bytesOut: 2048,
      llmRequests: llmRequests,
      llmBlocks: llmBlocks,
      llmWindowStartMs: startMs,
      llmWindowEndMs: endMs,
    );

    test('the new fields are appended, so existing greps keep working', () {
      final line = group(
        llmRequests: 1,
        llmBlocks: 63,
        startMs: 1700000000000,
        endMs: 1700000097539,
      ).toLogLine();
      expect(line, startsWith('GroupPerf pages=4 '));
      expect(line, contains('llm_pages=4'));
      expect(line, contains('llm_reqs=1'));
      expect(line, contains('llm_blocks=63'));
      expect(line, contains('llm_window=1700000000000..1700000097539'));
      expect(line, contains('llm_reqs_total='));
    });

    test('a group that made no request reports zero, not a fake measurement',
        () {
      final line = group().toLogLine();
      expect(line, contains('llm_reqs=0'));
      expect(line, contains('llm_blocks=0'));
      expect(line, contains('llm_window=0..0'));
    });
  });
}
