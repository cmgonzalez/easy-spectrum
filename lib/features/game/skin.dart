import 'package:flutter/material.dart';

export 'package:flutter/foundation.dart' show setEquals;

/// Imagen de fondo de un control. Toda la geometría de teclas y botones se expresa
/// en píxeles de la imagen *original*; si el asset es un recorte, [origin] es la
/// esquina del recorte en la original (así no hay que re-medir al recortar).
class SkinImage {
  final String asset;
  final double width; // tamaño del asset (recortado)
  final double height;
  final Offset origin;
  const SkinImage(this.asset, this.width, this.height, {this.origin = Offset.zero});
}

/// Dibuja un [SkinImage] y traduce los toques a coordenadas de la imagen.
/// [stretch] = false: ajuste proporcional (contain, centrado). true: rellena todo el
/// espacio aunque deforme (el teclado se estira en vertical para ocupar la misma área
/// que el mando). Multitáctil: cada puntero llega con su id.
class SkinView extends StatelessWidget {
  final SkinImage skin;
  final void Function(int pointer, Offset imagePos) onDown;
  final void Function(int pointer, Offset imagePos)? onMove;
  final void Function(int pointer) onUp;
  final SkinPainter painter;
  /// Capa encima de [painter] que se repinta sola (animaciones: ver SkinPainter.repaint).
  final SkinPainter? foreground;
  /// Imágenes pegadas sobre la piel (asset, rectángulo en coordenadas de la original).
  final List<(String, Rect)> decals;
  final bool stretch;

  const SkinView({
    super.key,
    required this.skin,
    required this.onDown,
    required this.onUp,
    required this.painter,
    this.foreground,
    this.decals = const [],
    this.onMove,
    this.stretch = false,
  });

  @override
  Widget build(BuildContext context) {
    return ColoredBox(
      color: Colors.black,
      child: LayoutBuilder(builder: (context, box) {
        var sx = box.maxWidth / skin.width, sy = box.maxHeight / skin.height;
        if (!stretch) sx = sy = sx < sy ? sx : sy;
        final w = skin.width * sx, h = skin.height * sy;
        final origin = Offset((box.maxWidth - w) / 2, (box.maxHeight - h) / 2);
        Offset toImage(Offset local) {
          final d = local - origin;
          return Offset(d.dx / sx, d.dy / sy) + skin.origin;
        }

        return Listener(
          behavior: HitTestBehavior.opaque,
          onPointerDown: (e) => onDown(e.pointer, toImage(e.localPosition)),
          onPointerMove: onMove == null ? null : (e) => onMove!(e.pointer, toImage(e.localPosition)),
          onPointerUp: (e) => onUp(e.pointer),
          onPointerCancel: (e) => onUp(e.pointer),
          child: Stack(
            children: [
              Positioned(
                left: origin.dx,
                top: origin.dy,
                width: w,
                height: h,
                child: Image.asset(skin.asset, fit: BoxFit.fill, gaplessPlayback: true),
              ),
              for (final (asset, r) in decals)
                Positioned(
                  left: origin.dx + (r.left - skin.origin.dx) * sx,
                  top: origin.dy + (r.top - skin.origin.dy) * sy,
                  width: r.width * sx,
                  height: r.height * sy,
                  child: Image.asset(asset, fit: BoxFit.fill, gaplessPlayback: true),
                ),
              Positioned(
                left: origin.dx,
                top: origin.dy,
                width: w,
                height: h,
                child: CustomPaint(
                  painter: painter
                    ..sx = sx
                    ..sy = sy
                    ..origin = skin.origin,
                ),
              ),
              if (foreground != null)
                Positioned(
                  left: origin.dx,
                  top: origin.dy,
                  width: w,
                  height: h,
                  child: CustomPaint(
                    painter: foreground!
                      ..sx = sx
                      ..sy = sy
                      ..origin = skin.origin,
                  ),
                ),
            ],
          ),
        );
      }),
    );
  }
}

/// Painter de overlays (pulsaciones, rótulos) en coordenadas de la imagen original.
abstract class SkinPainter extends CustomPainter {
  SkinPainter({super.repaint});

  double sx = 1, sy = 1;
  Offset origin = Offset.zero;

  void paintSkin(Canvas canvas);

  /// Para los shouldRepaint de las subclases: cambió la escala o el recorte.
  bool geometryChanged(SkinPainter old) => old.sx != sx || old.sy != sy || old.origin != origin;

  @override
  void paint(Canvas canvas, Size size) {
    canvas.save();
    canvas.scale(sx, sy);
    canvas.translate(-origin.dx, -origin.dy);
    paintSkin(canvas);
    canvas.restore();
  }
}
