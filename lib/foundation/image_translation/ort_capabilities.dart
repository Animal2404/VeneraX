/// Runtime execution provider capabilities, probing, and fallback state machine.
/// Specification: §1.2.6 in VeneraX AI Translation Implementation Plan.
library;

import 'dart:io';

import 'ort_ffi.dart';

enum OrtEpKind {
  cuda,
  directml,
  cpu,
}

/// Settings choice for execution provider preference.
enum EpPreference {
  auto,
  cuda,
  directml,
  cpu,
}

class OrtProbe {
  const OrtProbe({
    required this.runtimeVersion,
    required this.hasCudaSymbol,
    required this.hasDmlSymbol,
    required this.isWindows,
    required this.isDesktop,
  });

  final String runtimeVersion;
  final bool hasCudaSymbol;
  final bool hasDmlSymbol;
  final bool isWindows;
  final bool isDesktop;
}

/// Probes the active ONNX Runtime DLL for available execution provider symbols.
OrtProbe probeOrtRuntime() {
  var rt = OrtRuntime.open();
  return OrtProbe(
    runtimeVersion: OrtRuntime.runtimeVersion(),
    hasCudaSymbol: rt.hasExport('OrtSessionOptionsAppendExecutionProvider_CUDA'),
    hasDmlSymbol: rt.hasExport('OrtSessionOptionsAppendExecutionProvider_DML'),
    isWindows: Platform.isWindows,
    isDesktop: Platform.isWindows || Platform.isLinux || Platform.isMacOS,
  );
}

enum EpDecision {
  tryNextEp,
  shrinkAndRetry,
  goCpuPermanently,
}

/// Pure function: produces candidate execution provider order based on preference and probe.
List<OrtEpKind> planEpOrder(EpPreference pref, OrtProbe probe) {
  if (!probe.isDesktop) {
    return const [OrtEpKind.cpu];
  }

  switch (pref) {
    case EpPreference.cpu:
      return const [OrtEpKind.cpu];

    case EpPreference.cuda:
      final order = <OrtEpKind>[OrtEpKind.cuda];
      if (probe.hasDmlSymbol && probe.isWindows) {
        order.add(OrtEpKind.directml);
      }
      order.add(OrtEpKind.cpu);
      return order;

    case EpPreference.directml:
      if (probe.isWindows) {
        return const [OrtEpKind.directml, OrtEpKind.cpu];
      }
      return const [OrtEpKind.cpu];

    case EpPreference.auto:
      if (!probe.isWindows) {
        return const [OrtEpKind.cpu];
      }
      final order = <OrtEpKind>[];
      if (probe.hasCudaSymbol) {
        order.add(OrtEpKind.cuda);
      }
      if (probe.hasDmlSymbol) {
        order.add(OrtEpKind.directml);
      }
      order.add(OrtEpKind.cpu);
      return order;
  }
}

/// Pure function: determines recovery action upon an execution provider error.
EpDecision decideAfterFailure(
  OrtFfiException e, {
  required int alreadyTried,
  required int consecutiveFailures,
}) {
  switch (e.kind) {
    case OrtFfiErrorKind.epUnavailable:
    case OrtFfiErrorKind.invalidGraph:
      return EpDecision.tryNextEp;

    case OrtFfiErrorKind.outOfMemory:
      return EpDecision.shrinkAndRetry;

    case OrtFfiErrorKind.deviceRemoved:
      return EpDecision.goCpuPermanently;

    case OrtFfiErrorKind.shapeMismatch:
    case OrtFfiErrorKind.other:
      if (consecutiveFailures >= 2) {
        return EpDecision.goCpuPermanently;
      }
      return EpDecision.tryNextEp;
  }
}

/// Report transmitted from worker isolate back to main isolate.
class EpReport {
  const EpReport({
    required this.active,
    required this.runtimeVersion,
    required this.attempts,
    required this.modelInputShapes,
    required this.batchCapable,
    this.sessionCount = 0,
    this.arenaCapacityBytes = 0,
    this.hiddenArenaCapacityBytes = 0,
    this.degradedTrail = const [],
  });

  final OrtEpKind active;
  final String runtimeVersion;
  final List<String> attempts;
  final Map<String, List<int>> modelInputShapes;
  final bool batchCapable;

  /// Live `OrtFfiSession` count in the reporting worker. This is what makes
  /// "did the VRAM actually come back?" observable (plan D-1 / V7-1): a
  /// shutdown that leaves sessions > 0 released nothing.
  final int sessionCount;

  /// Capacity of the two native staging arenas, in bytes. These are **host**
  /// allocations, not VRAM — they cover the isolate-heap half of the story and
  /// must never be presented as a GPU number (plan §3.6).
  final int arenaCapacityBytes;
  final int hiddenArenaCapacityBytes;

  /// Shrink/fallback events for this worker, e.g. `rec16<-32`, `det1<-4`,
  /// `cpu`. The perf log used to hard-code `degraded=none` and so could never
  /// show a real fallback (plan D-5).
  final List<String> degradedTrail;

  Map<String, dynamic> toJson() => {
        'active': active.name,
        'runtimeVersion': runtimeVersion,
        'attempts': attempts,
        'modelInputShapes': modelInputShapes,
        'batchCapable': batchCapable,
        'sessionCount': sessionCount,
        'arenaCapacityBytes': arenaCapacityBytes,
        'hiddenArenaCapacityBytes': hiddenArenaCapacityBytes,
        'degradedTrail': degradedTrail,
      };
}
