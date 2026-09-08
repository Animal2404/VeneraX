import 'dart:async';

import 'package:flutter/foundation.dart';

/// A mixin class that provides a way to ensure the class is initialized.
abstract mixin class Init {
  bool _isInit = false;

  /// Whether an initialization pass is already in flight.
  ///
  /// [ensureInit] used to only queue a waiter and depend on somebody else
  /// calling [init]. When nobody did, the returned future hung forever: the
  /// `--headless` entry point never runs the deferred init that normally kicks
  /// `ComicSourceManager` off, so `LocalManager.init()` awaited a waiter with
  /// no driver, `App.initComponents()` never returned, and the process sat
  /// there producing no output (plan D-14).
  bool _initStarted = false;

  final _initCompleter = <Completer<void>>[];

  /// Ensure the class is initialized, starting the initialization if needed.
  Future<void> ensureInit() async {
    if (_isInit) {
      return;
    }
    var completer = Completer<void>();
    _initCompleter.add(completer);
    _startInit();
    return completer.future;
  }

  void _startInit() {
    if (_isInit || _initStarted) return;
    _initStarted = true;
    unawaited(
      Future(() async {
        try {
          await doInit();
        } catch (e, s) {
          // A failed initialization must not leave the waiters hanging: hand
          // them the error and allow a later retry.
          _abandonInit();
          for (var completer in _initCompleter) {
            if (!completer.isCompleted) completer.completeError(e, s);
          }
          _initCompleter.clear();
          return;
        }
        await _markInit();
      }),
    );
  }

  void _abandonInit() {
    _isInit = false;
    _initStarted = false;
  }

  Future<void> _markInit() async {
    _isInit = true;
    _initStarted = false;
    for (var completer in _initCompleter) {
      completer.complete();
    }
    _initCompleter.clear();
  }

  @protected
  Future<void> doInit();

  /// Initialize the class.
  Future<void> init() async {
    if (_isInit) {
      return;
    }
    if (_initStarted) {
      // A pass is already running (typically started by [ensureInit]); wait
      // for it rather than running `doInit` a second time.
      return ensureInit();
    }
    _initStarted = true;
    try {
      await doInit();
    } catch (_) {
      _abandonInit();
      rethrow;
    }
    await _markInit();
  }
}
