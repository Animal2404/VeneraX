import 'dart:math' as math;
import 'dart:typed_data';

import 'ort_capabilities.dart';
import 'translation_types.dart';

/// Quantize [v] up to the nearest multiple of [q].
int quantizeUp(int v, int q) {
  if (q <= 1) return v;
  return ((v + q - 1) ~/ q) * q;
}

/// Calculate the target width for a line recognition crop.
///
/// Preserves aspect ratio, scales to [height], rounds to multiple of 8 (stride),
/// and clamps between [minW] and [maxW].
int recTargetWidth({
  required int rectW,
  required int rectH,
  required int height,
  int minW = 16,
  int maxW = 960,
}) {
  if (rectH <= 0) return minW;
  var scaledW = ((rectW * height) / rectH).round();
  scaledW = ((scaledW + 7) ~/ 8) * 8;
  return scaledW.clamp(minW, maxW);
}

/// A line crop row within a recognition batch.
class RecRow {
  const RecRow({
    required this.rect,
    required this.width,
    required this.originalIndex,
  });

  final IntRect rect;

  /// The actual width required for this line after aspect ratio scaling.
  final int width;

  /// Index of the line in the original input list.
  final int originalIndex;
}

/// A batch of recognition crops with a shared target shape [rows.length, 3, height, maxWidth].
class RecBatch {
  const RecBatch({
    required this.rows,
    required this.height,
    required this.maxWidth,
  });

  final List<RecRow> rows;
  final int height;
  final int maxWidth;

  int get elementCount => rows.length * 3 * height * maxWidth;
}

/// Plans batched recognition inference by bucketing lines according to width.
List<RecBatch> planRecBatch({
  required List<IntRect> lines,
  required int height,
  required List<int> widthBuckets,
  required int maxBatch,
}) {
  if (lines.isEmpty) return const [];
  final effectiveMaxBatch = math.max(1, maxBatch);
  final sortedBuckets = [...widthBuckets]..sort();
  final maxBucket = sortedBuckets.isNotEmpty ? sortedBuckets.last : 960;

  // Assign each line to a bucket.
  final bucketMap = <int, List<RecRow>>{};
  for (var i = 0; i < lines.length; i++) {
    final line = lines[i];
    final w = recTargetWidth(
      rectW: line.width,
      rectH: line.height,
      height: height,
      maxW: maxBucket,
    );

    // Pick smallest bucket that can hold w
    var chosenBucket = maxBucket;
    for (var b in sortedBuckets) {
      if (b >= w) {
        chosenBucket = b;
        break;
      }
    }

    bucketMap.putIfAbsent(chosenBucket, () => []).add(
          RecRow(rect: line, width: w, originalIndex: i),
        );
  }

  final batches = <RecBatch>[];
  for (var entry in bucketMap.entries) {
    final bucketWidth = entry.key;
    final rows = entry.value;
    for (var i = 0; i < rows.length; i += effectiveMaxBatch) {
      final end = math.min(i + effectiveMaxBatch, rows.length);
      batches.add(
        RecBatch(
          rows: rows.sublist(i, end),
          height: height,
          maxWidth: bucketWidth,
        ),
      );
    }
  }

  return batches;
}

/// A single detection tile.
class DetTile {
  const DetTile({
    required this.tileIndex,
    required this.w,
    required this.h,
    required this.top,
  });

  final int tileIndex;
  final int w;
  final int h;
  final int top;
}

/// A batch of detection tiles.
class DetBatch {
  const DetBatch({
    required this.tiles,
    required this.w,
    required this.h,
  });

  final List<DetTile> tiles;
  final int w;
  final int h;

  int get elementCount => tiles.length * 3 * h * w;
}

