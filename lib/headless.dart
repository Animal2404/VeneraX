import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';
import 'package:flutter/widgets.dart';
import 'package:venera/utils/data_sync.dart';
import 'package:venera/foundation/comic_source/comic_source.dart';
import 'package:venera/foundation/log.dart';
import 'package:venera/pages/comic_source_page.dart';
import 'package:venera/init.dart';
import 'package:venera/foundation/follow_updates.dart';
import 'package:venera/foundation/headless_trace.dart';
import 'package:venera/foundation/follow_update_scope.dart';
import 'package:venera/foundation/app.dart';
import 'package:venera/foundation/favorites.dart';
import 'package:venera/network/cookie_jar.dart';
import 'package:venera/foundation/image_translation/ort_capabilities.dart';
import 'package:venera/foundation/image_translation/process_diagnostics.dart';
import 'package:venera/foundation/image_translation/translation_models.dart';
import 'package:venera/foundation/image_translation/translation_service.dart';
import 'package:venera/foundation/image_translation/translation_store.dart';
import 'package:venera/foundation/image_translation/translation_worker.dart';
import 'package:venera/foundation/appdata.dart';

void cliPrint(Map<String, dynamic> data) {
  print('[CLI PRINT] ${jsonEncode(data)}');
}

/// Startup tracing for `--headless --trace` (see `foundation/headless_trace.dart`
/// for why a file and not a log line).
void _trace(String step) => headlessTrace(step);

/// Headless-internal switch, set once from `--offline` in [runHeadlessMode].
///
/// It exists because the OCR commands are the only headless work that must not
/// touch the network, and the code that would otherwise open sockets (comic
/// source scripts, download auto-resume) is initialised by `App.initComponents()`
/// — which headless may not edit. So the entry point simply does not call it
/// when this is on, and every report records the fact (`machine.offline`).
bool headlessOffline = false;

