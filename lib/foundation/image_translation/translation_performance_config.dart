import 'package:venera/foundation/app.dart';
import 'package:venera/foundation/appdata.dart';
import 'package:venera/foundation/image_translation/ort_capabilities.dart';
import 'package:venera/foundation/image_translation/process_diagnostics.dart';

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

/// What the on-device tier is. These are the *only* signals a suggestion may
/// rest on, and every one of them is either already in memory (the platform
/// flag, the EP report from the first probe) or explicitly optional — a field
/// the caller could not read is `null`, never a guessed number.
enum AdviceBasis {
  /// Not a desktop. Mobile keeps the shipped tier untouched: nothing measured
  /// here says anything about a phone's memory.
  mobile,

  /// No EP report yet (nothing has been translated in this install). We do not
  /// guess a GPU exists; the shipped default stays.
  noGpuReport,

  /// Probed, and the probe says CPU. The default tier is the right one.
  cpuOnly,

  /// A GPU EP is active but the detection model has no batch dimension to grow
  /// ([EpReport.batchCapable] false), so the detection batch must stay 1.
  gpuStaticBatch,

  /// GPU confirmed and total video memory measured → banded by that number.
  gpuVramBanded,

  /// GPU confirmed but total video memory unreadable (no `nvidia-smi`, AMD or
  /// Intel adapter, probe failed). Only the knobs whose cost is bounded
  /// regardless of card size are raised.
  gpuVramUnknown,
}

/// A machine-specific suggestion: which tier to use and the exact numbers behind
/// it. Produced only by [TranslationPerformanceConfig.advise]; it changes nothing
/// by itself — the user has to apply it.
class PerformanceAdvice {
  const PerformanceAdvice({
    required this.preset,
    required this.values,
    required this.basis,
    required this.isDesktop,
    this.vramMb,
  });

  final TranslationPerformancePreset preset;
  final TranslationPerformanceValues values;
  final AdviceBasis basis;

  /// The device class this advice was computed for, carried on the result
  /// instead of re-read from [App.isDesktop] at question time.
  ///
  /// This is not decoration: [values] is one of the `valuesFor` tables, and
  /// several of them differ between desktop and mobile (`fast` in four fields,
  /// `balanced` in four after the first-run raise). Answering "is this already
  /// applied?" or "is this table really the tier it is named after?" with the
  /// *ambient* platform therefore compared a desktop table against a mobile
  /// one and got "no" on a machine the advice never described — which is
  /// exactly what the first version of this class did, and what the two cloud
  /// test failures caught. [advise] takes `isDesktop` as an input; every
  /// judgement the advice supports has to use that same input.
  final bool isDesktop;

  /// The adapter total this advice was banded by, when there was one. Carried on
  /// the result rather than re-read by the UI, so a row can show the machine it
  /// actually described instead of whatever the cache says by then.
  final int? vramMb;

  /// Whether this install already runs the suggested numbers. False means there
  /// is nothing to offer, so the UI shows no button instead of a lie.
  ///
  /// The tier *name* counts as part of the answer: staying on `custom` while
  /// the suggested numbers happen to match is a different thing to have chosen
  /// than selecting a tier, and the sliders would then move if the user ever
  /// re-applied it.
  ///
  /// The comparison is made against this advice's own device class
  /// ([isDesktop]), never against [TranslationPerformanceConfig.effective]:
  /// `effective` resolves the ambient platform, and the tables are
  /// platform-split, so an advice about a desktop would have been judged
  /// "not yet applied" by a phone's numbers — see [isDesktop].
  bool get isActionable {
    final tier = TranslationPerformanceConfig.current;
    if (preset != tier) return true;
    return !values.sameTuning(
      TranslationPerformanceConfig.valuesFor(tier, isDesktop: isDesktop),
    );
  }

