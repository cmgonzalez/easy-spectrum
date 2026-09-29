import 'package:flutter/material.dart';

import '../../core/emulator/zx_types.dart';
import '../../core/haptics.dart';
import '../../core/theme/easy_theme.dart';
import 'joystick_pad.dart' show PadAction;
import 'skin.dart';

/// Geometría medida sobre la imagen original del teclado (art/, 1536×959): bandas
/// verticales de cada fila y tramos horizontales de cada tecla. El asset lo genera
/// tools/make_skins.py: con la cabecera "sinclair ZX Spectrum" acortada (se quitan
/// 60 filas de plástico liso). Origen (0, 60): la placa coincide con la original y la
/// cabecera queda en y = 60..235 de estas coordenadas.
const _skin = SkinImage('assets/skin/keyboard.jpg', 1536, 899, origin: Offset(0, 60));

/// Botones de acción en el hueco de la cabecera, a la derecha del logo (mismos que
/// los botones de colores del mando: configurar, ajustes, mando, lista).
const _actionColours = [Color(0xFFE8322B), Color(0xFFF5C400), Color(0xFF1FBF3A), Color(0xFF12B5E8)];
final _actionRects = [
  for (var i = 0; i < 4; i++) Rect.fromLTWH(810 + i * 172.0, 92, 150, 104),
];

/// Ícono de cada acción en el teclado: el verde vuelve al mando.
IconData _actionIcon(PadAction a) => a == PadAction.keyboard ? Icons.sports_esports_rounded : a.icon;

const _rowBands = [(354.0, 421.0), (492.0, 560.0), (630.0, 698.0), (765.0, 837.0)];

const _rowKeys = <List<(double, double, int)>>[
  [
    (70, 162, ZxKey.k1), (200, 293, ZxKey.k2), (331, 424, ZxKey.k3), (462, 555, ZxKey.k4),
    (593, 689, ZxKey.k5), (728, 824, ZxKey.k6), (863, 959, ZxKey.k7), (998, 1095, ZxKey.k8),
    (1134, 1231, ZxKey.k9), (1270, 1365, ZxKey.k0),
  ],
  [
    (132, 227, ZxKey.q), (265, 359, ZxKey.w), (397, 492, ZxKey.e), (530, 626, ZxKey.r),
    (664, 760, ZxKey.t), (798, 893, ZxKey.y), (931, 1028, ZxKey.u), (1067, 1163, ZxKey.i),
    (1202, 1299, ZxKey.o), (1337, 1434, ZxKey.p),
  ],
  [
    (164, 260, ZxKey.a), (299, 394, ZxKey.s), (433, 529, ZxKey.d), (567, 662, ZxKey.f),
    (700, 796, ZxKey.g), (834, 929, ZxKey.h), (967, 1064, ZxKey.j), (1102, 1200, ZxKey.k),
    (1239, 1335, ZxKey.l), (1373, 1471, ZxKey.enter),
  ],
  [
    (56, 185, ZxKey.caps), (223, 320, ZxKey.z), (358, 455, ZxKey.x), (493, 591, ZxKey.c),
    (628, 727, ZxKey.v), (764, 863, ZxKey.b), (900, 999, ZxKey.n), (1037, 1136, ZxKey.m),
    (1174, 1275, ZxKey.sym), (1313, 1477, ZxKey.space),
  ],
];

/// Rectángulo (en coordenadas de la imagen) de cada tecla, para dibujar la pulsación.
final Map<int, Rect> _keyRects = {
  for (var r = 0; r < _rowKeys.length; r++)
    for (final (x0, x1, code) in _rowKeys[r])
      code: Rect.fromLTRB(x0, _rowBands[r].$1, x1, _rowBands[r].$2),
};

/// Tecla bajo un punto de la imagen. Cada fila ocupa hasta la mitad del hueco con
/// la vecina y, dentro de la fila, gana la tecla de centro más cercano: los
/// espacios entre teclas también cuentan (más fácil de acertar con el dedo).
int? _keyAt(Offset p) {
  const top = 250.0, bottom = 959.0; // la placa (arriba está la cabecera)
  if (p.dy < top || p.dy > bottom || p.dx < 30 || p.dx > 1500) return null;
  var row = _rowBands.length - 1;
  for (var r = 0; r < _rowBands.length - 1; r++) {
    if (p.dy < (_rowBands[r].$2 + _rowBands[r + 1].$1) / 2) {
      row = r;
      break;
    }
  }
  int? best;
  var bestDist = double.infinity;
  for (final (x0, x1, code) in _rowKeys[row]) {
    final d = (p.dx - (x0 + x1) / 2).abs();
    if (d < bestDist) {
      bestDist = d;
      best = code;
    }
  }
  return best;
}

/// Teclado del Spectrum 48K dibujado con la imagen real. Multitáctil: cada dedo
/// queda asociado a la tecla que tocó. CAPS SHIFT y SYMBOL SHIFT se fijan con un
/// toque y se sueltan solos tras la siguiente tecla (o se mantienen pulsados a la vez).
class ZxKeyboard extends StatefulWidget {
  final void Function(int code, bool pressed) onKey;
  final void Function(PadAction action) onAction;
  final bool haptics;
  const ZxKeyboard({super.key, required this.onKey, required this.onAction, this.haptics = true});

  @override
  State<ZxKeyboard> createState() => _ZxKeyboardState();
}

