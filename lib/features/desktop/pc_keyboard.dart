import 'package:flutter/services.dart';

import '../../core/emulator/zx_bridge.dart';
import '../../core/emulator/zx_types.dart';

/// Teclado físico del PC → matriz del Spectrum.
///
/// Por posición: letras, números (también el numérico), Enter, Espacio,
/// Shift = CAPS SHIFT y Ctrl = SYMBOL SHIFT. Retroceso = DELETE (CAPS+0) y
/// Esc = BREAK (CAPS+SPACE). Los signos de puntuación se toman por el carácter que
/// escribe la tecla (depende de la distribución del teclado) y se envían con
/// SYMBOL SHIFT, soltando CAPS si el Shift del PC estaba pulsado para escribirlos.
/// Flechas + Alt/Tab (fuego) = [joystick]; si es null, las flechas son los cursores
/// del Spectrum (CAPS+5..8).
///
/// Cada tecla del PC recuerda lo que pulsó, y la matriz se recalcula como la unión de
/// todo lo que está abajo: así una combinación nunca deja teclas pegadas.
class PcKeyboard {
  PcKeyboard(this.zx);

  final ZxBridge zx;
  JoyMapping? joystick = JoyMapping.kempston;

  final Map<PhysicalKeyboardKey, _Held> _held = {};
  Set<int> _matrix = {};
  int _kempston = 0;

  static final Map<PhysicalKeyboardKey, int> _positional = {
    PhysicalKeyboardKey.keyA: ZxKey.a, PhysicalKeyboardKey.keyB: ZxKey.b,
    PhysicalKeyboardKey.keyC: ZxKey.c, PhysicalKeyboardKey.keyD: ZxKey.d,
    PhysicalKeyboardKey.keyE: ZxKey.e, PhysicalKeyboardKey.keyF: ZxKey.f,
    PhysicalKeyboardKey.keyG: ZxKey.g, PhysicalKeyboardKey.keyH: ZxKey.h,
    PhysicalKeyboardKey.keyI: ZxKey.i, PhysicalKeyboardKey.keyJ: ZxKey.j,
    PhysicalKeyboardKey.keyK: ZxKey.k, PhysicalKeyboardKey.keyL: ZxKey.l,
    PhysicalKeyboardKey.keyM: ZxKey.m, PhysicalKeyboardKey.keyN: ZxKey.n,
    PhysicalKeyboardKey.keyO: ZxKey.o, PhysicalKeyboardKey.keyP: ZxKey.p,
    PhysicalKeyboardKey.keyQ: ZxKey.q, PhysicalKeyboardKey.keyR: ZxKey.r,
    PhysicalKeyboardKey.keyS: ZxKey.s, PhysicalKeyboardKey.keyT: ZxKey.t,
    PhysicalKeyboardKey.keyU: ZxKey.u, PhysicalKeyboardKey.keyV: ZxKey.v,
    PhysicalKeyboardKey.keyW: ZxKey.w, PhysicalKeyboardKey.keyX: ZxKey.x,
    PhysicalKeyboardKey.keyY: ZxKey.y, PhysicalKeyboardKey.keyZ: ZxKey.z,
    PhysicalKeyboardKey.digit0: ZxKey.k0, PhysicalKeyboardKey.digit1: ZxKey.k1,
    PhysicalKeyboardKey.digit2: ZxKey.k2, PhysicalKeyboardKey.digit3: ZxKey.k3,
    PhysicalKeyboardKey.digit4: ZxKey.k4, PhysicalKeyboardKey.digit5: ZxKey.k5,
    PhysicalKeyboardKey.digit6: ZxKey.k6, PhysicalKeyboardKey.digit7: ZxKey.k7,
    PhysicalKeyboardKey.digit8: ZxKey.k8, PhysicalKeyboardKey.digit9: ZxKey.k9,
    PhysicalKeyboardKey.numpad0: ZxKey.k0, PhysicalKeyboardKey.numpad1: ZxKey.k1,
    PhysicalKeyboardKey.numpad2: ZxKey.k2, PhysicalKeyboardKey.numpad3: ZxKey.k3,
    PhysicalKeyboardKey.numpad4: ZxKey.k4, PhysicalKeyboardKey.numpad5: ZxKey.k5,
    PhysicalKeyboardKey.numpad6: ZxKey.k6, PhysicalKeyboardKey.numpad7: ZxKey.k7,
    PhysicalKeyboardKey.numpad8: ZxKey.k8, PhysicalKeyboardKey.numpad9: ZxKey.k9,
    PhysicalKeyboardKey.enter: ZxKey.enter, PhysicalKeyboardKey.numpadEnter: ZxKey.enter,
    PhysicalKeyboardKey.space: ZxKey.space,
    PhysicalKeyboardKey.shiftLeft: ZxKey.caps, PhysicalKeyboardKey.shiftRight: ZxKey.caps,
    PhysicalKeyboardKey.controlLeft: ZxKey.sym, PhysicalKeyboardKey.controlRight: ZxKey.sym,
  };

