import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter/scheduler.dart';

import '../../core/emulator/zx_types.dart';
import '../../core/haptics.dart';
import '../../core/l10n.dart';
import 'pad_config_sheet.dart';
import 'skin.dart';

/// Geometría medida sobre la imagen original del mando (art/, 1536×1024). El asset lo
/// genera tools/make_skins.py: contenido sin el relleno entre marco y controles y un
/// marco redibujado con el relieve original; empieza en (121, 146) de la original.
const _skin = SkinImage('assets/skin/joystick.jpg', 1393, 799, origin: Offset(121, 146));
const _dpadCenter = Offset(367, 508);
const _dpadArm = 107.0; // ancho de cada brazo de la cruz (bbox 206..528 / 3)
const _dpadReach = 270.0; // radio de toque (más generoso que el dibujo)
const _fireCenter = Offset(1163, 542);
const _fireRadius = 128.0; // tapa del botón
const _fireReach = 240.0;
const _lcd = Rect.fromLTRB(484, 752, 1038, 858);

/// Botones de colores = acciones del mando (ver [PadAction]).
const _buttons = <Rect>[
  Rect.fromLTRB(813, 192, 949, 287),
  Rect.fromLTRB(962, 191, 1098, 287),
  Rect.fromLTRB(1110, 191, 1247, 287),
  Rect.fromLTRB(1259, 191, 1397, 287),
];

/// Botones extra (hasta 3), en el hueco entre los pozos de la cruceta y del fuego
/// (x ≈ 567..963): 1 grande al centro, 2 lado a lado o 3 en triángulo. Se miran
/// antes que la cruceta y el fuego, cuyos radios de toque llegan hasta aquí.
List<(Offset, double)> _extraLayout(int n) => switch (n) {
      1 => const [(Offset(765, 525), 88.0)],
      2 => const [(Offset(683, 525), 74.0), (Offset(847, 525), 74.0)],
      3 => const [(Offset(688, 440), 70.0), (Offset(842, 440), 70.0), (Offset(765, 600), 70.0)],
      _ => const [],
    };

/// Acciones de los botones de colores, en orden: rojo, amarillo, verde, azul.
enum PadAction {
  config(Icons.sports_esports_rounded), // configurar el control
  settings(Icons.settings_rounded), // ajustes de la app
  keyboard(Icons.keyboard_rounded), // cambiar al teclado
  exit(Icons.format_list_bulleted_rounded); // volver a la lista

  const PadAction(this.icon);
  final IconData icon;
}

enum _Zone { dpad, fire, key, action }

/// Mando dibujado con la imagen: cruceta roja (8 direcciones, se puede deslizar),
/// botón redondo = FUEGO, botones de colores = [PadAction], botones extra con la
/// tecla que se les asignó y la pantalla LCD partida en ENTER | ESPACIO.
class JoystickPad extends StatefulWidget {
  final void Function(int mask) onJoystick;
  final void Function(int code, bool pressed) onKey;
  final void Function(PadAction action) onAction;
  final List<int> extraKeys;
  final bool haptics;
  /// Letrero que avanza por la pantalla LCD (juego, datos, control…).
  final String lcdText;

  const JoystickPad({
    super.key,
    required this.onJoystick,
    required this.onKey,
    required this.onAction,
    this.extraKeys = const [],
    this.haptics = true,
    this.lcdText = '',
  });

  static double get aspectRatio => _skin.width / _skin.height;

  @override
  State<JoystickPad> createState() => _JoystickPadState();
}

class _JoystickPadState extends State<JoystickPad> with SingleTickerProviderStateMixin {
  // Reloj del letrero del LCD: solo repinta esa capa, no reconstruye el mando.
  final _clock = ValueNotifier<double>(0);
  late final Ticker _ticker;

  @override
  void initState() {
    super.initState();
    _ticker = createTicker((d) => _clock.value = d.inMicroseconds / 1e6)..start();
  }

  @override
  void dispose() {
    _ticker.dispose();
    _clock.dispose();
    super.dispose();
  }

