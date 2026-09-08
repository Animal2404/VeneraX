import 'dart:io';

/// Startup tracing shared by the headless entry point and the component
/// initialiser.
///
/// A GUI-subsystem binary has no console when launched detached, so a hang
/// during startup is otherwise invisible: the process simply sits there and the
/// only symptom is "no output". Writing each step to a file turns "it hangs"
/// into "it hangs at step N, after M ms" — which is how D-14 (`--headless`
/// never reaches its own `exit(0)`) gets located instead of guessed at.
bool headlessTraceEnabled = false;

String get headlessTracePath =>
    '${Directory.systemTemp.path}${Platform.pathSeparator}venera_headless_trace.log';

DateTime _last = DateTime.now();

/// Records [step] with the elapsed time since the previous step. Never throws:
/// tracing must not become the reason a command fails.
void headlessTrace(String step) {
  if (!headlessTraceEnabled) return;
  final now = DateTime.now();
  final gap = now.difference(_last).inMilliseconds;
  _last = now;
  try {
    File(headlessTracePath)
        .writeAsStringSync('${now.toIso8601String()} +${gap}ms $step\n',
            mode: FileMode.append, flush: true);
  } catch (_) {}
}

void headlessTraceStart(String label) {
  _last = DateTime.now();
  try {
    File(headlessTracePath).writeAsStringSync('--- $label ---\n');
  } catch (_) {}
}
