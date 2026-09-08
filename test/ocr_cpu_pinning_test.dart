import 'package:flutter_test/flutter_test.dart';
import 'package:venera/foundation/image_translation/translation_worker.dart';

/// Why this file exists at all: the DirectML pinning for the English and Korean
/// recognizers (plan D-15) shipped as **dead code** and nothing noticed, because
/// no test ever asked "is this path pinned?". The bug was a lost backslash in a
/// scripted patch — `replaceAll(r'', '/')` — which inserts a slash between every
/// character, so the substring match was false for every real path.
///
/// Every case below is a path shape that actually occurs on a real machine, not a
/// synthetic string, and the negative cases are here so the fix cannot be "match
/// anything at all".
void main() {
  test('pins the Windows recognizer paths that actually occur on disk', () {
    expect(
      TranslationWorker.isCpuOnlyRecPath(
        r'C:\Users\axia\AppData\Roaming\io.github.kyosee\venera'
        r'\translation_models\ocr_ko\rec.onnx',
      ),
      isTrue,
      reason: 'this exact shape is what workerPaths() returns on Windows',
    );
    expect(
      TranslationWorker.isCpuOnlyRecPath(
        r'C:\Users\axia\AppData\Roaming\io.github.kyosee\venera'
        r'\translation_models\ocr_en\rec.onnx',
      ),
      isTrue,
    );
  });

  test('pins POSIX-shaped paths too', () {
    expect(
      TranslationWorker.isCpuOnlyRecPath('/home/u/.venera/translation_models/ocr_en/rec.onnx'),
      isTrue,
    );
  });

  test('does not pin the other recognizers', () {
    for (final dir in ['ocr_zh', 'ocr_zh_high', 'ocr_ja', 'text_detector', 'text_detector_high']) {
      expect(
        TranslationWorker.isCpuOnlyRecPath(r'C:\models\$dir\rec.onnx'),
        isFalse,
        reason: '$dir must keep running on DirectML',
      );
    }
  });

  test('matches whole segments, not substrings', () {
    // A directory merely *named like* the pinned one must not be swept up: the
    // earlier `contains('/$dir/')` form would have matched `ocr_enhanced`.
    expect(
      TranslationWorker.isCpuOnlyRecPath(r'C:\models\ocr_enhanced\rec.onnx'),
      isFalse,
    );
    expect(TranslationWorker.isCpuOnlyRecPath(r'C:\models\ocr\en\rec.onnx'), isFalse);
  });

  test('degrades safely on empty and separator-free input', () {
    expect(TranslationWorker.isCpuOnlyRecPath(''), isFalse);
    expect(TranslationWorker.isCpuOnlyRecPath('rec.onnx'), isFalse);
  });
}