Future<void> runHeadlessMode(List<String> args) async {
  // Everything the entry point needs to know about argv comes from one pure
  // function, so `--offline` / `--trace` / command position are covered by
  // test/headless_golden_flags_test.dart instead of by a live run.
  final flags = parseHeadlessFlags(args);
  headlessOffline = flags.offline;
  headlessTraceEnabled = flags.trace;
  if (headlessTraceEnabled) headlessTraceStart('run ${DateTime.now()}');
  _trace('ensureInitialized');
  WidgetsFlutterBinding.ensureInitialized();
  _trace('binding ready');
  if (flags.mutedLog) {
    Log.isMuted = true;
  }
  if(Platform.isLinux || Platform.isMacOS){
    Directory.current = Platform.environment['HOME']!;
  }
  // Reject an unusable invocation *before* paying for init(): `--offline` on a
  // command that genuinely needs the network must fail loudly rather than run
  // half-initialised and report a confusing error later.
  if (flags.error != null) {
    cliPrint({'status': 'error', 'message': flags.error});
    exit(1);
  }
  var commandIndex = flags.commandIndex;
  var command = flags.command!;
  var subCommand = (commandIndex + 1 < args.length) ? args[commandIndex + 1] : null;

  // Need to initialize the app for some features to work
  _trace('init() ->');
  await init();
  _trace('init() done');
  if (flags.skipsNetworkInit) {
    // `--offline`: the OCR measurement commands run against local model files
    // only (`TranslationModels.workerPaths()` + `TranslationStore`), and
    // `pipeline.ocrPages` touches no store at all. What is deliberately NOT run
    // here is the comic-source pipeline: `App.initComponents()` -> `local.init()`
    // -> `ComicSourceManager().ensureInit()`, which executes every installed
    // source script through the JS engine, plus the same `local.init()` that
    // arms the 3-second download auto-resume. Both open sockets, which inside a
    // timing harness is only wasted wall clock and log noise (observed: an
    // external request reset by the peer during D-15 measurement runs).
    _trace('offline: skipping cookieJar + initComponents (comic-source load)');
    try {
      await TranslationStore().init();
      _trace('offline: TranslationStore done');
    } catch (e) {
      // A missing translation cache must not stop a measurement; the harness
      // would rather report the page results it has.
      _trace('offline: TranslationStore failed: $e');
      Log.error('headless', 'TranslationStore init failed in offline mode: $e');
    }
  } else {
    // The import path restores backups into LIVE stores (in-place, via the
    // SQLite backup API) instead of swapping files, so every store must be open
    // before a `webdav down` applies data — this also satisfies
    // coreDataStoresReady, which gates applying backups.
    _trace('cookieJar ->');
    await SingleInstanceCookieJar.createInstance();
    _trace('cookieJar done; initComponents ->');
    await App.initComponents();
    _trace('initComponents done');
  }
  // Headless never runs initDeferred(); complete the gate so DataSync's
  // download entry (which waits for deferred init before applying backups)
  // proceeds immediately instead of stalling on its 60s safety timeout.
  if (!deferredInitCompleter.isCompleted) {
    deferredInitCompleter.complete();
  }

  switch (command) {
    case 'webdav':
      if (subCommand == 'up') {
        cliPrint({'status': 'running', 'message': 'Uploading WebDAV data...'});
        var result = await DataSync().uploadData(force: true);
        if (result.error) {
          cliPrint({
            'status': 'error',
            'message': 'Upload failed: ${result.errorMessage}',
          });
          exit(1);
        }
        cliPrint({'status': 'success', 'message': 'Upload complete.'});
      } else if (subCommand == 'down') {
        cliPrint({'status': 'running', 'message': 'Downloading WebDAV data...'});
        var result = await DataSync().downloadData();
        if (result.error) {
          cliPrint({
            'status': 'error',
            'message': 'Download failed: ${result.errorMessage}',
          });
          exit(1);
        }
        cliPrint({'status': 'success', 'message': 'Download complete.'});
      } else {
        cliPrint({'status': 'error', 'message': 'Invalid webdav command. Use "up" or "down".'});
        exit(1);
      }
      break;
    case 'updatescript':
      if (subCommand == 'all') {
        cliPrint({'status': 'running', 'message': 'Checking for comic source script updates...'});
        await ComicSourcePage.checkComicSourceUpdate();
        var updates = ComicSourceManager().availableUpdates;
        if (updates.isEmpty) {
          cliPrint({'status': 'success', 'message': 'No updates found.'});
        } else {
          var total = updates.length;
          var current = 0;
          var errors = 0;
          var updated = 0;
          cliPrint({
            'status': 'running',
            'message': 'Updating all comic source scripts...',
            'data': {
              'total': total,
              'current': 0,
              'updated': 0,
              'errors': 0,
            }
          });
          for (var key in updates.keys) {
            var source = ComicSource.find(key);
            if (source != null) {
              current++;
              var data = {
                'current': current,
                'total': total,
                'source': {
                  'key': source.key,
                  'name': source.name,
                  'version': source.version,
                  'url': source.url,
                }
              };
              try {
                await ComicSourcePage.update(source, false);
                updated++;
                cliPrint({
                  'status': 'running',
                  'message': 'Progress',
                  'data': data,
                });
              } catch (e) {
                errors++;
                cliPrint({
                  'status': 'running',
                  'message': 'ProgressError',
                  'data': {
                    ...data,
                    'error': e.toString(),
                  },
                });
              }
            }
          }
          cliPrint({
            'status': 'success',
            'message': 'All scripts updated.',
            'data': {
              'total': total,
              'updated': updated,
              'errors': errors,
            }
          });
        }
      } else {
        cliPrint({'status': 'error', 'message': 'Invalid updatescript command. Use "all".'});
        exit(1);
      }
      break;
    case 'updatesubscribe':
      cliPrint({'status': 'running', 'message': 'Updating subscribed comics...'});
      var folders = FollowUpdateScope.folders();
      if (folders.isEmpty) {
        cliPrint({'status': 'error', 'message': 'Follow updates is not configured.'});
        exit(1);
      }

      var updateIndex = args.indexOf('--update-comic-by-id-type');
      if (updateIndex != -1) {
        var id = args[updateIndex + 1];
        var type = args[updateIndex + 2];
        var comics = LocalFavoritesManager().getComicsWithUpdatesInfoIn(folders);
        var comic = comics.firstWhere((c) => c.id == id && c.type.sourceKey == type);
        // Write the result into every followed folder that holds the comic, the
        // same way a full check does.
        var holding = LocalFavoritesManager().find(id, comic.type);
        var targets = folders.where(holding.contains).toList();
        var result = await updateComic(comic, targets.isEmpty ? folders : targets);
        
        Map<String, dynamic> data = {
          'current': 1,
          'total': 1,
          'comic': {
            'id': comic.id,
            'name': comic.name,
            'coverUrl': comic.coverPath,
            'author': comic.author,
            'type': comic.type.sourceKey,
            'updateTime': comic.updateTime,
            'tags': comic.tags,
          }
        };

        var message = 'Progress';
        if (result.errorMessage != null) {
          message = 'ProgressError';
          data['error'] = result.errorMessage;
        }

        cliPrint({
          'status': 'running',
          'message': message,
          'data': data,
        });

        cliPrint({
          'status': 'running',
          'message': 'Update check complete.',
          'data': {
            'total': 1,
            'updated': result.updated ? 1 : 0,
            'errors': result.errorMessage != null ? 1 : 0,
          }
        });

        await Future.delayed(const Duration(milliseconds: 500));
        var json = await getUpdatedComicsAsJson(folders);
        cliPrint({
          'status': result.errorMessage != null ? 'error' : 'success',
          'message': 'Updated comics list.',
          'data': jsonDecode(json),
        });
      } else {
        int total = 0;
        int updated = 0;
        int errors = 0;
        await for (var progress in updateFolders(folders, true)) {
          total = progress.total;
          updated = progress.updated;
          errors = progress.errors;
          Map<String, dynamic> data = {
            'current': progress.current,
            'total': progress.total,
          };
          if (progress.comic != null) {
            data['comic'] = {
              'id': progress.comic!.id,
              'name': progress.comic!.name,
              'coverUrl': progress.comic!.coverPath,
              'author': progress.comic!.author,
              'type': progress.comic!.type.sourceKey,
              'updateTime': progress.comic!.updateTime,
              'tags': progress.comic!.tags,
            };
          }
          var message = 'Progress';
          if (progress.errorMessage != null) {
            message = 'ProgressError';
            data['error'] = progress.errorMessage;
          }
          cliPrint({
            'status': 'running',
            'message': message,
            'data': data,
          });
        }
        cliPrint({
          'status': 'running',
          'message': 'Update check complete.',
          'data': {
            'total': total,
            'updated': updated,
            'errors': errors,
          }
        });
        await Future.delayed(const Duration(milliseconds: 500));
        var json = await getUpdatedComicsAsJson(folders);
        cliPrint({
          'status': errors > 0 ? 'error' : 'success',
          'message': 'Updated comics list.',
          'data': jsonDecode(json),
        });
      }
      break;
    case 'ocr-selfcheck':
      await _ocrSelfcheck(args.sublist(commandIndex + 1), subCommand);
      break;
    case 'ocr-golden':
      await _ocrGolden(args.sublist(commandIndex + 1));
      break;
    default:
      cliPrint({'status': 'error', 'message': 'Unknown command: $command'});
      exit(1);
  }

  // Exit after command execution
  exit(0);
}

