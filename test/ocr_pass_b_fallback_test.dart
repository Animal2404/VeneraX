// NOTE: 本文件按任务约束在本地**未运行**（禁止本地 flutter test / 构建 / analyze）。
// 列入待云端 `Test` job 验证清单。
//
// 复核过的缺陷（translation_worker.dart）：Pass B 用 `_ClusterWork.engine`
// 路由，而 `engine` 只在识别**成功**时写入 ⇒ 被 ja 拒的簇 engine 为空串 ⇒
// `== 'ja'` 恒假 ⇒ rec 兜底分支不可达，且这些簇被送回 ja 再解一遍。
// 修复：路由改读新增的尝试记录 `attemptedWith`（决策函数 [planPassBFallback]）。

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:venera/foundation/image_translation/translation_worker.dart';

/// Locks the Pass B route in `translation_worker.dart` to the *attempt* record
/// instead of the *result* field.
///
/// The defect: Pass B picked the fallback engine with
///
/// ```dart
/// if (item.engine == 'ja') passBRec.add(item); else if (hasJa) passBJa.add(item);
/// ```
///
/// while `_ClusterWork.engine` is written **only when an engine produced
/// readable text** — inside the `verdict == OcrReject.none` branch of
/// `executeMultiEngineBatch`. For a cluster the Japanese decoder attempted and
/// rejected, that field is `''`, so the test was false for exactly the
/// population the pass exists for: `passBRec` was unreachable, and every one of
/// those clusters went back to the ja queue for a second decode of
/// byte-identical input. Symptom: "the bubble has text and nothing was
/// translated" — the crop was looked at twice by the engine that could not read
/// it, and never once by the one that could.
///
/// The fix routes on a separate record, `_ClusterWork.attemptedWith` ("which
/// engine actually received this crop"), decided by [planPassBFallback].
///
/// Why the file is shaped the way it is: the routing sits behind two ONNX calls
/// in a worker isolate no test can start (R3), so the decision is a pure
/// function — the same move [tallyClusterLineLoss] makes for the S2 double
/// count — and this file checks it from three directions:
///
///  * ① the rescue happens: a cluster ja rejected reaches the recognition
///    queue, asserted on the *result* of the decision and on a run that shows
///    the cluster becoming a block;
///  * ② nothing else does: accepted text never re-enters Pass B, no engine sees
///    a cluster twice, and no cluster is queued by both routes;
///  * ③ the route is the old one, everywhere the fix does not reach: compared
///    against [legacyRoute], a verbatim re-implementation of the lines this
///    change replaced, over an exhaustive 3072-case sweep.
///
/// The source locks at the end keep the mirror in [Mini] honest: they fail if
/// the worker stops writing the attempt record, starts reading `engine` for a
/// route again, or lets Pass B out of the `sourceLang == 'auto'` gate.
///
/// Pure Dart on purpose: no isolate, no ONNX session, no GPU.
void main() {
  // The engine names a cluster may have been attempted with, including `''` =
  // "no crop ever reached a model".
  const engines = ['', 'ja', 'zh', 'ko'];

  group('① the cluster the ja decoder rejected now reaches recognition', () {
    test('ja-attempted and unusable ⇒ routed to the fallback rec engine', () {
      final c = Case(['ja'], [false], hasJa: true, fallbackRec: 'zh');
      expect(c.destination, ['rec:zh'], reason: c.label);
      expect(c.plan.rec, [0]);
      expect(c.plan.ja, isEmpty, reason: 'and not back to the engine that failed');
      expect(c.plan.jaRejected, [0]);
      expect(c.plan.stayed, 0);
    });

    test('the pre-fix route sent that same cluster back to ja, and rec nowhere',
        () {
      // Both halves of the defect in one place: the wasted decode and the dead
      // branch. This is the assertion that fails against the old lines.
      final old = legacyRoute(
        attemptedWith: ['ja'],
        plausible: [false],
        hasJa: true,
      );
      expect(old.ja, [0], reason: 'the second, pointless ja decode');
      expect(old.rec, isEmpty, reason: 'the dead fallback queue');

      final now = Case(['ja'], [false], hasJa: true, fallbackRec: 'zh');
      expect(now.plan.rec, [0]);
      expect(now.plan.ja, isEmpty);
    });

    test('a rescue that works turns the cluster into a block', () {
      // Not just the queue: the run. ja cannot read this crop, recognition can.
      final run = Mini(
        items: [_Item('ja', jaReads: false, recReads: true)],
        hasJa: true,
        recLangs: const ['zh'],
      )..run();

      expect(run.decodes['ja'], 1, reason: 'asked once, not twice');
      expect(run.decodes['zh'], 1, reason: 'the fallback actually ran');
      expect(run.funnel.blocks, 1);
      expect(run.items[0].attemptedWith, 'zh', reason: 'the record names who ran');
      expect(
        run.items[0].engine,
        'zh',
        reason: 'and the success field names who produced the text',
      );
      expect(
        run.funnel.line(),
        contains('passB={jaRejected=1 recFallback=1 recFallbackSaved=1 '
            'jaFallback=0 jaFallbackSaved=0}'),
      );
    });

    test('…and the same run on the pre-fix route never asks recognition', () {
      final run = Mini(
        items: [_Item('ja', jaReads: false, recReads: true)],
        hasJa: true,
        recLangs: const ['zh'],
        legacy: true,
      )..run();

      expect(run.decodes['ja'], 2, reason: 'the wasted decode');
      expect(run.decodes.containsKey('zh'), isFalse, reason: 'never tried');
      expect(run.funnel.blocks, 0, reason: 'the user-visible "no translation"');
      expect(run.funnel.implausible, 1);
    });

    test('a cluster that was never attempted at all still goes to ja', () {
      // `''` = no model for its engine, or every line under the 8 px floor.
      // Unchanged by this fix: ja is the one engine that has not seen it.
      final c = Case([''], [false], hasJa: true, fallbackRec: 'zh');
      expect(c.destination, ['ja'], reason: c.label);
      expect(c.plan.jaRejected, isEmpty, reason: 'ja never failed on it');
    });

    test('a cluster the recognition engine rejected still goes to ja', () {
      final c = Case(['zh'], [false], hasJa: true, fallbackRec: 'zh');
      expect(c.destination, ['ja'], reason: c.label);
      final run = Mini(
        items: [_Item('zh', jaReads: true)],
        hasJa: true,
        recLangs: const ['zh'],
      )..run();
      expect(run.destinationOf(0), 'ja');
      expect(run.funnel.jaFallback, 1);
      expect(run.funnel.jaFallbackSaved, 1);
      expect(run.funnel.recFallback, 0, reason: 'rec was Pass A, not a fallback');
    });

    test('with no recognition model the ja rejection is not re-decoded by ja',
        () {
      final c = Case(['ja'], [false], hasJa: true, fallbackRec: null);
      expect(c.destination, [null], reason: c.label);
      expect(c.plan.jaRejected, [0], reason: 'the rejection is still counted');
      expect(c.plan.rec, isEmpty);
      expect(c.plan.ja, isEmpty);
      expect(c.plan.stayed, 1);
    });

    test('a rec model spelled ja is not a second engine', () {
      // `executeMultiEngineBatch` dispatches on the name, so it would be the
      // same wasted decode under a different spelling.
      final c = Case(['ja'], [false], hasJa: true, fallbackRec: 'ja');
      expect(c.destination, [null], reason: c.label);
      expect(c.plan.rec, isEmpty);
      expect(c.plan.jaRejected, [0]);
    });

    test('the choice is per cluster, not per page', () {
      final c = Case(
        ['ja', 'zh', 'ja', ''],
        [false, false, false, false],
        hasJa: true,
        fallbackRec: 'ko',
      );
      expect(c.destination, ['rec:ko', 'ja', 'rec:ko', 'ja'], reason: c.label);
      expect(c.plan.rec, [0, 2]);
      expect(c.plan.ja, [1, 3]);
      expect(c.plan.jaRejected, [0, 2]);
    });
  });

  group('② readable text never re-enters Pass B', () {
    test('a ja success is in neither queue', () {
      final c = Case(['ja'], [true], hasJa: true, fallbackRec: 'zh');
      expect(c.plan.ja, isEmpty, reason: c.label);
      expect(c.plan.rec, isEmpty, reason: c.label);
      expect(c.destination, [null]);
      expect(c.plan.jaRejected, isEmpty, reason: 'a success is not a rejection');
      expect(c.plan.stayed, 1);
    });

    test('an accepted cluster is decoded exactly once, by any engine', () {
      for (final engine in engines) {
        for (final hasJa in [false, true]) {
          for (final fallbackRec in <String?>[null, 'zh', 'ja']) {
            final c = Case(
              [engine],
              [true],
              hasJa: hasJa,
              fallbackRec: fallbackRec,
            );
            expect(
              c.plan.isEmpty,
              isTrue,
              reason: 'plausible text must never be recognized again: '
                  '${c.label}',
            );
            expect(c.plan.stayed, 1, reason: c.label);
          }
        }
      }
      final run = Mini(
        items: [_Item('ja', jaReads: true)],
        hasJa: true,
        recLangs: const ['zh'],
      )..run();
      expect(run.decodes['ja'], 1, reason: 'no second decode of a success');
      expect(run.decodes.containsKey('zh'), isFalse);
      expect(run.passBReported, isFalse, reason: 'the line says nothing happened');
    });

    test('no cluster is queued twice, so nothing can be counted twice', () {
      for (final c in sweep(engines)) {
        final all = [...c.plan.ja, ...c.plan.rec];
        expect(all.toSet().length, all.length, reason: c.label);
        expect(
          c.plan.ja.toSet().intersection(c.plan.rec.toSet()),
          isEmpty,
          reason: 'both queues at once is the ping-pong: ${c.label}',
        );
      }
    });

    test('an engine never sees the same cluster twice', () {
      for (final c in sweep(engines)) {
        for (final i in c.plan.rec) {
          expect(c.attemptedWith[i], 'ja', reason: c.label);
        }
        for (final i in c.plan.ja) {
          expect(
            c.attemptedWith[i],
            isNot('ja'),
            reason: 'a cluster ja already failed on must not go back to it: '
                '${c.label}',
          );
        }
      }
    });

    test('a cluster rejected by both engines is tallied once', () {
      // The funnel identity is the point of this one: Pass B ran for it twice
      // and the page still bills the cluster to exactly one bucket.
      final run = Mini(
        items: [_Item('ja', jaReads: false, recReads: false)],
        hasJa: true,
        recLangs: const ['zh'],
      )..run();
      expect(run.decodes['ja'], 1);
      expect(run.decodes['zh'], 1);
      expect(run.funnel.workItems, 1);
      expect(
        run.funnel.blocks +
            run.funnel.tooShort +
            run.funnel.implausible +
            run.funnel.empty +
            run.funnel.untried,
        run.funnel.workItems,
        reason: run.funnel.line(),
      );
      expect(run.funnel.blocks, 0);
      expect(run.funnel.implausible, 1, reason: 'the last attempt owns the verdict');
    });
  });

  group('③ the route is the old route everywhere the fix does not reach', () {
    test('the old rec queue was unreachable for every input', () {
      // Not a nicety: this assertion *is* the defect, stated as a fact about
      // the old code over the whole input space. `engine` could only name `ja`
      // for a cluster that was already plausible, and the queue required one
      // that was not, so the intersection was empty by construction.
      for (final c in sweep(engines)) {
        final old = legacyOf(c);
        expect(old.rec, isEmpty, reason: c.label);
      }
    });

    test('untouched clusters land in the same queue, index for index', () {
      // The identity claim, as a comparison and not as a restatement: wherever
      // nothing was rejected by the Japanese decoder — which covers every page
      // with an explicit source language, because Pass B does not run there at
      // all — the two routes agree element by element and in order.
      var compared = 0;
      var withDelta = 0;
      for (final c in sweep(engines)) {
        final old = legacyOf(c);
        if (c.plan.jaRejected.isEmpty) {
          compared++;
          expect(c.destination, legacyDestination(old, c), reason: c.label);
          expect(c.plan.ja, equals(old.ja), reason: c.label);
          expect(c.plan.rec, equals(old.rec), reason: c.label);
        } else {
          withDelta++;
        }
      }
      // 2058 of the 3072 cases have an empty ja-rejected set, 1014 do not; the
      // thresholds are deliberately low — they say "both halves of the
      // comparison ran", which the exhaustive sweep itself guarantees.
      expect(compared, greaterThan(500), reason: 'the sweep must have run');
      expect(withDelta, greaterThan(500), reason: '…and the fixed class too');
    });

    test('the only difference is the ja-rejected set, and nowhere else', () {
      for (final c in sweep(engines)) {
        final old = legacyOf(c);
        expect(
          c.plan.rec,
          equals(c.canFallBack ? c.plan.jaRejected : const <int>[]),
          reason: 'the new rec queue is exactly the ja rejections: ${c.label}',
        );
        expect(
          c.plan.ja.toSet(),
          equals(old.ja.toSet().difference(c.plan.jaRejected.toSet())),
          reason: 'the ja queue only loses the wasted retries: ${c.label}',
        );
      }
    });

    test('every cluster is accounted for by exactly one route', () {
      for (final c in sweep(engines)) {
        expect(
          c.plan.ja.length + c.plan.rec.length + c.plan.stayed,
          c.total,
          reason: 'a cluster that vanishes without a route is the whole bug: '
              '${c.label}',
        );
      }
    });

    test('a success can never be reported as a rejection', () {
      for (final c in sweep(engines)) {
        for (final i in c.plan.jaRejected) {
          expect(c.attemptedWith[i], 'ja', reason: c.label);
          expect(c.plausible[i], isFalse, reason: c.label);
        }
      }
    });

    test('an explicit source language runs exactly one pass', () {
      // Auto off ⇒ the planner is not consulted and no cluster is decoded
      // twice, whatever the models on disk say. Locked on the run, and again
      // on the source below (the gate is a one-line `if` no test can reach
      // except as text).
      for (final passA in const ['ja', 'zh']) {
        // `''` is skipped on purpose: with no engine receiving the crop there
        // is no pass to count, which is a different claim than this one.
        final autoOff = Mini(
          items: [_Item(passA, jaReads: false)],
          hasJa: true,
          recLangs: const ['zh'],
          auto: false,
        )..run();
        expect(autoOff.passBCalls, 0, reason: 'Pass B must not run at all');
        expect(autoOff.decodes.length, 1, reason: 'exactly one engine ran');
        expect(autoOff.decodes.containsKey('zh'), passA == 'zh' ? isTrue : isFalse,
            reason: 'and it was the one Pass A chose');
        expect(autoOff.passBReported, isFalse, reason: autoOff.funnel.line());
      }
    });
  });

  group('the funnel line reports what the fallback bought', () {
    OcrPageFunnel page() => OcrPageFunnel(2)
      ..clusters = 6
      ..cropLimit = 128
      ..workItems = 6;

    test('a page with no second-engine activity prints no passB group', () {
      final f = page();
      for (var i = 0; i < 6; i++) {
        f.countOutcome(OcrReject.none);
      }
      expect(f.passBPart(), isEmpty);
      expect(f.line(), isNot(contains('passB=')));
    });

    test('the group names every field, key for field', () {
      final f = page()
        ..jaRejected = 4
        ..recFallback = 4
        ..recFallbackSaved = 1
        ..jaFallback = 2
        ..jaFallbackSaved = 2;
      expect(
        f.passBPart(),
        ' passB={jaRejected=4 recFallback=4 recFallbackSaved=1 '
        'jaFallback=2 jaFallbackSaved=2}',
      );
      expect(f.line(), contains(f.passBPart().trim()));
    });

    test('"recognition said no too" and "there was no recognition model" differ',
        () {
      // The ambiguity the fix removed, now readable off one line.
      final rescued = page()
        ..jaRejected = 3
        ..recFallback = 3
        ..recFallbackSaved = 2;
      final stuck = page()..jaRejected = 3;
      expect(rescued.line(), contains('recFallback=3 recFallbackSaved=2'));
      expect(stuck.line(), contains('recFallback=0 recFallbackSaved=0'));
      expect(rescued.line(), isNot(equals(stuck.line())));
    });

    test('the new counters cannot leak into the closing identity', () {
      // `passB={…}` counts *attempts*: a rescued cluster is both a
      // `recFallback` and a `blocks`. The ledger must not notice.
      final f = page()
        ..jaRejected = 4
        ..recFallback = 4
        ..recFallbackSaved = 1
        ..jaFallback = 1
        ..jaFallbackSaved = 1;
      f.countOutcome(OcrReject.none);
      f.countOutcome(OcrReject.none);
      f.countOutcome(OcrReject.short);
      f.countOutcome(OcrReject.ratio);
      f.countOutcome(OcrReject.empty);
      f.countOutcome(null);
      expect(
        f.workItems,
        f.blocks + f.tooShort + f.implausible + f.empty + f.untried,
        reason: 'crops → blocks does not close: ${f.line()}',
      );
      expect(
        f.clusters,
        f.droppedFromCrops + f.blocks,
        reason: 'clustering → blocks does not close: ${f.line()}',
      );
      expect(f.droppedFromCrops, 4);
      expect(f.line(), isNot(contains('\n')), reason: 'one line per page');
      expect(f.line().length, lessThan(1000));
      expect(f.toString(), f.line());
    });
  });

  group('source locks (the worker must keep matching the mirror above)', () {
    test('nothing routes off the success field any more', () {
      final code = _codeOnly(workerSource);
      expect(code, isNot(contains('item.engine')), reason: 'the route read it');
      expect(code, isNot(contains('.engine == ')), reason: 'any engine compare');
    });

    test('the attempt record is written by both engine branches', () {
      final code = _codeOnly(workerSource);
      expect(
        _count(code, "t.attemptedWith = 'ja';"),
        1,
        reason: 'the ja branch sends the whole cluster: always a real attempt',
      );
      expect(
        _count(code, 't.attemptedWith = engine;'),
        1,
        reason: 'the recognition branch names the engine that ran',
      );
      // The recognition write must sit *behind* the crop test. A cluster whose
      // lines were all under the 8 px floor was attempted by nobody, and
      // recording an attempt there would be the same lie the `engine` field
      // told the route.
      final guard = workerSource.indexOf('if (!sentToRec[i]) continue;');
      final write = workerSource.indexOf('t.attemptedWith = engine;');
      expect(guard, greaterThan(-1), reason: 'the crop test must still be there');
      expect(write, greaterThan(guard));
    });

    test('Pass B is still reached only through the auto gate', () {
      final src = workerSource;
      final gate = src.indexOf("if (req.sourceLang == 'auto') {");
      final call = src.indexOf('final plan = planPassBFallback(');
      expect(gate, greaterThan(-1));
      expect(call, greaterThan(gate));
      expect(
        src.substring(gate, call),
        isNot(contains('\n      }')),
        reason: 'nothing may close the gate before the route is planned',
      );
      expect(
        _count(_codeOnly(src), 'final plan = planPassBFallback('),
        1,
        reason: 'one route, decided in one place',
      );
    });

    test('Pass A grouping is untouched by this change', () {
      expect(
        _count(_codeOnly(workerSource), 'final engineGroups = planEngineGroups('),
        1,
        reason: 'and it must stay the only Pass A planner',
      );
    });
  });
}

