import 'dart:convert';
import 'dart:ffi';
import 'dart:io';
import 'dart:typed_data';

import 'package:ffi/ffi.dart';
import 'ort_capabilities.dart';

part 'ort_api_indices.g.dart';

/// Error kinds for structured OrtFfiException.
enum OrtFfiErrorKind {
  epUnavailable,
  shapeMismatch,
  outOfMemory,
  deviceRemoved,
  invalidGraph,
  other,
}

/// Structured exception thrown on ONNX Runtime errors.
class OrtFfiException implements Exception {
  const OrtFfiException(this.message, this.kind);

  final String message;
  final OrtFfiErrorKind kind;

  static OrtFfiErrorKind classify(String message) {
    final lower = message.toLowerCase();
    // Order matters. A DirectML `Run` failure mentions `DmlExecutionProvider`,
    // which the broad 'provider' test below would label `epUnavailable` — and
    // an out-of-memory inside a provider would then be "fixable" by switching
    // providers instead of shrinking the batch. Genuine resource exhaustion is
    // decided first so the batch ladder gets the error it can actually act on.
    if (lower.contains('out of memory') ||
        lower.contains('e_outofmemory') ||
        lower.contains('failed to allocate') ||
        lower.contains('cuda out of memory') ||
        lower.contains('bad_alloc')) {
      return OrtFfiErrorKind.outOfMemory;
    }
    if (lower.contains('not registered') ||
        lower.contains('provider') ||
        lower.contains('does not implement') ||
        lower.contains('failed to load library') ||
        lower.contains('entry point not found') ||
        lower.contains('loadlibrary') ||
        lower.contains('no available device')) {
      return OrtFfiErrorKind.epUnavailable;
    }
    if (lower.contains('device side assert') ||
        lower.contains('device_removed') ||
        lower.contains('d3d_error') ||
        lower.contains('dxgi_error_device_removed') ||
        lower.contains('dxgi_error_device_reset')) {
      return OrtFfiErrorKind.deviceRemoved;
    }
    if (lower.contains('shape') ||
        lower.contains('dimension') ||
        lower.contains('mismatch') ||
        lower.contains('invalid rank')) {
      return OrtFfiErrorKind.shapeMismatch;
    }
    if (lower.contains('invalid graph') ||
        lower.contains('model is invalid') ||
        lower.contains('cannot deserialize')) {
      return OrtFfiErrorKind.invalidGraph;
    }
    return OrtFfiErrorKind.other;
  }

  @override
  String toString() => 'OrtFfiException($kind): $message';
}

/// Minimal, synchronous binding to the ONNX Runtime C API.
///
/// The runtime library itself is bundled by the flutter_onnxruntime plugin
/// or replaced with a GPU DirectML/CUDA build. This binding is only ever used inside
/// the translation worker isolate, where blocking is fine.
class OrtRuntime {
  OrtRuntime._(this._api, this._rawLib);

  static OrtRuntime? _instance;

  final Pointer<Pointer<Void>> _api;
  final DynamicLibrary _rawLib;

  static const _ortApiVersion = 16;

  // ONNXTensorElementDataType
  static const typeFloat32 = 1;
  static const typeUint8 = 2;
  static const typeInt32 = 6;
  static const typeInt64 = 7;
  static const typeString = 8;
  static const typeBool = 9;
  static const typeFloat16 = 10;
  static const typeBFloat16 = 16;

  static OrtRuntime open() {
    if (_instance != null) {
      return _instance!;
    }
    var lib = _openLibrary();
    var getApiBase = lib
        .lookupFunction<
          Pointer<Pointer<Void>> Function(),
          Pointer<Pointer<Void>> Function()
        >('OrtGetApiBase');
    var apiBase = getApiBase();
    var getApi = apiBase[0]
        .cast<
          NativeFunction<Pointer<Pointer<Void>> Function(Uint32)>
        >()
        .asFunction<Pointer<Pointer<Void>> Function(int)>();

    Pointer<Pointer<Void>> api = getApi(_ortApiVersion);
    if (api == nullptr) {
      // Fallback to version 15 or 14 if version 16 is unavailable
      for (final v in [15, 14]) {
        api = getApi(v);
        if (api != nullptr) break;
      }
    }

    if (api == nullptr) {
      throw const OrtFfiException(
        'ONNX Runtime API versions 14..16 unavailable',
        OrtFfiErrorKind.epUnavailable,
      );
    }
    return _instance = OrtRuntime._(api, lib);
  }

  static String runtimeVersion() {
    try {
      var lib = _openLibrary();
      var getApiBase = lib
          .lookupFunction<
            Pointer<Pointer<Void>> Function(),
            Pointer<Pointer<Void>> Function()
          >('OrtGetApiBase');
      var apiBase = getApiBase();
      var getVersionString = apiBase[1]
          .cast<NativeFunction<Pointer<Utf8> Function()>>()
          .asFunction<Pointer<Utf8> Function()>();
      return getVersionString().toDartString();
    } catch (e) {
      return 'unknown ($e)';
    }
  }

  bool hasExport(String name) {
    return _rawLib.providesSymbol(name);
  }

