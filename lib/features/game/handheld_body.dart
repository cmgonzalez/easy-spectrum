import 'package:flutter/material.dart';

/// Cuerpo de la consola portátil sobre los controles: el mismo plástico y cantos
/// que el mando (assets/skin/body_*.jpg, de tools/make_skins.py), con el LED de
/// encendido, la rejilla del altavoz y la pantalla del juego dentro de un vidrio.
/// [closedBottom]: abajo no va el mando (teclado) → el cuerpo cierra con sus esquinas;
/// si no, queda abierto y se une sin costura con el mando (también abierto arriba).
class HandheldBody extends StatelessWidget {
  final Widget screen;
  final bool closedBottom;
  const HandheldBody({super.key, required this.screen, this.closedBottom = false});

  static const _skinWidth = 1393.0; // ancho de las piezas (= mando)
  static const _frame = 24.0; // grosor del canto en la piel

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(builder: (context, box) {
      final k = box.maxWidth / _skinWidth;
      final frame = _frame * k;
      final topH = 64 * k, bottomH = closedBottom ? 64 * k : 0.0;

      // Pantalla: lo más grande posible dentro del cuerpo, con la fila del LED
      // encima, y el bloque centrado en vertical.
      const margin = 14.0, glass = 12.0, ledRow = 34.0, gap = 10.0;
      final innerTop = topH * 0.4, innerBottom = bottomH > 0 ? bottomH * 0.6 : frame + 8;
      final availH = box.maxHeight - innerTop - innerBottom - ledRow - gap;
      final maxW = box.maxWidth - 2 * (frame + margin);
      var gameW = maxW - 2 * glass;
      var gameH = gameW * 256 / 320;
      if (gameH + 2 * glass > availH) {
        gameH = (availH - 2 * glass).clamp(0, double.infinity);
        gameW = gameH * 320 / 256;
      }
      final bezelW = gameW + 2 * glass;

      return Stack(
        fit: StackFit.expand,
        children: [
          Column(
            children: [
              Image.asset('assets/skin/body_top.jpg',
                  width: box.maxWidth, height: topH, fit: BoxFit.fill, gaplessPlayback: true),
              Expanded(
                child: Image.asset(
                  'assets/skin/body_mid.jpg',
                  width: box.maxWidth,
                  fit: BoxFit.fitWidth,
                  repeat: ImageRepeat.repeatY,
                  alignment: Alignment.topCenter,
                  gaplessPlayback: true,
                ),
              ),
              if (closedBottom)
                Image.asset('assets/skin/body_bottom.jpg',
                    width: box.maxWidth, height: bottomH, fit: BoxFit.fill, gaplessPlayback: true),
            ],
          ),
          Padding(
            padding: EdgeInsets.only(top: innerTop, bottom: innerBottom),
            child: Center(
              child: SizedBox(
                width: bezelW,
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    const SizedBox(height: ledRow, child: _TopRow()),
                    const SizedBox(height: gap),
                    _Bezel(
                      padding: glass,
                      child: SizedBox(width: gameW, height: gameH, child: screen),
                    ),
                  ],
                ),
              ),
            ),
          ),
        ],
      );
    });
  }
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
            height: 22,
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
