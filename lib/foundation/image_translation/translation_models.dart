// ===========================================================================
// OWNERSHIP — read this before touching the two files below.
//
// `translation_models.dart` and
// `lib/pages/settings/translation_models_settings.dart` are owned
// EXCLUSIVELY by the local-model validation task (defects: symbolic ONNX axes
// rejected by the validator, unpublished rows rendered as dead ends, detection
// only on demand, English-only diagnostics).
//
// A `git checkout --` / `git restore` on either path does NOT just undo the
// change you meant to undo: it also deletes the settings-page wiring that the
// validator work depends on, because the list filter, the detection-on-open
// pass and the one-click recheck all live here. This has already happened
// once in reality (a sibling task restored this file from HEAD and took the
// release-blocking fix's UI half down with it). If a file in this pair has to
// be reverted, revert it together with `local_model_import.dart` and say so.
// ===========================================================================

import 'dart:async';

import 'package:crypto/crypto.dart';
import 'package:dio/dio.dart';
import 'package:flutter/foundation.dart';
import 'package:venera/foundation/app.dart';
import 'package:venera/foundation/appdata.dart';
import 'package:venera/foundation/consts.dart';
import 'package:venera/foundation/image_translation/local_model_import.dart';
import 'package:venera/foundation/image_translation/ort_capabilities.dart';
import 'package:venera/foundation/image_translation/translation_worker.dart';
import 'package:venera/foundation/log.dart';
import 'package:venera/network/app_dio_io.dart';
import 'package:venera/utils/io.dart';

// Re-exported so the model-management settings page (a `part` of
// settings_page.dart, which therefore cannot add its own imports without a
// cross-agent edit) reaches the import API through this library only.
export 'local_model_import.dart' show ImportVerdict, validateComponent;

/// A single downloadable file of a model component. [urls] is a fallback
/// chain: mirrors are tried in order, so a blocked host does not make the
/// component impossible to install.
class ModelFile {
  const ModelFile(this.name, this.urls, {this.expectedSha256});

  /// File name inside the component directory.
  final String name;

  /// Candidate URLs. `{hf}` is replaced with the configured HuggingFace
  /// endpoint (official or mirror) at download time.
  /// `{release}` is replaced with the GitHub Releases download URL for models.
  final List<String> urls;

  /// Optional expected SHA-256 checksum (hex string, case-insensitive).
  final String? expectedSha256;
}

/// Verification state of a component's local files (plan §7.2.1, name
/// frozen by appendix F — other phases and the settings UI compile against
/// these exact identifiers).
///
/// * [absent]   — at least one required file is missing or 0 bytes.
/// * [present]  — files exist, are non-empty and passed the cheap, FFI-free
///   structure gate of `local_model_import.dart`, but nothing stronger has
///   ever been checked (no checksum comparison, no session probe).
/// * [verified] — [absent]/[present] plus a full [validateComponent] pass,
///   which includes checksum matches against [ModelFile.expectedSha256].
/// * [invalid]  — validation (on sight or on demand) found a defect with a
///   human-readable [TranslationModels.validationDetail]; the component is
///   excluded from `isInstalled` / `workerPaths()` so a broken file can
///   never blow up in the middle of inference (V10-4).
enum ModelState { absent, present, verified, invalid }

/// Accuracy / performance tier for models.
enum ModelTier {
  fast,
  high,
}

/// Logical kind of the model component.
enum ModelKind {
  detector,
  rec,
  mangaEncoder,
}

/// A heading of the model-management list.
///
/// The split is a property of the registry, not of the page: keeping it here
/// is what lets "do not list unpublished assets" have one implementation and
/// one test instead of three copies inside a `build()` (defect 2).
enum ModelSection {
  detection,
  recognition,
  highAndGpu;

  /// Whether [c] belongs under this heading. Identical to the predicate each
  /// section used while it was still written out in the page.
  bool contains(ModelComponent c) => switch (this) {
    ModelSection.detection => c.kind == ModelKind.detector,
    ModelSection.recognition =>
      c.kind != ModelKind.detector &&
          !c.requiresGpuEp &&
          c.tier != ModelTier.high,
    ModelSection.highAndGpu =>
      c.kind != ModelKind.detector &&
          (c.requiresGpuEp || c.tier == ModelTier.high),
  };
}

/// What one detection pass over a set of components found.
///
/// Produced by [TranslationModels.runDetectionPass] — the pass the
/// model-management page runs as soon as it opens, and again from its
/// "check every component" button.
class ModelSweepResult {
  const ModelSweepResult({
    required this.states,
    required this.failed,
    required this.rechecks,
  });

  /// Component id → the state each row should now render.
  final Map<String, ModelState> states;

  /// Ids judged [ModelState.invalid]: a file that is there and is wrong.
  ///
  /// [ModelState.absent] is deliberately NOT a failure. "Not installed" is a
  /// choice the row already shows as a Download button; raising the
  /// check-everything notice for it would train the user to ignore the notice.
  final List<String> failed;

  /// How many structure gates actually parsed a file during this pass.
  /// Zero means every answer came from the size@mtime ledger — the property
  /// that makes "detect as soon as the page opens" cheap enough to allow.
  final int rechecks;

  bool get hasFailures => failed.isNotEmpty;

  /// The human reason behind a row's failure, when it failed.
  String? detailOf(ModelComponent c) =>
      states[c.id] == ModelState.invalid
          ? TranslationModels.validationDetail(c)
          : null;
}

