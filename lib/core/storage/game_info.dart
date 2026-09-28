import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:flutter/foundation.dart';

import 'game_thumbnail.dart';
import 'media_db.dart';

/// Ficha de un juego según ZXDB (vía la API de ZXInfo).
class GameInfo {
  final int id;
  final String title;
  final int? year;
  final String? publisher;
  final String? genre;
  const GameInfo({required this.id, required this.title, this.year, this.publisher, this.genre});

  /// "1986 · Ocean Software Ltd"
  String get subtitle => [
        if (year != null) '$year',
        if (publisher != null)
          publisher!.replaceAll(RegExp(r',?\s+(Ltd\.?|Limited|Inc\.?|S\.?A\.?|plc)$', caseSensitive: false), ''),
      ].join(' · ');
}

/// Identifica los juegos por el MD5 del archivo en ZXDB (api.zxinfo.dk, gratuita,
/// sin cuenta) y baja la pantalla de carga (.scr de 6912 bytes) para la miniatura.
/// Solo reconoce volcados conocidos (WOS, TOSEC, Spectrum Computing…): la búsqueda
/// por nombre no es fiable ("Cobra" da primero el de ZX81), así que no se usa.
///
/// Se guarda en [MediaDb] (zxdb_status 0 = no está en ZXDB, no se vuelve a
/// preguntar). Los errores de red no se guardan: se reintenta en otra sesión.
class GameInfoService {
  static const _api = 'https://api.zxinfo.dk/v3';
  static const _media = 'https://zxinfo.dk/media';
  static const _agent = 'EasySpectrum/1.0 (Android; soporte@easysoft.cl)';

  /// Ajuste "Buscar datos en internet" (lo fija la pantalla de inicio).
  static bool enabled = true;

  static final Map<String, GameInfo?> _memory = {};
  static final Map<String, Future<GameInfo?>> _pending = {};

  /// Ficha en caché (sin red), o null.
  static GameInfo? cached(String gamePath) => _memory[gamePath];

  /// Ficha del juego: de la caché o, si está activado, de ZXInfo.
  static Future<GameInfo?> load(String gamePath) {
    if (_memory.containsKey(gamePath)) return Future.value(_memory[gamePath]);
    return _pending.putIfAbsent(gamePath, () async {
      try {
        final row = await MediaDb.get(
            gamePath, ['zxdb_status', 'zxdb_id', 'title', 'year', 'publisher', 'genre']);
        final status = row?['zxdb_status'] as int?;
        if (status != null) {
          return _memory[gamePath] = status == 1
              ? GameInfo(
                  id: row!['zxdb_id'] as int,
                  title: row['title'] as String,
                  year: row['year'] as int?,
                  publisher: row['publisher'] as String?,
                  genre: row['genre'] as String?,
                )
              : null;
        }
        if (!enabled) return null; // sin guardar en memoria: al activarlo se consulta
        final info = await _fetch(gamePath);
        await MediaDb.put(gamePath, {
          'zxdb_status': info == null ? 0 : 1,
          'zxdb_id': info?.id,
          'title': info?.title,
          'year': info?.year,
          'publisher': info?.publisher,
          'genre': info?.genre,
        });
        return _memory[gamePath] = info;
      } catch (e) {
        debugPrint('ZXInfo: $e');
        return _memory[gamePath] = null; // red caída: no insistir en esta sesión
      } finally {
        _pending.remove(gamePath);
      }
    });
  }

  /// Olvida la ficha en memoria (la fila de la base la borra GameLibrary).
  static void forget(String gamePath) => _memory.remove(gamePath);

  /// null = no está en ZXDB. Lanza excepción si falla la red.
  static Future<GameInfo?> _fetch(String gamePath) async {
    final data = await File(gamePath).readAsBytes();
    // Un archivo vacío coincide con entradas de ZXDB que traen archivos vacíos
    // (p. ej. "Colours"): nunca identificar algo tan pequeño.
    if (data.length < 256) return null;
    final hash = md5.convert(data).toString();
    final check = await _getJson('$_api/filecheck/$hash');
    if (check == null) return null;
    final id = int.parse('${check['entry_id']}');
    final entry = await _getJson('$_api/games/${check['entry_id']}?mode=compact');
    final src = (entry?['_source'] as Map<String, Object?>?) ?? check;

    final publishers = src['publishers'] as List?;
    final info = GameInfo(
      id: id,
      title: (src['title'] as String?) ?? (check['title'] as String),
      year: src['originalYearOfRelease'] as int?,
      publisher: publishers != null && publishers.isNotEmpty
          ? (publishers.first as Map)['name'] as String?
          : null,
      genre: src['genre'] as String?,
    );

    // Pantalla de carga (o, si no hay, la de juego) en formato .scr.
    final screens = (src['screens'] as List?)?.cast<Map>() ?? const [];
    String? scr;
    for (final type in const ['Loading screen', 'Running screen']) {
      for (final s in screens) {
        final url = s['scrUrl'] as String?;
        if (s['type'] == type && url != null && url.toLowerCase().endsWith('.scr')) {
          scr ??= url;
        }
      }
    }
    if (scr != null) {
      final bytes = await _getBytes('$_media$scr');
      if (bytes != null && bytes.length == GameThumbnail.screenSize) {
        await GameThumbnail.saveNetScreen(gamePath, bytes);
      }
    }
    return info;
  }

  static Future<Uint8List?> _getBytes(String url) async {
    final client = HttpClient()
      ..connectionTimeout = const Duration(seconds: 10)
      ..userAgent = _agent;
    try {
      final req = await client.getUrl(Uri.parse(url));
      final res = await req.close().timeout(const Duration(seconds: 20));
      if (res.statusCode == 404) return null;
      if (res.statusCode != 200) throw HttpException('HTTP ${res.statusCode}');
      final builder = BytesBuilder(copy: false);
      await for (final chunk in res.timeout(const Duration(seconds: 20))) {
        builder.add(chunk);
      }
      return builder.takeBytes();
    } finally {
      client.close();
    }
  }

  static Future<Map<String, Object?>?> _getJson(String url) async {
    final bytes = await _getBytes(url);
    return bytes == null ? null : jsonDecode(utf8.decode(bytes)) as Map<String, Object?>;
  }
}
