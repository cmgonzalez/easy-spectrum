import 'dart:ui' as ui;

import 'package:flutter/services.dart';

/// Copia la parte visible de [frame] ([src], sin el borde recortado) al portapapeles de Windows
/// como imagen. Se escala con la proporción [aspect] de la pantalla (los píxeles de algunas
/// máquinas no son cuadrados) hasta tener al menos [minHeight] px de alto, para que al pegarla
/// no salga diminuta. [channel] es el canal del runner de Windows (método `copyImage`).
Future<bool> copyFrameToClipboard(
  MethodChannel channel,
  ui.Image frame,
  ui.Rect src,
  double aspect, {
  int minHeight = 720,
}) async {
  final k = (minHeight / src.height).ceil().clamp(1, 8);
  final h = (src.height * k).round();
  final w = (h * aspect).round();
  final exact = w % src.width.round() == 0 && h % src.height.round() == 0;
  final recorder = ui.PictureRecorder();
  ui.Canvas(recorder).drawImageRect(
    frame,
    src,
    ui.Rect.fromLTWH(0, 0, w.toDouble(), h.toDouble()),
    ui.Paint()..filterQuality = exact ? ui.FilterQuality.none : ui.FilterQuality.medium,
  );
  final picture = recorder.endRecording();
  final img = await picture.toImage(w, h);
  picture.dispose();
  final bytes = await img.toByteData(format: ui.ImageByteFormat.rawRgba);
  img.dispose();
  if (bytes == null) return false;
  final ok = await channel.invokeMethod<bool>('copyImage', {
    'width': w,
    'height': h,
    'data': bytes.buffer.asUint8List(bytes.offsetInBytes, bytes.lengthInBytes),
  });
  return ok ?? false;
}
