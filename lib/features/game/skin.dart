import 'package:flutter/material.dart';

export 'package:flutter/foundation.dart' show setEquals;

/// Imagen de fondo de un control y su tamaño original: toda la geometría de
/// teclas y botones se expresa en píxeles de esta imagen.
class SkinImage {
  final String asset;
  final double width;
  final double height;
  const SkinImage(this.asset, this.width, this.height);
}

/// Dibuja un [SkinImage] ajustado (contain, centrado) y traduce los toques a
/// coordenadas de la imagen. Multitáctil: cada puntero llega con su id.
class SkinView extends StatelessWidget {
  final SkinImage skin;
  final void Function(int pointer, Offset imagePos) onDown;
  final void Function(int pointer, Offset imagePos)? onMove;
  final void Function(int pointer) onUp;
  final SkinPainter painter;

  const SkinView({
    super.key,
    required this.skin,
    required this.onDown,
    required this.onUp,
    required this.painter,
    this.onMove,
  });

  @override
  Widget build(BuildContext context) {
    return ColoredBox(
      color: Colors.black,
      child: LayoutBuilder(builder: (context, box) {
        final scale = (box.maxWidth / skin.width) < (box.maxHeight / skin.height)
            ? box.maxWidth / skin.width
            : box.maxHeight / skin.height;
        final w = skin.width * scale, h = skin.height * scale;
        final origin = Offset((box.maxWidth - w) / 2, (box.maxHeight - h) / 2);
        Offset toImage(Offset local) => (local - origin) / scale;

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
              Positioned(
                left: origin.dx,
                top: origin.dy,
                width: w,
                height: h,
                child: CustomPaint(painter: painter..scale = scale),
              ),
            ],
          ),
        );
      }),
    );
  }
}

/// Painter de overlays (pulsaciones, rótulos) en coordenadas de la imagen.
abstract class SkinPainter extends CustomPainter {
  double scale = 1;

  void paintSkin(Canvas canvas);

  @override
  void paint(Canvas canvas, Size size) {
    canvas.save();
    canvas.scale(scale);
    paintSkin(canvas);
    canvas.restore();
  }
}