// ---------------------------------------------------------------------------
// OCR measurement harness — Phase 6 of `VeneraX_AI_Translation_Phase2_Plan.md`.
//
// These commands exist because every performance claim in this project's
// history has been unfalsifiable: no golden corpus, no baseline table, no
// resource reading. The harness must not change inference behaviour; it only
// measures it. Consistency is judged by **exact text equality**, never by
// similarity — a fuzzy metric hides real regressions (plan §3.7).
// ---------------------------------------------------------------------------

/// Reads `--name value` or `--name=value`.
String? _flag(List<String> args, String name) {
  final i = args.indexOf(name);
  if (i >= 0 && i + 1 < args.length) return args[i + 1];
  final prefix = '$name=';
  for (final a in args) {
    if (a.startsWith(prefix)) return a.substring(prefix.length);
  }
  return null;
}

List<String> _flagList(List<String> args, String name, String dflt) =>
    (_flag(args, name) ?? dflt)
        .split(',')
        .map((e) => e.trim())
        .where((e) => e.isNotEmpty)
        .toList();

/// Pulls the structured timing fields out of a worker perf-log line.
Map<String, int> _parsePerfLog(String line) {
  int? grab(String key) =>
      int.tryParse(RegExp('${RegExp.escape(key)}[:{](\\d+)').firstMatch(line)?.group(1) ?? '');
  final out = <String, int>{};
  for (final entry in {
    'detMs': 'det',
    'recMs': 'rec',
    'decMs': 'dec',
    'totalMs': 'total_ms',
  }.entries) {
    final v = grab(entry.value);
    if (v != null) out[entry.key] = v;
  }
  return out;
}

Map<String, dynamic> _lastPerf() {
  final logs = TranslationWorker.instance.recentPerfLogs;
  if (logs.isEmpty) return const {};
  final line = logs.last;
  return {
    ..._parsePerfLog(line),
    'ep': RegExp(r'ep=(\w+)').firstMatch(line)?.group(1),
    'sessions': int.tryParse(
      RegExp(r'sessions=(\d+)').firstMatch(line)?.group(1) ?? '',
    ),
    'degraded': RegExp(r'degraded=(\S+)').firstMatch(line)?.group(1),
  };
}

// ---------------------------------------------------------------------------
// Pure argument / verdict helpers.
//
// Everything that decides "did this measurement pass" lives here rather than
// inside the IO loops for one reason: this harness is the only evidence behind
// every performance claim in the project, so its own decision logic has to be
// unit-testable without a GPU, a model set or a comic source attached.
// Covered by test/headless_golden_flags_test.dart.
// ---------------------------------------------------------------------------

/// Commands that measure local inference and may therefore run with `--offline`.
const List<String> kOfflineCapableCommands = ['ocr-golden', 'ocr-selfcheck'];

/// What argv asked the headless entry point to do — a pure function of argv,
/// no IO, no bindings.
class HeadlessFlags {
  const HeadlessFlags({
    required this.command,
    required this.commandIndex,
    required this.trace,
    required this.offline,
    required this.mutedLog,
  });

  /// `ocr-golden`, `webdav`, … or null when nothing followed `--headless`.
  final String? command;

  /// Index of [command] in argv; every sub-command parser slices from here.
  final int commandIndex;

  /// `--trace`: append every step to the headless trace file.
  final bool trace;

  /// `--offline`: skip the network-typed startup steps.
  final bool offline;

  /// `--ignore-disheadless-log`: mute the app logger.
  final bool mutedLog;

  bool get isOcrCommand => kOfflineCapableCommands.contains(command);

  /// Whether the comic-source / download startup may be skipped. Only ever
  /// true for an OCR command: skipping it elsewhere would silently break
  /// webdav / updatescript / updatesubscribe.
  bool get skipsNetworkInit => offline && isOcrCommand;

  /// A fatal argument problem, or null when the invocation is runnable.
  String? get error {
    if (command == null) return 'No command provided for headless mode.';
    if (offline && !isOcrCommand) {
      return '--offline is only supported for '
          '${kOfflineCapableCommands.join(' and ')}; "$command" needs the '
          'network.';
    }
    return null;
  }
}

@visibleForTesting
HeadlessFlags parseHeadlessFlags(List<String> args) {
  // The first arg is '--headless', so the command is the one right after it.
  final at = args.indexOf('--headless');
  final commandIndex = at + 1;
  final hasCommand = at >= 0 && commandIndex < args.length;
  return HeadlessFlags(
    command: hasCommand ? args[commandIndex] : null,
    commandIndex: hasCommand ? commandIndex : -1,
    trace: args.contains('--trace'),
    offline: args.contains('--offline'),
    mutedLog: args.contains('--ignore-disheadless-log'),
  );
}