/// A downloadable model component (detector / OCR / translator).
class ModelComponent {
  const ModelComponent({
    required this.id,
    required this.files,
    required this.approxSizeBytes,
    this.tier = ModelTier.fast,
    this.kind = ModelKind.rec,
    this.requiresGpuEp = false,
    this.dictFrom,
    this.replaces,
    this.enabled = true,
    this.displayNameKey,
    this.blurbKey,
  });

  final String id;
  final List<ModelFile> files;

  /// Rough total download size, for display before downloading.
  final int approxSizeBytes;

  /// Accuracy/speed tier (fast / high).
  final ModelTier tier;

  /// Logical role of this model.
  final ModelKind kind;

  /// Whether this model requires a GPU execution provider (e.g. FP16 weights).
  /// If true, this component is never returned to workers when CPU EP is active.
  final bool requiresGpuEp;

  /// If this model shares a dictionary with another component, specify that
  /// component's ID here (e.g. 'ocr_zh' for 'ocr_zh_high').
  final String? dictFrom;

  /// Component ID in the same tier that this component replaces (for UI/pairing).
  final String? replaces;

  /// Whether this component is currently available or a placeholder/disabled.
  final bool enabled;

  /// Localization key for display name.
  final String? displayNameKey;

  /// One plain-language line under the name: what this model does, and when to
  /// pick it over its neighbour. The list used to show a name, a size and a
  /// validation verdict — enough to know a file is *there*, not enough to know
  /// whether to download it, which is why the high/GPU section read as a pile
  /// of variants nobody could rank.
  final String? blurbKey;

  String get directory =>
      FilePath.join(App.dataPath, 'translation_models', id);

  /// Whether [name] is one of this component's own files (a `dictFrom`
  /// dictionary does not count — it belongs to the owner).
  bool ownsFileNamed(String name) => files.any((f) => f.name == name);

  bool get isInstalled {
    // Plan §7.2.1 / V10-4: usability is state-gated, not "exists && > 0
    // bytes". `stateOf` runs the cheap synchronous structure check the
    // first time a file set is seen (and again whenever size/mtime
    // changed), so files dropped in from a network drive are judged before
    // they can reach an inference crash; `invalid` is excluded outright.
    // The 12 published upstream fp32 assets ride the "checksum matched"
    // (verified) branch or pass the structure gate as `present`; neither
    // route requires a session, and neither can regress a good install —
    // pinned by test/local_model_import_test.dart.
    if (!enabled) return false;
    final s = TranslationModels.stateOf(this);
    return s == ModelState.present || s == ModelState.verified;
  }

  String filePath(String name) {
    if (name == 'dict.txt' && dictFrom != null) {
      var dictComp = TranslationModels.find(dictFrom!);
      if (dictComp != null) {
        return dictComp.filePath('dict.txt');
      }
    }
    return FilePath.join(directory, name);
  }
}

/// Registry of every component the local translation pipeline can use.
///
/// All models are public, permissively licensed releases fetched directly
/// from their official repositories; nothing is bundled into the app so the
/// install stays lightweight until the user opts in.
abstract class TranslationModels {
  /// Text region detector (PP-OCRv5 mobile, DBNet). Language independent.
  ///
  /// v5-mobile replaced v4-mobile at the same size: the vendor's own detection
  /// benchmark puts mobile v4 at Hmean 63.8 and mobile v5 at 79.0 — 15 points
  /// for no extra bytes, so the old entry had no reason to exist. (PP-OCRv4
  /// server, the other half of the pair this project shipped, scores 69.2 —
  /// below the *mobile* v5 — which is why the server tier below is v5 too.)
  static const detector = ModelComponent(
    id: 'text_detector',
    approxSizeBytes: 4826518,
    tier: ModelTier.fast,
    kind: ModelKind.detector,
    displayNameKey: 'Text detector',
    blurbKey: 'Finds the text areas on each page before anything is read.',
    files: [
      ModelFile(
        'det.onnx',
        [
          '{hf}/PaddlePaddle/PP-OCRv5_mobile_det_onnx/resolve/main/inference.onnx',
        ],
        expectedSha256:
            'a431985659dc921974177a95adcfbb90fd9e51989a5e04d70d0b75f597b6e61d',
      ),
    ],
  );

  /// High-accuracy server text detector (PP-OCRv5 server, DBNet).
  ///
  /// Beats the v4 server model it replaced on every axis at once — Hmean 83.8
  /// against 69.2, and 383 ms against 586 ms on the vendor's CPU benchmark —
  /// while also being smaller (84 MB against 109 MB). It stays a deliberate
  /// choice rather than the default: roughly six times the mobile model's cost
  /// for about five points, which pays off on dense artwork and dirty scans and
  /// wastes time everywhere else.
  static const detectorHigh = ModelComponent(
    id: 'text_detector_high',
    approxSizeBytes: 88116791,
    tier: ModelTier.high,
    kind: ModelKind.detector,
    displayNameKey: 'High-accuracy text detector (server)',
    blurbKey:
        'The same job done more carefully: about 5 points more accurate and roughly six times slower.',
    files: [
      ModelFile(
        'det.onnx',
        [
          '{hf}/PaddlePaddle/PP-OCRv5_server_det_onnx/resolve/main/inference.onnx',
        ],
        expectedSha256:
            '10803475a591f7dc623e24670fb5752ec94d39a1f8cf069aac1b6f0ce19cfc85',
      ),
    ],
  );

