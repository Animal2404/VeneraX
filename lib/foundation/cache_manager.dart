import 'package:crypto/crypto.dart';
import 'package:sqlite3/sqlite3.dart';
import 'package:venera/foundation/sqlite_connection.dart';
import 'package:venera/foundation/log.dart';
import 'package:venera/utils/io.dart';

import 'app.dart';

/// How long a cache file must exist before the orphan sweep may remove it.
///
/// `writeCache` writes the file **before** it inserts the row that makes the
/// file "managed", so a sweep listing the directory in that gap would see a
/// live entry as an orphan — and on Windows the `delete` can then fail outright
/// with errno 32 because the writer still holds the handle, turning a routine
/// sweep into an exception delivered to whoever happened to be writing. Both
/// halves of that are real: the file is destroyed, or the caller crashes. The
/// grace window removes the race instead of hardening only the symptom.
const Duration kCacheSweepGrace = Duration(seconds: 60);

/// Whether a file with no row in the cache table is old enough to be swept.
///
/// Pure, so the boundary is pinned by a test: a file written a moment ago is
/// somebody's in-flight write; one that has sat there for [grace] is litter.
bool unmanagedCacheFileIsSweepable(
  DateTime modified,
  DateTime now, {
  Duration grace = kCacheSweepGrace,
}) => now.difference(modified) >= grace;

class CacheManager {
  static String get cachePath => '${App.cachePath}/cache';

  static String get _dbPath => '${App.dataPath}/cache.db';

  static CacheManager? instance;

  late Database _db;

  int? _currentSize;

  /// size in bytes
  int get currentSize => _currentSize ?? 0;

  int dir = 0;

  int _limitSize = 2 * 1024 * 1024 * 1024;

  static Future<int> _scanDir(String dbPath, String dir) async {
    // Runs on a fresh connection inside an isolate rather than sharing the
    // main isolate's handle: the sqlite3 package attaches a NativeFinalizer to
    // every Database, so a wrapper built from a shared pointer could close the
    // connection the main isolate is still using (double-free / use-after-free,
    // a native heap abort). isolateOp serializes on the gateway chain so this
    // scan never runs concurrently with another background DB isolate.
    var res = await DatabaseGateway.instance.isolateOp(dbPath, (db) async {
      int totalSize = 0;
      List<String> unmanagedFiles = [];
      await for (var file in Directory(dir).list(recursive: true)) {
        if (file is File) {
          var size = await file.length();
          var segments = file.uri.pathSegments;
          var name = segments.last;
          var dir = segments.elementAtOrNull(segments.length - 2) ?? "*";
          var res = db.select(
            '''
                SELECT * FROM cache
                WHERE dir = ? AND name = ?
              ''',
            [dir, name],
          );
          if (res.isEmpty) {
            unmanagedFiles.add(file.path);
          } else {
            totalSize += size;
          }
        }
      }
      return {'totalSize': totalSize, 'unmanagedFiles': unmanagedFiles};
    });
    // delete unmanaged files
    // Only modify the database in the main isolate to avoid deadlock
    var sweepNow = DateTime.now();
    for (var filePath in res['unmanagedFiles'] as List<String>) {
      var file = File(filePath);
      if (await file.exists()) {
        // A file younger than the grace window is a write in flight, not an
        // orphan: `writeCache` creates the file first and inserts its row after,
        // so this sweep can legitimately catch it in between.
        try {
          final stat = await file.stat();
          if (!unmanagedCacheFileIsSweepable(stat.modified, sweepNow)) {
            continue;
          }
        } on FileSystemException catch (e) {
          Log.warning('CacheManager', 'cache sweep could not stat ${file.path}: $e');
          continue;
        }
        try {
          await file.delete();
        } on FileSystemException catch (e) {
          // Windows refuses to unlink a file another handle still holds. A
          // sweep is housekeeping: it may skip a file, never fail its caller.
          Log.warning(
            'CacheManager',
            'cache sweep could not delete ${file.path}: $e',
          );
          continue;
        }
      }
      var segments = file.uri.pathSegments;
      var name = segments.last;
      var dir = segments.elementAtOrNull(segments.length - 2) ?? "*";
      CacheManager()._db.execute(
        '''
        DELETE FROM cache
        WHERE dir = ? AND name = ?
      ''',
        [dir, name],
      );
    }
    return res['totalSize'] as int;
  }

