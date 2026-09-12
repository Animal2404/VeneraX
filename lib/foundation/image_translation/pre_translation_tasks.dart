import 'dart:async';
import 'dart:io';
import 'dart:math' as math;

import 'package:flutter/foundation.dart';
import 'package:venera/foundation/app.dart';
import 'package:venera/foundation/appdata.dart';
import 'package:venera/foundation/background_keepalive.dart';
import 'package:venera/foundation/comic_source/comic_source.dart';
import 'package:venera/foundation/comic_type.dart';
import 'package:venera/foundation/image_translation/ordered_group_committer.dart';
import 'package:venera/foundation/image_translation/ort_capabilities.dart';
import 'package:venera/foundation/image_translation/page_prefetcher.dart';
import 'package:venera/foundation/image_translation/rate_limiter.dart';
import 'package:venera/foundation/image_translation/translation_config.dart';
import 'package:venera/foundation/image_translation/translation_models.dart';
import 'package:venera/foundation/image_translation/translation_performance_config.dart';
import 'package:venera/foundation/image_translation/translation_service.dart';
import 'package:venera/foundation/image_translation/translation_store.dart';
import 'package:venera/foundation/image_translation/translation_types.dart';
import 'package:venera/foundation/image_translation/translation_worker.dart';
import 'package:venera/foundation/local.dart';
import 'package:venera/foundation/log.dart';
import 'package:venera/network/images.dart';

enum PreTranslationTaskStatus { running, paused, completed, canceled, failed }

/// One chapter queued for background pre-translation.
class PreTranslationChapter {
  PreTranslationChapter({
    required this.eid,
    required this.title,
    this.total = 0,
    this.done = 0,
    this.failed = 0,
    this.canceled = false,
    Set<int>? failedPages,
  }) : failedPages = failedPages ?? <int>{};

  /// Source chapter id (the eid passed to loadComicPages / image keys). For a
  /// comic without chapters this is '0'.
  final String eid;
  final String title;

  /// Page count, resolved lazily when the chapter starts.
  int total;
  int done;
  int failed;

  /// Set when the user cancels just this chapter of a still-running job. The
  /// worker loop skips a canceled chapter (both the forward pass and the retry
  /// pass), so the rest of the job keeps going. Not persisted as "running": a
  /// canceled chapter is simply left where it stopped and never resumed.
  bool canceled;

  /// Indices (into the resolved page-key list) of the pages that failed this
  /// run, so a retry can re-run exactly those and leave the succeeded pages
  /// alone. Kept in lockstep with [failed]: a page enters here when it fails
  /// and leaves when a retry succeeds, so `failedPages.length == failed` for a
  /// chapter recorded by the current version. Persisted so a retry survives a
  /// restart. Older persisted tasks lack it (empty set) — a retry then falls
  /// back to re-scanning the whole chapter, which is cheap because rendered
  /// pages skip via hasRenderedPage.
  final Set<int> failedPages;

  Map<String, dynamic> toJson() => {
    'eid': eid,
    'title': title,
    'total': total,
    'done': done,
    'failed': failed,
    'canceled': canceled,
    'failedPages': failedPages.toList(),
  };

  factory PreTranslationChapter.fromJson(Map<String, dynamic> json) {
    return PreTranslationChapter(
      eid: json['eid']?.toString() ?? '0',
      title: json['title']?.toString() ?? '',
      total: json['total'] ?? 0,
      done: json['done'] ?? 0,
      failed: json['failed'] ?? 0,
      canceled: json['canceled'] == true,
      failedPages: (json['failedPages'] as List? ?? [])
          .map((e) => e is int ? e : int.tryParse('$e'))
          .whereType<int>()
          .toSet(),
    );
  }
}

/// A background job that pre-translates selected chapters of one comic so the
/// rendered pages are cached before the user opens the reader.
///
/// It reuses [ImageTranslationService.translateOne] and therefore writes to
/// the exact cache keys the reader reads from — a pre-translated page shows
/// instantly with no in-reader wait.
class PreTranslationTask {
  PreTranslationTask({
    required this.id,
    required this.cid,
    required this.sourceKey,
    required this.comicType,
    required this.title,
    required this.chapters,
    required this.createdAt,
    this.cover = '',
    this.status = PreTranslationTaskStatus.running,
    this.finishedAt,
    this.finalSummary,
  });

  final String id;
  final String cid;
  final String sourceKey;
  final ComicType comicType;
  final String title;
  final String cover;
  final List<PreTranslationChapter> chapters;
  final DateTime createdAt;
  PreTranslationTaskStatus status;
  DateTime? finishedAt;

  /// The card's last live view, frozen at the moment the job ended (natural
  /// finish, failure or cancel). Rates, per-phase page counts and the engine
  /// row used to live only in [PreTranslationActivity] and the worker fold,
  /// both of which are gone once the loop exits — so a finished card showed
  /// none of them. This is plain JSON inside the task object itself: it rides
  /// the existing history persistence (appdata implicit data), **not** a new
  /// database table. Null for jobs recorded before this existed, which the
  /// card renders from committed counters with `—` rates (never fake zeros).
  PreTranslationTaskSummary? finalSummary;

  String get comicKey => '$cid@$sourceKey';

  /// This comic's own language pair + text-removal mode. Resolved live, exactly
  /// like [ImageTranslationService.cacheKeyFor] does, so the config and the
  /// cache keys a job writes to always describe the same generation.
  TranslationConfig get config => TranslationConfig.of(cid, sourceKey);

  bool get isRunning => status == PreTranslationTaskStatus.running;

  int get total => chapters.fold(0, (sum, c) => sum + c.total);
  int get done => chapters.fold(0, (sum, c) => sum + c.done);
  int get failed => chapters.fold(0, (sum, c) => sum + c.failed);

  /// Whether any chapter has failed pages that could be retried. A canceled
  /// chapter is excluded: both the forward loop and the retry sweep skip it, so
  /// its failures are unreachable and offering a retry for them would do
  /// nothing. Re-running such a chapter goes through the picker's re-translate.
  bool get hasFailures => chapters.any((c) => !c.canceled && c.failed > 0);

  /// Overall progress across the whole job, weighted by chapters rather than
  /// pages. Each chapter contributes an equal 1/N slice; a chapter whose page
  /// count is not resolved yet (total == 0) counts as 0% until it starts, and a
  /// fully processed chapter counts as 100%. This keeps the percentage
  /// representative of the entire comic (all selected chapters), and monotonic,
  /// instead of tracking only the page counts of chapters that have already
  /// begun — which made the earlier page-based ratio jump around as new
  /// chapters resolved their totals.
  double get progress {
    if (chapters.isEmpty) return 0;
    var sum = 0.0;
    for (var c in chapters) {
      if (c.total <= 0) continue;
      sum += ((c.done + c.failed) / c.total).clamp(0.0, 1.0);
    }
    return sum / chapters.length;
  }

  Map<String, dynamic> toJson() => {
    'id': id,
    'cid': cid,
    'sourceKey': sourceKey,
    'comicType': comicType.value,
    'title': title,
    'cover': cover,
    'createdAt': createdAt.toIso8601String(),
    'finishedAt': finishedAt?.toIso8601String(),
    'status': status.name,
    'finalSummary': finalSummary?.toJson(),
    'chapters': chapters.map((c) => c.toJson()).toList(),
  };

  factory PreTranslationTask.fromJson(Map<String, dynamic> json) {
    return PreTranslationTask(
      id: json['id']?.toString() ?? '',
      cid: json['cid']?.toString() ?? '',
      sourceKey: json['sourceKey']?.toString() ?? '',
      comicType: ComicType(json['comicType'] ?? 0),
      title: json['title']?.toString() ?? '',
      cover: json['cover']?.toString() ?? '',
      createdAt: DateTime.tryParse(json['createdAt'] ?? '') ?? DateTime.now(),
      finishedAt: DateTime.tryParse(json['finishedAt'] ?? ''),
      status: PreTranslationTaskStatus.values.firstWhere(
        (e) => e.name == json['status'],
        orElse: () => PreTranslationTaskStatus.completed,
      ),
      finalSummary: json['finalSummary'] is Map
          ? PreTranslationTaskSummary.fromJson(
              Map<String, dynamic>.from(json['finalSummary'] as Map),
            )
          : null,
      chapters: (json['chapters'] as List? ?? [])
          .whereType<Map>()
          .map(
            (e) => PreTranslationChapter.fromJson(Map<String, dynamic>.from(e)),
          )
          .toList(),
    );
  }
}

/// One step of the stage-1 sweep's page accounting, as a pure function.
///
/// The sweep has two different notions of "this page is done", and collapsing
/// them was S1: a page whose fetch failed, or whose OCR chunk threw, is
/// *settled* — the sweep will not visit it again, so the bar's denominator must
/// move or the job reads as frozen — but it was never *recognized*, and the
/// figure printed next to the page total is called "recognized X / total".
/// Crediting a failure there (and, worse, sampling it into [_sweepRate]) makes
/// "已识别 X/Y" claim pages the OCR never read, and inflates the window's page
/// count while its wall-clock span stays the same: a rate too high and an ETA
/// too optimistic. The repository's rule is the one asserted here — unreadable
/// is N/A, never a fake credit.
///
/// [settledPages] / [recognizedPages] are the running totals before this call,
/// [chunkPages] the pages this chunk settled, [storedPages] the subset whose
/// `putOcr` succeeded (0 on the throw path and for a fetch failure).
///
/// Returned `completedPages` is the bar's page-equivalent (`settled × 0.55`,
/// the phase weight the sweep has always used) and `recognizedPages` is the raw
/// count for the "recognized X / total" line. `tallied` reports whether this
/// call changed either total, so a caller can tell "settled but not recognized"
/// (advance the bar, say nothing about recognition, sample nothing) from a real
/// recognition step.
///
/// Public and top-level for the same reason `tallyClusterLineLoss` is: the
/// arithmetic lives two GPU calls deep inside a private sweep and no test can
/// drive that (R3 — no isolate, no ONNX session, no GPU).
({
  int settledPages,
  int recognizedPages,
  double completedPages,
  bool tallied,
}) sweepPageAccounting({
  required int settledPages,
  required int recognizedPages,
  required int chunkPages,
  required int storedPages,
}) {
  // `storedPages` can never exceed the chunk: the producer counts a stored page
  // once, inside the chunk's own loop. The clamp is belt-and-braces so a future
  // caller cannot credit recognition for pages this chunk never carried.
  final stored = storedPages.clamp(0, chunkPages);
  final settled = settledPages + (chunkPages > 0 ? chunkPages : 0);
  final recognized = recognizedPages + stored;
  return (
    settledPages: settled,
    recognizedPages: recognized,
    completedPages: settled * 0.55,
    tallied: settled != settledPages || recognized != recognizedPages,
  );
}

/// Live view of one in-flight page group.
///
/// Never persisted and never folded into [PreTranslationChapter.done] /
/// `failed`: the resume cursor is `done + failed` and requires those to stay a
/// contiguous *committed* prefix, so a per-page stage change must not touch
/// them. This is the parallel, display-only channel instead.
class PreTranslationGroupActivity {
  PreTranslationGroupActivity({required this.index, required this.pageCount});

  /// Group order within the chapter, which is also its commit order.
  final int index;
  final int pageCount;
  TranslationStage stage = TranslationStage.fetching;

  /// Pages of this group already accounted for, in page units and weighted by
  /// the phase each page has reached — so a group that is minutes from
  /// committing still reads as partial progress rather than as nothing.
  double completedPages = 0;

  /// Raw page count settled by the stage-1 recognition sweep. Only the
  /// [PreTranslationActivity.ocrSweepIndex] slot ever sets it; everywhere else
  /// it stays null. Purely additive display data: unlike [completedPages] it
  /// is not phase-weighted (8 recognized pages read as 8, not as 8×0.55), and
  /// like [completedPages] it never feeds the resume cursor.
  int? recognizedPages;

  /// Moves [stage] forward and reports whether this change is the moment the
  /// group *crossed from before-rendering into rendering*.
  ///
  /// That crossing is exactly when the group's translation response landed —
  /// [ImageTranslationService.translatePageGroup] only enters its render loop
  /// after the batch call returned (a failed batch also reports back and
  /// settles, which is why the failure path counts too, matching
  /// [PreTranslationActivity.translatedThrough]'s "the request came back"
  /// semantics). The check fires true once per group: every later
  /// `rendering` report sees a previous stage that is already ≥ rendering.
  /// This is how the translation stream gets sampled without adding a second
  /// instrumentation path to the service (the service's own GroupPerf log
  /// stays the log it is; the crossing is already visible here).
  bool noteStage(TranslationStage stage) {
    var crossed =
        this.stage.index < TranslationStage.rendering.index &&
        stage.index >= TranslationStage.rendering.index;
    this.stage = stage;
    return crossed;
  }
}

/// What a running job is doing right now, beyond its committed counters.
class PreTranslationActivity {
  /// 1-based index of the chapter being processed; 0 before the first starts.
  int chapterIndex = 0;
  String chapterTitle = '';

  /// eid of the chapter being processed, so a per-chapter display can tell
  /// whether [bufferedPages] belongs to it.
  String chapterEid = '';

  final Map<int, PreTranslationGroupActivity> groups = {};

  /// Pages of groups that finished and handed their counts to the committer,
  /// but which are still buffered behind an earlier, slower group.
  ///
  /// These pages are genuinely rendered and cached; only the resume cursor
  /// cannot move past them yet, because `done + failed` has to stay a
  /// contiguous prefix. Keeping them here lets the display credit real work
  /// without touching the chapter counters. Reset per chapter, since each
  /// chapter gets its own committer.
  int bufferedDone = 0;
  int bufferedFailed = 0;

  int get bufferedPages => bufferedDone + bufferedFailed;

  /// Key of the pseudo-group that carries the stage-1 recognition sweep
  /// (created in `_runChapterOcrPass`). It is not a commit group — no counts
  /// ever flow through it — but it lives in [groups] so the head stage and the
  /// stage breakdown already see the sweep as "what the job is doing".
  static const int ocrSweepIndex = -1;

  /// The live stage-1 sweep slot, or null when no sweep is running.
  PreTranslationGroupActivity? get ocrSweep => groups[ocrSweepIndex];

  bool get sweepActive => ocrSweep != null;

  /// Raw pages the running sweep has recognized so far (0 when none runs).
  /// This is the number that was invisible to the page line whenever a real
  /// 82-page chapter showed "页数: 0/82" while the log already said
  /// `pages=[0..7]`: the sweep's credit sat in [completedPages] with the 0.55
  /// phase weight and only ever reached the bar, never a page figure.
  int get ocrRecognizedPages => ocrSweep?.recognizedPages ?? 0;

  /// Pages the sweep was handed at its start (cached pages are already
  /// excluded, so this can be smaller than the chapter total).
  int get ocrSweepTotal => ocrSweep?.pageCount ?? 0;

  int get ocrSweepPendingPages => math.max(0, ocrSweepTotal - ocrRecognizedPages);

  // ---------------------------------------------------------------------
  // Per-phase completion stamps.
  //
  // The card has to be able to say "识别完 37 张用了 1:12" and then *stop* —
  // the elapsed time of a phase that is over is a fact, not a live figure, and
  // deriving it from `now` would keep it growing after the phase ended (the
  // defect this replaced: every row looked alive until the whole job ended).
  //
  // Each stamp is written once, at the first observation of that phase
  // covering every page, by [notePhaseCompletions] — called from the manager's
  // activity-notify path, so a background job gets the same accuracy as one
  // being watched (no dependence on the card being built or visible).
  // ---------------------------------------------------------------------

  DateTime? recognizedDoneAt;
  DateTime? translatedDoneAt;
  DateTime? renderedDoneAt;

  /// When recognition actually began (the first chunk reached the worker).
  /// Distinct from `task.createdAt`: the job exists from the moment the user
  /// presses the button, and the gap between the two is downloads and model
  /// loading — real time, but not "recognition".
  DateTime? ocrStartedAt;

  /// When the first translation request went out, and when the first answer
  /// came back. The pair is what makes the silence in between *visible*: that
  /// wait is one long `await` with no natural progress of its own, so a card
  /// that can say "waiting since 12:03" is the difference between "slow" and
  /// "stuck".
  DateTime? requestSentAt;
  DateTime? firstResponseAt;

  /// Set once the six-timestamp timeline has been logged for this job, so a
  /// finished card that keeps rebuilding cannot repeat the line.
  bool timelineLogged = false;

  /// Stamps the two figures that only the pipeline's own callbacks can see.
  ///
  /// Written on first observation only: chunks finish out of order, and a
  /// later chunk entering recognition must not move the phase's start line
  /// backwards.
  void notePipelineStage(TranslationStage stage, DateTime at) {
    if (ocrStartedAt == null &&
        (stage == TranslationStage.loadingModel ||
            stage == TranslationStage.recognizing)) {
      ocrStartedAt = at;
    }
    if (requestSentAt == null && stage == TranslationStage.translating) {
      requestSentAt = at;
    }
  }

  /// Records the first translation answer for this job, once.
  void noteFirstResponse(DateTime at) {
    firstResponseAt ??= at;
  }

  /// Records the three completion stamps. Idempotent: each one is written only
  /// while it is still null, so a rebuild, a re-entrant notify or a late call
  /// cannot move a phase's finish line.
  void notePhaseCompletions(PreTranslationTask task, DateTime now) {
    if (task.total <= 0) return;
    if (recognizedDoneAt == null && recognizedThrough(task) >= task.total) {
      recognizedDoneAt = now;
    }
    if (translatedDoneAt == null && translatedThrough(task) >= task.total) {
      translatedDoneAt = now;
    }
    if (renderedDoneAt == null && renderedThrough(task) >= task.total) {
      renderedDoneAt = now;
    }
    if (!timelineLogged && renderedDoneAt != null) {
      timelineLogged = true;
      logPhaseTimeline(task, this);
    }
  }

