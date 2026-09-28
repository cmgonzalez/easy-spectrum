import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../core/emulator/zx_types.dart';
import '../../core/theme/easy_theme.dart';

/// Controles tipo mando: cruceta de 8 direcciones, botón FUEGO y una fila de
/// teclas rápidas (números para menús, ENTER y ESPACIO).
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

  @override
  State<JoystickPad> createState() => _JoystickPadState();
}

class _JoystickPadState extends State<JoystickPad> {
  int _dir = 0;
  bool _fire = false;

  void _emit() => widget.onJoystick(_dir | (_fire ? ZxJoy.fire : 0));

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

  @override
  Widget build(BuildContext context) {
    return Container(
      color: ZxColors.body,
      padding: const EdgeInsets.fromLTRB(12, 8, 12, 8),
      child: Column(
        children: [
          SizedBox(
            height: 52,
            child: Row(
              children: [
                for (final (label, code) in const [
                  ('1', ZxKey.k1), ('2', ZxKey.k2), ('3', ZxKey.k3),
                  ('4', ZxKey.k4), ('5', ZxKey.k5),
                ])
                  Expanded(child: _QuickKey(label: label, code: code, onKey: widget.onKey)),
                Expanded(
                    flex: 2,
                    child: _QuickKey(label: 'ENTER', code: ZxKey.enter, onKey: widget.onKey)),
                Expanded(
                    flex: 2,
                    child: _QuickKey(label: 'ESPACIO', code: ZxKey.space, onKey: widget.onKey)),
              ],
            ),
          ),
          const SizedBox(height: 8),
          Expanded(
            child: Row(
              children: [
                Expanded(
                  child: Center(
                    child: AspectRatio(
                      aspectRatio: 1,
                      child: _DPad(direction: _dir, onDirection: _setDir),
                    ),
                  ),
                ),
                const SizedBox(width: 16),
                Expanded(
                  child: Center(
                    child: AspectRatio(
                      aspectRatio: 1,
                      child: Padding(
                        padding: const EdgeInsets.all(12),
                        child: Listener(
                          onPointerDown: (_) => _setFire(true),
                          onPointerUp: (_) => _setFire(false),
                          onPointerCancel: (_) => _setFire(false),
                          child: Container(
                            decoration: BoxDecoration(
                              shape: BoxShape.circle,
                              color: _fire ? ZxColors.yellow : ZxColors.red,
                              border: Border.all(color: Colors.black, width: 3),
                              boxShadow: const [
                                BoxShadow(color: Colors.black54, blurRadius: 8, offset: Offset(0, 4)),
                              ],
                            ),
                            child: const Center(
                              child: Text('FUEGO',
                                  style: TextStyle(
                                      fontSize: 24,
                                      fontWeight: FontWeight.bold,
                                      color: Colors.white)),
                            ),
                          ),
                        ),
                      ),
                    ),
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

/// Cruceta: la dirección sale del ángulo del dedo respecto al centro
/// (8 sectores), así se puede deslizar sin levantar el dedo.
class _DPad extends StatelessWidget {
  final int direction;
  final ValueChanged<int> onDirection;
  const _DPad({required this.direction, required this.onDirection});

  int _dirFor(Offset local, Size size) {
    final c = size.center(Offset.zero);
    final d = local - c;
    if (d.distance < size.shortestSide * 0.12) return 0;
    final a = math.atan2(d.dy, d.dx); // 0 = derecha, positivo hacia abajo
    final sector = ((a + math.pi) / (math.pi / 4) + 0.5).floor() % 8;
    // sector 0 = izquierda, luego en sentido horario.
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

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(builder: (context, box) {
      final size = box.biggest;
      return Listener(
        onPointerDown: (e) => onDirection(_dirFor(e.localPosition, size)),
        onPointerMove: (e) => onDirection(_dirFor(e.localPosition, size)),
        onPointerUp: (_) => onDirection(0),
        onPointerCancel: (_) => onDirection(0),
        child: CustomPaint(size: size, painter: _DPadPainter(direction)),
      );
    });
  }
}

class _DPadPainter extends CustomPainter {
  final int dir;
  _DPadPainter(this.dir);

  @override
  void paint(Canvas canvas, Size size) {
    final s = size.shortestSide;
    final c = size.center(Offset.zero);
    final arm = s * 0.34;
    final r = RRect.fromRectAndRadius(
        Rect.fromCenter(center: c, width: arm, height: s * 0.94), const Radius.circular(10));
    final h = RRect.fromRectAndRadius(
        Rect.fromCenter(center: c, width: s * 0.94, height: arm), const Radius.circular(10));
    final base = Paint()..color = ZxColors.key;
    canvas.drawCircle(c, s * 0.5, Paint()..color = ZxColors.bodyLight);
    canvas.drawRRect(r, base);
    canvas.drawRRect(h, base);

    final hi = Paint()..color = ZxColors.cyan;
    final off = s * 0.31;
    void arrow(int mask, Offset o, double angle) {
      final on = dir & mask != 0;
      if (on) {
        canvas.drawRRect(
            RRect.fromRectAndRadius(
                Rect.fromCenter(center: c + o, width: arm, height: arm), const Radius.circular(8)),
            hi);
      }
      canvas.save();
      canvas.translate(c.dx + o.dx, c.dy + o.dy);
      canvas.rotate(angle);
      final p = Path()
        ..moveTo(0, -arm * 0.22)
        ..lineTo(arm * 0.2, arm * 0.12)
        ..lineTo(-arm * 0.2, arm * 0.12)
        ..close();
      canvas.drawPath(p, Paint()..color = on ? Colors.black : ZxColors.textLight);
      canvas.restore();
    }

    arrow(ZxJoy.up, Offset(0, -off), 0);
    arrow(ZxJoy.right, Offset(off, 0), math.pi / 2);
    arrow(ZxJoy.down, Offset(0, off), math.pi);
    arrow(ZxJoy.left, Offset(-off, 0), -math.pi / 2);
  }

  @override
  bool shouldRepaint(_DPadPainter old) => old.dir != dir;
}

class _QuickKey extends StatefulWidget {
  final String label;
  final int code;
  final void Function(int code, bool pressed) onKey;
  const _QuickKey({required this.label, required this.code, required this.onKey});

  @override
  State<_QuickKey> createState() => _QuickKeyState();
}

class _QuickKeyState extends State<_QuickKey> {
  bool _down = false;

  void _set(bool v) {
    if (v == _down) return;
    setState(() => _down = v);
    widget.onKey(widget.code, v);
  }

  @override
  Widget build(BuildContext context) {
    return Listener(
      onPointerDown: (_) => _set(true),
      onPointerUp: (_) => _set(false),
      onPointerCancel: (_) => _set(false),
      child: Container(
        margin: const EdgeInsets.symmetric(horizontal: 3),
        decoration: BoxDecoration(
          color: _down ? ZxColors.keyPressed : ZxColors.key,
          borderRadius: BorderRadius.circular(10),
        ),
        child: Center(
          child: FittedBox(
            fit: BoxFit.scaleDown,
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 4),
              child: Text(widget.label,
                  style: const TextStyle(
                      fontSize: 18, fontWeight: FontWeight.bold, color: ZxColors.keyText)),
            ),
          ),
        ),
      ),
    );
  }
}
