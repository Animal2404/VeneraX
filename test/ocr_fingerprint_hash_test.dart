import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:venera/foundation/image_translation/ocr_fingerprint.dart';
import 'package:venera/foundation/image_translation/ort_capabilities.dart';
import 'package:venera/foundation/image_translation/translation_models.dart';
import 'package:venera/foundation/image_translation/translation_worker.dart';

/// The OCR intermediate cache (`translated_ocr_page`) is matched on this
/// fingerprint, and the fingerprint carries one stamp per model file. While a
/// stamp was the file's *length*, replacing a model with a different build of
/// the same size left the fingerprint identical, so every page kept being
/// served recognition produced by the file that was no longer installed — the
/// "old translation keeps matching forever" bug. These tests pin the stamp to
/// the file's **content**.
///
/// They are the only place the sampling rule is asserted: the rest of the
/// fingerprint's dimensions are covered by `ocr_fingerprint_test.dart`.
void main() {
  late Directory root;

  setUp(() async {
    root = await Directory.systemTemp.createTemp('venera-ocr-stamp');
  });

  tearDown(() async {
    if (root.existsSync()) await root.delete(recursive: true);
  });

  /// Writes [bytes] under a fresh name and returns its path.
  String write(String name, List<int> bytes) {
    final file = File('${root.path}/$name');
    file.writeAsBytesSync(bytes);
    return file.path;
  }

  /// The detector stamp of a one-detector path set.
  String detStamp(String detPath) => componentStampsFor(
    WorkerModelPaths(detector: detPath),
  ).single;

  String hashOf(String path) => detStamp(path).substring('det:'.length);

  bool looksLikeHash(String stamp) =>
      RegExp(r'^[0-9a-f]{16}$').hasMatch(stamp);

  group('a stamp is a content hash, not a length', () {
    test('same size, different bytes ⇒ different stamp (the bug)', () {
      final a = write('a.onnx', List<int>.filled(4096, 0x41));
      final b = write('b.onnx', List<int>.filled(4096, 0x42));
      expect(File(a).lengthSync(), File(b).lengthSync());

      expect(
        detStamp(a),
        isNot(detStamp(b)),
        reason: 'this is exactly the case that used to collide',
      );
      expect(looksLikeHash(hashOf(a)), isTrue);
    });

    test('identical bytes ⇒ identical stamp', () {
      final a = write('a.onnx', List<int>.generate(1000, (i) => i % 251));
      final b = write('b.onnx', List<int>.generate(1000, (i) => i % 251));
      expect(detStamp(a), detStamp(b));
    });

    test('a one-byte change anywhere is a different stamp — including in the '
        'middle of a large file', () {
      const size = 200 * 1024; // larger than one 64 KiB sample window
      final base = Uint8List(size);
      for (var i = 0; i < size; i++) {
        base[i] = i % 256;
      }
      final head = Uint8List.fromList(base);
      final middle = Uint8List.fromList(base);
      final tail = Uint8List.fromList(base);
      head[0] ^= 0xFF;
      middle[size ~/ 2] ^= 0xFF;
      tail[size - 1] ^= 0xFF;

      final anchor = hashOf(write('base.onnx', base));
      expect(hashOf(write('head.onnx', head)), isNot(anchor));
      expect(
        hashOf(write('mid.onnx', middle)),
        isNot(anchor),
        reason: 'the sample windows are spread across the file, not clustered '
            'at the head',
      );
      expect(hashOf(write('tail.onnx', tail)), isNot(anchor));
    });

    test('truncating a large file changes the stamp even when the sampled '
        'windows are unchanged', () {
      // The length is folded into the hash, so a file that only lost its tail
      // cannot keep the old stamp by matching every sample window.
      const size = 200 * 1024;
      final base = Uint8List(size);
      final shorter = Uint8List(size - 1)..setRange(0, size - 1, base);
      expect(
        hashOf(write('full.onnx', base)),
        isNot(hashOf(write('short.onnx', shorter))),
      );
    });

    test('a small file is hashed whole, not sampled', () {
      // Two files below the sample size differ only in their last byte: a
      // whole-file hash must see it. (A sampled hash would too here, but this
      // pins the "no larger than one window ⇒ whole file" rule.)
      final a = write('a.onnx', List<int>.filled(64, 1));
      final b = write('b.onnx', List<int>.filled(64, 1)..[63] = 2);
      expect(hashOf(a), isNot(hashOf(b)));
    });
  });

  group('missing and unreadable are their own sentinels', () {
    test('a path that does not exist stamps as missing', () {
      expect(detStamp('${root.path}/nope.onnx'), 'det:missing');
    });

    test('a file deleted after being written stamps as missing, not unreadable '
        '— nothing is left at the path', () {
      final path = write('gone.onnx', List<int>.filled(16, 7));
      File(path).deleteSync();
      expect(detStamp(path), 'det:missing');
    });

    test('a path that cannot be read stamps as unreadable, and is not '
        'confused with missing', () {
      // A directory is the portable "exists, but has no bytes to hash" path:
      // it is a real entry, and every platform refuses to read it as a file
      // (Windows denies the open, POSIX raises EISDIR). A *deleted* path is
      // deliberately not used here — nothing exists at it any more, so
      // `missing` is the honest stamp and a test that asked for `unreadable`
      // would be asserting a distinction the filesystem cannot make.
      final path = Directory('${root.path}/unreadable').createSync().path;
      expect(detStamp(path), 'det:unreadable');
      expect(detStamp(path), isNot('det:missing'));
      expect(looksLikeHash(hashOf(path)), isFalse);
    });

    test('a sentinel never collides with a real hash', () {
      final real = detStamp(write('real.onnx', List<int>.filled(16, 3)));
      expect(real, isNot('det:missing'));
      expect(real, isNot('det:unreadable'));
      // `real` is the whole stamp ('det:<hash>'); the shape being pinned is
      // the hash half. Comparing the prefixed string against a bare-hex regex
      // could never pass, whatever the file contained.
      expect(looksLikeHash(hashOf(real)), isTrue);
    });
  });

  group('every component is stamped by content', () {
    test('a same-size rec-model swap changes that component\'s stamp', () {
      final recA = write('rec_a.onnx', List<int>.filled(2048, 0x10));
      final recB = write('rec_b.onnx', List<int>.filled(2048, 0x20));
      final det = write('det.onnx', List<int>.filled(64, 0));

      final stampsA = componentStampsFor(
        WorkerModelPaths(detector: det, recModels: {'ja': recA}),
      );
      final stampsB = componentStampsFor(
        WorkerModelPaths(detector: det, recModels: {'ja': recB}),
      );

      expect(stampsA, contains('det:${hashOf(det)}'));
      final jaA = stampsA.firstWhere((s) => s.startsWith('rec-ja:'));
      final jaB = stampsB.firstWhere((s) => s.startsWith('rec-ja:'));
      expect(jaA, isNot(jaB));
      expect(
        stampsA.firstWhere((s) => s.startsWith('det:')),
        stampsB.firstWhere((s) => s.startsWith('det:')),
        reason: 'only the swapped component moves',
      );
    });

    test('the dictionary is stamped too, and it is a separate stamp', () {
      final dict = write('dict.txt', List<int>.filled(128, 0x2E));
      final stamps = componentStampsFor(
        WorkerModelPaths(
          detector: write('det.onnx', List<int>.filled(8, 0)),
          recModels: {'zh': write('rec_zh.onnx', List<int>.filled(8, 1))},
          recDicts: {'zh': dict},
        ),
      );
      expect(stamps.where((s) => s.startsWith('dict-zh:')), hasLength(1));
      expect(
        stamps.firstWhere((s) => s.startsWith('dict-zh:')),
        'dict-zh:${hashOf(dict)}',
      );
    });
  });

  group('the fingerprint reacts to a same-size model swap', () {
    OcrInputs inputs(List<String> stamps) => OcrInputs(
      schemaGen: 2,
      effectiveLang: 'ja',
      tier: ModelTier.fast,
      epKind: OrtEpKind.cpu,
      componentStamps: stamps,
    );

    test('end to end: swapping the detector file invalidates the key', () {
      final detA = write('det_a.onnx', List<int>.filled(4096, 0xAA));
      final detB = write('det_b.onnx', List<int>.filled(4096, 0xBB));
      final fpA = ocrFingerprintOf(
        inputs(componentStampsFor(WorkerModelPaths(detector: detA))),
      );
      final fpB = ocrFingerprintOf(
        inputs(componentStampsFor(WorkerModelPaths(detector: detB))),
      );
      expect(fpA, isNot(fpB));
      expect(fpA, matches(r'^[0-9a-f]{16}$'));
    });

    test('the shipped model set still produces a stable fingerprint', () {
      // Whatever files this machine has (possibly none), the stamping is a
      // pure function of them: two calls in a row agree.
      final stamps = componentStampsFor(TranslationModels.workerPaths());
      expect(stamps, isNotEmpty);
      expect(ocrFingerprintOf(inputs(stamps)), ocrFingerprintOf(inputs(stamps)));
    });
  });
}