// ---------------------------------------------------------------------------
// The decision under test, wrapped so the assertions read as sentences.
// ---------------------------------------------------------------------------

/// One [planPassBFallback] call plus the reading of its result that the tests
/// below compare.
class Case {
  Case(
    List<String> attemptedWith,
    List<bool> plausible, {
    required this.hasJa,
    required this.fallbackRec,
  })  : attemptedWith = List.of(attemptedWith),
        plausible = List.of(plausible),
        plan = planPassBFallback(
          attemptedWith: attemptedWith,
          plausible: plausible,
          hasJa: hasJa,
          fallbackRec: fallbackRec,
        );

  final List<String> attemptedWith;
  final List<bool> plausible;
  final bool hasJa;
  final String? fallbackRec;
  final OcrPassBPlan plan;

  int get total => attemptedWith.length;

  /// A fallback of `'ja'` — or none — means there is no second engine to hand
  /// the cluster to.
  bool get canFallBack => fallbackRec != null && fallbackRec != 'ja';

  String get label =>
      'attempts=$attemptedWith plausible=$plausible hasJa=$hasJa '
      'fallbackRec=$fallbackRec';

  /// The routing *result*: where each index ends up. `null` = it stays put.
  List<String?> get destination {
    final out = List<String?>.filled(total, null);
    for (final i in plan.ja) {
      out[i] = 'ja';
    }
    for (final i in plan.rec) {
      out[i] = 'rec:$fallbackRec';
    }
    return out;
  }
}