/// The recorded `gitsha` plus where it came from, so a reader can tell a
/// build-time attestation from a CI-runtime one. Never guess: an unknown sha is
/// reported as empty and `tool/ocr_run_stats.dart` refuses it.
@visibleForTesting
class GitShaInfo {
  const GitShaInfo(this.sha, this.source);
  final String sha;

  /// `'dart-define'` | `'github-sha'` | `'none'`.
  final String source;
}

@visibleForTesting
GitShaInfo resolveGitSha({
  String? defineValue,
  Map<String, String>? environment,
}) {
  final define = (defineValue ?? const String.fromEnvironment('GIT_SHA')).trim();
  if (define.isNotEmpty) return GitShaInfo(define, 'dart-define');
  // `GITHUB_SHA` only exists inside a Actions step, where it is by definition
  // the commit that produced the artifact, so it cannot mis-attribute a stale
  // binary. A developer-set `GIT_SHA` *could*, which is why it is deliberately
  // not read here.
  final ci = (environment ?? Platform.environment)['GITHUB_SHA']?.trim() ?? '';
  if (ci.isNotEmpty) return GitShaInfo(ci, 'github-sha');
  return const GitShaInfo('', 'none');
}

/// One failed page/variant: what was being measured, and what the evidence
/// says. `doc/ocr-baseline.md` D-15 step 0 requires the model paths and the
/// session EP in the record — without them a crash cannot be attributed to a
/// model at all, which is exactly how D-15 stayed unsolved for a whole run.
@visibleForTesting
Map<String, dynamic> ocrErrorRecord({
  required String file,
  required String tier,
  required int batch,
  required int group,
  required int variant,
  required String error,
  Map<String, dynamic> context = const {},
  String? stack,
}) {
  return {
    'file': file,
    'tier': tier,
    'batch': batch,
    'group': group,
    'variant': variant,
    'error': error,
    ...context,
    if (stack != null && stack.isNotEmpty) 'stack': stack,
  };
}

/// Flatten [WorkerModelPaths] into JSON-safe fields for an error record.
///
/// `dirs` is deliberate: the D-15 CPU containment
/// (`translation_worker.dart` -> `_cpuOnlyRecDirs`) is matched against the
/// *model directory name*, so a reader has to be able to compare the two
/// without re-deriving anything from a path. Reporting the resolved directory
/// names beside the full paths turns "did the pin apply?" from a guess into a
/// line-by-line check — and survives both separators, unlike a matcher that
/// assumes one.
@visibleForTesting
Map<String, dynamic> describeModelPaths(WorkerModelPaths paths) {
  final recDirs = <String, String>{
    for (final e in paths.recModels.entries) e.key: _dirName(e.value),
  };
  return {
    'detector': paths.detector,
    'recModels': paths.recModels,
    'recDicts': paths.recDicts,
    'recHeights': paths.recHeights,
    if (paths.jaEncoder != null) 'jaEncoder': paths.jaEncoder,
    if (paths.jaDecoder != null) 'jaDecoder': paths.jaDecoder,
    if (paths.jaVocab != null) 'jaVocab': paths.jaVocab,
    'dirs': {
      'detector': _dirName(paths.detector),
      ...recDirs,
      if (paths.jaEncoder != null) 'jaEncoder': _dirName(paths.jaEncoder!),
    },
  };
}

/// The parent directory name of a model file. The on-disk layout is
/// `translation_models/<componentId>/<file>`, so this yields the
/// `componentId` token — which is exactly what the CPU pin list is written in.
String _dirName(String path) {
  final parts = path
      .replaceAll(_backslash, '/')
      .split('/')
    ..removeWhere((e) => e.isEmpty);
  return parts.length < 2 ? '' : parts[parts.length - 2];
}

/// A single backslash, spelled so it cannot be mistaken for an empty pattern.
const String _backslash = '\\';

/// The consistency gate (plan §3.8 / §3.10, gate G1).
///
/// Tolerance must not become a pass: a page that threw simply produces no row,
/// so `mismatches` alone would read "perfect" for a run where every model
/// crashed. Hence the three additional conditions — recorded errors, zero
/// samples, and a sample count below what the sweep should have produced.
@visibleForTesting
bool goldenIsConsistent({
  required List<Map<String, dynamic>> mismatches,
  required List<Map<String, dynamic>> errors,
  required int samples,
  required int expectedSamples,
}) {
  if (mismatches.isNotEmpty) return false;
  if (errors.isNotEmpty) return false;
  if (samples <= 0) return false;
  if (samples != expectedSamples) return false;
  return true;
}

