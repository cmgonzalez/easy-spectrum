import 'dart:math' as math;

import 'package:flutter/material.dart';

import 'console_parts.dart';

/// Consola portátil que ocupa toda la pantalla bajo la barra superior: el plástico
/// y los cantos del cuerpo (assets/skin/body_*.jpg, de tools/make_skins.py) y, de
/// arriba abajo: LED de encendido y rejilla del altavoz, la pantalla del juego en
/// un vidrio, el LCD, la fila de botones de acción y el área de controles (mando o
/// teclado). La pantalla tiene el mismo tamaño con mando y con teclado.
class ConsoleView extends StatelessWidget {
  final Widget screen;
  final Widget lcd;
  final Widget actions;
  final Widget controls;
  /// Arcoíris en la esquina inferior derecha (con el mando; el teclado trae el suyo).
  final bool rainbow;
  /// Proporción ancho/alto de la pantalla (depende de cuánto borde se muestra).
  final double screenAspect;

  const ConsoleView({
    super.key,
    required this.screen,
    required this.lcd,
    required this.actions,
    required this.controls,
    this.rainbow = true,
    this.screenAspect = 320 / 256,
  });

  static const _skinWidth = 1393.0; // ancho de las piezas del cuerpo
  static const _frame = 24.0; // grosor del canto en la piel
  static const _cap = 64.0; // alto de las tapas superior e inferior

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(builder: (context, box) {
      final w = box.maxWidth, h = box.maxHeight;
      final k = w / _skinWidth;
      final frame = _frame * k, cap = _cap * k;
      // Solo una línea fina para el arte de los cantos: pantalla y teclado a todo el ancho.
      final side = frame + 3;

      // Pantalla: todo el ancho útil, sin pasar del ~40% del alto (los controles
      // necesitan su espacio en teléfonos bajos).
      const glass = 5.0;
      var gameW = w - 2 * side - 2 * glass;
      gameW = math.min(gameW, h * 0.46 * screenAspect);
      final gameH = gameW / screenAspect;
      final lcdW = w * 0.56;
      final actionsH = w * 0.085;

      return Stack(
        fit: StackFit.expand,
        children: [
          Column(
            children: [
              Image.asset('assets/skin/body_top.jpg', width: w, height: cap, fit: BoxFit.fill, gaplessPlayback: true),
              Expanded(
                child: Image.asset(
                  'assets/skin/body_mid.jpg',
                  width: w,
                  fit: BoxFit.fitWidth,
                  repeat: ImageRepeat.repeatY,
                  alignment: Alignment.topCenter,
                  gaplessPlayback: true,
                ),
              ),
              Image.asset('assets/skin/body_bottom.jpg',
                  width: w, height: cap, fit: BoxFit.fill, gaplessPlayback: true),
            ],
          ),
          if (rainbow) CustomPaint(painter: _RainbowPainter(frame: frame)),
          Padding(
            padding: EdgeInsets.fromLTRB(0, cap * 0.3, 0, frame + 6),
            child: Column(
              children: [
                Padding(
                  padding: EdgeInsets.symmetric(horizontal: side),
                  child: const SizedBox(height: 28, child: _TopRow()),
                ),
                const SizedBox(height: 6),
                _Bezel(
                  padding: glass,
                  child: SizedBox(width: gameW, height: gameH, child: screen),
                ),
                const SizedBox(height: 12),
                SizedBox(width: lcdW, height: lcdW / LcdPanel.aspect, child: lcd),
                SizedBox(height: w * 0.035),
                Padding(
                  padding: EdgeInsets.symmetric(horizontal: side),
                  child: SizedBox(height: actionsH, child: actions),
                ),
                // El teclado (sin arcoíris propio del cuerpo) ocupa todo el ancho útil.
                Expanded(
                  child: Padding(
                    padding: EdgeInsets.symmetric(horizontal: rainbow ? side : frame + 2),
                    child: controls,
                  ),
                ),
              ],
            ),
          ),
        ],
      );
    });
  }
}

