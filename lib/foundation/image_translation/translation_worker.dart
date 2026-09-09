import 'dart:async';
import 'dart:ffi';
import 'dart:isolate';
import 'dart:math' as math;

import 'package:venera/foundation/app.dart';
import 'package:venera/foundation/image_translation/hf_tokenizer.dart';
import 'package:venera/foundation/image_translation/ocr_batching.dart';
import 'package:venera/foundation/image_translation/ort_capabilities.dart';
import 'package:venera/foundation/image_translation/ort_ffi.dart';
import 'package:venera/foundation/image_translation/translation_types.dart';
import 'package:venera/foundation/image_translation/translation_performance_config.dart';
import 'package:venera/foundation/image_translation/worker_pool_selection.dart';
import 'package:venera/foundation/log.dart';
import 'package:venera/utils/io.dart';

/// Model file paths handed to the worker with each request; the worker has no
/// access to appdata/settings singletons.
class WorkerModelPaths {
  WorkerModelPaths({
    required this.detector,
    this.jaEncoder,
    this.jaDecoder,
    this.jaVocab,
    this.recModels = const {},
    this.recDicts = const {},
    this.recHeights = const {},
  });

  final String detector;
  final String? jaEncoder;
  final String? jaDecoder;
  final String? jaVocab;

  /// lang -> rec model path ('zh', 'en', 'ko').
  final Map<String, String> recModels;
  final Map<String, String> recDicts;
  final Map<String, int> recHeights;
}

/// The OCR result for a single page within a super-batched group request.
class OcrPageResult {
  const OcrPageResult({
    required this.pageIndex,
    this.blocks,
    this.error,
  });

  final int pageIndex;
  final List<OcrBlock>? blocks;
  final String? error;
}

class _PageInput {
  const _PageInput({
    required this.pageIndex,
    required this.pixels,
    required this.width,
    required this.height,
  });

  final int pageIndex;
  final TransferableTypedData pixels;
  final int width;
  final int height;
}

class _OcrPagesRequest {
  _OcrPagesRequest(
    this.id,
    this.pages,
    this.sourceLang,
    this.paths,
    this.intraThreads, {
    this.epPref = EpPreference.auto,
    this.detBatch = 1,
    this.recBatch = 1,
  });

  final int id;
  final List<_PageInput> pages;
  final String sourceLang;
  final WorkerModelPaths paths;
  final int intraThreads;
  final EpPreference epPref;
  final int detBatch;
  final int recBatch;
}

class _OcrPageRequest {
  _OcrPageRequest(
    this.id,
    this.pixels,
    this.width,
    this.height,
    this.sourceLang,
    this.paths,
    this.intraThreads,
  );

  final int id;
  final TransferableTypedData pixels;
  final int width;
  final int height;

  /// 'auto' enables the vertical heuristic + fallback OCR chain.
  final String sourceLang;
  final WorkerModelPaths paths;
  final int intraThreads;
  EpPreference epPref = EpPreference.auto;
  int detBatch = 1;
  int recBatch = 1;
}

class _ProbeRequest {
  const _ProbeRequest(this.id, this.pref, this.paths);
  final int id;
  final EpPreference pref;
  final WorkerModelPaths paths;
}

class _ReleaseRequest {
  const _ReleaseRequest();
}

/// Sent back by the worker once it has actually run `ReleaseSession` on every
/// session and freed the native arenas. Without this handshake, killing the
/// isolate destroys the only Dart handles that could release those native
/// objects, and the VRAM stays pinned for the life of the process (plan D-1).
class _ReleaseAck {
  const _ReleaseAck(this.report);

  final EpReport? report;
}

class _WorkerResponse {
  _WorkerResponse(
    this.id,
    this.result,
    this.error, [
    this.report,
    this.perfLog,
    this.perf,
  ]);

  final int id;
  final Object? result;
  final String? error;
  final EpReport? report;
  final String? perfLog;

  /// Structured twin of [perfLog], built at the same site from the same local
  /// values so the two cannot drift. Sent so the UI can show batch throughput
  /// without parsing the log line — parsing display strings is exactly the
  /// coupling that breaks when someone rewords a label.
  final OcrBatchPerf? perf;
}

/// Machine-readable form of one OCR batch's perf log: the counts and timings
/// behind `batch={det,rec} det={...} rec={...} dec={...} total_ms sessions`.
/// Immutable and built only from plain values so it survives the
/// isolate→main message copy untouched.
class OcrBatchPerf {
  const OcrBatchPerf({
    required this.pages,
    required this.epName,
    required this.detBatchCap,
    required this.recBatchCap,
    required this.detTiles,
    required this.detBuckets,
    required this.detMs,
    required this.recGroups,
    required this.recBatches,
    required this.recCrops,
    required this.recMs,
    required this.decRows,
    required this.decSteps,
    required this.decMs,
    required this.totalMs,
    required this.sessionCount,
    required this.arenaBytes,
    required this.degradedTrail,
    this.recGpuMs = 0,
    this.restMs = 0,
  });

  /// Images in this batch (`pages=[...]`).
  final int pages;
  /// Execution provider the batch ran on (`ep=`).
  final String epName;
  /// Requested detection / recognition batch caps (`batch={det,rec}`).
  final int detBatchCap;
  final int recBatchCap;
  /// Detection: tiles scanned, batches run, milliseconds (`det={...}`).
  final int detTiles;
  final int detBuckets;
  final int detMs;
  /// Recognition: groups, sub-batches, crops, milliseconds (`rec={...}`).
  final int recGroups;
  final int recBatches;
  final int recCrops;
  final int recMs;
  /// Decoder: text lines, steps, milliseconds (`dec={...}`).
  ///
  /// IMPORTANT: [decMs] is a *nested* interval of [recMs] (the decode loop
  /// runs inside the recognition pass), never a sibling segment. The additive
  /// triple is `detMs + recMs + restMs == totalMs`; do not sum det, rec and
  /// dec — that double-counts the decoder (`parts={...}` in the log string
  /// spells the disjoint version out).
  final int decRows;
  final int decSteps;
  final int decMs;
  final int totalMs;
  final int sessionCount;
  /// Host staging arenas in bytes — never a VRAM figure (plan §3.6).
  final int arenaBytes;
  /// Shrink/fallback events so far (`degraded=`; empty = none).
  final List<String> degradedTrail;
  /// Recognition time excluding the nested decoder loop (`parts.recGpuMs`):
  /// `recGpuMs + decMs == recMs`. This is what the recognizer spends on
  /// crop preprocessing plus encoder/inference work.
  final int recGpuMs;
  /// Wall time inside `ocrPagesAll` that neither the det nor the rec
  /// stopwatch covers — buffer materialise, box clustering, result assembly
  /// (`parts.restMs`). Closes the identity
  /// `detMs + recGpuMs + decMs + restMs == totalMs`.
  final int restMs;
}

/// The disjoint, additive partition of one OCR batch's wall time.
///
/// `detSw` and `recSw` are sequential top-level segments of `ocrPagesAll`;
/// `decSw` is NOT a third segment — the decode loop starts and stops inside
/// `_mangaOcrBatchMulti`, which runs wholly inside the recognition interval,
/// so `decMs ⊆ recMs`. Summing det+rec+dec double-counts the decoder and can
/// exceed `total_ms` (a real log once read det 5760 + rec 29817 + dec 21255
/// = 56832 > total 35647 for exactly this reason). This function turns the
/// four nested stopwatches into a sum that closes:
/// `detMs + recGpuMs + decMs + restMs == totalMs` (given sane non-negative,
/// non-overlapping-behaviour inputs; clamped so a weird clock can never
/// produce negative parts). Pure, so the closing identity is unit-testable
/// without spawning a worker isolate.
({int detMs, int recGpuMs, int decMs, int restMs}) ocrPerfParts({
  required int detMs,
  required int recMs,
  required int decMs,
  required int totalMs,
}) {
  final dec = math.min(math.max(0, decMs), math.max(0, recMs));
  final recGpu = recMs - dec;
  final rest = math.max(0, totalMs - detMs - recMs);
  return (detMs: detMs, recGpuMs: recGpu, decMs: dec, restMs: rest);
}

/// Resolves the OCR worker count without touching platform or settings state.
/// Kept public so the mobile memory policy can be covered by a pure unit test.
int resolveOcrPoolSize({
  required int requested,
  required int processorCount,
  required bool isMobile,
  required bool isDesktop,
  required String sourceLang,
  required bool hasJapaneseModel,
  OrtEpKind ep = OrtEpKind.cpu,
}) {
  if (ep != OrtEpKind.cpu && isDesktop) {
    if (requested > 0) return requested.clamp(1, 2);
    return (processorCount ~/ 4).clamp(1, 2);
  }
  if (isMobile &&
      (sourceLang == 'ja' || (sourceLang == 'auto' && hasJapaneseModel))) {
    return 1;
  }
  if (requested > 0) {
    return requested.clamp(1, isMobile ? 2 : 6);
  }
  var automatic = processorCount ~/ 2;
  return automatic.clamp(1, isDesktop ? 3 : 2);
}

/// Conservative page-local hint for auto OCR. Only the first two blocks with
/// unambiguous script evidence participate; a disagreement disables the hint.
/// Han-only text is deliberately not evidence, except vertical Japanese text.
class OcrPageEngineHint {
  String? _candidate;
  var _evidenceCount = 0;
  var _settled = false;

  String? get preferredEngine => _evidenceCount >= 2 ? _candidate : null;

  void observe({
    required String text,
    required String language,
    required String engine,
    required bool isVertical,
  }) {
    if (_settled) return;
    var signal = strongOcrEngineSignal(
      text: text,
      language: language,
      engine: engine,
      isVertical: isVertical,
    );
    if (signal == null) return;
    if (_candidate == null) {
      _candidate = signal;
      _evidenceCount = 1;
      return;
    }
    _settled = true;
    if (_candidate == signal) {
      _evidenceCount = 2;
    } else {
      _candidate = null;
      _evidenceCount = 0;
    }
  }
}

String? strongOcrEngineSignal({
  required String text,
  required String language,
  required String engine,
  required bool isVertical,
}) {
  if (language != engine) return null;
  var hasKana = false;
  var hasHangul = false;
  var hasHan = false;
  var hasLatin = false;
  for (var rune in text.runes) {
    if ((rune >= 0x3040 && rune <= 0x30FF) ||
        (rune >= 0x31F0 && rune <= 0x31FF)) {
      hasKana = true;
    } else if ((rune >= 0xAC00 && rune <= 0xD7AF) ||
        (rune >= 0x1100 && rune <= 0x11FF)) {
      hasHangul = true;
    } else if ((rune >= 0x4E00 && rune <= 0x9FFF) ||
        (rune >= 0x3400 && rune <= 0x4DBF)) {
      hasHan = true;
    } else if ((rune >= 0x41 && rune <= 0x5A) ||
        (rune >= 0x61 && rune <= 0x7A)) {
      hasLatin = true;
    }
  }
  if (language == 'ja' && (hasKana || (engine == 'ja' && isVertical))) {
    return engine;
  }
  if (language == 'ko' && hasHangul) return engine;
  if (language == 'en' && hasLatin && !hasHan) return engine;
  return null;
}

// ===========================================================================
// Main-isolate client
// ===========================================================================

/// Handle to the translation worker isolate. All heavy work — preprocessing,
/// ONNX inference (via the FFI binding), decoding loops — runs inside the
/// worker, so nothing here can jank the UI.
/// Pool of OCR worker isolates. All heavy work — preprocessing, ONNX inference,
/// decoding — runs inside a worker, so nothing here janks the UI. Concurrent
/// [ocrPage] calls fan out across workers instead of queuing on one, so the
/// reader's two in-flight pages and the pre-translation pipeline's overlapped
/// groups get real parallelism on multi-core devices.
class TranslationWorker {
  /// Test seam for the DirectML pinning rule (plan D-15). The rule itself
  /// lives in `_WorkerState`, which is private to this library, and a lost
  /// backslash there once made it dead code without any test noticing.
  static bool isCpuOnlyRecPath(String path) =>
      _WorkerState.isCpuOnlyRecPath(path);

  TranslationWorker._();

  static final instance = TranslationWorker._();

  final _workers = <_IsolateWorker>[];

