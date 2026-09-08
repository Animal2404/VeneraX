import 'dart:convert';
import 'dart:ffi';
import 'dart:io';
import 'dart:typed_data';

import 'package:ffi/ffi.dart';

/// Process- and GPU-level resource readings — the "ruler" that
/// `VeneraX_AI_Translation_Phase2_Plan.md` §3.5 demands before any performance
/// claim can be made, and the only way to prove that D-1 (VRAM never returned)
/// is actually fixed.
///
/// The rule that matters most here: **a value that cannot be read is `null`,
/// never `0`.** Reporting 0 for "no GPU memory in use" when the probe merely
/// failed is how a leak gets mistaken for a clean release — the exact mistake
/// this module exists to prevent (plan §3.6, D-13).
class ProcessSnapshot {
  const ProcessSnapshot({
    required this.sources,
    this.workingSetBytes,
    this.peakWorkingSetBytes,
    this.pagefileBytes,
    this.gpuCurrentUsageBytes,
    this.gpuBudgetBytes,
    this.gpuProcessUsageBytes,
    this.gpuAdapter,
  });

  /// Which probe produced which field; failures are recorded with a reason so a
  /// reader can tell "0 MB" apart from "unmeasurable".
  final Map<String, String> sources;
  final int? workingSetBytes;
  final int? peakWorkingSetBytes;
  final int? pagefileBytes;

  /// Video memory currently in use on the adapter (whole-adapter, not per
  /// process — see the note on [gpuProcessUsageBytes]).
  final int? gpuCurrentUsageBytes;

  /// The adapter's total video memory, so "usage fell" can be distinguished
  /// from "the driver changed the budget under us".
  final int? gpuBudgetBytes;

  /// Per-process GPU usage, when the driver attributes it. A process that
  /// renders through the graphics engine rather than the compute engine is
  /// routinely absent from that list; that is recorded, not reported as zero.
  final int? gpuProcessUsageBytes;
  final String? gpuAdapter;

  static const ProcessSnapshot unavailable = ProcessSnapshot(
    sources: {'psapi': 'skipped', 'gpu': 'skipped'},
  );

  bool get hasGpuReading => gpuCurrentUsageBytes != null;

  static double? _mb(int? bytes) => bytes == null
      ? null
      : double.parse((bytes / (1024 * 1024)).toStringAsFixed(1));

  Map<String, dynamic> toJson() => {
    'workingSetMB': _mb(workingSetBytes),
    'peakWorkingSetMB': _mb(peakWorkingSetBytes),
    'pagefileMB': _mb(pagefileBytes),
    'gpuCurrentMB': _mb(gpuCurrentUsageBytes),
    'gpuBudgetMB': _mb(gpuBudgetBytes),
    'gpuProcessMB': _mb(gpuProcessUsageBytes),
    'gpuAdapter': gpuAdapter,
    'sources': sources,
  };

  @override
  String toString() {
    String f(String label, int? bytes) =>
        '$label=${bytes == null ? "N/A" : "${(bytes / (1024 * 1024)).toStringAsFixed(0)}MB"}';
    return '${f('rss', workingSetBytes)} ${f('gpu', gpuCurrentUsageBytes)} '
        '${f('gpuProc', gpuProcessUsageBytes)} ${f('gpuTotal', gpuBudgetBytes)}';
  }
}