/// Plans detection tile batches, padding height and width to multiples of [stride].
List<DetBatch> planDetBatch({
  required List<DetTile> tiles,
  required int maxBatch,
  int stride = 32,
}) {
  if (tiles.isEmpty) return const [];
  final effectiveMaxBatch = math.max(1, maxBatch);
  final batches = <DetBatch>[];

  for (var i = 0; i < tiles.length; i += effectiveMaxBatch) {
    final end = math.min(i + effectiveMaxBatch, tiles.length);
    final chunk = tiles.sublist(i, end);

    var maxW = 0;
    var maxH = 0;
    for (var t in chunk) {
      if (t.w > maxW) maxW = t.w;
      if (t.h > maxH) maxH = t.h;
    }

    batches.add(
      DetBatch(
        tiles: chunk,
        w: quantizeUp(maxW, stride),
        h: quantizeUp(maxH, stride),
      ),
    );
  }

  return batches;
}

/// CTC greedy collapse across a batch of argmax class predictions.
///
/// [argmax] has length `batch * steps`. For each row in `0..batch-1`, performs
/// blank (0) skipping and deduplication identical to single-line CTC decode.
List<String> ctcGreedyCollapse({
  required Int32List argmax,
  required int batch,
  required int steps,
  required List<String> charset,
}) {
  final results = <String>[];
  for (var b = 0; b < batch; b++) {
    final buffer = StringBuffer();
    var prev = 0;
    final offset = b * steps;
    for (var t = 0; t < steps; t++) {
      final best = argmax[offset + t];
      if (best != 0 && best != prev && best < charset.length) {
        buffer.write(charset[best]);
      }
      prev = best;
    }
    results.add(buffer.toString().trim());
  }
  return results;
}

/// Special token constants for manga-ocr.
abstract final class MangaOcrTokens {
  static const int pad = 0;
  static const int unk = 1;
  static const int start = 2;
  static const int eos = 3;
  static const int maxTokens = 80;
}

/// State tracker for manga-ocr batched auto-regressive decoding.
class BatchDecodeState {
  BatchDecodeState({
    required this.batch,
    this.maxTokens = MangaOcrTokens.maxTokens,
    this.startToken = MangaOcrTokens.start,
    this.eosToken = MangaOcrTokens.eos,
    this.padToken = MangaOcrTokens.pad,
  })  : ids = List.generate(batch, (_) => <int>[startToken]),
        validTokens = List.generate(batch, (_) => <int>[]),
        done = List.filled(batch, false);

  final int batch;
  final int maxTokens;
  final int startToken;
  final int eosToken;
  final int padToken;

  /// Full token histories including padding.
  final List<List<int>> ids;

  /// Tokens collected prior to EOS or repetition loop termination.
  final List<List<int>> validTokens;

  /// Whether decoding for row `i` has completed.
  final List<bool> done;

  bool get allDone => done.every((d) => d);

  int get currentStep => ids[0].length;

  /// Flattened prefixes of shape `[batch, len]` for decoder input_ids.
  Int64List flatPrefix(int len) {
    final list = Int64List(batch * len);
    for (var b = 0; b < batch; b++) {
      final row = ids[b];
      final rowOffset = b * len;
      for (var i = 0; i < len; i++) {
        list[rowOffset + i] = row[i];
      }
    }
    return list;
  }

  /// Appends one predicted token per row, marking rows done on EOS or repetition loop.
  void appendAll(List<int> nextPerRow) {
    for (var b = 0; b < batch; b++) {
      if (done[b]) {
        ids[b].add(padToken);
        continue;
      }
      final token = nextPerRow[b];
      if (token == eosToken) {
        done[b] = true;
        ids[b].add(padToken);
        continue;
      }

      validTokens[b].add(token);
      ids[b].add(token);

      if (hasRepetitionLoop(validTokens[b])) {
        if (validTokens[b].length >= 3) {
          validTokens[b].removeRange(
            validTokens[b].length - 3,
            validTokens[b].length,
          );
        }
        done[b] = true;
      }
    }
  }

  /// Checks if token tail repeats identical 4-grams or repeating trigram twice.
  static bool hasRepetitionLoop(List<int> tokens) {
    final n = tokens.length;
    if (n >= 4 &&
        tokens[n - 1] == tokens[n - 2] &&
        tokens[n - 2] == tokens[n - 3] &&
        tokens[n - 3] == tokens[n - 4]) {
      return true;
    }
    if (n >= 6) {
      var repeated = true;
      for (var i = 0; i < 3; i++) {
        if (tokens[n - 1 - i] != tokens[n - 4 - i]) {
          repeated = false;
          break;
        }
      }
      if (repeated) return true;
    }
    return false;
  }

