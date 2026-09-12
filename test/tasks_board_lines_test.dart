// NOTE: 本文件按仓库约束在本地**未运行**（禁止本地 flutter test / 构建），
// 只经过 `flutter analyze --no-pub`；结论以云端 `Test` job 为准。
//
// 这里钉的是"看板**真的出现在界面上**"，而不只是数据对了。
//
// 上一轮我只测了数据（`waitingFor` 等），没测卡片到底渲染出什么 —— 而用户的
// 验收恰恰是"界面上能持续看到：当前阶段 / 已完成/总数 / 当前条目 / 已用时间 /
// 最近一次响应或错误 / 模型名与是否启用 reasoning"。要做到可断言，四行文本被提成
// 纯函数 [taskBoardLinesOf]（值进、文本出），下面用**真实数据路径**驱动它：
// 任务 + 活动 → PreTranslationProgress.snapshot → 看板四行。
//
// 秒数取用户那次运行的真实值：请求 15:09:03 发出、首个响应 15:10:51 到达 ——
// 那 108 秒的静默正是这块看板存在的理由。

import 'package:flutter_test/flutter_test.dart';
import 'package:venera/foundation/comic_type.dart';
import 'package:venera/foundation/image_translation/pre_translation_tasks.dart';
import 'package:venera/foundation/image_translation/translation_types.dart';
import 'package:venera/pages/tasks_page.dart';

DateTime _at(int m, int s) => DateTime(2026, 9, 12, 15, m, s);
final _sent = _at(9, 3);
final _answered = _at(10, 51);

PreTranslationTask _task({int total = 37, int done = 12}) => PreTranslationTask(
  id: 't',
  cid: 'c',
  sourceKey: 's',
  comicType: ComicType(0),
  title: 'Comic',
  chapters: [
    PreTranslationChapter(eid: '1', title: 'Ch 1', total: total, done: done),
  ],
  createdAt: _at(8, 12),
  status: PreTranslationTaskStatus.running,
);

PreTranslationActivity _groupInFlight({DateTime? answered}) {
  final activity = PreTranslationActivity()
    ..currentChapter = 'Ch 2'
    ..currentFromPage = 12
    ..currentToPage = 17
    ..requestSentAt = _sent
    ..firstResponseAt = answered;
  // The stage lives on the group level; `headStage` reads the lowest index, and
  // the card's focus flags come from it.
  activity.groups[0] = PreTranslationGroupActivity(index: 0, pageCount: 6)
    ..stage = TranslationStage.translating;
  return activity;
}

void main() {
  group('the card shows the board while the translation request is out', () {
    test('during the wait: stage, item, wait and model are all there', () {
      final task = _task();
      final activity = _groupInFlight();
      final view = PreTranslationProgress.snapshot(task, activity: activity,
          now: _answered);

      final board = taskBoardLinesOf(view, now: _answered);

      expect(board.head, contains('Stage:'));
      expect(board.head, contains('Translating'), reason: 'current phase');
      expect(board.head, contains('Ch 2'), reason: 'current item');
      expect(board.head, contains('12'), reason: 'first page in flight');
      expect(board.head, contains('17'), reason: 'last page in flight');
      expect(
        board.waiting,
        contains('1:48'),
        reason: '108 seconds of silence; formatTaskDuration drops the leading '
            'zero below an hour',
      );
      expect(board.waiting, contains('6'), reason: 'pages in flight');
      expect(board.model, contains('No reasoning/thinking parameter'));
      expect(board.lastEvent, isNull, reason: 'nothing has come back yet');
      expect(board.isEmpty, isFalse);
    });

    test('after the first answer: the wait is gone, its age takes over', () {
      final task = _task();
      final activity = _groupInFlight(answered: _answered)
        ..lastResponseAt = _answered;
      final view = PreTranslationProgress.snapshot(task, activity: activity,
          now: _answered.add(const Duration(minutes: 1)));

      final board = taskBoardLinesOf(
        view,
        now: _answered.add(const Duration(minutes: 1)),
      );

      expect(board.waiting, isNull, reason: 'the answer is in');
      expect(board.lastEvent, contains('Last response'));
      expect(board.lastEvent, contains('1:00'));
      expect(board.isError, isFalse);
    });

    test('an error is shown verbatim instead of a stopped progress bar', () {
      final task = _task();
      final activity = _groupInFlight(answered: _answered)
        ..lastResponseAt = _answered
        ..lastError = 'HTTP 502 from the endpoint';
      final view = PreTranslationProgress.snapshot(task, activity: activity,
          now: _answered);

      final board = taskBoardLinesOf(view, now: _answered);

      expect(board.lastEvent, contains('HTTP 502 from the endpoint'));
      expect(board.isError, isTrue);
    });

    test('a finished card shows no board at all', () {
      final task = _task();
      final view = PreTranslationProgress.snapshot(task, now: _at(20, 0));

      final board = taskBoardLinesOf(view, now: _at(20, 0));

      expect(board.isEmpty, isTrue);
      expect(board.head, isNull);
      expect(board.waiting, isNull);
      expect(
        board.model,
        isNull,
        reason: 'a finished card must not name the model configured now',
      );
      expect(board.lastEvent, isNull);
    });
  });
}
