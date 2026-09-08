import 'package:venera/foundation/app.dart';
import 'package:venera/foundation/appdata.dart';
import 'package:venera/foundation/image_translation/ort_capabilities.dart';

enum TranslationPerformancePreset { saver, balanced, fast, custom }

/// Two-stage pipeline topology choice (ruling R-4). The setting key and the
/// two value names are frozen by the plan's interface table (附录 F:
/// `imageTranslationPipelineMode`, `throughput` | `freeVram`) — renaming
/// either silently breaks persistence and cross-device expectations.
enum PipelineMode {
  /// Speed first: the OCR worker pool survives a chapter's stage-1 sweep, so
  /// the next chapter can reuse the loaded sessions while this chapter's
  /// stage-2 (pure network) is running. Cost: GPU memory stays resident
  /// during translation — which is exactly what decision gate G2 has **not**
  /// yet proven safe to keep (see the default below).
  throughput,

  /// VRAM first: every stage end releases the worker pool through the
  /// release handshake (the historical behavior). This is the factory
  /// default until G2 (true release measured by V7-1/V7-2) passes; do not
  /// flip it on a hunch.
  freeVram,
}

class TranslationPerformanceValues {
  const TranslationPerformanceValues({
    required this.batchPages,
    required this.ocrWorkers,
    required this.imageConcurrency,
    required this.llmConcurrency,
    this.ep = EpPreference.auto,
    this.detBatch = 1,
    this.recBatch = 1,
    this.pagesPerOcrCall = 2,
  });

  final int batchPages;
  final int ocrWorkers;
  final int imageConcurrency;
  final int llmConcurrency;
  final EpPreference ep;
  final int detBatch;
  final int recBatch;
  final int pagesPerOcrCall;
}

abstract final class TranslationPerformanceConfig {
  static const settingKey = 'imageTranslationPerformancePreset';

  static TranslationPerformancePreset get current =>
      fromSetting(appdata.settings[settingKey]);

  static TranslationPerformanceValues get effective =>
      valuesFor(current, isDesktop: App.isDesktop);

  static TranslationPerformancePreset fromSetting(Object? value) =>
      switch (value) {
        'saver' => TranslationPerformancePreset.saver,
        'fast' => TranslationPerformancePreset.fast,
        'custom' => TranslationPerformancePreset.custom,
        _ => TranslationPerformancePreset.balanced,
      };

  static EpPreference _epSetting() {
    return switch (appdata.settings['imageTranslationExecutionProvider']) {
      'directml' => EpPreference.directml,
      'cpu' => EpPreference.cpu,
      _ => EpPreference.auto,
    };
  }

  /// Frozen setting-key name (plan 附录 F). Value domain: `throughput` |
  /// `freeVram`.
  static const pipelineModeSettingKey = 'imageTranslationPipelineMode';

  /// The pipeline mode as configured on this device. Unknown or missing
  /// values fall back to [PipelineMode.freeVram] — the factory default while
  /// decision gate G2 ("did the release handshake actually give the VRAM
  /// back?") has not passed. Ruling R-4 wants `throughput` as the eventual
  /// default, but explicitly defers that flip to G2's evidence; until then a
  /// resident pool would turn "one leaked round per chapter" into "one leak
  /// held for the whole book", which is worse than not changing anything.
  static PipelineMode get pipelineMode =>
      pipelineModeFromSetting(appdata.settings[pipelineModeSettingKey]);

  /// Pure parse, same shape as [_epSetting]: unknown values keep the safe
  /// (memory-first) mode.
  static PipelineMode pipelineModeFromSetting(Object? value) =>
      switch (value) {
        'throughput' => PipelineMode.throughput,
        'freeVram' => PipelineMode.freeVram,
        // Anything unrecognized (typos, null, a value written by a future
        // build) falls back to the memory-safe default, never to throughput.
        _ => PipelineMode.freeVram,
      };

  static TranslationPerformanceValues valuesFor(
    TranslationPerformancePreset preset, {
    required bool isDesktop,
  }) => switch (preset) {
    TranslationPerformancePreset.saver => const TranslationPerformanceValues(
      batchPages: 1,
      ocrWorkers: 1,
      imageConcurrency: 1,
      llmConcurrency: 1,
      ep: EpPreference.cpu,
      detBatch: 1,
      recBatch: 1,
      pagesPerOcrCall: 1,
    ),
    TranslationPerformancePreset.balanced => TranslationPerformanceValues(
      batchPages: isDesktop ? 4 : 2,
      ocrWorkers: 0,
      imageConcurrency: isDesktop ? 3 : 2,
      llmConcurrency: 2,
      ep: EpPreference.auto,
      detBatch: 1,
      recBatch: isDesktop ? 8 : 4,
      pagesPerOcrCall: 2,
    ),
    TranslationPerformancePreset.fast => TranslationPerformanceValues(
      batchPages: isDesktop ? 8 : 4,
      ocrWorkers: isDesktop ? 3 : 2,
      imageConcurrency: isDesktop ? 6 : 3,
      llmConcurrency: isDesktop ? 4 : 3,
      ep: EpPreference.auto,
      detBatch: 4,
      recBatch: 16,
      pagesPerOcrCall: 4,
    ),
    TranslationPerformancePreset.custom => TranslationPerformanceValues(
      batchPages: _intSetting(
        'imageTranslationPreBatchPages',
        1,
      ).clamp(1, isDesktop ? 20 : 8),
      ocrWorkers: _intSetting(
        'imageTranslationOcrWorkers',
        0,
      ).clamp(0, isDesktop ? 6 : 2),
      imageConcurrency: _intSetting(
        'imageTranslationImageConcurrency',
        3,
      ).clamp(1, isDesktop ? 6 : 3),
      llmConcurrency: _intSetting(
        'imageTranslationLlmConcurrency',
        2,
      ).clamp(1, isDesktop ? 8 : 3),
      ep: _epSetting(),
      detBatch: _intSetting('imageTranslationOcrDetBatch', 1).clamp(1, 16),
      recBatch: _intSetting('imageTranslationOcrRecBatch', 1).clamp(1, isDesktop ? 32 : 4),
      pagesPerOcrCall: _intSetting('imageTranslationPagesPerOcrCall', 2).clamp(1, 8),
    ),
  };

  static void apply(TranslationPerformancePreset preset) {
    appdata.settings[settingKey] = preset.name;
    if (preset != TranslationPerformancePreset.custom) {
      var values = valuesFor(preset, isDesktop: App.isDesktop);
      appdata.settings['imageTranslationPreBatchPages'] = values.batchPages;
      appdata.settings['imageTranslationOcrWorkers'] = values.ocrWorkers;
      appdata.settings['imageTranslationImageConcurrency'] =
          values.imageConcurrency;
      appdata.settings['imageTranslationLlmConcurrency'] =
          values.llmConcurrency;
      appdata.settings['imageTranslationOcrDetBatch'] = values.detBatch;
      appdata.settings['imageTranslationOcrRecBatch'] = values.recBatch;
      appdata.settings['imageTranslationPagesPerOcrCall'] = values.pagesPerOcrCall;
    }
    appdata.saveData();
  }

  static void markCustom() {
    appdata.settings[settingKey] = TranslationPerformancePreset.custom.name;
    appdata.saveData();
  }

  static int _intSetting(String key, int fallback) {
    var value = appdata.settings[key];
    return value is int ? value : int.tryParse('$value') ?? fallback;
  }
}