  /// Pages settled for display: committed plus buffered. Never write this back
  /// into [PreTranslationChapter.done] — that would break the resume cursor.
  int liveDone(PreTranslationTask task) => task.done + bufferedDone;

  int liveFailed(PreTranslationTask task) => task.failed + bufferedFailed;

  /// Pages the job is finished with, successes and failures alike — the same
  /// set [PreTranslationTask.progress] counts. Page counters must report this
  /// rather than [liveDone], or a failed page freezes the number while the bar
  /// keeps advancing.
  int liveProcessed(PreTranslationTask task) =>
      liveDone(task) + liveFailed(task);

  /// Stage of the lowest-numbered live group. Counts commit in group order, so
  /// that group is the one holding the cursor — it answers "why hasn't the
  /// number moved" better than whichever group changed stage most recently.
  TranslationStage? get headStage {
    PreTranslationGroupActivity? head;
    for (var g in groups.values) {
      if (head == null || g.index < head.index) head = g;
    }
    return head?.stage;
  }

  /// How many live groups sit in each stage, for the expanded breakdown.
  Map<TranslationStage, int> get stageCounts {
    var counts = <TranslationStage, int>{};
    for (var g in groups.values) {
      counts[g.stage] = (counts[g.stage] ?? 0) + 1;
    }
    return counts;
  }

  // ---------------------------------------------------------------------
  // Per-phase overall numerators (display only).
  //
  // Each returns an "X / task.total pages" figure for one phase, in one
  // number: committed + buffered pages plus the in-flight credit that phase
  // has earned. They read [groups] and the chapter counters but never write
  // anything — [liveProcessed] and [completedPages] keep the exact meaning
  // the tests pin down, and the resume cursor is untouched.
  // ---------------------------------------------------------------------

  /// The chapter the activity currently points at, by identity of its eid,
  /// or null when it names nothing (between chapters / before the first).
  PreTranslationChapter? _chapterOf(PreTranslationTask task) {
    if (chapterEid.isEmpty) return null;
    return task.chapters.where((c) => c.eid == chapterEid).firstOrNull;
  }

  /// Pages whose text is recognized.
  ///
  /// During the sweep this is the committed/buffered base plus the sweep's
  /// raw count — the live value that was previously only visible as a
  /// fractional bar credit, the number the user never saw move. After the
  /// sweep, every *remaining* page of that chapter has passed recognition
  /// (stage 2 only launches once it finished, and a fully-cached chapter
  /// never needed it), so the whole chapter counts. Buffered pages are
  /// subtracted from that credit because the base already includes them —
  /// counting them twice would overshoot the chapter.
  int recognizedThrough(PreTranslationTask task) {
    var processed = liveProcessed(task);
    var extra = 0;
    if (sweepActive) {
      extra = ocrRecognizedPages;
    } else {
      var chapter = _chapterOf(task);
      if (chapter != null && chapter.total > 0) {
        extra = math.max(
          0,
          chapter.total - (chapter.done + chapter.failed) - bufferedPages,
        );
      }
    }
    var v = processed + extra;
    var total = task.total;
    return total > 0 ? math.min(v, total) : v;
  }

  /// Pages whose translation request has come back: committed/buffered pages
  /// plus in-flight groups that moved past `translating` into rendering. A
  /// group enters `rendering` only when its batch response landed, so its
  /// whole count is honest credit; pages that later failed were still
  /// translated, which is why the base is `liveProcessed`, not `liveDone`.
  int translatedThrough(PreTranslationTask task) {
    var v = liveProcessed(task);
    for (var g in groups.values) {
      if (g.index >= 0 &&
          g.stage.index > TranslationStage.translating.index) {
        v += g.pageCount;
      }
    }
    var total = task.total;
    return total > 0 ? math.min(v, total) : v;
  }

  /// Pages fully drawn and counted — committed plus buffered. In-flight
  /// rendering groups are deliberately *not* added: their images land page by
  /// page but the unit of settlement is the group, and crediting the whole
  /// group the moment its first page draws would overshoot on multi-page
  /// groups.
  int renderedThrough(PreTranslationTask task) => liveProcessed(task);

  // ---------------------------------------------------------------------
  // Throughput (display only, window-based).
  //
  // Three separate streams, one per pipeline phase, because the phases
  // alternate and sharing one number printed a "translation throughput"
  // computed from OCR chunks — the exact class of wrong-but-plausible
  // figure this card exists to remove. Recognition is fed by the sweep
  // (stage 1), translation by each group's translating→rendering crossing
  // (the moment its LLM answer landed), rendering by group commits (a
  // committed page is a drawn page). All three are the same
  // [_ThroughputTracker] mechanism; what differs is only which producer
  // calls `add`.
  // ---------------------------------------------------------------------

  final _sweepRate = _ThroughputTracker();
  final _translateRate = _ThroughputTracker();
  final _pipelineRate = _ThroughputTracker();

  /// Stage-3 draw cost (pages drawn / milliseconds spent drawing), fed by the
  /// structured [GroupPerf] the translation service reports. Separate from
  /// [_pipelineRate] because that one counts *commits* — pages the job is
  /// finished with, which is what the ETA divides — while this one measures the
  /// drawing phase alone, which is what the Rendered row's `ms/页` claims.
  final _renderWork = _ThroughputTracker();

  /// Rolling pages/min of the recognition sweep, or null when it has not run
  /// long enough to say (never 0 — see [_ThroughputTracker]).
  double? get sweepPagesPerMinute => _sweepRate.pagesPerMinute;

  /// Full figure set of each stream, including the first-sample (warm-up) rate
  /// and the sample count the card prints next to it (plan 12-B/12-C). The
  /// `…PagesPerMinute` getters above stay the *stable* wall-clock numbers the
  /// ETA is allowed to use.
  PhaseRates get sweepRates => _sweepRate.view;
  PhaseRates get translateRates => _translateRate.view;
  PhaseRates get commitRates => _pipelineRate.view;

  /// Draw-phase cost per page (`ms/页` of the Rendered row); null until a group
  /// reported a measured render, never 0 for a group that drew nothing.
  PhaseRates get renderWorkRates => _renderWork.view;

  /// When the sweep last credited a page; lets readers notice the stream went
  /// quiet instead of quoting the last known rate forever.
  DateTime? get lastOcrSampleAt => _sweepRate.lastSampleAt;

  /// When the last group committed. The card's estimate decays against it
  /// between commits, so "预计还需" counts down every second instead of only
  /// jumping when a batch lands (the reported defect: "已用时每秒跳，预计还需
  /// 不动"). See [decayEta].
  DateTime? get lastCommitSampleAt => _pipelineRate.lastSampleAt;

  /// Stable (wall-clock window) pages/min of answered translation requests.
  /// Null until two of them span a few seconds — use [translateRates] for what
  /// the card shows. The fold additionally hides it while a sweep owns the card
  /// (stage-2 requests cannot land mid-sweep anyway — chapters run strictly in
  /// sequence).
  double? get translatePagesPerMinute => _translateRate.pagesPerMinute;

  /// Rolling pages/min of committed (fully translated + rendered) pages.
  /// This is the *rendering* stream's rate: the commit is exactly when a
  /// group's pages are drawn, cached and counted.
  double? get pagesPerMinute => _pipelineRate.pagesPerMinute;

  /// Called by the sweep once per OCR chunk (and per fetch failure). Cheap:
  /// one append plus an occasional window trim, on the producer side, so the
  /// UI's build path only reads a pre-computed double. [workMs] is that chunk's
  /// own measured wall time — the duration that lets the very first chunk
  /// already carry a rate (plan 12-C). A fetch failure has no such number and
  /// says so by passing null, which keeps it out of the ms/page denominator.
  void recordOcrPages(int pages, {int? workMs, DateTime? at}) =>
      _sweepRate.add(pages, workMs: workMs, at: at);

  /// Called once per group whose [GroupPerf] came back, i.e. once per answered
  /// translation request, with the pages that request carried and the wall
  /// time it spent on them. This replaces the translating→rendering crossing
  /// as the translation stream's producer: the crossing was a *proxy* for
  /// "an answer landed", needed only while nothing measured the request
  /// itself. Now that the service reports a structured [GroupPerf] (plan 12-B),
  /// sampling the measurement directly is both more accurate and what makes a
  /// single answered request enough to print a rate.
  ///
  /// [at] should be the moment the answer landed (the crossing), not the moment
  /// the group finished drawing — otherwise the window's wall-clock span would
  /// include rendering time it is not measuring.
  void recordTranslatedGroup(GroupPerf perf, {DateTime? at}) {
    _translateRate.add(
      perf.llmPages,
      workMs: perf.llmMs > 0 ? perf.llmMs : null,
      at: at,
    );
  }

  /// Stage-3 cost of the same group: pages the draw loop visited over the wall
  /// time it visited them. Fed by the same [GroupPerf], reported once.
  /// [at] exists so a test can keep every sample of a window on one fake clock;
  /// the loop reports without it, straight from the arrival of the response.
  void recordRenderWork(GroupPerf perf, {DateTime? at}) {
    _renderWork.add(
      perf.renderPages,
      workMs: perf.renderMs > 0 ? perf.renderMs : null,
      at: at,
    );
  }

  /// Called once per group at its translating→rendering crossing, with the
  /// page count the service was handed. Producer-side, like the others.
  ///
  /// Kept for callers that have a crossing but no [GroupPerf] to go with it
  /// (tests, and any future path that learns about an answer from the stage
  /// report alone); the pre-translation loop samples [recordTranslatedGroup]
  /// instead, because that sample carries a duration.
  void recordTranslatedPages(int pages, {int? workMs, DateTime? at}) =>
      _translateRate.add(pages, workMs: workMs, at: at);

  /// Called once per *committed* group — deliberately coarse: this number
  /// means "pages fully done", and crediting in-flight fractions would just
  /// re-derive the weighted bar with extra steps. [workMs] is that group's
  /// end-to-end [GroupPerf.totalMs] when the service measured one, which is
  /// what lets the Rendered row also answer plan 12-C's first sample.
  void recordSettledPages(int pages, {int? workMs, DateTime? at}) =>
      _pipelineRate.add(pages, workMs: workMs, at: at);

  /// Pages finished inside groups that have not committed yet, weighted by how
  /// far each in-flight page has got, plus whole groups already waiting on the
  /// committer.
  double get uncommittedPages =>
      bufferedPages +
      groups.values.fold(0.0, (sum, g) => sum + g.completedPages);

  /// [PreTranslationTask.progress] plus those uncommitted pages. A group of
  /// 4-8 pages commits its counts at once, so the committed value can sit
  /// still for minutes — long enough to read as a stalled job. Falls back to
  /// the committed value whenever the running chapter is unknown or its page
  /// count is not resolved yet.
  double liveProgress(PreTranslationTask task) {
    var base = task.progress;
    var index = chapterIndex - 1;
    if (index < 0 || index >= task.chapters.length) return base;
    var chapter = task.chapters[index];
    if (chapter.total <= 0) return base;
    var extra = (uncommittedPages / chapter.total).clamp(0.0, 1.0);
    return (base + extra / task.chapters.length).clamp(0.0, 1.0);
  }
}

/// Sliding-window throughput and per-page cost for one progress stream (the
/// recognition sweep, the answered translation requests, or settled commits).
/// Three deliberate choices:
///
///  * window, not EMA: "how many pages landed in the last [_window]" answers
///    what the job is doing *now* and self-heals after a pause with no reset
///    hook;
///  * recomputed on add(), never on read: the task card rebuilds on every
///    coalesced notify *and* on every wall-clock tick (plan 12-A), and must not
///    scan a list or read the clock while building. Reading a [PhaseRates]
///    snapshot is a field read;
///  * a sample may carry the **duration its pages were measured over**
///    ([add]'s `workMs`, plan 12-B). That is what lets a single finished batch
///    already state a rate and an ms/page instead of withholding both until two
///    samples happen to straddle [_minSpan] — the complaint behind plan 12-C.
///
/// A rate with fewer than two samples, or samples spanning less than
/// [_minSpan], leaves [PhaseRates.stablePagesPerMinute] null: "unreadable" is
/// N/A, not a 0 that would read as "the job is doing zero pages per minute".
class _ThroughputTracker {
  final _samples = <({DateTime at, int pages, int? workMs})>[];
  DateTime? _lastAt;
  double? _rate;
  double? _measuredRate;
  double? _msPerPage;
  int _measuredSamples = 0;

  static const _window = Duration(seconds: 120);
  static const _minSpan = Duration(seconds: 3);

  DateTime? get lastSampleAt => _lastAt;

  double? get pagesPerMinute => _rate;

  /// Everything the card shows for this stream, computed here so the widget
  /// tree reads plain numbers (plan 12-B/12-C).
  PhaseRates get view {
    var stable = _rate;
    var measured = _measuredRate;
    return PhaseRates(
      pagesPerMinute: stable ?? measured,
      stablePagesPerMinute: stable,
      measuredPagesPerMinute: measured,
      msPerPage: _msPerPage,
      // Wall-clock seconds per page at the rate printed beside it — the exact
      // reciprocal (60 s / (pages per minute)), so the two figures can never
      // contradict each other. Null while the shown rate is the measured
      // warm-up one: there the reciprocal *is* [msPerPage], and printing one
      // number twice under two names is noise, not evidence.
      //
      // Seconds, not milliseconds: the row renders this through
      // `formatSecondsPerPage` under the `@s s/page throughput` key (whose
      // zh_CN text is `吞吐 @s 秒/页`). The old `60000 / stable` was the
      // millisecond form, so a 32 pages/min row printed `1875.0 s/page`
      // beside `32.0 页/分` — the same measurement told in the wrong unit.
      throughputSecondsPerPage:
          stable != null && stable > 0 ? 60 / stable : null,
      // The count has to back the number it is printed next to: a wall-clock
      // window is made of every sample in it, a measured warm-up rate only of
      // the samples that carried a duration. Claiming "3 samples" behind a
      // rate two of them never contributed to would be the same kind of
      // over-claim plan 12-C exists to prevent.
      samples: stable != null
          ? _samples.length
          : measured != null
          ? _measuredSamples
          : _samples.length,
    );
  }

  /// [pages] pages that the producer measured over [workMs] milliseconds of its
  /// own wall time (null = "this sample says nothing about duration", e.g. a
  /// fetch failure that was never timed).
  ///
  /// [at] is when the work *happened*, which the caller may know better than
  /// this moment: a translation group is credited at its batch answer, not at
  /// the end of its drawing. That is also why the insert below is sorted —
  /// with overlapping groups, the answers can be *reported* out of the order
  /// their arrivals happened in.
  void add(int pages, {int? workMs, DateTime? at}) {
    if (pages <= 0) return;
    var now = at ?? DateTime.now();
    var sample = (at: now, pages: pages, workMs: workMs);
    if (_samples.isEmpty || !_samples.last.at.isAfter(now)) {
      _samples.add(sample);
    } else {
      // Back-dated sample: slot it in from the back, which is where it nearly
      // always lands (the window is small and out-of-order is rare). Appending
      // it would leave the list unsorted, and both the trim and the span below
      // are defined over event order — an unsorted head makes the span
      // negative or short, i.e. an *inflated* rate, i.e. an ETA that promises
      // the job arrives sooner than it can.
      var i = _samples.length;
      while (i > 0 && _samples[i - 1].at.isAfter(now)) {
        i--;
      }
      _samples.insert(i, sample);
    }
    // The window is anchored at the newest event, not at the call order.
    var newest = _samples.last.at;
    if (_lastAt == null || newest.isAfter(_lastAt!)) {
      _lastAt = newest;
    }
    while (newest.difference(_samples.first.at) > _window) {
      _samples.removeAt(0);
    }
    var span = newest.difference(_samples.first.at);
    if (_samples.length >= 2 && span >= _minSpan) {
      var total = 0;
      for (var s in _samples) {
        total += s.pages;
      }
      _rate = total * 60000 / span.inMilliseconds;
    } else {
      // Recomputed to null, not left alone. The window trims, so the two
      // samples that produced this rate can leave it while the number stays:
      // after a pause longer than [_window], a job that has answered exactly
      // one request would still show — and the ETA would still be built on —
      // the rate of a burst that ended minutes ago. That is the "stale but
      // plausible" failure mode this whole card exists to remove.
      _rate = null;
    }
    // The duration view of the same window. Samples without a measured
    // duration are skipped on both sides of the division, so the rate and the
    // ms/page always describe the *same* set of pages — and a 0 ms duration
    // (a sub-millisecond, fully cache-resolved phase) is treated as "not
    // measurable" rather than as an infinite speed.
    var measuredMs = 0;
    var measuredPages = 0;
    _measuredSamples = 0;
    for (var s in _samples) {
      var ms = s.workMs;
      if (ms == null || ms <= 0) continue;
      measuredMs += ms;
      measuredPages += s.pages;
      _measuredSamples++;
    }
    if (measuredPages > 0 && measuredMs > 0) {
      _msPerPage = measuredMs / measuredPages;
      _measuredRate = measuredPages * 60000 / measuredMs;
    } else {
      _msPerPage = null;
      _measuredRate = null;
    }
  }
}

/// The figures one progress stream contributes to the card, all pre-computed
/// by [_ThroughputTracker] on write so a rebuild never recomputes anything.
///
/// The three rates answer different questions and are kept apart on purpose:
///
///  * [stablePagesPerMinute] is pages per minute of *wall clock* across a
///    window of at least two samples spanning a few seconds. It is the only
///    figure honest enough to divide a remaining-page count by, so it is the
///    ETA source — plan 12-A requires "not enough samples" to print `—` rather
///    than an arrival time built on one sample;
///  * [measuredPagesPerMinute] is pages per minute of *measured work*: what the
///    durations the producers reported add up to inside the window. One
///    finished batch already answers it, which is exactly what plan 12-C asked
///    the card to stop withholding; it excludes the gaps between batches, so
///    it reads fast on a job that then waits on the network;
///  * [pagesPerMinute] is the display rate: the wall-clock one once there is
///    one, the measured one while the job is still warming up.
///
/// [samples] is how many samples sit in the window. The card prints it next to
/// the rate (`12 页/分 · 2 样本`) instead of quietly promoting a first sample to
/// a stable figure — the user judges the number's trustworthiness rather than
/// having to take the display's word for it (plan 12-C, decision D3).
class PhaseRates {
  const PhaseRates({
    required this.pagesPerMinute,
    required this.stablePagesPerMinute,
    required this.measuredPagesPerMinute,
    required this.msPerPage,
    required this.throughputSecondsPerPage,
    required this.samples,
  });