  /// Whether the suggestion is based on a GPU actually being present. Only
  /// then may the UI claim to know something about this machine.
  bool get isGpuBased =>
      basis == AdviceBasis.gpuStaticBatch ||
      basis == AdviceBasis.gpuVramBanded ||
      basis == AdviceBasis.gpuVramUnknown;
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

  /// Compare the seven writable numbers, ignoring [ep].
  ///
  /// The inference backend is its own setting (`imageTranslationExecutionProvider`)
  /// and a batch suggestion never moves it, so both "is this already applied?"
  /// and "may this tier keep its name?" have to be answered from the numbers
  /// the apply path actually writes.
  bool sameTuning(TranslationPerformanceValues other) =>
      batchPages == other.batchPages &&
      ocrWorkers == other.ocrWorkers &&
      imageConcurrency == other.imageConcurrency &&
      llmConcurrency == other.llmConcurrency &&
      detBatch == other.detBatch &&
      recBatch == other.recBatch &&
      pagesPerOcrCall == other.pagesPerOcrCall;
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

  /// Frozen setting-key name for the ink-boundary experiment. Value domain:
  /// `true` | `false` (absent means false).
  static const inkBoundarySplitSettingKey = 'imageTranslationInkBoundarySplit';

  /// Whether the OCR clustering pass is allowed to *refuse* a candidate merge
  /// because the page's own ink says two facing boxes sit in different speech
  /// bubbles.
  ///
  /// Factory default **false**, and deliberately so. The discriminator is the
  /// bubble outline (a thin dark run in the gap band with bright pixels on both
  /// sides), and the geometry-only discriminator was proven unusable: the
  /// narration gap that must survive is 1.00× line thickness while the
  /// cross-bubble gap that must be split is 0.57×, so every geometric
  /// threshold cuts the legitimate one first. Until a real-device log says the
  /// ink rule fires only on real outlines, the shipped behaviour is the
  /// measured one: merge everything the existing gates accept. The switch
  /// exists so that verdict costs one run instead of another refactor, and
  /// [inkBoundarySplitFromSetting] keeps it a pure read.
  static bool get inkBoundarySplit =>
      inkBoundarySplitFromSetting(appdata.settings[inkBoundarySplitSettingKey]);

  /// Pure parse, same shape as [_epSetting] / [pipelineModeFromSetting]: only a
  /// real `true` enables the experiment. Null, a string, a number or any value
  /// written by a future build leaves the shipped clustering path untouched —
  /// an experiment must never be turned on by a typo.
  static bool inkBoundarySplitFromSetting(Object? value) => value == true;

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
    /// The factory tier for a fresh install, so these two desktop numbers *are*
    /// the first-run experience. Both were raised from the shipped `1` / `2`:
    /// * `detBatch 2` — measured on a 6 GB desktop GPU (RTX 3060 Laptop,
    ///   DirectML): a whole 8-page sweep at det 1 / rec 8 / group 8 peaked at
    ///   2473 MB of 6144 MB, i.e. 40% used, 3.6 GB idle. One extra detection
    ///   tile is 3·1280·896 floats = 13.8 MB of staging (the arena that held
    ///   the whole measured call reported 36 MB), so det 2 asks for ~14 MB more
    ///   plus the detector's own feature maps: 0.4% of the idle 3.6 GB, and the
    ///   OOM ladder in `ocr_batching.dart` (`runWithShrinkLadder` + the sticky
    ///   `cappedBy` ceiling) retreats it automatically on any card that
    ///   disagrees.
    /// * `pagesPerOcrCall 4` — half of the 8 pages per call that the same sweep
    ///   ran successfully. Crossing pages amortises per-call setup and feeds
    ///   the worker pool, and its cost is host RAM for the decoded RGBA pages
    ///   (~7.2 MB each at 1125×1600, so a group of 4 is ~29 MB against the ~58
    ///   MB the measured group of 8 held) — not video memory.
    /// `recBatch` is deliberately NOT raised: the same sweep's timing split
    /// (`parts={detMs:5300,recGpuMs:5700,decMsInRec:36000}` over 46.6 s) puts
    /// recognition GPU at 12% of the wall clock and the CPU-side decode at
    /// 78%. Doubling `recBatch` could therefore recover at most ~6% while
    /// doubling the crop staging — a cost with no paying benefit. Mobile
    /// numbers are untouched: nothing above was measured on a phone.
    TranslationPerformancePreset.balanced => TranslationPerformanceValues(
      batchPages: isDesktop ? 4 : 2,
      ocrWorkers: 0,
      imageConcurrency: isDesktop ? 3 : 2,
      llmConcurrency: 2,
      ep: EpPreference.auto,
      detBatch: isDesktop ? 2 : 1,
      recBatch: isDesktop ? 8 : 4,
      pagesPerOcrCall: isDesktop ? 4 : 2,
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
    TranslationPerformancePreset.custom => clampTuningToCustom(
      TranslationPerformanceValues(
        batchPages: _intSetting('imageTranslationPreBatchPages', 1),
        ocrWorkers: _intSetting('imageTranslationOcrWorkers', 0),
        imageConcurrency: _intSetting('imageTranslationImageConcurrency', 3),
        llmConcurrency: _intSetting('imageTranslationLlmConcurrency', 2),
        ep: _epSetting(),
        detBatch: _intSetting('imageTranslationOcrDetBatch', 1),
        recBatch: _intSetting('imageTranslationOcrRecBatch', 1),
        pagesPerOcrCall: _intSetting('imageTranslationPagesPerOcrCall', 2),
      ),
      isDesktop: isDesktop,
    ),
  };

