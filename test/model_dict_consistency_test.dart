import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:venera/foundation/image_translation/local_model_import.dart';
import 'package:venera/foundation/image_translation/translation_models.dart';
import 'package:venera/foundation/image_translation/translation_types.dart';
import 'package:venera/foundation/image_translation/translation_worker.dart';

void main() {
  group('Dict and Charset Consistency (V3-6)', () {
    late Directory tempDir;
    late File dictFile;

    setUp(() {
      tempDir = Directory.systemTemp.createTempSync('ocr_dict_test_');
      dictFile = File('${tempDir.path}/test_dict.txt');
      // Create a mock dictionary with 5 lines
      dictFile.writeAsStringSync('a\nb\nc\nd\ne\n');
    });

    tearDown(() {
      if (tempDir.existsSync()) {
        tempDir.deleteSync(recursive: true);
      }
    });

    test('loadCharset produces correct blank and space tokens', () {
      final charset = loadCharset(dictFile.path);
      // 5 lines in dict + blank at index 0 + space at last index = 7 tokens
      expect(charset.length, 7);
      expect(charset.first, '');
      expect(charset.last, ' ');
      expect(charset.sublist(1, 6), ['a', 'b', 'c', 'd', 'e']);
    });

    test('loadCharset succeeds when expectedClasses matches charset.length', () {
      final charset = loadCharset(dictFile.path, expectedClasses: 7);
      expect(charset.length, 7);
    });

    test('loadCharset throws DictMismatchException when expectedClasses does not match', () {
      expect(
        () => loadCharset(dictFile.path, expectedClasses: 10),
        throwsA(isA<DictMismatchException>()),
      );

      try {
        loadCharset(dictFile.path, expectedClasses: 10);
        fail('Should have thrown DictMismatchException');
      } on DictMismatchException catch (e) {
        expect(e.message, contains('Expected 8 dict lines but got 5'));
      }
    });

    test('loadCharset throws DictMismatchException when file is missing', () {
      expect(
        () => loadCharset('${tempDir.path}/non_existent.txt'),
        throwsA(isA<DictMismatchException>()),
      );
    });
  });

  group('Direction-Aware Line Inflation (RecParams)', () {
    test('horizontal text expands symmetrically by padPx', () {
      // 100 wide x 30 high: left=50, top=50, right=150, bottom=80 (h / w = 0.3 <= 1.3)
      final line = IntRect(50, 50, 150, 80);
      final inflated = RecParams.inflateLine(line, 500, 500);

      expect(inflated.left, 50 - RecParams.padPx);
      expect(inflated.right, 150 + RecParams.padPx);
      expect(inflated.top, 50 - RecParams.padPx);
      expect(inflated.bottom, 80 + RecParams.padPx);
    });

    test('vertical text expands vertically by padPx * 3', () {
      // 20 wide x 60 high: left=50, top=50, right=70, bottom=110 (h / w = 3.0 > 1.3)
      final line = IntRect(50, 50, 70, 110);
      final inflated = RecParams.inflateLine(line, 500, 500);

      expect(inflated.left, 50 - RecParams.padPx);
      expect(inflated.right, 70 + RecParams.padPx);
      expect(inflated.top, 50 - RecParams.padPx * 3);
      expect(inflated.bottom, 110 + RecParams.padPx * 3);
    });
  });

  group('Model Tier and CPU Guard (F3)', () {
    test('workerPaths with gpuEpActive: false never includes requiresGpuEp models', () {
      final paths = TranslationModels.workerPaths(
        tier: ModelTier.high,
        gpuEpActive: false,
      );

      // Even when tier is high, FP16 variants requiring GPU must not be selected on CPU
      if (paths.jaEncoder != null) {
        expect(paths.jaEncoder, isNot(contains('fp16')));
      }
      for (var model in paths.recModels.values) {
        expect(model, isNot(contains('fp16')));
      }
    });

    test('ModelComponent properties are correctly initialized', () {
      expect(TranslationModels.detector.tier, ModelTier.fast);
      expect(TranslationModels.detectorHigh.tier, ModelTier.high);
      expect(TranslationModels.detectorManga.enabled, isFalse);

      expect(TranslationModels.ocrZhFp16.requiresGpuEp, isTrue);
      expect(TranslationModels.ocrZhHighFp16.requiresGpuEp, isTrue);
      expect(TranslationModels.ocrJaFp16.requiresGpuEp, isTrue);

      expect(TranslationModels.ocrZhHigh.dictFrom, 'ocr_zh');
      expect(TranslationModels.ocrZhHighFp16.dictFrom, 'ocr_zh');
    });

    test('ModelKind groups components appropriately', () {
      final detectors = TranslationModels.all
          .where((c) => c.kind == ModelKind.detector)
          .map((c) => c.id)
          .toList();
      expect(detectors, containsAll(['text_detector', 'text_detector_high', 'text_detector_manga']));

      final manga = TranslationModels.all
          .where((c) => c.kind == ModelKind.mangaEncoder)
          .map((c) => c.id)
          .toList();
      expect(manga, containsAll(['ocr_ja', 'ocr_ja_fp16']));
    });
  });

  // =========================================================================
  // Defect 2. A component that is registered but whose assets were never
  // published is a dead end in the management list: nothing to download (its
  // only URL is a `{release}` tag that does not exist), nothing to verify (no
  // checksum), nothing to click. It is therefore not listed at all — and the
  // rule lives in the registry, where it can be tested, not in the page.
  //
  // DECISION GATE G5 — what it takes to un-hide one of these rows:
  //   ① the asset is actually published under the fork's `models` release
  //      (`tool/model_export/publish.py` has run; `ASSETS.md` records it), AND
  //   ② every file it declares carries an `expectedSha256`.
  // Only then does `enabled: true` go on the component. Flipping that flag is
  // the *whole* of the un-hide: `isUnpublishedAsset` keys off it, so no page
  // edit is waiting to be remembered. Do not "fix" the missing row by
  // rendering the disabled components again.
  // =========================================================================
  group('unpublished assets are not listed (defect 2 / gate G5)', () {
    const unpublishedIds = [
      'ocr_ja_fp16',
      'ocr_zh_fp16',
      'ocr_zh_high_fp16',
    ];

    test('exactly the three {release}-only components are hidden', () {
      expect(
        TranslationModels.all
            .where(TranslationModels.isUnpublishedAsset)
            .map((c) => c.id)
            .toList(),
        unorderedEquals(unpublishedIds),
      );
    });

    test('no section lists a disabled component that declares files', () {
      for (final section in ModelSection.values) {
        for (final c in TranslationModels.listedComponents(section)) {
          expect(
            TranslationModels.isUnpublishedAsset(c),
            isFalse,
            reason: '${c.id} must not reappear in ${section.name}',
          );
        }
      }
      final listed = [
        for (final s in ModelSection.values)
          ...TranslationModels.listedComponents(s),
      ].map((c) => c.id).toList();
      for (final id in unpublishedIds) {
        expect(listed, isNot(contains(id)), reason: '$id must stay hidden');
      }
    });

    test('every published component is listed exactly once', () {
      final listed = [
        for (final s in ModelSection.values)
          ...TranslationModels.listedComponents(s),
      ].map((c) => c.id).toList();
      final published = TranslationModels.all
          .where((c) => c.enabled)
          .map((c) => c.id)
          .toList();
      // Hiding the dead rows must not have swallowed a real one, and the
      // three sections must not overlap.
      expect(listed.toSet(), published.toSet());
      expect(listed.length, listed.toSet().length);
    });

    test('a file-less placeholder keeps its "Coming soon" row', () {
      // text_detector_manga is reserved, not unpublished: different case,
      // different answer.
      expect(
        TranslationModels.isUnpublishedAsset(TranslationModels.detectorManga),
        isFalse,
      );
      expect(TranslationModels.detectorManga.files, isEmpty);
      expect(
        TranslationModels.listedComponents(ModelSection.detection)
            .map((c) => c.id),
        contains('text_detector_manga'),
      );
    });

    test('hiding is presentation only: enabled still gates the pipeline', () {
      for (final id in unpublishedIds) {
        final c = TranslationModels.find(id)!;
        expect(c.enabled, isFalse, reason: '$id: G5 has not passed');
        expect(c.files, isNotEmpty);
        for (final f in c.files.where((f) => f.name.endsWith('.onnx'))) {
          expect(
            f.expectedSha256,
            isNull,
            reason:
                '${c.id}/${f.name} has no published checksum, which is '
                'condition ② of G5',
          );
        }
        expect(c.isInstalled, isFalse);
        expect(TranslationModels.stateOf(c), ModelState.absent);
      }
    });

    test('the un-hide needs no page change (G5 mechanics)', () {
      const revived = ModelComponent(
        id: 'ocr_zh_fp16',
        approxSizeBytes: 5500000,
        kind: ModelKind.rec,
        requiresGpuEp: true,
        replaces: 'ocr_zh',
        dictFrom: 'ocr_zh',
        files: [
          ModelFile(
            'rec.onnx',
            ['{release}/rec_zh_fp16.onnx'],
            expectedSha256:
                'd2a7720d45a54257208b1e13e36a8479894cb74155a5efe29462512d42f49da9',
          ),
        ],
      );
      expect(TranslationModels.isUnpublishedAsset(revived), isFalse);
    });

    test('the page builds its rows from the registry rule, not from `all`', () {
      // Same style as the red-line R3 guard in local_model_import_test.dart:
      // the defect was "three dead rows", and the fix is only durable if the
      // page cannot drift back to listing `TranslationModels.all`.
      final src = File(
        'lib/pages/settings/translation_models_settings.dart',
      ).readAsStringSync();
      expect(src, contains('TranslationModels.listedComponents('));
      expect(
        RegExp(r'TranslationModels\.all\s*\.where').hasMatch(src),
        isFalse,
        reason: 'a section filtered straight off the registry would bypass G5',
      );
      // Kept on purpose: the per-row "打开模型目录" action.
      expect(src, contains('Icons.folder_open'));
      expect(src, contains('_openModelFolder'));
    });

    test('the page detects on open and only then offers the one-click recheck',
        () {
      final src = File(
        'lib/pages/settings/translation_models_settings.dart',
      ).readAsStringSync();
      expect(src, contains('addPostFrameCallback'));
      expect(src, contains('TranslationModels.runDetectionPass'));
      expect(src, contains('_detectOnOpen'));
      // The notice is conditional on a failure, not a permanent fixture.
      expect(src, contains('if (_showCheckAll)'));
      expect(src, contains('hasFailures'));
      // …and one click walks every component, not one row at a time.
      expect(src, contains('_checkAllComponents'));
      expect(src, contains('for (final component in targets)'));
    });
  });

  // =========================================================================
  // The user of this page reads Chinese and cannot read English, so every
  // sentence the validator can produce must arrive in Chinese — and the two
  // places that hold that wording (the Dart skeletons, which are the floor for
  // the worker isolate and for tests, and `assets/translation.json`, which is
  // what the running app renders) must not drift apart. Both directions are
  // checked mechanically here.
  // =========================================================================
  group('校验提示必须是中文，且 Dart 骨架与 translation.json 不漂移', () {
    final locales = () {
      final json = jsonDecode(
        File('assets/translation.json').readAsStringSync(),
      ) as Map<String, dynamic>;
      return {
        for (final loc in const ['zh_CN', 'zh_TW'])
          loc: Map<String, String>.from(json[loc] as Map),
      };
    }();

    Set<String> placeholders(String s) => RegExp(
      r'@([A-Za-z]+)',
    ).allMatches(s).map((m) => m.group(1)!).toSet();

    test('每条骨架都在 zh_CN 与 zh_TW 里，且占位符一致', () {
      expect(ModelMessages.skeletons, isNotEmpty);
      for (final entry in ModelMessages.skeletons.entries) {
        final key = '${ModelMessages.namespace}${entry.key}';
        for (final loc in const ['zh_CN', 'zh_TW']) {
          final text = locales[loc]![key];
          expect(text, isNotNull, reason: '$loc 缺少 $key');
          final want = placeholders(entry.value);
          final got = placeholders(text!);
          expect(
            got,
            want,
            reason: '$loc/$key 的 @占位符与 Dart 骨架不一致：$want vs $got',
          );
        }
      }
    });

    test('zh_CN 与 Dart 骨架逐字相同（页面显示的就是测试断言的那句）', () {
      // The fallback and the shipped Simplified text are the same sentence on
      // purpose: a test that asserts the fallback asserts what the user sees.
      for (final entry in ModelMessages.skeletons.entries) {
        final key = '${ModelMessages.namespace}${entry.key}';
        expect(
          locales['zh_CN']![key],
          entry.value,
          reason: '$key 的 zh_CN 与代码骨架已经漂移',
        );
      }
    });

    test('没有一条骨架是成句的英文（技术标识符除外）', () {
      // "an aaaaaaaaaa bbbbbbbbbb cccccccccc" is prose; `float32`,
      // `softmax_11.tmp_0`, `[batch,3,height,width]` are not — they are the
      // diagnostic handle and stay verbatim.
      final englishSentence = RegExp(r'[A-Za-z]{4,}( [A-Za-z]{4,}){2,}');
      for (final entry in ModelMessages.skeletons.entries) {
        expect(
          englishSentence.hasMatch(entry.value),
          isFalse,
          reason: '${entry.key} 仍是英文句子：${entry.value}',
        );
      }
      for (final loc in const ['zh_CN', 'zh_TW']) {
        for (final entry in ModelMessages.skeletons.entries) {
          final text =
              locales[loc]!['${ModelMessages.namespace}${entry.key}']!;
          expect(
            englishSentence.hasMatch(text),
            isFalse,
            reason: '$loc/${entry.key} 仍是英文句子：$text',
          );
        }
      }
    });

    test('render 填参后不留未替换的 @占位符', () {
      for (final entry in ModelMessages.skeletons.entries) {
        final params = {
          for (final p in placeholders(entry.value))
            p: 'X',
        };
        expect(
          ModelMessages.render(entry.key, params),
          isNot(contains('@')),
          reason: entry.key,
        );
      }
    });

    test('模型管理页没有会回退成英文的 .tl 键', () {
      final src = File(
        'lib/pages/settings/translation_models_settings.dart',
      ).readAsStringSync();
      final keys = RegExp(
        r'"([^"]{2,})"\s*\.tl',
      ).allMatches(src).map((m) => m.group(1)!).toSet();
      expect(keys, isNotEmpty);
      for (final key in keys) {
        for (final loc in const ['zh_CN', 'zh_TW']) {
          expect(
            locales[loc]![key],
            isNotNull,
            reason: '$loc 缺少页面文案「$key」，界面会显示英文',
          );
        }
      }
      // 组件名同样经 .tl 渲染
      for (final c in TranslationModels.all) {
        final key = c.displayNameKey;
        if (key == null) continue;
        expect(
          locales['zh_CN']![key],
          isNotNull,
          reason: '${c.id} 的名称 $key 没有中文译文',
        );
        expect(
          locales['zh_TW']![key],
          isNotNull,
          reason: '${c.id} 的名称 $key 没有繁体译文',
        );
      }
    });
  });
}
