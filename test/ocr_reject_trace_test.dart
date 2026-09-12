// NOTE: 本文件按仓库约束在本地**未运行**（禁止本地 flutter test / 构建），
// 只经过 `flutter analyze --no-pub`；结论以云端 `Test` job 为准。
//
// 这里钉的是"被丢掉的是哪段文字"这件事。
//
// 用户报的是"日语 OCR 识别不全"：渲染页上有的气泡还是日文原文。funnel 行原本
// 只有计数（`tooShort=4 implausible=7`），计数能证明"这页丢了簇"，但证明不了
// **丢的是哪一段** —— 而"检测根本没找到"和"识别出来了但被判不可信"需要完全
// 不同的修法。所以每个被 `short`/`ratio` 拒掉的字符串现在带进 funnel 行，
// 有界（6 条、每条 28 字），计数仍然精确。
//
// 采样不能影响判定：这些断言同时钉住"计数照旧"和"样本有界"。

import 'package:flutter_test/flutter_test.dart';
import 'package:venera/foundation/image_translation/translation_worker.dart';

void main() {
  group('the funnel can say which texts it threw away', () {
    test('a short or implausible text is kept with its verdict', () {
      final funnel = OcrPageFunnel(3);

      funnel.countOutcome(OcrReject.short, text: 'あ');
      funnel.countOutcome(OcrReject.ratio, text: '……あ…………');

      expect(funnel.tooShort, 1);
      expect(funnel.implausible, 1);
      expect(funnel.rejectedSamples, hasLength(2));
      expect(funnel.rejectedSamples.first.$1, OcrReject.short);
      expect(funnel.rejectedSamples.first.$2, 'あ');
      expect(funnel.rejectedSamples.last.$2, '……あ…………');
    });

    test('the line names them, so a report can quote the text', () {
      final funnel = OcrPageFunnel(3);
      funnel.countOutcome(OcrReject.ratio, text: '……！？');

      expect(
        funnel.line(),
        contains('rejected=[ratio:……！？]'),
        reason: 'the funnel line is what lands in logs.txt',
      );
    });

    test('a page that rejected nothing renders exactly as before', () {
      final funnel = OcrPageFunnel(0);
      funnel.countOutcome(OcrReject.none, text: 'なんとかウチまで');

      expect(funnel.line(), isNot(contains('rejected=')));
      expect(funnel.blocks, 1);
    });

    test('verdicts with nothing to show never sample', () {
      final funnel = OcrPageFunnel(1);

      funnel.countOutcome(OcrReject.empty, text: '   ');
      funnel.countOutcome(OcrReject.untried, text: '');
      funnel.countOutcome(null); // a null verdict *is* "never attempted"

      expect(funnel.rejectedSamples, isEmpty);
      expect(funnel.empty, 1);
      expect(
        funnel.untried,
        2,
        reason: 'the explicit untried plus the null verdict, which maps to it',
      );
    });

    test('the sample is bounded while the counts stay exact', () {
      final funnel = OcrPageFunnel(2);
      for (var i = 0; i < 9; i++) {
        funnel.countOutcome(OcrReject.ratio, text: 'line$i');
      }

      expect(funnel.implausible, 9, reason: 'the count is the truth');
      expect(
        funnel.rejectedSamples,
        hasLength(OcrPageFunnel.rejectedSampleLimit),
        reason: 'the sample is a sample',
      );
      expect(funnel.rejectedSamples.first.$2, 'line0');
    });

    test('a long text is cut short rather than wrapped onto another line', () {
      final funnel = OcrPageFunnel(4);
      final long = 'あ' * 80;

      funnel.countOutcome(OcrReject.ratio, text: long);

      expect(funnel.rejectedSamples.single.$2.length,
          OcrPageFunnel.rejectedSampleChars);
      expect(funnel.line().contains('\n'), isFalse);
    });
  });
}
