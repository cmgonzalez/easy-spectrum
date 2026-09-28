import 'package:flutter/services.dart';

/// Vibraciones de los controles con intensidad propia (MainActivity.kt, canal
/// `.../haptics`): los HapticFeedback de Flutter usan efectos del sistema que en
/// Samsung apenas se notan (selectionClick = CLOCK_TICK) y no se pueden graduar.
class Haptics {
  static const _channel = MethodChannel('cl.easysoft.easyspectrum/haptics');

  /// Cruceta al cambiar de dirección: corta y suave.
  static void tick() => _vibrate(10, 70);

  /// Fuego, botones y teclas: más firme que la cruceta.
  static void press() => _vibrate(22, 170);

  static void _vibrate(int ms, int amplitude) {
    _channel.invokeMethod('vibrate', {'ms': ms, 'amplitude': amplitude}).catchError((_) {
      HapticFeedback.lightImpact(); // sin el canal (otra plataforma)
    });
  }
}