  static DynamicLibrary _openLibrary() {
    var candidates = <String Function()>[];
    if (Platform.isWindows) {
      // Direct attempt at executable directory first to avoid working directory drift
      try {
        final exeDir = File(Platform.resolvedExecutable).parent.path;
        final directPath = '$exeDir${Platform.pathSeparator}onnxruntime.dll';
        if (File(directPath).existsSync()) {
          candidates.add(() => directPath);
        }
      } catch (_) {}
      candidates.add(() => 'onnxruntime.dll');
    } else if (Platform.isAndroid) {
      candidates.add(() => 'libonnxruntime.so');
    } else if (Platform.isLinux) {
      candidates.add(() => 'libonnxruntime.so');
      candidates.add(() => 'libonnxruntime.so.1');
    } else {
      candidates.add(() => 'libonnxruntime.dylib');
    }
    Object? lastError;
    // On iOS/macOS the runtime may be statically linked into the process.
    try {
      var process = DynamicLibrary.process();
      if (process.providesSymbol('OrtGetApiBase')) {
        return process;
      }
    } catch (_) {}
    for (var candidate in candidates) {
      try {
        return DynamicLibrary.open(candidate());
      } catch (e) {
        lastError = e;
      }
    }
    throw OrtFfiException(
      'Failed to load ONNX Runtime library: $lastError',
      OrtFfiErrorKind.epUnavailable,
    );
  }

  late final _getErrorMessage = _api[OrtApiIdx.getErrorMessage]
      .cast<NativeFunction<Pointer<Utf8> Function(Pointer<Void>)>>()
      .asFunction<Pointer<Utf8> Function(Pointer<Void>)>();
  late final _releaseStatus = _releaser(OrtApiIdx.releaseStatus);

  void Function(Pointer<Void>) _releaser(int index) {
    return _api[index]
        .cast<NativeFunction<Void Function(Pointer<Void>)>>()
        .asFunction<void Function(Pointer<Void>)>();
  }

  /// Throws if [status] is an error; releases it either way.
  void _check(Pointer<Void> status) {
    if (status == nullptr) return;
    var message = _statusMessage(status);
    _releaseStatus(status);
    final kind = OrtFfiException.classify(message);
    throw OrtFfiException(message, kind);
  }

  /// Reads an OrtStatus message without letting the decoder hijack the error.
  ///
  /// `toDartString()` decoded strictly and threw `FormatException: Unexpected
  /// extension byte` on a driver-supplied error blob — so the real ONNX Runtime
  /// message was lost and every GPU failure surfaced as an unrelated decoding
  /// error (this is exactly what blocked diagnosing D-15). Scan to the
  /// terminator, then decode leniently.
  String _statusMessage(Pointer<Void> status) {
    final raw = _getErrorMessage(status).cast<Uint8>();
    if (raw == nullptr) return '(OrtStatus with no message)';
    var length = 0;
    while (length < 8192 && raw[length] != 0) {
      length++;
    }
    if (length == 0) return '(empty OrtStatus message)';
    try {
      return utf8.decode(raw.asTypedList(length), allowMalformed: true);
    } catch (_) {
      return String.fromCharCodes(raw.asTypedList(length));
    }
  }

  Pointer<Void>? _env;
  Pointer<Void>? _memoryInfo;
  Pointer<Void>? _allocator;

  Pointer<Void> get env {
    if (_env == null) {
      var createEnv = _api[OrtApiIdx.createEnv]
          .cast<
            NativeFunction<
              Pointer<Void> Function(
                Int32,
                Pointer<Utf8>,
                Pointer<Pointer<Void>>,
              )
            >
          >()
          .asFunction<
            Pointer<Void> Function(int, Pointer<Utf8>, Pointer<Pointer<Void>>)
          >();
      var out = calloc<Pointer<Void>>();
      var name = 'venera'.toNativeUtf8();
      try {
        _check(createEnv(3 /* ORT_LOGGING_LEVEL_ERROR */, name, out));
        _env = out.value;
      } finally {
        calloc.free(out);
        calloc.free(name);
      }
    }
    return _env!;
  }

  Pointer<Void> get memoryInfo {
    if (_memoryInfo == null) {
      var create = _api[OrtApiIdx.createCpuMemoryInfo]
          .cast<
            NativeFunction<
              Pointer<Void> Function(Int32, Int32, Pointer<Pointer<Void>>)
            >
          >()
          .asFunction<
            Pointer<Void> Function(int, int, Pointer<Pointer<Void>>)
          >();
      var out = calloc<Pointer<Void>>();
      try {
        _check(create(0 /* OrtDeviceAllocator */, 0 /* default */, out));
        _memoryInfo = out.value;
      } finally {
        calloc.free(out);
      }
    }
    return _memoryInfo!;
  }

  Pointer<Void> get allocator {
    if (_allocator == null) {
      var get = _api[OrtApiIdx.getAllocatorWithDefaultOptions]
          .cast<NativeFunction<Pointer<Void> Function(Pointer<Pointer<Void>>)>>()
          .asFunction<Pointer<Void> Function(Pointer<Pointer<Void>>)>();
      var out = calloc<Pointer<Void>>();
      try {
        _check(get(out));
        _allocator = out.value;
      } finally {
        calloc.free(out);
      }
    }
    return _allocator!;
  }

  void allocatorFree(Pointer<Void> p) {
    var free = _api[OrtApiIdx.allocatorFree]
        .cast<
          NativeFunction<Pointer<Void> Function(Pointer<Void>, Pointer<Void>)>
        >()
        .asFunction<Pointer<Void> Function(Pointer<Void>, Pointer<Void>)>();
    _check(free(allocator, p));
  }
}

