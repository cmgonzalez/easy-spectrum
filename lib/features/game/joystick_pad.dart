import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../core/emulator/zx_types.dart';
import '../../core/l10n.dart';
import 'skin.dart';

/// Geometría medida sobre la imagen original del mando (art/, 1536×1024). El asset
/// es un recorte (145, 170)–(1500, 885) sin el marco, para agrandar los controles.
const _skin = SkinImage('assets/skin/joystick.jpg', 1355, 715, origin: Offset(145, 170));
const _dpadCenter = Offset(367, 508);
const _dpadArm = 107.0; // ancho de cada brazo de la cruz (bbox 206..528 / 3)
const _dpadReach = 270.0; // radio de toque (más generoso que el dibujo)
const _fireCenter = Offset(1163, 542);
const _fireRadius = 128.0; // tapa del botón
const _fireReach = 240.0;
const _lcd = Rect.fromLTRB(484, 752, 1038, 858);

/// Botones de colores → teclas 1-4 (las de los menús "1 teclado, 2 Kempston…").
const _buttons = <(Rect, int, String)>[
  (Rect.fromLTRB(813, 192, 949, 287), ZxKey.k1, '1'),
  (Rect.fromLTRB(962, 191, 1098, 287), ZxKey.k2, '2'),
  (Rect.fromLTRB(1110, 191, 1247, 287), ZxKey.k3, '3'),
  (Rect.fromLTRB(1259, 191, 1397, 287), ZxKey.k4, '4'),
];

enum _Zone { dpad, fire, key }

/// Mando dibujado con la imagen: cruceta roja (8 direcciones, se puede deslizar),
/// botón redondo = FUEGO, botones de colores = teclas 1-4 y la pantalla LCD
/// partida en ENTER | ESPACIO.
class JoystickPad extends StatefulWidget {
  final void Function(int mask) onJoystick;
  final void Function(int code, bool pressed) onKey;
  final bool haptics;

  const JoystickPad({
    super.key,
    required this.onJoystick,
    required this.onKey,
    this.haptics = true,
  });

  static double get aspectRatio => _skin.width / _skin.height;

  @override
  State<JoystickPad> createState() => _JoystickPadState();
}

class _JoystickPadState extends State<JoystickPad> {
  final Map<int, (_Zone, int)> _pointers = {}; // puntero → zona (+ tecla)
  int _dir = 0;
  bool _fire = false;
  final Set<int> _keysDown = {};

  void _emit() => widget.onJoystick(_dir | (_fire ? ZxJoy.fire : 0));

  static int _dirFor(Offset p) {
    final d = p - _dpadCenter;
    if (d.distance < 30) return 0;
    final a = math.atan2(d.dy, d.dx); // 0 = derecha, positivo hacia abajo
    final sector = ((a + math.pi) / (math.pi / 4) + 0.5).floor() % 8;
    const masks = [
      ZxJoy.left,
      ZxJoy.left | ZxJoy.up,
      ZxJoy.up,
      ZxJoy.up | ZxJoy.right,
      ZxJoy.right,
      ZxJoy.right | ZxJoy.down,
      ZxJoy.down,
      ZxJoy.down | ZxJoy.left,
    ];
    return masks[sector];
  }

  void _setDir(int dir) {
    if (dir == _dir) return;
    if (widget.haptics && dir != 0) HapticFeedback.selectionClick();
    setState(() => _dir = dir);
    _emit();
  }

  void _setFire(bool v) {
    if (v == _fire) return;
    if (widget.haptics && v) HapticFeedback.lightImpact();
    setState(() => _fire = v);
    _emit();
  }

  void _setKey(int code, bool v) {
    if (v && widget.haptics) HapticFeedback.selectionClick();
    setState(() => v ? _keysDown.add(code) : _keysDown.remove(code));
    widget.onKey(code, v);
  }

  (_Zone, int)? _zoneAt(Offset p) {
    if ((p - _dpadCenter).distance <= _dpadReach) return (_Zone.dpad, 0);
    if ((p - _fireCenter).distance <= _fireReach) return (_Zone.fire, 0);
    for (final (r, code, _) in _buttons) {
      if (r.inflate(18).contains(p)) return (_Zone.key, code);
    }
    if (_lcd.inflate(18).contains(p)) {
      return (_Zone.key, p.dx < _lcd.center.dx ? ZxKey.enter : ZxKey.space);
    }
    return null;
  }

  void _down(int id, Offset p) {
    final z = _zoneAt(p);
    if (z == null) return;
    _pointers[id] = z;
    switch (z.$1) {
      case _Zone.dpad:
        _setDir(_dirFor(p));
      case _Zone.fire:
        _setFire(true);
      case _Zone.key:
        _setKey(z.$2, true);
    }
  }