  final Map<int, (_Zone, int)> _pointers = {}; // puntero → zona (+ tecla / acción)
  int _dir = 0;
  bool _fire = false;
  final Set<int> _keysDown = {};
  final Set<int> _actionsDown = {};

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
    if (widget.haptics && dir != 0) Haptics.tick();
    setState(() => _dir = dir);
    _emit();
  }

  void _setFire(bool v) {
    if (v == _fire) return;
    if (widget.haptics && v) Haptics.press();
    setState(() => _fire = v);
    _emit();
  }

  void _setKey(int code, bool v) {
    if (v && widget.haptics) Haptics.press();
    setState(() => v ? _keysDown.add(code) : _keysDown.remove(code));
    widget.onKey(code, v);
  }

  (_Zone, int)? _zoneAt(Offset p) {
    final extras = _extraLayout(widget.extraKeys.length);
    for (var i = 0; i < extras.length; i++) {
      final (c, r) = extras[i];
      if ((p - c).distance <= r + 12) return (_Zone.key, widget.extraKeys[i]);
    }
    if ((p - _dpadCenter).distance <= _dpadReach) return (_Zone.dpad, 0);
    if ((p - _fireCenter).distance <= _fireReach) return (_Zone.fire, 0);
    for (var i = 0; i < _buttons.length; i++) {
      if (_buttons[i].inflate(18).contains(p)) return (_Zone.action, i);
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
      case _Zone.action:
        if (widget.haptics) Haptics.press();
        setState(() => _actionsDown.add(z.$2));
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
      case _Zone.action:
        // Al soltar: la acción puede abrir un panel o cambiar de pantalla.
        setState(() => _actionsDown.remove(z.$2));
        widget.onAction(PadAction.values[z.$2]);
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
        actions: {..._actionsDown},
        extras: [for (final k in widget.extraKeys) (k, zxKeyName(context, k))],
      ),
      foreground: _LcdPainter(
        clock: _clock,
        text: widget.lcdText,
        enter: _keysDown.contains(ZxKey.enter),
        space: _keysDown.contains(ZxKey.space),
        spaceLabel: context.l10n.space,
      ),
    );
  }
}

class _PadOverlay extends SkinPainter {
  final int dir;
  final bool fire;
  final Set<int> keys;
  final Set<int> actions;
  final List<(int, String)> extras; // (tecla, rótulo)
  _PadOverlay({
    required this.dir,
    required this.fire,
    required this.keys,
    required this.actions,
    required this.extras,
  });

  void _text(Canvas canvas, String text, Offset center, TextStyle style, {double? maxWidth}) {
    final tp = TextPainter(
      text: TextSpan(text: text, style: style),
      textDirection: TextDirection.ltr,
    )..layout();
    if (maxWidth != null && tp.width > maxWidth) {
      // Rótulos largos (ENTER, SPACE…): se encogen para caber en el botón.
      final k = maxWidth / tp.width;
      canvas.save();
      canvas.translate(center.dx, center.dy);
      canvas.scale(k);
      tp.paint(canvas, Offset(-tp.width / 2, -tp.height / 2));
      canvas.restore();
      return;
    }
    tp.paint(canvas, center - Offset(tp.width / 2, tp.height / 2));
  }

  void _label(Canvas canvas, String text, Offset center, double size, Color color, {double? maxWidth}) =>
      _text(
          canvas,
          text,
          center,
          TextStyle(
            fontSize: size,
            fontWeight: FontWeight.w900,
            color: color,
            letterSpacing: size * 0.08,
            fontFamily: 'monospace',
          ),
          maxWidth: maxWidth);

  void _icon(Canvas canvas, IconData icon, Offset center, double size, Color color) => _text(
        canvas,
        String.fromCharCode(icon.codePoint),
        center,
        TextStyle(
          fontSize: size,
          color: color,
          fontFamily: icon.fontFamily,
          package: icon.fontPackage,
          height: 1,
        ),
      );

