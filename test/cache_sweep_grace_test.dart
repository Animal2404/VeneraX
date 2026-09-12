// NOTE: 本文件按仓库约束在本地**未运行**（禁止本地 flutter test / 构建），
// 只经过 `flutter analyze --no-pub`；结论以云端 `Test` job 为准。
//
// 这里钉的是缓存清扫**不能**碰刚写下的文件。
//
// 原因是一次真实的失败：云端 `image_downloader_stream_test` 间歇性变红，报的是
// `PathAccessException ... errno = 32（另一个进程正在使用此文件）`，栈指向
// `CacheManager._scanDir` ← `new CacheManager` ← 测试里的 `writeCache`。
// 机制是 `writeCache` **先写文件、后插行**，而构造时启动的孤儿清扫正好能落在
// 这两步之间：它把这个文件当孤儿删掉——在 Windows 上还会因为写者仍持有句柄而
// 直接抛异常给调用方。宽限期把竞态从源头去掉，谓词是纯函数，所以单独测。

import 'package:flutter_test/flutter_test.dart';
import 'package:venera/foundation/cache_manager.dart';

void main() {
  group('unmanagedCacheFileIsSweepable: the sweep must not eat a live write', () {
    final now = DateTime(2026, 9, 12, 12);

    test('a file written a moment ago is somebody\'s in-flight write', () {
      expect(
        unmanagedCacheFileIsSweepable(
          now.subtract(const Duration(milliseconds: 200)),
          now,
        ),
        isFalse,
      );
      expect(
        unmanagedCacheFileIsSweepable(
          now.subtract(const Duration(seconds: 30)),
          now,
        ),
        isFalse,
      );
    });

    test('a file that has sat there for the whole window is litter', () {
      expect(
        unmanagedCacheFileIsSweepable(
          now.subtract(const Duration(seconds: 61)),
          now,
        ),
        isTrue,
      );
      expect(
        unmanagedCacheFileIsSweepable(
          now.subtract(const Duration(days: 3)),
          now,
        ),
        isTrue,
      );
    });

    test('the boundary is inclusive at exactly the window', () {
      expect(
        unmanagedCacheFileIsSweepable(
          now.subtract(kCacheSweepGrace),
          now,
        ),
        isTrue,
      );
      expect(
        unmanagedCacheFileIsSweepable(
          now.subtract(kCacheSweepGrace - const Duration(milliseconds: 1)),
          now,
        ),
        isFalse,
      );
    });

    test('the window is wide enough to cover a slow write, and short enough to '
        'still be housekeeping', () {
      expect(kCacheSweepGrace, greaterThanOrEqualTo(const Duration(seconds: 5)));
      expect(kCacheSweepGrace, lessThanOrEqualTo(const Duration(minutes: 5)));
    });
  });
}