/// Native memory arena for zero-copy tensor inputs and outputs.
class OrtTensorArena {
  OrtTensorArena({this.maxBytes = 256 * 1024 * 1024});

  final int maxBytes;
  Pointer<Float> _ptr = nullptr;
  int _capacityElements = 0;
  Float32List? _cachedView;

  int get capacityElements => _capacityElements;
  int get capacityBytes => _capacityElements * sizeOf<Float>();
  Pointer<Float> get basePtr => _ptr;

  Float32List get view {
    if (_ptr == nullptr || _cachedView == null) {
      ensure(0, 1024);
    }
    return _cachedView!;
  }

  Pointer<Float> pointerAt(int offset) {
    if (offset < 0 || offset > _capacityElements) {
      throw RangeError.range(offset, 0, _capacityElements);
    }
    return _ptr + offset;
  }

  /// Ensures capacity for at least [offset + count] float elements.
  /// Returns [offset].
  int ensure(int offset, int count) {
    final required = offset + count;
    if (required * sizeOf<Float>() > maxBytes) {
      throw OrtFfiException(
        'Arena allocation request ${required * 4} bytes exceeds maxBytes limit $maxBytes',
        OrtFfiErrorKind.outOfMemory,
      );
    }
    if (required > _capacityElements) {
      var newCap = _capacityElements == 0 ? 65536 : _capacityElements * 2;
      while (newCap < required) {
        newCap *= 2;
      }
      final newPtr = calloc<Float>(newCap);
      if (_ptr != nullptr) {
        if (offset > 0) {
          newPtr.asTypedList(newCap).setRange(0, offset, _cachedView!);
        }
        calloc.free(_ptr);
      }
      _ptr = newPtr;
      _capacityElements = newCap;
      _cachedView = _ptr.asTypedList(_capacityElements);
    }
    return offset;
  }

  void free() {
    if (_ptr != nullptr) {
      calloc.free(_ptr);
      _ptr = nullptr;
      _capacityElements = 0;
      _cachedView = null;
    }
  }
}

/// Description of an input tensor (Float32, Native Float32, Int64, or Float16).
sealed class OrtInput {
  const OrtInput();

  factory OrtInput.float32(Float32List data, List<int> shape) = _OrtInputF32Dart;
  factory OrtInput.nativeFloat32(Pointer<Float> ptr, int elementCount, List<int> shape) = _OrtInputF32Native;
  factory OrtInput.fromArena(OrtTensorArena arena, int offset, int elementCount, List<int> shape) =>
      OrtInput.nativeFloat32(arena.pointerAt(offset), elementCount, shape);
  factory OrtInput.int64(Int64List data, List<int> shape) = _OrtInputI64Dart;
  factory OrtInput.float16(Uint16List halfs, List<int> shape) = _OrtInputF16Dart;

  List<int> get shape;
  Float32List? get f32Data => null;
  Int64List? get i64Data => null;
}

class _OrtInputF32Dart extends OrtInput {
  const _OrtInputF32Dart(this.data, this.shape);
  final Float32List data;
  @override
  final List<int> shape;
  @override
  Float32List? get f32Data => data;
}

class _OrtInputF32Native extends OrtInput {
  const _OrtInputF32Native(this.ptr, this.elementCount, this.shape);
  final Pointer<Float> ptr;
  final int elementCount;
  @override
  final List<int> shape;
}

class _OrtInputI64Dart extends OrtInput {
  const _OrtInputI64Dart(this.data, this.shape);
  final Int64List data;
  @override
  final List<int> shape;
  @override
  Int64List? get i64Data => data;
}

class _OrtInputF16Dart extends OrtInput {
  const _OrtInputF16Dart(this.halfs, this.shape);
  final Uint16List halfs;
  @override
  final List<int> shape;
}

/// One inference output: float data plus its shape and element type.
class OrtOutput {
  OrtOutput(this.data, this.shape, {this.elementType = OrtRuntime.typeFloat32});

  final Float32List data;
  final List<int> shape;
  final int elementType;
}

/// Synchronous inference session. Only use inside a worker isolate.
class OrtFfiSession {
  OrtFfiSession._(
    this._rt,
    this._session,
    this.inputNames,
    this.outputNames,
    this.ep,
  );

  final OrtRuntime _rt;
  final Pointer<Void> _session;
  final List<String> inputNames;
  final List<String> outputNames;
  final OrtEpKind ep;

  /// Sink for the dict/model class-count check in [runArgmaxGrid] (D-11
  /// companion). Production wiring assigns a function with the same
  /// signature as `Log.warning` — that wiring lives in the worker bootstrap,
  /// not here, because this file must keep compiling under plain `dart run`
  /// (`tool/ort_ep_selfcheck.dart`): `package:venera/foundation/log.dart`
  /// pulls in `dart:ui` through `foundation/app.dart`. While the sink is
  /// unset, [warnClassMismatch] falls back to [print], which `flutter run`
  /// forwards from worker isolates and `flutter test` captures.
  static void Function(String title, String content)? classMismatchWarning;

  /// Routes one dict/model class-count warning to the configured sink, or to
  /// stdout when the app has not wired it yet. See [classMismatchWarning].
  static void warnClassMismatch(String message) {
    final sink = classMismatchWarning;
    if (sink != null) {
      sink('OCR Rec', message);
    } else {
      print('WARNING [OCR Rec] $message');
    }
  }

