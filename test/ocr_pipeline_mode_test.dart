import 'package:flutter_test/flutter_test.dart';
import 'package:venera/foundation/appdata.dart';
import 'package:venera/foundation/image_translation/translation_performance_config.dart';

/// Pure parsing tests for the PipelineMode setting (ruling R-4, plan §6.2.2 /
/// 附录 F). Behavior (whether the finally in `_runChapterOcrPass` shuts the
/// worker pool down) is a one-line branch on this parsed value; the value's
/// integrity is what the gate depends on, so it is pinned here without
/// spinning up isolates or FFmpeg.
void main() {
  const key = 'imageTranslationPipelineMode';

  Object? saved;
  setUp(() => saved = appdata.settings[key]);
  tearDown(() => appdata.settings[key] = saved);

  test('frozen setting-key name (附录 F contract)', () {
    // Renaming the key would silently orphan every stored value and split the
    // name across devices/sync — the plan froze it for a reason.
    expect(TranslationPerformanceConfig.pipelineModeSettingKey, key);
  });

  test('factory default is freeVram until gate G2 passes', () {
    // R-4 defers the "throughput as default" flip to decision gate G2 (the
    // release handshake must be MEASURED to free VRAM first). This assertion
    // is the tripwire: if the appdata default table flips before that
    // evidence exists, this test fails.
    expect(appdata.settings[key], 'freeVram');
    expect(TranslationPerformanceConfig.pipelineMode, PipelineMode.freeVram);
  });

  test('both valid values parse to their mode', () {
    expect(
      TranslationPerformanceConfig.pipelineModeFromSetting('throughput'),
      PipelineMode.throughput,
    );
    expect(
      TranslationPerformanceConfig.pipelineModeFromSetting('freeVram'),
      PipelineMode.freeVram,
    );
    appdata.settings[key] = 'throughput';
    expect(
      TranslationPerformanceConfig.pipelineMode,
      PipelineMode.throughput,
    );
  });

  test('unknown or missing values fall back to freeVram, never throughput',
      () {
    // Anything unrecognized must land on the memory-safe mode: a typo, a
    // value from a future build, or a null hole left by an interrupted sync
    // may not silently enable the residency mode G2 has not approved.
    for (final bad in [null, '', 'THROUGHPUT', 'speed', 0, true, 'free_vram']) {
      expect(
        TranslationPerformanceConfig.pipelineModeFromSetting(bad),
        PipelineMode.freeVram,
        reason: 'fallback broken for $bad',
      );
    }
  });

  test('pipeline mode is device-local: excluded from cross-device sync', () {
    // A big-VRAM desktop must not push `throughput` onto a low-VRAM laptop,
    // same policy as the rest of the performance tuning block.
    var disabled = Appdata.syncDisabledFields(const []);
    expect(disabled, contains(key));
  });
}