/// Every combination over three clusters: attempted-with (4) × plausible (2) ×
/// `hasJa` (2) × fallback engine (3) = 3072 cases. Exhaustive on purpose: the
/// route used to be wrong for a class of inputs no spot check was obliged to
/// contain.
Iterable<Case> sweep(List<String> engines) sync* {
  for (var code = 0; code < 64; code++) {
    final attempts = [
      engines[code % 4],
      engines[(code ~/ 4) % 4],
      engines[(code ~/ 16) % 4],
    ];
    for (var flags = 0; flags < 8; flags++) {
      final plausible = [(flags & 1) != 0, (flags & 2) != 0, (flags & 4) != 0];
      for (final hasJa in [false, true]) {
        for (final fallbackRec in <String?>[null, 'zh', 'ja']) {
          yield Case(
            attempts,
            plausible,
            hasJa: hasJa,
            fallbackRec: fallbackRec,
          );
        }
      }
    }
  }
}

/// How the pre-fix code could see a cluster: `_ClusterWork.engine` named an
/// engine **only when that engine had produced readable text**, so "attempted
/// and rejected" and "never attempted" were the same value — which is exactly
/// the information the old route was missing.
String legacyEngineOf({required String attemptedWith, required bool plausible}) {
  if (!plausible) return '';
  return attemptedWith;
}

