import 'dart:convert';


import 'emulator/zx_types.dart';
import 'storage/media_db.dart';

/// Configuración del mando de un juego: tipo de joystick, teclas del modo
/// "Teclado" y hasta 3 botones extra con cualquier tecla. Se guarda por juego en
/// [MediaDb]; sin configuración propia se usa el tipo por defecto de Ajustes.
class PadConfig {
  static const maxExtra = 3;

  JoyMapping type;
  final List<int> keys; // [arriba, abajo, izquierda, derecha, fuego] del modo Teclado
  final List<int?> extra; // null = botón desactivado

  PadConfig({required this.type, List<int>? keys, List<int?>? extra})
      : keys = List.of(keys ?? defaultPadKeys),
        extra = List.of(extra ?? List.filled(maxExtra, null));

  PadConfig copy() => PadConfig(type: type, keys: keys, extra: extra);

  /// Teclas de cada dirección, o null si es Kempston (joystick real).
  List<int>? get directionKeys => type == JoyMapping.keyboard ? keys : type.keys;

  /// Teclas de los botones extra activados, en orden.
  List<int> get extraKeys => extra.whereType<int>().toList();

  static Future<PadConfig> load(String gamePath, JoyMapping fallback) async {
    try {
      final raw = (await MediaDb.get(gamePath, ['pad']))?['pad'] as String?;
      if (raw != null) {
        final j = jsonDecode(raw) as Map<String, Object?>;
        final keys = (j['keys'] as List).cast<int>();
        final extra = (j['extra'] as List).cast<int?>();
        return PadConfig(
          type: JoyMapping.byName(j['type'] as String?) ?? fallback,
          keys: keys.length == 5 ? keys : null,
          extra: extra.length == maxExtra ? extra : null,
        );
      }
    } catch (_) {}
    return PadConfig(type: fallback);
  }

  /// true si el juego tiene configuración propia (si no, sigue el tipo de Ajustes).
  static Future<bool> isSaved(String gamePath) async =>
      (await MediaDb.get(gamePath, ['pad']))?['pad'] != null;

  Future<void> save(String gamePath) => MediaDb.put(
      gamePath, {'pad': jsonEncode({'type': type.name, 'keys': keys, 'extra': extra})});
}