class _ZxKeyboardState extends State<ZxKeyboard> {
  final Map<int, int> _pointers = {}; // puntero → tecla
  final Map<int, int> _actionPointers = {}; // puntero → botón de acción
  final Set<int> _down = {};
  final Set<int> _latched = {};
  final Set<int> _modifierHeld = {};
  bool _usedWhileHeld = false;

  bool _isModifier(int code) => code == ZxKey.caps || code == ZxKey.sym;

  void _press(int code) {
    if (widget.haptics) Haptics.press();
    setState(() => _down.add(code));
    if (_isModifier(code)) {
      _modifierHeld.add(code);
      _usedWhileHeld = false;
      if (!_latched.contains(code)) widget.onKey(code, true);
      return;
    }
    if (_modifierHeld.isNotEmpty) _usedWhileHeld = true;
    for (final m in _latched) {
      widget.onKey(m, true);
    }
    widget.onKey(code, true);
  }

  void _release(int code) {
    setState(() => _down.remove(code));
    if (_isModifier(code)) {
      _modifierHeld.remove(code);
      if (_usedWhileHeld) {
        widget.onKey(code, false);
      } else if (_latched.contains(code)) {
        // Segundo toque: desbloquear.
        _latched.remove(code);
        widget.onKey(code, false);
      } else {
        // Toque simple: queda fijada hasta la próxima tecla.
        _latched.add(code);
      }
      setState(() {});
      return;
    }
    widget.onKey(code, false);
    if (_latched.isNotEmpty) {
      for (final m in _latched) {
        widget.onKey(m, false);
      }
      setState(_latched.clear);
    }
  }

  @override
  Widget build(BuildContext context) {
    return SkinView(
      skin: _skin,
      // Rellena el área del mando (se estira ~20% en vertical): al cambiar entre
      // teclado y mando la pantalla del juego no se mueve.
      stretch: true,
      onDown: (id, p) {
        for (var i = 0; i < _actionRects.length; i++) {
          if (_actionRects[i].inflate(16).contains(p)) {
            if (widget.haptics) Haptics.press();
            setState(() => _actionPointers[id] = i);
            return;
          }
        }
        final code = _keyAt(p);
        if (code == null || _pointers.containsValue(code)) return;
        _pointers[id] = code;
        _press(code);
      },
      onUp: (id) {
        final action = _actionPointers.remove(id);
        if (action != null) {
          // Al soltar: la acción puede abrir un panel o cambiar al mando.
          setState(() {});
          widget.onAction(PadAction.values[action]);
          return;
        }
        final code = _pointers.remove(id);
        if (code != null) _release(code);
      },
      painter: _KeyboardOverlay(
        down: {..._down},
        latched: {..._latched},
        actions: {..._actionPointers.values},
      ),
    );
  }
}

class _KeyboardOverlay extends SkinPainter {
  final Set<int> down;
  final Set<int> latched;
  final Set<int> actions;
  _KeyboardOverlay({required this.down, required this.latched, required this.actions});

  /// Botón de acción: tapa oscura con canto del color de la acción e ícono blanco.
  void _actionButton(Canvas canvas, int i) {
    final r = _actionRects[i];
    final rr = RRect.fromRectAndRadius(r, const Radius.circular(22));
    canvas.drawRRect(rr.shift(const Offset(0, 5)), Paint()..color = Colors.black.withValues(alpha: 0.6));
    canvas.drawRRect(
      rr,
      Paint()
        ..shader = LinearGradient(
          begin: Alignment.topCenter,
          end: Alignment.bottomCenter,
          colors: actions.contains(i)
              ? const [Color(0xFF1E2023), Color(0xFF2C2F33)]
              : const [Color(0xFF45484D), Color(0xFF26282B)],
        ).createShader(r),
    );
    canvas.drawRRect(
        rr.deflate(3),
        Paint()
          ..style = PaintingStyle.stroke
          ..strokeWidth = 7
          ..color = _actionColours[i]);
    final icon = _actionIcon(PadAction.values[i]);
    final tp = TextPainter(
      text: TextSpan(
        text: String.fromCharCode(icon.codePoint),
        style: TextStyle(
          fontSize: 66,
          height: 1,
          fontFamily: icon.fontFamily,
          package: icon.fontPackage,
          color: Colors.white.withValues(alpha: 0.92),
        ),
      ),
      textDirection: TextDirection.ltr,
    )..layout();
    tp.paint(canvas, r.center - Offset(tp.width / 2, tp.height / 2));
  }

  @override
  void paintSkin(Canvas canvas) {
    for (var i = 0; i < _actionRects.length; i++) {
      _actionButton(canvas, i);
    }
    final pressed = Paint()..color = Colors.white.withValues(alpha: 0.35);
    final lock = Paint()..color = ZxColors.cyan.withValues(alpha: 0.45);
    for (final code in {...down, ...latched}) {
      final r = _keyRects[code];
      if (r == null) continue;
      canvas.drawRRect(RRect.fromRectAndRadius(r, const Radius.circular(10)),
          latched.contains(code) ? lock : pressed);
    }
  }

  @override
  bool shouldRepaint(_KeyboardOverlay old) =>
      geometryChanged(old) ||
      !setEquals(old.down, down) ||
      !setEquals(old.latched, latched) ||
      !setEquals(old.actions, actions);
}