  // `text_detector_manga` ("Manga text detector (bubble)") lived here as a
  // reserved row with no files, and shipped for months as a greyed entry
  // promising "Coming soon" — a promise this project never kept, listed beside
  // working downloads, which is exactly the kind of row a user cannot tell from
  // a broken feature. It is removed rather than re-labelled:
  //
  //  * the capability it advertised now exists and needs no model at all —
  //    `balloon.dart` separates two neighbouring bubbles on the page's own ink
  //    (a flood fill bounded by the outline), the approach both mainstream
  //    projects take;
  //  * a *learned* bubble detector is real and licensable (the research
  //    recommends `ogkalu/comic-text-and-bubble-detector`, RT-DETR-v2, 11.1 MB,
  //    Apache-2.0, one forward pass for bubble + text), but wiring it means a
  //    new pre/post-processing chain in Dart, and adding a model the app does
  //    not run would repeat the mistake this placeholder was.
  //
  // See doc/MODEL_RESEARCH_MANGA_MT.md for the survey and the licence traps
  // (six Ultralytics exports carry AGPL-3.0 *inside the file*, whatever their
  // repository page says).

  /// Japanese OCR (manga-ocr, vision encoder-decoder). The only reliable
  /// option for vertical manga text; large but worth it.
  static const ocrJa = ModelComponent(
    id: 'ocr_ja',
    approxSizeBytes: 461000000,
    tier: ModelTier.fast,
    kind: ModelKind.mangaEncoder,
    displayNameKey: 'Japanese OCR (manga)',
    blurbKey:
        'Reads Japanese, including the vertical lettering ordinary OCR cannot follow. Large, and the only reliable option for manga.',
    files: [
      ModelFile(
        'encoder.onnx',
        [
          '{release}/manga_encoder.onnx',
          '{hf}/mayocream/manga-ocr-onnx/resolve/main/encoder_model.onnx',
        ],
        expectedSha256:
            '15fa8155fe9bc1a7d25d9bb353debaa4def033d0174e907dbd2dd6d995def85f',
      ),
      ModelFile(
        'decoder.onnx',
        [
          '{release}/manga_decoder.onnx',
          '{hf}/mayocream/manga-ocr-onnx/resolve/main/decoder_model.onnx',
        ],
        expectedSha256:
            'ef7765261e9d1cdc34d89356986c2bbc2a082897f753a89605ae80fdfa61f5e8',
      ),
      ModelFile(
        'vocab.txt',
        [
          '{release}/manga_vocab.txt',
          '{hf}/mayocream/manga-ocr-onnx/resolve/main/vocab.txt',
        ],
        expectedSha256:
            '5cb5c5586d98a2f331d9f8828e4586479b0611bfba5d8c3b6dadffc84d6a36a3',
      ),
    ],
  );

  /// Japanese OCR FP16 variant (requires GPU EP).
  static const ocrJaFp16 = ModelComponent(
    id: 'ocr_ja_fp16',
    approxSizeBytes: 230000000,
    tier: ModelTier.fast,
    kind: ModelKind.mangaEncoder,
    requiresGpuEp: true,
    // Not published: the only source is {release}, which has no
    // `models` tag behind it, and there is no checksum either. Registered but
    // never produced (plan D-10 / decision R-3); re-enable through gate G5.
    enabled: false,
    replaces: 'ocr_ja',
    displayNameKey: 'Japanese OCR (FP16 GPU)',
    files: [
      ModelFile(
        'encoder.onnx',
        [
          '{release}/manga_encoder_fp16.onnx',
        ],
      ),
      ModelFile(
        'decoder.onnx',
        [
          '{release}/manga_decoder_fp16.onnx',
        ],
      ),
      ModelFile(
        'vocab.txt',
        [
          '{release}/manga_vocab.txt',
          '{hf}/mayocream/manga-ocr-onnx/resolve/main/vocab.txt',
        ],
        expectedSha256:
            '5cb5c5586d98a2f331d9f8828e4586479b0611bfba5d8c3b6dadffc84d6a36a3',
      ),
    ],
  );

  /// Chinese + Latin OCR (PP-OCRv4 mobile rec).
  static const ocrZh = ModelComponent(
    id: 'ocr_zh',
    approxSizeBytes: 10857958,
    tier: ModelTier.fast,
    kind: ModelKind.rec,
    displayNameKey: 'Chinese / Latin OCR',
    blurbKey:
        'Reads Chinese and Latin letters. Small and quick; the high variant below is for small or noisy text.',
    files: [
      ModelFile(
        'rec.onnx',
        [
          '{release}/rec_zh.onnx',
          '{hf}/SWHL/RapidOCR/resolve/main/PP-OCRv4/ch_PP-OCRv4_rec_infer.onnx',
        ],
        expectedSha256:
            '48fc40f24f6d2a207a2b1091d3437eb3cc3eb6b676dc3ef9c37384005483683b',
      ),
      ModelFile(
        'dict.txt',
        [
          'https://cdn.jsdelivr.net/gh/PaddlePaddle/PaddleOCR@v2.7.0/ppocr/utils/ppocr_keys_v1.txt',
          'https://raw.githubusercontent.com/PaddlePaddle/PaddleOCR/v2.7.0/ppocr/utils/ppocr_keys_v1.txt',
        ],
        expectedSha256:
            '28b2362ad4ab2dc38769aa72feb535e3a9ddb3fd2a7585a05920e6393b1dc7f7',
      ),
    ],
  );