  CacheManager._create() {
    Directory(cachePath).createSync(recursive: true);
    _db = DatabaseGateway.instance.openManaged(_dbPath);
    _db.execute('''
      CREATE TABLE IF NOT EXISTS cache (
        key TEXT PRIMARY KEY NOT NULL,
        dir TEXT NOT NULL,
        name TEXT NOT NULL,
        expires INTEGER NOT NULL,
        type TEXT
      )
    ''');
    _scanDir(_dbPath, cachePath).then((value) {
      _currentSize = value;
      checkCache();
    });
  }

  /// Get the singleton instance of CacheManager.
  factory CacheManager() => instance ??= CacheManager._create();

  /// set cache size limit in MB
  void setLimitSize(int size) {
    _limitSize = size * 1024 * 1024;
  }

  /// Write cache to disk.
  Future<void> writeCache(
    String key,
    List<int> data, [
    int duration = 7 * 24 * 60 * 60 * 1000,
  ]) async {
    await delete(key);
    this.dir++;
    this.dir %= 100;
    var dir = this.dir;
    var name = md5.convert(key.codeUnits).toString();
    var file = File('$cachePath/$dir/$name');
    await file.create(recursive: true);
    await file.writeAsBytes(data);
    var expires = DateTime.now().millisecondsSinceEpoch + duration;
    _db.execute(
      '''
      INSERT OR REPLACE INTO cache (key, dir, name, expires) VALUES (?, ?, ?, ?)
    ''',
      [key, dir.toString(), name, expires],
    );
    if (_currentSize != null) {
      _currentSize = _currentSize! + data.length;
    }
    checkCacheIfRequired();
  }

  /// Find cache by key.
  /// If cache is expired, it will be deleted and return null.
  /// If cache is not found, it will return null.
  /// If cache is found, it will return the file, and update the expires time.
  Future<File?> findCache(String key) async {
    var res = _db.select(
      '''
      SELECT * FROM cache
      WHERE key = ?
    ''',
      [key],
    );
    if (res.isEmpty) {
      return null;
    }
    var row = res.first;
    var dir = row[1] as String;
    var name = row[2] as String;
    var expires = row[3] as int;
    var file = File('$cachePath/$dir/$name');
    var now = DateTime.now().millisecondsSinceEpoch;
    if (expires < now) {
      // expired
      _db.execute(
        '''
        DELETE FROM cache
        WHERE key = ?
      ''',
        [key],
      );
      if (await file.exists()) {
        await file.delete();
      }
      return null;
    }
    if (await file.exists()) {
      // update time
      var expires = now + 7 * 24 * 60 * 60 * 1000;
      _db.execute(
        '''
        UPDATE cache
        SET expires = ?
        WHERE key = ?
      ''',
        [expires, key],
      );
      return file;
    } else {
      _db.execute(
        '''
        DELETE FROM cache
        WHERE key = ?
      ''',
        [key],
      );
    }
    return null;
  }

  bool _isChecking = false;

  /// Check cache size and delete expired cache.
  /// Only check cache if current size is greater than limit size.
  void checkCacheIfRequired() {
    if (_currentSize != null && _currentSize! > _limitSize) {
      checkCache();
    }
  }