/// The pre-fix route, copied out of the code this change replaces:
///
/// ```dart
/// for (var item in workItems) {
///   if (!item.isPlausible) {
///     if (item.engine == 'ja') passBRec.add(item);
///     else if (hasJa) passBJa.add(item);
///   }
/// }
/// ```
class LegacyRoute {
  LegacyRoute(this.ja, this.rec);

  final List<int> ja;
  final List<int> rec;
}

LegacyRoute legacyRoute({
  required List<String> attemptedWith,
  required List<bool> plausible,
  required bool hasJa,
}) {
  final toJa = <int>[];
  final toRec = <int>[];
  for (var i = 0; i < attemptedWith.length; i++) {
    if (plausible[i]) continue;
    final engine =
        legacyEngineOf(attemptedWith: attemptedWith[i], plausible: plausible[i]);
    if (engine == 'ja') {
      toRec.add(i);
    } else if (hasJa) {
      toJa.add(i);
    }
  }
  return LegacyRoute(toJa, toRec);
}

LegacyRoute legacyOf(Case c) => legacyRoute(
      attemptedWith: c.attemptedWith,
      plausible: c.plausible,
      hasJa: c.hasJa,
    );

/// [Case.destination] in the old shape, so ③ compares two results rather than
/// two implementations of the same expression.
List<String?> legacyDestination(LegacyRoute old, Case c) {
  final out = List<String?>.filled(c.total, null);
  for (final i in old.ja) {
    out[i] = 'ja';
  }
  for (final i in old.rec) {
    out[i] = 'rec:${c.fallbackRec}';
  }
  return out;
}