  List<String> textOf(String Function(List<int> tokens) decode) {
    return [for (var b = 0; b < batch; b++) decode(validTokens[b])];
  }
}

/// Execution profile controlling batch sizes and bucketing.
class BatchProfile {
  const BatchProfile({
    required this.detBatch,
    required this.recBatch,
    required this.decBatch,
    required this.widthQuantum,
    required this.widthBuckets,
  });

  final int detBatch;
  final int recBatch;
  final int decBatch;
  final int widthQuantum;
  final List<int> widthBuckets;

  BatchProfile halve() {
    return BatchProfile(
      detBatch: (detBatch ~/ 2).clamp(1, detBatch),
      recBatch: (recBatch ~/ 2).clamp(1, recBatch),
      decBatch: (decBatch ~/ 2).clamp(1, decBatch),
      widthQuantum: widthQuantum,
      widthBuckets: widthBuckets,
    );
  }

  static const cuda = BatchProfile(
    detBatch: 4,
    recBatch: 32,
    decBatch: 32,
    widthQuantum: 64,
    widthBuckets: [160, 256, 384, 512, 640, 768, 896, 960],
  );

  static const directml = BatchProfile(
    detBatch: 2,
    recBatch: 16,
    decBatch: 16,
    widthQuantum: 64,
    widthBuckets: [160, 256, 384, 512, 640, 768, 896, 960],
  );

  static const desktopCpu = BatchProfile(
    detBatch: 1,
    recBatch: 4,
    decBatch: 4,
    widthQuantum: 32,
    widthBuckets: [160, 256, 384, 512, 640, 768, 896, 960],
  );

  static const single = BatchProfile(
    detBatch: 1,
    recBatch: 1,
    decBatch: 1,
    widthQuantum: 32,
    widthBuckets: [160, 256, 384, 512, 640, 768, 896, 960],
  );

  static BatchProfile forEp(OrtEpKind ep, {bool isDesktop = true}) {
    if (!isDesktop) return single;
    switch (ep) {
      case OrtEpKind.cuda:
        return cuda;
      case OrtEpKind.directml:
        return directml;
      case OrtEpKind.cpu:
        return desktopCpu;
    }
  }
}

/// Engine routing group for a batch of clusters.
class EngineGroup {
  const EngineGroup({
    required this.engine,
    required this.clusterIndices,
  });

  final String engine;
  final List<int> clusterIndices;
}

/// Groups detected text clusters into engine batches.
List<EngineGroup> planEngineGroups({
  required List<IntRect> bounds,
  required bool hasJa,
  required List<String> recLangs,
  required String sourceLang,
  String? preferredEngine,
}) {
  if (bounds.isEmpty) return const [];

  final map = <String, List<int>>{};

  if (sourceLang != 'auto') {
    final String chosenEngine;
    if (sourceLang == 'ja' && hasJa) {
      chosenEngine = 'ja';
    } else if (recLangs.contains(sourceLang)) {
      chosenEngine = sourceLang;
    } else if (recLangs.isNotEmpty) {
      chosenEngine = recLangs.first;
    } else {
      chosenEngine = 'zh';
    }
    return [
      EngineGroup(
        engine: chosenEngine,
        clusterIndices: List.generate(bounds.length, (i) => i),
      ),
    ];
  }

  // sourceLang == 'auto'
  for (var i = 0; i < bounds.length; i++) {
    final rect = bounds[i];
    final isVertical = rect.height > rect.width * 1.3;

    final String engine;
    if (isVertical && hasJa) {
      engine = 'ja';
    } else if (preferredEngine != null &&
        (preferredEngine == 'ja' ? hasJa : recLangs.contains(preferredEngine))) {
      engine = preferredEngine;
    } else if (recLangs.isNotEmpty) {
      engine = recLangs.first;
    } else {
      engine = hasJa ? 'ja' : 'zh';
    }

    map.putIfAbsent(engine, () => []).add(i);
  }

  return [
    for (var entry in map.entries)
      EngineGroup(engine: entry.key, clusterIndices: entry.value),
  ];
}