  static OrtFfiSession open(
    String modelPath, {
    required OrtEpKind ep,
    int? intraOpThreads,
  }) {
    var rt = OrtRuntime.open();
    var optionsOut = calloc<Pointer<Void>>();
    var sessionOut = calloc<Pointer<Void>>();
    Pointer<Void>? options;
    try {
      var createOptions = rt._api[OrtApiIdx.createSessionOptions]
          .cast<NativeFunction<Pointer<Void> Function(Pointer<Pointer<Void>>)>>()
          .asFunction<Pointer<Void> Function(Pointer<Pointer<Void>>)>();
      rt._check(createOptions(optionsOut));
      options = optionsOut.value;
      if (intraOpThreads != null) {
        var setThreads = rt._api[OrtApiIdx.setIntraOpNumThreads]
            .cast<
              NativeFunction<Pointer<Void> Function(Pointer<Void>, Int32)>
            >()
            .asFunction<Pointer<Void> Function(Pointer<Void>, int)>();
        rt._check(setThreads(options, intraOpThreads));
      }

      // EP Injection
      if (ep == OrtEpKind.directml) {
        if (rt.hasExport('OrtSessionOptionsAppendExecutionProvider_DML')) {
          var appendDml = rt._rawLib.lookupFunction<
            Pointer<Void> Function(Pointer<Void>, Int32),
            Pointer<Void> Function(Pointer<Void>, int)
          >('OrtSessionOptionsAppendExecutionProvider_DML');
          rt._check(appendDml(options, 0)); // device 0
        } else {
          throw const OrtFfiException(
            'DirectML export OrtSessionOptionsAppendExecutionProvider_DML not found in library',
            OrtFfiErrorKind.epUnavailable,
          );
        }

        // DirectML requirement: sequential execution mode and disable memory pattern
        var setMode = rt._api[OrtApiIdx.setSessionExecutionMode]
            .cast<NativeFunction<Pointer<Void> Function(Pointer<Void>, Int32)>>()
            .asFunction<Pointer<Void> Function(Pointer<Void>, int)>();
        rt._check(setMode(options, 0 /* ORT_SEQUENTIAL */));

        var disableMem = rt._api[OrtApiIdx.disableMemPattern]
            .cast<NativeFunction<Pointer<Void> Function(Pointer<Void>)>>()
            .asFunction<Pointer<Void> Function(Pointer<Void>)>();
        rt._check(disableMem(options));
      } else if (ep == OrtEpKind.cuda) {
        if (rt.hasExport('OrtSessionOptionsAppendExecutionProvider_CUDA')) {
          var appendCuda = rt._rawLib.lookupFunction<
            Pointer<Void> Function(Pointer<Void>, Int32),
            Pointer<Void> Function(Pointer<Void>, int)
          >('OrtSessionOptionsAppendExecutionProvider_CUDA');
          rt._check(appendCuda(options, 0));
        } else {
          throw const OrtFfiException(
            'CUDA export OrtSessionOptionsAppendExecutionProvider_CUDA not found in library',
            OrtFfiErrorKind.epUnavailable,
          );
        }
      }

      // ORTCHAR_T is wchar_t (UTF-16) on Windows and char (UTF-8) elsewhere.
      Pointer<Void> pathPtr;
      if (Platform.isWindows) {
        var units = modelPath.codeUnits;
        var p = calloc<Uint16>(units.length + 1);
        p.asTypedList(units.length + 1)
          ..setRange(0, units.length, units)
          ..[units.length] = 0;
        pathPtr = p.cast();
      } else {
        pathPtr = modelPath.toNativeUtf8().cast();
      }
      try {
        var createSession = rt._api[OrtApiIdx.createSession]
            .cast<
              NativeFunction<
                Pointer<Void> Function(
                  Pointer<Void>,
                  Pointer<Void>,
                  Pointer<Void>,
                  Pointer<Pointer<Void>>,
                )
              >
            >()
            .asFunction<
              Pointer<Void> Function(
                Pointer<Void>,
                Pointer<Void>,
                Pointer<Void>,
                Pointer<Pointer<Void>>,
              )
            >();
        rt._check(createSession(rt.env, pathPtr, options, sessionOut));
      } finally {
        calloc.free(pathPtr);
      }
      var session = sessionOut.value;
      var inputNames = _names(
        rt,
        session,
        OrtApiIdx.sessionGetInputCount,
        OrtApiIdx.sessionGetInputName,
      );
      var outputNames = _names(
        rt,
        session,
        OrtApiIdx.sessionGetOutputCount,
        OrtApiIdx.sessionGetOutputName,
      );
      final opened = OrtFfiSession._(rt, session, inputNames, outputNames, ep);
      liveSessions++;
      return opened;
    } finally {
      if (options != null) {
        rt._releaser(OrtApiIdx.releaseSessionOptions)(options);
      }
      calloc.free(optionsOut);
      calloc.free(sessionOut);
    }
  }

