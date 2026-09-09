import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

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
  /// SHA-256 prefix of the file's content — or the sentinel `missing` /
  /// `unreadable` when no bytes could be read (see [_stampFile]). A sentinel is
  /// never shaped like a hash, so it cannot collide with a real stamp.
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
/// Each stamp is the content hash of the file — see [_stampFile] for what
/// "content" means for a file too large to hash whole, and for why a length
/// stamp is not a fingerprint of a model at all.
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

/// Bytes read per sample point by [_stampFile].
///
/// Sized to hold the ONNX file header (a protobuf header, the producer/opset
/// strings) plus the leading graph nodes: the part that differs between two
/// builds of the same size long before the weight tensors do.
const int _stampSampleBytes = 64 * 1024;

/// How many evenly spaced sample points a large file is read at. 1 is the
/// head, [kStampSamples] the tail — see [_stampFile].
const int kStampSamples = 4;

/// Stamps [path] with the SHA-256 of its **content**, not its length.
///
/// A length stamp is not a fingerprint of a model: two builds, two
/// quantisations or two different models of the same component routinely have
/// the same byte count, and then the stored stamp does not change, the OCR
/// fingerprint does not change, and `translated_ocr_page` keeps serving
/// recognition produced by the file that was there *before* the user replaced
/// it — with no line in the log to say so. Hashing the content is what makes
/// "the model was swapped" observable at all.
///
/// Cost and sampling: a file no larger than [kStampSampleBytes] is hashed
/// whole. A larger one is read at [kStampSamples] evenly spaced offsets
/// (offset 0 .. length - sampleBytes), [kStampSampleBytes] bytes each, and
/// those bytes plus the file length are hashed as one buffer. The length is
/// folded in so a file that was only truncated cannot hash to the same digest
/// as the file it was truncated from.
///
/// Collision risk, stated plainly:
///  * accidental — a build that differs in any sampled region, or in its
///    length, is a different stamp. SHA-256's own collision probability over
///    distinct inputs is ~2^-128, i.e. not a risk. The risk is **coverage**,
///    not hashing: two files that agree byte-for-byte at all four sample
///    windows and in length but differ somewhere in between (a single weight
///    edited mid-file, a build whose only change is a late graph node) collide
///    by construction. That is a far narrower hole than "same length", which
///    is what shipped before — but it is a hole, and it is why the sample
///    windows are spread across the file rather than clustered at the head.
///  * adversarial — a deliberately crafted file can be made to match the
///    sample windows. Out of scope: the threat model is the user replacing
///    their own model files, not an attacker shipping one.
///
/// `missing` and `unreadable` are kept as their own sentinels: they are not
/// hashes and can never collide with one — a stamp is either 16 lowercase hex
/// digits, or one of those two words.
///
/// The two sentinels mean different things and must not be conflated:
/// `missing` is "nothing exists at this path" (the model is not installed),
/// `unreadable` is "something is there but its bytes could not be read" — a
/// transient IO failure, a deleted-under-us file, a path that is not a regular
/// file at all. A transient failure reported as `missing` would say the user
/// has no model, and the caller cannot tell that from a first-run install.
///
/// USER-VISIBLE COST: this stamp feeds [ocrFingerprintOf], which is the match
/// key of the OCR intermediate cache. Changing it at all — including this
/// change from length to content — changes the fingerprint, so **every
/// existing `translated_ocr_page` row stops matching and those pages are
/// re-recognized once** (GPU/CPU work, no LLM request: the durable text
/// results and rendered images are keyed by `TranslationConfig.cachePrefix`
/// and are not touched). That re-run is the intended price of the fix: the
/// alternative is silently reusing recognition produced by a file that may no
/// longer be installed.
String _stampFile(String path) {
  try {
    // The two sentinels are decided here, before any read is attempted, and
    // they are decided from the entity type rather than from "did the read
    // throw". A path that does not exist is `missing`; a path that exists as
    // anything other than a regular file (a directory, a device, a link to
    // nowhere) is `unreadable` — it is present, so "the user has no model" is
    // the wrong thing to say about it, and hashing it is not possible.
    final stat = File(path).statSync();
    if (stat.type == FileSystemEntityType.notFound) return 'missing';
    if (stat.type != FileSystemEntityType.file) return 'unreadable';
    final file = File(path);
    final digest = sha256.convert(_sampleBytes(file, stat.size));
    return digest.toString().substring(0, 16);
  } catch (_) {
    return 'unreadable';
  }
}

/// The bytes [_stampFile] hashes: the whole file when small, otherwise
/// [kStampSamples] evenly spaced windows followed by the file length.
Uint8List _sampleBytes(File file, int length) {
  if (length <= _stampSampleBytes) {
    return Uint8List.fromList(file.readAsBytesSync());
  }
  final handle = file.openSync();
  try {
    final step = (length - _stampSampleBytes) ~/ (kStampSamples - 1);
    final sampled = <int>[];
    for (var i = 0; i < kStampSamples; i++) {
      final offset = i == kStampSamples - 1
          ? length - _stampSampleBytes
          : i * step;
      handle.setPositionSync(offset);
      sampled.addAll(handle.readSync(_stampSampleBytes));
    }
    // Length is appended rather than prefixed so the sample layout stays
    // readable in a dump: the first 64 KiB are still the ONNX header.
    final bytes = Uint8List(sampled.length + 8);
    bytes.setRange(0, sampled.length, sampled);
    ByteData.sublistView(bytes).setInt64(sampled.length, length);
    return bytes;
  } finally {
    handle.closeSync();
  }
}