  /// Nothing measured yet: every figure null, so the card prints `—`.
  static const unknown = PhaseRates(
    pagesPerMinute: null,
    stablePagesPerMinute: null,
    measuredPagesPerMinute: null,
    msPerPage: null,
    throughputSecondsPerPage: null,
    samples: 0,
  );

  final double? pagesPerMinute;
  final double? stablePagesPerMinute;
  final double? measuredPagesPerMinute;

  /// Mean milliseconds this phase's own measured work spent per page — the
  /// **service time of one group / batch / request**, not the job's pace.
  ///
  /// Translation and rendering report Σ workMs over Σ pages of the groups in
  /// the window ([GroupPerf.llmMs]/[GroupPerf.llmPages] and
  /// [GroupPerf.renderMs]/[GroupPerf.renderPages]); recognition reports the
  /// engine's own batch time per page. With N groups in flight at once those
  /// durations overlap, so this figure is ≈ N × the per-page wall clock — the
  /// real-device card showed `16.8 页/分钟` (= 3.57 s/page) next to
  /// `平均每页 15727 毫秒` on a four-group run, two numbers that read as a
  /// contradiction because one of them was labelled "average per page".
  /// It stays exactly this measurement (the tests pin it); the card now prints
  /// it under a name that says what it measures, beside the throughput figure
  /// below. Null when no sample in the window carried a duration.
  final double? msPerPage;

  /// Wall-clock seconds per page at the *shown* rate — the reciprocal of
  /// [pagesPerMinute], pre-computed so the row's two per-page figures are
  /// consistent by construction rather than by coincidence. Null when the
  /// shown rate is the measured warm-up one (see [_ThroughputTracker.view]).
  final double? throughputSecondsPerPage;

  /// Samples in the window — the confidence figure shown beside the rate.
  final int samples;

  /// `int?` so an unmeasured stream prints `—` rather than `0 样本`, which would
  /// claim a measurement of zero happened.
  int? get sampleCount => samples > 0 ? samples : null;

  /// True while the shown rate still comes from measured work rather than from
  /// a wall-clock window: the warm-up state plan 12-C wants disclosed (the card
  /// discloses it through [sampleCount]).
  bool get isWarmup =>
      pagesPerMinute != null && stablePagesPerMinute == null;
}

/// Everything the pre-translation card shows about a running job, folded into
/// one immutable snapshot so `build()` only formats numbers it is handed.
///
/// All derivation lives here, in the data layer: no text parsing (the OCR
/// batch stats arrive structured through [TranslationWorker.lastPerf], the
/// translation group's split through the service's structured [GroupPerf] —
/// never regexed out of either log line), no IO, and one clock read per
/// construction. Construction rides the coalesced activity notifies **and** the
/// wall-clock tick of [PreTranslationProgressTicker] (plan 12-A), never the
/// frame rate: a tick with no event behind it still re-folds, which is exactly
/// what makes `createdAt -> now` move. Unreadable figures are null and the card
/// prints `—`; they are never a fabricated 0.
/// The remaining-time projection, kept alive between commits.
///
/// The estimate is `remaining pages × the phase's own page time`, recomputed
/// only when a sample lands — so with a batch gap of half a minute the number
/// sat still while "已用时" ticked, which reads as a frozen (or hung) estimate.
/// That was the reported defect: "预计还需不是按秒刷新的".
///
/// The pages counted as *remaining* include the group currently in flight,
/// whose work is already partly done. Subtracting the time elapsed since the
/// last sample is what makes the projection decay tick by tick and re-anchor at
/// the next commit.
///
/// Pure: [now] and [lastSampleAt] come in, a Duration goes out. No anchor
/// (nothing sampled yet) leaves the base untouched; a projection already in the
/// past clamps to zero rather than going negative.
Duration? decayEta(
  Duration? base, {
  required DateTime now,
  DateTime? lastSampleAt,
}) {
  if (base == null) return null;
  if (lastSampleAt == null) return base;
  var spent = now.difference(lastSampleAt);
  if (spent <= Duration.zero) return base;
  var left = base - spent;
  return left > Duration.zero ? left : Duration.zero;
}

/// How long a phase took, measured from the job's start; null while that phase
/// has not finished. Clamped at zero so a clock that moved backwards cannot
/// print a negative duration.
///
/// This is the *cumulative* figure — "the job had been running this long when
/// the phase finished". It is the wrong number for a row labelled with one
/// phase's name, which is what [phaseDurationsOf] exists to provide; it is kept
/// for the total row, where the same quantity is exactly right.
Duration? phaseDoneAfter(PreTranslationTask task, DateTime? doneAt) {
  if (doneAt == null) return null;
  var elapsed = doneAt.difference(task.createdAt);
  return elapsed.isNegative ? Duration.zero : elapsed;
}

/// Each phase's own cost, measured between consecutive finish lines.
///
/// The card used to print [phaseDoneAfter] under "Recognized / Translated /
/// Rendered … elapsed", so a run whose recognition took 0:50 and whose
/// translation took 3:51 showed "Translated … 4:41" — the OCR time included,
/// because 4:41 was the clock since the job started, not the phase. The user
/// reads that row as the phase's cost and cannot reconcile it with the total:
/// 0:50 + 4:41 + 0:03 ≠ 4:44. Subtracting the previous stamp is the whole fix,
/// and it needs no new measurement — the finish lines were already recorded.
///
/// Additive by construction: recognition + translation + render == total.
class PhaseDurations {
  const PhaseDurations({
    this.recognition,
    this.translation,
    this.render,
    this.total,
    this.ocrStartDelay,
  });

  /// Job start → recognition finished.
  final Duration? recognition;

  /// Recognition finished → translation finished. This is the phase the user
  /// complained about: it starts when the text is in hand and the request can
  /// go out, and ends when the last answer lands.
  final Duration? translation;

  /// Translation finished → pages drawn.
  final Duration? render;

  /// Job start → pages drawn.
  final Duration? total;

  /// Job start → the first chunk reached the worker (downloads, queueing).
  final Duration? ocrStartDelay;

  /// Null when any phase is still open — a half-finished sum is a wrong
  /// number, not a partial one.
  bool get complete =>
      recognition != null && translation != null && render != null;

  /// The three phases added up. Must equal [total] once every phase is in;
  /// `phase_durations_test.dart` pins that, because a display that disagrees
  /// with itself is the defect this type was written to remove.
  Duration? get sum {
    if (!complete) return null;
    return recognition! + translation! + render!;
  }
}

/// Reads the phase costs off a job's stamps. Pure: every input is a value the
/// caller already holds, so the arithmetic is testable without a running job.
PhaseDurations phaseDurationsOf(
  PreTranslationTask task,
  PreTranslationActivity? activity,
) {
  Duration? between(DateTime? from, DateTime? to) {
    if (from == null || to == null) return null;
    var d = to.difference(from);
    return d.isNegative ? Duration.zero : d;
  }

  var created = task.createdAt;
  var ocrDone = activity?.recognizedDoneAt;
  var xlateDone = activity?.translatedDoneAt;
  var renderDone = activity?.renderedDoneAt;
  var ocrStart = activity?.ocrStartedAt;
  // A job that already finished carries its stamps in the summary, so a card
  // opened later reads the same numbers as one that watched it happen.
  if (ocrDone == null || xlateDone == null || renderDone == null) {
    var summary = task.finalSummary;
    if (summary != null) {
      ocrDone ??= _stampFromMs(created, summary.recognitionDoneAfterMs);
      xlateDone ??= _stampFromMs(created, summary.translationDoneAfterMs);
      renderDone ??= _stampFromMs(created, summary.renderDoneAfterMs);
    }
  }
  return PhaseDurations(
    recognition: between(created, ocrDone),
    translation: between(ocrDone, xlateDone),
    render: between(xlateDone, renderDone),
    total: between(created, renderDone),
    ocrStartDelay: between(created, ocrStart),
  );
}

DateTime? _stampFromMs(DateTime created, int? ms) =>
    ms == null ? null : created.add(Duration(milliseconds: ms));

/// The same subtraction, for the three cumulative millisecond marks a finished
/// job persists. Kept beside [phaseDurationsOf] so the live card and the
/// summary card cannot disagree about what "translation took" means.
PhaseDurations phaseDurationsFromStamps({
  required int? recognitionDoneAfterMs,
  required int? translationDoneAfterMs,
  required int? renderDoneAfterMs,
}) {
  Duration? ms(int? v) => v == null ? null : Duration(milliseconds: v);
  Duration? diff(int? from, int? to) {
    if (from == null || to == null) return null;
    var d = to - from;
    return Duration(milliseconds: d < 0 ? 0 : d);
  }

  return PhaseDurations(
    recognition: ms(recognitionDoneAfterMs),
    translation: diff(recognitionDoneAfterMs, translationDoneAfterMs),
    render: diff(translationDoneAfterMs, renderDoneAfterMs),
    total: ms(renderDoneAfterMs),
  );
}

/// One grep-able line with the six timestamps a report needs, plus the three
/// phase costs and their sum.
///
/// The card shows the numbers; a log line is what makes them *checkable* — a
/// user reporting "4:41 of translation" and a developer reading the same run
/// can now both point at the same six instants. The sum is printed rather than
/// left to the reader: recognition + translation + render must equal total, and
/// printing both sides is how a future regression in that arithmetic shows up
/// as a disagreement instead of as a plausible-looking number.
void logPhaseTimeline(PreTranslationTask task, PreTranslationActivity activity) {
  var d = phaseDurationsOf(task, activity);
  String at(DateTime? t) => t == null
      ? '-'
      : '${t.hour.toString().padLeft(2, '0')}:'
            '${t.minute.toString().padLeft(2, '0')}:'
            '${t.second.toString().padLeft(2, '0')}.'
            '${t.millisecond.toString().padLeft(3, '0')}';
  String secs(Duration? v) =>
      v == null ? '-' : (v.inMilliseconds / 1000).toStringAsFixed(1);
  Log.info(
    'Pre-translation',
    'PhaseTimeline pages=${task.total} '
    'start=${at(task.createdAt)} '
    'ocrStart=${at(activity.ocrStartedAt)} '
    'ocrDone=${at(activity.recognizedDoneAt)} '
    'reqSent=${at(activity.requestSentAt)} '
    'firstResp=${at(activity.firstResponseAt)} '
    'done=${at(activity.renderedDoneAt)} '
    'ocr=${secs(d.recognition)}s '
    'translate=${secs(d.translation)}s '
    'render=${secs(d.render)}s '
    'sum=${secs(d.sum)}s total=${secs(d.total)}s',
  );
}

class PreTranslationProgress {
  PreTranslationProgress({
    required this.running,
    required this.processed,
    required this.total,
    required this.recognized,
    required this.translated,
    required this.rendered,
    required this.sweepActive,
    required this.focusRecognizing,
    required this.focusTranslating,
    required this.focusRendering,
    required this.recognitionRatePerMinute,
    required this.translationRatePerMinute,
    required this.commitRatePerMinute,
    required this.recognitionSamples,
    required this.translationSamples,
    required this.commitSamples,
    required this.recognitionSecondsPerPage,
    required this.translationSecondsPerPage,
    required this.commitSecondsPerPage,
    required this.translationMsPerPage,
    required this.renderMsPerPage,
    required this.batch,
    required this.msPerPage,
    required this.elapsed,
    required this.eta,
    required this.recognitionDoneAfter,
    required this.translationDoneAfter,
    required this.renderDoneAfter,
    this.durations = const PhaseDurations(),
    required this.epName,
    required this.sessions,
    required this.arenaMb,
    required this.degradedLabel,
  });

  /// Folds [task] + its live [activity] into display figures. Thin wrapper
  /// around the pure [PreTranslationProgress.snapshot] that reads the worker
  /// singletons' *plain fields* (lastReport/lastPerf are set by responses the
  /// pool already sent; reading them never starts an isolate). Everything a
  /// test needs is injectable through [snapshot], which touches no singletons.
  factory PreTranslationProgress.of(
    PreTranslationTask task, {
    PreTranslationActivity? activity,
  }) =>
      PreTranslationProgress.snapshot(
        task,
        activity: activity,
        workerReport: TranslationWorker.instance.lastReport,
        batchPerf: TranslationWorker.instance.lastPerf,
        batchPerfAt: TranslationWorker.instance.lastPerfAt,
      );

  /// Pure fold: no singleton reads, no IO, no parsing — pass the worker data
  /// in explicitly (nulls = "no data yet" and surface as `—`, never as 0).
  factory PreTranslationProgress.snapshot(
    PreTranslationTask task, {
    PreTranslationActivity? activity,
    EpReport? workerReport,
    OcrBatchPerf? batchPerf,
    DateTime? batchPerfAt,
    DateTime? now,
  }) {
    var at = now ?? DateTime.now();
    // A batch older than this says nothing about the job's *current* speed
    // (the sweep may have ended, the pool may have been released for VRAM),
    // so it is treated as no data at all rather than as live numbers.
    var freshBatch = batchPerf != null &&
            batchPerfAt != null &&
            at.difference(batchPerfAt) <= const Duration(seconds: 30)
        ? batchPerf
        : null;

    var processed =
        activity?.liveProcessed(task) ?? (task.done + task.failed);
    var total = task.total;
    var recognized =
        activity != null ? activity.recognizedThrough(task) : processed;
    var translated =
        activity != null ? activity.translatedThrough(task) : processed;
    var rendered =
        activity != null ? activity.renderedThrough(task) : processed;

    var sweepActive = activity?.sweepActive ?? false;
    var stage = activity?.headStage;
    // What the eye should land on. The sweep slot is always the head while it
    // runs, so a sweep highlights recognition; during stage 2 a loading /
    // recognizing head is the same phase in spirit, and `fetching` is the
    // translation pipeline's own first step.
    var focusRecognizing = sweepActive ||
        stage == TranslationStage.recognizing ||
        stage == TranslationStage.loadingModel;
    var focusTranslating = !sweepActive &&
        (stage == TranslationStage.translating ||
            stage == TranslationStage.fetching);
    var focusRendering =
        !sweepActive && stage == TranslationStage.rendering;

    // One [PhaseRates] per stream: the shown rate (wall-clock window once it
    // exists, otherwise the measured warm-up figure), the sample count behind
    // it, and the phase's own ms/page. Plan 12-B/12-C.
    var rec = activity?.sweepRates ?? PhaseRates.unknown;
    var trans = activity?.translateRates ?? PhaseRates.unknown;
    var commit = activity?.commitRates ?? PhaseRates.unknown;
    var render = activity?.renderWorkRates ?? PhaseRates.unknown;
    // The ETA is deliberately sourced from the *stable* rates only: a first
    // sample may be shown as a rate, but multiplying it into a promise about
    // every remaining page is the "fake ETA" plan 12-A forbids.
    var recRate = rec.stablePagesPerMinute;
    var commitRate = commit.stablePagesPerMinute;
    Duration? eta;
    if (activity != null && task.isRunning) {
      if (sweepActive) {
        var pending = activity.ocrSweepPendingPages;
        if (recRate != null && recRate > 0 && pending > 0) {
          eta = decayEta(
            Duration(seconds: (pending * 60 / recRate).round()),
            now: at,
            lastSampleAt: activity.lastOcrSampleAt,
          );
        }
      } else {
        var remaining = math.max(0, total - processed);
        if (commitRate != null && commitRate > 0 && remaining > 0) {
          eta = decayEta(
            Duration(seconds: (remaining * 60 / commitRate).round()),
            now: at,
            lastSampleAt: activity.lastCommitSampleAt,
          );
        }
      }
    }

    var arenaBytes = workerReport != null
        ? workerReport.arenaCapacityBytes + workerReport.hiddenArenaCapacityBytes
        : freshBatch?.arenaBytes;
    List<String>? trail;
    if (workerReport != null) {
      trail = workerReport.degradedTrail;
    } else if (freshBatch != null) {
      trail = freshBatch.degradedTrail;
    }

    return PreTranslationProgress(
      running: task.isRunning,
      processed: processed,
      total: total,
      recognized: recognized,
      translated: translated,
      rendered: rendered,
      sweepActive: sweepActive,
      focusRecognizing: focusRecognizing,
      focusTranslating: focusTranslating,
      focusRendering: focusRendering,
      // Each phase line gets *its own* stream's number; the three are never
      // interchangeable. While the sweep owns the card no stage-2 request can
      // be landing, and once it stopped a stale recognition figure
      // would quote the wrong stream — so each rate is nulled outside its
      // phase, and the card prints `—`, never a borrowed number. The sample
      // count travels with the rate it describes (plan 12-C: the first sample
      // is shown, and shown *as* a first sample).
      recognitionRatePerMinute: sweepActive ? rec.pagesPerMinute : null,
      recognitionSamples: sweepActive ? rec.sampleCount : null,
      recognitionSecondsPerPage:
          sweepActive ? rec.throughputSecondsPerPage : null,
      translationRatePerMinute: sweepActive ? null : trans.pagesPerMinute,
      translationSamples: sweepActive ? null : trans.sampleCount,
      translationSecondsPerPage:
          sweepActive ? null : trans.throughputSecondsPerPage,
      translationMsPerPage: sweepActive ? null : trans.msPerPage,
      commitRatePerMinute: commit.pagesPerMinute,
      commitSamples: commit.sampleCount,
      commitSecondsPerPage: commit.throughputSecondsPerPage,
      renderMsPerPage: render.msPerPage,
      batch: freshBatch,
      // Recognition's ms/page stays the worker's own per-page measurement
      // (`OcrBatchPerf.totalMs / pages`) rather than the sweep window's: the
      // batch number is timed inside the engine, it is what this row has always
      // quoted, and the sweep's chunk wall time (which also feeds its warm-up
      // rate) additionally contains the queueing between chunks. Null -> `—`.
      msPerPage: freshBatch != null && freshBatch.pages > 0
          ? freshBatch.totalMs / freshBatch.pages
          : null,
      // Wall clock the card shows next to the ETA. For a finished job this
      // is the *total* run time (createdAt→finishedAt, both persisted), so
      // the history card can answer "how long did that take" without any
      // summary; for a paused job (activity alive, not running) it keeps
      // ticking to "now". null only when nothing can be said (no finish and
      // no live activity) — printed as `—`.
      elapsed: task.finishedAt != null
          ? task.finishedAt!.difference(task.createdAt)
          : (task.isRunning || activity != null)
          ? at.difference(task.createdAt)
          : null,
      eta: eta,
      // How long each phase took, once it is over. These are the numbers the
      // user reads *after* a phase ends ("识别完 37 张用了多久") and they must
      // not move again — see [PreTranslationActivity.notePhaseCompletions].
      recognitionDoneAfter: phaseDoneAfter(task, activity?.recognizedDoneAt),
      translationDoneAfter: phaseDoneAfter(task, activity?.translatedDoneAt),
      renderDoneAfter: phaseDoneAfter(task, activity?.renderedDoneAt),
      durations: phaseDurationsOf(task, activity),
      epName: workerReport?.active.name ?? batchPerf?.epName,
      sessions: workerReport?.sessionCount ?? batchPerf?.sessionCount,
      arenaMb: arenaBytes == null
          ? null
          : arenaBytes / (1024 * 1024),
      // "none" is a real observation (the report exists and says no fallback
      // happened); null is the absence of a report, printed as `—`.
      degradedLabel: trail == null ? null : (trail.isEmpty ? "none" : trail.join(",")),
    );
  }