/// Assemble the `ocr-golden` JSON payload. Field names are the frozen contract
/// of plan §3.8; `errors` is additive (a run with no errors emits `[]`).
@visibleForTesting
Map<String, dynamic> buildGoldenReport({
  required List<Map<String, dynamic>> rows,
  required List<Map<String, dynamic>> mismatches,
  required List<Map<String, dynamic>> errors,
  required int expectedSamples,
  required GitShaInfo gitSha,
  Map<String, dynamic>? machine,
  Map<String, dynamic>? ort,
  Map<String, dynamic>? resource,
}) {
  final consistent = goldenIsConsistent(
    mismatches: mismatches,
    errors: errors,
    samples: rows.length,
    expectedSamples: expectedSamples,
  );
  return {
    'status': consistent ? 'success' : 'error',
    'data': {
      'gitsha': gitSha.sha,
      'gitshasource': gitSha.source,
      'machine': machine ?? const <String, dynamic>{},
      'ort': ort,
      'pages': rows,
      'errors': errors,
      'consistency': {
        'baseline': 'first-variant',
        'mismatches': mismatches,
      },
      'resource': resource ??
          const <String, dynamic>{
            'before': null,
            'during': [],
            'after': null,
          },
      'verdict': {
        'consistent': consistent,
        'samples': rows.length,
        'errors': errors.length,
        'expectedSamples': expectedSamples,
      },
    },
  };
}

/// Exit code for a finished golden run: 1 unless *both* the status field and
/// `verdict.consistent` say clean. Requiring agreement is deliberate — if one
/// of the two is ever edited the run fails, it never "looks like a pass".
@visibleForTesting
int goldenExitCode(Map<String, dynamic> report) {
  final data = report['data'];
  final verdict = data is Map ? data['verdict'] : null;
  final consistent = verdict is Map && verdict['consistent'] == true;
  return (report['status'] == 'success' && consistent) ? 0 : 1;
}

/// One-line "was it slow or was it dead" summary, written to stderr: the D-14 /
/// D-15 runs could not tell a stalled harness from a merely slow one.
@visibleForTesting
String goldenSummaryLine({
  required Duration elapsed,
  required int pages,
  required int variants,
  required int samples,
  required int expectedSamples,
  required int mismatches,
  required int errors,
}) {
  final ms = elapsed.inMilliseconds;
  final perRow = samples == 0 ? 0 : (ms / samples).round();
  return 'ocr-golden: $ms ms wall | $pages page(s) x $variants variant(s) '
      '-> $samples/$expectedSamples row(s) | ~$perRow ms/row '
      '(repeat included) | $mismatches mismatch(es) | $errors error(s)';
}

/// Evidence that identifies **which model and which EP** a failure happened
/// under, read from the live [EpReport] — no new dependency, no worker change.
///
/// Two path sets are reported, and the difference is the whole point:
///  * `models`     (see [describeModelPaths]) — what the variant was *configured*
///    to load, derived from settings and installed files;
///  * `modelPaths` — the keys of `EpReport.modelInputShapes`, i.e. the models a
///    session was **actually opened for** in this process, each with its input
///    shape.
///
/// Only the second can separate "the rec session died" from "the detector died",
/// which is precisely what D-15 could not resolve after a full sweep
/// (doc/ocr-baseline.md, step 0). `sessions` / `degradedTrail` show whether an
/// EP fallback or a batch back-off had already happened at that moment.
@visibleForTesting
Map<String, dynamic> ocrSessionEvidence({
  EpReport? report,
  Map<String, dynamic> perf = const {},
}) {
  if (report == null) return const {'ep': null, 'sessions': null};
  final shapes = report.modelInputShapes;
  return {
    'ep': report.active.name,
    'sessions': report.sessionCount,
    'modelPaths': shapes.keys.toList(),
    'modelInputShapes': shapes,
    if (report.attempts.isNotEmpty) 'epAttempts': report.attempts,
    if (report.degradedTrail.isNotEmpty) 'degradedTrail': report.degradedTrail,
    // The worker's own last perf line: `degraded` / `sessions` as the isolate
    // reported them, alongside the structured report above.
    if (perf['degraded'] != null) 'degraded': perf['degraded'],
    if (perf['sessions'] != null) 'perfSessions': perf['sessions'],
    if (perf['ep'] != null) 'perfEp': perf['ep'],
  };
}

/// [ocrSessionEvidence] must never be the reason a failure goes unreported, so
/// every read is guarded: this runs inside a `catch`, where a second throw
/// would reproduce the exact defect it is meant to document.
Map<String, dynamic> _sessionEvidence() {
  try {
    return ocrSessionEvidence(
      report: TranslationWorker.instance.lastReport,
      perf: _lastPerf(),
    );
  } catch (e) {
    return {'evidenceUnavailable': '$e'};
  }
}