  /// Botón extra: redondo y oscuro como el de fuego, con la tecla escrita.
  void _extraButton(Canvas canvas, Offset c, double r, String label, bool pressed) {
    canvas.drawCircle(c + const Offset(0, 6), r + 4, Paint()..color = Colors.black.withValues(alpha: 0.55));
    canvas.drawCircle(c, r + 6, Paint()..color = const Color(0xFF141517));
    canvas.drawCircle(
      c,
      r,
      Paint()
        ..shader = RadialGradient(
          center: const Alignment(-0.3, -0.4),
          colors: pressed
              ? const [Color(0xFF2A2D31), Color(0xFF16181A)]
              : const [Color(0xFF55595F), Color(0xFF2A2C30)],
        ).createShader(Rect.fromCircle(center: c, radius: r)),
    );
    if (pressed) {
      canvas.drawCircle(
          c,
          r + 3,
          Paint()
            ..style = PaintingStyle.stroke
            ..strokeWidth = 8
            ..color = const Color(0xFF00C8D8));
    }
    _label(canvas, label, c, r * 0.72, Colors.white.withValues(alpha: 0.92), maxWidth: r * 1.6);
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

    // Botones de colores con el ícono de su acción.
    for (var i = 0; i < _buttons.length; i++) {
      final r = _buttons[i];
      if (actions.contains(i)) {
        canvas.drawRRect(RRect.fromRectAndRadius(r.deflate(8), const Radius.circular(14)), glow);
      }
      _icon(canvas, PadAction.values[i].icon, r.center, 64, Colors.white.withValues(alpha: 0.92));
    }

    // Botones extra.
    final layout = _extraLayout(extras.length);
    for (var i = 0; i < extras.length; i++) {
      _extraButton(canvas, layout[i].$1, layout[i].$2, extras[i].$2, keys.contains(extras[i].$1));
    }
  }

  @override
  bool shouldRepaint(_PadOverlay old) =>
      geometryChanged(old) ||
      old.dir != dir ||
      old.fire != fire ||
      !setEquals(old.keys, keys) ||
      !setEquals(old.actions, actions) ||
      old.extras.length != extras.length ||
      !Iterable.generate(extras.length).every((i) => old.extras[i] == extras[i]);
}

/// Pantalla LCD: letrero que avanza en bucle y, al pulsar una mitad, ENTER o
/// ESPACIO en negativo. Se repinta con [clock] (segundos).
class _LcdPainter extends SkinPainter {
  final ValueNotifier<double> clock;
  final String text;
  final bool enter;
  final bool space;
  final String spaceLabel;
  _LcdPainter({
    required this.clock,
    required this.text,
    required this.enter,
    required this.space,
    required this.spaceLabel,
  }) : super(repaint: clock);

  static const _ink = Color(0xFF263022);
  static const _light = Color(0xFF9DAA8C);
  static const _speed = 110.0; // px de la imagen por segundo
  static const _gap = 160.0; // entre el final del texto y la vuelta a empezar

  // El TextPainter del letrero se reutiliza entre fotogramas.
  static String? _cachedText;
  static TextPainter? _cached;

  static TextPainter _paintText(String text, double size, Color color) => TextPainter(
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

  @override
  void paintSkin(Canvas canvas) {
    final screen = _lcd.deflate(10);
    canvas.save();
    canvas.clipRect(screen);

    if (text.isNotEmpty) {
      final tp = _cachedText == text && _cached != null
          ? _cached!
          : (_cached = _paintText(text, 44, _ink.withValues(alpha: 0.9)));
      _cachedText = text;
      final y = screen.center.dy - tp.height / 2;
      if (tp.width <= screen.width) {
        tp.paint(canvas, Offset(screen.center.dx - tp.width / 2, y));
      } else {
        final period = tp.width + _gap;
        var x = screen.left + screen.width * 0.25 - (clock.value * _speed) % period;
        for (; x < screen.right; x += period) {
          tp.paint(canvas, Offset(x, y));
        }
      }
    }

    final halves = [
      (enter, Rect.fromLTRB(screen.left, screen.top, _lcd.center.dx, screen.bottom), 'ENTER'),
      (space, Rect.fromLTRB(_lcd.center.dx, screen.top, screen.right, screen.bottom), spaceLabel),
    ];
    for (final (on, r, label) in halves) {
      if (!on) continue;
      canvas.drawRect(r, Paint()..color = _ink.withValues(alpha: 0.92));
      final tp = _paintText(label.toUpperCase(), 46, _light);
      tp.paint(canvas, r.center - Offset(tp.width / 2, tp.height / 2));
    }
    canvas.restore();
  }

  @override
  bool shouldRepaint(_LcdPainter old) =>
      geometryChanged(old) || old.text != text || old.enter != enter || old.space != space;
}
