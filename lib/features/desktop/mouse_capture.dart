import 'dart:async';
import 'dart:ffi';

import 'package:ffi/ffi.dart';

/// Captura del puntero de Windows para el ratón Kempston/AMX del Spectrum: oculta el cursor,
/// lo confina a una zona pequeña en el centro de la ventana y, a ~125 Hz, convierte cuánto
/// se alejó del centro en un desplazamiento relativo y lo devuelve al centro. Se suelta con
/// [stop] (la pantalla lo llama con F9, al perder el foco o al quitar el ratón).
class MouseCapture {
  static final _user32 = DynamicLibrary.open('user32.dll');
  static final _getCursorPos =
      _user32.lookupFunction<Int32 Function(Pointer<Int32>), int Function(Pointer<Int32>)>('GetCursorPos');
  static final _setCursorPos =
      _user32.lookupFunction<Int32 Function(Int32, Int32), int Function(int, int)>('SetCursorPos');
  static final _showCursor = _user32.lookupFunction<Int32 Function(Int32), int Function(int)>('ShowCursor');
  static final _clipCursor =
      _user32.lookupFunction<Int32 Function(Pointer<Int32>), int Function(Pointer<Int32>)>('ClipCursor');
  static final _foreground = _user32.lookupFunction<IntPtr Function(), int Function()>('GetForegroundWindow');
  static final _getWindowRect = _user32.lookupFunction<Int32 Function(IntPtr, Pointer<Int32>),
      int Function(int, Pointer<Int32>)>('GetWindowRect');

  Timer? _timer;
  int _cx = 0, _cy = 0;
  double _remX = 0, _remY = 0;

  bool get active => _timer != null;

  /// Píxeles físicos del ratón de Windows por cada paso del ratón del Spectrum (≈ píxeles
  /// de pantalla por píxel del Spectrum); la pantalla lo actualiza según el tamaño de la imagen.
  double pixelsPerStep = 3.0;

  /// Empieza a capturar; [onMove] recibe dx, dy enteros (dy positivo = hacia abajo).
  bool start(void Function(int dx, int dy) onMove) {
    if (active) return true;
    final hwnd = _foreground();
    if (hwnd == 0) return false;
    final r = calloc<Int32>(4);
    try {
      if (_getWindowRect(hwnd, r) == 0) return false;
      _cx = (r[0] + r[2]) ~/ 2;
      _cy = (r[1] + r[3]) ~/ 2;
      // Zona de confinamiento de 400×400 px alrededor del centro.
      r[0] = _cx - 200;
      r[1] = _cy - 200;
      r[2] = _cx + 200;
      r[3] = _cy + 200;
      _clipCursor(r);
    } finally {
      calloc.free(r);
    }
    _showCursor(0);
    _setCursorPos(_cx, _cy);
    _remX = _remY = 0;
    final pt = calloc<Int32>(2);
    _timer = Timer.periodic(const Duration(milliseconds: 8), (_) {
      if (_getCursorPos(pt) == 0) return;
      final dx = pt[0] - _cx, dy = pt[1] - _cy;
      if (dx == 0 && dy == 0) return;
      _setCursorPos(_cx, _cy);
      _remX += dx / pixelsPerStep;
      _remY += dy / pixelsPerStep;
      final ix = _remX.truncate(), iy = _remY.truncate();
      if (ix != 0 || iy != 0) {
        _remX -= ix;
        _remY -= iy;
        onMove(ix, iy);
      }
    });
    _pt = pt;
    return true;
  }

  Pointer<Int32>? _pt;

  void stop() {
    final t = _timer;
    if (t == null) return;
    t.cancel();
    _timer = null;
    _clipCursor(nullptr);
    _showCursor(1);
    final pt = _pt;
    if (pt != null) calloc.free(pt);
    _pt = null;
  }
}
