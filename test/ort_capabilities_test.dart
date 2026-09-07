import 'package:flutter_test/flutter_test.dart';
import 'package:venera/foundation/image_translation/ort_capabilities.dart';
import 'package:venera/foundation/image_translation/ort_ffi.dart';

void main() {
  group('planEpOrder', () {
    test('non-desktop platform always resolves to cpu only', () {
      const probe = OrtProbe(
        runtimeVersion: '1.22.0',
        hasCudaSymbol: true,
        hasDmlSymbol: true,
        isWindows: false,
        isDesktop: false,
      );
      expect(planEpOrder(EpPreference.auto, probe), [OrtEpKind.cpu]);
      expect(planEpOrder(EpPreference.cuda, probe), [OrtEpKind.cpu]);
      expect(planEpOrder(EpPreference.directml, probe), [OrtEpKind.cpu]);
    });

    test('auto on Windows with DirectML and CUDA probes', () {
      const probeBoth = OrtProbe(
        runtimeVersion: '1.22.0',
        hasCudaSymbol: true,
        hasDmlSymbol: true,
        isWindows: true,
        isDesktop: true,
      );
      expect(planEpOrder(EpPreference.auto, probeBoth), [
        OrtEpKind.cuda,
        OrtEpKind.directml,
        OrtEpKind.cpu,
      ]);

      const probeDmlOnly = OrtProbe(
        runtimeVersion: '1.22.0',
        hasCudaSymbol: false,
        hasDmlSymbol: true,
        isWindows: true,
        isDesktop: true,
      );
      expect(planEpOrder(EpPreference.auto, probeDmlOnly), [
        OrtEpKind.directml,
        OrtEpKind.cpu,
      ]);

      const probeNone = OrtProbe(
        runtimeVersion: '1.22.0',
        hasCudaSymbol: false,
        hasDmlSymbol: false,
        isWindows: true,
        isDesktop: true,
      );
      expect(planEpOrder(EpPreference.auto, probeNone), [OrtEpKind.cpu]);
    });

    test('explicit preferences on Windows', () {
      const probe = OrtProbe(
        runtimeVersion: '1.22.0',
        hasCudaSymbol: false,
        hasDmlSymbol: true,
        isWindows: true,
        isDesktop: true,
      );
      expect(planEpOrder(EpPreference.cpu, probe), [OrtEpKind.cpu]);
      expect(planEpOrder(EpPreference.directml, probe), [
        OrtEpKind.directml,
        OrtEpKind.cpu,
      ]);
      expect(planEpOrder(EpPreference.cuda, probe), [
        OrtEpKind.cuda,
        OrtEpKind.directml,
        OrtEpKind.cpu,
      ]);
    });
  });

  group('decideAfterFailure', () {
    test('epUnavailable and invalidGraph trigger tryNextEp', () {
      const e1 = OrtFfiException('provider failed to load', OrtFfiErrorKind.epUnavailable);
      expect(decideAfterFailure(e1, alreadyTried: 1, consecutiveFailures: 0), EpDecision.tryNextEp);

      const e2 = OrtFfiException('invalid graph', OrtFfiErrorKind.invalidGraph);
      expect(decideAfterFailure(e2, alreadyTried: 1, consecutiveFailures: 0), EpDecision.tryNextEp);
    });

    test('outOfMemory triggers shrinkAndRetry', () {
      const e = OrtFfiException('cuda out of memory', OrtFfiErrorKind.outOfMemory);
      expect(decideAfterFailure(e, alreadyTried: 1, consecutiveFailures: 0), EpDecision.shrinkAndRetry);
    });

    test('deviceRemoved triggers goCpuPermanently', () {
      const e = OrtFfiException('device_removed D3D_ERROR', OrtFfiErrorKind.deviceRemoved);
      expect(decideAfterFailure(e, alreadyTried: 1, consecutiveFailures: 0), EpDecision.goCpuPermanently);
    });

    test('other errors trigger tryNextEp and permanently fall back after threshold', () {
      const e = OrtFfiException('unknown failure', OrtFfiErrorKind.other);
      expect(decideAfterFailure(e, alreadyTried: 1, consecutiveFailures: 0), EpDecision.tryNextEp);
      expect(decideAfterFailure(e, alreadyTried: 1, consecutiveFailures: 1), EpDecision.tryNextEp);
      expect(decideAfterFailure(e, alreadyTried: 1, consecutiveFailures: 2), EpDecision.goCpuPermanently);
    });
  });
}