  bool _isWarm = false;
  EpReport? _lastReport;

  /// Whether a recognition request has already come back. Until it has, the
  /// next one also pays for loading the ONNX models into a fresh isolate —
  /// seconds on mobile — which the task list shows as its own stage rather
  /// than as a recognition step that appears to hang.
  bool get isWarm => _isWarm;
  EpReport? get lastReport => _lastReport;

  Future<EpReport> capabilities({
    required EpPreference pref,
    required WorkerModelPaths paths,
  }) async {
    var worker = _pickWorker(1);
    var report = await worker.probe(pref: pref, paths: paths);
    _lastReport = report;
    return report;
  }

  int _poolSize(String sourceLang, WorkerModelPaths paths) {
    var n = TranslationPerformanceConfig.effective.ocrWorkers;
    return resolveOcrPoolSize(
      requested: n,
      processorCount: Platform.numberOfProcessors,
      isMobile: App.isMobile,
      isDesktop: App.isDesktop,
      sourceLang: sourceLang,
      hasJapaneseModel: paths.jaEncoder != null,
      ep: _lastReport?.active ?? OrtEpKind.cpu,
    );
  }

  /// The number of worker isolates the pool is willing to grow to for a
  /// given workload — i.e. what [_poolSize] would cap dispatch at, including
  /// the GPU/mobile clamps that make the raw `imageTranslationOcrWorkers`
  /// setting smaller in practice. Callers that want to feed the pool at its
  /// real parallel capacity (the pre-translation OCR sweep) size their
  /// in-flight window with this instead of the setting, so the knob is
  /// measured by actual dispatch capacity rather than by the slider label.
  int poolCapacity({
    required String sourceLang,
    required WorkerModelPaths paths,
  }) =>
      _poolSize(sourceLang, paths);

  final _recentPerfLogs = <String>[];

  /// The 20 most recent structured OCR performance timing logs.
  List<String> get recentPerfLogs => List.unmodifiable(_recentPerfLogs);

  /// Structured twin of [recentPerfLogs]' last entry, for display code that
  /// must not parse log text. Null before the first batch has returned —
  /// readers show `—` (never a fake 0) while it is null.
  OcrBatchPerf? _lastPerf;
  OcrBatchPerf? get lastPerf => _lastPerf;

  /// When [_lastPerf] was captured on the main isolate (message arrival, not
  /// batch end — the batch's own wall clock never leaves the isolate). The
  /// reader uses it to decide whether the numbers are still live; a stale
  /// batch of an idle/paused job would otherwise keep printing throughput
  /// the job is no longer achieving.
  DateTime? _lastPerfAt;
  DateTime? get lastPerfAt => _lastPerfAt;

  void addPerfLog(String log) {
    _recentPerfLogs.add(log);
    if (_recentPerfLogs.length > 20) {
      _recentPerfLogs.removeAt(0);
    }
  }

  /// Super-batched OCR across multiple images simultaneously.
  Future<List<OcrPageResult>> ocrPages(
    List<RgbaImage> images, {
    required String sourceLang,
    required WorkerModelPaths paths,
    List<int>? pageIndices,
  }) {
    if (images.isEmpty) return Future.value(const []);
    var poolSize = _poolSize(sourceLang, paths);
    _trimIdleWorkers(poolSize);
    var intraThreads = (Platform.numberOfProcessors ~/ poolSize).clamp(1, 4);
    var worker = _pickWorker(poolSize);
    final perf = TranslationPerformanceConfig.effective;
    final indices = pageIndices ?? List.generate(images.length, (i) => i);
    return worker
        .ocrPages(
          images,
          indices,
          sourceLang: sourceLang,
          paths: paths,
          intraThreads: intraThreads,
          epPref: perf.ep,
          detBatch: perf.detBatch,
          recBatch: perf.recBatch,
        )
        .whenComplete(() => _isWarm = true);
  }

  Future<List<OcrBlock>> ocrPage(
    RgbaImage image, {
    required String sourceLang,
    required WorkerModelPaths paths,
  }) async {
    final results = await ocrPages(
      [image],
      sourceLang: sourceLang,
      paths: paths,
      pageIndices: const [0],
    );
    if (results.isEmpty) return const [];
    final first = results.first;
    if (first.error != null) {
      throw Exception('OCR failed for page: ${first.error}');
    }
    return first.blocks ?? const [];
  }

  _IsolateWorker _pickWorker(int poolSize) {
    var eligibleCount = math.min(poolSize, _workers.length);
    // Prefer an idle existing worker — avoids spawning (and re-loading models
    // into) a new isolate when load is low.
    for (var w in _workers.take(eligibleCount)) {
      if (w.pendingCount == 0) return w;
    }
    // Under capacity and all busy: add a worker for more parallelism.
    if (eligibleCount < poolSize) {
      var worker = _IsolateWorker();
      _workers.insert(eligibleCount, worker);
      return worker;
    }
    // At capacity: dispatch to the least-busy worker.
    var idx = pickLeastBusyIndex([
      for (var w in _workers.take(poolSize)) w.pendingCount,
    ]);
    return _workers[idx];
  }

  void _trimIdleWorkers(int poolSize) {
    for (var i = _workers.length - 1; i >= poolSize; i--) {
      if (_workers[i].pendingCount != 0) continue;
      final worker = _workers.removeAt(i);
      // Shrinking the pool still has to hand the memory back; a bare kill
      // strands the sessions this worker was holding (plan D-1).
      unawaited(worker.shutdown());
    }
  }

  int _leases = 0;

  /// Number of in-flight consumers of the worker pool.
  int get leaseCount => _leases;

  /// Marks a task as using the pool. While any lease is held, [shutdownAll]
  /// degrades to [release] so one task finishing cannot kill the isolates
  /// another task is still reading from (plan D-9).
  OcrLease acquireLease() {
    _leases++;
    return OcrLease._(() {
      if (_leases > 0) _leases--;
    });
  }

  /// Frees model memory in every worker (sessions re-create lazily).
  void release() {
    for (var w in _workers) {
      w.release();
    }
    // Sessions re-create lazily, so the next request pays the load again.
    _isWarm = false;
  }

  /// Releases every worker's native sessions and tears the isolates down —
  /// handshake first, kill second, never the reverse.
  ///
  /// Await this from any path whose purpose is "give the memory back": task
  /// finish, cancel, pause-out, reader close, the diagnostics button.
  Future<void> shutdownAll({
    Duration timeout = const Duration(seconds: 8),
  }) async {
    if (_leases > 0) {
      // Someone is still using these sessions; free what is safe to free and
      // leave the isolates alive rather than pulling them out from under it.
      release();
      Log.info('OCR Lifecycle', 'shutdownAll deferred: $_leases lease(s) held');
      return;
    }
    final workers = List.of(_workers);
    _workers.clear();
    _isWarm = false;
    var unconfirmed = 0;
    for (var w in workers) {
      if (!await w.shutdown(timeout: timeout)) unconfirmed++;
    }
    // Report the observed count, never a hard-coded "0" — a log line that
    // asserts success unconditionally is how D-13 hid the leak.
    Log.info(
      'OCR Lifecycle',
      'shutdownAll: ${workers.length} worker(s), '
      'liveSessions=${_lastReport?.sessionCount ?? -1}'
      '${unconfirmed == 0 ? '' : ', unconfirmed=$unconfirmed'}',
    );
  }

  /// Kills all worker isolates without releasing them first. Test-only:
  /// production code must call [shutdownAll], which releases before killing.
  void dispose() {
    for (var w in _workers) {
      w.killNow();
    }
    _workers.clear();
  }
}

/// Handle returned by [TranslationWorker.acquireLease]; call [release] exactly
/// once when the task is done with the pool.
class OcrLease {
  OcrLease._(this._onRelease);

  final void Function() _onRelease;
  bool _done = false;

  void release() {
    if (_done) return;
    _done = true;
    _onRelease();
  }
}

/// A single OCR worker isolate. Owns its ONNX sessions (lazily loaded on first
/// request, so an unused worker costs no model memory).
class _IsolateWorker {
  Isolate? _isolate;
  SendPort? _sendPort;
  Future<void>? _starting;
  ReceivePort? _receivePort;
  final _pending = <int, Completer<Object?>>{};
  int _nextId = 0;

  int get pendingCount => _pending.length;

  Future<void> _ensureStarted() async {
    if (_sendPort != null) return;
    if (_starting != null) return _starting;
    var completer = Completer<void>();
    _starting = completer.future;
    var port = ReceivePort();
    _receivePort = port;
    port.listen((message) {
      if (message is SendPort) {
        _sendPort = message;
        completer.complete();
      } else if (message is _WorkerResponse) {
        if (message.report != null) {
          TranslationWorker.instance._lastReport = message.report;
        }
        if (message.perfLog != null) {
          Log.info('OCR Perf', message.perfLog!);
          TranslationWorker.instance.addPerfLog(message.perfLog!);
        }
        if (message.perf != null) {
          TranslationWorker.instance._lastPerf = message.perf;
          TranslationWorker.instance._lastPerfAt = DateTime.now();
        }
        var pending = _pending.remove(message.id);
        if (pending == null) return;
        if (message.error != null) {
          pending.completeError(Exception(message.error));
        } else {
          pending.complete(message.result);
        }
      } else if (message is _ReleaseAck) {
        if (message.report != null) {
          TranslationWorker.instance._lastReport = message.report;
        }
        final ack = _releaseAck;
        _releaseAck = null;
        if (ack != null && !ack.isCompleted) ack.complete();
      }
    });
    try {
      _isolate = await Isolate.spawn(
        _workerMain,
        port.sendPort,
        debugName: 'imageTranslationWorker',
      );
    } catch (e) {
      _starting = null;
      completer.completeError(e);
      rethrow;
    }
    await completer.future;
    _starting = null;
  }

  Future<T> _request<T>(Object Function(int id) build) async {
    // Register the pending slot synchronously, *before* awaiting isolate
    // startup. `_pickWorker` reads `pendingCount` to decide whether a worker
    // is idle, and while `_ensureStarted` is spawning (or a first request is
    // in flight), a lazily-registered slot would keep the worker reading as
    // idle — so concurrent callers would all stack onto it and the pool would
    // never actually spread. The id reservation and map insert are synchronous
    // here precisely so the next dispatch already sees this one.
    var id = _nextId++;
    var completer = Completer<Object?>();
    _pending[id] = completer;
    try {
      await _ensureStarted();
      _sendPort!.send(build(id));
    } catch (e) {
      // Nobody is awaiting `completer.future` at this point (the caller gets
      // the error via rethrow), so completing it with an error would surface
      // as an *unhandled* async error. Just drop the slot.
      _pending.remove(id);
      rethrow;
    }
    return await completer.future as T;
  }

  Future<EpReport> probe({
    required EpPreference pref,
    required WorkerModelPaths paths,
  }) {
    return _request<EpReport>((id) => _ProbeRequest(id, pref, paths));
  }

  Future<List<OcrPageResult>> ocrPages(
    List<RgbaImage> images,
    List<int> pageIndices, {
    required String sourceLang,
    required WorkerModelPaths paths,
    required int intraThreads,
    EpPreference epPref = EpPreference.auto,
    int detBatch = 1,
    int recBatch = 1,
  }) {
    final inputs = [
      for (var i = 0; i < images.length; i++)
        _PageInput(
          pageIndex: pageIndices[i],
          pixels: TransferableTypedData.fromList([images[i].pixels]),
          width: images[i].width,
          height: images[i].height,
        ),
    ];
    return _request<List<OcrPageResult>>(
      (id) => _OcrPagesRequest(
        id,
        inputs,
        sourceLang,
        paths,
        intraThreads,
        epPref: epPref,
        detBatch: detBatch,
        recBatch: recBatch,
      ),
    );
  }

  Future<List<OcrBlock>> ocrPage(
    RgbaImage image, {
    required String sourceLang,
    required WorkerModelPaths paths,
    required int intraThreads,
    EpPreference epPref = EpPreference.auto,
    int detBatch = 1,
    int recBatch = 1,
  }) async {
    final results = await ocrPages(
      [image],
      const [0],
      sourceLang: sourceLang,
      paths: paths,
      intraThreads: intraThreads,
      epPref: epPref,
      detBatch: detBatch,
      recBatch: recBatch,
    );
    if (results.isEmpty) return const [];
    if (results.first.error != null) {
      throw Exception(results.first.error);
    }
    return results.first.blocks ?? const [];
  }