  /// High-accuracy Chinese + Latin OCR (PP-OCRv4 server rec).
  static const ocrZhHigh = ModelComponent(
    id: 'ocr_zh_high',
    approxSizeBytes: 90530732,
    tier: ModelTier.high,
    kind: ModelKind.rec,
    dictFrom: 'ocr_zh',
    displayNameKey: 'High-accuracy Chinese / Latin OCR (server)',
    blurbKey:
        'The larger recognizer for the same languages. Bigger and slower for a modest gain — worth trying when the default misreads, not automatically better.',
    files: [
      ModelFile(
        'rec.onnx',
        [
          '{release}/rec_zh_server.onnx',
          '{hf}/SWHL/RapidOCR/resolve/main/PP-OCRv4/ch_PP-OCRv4_rec_server_infer.onnx',
        ],
        expectedSha256:
            '6a2676219be9907c7fc9cf61ebaa843bf2898777def567925b78886fcd90c07a',
      ),
    ],
  );

  /// Chinese + Latin OCR FP16 variant (requires GPU EP).
  static const ocrZhFp16 = ModelComponent(
    id: 'ocr_zh_fp16',
    approxSizeBytes: 5500000,
    tier: ModelTier.fast,
    kind: ModelKind.rec,
    requiresGpuEp: true,
    enabled: false, // unpublished {release}-only asset (D-10)
    replaces: 'ocr_zh',
    dictFrom: 'ocr_zh',
    displayNameKey: 'Chinese / Latin OCR (FP16 GPU)',
    files: [
      ModelFile(
        'rec.onnx',
        [
          '{release}/rec_zh_fp16.onnx',
        ],
      ),
    ],
  );

  /// High-accuracy Chinese + Latin OCR FP16 variant (requires GPU EP).
  static const ocrZhHighFp16 = ModelComponent(
    id: 'ocr_zh_high_fp16',
    approxSizeBytes: 45000000,
    tier: ModelTier.high,
    kind: ModelKind.rec,
    requiresGpuEp: true,
    enabled: false, // unpublished {release}-only asset (D-10)
    replaces: 'ocr_zh_high',
    dictFrom: 'ocr_zh',
    displayNameKey: 'High-accuracy Chinese / Latin OCR (FP16 GPU)',
    files: [
      ModelFile(
        'rec.onnx',
        [
          '{release}/rec_zh_server_fp16.onnx',
        ],
      ),
    ],
  );

  /// English OCR (PP-OCRv3 rec).
  static const ocrEn = ModelComponent(
    id: 'ocr_en',
    approxSizeBytes: 8967018,
    tier: ModelTier.fast,
    kind: ModelKind.rec,
    displayNameKey: 'English OCR',
    blurbKey: 'Reads English letters.',
    files: [
      ModelFile(
        'rec.onnx',
        [
          '{release}/rec_en.onnx',
          '{hf}/SWHL/RapidOCR/resolve/main/PP-OCRv3/en_PP-OCRv3_rec_infer.onnx',
        ],
        expectedSha256:
            'ef7abd8bd3629ae57ea2c28b425c1bd258a871b93fd2fe7c433946ade9b5d9ea',
      ),
      ModelFile(
        'dict.txt',
        [
          'https://cdn.jsdelivr.net/gh/PaddlePaddle/PaddleOCR@v2.7.0/ppocr/utils/en_dict.txt',
          'https://raw.githubusercontent.com/PaddlePaddle/PaddleOCR/v2.7.0/ppocr/utils/en_dict.txt',
        ],
        expectedSha256:
            '5662df9d2d03f0e8ca0d3b0649d6acbab904b6a14b3d3521463c71c37c668ce3',
      ),
    ],
  );

  /// Korean OCR (PP-OCR mobile rec).
  /// Korean OCR, model and dictionary from the same release.
  ///
  /// The previous pair could never pass validation: a PP-OCRv1-era recognizer
  /// (3689 output classes) shipped with PaddleOCR v2.7's `korean_dict.txt`
  /// (3688 lines), while the charset rule requires 3688 + 2 = 3690 — so Korean
  /// was flagged "Invalid" permanently. The row was in the list; the language
  /// was not usable. v5 publishes the dictionary *inside the model's own
  /// `inference.yml`, which makes the pairing exact rather than hopeful: 11945
  /// entries + blank + space = 11947 classes, and the model outputs 11947
  /// (counted from the real file, not from documentation). `ocr_dict.dart` is
  /// what allows a dictionary to be read out of that yml.
  static const ocrKo = ModelComponent(
    id: 'ocr_ko',
    approxSizeBytes: 13418787,
    tier: ModelTier.fast,
    kind: ModelKind.rec,
    displayNameKey: 'Korean OCR',
    blurbKey:
        'Reads Korean. Its dictionary travels inside the model file itself, which is what the validation checks.',
    files: [
      ModelFile(
        'rec.onnx',
        [
          '{hf}/PaddlePaddle/korean_PP-OCRv5_mobile_rec_onnx/resolve/main/inference.onnx',
        ],
        expectedSha256:
            '92f0b7785e64fc9090106a241cf4c1eb97472824558272751b88a2a4476d3a08',
      ),
      ModelFile(
        // The dictionary ships as the model's `inference.yml`; the reader
        // extracts its `character_dict` block (see `parseDictEntries`).
        'dict.txt',
        [
          '{hf}/PaddlePaddle/korean_PP-OCRv5_mobile_rec_onnx/resolve/main/inference.yml',
        ],
        expectedSha256:
            'f757fa1c40e99edcf27e9cce879b93eb2a51fa46f5ef39095689b8c37dd75998',
      ),
    ],
  );

  static const all = [
    detector,
    detectorHigh,
    ocrJa,
    ocrJaFp16,
    ocrZh,
    ocrZhHigh,
    ocrZhFp16,
    ocrZhHighFp16,
    ocrEn,
    ocrKo,
  ];

  static ModelComponent? find(String id) {
    for (var c in all) {
      if (c.id == id) return c;
    }
    return null;
  }