  final bool running;

  /// Committed + buffered pages — the same set the percentage bar counts
  /// ([PreTranslationActivity.liveProcessed]). Its meaning is unchanged; the
  /// phase numerators below add the in-flight credit on top.
  final int processed;
  final int total;

  /// Per-phase readouts, each an overall "X / total pages" figure: pages that
  /// reached that phase, counting committed pages in all earlier phases (a
  /// committed page has by definition been recognized and translated).
  final int recognized;
  final int translated;
  final int rendered;

  /// A stage-1 recognition sweep is running: the recognized line is live OCR
  /// scan progress, explicitly *not* translation completeness.
  final bool sweepActive;

  /// Which phase line to highlight. At most one of these is true.
  final bool focusRecognizing;
  final bool focusTranslating;
  final bool focusRendering;

  /// Pages/min shown on the Recognized row: the sweep window's rate, available
  /// from the first measured chunk onward (plan 12-C). Only
  /// non-null while a sweep is active — a stale recognition rate next to a
  /// translating job would read as the wrong stream's speed.
  final double? recognitionRatePerMinute;

  /// Pages/min of answered translation requests (the translating→rendering
  /// requests in the last window), from the first answered one onward; the
  /// sample count printed next to it says how much data the rate rests on
  /// (plan 12-C). Null while a sweep owns the card, which prints `—` instead.
  final double? translationRatePerMinute;

  /// Pages/min of fully settled (committed = drawn + cached) pages — the
  /// *rendering* line's rate; null until at least two commits span a few
  /// seconds.
  final double? commitRatePerMinute;

  /// Samples behind [recognitionRatePerMinute] / [translationRatePerMinute] /
  /// [commitRatePerMinute], shown next to each rate as `· N 样本` so a
  /// first-sample (warm-up) figure is visibly a first-sample figure rather than
  /// a promoted one (plan 12-C). Null = nothing measured in the window, which
  /// prints `—`, never `0 样本` — a 0 would claim a measurement happened.
  final int? recognitionSamples;
  final int? translationSamples;
  final int? commitSamples;

  /// Wall-clock seconds per page at the rate shown on the same row — the
  /// reciprocal of the row's `…RatePerMinute`, pre-computed in
  /// [PhaseRates.throughputSecondsPerPage] so the card never divides while
  /// building. Null while that row's rate is a measured warm-up figure (the
  /// reciprocal would just repeat the row's service-time number) or when the
  /// row has no rate at all.
  final double? recognitionSecondsPerPage;
  final double? translationSecondsPerPage;
  final double? commitSecondsPerPage;

  /// Mean milliseconds this phase's measured work spent per page it carried,
  /// for the two stage-2 rows (plan 12-B). Translation comes from the shared
  /// request's own wall time ([GroupPerf.llmMs] over [GroupPerf.llmPages]);
  /// rendering from the draw loop's ([GroupPerf.renderMs] over
  /// [GroupPerf.renderPages]). Both are structured values the service reported
  /// at its timing sites — nothing here is read back out of a log line, which
  /// is the coupling Phase 2's detMs accident ruled out. Null prints `—`.
  ///
  /// This is **service time inside one group/request**, not the job's pace:
  /// concurrent groups overlap, so it is ≈ concurrency × the per-page wall
  /// clock. The card labels it accordingly and prints the throughput figure
  /// beside it, so the pair can no longer read as a contradiction.
  final double? translationMsPerPage;
  final double? renderMsPerPage;

  /// The freshest OCR batch's structured stats, or null when there is no
  /// batch or the last one is too old to quote.
  final OcrBatchPerf? batch;

  /// Mean milliseconds one page took inside the freshest OCR batch.
  final double? msPerPage;

  /// Wall-clock time since the job was created (pauses included — honest
  /// enough for an estimate row, and cheaper than tracking pause segments).
  final Duration? elapsed;

  /// Remaining-time estimate for the *current* phase (sweep pages at sweep
  /// rate, otherwise unprocessed pages at commit rate); null when the rate or
  /// the remainder is unknown. Decays with wall clock between commits — see
  /// [decayEta].
  final Duration? eta;

  /// How long each phase took, once it finished. Frozen at the phase's own
  /// finish line (not at job end), so the card can print "识别: 37/37 页 · 用时
  /// 1:12" while the translation is still running. Null while the phase is
  /// unfinished — printed as a rate instead, or `—` when there is no rate.
  final Duration? recognitionDoneAfter;
  final Duration? translationDoneAfter;
  final Duration? renderDoneAfter;

  /// Each phase's own cost. The three `…DoneAfter` fields above are cumulative
  /// marks since the job started; these are the numbers a row labelled with one
  /// phase's name should print (see [phaseDurationsOf] for why both exist).
  final PhaseDurations durations;

  /// Engine row — the arena figure is host staging memory, not VRAM (plan
  /// §3.6), which is why the label says "暂存池", never 显存.
  final String? epName;
  final int? sessions;
  final double? arenaMb;
  final String? degradedLabel;
}

/// What a finished job's card still shows, frozen by [_run]'s finally out of
/// the last [PreTranslationProgress] fold, before the live activity and the
/// worker's fresh-batch window go away.
///
/// Everything here is a plain nullable scalar and rides
/// [PreTranslationTask.toJson] — appdata implicit data, **not** a new
/// database table. Absence of data stays absence: each null prints `—` on
/// the card; nothing here may be back-filled with a 0 that would read as a
/// measurement (the project's standing rule).
class PreTranslationTaskSummary {
  const PreTranslationTaskSummary({
    this.recognized,
    this.translated,
    this.rendered,
    this.recognitionRatePerMinute,
    this.translationRatePerMinute,
    this.renderRatePerMinute,
    this.recognitionSamples,
    this.translationSamples,
    this.renderSamples,
    this.recognitionSecondsPerPage,
    this.translationSecondsPerPage,
    this.commitSecondsPerPage,
    this.translationMsPerPage,
    this.renderMsPerPage,
    this.msPerPage,
    this.recognitionDoneAfterMs,
    this.translationDoneAfterMs,
    this.renderDoneAfterMs,
    this.epName,
    this.sessions,
    this.arenaMb,
    this.degradedLabel,
  });

  /// Freezes one live fold. Only the fields the live fold derives from the
  /// dying activity / worker window are kept; counts, elapsed and ETA are
  /// recomputed from the (persisted) task itself at display time, so they
  /// cannot go stale here.
  ///
  /// The rate parameters are taken **ungated** from [activity] when given:
  /// the live fold hides each phase's rate outside its own phase (a stale
  /// recognition figure beside a translating job quotes the wrong stream),
  /// but that guard is a *live-display* rule — the final view is a museum
  /// plaque, and its phase rows are labelled by phase, not "current speed".
  /// So the summary keeps the last measured figure of all three streams
  /// even when the card ended mid-another-phase (e.g. cancelled during a
  /// sweep: the chapter-before's translation rate is still real data).
  ///
  /// What is kept is the *shown* figure (`PhaseRates.pagesPerMinute`: the
  /// wall-clock window once it exists, else the measured warm-up value) plus
  /// its sample count, so a finished card repeats exactly what the user was
  /// looking at rather than dropping a warm-up rate that was on screen.
  factory PreTranslationTaskSummary.capture(
    PreTranslationProgress p, {
    PreTranslationActivity? activity,
  }) {
    var rec = activity?.sweepRates;
    var trans = activity?.translateRates;
    var commit = activity?.commitRates;
    return PreTranslationTaskSummary(
      recognized: p.recognized,
      translated: p.translated,
      rendered: p.rendered,
      recognitionRatePerMinute:
          rec?.pagesPerMinute ?? p.recognitionRatePerMinute,
      translationRatePerMinute:
          trans?.pagesPerMinute ?? p.translationRatePerMinute,
      renderRatePerMinute: commit?.pagesPerMinute ?? p.commitRatePerMinute,
      recognitionSamples: rec?.sampleCount ?? p.recognitionSamples,
      translationSamples: trans?.sampleCount ?? p.translationSamples,
      renderSamples: commit?.sampleCount ?? p.commitSamples,
      // The throughput figure rides with the rate it is the reciprocal of, and
      // is already null when that rate was a measured warm-up one.
      recognitionSecondsPerPage:
          rec?.throughputSecondsPerPage ?? p.recognitionSecondsPerPage,
      translationSecondsPerPage:
          trans?.throughputSecondsPerPage ?? p.translationSecondsPerPage,
      commitSecondsPerPage:
          commit?.throughputSecondsPerPage ?? p.commitSecondsPerPage,
      translationMsPerPage: trans?.msPerPage ?? p.translationMsPerPage,
      renderMsPerPage:
          activity?.renderWorkRates.msPerPage ?? p.renderMsPerPage,
      msPerPage: p.msPerPage,
      // The three phase finish times, frozen with the rates they replace: a
      // finished card shows "识别 37/37 · 用时 1:12" forever, without needing
      // the activity (which dies with the job) or a clock.
      recognitionDoneAfterMs: p.recognitionDoneAfter?.inMilliseconds,
      translationDoneAfterMs: p.translationDoneAfter?.inMilliseconds,
      renderDoneAfterMs: p.renderDoneAfter?.inMilliseconds,
      epName: p.epName,
      sessions: p.sessions,
      arenaMb: p.arenaMb,
      degradedLabel: p.degradedLabel,
    );
  }

  /// Final per-phase page counts. The last fold could include in-flight
  /// credit the commits never reached (a cancel mid-sweep really did
  /// recognise those pages and stored their OCR rows), so these are shown in
  /// preference to the committed counters when present.
  final int? recognized;
  final int? translated;
  final int? rendered;

  /// The three phase rates as of the last fold; null when that stream never
  /// produced a measurable window (the card prints `—`).
  final double? recognitionRatePerMinute;
  final double? translationRatePerMinute;
  final double? renderRatePerMinute;

  /// Sample counts behind those three rates, frozen with them so the finished
  /// card still discloses how little (or how much) data a shown rate rested on
  /// (plan 12-C). Null prints `—`, never `0 样本`.
  final int? recognitionSamples;
  final int? translationSamples;
  final int? renderSamples;

  /// Wall-clock seconds per page at each frozen rate, kept so a finished card
  /// prints the same consistent pair the live card printed (throughput beside
  /// service time) instead of dropping one half of it.
  final double? recognitionSecondsPerPage;
  final double? translationSecondsPerPage;
  final double? commitSecondsPerPage;

  /// Per-phase `ms/页` of the two stage-2 phases, from the service's structured
  /// [GroupPerf] (plan 12-B) — the last measured values the live card printed.
  final double? translationMsPerPage;
  final double? renderMsPerPage;

  /// Recognition ms/page from the freshest OCR batch at capture time.
  final double? msPerPage;

  /// How long each phase took, in milliseconds from the job's start, frozen at
  /// the phase's own finish. Kept as a number so the summary rides plain JSON;
  /// the card turns it back into the same `用时 H:MM` a live card prints.
  final int? recognitionDoneAfterMs;
  final int? translationDoneAfterMs;
  final int? renderDoneAfterMs;

  /// Engine row as last observed (the worker may have torn down since; this
  /// is what the card showed *while* it ran, kept honest by being marked
  /// final).
  final String? epName;
  final int? sessions;
  final double? arenaMb;
  final String? degradedLabel;

  /// Rebuilds the card's fold for a finished job. The card formats this
  /// exactly like the live fold — same fields, same `—` rules — so the
  /// display code has one path, not two.
  PreTranslationProgress toProgress(PreTranslationTask task) {
    // Committed counters are the persisted truth for processed/total; the
    // captured phase counts (when present) may exceed them with legitimate
    // end-of-run in-flight credit.
    var processed = task.done + task.failed;
    return PreTranslationProgress(
      running: false,
      processed: processed,
      total: task.total,
      recognized: recognized ?? processed,
      translated: translated ?? processed,
      rendered: rendered ?? processed,
      sweepActive: false,
      focusRecognizing: false,
      focusTranslating: false,
      focusRendering: false,
      recognitionRatePerMinute: recognitionRatePerMinute,
      translationRatePerMinute: translationRatePerMinute,
      commitRatePerMinute: renderRatePerMinute,
      recognitionSamples: recognitionSamples,
      translationSamples: translationSamples,
      commitSamples: renderSamples,
      recognitionSecondsPerPage: recognitionSecondsPerPage,
      translationSecondsPerPage: translationSecondsPerPage,
      commitSecondsPerPage: commitSecondsPerPage,
      translationMsPerPage: translationMsPerPage,
      renderMsPerPage: renderMsPerPage,
      // The worker's last batch belongs to whoever used the pool *last*, not
      // necessarily to this finished job — deliberately not quoted here.
      batch: null,
      msPerPage: msPerPage,
      elapsed: task.finishedAt?.difference(task.createdAt),
      eta: null,
      recognitionDoneAfter: recognitionDoneAfterMs == null
          ? null
          : Duration(milliseconds: recognitionDoneAfterMs!),
      translationDoneAfter: translationDoneAfterMs == null
          ? null
          : Duration(milliseconds: translationDoneAfterMs!),
      renderDoneAfter: renderDoneAfterMs == null
          ? null
          : Duration(milliseconds: renderDoneAfterMs!),
      durations: phaseDurationsFromStamps(
        recognitionDoneAfterMs: recognitionDoneAfterMs,
        translationDoneAfterMs: translationDoneAfterMs,
        renderDoneAfterMs: renderDoneAfterMs,
      ),
      epName: epName,
      sessions: sessions,
      arenaMb: arenaMb,
      degradedLabel: degradedLabel,
    );
  }

  Map<String, dynamic> toJson() => {
    'recognized': recognized,
    'translated': translated,
    'rendered': rendered,
    'recognitionRatePerMinute': recognitionRatePerMinute,
    'translationRatePerMinute': translationRatePerMinute,
    'renderRatePerMinute': renderRatePerMinute,
    'recognitionSamples': recognitionSamples,
    'translationSamples': translationSamples,
    'renderSamples': renderSamples,
    'recognitionSecondsPerPage': recognitionSecondsPerPage,
    'translationSecondsPerPage': translationSecondsPerPage,
    'commitSecondsPerPage': commitSecondsPerPage,
    'translationMsPerPage': translationMsPerPage,
    'renderMsPerPage': renderMsPerPage,
    'msPerPage': msPerPage,
    'recognitionDoneAfterMs': recognitionDoneAfterMs,
    'translationDoneAfterMs': translationDoneAfterMs,
    'renderDoneAfterMs': renderDoneAfterMs,
    'epName': epName,
    'sessions': sessions,
    'arenaMb': arenaMb,
    'degradedLabel': degradedLabel,
  }..removeWhere((_, v) => v == null);

  factory PreTranslationTaskSummary.fromJson(Map<String, dynamic> json) {
    return PreTranslationTaskSummary(
      recognized: (json['recognized'] as num?)?.toInt(),
      translated: (json['translated'] as num?)?.toInt(),
      rendered: (json['rendered'] as num?)?.toInt(),
      recognitionRatePerMinute: (json['recognitionRatePerMinute'] as num?)
          ?.toDouble(),
      translationRatePerMinute: (json['translationRatePerMinute'] as num?)
          ?.toDouble(),
      renderRatePerMinute: (json['renderRatePerMinute'] as num?)?.toDouble(),
      recognitionSamples: (json['recognitionSamples'] as num?)?.toInt(),
      translationSamples: (json['translationSamples'] as num?)?.toInt(),
      renderSamples: (json['renderSamples'] as num?)?.toInt(),
      recognitionSecondsPerPage:
          (json['recognitionSecondsPerPage'] as num?)?.toDouble(),
      translationSecondsPerPage:
          (json['translationSecondsPerPage'] as num?)?.toDouble(),
      commitSecondsPerPage:
          (json['commitSecondsPerPage'] as num?)?.toDouble(),
      translationMsPerPage: (json['translationMsPerPage'] as num?)?.toDouble(),
      renderMsPerPage: (json['renderMsPerPage'] as num?)?.toDouble(),
      msPerPage: (json['msPerPage'] as num?)?.toDouble(),
      recognitionDoneAfterMs: (json['recognitionDoneAfterMs'] as num?)?.toInt(),
      translationDoneAfterMs: (json['translationDoneAfterMs'] as num?)?.toInt(),
      renderDoneAfterMs: (json['renderDoneAfterMs'] as num?)?.toInt(),
      epName: json['epName']?.toString(),
      sessions: (json['sessions'] as num?)?.toInt(),
      arenaMb: (json['arenaMb'] as num?)?.toDouble(),
      degradedLabel: json['degradedLabel']?.toString(),
    );
  }
}

