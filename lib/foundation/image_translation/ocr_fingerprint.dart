import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:venera/foundation/image_translation/ort_capabilities.dart';
import 'package:venera/foundation/image_translation/translation_models.dart';
import 'package:venera/foundation/image_translation/translation_worker.dart';

/// Everything that changes what OCR *produces*.
///
/// The intermediate OCR cache (`translated_ocr_page`) is keyed by the page's
/// cache key, which embeds only the language pair and a hand-written
/// generation number. Switching 极速/高精, swapping a model file, or moving
/// between CPU and a GPU EP therefore keeps serving the *old* recognition
/// result — the user pays the download and sees no change (plan D-2).
///
/// This fingerprint is the missing dimension. It is stored as a column and
/// matched on read, so a stale row is simply not selected: translations and
/// rendered pages the user already has are never invalidated by it.
class OcrInputs {
  const OcrInputs({
    required this.schemaGen,
    required this.effectiveLang,
    required this.tier,
    required this.epKind,
    required this.componentStamps,
  });

  /// Bump whenever detection/recognition/padding semantics change in code.
  /// Shared with `TranslationConfig.cachePrefix` so the two cannot drift.
  final int schemaGen;

  /// The language actually used — for `auto`, the resolved value, not the
  /// configured one (a language-lock flip changes the model, not the key).
  final String effectiveLang;

  final ModelTier tier;
  final OrtEpKind epKind;

  /// `id@stamp` for each component actually selected, where stamp is the
  /// SHA-256 prefix when known and the file size otherwise.
  final List<String> componentStamps;

  @override
  String toString() =>
      'gen=$schemaGen lang=$effectiveLang tier=${tier.name} ep=${epKind.name} '
      'models=${(<String>[...componentStamps]..sort()).join(",")}';
}

/// Stable 16-hex fingerprint. Pure: same inputs, same output, on every
/// platform and every run. Component order is normalised so a registry
/// reshuffle cannot masquerade as a model change.
String ocrFingerprintOf(OcrInputs inputs) =>
    sha1.convert(utf8.encode(inputs.toString())).toString().substring(0, 16);

/// Stamps for the model set currently selected in [paths].
///
/// File size is used when no checksum is available; that is weaker (two
/// different builds of the same size collide) but it is what the registry
/// currently guarantees, and it still catches the common case: a different
/// model file for the same component.
List<String> componentStampsFor(WorkerModelPaths paths) {
  final out = <String>['det:${_stampFile(paths.detector)}'];
  if (paths.jaEncoder != null) {
    out.add('jaEnc:${_stampFile(paths.jaEncoder!)}');
  }
  if (paths.jaDecoder != null) {
    out.add('jaDec:${_stampFile(paths.jaDecoder!)}');
  }
  for (final lang in (paths.recModels.keys.toList()..sort())) {
    out.add('rec-$lang:${_stampFile(paths.recModels[lang]!)}');
    final dict = paths.recDicts[lang];
    if (dict != null) out.add('dict-$lang:${_stampFile(dict)}');
  }
  return out;
}

String _stampFile(String path) {
  try {
    final file = File(path);
    if (!file.existsSync()) return 'missing';
    return '${file.lengthSync()}';
  } catch (_) {
    return 'unreadable';
  }
}