// ---------------------------------------------------------------------------
// A run-through of the worker's recognition loop, without the GPU.
// ---------------------------------------------------------------------------

/// One cluster: which engine Pass A gave it, and which engines can read it.
class _Item {
  _Item(this.passAEngine, {required this.jaReads, this.recReads = false});

  /// The engine Pass A grouped this cluster to (`'ja'` or a recognition name).
  final String passAEngine;

  /// Whether the Japanese decoder would bring back usable text. The plausibility
  /// gate itself is [OcrReject]-shaped and untouched here; these two flags are
  /// the test's stand-in for "what the model saw".
  final bool jaReads;
  final bool recReads;

  /// Mirrors of the [_ClusterWork] fields the two passes touch.
  String attemptedWith = '';
  String engine = '';
  String text = '';
  bool isPlausible = false;
  OcrReject? reject;
}

/// The worker's order of operations — Pass A, Pass B, final tally — with the
/// model calls replaced by [jaReads] / [recReads].
///
/// This is a mirror, not the code: `_ClusterWork` is private to the library and
/// `executeMultiEngineBatch` lives inside a worker isolate (R3). The mirror is
/// pinned to the original by the source locks in the last group — if the worker
/// stops writing the attempt record, or routes on something other than
/// [planPassBFallback] inside the auto gate, those tests fail even though this
/// one keeps passing.
class Mini {
  Mini({
    required this.items,
    required this.hasJa,
    required this.recLangs,
    this.auto = true,
    this.legacy = false,
  });

