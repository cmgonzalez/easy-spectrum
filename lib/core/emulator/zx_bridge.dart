import 'dart:async';
import 'dart:ffi';
import 'dart:io';
import 'dart:ui' as ui;

import 'package:ffi/ffi.dart';
import 'package:flutter/services.dart';
import 'package:path_provider/path_provider.dart';

import 'zx_types.dart';

// ---------------------------------------------------------------------------
// Firmas nativas (native/zx_bridge.h)
// ---------------------------------------------------------------------------

typedef _CreateN = Pointer<Void> Function(
    Pointer<Utf8> romDir, Int32 model, Pointer<Utf8> media, Int32 freq);
typedef _Create = Pointer<Void> Function(
    Pointer<Utf8> romDir, int model, Pointer<Utf8> media, int freq);

typedef _LastErrorN = Pointer<Utf8> Function();
typedef _VoidHN = Void Function(Pointer<Void> h);
typedef _VoidH = void Function(Pointer<Void> h);
typedef _RunN = Int32 Function(Pointer<Void> h, Double seconds);
typedef _Run = int Function(Pointer<Void> h, double seconds);
typedef _FbN = Pointer<Uint8> Function(Pointer<Void> h);
typedef _SetKeyN = Void Function(Pointer<Void> h, Int32 key, Int32 pressed);
typedef _SetKey = void Function(Pointer<Void> h, int key, int pressed);
typedef _IntArgN = Void Function(Pointer<Void> h, Int32 v);
typedef _IntArg = void Function(Pointer<Void> h, int v);
typedef _IntRetN = Int32 Function(Pointer<Void> h);
typedef _IntRet = int Function(Pointer<Void> h);
typedef _AudioN = Int32 Function(Pointer<Void> h, Pointer<Int16> out, Int32 max);
typedef _Audio = int Function(Pointer<Void> h, Pointer<Int16> out, int max);
typedef _TypeN = Void Function(Pointer<Void> h, Pointer<Utf8> text);
typedef _Type = void Function(Pointer<Void> h, Pointer<Utf8> text);
typedef _SpeedN = Void Function(Pointer<Void> h, Double m);
typedef _Speed = void Function(Pointer<Void> h, double m);

/// Puente dart:ffi → libzx_bridge.so (core Clock Signal).
class ZxBridge {
  ZxBridge._() {
    final lib = Platform.isAndroid
        ? DynamicLibrary.open('libzx_bridge.so')
        : DynamicLibrary.process();
    _create = lib.lookupFunction<_CreateN, _Create>('zx_create');
    _lastError = lib.lookupFunction<_LastErrorN, _LastErrorN>('zx_last_error');
    _destroy = lib.lookupFunction<_VoidHN, _VoidH>('zx_destroy');
    _run = lib.lookupFunction<_RunN, _Run>('zx_run');
    _fb = lib.lookupFunction<_FbN, _FbN>('zx_get_framebuffer');
    _setKey = lib.lookupFunction<_SetKeyN, _SetKey>('zx_set_key');
    _clearKeys = lib.lookupFunction<_VoidHN, _VoidH>('zx_clear_keys');
    _type = lib.lookupFunction<_TypeN, _Type>('zx_type');
    _setJoy = lib.lookupFunction<_IntArgN, _IntArg>('zx_set_joystick');
    _audio = lib.lookupFunction<_AudioN, _Audio>('zx_get_audio');
    _reset = lib.lookupFunction<_VoidHN, _VoidH>('zx_reset');
    _setTape = lib.lookupFunction<_IntArgN, _IntArg>('zx_set_tape_playing');
    _getTape = lib.lookupFunction<_IntRetN, _IntRet>('zx_get_tape_playing');
    _setQuick = lib.lookupFunction<_IntArgN, _IntArg>('zx_set_quickload');
    _setSpeed = lib.lookupFunction<_SpeedN, _Speed>('zx_set_speed');
    _isTurbo = lib.lookupFunction<_IntRetN, _IntRet>('zx_is_turbo');
  }

  static final ZxBridge instance = ZxBridge._();

  late final _Create _create;
  late final _LastErrorN _lastError;
  late final _VoidH _destroy;
  late final _Run _run;
  late final _FbN _fb;
  late final _SetKey _setKey;
  late final _VoidH _clearKeys;
  late final _Type _type;
  late final _IntArg _setJoy;
  late final _Audio _audio;
  late final _VoidH _reset;
  late final _IntArg _setTape;
  late final _IntRet _getTape;
  late final _IntArg _setQuick;
  late final _Speed _setSpeed;
  late final _IntRet _isTurbo;

  Pointer<Void> _h = nullptr;
  Pointer<Int16>? _audioBuf;
  static const _audioBufLen = 16384;
  String? _romDir;

