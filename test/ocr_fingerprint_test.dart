import 'package:flutter_test/flutter_test.dart';
import 'package:venera/foundation/image_translation/ocr_fingerprint.dart';
import 'package:venera/foundation/image_translation/ort_capabilities.dart';
import 'package:venera/foundation/image_translation/translation_models.dart';

/// The OCR cache is keyed by page, so the fingerprint is the *only* thing that
/// makes "I switched to the high-accuracy model" mean "the text will actually
/// be re-recognised". If this function stops reacting to a dimension that
/// changes recognition, the feature silently stops working (plan D-2).
void main() {
  OcrInputs base({
    int gen = 2,
    String lang = 'ja',
    ModelTier tier = ModelTier.fast,
    OrtEpKind ep = OrtEpKind.directml,
    List<String> stamps = const ['det:4745517', 'rec-zh:10857958'],
  }) => OcrInputs(
    schemaGen: gen,
    effectiveLang: lang,
    tier: tier,
    epKind: ep,
    componentStamps: stamps,
  );

  test('is stable for identical inputs', () {
    expect(ocrFingerprintOf(base()), ocrFingerprintOf(base()));
    expect(ocrFingerprintOf(base()).length, 16);
    expect(ocrFingerprintOf(base()), matches(r'^[0-9a-f]{16}$'));
  });

  test('changes when any recognition-affecting dimension changes', () {
    final anchor = ocrFingerprintOf(base());
    expect(ocrFingerprintOf(base(tier: ModelTier.high)), isNot(anchor));
    expect(ocrFingerprintOf(base(ep: OrtEpKind.cpu)), isNot(anchor));
    expect(ocrFingerprintOf(base(lang: 'zh')), isNot(anchor));
    expect(ocrFingerprintOf(base(gen: 3)), isNot(anchor));
    expect(
      ocrFingerprintOf(
        base(stamps: const ['det:4745517', 'rec-zh:90530732']),
      ),
      isNot(anchor),
      reason: 'a different model file for the same component must invalidate',
    );
  });

  test('ignores component ordering', () {
    expect(
      ocrFingerprintOf(
        base(stamps: const ['rec-zh:10857958', 'det:4745517']),
      ),
      ocrFingerprintOf(base()),
      reason: 'a registry reshuffle is not a model change',
    );
  });

  test('distinguishes the resolved language from the configured one', () {
    // `auto` must never reach this function; the caller resolves it first.
    // A lock flip ja -> en therefore has to change the fingerprint.
    expect(
      ocrFingerprintOf(base(lang: 'en')),
      isNot(ocrFingerprintOf(base(lang: 'ja'))),
    );
  });
}