  final List<_Item> items;
  final bool hasJa;
  final List<String> recLangs;

  /// `false` = an explicit source language: Pass B does not run, at all.
  final bool auto;

  /// `true` = route with the pre-fix rule, so the defect can be *run* and not
  /// only described.
  final bool legacy;

  /// Engine name → times asked. The double decode is a number here.
  final Map<String, int> decodes = {};

  /// How many clusters Pass B routed somewhere: the planner's workload.
  int passBCalls = 0;

  final OcrPageFunnel funnel = OcrPageFunnel(0);

  /// Where index [i] ended up, as a string — the run's routing result, read
  /// back out of the queues the run actually filled (not out of the code).
  String? destinationOf(int i) => _placed[i];

  final Map<int, String> _placed = {};

  bool get passBReported => funnel.passBPart().isNotEmpty;

  void run() {
    // Pass A: every cluster goes to the engine it was grouped to.
    for (final t in items) {
      _attempt(t, t.passAEngine);
    }
    if (auto) {
      final fallbackRec = recLangs.isNotEmpty ? recLangs.first : null;
      final attemptedWith = [for (final it in items) it.attemptedWith];
      final plausible = [for (final it in items) it.isPlausible];
      final toJa = <int>[];
      final toRec = <int>[];
      if (legacy) {
        final old = legacyRoute(
          attemptedWith: attemptedWith,
          plausible: plausible,
          hasJa: hasJa,
        );
        toJa.addAll(old.ja);
        toRec.addAll(old.rec);
      } else {
        final plan = planPassBFallback(
          attemptedWith: attemptedWith,
          plausible: plausible,
          hasJa: hasJa,
          fallbackRec: fallbackRec,
        );
        toJa.addAll(plan.ja);
        toRec.addAll(plan.rec);
        for (final i in plan.jaRejected) {
          funnel.jaRejected += 1;
        }
      }
      passBCalls = toJa.length + toRec.length;
      for (final i in toRec) {
        funnel.recFallback += 1;
        _placed[i] = 'rec:$fallbackRec';
      }
      for (final i in toJa) {
        funnel.jaFallback += 1;
        _placed[i] = 'ja';
      }
      // The worker runs the ja queue first, then the recognition queue; the
      // two are disjoint either way, which is what ② asserts.
      for (final i in toJa) {
        _attempt(items[i], 'ja');
      }
      for (final i in toRec) {
        _attempt(items[i], fallbackRec!);
      }
      for (final i in toRec) {
        if (items[i].isPlausible) funnel.recFallbackSaved += 1;
      }
      for (final i in toJa) {
        if (items[i].isPlausible) funnel.jaFallbackSaved += 1;
      }
    }
    funnel.workItems = items.length;
    for (final t in items) {
      // The worker's final loop, verbatim in shape.
      final text = t.text.trim();
      if (text.isEmpty || !t.isPlausible) {
        funnel.countOutcome(t.reject);
        continue;
      }
      funnel.countOutcome(OcrReject.none);
    }
  }

