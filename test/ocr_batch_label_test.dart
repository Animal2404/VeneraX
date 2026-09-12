// NOTE: 本文件按仓库约束在本地**未运行**（禁止本地 flutter test / 构建），
// 只经过 `flutter analyze --no-pub`；结论以云端 `Test` job 为准。
//
// 这里钉的是日志能不能跟"用户的某一页"对上。
//
// worker 的每页行（`OcrFunnel page=3 …`、以及随行的检测/拒绝台账）用的是
// **批内下标**：一章 37 页、每批 6 页时，`page=3` 每批都出现一次，指的是不同的
// 页。于是"用户报第 3 页有问题"与"我在 logs.txt 里读到的 page=3"永远对不上 ——
// 这正是上一轮定位"识别不全"时卡住的地方。
//
// 现在每次 OCR 调用先打一行 `OCR batch pages=31.jpg,32.jpg,…`，用的是缓存键的
// 末段（短、且逐页唯一），批内的 page=N 从此可以映射回真实页。

import 'package:flutter_test/flutter_test.dart';
import 'package:venera/foundation/image_translation/translation_service.dart';

void main() {
  group('the OCR batch line names the pages it covers', () {
    test('a rendered-page key yields its page segment, without the mode suffix', () {
      const key =
          'pageTranslation@2@1@auto>zh@e8043ff9@nhentai@384271@0@'
          'https://i3.nhentai.net/galleries/2089266/31.jpg#s';

      expect(ocrBatchPageLabel(key), '31.jpg');
    });

    test('a source-image key yields the same label', () {
      expect(
        ocrBatchPageLabel('https://i3.nhentai.net/galleries/2089266/31.jpg'),
        '31.jpg',
      );
    });

    test('a key with no path and no suffix is returned as it is', () {
      expect(ocrBatchPageLabel('localcover'), 'localcover');
      expect(ocrBatchPageLabel('a/b/c.webp#p'), 'c.webp');
    });

    test('a trailing slash does not produce an empty label', () {
      // Defensive: an empty label in the log line would silently merge two
      // pages' worth of ledger lines under one name.
      expect(ocrBatchPageLabel('https://x/galleries/2089266/'), isNot(''));
    });
  });
}