/// The user-tunable refresh cadence of the pre-translation progress card.
///
/// Stored in [appdata]'s implicit data — the same per-device channel the
/// pre-translation task records themselves persist through — because the
/// typed `Settings` defaults table lives in appdata.dart (frozen scope for
/// this feature) and this is a display preference, not a pipeline input. It
/// is deliberately **not** part of the performance-preset value table: like
/// "Pipeline mode", changing it must not flip the user's preset to custom.
class PreTranslationRefresh {
  /// Key inside appdata.implicitData.
  static const settingKey = 'imageTranslationProgressRefreshMs';

  /// What the card defaults to: half the old hard-coded rebuild floor was
  /// 500 ms twice a second; one second is the middle of the honest range
  /// (the rates are 120-second window figures anyway).
  ///
  /// Since plan 12-A this number means two things, by design: how often an
  /// event burst is allowed to rebuild the list ([PreTranslationTaskManager
  /// ._notifyActivity]) **and** how often [PreTranslationProgressTicker]
  /// repaints it when nothing happens at all. One knob, one cadence — a card
  /// that repainted faster than its own coalescing window would only ever show
  /// the same figures more often.
  static const defaultMs = 1000;

  /// 0.5–5 s. The floor is the previous hard-coded coalescing window: below
  /// it the task-list rebuild cost rises per perceived tick with nothing new
  /// to show (the sweep itself only reports per chunk, typically ≥ 1 s).
  static const minMs = 500;
  static const maxMs = 5000;

  /// Pure, testable normalisation: anything unreadable or out of range
  /// falls back to the default; in-range values clamp, never silently 0.
  static int normalizeMs(Object? raw) {
    if (raw is! num) return defaultMs;
    var v = raw.round();
    if (v < minMs || v > maxMs) return defaultMs;
    return v;
  }

  /// Current interval, already normalised. A plain in-memory map read — no
  /// IO, safe to call from build paths and from every activity event.
  static int intervalMs(Object? stored) => normalizeMs(stored);

  static Duration intervalFrom(Object? stored) =>
      Duration(milliseconds: intervalMs(stored));
}

/// Cancellation of a scheduled periodic callback, as handed back by a
/// [PreTranslationTickScheduler].
typedef PreTranslationTickCancellation = void Function();

/// Schedules [tick] once per [interval] until the returned handle is called.
/// Production uses [Timer.periodic]; tests substitute a manual clock so the
/// whole class can be exercised without waiting on a real second (plan 12-A's
/// acceptance rule: no test may depend on real sleeping).
typedef PreTranslationTickScheduler =
    PreTranslationTickCancellation Function(Duration interval, void Function() tick);

/// Wall-clock repaint driver for the pre-translation progress card (plan 12-A).
///
/// **What it is not**: the manager's `_notifyActivity`, which coalesces
/// *events*. That one only ever fires while events happen — no OCR chunk, no
/// stage change, no notify — so a card whose most visible figure is `createdAt
/// → now` sits frozen at "已用时 2:38" however long the user watches it. Treating
/// the coalescing window as a refresh period was the concept swap 12-A names:
/// "don't rebuild more than once per interval" and "rebuild once per interval"
/// are different promises, and only the second one is what the setting says.
///
/// So this class holds the second promise alone: it owns one [Timer.periodic]
/// and calls [onTick] when it fires. It never touches the managers'
/// [ChangeNotifier]s — the repaint is the card's own, which is what keeps a
/// 1 Hz tick from rebuilding every other listener of the task manager (the
/// comic page, the reader) for one ticking clock label.
///
/// Three guards, all plan 12-A's requirements:
///  * [shouldTick] false → the timer **stops itself** on the next tick, so a
///    finished, failed or paused job cannot leave a timer running;
///  * [isVisible] false → the tick is swallowed (no rebuild of a page nobody is
///    looking at). The timer keeps running, so the first tick after the page
///    returns repaints it with the then-current elapsed time;
///  * [dispose] always cancels, and it is safe to call twice.
///
/// The interval is re-read on every tick, so the user moving the "刷新间隔"
/// slider changes the cadence within one tick instead of needing the page
/// rebuilt first.
class PreTranslationProgressTicker {
  PreTranslationProgressTicker({
    required this.onTick,
    required this.interval,
    this.shouldTick = _always,
    this.isVisible = _always,
    this.clock = DateTime.now,
    PreTranslationTickScheduler? scheduler,
  }) : _schedule = scheduler ?? _periodicScheduler;

  static bool _always() => true;

  static PreTranslationTickCancellation _periodicScheduler(
    Duration interval,
    void Function() tick,
  ) {
    final timer = Timer.periodic(interval, (_) => tick());
    return timer.cancel;
  }

  /// Called with the clock reading taken for this tick. Everything the card
  /// shows is derived from that one reading (the fold's `now`), so a repaint
  /// and the figure it prints cannot disagree.
  final void Function(DateTime now) onTick;

  /// Current refresh interval. Read per tick, never cached by the caller.
  final Duration Function() interval;

  /// Whether there is anything to refresh at all (a running pre-translation
  /// job). False stops the timer; see [start] for how it gets restarted.
  final bool Function() shouldTick;

  /// Whether the page showing the card can actually see it.
  final bool Function() isVisible;

  /// The clock [onTick] is handed. Injectable so a test can advance time
  /// without waiting for it.
  final DateTime Function() clock;

  final PreTranslationTickScheduler _schedule;

  PreTranslationTickCancellation? _cancel;
  Duration? _runningFor;

  /// Whether a periodic callback is currently armed.
  bool get isRunning => _cancel != null;

  /// The interval the armed timer was started with, or null when it is stopped.
  Duration get runningInterval => _runningFor ?? Duration.zero;

  /// Arm the timer. Idempotent, and cheap enough to call from every rebuild:
  /// it does nothing when a timer with the same interval is already armed.
  void start() {
    var want = _checkedInterval();
    if (_cancel != null && _runningFor == want) return;
    _teardown();
    _runningFor = want;
    _cancel = _schedule(want, _fire);
  }

  /// Disarm. Called when the job leaves the running state or the page goes
  /// away; a later [start] re-arms.
  void stop() {
    _teardown();
  }

  void dispose() {
    _teardown();
  }

  void _teardown() {
    _cancel?.call();
    _cancel = null;
    _runningFor = null;
  }

  void _fire() {
    // A job that is no longer running (finished, failed, cancelled, paused)
    // has nothing left to count up: stop instead of repainting a frozen card.
    if (!shouldTick()) {
      stop();
      return;
    }
    // Off-screen: skip the rebuild, keep the timer, so coming back repaints on
    // the next tick without any extra wiring.
    if (!isVisible()) return;
    var want = _checkedInterval();
    if (want != _runningFor) {
      // The user moved the refresh-interval slider since the last tick.
      start();
      return;
    }
    onTick(clock());
  }

  /// The interval, made non-null and non-zero: a scheduler handed a zero or
  /// negative duration would spin, and [interval] is a user-facing setting
  /// read through a plain map lookup, so it is defended at the one place that
  /// turns it into a timer. [PreTranslationRefresh] already clamps the stored
  /// value; this is the belt to that pair of braces.
  Duration _checkedInterval() {
    var want = interval();
    return want.isNegative || want == Duration.zero
        ? const Duration(milliseconds: PreTranslationRefresh.defaultMs)
        : want;
  }
}

/// Manages background pre-translation jobs. Mirrors the structure of the
/// other task managers (currentTasks / historyTasks / persistence) so the
/// tasks page can render it the same way.
class PreTranslationTaskManager with ChangeNotifier {
  PreTranslationTaskManager._() {
    _load();
  }

  static final PreTranslationTaskManager instance =
      PreTranslationTaskManager._();

  final currentTasks = <PreTranslationTask>[];
  final historyTasks = <PreTranslationTask>[];
  final _canceledIds = <String>{};
  final _runningIds = <String>{};
  final _activities = <String, PreTranslationActivity>{};

  /// Live stage detail for a running job; null once it stops. Not persisted —
  /// a restart resumes from the committed counters, not from mid-group state.
  PreTranslationActivity? activityOf(String taskId) => _activities[taskId];

  Timer? _activityNotifyTimer;
  DateTime _lastActivityNotify = DateTime.fromMillisecondsSinceEpoch(0);

  /// Stage changes and sweep samples land per page across up to four
  /// concurrent groups, and each one would rebuild the whole task list, so
  /// they are coalesced to at most one notify per refresh window.
  ///
  /// That window is the user-tunable card refresh interval
  /// ([PreTranslationRefresh], default 1 s, floor 0.5 s = the previous
  /// hard-coded 500 ms): one knob controls both "how fresh the card looks"
  /// and "how often the list rebuilds", instead of the old two-constant
  /// dance where a configurable tick could only ever land on top of the
  /// fixed 500 ms floor and fight it. The trade-off, deliberately:
  ///  * the expensive half of a notify is the list rebuild, not the data
  ///    fold (PreTranslationProgress reads pre-computed numbers), so a
  ///    smaller window costs frame work only — but on a long task list that
  ///    work is every window, forever while a job runs; 0.5 s therefore
  ///    stays the floor, and the 1 s default halves the notify load the old
  ///    500 ms coalescing produced;
  ///  * nothing is lost for the figures this path *feeds*: every number an
  ///    event carries is a 120-second window rate or a committed counter, none
  ///    of which move meaningfully inside one interval. The one figure that
  ///    does change with no event at all is `createdAt -> now`, and it is not
  ///    this path's job any more — plan 12-A split the two meanings apart, and
  ///    [PreTranslationProgressTicker] owns the "repaint even though nothing
  ///    happened" half. Reading a coalescing window as a refresh period was the
  ///    concept swap that made the card look frozen;
  ///  * the trailing timer still guarantees the *final* change is not
  ///    swallowed — the last notify of a burst fires one window after the
  ///    first, so a coalesced burst always lands.
  ///
  /// The interval is read as a plain in-memory map lookup (no IO) per
  /// event, so a settings change takes effect on the next event without
  /// any wiring.
  void _notifyActivity() {
    var now = DateTime.now();
    // Phase finish lines are stamped here, not in the card's build: every
    // activity change passes through this method, so a job running in the
    // background records the same times a watched one does (a stamp taken from
    // the build path would only exist while the user is looking at the card).
    for (var task in currentTasks) {
      _activities[task.id]?.notePhaseCompletions(task, now);
    }
    var window = PreTranslationRefresh.intervalFrom(
      appdata.implicitData[PreTranslationRefresh.settingKey],
    );
    if (now.difference(_lastActivityNotify) >= window) {
      _lastActivityNotify = now;
      _activityNotifyTimer?.cancel();
      _activityNotifyTimer = null;
      notifyListeners();
      return;
    }
    _activityNotifyTimer ??= Timer(window, () {
      _activityNotifyTimer = null;
      _lastActivityNotify = DateTime.now();
      notifyListeners();
    });
  }

  void Function(PreTranslationTask task)? onTaskFinished;

  /// Starts pre-translating [chapters] (source chapter ids) of a comic. Returns
  /// null when translation is not usable (models/endpoint not configured) or a
  /// job for the comic is already running.
  PreTranslationTask? start({
    required String cid,
    required String sourceKey,
    required ComicType comicType,
    required String title,
    required List<PreTranslationChapter> chapters,
    String cover = '',
  }) {
    if (!ImageTranslationService.isReadyForComic(cid, sourceKey) ||
        chapters.isEmpty) {
      return null;
    }
    var existing = currentTasks
        .where((t) => t.comicKey == '$cid@$sourceKey' && t.isRunning)
        .firstOrNull;
    if (existing != null) {
      return existing;
    }
    var task = PreTranslationTask(
      id: DateTime.now().microsecondsSinceEpoch.toString(),
      cid: cid,
      sourceKey: sourceKey,
      comicType: comicType,
      title: title,
      cover: cover,
      chapters: chapters,
      createdAt: DateTime.now(),
    );
    currentTasks.insert(0, task);
    _saveActive();
    notifyListeners();
    unawaited(_run(task));
    return task;
  }

  /// Whether a running job exists for the comic (detail page badge).
  PreTranslationTask? runningTaskFor(String cid, String sourceKey) {
    return currentTasks
        .where((t) => t.comicKey == '$cid@$sourceKey' && t.isRunning)
        .firstOrNull;
  }

  /// Best-known progress of a chapter for a comic, looking first at a running
  /// job and then at the most recent finished job. Lets the chapter picker show
  /// a "translated" / progress marker even after the app restarts or the task
  /// moved to history, so already-done chapters are obvious and not re-queued
  /// blindly.
  PreTranslationChapter? chapterProgressFor(
    String cid,
    String sourceKey,
    String eid,
  ) {
    var comicKey = '$cid@$sourceKey';
    // A running/paused job owns the chapter: return it even before its page
    // count is known (total == 0) so the picker can show a "waiting" state for
    // queued-but-not-started chapters, not just active ones.
    for (var task in currentTasks) {
      if (task.comicKey != comicKey) continue;
      var chapter = task.chapters.where((c) => c.eid == eid).firstOrNull;
      // A per-chapter cancel leaves the chapter in the running job but no longer
      // being worked; fall through so the history/stored-text lookup can still
      // surface a "translated" marker if some pages were done before the cancel.
      if (chapter != null && !chapter.canceled) return chapter;
    }
    // Otherwise only report a finished chapter (all pages accounted for) so a
    // canceled/failed run does not masquerade as in-progress after restart.
    for (var task in historyTasks) {
      if (task.comicKey != comicKey) continue;
      var chapter = task.chapters.where((c) => c.eid == eid).firstOrNull;
      if (chapter != null &&
          chapter.total > 0 &&
          chapter.done + chapter.failed >= chapter.total) {
        return chapter;
      }
    }
    return null;
  }

  /// Live page counts for [chapter] of a comic: the committed counters plus a
  /// running job's finished-but-buffered groups.
  ({int done, int processed}) livePagesOf(
    String cid,
    String sourceKey,
    PreTranslationChapter chapter,
  ) {
    var task = runningTaskFor(cid, sourceKey);
    // Identity check, not eid: a per-chapter cancel makes chapterProgressFor
    // fall through to a history record for the same eid, and that record must
    // not be credited with the running job's buffered pages.
    if (task == null || !task.chapters.contains(chapter)) {
      return livePagesFor(chapter, null);
    }
    return livePagesFor(chapter, _activities[task.id]);
  }

  /// Credits [activity]'s buffered groups to [chapter] for display, when they
  /// belong to this chapter.
  ///
  /// Buffered pages cannot advance `done + failed` (that must stay a contiguous
  /// prefix for the resume cursor), but they are rendered and cached, so
  /// leaving them out makes the number sit still while work is plainly
  /// happening — which is what a slow head group looks like from the outside.
  /// Display only: never write these back into the chapter.
  @visibleForTesting
  static ({int done, int processed}) livePagesFor(
    PreTranslationChapter chapter,
    PreTranslationActivity? activity,
  ) {
    var committed = (
      done: chapter.done,
      processed: chapter.done + chapter.failed,
    );
    if (activity == null || activity.chapterEid != chapter.eid) {
      return committed;
    }
    return (
      done: committed.done + activity.bufferedDone,
      processed: committed.processed + activity.bufferedPages,
    );
  }

  /// Whether a chapter belongs to a currently running/paused job (so the picker
  /// can distinguish "queued/among this run" from a finished-in-history one).
  bool isChapterActive(String cid, String sourceKey, String eid) {
    var comicKey = '$cid@$sourceKey';
    for (var task in currentTasks) {
      if (task.comicKey != comicKey) continue;
      if (task.chapters.any((c) => c.eid == eid && !c.canceled)) return true;
    }
    return false;
  }

  bool get hasRunningTasks => currentTasks.any((t) => t.isRunning);

  void cancel(String id) {
    _canceledIds.add(id);
    var task = currentTasks.where((t) => t.id == id).firstOrNull;
    if (task == null) {
      notifyListeners();
      return;
    }
    task.status = PreTranslationTaskStatus.canceled;
    _moveToHistory(task);
    if (!_runningIds.contains(id)) {
      _canceledIds.remove(id);
    }
    // Defect C. Cancelling is an explicit statement of intent, and until now
    // the teardown it asked for could not happen: this job's own [OcrLease]
    // was still in [_ocrLeases] (the loop releases it only in its `finally`),
    // so `shutdownAll()` below always took its "a lease is held" branch — free
    // the sessions, keep the isolates, return without ever observing whether
    // the memory came back. Then the loop's remaining pages asked the worker
    // for one more recognition, which re-opened every session lazily, and the
    // VRAM the user had just cancelled was loaded again on their side of the
    // screen.
    //
    // Dropping *our own* lease here is the step that was missing, and it is
    // the same move [_waitWhilePaused] already makes on pause: a task that is
    // going away does not need the pool, and no *other* task's lease is
    // touched, so the rule the lease exists for — never pull the isolates out
    // from under someone still reading them — stays intact. What is in flight
    // right now completes with an error and is discarded, which is exactly
    // what a cancellation is for.
    _ocrLeases.remove(id)?.release();
    if (currentTasks.every((t) => !t.isRunning)) {
      unawaited(TranslationWorker.instance.shutdownAll());
    }
    notifyListeners();
  }