  /// [executeMultiEngineBatch], with the decoder replaced by a boolean.
  void _attempt(_Item t, String engine) {
    if (engine == 'ja' && !hasJa) return;
    if (engine != 'ja' && !recLangs.contains(engine)) return;
    decodes[engine] = (decodes[engine] ?? 0) + 1;
    final usable = engine == 'ja' ? t.jaReads : t.recReads;
    // The order the real branch uses: record the attempt, then the verdict,
    // then — and only then — the success fields.
    t.attemptedWith = engine;
    t.reject = usable ? OcrReject.none : OcrReject.ratio;
    if (usable) {
      t.text = 'ようこそ';
      t.engine = engine;
      t.isPlausible = true;
    }
  }
}

// ---------------------------------------------------------------------------
// Source helpers for the locks in the last group.
// ---------------------------------------------------------------------------

/// The file the whole suite is about. Read lazily, and relative to the package
/// root like every other source-level test here (`native_api_guard_test.dart`).
final String workerSource =
    File('lib/foundation/image_translation/translation_worker.dart')
        .readAsStringSync();

/// [src] with whole-line comments and doc comments removed, so a lock cannot
/// fail because the reason for the fix is spelled out in prose.
String _codeOnly(String src) => src
    .split('\n')
    .where((line) => !line.trimLeft().startsWith('//'))
    .join('\n');

int _count(String haystack, String needle) {
  var n = 0;
  var from = 0;
  while (from <= haystack.length) {
    final at = haystack.indexOf(needle, from);
    if (at < 0) return n;
    n++;
    from = at + needle.length;
  }
  return n;
}
