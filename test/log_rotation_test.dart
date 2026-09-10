// NOTE: 本文件按仓库约束在本地**未运行**（禁止本地 flutter test / 构建），
// 只经过 `flutter analyze --no-pub`；结论以云端 `Test` job 为准。
//
// 为什么值得钉：日志是"发我一份 log"这类排查的唯一凭据，而 `openWrite()`
// 默认截断——每次启动都会抹掉上一次会话，正好抹掉要排查的那一次。改成追加
// 之后必须有界，所以轮转策略是纯函数，单独测；文件 IO 本身不在这里碰。

import 'package:flutter_test/flutter_test.dart';
import 'package:venera/foundation/log.dart';

void main() {
  List<int> bytesOf(String text) => text.codeUnits;

  group('Log.retainedTail: rotation keeps the recent record, whole lines only', () {
    test('a file under the cap is returned untouched', () {
      final bytes = bytesOf('alpha\nbeta\n');
      expect(Log.retainedTail(bytes, keepBytes: 1024), bytes);
    });

    test('an over-cap file keeps exactly its last keepBytes, rounded to a '
        'line boundary', () {
      // 100 one-byte lines: rotation keeping 30 bytes must start on a line
      // boundary, i.e. drop the partial line it would otherwise begin with.
      final text = '${List.generate(100, (i) => 'L${i % 10}').join('\n')}\n';
      final bytes = bytesOf(text);
      final kept = Log.retainedTail(bytes, keepBytes: 30);

      expect(kept.length, lessThanOrEqualTo(30));
      expect(
        kept.first,
        isNot(10),
        reason: 'never start the retained record with an empty line',
      );
      final keptText = String.fromCharCodes(kept);
      expect(
        text.endsWith(keptText),
        isTrue,
        reason: 'what survives is the tail of what was there',
      );
      expect(keptText, endsWith('\n'));
    });

    test('a tail with no line break at all is kept as-is rather than emptied', () {
      final bytes = List<int>.filled(100, 65); // 'AAAA…', no newline
      final kept = Log.retainedTail(bytes, keepBytes: 30);
      expect(kept.length, 30);
      expect(kept.every((b) => b == 65), isTrue);
    });

    test('the shipped bounds are the ones the file is rotated against', () {
      expect(Log.maxFileBytes, greaterThan(Log.keepFileBytes));
      expect(Log.keepFileBytes, 1024 * 1024);
    });
  });
}
