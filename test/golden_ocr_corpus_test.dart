import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

/// Guards the golden OCR corpus (Phase 6 of
/// `VeneraX_AI_Translation_Phase2_Plan.md`, acceptance V6-10).
///
/// The corpus is the only thing that makes every later performance claim
/// falsifiable, so its integrity is checked here rather than trusted: a
/// fixture that is missing, unlicensed, oversized or silently edited would
/// turn `ocr-golden` back into the unfalsifiable storytelling it replaced.
void main() {
  const dirPath = 'test/fixtures/golden_ocr';
  const sizeBudgetBytes = 8 * 1024 * 1024;

  test('golden corpus manifest exists and parses', () {
    final file = File('$dirPath/manifest.json');
    expect(file.existsSync(), isTrue, reason: 'run: python tool/gen_golden_fixtures.py');
    final manifest = jsonDecode(file.readAsStringSync()) as Map<String, dynamic>;
    expect(manifest['pages'], isA<List<dynamic>>());
    final pages = (manifest['pages'] as List).cast<Map<String, dynamic>>();
    expect(pages.length, greaterThanOrEqualTo(5), reason: 'plan §3.7 coverage matrix');
  });

  test('every fixture is present, licensed and inside the size budget', () {
    final manifest = jsonDecode(
          File('$dirPath/manifest.json').readAsStringSync(),
        ) as Map<String, dynamic>,
        pages = (manifest['pages'] as List).cast<Map<String, dynamic>>();

    var total = 0;
    for (final page in pages) {
      final file = File('$dirPath/${page['file']}');
      expect(file.existsSync(), isTrue, reason: '${page['file']} missing');
      // Unlicensed corpus data blocks release; "unknown" is treated as absent.
      expect(page['license'], isNotNull, reason: '${page['file']} has no license');
      expect(
        page['license'].toString().toLowerCase(),
        isNot(contains('unknown')),
        reason: '${page['file']} license must be explicit (plan §3.7)',
      );
      expect(page['source'], isNotNull, reason: '${page['file']} has no provenance');
      // A block lower bound is what makes "OCR found nothing" a failure.
      expect(page['blocks'], isA<num>());
      expect((page['blocks'] as num) > 0, isTrue);
      total += file.lengthSync();
    }
    expect(
      total,
      lessThan(sizeBudgetBytes),
      reason: 'corpus must stay small enough to live in the repo',
    );
  });

  test('fixtures are legible enough to be worth testing against', () {
    // A page that is blank, or whose ink is so sparse that detection could
    // never find a box, would let a broken OCR pipeline pass "no mismatch".
    // PNG bytes are not decoded here (no engine in a plain unit test), so the
    // check is on recorded dimensions and the declared block count.
    final manifest = jsonDecode(
          File('$dirPath/manifest.json').readAsStringSync(),
        ) as Map<String, dynamic>,
        pages = (manifest['pages'] as List).cast<Map<String, dynamic>>();
    for (final page in pages) {
      final size = (page['size'] as List).cast<num>();
      expect(size[0] > 400 && size[1] > 400, isTrue, reason: '${page['file']} too small');
      expect(page['bytes'], isA<num>());
      expect((page['bytes'] as num) > 5000, isTrue, reason: '${page['file']} looks empty');
    }
  });

  test('expected-text files, once recorded, are non-empty', () {
    // They are produced by a reviewed first run, so absence is legal; presence
    // of an empty file is not — it would make every comparison trivially pass.
    final dir = Directory(dirPath);
    for (final entity in dir.listSync()) {
      if (entity is! File || !entity.path.endsWith('.expected.txt')) continue;
      expect(
        entity.readAsStringSync().trim().isNotEmpty,
        isTrue,
        reason: '${entity.path} is empty; delete it or record real text',
      );
    }
  });
}