  /// Cancels just one chapter of a still-running job, leaving the other
  /// chapters to keep translating. The chapter is flagged [PreTranslationChapter.canceled]
  /// so both the forward pass and the retry pass skip it; an in-flight chapter
  /// stops at the next group boundary. If every remaining chapter is now
  /// canceled (or already finished), the whole job is canceled so it doesn't
  /// linger as "running" with nothing left to do.
  void cancelChapter(String taskId, String eid) {
    var task = currentTasks.where((t) => t.id == taskId).firstOrNull;
    if (task == null) return;
    var chapter = task.chapters.where((c) => c.eid == eid).firstOrNull;
    if (chapter == null || chapter.canceled) return;
    chapter.canceled = true;
    // If nothing is left to do, cancel the whole job. "Left to do" = a chapter
    // that isn't canceled and isn't already fully processed.
    var hasPending = task.chapters.any((c) {
      if (c.canceled) return false;
      return c.total <= 0 || (c.done + c.failed) < c.total;
    });
    if (!hasPending) {
      cancel(taskId);
      return;
    }
    _saveActive();
    notifyListeners();
  }

  /// Pauses a running pre-translation job. The worker loop checks this state
  /// between pages and waits until [resume] is called or the job is canceled.
  void pause(String id) {
    var task = currentTasks.where((t) => t.id == id).firstOrNull;
    if (task == null || !task.isRunning) return;
    task.status = PreTranslationTaskStatus.paused;
    _saveActive();
    notifyListeners();
    if (currentTasks.every((t) => !t.isRunning)) {
      unawaited(TranslationWorker.instance.shutdownAll());
    }
  }

  /// Resumes a paused pre-translation job.
  void resume(String id) {
    var task = currentTasks.where((t) => t.id == id).firstOrNull;
    if (task == null || task.status != PreTranslationTaskStatus.paused) return;
    task.status = PreTranslationTaskStatus.running;
    _saveActive();
    notifyListeners();
    if (!_runningIds.contains(id)) {
      unawaited(_run(task));
    }
  }

  /// Manually re-runs the failed pages of a job. Works on a running job (the
  /// running loop's own auto-retry already covers it, so this is mainly for a
  /// finished one) or a finished/failed job in history: the job is moved back
  /// to the active list, set running, and re-driven — [_run]'s forward loop
  /// no-ops on already-processed chapters, then [_retryFailedPasses] re-runs
  /// just the failed pages. Succeeded pages are never re-requested (they skip
  /// via hasRenderedPage). Does nothing if the job has no failures.
  void retryFailed(String id) {
    var task =
        currentTasks.where((t) => t.id == id).firstOrNull ??
        historyTasks.where((t) => t.id == id).firstOrNull;
    if (task == null || !task.hasFailures) return;
    if (_runningIds.contains(task.id)) return;
    if (historyTasks.remove(task)) {
      currentTasks.insert(0, task);
    }
    task.status = PreTranslationTaskStatus.running;
    task.finishedAt = null;
    _canceledIds.remove(task.id);
    _saveActive();
    notifyListeners();
    unawaited(_run(task));
  }

  void _refreshKeepAlive(PreTranslationTask task) {
    var activity = _activities[task.id];
    // Processed, not succeeded: a chapter whose pages keep failing would
    // otherwise leave the notification frozen on the last successful page.
    var processed = activity?.liveProcessed(task) ?? (task.done + task.failed);
    BackgroundKeepAlive.instance.update(
      BackgroundKeepAlive.tagPreTranslate,
      formatTaskStatus(
        title: task.title,
        detail: task.total == 0 ? null : '$processed/${task.total}',
      ),
    );
  }

  /// One lease per running task. While any lease is held, `shutdownAll()`
  /// degrades to `release()` so that a task finishing cannot kill the worker
  /// isolates another task is still reading from (plan D-9).
  final _ocrLeases = <String, OcrLease>{};

  Future<void> _run(PreTranslationTask task) async {
    if (_runningIds.contains(task.id)) return;
    if (_canceledIds.contains(task.id) || !currentTasks.contains(task)) {
      return;
    }
    _runningIds.add(task.id);
    _activities[task.id] = PreTranslationActivity();
    _ocrLeases[task.id] = TranslationWorker.instance.acquireLease();
    _refreshKeepAlive(task);
    try {
      for (var chapter in task.chapters) {
        if (_canceledIds.contains(task.id)) break;
        if (chapter.canceled) continue;
        await _waitWhilePaused(task);
        if (_canceledIds.contains(task.id)) break;
        await _runChapter(task, chapter);
      }
      // Auto-retry the failed pages once: a transient error (network blip, rate
      // limit) on the first pass is common, and one automatic sweep clears most
      // of them without the user noticing. Only the pages that actually failed
      // are re-run; succeeded pages are untouched.
      if (!_canceledIds.contains(task.id) &&
          task.status == PreTranslationTaskStatus.running) {
        await _retryFailedPasses(task);
      }
      if (task.status == PreTranslationTaskStatus.running) {
        task.status = task.failed > 0 && task.done == 0
            ? PreTranslationTaskStatus.failed
            : PreTranslationTaskStatus.completed;
      }
    } catch (e, s) {
      // A cancelled job tears its own worker pool down, and whatever was in
      // flight when it did answers back with "worker disposed". That is the
      // cancellation working, not the job failing — and rewriting `canceled`
      // into `failed` here is what makes a job the user stopped show up red in
      // the list, which reads as "your cancel did something bad".
      if (_canceledIds.contains(task.id) ||
          task.status == PreTranslationTaskStatus.canceled) {
        Log.info('Pre-translation', 'cancelled job aborted in flight: $e');
      } else {
        Log.error('Pre-translation', '$e', s);
        task.status = PreTranslationTaskStatus.failed;
      }
    } finally {
      // Captured before the id goes: the line below is the only place that
      // still knows *why* this loop ended.
      final wasCanceled =
          _canceledIds.contains(task.id) ||
          task.status == PreTranslationTaskStatus.canceled;
      _canceledIds.remove(task.id);
      _runningIds.remove(task.id);
      // Drop our own lease *before* shutting down: shutdownAll() defers while
      // any lease is held, so keeping ours here would block our own cleanup.
      _ocrLeases.remove(task.id)?.release();
      // The coalescing timer is shared by every running job, so it is not this
      // job's to cancel; the notifyListeners below already flushes this one.
      //
      // Freeze the card's last live view *before* the activity dies: per-phase
      // rates, in-flight-credited phase counts and the engine row only exist
      // in the fold of (activity + worker window), and that fold goes stale
      // the moment the pool is released below. Plain JSON on the task object;
      // no new storage. (A job that never got an activity — started, died in
      // `_resolvePageKeys` — still gets a counts-only summary, which is what
      // the committed data can honestly say.)
      // Last chance to stamp a phase that finished with the job itself: the
      // loop's final notify can land after the last page was counted.
      _activities[task.id]?.notePhaseCompletions(task, DateTime.now());
      task.finalSummary = PreTranslationTaskSummary.capture(
        PreTranslationProgress.of(task, activity: _activities[task.id]),
        activity: _activities[task.id],
      );
      _activities.remove(task.id);
      // cancel() already moved the task to history and saved it *before* this
      // summary existed; saving the history again covers that path (a no-op
      // extra write once per job end). For jobs that finish on their own,
      // _moveToHistory performs the save with the summary in place.
      final alreadyMoved = !currentTasks.contains(task);
      _moveToHistory(task);
      if (alreadyMoved) {
        _saveHistory();
      }
      if (currentTasks.every((t) => !t.isRunning)) {
        BackgroundKeepAlive.instance.remove(
          BackgroundKeepAlive.tagPreTranslate,
        );
        // Defect C: awaited, not fired-and-forgotten. The drain above can
        // perfectly well have re-opened the sessions a cancel had already
        // freed — a chunk admitted before the flag was set runs to completion
        // on purpose — so this is the last word on them, and `shutdownAll`
        // answers with what it *observed*: `sessions=0` when the isolates
        // confirmed, `sessions=N/A` when one did not. Both land in the log the
        // user reads next to Task Manager; neither is a claim of success.
        final teardown = await TranslationWorker.instance.shutdownAll();
        if (wasCanceled) {
          Log.info(
            'Pre-translation',
            'cancel of "${task.title}" released the OCR pool: '
            '${teardown.evidence} (workers=${teardown.workers})',
          );
        }
      }
      onTaskFinished?.call(task);
      notifyListeners();
    }
  }

  /// Suspends the loop while [task] is paused, returning as soon as it resumes
  /// or gets canceled. This frees GPU resources while paused.
  Future<void> _waitWhilePaused(PreTranslationTask task) async {
    if (currentTasks.every((t) => !t.isRunning)) {
      // Nothing is executing: hand our lease back so the pool can actually be
      // torn down, and await the handshake instead of firing blind — this is
      // the "pause frees the GPU" path a user can see in Task Manager.
      _ocrLeases.remove(task.id)?.release();
      await TranslationWorker.instance.shutdownAll();
    }
    while (task.status == PreTranslationTaskStatus.paused) {
      if (_canceledIds.contains(task.id)) return;
      // Poll every second. Resume() flips the status and the next iteration
      // exits immediately.
      await Future.delayed(const Duration(seconds: 1));
    }
    // A job the user cancelled on its way out of pause does not get a pool
    // lease back — it has no work left to protect, and holding one would defer
    // the very teardown the cancel asked for.
    if (_canceledIds.contains(task.id) ||
        task.status == PreTranslationTaskStatus.canceled) {
      return;
    }
    _ocrLeases[task.id] ??= TranslationWorker.instance.acquireLease();
  }

  Future<void> _runChapter(
    PreTranslationTask task,
    PreTranslationChapter chapter,
  ) async {
    var activity = _activities[task.id];
    activity
      ?..chapterIndex = task.chapters.indexOf(chapter) + 1
      ..chapterTitle = chapter.title
      ..chapterEid = chapter.eid
      ..bufferedDone = 0
      ..bufferedFailed = 0
      ..groups.clear();
    List<String> pageKeys;
    try {
      pageKeys = await _resolvePageKeys(task, chapter);
    } catch (e, s) {
      Log.error('Pre-translation', 'Failed to list pages: $e', s);
      chapter.failed = chapter.total == 0 ? 1 : chapter.total - chapter.done;
      _saveActiveThrottled();
      notifyListeners();
      return;
    }
    chapter.total = pageKeys.length;
    notifyListeners();

    // Resume across restart: pages already cached are skipped without any
    // network fetch or inference.
    var startIndex = chapter.done + chapter.failed;
    var groupSize = _batchPages;

    // Build the contiguous list of group [start,end) ranges to process.
    var ranges = <({int start, int end})>[];
    for (var i = startIndex; i < pageKeys.length; i += groupSize) {
      ranges.add((start: i, end: (i + groupSize).clamp(0, pageKeys.length)));
    }
    if (ranges.isEmpty) return;

    // Stage 1: Full-Speed GPU OCR Sweep across the entire chapter.
    // Pre-run OCR on all remaining un-rendered pages across the chapter.
    // This allows the GPU to run at maximum throughput without waiting on LLM I/O,
    // stores intermediate OCR results in TranslationStore, and then disposes the
    // TranslationWorker to immediately release all GPU VRAM before translation starts.
    await _runChapterOcrPass(task, chapter, pageKeys, startIndex);
    if (_canceledIds.contains(task.id) || chapter.canceled) return;

    // Overlap groups so a group's translation request can proceed concurrently.
    // Since Stage 1 completed OCR and freed the GPU, Stage 2 (LLM translation + rendering)
    // runs with ep: OrtEpKind.cpu, allowing full network concurrency without GPU VRAM risk.
    var committer = OrderedGroupCommitter(0);
    var overlap = pipelineConcurrencyFor(
      TranslationPerformanceConfig.effective,
      isMobile: App.isMobile,
      sourceLang: task.config.sourceLang,
      hasJapaneseModel: TranslationModels.workerPaths().jaEncoder != null,
      ep: OrtEpKind.cpu,
    );
    var next = 0;
    // Self-removing set: each launched future removes itself on completion, so
    // after `await Future.any(active)` the finished group is already gone and
    // the window slides forward by one. Earlier-registered listeners fire
    // first, so removal happens before Future.any's await returns.
    var active = <Future<void>>{};

    void commit(int groupIndex, GroupResult result, GroupPerf? measured) {
      applyGroupResult(committer, chapter, activity, groupIndex, result);
      // One throughput sample per *committed group* — the commit is the only
      // moment a page is genuinely finished, and sampling here (not per
      // in-flight page) keeps the pages/min figure meaning "pages done",
      // matching the phase lines next to it. The group's own end-to-end wall
      // time rides along when the service measured one, which is what lets the
      // Rendered row answer plan 12-C's first sample instead of waiting for a
      // second commit to straddle three seconds.
      activity?.recordSettledPages(
        result.done + result.failed,
        workMs: measured?.totalMs,
      );
      _refreshKeepAlive(task);
      _saveActiveThrottled();
      notifyListeners();
    }

    void launch(int groupIndex) {
      late Future<void> f;
      var range = ranges[groupIndex];
      // Registered before the work starts so the card shows the group the
      // moment it is queued, and dropped in whenComplete whether it committed,
      // was abandoned or threw — a leftover entry would keep counting pages
      // that no longer exist toward the live progress. A committed group has
      // already been removed (and re-credited as buffered) inside commit; the
      // removal here is idempotent and covers the abandoned/threw paths, where
      // dropping the credit is the correct outcome.
      var groupActivity = PreTranslationGroupActivity(
        index: groupIndex,
        pageCount: range.end - range.start,
      );
      activity?.groups[groupIndex] = groupActivity;
      _notifyActivity();
      // This group's structured timing, held *per group* rather than in one
      // shared slot: up to `overlap` groups are in flight at once, and a
      // committer that releases two of them in one go must not bill the second
      // one with the first one's milliseconds.
      GroupPerf? measured;
      f =
          () async {
            try {
              var result = await _processGroup(
                task,
                chapter,
                pageKeys,
                range.start,
                range.end,
                groupActivity,
                onMeasured: (perf) => measured = perf,
              );
              // A canceled/paused-out group returns null; skip committing it so
              // counts stay at the group boundary and a resume redoes it.
              if (result != null) commit(groupIndex, result, measured);
            } catch (e, s) {
              // Never let a group future complete with an error: with groups
              // overlapping, an errored future would make `Future.any` rethrow and
              // abandon the other in-flight groups (and a second error would become
              // an unhandled async error). An uncommitted group simply stays at the
              // prefix boundary and is redone on resume.
              Log.error('Pre-translation', 'Group task failed: $e', s);
            }
          }().whenComplete(() {
            active.remove(f);
            activity?.groups.remove(groupIndex);
          });
      active.add(f);
    }

    while (next < ranges.length) {
      if (_canceledIds.contains(task.id) || chapter.canceled) break;
      await _waitWhilePaused(task);
      if (_canceledIds.contains(task.id) || chapter.canceled) break;
      launch(next++);
      if (active.length >= overlap) {
        await Future.any(active);
      }
    }
    await Future.wait(active);
  }

