import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;

import 'package:venera/foundation/image_translation/ort_capabilities.dart';
import 'package:venera/foundation/image_translation/ort_ffi.dart';

void main(List<String> args) {
  var isJson = false;
  var epStr = 'auto';
  String? modelDetPath;
  String? modelRecPath;

  for (var i = 0; i < args.length; i++) {
    final arg = args[i];
    if (arg == '--json') {
      isJson = true;
    } else if (arg == '--ep' && i + 1 < args.length) {
      epStr = args[++i].toLowerCase();
    } else if (arg == '--model-det' && i + 1 < args.length) {
      modelDetPath = args[++i];
    } else if (arg == '--model-rec' && i + 1 < args.length) {
      modelRecPath = args[++i];
    }
  }

  final pref = EpPreference.values.firstWhere(
    (p) => p.name == epStr,
    orElse: () => EpPreference.auto,
  );

  final out = <String, dynamic>{};

  try {
    final probe = probeOrtRuntime();
    final planned = planEpOrder(pref, probe);

    out['runtimeVersion'] = probe.runtimeVersion;
    out['symbols'] = {
      'hasCuda': probe.hasCudaSymbol,
      'hasDml': probe.hasDmlSymbol,
    };
    out['platform'] = {
      'isWindows': probe.isWindows,
      'isDesktop': probe.isDesktop,
    };
    out['plannedEpOrder'] = planned.map((e) => e.name).toList();

    if (!isJson) {
      print('=== ONNX Runtime Probe ===');
      print('Runtime Version : ${probe.runtimeVersion}');
      print('CUDA Symbol     : ${probe.hasCudaSymbol}');
      print('DirectML Symbol : ${probe.hasDmlSymbol}');
      print('Planned EP Order: ${planned.map((e) => e.name).join(' -> ')}');
    }

    // Default paths if not specified
    if (modelDetPath == null) {
      final appData = Platform.environment['APPDATA'] ?? Platform.environment['LOCALAPPDATA'];
      if (appData != null) {
        final cand = '$appData${Platform.pathSeparator}com.kyosee.venera${Platform.pathSeparator}translation_models${Platform.pathSeparator}ch_PP-OCRv4_det_infer.onnx';
        if (File(cand).existsSync()) modelDetPath = cand;
      }
    }

    final sessionReports = <String, dynamic>{};
    for (final modelEntry in [
      ('det', modelDetPath),
      ('rec', modelRecPath),
    ]) {
      final tag = modelEntry.$1;
      final path = modelEntry.$2;
      if (path == null || !File(path).existsSync()) continue;

      final attempts = <String>[];
      OrtFfiSession? activeSession;
      OrtEpKind? activeEp;

      for (final ep in planned) {
        try {
          final s = OrtFfiSession.open(path, ep: ep, intraOpThreads: 2);
          activeSession = s;
          activeEp = ep;
          attempts.add('${ep.name}:ok');
          break;
        } catch (e) {
          attempts.add('${ep.name}:fail($e)');
        }
      }

      if (activeSession != null) {
        final shapes = activeSession.inputShapes();
        final runs = <double>[];

        // Benchmark 3 synthetic runs
        final inputName = activeSession.inputNames.first;
        final shape = shapes[inputName] ?? [1, 3, 48, 96];
        final effectiveShape = [
          for (var dim in shape) dim <= 0 ? 1 : dim,
        ];
        var totalElements = 1;
        for (var d in effectiveShape) {
          totalElements *= d;
        }

        final arena = OrtTensorArena();
        final offset = arena.ensure(0, totalElements);
        final rng = math.Random();
        for (var i = 0; i < totalElements; i++) {
          arena.view[offset + i] = rng.nextDouble();
        }

        for (var r = 0; r < 3; r++) {
          final sw = Stopwatch()..start();
          activeSession.run({
            inputName: OrtInput.nativeFloat32(
              arena.pointerAt(offset),
              totalElements,
              effectiveShape,
            ),
          });
          sw.stop();
          runs.add(sw.elapsedMicroseconds / 1000.0);
        }

        arena.free();
        activeSession.close();

        sessionReports[tag] = {
          'path': path,
          'activeEp': activeEp?.name,
          'attempts': attempts,
          'inputShapes': shapes,
          'benchMs': runs,
        };
      } else {
        sessionReports[tag] = {
          'path': path,
          'activeEp': null,
          'attempts': attempts,
        };
      }
    }

    out['models'] = sessionReports;

    if (isJson) {
      print(jsonEncode(out));
    } else {
      if (sessionReports.isNotEmpty) {
        print('\n=== Model Probes ===');
        for (final entry in sessionReports.entries) {
          print('Model [${entry.key}]: ${entry.value['activeEp'] ?? 'failed'}');
          print('  Attempts: ${entry.value['attempts']}');
          print('  Shapes  : ${entry.value['inputShapes']}');
          if (entry.value['benchMs'] != null) {
            print('  Runs (ms): ${entry.value['benchMs']}');
          }
        }
      }
      print('\nSelf-check completed successfully.');
    }
  } catch (e, stack) {
    if (isJson) {
      print(jsonEncode({'error': e.toString(), 'stack': stack.toString()}));
    } else {
      stderr.writeln('Self-check error: $e\n$stack');
    }
    exit(1);
  }
}