  // ------------------------------------------------------------------------
  // Settings-list visibility — decision gate G5
  // ------------------------------------------------------------------------

  /// A component that is registered, declares downloadable files, and is
  /// disabled: an **unpublished asset**.
  ///
  /// Exactly three are in this state — `ocr_ja_fp16`, `ocr_zh_fp16`,
  /// `ocr_zh_high_fp16`. For all three the only source is a `{release}` URL
  /// behind a `models` tag that has never existed, and the model files carry
  /// no `expected_sha256` either. Such a row is a dead end: nothing to
  /// download, nothing to drop in, nothing to click. The management page
  /// therefore leaves it out of the list entirely — the earlier "未发布 · 暂不
  /// 可用" label (and greyed-out row) was tried and rejected by users, who
  /// read it as a broken feature.
  ///
  /// **The condition for un-hiding one of these is decision gate G5, not a UI
  /// change:**
  /// ① the asset is actually published under the fork's `models` release
  ///    (`tool/model_export/publish.py` has run, `ASSETS.md` records it), and
  /// ② every file it declares carries an `expectedSha256`, so a download can
  ///    be verified against what upstream shipped.
  /// Only then does `enabled: true` belong on the component. Flipping that
  /// flag is the *whole* of the un-hide — this predicate keys off `enabled`,
  /// so no page edit is waiting to be remembered, and
  /// `test/model_dict_consistency_test.dart` pins both the membership and the
  /// fact that enabling alone re-lists the row.
  ///
  /// A disabled component with **no** files (`text_detector_manga`) is not an
  /// unpublished asset but a roadmap placeholder, and keeps its "Coming soon"
  /// row. `enabled` itself stays the data switch it always was: it gates
  /// `isInstalled` / `workerPaths` (V10-2) independently of what the list shows.
  static bool isUnpublishedAsset(ModelComponent c) =>
      !c.enabled && c.files.isNotEmpty;

  /// The components [section] should render: its own partition, minus
  /// unpublished assets. One place for the rule, so the page cannot drift
  /// back to listing dead rows.
  static List<ModelComponent> listedComponents(ModelSection section) => all
      .where((c) => section.contains(c) && !isUnpublishedAsset(c))
      .toList();

  // ------------------------------------------------------------------------
  // Detection pass (model-management page, plan §7.2.3 "行内状态")
  // ------------------------------------------------------------------------

  /// How often the FFI-free structure gate has actually parsed a component.
  ///
  /// The gate reads every declared input/output of a model out of the file's
  /// bytes; on a 343 MB encoder that is milliseconds, but it must still happen
  /// at most once per size@mtime fingerprint — which is the difference between
  /// "opening the page is free" and "opening the page re-reads 574 MB".
  static int get structureGateRuns => _structureGateRuns;

  static int _structureGateRuns = 0;

  @visibleForTesting
  static void resetStructureGateRunsForTest() => _structureGateRuns = 0;

  /// One cheap detection pass over [components].
  ///
  /// Nothing here hashes a file, opens an ORT session, or touches the network:
  /// [stateOf] answers from the verdict ledger while the size@mtime
  /// fingerprint holds, and otherwise runs the pure-Dart structure gate (red
  /// line R3 — no FFI on this isolate). That is what makes it safe to run the
  /// moment the page opens instead of waiting for a click, and what makes the
  /// second and hundredth open free ([ModelSweepResult.rechecks] == 0).
  ///
  /// Disabled components are skipped: [validateComponent] refuses them and
  /// that would report unpublished assets as failures.
  static ModelSweepResult runDetectionPass(
    Iterable<ModelComponent> components,
  ) {
    final states = <String, ModelState>{};
    final failed = <String>[];
    final before = _structureGateRuns;
    for (final c in components) {
      if (!c.enabled) continue;
      ModelState state;
      try {
        state = stateOf(c);
      } catch (e) {
        // A detection pass must never be the thing that breaks the page.
        Log.error('Translation Models', 'detection pass failed for ${c.id}: $e');
        continue;
      }
      states[c.id] = state;
      if (state == ModelState.invalid) failed.add(c.id);
    }
    return ModelSweepResult(
      states: states,
      failed: failed,
      rechecks: _structureGateRuns - before,
    );
  }

  // ------------------------------------------------------------------------
  // Validation ledger (plan §7.2.1 / §7.2.2, decision R-3)
  //
  // Component id -> last verdict, stamped with the fingerprint (size +
  // mtime, shared dictionary included) of the files it was computed for.
  // A fingerprint miss means "the user replaced something": the verdict is
  // recomputed by the FFI-free structure gate in local_model_import.dart
  // (red line R3: it never opens an ORT session, so it is safe on this
  // isolate). validateComponent() upgrades or downgrades entries after a
  // full pass (checksums, optional session probe).
  // ------------------------------------------------------------------------

  static final _verdicts = <String, _ModelVerdict>{};