  /// Check cache size and delete expired cache.
  /// If current size is greater than limit size,
  /// delete cache until current size is less than limit size.
  Future<void> checkCache() async {
    if (_isChecking) {
      return;
    }
    _isChecking = true;
    var res = _db.select(
      '''
      SELECT * FROM cache
      WHERE expires < ?
    ''',
      [DateTime.now().millisecondsSinceEpoch],
    );
    for (var row in res) {
      var dir = row[1] as String;
      var name = row[2] as String;
      var file = File('$cachePath/$dir/$name');
      if (await file.exists()) {
        var size = await file.length();
        _currentSize = _currentSize! - size;
        await file.delete();
      }
    }
    if (res.isNotEmpty) {
      _db.execute(
        '''
      DELETE FROM cache
      WHERE expires < ?
    ''',
        [DateTime.now().millisecondsSinceEpoch],
      );
    }

    while (_currentSize != null && _currentSize! > _limitSize) {
      var res = _db.select('''
        SELECT * FROM cache
        ORDER BY expires ASC
        limit 10
      ''');
      if (res.isEmpty) {
        // There are many files unmanaged by the cache manager.
        // Clear all cache.
        await Directory(cachePath).delete(recursive: true);
        Directory(cachePath).createSync(recursive: true);
        break;
      }
      for (var row in res) {
        var key = row[0] as String;
        var dir = row[1] as String;
        var name = row[2] as String;
        var file = File('$cachePath/$dir/$name');
        if (await file.exists()) {
          var size = await file.length();
          await file.delete();
          _db.execute(
            '''
            DELETE FROM cache
            WHERE key = ?
          ''',
            [key],
          );
          _currentSize = _currentSize! - size;
          if (_currentSize! <= _limitSize) {
            break;
          }
        } else {
          _db.execute(
            '''
            DELETE FROM cache
            WHERE key = ?
          ''',
            [key],
          );
        }
      }
    }
    _isChecking = false;
  }

  /// Delete cache by key.
  Future<void> delete(String key) async {
    var res = _db.select(
      '''
      SELECT * FROM cache
      WHERE key = ?
    ''',
      [key],
    );
    if (res.isEmpty) {
      return;
    }
    var row = res.first;
    var dir = row[1] as String;
    var name = row[2] as String;
    var file = File('$cachePath/$dir/$name');
    var fileSize = 0;
    if (await file.exists()) {
      fileSize = await file.length();
      await file.delete();
    }
    _db.execute(
      '''
      DELETE FROM cache
      WHERE key = ?
    ''',
      [key],
    );
    if (_currentSize != null) {
      _currentSize = _currentSize! - fileSize;
    }
  }

  /// Deletes every cache entry whose key starts with [prefix], returning the
  /// number removed. Used to invalidate a scope of derived cache (e.g. all
  /// translated pages of one comic) without touching unrelated entries.
  Future<int> deleteByPrefix(String prefix) async {
    var rows = _db.select(
      '''
      SELECT key, dir, name FROM cache
      WHERE key LIKE ? ESCAPE '\\'
    ''',
      ['${_escapeLike(prefix)}%'],
    );
    var removed = 0;
    for (var row in rows) {
      var dir = row[1] as String;
      var name = row[2] as String;
      var file = File('$cachePath/$dir/$name');
      if (await file.exists()) {
        if (_currentSize != null) {
          _currentSize = _currentSize! - await file.length();
        }
        await file.delete();
      }
      removed++;
    }
    _db.execute(
      '''
      DELETE FROM cache
      WHERE key LIKE ? ESCAPE '\\'
    ''',
      ['${_escapeLike(prefix)}%'],
    );
    return removed;
  }

  /// Escapes LIKE wildcards so a prefix containing '%' or '_' matches literally.
  static String _escapeLike(String value) {
    return value
        .replaceAll('\\', '\\\\')
        .replaceAll('%', '\\%')
        .replaceAll('_', '\\_');
  }

  /// Delete all cache.
  Future<void> clear() async {
    await Directory(cachePath).delete(recursive: true);
    Directory(cachePath).createSync(recursive: true);
    _db.execute('''
      DELETE FROM cache
    ''');
    _currentSize = 0;
  }
}
