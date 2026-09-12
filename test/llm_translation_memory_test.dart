// NOTE: 本文件按仓库约束在本地**未运行**（禁止本地 flutter test / 构建），
// 只经过 `flutter analyze --no-pub`；结论以云端 `Test` job 为准。
//
// 这里钉的是"API 翻译慢"的两条免请求路径：
//
//  1. **没有可译内容的行直通**：`…`、`!?`、`♪`、`ーーー` 这类气泡没有词，
//     模型只能原样吐回来。manga 里这种行占比很高，跳过它们在构造上是安全的
//     （返回的就是输入本身），却能把它们从每个请求里删掉。
//  2. **翻译记忆**：同一句话在漫画里反复出现（`ハァ…`、口癖、拟声词），重读或
//     重渲染会再问一次。命中一次就省一次跨网请求——这是"在等别人 API"的管线里
//     最便宜的提速。键里带模型：换模型后措辞本来就可能不同，不能悄悄给旧译文。
//
// `translateBatch` 本身要网络，所以这里只测它的两个纯部件（`needsTranslation`、
// 记忆的键与淘汰），并且用公开的 `remember`/`memoryLookup` 而不是改写实现。

import 'package:flutter_test/flutter_test.dart';
import 'package:venera/foundation/image_translation/llm_translator.dart';

void main() {
  setUp(LlmTranslator.clearMemory);
  tearDown(LlmTranslator.clearMemory);

  group('needsTranslation: a bubble with no words is not a translation job', () {
    test('punctuation, ellipses and symbols only ⇒ nothing to translate', () {
      for (final text in ['……', '…', '!?', '！？', '♪', '！！', '、、', '〜', '　', '']) {
        expect(
          LlmTranslator.needsTranslation(text),
          isFalse,
          reason: '"$text" carries no words',
        );
      }
    });

    test('a prolonged-sound-mark run counts as content, not as punctuation', () {
      // `ー` is U+30FC, inside the kana block, and manga use `ーーー` as a sound
      // effect. The filter is deliberately conservative: it skips a line only
      // when there is nothing letter-like in it at all, so this stays a
      // translation job rather than being silently passed through.
      expect(LlmTranslator.needsTranslation('ーーー'), isTrue);
    });

    test('anything with a letter or a digit ⇒ translate', () {
      for (final text in ['ハァ…', 'あっ', 'お姉さん', '12', 'OK', '……はい', 'あ…？！']) {
        expect(
          LlmTranslator.needsTranslation(text),
          isTrue,
          reason: '"$text" carries words',
        );
      }
    });
  });

  group('the translation memory: keyed by language AND model', () {
    test('a stored translation comes back for the same key', () {
      LlmTranslator.remember('zh', 'mimo-v2.5', 'ハァ…', '呼……');

      expect(LlmTranslator.memoryLookup('zh', 'mimo-v2.5', 'ハァ…'), '呼……');
      expect(LlmTranslator.memorySize, 1);
    });

    test('a different model or language does not inherit the wording', () {
      LlmTranslator.remember('zh', 'model-a', 'ハァ…', '呼……');

      expect(
        LlmTranslator.memoryLookup('zh', 'model-b', 'ハァ…'),
        isNull,
        reason: 'switching models must not look like a broken switch',
      );
      expect(LlmTranslator.memoryLookup('en', 'model-a', 'ハァ…'), isNull);
      expect(LlmTranslator.memoryLookup('zh', 'model-a', '……'), isNull);
    });

    test('empty or wordless material is never remembered', () {
      LlmTranslator.remember('zh', 'm', '……', '……');
      LlmTranslator.remember('zh', 'm', 'あっ', '');
      LlmTranslator.remember('zh', 'm', '   ', '  ');

      expect(LlmTranslator.memorySize, 0);
    });

    test('storing the same key again replaces rather than duplicates', () {
      LlmTranslator.remember('zh', 'm', 'あっ', '啊');
      LlmTranslator.remember('zh', 'm', 'あっ', '啊！');

      expect(LlmTranslator.memorySize, 1);
      expect(LlmTranslator.memoryLookup('zh', 'm', 'あっ'), '啊！');
    });

    test('the memory is bounded, dropping the oldest entries first', () {
      // One over the cap, so exactly the first insertion must be gone.
      for (var i = 0; i < LlmTranslator.memoryCapacity + 1; i++) {
        LlmTranslator.remember('zh', 'm', 'line$i', 'translated$i');
      }

      expect(LlmTranslator.memorySize, LlmTranslator.memoryCapacity);
      expect(
        LlmTranslator.memoryLookup('zh', 'm', 'line0'),
        isNull,
        reason: 'oldest first',
      );
      expect(
        LlmTranslator.memoryLookup('zh', 'm', 'line${LlmTranslator.memoryCapacity}'),
        isNotNull,
        reason: 'the newest entry is always kept',
      );
    });

    test('forgetAllTranslations clears it — what 重新翻译 needs', () {
      LlmTranslator.remember('zh', 'm', 'あっ', '啊');
      expect(LlmTranslator.memorySize, 1);

      LlmTranslator.forgetAllTranslations();

      expect(LlmTranslator.memorySize, 0);
      expect(LlmTranslator.memoryLookup('zh', 'm', 'あっ'), isNull);
    });
  });
}
