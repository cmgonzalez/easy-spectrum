import 'dart:ui' as ui;

import 'package:flutter/material.dart';

import '../../core/emulator/zx_types.dart';
import '../../core/l10n.dart';
import '../../core/theme/easy_theme.dart';

/// Pinta el framebuffer 320×256 del Spectrum con píxeles cuadrados y sin filtrado.
/// [turbo]: la cinta está cargando acelerada → icono ⏩ en la esquina inferior derecha.
class GameDisplay extends StatelessWidget {
  final ui.Image? frame;
  final bool turbo;
  const GameDisplay({super.key, this.frame, this.turbo = false});

  @override
  Widget build(BuildContext context) {
    return ColoredBox(
      color: Colors.black,
      child: Center(
        child: AspectRatio(
          aspectRatio: zxFbWidth / zxFbHeight,
          child: Stack(
            fit: StackFit.expand,
            children: [
              frame != null
                  ? CustomPaint(painter: _FramePainter(frame!))
                  : const ColoredBox(color: Colors.black),
              if (turbo)
                Positioned(
                  right: 8,
                  bottom: 8,
                  child: Tooltip(
                    message: context.l10n.turboLoading,
                    child: Container(
                      padding: const EdgeInsets.all(4),
                      decoration: BoxDecoration(
                        color: Colors.black.withValues(alpha: 0.6),
                        borderRadius: BorderRadius.circular(8),
                      ),
                      child: const Icon(Icons.fast_forward_rounded,
                          size: 32, color: ZxColors.yellow),
                    ),
                  ),
                ),
            ],
          ),
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
