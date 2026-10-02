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
typedef _Int2N = Void Function(Pointer<Void> h, Int32 a, Int32 b);
typedef _Int2 = void Function(Pointer<Void> h, int a, int b);
typedef _IntArg = void Function(Pointer<Void> h, int v);
typedef _IntRetN = Int32 Function(Pointer<Void> h);
typedef _IntRet = int Function(Pointer<Void> h);
typedef _AudioN = Int32 Function(Pointer<Void> h, Pointer<Int16> out, Int32 max);
typedef _Audio = int Function(Pointer<Void> h, Pointer<Int16> out, int max);
typedef _TypeN = Void Function(Pointer<Void> h, Pointer<Utf8> text);
typedef _Type = void Function(Pointer<Void> h, Pointer<Utf8> text);
typedef _PdpStartN = Int32 Function(Pointer<Void> h, Int32 port);
typedef _PdpStart = int Function(Pointer<Void> h, int port);
typedef _SpeedN = Void Function(Pointer<Void> h, Double m);
typedef _Speed = void Function(Pointer<Void> h, double m);
typedef _PathN = Int32 Function(Pointer<Void> h, Pointer<Utf8> path);
typedef _Path = int Function(Pointer<Void> h, Pointer<Utf8> path);
typedef _IntIntN = Int32 Function(Pointer<Void> h, Int32 v);
typedef _IntInt = int Function(Pointer<Void> h, int v);
typedef _TapeInfoN = Int32 Function(Pointer<Void> h, Pointer<Int32> block, Pointer<Int32> total);
typedef _TapeInfo = int Function(Pointer<Void> h, Pointer<Int32> block, Pointer<Int32> total);
typedef _TakeN = Int32 Function(Pointer<Void> h, Pointer<Uint8> out, Int32 max);
typedef _Take = int Function(Pointer<Void> h, Pointer<Uint8> out, int max);

/// Estado de la cinta insertada (`zx_tape_info`, gestor de cintas).
class ZxTapeInfo {
  static const inserted = 1 << 0, playing = 1 << 1, end = 1 << 2, paused = 1 << 3, recording = 1 << 4;
  final int flags;
  /// Bloque que suena (== [total] al terminar la cinta).
  final int block;
  final int total;
  const ZxTapeInfo(this.flags, this.block, this.total);
  static const none = ZxTapeInfo(0, 0, 0);

  bool get hasTape => flags & inserted != 0;
  bool get isPlaying => flags & playing != 0;
  bool get atEnd => flags & end != 0;
  bool get isPaused => flags & paused != 0;
  bool get isRecording => flags & recording != 0;

  @override
  bool operator ==(Object other) =>
      other is ZxTapeInfo && other.flags == flags && other.block == block && other.total == total;
  @override
  int get hashCode => Object.hash(flags, block, total);
}

/// Puente dart:ffi → libzx_bridge.so / zx_bridge.dll (core Clock Signal).
class ZxBridge {
  ZxBridge._() {
    final lib = Platform.isAndroid
        ? DynamicLibrary.open('libzx_bridge.so')
        : Platform.isWindows
            ? DynamicLibrary.open('zx_bridge.dll')
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
    _setMouseMode = lib.lookupFunction<_IntArgN, _IntArg>('zx_set_mouse_mode');
    _mouseMove = lib.lookupFunction<_Int2N, _Int2>('zx_mouse_move');
    _mouseButtons = lib.lookupFunction<_IntArgN, _IntArg>('zx_mouse_buttons');
    _audio = lib.lookupFunction<_AudioN, _Audio>('zx_get_audio');
    _reset = lib.lookupFunction<_VoidHN, _VoidH>('zx_reset');
    _setTape = lib.lookupFunction<_IntArgN, _IntArg>('zx_set_tape_playing');
    _getTape = lib.lookupFunction<_IntRetN, _IntRet>('zx_get_tape_playing');
    _setQuick = lib.lookupFunction<_IntArgN, _IntArg>('zx_set_quickload');
    _setSpeed = lib.lookupFunction<_SpeedN, _Speed>('zx_set_speed');
    _isTurbo = lib.lookupFunction<_IntRetN, _IntRet>('zx_is_turbo');
    _getModel = lib.lookupFunction<_IntRetN, _IntRet>('zx_get_model');
    _isUla = lib.lookupFunction<_IntRetN, _IntRet>('zx_is_ulaplus');
    _setGiga = lib.lookupFunction<_IntArgN, _IntArg>('zx_set_gigascreen');
    _pdpStart = lib.lookupFunction<_PdpStartN, _PdpStart>('zx_pdp_start');
    _tapeInsert = lib.lookupFunction<_PathN, _Path>('zx_tape_insert');
    _tapeEject = lib.lookupFunction<_VoidHN, _VoidH>('zx_tape_eject');
    _tapeSeek = lib.lookupFunction<_IntIntN, _IntInt>('zx_tape_seek');
    _tapeInfo = lib.lookupFunction<_TapeInfoN, _TapeInfo>('zx_tape_info');
    _tapePause = lib.lookupFunction<_IntArgN, _IntArg>('zx_tape_set_paused');
    _tapeRecord = lib.lookupFunction<_IntArgN, _IntArg>('zx_tape_record');
    _tapeTake = lib.lookupFunction<_TakeN, _Take>('zx_tape_take_recorded');
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
  late final _IntArg _setMouseMode;
  late final _Int2 _mouseMove;
  late final _IntArg _mouseButtons;
  int _mouseMode = 0;
  late final _Audio _audio;
  late final _VoidH _reset;
  late final _IntArg _setTape;
  late final _IntRet _getTape;
  late final _IntArg _setQuick;
  late final _Speed _setSpeed;
  late final _IntRet _isTurbo;
  late final _IntRet _getModel;
  late final _IntRet _isUla;
  late final _IntArg _setGiga;
  late final _PdpStart _pdpStart;
  late final _Path _tapeInsert;
  late final _VoidH _tapeEject;
  late final _IntInt _tapeSeek;
  late final _TapeInfo _tapeInfo;
  late final _IntArg _tapePause;
  late final _IntArg _tapeRecord;
  late final _Take _tapeTake;
  Pointer<Int32>? _infoBuf;

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
    if (_mouseMode != 0) _setMouseMode(_h, _mouseMode);
    if (!quickLoad) _setQuick(_h, 0);
    // Depurador PDP (doc/PDP.md): opt-in con EASYSPECTRUM_PDP_PORT (solo escritorio).
    final pdpPort = int.tryParse(Platform.environment['EASYSPECTRUM_PDP_PORT'] ?? '');
    if (pdpPort != null && (Platform.isWindows || Platform.isLinux || Platform.isMacOS)) {
      _pdpStart(_h, pdpPort);
    }
    return null;
  }