/// Reads whatever this platform exposes. Never throws: a failed probe is
/// recorded in [ProcessSnapshot.sources] and leaves its field `null`.
///
/// [vendorProbe] additionally shells out to `nvidia-smi` (~30-100 ms); the
/// sampling tools enable it, the in-app diagnostics page does not.
Future<ProcessSnapshot> takeProcessSnapshot({bool vendorProbe = false}) async {
  final sources = <String, String>{};
  int? rss, peakRss, pagefile, gpuNow, gpuTotal, gpuProc;
  String? adapter;

  final proc = _readProcessMemory();
  if (proc != null) {
    rss = proc.workingSet;
    peakRss = proc.peakWorkingSet;
    pagefile = proc.pagefileUsage;
    sources['psapi'] = 'ok';
  } else {
    sources['psapi'] = Platform.isWindows
        ? 'failed (K32GetProcessMemoryInfo)'
        : 'skipped (non-Windows)';
  }

  if (vendorProbe) {
    final v = await _readNvidiaSmi();
    if (v.usedBytes != null) {
      gpuNow = v.usedBytes;
      gpuTotal = v.totalBytes;
      adapter = v.name;
      sources['nvidia-smi'] = 'ok';
    } else {
      sources['nvidia-smi'] = v.reason ?? 'unreadable';
    }
    final p = await _readNvidiaSmiProcess();
    if (p.processBytes != null) {
      gpuProc = p.processBytes;
      sources['nvidia-smi-pid'] = 'ok';
    } else {
      sources['nvidia-smi-pid'] = p.reason ?? 'no per-process value';
    }
  } else {
    sources['nvidia-smi'] = 'not requested';
  }

  return ProcessSnapshot(
    sources: sources,
    workingSetBytes: rss,
    peakWorkingSetBytes: peakRss,
    pagefileBytes: pagefile,
    gpuCurrentUsageBytes: gpuNow,
    gpuBudgetBytes: gpuTotal,
    gpuProcessUsageBytes: gpuProc,
    gpuAdapter: adapter,
  );
}

// ---------------------------------------------------------------------------
// P-1: psapi — process working set. Validated on-device: allocating a 64 MB
// ballast moved the reported working set by ~70 MB, so this path tracks
// reality and covers the Dart/isolate-heap half of the leak story even on
// machines where no GPU reading exists at all.
//
// PROCESS_MEMORY_COUNTERS (Psapi.h:466) on x64, 72 bytes:
//   cb@0(DWORD) PageFaultCount@4(DWORD) PeakWorkingSetSize@8 WorkingSetSize@16
//   QuotaPeakPagedPoolUsage@24 QuotaPagedPoolUsage@32
//   QuotaPeakNonPagedPoolUsage@40 QuotaNonPagedPoolUsage@48
//   PagefileUsage@56 PeakPagefileUsage@64
// HANDLE is pointer-sized and is passed as IntPtr.
// ---------------------------------------------------------------------------

typedef _GetProcMemNative =
    Int32 Function(IntPtr process, Pointer<Void> counters, Uint32 cb);
typedef _GetProcMemDart =
    int Function(int process, Pointer<Void> counters, int cb);

class _ProcMemory {
  const _ProcMemory(this.workingSet, this.peakWorkingSet, this.pagefileUsage);
  final int workingSet;
  final int peakWorkingSet;
  final int pagefileUsage;
}

_ProcMemory? _readProcessMemory() {
  if (!Platform.isWindows) return null;
  const structSize = 72;
  try {
    final kernel32 = DynamicLibrary.open('kernel32.dll');
    final getCurrentProcess = kernel32
        .lookupFunction<IntPtr Function(), int Function()>(
          'GetCurrentProcess',
        );
    final getMemoryInfo = kernel32
        .lookupFunction<_GetProcMemNative, _GetProcMemDart>(
          'K32GetProcessMemoryInfo',
        );
    final mem = calloc<Uint8>(structSize);
    try {
      mem.cast<Uint32>().value = structSize; // the API requires `cb` prefilled
      if (getMemoryInfo(getCurrentProcess(), mem.cast(), structSize) == 0) {
        return null;
      }
      final q = mem.cast<Uint64>();
      return _ProcMemory(q[2], q[1], q[7]); // WorkingSet, Peak, Pagefile
    } finally {
      calloc.free(mem);
    }
  } catch (_) {
    return null;
  }
}

// ---------------------------------------------------------------------------
// P-2: adapter video memory, via the vendor tool.
//
// A DXGI `IDXGIAdapter3::QueryVideoMemoryInfo` route was attempted first and
// deliberately dropped: the SDK headers in 10.0.26100.0 describe
// `IDXGIFactory1Vtbl` without `IDXGIFactory::GetSharedResourceAdapterLuid`
// (declared in a `dxgi1_1.h` that this SDK does not ship), so the header-derived
// slot numbers are off by one against the live vtable. Measured on this machine:
// slot 12 answered S_OK while writing nothing (it is the Luid call, which
// happily wrote into the buffer passed as its "riid" argument), and slot 13
// returned 1 — `IsCurrent()`. Calling an unverified vtable slot is not a
// graceful-degradation risk but a hard access violation (observed), and this
// code runs inside the reader, so an unverifiable index must not ship.
// Revisit only with a slot table confirmed against a real `dxgi1_1.h`, or by
// binding through `QueryInterface` on a device created with d3d11 instead of
// hand-counting slots.
// ---------------------------------------------------------------------------