  void release() {
    _sendPort?.send(const _ReleaseRequest());
  }

  Completer<void>? _releaseAck;

  /// Frees the native sessions inside the isolate, waits for its ack, and only
  /// then kills it.
  ///
  /// The order is the whole point: `Isolate.kill(immediate)` discards the Dart
  /// heap that held the `OrtSession` handles while the ONNX Runtime library —
  /// loaded once per process — keeps the D3D12 allocations alive. Killing
  /// first therefore does not "release memory early", it makes the memory
  /// permanently unreclaimable (plan D-1).
  ///
  /// Returns `false` when the ack never arrived; the isolate is killed anyway
  /// so a wedged worker cannot hang shutdown, but the caller learns the
  /// release was not confirmed.
  Future<bool> shutdown({Duration timeout = const Duration(seconds: 8)}) async {
    var port = _sendPort;
    if (port == null) {
      killNow();
      return true;
    }
    final ack = Completer<void>();
    _releaseAck = ack;
    port.send(const _ReleaseRequest());
    var confirmed = true;
    try {
      await ack.future.timeout(timeout);
    } catch (_) {
      confirmed = false;
      // release-ack-timeout: the only place allowed to kill without an ack.
      Log.error(
        'OCR Lifecycle',
        'release ack timeout, force kill (VRAM may stay pinned)',
      );
    }
    _releaseAck = null;
    killNow();
    return confirmed;
  }

  /// Kills the isolate without giving it a chance to release anything.
  /// Only for crash recovery and tests; production paths use [shutdown].
  void killNow() {
    _isolate?.kill(priority: Isolate.immediate);
    _isolate = null;
    _sendPort = null;
    _starting = null;
    _receivePort?.close();
    _receivePort = null;
    for (var pending in _pending.values) {
      pending.completeError(Exception('Translation worker disposed'));
    }
    _pending.clear();
  }
}

// ===========================================================================
// Worker isolate
// ===========================================================================

void _workerMain(SendPort mainPort) {
  // Wire the dict/model class-count sink delivered with `ort_ffi.dart`
  // (D-11 companion): `runArgmaxGrid` compares the output tensor's class
  // axis (`shape.last`) against the active charset length on every run and
  // routes the mismatch through this hook. The assignment belongs here —
  // the worker isolate is where sessions live, and it is the only side
  // allowed to pull `Log` (which drags `dart:ui` via `foundation/app.dart`)
  // into `ort_ffi.dart`'s reach; that file must keep compiling under plain
  // `dart run` for `tool/ort_ep_selfcheck.dart`. Unwired, the hook falls
  // back to print() and never reaches the app log or the diagnostics page.
  OrtFfiSession.classMismatchWarning = Log.warning;
  var port = ReceivePort();
  mainPort.send(port.sendPort);
  var state = _WorkerState();
  port.listen((message) {
    if (message is _OcrPagesRequest) {
      try {
        state.currentPref = message.epPref;
        var (results, perfLog, perf) = state.ocrPagesAll(message);
        mainPort.send(
          _WorkerResponse(message.id, results, null, state.report, perfLog, perf),
        );
      } catch (e, s) {
        mainPort.send(_WorkerResponse(message.id, null, '$e\n$s', state.report));
      }
    } else if (message is _OcrPageRequest) {
      try {
        state.currentPref = message.epPref;
        var blocks = state.ocrPage(message);
        mainPort.send(_WorkerResponse(message.id, blocks, null, state.report));
      } catch (e, s) {
        mainPort.send(_WorkerResponse(message.id, null, '$e\n$s'));
      }
    } else if (message is _ProbeRequest) {
      try {
        state.currentPref = message.pref;
        final firstModel = message.paths.jaEncoder ??
            message.paths.recModels.values.firstOrNull ??
            message.paths.detector;
        state._session(firstModel);
        mainPort.send(_WorkerResponse(message.id, state.report, null, state.report));
      } catch (e, s) {
        mainPort.send(_WorkerResponse(message.id, null, '$e\n$s'));
      }
    } else if (message is _ReleaseRequest) {
      state.release();
      // Ack with the post-release report so the caller can confirm sessions
      // really dropped to zero before it kills this isolate.
      mainPort.send(_ReleaseAck(state.report));
    }
  });
}

/// Parameters for DBNet text detection.
class DetParams {
  static const double unclipRatio = 1.8;
  static const double binaryThreshold = 0.3;
  static const double scoreThreshold = 0.5;
}

/// Parameters for text recognition padding and line expansion.
class RecParams {
  /// Base line padding in pixels.
  static const int padPx = 4;

  /// Direction-aware line inflation for horizontal and vertical lines.
  static IntRect inflateLine(IntRect line, int imgW, int imgH) {
    final isVertical = line.height > line.width * 1.3;
    final dx = padPx;
    final dy = isVertical ? padPx * 3 : padPx;
    return line.inflated(dx, dy, imgW, imgH);
  }
}

/// Exception thrown when model output class count does not match dictionary size + 2.
class DictMismatchException implements Exception {
  DictMismatchException(this.message);
  final String message;

  @override
  String toString() => 'DictMismatchException: $message';
}

/// Reads dictionary lines and returns charset with blank (index 0) and space (last index).
/// Validates that total classes equals [expectedClasses] if provided.
List<String> loadCharset(String dictPath, {int? expectedClasses}) {
  final file = File(dictPath);
  if (!file.existsSync()) {
    throw DictMismatchException('Dictionary file not found: $dictPath');
  }
  final lines = file.readAsLinesSync();
  final charset = ['', ...lines.map((l) => l.isEmpty ? ' ' : l), ' '];
  if (expectedClasses != null && charset.length != expectedClasses) {
    throw DictMismatchException(
      'Model output classes ($expectedClasses) does not match charset length (${charset.length}) '
      'from dict $dictPath. Expected ${expectedClasses - 2} dict lines but got ${lines.length}.',
    );
  }
  return charset;
}

class _ClusterWork {
  _ClusterWork({
    this.pageIndex = 0,
    required this.index,
    required this.cluster,
    required this.bounds,
    required this.eraseBounds,
    required this.eraseLines,
    required this.colors,
    required this.lineHeight,
  });

  final int pageIndex;
  final int index;
  final List<IntRect> cluster;
  final IntRect bounds;
  final IntRect eraseBounds;
  final List<IntRect> eraseLines;
  final (int, int) colors;
  final int lineHeight;

  String text = '';
  String lang = '';
  String engine = '';
  bool isPlausible = false;
}

/// Debug aid for acceptance criterion V9-5: with
/// `--dart-define=OCR_DEBUG_FORCE_OOM=true`, the first recognition batch run
/// in each worker isolate throws a synthetic out-of-memory, so the shrink
/// ladder (D-5) can be exercised without waiting for a real VRAM exhaustion.
/// Production builds leave this `false`; it is a const, so the throw sites
/// fold away and the normal path is byte-for-byte the behavior it always had.
const bool ocrDebugForceOom = bool.fromEnvironment('OCR_DEBUG_FORCE_OOM');

/// Session bookkeeping for [_WorkerState]: a cache of ONNX sessions keyed by
/// **model path + the execution provider that session actually runs on**.
///
/// Extracted from the old inline `_session()` and made generic over the
/// session type so its invariants are unit-testable — `OrtFfiSession.open`
/// reaches for `onnxruntime.dll` and cannot be faked inside a test (see
/// `test/ocr_worker_session_test.dart`).
///
/// The invariants, and why they are the correct semantics:
///
///  * **Exactly one live session per path.** This map is the only thing
///    standing between a native `OrtSession` handle and being forgotten:
///    [_WorkerState.release] is the sole production caller of
///    `OrtFfiSession.close()`, so an entry that no lookup can reach again is
///    not a cache hit waiting for reuse — it is VRAM pinned for the life of
///    the isolate (the D-1 leak class), plus a `sessionCount` reporting more
///    live sessions than the worker can still address. The old code produced
///    exactly that state: once a model fell back to CPU while the
///    worker-wide `_ep` still said `directml`, every later lookup of that
///    path asked for `path@cpu`, missed, re-opened the model, and left the
///    old `path@directml` handle stranded in the map — same model, two
///    providers, double VRAM, inflated count. Every publish now goes through
///    [_publish], which closes and removes any session of the same path on
///    every *other* EP first. `OrtFfiSession.close()` is idempotent, so the
///    eviction cannot double-free even if a stale Dart reference reaches it.
///
///  * **The key names the EP the session was opened on, not the EP the
///    lookup guessed.** The old code computed the key once on entry from
///    the (stale) `_ep` and then stored the successful session under it no
///    matter which candidate actually won — so the first DirectML success
///    inside a worker (entry `_ep == cpu`, the initial value) was filed
///    under `path@cpu`, guaranteeing a pointless re-open on the next call.
///    The entry lookup here uses [observedEp] (or `cpu` when pinned) only
///    as a *prediction* for the cache fast path; storage always uses the
///    winning candidate.
///
///  * **[observedEp] is an observation, not an instruction.** It records
///    "the EP of the most recent **non-pinned** open success" — a sample of
///    what the GPU is currently doing for this worker, consumed by
///    `BatchProfile.forEp`, the perf log and `EpReport.active`. It never
///    advances on a CPU-pinned (D-15) open, and no session ever *runs on*
///    it — each session's real EP is whatever its key says.
class EpSessionCache<S> {
  EpSessionCache({
    required this.open,
    required this.release,
    this.onOpened,
  });

  /// Creates a session for [path] on [ep]; throws an `OrtFfiException` when
  /// the provider cannot host the model.
  final S Function(String path, OrtEpKind ep, int intraOpThreads) open;

  /// Called exactly once per session when it leaves the map — either
  /// because the same path was superseded on another EP, or via [closeAll].
  final void Function(S session) release;

  /// Notified after a loop-success open, with the winning EP — used by the
  /// worker to record input shapes for `EpReport`; keeping it a callback is
  /// what lets the cache stay free of native types.
  final void Function(S session, String path, OrtEpKind ep)? onOpened;

  final _sessions = <String, S>{};

  /// Attempt log (`ep:ok` / `ep:fail(kind):msg…`), surfaced through
  /// `EpReport.attempts`.
  final attempts = <String>[];

  /// EP of the most recent **non-pinned** open success. See class comment.
  OrtEpKind observedEp = OrtEpKind.cpu;

  int _consecutiveFailures = 0;

  int get sessionCount => _sessions.length;

  Iterable<String> get keys => _sessions.keys;

  static String keyFor(String path, OrtEpKind ep) => '$path@${ep.name}';

  bool contains(String path, OrtEpKind ep) =>
      _sessions.containsKey(keyFor(path, ep));

  /// Open (or reuse) a session for [path], walking the provider fallback
  /// ladder. [forceCpu] pins the model to the CPU EP (plan D-15): the order
  /// collapses to `[cpu]`, the key says `cpu` explicitly, and [observedEp]
  /// is deliberately left untouched.
  S resolve(
    String path, {
    required EpPreference pref,
    required OrtProbe probe,
    required int intraOpThreads,
    bool forceCpu = false,
  }) {
    final hit = _sessions[keyFor(path, forceCpu ? OrtEpKind.cpu : observedEp)];
    if (hit != null) return hit;

    final order = forceCpu ? const [OrtEpKind.cpu] : planEpOrder(pref, probe);

    for (final candidate in order) {
      try {
        final session = open(path, candidate, intraOpThreads);
        // A pinned model must not rewrite the worker-wide observation —
        // that guard (kept from the D-15 fix) is what stops the CPU-only
        // recognizers from dragging every later key/profile decision to
        // CPU.
        if (!forceCpu) observedEp = candidate;
        attempts.add('${candidate.name}:ok');
        _publish(path, candidate, session);
        onOpened?.call(session, path, candidate);
        return session;
      } on OrtFfiException catch (e) {
        final truncated =
            e.message.length > 200 ? e.message.substring(0, 200) : e.message;
        attempts.add('${candidate.name}:fail(${e.kind.name}):$truncated');
        final decision = decideAfterFailure(
          e,
          alreadyTried: attempts.length,
          consecutiveFailures: _consecutiveFailures,
        );
        switch (decision) {
          case EpDecision.tryNextEp:
          case EpDecision.shrinkAndRetry:
            _consecutiveFailures++;
            continue;
          case EpDecision.goCpuPermanently:
            observedEp = OrtEpKind.cpu;
            _consecutiveFailures = 0;
            final cpuSession = open(path, OrtEpKind.cpu, intraOpThreads);
            _publish(path, OrtEpKind.cpu, cpuSession);
            return cpuSession;
        }
      } catch (e) {
        attempts.add('${candidate.name}:fail(other):$e');
        continue;
      }
    }

    observedEp = OrtEpKind.cpu;
    final cpuSession = open(path, OrtEpKind.cpu, intraOpThreads);
    _publish(path, OrtEpKind.cpu, cpuSession);
    return cpuSession;
  }