  /// Stage 1: Continuous GPU OCR pass across all remaining pages in [chapter].
  ///
  /// Extracts text and bubble bounding boxes at maximum GPU batching speed
  /// without waiting for remote LLM responses. Results are saved directly into
  /// [TranslationStore.putOcr]. How the GPU is handed back afterwards depends
  /// on [PipelineMode]: `freeVram` releases the worker pool through the
  /// release handshake at the end of the sweep, `throughput` keeps it warm for
  /// the next chapter (ruling R-4; the pool is still shut down at task
  /// end/pause/cancel either way).
  Future<void> _runChapterOcrPass(
    PreTranslationTask task,
    PreTranslationChapter chapter,
    List<String> pageKeys,
    int startIndex,
  ) async {
    final service = ImageTranslationService.instance;
    final store = TranslationStore();
    final perf = TranslationPerformanceConfig.effective;
    final sourceLang = service.effectiveSourceFor(task.comicKey, task.config);
    // One fingerprint for the whole sweep: it stats the selected model files,
    // and every OCR-cache reader must agree on the same value (plan §5.3).
    final ocrFp = ImageTranslationService.ocrFingerprintFor(sourceLang);

    // 1. Identify which page indices still need OCR
    final ocrNeeded = <int>[];
    for (var i = startIndex; i < pageKeys.length; i++) {
      if (_canceledIds.contains(task.id) || chapter.canceled) return;
      final imageKey = pageKeys[i];
      final cacheKey = ImageTranslationService.cacheKeyFor(
        imageKey,
        task.sourceKey,
        task.cid,
        chapter.eid,
      );
      if (await service.hasRenderedPage(cacheKey, task.config.mode)) {
        continue;
      }
      if (store.get(cacheKey) != null) {
        continue;
      }
      if (store.hasOcr(cacheKey, fingerprint: ocrFp)) {
        continue;
      }
      ocrNeeded.add(i);
    }

    if (ocrNeeded.isEmpty) {
      return;
    }

    // 2. Report OCR sweep activity in UI
    final activity = _activities[task.id];
    final ocrSlot = PreTranslationGroupActivity(
      index: -1,
      pageCount: ocrNeeded.length,
    )..stage = TranslationStage.recognizing;
    activity?.groups[PreTranslationActivity.ocrSweepIndex] = ocrSlot;
    _notifyActivity();

    try {
      final chunkSize = math.max<int>(1, perf.pagesPerOcrCall);
      final pipeline = service.pipeline;
      // Fetch ahead while the GPU is busy, instead of alternating download and
      // inference per chunk (plan D-7). Concurrency still flows through
      // `_fetchPageBytes`, which holds the per-source rate limit, so no second
      // uncoordinated gate is introduced here.
      final prefetcher = PagePrefetcher(
        depth: (perf.imageConcurrency * 2).clamp(2, 8),
        fetch: (idx) => _fetchPageBytes(task, chapter.eid, pageKeys[idx]),
      );
      final pending = <({int index, String cacheKey, Uint8List bytes})>[];
      // Two counts on purpose (S1, telemetry honesty). A page can leave the
      // sweep without having been recognised — its fetch failed, or the chunk
      // that carried it threw — and the sweep must not call that "recognized".
      // `settledProcessed` only drives the bar (the denominator keeps moving,
      // so the job never freezes at 0 %), `recognizedProcessed` is the raw
      // figure printed as "recognized X / total" and is incremented *only*
      // where `putOcr` succeeded. "Unreadable is N/A, never a fake credit."
      var settledProcessed = 0;
      var recognizedProcessed = 0;

      Future<void> runChunk(
        List<({int index, String cacheKey, Uint8List bytes})> chunkData,
      ) async {
        if (chunkData.isEmpty) return;
        // The chunk's own wall time: the recognition stream's first sample is
        // only honest if it carries the duration those pages were measured
        // over (plan 12-C). Timed here, at the call site, so the number
        // includes exactly what the sweep waited for.
        final chunkSw = Stopwatch()..start();
        // Whether the batch actually came back. A chunk that threw cost wall
        // time but produced no recognition, and billing its milliseconds to
        // the pages it failed would leak retry/timeout latency into the
        // sweep's ms/page — the fetch-failure path below already credits pages
        // without a duration for exactly this reason, and the two must agree.
        var recognized = false;
        // Declared outside the try on purpose: the accounting below runs
        // whether the chunk succeeded or threw, and a `stored` scoped to the
        // try block does not exist there (this compiled as a getter lookup on
        // the class and failed the whole suite for 109 cases).
        var stored = 0;
        try {
          final results = await pipeline.ocrPages(
            chunkData.map((e) => e.bytes).toList(),
            sourceLang: sourceLang,
            targetLang: task.config.targetLang,
          );
          for (var c = 0; c < chunkData.length; c++) {
            if (c < results.length && !results[c].hasError) {
              store.putOcr(
                chunkData[c].cacheKey,
                results[c],
                fingerprint: ocrFp,
              );
              stored++;
            }
          }
          recognized = true;
        } catch (e, s) {
          Log.warning('Pre-translation', 'GPU OCR sweep chunk failed: $e\n$s');
        }
        chunkSw.stop();
        // The chunk is settled either way — it is not retried — so the bar's
        // denominator always advances. Its *recognition* only advanced by the
        // pages `putOcr` actually stored, which on the throw path is zero.
        // [sweepPageAccounting] holds that arithmetic so it can be tested
        // without a GPU.
        final step = sweepPageAccounting(
          settledPages: settledProcessed,
          recognizedPages: recognizedProcessed,
          chunkPages: chunkData.length,
          storedPages: stored,
        );
        settledProcessed = step.settledPages;
        recognizedProcessed = step.recognizedPages;
        ocrSlot.completedPages = step.completedPages;
        // Raw count for the "recognized X / total" line: the 0.55 weight
        // above is for the bar's page-equivalents and must not leak into a
        // figure that is printed next to a page total.
        ocrSlot.recognizedPages = step.recognizedPages;
        // A failed chunk is not billed to the sweep's rate either: with
        // `stored == 0` the producer adds nothing at all, because a zero-page
        // sample is not a measurement of anything (`_ThroughputTracker.add`
        // ignores pages <= 0). Only a chunk that really produced recognition
        // carries its wall time — the same rule the fetch-failure path below
        // already follows.
        if (stored > 0) {
          activity?.recordOcrPages(
            stored,
            workMs: recognized ? chunkSw.elapsedMilliseconds : null,
          );
        }
        _notifyActivity();
      }

      // The single sweep optimisation: keep the OCR pool's declared capacity
      // actually fed. As written above, `runChunk` was awaited inline — so at
      // most ONE `ocrPages` call was ever in flight, `_pickWorker` always
      // found worker[0] idle and returned it, the pool never grew past a
      // single isolate no matter what `imageTranslationOcrWorkers` said (the
      // slider was a dead knob for pre-translation), and that isolate
      // strictly alternated CPU pre/post-processing with GPU inference — the
      // mechanism behind the ~20% GPU occupancy. A bounded window of
      // concurrent chunk calls lets one worker's CPU work overlap another's
      // GPU submissions. `poolCapacity` already applies the GPU (≤2) and
      // mobile clamps; the window stays ≤2 on top, so the sweep never peaks
      // beyond the concurrency the interactive reader already reaches with
      // its two in-flight pages.
      final ocrWindow = ocrSweepWindowFor(
        TranslationWorker.instance.poolCapacity(
          sourceLang: sourceLang,
          paths: TranslationModels.workerPaths(),
        ),
      );
      var chunksStarted = 0;
      var maxInflight = 0;
      var stoppedEarly = false;
      final sweepSw = Stopwatch()..start();
      final inFlight = <Future<void>>{};

      Future<void> launch(
        List<({int index, String cacheKey, Uint8List bytes})> batch,
      ) async {
        late Future<void> f;
        f = runChunk(batch).whenComplete(() => inFlight.remove(f));
        inFlight.add(f);
        chunksStarted++;
        if (inFlight.length > maxInflight) maxInflight = inFlight.length;
        if (inFlight.length >= ocrWindow) {
          // Sliding-window backpressure: admit no more until one finishes.
          // Each future removes itself in `whenComplete`, and self-removal
          // registered at add-time fires first, so the set has already
          // shrunk by the time `Future.any` resumes (same pattern as the
          // stage-2 group window in [_runChapter]).
          await Future.any(inFlight);
        }
      }

      await for (final page in prefetcher.run(ocrNeeded)) {
        if (_canceledIds.contains(task.id) || chapter.canceled) {
          stoppedEarly = true;
          break;
        }
        await _waitWhilePaused(task);
        if (_canceledIds.contains(task.id) || chapter.canceled) {
          stoppedEarly = true;
          break;
        }
        final fetchError = page.error;
        if (fetchError != null) {
          // Stage 2 still visits this page (it has no OCR row), so nothing is
          // lost — but the sweep must say so instead of going quiet (D-12).
          Log.warning(
            'Pre-translation',
            'Fetch failed in OCR sweep (page ${page.index}): $fetchError',
          );
          // Settled, not recognized: nothing was read on this page, so it must
          // not move the "recognized X / total" figure — and, for the same
          // reason, it must not be billed to the sweep's rate. The old
          // `recordOcrPages(1)` here credited a fetch failure as a recognized
          // page with no duration, which inflated the window's numerator while
          // the wall denominator stayed put: a rate too high, an ETA too
          // optimistic. The page still settles for the bar above.
          final step = sweepPageAccounting(
            settledPages: settledProcessed,
            recognizedPages: recognizedProcessed,
            chunkPages: 1,
            storedPages: 0,
          );
          settledProcessed = step.settledPages;
          recognizedProcessed = step.recognizedPages;
          ocrSlot.completedPages = step.completedPages;
          ocrSlot.recognizedPages = step.recognizedPages;
          _notifyActivity();
          continue;
        }
        final imageKey = pageKeys[page.index];
        pending.add((
          index: page.index,
          cacheKey: ImageTranslationService.cacheKeyFor(
            imageKey,
            task.sourceKey,
            task.cid,
            chapter.eid,
          ),
          bytes: page.bytes!,
        ));
        if (pending.length >= chunkSize) {
          await launch(List.of(pending));
          pending.clear();
        }
      }
      // The tail is a real chunk. Dropping it would silently skip the last
      // pages of every chapter whose length is not a multiple of chunkSize.
      if (!stoppedEarly && pending.isNotEmpty) {
        await launch(List.of(pending));
        pending.clear();
      }
      // In-flight chunks run to completion: their `putOcr` writes are per
      // page and idempotent, so a canceled sweep still caches what it
      // started — but the sweep must not RETURN with them dangling, because
      // the freeVram handshake in `finally` releases exactly the workers
      // these futures are using.
      await Future.wait(inFlight);
      Log.info(
        'Pre-translation',
        'OcrSweep pages=${ocrNeeded.length} chunks=$chunksStarted '
        'window=$ocrWindow maxInflight=$maxInflight '
        'wall_ms=${sweepSw.elapsedMilliseconds} '
        'ms_per_page='
        '${(sweepSw.elapsedMilliseconds / math.max(1, ocrNeeded.length)).toStringAsFixed(1)}'
        '${stoppedEarly ? ' canceled=true' : ''}',
      );
      if (stoppedEarly) return;
    } finally {
      activity?.groups.remove(PreTranslationActivity.ocrSweepIndex);
      _notifyActivity();
      // freeVram (the factory default): hand the GPU memory back through the
      // release handshake — awaiting here means the sessions are provably
      // closed before the next stage starts. (The previous comment here
      // claimed `dispose()` freed VRAM "immediately"; it killed the isolate
      // instead and stranded the sessions — plan D-1/D-13.)
      // throughput: keep the pool warm so the next chapter's sweep reuses the
      // loaded sessions while this chapter's stage 2 burns network time
      // (ruling R-4). The default stays freeVram until gate G2 measures that
      // release really frees VRAM — **and the warm-pool half of that bargain
      // is only about work that is still going on.** A cancelled chapter has no
      // such work: it is draining, and everything it recognises from here is
      // thrown away. Warming a pool for a job the user just stopped is how
      // "取消即释放" turned into "取消后显存还在", so the cancel path ignores
      // [PipelineMode] entirely. (Nothing else about the modes changes here,
      // and the factory default is still freeVram — gate G2 has not passed.)
      final canceled = _canceledIds.contains(task.id) || chapter.canceled;
      if (releasesPoolOnSweepEnd(
        mode: TranslationPerformanceConfig.pipelineMode,
        canceled: canceled,
      )) {
        await TranslationWorker.instance.shutdownAll();
      }
    }
  }

  /// Applies one finished group's counts, keeping the display channel in step.
  ///
  /// The group leaves [activity]'s in-flight map and its pages become buffered
  /// credit; when [committer] releases a contiguous run, those pages move out of
  /// the buffer and into the chapter counters. Every group's pages therefore
  /// enter the buffer exactly once and leave exactly once, so the live figures
  /// never double-count a group and never dip while one waits behind a slower
  /// predecessor. A group that is abandoned instead of committed never gets
  /// here, so its in-flight credit is simply dropped — which is correct, since
  /// a resume will redo it.
  @visibleForTesting
  static void applyGroupResult(
    OrderedGroupCommitter committer,
    PreTranslationChapter chapter,
    PreTranslationActivity? activity,
    int groupIndex,
    GroupResult result,
  ) {
    activity?.groups.remove(groupIndex);
    if (activity != null) {
      activity.bufferedDone += result.done;
      activity.bufferedFailed += result.failed;
    }
    for (var r in committer.record(groupIndex, result)) {
      chapter.done += r.done;
      chapter.failed += r.failed;
      chapter.failedPages.addAll(r.failedPages);
      if (activity != null) {
        activity.bufferedDone -= r.done;
        activity.bufferedFailed -= r.failed;
      }
    }
  }

  /// Whether the OCR pool is given back when a chapter's stage-1 sweep ends.
  ///
  /// [PipelineMode] is a *throughput* policy: `throughput` keeps the loaded
  /// sessions around so the next chunk does not pay for them twice. A cancelled
  /// job has no next chunk — everything it does from here is discarded — so the
  /// mode has nothing left to optimise, and holding the VRAM for it is pure
  /// cost. Hence: **any** cancel releases, in either mode. This is not a change
  /// to the factory default (`freeVram` it stays, gate G2 has not measured the
  /// release otherwise) and not a change to what `throughput` does for work
  /// that is still running.
  @visibleForTesting
  static bool releasesPoolOnSweepEnd({
    required PipelineMode mode,
    required bool canceled,
  }) => canceled || mode == PipelineMode.freeVram;

  /// How many OCR chunks the stage-1 sweep keeps in flight, given the worker
  /// pool's real dispatch capacity. Floor 1 (work must still flow when the
  /// pool resolves to a single isolate — mobile/ja), ceiling 2: that is the
  /// pool's own desktop-GPU cap and the concurrency the interactive reader
  /// already reaches with its two in-flight pages, so the sweep overlaps CPU
  /// pre/post-processing with GPU inference across isolates without ever
  /// asking for a VRAM peak the app is not already designed around
  /// (freeVram stays the memory-first factory default; G2 unproven).
  @visibleForTesting
  static int ocrSweepWindowFor(int poolCapacity) =>
      math.min(2, math.max(1, poolCapacity));

  /// How many pre-translation groups may be in flight at once. Bounded by the
  /// LLM concurrency setting (the pipeline's scarcest shared resource); the
  /// per-source image gate and OCR worker pool further shape actual parallelism.
  @visibleForTesting
  static int pipelineConcurrencyFor(
    TranslationPerformanceValues performance, {
    required bool isMobile,
    required String sourceLang,
    required bool hasJapaneseModel,
    OrtEpKind ep = OrtEpKind.cpu,
  }) {
    if (isMobile &&
        (sourceLang == 'ja' || (sourceLang == 'auto' && hasJapaneseModel))) {
      return 1;
    }
    final base = performance.llmConcurrency.clamp(1, 8);
    if (ep != OrtEpKind.cpu) {
      // GPU is serialized; overlap > 2 just causes more pages to hold decoded
      // RGBA buffers and queue for VRAM, raising VRAM pressure and OOM risk.
      return math.min(base, 2);
    }
    return base;
  }

  /// Re-runs only the pages that failed, across every chapter that has any.
  /// A success moves a page from failed→done (the chapter's failed count drops
  /// and its index leaves [PreTranslationChapter.failedPages]); a page that
  /// fails again stays recorded. Because this only shifts counts between failed
  /// and done — never changing done+failed — the forward resume cursor
  /// (startIndex = done + failed) stays valid.
  ///
  /// Called once automatically at the end of [_run], and again on each manual
  /// [retryFailed]. Chapters recorded before this feature existed have failures
  /// but no indices; those are re-scanned wholesale by zeroing their counters
  /// so the forward path redoes them (rendered pages skip cheaply).
  Future<void> _retryFailedPasses(PreTranslationTask task) async {
    var groupSize = _batchPages;
    for (var chapter in task.chapters) {
      if (_canceledIds.contains(task.id)) return;
      if (chapter.canceled) continue;
      if (chapter.failed <= 0) continue;

      // The retry sweep also walks one chapter at a time: point the activity at
      // it so the card names the right chapter, and clear any buffered credit
      // the forward pass left behind (an abandoned group can strand a later
      // group in the committer) so it cannot be attributed to this one.
      _activities[task.id]
        ?..chapterIndex = task.chapters.indexOf(chapter) + 1
        ..chapterTitle = chapter.title
        ..chapterEid = chapter.eid
        ..bufferedDone = 0
        ..bufferedFailed = 0;

      // Legacy task with failures but no recorded indices: reset the chapter so
      // the forward loop re-scans it. Cheap — already-rendered pages skip.
      if (chapter.failedPages.isEmpty) {
        chapter.done = 0;
        chapter.failed = 0;
        chapter.total = 0;
        await _runChapter(task, chapter);
        continue;
      }

      List<String> pageKeys;
      try {
        pageKeys = await _resolvePageKeys(task, chapter);
      } catch (e, s) {
        Log.error('Pre-translation', 'Retry failed to list pages: $e', s);
        continue;
      }

      // Only indices still in range and still marked failed. Sorted so grouping
      // is deterministic.
      var targets =
          chapter.failedPages
              .where((i) => i >= 0 && i < pageKeys.length)
              .toList()
            ..sort();
      for (var g = 0; g < targets.length; g += groupSize) {
        if (_canceledIds.contains(task.id)) return;
        await _waitWhilePaused(task);
        if (_canceledIds.contains(task.id)) return;
        var slice = targets.sublist(
          g,
          (g + groupSize).clamp(0, targets.length),
        );
        GroupPerf? measured;
        await _retryGroup(task, chapter, pageKeys, slice, (perf) {
          measured = perf;
        });
        // The retry pass settles its slice whole; count it as committed
        // throughput so a long retry sweep also shows live pages/min, with the
        // slice's own end-to-end milliseconds so the first slice is already a
        // rate (plan 12-C).
        _activities[task.id]?.recordSettledPages(
          slice.length,
          workMs: measured?.totalMs,
        );
        _refreshKeepAlive(task);
        _saveActiveThrottled();
        notifyListeners();
      }
    }
  }

  /// Re-translates the specific page [indices] of a chapter (a retry slice).
  /// Unlike [_runGroup] this operates on an explicit, possibly non-contiguous
  /// set and moves counts failed→done instead of appending to a prefix, so
  /// done+failed is preserved.
  Future<void> _retryGroup(
    PreTranslationTask task,
    PreTranslationChapter chapter,
    List<String> pageKeys,
    List<int> indices, [
    void Function(GroupPerf perf)? onMeasured,
  ]) async {
    // The retry sweep runs after the forward loop, so no other group holds a
    // slot; index 0 makes this the head one, and the card keeps naming a stage
    // instead of dropping back to a bare "running" for the whole sweep.
    var activity = _activities[task.id];
    var slot = PreTranslationGroupActivity(index: 0, pageCount: indices.length);
    activity?.groups[0] = slot;
    _notifyActivity();
    try {
      await _retrySlice(task, chapter, pageKeys, indices, slot, onMeasured);
    } finally {
      activity?.groups.remove(0);
      _notifyActivity();
    }
  }