  void _move(int id, Offset p) {
    final z = _pointers[id];
    if (z != null && z.$1 == _Zone.dpad) _setDir(_dirFor(p));
  }

  void _up(int id) {
    final z = _pointers.remove(id);
    if (z == null) return;
    switch (z.$1) {
      case _Zone.dpad:
        _setDir(0);
      case _Zone.fire:
        _setFire(false);
      case _Zone.key:
        _setKey(z.$2, false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return SkinView(
      skin: _skin,
      onDown: _down,
      onMove: _move,
      onUp: _up,
      painter: _PadOverlay(
        dir: _dir,
        fire: _fire,
        keys: {..._keysDown},
        space: context.l10n.space,
      ),
    );
  }
}

class _PadOverlay extends SkinPainter {
  final int dir;
  final bool fire;
  final Set<int> keys;
  final String space;
  _PadOverlay({required this.dir, required this.fire, required this.keys, required this.space});

  static const _lcdInk = Color(0xFF263022);

  void _label(Canvas canvas, String text, Offset center, double size, Color color) {
    final tp = TextPainter(
      text: TextSpan(
        text: text,
        style: TextStyle(
          fontSize: size,
          fontWeight: FontWeight.w900,
          color: color,
          letterSpacing: size * 0.08,
          fontFamily: 'monospace',
        ),
      ),
      textDirection: TextDirection.ltr,
    )..layout();
    tp.paint(canvas, center - Offset(tp.width / 2, tp.height / 2));
  }

  @override
  void paintSkin(Canvas canvas) {
    final glow = Paint()..color = Colors.white.withValues(alpha: 0.35);

    // Cruceta: ilumina los brazos activos.
    const arm = _dpadArm;
    const reach = arm; // del centro de la cruz al centro de cada brazo (322 px / 3)
    void armGlow(int mask, Offset o) {
      if (dir & mask == 0) return;
      canvas.drawRRect(
          RRect.fromRectAndRadius(
              Rect.fromCenter(center: _dpadCenter + o, width: arm, height: arm),
              const Radius.circular(14)),
          glow);
    }

    armGlow(ZxJoy.up, const Offset(0, -reach));
    armGlow(ZxJoy.down, const Offset(0, reach));
    armGlow(ZxJoy.left, const Offset(-reach, 0));
    armGlow(ZxJoy.right, const Offset(reach, 0));

    // Fuego: hundido (más oscuro) con aro de color al pulsar.
    if (fire) {
      canvas.drawCircle(_fireCenter, _fireRadius, Paint()..color = Colors.black.withValues(alpha: 0.35));
      canvas.drawCircle(
          _fireCenter,
          _fireRadius + 6,
          Paint()
            ..style = PaintingStyle.stroke
            ..strokeWidth = 10
            ..color = const Color(0xFFE8322B));
    }

    // Botones de colores con su número.
    for (final (r, code, label) in _buttons) {
      if (keys.contains(code)) {
        canvas.drawRRect(RRect.fromRectAndRadius(r.deflate(8), const Radius.circular(14)), glow);
      }
      _label(canvas, label, r.center, 52, Colors.white.withValues(alpha: 0.9));
    }

    // LCD: ENTER | ESPACIO, con la mitad pulsada en negativo.
    final left = Rect.fromLTRB(_lcd.left, _lcd.top, _lcd.center.dx, _lcd.bottom);
    final right = Rect.fromLTRB(_lcd.center.dx, _lcd.top, _lcd.right, _lcd.bottom);
    final pressedLcd = Paint()..color = _lcdInk.withValues(alpha: 0.85);
    final enter = keys.contains(ZxKey.enter), spc = keys.contains(ZxKey.space);
    if (enter) canvas.drawRect(left.deflate(6), pressedLcd);
    if (spc) canvas.drawRect(right.deflate(6), pressedLcd);
    canvas.drawLine(Offset(_lcd.center.dx, _lcd.top + 14), Offset(_lcd.center.dx, _lcd.bottom - 14),
        Paint()
          ..color = _lcdInk.withValues(alpha: 0.6)
          ..strokeWidth = 4);
    const lcdLight = Color(0xFF9DAA8C);
    _label(canvas, 'ENTER', left.center, 46, enter ? lcdLight : _lcdInk);
    _label(canvas, space, right.center, 46, spc ? lcdLight : _lcdInk);
  }

  @override
  bool shouldRepaint(_PadOverlay old) =>
      old.scale != scale || old.dir != dir || old.fire != fire || !setEquals(old.keys, keys) || old.space != space;
}