  /// The one place the `custom` ceilings are expressed. [valuesFor] applies it
  /// when reading stored settings, and [applyAdvice] applies it before writing
  /// a table it files under `custom`: a number stored above a ceiling the
  /// read-back re-applies is a number the sliders silently move out from under
  /// the user — the same "display says one number, the engine runs another"
  /// defect this file keeps having to kill.
  static TranslationPerformanceValues clampTuningToCustom(
    TranslationPerformanceValues values, {
    required bool isDesktop,
  }) => TranslationPerformanceValues(
    batchPages: values.batchPages.clamp(1, isDesktop ? 20 : 8),
    ocrWorkers: values.ocrWorkers.clamp(0, isDesktop ? 6 : 2),
    imageConcurrency: values.imageConcurrency.clamp(1, isDesktop ? 6 : 3),
    llmConcurrency: values.llmConcurrency.clamp(1, isDesktop ? 8 : 3),
    ep: values.ep,
    detBatch: values.detBatch.clamp(1, 16),
    recBatch: values.recBatch.clamp(1, isDesktop ? 32 : 4),
    pagesPerOcrCall: values.pagesPerOcrCall.clamp(1, 8),
  );

  static void apply(TranslationPerformancePreset preset) {
    if (preset == TranslationPerformancePreset.custom) {
      // Custom has no table of its own: the individual sliders already hold the
      // numbers, so selecting it must not overwrite them.
      appdata.settings[settingKey] = preset.name;
      appdata.saveData();
      return;
    }
    applyValues(valuesFor(preset, isDesktop: App.isDesktop), preset: preset);
  }

  /// Write one concrete table and record which tier it came from. Used by the
  /// machine suggestion (whose GPU tier is not a shipped preset, so it lands on
  /// `custom` and stays editable by the sliders).
  ///
  /// [TranslationPerformanceValues.ep] is intentionally ignored: the inference
  /// backend is its own setting and a throughput suggestion must not silently
  /// move a user off the backend they picked.
  static void applyValues(
    TranslationPerformanceValues values, {
    TranslationPerformancePreset preset = TranslationPerformancePreset.custom,
  }) {
    appdata.settings[settingKey] = preset.name;
    appdata.settings['imageTranslationPreBatchPages'] = values.batchPages;
    appdata.settings['imageTranslationOcrWorkers'] = values.ocrWorkers;
    appdata.settings['imageTranslationImageConcurrency'] = values.imageConcurrency;
    appdata.settings['imageTranslationLlmConcurrency'] = values.llmConcurrency;
    appdata.settings['imageTranslationOcrDetBatch'] = values.detBatch;
    appdata.settings['imageTranslationOcrRecBatch'] = values.recBatch;
    appdata.settings['imageTranslationPagesPerOcrCall'] = values.pagesPerOcrCall;
    appdata.saveData();
  }