  /// Current verification state of [c]'s local files. See [ModelState].
  static ModelState stateOf(ModelComponent c) {
    if (!c.enabled) return ModelState.absent;
    for (final f in c.files) {
      final file = File(c.filePath(f.name));
      if (!file.existsSync() || file.lengthSync() == 0) {
        if (_verdicts.remove(c.id) != null) invalidateReadyCache();
        return ModelState.absent;
      }
    }
    if (c.dictFrom != null) {
      final owner = find(c.dictFrom!);
      if (owner == null) return ModelState.invalid;
      final os = stateOf(owner);
      if (os == ModelState.absent || os == ModelState.invalid) {
        // A component whose shared dictionary is gone/broken is not usable
        // either, regardless of what its own files look like.
        if (_verdicts.remove(c.id) != null) invalidateReadyCache();
        return os;
      }
    }
    final fp = _componentFingerprint(c);
    final v = _verdicts[c.id];
    if (v != null && v.fingerprint == fp) return v.state;
    // Fingerprints differ (or nothing was ever recorded): this is the one
    // place a model file is re-parsed, and the counter is how the tests prove
    // that re-opening the page does not do it again.
    _structureGateRuns++;
    final check = checkComponentStructure(c);
    final problem = check.problem;
    if (problem != null) {
      Log.warning('Translation Models', '${c.id}: ${check.problem}');
      _verdicts[c.id] = _ModelVerdict(
        ModelState.invalid,
        detail: problem,
        fingerprint: fp,
      );
      invalidateReadyCache();
      return ModelState.invalid;
    }
    _verdicts[c.id] = _ModelVerdict(ModelState.present, fingerprint: fp);
    // A fresh gate result (files replaced since last check): the memoised
    // readiness must not outlive it.
    invalidateReadyCache();
    return ModelState.present;
  }

  /// Records a verdict from the validators (`validateComponent`, the
  /// download path). The fingerprint is taken now, so any later change to
  /// the files demotes the component back to "re-check me".
  static void recordVerdict(
    ModelComponent c,
    ModelState state, {
    String? detail,
  }) {
    _verdicts[c.id] = _ModelVerdict(
      state,
      detail: detail,
      fingerprint: _componentFingerprint(c),
    );
    invalidateReadyCache();
  }

  /// Human-readable reason behind an [ModelState.invalid] verdict, for the
  /// settings page inline status (plan §7.2.3: "Toast + 行内状态").
  static String? validationDetail(ModelComponent c) => _verdicts[c.id]?.detail;

  /// Forgets the verdict of [c] (files deleted etc.); it will be recomputed
  /// on the next [stateOf] call.
  static void forgetVerdictsFor(ModelComponent c) {
    _verdicts.remove(c.id);
    invalidateReadyCache();
  }

  @visibleForTesting
  static void clearVerdictsForTest() {
    _verdicts.clear();
    invalidateReadyCache();
  }

  static String _componentFingerprint(ModelComponent c) {
    final sb = StringBuffer();
    for (final f in c.files) {
      sb.write('|${_fileFingerprint(c.filePath(f.name))}');
    }
    if (c.dictFrom != null) {
      final owner = find(c.dictFrom!);
      // A shared dictionary is part of "this component's inputs" as far as
      // the C == N + 2 gate goes: replacing it must re-validate the model.
      if (owner != null) {
        sb.write('|dict:${_fileFingerprint(owner.filePath('dict.txt'))}');
      }
    }
    return sb.toString();
  }

  static String _fileFingerprint(String path) {
    try {
      final s = File(path).statSync();
      if (s.type == FileSystemEntityType.notFound) return 'missing';
      // FileStat exposes `modified` as a DateTime (there is no
      // modifiedMicrosecondsSinceEpoch); sync path on purpose — this runs
      // from isInstalled, which callers use from build() too.
      return '${s.size}@${s.modified.millisecondsSinceEpoch}';
    } catch (_) {
      return 'unknown';
    }
  }

  /// Current model tier configured in app settings.
  static ModelTier get currentModelTier =>
      appdata.settings['imageTranslationModelQuality'] == 'high'
          ? ModelTier.high
          : ModelTier.fast;

  /// The OCR component required for a source language.
  static ModelComponent ocrFor(String sourceLang, {ModelTier? tier}) {
    tier ??= currentModelTier;
    return switch (sourceLang) {
      'ja' => ocrJa,
      'ko' => ocrKo,
      'en' => ocrEn,
      _ => tier == ModelTier.high ? ocrZhHigh : ocrZh,
    };
  }

  static const _recLangs = ['zh', 'en', 'ko'];

  /// Rec input heights: 48 for the v3/v4 models, 32 for the older Korean one.
  static int recHeightFor(String lang) => lang == 'ko' ? 32 : 48;

  /// Model file paths for the worker isolate, containing only what is
  /// actually installed.
  ///
  /// CRITICAL (F3): When [gpuEpActive] is false, components with [requiresGpuEp]
  /// are NEVER returned, guaranteeing safe CPU fallback without crashing.
  /// Conservative "is a GPU execution provider even available here?" answer
  /// for the window before the first session exists: checks the loaded
  /// onnxruntime.dll for the DML/CUDA entry points. Never throws — a failed
  /// probe means "assume CPU", which is the safe direction.
  static bool gpuEpLikely() {
    try {
      final probe = probeOrtRuntime();
      return probe.hasDmlSymbol || probe.hasCudaSymbol;
    } catch (_) {
      return false;
    }
  }

