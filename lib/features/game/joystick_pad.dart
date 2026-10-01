import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../../core/emulator/zx_types.dart';
import '../../core/haptics.dart';
import 'console_parts.dart';
import 'pad_config_sheet.dart';

/// Botones de cada botonera (centro y radio de la tapa como fracción del lado de
/// assets/skin/cluster_<n>.png), medidos por tools/make_skins.py. Orden: rojo
/// (fuego), amarillo, verde, azul = PadConfig.extra[0..2]. Anillo: centro 0,5; radio 0,4187.
const _clusters = <List<(Offset, double)>>[
  [(Offset(0.4958, 0.4812), 0.2543)],
  [(Offset(0.3679, 0.6004), 0.1379), (Offset(0.6378, 0.3750), 0.1367)],
  [(Offset(0.4977, 0.6600), 0.1231), (Offset(0.3401, 0.3855), 0.1231), (Offset(0.6564, 0.3887), 0.1234)],
  [
    (Offset(0.4956, 0.6929), 0.1171),
    (Offset(0.2836, 0.4832), 0.1136),
    (Offset(0.4954, 0.2907), 0.1145),
    (Offset(0.7090, 0.4846), 0.1163),
  ],
];
const _ringRadius = 0.4187;

/// Cruceta (assets/skin/dpad.png): brazo de la cruz, fracción del lado.
const _dpadArm = 0.2488;

/// Select / Start (assets/skin/select_<n>.png): tamaño del PNG y teclas grises, en px.
const _selects = <int, (Size, List<Rect>)>{
  1: (Size(236, 136), [Rect.fromLTRB(30, 26, 204, 93)]),
  2: (Size(397, 146), [Rect.fromLTRB(30, 39, 187, 103), Rect.fromLTRB(205, 39, 362, 104)]),
};

enum _Zone { dpad, button, select }

/// Área de controles del mando, armada por piezas según el espacio: cruceta a la
/// izquierda, botonera de 1-4 botones a la derecha (rojo = FUEGO, los demás con la
/// tecla asignada o el salto) y, debajo, los botones Select / Start si los hay. El
/// espacio vertical se reparte entre ellos; las piezas nunca se deforman.
class JoystickPad extends StatefulWidget {
  final void Function(int mask) onJoystick;
  final void Function(int code, bool pressed) onKey;
  final List<int> extraKeys;
  /// Teclas de los botones Select / Start (0-2; sin botones no se dibuja nada).
  final List<int> selectKeys;
  /// Botón de la botonera (1-3) que envía "arriba"; la cruceta deja de hacerlo.
  final int? jumpButton;
  final String jumpLabel;
  final bool haptics;
  /// Horizontal: cruceta y botonera en los costados de una pantalla ancha (Select /
  /// Start bajo la cruceta), para dibujarse translúcidos sobre el juego.
  final bool landscape;

  const JoystickPad({
    super.key,
    required this.onJoystick,
    required this.onKey,
    this.extraKeys = const [],
    this.selectKeys = const [],
    this.jumpButton,
    this.jumpLabel = 'JUMP',
    this.haptics = true,
    this.landscape = false,
  });

  @override
  State<JoystickPad> createState() => _JoystickPadState();
}

/// Posiciones de las piezas para un tamaño dado.
class _Layout {
  final Rect dpad, cluster;
  final Rect? select;
  _Layout(this.dpad, this.cluster, this.select);

  /// Horizontal: piezas a los costados; Select / Start debajo de la cruceta.
  factory _Layout.landscape(Size size, int selects) {
    final w = size.width, h = size.height;
    final sel = _selects[selects];
    final d = math.min(h * 0.56, w * 0.22);
    final selW = sel == null ? 0.0 : d * (selects == 2 ? 0.95 : 0.6);
    final selH = sel == null ? 0.0 : selW * sel.$1.height / sel.$1.width;
    final top = h - d - selH - h * 0.1;
    final cy = top + d / 2;
    final dpad = Rect.fromCenter(center: Offset(w * 0.04 + d / 2, cy), width: d * 0.9, height: d * 0.9);
    final cluster = Rect.fromLTWH(w - w * 0.04 - d, top, d, d);
    final select = sel == null ? null : Rect.fromLTWH(dpad.center.dx - selW / 2, top + d + h * 0.02, selW, selH);
    return _Layout(dpad, cluster, select);
  }

