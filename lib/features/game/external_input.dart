import 'package:flutter/services.dart';

import '../../core/emulator/zx_bridge.dart';
import '../../core/emulator/zx_types.dart';
import '../../core/pad_config.dart';
import '../desktop/pc_keyboard.dart';

/// Teclado físico y mando externo (Bluetooth/USB) en el móvil.
///
/// Teclado: matriz del Spectrum por posición (mismo mapa que en Windows); las
/// flechas son el joystick de la configuración del juego (o los cursores en BASIC).
/// Mando: cruceta (y palanca izquierda, que Android entrega como cruceta) = direcciones;
/// A = fuego, B / X / Y = botones de color 2-4 según la configuración del juego
/// (incluido el salto); Select / Start = los botones Select-Start del juego (o
/// SPACE / ENTER si no tiene).
class ExternalInput {
  ExternalInput({
    required this.zx,
    required this.pad,
    required this.cursorsInsteadOfJoystick,
    required this.onJoystick,
  });

  final ZxBridge zx;

  /// Configuración del control del juego (se reasigna al cambiarla).
  PadConfig Function() pad;

  /// Sin juego (BASIC) las flechas del teclado son los cursores del Spectrum.
  final bool cursorsInsteadOfJoystick;

  /// Máscara de direcciones/fuego de las fuentes externas.
  final void Function(int mask) onJoystick;

  late final _keyboard = PcKeyboard(zx)..joystick = null;
  final Map<LogicalKeyboardKey, _Held> _held = {};
  int _mask = 0;

  static final _dirs = {
    LogicalKeyboardKey.arrowUp: ZxJoy.up,
    LogicalKeyboardKey.arrowDown: ZxJoy.down,
    LogicalKeyboardKey.arrowLeft: ZxJoy.left,
    LogicalKeyboardKey.arrowRight: ZxJoy.right,
  };

  static final _fireKeys = {
    LogicalKeyboardKey.gameButtonA,
    LogicalKeyboardKey.select, // centro de la cruceta
  };

  /// Botón del mando → botón de color de la botonera (índice 1 = amarillo…).
  static final _colourButtons = {
    LogicalKeyboardKey.gameButtonB: 1,
    LogicalKeyboardKey.gameButtonX: 2,
    LogicalKeyboardKey.gameButtonY: 3,
  };

  /// Procesa un evento; true si lo consumió.
  bool handle(KeyEvent e) {
    final key = e.logicalKey;
    final isGamepad = _fireKeys.contains(key) ||
        _colourButtons.containsKey(key) ||
        key == LogicalKeyboardKey.gameButtonStart ||
        key == LogicalKeyboardKey.gameButtonSelect;
    final dir = _dirs[key];
    if ((dir != null && cursorsInsteadOfJoystick) || (dir == null && !isGamepad)) {
      return _keyboard.handle(e); // con joystick = null, las flechas son cursores
    }

    if (e is KeyRepeatEvent) return true;
    if (e is KeyUpEvent) {
      final h = _held.remove(key);
      if (h == null) return false;
      _release(h);
      return true;
    }
    if (_held.containsKey(key)) return true;
    final h = _translate(key, dir);
    if (h == null) return false;
    _held[key] = h;
    if (h.code != null) zx.setKey(h.code!, true);
    _mask |= h.bits;
    onJoystick(_mask);
    return true;
  }

  _Held? _translate(LogicalKeyboardKey key, int? dir) {
    if (dir != null) return _Held(bits: dir);
    if (_fireKeys.contains(key)) return const _Held(bits: ZxJoy.fire);
    final p = pad();
    final i = _colourButtons[key];
    if (i != null) {
      if (i >= p.buttons) return null;
      if (i == p.jumpButton) return const _Held(bits: ZxJoy.up);
      return _Held(code: p.extra[i - 1]);
    }
    final sys = p.selectKeys;
    if (key == LogicalKeyboardKey.gameButtonSelect) {
      return _Held(code: sys.isNotEmpty ? sys[0] : PadConfig.defaultSystem[1]);
    }
    if (key == LogicalKeyboardKey.gameButtonStart) {
      return _Held(code: sys.length > 1 ? sys[1] : sys.isNotEmpty ? sys[0] : PadConfig.defaultSystem[0]);
    }
    return null;
  }

  void _release(_Held h) {
    if (h.code != null) zx.setKey(h.code!, false);
    _mask = 0;
    for (final o in _held.values) {
      _mask |= o.bits;
    }
    onJoystick(_mask);
  }

  /// Suelta todo (al abrir un panel, pausar o cambiar de controles).
  void releaseAll() {
    for (final h in _held.values) {
      if (h.code != null) zx.setKey(h.code!, false);
    }
    _held.clear();
    _mask = 0;
    _keyboard.releaseAll();
  }
}

class _Held {
  final int bits;
  final int? code;
  const _Held({this.bits = 0, this.code});
}