  static WorkerModelPaths workerPaths({
    ModelTier? tier,
    bool? gpuEpActive,
  }) {
    tier ??= currentModelTier;
    // Three-stage resolution (plan D-3): the live report if a session has run,
    // otherwise a cheap symbol probe. The old two-stage version assumed CPU
    // whenever no report existed yet, so the *first* request on a GPU machine
    // always picked the fp32 components and the FP16/high path could never be
    // selected before something else happened to populate the report.
    gpuEpActive ??= TranslationWorker.instance.lastReport != null
        ? TranslationWorker.instance.lastReport!.active != OrtEpKind.cpu
        : gpuEpLikely();

    ModelComponent? pickRecZh() {
      final wantHigh = tier == ModelTier.high &&
          (ocrZhHigh.isInstalled || (gpuEpActive! && ocrZhHighFp16.isInstalled));
      if (wantHigh) {
        if (gpuEpActive! && ocrZhHighFp16.isInstalled) return ocrZhHighFp16;
        if (ocrZhHigh.isInstalled) return ocrZhHigh;
      }
      if (gpuEpActive! && ocrZhFp16.isInstalled) return ocrZhFp16;
      if (ocrZh.isInstalled) return ocrZh;
      return null;
    }

    var recModels = <String, String>{};
    var recDicts = <String, String>{};
    var recHeights = <String, int>{};

    for (var lang in _recLangs) {
      ModelComponent? comp;
      if (lang == 'zh') {
        comp = pickRecZh();
      } else {
        comp = ocrFor(lang, tier: tier);
        if (!comp.isInstalled) comp = null;
      }

      if (comp != null) {
        recModels[lang] = comp.filePath('rec.onnx');
        recDicts[lang] = comp.filePath('dict.txt');
        recHeights[lang] = recHeightFor(lang);
      }
    }

    ModelComponent? chosenJa;
    if (gpuEpActive && ocrJaFp16.isInstalled) {
      chosenJa = ocrJaFp16;
    } else if (ocrJa.isInstalled) {
      chosenJa = ocrJa;
    }

    ModelComponent chosenDet;
    if (tier == ModelTier.high && detectorHigh.isInstalled) {
      chosenDet = detectorHigh;
    } else {
      chosenDet = detector;
    }

    return WorkerModelPaths(
      detector: chosenDet.filePath('det.onnx'),
      jaEncoder: chosenJa?.filePath('encoder.onnx'),
      jaDecoder: chosenJa?.filePath('decoder.onnx'),
      jaVocab: chosenJa?.filePath('vocab.txt'),
      recModels: recModels,
      recDicts: recDicts,
      recHeights: recHeights,
    );
  }

  /// Components required for the current settings, for the model management
  /// UI. With 'auto' any one OCR component suffices, so only the detector is
  /// strictly required.
  static List<ModelComponent> requiredFor(String sourceLang, {ModelTier? tier}) {
    tier ??= currentModelTier;
    final det = (tier == ModelTier.high && detectorHigh.isInstalled)
        ? detectorHigh
        : detector;
    return [
      det,
      if (sourceLang != 'auto') ocrFor(sourceLang, tier: tier),
    ];
  }

  /// Whether detection + OCR can run for [sourceLang]. Translation-engine
  /// readiness (LLM configured / local model installed) is checked
  /// separately by the service.
  static bool isReadyFor(String sourceLang, {ModelTier? tier}) {
    tier ??= currentModelTier;
    final key = '$sourceLang@${tier.name}';
    return _readyCache[key] ??= _computeReady(sourceLang, tier: tier);
  }

  static bool _computeReady(String sourceLang, {required ModelTier tier}) {
    final detInstalled = (tier == ModelTier.high && detectorHigh.isInstalled) ||
        detector.isInstalled;
    if (!detInstalled) return false;

    bool jaInstalled() => ocrJa.isInstalled || ocrJaFp16.isInstalled;

    bool recLangInstalled(String lang) {
      if (lang == 'ja') return jaInstalled();
      if (lang == 'zh') {
        if (tier == ModelTier.high &&
            (ocrZhHigh.isInstalled || ocrZhHighFp16.isInstalled)) {
          return true;
        }
        return ocrZh.isInstalled || ocrZhFp16.isInstalled;
      }
      return ocrFor(lang, tier: tier).isInstalled;
    }

    if (sourceLang == 'auto') {
      return jaInstalled() || _recLangs.any(recLangInstalled);
    }
    return recLangInstalled(sourceLang);
  }

  static final _readyCache = <String, bool>{};

  static void invalidateReadyCache() => _readyCache.clear();
}

class ModelDownloadState {
  bool downloading = false;
  double progress = 0;
  int receivedBytes = 0;
  int? totalBytes;
  String? error;
}

/// One entry of the validation ledger: a [ModelState] stamped with the
/// fingerprint (size + mtime of every file that feeds the checks, shared
/// dictionary included) it was computed for.
class _ModelVerdict {
  const _ModelVerdict(this.state, {this.detail, required this.fingerprint});

  final ModelState state;
  final String? detail;
  final String fingerprint;
}

/// Downloads and manages local translation model files.
class TranslationModelStore with ChangeNotifier {
  TranslationModelStore._();

  static final instance = TranslationModelStore._();

  final _states = <String, ModelDownloadState>{};
  final _cancelTokens = <String, CancelToken>{};

  ModelDownloadState stateOf(ModelComponent component) {
    return _states.putIfAbsent(component.id, () => ModelDownloadState());
  }

  static String get hfEndpoint {
    var value = appdata.settings['imageTranslationHfEndpoint'];
    if (value is String && value.isNotEmpty) {
      return value;
    }
    return 'https://huggingface.co';
  }

  /// Whether this fork publishes its own model Release (`models`).
  ///
  /// Off by default: the tag has never existed, so treating `{release}` as a
  /// first-choice source only produced a 404 in front of every working mirror
  /// (plan D-10 / decision R-3). Turn it on once `tool/model_export/publish.py`
  /// has actually run and `ASSETS.md` records the published checksums.
  static bool get selfHostedSourceEnabled =>
      appdata.settings['imageTranslationSelfHostedSource'] == true;

  static String get releaseEndpoint =>
      'https://github.com/$kUpdateRepoOwner/$kUpdateRepoName/releases/download/models';