  factory _Layout.of(Size size, int selects) {
    final w = size.width, h = size.height;
    final sel = _selects[selects];
    final selW = sel == null ? 0.0 : w * (selects == 2 ? 0.42 : 0.25);
    final selH = sel == null ? 0.0 : selW * sel.$1.height / sel.$1.width;
    // Botonera y cruceta lo más grandes posible sin chocar entre ellas ni pasarse
    // del alto disponible (dejando aire arriba y abajo).
    final clusterD = math.min(w * 0.47, (h - selH) * 0.86);
    final dpadD = clusterD * 0.9;
    final free = h - clusterD - selH;
    final gap = free / (sel == null ? 2 : 3);
    final rowY = gap;
    final rowCy = rowY + clusterD / 2;
    final dpad = Rect.fromCenter(center: Offset(w * 0.03 + dpadD / 2, rowCy), width: dpadD, height: dpadD);
    final cluster = Rect.fromLTWH(w - w * 0.01 - clusterD, rowY, clusterD, clusterD);
    final select = sel == null
        ? null
        : Rect.fromLTWH((w - selW) / 2, rowY + clusterD + gap * 0.8, selW, selH);
    return _Layout(dpad, cluster, select);
  }
}

class _JoystickPadState extends State<JoystickPad> {
  final Map<int, (_Zone, int)> _pointers = {}; // puntero → zona (+ botón)
  int _dir = 0;
  bool _fire = false;
  bool _jump = false;
  final Set<int> _buttonsDown = {}; // botones de la botonera (0 = fuego)
  final Set<int> _selectDown = {};
  _Layout? _layout;

  List<(Offset, double)> get _cluster => _clusters[widget.extraKeys.length.clamp(0, 3)];

  /// Botones de la botonera en coordenadas del área.
  List<(Offset, double)> _clusterButtons(Rect r) =>
      [for (final (c, rad) in _cluster) (r.topLeft + Offset(c.dx * r.width, c.dy * r.height), rad * r.width)];

  List<Rect> _selectCaps(Rect? r) {
    final sel = _selects[widget.selectKeys.length];
    if (sel == null || r == null) return const [];
    final k = r.width / sel.$1.width;
    return [for (final c in sel.$2) Rect.fromLTRB(r.left + c.left * k, r.top + c.top * k, r.left + c.right * k, r.top + c.bottom * k)];
  }

  /// Dirección enviada: con botón de salto, arriba sale de ese botón y no de la cruceta.
  int get _sentDir {
    if (widget.jumpButton == null) return _dir;
    return (_dir & ~ZxJoy.up) | (_jump ? ZxJoy.up : 0);
  }

  void _emit() => widget.onJoystick(_sentDir | (_fire ? ZxJoy.fire : 0));