  /// File [session] under its real EP and supersede every other session of
  /// the same path (class comment, invariant 1). The keep-key is included
  /// in the sweep: a re-open landing on the EP an older session already
  /// holds must release that older handle too, never silently overwrite it.
  void _publish(String path, OrtEpKind ep, S session) {
    for (final other in OrtEpKind.values) {
      final stale = _sessions.remove(keyFor(path, other));
      if (stale != null && !identical(stale, session)) release(stale);
    }
    _sessions[keyFor(path, ep)] = session;
  }

  /// Release every session in the map and forget it (the worker's release /
  /// reconfigure point). Attempts and [observedEp] survive — the old inline
  /// `release()` kept them too, and the observation is about the provider,
  /// not about any one session.
  void closeAll() {
    for (final session in _sessions.values) {
      release(session);
    }
    _sessions.clear();
  }
}

/// Pure half of the dict-vs-model class-count check on the batch path
/// ([_WorkerState._charsetFor]).
///
/// Returns a one-line warning when [expectedClasses] (the opened session's
/// real output class count, `shape.last`) disagrees with [charsetLength]
/// (dict lines + 2, see [loadCharset]); `null` when they agree **or when
/// [expectedClasses] is `null`** — a null means the probe could not read
/// the model's output shape, in which case the check is explicitly skipped:
/// a missing observation must never be counted as a mismatch.
String? charsetClassMismatch({
  required String lang,
  required int charsetLength,
  required int? expectedClasses,
  String? dictPath,
}) {
  if (expectedClasses == null || expectedClasses == charsetLength) return null;
  return 'Model output classes ($expectedClasses) does not match charset '
      'length ($charsetLength) for $lang'
      '${dictPath == null ? '' : ' (dict $dictPath)'}';
}

class _WorkerState {
  /// The one-live-session-per-path cache described by [EpSessionCache].
  /// Named `_sessions` for continuity; `sessionCount`/`keys`/`attempts`
  /// replace the direct map reads the old inline implementation had.
  late final _sessions = EpSessionCache<OrtFfiSession>(
    open: (path, ep, threads) =>
        OrtFfiSession.open(path, ep: ep, intraOpThreads: threads),
    release: (session) => session.close(),
    onOpened: (session, path, ep) {
      try {
        final shapes = session.inputShapes();
        if (shapes.isNotEmpty) {
          _inputShapes[path] = shapes.values.first;
        }
      } catch (_) {}
    },
  );
  final _charsets = <String, List<String>>{};

  /// Output class count (`shape.last`) probed once per rec model path from
  /// the **already opened** session, cached because the probe costs an
  /// inference. A `null` value is a cached *failure* — the probe threw or the
  /// graph exposes no rank — and the dict/model class check is then
  /// explicitly skipped for that path, never guessed. Cleared in [release]
  /// together with the sessions it describes.
  final _recClasses = <String, int?>{};

  /// `lang@classes` pairs already warned about, so a genuine dict/model
  /// mismatch logs once per worker instead of once per batch.
  final _charsetMismatchNoted = <String>{};
  WordPieceVocab? _jaVocab;
  int _intraThreads = 2;
  EpPreference currentPref = EpPreference.auto;

  /// The worker's EP observation — owned by [_sessions], read-only here.
  OrtEpKind get _ep => _sessions.observedEp;

  OrtProbe? _probe;
  final _inputShapes = <String, List<int>>{};
  final _arena = OrtTensorArena();
  final _hiddenArena = OrtTensorArena();

  /// Shrink/fallback events observed by this worker, e.g. `rec16<-32`.
  /// Recorded so the perf log and the diagnostics page can show a real
  /// degradation instead of the previously hard-coded `degraded=none` (D-5).
  final _degradedTrail = <String>[];

  /// The tier the OOM shrink ladder retreated to, sticky for this worker's
  /// lifetime (plan §6.2.3): the next request starts capped here instead of
  /// re-discovering the same VRAM wall. Reset in [release], which is this
  /// codebase's reconfigure point (sessions and arenas are torn down there —
  /// after a model/EP switch the old ceiling no longer describes the memory
  /// picture). `shutdownAll` kills the isolate, which discards the state
  /// wholesale, so it needs no extra hook.
  BatchProfile? _oomCeiling;

  /// V9-5 acceptance aid, see [ocrDebugForceOom]. Armed once per worker
  /// lifetime; re-armed by [release] so a settings switch re-proves the ladder.
  bool _forceOomPending = ocrDebugForceOom;

  /// Called by the batch paths when they back off. Sticky for the process:
  /// retrying the size that just failed would only fail again.
  void noteDegraded(String event) {
    if (!_degradedTrail.contains(event)) _degradedTrail.add(event);
  }

  OrtProbe _getProbe() {
    return _probe ??= probeOrtRuntime();
  }

  EpReport get report => EpReport(
        active: _ep,
        runtimeVersion: OrtRuntime.runtimeVersion(),
        attempts: List.unmodifiable(_sessions.attempts),
        modelInputShapes: Map.unmodifiable(_inputShapes),
        batchCapable: _inputShapes.values.isNotEmpty &&
            _inputShapes.values.every((s) => s.isNotEmpty && s[0] <= 0),
        sessionCount: _sessions.sessionCount,
        arenaCapacityBytes: _arena.capacityBytes,
        hiddenArenaCapacityBytes: _hiddenArena.capacityBytes,
        degradedTrail: List.unmodifiable(_degradedTrail),
      );

  /// Rec recognizers that DirectML cannot execute (plan D-15).
  ///
  /// On the pinned stack (ORT DirectML 1.22.0 + DirectML 1.15.4, RTX 3060) the
  /// English PP-OCRv3 and Korean PP-OCRv1 recognizers fail *inside* `Run` at
  /// their `Softmax_0` node with E_INVALIDARG (80070057). `Softmax_0` exists in
  /// no other asset we ship: not in the zh rec, not in either manga-ocr graph,
  /// not in the two detectors. A `Run`-time failure has no execution-provider
  /// fallback — the retry state machine only guards session creation — so these
  /// two are pinned to the CPU EP, where 8.9 MB and 3.3 MB models cost nothing
  /// measurable, instead of failing the page.
  ///
  /// This is containment, not a cure: the shape predicate inside the closed
  /// `MLOperatorAuthorImpl` could not be determined from the repository, so the
  /// model directory names are the (data, not logic) boundary. Extending the
  /// list is the response if another recognizer starts failing the same way.
  static const _cpuOnlyRecDirs = ['ocr_en', 'ocr_ko'];

  /// Whether [path] belongs to a component that must stay on the CPU EP.
  ///
  /// Deliberately free of any backslash *literal*: the first version of this
  /// function was written as `path.replaceAll(r'', '/')`, but the backslash
  /// did not survive the scripted patch that created it, leaving
  /// `path.replaceAll(r'', '/')` — which inserts a slash between **every**
  /// character, so `contains('/ocr_en/')` was false for every path and the
  /// pinning was dead code from the day it shipped (plan D-15). Splitting on
  /// both separators via `codeUnit 92` cannot be silently mangled the same way,
  /// and comparing whole segments also avoids the substring trap that would
  /// match a directory merely named like `ocr_enhanced`.
  /// Public only so a regression test can pin it (see test/ocr_cpu_pinning_test.dart).
  static bool isCpuOnlyRecPath(String path) {
    final buffer = StringBuffer();
    for (final unit in path.codeUnits) {
      // 92 is the backslash; written as a number so no escaping can corrupt it.
      buffer.write(unit == 92 ? '/' : String.fromCharCode(unit));
    }
    final segments = buffer.toString().split('/');
    return segments.any(_cpuOnlyRecDirs.contains);
  }

  /// Opens (or reuses) a session for [path]. All of the interesting policy —
  /// the cache key, the provider ladder, the eviction of a superseded EP's
  /// session for the same path — lives in [EpSessionCache.resolve], which is
  /// generic over the session type so it can be unit-tested without the
  /// native runtime. [forceCpu] pins the model to the CPU EP (plan D-15).
  OrtFfiSession _session(String path, {bool forceCpu = false}) {
    return _sessions.resolve(
      path,
      pref: currentPref,
      probe: _getProbe(),
      intraOpThreads: _intraThreads,
      forceCpu: forceCpu,
    );
  }

  void release() {
    // closeAll() is the single place that hands every session back to the
    // native runtime (via OrtFfiSession.close(), idempotent).
    _sessions.closeAll();
    _charsets.clear();
    // The probed class counts belong to the sessions that just died: a
    // settings switch may swap in a different model file under the same
    // path, and a stale count would then either silence a real mismatch
    // warning or manufacture a wrong one.
    _recClasses.clear();
    _jaVocab = null;
    _arena.free();
    _hiddenArena.free();
    // This is the reconfigure point: sessions/arenas are gone and will be
    // rebuilt (possibly on another EP or another model tier), so the memory
    // ceiling that produced the last OOM no longer describes the situation.
    // Keep the shrink sticky past here and a one-off OOM on the 8 GB card
    // setting would punish every later configuration that could batch again.
    _oomCeiling = null;
    _forceOomPending = ocrDebugForceOom;
  }

  // -------------------------------------------------------------------------
  // OCR page
  // -------------------------------------------------------------------------

  List<OcrBlock> ocrPage(_OcrPageRequest req) {
    final (results, _, _) = ocrPagesAll(_OcrPagesRequest(
      req.id,
      [
        _PageInput(
          pageIndex: 0,
          pixels: req.pixels,
          width: req.width,
          height: req.height,
        ),
      ],
      req.sourceLang,
      req.paths,
      req.intraThreads,
      epPref: req.epPref,
      detBatch: req.detBatch,
      recBatch: req.recBatch,
    ));
    if (results.isEmpty) return const [];
    if (results.first.error != null) {
      throw Exception(results.first.error);
    }
    return results.first.blocks ?? const [];
  }