  static List<String> _names(
    OrtRuntime rt,
    Pointer<Void> session,
    int countIndex,
    int nameIndex,
  ) {
    var getCount = rt._api[countIndex]
        .cast<
          NativeFunction<
            Pointer<Void> Function(Pointer<Void>, Pointer<Size>)
          >
        >()
        .asFunction<Pointer<Void> Function(Pointer<Void>, Pointer<Size>)>();
    var getName = rt._api[nameIndex]
        .cast<
          NativeFunction<
            Pointer<Void> Function(
              Pointer<Void>,
              Size,
              Pointer<Void>,
              Pointer<Pointer<Utf8>>,
            )
          >
        >()
        .asFunction<
          Pointer<Void> Function(
            Pointer<Void>,
            int,
            Pointer<Void>,
            Pointer<Pointer<Utf8>>,
          )
        >();
    var countOut = calloc<Size>();
    var nameOut = calloc<Pointer<Utf8>>();
    try {
      rt._check(getCount(session, countOut));
      var names = <String>[];
      for (var i = 0; i < countOut.value; i++) {
        rt._check(getName(session, i, rt.allocator, nameOut));
        names.add(nameOut.value.toDartString());
        rt.allocatorFree(nameOut.value.cast());
      }
      return names;
    } finally {
      calloc.free(countOut);
      calloc.free(nameOut);
    }
  }

  /// Probes the input tensor shapes of the loaded session.
  /// Returns a map of input name to dimension sizes (-1 or 0 indicate dynamic).
  Map<String, List<int>> inputShapes() {
    var rt = _rt;
    var countOut = calloc<Size>();
    try {
      var getCount = rt._api[OrtApiIdx.sessionGetInputCount]
          .cast<NativeFunction<Pointer<Void> Function(Pointer<Void>, Pointer<Size>)>>()
          .asFunction<Pointer<Void> Function(Pointer<Void>, Pointer<Size>)>();
      rt._check(getCount(_session, countOut));
      var count = countOut.value;
      var shapes = <String, List<int>>{};

      for (var i = 0; i < count; i++) {
        var name = inputNames[i];
        var typeInfoOut = calloc<Pointer<Void>>();
        try {
          var getTypeInfo = rt._api[OrtApiIdx.sessionGetInputTypeInfo]
              .cast<NativeFunction<Pointer<Void> Function(Pointer<Void>, Size, Pointer<Pointer<Void>>)>>()
              .asFunction<Pointer<Void> Function(Pointer<Void>, int, Pointer<Pointer<Void>>)>();
          rt._check(getTypeInfo(_session, i, typeInfoOut));
          var typeInfo = typeInfoOut.value;

          var tensorInfoOut = calloc<Pointer<Void>>();
          try {
            var castToTensor = rt._api[OrtApiIdx.castTypeInfoToTensorInfo]
                .cast<NativeFunction<Pointer<Void> Function(Pointer<Void>, Pointer<Pointer<Void>>)>>()
                .asFunction<Pointer<Void> Function(Pointer<Void>, Pointer<Pointer<Void>>)>();
            rt._check(castToTensor(typeInfo, tensorInfoOut));
            var tensorInfo = tensorInfoOut.value;

            var dimCountOut = calloc<Size>();
            try {
              var getDimCount = rt._api[OrtApiIdx.getDimensionsCount]
                  .cast<NativeFunction<Pointer<Void> Function(Pointer<Void>, Pointer<Size>)>>()
                  .asFunction<Pointer<Void> Function(Pointer<Void>, Pointer<Size>)>();
              rt._check(getDimCount(tensorInfo, dimCountOut));
              var dims = calloc<Int64>(dimCountOut.value);
              try {
                var getDims = rt._api[OrtApiIdx.getDimensions]
                    .cast<NativeFunction<Pointer<Void> Function(Pointer<Void>, Pointer<Int64>, Size)>>()
                    .asFunction<Pointer<Void> Function(Pointer<Void>, Pointer<Int64>, int)>();
                rt._check(getDims(tensorInfo, dims, dimCountOut.value));
                shapes[name] = List<int>.generate(dimCountOut.value, (d) => dims[d]);
              } finally {
                calloc.free(dims);
              }
            } finally {
              calloc.free(dimCountOut);
            }
          } finally {
            calloc.free(tensorInfoOut);
          }
        } finally {
          if (typeInfoOut.value != nullptr) {
            rt._releaser(OrtApiIdx.releaseTypeInfo)(typeInfoOut.value);
          }
          calloc.free(typeInfoOut);
        }
      }
      return shapes;
    } finally {
      calloc.free(countOut);
    }
  }

  /// Runs the session. Returns outputs in [requestedOutputs] order (all
  /// outputs when null). Blocking; worker isolate only.
  Map<String, OrtOutput> run(
    Map<String, OrtInput> inputs, {
    List<String>? requestedOutputs,
  }) {
    var outputs = requestedOutputs ?? outputNames;
    return _execute(inputs, outputs, (values) {
      var result = <String, OrtOutput>{};
      for (var i = 0; i < outputs.length; i++) {
        result[outputs[i]] = _readOutput(values[i], outputs[i]);
      }
      return result;
    });
  }

