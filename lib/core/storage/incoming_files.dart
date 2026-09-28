import 'package:flutter/services.dart';

import 'game_library.dart';

/// Archivo recibido de otra app ("Abrir con" / "Compartir"). [bytes] es null si
/// no se pudo leer.
class IncomingFile {
  final String name;
  final Uint8List? bytes;
  const IncomingFile(this.name, this.bytes);
}

/// Canal con MainActivity.kt: el archivo con el que se arrancó la app y los que
/// llegan con la app ya abierta.
class IncomingFiles {
  static const _channel = MethodChannel('cl.easysoft.easyspectrum/open');

  static void listen(void Function(IncomingFile file) onFile) {
    _channel.setMethodCallHandler((call) async {
      if (call.method == 'open') {
        final f = _parse(call.arguments);
        if (f != null) onFile(f);
      }
    });
    _channel.invokeMethod<Object?>('initial').then((a) {
      final f = _parse(a);
      if (f != null) onFile(f);
    }).catchError((_) {});
  }

  static IncomingFile? _parse(Object? args) {
    if (args is! Map) return null;
    final bytes = args['bytes'] as Uint8List?;
    final name = (args['name'] as String?) ?? 'game';
    return IncomingFile(bytes == null ? name : _fixName(name, bytes), bytes);
  }

  /// Algunas apps (WhatsApp, Telegram) cambian el nombre y pierden la extensión:
  /// se deduce del contenido cuando es posible.
  static String _fixName(String name, Uint8List b) {
    final ext = GameLibrary.extensionOf(name);
    if (ext == 'zip' || GameLibrary.isSupported(ext)) return name;
    bool starts(String magic) =>
        b.length >= magic.length && String.fromCharCodes(b.sublist(0, magic.length)) == magic;
    if (starts('ZXTape!')) return '$name.tzx';
    if (starts('PK\x03\x04')) return '$name.zip';
    if (starts('ZXST')) return '$name.szx';
    if (b.length == 49179 || b.length == 131103 || b.length == 147487) return '$name.sna';
    return name;
  }
}