  /// Suggest a tier for this machine. Pure: every fact is passed in, so the
  /// whole policy — including the parts that must stay false on a machine
  /// without a GPU — is unit-testable without an isolate, a probe or a network.
  ///
  /// The conservatism is the point. [ep] is what the runtime actually probed
  /// (null until the first translation has run); [totalVramMb] is what the
  /// adapter reports as its *total* (null whenever no probe answered, which is
  /// every AMD/Intel card and every machine without `nvidia-smi`). A null never
  /// becomes a guessed number: it either keeps the shipped default or limits the
  /// suggestion to the one knob whose cost is bounded whatever the card is.
  ///
  /// Nothing here touches [pipelineMode]. The factory default of the pipeline
  /// topology stays [PipelineMode.freeVram] until decision gate G2 measures the
  /// release handshake, and an aggressive batch is not an argument about it.
  static PerformanceAdvice advise({
    bool? isDesktop,
    OrtEpKind? ep,
    bool batchCapable = false,
    int? totalVramMb,
  }) {
    final desktop = isDesktop ?? App.isDesktop;
    final base = valuesFor(
      TranslationPerformancePreset.balanced,
      isDesktop: desktop,
    );
    if (!desktop) {
      return PerformanceAdvice(
        preset: TranslationPerformancePreset.balanced,
        values: base,
        isDesktop: desktop,
        basis: AdviceBasis.mobile,
      );
    }
    if (ep == null) {
      // Nothing has been probed. Saying "balanced" is the honest answer;
      // saying "I detect no GPU" would be a lie we cannot support.
      return PerformanceAdvice(
        preset: TranslationPerformancePreset.balanced,
        values: base,
        isDesktop: desktop,
        basis: AdviceBasis.noGpuReport,
      );
    }
    if (ep == OrtEpKind.cpu) {
      return PerformanceAdvice(
        preset: TranslationPerformancePreset.balanced,
        values: base,
        isDesktop: desktop,
        basis: AdviceBasis.cpuOnly,
      );
    }
    if (!batchCapable) {
      // A GPU is running, but the detection graph has no batch dimension to
      // grow: only recognition can batch. Keep the shipped table's other
      // numbers, pull detection back to one tile — and call the result what
      // it is, `custom`, because those numbers no longer *are* the balanced
      // tier (naming it balanced would have the read-back ignore the detBatch
      // we just wrote, and show the user a tier that lies).
      return PerformanceAdvice(
        preset: TranslationPerformancePreset.custom,
        values: TranslationPerformanceValues(
          batchPages: base.batchPages,
          ocrWorkers: base.ocrWorkers,
          imageConcurrency: base.imageConcurrency,
          llmConcurrency: base.llmConcurrency,
          detBatch: 1,
          recBatch: base.recBatch,
          pagesPerOcrCall: base.pagesPerOcrCall,
        ),
        isDesktop: desktop,
        basis: AdviceBasis.gpuStaticBatch,
      );
    }
    final vram = totalVramMb;
    if (vram == null) {
      // GPU confirmed, its size unknown: the detection batch is the only
      // raising worth doing (one extra tile is 13.8 MB of host staging against
      // a 36 MB arena measured for the whole call), and that is already the
      // shipped default — so the answer here is deliberately "stay where you
      // are".
      return PerformanceAdvice(
        preset: TranslationPerformancePreset.balanced,
        values: base,
        isDesktop: desktop,
        basis: AdviceBasis.gpuVramUnknown,
      );
    }
    if (vram < 2048) {
      // A GPU that small is a shared or very old one; do not push it at all.
      return PerformanceAdvice(
        preset: TranslationPerformancePreset.balanced,
        values: base,
        vramMb: vram,
        isDesktop: desktop,
        basis: AdviceBasis.gpuVramBanded,
      );
    }
    if (vram < 4096) {
      // Derived, not measured (cloud test CT-2): trade the recognition stage —
      // the one that actually allocated 2.4 GB with the pool — down, and run a
      // single worker so only one copy of the models is resident.
      return PerformanceAdvice(
        preset: TranslationPerformancePreset.custom,
        values: TranslationPerformanceValues(
          batchPages: 2,
          ocrWorkers: 1,
          imageConcurrency: 3,
          llmConcurrency: 2,
          detBatch: 2,
          recBatch: 4,
          pagesPerOcrCall: 2,
        ),
        vramMb: vram,
        isDesktop: desktop,
        basis: AdviceBasis.gpuVramBanded,
      );
    }
    if (vram >= 12288) {
      // At least twice the card every figure here was measured on. `fast` was
      // built for that much memory; it is still not *measured* there, which is
      // what cloud test CT-1 is for.
      return PerformanceAdvice(
        preset: TranslationPerformancePreset.fast,
        // Same device class as the advice itself: a desktop table looked
        // up for a phone would be judged a foreign table by applyAdvice.
        values: valuesFor(
          TranslationPerformancePreset.fast,
          isDesktop: desktop,
        ),
        vramMb: vram,
        isDesktop: desktop,
        basis: AdviceBasis.gpuVramBanded,
      );
    }
    // 4 GB … 12 GB: the band the measurement was made in (6144 MB adapter,
    // 2473 MB peak over a whole 8-page sweep at det 1 / rec 8 / group 8).
    return PerformanceAdvice(
      preset: TranslationPerformancePreset.custom,
      values: TranslationPerformanceValues(
        // Unchanged from the shipped tier: this groups pages for one *network*
        // translation request, and nothing in the sweep measured it.
        batchPages: 4,
        // 0 = auto on purpose. A hand-set 6 is a lie on a GPU desktop:
        // `resolveOcrPoolSize` clamps the pool to 2 whenever the EP is not CPU
        // (translation_worker.dart:266-269), so auto is what actually runs.
        ocrWorkers: 0,
        // Downloads cost no video memory; the source's own rate limit plus the
        // AIMD backoff is the gate. The user's run held 6 without a recorded
        // 429, so 4 is a deliberate half-step, not the ceiling.
        imageConcurrency: 4,
        // Desktop slider maximum, and the value the reference run used. The
        // pipeline's own GPU overlap rule intends 2 (pre_translation_tasks.dart:
        // 1482-1486), so this buys network parallelism, not GPU contention.
        llmConcurrency: 4,
        detBatch: 2,
        // Not 16: recognition's GPU half was 12% of the wall clock, its decode
        // half 78% and CPU-side. A bigger rec batch cannot buy back time the
        // GPU was not spending.
        recBatch: 8,
        // Half of the 8 pages per call the reference sweep ran; the rest of the
        // cost is host RAM for decoded pages (~57 MB each), not VRAM.
        pagesPerOcrCall: 4,
      ),
      vramMb: vram,
      isDesktop: desktop,
      basis: AdviceBasis.gpuVramBanded,
    );
  }