  static final Map<PhysicalKeyboardKey, List<int>> _combos = {
    PhysicalKeyboardKey.backspace: const [ZxKey.caps, ZxKey.k0],
    PhysicalKeyboardKey.escape: const [ZxKey.caps, ZxKey.space],
  };

  static final Map<PhysicalKeyboardKey, int> _arrows = {
    PhysicalKeyboardKey.arrowUp: ZxJoy.up,
    PhysicalKeyboardKey.arrowDown: ZxJoy.down,
    PhysicalKeyboardKey.arrowLeft: ZxJoy.left,
    PhysicalKeyboardKey.arrowRight: ZxJoy.right,
  };

  static final Map<PhysicalKeyboardKey, int> _fire = {
    PhysicalKeyboardKey.altLeft: ZxJoy.fire,
    PhysicalKeyboardKey.altRight: ZxJoy.fire,
    PhysicalKeyboardKey.tab: ZxJoy.fire,
  };

  /// Cursores del Spectrum: CAPS SHIFT + 5 (←), 6 (↓), 7 (↑), 8 (→).
  static const Map<int, int> _cursor = {
    ZxJoy.left: ZxKey.k5,
    ZxJoy.down: ZxKey.k6,
    ZxJoy.up: ZxKey.k7,
    ZxJoy.right: ZxKey.k8,
  };

  /// Signos con SYMBOL SHIFT, por el carácter que produce la tecla del PC.
  static const Map<String, int> _symbols = {
    '!': ZxKey.k1, '@': ZxKey.k2, '#': ZxKey.k3, r'$': ZxKey.k4, '%': ZxKey.k5,
    '&': ZxKey.k6, "'": ZxKey.k7, '(': ZxKey.k8, ')': ZxKey.k9, '_': ZxKey.k0,
    '<': ZxKey.r, '>': ZxKey.t, ';': ZxKey.o, '"': ZxKey.p, '^': ZxKey.h,
    '-': ZxKey.j, '+': ZxKey.k, '=': ZxKey.l, ':': ZxKey.z, '£': ZxKey.x,
    '?': ZxKey.c, '/': ZxKey.v, '*': ZxKey.b, ',': ZxKey.n, '.': ZxKey.m,
  };

  /// Procesa un evento de teclado; devuelve true si lo consumió.
  bool handle(KeyEvent e) {
    final key = e.physicalKey;
    if (e is KeyRepeatEvent) return _held.containsKey(key);
    if (e is KeyUpEvent) {
      if (_held.remove(key) == null) return false;
      _apply();
      return true;
    }
    if (_held.containsKey(key)) return true;
    final held = _translate(e);
    if (held == null) return false;
    _held[key] = held;
    _apply();
    return true;
  }

  _Held? _translate(KeyEvent e) {
    final key = e.physicalKey;
    final pos = _positional[key];
    if (pos != null) return _Held(keys: [pos]);
    final combo = _combos[key];
    if (combo != null) return _Held(keys: combo);
    final dir = _arrows[key];
    if (dir != null) {
      return joystick == null ? _Held(keys: [ZxKey.caps, _cursor[dir]!]) : _Held(joy: dir);
    }
    final fire = _fire[key];
    if (fire != null) return joystick == null ? null : _Held(joy: fire);
    final sym = _symbols[e.character];
    if (sym != null) return _Held(keys: [ZxKey.sym, sym], noCaps: true);
    return null;
  }

  /// Suelta todo (al perder el foco la ventana no llegan los KeyUp).
  void releaseAll() {
    _held.clear();
    _apply();
  }

  void _apply() {
    final want = <int>{};
    var joy = 0;
    var noCaps = false;
    for (final h in _held.values) {
      want.addAll(h.keys);
      joy |= h.joy;
      noCaps |= h.noCaps;
    }
    final keys = joystick?.keys;
    if (keys != null) {
      const bits = [ZxJoy.up, ZxJoy.down, ZxJoy.left, ZxJoy.right, ZxJoy.fire];
      for (var i = 0; i < bits.length; i++) {
        if (joy & bits[i] != 0) want.add(keys[i]);
      }
    }
    if (noCaps) want.remove(ZxKey.caps);

    for (final k in _matrix.difference(want)) {
      zx.setKey(k, false);
    }
    for (final k in want.difference(_matrix)) {
      zx.setKey(k, true);
    }
    _matrix = want;

    final kempston = joystick == JoyMapping.kempston ? joy : 0;
    if (kempston != _kempston) {
      zx.setJoystick(kempston);
      _kempston = kempston;
    }
  }
}

class _Held {
  final List<int> keys;
  final int joy;
  final bool noCaps;
  const _Held({this.keys = const [], this.joy = 0, this.noCaps = false});
}