  (List<OcrPageResult>, String, OcrBatchPerf) ocrPagesAll(_OcrPagesRequest req) {
    final totalSw = Stopwatch()..start();
    final detSw = Stopwatch();
    final recSw = Stopwatch();
    final decSw = Stopwatch();

    _intraThreads = req.intraThreads;

    final pageImages = <int, RgbaImage>{};
    final pageErrors = <int, String>{};

    for (var p in req.pages) {
      try {
        final bytes = p.pixels.materialize().asUint8List();
        if (bytes.length < p.width * p.height * 4) {
          pageErrors[p.pageIndex] =
              'Invalid image pixel buffer length: ${bytes.length} for ${p.width}x${p.height}';
          continue;
        }
        pageImages[p.pageIndex] = RgbaImage(p.width, p.height, bytes);
      } catch (e, s) {
        pageErrors[p.pageIndex] = '$e\n$s';
      }
    }

    final baseProfile = BatchProfile.forEp(_ep, isDesktop: App.isDesktop);
    // Sticky OOM retreat (D-5): a previous shrink in this worker's lifetime
    // caps what this request may attempt. Width bucketing is deliberately
    // not capped — it is a shape choice, not an occupancy knob.
    final effectiveProfile = cappedBy(
      BatchProfile(
        detBatch: req.detBatch > 0 ? req.detBatch : baseProfile.detBatch,
        recBatch: req.recBatch > 0 ? req.recBatch : baseProfile.recBatch,
        decBatch: req.recBatch > 0 ? req.recBatch : baseProfile.decBatch,
        widthQuantum: baseProfile.widthQuantum,
        widthBuckets: baseProfile.widthBuckets,
      ),
      _oomCeiling,
    );

    var detTilesCount = 0;
    var detBatchesCount = 0;
    final pageBoxes = <int, List<IntRect>>{};
    for (final pageIdx in pageImages.keys) {
      pageBoxes[pageIdx] = <IntRect>[];
    }

    if (pageImages.isNotEmpty) {
      detSw.start();
      const tileHeight = 1280;
      const tileOverlap = 128;
      final allTiles = <({int pageIndex, DetTile tile})>[];
      var tileIdx = 0;

      for (final entry in pageImages.entries) {
        final pageIdx = entry.key;
        final img = entry.value;
        var top = 0;
        while (top < img.height) {
          var bottom = math.min(img.height, top + tileHeight);
          allTiles.add((
            pageIndex: pageIdx,
            tile: DetTile(
              tileIndex: tileIdx++,
              w: img.width,
              h: bottom - top,
              top: top,
            ),
          ));
          if (bottom >= img.height) break;
          top = bottom - tileOverlap;
        }
      }

      detTilesCount = allTiles.length;
      final session = _session(req.paths.detector);

      // OOM shrink ladder for the detection pass — see [runWithShrinkLadder]
      // (plan D-5 / §6.2.3): an allocation failure re-plans the tile list at
      // the halved profile and retries *in place*, instead of only learning
      // the lesson when the next request is capped by `cappedBy`. The
      // retreat is sticky through [_oomCeiling], and `noteDegraded` gets a
      // `det`-prefixed event so the diagnostics trail names the pass that
      // actually backed off. The stop rule is deliberately shared with rec
      // ([profileAfterOom] keys the give-up rung on recBatch): once recBatch
      // is 1 the page genuinely does not fit and the exception rethrows —
      // never swallowed. Honest caveat: when the OOM hits at detBatch == 1
      // the ladder has no per-tile occupancy knob left (tile side-lengths
      // change detection results and are not part of the ladder), so those
      // extra rungs only shrink the rec/dec footprint before rethrowing.
      runWithShrinkLadder(
        start: effectiveProfile,
        attempt: (p) {
          final batches = planDetBatch(
            tiles: [for (var t in allTiles) t.tile],
            maxBatch: p.detBatch,
            stride: 32,
          );
          // The stats describe the plan that actually completed; failed
          // attempts are not counted twice (same rule as rec).
          detBatchesCount = batches.length;

          for (var batch in batches) {
            final n = batch.tiles.length;
            final targetW = batch.w;
            final targetH = batch.h;
            final totalElements = n * 3 * targetH * targetW;
            final offset = _arena.ensure(0, totalElements);
            _arena.view.fillRange(offset, offset + totalElements, 0.0);

            final tileInfo = <({int pageIndex, int realW, int realH, int origW, int origH, int top})>[];
            const maxSide = 1280.0;
            const mean = [0.485, 0.456, 0.406];
            const std = [0.229, 0.224, 0.225];

            for (var b = 0; b < n; b++) {
              final t = batch.tiles[b];
              final tileMeta = allTiles[t.tileIndex];
              final img = pageImages[tileMeta.pageIndex]!;
              final scale = math.min(1.0, maxSide / math.max(t.w, t.h));
              int round32(double v) => math.max(32, (v / 32).round() * 32);
              final inW = round32(t.w * scale);
              final inH = round32(t.h * scale);
              tileInfo.add((
                pageIndex: tileMeta.pageIndex,
                realW: inW,
                realH: inH,
                origW: t.w,
                origH: t.h,
                top: t.top,
              ));

              final tilePixels = Uint8List.sublistView(
                img.pixels,
                t.top * img.width * 4,
                (t.top + t.h) * img.width * 4,
              );
              final tileImg = RgbaImage(t.w, t.h, tilePixels);
              final resized = _resizeRegion(tileImg, IntRect(0, 0, t.w, t.h), inW, inH);

              final plane = targetH * targetW;
              final bOffset = offset + b * 3 * plane;
              for (var y = 0; y < inH; y++) {
                final rowIn = y * inW;
                final rowOut = y * targetW;
                for (var x = 0; x < inW; x++) {
                  final srcIdx = (rowIn + x) * 4;
                  final dstIdx = rowOut + x;
                  for (var c = 0; c < 3; c++) {
                    _arena.view[bOffset + c * plane + dstIdx] =
                        (resized[srcIdx + c] / 255.0 - mean[c]) / std[c];
                  }
                }
              }
            }

            session.runInPlace(
              {
                session.inputNames.first: OrtInput.nativeFloat32(
                  _arena.pointerAt(offset),
                  totalElements,
                  [n, 3, targetH, targetW],
                ),
              },
              session.outputNames.first,
              (probsPtr, shape, elementCount) {
                final plane = targetH * targetW;
                for (var b = 0; b < n; b++) {
                  final info = tileInfo[b];
                  final tileProbs = probsPtr + (b * plane);
                  final tileBoxes = _detPostprocessBatchSingle(
                    tileProbs,
                    w: targetW,
                    h: targetH,
                    realW: info.realW,
                    realH: info.realH,
                    tileWidth: info.origW,
                    tileHeight: info.origH,
                  );
                  final boxesList = pageBoxes[info.pageIndex]!;
                  for (var box in tileBoxes) {
                    box.top += info.top;
                    box.bottom += info.top;
                    if (!boxesList.any((existing) => _iou(existing, box) > 0.5)) {
                      boxesList.add(box);
                    }
                  }
                }
                return null;
              },
            );
          }
        },
        onShrink: (next, previous) {
          _oomCeiling = cappedBy(next, _oomCeiling);
          noteDegraded('det${next.detBatch}<-${previous.detBatch}');
          Log.warning(
            'OCR Perf',
            'OOM: detBatch ${previous.detBatch}->${next.detBatch}',
          );
          // The retry replays the page's batches from the first one. Boxes
          // merged before the throw are re-derived identically (detection is
          // deterministic for a fixed tile plan) and dropped by the IoU>0.5
          // dedup guard above, so a replay can never duplicate a box.
        },
      );
      detSw.stop();
    }

    final workItems = <_ClusterWork>[];
    for (final entry in pageBoxes.entries) {
      final pageIdx = entry.key;
      final img = pageImages[pageIdx]!;
      var boxes = entry.value;
      if (boxes.isEmpty) continue;
      var clusters = clusterOcrBoxes(boxes, img.width, img.height);
      clusters.sort((a, b) => _boundsOf(a).top.compareTo(_boundsOf(b).top));
      final pageCropLimit = (effectiveProfile.recBatch * 4).clamp(32, 128);
      if (clusters.length > pageCropLimit) {
        clusters = clusters.sublist(0, pageCropLimit);
      }
      for (var i = 0; i < clusters.length; i++) {
        final cluster = clusters[i];
        final detectedBounds = _boundsOf(cluster);
        final eraseBounds = detectedBounds.inflated(2, 2, img.width, img.height);
        final eraseLines = [
          for (var line in cluster) line.inflated(0, 0, img.width, img.height),
        ];
        final lineHeight = _medianLineHeight(cluster);
        final pad = math.max(4, (0.06 * lineHeight).round().clamp(4, 8));
        final bounds = detectedBounds.inflated(pad, pad, img.width, img.height);
        if (bounds.width < 8 || bounds.height < 8) continue;
        final colors = _sampleColors(img, bounds);
        workItems.add(
          _ClusterWork(
            pageIndex: pageIdx,
            index: i,
            cluster: cluster,
            bounds: bounds,
            eraseBounds: eraseBounds,
            eraseLines: eraseLines,
            colors: colors,
            lineHeight: lineHeight,
          ),
        );
      }
    }

    var recGroupsCount = 0;
    var recBatchesCount = 0;
    var recCropsCount = 0;
    var decRowsCount = 0;
    var decStepsCount = 0;

    if (workItems.isNotEmpty) {
      recSw.start();
      final hasJa = req.paths.jaEncoder != null;
      final recLangs = req.paths.recModels.keys.toList();

      void executeMultiEngineBatch(
        List<_ClusterWork> targets,
        String engine,
        WorkerModelPaths paths,
        BatchProfile profile,
      ) {
        if (targets.isEmpty) return;
        recGroupsCount++;
        if (engine == 'ja') {
          final targetInputs = [
            for (var t in targets) (image: pageImages[t.pageIndex]!, bounds: t.bounds)
          ];
          final texts = _mangaOcrBatchMulti(
            targetInputs,
            paths,
            profile: profile,
            decStopwatch: decSw,
            onStepStats: (rows, steps) {
              decRowsCount += rows;
              decStepsCount += steps;
            },
          );
          for (var i = 0; i < targets.length; i++) {
            final t = targets[i];
            final raw = texts[i].trim();
            if (_isPlausible(raw)) {
              t.text = raw;
              t.lang = _detectLanguage(raw, 'ja');
              t.engine = 'ja';
              t.isPlausible = true;
            }
          }
        } else {
          if (!paths.recModels.containsKey(engine)) return;
          final lineClusterIdx = <int>[];
          final allLineItems = <({RgbaImage image, IntRect rect})>[];
          for (var i = 0; i < targets.length; i++) {
            final t = targets[i];
            final img = pageImages[t.pageIndex]!;
            final sortedLines = [
              for (var l in t.cluster)
                RecParams.inflateLine(l, img.width, img.height),
            ]..sort((a, b) => a.top.compareTo(b.top));
            final validLines = sortedLines.where((r) => r.width >= 8 && r.height >= 8).toList();
            for (var l in validLines) {
              lineClusterIdx.add(i);
              allLineItems.add((image: img, rect: l));
            }
          }

          if (allLineItems.isEmpty) return;

          final lineTexts = _recognizeLinesBatchMulti(
            allLineItems,
            engine,
            paths,
            profile: profile,
            onStats: (batches, crops) {
              recBatchesCount += batches;
              recCropsCount += crops;
            },
          );

          final clusterParts = List.generate(targets.length, (_) => <String>[]);
          for (var l = 0; l < allLineItems.length; l++) {
            final txt = lineTexts[l].trim();
            if (txt.isNotEmpty) {
              clusterParts[lineClusterIdx[l]].add(txt);
            }
          }

          for (var i = 0; i < targets.length; i++) {
            final t = targets[i];
            final raw = clusterParts[i].join(' ').trim();
            if (_isPlausible(raw)) {
              t.text = raw;
              t.lang = _detectLanguage(raw, engine);
              t.engine = engine;
              t.isPlausible = true;
            }
          }
        }
      }

      // Pass A: Group by preferred engine
      final engineGroups = planEngineGroups(
        bounds: [for (var c in workItems) c.bounds],
        hasJa: hasJa,
        recLangs: recLangs,
        sourceLang: req.sourceLang,
      );

      for (var group in engineGroups) {
        final targets = [for (var idx in group.clusterIndices) workItems[idx]];
        executeMultiEngineBatch(targets, group.engine, req.paths, effectiveProfile);
      }

      // Pass B: For un-plausible items in auto mode, try fallback engine
      if (req.sourceLang == 'auto') {
        final passBJa = <_ClusterWork>[];
        final passBRec = <_ClusterWork>[];
        final defaultRec = recLangs.isNotEmpty ? recLangs.first : 'zh';

        for (var item in workItems) {
          if (!item.isPlausible) {
            if (item.engine == 'ja') {
              passBRec.add(item);
            } else if (hasJa) {
              passBJa.add(item);
            }
          }
        }

        if (passBJa.isNotEmpty) {
          executeMultiEngineBatch(passBJa, 'ja', req.paths, effectiveProfile);
        }
        if (passBRec.isNotEmpty) {
          executeMultiEngineBatch(passBRec, defaultRec, req.paths, effectiveProfile);
        }
      }
      recSw.stop();
    }

    final pageBlocks = <int, List<OcrBlock>>{};
    for (final pageIdx in pageImages.keys) {
      pageBlocks[pageIdx] = <OcrBlock>[];
    }

    for (var item in workItems) {
      final text = item.text.trim();
      if (text.isEmpty || !item.isPlausible) continue;
      final lineHeight = _medianLineHeight(item.cluster);
      pageBlocks[item.pageIndex]?.add(
        OcrBlock(
          rect: item.bounds,
          eraseRect: item.eraseBounds,
          eraseRects: item.eraseLines,
          text: text,
          language: item.lang,
          backgroundColor: item.colors.$1,
          textColor: item.colors.$2,
          lineHeight: lineHeight,
        ),
      );
    }

    final results = <OcrPageResult>[];
    for (var p in req.pages) {
      final err = pageErrors[p.pageIndex];
      if (err != null) {
        results.add(OcrPageResult(pageIndex: p.pageIndex, error: err));
      } else {
        results.add(OcrPageResult(
          pageIndex: p.pageIndex,
          blocks: pageBlocks[p.pageIndex] ?? const [],
        ));
      }
    }

    totalSw.stop();

    final pagesStr = req.pages.map((p) => p.pageIndex).join(',');
    final totalArenaBytes = _arena.capacityBytes + _hiddenArena.capacityBytes;
    // Additive partition of total_ms — see [ocrPerfParts]: `decMs` is a
    // nested interval of `recMs`, never a sibling segment, and
    // `parts={...}` below is the disjoint sum that closes on `total_ms`.
    final detMs = detSw.elapsedMilliseconds;
    final recMs = recSw.elapsedMilliseconds;
    final batchTotalMs = totalSw.elapsedMilliseconds;
    final parts = ocrPerfParts(
      detMs: detMs,
      recMs: recMs,
      decMs: decSw.elapsedMilliseconds,
      totalMs: batchTotalMs,
    );
    final perfLog = 'pages=[$pagesStr] ep=${_ep.name} '
        'batch={det:${req.detBatch},rec:${req.recBatch}} '
        'det={tiles:$detTilesCount buckets:$detBatchesCount ms:$detMs} '
        'rec={groups:$recGroupsCount batches:$recBatchesCount crops:$recCropsCount ms:$recMs} '
        'dec={rows:$decRowsCount steps:$decStepsCount ms:${parts.decMs}} '
        'total_ms=$batchTotalMs '
        'bytes_in_arena=${(totalArenaBytes / (1024 * 1024)).toStringAsFixed(1)}MB '
        'sessions=${_sessions.sessionCount} '
        'degraded=${_degradedTrail.isEmpty ? "none" : _degradedTrail.join(",")} '
        'parts={detMs:${parts.detMs},recGpuMs:${parts.recGpuMs},decMsInRec:${parts.decMs},restMs:${parts.restMs}}';

    // Same numbers, structured shape: built right here so the perf log and
    // the display data can never disagree about what a field means.
    final perf = OcrBatchPerf(
      pages: req.pages.length,
      epName: _ep.name,
      detBatchCap: req.detBatch,
      recBatchCap: req.recBatch,
      detTiles: detTilesCount,
      detBuckets: detBatchesCount,
      detMs: detSw.elapsedMilliseconds,
      recGroups: recGroupsCount,
      recBatches: recBatchesCount,
      recCrops: recCropsCount,
      recMs: recSw.elapsedMilliseconds,
      decRows: decRowsCount,
      decSteps: decStepsCount,
      decMs: decSw.elapsedMilliseconds,
      totalMs: totalSw.elapsedMilliseconds,
      sessionCount: _sessions.sessionCount,
      arenaBytes: totalArenaBytes,
      degradedTrail: List.of(_degradedTrail),
      recGpuMs: parts.recGpuMs,
      restMs: parts.restMs,
    );

    return (results, perfLog, perf);
  }

