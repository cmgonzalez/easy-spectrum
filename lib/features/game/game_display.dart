import 'dart:ui' as ui;

import 'package:flutter/material.dart';

import '../../core/emulator/zx_types.dart';
import '../../core/l10n.dart';
import '../../core/theme/easy_theme.dart';
import '../../core/screen_border.dart';
import '../../core/video_mode.dart';

/// Pinta el framebuffer 320×256 del Spectrum según el [mode] de video: píxeles
/// cuadrados sin filtrar, filtrado bilineal, esquinas redondeadas o el shader CRT
/// (shaders/crt.frag) para monitor y TV.
/// [turbo]: la cinta está cargando acelerada → icono ⏩ en la esquina inferior derecha.
class GameDisplay extends StatefulWidget {
  final ui.Image? frame;
  final bool turbo;
  final VideoMode mode;
  final ScreenBorder border;
  const GameDisplay(
      {super.key, this.frame, this.turbo = false, this.mode = VideoMode.sharp, this.border = ScreenBorder.half});

  /// Proporción de la parte visible (320×256 menos el borde recortado).
  static double aspectFor(ScreenBorder b) => (zxFbWidth - 2 * b.crop) / (zxFbHeight - 2 * b.crop);

  @override
  State<GameDisplay> createState() => _GameDisplayState();
}

class _GameDisplayState extends State<GameDisplay> {
  static Future<ui.FragmentProgram>? _program;
  ui.FragmentShader? _shader;

  @override
  void initState() {
    super.initState();
    _loadShader();
  }

  @override
  void didUpdateWidget(GameDisplay old) {
    super.didUpdateWidget(old);
    _loadShader();
  }

  void _loadShader() {
    if (_shader != null || widget.mode.crt == null) return;
    (_program ??= ui.FragmentProgram.fromAsset('shaders/crt.frag')).then((p) {
      if (mounted) setState(() => _shader ??= p.fragmentShader());
    }, onError: (e) => debugPrint('CRT shader: $e'));
  }

  @override
  void dispose() {
    _shader?.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final mode = widget.mode;
    final frame = widget.frame;
    Widget screen = frame != null
        ? CustomPaint(
            painter: _FramePainter(
              frame,
              mode: mode,
              border: widget.border.crop,
              shader: mode.crt != null ? _shader : null,
              dpr: MediaQuery.devicePixelRatioOf(context),
            ),
          )
        : const ColoredBox(color: Colors.black);
    if (mode == VideoMode.rounded) {
      // El builder corre después: debe capturar la pantalla, no la variable `screen`
      // (que para entonces es este LayoutBuilder → se contendría a sí mismo).
      final content = screen;
      screen = LayoutBuilder(
        builder: (context, box) => ClipRRect(
          borderRadius: BorderRadius.circular(box.maxHeight * 0.05),
          child: content,
        ),
      );
    }
    return ColoredBox(
      color: Colors.black,
      child: Center(
        child: AspectRatio(
          aspectRatio: GameDisplay.aspectFor(widget.border),
          child: Stack(
            fit: StackFit.expand,
            children: [
              screen,
              if (widget.turbo)
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
  final VideoMode mode;
  final int border;
  final ui.FragmentShader? shader;
  final double dpr;
  _FramePainter(this.image, {required this.mode, required this.border, this.shader, required this.dpr});

  @override
  void paint(Canvas canvas, Size size) {
    final crt = mode.crt;
    final s = shader;
    if (crt != null && s != null) {
      // Orden de los uniforms de shaders/crt.frag.
      s
        ..setFloat(0, size.width)
        ..setFloat(1, size.height)
        ..setFloat(2, (zxFbWidth - 2 * border).toDouble())
        ..setFloat(3, (zxFbHeight - 2 * border).toDouble())
        ..setFloat(4, dpr)
        ..setFloat(5, crt.curve)
        ..setFloat(6, crt.scan)
        ..setFloat(7, crt.mask)
        ..setFloat(8, crt.vignette)
        ..setFloat(9, crt.corner)
        ..setFloat(10, crt.glow)
        ..setFloat(11, border.toDouble())
        ..setFloat(12, border.toDouble())
        ..setFloat(13, zxFbWidth.toDouble())
        ..setFloat(14, zxFbHeight.toDouble())
        ..setImageSampler(0, image);
      canvas.drawRect(Offset.zero & size, Paint()..shader = s);
      return;
    }
    canvas.drawImageRect(
      image,
      Rect.fromLTWH(border.toDouble(), border.toDouble(), (zxFbWidth - 2 * border).toDouble(),
          (zxFbHeight - 2 * border).toDouble()),
      Offset.zero & size,
      Paint()..filterQuality = mode == VideoMode.smooth ? FilterQuality.medium : FilterQuality.none,
    );
  }

  @override
  bool shouldRepaint(_FramePainter old) =>
      !identical(old.image, image) || old.mode != mode || old.border != border || old.shader != shader || old.dpr != dpr;
}
