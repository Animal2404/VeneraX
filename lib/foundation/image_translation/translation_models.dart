import 'dart:async';

import 'package:crypto/crypto.dart';
import 'package:dio/dio.dart';
import 'package:flutter/foundation.dart';
import 'package:venera/foundation/app.dart';
import 'package:venera/foundation/appdata.dart';
import 'package:venera/foundation/consts.dart';
import 'package:venera/foundation/image_translation/ort_capabilities.dart';
import 'package:venera/foundation/image_translation/translation_worker.dart';
import 'package:venera/foundation/log.dart';
import 'package:venera/network/app_dio_io.dart';
import 'package:venera/utils/io.dart';

/// A single downloadable file of a model component. [urls] is a fallback
/// chain: mirrors are tried in order, so a blocked host does not make the
/// component impossible to install.
class ModelFile {
  const ModelFile(
    this.name,
    this.urls, {
    this.sha256BytesHint,
    this.expectedSha256,
  });

  /// File name inside the component directory.
  final String name;

  /// Candidate URLs. `{hf}` is replaced with the configured HuggingFace
  /// endpoint (official or mirror) at download time.
  /// `{release}` is replaced with the GitHub Releases download URL for models.
  final List<String> urls;

  /// Optional expected file size hint in bytes.
  final int? sha256BytesHint;

  /// Optional expected SHA-256 checksum (hex string, case-insensitive).
  final String? expectedSha256;
}

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

  String get directory =>
      FilePath.join(App.dataPath, 'translation_models', id);

  bool get isInstalled {
    if (!enabled) return false;
    for (var file in files) {
      var f = File(FilePath.join(directory, file.name));
      if (!f.existsSync() || f.lengthSync() == 0) {
        return false;
      }
    }
    if (dictFrom != null) {
      var dictComp = TranslationModels.find(dictFrom!);
      if (dictComp == null || !dictComp.isInstalled) {
        return false;
      }
    }
    return true;
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
  /// Text region detector (PP-OCRv4 mobile, DBNet). Language independent.
  static const detector = ModelComponent(
    id: 'text_detector',
    approxSizeBytes: 4745517,
    tier: ModelTier.fast,
    kind: ModelKind.detector,
    displayNameKey: 'Text detector',
    files: [
      ModelFile(
        'det.onnx',
        [
          '{release}/det.onnx',
          '{hf}/SWHL/RapidOCR/resolve/main/PP-OCRv4/ch_PP-OCRv4_det_infer.onnx',
        ],
        expectedSha256:
            'd2a7720d45a54257208b1e13e36a8479894cb74155a5efe29462512d42f49da9',
      ),
    ],
  );

  /// High-accuracy server text detector (PP-OCRv4 server, DBNet).
  static const detectorHigh = ModelComponent(
    id: 'text_detector_high',
    approxSizeBytes: 113352104,
    tier: ModelTier.high,
    kind: ModelKind.detector,
    displayNameKey: 'High-accuracy text detector (server)',
    files: [
      ModelFile(
        'det.onnx',
        [
          '{release}/det_server.onnx',
          '{hf}/SWHL/RapidOCR/resolve/main/PP-OCRv4/ch_PP-OCRv4_det_server_infer.onnx',
        ],
        expectedSha256:
            'cfa39a3f298f6d3fc71789834d15da36d11a6c59b489fc16ea4733728012f786',
      ),
    ],
  );

  /// Reserved: Manga-specific text detector.
  static const detectorManga = ModelComponent(
    id: 'text_detector_manga',
    approxSizeBytes: 10000000,
    tier: ModelTier.fast,
    kind: ModelKind.detector,
    enabled: false,
    displayNameKey: 'Manga text detector (bubble)',
    files: [],
  );

  /// Japanese OCR (manga-ocr, vision encoder-decoder). The only reliable
  /// option for vertical manga text; large but worth it.
  static const ocrJa = ModelComponent(
    id: 'ocr_ja',
    approxSizeBytes: 461000000,
    tier: ModelTier.fast,
    kind: ModelKind.mangaEncoder,
    displayNameKey: 'Japanese OCR (manga)',
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
  static const ocrKo = ModelComponent(
    id: 'ocr_ko',
    approxSizeBytes: 3290650,
    tier: ModelTier.fast,
    kind: ModelKind.rec,
    displayNameKey: 'Korean OCR',
    files: [
      ModelFile(
        'rec.onnx',
        [
          '{release}/rec_ko.onnx',
          '{hf}/SWHL/RapidOCR/resolve/main/PP-OCRv1/korean_mobile_v2.0_rec_infer.onnx',
        ],
        expectedSha256:
            'b6558500138b43b46a4941957fb8c918546dae5fb0e71718536f1883acc80faf',
      ),
      ModelFile(
        'dict.txt',
        [
          'https://cdn.jsdelivr.net/gh/PaddlePaddle/PaddleOCR@v2.7.0/ppocr/utils/dict/korean_dict.txt',
          'https://raw.githubusercontent.com/PaddlePaddle/PaddleOCR/v2.7.0/ppocr/utils/dict/korean_dict.txt',
        ],
        expectedSha256:
            'aa1fdc8ae8f7cd40a0ec4edb472eb0421e11427e6ccfee9915440742c18b0a20',
      ),
    ],
  );

  static const all = [
    detector,
    detectorHigh,
    detectorManga,
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