  /// Avanza [seconds] de tiempo real; devuelve frames completados.
  int run(double seconds) => isRunning ? _run(_h, seconds) : 0;

  /// Frame actual como imagen lista para pintar.
  Future<ui.Image?> frame() {
    final bytes = framebuffer();
    if (bytes == null) return Future.value(null);
    final c = Completer<ui.Image>();
    ui.decodeImageFromPixels(
        bytes, zxFbWidth, zxFbHeight, ui.PixelFormat.rgba8888, c.complete);
    return c.future;
  }

  /// Copia del framebuffer RGBA ([zxFbWidth]×[zxFbHeight]) del último frame completo.
  Uint8List? framebuffer() {
    if (!isRunning) return null;
    final ptr = _fb(_h);
    if (ptr == nullptr) return null;
    return Uint8List.fromList(ptr.asTypedList(zxFbWidth * zxFbHeight * 4));
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

  /// Ratón: 0 = ninguno, 1 = Kempston, 2 = AMX. Se recuerda y se reaplica al crear la
  /// máquina (cada máquina nueva empieza sin ratón).
  int get mouseMode => _mouseMode;
  set mouseMode(int mode) {
    _mouseMode = mode;
    if (isRunning) _setMouseMode(_h, mode);
  }

  /// Desplazamiento relativo del ratón (dy positivo = hacia abajo).
  void mouseMove(int dx, int dy) {
    if (isRunning && _mouseMode != 0 && (dx != 0 || dy != 0)) _mouseMove(_h, dx, dy);
  }

  /// Botones: bit 0 izquierdo, bit 1 derecho, bit 2 central.
  void mouseButtons(int mask) {
    if (isRunning && _mouseMode != 0) _mouseButtons(_h, mask);
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

  /// Modelo real de la máquina (ZX_MODEL_*: 0-5 como [ZxModel.index], 6 = Next).
  int get modelIndex => isRunning ? _getModel(_h) : 1;

  /// El programa activó la paleta ULAplus.
  bool get ulaplus => isRunning && _isUla(_h) != 0;

  /// true mientras la cinta carga en turbo (emulación acelerada y sin sonido).
  bool get turbo => isRunning && _isTurbo(_h) != 0;

  /// Gigascreen: cada frame se mezcla con el anterior (dos pantallas alternadas = más colores).
  void setGigascreen(bool enabled) {
    if (isRunning) _setGiga(_h, enabled ? 1 : 0);
  }

  void setQuickLoad(bool enabled) {
    if (isRunning) _setQuick(_h, enabled ? 1 : 0);
  }

  void setSpeed(double multiplier) {
    if (isRunning) _setSpeed(_h, multiplier);
  }

  // --- Gestor de cintas (doc/TAPE_MANAGER.md) ---

  /// Inserta una cinta (.tap .tzx .csw) con la máquina en marcha.
  bool tapeInsert(String path) {
    if (!isRunning) return false;
    final p = path.toNativeUtf8();
    try {
      return _tapeInsert(_h, p) != 0;
    } finally {
      calloc.free(p);
    }
  }

  void tapeEject() {
    if (isRunning) _tapeEject(_h);
  }

  /// Mueve la cinta al inicio del bloque [block] (0 = rebobinar).
  bool tapeSeek(int block) => isRunning && _tapeSeek(_h, block) != 0;

  ZxTapeInfo tapeInfo() {
    if (!isRunning) return ZxTapeInfo.none;
    final buf = _infoBuf ??= calloc<Int32>(2);
    final flags = _tapeInfo(_h, buf, buf + 1);
    return ZxTapeInfo(flags, buf[0], buf[1]);
  }

  /// Pausa: motor apagado y sin arranque automático (el cargador no la vuelve a arrancar).
  void tapePause(bool paused) {
    if (isRunning) _tapePause(_h, paused ? 1 : 0);
  }

  /// Grabación de los SAVE del ROM.
  void tapeRecord(bool enabled) {
    if (isRunning) _tapeRecord(_h, enabled ? 1 : 0);
  }

  /// Bloques grabados desde la última llamada, en formato .tap (vacío si no hay).
  Uint8List takeRecorded() {
    if (!isRunning) return Uint8List(0);
    final n = _tapeTake(_h, nullptr, 0);
    if (n <= 0) return Uint8List(0);
    final buf = calloc<Uint8>(n);
    try {
      final got = _tapeTake(_h, buf, n);
      return Uint8List.fromList(buf.asTypedList(got));
    } finally {
      calloc.free(buf);
    }
  }

  void dispose() {
    clearKeys();
    if (_h != nullptr) _destroy(_h);
    _h = nullptr;
  }
}