  /// Model downloads are large one-shot transfers, so this stays a bare [Dio]
  /// (no shared cache / cookie / log interceptors, no total timeout) rather
  /// than [AppDio]. The adapter is still the app's: dio's default `dart:io`
  /// one honored none of the proxy / DNS / certificate settings, which made
  /// every download fail behind a TLS-intercepting proxy while the rest of the
  /// app kept working.
  Dio _createDio() {
    return Dio(
      BaseOptions(
        connectTimeout: const Duration(seconds: 30),
        headers: {'User-Agent': 'venera/${App.version}'},
        followRedirects: true,
        maxRedirects: 10,
      ),
    )..httpClientAdapter = createAppHttpClientAdapter();
  }

  void _cleanStalePartFiles(String dirPath) {
    try {
      final dir = Directory(dirPath);
      if (!dir.existsSync()) return;
      final now = DateTime.now();
      for (var entry in dir.listSync()) {
        if (entry is File && entry.path.endsWith('.part')) {
          final stat = entry.statSync();
          if (now.difference(stat.modified).inHours > 24) {
            entry.deleteIgnoreError();
          }
        }
      }
    } catch (_) {}
  }

  Future<void> download(ModelComponent component) async {
    var state = stateOf(component);
    if (state.downloading || component.isInstalled) {
      return;
    }
    state
      ..downloading = true
      ..error = null
      ..progress = 0
      ..receivedBytes = 0
      ..totalBytes = component.approxSizeBytes;
    notifyListeners();
    var cancelToken = CancelToken();
    _cancelTokens[component.id] = cancelToken;
    var dio = _createDio();
    try {
      Directory(component.directory).createSync(recursive: true);
      _cleanStalePartFiles(component.directory);

      // Progress is reported across the whole component, weighted by each
      // file's share of the approximate total.
      var finishedBytes = 0;
      for (var file in component.files) {
        var target = File(component.filePath(file.name));
        if (target.existsSync() && target.lengthSync() > 0) {
          finishedBytes += target.lengthSync();
          continue;
        }
        var temp = File('${target.path}.part');
        Object? lastError;
        var ok = false;
        for (var rawUrl in file.urls) {
          // `{release}` is this fork's own `models` Release, which may not
          // exist. When the self-hosted source is off, the URL is dropped from
          // the chain rather than tried first: all 20 assets list it first, so
          // every download otherwise begins with a guaranteed 404 (plan D-10).
          if (!selfHostedSourceEnabled && rawUrl.startsWith('{release}')) {
            continue;
          }
          final url = rawUrl
              .replaceFirst('{hf}', hfEndpoint)
              .replaceFirst('{release}', releaseEndpoint);
          try {
            await dio.download(
              url,
              temp.path,
              cancelToken: cancelToken,
              onReceiveProgress: (count, total) {
                state.receivedBytes = finishedBytes + count;
                var estimated = component.approxSizeBytes;
                state.progress = (state.receivedBytes / estimated).clamp(
                  0.0,
                  1.0,
                );
                notifyListeners();
              },
            );

            // Verify checksum if expectedSha256 is configured
            if (file.expectedSha256 != null) {
              final actualSha =
                  (await sha256.bind(temp.openRead()).first).toString();
              if (actualSha.toLowerCase() !=
                  file.expectedSha256!.toLowerCase()) {
                temp.deleteIgnoreError();
                lastError = Exception(
                  'Checksum mismatch for ${file.name}: expected ${file.expectedSha256}, got $actualSha',
                );
                Log.warning(
                  'Translation Models',
                  'Checksum mismatch for $url: expected ${file.expectedSha256}, got $actualSha',
                );
                continue;
              }
            }

            temp.renameSync(target.path);
            ok = true;
            break;
          } catch (e) {
            temp.deleteIgnoreError();
            if (cancelToken.isCancelled) {
              rethrow;
            }
            lastError = e;
            Log.warning(
              'Translation Models',
              'Download failed from $url, trying next mirror: $e',
            );
          }
        }
        if (!ok) {
          throw lastError ?? Exception('Download failed');
        }
        finishedBytes += target.lengthSync();
      }
      state.progress = 1;
      // §7.3: downloaded files run the same import validation as manually
      // dropped ones. Per-file checksums were already enforced on the
      // `.part` file above, so what happens here is the structure / dict
      // cross-check plus the verdict record the gate reads.
      final verdict = await validateComponent(component);
      if (!verdict.ok) {
        state.error = verdict.reason;
        Log.error(
          'Translation Models',
          'Post-download validation failed for ${component.id}: ${verdict.reason}',
        );
      }
    } catch (e) {
      if (!cancelToken.isCancelled) {
        state.error = e.toString();
        Log.error('Translation Models', 'Failed to download ${component.id}', e);
      }
    } finally {
      dio.close();
      _cancelTokens.remove(component.id);
      state.downloading = false;
      TranslationModels.invalidateReadyCache();
      notifyListeners();
    }
  }

  void cancelDownload(ModelComponent component) {
    _cancelTokens[component.id]?.cancel();
  }

  Future<void> delete(ModelComponent component) async {
    cancelDownload(component);
    var dir = Directory(component.directory);
    if (dir.existsSync()) {
      await dir.deleteIgnoreError(recursive: true);
    }
    _states.remove(component.id);
    TranslationModels.forgetVerdictsFor(component);
    TranslationModels.invalidateReadyCache();
    notifyListeners();
  }

  /// Total disk usage of installed model files.
  int get installedSizeBytes {
    var root = Directory(FilePath.join(App.dataPath, 'translation_models'));
    if (!root.existsSync()) return 0;
    var total = 0;
    for (var entity in root.listSync(recursive: true)) {
      if (entity is File) {
        total += entity.lengthSync();
      }
    }
    return total;
  }
}