  bool get isRunning => _h != nullptr;

  /// Copia las ROMs de assets a una carpeta local (el core las lee por ruta).
  Future<String> _ensureRoms() async {
    if (_romDir != null) return _romDir!;
    final dir = Directory('${(await getApplicationSupportDirectory()).path}/roms');
    await dir.create(recursive: true);
    for (final name in ['48.rom', '128.rom', 'plus2.rom', 'plus3.rom']) {
      final f = File('${dir.path}/$name');
      if (!await f.exists()) {
        final data = await rootBundle.load('assets/roms/$name');
        await f.writeAsBytes(data.buffer.asUint8List(), flush: true);
      }
    }
    return _romDir = dir.path;
  }

  /// Arranca una máquina nueva. [mediaPath] vacío = BASIC.
  /// Devuelve null si todo bien, o el mensaje de error.
  Future<String?> start({
    required ZxModel model,
    String mediaPath = '',
    required int audioFreq,
    bool quickLoad = true,
  }) async {
    dispose();
    final romDir = await _ensureRoms();
    final pRom = romDir.toNativeUtf8();
    final pMedia = mediaPath.toNativeUtf8();
    try {
      _h = _create(pRom, model.index, pMedia, audioFreq);
    } finally {
      calloc.free(pRom);
      calloc.free(pMedia);
    }
    if (_h == nullptr) return _lastError().toDartString();
    if (!quickLoad) _setQuick(_h, 0);
    return null;
  }

  /// Avanza [seconds] de tiempo real; devuelve frames completados.
  int run(double seconds) => isRunning ? _run(_h, seconds) : 0;

  /// Frame actual como imagen lista para pintar.
  Future<ui.Image?> frame() {
    if (!isRunning) return Future.value(null);
    final ptr = _fb(_h);
    if (ptr == nullptr) return Future.value(null);
    final bytes = Uint8List.fromList(ptr.asTypedList(zxFbWidth * zxFbHeight * 4));
    final c = Completer<ui.Image>();
    ui.decodeImageFromPixels(
        bytes, zxFbWidth, zxFbHeight, ui.PixelFormat.rgba8888, c.complete);
    return c.future;
  }

  // El ROM lee el teclado una vez por frame (20 ms): un toque más corto que eso
  // se pierde. Cada tecla queda pulsada al menos [_minHold].
  static const _minHold = Duration(milliseconds: 60);
  final Map<int, DateTime> _pressedAt = {};
  final Map<int, Timer> _pendingRelease = {};

  void setKey(int key, bool pressed) {
    if (!isRunning) return;
    _pendingRelease.remove(key)?.cancel();
    if (pressed) {
      _pressedAt[key] = DateTime.now();
      _setKey(_h, key, 1);
      return;
    }
    final since = DateTime.now().difference(_pressedAt.remove(key) ?? DateTime(0));
    if (since >= _minHold) {
      _setKey(_h, key, 0);
    } else {
      _pendingRelease[key] = Timer(_minHold - since, () {
        _pendingRelease.remove(key);
        if (isRunning) _setKey(_h, key, 0);
      });
    }
  }

  void clearKeys() {
    for (final t in _pendingRelease.values) {
      t.cancel();
    }
    _pendingRelease.clear();
    _pressedAt.clear();
    if (isRunning) _clearKeys(_h);
  }

  void typeText(String text) {
    if (!isRunning) return;
    final p = text.toNativeUtf8();
    _type(_h, p);
    calloc.free(p);
  }

  void setJoystick(int mask) {
    if (isRunning) _setJoy(_h, mask);
  }

  /// Audio pendiente como PCM s16le estéreo (bytes), o null si no hay.
  Uint8List? drainAudio() {
    if (!isRunning) return null;
    final buf = _audioBuf ??= calloc<Int16>(_audioBufLen);
    final n = _audio(_h, buf, _audioBufLen);
    if (n <= 0) return null;
    return Uint8List.fromList(buf.cast<Uint8>().asTypedList(n * 2));
  }

  void reset() {
    if (isRunning) _reset(_h);
  }

  bool get tapePlaying => isRunning && _getTape(_h) != 0;
  set tapePlaying(bool v) {
    if (isRunning) _setTape(_h, v ? 1 : 0);
  }

  /// true mientras la cinta carga en turbo (emulación acelerada y sin sonido).
  bool get turbo => isRunning && _isTurbo(_h) != 0;

  void setSpeed(double multiplier) {
    if (isRunning) _setSpeed(_h, multiplier);
  }

  void dispose() {
    clearKeys();
    if (_h != nullptr) _destroy(_h);
    _h = nullptr;
  }
}
