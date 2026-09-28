import 'dart:ui' as ui;

import 'package:flutter/material.dart';

import '../../core/emulator/zx_types.dart';

/// Pinta el framebuffer 320×256 del Spectrum con píxeles cuadrados y sin filtrado.
class GameDisplay extends StatelessWidget {
  final ui.Image? frame;
  const GameDisplay({super.key, this.frame});

  @override
  Widget build(BuildContext context) {
    return ColoredBox(
      color: Colors.black,
      child: Center(
        child: AspectRatio(
          aspectRatio: zxFbWidth / zxFbHeight,
          child: frame != null
              ? CustomPaint(painter: _FramePainter(frame!))
              : const ColoredBox(color: Colors.black),
        ),
      ),
    );
  }
}

class _FramePainter extends CustomPainter {
  final ui.Image image;
  _FramePainter(this.image);

  @override
  void paint(Canvas canvas, Size size) {
    canvas.drawImageRect(
      image,
      Rect.fromLTWH(0, 0, zxFbWidth.toDouble(), zxFbHeight.toDouble()),
      Offset.zero & size,
      Paint()..filterQuality = FilterQuality.none,
    );
  }

  @override
  bool shouldRepaint(_FramePainter old) => !identical(old.image, image);
}
