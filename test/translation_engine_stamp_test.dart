// NOTE: 本文件按仓库约束在本地**未运行**（禁止本地 flutter test / 构建），
// 只经过 `flutter analyze --no-pub`；结论以云端 `Test` job 为准。
//
// 这里钉的是"换了模型却没变化"的修复：**引擎戳进缓存世代**。
//
// 缺陷原状：`cachePrefix` 只有 `pageTranslation@世代@源>目标@`，而
// 渲染图缓存键（`cacheKeyFor`）和持久译文（`translated_page.cache_key`、
// `translated_chapter_index.scope_prefix`）全都从它拼出来。于是换语言会换代
// （语言对在键里），**换模型不会** —— 阅读器继续命中旧译文，用户看到的结论就是
// "模型还是没改"。把 provider kind + endpoint + model 的短哈希拼进前缀之后，
// 一次改动同时移动渲染缓存与译文文本。
//
// 反过来也要钉住"不该进键的东西"：API key 轮换、条目改名都不是新模型，不应把
// 用户的整库译文作废。

import 'package:flutter_test/flutter_test.dart';
import 'package:venera/foundation/appdata.dart';
import 'package:venera/foundation/image_translation/llm_translator.dart';
import 'package:venera/foundation/image_translation/translation_config.dart';

void main() {
  const listKey = 'imageTranslationProviders';
  const activeKey = 'imageTranslationActiveProviderId';

  Map<String, dynamic> provider({
    String id = 'p1',
    String name = 'Gateway',
    String url = 'https://example.test/v1',
    String key = 'sk-secret',
    String model = 'model-a',
    String kind = 'openai',
  }) => {
    'id': id,
    'name': name,
    'url': url,
    'key': key,
    'model': model,
    'kind': kind,
  };

  void install(List<Map<String, dynamic>> providers, String activeId) {
    appdata.settings[listKey] = providers;
    appdata.settings[activeKey] = activeId;
  }

  setUp(() => install([provider()], 'p1'));

  tearDown(() {
    appdata.settings[listKey] = null;
    appdata.settings[activeKey] = null;
  });

  group('translationEngineStampOf: what may invalidate a translation cache', () {
    String stamp({
      String kind = 'openai',
      String url = 'https://example.test/v1',
      String model = 'model-a',
    }) => translationEngineStampOf(kind: kind, url: url, model: model);

    test('the same engine gives the same stamp', () {
      expect(stamp(), stamp());
    });

    test('a different model, endpoint or kind is a different engine', () {
      expect(stamp(model: 'model-b'), isNot(stamp()));
      expect(stamp(url: 'https://other.test/v1'), isNot(stamp()));
      expect(stamp(kind: 'public'), isNot(stamp()));
    });

    test('it is short and carries nothing a key or a file path may not hold', () {
      final value = stamp();
      expect(value, hasLength(8));
      expect(value, matches(RegExp(r'^[0-9a-f]{8}$')));
      expect(value.contains(':'), isFalse);
      expect(value.contains('/'), isFalse);
      expect(value.contains('%'), isFalse);
    });
  });

  group('TranslationConfig.cachePrefix: the generation switch', () {
    test('a model change moves the prefix', () {
      final before = TranslationConfig.global.cachePrefix;

      install([provider(model: 'model-b')], 'p1');

      final after = TranslationConfig.global.cachePrefix;
      expect(
        after,
        isNot(before),
        reason: 'switching models must not keep serving the old translation',
      );
    });

    test('rotating the key or renaming the entry does not move it', () {
      final before = TranslationConfig.global.cachePrefix;

      install([
        provider(key: 'sk-rotated', name: 'Renamed gateway'),
      ], 'p1');

      expect(
        TranslationConfig.global.cachePrefix,
        before,
        reason: 'neither a new key nor a new label is a new model',
      );
    });

    test('the prefix still names the namespace, the generations and the pair', () {
      final prefix = TranslationConfig.global.cachePrefix;

      expect(prefix, startsWith('pageTranslation@'));
      expect(
        prefix,
        startsWith('pageTranslation@$kOcrSchemaGeneration@'),
        reason: '"clear all" and the scope deletes match on this head',
      );
      expect(
        prefix.contains('@$kTranslationPromptGeneration@'),
        isTrue,
        reason: 'a prompt revision gets its own generation slot',
      );
      expect(prefix.contains('>'), isTrue, reason: 'the language pair stays');
      expect(
        prefix.endsWith('@'),
        isTrue,
        reason: 'scopes are concatenated onto it',
      );
    });

    test('no provider configured keeps a stable generation', () {
      install(<Map<String, dynamic>>[], '');
      final first = TranslationConfig.global.cachePrefix;
      final second = TranslationConfig.global.cachePrefix;

      expect(first, second);
      expect(first, endsWith('@none@'));
    });
  });
}