  /// Median height of a cluster's line boxes — an estimate of the original
  /// glyph height, used to size the translation to the source text.
  int _medianLineHeight(List<IntRect> lines) {
    if (lines.isEmpty) return 0;
    var heights = [for (var l in lines) l.height]..sort();
    return heights[heights.length ~/ 2];
  }



  bool _isPlausible(String text) {
    if (text.length < 2) return false;
    var meaningful = text.runes
        .where((r) => r > 0x2E80 || (r >= 0x30 && r <= 0x7A))
        .length;
    return meaningful >= math.max(2, text.length ~/ 2);
  }

  /// Determines the language from the recognized script; falls back to the
  /// engine's own language when the text is ambiguous.
  String _detectLanguage(String text, String engineLang) {
    var kana = 0, hangul = 0, han = 0, latin = 0;
    for (var r in text.runes) {
      if ((r >= 0x3040 && r <= 0x30FF) || (r >= 0x31F0 && r <= 0x31FF)) {
        kana++;
      } else if ((r >= 0xAC00 && r <= 0xD7AF) || (r >= 0x1100 && r <= 0x11FF)) {
        hangul++;
      } else if ((r >= 0x4E00 && r <= 0x9FFF) || (r >= 0x3400 && r <= 0x4DBF)) {
        han++;
      } else if ((r >= 0x41 && r <= 0x5A) || (r >= 0x61 && r <= 0x7A)) {
        latin++;
      }
    }
    if (kana > 0) return 'ja';
    if (hangul > 0) return 'ko';
    if (han > 0) return engineLang == 'ja' ? 'ja' : 'zh';
    if (latin > 0) return 'en';
    return engineLang;
  }



  List<IntRect> _detPostprocessBatchSingle(
    Pointer<Float> probs, {
    required int w,
    required int h,
    required int realW,
    required int realH,
    required int tileWidth,
    required int tileHeight,
  }) {
    const binaryThreshold = DetParams.binaryThreshold;
    const scoreThreshold = DetParams.scoreThreshold;
    const unclipRatio = DetParams.unclipRatio;
    var labels = Int32List(w * h);
    var boxes = <IntRect>[];
    var stack = <int>[];
    var nextLabel = 0;

    for (var start = 0; start < w * h; start++) {
      if (labels[start] != 0 || probs[start] < binaryThreshold) {
        continue;
      }
      nextLabel++;
      var minX = w, minY = h, maxX = 0, maxY = 0;
      var count = 0;
      var scoreSum = 0.0;
      stack.add(start);
      labels[start] = nextLabel;
      while (stack.isNotEmpty) {
        var index = stack.removeLast();
        var x = index % w;
        var y = index ~/ w;
        count++;
        scoreSum += probs[index];
        if (x < minX) minX = x;
        if (x > maxX) maxX = x;
        if (y < minY) minY = y;
        if (y > maxY) maxY = y;
        for (var d = 0; d < 4; d++) {
          var nx = x + const [1, -1, 0, 0][d];
          var ny = y + const [0, 0, 1, -1][d];
          if (nx < 0 || ny < 0 || nx >= w || ny >= h) continue;
          var ni = ny * w + nx;
          if (labels[ni] == 0 && probs[ni] >= binaryThreshold) {
            labels[ni] = nextLabel;
            stack.add(ni);
          }
        }
      }

      var centerX = (minX + maxX) / 2.0;
      var centerY = (minY + maxY) / 2.0;
      if (centerX >= realW || centerY >= realH) {
        continue;
      }

      if (count < 12 || scoreSum / count < scoreThreshold) {
        continue;
      }
      var boxW = maxX - minX + 1;
      var boxH = maxY - minY + 1;
      if (boxW < 3 || boxH < 3) continue;
      var offset = boxW * boxH * unclipRatio / (2 * (boxW + boxH));
      var scaleX = tileWidth / realW;
      var scaleY = tileHeight / realH;
      boxes.add(
        IntRect(
          ((minX - offset) * scaleX).round(),
          ((minY - offset) * scaleY).round(),
          ((maxX + 1 + offset) * scaleX).round(),
          ((minY - offset) * scaleY).round() +
              ((boxH + 2 * offset) * scaleY).round(),
        ),
      );
    }
    return boxes;
  }

  List<String> _recognizeLinesBatchMulti(
    List<({RgbaImage image, IntRect rect})> lineItems,
    String lang,
    WorkerModelPaths paths, {
    required BatchProfile profile,
    void Function(int batches, int crops)? onStats,
  }) {
    if (lineItems.isEmpty) return const [];
    final modelPath = paths.recModels[lang];
    if (modelPath == null) return List.filled(lineItems.length, '');
    final session = _session(modelPath, forceCpu: isCpuOnlyRecPath(modelPath));
    final height = paths.recHeights[lang] ?? 48;
    // Dead-validation fix: `_charsetFor` has always accepted an
    // `expectedClasses`, but the batch path never passed one, so the
    // dict-lines-vs-model-classes check silently never ran on the main
    // path. The number comes from the session we just opened — probed once
    // per model path via its real output shape (`shape.last`), see
    // [_probeRecClasses].
    final expectedClasses = _probeRecClasses(lang, modelPath, session, height);
    final List<String> charset;
    try {
      charset = _charsetFor(lang, paths, expectedClasses: expectedClasses);
    } on DictMismatchException catch (e) {
      // Only a genuinely missing/unreadable dictionary still skips the lang:
      // without a charset there is nothing to decode with. A mere class
      // count mismatch now warns instead (see [_charsetFor]).
      Log.error('OCR Worker', 'Skipping batch for $lang due to dict mismatch: $e');
      return List.filled(lineItems.length, '');
    }

    final results = List.filled(lineItems.length, '');
    // OOM shrink ladder (plan D-5 / §6.2.3) via the shared
    // [runWithShrinkLadder]: when a run below reports an allocation failure,
    // the whole plan is re-planned at the halved profile and retried; the
    // retreat is sticky for this worker until [release] (the reconfigure
    // point). Stop rules live in the pure [profileAfterOom]: non-OOM errors
    // and recBatch==1 rethrow — the exception is never swallowed, a page
    // that genuinely cannot fit must still fail loudly.
    runWithShrinkLadder(
      start: profile,
      attempt: (p) {
        final batches = planRecBatch(
          lines: [for (var item in lineItems) item.rect],
          height: height,
          widthBuckets: p.widthBuckets,
          maxBatch: p.recBatch,
        );
        for (var batch in batches) {
          final n = batch.rows.length;
          final targetW = batch.maxWidth;
          final targetH = batch.height;
          final totalElements = n * 3 * targetH * targetW;
          final offset = _arena.ensure(0, totalElements);
          _arena.view.fillRange(offset, offset + totalElements, 0.0);

          final plane = targetH * targetW;
          for (var b = 0; b < n; b++) {
            final row = batch.rows[b];
            final item = lineItems[row.originalIndex];
            final resized = _resizeRegion(item.image, row.rect, row.width, targetH);
            final bOffset = offset + b * 3 * plane;
            for (var y = 0; y < targetH; y++) {
              final rowIn = y * row.width;
              final rowOut = y * targetW;
              for (var x = 0; x < row.width; x++) {
                final srcIdx = (rowIn + x) * 4;
                final dstIdx = rowOut + x;
                for (var c = 0; c < 3; c++) {
                  _arena.view[bOffset + c * plane + dstIdx] =
                      (resized[srcIdx + c] / 255.0 - 0.5) / 0.5;
                }
              }
            }
          }

          if (_forceOomPending) {
            // V9-5: pretend this exact run hit the VRAM wall — once per
            // worker lifetime (re-armed by [release]). Thrown inside the try
            // so the debug path walks the same ladder as real OOM. With the
            // dart-define absent, both writes to `_forceOomPending` are the
            // const-false `ocrDebugForceOom`, so this branch can never be
            // taken and the production path is unchanged.
            _forceOomPending = false;
            throw const OrtFfiException(
              'forced out-of-memory (OCR_DEBUG_FORCE_OOM)',
              OrtFfiErrorKind.outOfMemory,
            );
          }

          final argmax = session.runArgmaxGrid(
            {
              session.inputNames.first: OrtInput.nativeFloat32(
                _arena.pointerAt(offset),
                totalElements,
                [n, 3, targetH, targetW],
              ),
            },
            session.outputNames.first,
            batch: n,
            steps: targetW ~/ 8,
            classes: charset.length,
          );

          final steps = argmax.length ~/ n;
          final decodedTexts = ctcGreedyCollapse(
            argmax: argmax,
            batch: n,
            steps: steps,
            charset: charset,
          );

          for (var b = 0; b < n; b++) {
            final origIdx = batch.rows[b].originalIndex;
            results[origIdx] = decodedTexts[b];
          }
        }
        // Stats describe the plan that actually produced this page's texts;
        // failed attempts are deliberately not counted twice.
        onStats?.call(batches.length, lineItems.length);
      },
      onShrink: (next, previous) {
        _oomCeiling = cappedBy(next, _oomCeiling);
        noteDegraded('rec${next.recBatch}<-${previous.recBatch}');
        Log.warning(
          'OCR Perf',
          'OOM: recBatch ${previous.recBatch}->${next.recBatch}',
        );
        // Rows decoded before the throw are recomputed by the retry: results
        // are written per originalIndex and recognition is deterministic, so
        // re-running costs a little and corrupts nothing.
      },
    );

    return results;
  }



