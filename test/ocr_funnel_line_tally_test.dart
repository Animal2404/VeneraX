import 'package:flutter_test/flutter_test.dart';
import 'package:venera/foundation/image_translation/translation_worker.dart';

/// S2 — `OcrPageFunnel.recLinesDropped` was counted twice per cluster.
///
/// The reported defect: `executeMultiEngineBatch` (translation_worker.dart)
/// applies the 8 px recognition floor per line and tallies the shortfall into
/// `funnels[pageIndex].recLinesDropped`. Pass A runs it once per engine group
/// and Pass B (auto source language) runs it again for every cluster whose text
/// came back implausible — a cluster rejected by Pass A therefore reached the
/// tally twice, and the same sub-8-px lines were added to the page's loss
/// twice. The funnel's contract says the opposite: "Each is counted once, per
/// page", and a doubled figure reads as twice the real loss.
///
/// The fix is a `linesTallied` flag on `_ClusterWork` (the work item both
/// passes share), decided by [tallyClusterLineLoss]. The function is top-level
/// and pure because the branch it replaces sits two GPU calls deep in a worker
/// isolate that no test can start (R3 — no isolate, no ONNX session, no GPU).
///
/// Every assertion below fails under the pre-fix code: that code had no flag,
/// so its equivalent of `tally` returned `lostLines` on *every* pass.
///
/// NOT VERIFIED LOCALLY (no `flutter test` in this workspace) — see the
/// "待云端 Test job 验证" list in the hand-off report.
void main() {
  group('tallyClusterLineLoss: once per cluster, across both passes', () {
    test('a cluster with no short line is never tallied', () {
      final r = tallyClusterLineLoss(alreadyTallied: false, lostLines: 0);
      expect(r.count, 0);
      expect(r.tallied, isFalse);
    });

    test('the first pass that loses lines tallies exactly once', () {
      final r = tallyClusterLineLoss(alreadyTallied: false, lostLines: 3);
      expect(r.count, 3);
      expect(r.tallied, isTrue);
    });

    test('Pass B re-entering the same branch tallies nothing', () {
      // Pass A: three lines under 8 px inside a cluster that still produced a
      // crop.
      final passA = tallyClusterLineLoss(alreadyTallied: false, lostLines: 3);
      expect(passA.count, 3);

      // Pass B retries the same cluster with the fallback engine and measures
      // the same three lines again. The old code added 3 more here.
      final passB = tallyClusterLineLoss(
        alreadyTallied: passA.tallied,
        lostLines: 3,
      );
      expect(passB.count, 0, reason: 'counted once, per page');
      expect(passB.tallied, isTrue, reason: 'the flag stays set');
      expect(passA.count + passB.count, 3);
    });

    test('a third attempt still cannot re-tally', () {
      var tally = false;
      var total = 0;
      for (var pass = 0; pass < 3; pass++) {
        final r = tallyClusterLineLoss(alreadyTallied: tally, lostLines: 2);
        tally = r.tallied;
        total += r.count;
      }
      expect(total, 2, reason: 'three passes over one cluster, one tally');
    });

    test('two different clusters each tally their own loss once', () {
      // The flag is per work item, not per page: two clusters on the same page
      // that each lose lines must both be counted.
      final a = tallyClusterLineLoss(alreadyTallied: false, lostLines: 1);
      final b = tallyClusterLineLoss(alreadyTallied: false, lostLines: 4);
      expect(a.count + b.count, 5);
    });

    test('a later pass that loses nothing leaves the flag alone', () {
      final r = tallyClusterLineLoss(alreadyTallied: true, lostLines: 0);
      expect(r.count, 0);
      expect(r.tallied, isTrue);
    });

    test('the funnel line reports the once-only number', () {
      // The consumer end of the same contract: what the tally writes is what
      // `OcrFunnel` prints, and the ledger still closes on itself.
      final funnel = OcrPageFunnel(2)
        ..det.components = 5
        ..det.emitted = 5
        ..detBoxes = 5
        ..clusters = 2
        ..cropLimit = 128
        ..workItems = 2;
      final passA = tallyClusterLineLoss(alreadyTallied: false, lostLines: 3);
      funnel.recLinesDropped += passA.count;
      final passB = tallyClusterLineLoss(
        alreadyTallied: passA.tallied,
        lostLines: 3,
      );
      funnel.recLinesDropped += passB.count;
      funnel.countOutcome(OcrReject.none);
      funnel.countOutcome(OcrReject.none);

      expect(funnel.recLinesDropped, 3);
      expect(funnel.line(), contains('recLinesDropped=3'));
      expect(funnel.workItems, funnel.blocks);
    });
  });
}
