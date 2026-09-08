part of 'settings_page.dart';

class TranslationDiagnosticsPage extends StatefulWidget {
  const TranslationDiagnosticsPage({super.key});

  @override
  State<TranslationDiagnosticsPage> createState() =>
      _TranslationDiagnosticsPageState();
}

class _TranslationDiagnosticsPageState
    extends State<TranslationDiagnosticsPage> {
  /// Cached so the resource card does not re-run the native probes on every
  /// rebuild. `unavailable` renders as N/A, never as 0.
  ProcessSnapshot _snapshot = ProcessSnapshot.unavailable;
  bool _releasing = false;

  @override
  void initState() {
    super.initState();
    _refreshSnapshot();
  }

  Future<void> _refreshSnapshot() async {
    final snap = await takeProcessSnapshot();
    if (mounted) setState(() => _snapshot = snap);
  }

  /// Releases through the handshake and reports what was actually observed.
  Future<void> _releaseMemory() async {
    setState(() => _releasing = true);
    await TranslationWorker.instance.shutdownAll();
    await _refreshSnapshot();
    if (mounted) setState(() => _releasing = false);
    final sessions = TranslationWorker.instance.lastReport?.sessionCount;
    context.showMessage(
      message: sessions == 0
          ? "Memory and VRAM released".tl
          : "Release requested (no live reading)".tl,
    );
  }

  static String _mb(int? bytes) => bytes == null
      ? "N/A"
      : "${(bytes / (1024 * 1024)).toStringAsFixed(0)} MB";

  Widget _resourceRow(String label, String value, {String? note}) => ListTile(
    dense: true,
    title: Text(label, style: const TextStyle(fontSize: 13)),
    subtitle: (note == null || note.isEmpty)
        ? null
        : Text(note, style: const TextStyle(fontSize: 11)),
    trailing: Text(
      value,
      style: const TextStyle(fontFamily: 'monospace', fontSize: 13),
    ),
  );

  void _copyDiagnostics(
    BuildContext context,
    EpReport? report,
    List<String> perfLogs,
  ) {
    final buffer = StringBuffer();
    buffer.writeln('=== Execution Provider Report ===');
    if (report != null) {
      buffer.writeln('Active: ${report.active.name.toUpperCase()}');
      buffer.writeln('ORT Runtime: ${report.runtimeVersion}');
      buffer.writeln('Batch Capable: ${report.batchCapable}');
      buffer.writeln('Attempts:');
      for (var a in report.attempts) {
        buffer.writeln('  - $a');
      }
      buffer.writeln('Model Input Shapes:');
      for (var entry in report.modelInputShapes.entries) {
        buffer.writeln('  - ${entry.key}: ${entry.value}');
      }
    } else {
      buffer.writeln('Status: Not initialized');
    }

    buffer.writeln();
    buffer.writeln('=== Recent OCR Performance Logs ===');
    if (perfLogs.isNotEmpty) {
      for (var log in perfLogs) {
        buffer.writeln(log);
      }
    } else {
      buffer.writeln('No OCR logs recorded yet.');
    }

    Clipboard.setData(ClipboardData(text: buffer.toString()));
    context.showMessage(message: "Diagnostics copied to clipboard".tl);
  }

  @override
  Widget build(BuildContext context) {
    final report = TranslationWorker.instance.lastReport;
    final perfLogs = TranslationWorker.instance.recentPerfLogs;

    return Scaffold(
      body: SmoothCustomScrollView(
        scrollbarTopPadding: context.padding.top + 56,
        slivers: [
          SliverAppbar(
            title: Text("Inference diagnostics".tl),
            actions: [
              IconButton(
                icon: const Icon(Icons.cleaning_services_outlined),
                tooltip: "Release memory / VRAM".tl,
                // Disabled while in flight: releasing is now a handshake with
                // the worker, and a second click would race the first.
                onPressed: _releasing ? null : _releaseMemory,
              ),
              IconButton(
                icon: const Icon(Icons.copy),
                tooltip: "Copy diagnostics".tl,
                onPressed: () => _copyDiagnostics(context, report, perfLogs),
              ),
            ],
          ),
          SliverToBoxAdapter(
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  _buildSectionHeader(context, "Execution Provider".tl),
                  const SizedBox(height: 8),
                  if (report == null)
                    Card(
                      child: Padding(
                        padding: const EdgeInsets.all(16),
                        child: Row(
                          children: [
                            const Icon(Icons.info_outline, color: Colors.amber),
                            const SizedBox(width: 12),
                            Expanded(
                              child: Text(
                                "Not initialized (will detect on first translation)".tl,
                                style: const TextStyle(fontSize: 14),
                              ),
                            ),
                          ],
                        ),
                      ),
                    )
                  else ...[
                    Card(
                      child: Column(
                        children: [
                          ListTile(
                            leading: Icon(
                              report.active != OrtEpKind.cpu
                                  ? Icons.bolt
                                  : Icons.memory,
                              color: report.active != OrtEpKind.cpu
                                  ? Colors.green
                                  : null,
                            ),
                            title: Text("Active Provider".tl),
                            subtitle: Text(
                              '${report.active.name.toUpperCase()} (ORT ${report.runtimeVersion})',
                              style: const TextStyle(fontWeight: FontWeight.bold),
                            ),
                            trailing: Chip(
                              label: Text(
                                report.batchCapable
                                    ? "Dynamic Batching".tl
                                    : "Fixed Batch".tl,
                                style: const TextStyle(fontSize: 12),
                              ),
                            ),
                          ),
                          const Divider(height: 1),
                          Padding(
                            padding: const EdgeInsets.all(12),
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                Text(
                                  "Provider Attempts".tl,
                                  style: TextStyle(
                                    fontSize: 12,
                                    color: context.colorScheme.outline,
                                    fontWeight: FontWeight.bold,
                                  ),
                                ),
                                const SizedBox(height: 6),
                                for (var a in report.attempts)
                                  Padding(
                                    padding: const EdgeInsets.symmetric(vertical: 2),
                                    child: Row(
                                      children: [
                                        Icon(
                                          !a.contains('failed')
                                              ? Icons.check_circle_outline
                                              : Icons.cancel_outlined,
                                          size: 16,
                                          color: !a.contains('failed')
                                              ? Colors.green
                                              : Colors.red,
                                        ),
                                        const SizedBox(width: 8),
                                        Expanded(
                                          child: Text(
                                            a,
                                            style: const TextStyle(fontSize: 13),
                                          ),
                                        ),
                                      ],
                                    ),
                                  ),
                                if (report.modelInputShapes.isNotEmpty) ...[
                                  const SizedBox(height: 12),
                                  Text(
                                    "Model Input Shapes".tl,
                                    style: TextStyle(
                                      fontSize: 12,
                                      color: context.colorScheme.outline,
                                      fontWeight: FontWeight.bold,
                                    ),
                                  ),
                                  const SizedBox(height: 6),
                                  for (var entry in report.modelInputShapes.entries)
                                    Padding(
                                      padding: const EdgeInsets.symmetric(vertical: 2),
                                      child: Row(
                                        children: [
                                          const Icon(Icons.shape_line, size: 16),
                                          const SizedBox(width: 8),
                                          Text(
                                            '${entry.key}: ',
                                            style: const TextStyle(fontSize: 13),
                                          ),
                                          Text(
                                            '${entry.value}',
                                            style: TextStyle(
                                              fontSize: 12,
                                              color: context.colorScheme.primary,
                                              fontFamily: 'monospace',
                                            ),
                                          ),
                                        ],
                                      ),
                                    ),
                                ],
                              ],
                            ),
                          ),
                        ],
                      ),
                    ),
                  ],
                  const SizedBox(height: 24),
                  _buildSectionHeader(context, "Resources".tl),
                  const SizedBox(height: 8),
                  Card(
                    child: Column(
                      children: [
                        _resourceRow(
                          "Live OCR sessions".tl,
                          report == null
                              ? "N/A"
                              : "${report.sessionCount}",
                          note: "0 after a release proves the handshake ran",
                        ),
                        _resourceRow(
                          "Native arena".tl,
                          report == null
                              ? "N/A"
                              : _mb(
                                  report.arenaCapacityBytes +
                                      report.hiddenArenaCapacityBytes,
                                ),
                          note: "host RAM, not VRAM",
                        ),
                        _resourceRow(
                          "Process working set".tl,
                          _mb(_snapshot.workingSetBytes),
                        ),
                        _resourceRow(
                          "GPU memory in use".tl,
                          _mb(_snapshot.gpuCurrentUsageBytes),
                          note: _snapshot.sources['nvidia-smi'] ?? '',
                        ),
                        _resourceRow(
                          "Degradations".tl,
                          (report?.degradedTrail.isEmpty ?? true)
                              ? "none"
                              : report!.degradedTrail.join(", "),
                        ),
                      ],
                    ),
                  ),
                  const SizedBox(height: 24),
                  _buildSectionHeader(context, "Recent OCR Performance Logs".tl),
                  const SizedBox(height: 8),
                  if (perfLogs.isEmpty)
                    Card(
                      child: Padding(
                        padding: const EdgeInsets.all(16),
                        child: Text(
                          "No OCR performance logs yet".tl,
                          style: TextStyle(color: context.colorScheme.outline),
                        ),
                      ),
                    )
                  else
                    Card(
                      child: ListView.separated(
                        shrinkWrap: true,
                        physics: const NeverScrollableScrollPhysics(),
                        itemCount: perfLogs.length,
                        separatorBuilder: (_, __) => const Divider(height: 1),
                        itemBuilder: (context, index) {
                          final log = perfLogs[perfLogs.length - 1 - index];
                          return Padding(
                            padding: const EdgeInsets.all(10),
                            child: SelectableText(
                              log,
                              style: const TextStyle(
                                fontSize: 11,
                                fontFamily: 'monospace',
                                height: 1.4,
                              ),
                            ),
                          );
                        },
                      ),
                    ),
                  const SizedBox(height: 32),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildSectionHeader(BuildContext context, String title) {
    return Text(
      title,
      style: TextStyle(
        fontSize: 14,
        fontWeight: FontWeight.bold,
        color: context.colorScheme.primary,
      ),
    );
  }
}