  /// In-place access to native output tensor without copying full float arrays into Dart memory.
  T withNativeOutput<T>(
    Map<String, OrtInput> inputs,
    String outputName,
    T Function(Pointer<Float> ptr, List<int> shape, int elementCount) action,
  ) {
    return _execute(inputs, [outputName], (values) {
      var value = values[0];
      // D-11 gate: the callback below reinterprets the raw buffer as Float32,
      // as do runArgmaxGrid / runArgmaxLastPosition / runInPlace — all of
      // which delegate here. Refuse anything but fp32 before reading.
      _requireFloat32Output(value, outputName);
      var (shape, elementCount) = _readShape(value);
      var dataOut = calloc<Pointer<Void>>();
      try {
        var getData = _rt._api[OrtApiIdx.getTensorMutableData]
            .cast<
              NativeFunction<
                Pointer<Void> Function(Pointer<Void>, Pointer<Pointer<Void>>)
              >
            >()
            .asFunction<
              Pointer<Void> Function(Pointer<Void>, Pointer<Pointer<Void>>)
            >();
        _rt._check(getData(value, dataOut));
        return action(dataOut.value.cast<Float>(), shape, elementCount);
      } finally {
        calloc.free(dataOut);
      }
    });
  }

  /// Runs the session and returns the argmax at the last sequence position for each batch item.
  /// Output shape is [B, L, V].
  Int32List runArgmaxLastPosition(
    Map<String, OrtInput> inputs,
    String outputName, {
    required int batch,
    required int seqLen,
  }) {
    return withNativeOutput(inputs, outputName, (ptr, shape, elementCount) {
      final vocab = shape.last;
      final result = Int32List(batch);
      for (var b = 0; b < batch; b++) {
        final offset = ((b * seqLen) + (seqLen - 1)) * vocab;
        final row = ptr + offset;
        var best = 0;
        var bestScore = row[0];
        for (var v = 1; v < vocab; v++) {
          final score = row[v];
          if (score > bestScore) {
            bestScore = score;
            best = v;
          }
        }
        result[b] = best;
      }
      return result;
    });
  }

  /// Compatibility wrapper for batch=1 greedy decoding.
  int runArgmaxLastRow(Map<String, OrtInput> inputs, String outputName) {
    return runArgmaxLastPosition(inputs, outputName, batch: 1, seqLen: 1)[0];
  }

  /// Runs the session and computes argmax across the classes dimension for each step and batch item.
  /// [outputName] tensor shape is [B, T, C].
  Int32List runArgmaxGrid(
    Map<String, OrtInput> inputs,
    String outputName, {
    required int batch,
    required int steps,
    required int classes,
  }) {
    return withNativeOutput(inputs, outputName, (ptr, shape, elementCount) {
      final actualSteps = shape.length >= 2 ? shape[1] : steps;
      final actualClasses = shape.last;
      // The decoder collapses with charset[<index>], so a dict shorter or
      // longer than the model's class axis corrupts text without any native
      // error. [classes] exists exactly to catch that early. Decoding itself
      // keeps using actualClasses (the tensor is the ground truth).
      if (actualClasses != classes) {
        OrtFfiSession.warnClassMismatch(
          'runArgmaxGrid("$outputName"): model emits $actualClasses '
          'classes but the active dict has $classes rows',
        );
      }
      final total = batch * actualSteps;
      final result = Int32List(total);

      for (var b = 0; b < batch; b++) {
        final bOffset = b * actualSteps * actualClasses;
        final resOffset = b * actualSteps;
        for (var t = 0; t < actualSteps; t++) {
          final row = ptr + (bOffset + t * actualClasses);
          var best = 0;
          var bestScore = row[0];
          for (var c = 1; c < actualClasses; c++) {
            final score = row[c];
            if (score > bestScore) {
              bestScore = score;
              best = c;
            }
          }
          result[resOffset + t] = best;
        }
      }
      return result;
    });
  }

  /// Runs the session and writes output tensor data directly into [dst] arena at [offset].
  (List<int>, int) runInto(
    Map<String, OrtInput> inputs, {
    required String outputName,
    required OrtTensorArena dst,
    required int offset,
  }) {
    return withNativeOutput(inputs, outputName, (ptr, shape, elementCount) {
      dst.ensure(offset, elementCount);
      final dstPtr = dst.pointerAt(offset);
      dstPtr.asTypedList(elementCount).setRange(
            0,
            elementCount,
            ptr.asTypedList(elementCount),
          );
      return (shape, elementCount);
    });
  }

  /// In-place execution callback view.
  R runInPlace<R>(
    Map<String, OrtInput> inputs,
    String outputName,
    R Function(Pointer<Float> ptr, List<int> shape, int elementCount) action,
  ) =>
      withNativeOutput(inputs, outputName, action);