  List<String> _mangaOcrBatchMulti(
    List<({RgbaImage image, IntRect bounds})> targets,
    WorkerModelPaths paths, {
    required BatchProfile profile,
    Stopwatch? decStopwatch,
    void Function(int rows, int steps)? onStepStats,
  }) {
    if (targets.isEmpty) return const [];
    if (paths.jaEncoder == null || paths.jaDecoder == null || paths.jaVocab == null) {
      return List.filled(targets.length, '');
    }
    _jaVocab ??= WordPieceVocab.fromFileSync(paths.jaVocab!);
    final encoder = _session(paths.jaEncoder!);
    final decoder = _session(paths.jaDecoder!);

    final results = <String>[];
    // OOM shrink ladder for the manga-ocr (ja) pass — via the same shared
    // [runWithShrinkLadder] that guards rec and det (plan D-5 / §6.2.3).
    // Without it, an allocation failure inside the encoder run or any
    // decoder step of [runArgmaxLastPosition] escaped the whole request, and
    // the shrink only took effect on the *next* request via `cappedBy`. A
    // chunk that dies on allocation is retried here and now at the halved
    // profile, sticky through [_oomCeiling]; the trail event is
    // `dec`-prefixed so diagnostics name the pass that actually retreated.
    // The give-up rule is deliberately shared with rec: [profileAfterOom]
    // stops at recBatch == 1 and the exception rethrows — never swallowed.
    var runProfile = profile;
    var cursor = 0;
    while (cursor < targets.length) {
      void runChunk(BatchProfile plan) {
        final chunkSize = math.min(plan.decBatch, targets.length - cursor);
        final chunkTargets = targets.sublist(cursor, cursor + chunkSize);
        final B = chunkTargets.length;
        final totalPixels = B * 3 * 224 * 224;
        final off = _arena.ensure(0, totalPixels);
        const plane = 224 * 224;
        for (var b = 0; b < B; b++) {
          final t = chunkTargets[b];
          final resized = _resizeRegion(t.image, t.bounds, 224, 224);
          final bOffset = off + b * 3 * plane;
          for (var p = 0; p < plane; p++) {
            final srcIdx = p * 4;
            for (var c = 0; c < 3; c++) {
              _arena.view[bOffset + c * plane + p] =
                  (resized[srcIdx + c] / 255.0 - 0.5) / 0.5;
            }
          }
        }

        final (hiddenShape, hiddenCount) = encoder.runInto(
          {
            encoder.inputNames.first: OrtInput.nativeFloat32(
              _arena.pointerAt(off),
              totalPixels,
              [B, 3, 224, 224],
            ),
          },
          outputName: encoder.outputNames.first,
          dst: _hiddenArena,
          offset: 0,
        );

        final state = BatchDecodeState(
          batch: B,
          maxTokens: MangaOcrTokens.maxTokens,
          startToken: MangaOcrTokens.start,
          eosToken: MangaOcrTokens.eos,
          padToken: MangaOcrTokens.pad,
        );

        decStopwatch?.start();
        var stepsTaken = 0;
        try {
          while (!state.allDone &&
              state.currentStep < MangaOcrTokens.maxTokens) {
            final L = state.currentStep;
            final inputIds = state.flatPrefix(L);
            final nextTokens = decoder.runArgmaxLastPosition(
              {
                'input_ids': OrtInput.int64(inputIds, [B, L]),
                'encoder_hidden_states': OrtInput.nativeFloat32(
                  _hiddenArena.pointerAt(0),
                  hiddenCount,
                  hiddenShape,
                ),
              },
              decoder.outputNames.first,
              batch: B,
              seqLen: L,
            );
            state.appendAll(nextTokens);
            stepsTaken++;
          }
        } finally {
          // A throw inside the step loop used to leave the stopwatch
          // running across the retry; the timing then counted failed
          // attempts as if they had decoded.
          decStopwatch?.stop();
        }
        onStepStats?.call(B, stepsTaken);

        final chunkTexts = state.textOf((tokens) => _jaVocab!.decode(tokens));
        results.addAll(chunkTexts);
        cursor += chunkSize;
      }
      runWithShrinkLadder(
        start: runProfile,
        attempt: runChunk,
        onShrink: (next, previous) {
          runProfile = next;
          _oomCeiling = cappedBy(next, _oomCeiling);
          noteDegraded('dec${next.decBatch}<-${previous.decBatch}');
          Log.warning(
            'OCR Perf',
            'OOM: decBatch ${previous.decBatch}->${next.decBatch}',
          );
          // `results.addAll` is the last statement of a successful attempt,
          // so a failed chunk appended nothing; the retry re-slices the same
          // targets at the smaller chunk size. Decoding is deterministic per
          // crop and `cursor` only advances on success, so a replay can
          // never duplicate or drop a row.
        },
      );
    }

    return results;
  }

  /// Loads (or reuses) the charset for [lang] and cross-checks it against
  /// the opened model's real class count [expectedClasses].
  ///
  /// A mismatch is a **warning, not a failure**, by deliberate choice:
  /// user directories contain dict/model pairs shipped before the pairing
  /// was verifiable, and recognition itself degrades safely — the argmax
  /// runs over the model's own class range and [ctcGreedyCollapse] drops
  /// any index beyond the charset, so a wrong tail-class can at most lose
  /// some glyphs, never crash. Turning this into a hard failure would make
  /// every page of an old install untranslatable over what is, comparatively
  /// speaking, a cosmetic decode defect. Only a missing/unreadable
  /// dictionary (no charset at all) still throws — there the batch genuinely
  /// cannot be decoded.
  ///
  /// When [expectedClasses] is null the probe found nothing and the check is
  /// explicitly skipped ([charsetClassMismatch] returns null for that case);
  /// a missing observation is never treated as a mismatch.
  List<String> _charsetFor(
    String lang,
    WorkerModelPaths paths, {
    int? expectedClasses,
  }) {
    var charset = _charsets[lang];
    final dictPath = paths.recDicts[lang];
    if (charset == null) {
      if (dictPath == null) {
        throw DictMismatchException('No dictionary registered for $lang');
      }
      // loadCharset's expectedClasses parameter *throws*; we load unvalidated
      // and apply the warn-only policy below so the two entry paths
      // (fresh load vs cache hit) cannot disagree about severity.
      charset = loadCharset(dictPath);
      _charsets[lang] = charset;
    }
    final mismatch = charsetClassMismatch(
      lang: lang,
      charsetLength: charset.length,
      expectedClasses: expectedClasses,
      dictPath: dictPath,
    );
    if (mismatch != null) {
      final noteKey = '$lang@$expectedClasses';
      if (_charsetMismatchNoted.add(noteKey)) {
        Log.warning('OCR Worker', '$mismatch — continuing, out-of-range '
            'classes are dropped during CTC collapse');
      }
    }
    return charset;
  }

  /// Cached per-model-path class count for [_charsetFor]; see [_recClasses].
  int? _probeRecClasses(
    String lang,
    String modelPath,
    OrtFfiSession session,
    int height,
  ) {
    if (_recClasses.containsKey(modelPath)) return _recClasses[modelPath];
    final classes = _probeOutputClasses(session, height);
    _recClasses[modelPath] = classes;
    if (classes == null) {
      Log.info(
        'OCR Worker',
        'rec output-class probe failed for $lang ($modelPath); '
        'dict/model class check skipped for this model',
      );
    }
    return classes;
  }

  /// Reads the output class count of an open rec session by running one
  /// minimal zero-filled crop (batch 1, smallest width bucket, the model's
  /// own height) through [OrtFfiSession.runInPlace] and taking `shape.last`
  /// from the real output tensor.
  ///
  /// Why a run instead of metadata: `ort_ffi.dart` exposes `inputShapes()`
  /// only — the declared *output* shape would need a new binding there
  /// (another agent owns that file), and the C-API output-type-info route
  /// was already ruled out for this change. A single 1×3×48×160 forward is
  /// milliseconds, happens once per model per worker lifetime, and reports
  /// what the graph truly outputs — including after any EP-level rewrite.
  ///
  /// Any failure (a fixed-shape graph rejecting the probe, an OOM, a
  /// nameless I/O) returns null: the probe must never break recognition,
  /// which only ever *warns* downstream.
  int? _probeOutputClasses(OrtFfiSession session, int height) {
    try {
      const probeWidth = 160; // the smallest rec bucket every profile ships
      final total = 3 * height * probeWidth;
      final offset = _arena.ensure(0, total);
      _arena.view.fillRange(offset, offset + total, 0.0);
      return session.runInPlace(
        {
          session.inputNames.first: OrtInput.nativeFloat32(
            _arena.pointerAt(offset),
            total,
            [1, 3, height, probeWidth],
          ),
        },
        session.outputNames.first,
        (ptr, shape, elementCount) => shape.isEmpty ? null : shape.last,
      );
    } catch (_) {
      return null;
    }
  }
}

// ===========================================================================
// Pure image math (worker side)
// ===========================================================================


Uint8List _resizeRegion(RgbaImage src, IntRect region, int outW, int outH) {
  var out = Uint8List(outW * outH * 4);
  var srcW = region.width;
  var srcH = region.height;
  for (var y = 0; y < outH; y++) {
    var fy = (y + 0.5) * srcH / outH - 0.5;
    var y0 = fy.floor().clamp(0, srcH - 1);
    var y1 = (y0 + 1).clamp(0, srcH - 1);
    var wy = fy - fy.floor();
    for (var x = 0; x < outW; x++) {
      var fx = (x + 0.5) * srcW / outW - 0.5;
      var x0 = fx.floor().clamp(0, srcW - 1);
      var x1 = (x0 + 1).clamp(0, srcW - 1);
      var wx = fx - fx.floor();
      var outIndex = (y * outW + x) * 4;
      for (var c = 0; c < 4; c++) {
        var p00 = src
            .pixels[((region.top + y0) * src.width + region.left + x0) * 4 + c];
        var p01 = src
            .pixels[((region.top + y0) * src.width + region.left + x1) * 4 + c];
        var p10 = src
            .pixels[((region.top + y1) * src.width + region.left + x0) * 4 + c];
        var p11 = src
            .pixels[((region.top + y1) * src.width + region.left + x1) * 4 + c];
        var top = p00 + (p01 - p00) * wx;
        var bottom = p10 + (p11 - p10) * wx;
        out[outIndex + c] = (top + (bottom - top) * wy).round().clamp(0, 255);
      }
    }
  }
  return out;
}

