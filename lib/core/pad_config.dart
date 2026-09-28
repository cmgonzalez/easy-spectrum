import 'dart:convert';


import 'emulator/zx_types.dart';
import 'storage/media_db.dart';

/// Configuración del mando de un juego: tipo de joystick, teclas del modo
/// "Teclado" y botonera de 1-4 botones (rojo = fuego; los demás, cualquier
/// tecla). Se guarda por juego en [MediaDb]; sin configuración propia se usa el
/// tipo por defecto de Ajustes.
class PadConfig {
  static const maxButtons = 4; // rojo (fuego) + amarillo, verde, azul
  static const defaultExtra = [ZxKey.space, ZxKey.enter, ZxKey.y];
  static const maxSystem = 2; // botones Select / Start sobre el LCD
  static const defaultSystem = [ZxKey.enter, ZxKey.space];

  JoyMapping type;
  final List<int> keys; // [arriba, abajo, izquierda, derecha, fuego] del modo Teclado
  int buttons; // 1-4 botones en la botonera (el rojo siempre es fuego)
  final List<int> extra; // teclas de amarillo, verde y azul
  int system; // 0-2 botones Select / Start
  final List<int> systemKeys;

  PadConfig({
    required this.type,
    List<int>? keys,
    this.buttons = 1,
    List<int>? extra,
    this.system = 0,
    List<int>? systemKeys,
  })  : keys = List.of(keys ?? defaultPadKeys),
        extra = List.of(extra ?? defaultExtra),
        systemKeys = List.of(systemKeys ?? defaultSystem);

  PadConfig copy() => PadConfig(
      type: type, keys: keys, buttons: buttons, extra: extra, system: system, systemKeys: systemKeys);

  /// Teclas de cada dirección, o null si es Kempston (joystick real).
  List<int>? get directionKeys => type == JoyMapping.keyboard ? keys : type.keys;

  /// Teclas de los botones extra visibles (amarillo, verde, azul), en orden.
  List<int> get extraKeys => extra.take(buttons - 1).toList();

  /// Teclas de los botones Select / Start visibles.
  List<int> get selectKeys => systemKeys.take(system).toList();

  static Future<PadConfig> load(String gamePath, JoyMapping fallback) async {
    try {
      final raw = (await MediaDb.get(gamePath, ['pad']))?['pad'] as String?;
      if (raw != null) {
        final j = jsonDecode(raw) as Map<String, Object?>;
        final keys = (j['keys'] as List).cast<int>();
        // Formato anterior: 'extra' con null = botón apagado y sin 'buttons'. Las
        // teclas usadas quedan primero (son los botones visibles).
        final saved = (j['extra'] as List? ?? const []).cast<int?>();
        final used = saved.whereType<int>().toList();
        final extra = saved.length == used.length ? used : [...used, ...defaultExtra];
        final buttons = (j['buttons'] as int?) ?? 1 + used.length;
        return PadConfig(
          type: JoyMapping.byName(j['type'] as String?) ?? fallback,
          keys: keys.length == 5 ? keys : null,
          buttons: buttons.clamp(1, maxButtons),
          extra: extra.length >= 3 ? extra.take(3).toList() : null,
          system: ((j['system'] as int?) ?? 0).clamp(0, maxSystem),
          systemKeys: (j['systemKeys'] as List?)?.cast<int>(),
        );
      }
    } catch (_) {}
    return PadConfig(type: fallback);
  }

  /// true si el juego tiene configuración propia (si no, sigue el tipo de Ajustes).
  static Future<bool> isSaved(String gamePath) async =>
      (await MediaDb.get(gamePath, ['pad']))?['pad'] != null;

  Future<void> save(String gamePath) => MediaDb.put(
      gamePath,
      {'pad': jsonEncode({
        'type': type.name,
        'keys': keys,
        'buttons': buttons,
        'extra': extra,
        'system': system,
        'systemKeys': systemKeys,
      })});
}
