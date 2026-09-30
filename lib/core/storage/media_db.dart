import 'dart:io';

import 'package:path_provider/path_provider.dart';
import 'package:sqflite/sqflite.dart';

/// Base de datos de los medios (juegos) de la biblioteca: una fila por archivo,
/// clave = nombre del archivo en `<appDocs>/games`. Guarda todo lo que se sabe de
/// cada juego para no recalcularlo:
///
/// | columna       | contenido                                                        |
/// |---------------|------------------------------------------------------------------|
/// | file_screen   | pantalla (6912 B) sacada del archivo; vacía = no trae; NULL = sin mirar |
/// | net_screen    | pantalla de carga de ZXDB (6912 B)                                |
/// | capture       | captura del emulador, RGBA 256×192                                |
/// | zxdb_status   | NULL = sin consultar, 0 = no está en ZXDB, 1 = encontrado         |
/// | zxdb_id, title, year, publisher, genre | ficha de ZXDB                           |
/// | pad           | configuración del mando (JSON de PadConfig)                       |
/// | cfg           | ajustes propios del juego (JSON, ver AppSettings.loadForGame)      |
///
/// Sustituye a las cachés en archivos sueltos (`thumbs/`, `info/`), que se borran
/// al crear la base.
class MediaDb {
  static const _file = 'media.db';
  static Future<Database>? _db;

  static Future<Database> get _open => _db ??= _init();

  static Future<Database> _init() async {
    final dir = await getApplicationSupportDirectory();
    return openDatabase(
      '${dir.path}/$_file',
      version: 2,
      onCreate: (db, _) async {
        await db.execute('''
          CREATE TABLE media(
            name TEXT PRIMARY KEY,
            file_screen BLOB,
            net_screen BLOB,
            capture BLOB,
            zxdb_status INTEGER,
            zxdb_id INTEGER,
            title TEXT,
            year INTEGER,
            publisher TEXT,
            genre TEXT,
            pad TEXT,
            cfg TEXT
          )''');
        for (final old in const ['thumbs', 'info']) {
          try {
            await Directory('${dir.path}/$old').delete(recursive: true);
          } catch (_) {}
        }
      },
      onUpgrade: (db, from, _) async {
        if (from < 2) await db.execute('ALTER TABLE media ADD COLUMN cfg TEXT');
      },
    );
  }

  /// Clave de un juego: el nombre de su archivo ('' = BASIC sin medio).
  static String keyOf(String gamePath) =>
      gamePath.isEmpty ? '<basic>' : gamePath.split(RegExp(r'[\\/]')).last;

  /// Fila del juego (columnas pedidas, o todas), o null si no existe.
  static Future<Map<String, Object?>?> get(String gamePath, [List<String>? columns]) async {
    final rows = await (await _open).query('media',
        columns: columns, where: 'name = ?', whereArgs: [keyOf(gamePath)], limit: 1);
    return rows.isEmpty ? null : rows.first;
  }

  /// Crea la fila si falta y actualiza las columnas de [values].
  static Future<void> put(String gamePath, Map<String, Object?> values) async {
    final db = await _open;
    final key = keyOf(gamePath);
    await db.transaction((tx) async {
      await tx.insert('media', {'name': key}, conflictAlgorithm: ConflictAlgorithm.ignore);
      await tx.update('media', values, where: 'name = ?', whereArgs: [key]);
    });
  }

  static Future<void> delete(String gamePath) async {
    await (await _open).delete('media', where: 'name = ?', whereArgs: [keyOf(gamePath)]);
  }
}