/// Arcoíris del Spectrum con el mismo ángulo y ancho de franja que el del teclado
/// (25 px a la derecha por cada 60 hacia arriba; franjas de 25/1536 del ancho),
/// recortado dentro de los cantos del cuerpo.
class _RainbowPainter extends CustomPainter {
  final double frame;
  const _RainbowPainter({required this.frame});

  static const _colours = [Color(0xFFE8322B), Color(0xFFF5C400), Color(0xFF1FBF3A), Color(0xFF12B5E8)];

  @override
  void paint(Canvas canvas, Size size) {
    final w = size.width, h = size.height;
    const slope = 25 / 60;
    final band = w * 25 / 1536;
    final rise = w * 0.70;
    final run = rise * slope;
    final x0 = w - frame - run - 4 * band + w * 0.157;
    canvas.save();
    canvas.clipRRect(RRect.fromRectAndRadius(
        Rect.fromLTRB(frame, 0, w - frame, h - frame), Radius.circular(frame * 2.3)));
    for (var i = 0; i < 4; i++) {
      final xs = x0 + i * band;
      canvas.drawPath(
        Path()
          ..moveTo(xs, h)
          ..lineTo(xs + band, h)
          ..lineTo(xs + band + run, h - rise)
          ..lineTo(xs + run, h - rise)
          ..close(),
        Paint()..color = _colours[i],
      );
    }
    canvas.restore();
  }

  @override
  bool shouldRepaint(_RainbowPainter old) => old.frame != frame;
}

/// LED rojo de encendido con "POWER" a la izquierda y rejilla del altavoz a la derecha.
class _TopRow extends StatelessWidget {
  const _TopRow();

  @override
  Widget build(BuildContext context) {
    return Row(
      children: [
        const SizedBox(width: 6),
        const CustomPaint(size: Size(16, 16), painter: _LedPainter()),
        const SizedBox(width: 8),
        const Text('POWER',
            style: TextStyle(
                fontSize: 11, fontWeight: FontWeight.w700, letterSpacing: 1, color: Color(0xFFA0A2AA))),
        const Spacer(),
        for (var i = 0; i < 6; i++)
          Container(
            width: 5,
            height: 20,
            margin: const EdgeInsets.only(left: 6),
            decoration: BoxDecoration(
              color: Colors.black.withValues(alpha: 0.8),
              borderRadius: BorderRadius.circular(3),
              border: Border(bottom: BorderSide(color: Colors.white.withValues(alpha: 0.12))),
            ),
          ),
        const SizedBox(width: 6),
      ],
    );
  }
}

class _LedPainter extends CustomPainter {
  const _LedPainter();

  @override
  void paint(Canvas canvas, Size size) {
    final c = size.center(Offset.zero);
    canvas.drawCircle(
        c,
        size.width * 0.9,
        Paint()
          ..color = const Color(0xFFFF2A1E).withValues(alpha: 0.35)
          ..maskFilter = const MaskFilter.blur(BlurStyle.normal, 5));
    canvas.drawCircle(c, size.width * 0.32, Paint()..color = const Color(0xFFFF463C));
    canvas.drawCircle(c + Offset(-size.width * 0.1, -size.width * 0.12), size.width * 0.1,
        Paint()..color = const Color(0xFFFFBEB4));
  }

  @override
  bool shouldRepaint(_LedPainter old) => false;
}

/// Vidrio negro con canto oscuro y un brillo fino alrededor de la pantalla.
class _Bezel extends StatelessWidget {
  final double padding;
  final Widget child;
  const _Bezel({required this.padding, required this.child});

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: EdgeInsets.all(padding),
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(14),
        gradient: const LinearGradient(
          begin: Alignment.topCenter,
          end: Alignment.bottomCenter,
          colors: [Color(0xFF08090A), Color(0xFF141517)],
        ),
        border: Border.all(color: Colors.black, width: 2.5),
        boxShadow: [
          BoxShadow(color: Colors.white.withValues(alpha: 0.10), spreadRadius: 1),
          BoxShadow(color: Colors.black.withValues(alpha: 0.5), blurRadius: 6, offset: const Offset(0, 2)),
        ],
      ),
      child: child,
    );
  }
}
