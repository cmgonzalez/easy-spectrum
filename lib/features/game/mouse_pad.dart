import 'dart:async';

import 'package:flutter/material.dart';

import '../../core/haptics.dart';
import '../../core/theme/easy_theme.dart';

/// Touchpad del ratón Kempston/AMX: un área para deslizar el dedo (movimiento relativo)
/// y un único botón. Un toque corto sobre el pad también hace clic. Multitáctil: se
/// puede mover con un dedo mientras el otro mantiene el botón.
class MousePad extends StatefulWidget {
  /// Desplazamiento en enteros del ratón del Spectrum (dy positivo = hacia abajo).
  final void Function(int dx, int dy) onMove;
  /// Botón izquierdo (bit 0): true = pulsado.
  final void Function(bool pressed) onButton;
  final bool haptics;
  final double sensitivity;

  const MousePad({
    super.key,
    required this.onMove,
    required this.onButton,
    this.haptics = true,
    this.sensitivity = 1.6,
  });

  @override
  State<MousePad> createState() => _MousePadState();
}

class _MousePadState extends State<MousePad> {
  // Dedo del pad: posición de inicio, instante y distancia recorrida (para el toque-clic).
  int? _padPointer;
  Offset _padStart = Offset.zero;
  Offset _padLast = Offset.zero;
  DateTime _padDown = DateTime.now();
  double _moved = 0;
  double _remX = 0, _remY = 0; // fracciones que aún no llegan a un paso entero
  bool _padTouched = false;

  int? _buttonPointer;
  bool _tapClick = false;
  Timer? _tapTimer;

  void _setButton(bool down) {
    if (down && widget.haptics) Haptics.press();
    widget.onButton(down || _tapClick);
    setState(() {});
  }

  bool get _pressed => _buttonPointer != null || _tapClick;

  void _padDownEvent(PointerDownEvent e) {
    if (_padPointer != null) return;
    _padPointer = e.pointer;
    _padStart = _padLast = e.localPosition;
    _padDown = DateTime.now();
    _moved = 0;
    _padTouched = true;
    setState(() {});
  }

  void _padMoveEvent(PointerMoveEvent e) {
    if (e.pointer != _padPointer) return;
    final d = e.localPosition - _padLast;
    _padLast = e.localPosition;
    _moved = (e.localPosition - _padStart).distance > _moved ? (e.localPosition - _padStart).distance : _moved;
    _remX += d.dx * widget.sensitivity;
    _remY += d.dy * widget.sensitivity;
    final ix = _remX.truncate(), iy = _remY.truncate();
    if (ix != 0 || iy != 0) {
      _remX -= ix;
      _remY -= iy;
      widget.onMove(ix, iy);
    }
  }

  void _padUpEvent(PointerEvent e) {
    if (e.pointer != _padPointer) return;
    _padPointer = null;
    _padTouched = false;
    final quick = DateTime.now().difference(_padDown) < const Duration(milliseconds: 220);
    if (quick && _moved < 12 && e is PointerUpEvent) {
      // Toque corto: clic de unos 80 ms.
      _tapClick = true;
      if (widget.haptics) Haptics.press();
      widget.onButton(true);
      _tapTimer?.cancel();
      _tapTimer = Timer(const Duration(milliseconds: 80), () {
        _tapClick = false;
        widget.onButton(_buttonPointer != null);
        if (mounted) setState(() {});
      });
    }
    setState(() {});
  }

  @override
  void dispose() {
    _tapTimer?.cancel();
    widget.onButton(false);
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(builder: (context, box) {
      // Botón horizontal bajo el área de arrastre.
      final buttonH = (box.maxHeight * 0.26).clamp(52.0, 84.0);
      return Padding(
        padding: const EdgeInsets.symmetric(vertical: 6),
        child: Column(
          children: [
            Expanded(
              child: Listener(
                behavior: HitTestBehavior.opaque,
                onPointerDown: _padDownEvent,
                onPointerMove: _padMoveEvent,
                onPointerUp: _padUpEvent,
                onPointerCancel: _padUpEvent,
                child: DecoratedBox(
                  decoration: BoxDecoration(
                    borderRadius: BorderRadius.circular(22),
                    color: _padTouched ? const Color(0xFF26282C) : const Color(0xFF1B1D20),
                    border: Border.all(color: Colors.black, width: 3),
                    boxShadow: [BoxShadow(color: Colors.white.withValues(alpha: 0.10), spreadRadius: 1)],
                  ),
                  child: Center(
                    child: Icon(Icons.mouse_rounded, size: 56, color: Colors.white.withValues(alpha: 0.12)),
                  ),
                ),
              ),
            ),
            const SizedBox(height: 10),
            SizedBox(
              height: buttonH,
              width: double.infinity,
              child: Listener(
                behavior: HitTestBehavior.opaque,
                onPointerDown: (e) {
                  if (_buttonPointer != null) return;
                  _buttonPointer = e.pointer;
                  _setButton(true);
                },
                onPointerUp: (e) {
                  if (e.pointer != _buttonPointer) return;
                  _buttonPointer = null;
                  _setButton(false);
                },
                onPointerCancel: (e) {
                  if (e.pointer != _buttonPointer) return;
                  _buttonPointer = null;
                  _setButton(false);
                },
                child: DecoratedBox(
                  decoration: BoxDecoration(
                    borderRadius: BorderRadius.circular(22),
                    color: _pressed ? ZxColors.red : const Color(0xFF8E1B1B),
                    border: Border.all(color: Colors.black, width: 3),
                    boxShadow: [BoxShadow(color: Colors.white.withValues(alpha: 0.12), spreadRadius: 1)],
                  ),
                  child: const Center(child: Icon(Icons.ads_click_rounded, size: 44, color: Colors.white)),
                ),
              ),
            ),
          ],
        ),
      );
    });
  }
}