/// Groups detector line boxes into OCR blocks without joining incompatible
/// neighbouring captions or speech bubbles.
List<List<IntRect>> clusterOcrBoxes(
  List<IntRect> boxes,
  int width,
  int height,
) {
  var parents = List<int>.generate(boxes.length, (i) => i);
  var minThickness = [for (var box in boxes) math.min(box.width, box.height)];
  var maxThickness = [...minThickness];
  var hasHorizontal = [for (var box in boxes) _lineDirection(box) > 0];
  var hasVertical = [for (var box in boxes) _lineDirection(box) < 0];
  var members = [
    for (var i = 0; i < boxes.length; i++) <int>[i],
  ];
  int find(int i) {
    while (parents[i] != i) {
      parents[i] = parents[parents[i]];
      i = parents[i];
    }
    return i;
  }

  var inflated = [
    for (var box in boxes)
      // Inflation controls when neighbouring lines merge into one block.
      // Too generous and two adjacent speech bubbles fuse — the combined
      // crop then squashes both into one OCR input and recognition degrades
      // badly. 0.55 of the short side still bridges the gaps between lines
      // and vertical columns inside one bubble.
      box.inflated(
        (math.min(box.width, box.height) * 0.55).round().clamp(3, 32),
        (math.min(box.width, box.height) * 0.55).round().clamp(3, 32),
        width,
        height,
      ),
  ];
  for (var i = 0; i < boxes.length; i++) {
    for (var j = i + 1; j < boxes.length; j++) {
      if (inflated[i].intersects(inflated[j]) &&
          _compatibleTextLines(boxes[i], boxes[j])) {
        var rootI = find(i);
        var rootJ = find(j);
        if (rootI == rootJ) continue;
        var mergedHorizontal = hasHorizontal[rootI] || hasHorizontal[rootJ];
        var mergedVertical = hasVertical[rootI] || hasVertical[rootJ];
        var mergedMin = math.min(minThickness[rootI], minThickness[rootJ]);
        var mergedMax = math.max(maxThickness[rootI], maxThickness[rootJ]);
        if ((mergedHorizontal && mergedVertical) ||
            mergedMax > math.max(1, mergedMin) * 2.2) {
          continue;
        }
        var direction = mergedHorizontal
            ? 1
            : mergedVertical
            ? -1
            : 0;
        if (!_compatibleTextGroups(
          members[rootI],
          members[rootJ],
          boxes,
          direction,
        )) {
          continue;
        }
        parents[rootJ] = rootI;
        members[rootI].addAll(members[rootJ]);
        minThickness[rootI] = mergedMin;
        maxThickness[rootI] = mergedMax;
        hasHorizontal[rootI] = mergedHorizontal;
        hasVertical[rootI] = mergedVertical;
      }
    }
  }
  var groups = <int, List<IntRect>>{};
  for (var i = 0; i < boxes.length; i++) {
    groups.putIfAbsent(find(i), () => []).add(boxes[i]);
  }
  return groups.values.toList();
}

int _lineDirection(IntRect box) {
  if (box.width >= box.height * 1.25) return 1;
  if (box.height >= box.width * 1.25) return -1;
  return 0;
}

bool _compatibleTextLines(IntRect a, IntRect b) {
  var directionA = _lineDirection(a);
  var directionB = _lineDirection(b);
  if (directionA != 0 && directionB != 0 && directionA != directionB) {
    return false;
  }

  var thicknessA = math.min(a.width, a.height);
  var thicknessB = math.min(b.width, b.height);
  if (math.max(thicknessA, thicknessB) >
      math.max(1, math.min(thicknessA, thicknessB)) * 2.2) {
    return false;
  }

  var direction = directionA != 0 ? directionA : directionB;
  if (direction > 0) {
    var stacked =
        _axisOverlap(a.left, a.right, b.left, b.right) >=
        math.min(a.width, b.width) * 0.25;
    var shortFragments =
        a.width <= thicknessA * 12 && b.width <= thicknessB * 12;
    var sameLine =
        shortFragments &&
        _axisOverlap(a.top, a.bottom, b.top, b.bottom) >=
            math.min(a.height, b.height) * 0.6 &&
        _axisGap(a.left, a.right, b.left, b.right) <=
            _sameLineGap(thicknessA, thicknessB);
    return stacked || sameLine;
  }
  if (direction < 0) {
    var adjacentColumns =
        _axisOverlap(a.top, a.bottom, b.top, b.bottom) >=
        math.min(a.height, b.height) * 0.25;
    var shortFragments =
        a.height <= thicknessA * 12 && b.height <= thicknessB * 12;
    var sameColumn =
        shortFragments &&
        _axisOverlap(a.left, a.right, b.left, b.right) >=
            math.min(a.width, b.width) * 0.6 &&
        _axisGap(a.top, a.bottom, b.top, b.bottom) <=
            _sameLineGap(thicknessA, thicknessB);
    return adjacentColumns || sameColumn;
  }
  return true;
}

bool _compatibleTextGroups(
  List<int> groupA,
  List<int> groupB,
  List<IntRect> boxes,
  int direction,
) {
  for (var indexA in groupA) {
    for (var indexB in groupB) {
      var a = boxes[indexA];
      var b = boxes[indexB];
      if (direction > 0) {
        var sameLine =
            _axisOverlap(a.top, a.bottom, b.top, b.bottom) >=
            math.min(a.height, b.height) * 0.6;
        if (!sameLine &&
            _axisOverlap(a.left, a.right, b.left, b.right) <
                math.min(a.width, b.width) * 0.25) {
          return false;
        }
      } else if (direction < 0) {
        var sameColumn =
            _axisOverlap(a.left, a.right, b.left, b.right) >=
            math.min(a.width, b.width) * 0.6;
        if (!sameColumn &&
            _axisOverlap(a.top, a.bottom, b.top, b.bottom) <
                math.min(a.height, b.height) * 0.25) {
          return false;
        }
      } else if (!_compatibleTextLines(a, b)) {
        return false;
      }
    }
  }
  return true;
}

int _axisOverlap(int startA, int endA, int startB, int endB) =>
    math.max(0, math.min(endA, endB) - math.max(startA, startB));

int _axisGap(int startA, int endA, int startB, int endB) =>
    math.max(0, math.max(startA, startB) - math.min(endA, endB));

/// Largest run-direction gap two fragments of one line may have. Word spacing
/// and detector splits routinely leave most of a glyph height between pieces,
/// so this sits close to the line thickness rather than well below it.
double _sameLineGap(int thicknessA, int thicknessB) =>
    math.max(thicknessA, thicknessB) * 0.8;

IntRect _boundsOf(List<IntRect> boxes) {
  var result = IntRect(
    boxes[0].left,
    boxes[0].top,
    boxes[0].right,
    boxes[0].bottom,
  );
  for (var box in boxes.skip(1)) {
    result.left = math.min(result.left, box.left);
    result.top = math.min(result.top, box.top);
    result.right = math.max(result.right, box.right);
    result.bottom = math.max(result.bottom, box.bottom);
  }
  return result;
}



/// Estimates (backgroundColor, textColor) for a region by separating the two
/// dominant colour classes inside it.
///
/// The block's pixels split into a background class (bubble fill, the larger
/// share) and a text class (the strokes). An Otsu luminance threshold labels
/// each pixel, then the mean colour of each class is taken — so the text colour
/// is the *actual* ink (a coloured SFX, a grey caption) rather than a flat
/// dark/light guess, and the background is the *actual* fill sampled from the
/// non-stroke pixels rather than a ring outside the box that may fall on
/// artwork. A ring sample still seeds the background when the split is
/// degenerate (near-uniform crop), and the returned text colour is nudged to
/// keep a minimum contrast against the background so it stays legible.
(int, int) _sampleColors(RgbaImage image, IntRect rect) {
  var w = image.width;
  var left = rect.left.clamp(0, w - 1);
  var top = rect.top.clamp(0, image.height - 1);
  var right = rect.right.clamp(1, w);
  var bottom = rect.bottom.clamp(1, image.height);
  var pixels = image.pixels;

  // Stride so a big block stays cheap; small blocks read every pixel.
  var stepX = math.max(1, (right - left) ~/ 48);
  var stepY = math.max(1, (bottom - top) ~/ 48);

  var lum = <int>[];
  var pr = <int>[], pg = <int>[], pb = <int>[];
  for (var y = top; y < bottom; y += stepY) {
    for (var x = left; x < right; x += stepX) {
      var i = (y * w + x) * 4;
      var r = pixels[i], g = pixels[i + 1], b = pixels[i + 2];
      pr.add(r);
      pg.add(g);
      pb.add(b);
      lum.add((0.299 * r + 0.587 * g + 0.114 * b).round().clamp(0, 255));
    }
  }

  int ringMedianColor() {
    var ring = rect.inflated(6, 6, w, image.height);
    var rs = <int>[], gs = <int>[], bs = <int>[];
    void s(int x, int y) {
      var i = (y * w + x) * 4;
      rs.add(pixels[i]);
      gs.add(pixels[i + 1]);
      bs.add(pixels[i + 2]);
    }

    for (var x = ring.left; x < ring.right; x += 3) {
      s(x, ring.top);
      s(x, ring.bottom - 1);
    }
    for (var y = ring.top; y < ring.bottom; y += 3) {
      s(ring.left, y);
      s(ring.right - 1, y);
    }
    int med(List<int> v) {
      if (v.isEmpty) return 255;
      v.sort();
      return v[v.length ~/ 2];
    }

    return 0xFF000000 | (med(rs) << 16) | (med(gs) << 8) | med(bs);
  }

  if (lum.length < 8) {
    var bg = ringMedianColor();
    var bgLum =
        0.299 * ((bg >> 16) & 0xFF) +
        0.587 * ((bg >> 8) & 0xFF) +
        0.114 * (bg & 0xFF);
    return (bg, bgLum < 128 ? 0xFFF5F5F5 : 0xFF202020);
  }

  var threshold = _otsuOf(lum);
  var loSumR = 0, loSumG = 0, loSumB = 0, loN = 0;
  var hiSumR = 0, hiSumG = 0, hiSumB = 0, hiN = 0;
  for (var i = 0; i < lum.length; i++) {
    if (lum[i] <= threshold) {
      loSumR += pr[i];
      loSumG += pg[i];
      loSumB += pb[i];
      loN++;
    } else {
      hiSumR += pr[i];
      hiSumG += pg[i];
      hiSumB += pb[i];
      hiN++;
    }
  }

  // The background is the larger class; text is the smaller. A block that is
  // almost entirely one class (no real strokes visible) falls back to the ring.
  if (loN == 0 || hiN == 0) {
    var bg = ringMedianColor();
    var bgLum =
        0.299 * ((bg >> 16) & 0xFF) +
        0.587 * ((bg >> 8) & 0xFF) +
        0.114 * (bg & 0xFF);
    return (bg, bgLum < 128 ? 0xFFF5F5F5 : 0xFF202020);
  }

  int packMean(int sr, int sg, int sb, int n) =>
      0xFF000000 | ((sr ~/ n) << 16) | ((sg ~/ n) << 8) | (sb ~/ n);
  var loColor = packMean(loSumR, loSumG, loSumB, loN);
  var hiColor = packMean(hiSumR, hiSumG, hiSumB, hiN);

  // Background = majority class, text = minority class.
  int bgColor, textColor;
  if (loN >= hiN) {
    bgColor = loColor;
    textColor = hiColor;
  } else {
    bgColor = hiColor;
    textColor = loColor;
  }

  textColor = _ensureContrast(textColor, bgColor);
  return (bgColor, textColor);
}

/// Otsu threshold over a luminance sample list (worker-side twin of the one in
/// inpaint.dart, which takes a Uint8List).
int _otsuOf(List<int> lum) {
  var hist = Int32List(256);
  for (var l in lum) {
    hist[l]++;
  }
  var total = lum.length;
  var sum = 0.0;
  for (var t = 0; t < 256; t++) {
    sum += t * hist[t];
  }
  var sumB = 0.0;
  var wB = 0;
  var maxVar = -1.0;
  var threshold = 127;
  for (var t = 0; t < 256; t++) {
    wB += hist[t];
    if (wB == 0) continue;
    var wF = total - wB;
    if (wF == 0) break;
    sumB += t * hist[t];
    var mB = sumB / wB;
    var mF = (sum - sumB) / wF;
    var between = wB * wF * (mB - mF) * (mB - mF);
    if (between > maxVar) {
      maxVar = between;
      threshold = t;
    }
  }
  return threshold;
}

/// Nudges [text] away from [bg] when their luminance is too close, so the drawn
/// text stays readable. Keeps [text]'s hue, only pushing it darker or lighter.
int _ensureContrast(int text, int bg) {
  double lumOf(int c) =>
      0.299 * ((c >> 16) & 0xFF) +
      0.587 * ((c >> 8) & 0xFF) +
      0.114 * (c & 0xFF);
  var tl = lumOf(text);
  var bl = lumOf(bg);
  if ((tl - bl).abs() >= 60) return text;
  // Too close: fall back to a high-contrast neutral against the background.
  return bl < 128 ? 0xFFF5F5F5 : 0xFF202020;
}

double _iou(IntRect a, IntRect b) {
  var left = math.max(a.left, b.left);
  var top = math.max(a.top, b.top);
  var right = math.min(a.right, b.right);
  var bottom = math.min(a.bottom, b.bottom);
  if (left >= right || top >= bottom) return 0;
  var inter = (right - left) * (bottom - top);
  return inter / (a.area + b.area - inter);
}