  Future<void> _retrySlice(
    PreTranslationTask task,
    PreTranslationChapter chapter,
    List<String> pageKeys,
    List<int> indices,
    PreTranslationGroupActivity activity, [
    void Function(GroupPerf perf)? onMeasured,
  ]) async {
    var service = ImageTranslationService.instance;
    var settledBeforeBatch = 0;
    // See [_processGroup]: the arrival moment, not the render completion, is
    // what the translation window measures.
    DateTime? answeredAt;
    var pending = <({int index, String cacheKey, Uint8List imageBytes})>[];
    void reportFetchPhase() {
      activity
        ..completedPages =
            settledBeforeBatch + pending.length * fetchedPageWeight
        ..stage = TranslationStage.fetching;
      _notifyActivity();
    }

    for (var i in indices) {
      if (_canceledIds.contains(task.id)) return;
      var imageKey = pageKeys[i];
      var cacheKey = ImageTranslationService.cacheKeyFor(
        imageKey,
        task.sourceKey,
        task.cid,
        chapter.eid,
      );
      try {
        if (await service.hasRenderedPage(cacheKey, task.config.mode)) {
          _markRetrySuccess(chapter, i);
          settledBeforeBatch++;
          reportFetchPhase();
          continue;
        }
        var bytes = await _fetchPageBytes(task, chapter.eid, imageKey);
        pending.add((index: i, cacheKey: cacheKey, imageBytes: bytes));
        reportFetchPhase();
      } catch (e, s) {
        Log.warning('Pre-translation', 'Retry page failed: $e\n$s');
        // Still failed; leave it recorded.
        settledBeforeBatch++;
        reportFetchPhase();
      }
    }
    if (pending.isEmpty) return;
    try {
      var config = task.config;
      var results = await service.translatePageGroup(
        pending
            .map((p) => (cacheKey: p.cacheKey, imageBytes: p.imageBytes))
            .toList(),
        task.comicKey,
        config,
        chapter: ImageTranslationService.chapterIdentity(
          cid: task.cid,
          sourceKey: task.sourceKey,
          eid: chapter.eid,
          config: config,
          comicTitle: task.title,
          comicCover: task.cover,
          chapterTitle: chapter.title,
        ),
        shouldCancel: () => _canceledIds.contains(task.id),
        onStage: (stage, completed) {
          // Same sampling rule as the forward pass: the crossing is no longer
          // the stream's sample source (the GroupPerf below carries pages plus
          // duration), it only records *when* the answer landed.
          var crossed = activity.noteStage(stage);
          _activities[task.id]?.notePipelineStage(stage, DateTime.now());
          // The service scores only the pages it was handed, on the same scale.
          activity.completedPages = settledBeforeBatch + completed;
          if (crossed) {
            answeredAt = DateTime.now();
            // `crossed` is the moment this group's answer landed, so the first
            // one of them is the first response of the whole job.
            _activities[task.id]?.noteFirstResponse(answeredAt!);
          }
          _notifyActivity();
        },
        onGroupPerf: (perf) {
          // Same rule as the forward pass: bill a request that happened, and
          // credit a cache-resolved arrival without a duration.
          if (perf.llmPages > 0) {
            _activities[task.id]?.recordTranslatedGroup(perf, at: answeredAt);
          } else {
            _activities[task.id]?.recordTranslatedPages(
              pending.length,
              at: answeredAt,
            );
          }
          _activities[task.id]?.recordRenderWork(perf);
          onMeasured?.call(perf);
        },
      );
      for (var j = 0; j < pending.length; j++) {
        if (results[j]) {
          _markRetrySuccess(chapter, pending[j].index);
        }
      }
    } on PipelineCanceled {
      return;
    } catch (e, s) {
      Log.warning('Pre-translation', 'Retry group failed: $e\n$s');
      // Whole group still failed; leave every index recorded.
    }
  }

  /// Moves one page from failed→done after a successful retry, keeping
  /// done+failed (and thus the forward resume cursor) invariant.
  void _markRetrySuccess(PreTranslationChapter chapter, int index) {
    if (!chapter.failedPages.remove(index)) return;
    chapter.done++;
    if (chapter.failed > 0) chapter.failed--;
  }

  /// How many pages' bubbles to merge into one LLM request. 1 (default) keeps
  /// the historic per-page path; larger gives the model cross-page context and
  /// cuts request count. Clamped to a sane range so a bad stored value can't
  /// break the loop or overflow the model's context.
  int get _batchPages {
    return TranslationPerformanceConfig.effective.batchPages.clamp(1, 20);
  }

  /// Translates pages [start, end) of a chapter. For a single page this is the
  /// original per-page path (one page = one request); for several it fetches
  /// each page's bytes then hands the group to [translatePageGroup] so their
  /// bubbles share one request. Pages already rendered are skipped up front.
  Future<GroupResult?> _processGroup(
    PreTranslationTask task,
    PreTranslationChapter chapter,
    List<String> pageKeys,
    int start,
    int end,
    PreTranslationGroupActivity activity, {
    /// Receives this group's [GroupPerf] exactly once, when the service reports
    /// it. The caller keeps it next to the group so the commit sample can carry
    /// the same group's end-to-end milliseconds (plan 12-C's first sample).
    void Function(GroupPerf perf)? onMeasured,
  }) async {
    var service = ImageTranslationService.instance;
    var pending = <({int index, String cacheKey, Uint8List imageBytes})>[];
    var done = 0;
    var failed = 0;
    // Page indices that failed this group, recorded so a later retry pass can
    // re-run exactly these. Collected locally and returned as a GroupResult so
    // the caller's committer merges them into the chapter in strict group
    // order (never mutating the chapter directly from here).
    var failedIndices = <int>{};
    // Pages this group settled before the batch call; the service reports its
    // own settled count relative to what it was handed, so the two add up.
    var preSettled = 0;
    // When this group's batch answer landed, i.e. the moment its pages became
    // "translated". The GroupPerf arrives later (after the draw loop), and the
    // translation window must be spanned by the arrival times, not by the
    // render completions, or it quietly starts measuring a different phase.
    DateTime? answeredAt;
    activity.stage = TranslationStage.fetching;
    _notifyActivity();

    void reportFetchPhase() {
      activity.completedPages = preSettled + pending.length * fetchedPageWeight;
      _notifyActivity();
    }

    for (var i = start; i < end; i++) {
      // Cancel before the group is counted: return null so the caller leaves
      // the chapter counters at the group's start boundary and a resume redoes
      // the whole group. Every page is idempotent (rendered ones skip via
      // hasRenderedPage), so nothing is double-counted or skipped.
      if (_canceledIds.contains(task.id)) return null;
      var imageKey = pageKeys[i];
      var cacheKey = ImageTranslationService.cacheKeyFor(
        imageKey,
        task.sourceKey,
        task.cid,
        chapter.eid,
      );
      try {
        if (await service.hasRenderedPage(cacheKey, task.config.mode)) {
          done++;
          preSettled++;
          reportFetchPhase();
          continue;
        }
        var bytes = await _fetchPageBytes(task, chapter.eid, imageKey);
        pending.add((index: i, cacheKey: cacheKey, imageBytes: bytes));
        reportFetchPhase();
      } catch (e, s) {
        Log.warning('Pre-translation', 'Page failed: $e\n$s');
        failed++;
        failedIndices.add(i);
        preSettled++;
        reportFetchPhase();
      }
    }
    if (pending.isNotEmpty) {
      try {
        var config = task.config;
        var results = await service.translatePageGroup(
          pending
              .map((p) => (cacheKey: p.cacheKey, imageBytes: p.imageBytes))
              .toList(),
          task.comicKey,
          config,
          chapter: ImageTranslationService.chapterIdentity(
            cid: task.cid,
            sourceKey: task.sourceKey,
            eid: chapter.eid,
            config: config,
            comicTitle: task.title,
            comicCover: task.cover,
            chapterTitle: chapter.title,
          ),
          shouldCancel: () => _canceledIds.contains(task.id),
          onStage: (stage, completed) {
            // The translating→rendering crossing is the moment this group's
            // batch response landed (see PreTranslationGroupActivity
            // .noteStage). It no longer *samples* the translation stream — the
            // structured GroupPerf below carries both the pages and the
            // duration, which is a measurement instead of a proxy — but it is
            // still the timestamp the perf sample is credited at, so the
            // window measures "answer landed", not "page finished drawing".
            var crossed = activity.noteStage(stage);
            _activities[task.id]?.notePipelineStage(stage, DateTime.now());
            // The service scores only the pages it was handed, on the same
            // page-unit scale, so the two halves simply add up.
            activity.completedPages = preSettled + completed;
            if (crossed) {
              answeredAt = DateTime.now();
              _activities[task.id]?.noteFirstResponse(answeredAt!);
            }
            _notifyActivity();
          },
          onGroupPerf: (perf) {
            // Measured work when there was a request to measure: the pages it
            // carried and the wall time it spent (plan 12-B/12-C).
            if (perf.llmPages > 0) {
              _activities[task.id]?.recordTranslatedGroup(perf, at: answeredAt);
            } else {
              // A group whose text came from the cache asked nothing, so there
              // is no request to bill and no ms/page to claim — but its pages
              // really were answered, and dropping the sample entirely would
              // make a resumed chapter re-rendering from cached text (the
              // fastest thing the pipeline does) show `页/分: —`. Credit the
              // arrival, duration-less, exactly as the crossing used to: the
              // wall-clock window still sees it, the measured figures don't.
              _activities[task.id]?.recordTranslatedPages(
                pending.length,
                at: answeredAt,
              );
            }
            _activities[task.id]?.recordRenderWork(perf);
            onMeasured?.call(perf);
          },
        );
        for (var j = 0; j < pending.length; j++) {
          if (results[j]) {
            done++;
          } else {
            failed++;
            failedIndices.add(pending[j].index);
          }
        }
      } on PipelineCanceled {
        // Canceled mid-request: abandon this group's counts entirely (return
        // null). Pages rendered before the cancel are cached and get counted
        // (once) when the group is redone on resume.
        return null;
      } catch (e, s) {
        Log.warning('Pre-translation', 'Group failed: $e\n$s');
        for (var p in pending) {
          failed++;
          failedIndices.add(p.index);
        }
      }
    }
    // Return the whole contiguous group's counts so the caller applies them
    // atomically and in order, keeping done+failed a contiguous processed
    // prefix — the invariant the resume cursor (startIndex = done + failed)
    // relies on.
    return GroupResult(done, failed, failedIndices);
  }

  /// Resolves the ordered image keys of a chapter, from the local library when
  /// downloaded or from the comic source otherwise.
  Future<List<String>> _resolvePageKeys(
    PreTranslationTask task,
    PreTranslationChapter chapter,
  ) async {
    var downloaded = LocalManager().isDownloaded(
      task.cid,
      task.comicType,
      chapter.eid == '0' ? 0 : null,
    );
    if (downloaded) {
      return await LocalManager().getImages(
        task.cid,
        task.comicType,
        chapter.eid == '0' ? 0 : chapter.eid,
      );
    }
    var source = ComicSource.find(task.sourceKey);
    if (source?.loadComicPages == null) {
      throw 'Comic source not found';
    }
    var res = await source!.loadComicPages!(
      task.cid,
      chapter.eid == '0' ? null : chapter.eid,
    );
    if (res.error) {
      throw res.errorMessage ?? 'Failed to load pages';
    }
    return res.data;
  }

  /// Ceiling for fetching one page's bytes. Generous enough for a large page on
  /// a slow connection, but finite so a stalled transfer fails the page instead
  /// of holding an image-concurrency slot forever.
  static const _pageFetchTimeout = Duration(minutes: 2);

  /// Backstop for waiting on an image slot, not a congestion limit — queueing
  /// behind other pages is normal. Set far above any legitimate wait so it only
  /// fires when a slot was genuinely never released.
  static const _slotWaitBackstop = Duration(minutes: 30);

  Future<Uint8List> _fetchPageBytes(
    PreTranslationTask task,
    String eid,
    String imageKey,
  ) async {
    if (imageKey.startsWith('file://')) {
      return await File(imageKey.substring(7)).readAsBytes();
    }
    await _ImageRateLimit.gate.acquire(
      task.sourceKey,
      maxWait: _slotWaitBackstop,
    );
    try {
      Uint8List? bytes;
      // Bounded two ways, because the fetch holds an image-concurrency slot and
      // an unbounded one would retire that slot for good (#176):
      //   - stream.timeout catches a transfer that goes completely silent,
      //   - the deadline catches one that trickles bytes forever without ending.
      var deadline = DateTime.now().add(_pageFetchTimeout);
      var stream = ImageDownloader.loadComicImage(
        imageKey,
        task.sourceKey,
        task.cid,
        eid,
        onRateLimited: (_) =>
            _ImageRateLimit.aimd.onRateLimited(task.sourceKey),
      );
      await for (var event in stream.timeout(
        _pageFetchTimeout,
        onTimeout: (sink) => sink.addError(
          TimeoutException('Image fetch stalled', _pageFetchTimeout),
        ),
      )) {
        if (event.imageBytes != null) {
          bytes = event.imageBytes;
          break;
        }
        if (DateTime.now().isAfter(deadline)) {
          throw TimeoutException('Image fetch too slow', _pageFetchTimeout);
        }
      }
      if (bytes == null) {
        throw 'Empty image data';
      }
      return bytes;
    } finally {
      _ImageRateLimit.gate.release(task.sourceKey);
    }
  }

  void _moveToHistory(PreTranslationTask task) {
    if (!currentTasks.remove(task)) {
      return;
    }
    task.finishedAt ??= DateTime.now();
    historyTasks.insert(0, task);
    if (historyTasks.length > 50) {
      historyTasks.removeRange(50, historyTasks.length);
    }
    _saveActive();
    _saveHistory();
  }

  // -------------------------------------------------------------------------
  // Persistence
  // -------------------------------------------------------------------------

  static const _activeKey = 'pre_translation_active_tasks';
  static const _historyKey = 'pre_translation_task_history';

  DateTime _lastSave = DateTime.fromMillisecondsSinceEpoch(0);

  void _saveActiveThrottled() {
    var now = DateTime.now();
    if (now.difference(_lastSave) < const Duration(seconds: 1)) {
      return;
    }
    _lastSave = now;
    _saveActive();
  }

  void _saveActive() {
    appdata.implicitData[_activeKey] = currentTasks
        .where((t) => t.isRunning)
        .map((t) => t.toJson())
        .toList();
    appdata.writeImplicitData();
  }

  void _saveHistory() {
    appdata.implicitData[_historyKey] = historyTasks
        .map((t) => t.toJson())
        .toList();
    appdata.writeImplicitData();
  }

  void _load() {
    var active = appdata.implicitData[_activeKey];
    if (active is List) {
      currentTasks
        ..clear()
        ..addAll(
          active.whereType<Map>().map((e) {
            var task = PreTranslationTask.fromJson(
              Map<String, dynamic>.from(e),
            );
            // Anything persisted as active is coerced back to running so it can
            // be resumed after a restart.
            task.status = PreTranslationTaskStatus.running;
            task.finishedAt = null;
            return task;
          }),
        );
    }
    var history = appdata.implicitData[_historyKey];
    if (history is List) {
      historyTasks
        ..clear()
        ..addAll(
          history.whereType<Map>().map(
            (e) => PreTranslationTask.fromJson(Map<String, dynamic>.from(e)),
          ),
        );
    }
  }

  /// Resumes jobs interrupted by app termination. Called once at startup.
  void resumePendingTasks() {
    for (var task in currentTasks.toList()) {
      if (task.isRunning && !_runningIds.contains(task.id)) {
        unawaited(_run(task));
      }
    }
  }

  void clearHistory() {
    historyTasks.clear();
    _saveHistory();
    notifyListeners();
  }

  /// Resets the pre-translation status the chapter picker reads from, so that
  /// after the user clears all translation results the "translated" ticks and
  /// progress markers go away too. Finished/canceled/failed jobs (history) are
  /// dropped entirely; a still-running job keeps running but its counters are
  /// zeroed so its chapters re-count from scratch against the now-empty cache.
  void clearAllChapterStatus() {
    historyTasks.clear();
    for (var task in currentTasks) {
      for (var c in task.chapters) {
        c.done = 0;
        c.failed = 0;
        c.total = 0;
        c.canceled = false;
        c.failedPages.clear();
      }
    }
    _saveActive();
    _saveHistory();
    notifyListeners();
  }

  /// Resets the recorded pre-translation status of specific chapters of a comic
  /// (used by the picker's selection-based re-translate). Zeroes their counters
  /// in both history and any running job so the picker stops showing them as
  /// "translated" and a fresh run re-counts them from scratch against the now
  /// cleared cache.
  void resetChapterStatus(String cid, String sourceKey, Set<String> eids) {
    if (eids.isEmpty) return;
    var comicKey = '$cid@$sourceKey';
    for (var task in [...historyTasks, ...currentTasks]) {
      if (task.comicKey != comicKey) continue;
      for (var c in task.chapters) {
        if (eids.contains(c.eid)) {
          c.done = 0;
          c.failed = 0;
          c.total = 0;
          c.canceled = false;
          c.failedPages.clear();
        }
      }
    }
    _saveActive();
    _saveHistory();
    notifyListeners();
  }

  /// Resets the recorded pre-translation status of every chapter of one comic
  /// (used by the detail page's whole-comic re-translate). Drops that comic's
  /// finished history entries and zeroes any running job's counters so the
  /// picker's "translated" ticks for it clear, leaving other comics untouched.
  void resetComicStatus(String cid, String sourceKey) {
    var comicKey = '$cid@$sourceKey';
    historyTasks.removeWhere((t) => t.comicKey == comicKey);
    for (var task in currentTasks) {
      if (task.comicKey != comicKey) continue;
      for (var c in task.chapters) {
        c.done = 0;
        c.failed = 0;
        c.total = 0;
        c.canceled = false;
        c.failedPages.clear();
      }
    }
    _saveActive();
    _saveHistory();
    notifyListeners();
  }

  void removeTask(String id) {
    historyTasks.removeWhere((t) => t.id == id);
    _saveHistory();
    notifyListeners();
  }
}

/// Per-source image-fetch concurrency for pre-translation. The effective limit
/// is min(user setting, AIMD estimate); AIMD halves on a 429/503 from the image
/// host and grows back on success, so a rate-limiting host is backed off
/// automatically without the user tuning anything.
class _ImageRateLimit {
  static final aimd = AimdController(min: 1, max: 6);
  static final gate = ConcurrencyGate((bucket) {
    var userMax = TranslationPerformanceConfig.effective.imageConcurrency.clamp(
      1,
      6,
    );
    return math.min(userMax, aimd.limitFor(bucket));
  });
}
