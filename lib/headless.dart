import 'dart:convert';
import 'dart:io';
import 'package:flutter/widgets.dart';
import 'package:venera/utils/data_sync.dart';
import 'package:venera/foundation/comic_source/comic_source.dart';
import 'package:venera/foundation/log.dart';
import 'package:venera/pages/comic_source_page.dart';
import 'package:venera/init.dart';
import 'package:venera/foundation/follow_updates.dart';
import 'package:venera/foundation/follow_update_scope.dart';
import 'package:venera/foundation/app.dart';
import 'package:venera/foundation/favorites.dart';
import 'package:venera/network/cookie_jar.dart';
import 'package:venera/foundation/image_translation/ort_capabilities.dart';
import 'package:venera/foundation/image_translation/process_diagnostics.dart';
import 'package:venera/foundation/image_translation/translation_models.dart';
import 'package:venera/foundation/image_translation/translation_service.dart';
import 'package:venera/foundation/image_translation/translation_worker.dart';
import 'package:venera/foundation/appdata.dart';

void cliPrint(Map<String, dynamic> data) {
  print('[CLI PRINT] ${jsonEncode(data)}');
}

Future<void> runHeadlessMode(List<String> args) async {
  WidgetsFlutterBinding.ensureInitialized();
  if (args.contains('--ignore-disheadless-log')) {
    Log.isMuted = true;
  }
  if(Platform.isLinux || Platform.isMacOS){
    Directory.current = Platform.environment['HOME']!;
  }
  // The first arg is '--headless', so we look at the next ones.
  var commandIndex = args.indexOf('--headless') + 1;
  if (commandIndex >= args.length) {
    cliPrint({'status': 'error', 'message': 'No command provided for headless mode.'});
    exit(1);
  }

  // Need to initialize the app for some features to work
  await init();
  // The import path restores backups into LIVE stores (in-place, via the
  // SQLite backup API) instead of swapping files, so every store must be open
  // before a `webdav down` applies data — this also satisfies
  // coreDataStoresReady, which gates applying backups.
  await SingleInstanceCookieJar.createInstance();
  await App.initComponents();
  // Headless never runs initDeferred(); complete the gate so DataSync's
  // download entry (which waits for deferred init before applying backups)
  // proceeds immediately instead of stalling on its 60s safety timeout.
  if (!deferredInitCompleter.isCompleted) {
    deferredInitCompleter.complete();
  }

  var command = args[commandIndex];
  var subCommand = (commandIndex + 1 < args.length) ? args[commandIndex + 1] : null;

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

Future<void> _ocrSelfcheck(List<String> rest, String? positional) async {
  final out = <String, dynamic>{
    'gitsha': const String.fromEnvironment('GIT_SHA'),
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
  final dir = _flag(rest, '--dir') ?? 'test/fixtures/golden_ocr';
  final root = Directory(dir);
  if (!root.existsSync()) {
    cliPrint({'status': 'error', 'message': 'fixture dir not found: $dir'});
    exit(1);
  }
  final manifest =
      jsonDecode(File('$dir/manifest.json').readAsStringSync())
          as Map<String, dynamic>;
  final pages = (manifest['pages'] as List).cast<Map<String, dynamic>>();
  final batches = _flagList(rest, '--batches', '1').map(int.parse).toList();
  final tiers = _flagList(rest, '--tier', 'fast');
  final group = int.tryParse(_flag(rest, '--group') ?? '1') ?? 1;
  final repeat = int.tryParse(_flag(rest, '--repeat') ?? '1') ?? 1;
  final wantResource = rest.contains('--resource-probe');

  final rows = <Map<String, dynamic>>[];
  final baselineTexts = <String, String>{};
  final mismatches = <Map<String, dynamic>>[];
  ProcessSnapshot? before, after;
  final during = <Map<String, dynamic>>[];

  if (wantResource) before = await takeProcessSnapshot(vendorProbe: true);

  for (final tier in tiers) {
    appdata.settings['imageTranslationModelQuality'] = tier;
    TranslationModels.invalidateReadyCache();
    for (final batch in batches) {
      // detBatch / recBatch / pagesPerOcrCall are only read back from settings
      // under the `custom` preset (translation_performance_config.dart:107-109).
      // Without switching, a "batch sweep" would measure the same configuration
      // four times and report a trivially-passing consistency verdict — the
      // fake-measurement case plan §3.10 forbids.
      appdata.settings['imageTranslationPerformancePreset'] = 'custom';
      appdata.settings['imageTranslationOcrRecBatch'] = batch;
      appdata.settings['imageTranslationOcrDetBatch'] = (batch ~/ 8).clamp(1, 4);
      appdata.settings['imageTranslationPagesPerOcrCall'] = group;
      for (final page in pages) {
        final file = page['file'] as String;
        final lang = page['lang'] as String? ?? 'auto';
        final bytes = await File('$dir/$file').readAsBytes();
        String? text;
        final timings = <int>[];
        Map<String, dynamic> perf = const {};
        for (var r = 0; r < repeat; r++) {
          final sw = Stopwatch()..start();
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
          if (r == 0) {
            text = results.map(_pageText).join('\n---\n');
            perf = _lastPerf();
          }
          timings.add(sw.elapsedMilliseconds);
        }
        timings.sort();
        final got = text!;
        final want = baselineTexts[file];
        if (want == null) {
          baselineTexts[file] = got;
        } else if (want != got) {
          mismatches.add({
            'file': file,
            'tier': tier,
            'batch': batch,
            'diff': _firstDiff(want, got),
          });
        }
        rows.add({
          'file': file,
          'lang': lang,
          'tier': tier,
          'batch': batch,
          'group': group,
          'totalMsMedian': timings[timings.length ~/ 2],
          'expectedBlocks': page['blocks'],
          ...perf,
          'textHash': _hash(got),
        });
        if (wantResource) {
          during.add({
            'at': '$tier/$batch/$file',
            ...(await takeProcessSnapshot(vendorProbe: true)).toJson(),
          });
        }
      }
    }
  }
  if (wantResource) after = await takeProcessSnapshot(vendorProbe: true);

  // Compare against recorded expectations once they exist.
  for (final page in pages) {
    final file = page['file'] as String;
    final exp = File('$dir/$file.expected.txt');
    if (!exp.existsSync()) continue;
    final want = exp.readAsStringSync().replaceAll('\r', '').trim();
    final got = (baselineTexts[file] ?? '').trim();
    if (want != got) {
      mismatches.add({
        'file': file,
        'against': '$file.expected.txt',
        'diff': _firstDiff(want, got),
      });
    }
  }

  final ok = mismatches.isEmpty;
  cliPrint({
    'status': ok ? 'success' : 'error',
    'data': {
      'gitsha': const String.fromEnvironment('GIT_SHA'),
      'machine': {
        'os': Platform.operatingSystem,
        'osVersion': Platform.operatingSystemVersion,
        'cpu': Platform.numberOfProcessors,
      },
      'ort': TranslationWorker.instance.lastReport?.toJson(),
      'pages': rows,
      'consistency': {'baseline': 'first-variant', 'mismatches': mismatches},
      'resource': {
        'before': before?.toJson(),
        'during': during,
        'after': after?.toJson(),
      },
      'verdict': {'consistent': ok, 'samples': rows.length},
    },
  });
  if (!ok) exit(1);
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