  T _execute<T>(
    Map<String, OrtInput> inputs,
    List<String> outputs,
    T Function(List<Pointer<Void>> outputValues) read,
  ) {
    var rt = _rt;
    var inputCount = inputs.length;
    var nativeBuffers = <Pointer<Void>>[];
    var inputValues = calloc<Pointer<Void>>(inputCount);
    var inputNamePtrs = calloc<Pointer<Utf8>>(inputCount);
    var outputNamePtrs = calloc<Pointer<Utf8>>(outputs.length);
    var outputValues = calloc<Pointer<Void>>(outputs.length);
    var utf8Names = <Pointer<Utf8>>[];
    try {
      var createTensor = rt._api[OrtApiIdx.createTensorWithDataAsOrtValue]
          .cast<
            NativeFunction<
              Pointer<Void> Function(
                Pointer<Void>, // memory info
                Pointer<Void>, // data
                Size, // data length in bytes
                Pointer<Int64>, // shape
                Size, // shape length
                Int32, // element type
                Pointer<Pointer<Void>>,
              )
            >
          >()
          .asFunction<
            Pointer<Void> Function(
              Pointer<Void>,
              Pointer<Void>,
              int,
              Pointer<Int64>,
              int,
              int,
              Pointer<Pointer<Void>>,
            )
          >();
      var index = 0;
      var valueOut = calloc<Pointer<Void>>();
      try {
        for (var entry in inputs.entries) {
          var input = entry.value;
          Pointer<Void> dataPtr;
          int byteLength;
          int elementType;

          if (input is _OrtInputF32Native) {
            dataPtr = input.ptr.cast();
            byteLength = input.elementCount * 4;
            elementType = OrtRuntime.typeFloat32;
          } else if (input is _OrtInputF16Dart) {
            var data = input.halfs;
            var p = calloc<Uint16>(data.length);
            p.asTypedList(data.length).setAll(0, data);
            dataPtr = p.cast();
            byteLength = data.length * 2;
            elementType = OrtRuntime.typeFloat16;
            nativeBuffers.add(dataPtr);
          } else if (input.f32Data != null) {
            var data = input.f32Data!;
            var p = calloc<Float>(data.length);
            p.asTypedList(data.length).setAll(0, data);
            dataPtr = p.cast();
            byteLength = data.length * 4;
            elementType = OrtRuntime.typeFloat32;
            nativeBuffers.add(dataPtr);
          } else {
            var data = input.i64Data!;
            var p = calloc<Int64>(data.length);
            p.asTypedList(data.length).setAll(0, data);
            dataPtr = p.cast();
            byteLength = data.length * 8;
            elementType = OrtRuntime.typeInt64;
            nativeBuffers.add(dataPtr);
          }

          var shapePtr = calloc<Int64>(input.shape.length);
          shapePtr
              .asTypedList(input.shape.length)
              .setAll(0, input.shape);
          nativeBuffers.add(shapePtr.cast());
          rt._check(
            createTensor(
              rt.memoryInfo,
              dataPtr,
              byteLength,
              shapePtr,
              input.shape.length,
              elementType,
              valueOut,
            ),
          );
          inputValues[index] = valueOut.value;
          var namePtr = entry.key.toNativeUtf8();
          utf8Names.add(namePtr);
          inputNamePtrs[index] = namePtr;
          index++;
        }
      } finally {
        calloc.free(valueOut);
      }
      for (var i = 0; i < outputs.length; i++) {
        var namePtr = outputs[i].toNativeUtf8();
        utf8Names.add(namePtr);
        outputNamePtrs[i] = namePtr;
        outputValues[i] = nullptr;
      }

      var runFn = rt._api[OrtApiIdx.run]
          .cast<
            NativeFunction<
              Pointer<Void> Function(
                Pointer<Void>, // session
                Pointer<Void>, // run options
                Pointer<Pointer<Utf8>>, // input names
                Pointer<Pointer<Void>>, // input values
                Size,
                Pointer<Pointer<Utf8>>, // output names
                Size,
                Pointer<Pointer<Void>>, // output values
              )
            >
          >()
          .asFunction<
            Pointer<Void> Function(
              Pointer<Void>,
              Pointer<Void>,
              Pointer<Pointer<Utf8>>,
              Pointer<Pointer<Void>>,
              int,
              Pointer<Pointer<Utf8>>,
              int,
              Pointer<Pointer<Void>>,
            )
          >();
      rt._check(
        runFn(
          _session,
          nullptr,
          inputNamePtrs,
          inputValues,
          inputCount,
          outputNamePtrs,
          outputs.length,
          outputValues,
        ),
      );

      return read([for (var i = 0; i < outputs.length; i++) outputValues[i]]);
    } finally {
      var releaseValue = rt._releaser(OrtApiIdx.releaseValue);
      for (var i = 0; i < inputCount; i++) {
        if (inputValues[i] != nullptr) releaseValue(inputValues[i]);
      }
      for (var i = 0; i < outputs.length; i++) {
        if (outputValues[i] != nullptr) releaseValue(outputValues[i]);
      }
      for (var p in nativeBuffers) {
        calloc.free(p);
      }
      for (var p in utf8Names) {
        calloc.free(p);
      }
      calloc.free(inputValues);
      calloc.free(inputNamePtrs);
      calloc.free(outputNamePtrs);
      calloc.free(outputValues);
    }
  }

  /// Reads the real ONNX element type of a tensor OrtValue.
  /// Returns an `ONNXTensorElementDataType` number (float32 == 1).
  int _tensorElementType(Pointer<Void> value) {
    var rt = _rt;
    var infoOut = calloc<Pointer<Void>>();
    Pointer<Void>? info;
    try {
      var getInfo = rt._api[OrtApiIdx.getTensorTypeAndShape]
          .cast<
            NativeFunction<
              Pointer<Void> Function(Pointer<Void>, Pointer<Pointer<Void>>)
            >
          >()
          .asFunction<
            Pointer<Void> Function(Pointer<Void>, Pointer<Pointer<Void>>)
          >();
      rt._check(getInfo(value, infoOut));
      info = infoOut.value;
      // GetTensorElementType(OrtTensorTypeAndShapeInfo*, ONNXTensorElementDataType*)
      // — a C enum, so 32-bit on every platform this binding targets.
      var typeOut = calloc<Int32>();
      try {
        var getElementType = rt._api[OrtApiIdx.getTensorElementType]
            .cast<
              NativeFunction<Pointer<Void> Function(Pointer<Void>, Pointer<Int32>)>
            >()
            .asFunction<Pointer<Void> Function(Pointer<Void>, Pointer<Int32>)>();
        rt._check(getElementType(info, typeOut));
        return typeOut.value;
      } finally {
        calloc.free(typeOut);
      }
    } finally {
      if (info != null) {
        rt._releaser(OrtApiIdx.releaseTensorTypeAndShapeInfo)(info);
      }
      calloc.free(infoOut);
    }
  }