Future<void> _ocrSelfcheck(List<String> rest, String? positional) async {
  final sha = resolveGitSha();
  final out = <String, dynamic>{
    'gitsha': sha.sha,
    'gitshasource': sha.source,
  };
  try {
    final probe = probeOrtRuntime();
    // The old parser took the token right after the command as the EP
    // preference, so `--page x.png` silently degraded to "auto". Flags are now
    // read by name; a bare positional still works.
    final prefStr = (positional != null && !positional.startsWith('--'))
        ? positional
        : (_flag(rest, '--ep') ?? 'auto');
    final pref = EpPreference.values.firstWhere(
      (p) => p.name == prefStr.toLowerCase(),
      orElse: () => EpPreference.auto,
    );
    out['probe'] = {
      'runtimeVersion': probe.runtimeVersion,
      'hasCudaSymbol': probe.hasCudaSymbol,
      'hasDmlSymbol': probe.hasDmlSymbol,
      'isWindows': probe.isWindows,
      'isDesktop': probe.isDesktop,
      'plannedOrder': planEpOrder(pref, probe).map((e) => e.name).toList(),
    };

    final paths = TranslationModels.workerPaths();
    if (!TranslationModels.detector.isInstalled) {
      out['session'] = const {'skipped': 'text detector model not installed'};
      cliPrint({'status': 'success', 'data': out});
      return;
    }
    // Actually open a session: a symbol check alone never proves the EP works.
    out['session'] = (await TranslationWorker.instance.capabilities(
      pref: pref,
      paths: paths,
    )).toJson();

    final page = _flag(rest, '--page');
    if (page != null) {
      final bytes = await File(page).readAsBytes();
      final repeat = int.tryParse(_flag(rest, '--repeat') ?? '3') ?? 3;
      final runs = <int>[];
      for (var i = 0; i < repeat; i++) {
        final sw = Stopwatch()..start();
        await ImageTranslationService.instance.pipeline.ocrPages(
          [bytes],
          sourceLang: _flag(rest, '--lang') ?? 'auto',
          targetLang: 'zh',
        );
        sw.stop();
        runs.add(sw.elapsedMilliseconds);
      }
      runs.sort();
      out['bench'] = {
        'repeat': repeat,
        'msPerRun': runs[runs.length ~/ 2],
        'all': runs,
      };
    }
    out['resource'] = (await takeProcessSnapshot(vendorProbe: true)).toJson();
    cliPrint({'status': 'success', 'data': out});
  } catch (e, s) {
    cliPrint({
      'status': 'error',
      'message': 'Self-check failed: $e',
      'stack': '$s',
    });
    exit(1);
  }
}