  int _dirFor(Offset p) {
    final l = _layout!;
    final d = p - l.dpad.center;
    if (d.distance < l.dpad.width * 0.06) return 0;
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

  void _setButton(int i, bool v) {
    setState(() => v ? _buttonsDown.add(i) : _buttonsDown.remove(i));
    if (i == 0) {
      _setFire(v);
    } else if (i == widget.jumpButton) {
      if (v && widget.haptics) Haptics.press();
      _jump = v;
      _emit();
    } else {
      if (v && widget.haptics) Haptics.press();
      widget.onKey(widget.extraKeys[i - 1], v);
    }
  }

  (_Zone, int)? _zoneAt(Offset p) {
    final l = _layout!;
    final caps = _selectCaps(l.select);
    for (var i = 0; i < caps.length; i++) {
      var r = caps[i].inflate(16);
      if (caps.length == 2) {
        final mid = (caps[0].right + caps[1].left) / 2;
        r = i == 0 ? Rect.fromLTRB(r.left, r.top, mid, r.bottom) : Rect.fromLTRB(mid, r.top, r.right, r.bottom);
      }
      if (r.contains(p)) return (_Zone.select, i);
    }
    // Botonera: dentro del anillo (y un margen), el botón más cercano.
    if ((p - l.cluster.center).distance <= l.cluster.width * (_ringRadius + 0.06)) {
      final buttons = _clusterButtons(l.cluster);
      var best = 0;
      for (var i = 1; i < buttons.length; i++) {
        if ((p - buttons[i].$1).distance < (p - buttons[best].$1).distance) best = i;
      }
      return (_Zone.button, best);
    }
    // Cruceta: generosa (el dedo se sale del dibujo al deslizar).
    if ((p - l.dpad.center).distance <= l.dpad.width * 0.62) return (_Zone.dpad, 0);
    return null;
  }

  void _down(int id, Offset p) {
    final z = _zoneAt(p);
    if (z == null) return;
    _pointers[id] = z;
    switch (z.$1) {
      case _Zone.dpad:
        _setDir(_dirFor(p));
      case _Zone.button:
        _setButton(z.$2, true);
      case _Zone.select:
        if (widget.haptics) Haptics.press();
        setState(() => _selectDown.add(z.$2));
        widget.onKey(widget.selectKeys[z.$2], true);
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
      case _Zone.button:
        _setButton(z.$2, false);
      case _Zone.select:
        setState(() => _selectDown.remove(z.$2));
        widget.onKey(widget.selectKeys[z.$2], false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(builder: (context, box) {
      final l = _layout = widget.landscape
          ? _Layout.landscape(box.biggest, widget.selectKeys.length)
          : _Layout.of(box.biggest, widget.selectKeys.length);
      Widget place(Rect r, Widget child) =>
          Positioned(left: r.left, top: r.top, width: r.width, height: r.height, child: child);
      final n = widget.extraKeys.length + 1;
      return Listener(
        behavior: HitTestBehavior.translucent,
        onPointerDown: (e) => _down(e.pointer, e.localPosition),
        onPointerMove: (e) => _move(e.pointer, e.localPosition),
        onPointerUp: (e) => _up(e.pointer),
        onPointerCancel: (e) => _up(e.pointer),
        child: Stack(
          children: [
            place(l.dpad, Image.asset('assets/skin/dpad.png', gaplessPlayback: true)),
            place(l.cluster, Image.asset('assets/skin/cluster_$n.png', gaplessPlayback: true)),
            if (l.select != null)
              place(l.select!,
                  Image.asset('assets/skin/select_${widget.selectKeys.length}.png', fit: BoxFit.fill, gaplessPlayback: true)),
            Positioned.fill(
              child: CustomPaint(
                painter: _PadOverlay(
                  dpad: l.dpad,
                  dir: widget.jumpButton == null ? _dir : _dir & ~ZxJoy.up,
                  buttons: _clusterButtons(l.cluster),
                  buttonsDown: {..._buttonsDown},
                  labels: [
                    for (var i = 0; i < widget.extraKeys.length; i++)
                      i + 1 == widget.jumpButton ? widget.jumpLabel : zxKeyName(context, widget.extraKeys[i]),
                  ],
                  selectCaps: _selectCaps(l.select),
                  selectDown: {..._selectDown},
                  selectLabels: [for (final k in widget.selectKeys) zxKeyName(context, k)],
                ),
              ),
            ),
          ],
        ),
      );
    });
  }
}

class _PadOverlay extends CustomPainter {
  final Rect dpad;
  final int dir;
  final List<(Offset, double)> buttons;
  final Set<int> buttonsDown;
  final List<String> labels; // teclas de amarillo, verde y azul
  final List<Rect> selectCaps;
  final Set<int> selectDown;
  final List<String> selectLabels;
  _PadOverlay({
    required this.dpad,
    required this.dir,
    required this.buttons,
    required this.buttonsDown,
    required this.labels,
    required this.selectCaps,
    required this.selectDown,
    required this.selectLabels,
  });

  @override
  void paint(Canvas canvas, Size size) {
    final glow = Paint()..color = Colors.white.withValues(alpha: 0.35);

    // Cruceta: ilumina los brazos activos.
    final arm = dpad.width * _dpadArm;
    void armGlow(int mask, Offset o) {
      if (dir & mask == 0) return;
      canvas.drawRRect(
          RRect.fromRectAndRadius(Rect.fromCenter(center: dpad.center + o, width: arm, height: arm),
              Radius.circular(arm * 0.13)),
          glow);
    }

    armGlow(ZxJoy.up, Offset(0, -arm));
    armGlow(ZxJoy.down, Offset(0, arm));
    armGlow(ZxJoy.left, Offset(-arm, 0));
    armGlow(ZxJoy.right, Offset(arm, 0));

    // Botonera: la tapa pulsada se hunde con un aro claro; amarillo, verde y azul
    // llevan escrita su tecla.
    for (var i = 0; i < buttons.length; i++) {
      final (c, r) = buttons[i];
      if (buttonsDown.contains(i)) {
        canvas.drawCircle(c, r, Paint()..color = Colors.black.withValues(alpha: 0.35));
        canvas.drawCircle(
            c,
            r + r * 0.05,
            Paint()
              ..style = PaintingStyle.stroke
              ..strokeWidth = r * 0.09
              ..color = Colors.white.withValues(alpha: 0.8));
      }
      if (i > 0 && i - 1 < labels.length) {
        paintCenteredText(
          canvas,
          labels[i - 1],
          c + Offset(0, r * 0.04),
          TextStyle(
            fontSize: r * 0.62,
            fontWeight: FontWeight.w900,
            color: const Color(0xFF1B1B1B).withValues(alpha: 0.85),
            fontFamily: 'monospace',
          ),
          maxWidth: r * 1.5,
        );
      }
    }

    // Select / Start: tecla escrita en gris oscuro; pulsada, más oscura con borde.
    for (var i = 0; i < selectCaps.length && i < selectLabels.length; i++) {
      final r = selectCaps[i];
      final rr = RRect.fromRectAndRadius(r, Radius.circular(r.height * 0.18));
      if (selectDown.contains(i)) {
        canvas.drawRRect(rr, Paint()..color = Colors.black.withValues(alpha: 0.35));
        canvas.drawRRect(
            rr.inflate(2),
            Paint()
              ..style = PaintingStyle.stroke
              ..strokeWidth = 3
              ..color = Colors.white.withValues(alpha: 0.8));
      }
      paintCenteredText(
        canvas,
        selectLabels[i],
        r.center,
        TextStyle(
          fontSize: r.height * 0.55,
          fontWeight: FontWeight.w900,
          color: const Color(0xFF2A2D31).withValues(alpha: 0.9),
          fontFamily: 'monospace',
        ),
        maxWidth: r.width * 0.85,
      );
    }
  }

  @override
  bool shouldRepaint(_PadOverlay old) =>
      old.dpad != dpad ||
      old.dir != dir ||
      old.buttons.length != buttons.length ||
      (buttons.isNotEmpty && old.buttons.first != buttons.first) ||
      old.buttonsDown.length != buttonsDown.length ||
      !old.buttonsDown.containsAll(buttonsDown) ||
      old.labels.join('|') != labels.join('|') ||
      old.selectCaps.length != selectCaps.length ||
      (selectCaps.isNotEmpty && old.selectCaps.first != selectCaps.first) ||
      old.selectDown.length != selectDown.length ||
      !old.selectDown.containsAll(selectDown) ||
      old.selectLabels.join('|') != selectLabels.join('|');
}
