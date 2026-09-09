import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:venera/foundation/app.dart';
import 'package:venera/foundation/appdata.dart';
import 'package:venera/foundation/image_translation/ort_capabilities.dart';
import 'package:venera/foundation/image_translation/translation_performance_config.dart';
import 'package:venera/foundation/image_translation/pre_translation_tasks.dart';

void main() {
  // Two tests below apply a tier, and applying saves the settings file. Point
  // `App.dataPath` at a scratch directory so those saves cannot touch the
  // default path (`/venera/data`) — the same harness other appdata tests use.
  late Directory tempDir;
  setUpAll(() {
    TestWidgetsFlutterBinding.ensureInitialized();
    tempDir = Directory.systemTemp.createTempSync('venera-perf-config-');
    App.dataPath = tempDir.path;
  });
  tearDownAll(() {
    try {
      tempDir.deleteSync(recursive: true);
    } catch (_) {
      // A still-open floating save can hold the directory on Windows; leaking a
      // temp directory is harmless next to failing a suite.
    }
  });

  test('unknown and old settings default to balanced', () {
    expect(
      TranslationPerformanceConfig.fromSetting(null),
      TranslationPerformancePreset.balanced,
    );
    expect(
      TranslationPerformanceConfig.fromSetting('old-value'),
      TranslationPerformancePreset.balanced,
    );
  });

  test('mobile presets stay below desktop concurrency', () {
    var mobile = TranslationPerformanceConfig.valuesFor(
      TranslationPerformancePreset.fast,
      isDesktop: false,
    );
    var desktop = TranslationPerformanceConfig.valuesFor(
      TranslationPerformancePreset.fast,
      isDesktop: true,
    );
    expect(mobile.ocrWorkers, 2);
    expect(mobile.imageConcurrency, lessThan(desktop.imageConcurrency));
    expect(mobile.llmConcurrency, lessThan(desktop.llmConcurrency));
  });

  test('saver uses one unit of every resource', () {
    var values = TranslationPerformanceConfig.valuesFor(
      TranslationPerformancePreset.saver,
      isDesktop: false,
    );
    expect(values.batchPages, 1);
    expect(values.ocrWorkers, 1);
    expect(values.imageConcurrency, 1);
    expect(values.llmConcurrency, 1);
  });

  test('mobile presets stay within mobile-safe ceilings', () {
    for (var preset in [
      TranslationPerformancePreset.saver,
      TranslationPerformancePreset.balanced,
      TranslationPerformancePreset.fast,
    ]) {
      var values = TranslationPerformanceConfig.valuesFor(
        preset,
        isDesktop: false,
      );
      expect(values.batchPages, lessThanOrEqualTo(8));
      expect(values.ocrWorkers, lessThanOrEqualTo(2));
      expect(values.imageConcurrency, lessThanOrEqualTo(3));
      expect(values.llmConcurrency, lessThanOrEqualTo(3));
    }
  });

  test('mobile custom values clamp desktop-sized synced settings', () {
    var oldBatch = appdata.settings['imageTranslationPreBatchPages'];
    var oldOcr = appdata.settings['imageTranslationOcrWorkers'];
    var oldImage = appdata.settings['imageTranslationImageConcurrency'];
    var oldLlm = appdata.settings['imageTranslationLlmConcurrency'];
    addTearDown(() {
      appdata.settings['imageTranslationPreBatchPages'] = oldBatch;
      appdata.settings['imageTranslationOcrWorkers'] = oldOcr;
      appdata.settings['imageTranslationImageConcurrency'] = oldImage;
      appdata.settings['imageTranslationLlmConcurrency'] = oldLlm;
    });
    appdata.settings['imageTranslationPreBatchPages'] = 20;
    appdata.settings['imageTranslationOcrWorkers'] = 6;
    appdata.settings['imageTranslationImageConcurrency'] = 6;
    appdata.settings['imageTranslationLlmConcurrency'] = 4;

    var values = TranslationPerformanceConfig.valuesFor(
      TranslationPerformancePreset.custom,
      isDesktop: false,
    );
    expect(values.batchPages, 8);
    expect(values.ocrWorkers, 2);
    expect(values.imageConcurrency, 3);
    expect(values.llmConcurrency, 3);
  });

  test('mobile Japanese pipeline keeps one group in flight', () {
    var performance = TranslationPerformanceConfig.valuesFor(
      TranslationPerformancePreset.fast,
      isDesktop: false,
    );
    expect(
      PreTranslationTaskManager.pipelineConcurrencyFor(
        performance,
        isMobile: true,
        sourceLang: 'ja',
        hasJapaneseModel: true,
      ),
      1,
    );
    expect(
      PreTranslationTaskManager.pipelineConcurrencyFor(
        performance,
        isMobile: true,
        sourceLang: 'auto',
        hasJapaneseModel: true,
      ),
      1,
    );
  });

  test('desktop pipeline follows LLM concurrency', () {
    var performance = TranslationPerformanceConfig.valuesFor(
      TranslationPerformancePreset.fast,
      isDesktop: true,
    );
    expect(
      PreTranslationTaskManager.pipelineConcurrencyFor(
        performance,
        isMobile: false,
        sourceLang: 'ja',
        hasJapaneseModel: true,
      ),
      performance.llmConcurrency,
    );
  });

  test('GPU EP clamps pre-translation pipeline concurrency to at most 2', () {
    var performance = TranslationPerformanceConfig.valuesFor(
      TranslationPerformancePreset.fast,
      isDesktop: true,
    );
    expect(performance.llmConcurrency, 4);
    expect(
      PreTranslationTaskManager.pipelineConcurrencyFor(
        performance,
        isMobile: false,
        sourceLang: 'ja',
        hasJapaneseModel: true,
        ep: OrtEpKind.directml,
      ),
      2,
    );
    expect(
      PreTranslationTaskManager.pipelineConcurrencyFor(
        performance,
        isMobile: false,
        sourceLang: 'ja',
        hasJapaneseModel: true,
        ep: OrtEpKind.cuda,
      ),
      2,
    );
    expect(
      PreTranslationTaskManager.pipelineConcurrencyFor(
        performance,
        isMobile: false,
        sourceLang: 'ja',
        hasJapaneseModel: true,
        ep: OrtEpKind.cpu,
      ),
      4,
    );
  });

  test('performance tuning is excluded from cross-device sync', () {
    var disabled = Appdata.syncDisabledFields(const []);
    expect(disabled, contains(TranslationPerformanceConfig.settingKey));
    expect(disabled, contains('imageTranslationPreBatchPages'));
    expect(disabled, contains('imageTranslationOcrWorkers'));
    expect(disabled, contains('imageTranslationImageConcurrency'));
    expect(disabled, contains('imageTranslationLlmConcurrency'));
    expect(disabled, contains('imageTranslationOcrDetBatch'));
    expect(disabled, contains('imageTranslationOcrRecBatch'));
    expect(disabled, contains('imageTranslationPagesPerOcrCall'));
  });

  // ---------------------------------------------------------------------
  // First-run tier + the machine suggestion. Written against the measured
  // 6 GB DirectML reference (whole 8-page sweep peaking at 2473 MB of
  // 6144 MB, timing split det 11% / rec-GPU 12% / decode 78%).
  // NOTE: not executed locally (no `flutter test` in this environment) —
  // see the hand-off list.
  // ---------------------------------------------------------------------

  group('default tier on a desktop GPU', () {
    test('balanced raises detection and cross-page batching on desktop only',
        () {
      var desktop = TranslationPerformanceConfig.valuesFor(
        TranslationPerformancePreset.balanced,
        isDesktop: true,
      );
      var mobile = TranslationPerformanceConfig.valuesFor(
        TranslationPerformancePreset.balanced,
        isDesktop: false,
      );
      // The two numbers a fresh install used to run timidly on a GPU desktop.
      expect(desktop.detBatch, 2);
      expect(desktop.pagesPerOcrCall, 4);
      // Recognition is NOT raised: its GPU half was 12% of the wall clock, so
      // a bigger batch cannot recover the 78% the CPU-side decode spends.
      expect(desktop.recBatch, 8);
      // Nothing measured on a phone may change a phone.
      expect(mobile.detBatch, 1);
      expect(mobile.pagesPerOcrCall, 2);
      expect(mobile.recBatch, 4);
    });

    test('balanced desktop numbers survive a custom read-back', () {
      // A preset value the `custom` clamps would shrink is a value the user
      // sees move under them the moment they touch any slider.
      var values = TranslationPerformanceConfig.valuesFor(
        TranslationPerformancePreset.balanced,
        isDesktop: true,
      );
      var saved = <String, Object?>{};
      for (var key in _tuningKeys) {
        saved[key] = appdata.settings[key];
      }
      addTearDown(() {
        for (var key in _tuningKeys) {
          appdata.settings[key] = saved[key];
        }
      });
      appdata.settings['imageTranslationPreBatchPages'] = values.batchPages;
      appdata.settings['imageTranslationOcrWorkers'] = values.ocrWorkers;
      appdata.settings['imageTranslationImageConcurrency'] =
          values.imageConcurrency;
      appdata.settings['imageTranslationLlmConcurrency'] =
          values.llmConcurrency;
      appdata.settings['imageTranslationOcrDetBatch'] = values.detBatch;
      appdata.settings['imageTranslationOcrRecBatch'] = values.recBatch;
      appdata.settings['imageTranslationPagesPerOcrCall'] =
          values.pagesPerOcrCall;
      var read = TranslationPerformanceConfig.valuesFor(
        TranslationPerformancePreset.custom,
        isDesktop: true,
      );
      expect(read.detBatch, values.detBatch);
      expect(read.recBatch, values.recBatch);
      expect(read.pagesPerOcrCall, values.pagesPerOcrCall);
      expect(read.batchPages, values.batchPages);
      expect(read.ocrWorkers, values.ocrWorkers);
    });
  });

  group('_intSetting reads what the slider wrote', () {
    test('a double-valued setting is used, not replaced by the fallback', () {
      // The settings UI accepts `num` and displays `raw.toDouble()`, so it
      // happily shows "2" for a stored 2.0 while an `is int`-only read made the
      // engine run the fallback 1 — the exact "UI says 2, log says 1" shape.
      var saved = appdata.settings['imageTranslationOcrDetBatch'];
      addTearDown(
        () => appdata.settings['imageTranslationOcrDetBatch'] = saved,
      );
      appdata.settings['imageTranslationOcrDetBatch'] = 2.0;
      var values = TranslationPerformanceConfig.valuesFor(
        TranslationPerformancePreset.custom,
        isDesktop: true,
      );
      expect(values.detBatch, 2);
    });

    test('a numeric string is still parsed and garbage still falls back', () {
      var saved = appdata.settings['imageTranslationOcrRecBatch'];
      addTearDown(
        () => appdata.settings['imageTranslationOcrRecBatch'] = saved,
      );
      appdata.settings['imageTranslationOcrRecBatch'] = '12';
      expect(
        TranslationPerformanceConfig.valuesFor(
          TranslationPerformancePreset.custom,
          isDesktop: true,
        ).recBatch,
        12,
      );
      appdata.settings['imageTranslationOcrRecBatch'] = 'later';
      expect(
        TranslationPerformanceConfig.valuesFor(
          TranslationPerformancePreset.custom,
          isDesktop: true,
        ).recBatch,
        1,
      );
    });
  });

  group('advise is conservative about hardware it cannot see', () {
    test('no probe yet keeps the shipped tier and claims no GPU', () {
      var advice = TranslationPerformanceConfig.advise(
        isDesktop: true,
        ep: null,
      );
      expect(advice.basis, AdviceBasis.noGpuReport);
      expect(advice.preset, TranslationPerformancePreset.balanced);
      expect(advice.isGpuBased, isFalse);
      expect(advice.values.detBatch, 2);
    });

    test('a probed CPU keeps the shipped tier', () {
      var advice = TranslationPerformanceConfig.advise(
        isDesktop: true,
        ep: OrtEpKind.cpu,
        batchCapable: true,
        totalVramMb: 24576,
      );
      expect(advice.basis, AdviceBasis.cpuOnly);
      expect(advice.preset, TranslationPerformancePreset.balanced);
      expect(advice.isGpuBased, isFalse);
    });

    test('a phone is never advised upward, GPU or not', () {
      // A tablet/phone with a discrete-accelerator-looking probe must still get
      // the mobile table: nothing in the desktop measurement applies to it.
      var advice = TranslationPerformanceConfig.advise(
        isDesktop: false,
        ep: OrtEpKind.directml,
        batchCapable: true,
        totalVramMb: 24576,
      );
      expect(advice.basis, AdviceBasis.mobile);
      expect(advice.values.detBatch, 1);
      expect(advice.values.pagesPerOcrCall, 2);
    });

    test('unknown video memory raises only the bounded knob', () {
      var advice = TranslationPerformanceConfig.advise(
        isDesktop: true,
        ep: OrtEpKind.directml,
        batchCapable: true,
        totalVramMb: null,
      );
      expect(advice.basis, AdviceBasis.gpuVramUnknown);
      expect(advice.isGpuBased, isTrue);
      // Which means: no new tier at all. The suggestion is the shipped one.
      expect(advice.preset, TranslationPerformancePreset.balanced);
    });

    test('a detection graph without a batch dimension is not batched', () {
      var advice = TranslationPerformanceConfig.advise(
        isDesktop: true,
        ep: OrtEpKind.cuda,
        batchCapable: false,
        totalVramMb: 24576,
      );
      expect(advice.basis, AdviceBasis.gpuStaticBatch);
      expect(advice.values.detBatch, 1);
    });

    test('the memory band is unreachable until something measures it', () {
      // Nothing in this suite probes the driver (`nvidia-smi` is a process
      // spawn), so the cache must be empty and no VRAM band may fire. Asserting
      // "not banded" rather than a specific basis keeps the invariant true
      // whichever host runs the suite.
      expect(TranslationPerformanceConfig.measuredVramMb, isNull);
      var advice = TranslationPerformanceConfig.adviseForDevice(
        ep: OrtEpKind.directml,
        batchCapable: true,
      );
      expect(advice.basis, isNot(AdviceBasis.gpuVramBanded));
      expect(advice.values.detBatch, lessThanOrEqualTo(2));
    });

    test('an under-2 GB adapter is left alone', () {
      var advice = TranslationPerformanceConfig.advise(
        isDesktop: true,
        ep: OrtEpKind.directml,
        batchCapable: true,
        totalVramMb: 1024,
      );
      expect(advice.preset, TranslationPerformancePreset.balanced);
      expect(advice.isActionable, isFalse);
    });

    // Regression for the above: `isActionable` used to resolve the *ambient*
    // platform through `TranslationPerformanceConfig.effective`. On a runner
    // where that disagreed with the device class the advice was computed for,
    // a "keep what you have" answer (the under-2 GB and unreadable-VRAM
    // branches both return exactly the shipped tier) came out actionable, and
    // the UI would have offered to "apply" a change that was no change at all.
    // Both device classes are asserted here, so the answer cannot depend on
    // which machine runs the suite.
    test('"leave it alone" is not actionable on either device class', () {
      var saved = <String, Object?>{};
      for (var key in _tuningKeys) {
        saved[key] = appdata.settings[key];
      }
      addTearDown(() {
        for (var key in _tuningKeys) {
          appdata.settings[key] = saved[key];
        }
      });
      for (var desktop in [true, false]) {
        var shipped = TranslationPerformanceConfig.valuesFor(
          TranslationPerformancePreset.balanced,
          isDesktop: desktop,
        );
        appdata.settings[TranslationPerformanceConfig.settingKey] = 'balanced';
        appdata.settings['imageTranslationOcrDetBatch'] = shipped.detBatch;
        appdata.settings['imageTranslationOcrRecBatch'] = shipped.recBatch;
        appdata.settings['imageTranslationPagesPerOcrCall'] =
            shipped.pagesPerOcrCall;
        appdata.settings['imageTranslationPreBatchPages'] = shipped.batchPages;
        var advice = TranslationPerformanceConfig.advise(
          isDesktop: desktop,
          ep: OrtEpKind.directml,
          batchCapable: true,
          totalVramMb: 1024,
        );
        expect(
          advice.isActionable,
          isFalse,
          reason: 'a $desktop-class advice judged a $desktop-class machine',
        );
        // …and the flag is not simply always false.
        var nudged = TranslationPerformanceConfig.advise(
          isDesktop: desktop,
          ep: OrtEpKind.directml,
          batchCapable: false,
          totalVramMb: 1024,
        );
        if (desktop) {
          // A desktop whose detection graph is static gets a table that is not
          // the balanced tier's own, which is a real change and must read as
          // one.
          expect(nudged.basis, AdviceBasis.gpuStaticBatch);
          expect(nudged.preset, TranslationPerformancePreset.custom);
          expect(
            nudged.isActionable,
            isTrue,
            reason: 'the static-batch table read as no change',
          );
        } else {
          // A phone never reaches the hardware bands at all: `advise` stops at
          // the device class, so the answer is the shipped table and there is
          // nothing to apply.
          expect(nudged.basis, AdviceBasis.mobile);
          expect(nudged.preset, TranslationPerformancePreset.balanced);
          expect(nudged.isActionable, isFalse);
        }
      }
    });

    test('a 3 GB adapter trades recognition and the worker pool down', () {
      var advice = TranslationPerformanceConfig.advise(
        isDesktop: true,
        ep: OrtEpKind.directml,
        batchCapable: true,
        totalVramMb: 3072,
      );
      expect(advice.values.recBatch, lessThanOrEqualTo(4));
      expect(advice.values.ocrWorkers, lessThanOrEqualTo(1));
    });

    test('the 6 GB reference machine gets the measured tier', () async {
      var advice = TranslationPerformanceConfig.advise(
        isDesktop: true,
        ep: OrtEpKind.directml,
        batchCapable: true,
        totalVramMb: 6144,
      );
      expect(advice.basis, AdviceBasis.gpuVramBanded);
      // The number the band used travels with the advice, so the row can name
      // the machine it described instead of re-reading a cache that may have
      // moved on.
      expect(advice.vramMb, 6144);
      expect(advice.values.detBatch, 2);
      expect(advice.values.recBatch, 8);
      expect(advice.values.pagesPerOcrCall, 4);
      // 0 = auto: `resolveOcrPoolSize` clamps a GPU desktop's pool to 2
      // whatever the slider says, so a hand-set 6 would only make the UI lie.
      expect(advice.values.ocrWorkers, 0);
      // Every advised number must be inside the ceilings `custom` re-clamps
      // with, or applying a suggestion would silently move the sliders.
      var saved = <String, Object?>{};
      for (var key in _tuningKeys) {
        saved[key] = appdata.settings[key];
      }
      addTearDown(() {
        for (var key in _tuningKeys) {
          appdata.settings[key] = saved[key];
        }
      });
      TranslationPerformanceConfig.applyAdvice(advice);
      // `applyAdvice` saves without awaiting; let that write land while the
      // scratch directory still exists (see setUpAll).
      await Future<void>.delayed(const Duration(milliseconds: 60));
      var read = TranslationPerformanceConfig.valuesFor(
        TranslationPerformancePreset.custom,
        isDesktop: true,
      );
      expect(read.detBatch, advice.values.detBatch);
      expect(read.recBatch, advice.values.recBatch);
      expect(read.pagesPerOcrCall, advice.values.pagesPerOcrCall);
      expect(read.imageConcurrency, advice.values.imageConcurrency);
      expect(read.llmConcurrency, advice.values.llmConcurrency);
    });

    test('a card twice the measured size is the only one advised to `fast`',
        () {
      var big = TranslationPerformanceConfig.advise(
        isDesktop: true,
        ep: OrtEpKind.cuda,
        batchCapable: true,
        totalVramMb: 24576,
      );
      expect(big.preset, TranslationPerformancePreset.fast);
      var six = TranslationPerformanceConfig.advise(
        isDesktop: true,
        ep: OrtEpKind.cuda,
        batchCapable: true,
        totalVramMb: 6144,
      );
      expect(six.preset, isNot(TranslationPerformancePreset.fast));
    });
  });

  group('an applied suggestion is what the sliders then show', () {
    void saveTuning() {
      var saved = <String, Object?>{};
      for (var key in _tuningKeys) {
        saved[key] = appdata.settings[key];
      }
      addTearDown(() {
        for (var key in _tuningKeys) {
          appdata.settings[key] = saved[key];
        }
      });
    }

    test('a static-batch GPU lands on custom and the write sticks', () async {
      saveTuning();
      var advice = TranslationPerformanceConfig.advise(
        isDesktop: true,
        ep: OrtEpKind.cuda,
        batchCapable: false,
        totalVramMb: 24576,
      );
      // det 1 is not the balanced table, so the tier must not be called
      // balanced: a named tier recomputes its values on every read and would
      // silently drop the detBatch just written.
      expect(advice.preset, TranslationPerformancePreset.custom);
      TranslationPerformanceConfig.applyAdvice(advice);
      await Future<void>.delayed(const Duration(milliseconds: 60));
      var read = TranslationPerformanceConfig.valuesFor(
        TranslationPerformancePreset.custom,
        isDesktop: true,
      );
      expect(read.detBatch, 1);
      expect(read.recBatch, 8);
      expect(TranslationPerformanceConfig.current, advice.preset);
    });

    test('a table that is exactly a tier keeps that tier name', () async {
      saveTuning();
      var advice = TranslationPerformanceConfig.advise(
        isDesktop: true,
        ep: OrtEpKind.cuda,
        batchCapable: true,
        totalVramMb: 24576,
      );
      expect(advice.preset, TranslationPerformancePreset.fast);
      TranslationPerformanceConfig.applyAdvice(advice);
      await Future<void>.delayed(const Duration(milliseconds: 60));
      expect(TranslationPerformanceConfig.current, advice.preset);
      var read = TranslationPerformanceConfig.valuesFor(
        TranslationPerformancePreset.fast,
        isDesktop: true,
      );
      expect(read.sameTuning(advice.values), isTrue);
    });

    // Regression: the first version of `applyAdvice` looked the tier table up
    // with the *ambient* `App.isDesktop`, so on a runner where that disagreed
    // with the device class the advice was computed for, the desktop `fast`
    // table was compared against the mobile one, declared foreign, and filed
    // under `custom` — a tier label lying about the machine. `fast` is split
    // across four fields between the two classes (batchPages 8/4, ocrWorkers
    // 3/2, imageConcurrency 6/3, llmConcurrency 4/3), which is what made the
    // mismatch observable. Nothing here reads the host, so both directions
    // hold on every runner.
    test('the tier lookup follows the advice device class, not the host', () {
      saveTuning();
      for (var desktop in [true, false]) {
        var table = TranslationPerformanceConfig.valuesFor(
          TranslationPerformancePreset.fast,
          isDesktop: desktop,
        );
        TranslationPerformanceConfig.applyAdvice(
          PerformanceAdvice(
            preset: TranslationPerformancePreset.fast,
            values: table,
            basis: AdviceBasis.gpuVramBanded,
            isDesktop: desktop,
            vramMb: 24576,
          ),
        );
        // The name is what the old code got wrong: it compared the advice's
        // table against the *host* class's table, so on a runner whose
        // `App.isDesktop` disagreed with the advice this filed the fast table
        // under `custom` and the row then showed "Custom".
        expect(
          TranslationPerformanceConfig.current,
          TranslationPerformancePreset.fast,
          reason: 'a $desktop-class fast table lost its tier name',
        );
        // A named tier is recomputed from its own table on every read, so the
        // numbers the engine runs are the advised ones whatever the stored
        // keys happen to say. (They are not all in range for `custom` on this
        // class — mobile `fast` ships recBatch 16 above the mobile custom
        // ceiling of 4 — but that is a preset-vs-ceiling inconsistency in the
        // shipped table, reported separately, not a leak through this path.)
        var runs = TranslationPerformanceConfig.valuesFor(
          TranslationPerformanceConfig.current,
          isDesktop: desktop,
        );
        expect(
          runs.sameTuning(table),
          isTrue,
          reason: 'a $desktop-class fast table did not survive the apply',
        );
      }
    });

    test('a table filed as custom is clamped before it is written', () {
      saveTuning();
      TranslationPerformanceConfig.applyAdvice(
        PerformanceAdvice(
          preset: TranslationPerformancePreset.custom,
          // Values no slider could produce, on the class with the tighter caps.
          values: const TranslationPerformanceValues(
            batchPages: 99,
            ocrWorkers: 9,
            imageConcurrency: 9,
            llmConcurrency: 99,
            detBatch: 99,
            recBatch: 99,
            pagesPerOcrCall: 99,
          ),
          basis: AdviceBasis.gpuVramBanded,
          isDesktop: false,
        ),
      );
      // Stored == read-back: the sliders cannot move after Apply.
      expect(appdata.settings['imageTranslationOcrDetBatch'], 16);
      expect(appdata.settings['imageTranslationOcrRecBatch'], 4);
      expect(appdata.settings['imageTranslationPagesPerOcrCall'], 8);
      expect(appdata.settings['imageTranslationPreBatchPages'], 8);
      expect(appdata.settings['imageTranslationOcrWorkers'], 2);
      expect(appdata.settings['imageTranslationImageConcurrency'], 3);
      expect(appdata.settings['imageTranslationLlmConcurrency'], 3);
      var read = TranslationPerformanceConfig.valuesFor(
        TranslationPerformancePreset.custom,
        isDesktop: false,
      );
      expect(read.detBatch, appdata.settings['imageTranslationOcrDetBatch']);
      expect(read.recBatch, appdata.settings['imageTranslationOcrRecBatch']);
      expect(
        read.pagesPerOcrCall,
        appdata.settings['imageTranslationPagesPerOcrCall'],
      );
    });
  });

  group('the suggestion cannot cross the pipeline-mode red line', () {
    test('no hardware combination advises a different topology default', () {
      // Gate G2 has not measured the release handshake, so no throughput
      // default may leak in through a batch-size suggestion. This walks the
      // whole input space of `advise` — it is pure, so nothing is written.
      for (var desktop in [true, false]) {
        for (var ep in [null, ...OrtEpKind.values]) {
          for (var capable in [true, false]) {
            for (var vram in [null, 512, 3072, 6144, 24576]) {
              var advice = TranslationPerformanceConfig.advise(
                isDesktop: desktop,
                ep: ep,
                batchCapable: capable,
                totalVramMb: vram,
              );
              // Every advised number must fit inside the ceilings the `custom`
              // tier re-applies on read: an advised value above its own clamp
              // would silently move under the user right after they tap Apply.
              expect(
                advice.values.detBatch,
                allOf(greaterThanOrEqualTo(1), lessThanOrEqualTo(16)),
                reason: 'ep=$ep capable=$capable vram=$vram desktop=$desktop',
              );
              expect(
                advice.values.recBatch,
                allOf(
                  greaterThanOrEqualTo(1),
                  lessThanOrEqualTo(desktop ? 32 : 4),
                ),
                reason: 'ep=$ep capable=$capable vram=$vram desktop=$desktop',
              );
              expect(
                advice.values.pagesPerOcrCall,
                allOf(greaterThanOrEqualTo(1), lessThanOrEqualTo(8)),
                reason: 'ep=$ep capable=$capable vram=$vram desktop=$desktop',
              );
              expect(
                advice.values.batchPages,
                allOf(greaterThanOrEqualTo(1), lessThanOrEqualTo(desktop ? 20 : 8)),
              );
              expect(
                advice.values.ocrWorkers,
                allOf(greaterThanOrEqualTo(0), lessThanOrEqualTo(desktop ? 6 : 2)),
              );
              expect(
                advice.values.imageConcurrency,
                allOf(
                  greaterThanOrEqualTo(1),
                  lessThanOrEqualTo(desktop ? 6 : 3),
                ),
              );
              expect(
                advice.values.llmConcurrency,
                allOf(
                  greaterThanOrEqualTo(1),
                  lessThanOrEqualTo(desktop ? 8 : 3),
                ),
              );
              expect(
                TranslationPerformanceConfig.pipelineMode,
                PipelineMode.freeVram,
                reason: 'reading the advice flipped the default',
              );
            }
          }
        }
      }
    });

    test('applying a suggestion leaves pipeline mode and backend alone',
        () async {
      const key = 'imageTranslationPipelineMode';
      var saved = appdata.settings[key];
      var savedEp = appdata.settings['imageTranslationExecutionProvider'];
      var savedPreset = appdata.settings[
        TranslationPerformanceConfig.settingKey
      ];
      addTearDown(() {
        appdata.settings[key] = saved;
        appdata.settings['imageTranslationExecutionProvider'] = savedEp;
        appdata.settings[TranslationPerformanceConfig.settingKey] = savedPreset;
      });
      appdata.settings['imageTranslationExecutionProvider'] = 'cpu';
      var advice = TranslationPerformanceConfig.advise(
        isDesktop: true,
        ep: OrtEpKind.directml,
        batchCapable: true,
        totalVramMb: 6144,
      );
      TranslationPerformanceConfig.applyAdvice(advice);
      await Future<void>.delayed(const Duration(milliseconds: 60));
      expect(TranslationPerformanceConfig.pipelineMode, PipelineMode.freeVram);
      expect(appdata.settings[key], 'freeVram');
      // The advised table is a batch/network decision. The inference backend
      // the user chose is none of its business, even when the advice came from
      // a DirectML probe.
      expect(
        appdata.settings['imageTranslationExecutionProvider'],
        'cpu',
      );
      // …and the tier really did move, so the assertion above is not vacuous.
      expect(
        TranslationPerformanceConfig.current,
        TranslationPerformancePreset.custom,
      );
    });
  });
}

/// The device-local tuning keys `applyValues` writes, so a test can restore
/// exactly what it touched.
const _tuningKeys = [
  'imageTranslationPerformancePreset',
  'imageTranslationPreBatchPages',
  'imageTranslationOcrWorkers',
  'imageTranslationImageConcurrency',
  'imageTranslationLlmConcurrency',
  'imageTranslationOcrDetBatch',
  'imageTranslationOcrRecBatch',
  'imageTranslationPagesPerOcrCall',
];