  /// [advise] fed from what this process already knows, with no new probe: the
  /// caller passes the EP report's fields it holds anyway, plus whatever
  /// [measuredVramMb] has managed to learn. [totalVramMb] defaults to that
  /// cache, so a page that never probed simply gets the unreadable-memory
  /// branch instead of a guess.
  static PerformanceAdvice adviseForDevice({
    OrtEpKind? ep,
    bool batchCapable = false,
    int? totalVramMb,
  }) => advise(
    isDesktop: App.isDesktop,
    ep: ep,
    batchCapable: batchCapable,
    totalVramMb: totalVramMb ?? _measuredVramMb,
  );

  static int? _measuredVramMb;

  /// Total video memory of the graphics adapter in MB, or null while nothing
  /// has measured it. Null is the honest state on AMD, on Intel, and on
  /// NVIDIA machines where the caller has not asked yet — [advise] treats it as
  /// "do not get aggressive", never as "0 MB".
  static int? get measuredVramMb => _measuredVramMb;

  /// Ask the driver for the adapter's total video memory (a vendor probe: on
  /// Windows/NVIDIA this shells out to `nvidia-smi`, ~30-100 ms, so it belongs
  /// behind an explicit user action, not behind a settings page building
  /// itself). Returns the cached value when the probe cannot answer, and keeps
  /// an earlier good reading rather than replacing it with nothing.
  static Future<int?> probeAdapterVram() async {
    try {
      final snap = await takeProcessSnapshot(vendorProbe: true);
      final bytes = snap.gpuBudgetBytes;
      if (bytes != null && bytes > 0) {
        _measuredVramMb = (bytes / (1024 * 1024)).round();
      }
    } catch (e) {
      // A failed probe says nothing about the card; the cache and the
      // conservative branch it leaves in place are the answer.
    }
    return _measuredVramMb;
  }