class _AdapterMemory {
  const _AdapterMemory({this.usedBytes, this.totalBytes, this.name, this.reason});
  final int? usedBytes;
  final int? totalBytes;
  final String? name;
  final String? reason;
}

Future<_AdapterMemory> _readNvidiaSmi() async {
  try {
    final r = await Process.run('nvidia-smi', [
      '--query-gpu=memory.used,memory.total,name',
      '--format=csv,noheader,nounits',
    ]).timeout(const Duration(seconds: 5));
    if (r.exitCode != 0) {
      return const _AdapterMemory(reason: 'nvidia-smi exit != 0');
    }
    final line = const LineSplitter()
        .convert(r.stdout as String)
        .where((l) => l.trim().isNotEmpty)
        .firstOrNull;
    if (line == null) {
      return const _AdapterMemory(reason: 'nvidia-smi returned no row');
    }
    final parts = line.split(',');
    if (parts.length < 2) {
      return _AdapterMemory(reason: 'unexpected row: $line');
    }
    final used = int.tryParse(parts[0].trim());
    final total = int.tryParse(parts[1].trim());
    if (used == null || total == null) {
      return _AdapterMemory(reason: 'non-numeric memory row: $line');
    }
    return _AdapterMemory(
      usedBytes: used * 1024 * 1024,
      totalBytes: total * 1024 * 1024,
      name: parts.length > 2 ? parts[2].trim() : null,
    );
  } catch (e) {
    return _AdapterMemory(reason: 'nvidia-smi unavailable: $e');
  }
}

class _VendorProbe {
  const _VendorProbe({this.processBytes, this.reason});
  final int? processBytes;
  final String? reason;
}

Future<_VendorProbe> _readNvidiaSmiProcess() async {
  try {
    final r = await Process.run('nvidia-smi', [
      '--query-compute-apps=pid,used_memory',
      '--format=csv,noheader,nounits',
    ]).timeout(const Duration(seconds: 5));
    if (r.exitCode != 0) {
      return const _VendorProbe(reason: 'nvidia-smi exit != 0');
    }
    for (final line in const LineSplitter().convert(r.stdout as String)) {
      final parts = line.split(',');
      if (parts.length < 2) continue;
      if (int.tryParse(parts[0].trim()) != pid) continue;
      final mb = int.tryParse(parts[1].trim());
      if (mb == null) {
        return const _VendorProbe(reason: 'driver reports N/A for this pid');
      }
      return _VendorProbe(processBytes: mb * 1024 * 1024);
    }
    return const _VendorProbe(
      reason: 'pid absent (graphics engine, not compute) — use the adapter total',
    );
  } catch (e) {
    return _VendorProbe(reason: 'nvidia-smi unavailable: $e');
  }
}

/// Byte-order helper for building a COM `GUID` blob from its dashed form.
/// Kept here (unused by the probes above) so that any future DXGI re-attempt
/// starts from a tested layout instead of a hand-counted one; see the note on
/// P-2 about why slot numbers must be confirmed, not copied.
Uint8List leGuid(String dashed) {
  final hex = dashed.replaceAll('-', '');
  final out = Uint8List(16);
  final bd = ByteData.sublistView(out);
  bd.setUint32(0, int.parse(hex.substring(0, 8), radix: 16), Endian.little);
  bd.setUint16(4, int.parse(hex.substring(8, 12), radix: 16), Endian.little);
  bd.setUint16(6, int.parse(hex.substring(12, 16), radix: 16), Endian.little);
  for (var i = 0; i < 8; i++) {
    out[8 + i] = int.parse(hex.substring(16 + i * 2, 18 + i * 2), radix: 16);
  }
  return out;
}