Future<void> _ocrGolden(List<String> rest) async {
  final clock = Stopwatch()..start();
  final dir = _flag(rest, '--dir') ?? 'test/fixtures/golden_ocr';
  final root = Directory(dir);
  if (!root.existsSync()) {
    cliPrint({'status': 'error', 'message': 'fixture dir not found: $dir'});
    exit(1);
  }
  final List<Map<String, dynamic>> pages;
  try {
    final manifest =
        jsonDecode(File('$dir/manifest.json').readAsStringSync())
            as Map<String, dynamic>;
    pages = (manifest['pages'] as List).cast<Map<String, dynamic>>();
  } catch (e) {
    cliPrint({
      'status': 'error',
      'message': 'unreadable manifest.json in $dir: $e',
    });
    exit(1);
  }
  final batchSpec = _flagList(rest, '--batches', '1');
  final tiers = _flagList(rest, '--tier', 'fast');
  final batches = batchSpec.map(int.tryParse).toList();
  final group = int.tryParse(_flag(rest, '--group') ?? '1') ?? 1;
  final repeat = int.tryParse(_flag(rest, '--repeat') ?? '1') ?? 1;
  // An unparsable sweep spec used to escape as a bare `FormatException`, which
  // is the same failure mode as defect 1: process gone, no explanation, no
  // output. Say what is wrong and leave.
  if (pages.isEmpty ||
      tiers.isEmpty ||
      batches.isEmpty ||
      batches.any((b) => b == null || b < 1) ||
      group < 1 ||
      repeat < 1) {
    cliPrint({
      'status': 'error',
      'message': 'invalid sweep spec: pages=${pages.length} '
          'tier=${tiers.join(",")} batches=${batchSpec.join(",")} '
          'group=$group repeat=$repeat (need >=1 page, >=1 tier, integer '
          'batches >=1, group >=1, repeat >=1)',
    });
    exit(1);
  }
  final batchSizes = batches.cast<int>();
  final wantResource = rest.contains('--resource-probe');
  final variants = tiers.length * batchSizes.length;
  final expectedSamples = pages.length * variants;
  _trace('ocr-golden start: ${pages.length} page(s) x $variants variant(s) '
      '(tiers=${tiers.join(",")} batches=${batchSizes.join(",")} group=$group '
      'repeat=$repeat) offline=$headlessOffline');

  final rows = <Map<String, dynamic>>[];
  final baselineTexts = <String, String>{};
  final mismatches = <Map<String, dynamic>>[];
  final errors = <Map<String, dynamic>>[];
  ProcessSnapshot? before, after;
  final during = <Map<String, dynamic>>[];

  if (wantResource) {
    try {
      before = await takeProcessSnapshot(vendorProbe: true);
    } catch (e) {
      errors.add(ocrErrorRecord(
        file: '-',
        tier: '-',
        batch: 0,
        group: 0,
        variant: 0,
        error: 'resource probe (before) failed: $e',
        context: const {'stage': 'resource-probe'},
      ));
    }
  }

  for (final tier in tiers) {
    appdata.settings['imageTranslationModelQuality'] = tier;
    TranslationModels.invalidateReadyCache();
    for (final batch in batchSizes) {
      // detBatch / recBatch / pagesPerOcrCall are only read back from settings
      // under the `custom` preset (translation_performance_config.dart:107-109).
      // Without switching, a "batch sweep" would measure the same configuration
      // four times and report a trivially-passing consistency verdict — the
      // fake-measurement case plan §3.10 forbids.
      appdata.settings['imageTranslationPerformancePreset'] = 'custom';
      appdata.settings['imageTranslationOcrRecBatch'] = batch;
      appdata.settings['imageTranslationOcrDetBatch'] = (batch ~/ 8).clamp(1, 4);
      appdata.settings['imageTranslationPagesPerOcrCall'] = group;
      // What this variant actually runs: the model files (plus the directory
      // names the CPU pin list is written in) and the *whole* EP report, not
      // just the active EP. D-15 could not be attributed for a whole sweep
      // because the exception carried neither (doc/ocr-baseline.md, step 0).
      var context = <String, dynamic>{};
      try {
        final report = TranslationWorker.instance.lastReport;
        context = <String, dynamic>{
          // configured: what this variant is set up to load
          'models': describeModelPaths(TranslationModels.workerPaths()),
          // actual: which sessions the isolate really opened, and on what EP
          ...ocrSessionEvidence(report: report, perf: const {}),
          'ep': report?.active.name,
          if (report != null) 'ortReport': report.toJson(),
        };
      } catch (e) {
        context = <String, dynamic>{'modelResolutionFailed': '$e'};
      }
      // Announce the variant *before* issuing the first call. A DirectML
      // failure inside onnxruntime can abort the process natively, where no
      // Dart catch runs; then the run log is the only witness left, and it has
      // to say which models and which EP were in play.
      stderr.writeln('ocr-golden variant $tier/$batch context '
          '${jsonEncode(context)}');
      _trace('ocr-golden variant $tier/$batch context ${jsonEncode(context)}');
      for (final page in pages) {
        final file = page['file'] as String;
        final lang = page['lang'] as String? ?? 'auto';
        _trace('ocr-golden $tier/$batch/$file ->');
        Uint8List bytes;
        try {
          bytes = await File('$dir/$file').readAsBytes();
        } catch (e) {
          errors.add(ocrErrorRecord(
            file: file,
            tier: tier,
            batch: batch,
            group: group,
            variant: 0,
            error: 'reading fixture failed: $e',
            context: {...context, 'pageLang': lang},
          ));
          _trace('ocr-golden $tier/$batch/$file unreadable, continuing');
          continue;
        }
        String? text;
        final timings = <int>[];
        Map<String, dynamic> perf = const {};
        var failed = false;
        for (var r = 0; r < repeat; r++) {
          final sw = Stopwatch()..start();
          try {
            // `--group N` feeds N pages in ONE call — that is what exercises the
            // cross-page batching path. Repeating the same page keeps the text
            // comparison meaningful while still producing N padded rows.
            final results =
                await ImageTranslationService.instance.pipeline.ocrPages(
                  [for (var i = 0; i < group; i++) bytes],
                  sourceLang: lang,
                  targetLang: 'zh',
                );
            sw.stop();
            // A per-page worker failure does not throw: the pipeline carries it
            // in PageOcr.error and hands back empty ready/pending lists. Left
            // alone, every variant would then compare "" with "" and "pass" —
            // the silent-pass case §3.10 explicitly bans, so it is recorded.
            final erred = results.where((p) => p.hasError).toList();
            if (results.length != group || erred.isNotEmpty) {
              failed = true;
              errors.add(ocrErrorRecord(
                file: file,
                tier: tier,
                batch: batch,
                group: group,
                variant: r,
                error: results.isEmpty
                    ? 'ocrPages returned no result at all'
                    : erred.isNotEmpty
                        ? 'ocrPages page error (${erred.length}/$group): ${erred.first.error}'
                        : 'ocrPages returned ${results.length} page(s) for a group of $group',
                context: {
                  ...context,
                  'pageLang': lang,
                  'targetLang': 'zh',
                  'afterMs': sw.elapsedMilliseconds,
                  // Re-read at the moment of failure: which sessions exist *now*
                  // is what separates "the rec session died" from "the detector
                  // died" when the exception itself names neither.
                  ..._sessionEvidence(),
                  if (TranslationWorker.instance.lastReport != null)
                    'ortReport': TranslationWorker.instance.lastReport!.toJson(),
                },
              ));
              _trace('ocr-golden $tier/$batch/$file variant $r page-error, continuing');
              break;
            }
            if (r == 0) {
              text = results.map(_pageText).join('\n---\n');
              perf = _lastPerf();
            }
            timings.add(sw.elapsedMilliseconds);
          } catch (e, s) {
            // THE fix for "one dead model costs the whole sweep": record and
            // carry on with the next page. Before this, the throw escaped
            // runHeadlessMode, the process died, and not one already-measured
            // page survived on disk (D-15 lost a full run this way).
            sw.stop();
            failed = true;
            errors.add(ocrErrorRecord(
              file: file,
              tier: tier,
              batch: batch,
              group: group,
              variant: r,
              error: '$e',
              context: {
                ...context,
                'pageLang': lang,
                'targetLang': 'zh',
                'afterMs': sw.elapsedMilliseconds,
                // Re-read *inside* the handler: the report at failure time is
                // the evidence, not the one from the start of the variant.
                ..._sessionEvidence(),
                if (TranslationWorker.instance.lastReport != null)
                  'ortReport': TranslationWorker.instance.lastReport!.toJson(),
              },
              stack: '$s',
            ));
            _trace('ocr-golden $tier/$batch/$file variant $r threw: $e');
            break;
          }
        }
        if (failed || text == null) {
          // No row, and no baseline entry either: a crashed page must never
          // become the reference text that later variants are compared to.
          continue;
        }
        timings.sort();
        final got = text;
        final want = baselineTexts[file];
        if (want == null) {
          baselineTexts[file] = got;
        } else if (want != got) {
          mismatches.add({
            'file': file,
            'tier': tier,
            'batch': batch,
            'group': group,
            'diff': _firstDiff(want, got),
          });
        }
        final row = <String, dynamic>{
          'file': file,
          'lang': lang,
          'tier': tier,
          'batch': batch,
          'group': group,
          'totalMsMedian': timings[timings.length ~/ 2],
          'expectedBlocks': page['blocks'],
          ...perf,
          'textHash': _hash(got),
        };
        rows.add(row);
        // Echo each finished row to stderr — never as a `[CLI PRINT]` line, so
        // ocr_run_stats still reads exactly one report. If ORT kills the
        // process natively (no Dart exception to catch), the rows produced so
        // far are still recoverable from the run log.
        stderr.writeln(
          'ocr-golden row ${rows.length}/$expectedSamples ${jsonEncode(row)}',
        );
        _trace('ocr-golden $tier/$batch/$file done '
            '${timings[timings.length ~/ 2]}ms');
        if (wantResource) {
          try {
            during.add({
              'at': '$tier/$batch/$file',
              ...(await takeProcessSnapshot(vendorProbe: true)).toJson(),
            });
          } catch (e) {
            errors.add(ocrErrorRecord(
              file: file,
              tier: tier,
              batch: batch,
              group: group,
              variant: 0,
              error: 'resource probe failed: $e',
              context: const {'stage': 'resource-probe'},
            ));
          }
        }
      }
    }
  }
  if (wantResource) {
    try {
      after = await takeProcessSnapshot(vendorProbe: true);
    } catch (e) {
      errors.add(ocrErrorRecord(
        file: '-',
        tier: '-',
        batch: 0,
        group: 0,
        variant: 0,
        error: 'resource probe (after) failed: $e',
        context: const {'stage': 'resource-probe'},
      ));
    }
  }

  // Compare against recorded expectations once they exist.
  for (final page in pages) {
    final file = page['file'] as String;
    final exp = File('$dir/$file.expected.txt');
    if (!exp.existsSync()) continue;
    String want;
    try {
      want = exp.readAsStringSync().replaceAll('\r', '').trim();
    } catch (e) {
      errors.add(ocrErrorRecord(
        file: file,
        tier: '-',
        batch: 0,
        group: 0,
        variant: -1,
        error: 'unreadable $file.expected.txt: $e',
        context: const {'stage': 'expected'},
      ));
      continue;
    }
    final measured = baselineTexts[file];
    if (measured == null) {
      // Nothing survived for this page. Absent evidence is not agreement: an
      // empty-vs-empty comparison would have "passed" the expectation check.
      errors.add(ocrErrorRecord(
        file: file,
        tier: '-',
        batch: 0,
        group: 0,
        variant: -1,
        error: 'no measurement survived for $file, '
            'cannot compare against $file.expected.txt',
        context: const {'stage': 'expected'},
      ));
      continue;
    }
    if (want != measured.trim()) {
      mismatches.add({
        'file': file,
        'against': '$file.expected.txt',
        'diff': _firstDiff(want, measured.trim()),
      });
    }
  }

  clock.stop();
  final report = buildGoldenReport(
    rows: rows,
    mismatches: mismatches,
    errors: errors,
    expectedSamples: expectedSamples,
    gitSha: resolveGitSha(),
    machine: {
      'os': Platform.operatingSystem,
      'osVersion': Platform.operatingSystemVersion,
      'cpu': Platform.numberOfProcessors,
      'offline': headlessOffline,
    },
    ort: TranslationWorker.instance.lastReport?.toJson(),
    resource: {
      'before': before?.toJson(),
      'during': during,
      'after': after?.toJson(),
    },
  );
  cliPrint(report);
  stderr.writeln(goldenSummaryLine(
    elapsed: clock.elapsed,
    pages: pages.length,
    variants: variants,
    samples: rows.length,
    expectedSamples: expectedSamples,
    mismatches: mismatches.length,
    errors: errors.length,
  ));
  for (final e in errors) {
    // Every lost page is named on stderr too, so a run that "only" lost data
    // cannot be mistaken for a clean one by whoever is watching the console.
    stderr.writeln('ocr-golden ERROR ${jsonEncode(e)}');
  }
  _trace('ocr-golden end: ${clock.elapsedMilliseconds} ms, '
      '${rows.length}/$expectedSamples row(s), ${mismatches.length} mismatch(es), '
      '${errors.length} error(s), exit=${goldenExitCode(report)}');
  exit(goldenExitCode(report));
}

String _pageText(dynamic pageOcr) {
  final ready = (pageOcr.ready as List).map((e) => e.text as String);
  final pending = (pageOcr.pending as List).map((e) => e.text as String);
  return [...ready, ...pending].join('\n').trim();
}

String _firstDiff(String a, String b) {
  final la = a.split('\n'), lb = b.split('\n');
  final n = la.length < lb.length ? la.length : lb.length;
  for (var i = 0; i < n; i++) {
    if (la[i] != lb[i]) {
      return 'line ${i + 1}: ${jsonEncode(la[i])} != ${jsonEncode(lb[i])}';
    }
  }
  return 'line count ${la.length} vs ${lb.length}';
}

String _hash(String s) {
  var h = 0x811c9dc5;
  for (final c in s.codeUnits) {
    h = ((h ^ c) * 0x01000193) & 0xFFFFFFFF;
  }
  return h.toRadixString(16).padLeft(8, '0');
}
