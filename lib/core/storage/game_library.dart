import 'dart:io';
import 'dart:typed_data';

import 'package:archive/archive.dart';
import 'package:path_provider/path_provider.dart';

import '../emulator/zx_types.dart';

/// Biblioteca local de juegos: los archivos elegidos se copian a
/// <app documents>/games para poder relanzarlos sin volver a buscarlos.
class GameLibrary {
  static Future<Directory> _dir() async {
    final d = Directory('${(await getApplicationDocumentsDirectory()).path}/games');
    await d.create(recursive: true);
    return d;
  }

  static String extensionOf(String name) {
    final dot = name.lastIndexOf('.');
    return dot < 0 ? '' : name.substring(dot + 1).toLowerCase();
  }

  static String titleOf(String path) {
    final name = path.split(Platform.pathSeparator).last.split('/').last;
    final dot = name.lastIndexOf('.');
    return (dot > 0 ? name.substring(0, dot) : name).replaceAll('_', ' ');
  }

  /// Guarda [bytes] (o el primer juego dentro de un .zip) y devuelve la ruta.
  /// Lanza [FormatException] si no hay un formato soportado.
  static Future<String> import(String fileName, Uint8List bytes) async {
    var name = fileName;
    var data = bytes;
    if (extensionOf(name) == 'zip') {
      final archive = ZipDecoder().decodeBytes(bytes);
      final entry = archive.files.where((f) => f.isFile).firstWhere(
            (f) => zxMediaExtensions.contains(extensionOf(f.name)),
            orElse: () => throw const FormatException('El ZIP no contiene un juego de Spectrum'),
          );
      name = entry.name.split('/').last;
      data = entry.content;
    }
    if (!zxMediaExtensions.contains(extensionOf(name))) {
      throw FormatException('Formato no soportado: .${extensionOf(name)}');
    }
    final file = File('${(await _dir()).path}/$name');
    await file.writeAsBytes(data, flush: true);
    return file.path;
  }

  /// Juegos guardados, del más reciente al más antiguo.
  static Future<List<File>> list() async {
    final files = (await _dir())
        .listSync()
        .whereType<File>()
        .where((f) => zxMediaExtensions.contains(extensionOf(f.path)))
        .toList();
    files.sort((a, b) => b.statSync().modified.compareTo(a.statSync().modified));
    return files;
  }

  /// Marca un juego como el más reciente.
  static Future<void> touch(String path) async {
    try {
      await File(path).setLastModified(DateTime.now());
    } catch (_) {}
  }
}
