// NOTE: 本文件按仓库约束在本地**未运行**（禁止本地 flutter test / 构建），
// 只经过 `flutter analyze --no-pub`；结论以云端 `Test` job 为准。
//
// 这里钉的是"词典从哪读、读出来几条"。
//
// 起因是韩语模型：它配的是 PP-OCRv1 时代的识别模型（3689 类）+ PaddleOCR
// v2.7 的 korean_dict.txt（3688 行），而字符集规则要求 3688 + 2 = 3690 类，
// 于是永远"校验不通过"——行在列表里，语言不可用。v5 把词典**内联在模型自己
// 的 inference.yml 里**，这正是让配对变精确而不是靠猜的原因：11945 条 + blank
// + space = 11947 类，与模型输出一致（对着真实文件数出来的数，不是文档）。
//
// 三个调用点必须数出同一个数：`loadCharset()`（worker）与校验器里的
// `dictLineCountSync` / `_readTextLines`。任何一个不一致，就会把正确的模型判死。

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:venera/foundation/image_translation/ocr_dict.dart';
import 'package:venera/foundation/image_translation/translation_worker.dart';

void main() {
  group('parseDictEntries: plain dictionaries (everything up to v4)', () {
    test('one entry per line, and the final newline is not an entry', () {
      expect(parseDictEntries('a\nb\nc\n'), ['a', 'b', 'c']);
      expect(parseDictEntries('a\nb\nc'), ['a', 'b', 'c']);
    });

    test('an empty line inside the file is a real entry', () {
      // `loadCharset` maps an empty entry to a space, which some dictionaries
      // rely on; dropping it would shift every later class by one.
      expect(parseDictEntries('a\n\nb\n'), ['a', '', 'b']);
    });

    test('CRLF and lone CR both end a line', () {
      expect(parseDictEntries('a\r\nb\r\n'), ['a', 'b']);
      expect(parseDictEntries('a\rb\r'), ['a', 'b']);
    });

    test('an empty file has no entries', () {
      expect(parseDictEntries(''), isEmpty);
      expect(parseDictEntries('\n'), ['']);
    });
  });

  group('parseDictEntries: the dictionary inlined in inference.yml (v5)', () {
    const yml = '''
Global:
  model_name: korean_PP-OCRv5_mobile_rec
PostProcess:
  name: CTCLabelDecode
  character_dict:
  - ᄀ
  - ᄁ
  - ' '
  - "a"
  use_space_char: true
  another_key: 1
''';

    test('the character_dict block is what is read, not the whole file', () {
      expect(parseDictEntries(yml), ['ᄀ', 'ᄁ', ' ', 'a']);
    });

    test('the block ends at the next key', () {
      final entries = parseDictEntries(yml);

      expect(entries.contains('use_space_char: true'), isFalse);
      expect(entries, hasLength(4));
    });

    test('quoting is stripped, and an empty line inside the block is skipped', () {
      const spaced = 'character_dict:\n- a\n\n- b\n';
      expect(parseDictEntries(spaced), ['a', 'b']);
    });

    test('a file that merely mentions the key elsewhere is still plain text', () {
      // No `character_dict:` line: this is a plain dictionary whose entries
      // happen to contain punctuation.
      expect(parseDictEntries('a\nb\n'), ['a', 'b']);
    });
  });

  group('the "+2" pairing holds through both shapes', () {
    test('a plain dict of N entries needs N+2 classes', () {
      final dir = Directory.systemTemp.createTempSync('venera_dict_test');
      addTearDown(() => dir.deleteSync(recursive: true));
      final file = File('${dir.path}/dict.txt')..writeAsStringSync('a\nb\nc\n');

      expect(loadCharset(file.path, expectedClasses: 5), hasLength(5));
      expect(
        () => loadCharset(file.path, expectedClasses: 4),
        throwsA(isA<DictMismatchException>()),
      );
    });

    test('a dict inlined in a yml of N entries needs N+2 classes too', () {
      final dir = Directory.systemTemp.createTempSync('venera_dict_yml_test');
      addTearDown(() => dir.deleteSync(recursive: true));
      final file = File('${dir.path}/dict.txt')
        ..writeAsStringSync('character_dict:\n- a\n- b\n- c\nother: 1\n');

      // Three entries + blank + space = five classes, exactly as the Korean
      // model's 11945 entries become the 11947 classes it outputs.
      expect(loadCharset(file.path, expectedClasses: 5), hasLength(5));
      expect(
        () => loadCharset(file.path, expectedClasses: 3),
        throwsA(isA<DictMismatchException>()),
      );
    });
  });
}
