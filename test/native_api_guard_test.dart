import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

class _Rule {
  final RegExp pattern;
  final String reason;

  /// Path suffixes (with forward slashes) where the pattern is allowed.
  final List<String> allowedIn;

  const _Rule(this.pattern, this.reason, {this.allowedIn = const []});
}

/// Guards against reintroducing native-FFI APIs with known memory-safety
/// defects, and against opening SQLite connections outside the gateway.
/// Each entry documents the defect so a failure explains itself.
void main() {
  test('lib/ does not use known-unsafe native APIs', () {
    final rules = <_Rule>[
      // zip_flutter: openAndExtract registers its arg pointer with a GC
      // finalizer AND frees it manually — the finalizer then frees it a
      // second time and libmalloc aborts the process. This was the root
      // cause of the sync-import startup crash loop. openAndExtractAsync
      // is a separate, safe implementation and stays allowed.
      _Rule(
        RegExp(r'\bopenAndExtract\('),
        'use extractZip() from utils/archive.dart instead of '
        'ZipFile.openAndExtract (double-free, aborts the process)',
      ),
      // lodepng_flutter: the convenience wrappers free the native buffer and
      // then return a typed-data view over the freed memory.
      _Rule(
        RegExp(r'lodepng\.(decodePng|encodePng)\('),
        'use decodePngToPointer/encodePngToPointer with '
        'ByteBuffer.finalizer instead (wrappers return a view over '
        'freed memory)',
      ),
      // Every SQLite connection must come from the gateway: long-lived
      // handles via DatabaseGateway.openManaged (registered, so restores can
      // prove no handle is alive at the file-swap point), isolate work via
      // DatabaseGateway.isolateOp, and raw short-lived probes via
      // openRawDatabase. Ad-hoc opens bypass the registry and reopen the
      // door to swap-under-a-live-handle corruption.
      _Rule(
        RegExp(r'sqlite3\.open|openSqliteDatabase\(|withDatabase\('),
        'open connections through DatabaseGateway '
        '(openManaged/isolateOp) or openRawDatabase in '
        'foundation/sqlite_connection.dart',
        allowedIn: ['lib/foundation/sqlite_connection.dart'],
      ),
      // Killing an OCR isolate discards the only Dart handles that could call
      // ReleaseSession, while onnxruntime.dll keeps the D3D12 allocations
      // alive for the life of the process. "Dispose to free VRAM" therefore
      // leaked; the release must be handed back by the worker itself, over an
      // ack, before anything is killed.
      _Rule(
        RegExp(r'TranslationWorker\.instance\.dispose\(\)'),
        'use TranslationWorker.instance.shutdownAll() — dispose() kills the '
        'isolate immediately and strands its ONNX sessions in the process '
        '(plan D-1)',
        allowedIn: ['lib/foundation/image_translation/translation_worker.dart'],
      ),
      // Only the worker wrapper may kill an isolate, and only from killNow(),
      // which shutdown() calls after the release ack (or after logging the
      // timeout). Ad-hoc kills elsewhere reintroduce the same leak.
      _Rule(
        RegExp(r'Isolate\.kill\('),
        'isolates are torn down through _IsolateWorker.shutdown(), which '
        'waits for the release ack before killing',
        allowedIn: ['lib/foundation/image_translation/translation_worker.dart'],
      ),
    ];

    final violations = <String>[];
    for (final file in Directory('lib')
        .listSync(recursive: true)
        .whereType<File>()) {
      if (!file.path.endsWith('.dart')) continue;
      final normalizedPath = file.path.replaceAll('\\', '/');
      final lines = file.readAsLinesSync();
      for (var i = 0; i < lines.length; i++) {
        for (final rule in rules) {
          if (rule.allowedIn.any(normalizedPath.endsWith)) continue;
          if (rule.pattern.hasMatch(lines[i])) {
            violations.add(
              '$normalizedPath:${i + 1}: ${lines[i].trim()}\n'
              '  -> ${rule.reason}',
            );
          }
        }
      }
    }
    expect(violations, isEmpty, reason: violations.join('\n'));
  });
}