  /// D-11: every output reader in this file reinterprets the OrtValue buffer
  /// as float32. A model exported *without* `keep_io_types` (fp16 or int64
  /// outputs) would then yield silently wrong numbers instead of failing, so
  /// each read path must call this first. The message carries the numeric
  /// ONNXTensorElementDataType, which is the whole diagnosis (e.g. 10 ==
  /// float16, 7 == int64, 1 == float32). Returns the checked type.
  int _requireFloat32Output(Pointer<Void> value, String name) {
    final t = _tensorElementType(value);
    if (t != OrtRuntime.typeFloat32) {
      throw OrtFfiException(
        'unexpected output dtype $t for $name',
        OrtFfiErrorKind.invalidGraph,
      );
    }
    return t;
  }

  /// Reads a tensor's shape and total element count.
  (List<int>, int) _readShape(Pointer<Void> value) {
    var rt = _rt;
    var infoOut = calloc<Pointer<Void>>();
    Pointer<Void>? info;
    try {
      var getInfo = rt._api[OrtApiIdx.getTensorTypeAndShape]
          .cast<
            NativeFunction<
              Pointer<Void> Function(Pointer<Void>, Pointer<Pointer<Void>>)
            >
          >()
          .asFunction<
            Pointer<Void> Function(Pointer<Void>, Pointer<Pointer<Void>>)
          >();
      rt._check(getInfo(value, infoOut));
      info = infoOut.value;

      var dimCountOut = calloc<Size>();
      var elementCountOut = calloc<Size>();
      try {
        var getDimCount = rt._api[OrtApiIdx.getDimensionsCount]
            .cast<
              NativeFunction<Pointer<Void> Function(Pointer<Void>, Pointer<Size>)>
            >()
            .asFunction<Pointer<Void> Function(Pointer<Void>, Pointer<Size>)>();
        rt._check(getDimCount(info, dimCountOut));
        var dims = calloc<Int64>(dimCountOut.value);
        try {
          var getDims = rt._api[OrtApiIdx.getDimensions]
              .cast<
                NativeFunction<
                  Pointer<Void> Function(Pointer<Void>, Pointer<Int64>, Size)
                >
              >()
              .asFunction<
                Pointer<Void> Function(Pointer<Void>, Pointer<Int64>, int)
              >();
          rt._check(getDims(info, dims, dimCountOut.value));
          var shape = List<int>.generate(dimCountOut.value, (i) => dims[i]);

          var getElementCount = rt
              ._api[OrtApiIdx.getTensorShapeElementCount]
              .cast<
                NativeFunction<Pointer<Void> Function(Pointer<Void>, Pointer<Size>)>
              >()
              .asFunction<Pointer<Void> Function(Pointer<Void>, Pointer<Size>)>();
          rt._check(getElementCount(info, elementCountOut));
          return (shape, elementCountOut.value);
        } finally {
          calloc.free(dims);
        }
      } finally {
        calloc.free(dimCountOut);
        calloc.free(elementCountOut);
      }
    } finally {
      if (info != null) {
        rt._releaser(OrtApiIdx.releaseTensorTypeAndShapeInfo)(info);
      }
      calloc.free(infoOut);
    }
  }

  OrtOutput _readOutput(Pointer<Void> value, String name) {
    var rt = _rt;
    // D-11: assert the real element type before casting the buffer to Float.
    final elementType = _requireFloat32Output(value, name);
    var (shape, elementCount) = _readShape(value);
    var dataOut = calloc<Pointer<Void>>();
    try {
      var getData = rt._api[OrtApiIdx.getTensorMutableData]
          .cast<
            NativeFunction<
              Pointer<Void> Function(Pointer<Void>, Pointer<Pointer<Void>>)
            >
          >()
          .asFunction<
            Pointer<Void> Function(Pointer<Void>, Pointer<Pointer<Void>>)
          >();
      rt._check(getData(value, dataOut));
      // Copy out: the OrtValue is released right after this call.
      var view = dataOut.value.cast<Float>().asTypedList(elementCount);
      return OrtOutput(
        Float32List.fromList(view),
        shape,
        elementType: elementType,
      );
    } finally {
      calloc.free(dataOut);
    }
  }

  /// Sessions currently open in this isolate's runtime. Reported by the
  /// diagnostics page and the baseline table; the number is only trustworthy
  /// because [close] is idempotent and every production path reaches it.
  static int liveSessions = 0;

  bool _closed = false;

  void close() {
    // Idempotent: the CPU-fallback path can reach close() twice for the same
    // handle, and a second ReleaseSession on a freed pointer is undefined
    // behaviour, not a harmless no-op.
    if (_closed) return;
    _closed = true;
    _rt._releaser(OrtApiIdx.releaseSession)(_session);
    if (liveSessions > 0) liveSessions--;
  }
}