  /// Write an [advise] result. Both branches exist to keep the label honest,
  /// and both answer from the advice's own device class
  /// ([PerformanceAdvice.isDesktop]) rather than from the ambient platform —
  /// `fast` and `balanced` have different desktop and mobile tables, so a
  /// comparison that mixed the two classes decided "is this the tier's own
  /// table?" by comparing a desktop table against a phone's (that mismatch is
  /// what filed the desktop `fast` table under `custom`).
  ///
  /// * **Named tier, and the numbers are that tier's own** → store them under
  ///   that tier name. A named tier is recomputed by [valuesFor] on every read,
  ///   so what matters is that the recomputation lands on the advised numbers;
  ///   the stored keys then mirror them, exactly as in [apply].
  /// * **Anything else — including every advice that already says `custom`** →
  ///   the numbers are clamped to that class's ceilings *before* the write,
  ///   then filed under `custom`. `custom` is the one tier read back *through*
  ///   those ceilings, so an uncapped number stored there is a number the
  ///   sliders move out from under the user on the next read.
  static void applyAdvice(PerformanceAdvice advice) {
    final tierTable = valuesFor(advice.preset, isDesktop: advice.isDesktop);
    final named = advice.preset != TranslationPerformancePreset.custom;
    if (named && advice.values.sameTuning(tierTable)) {
      applyValues(advice.values, preset: advice.preset);
      return;
    }
    applyValues(
      clampTuningToCustom(advice.values, isDesktop: advice.isDesktop),
      preset: TranslationPerformancePreset.custom,
    );
  }

  static void markCustom() {
    appdata.settings[settingKey] = TranslationPerformancePreset.custom.name;
    appdata.saveData();
  }

  /// Read an integer setting without lying about what the sliders show.
  ///
  /// `value is int` alone used to fall through to `int.tryParse('$value')`,
  /// which returns null for a JSON round-tripped `2.0` — so a value written as
  /// a double (a copy from another device, a hand-edited appdata.json, any
  /// future float-producing widget) made the engine run the *fallback* while
  /// the settings UI happily displayed 2: the slider accepts `num` and shows
  /// `raw.toDouble()` (setting_components.dart:533-539). Truncating a double we
  /// can read is what the display already promised.
  static int _intSetting(String key, int fallback) {
    var value = appdata.settings[key];
    if (value is int) return value;
    if (value is num) return value.toInt();
    return int.tryParse('$value') ?? fallback;
  }
}
