import 'dart:async';
import 'dart:io';
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:archive/archive.dart';
import 'package:flutter/foundation.dart';
import 'package:path_provider/path_provider.dart';

/// Miniaturas de juegos a partir de su pantalla del Spectrum (6912 bytes: 6144 de
/// píxeles + 768 de atributos, lo que el ROM guarda en $4000):
/// - .tap / .tzx: la pantalla de carga (SCREEN$). Lógica portada de easytape-app.
/// - .sna / .z80 / .szx: la RAM del snapshot (respetando la pantalla sombra del 128K).
/// - Si el archivo no trae pantalla extraíble (.dsk, .csw, cintas con la pantalla
///   cifrada o comprimida), se usa la última pantalla del emulador al salir del
///   juego ([saveCaptureIfMissing]). Sin eso, la UI muestra el ícono genérico.
///
/// Caché en `<appSupport>/thumbs/`: `<nombre>.scr` (6912 bytes; vacío = el archivo
/// no tiene pantalla), `<nombre>.net.scr` (pantalla de ZXDB) y `<nombre>.rgba`
/// (captura 256×192 RGBA). Prioridad: archivo > ZXDB > captura. Imagen decodificada
/// en memoria.
class GameThumbnail {
  static const screenSize = 6912;
  static final Map<String, ui.Image?> _memory = {};
  static final Map<String, Future<ui.Image?>> _pending = {};

  static const _captureSize = 256 * 192 * 4;

  /// Imagen 256×192 de la pantalla del juego, o null si no hay ninguna.
  static Future<ui.Image?> load(String gamePath) {
    if (_memory.containsKey(gamePath)) return Future.value(_memory[gamePath]);
    return _pending.putIfAbsent(gamePath, () async {
      try {
        final screen = await _screenFor(gamePath) ?? await _netScreen(gamePath);
        ui.Image? image;
        if (screen != null) {
          image = await _render(screen);
        } else {
          final capture = await _cacheFile(gamePath, 'rgba');
          if (await capture.exists()) {
            final rgba = await capture.readAsBytes();
            if (rgba.length == _captureSize) image = await _decode(rgba);
          }
        }
        _memory[gamePath] = image;
        return image;
      } catch (_) {
        _memory[gamePath] = null;
        return null;
      } finally {
        _pending.remove(gamePath);
      }
    });
  }

  /// Borra la caché de un juego (al quitarlo de la biblioteca).
  static Future<void> forget(String gamePath) async {
    _memory.remove(gamePath)?.dispose();
    for (final ext in const ['scr', 'net.scr', 'rgba']) {
      try {
        await (await _cacheFile(gamePath, ext)).delete();
      } catch (_) {}
    }
  }

  /// true si el juego no trae pantalla propia ni tiene captura todavía.
  static Future<bool> needsCapture(String gamePath) async {
    try {
      if (await _screenFor(gamePath) != null) return false;
      if (await _netScreen(gamePath) != null) return false;
      return !await (await _cacheFile(gamePath, 'rgba')).exists();
    } catch (_) {
      return false;
    }
  }

  /// Colores distintos (hasta [max]) en la zona de papel del framebuffer RGBA
  /// 320×256: 1 = pantalla lisa (carga en negro), 2 = texto, 3+ = imagen.
  static int paperColours(Uint8List framebuffer, [int max = 3]) {
    final words = framebuffer.buffer.asUint32List(framebuffer.offsetInBytes, framebuffer.length ~/ 4);
    final colours = <int>{};
    for (var y = 32; y < 224; y++) {
      for (var x = 32; x < 288; x += 3) {
        colours.add(words[y * 320 + x]);
        if (colours.length >= max) return max;
      }
    }
    return colours.length;
  }

  /// Guarda la pantalla del emulador ([framebuffer] RGBA 320×256 con borde) como
  /// miniatura, solo si el archivo del juego no trae pantalla propia y aún no hay
  /// captura. Se descartan pantallas lisas: devuelve false para que se reintente;
  /// true = guardada o no hace falta.
  static Future<bool> saveCaptureIfMissing(String gamePath, Uint8List framebuffer) async {
    try {
      if (!await needsCapture(gamePath)) return true;
      if (paperColours(framebuffer, 2) < 2) return false;
      final file = await _cacheFile(gamePath, 'rgba');
      // Zona de papel: 256×192 desde (32, 32) en el framebuffer de 320×256.
      final crop = Uint8List(_captureSize);
      for (var y = 0; y < 192; y++) {
        final src = ((y + 32) * 320 + 32) * 4;
        crop.setRange(y * 1024, y * 1024 + 1024, framebuffer, src);
      }
      await file.writeAsBytes(crop, flush: true);
      _memory.remove(gamePath)?.dispose();
      return true;
    } catch (_) {
      return true;
    }
  }

  /// Pantalla de carga bajada de ZXDB (ver GameInfoService): se usa si el archivo
  /// no trae una propia, antes que la captura del emulador.
  static Future<void> saveNetScreen(String gamePath, Uint8List screen) async {
    await (await _cacheFile(gamePath, 'net.scr')).writeAsBytes(screen, flush: true);
    _memory.remove(gamePath)?.dispose();
  }

  static Future<Uint8List?> _netScreen(String gamePath) async {
    final f = await _cacheFile(gamePath, 'net.scr');
    if (!await f.exists()) return null;
    final bytes = await f.readAsBytes();
    return bytes.length == screenSize ? bytes : null;
  }

  static Future<File> _cacheFile(String gamePath, [String ext = 'scr']) async {
    final dir = Directory('${(await getApplicationSupportDirectory()).path}/thumbs');
    await dir.create(recursive: true);
    final name = gamePath.split(RegExp(r'[\\/]')).last;
    return File('${dir.path}/$name.$ext');
  }

  /// Pantalla desde la caché, o extraída del archivo del juego. Un archivo vacío
  /// en la caché marca "este juego no tiene pantalla" para no volver a buscar.
  static Future<Uint8List?> _screenFor(String gamePath) async {
    final cache = await _cacheFile(gamePath);
    if (await cache.exists()) {
      final bytes = await cache.readAsBytes();
      return bytes.length == screenSize ? bytes : null;
    }
    final data = await File(gamePath).readAsBytes();
    final ext = gamePath.split('.').last.toLowerCase();
    final screen = extractScreen(ext, data);
    await cache.writeAsBytes(screen ?? Uint8List(0), flush: true);
    return screen;
  }

  /// Los 6912 bytes de pantalla para un juego ya leído en memoria, o null.
  static Uint8List? extractScreen(String ext, Uint8List data) {
    try {
      return extractScreenOrThrow(ext, data);
    } catch (_) {
      return null;
    }
  }

  @visibleForTesting
  static Uint8List? extractScreenOrThrow(String ext, Uint8List data) {
    {
      return switch (ext) {
        'tap' => _fromTap(data),
        'tzx' => _fromTzx(data),
        'sna' => _fromSna(data),
        'z80' => _fromZ80(data),
        'szx' => _fromSzx(data),
        _ => null,
      };
    }
  }

  // --- Cintas: busca el bloque SCREEN$ --------------------------------------

  /// Busca la pantalla en los bloques de una cinta. `flagged` = bloque estilo TAP
  /// (flag + datos + checksum: 0x10/0x11); los 0x14 (datos puros) vienen sin nada.
  /// 1. Header Code con dirección $4000 → la pantalla es segura.
  /// 2. Candidatos validados con [_looksLikeScreen], en orden de cinta:
  ///    bloques ≥ 6912 (turbo 0x11 incluidos; offsets 1/0/2/3) y pantalla partida
  ///    en un bloque de 6144 (píxeles) seguido de otro de 768 (atributos).
  /// Muchos cargadores protegidos (Speedlock, etc.) cifran la pantalla: el filtro
  /// los descarta en vez de pintar basura.
  static Uint8List? _findScreenBlock(Iterable<(Uint8List, bool)> blocks) {
    int? lastHeaderType, lastHeaderAddr;
    Uint8List? pendingPixels; // bloque de 6144 esperando sus atributos
    var sincePixels = 0;
    for (final (block, flagged) in blocks) {
      if (block.isEmpty) continue;
      if (flagged && block[0] < 128 && block.length >= 18) {
        lastHeaderType = block[1];
        lastHeaderAddr = block[14] | (block[15] << 8);
        continue;
      }
      // Datos útiles: sin flag ni checksum en bloques TAP.
      final data = flagged && block.length >= 2
          ? Uint8List.sublistView(block, 1, block.length - 1)
          : block;

      if (lastHeaderType == 3 && lastHeaderAddr == 0x4000 && data.length >= screenSize) {
        return Uint8List.fromList(data.sublist(0, screenSize));
      }
      lastHeaderType = null;
      lastHeaderAddr = null;

      // Pantalla partida en píxeles + atributos.
      if (data.length == 6144) {
        pendingPixels = data;
        sincePixels = 0;
      } else if (pendingPixels != null) {
        if (data.length == 768) {
          final screen = Uint8List(screenSize)
            ..setAll(0, pendingPixels)
            ..setAll(6144, data);
          if (_looksLikeScreen(screen)) return screen;
        }
        if (++sincePixels > 3) pendingPixels = null;
      }

      if (data.length >= screenSize) {
        // Bloques TAP: la pantalla suele empezar justo tras el flag (offset 0 de
        // `data`); algunos cargadores turbo meten 1-3 bytes propios delante.
        final raw = flagged ? block : data;
        for (final off in flagged ? const [1, 0, 2, 3] : const [0, 1, 2, 3]) {
          if (off + screenSize > raw.length) break;
          final screen = Uint8List.fromList(raw.sublist(off, off + screenSize));
          if (_looksLikeScreen(screen)) return screen;
        }
      }
    }
    return null;
  }

  /// ¿6912 bytes con pinta de pantalla? Una pantalla real repite pocas combinaciones
  /// de tinta/papel y casi no usa FLASH; código, datos comprimidos o cifrados dan
  /// cientos de atributos distintos (o FLASH por todas partes).
  static bool _looksLikeScreen(Uint8List s) {
    final attrs = <int>{};
    var flash = 0;
    for (var i = 6144; i < screenSize; i++) {
      attrs.add(s[i]);
      if (s[i] & 0x80 != 0) flash++;
    }
    if (attrs.length > 64 || flash > 768 ~/ 4) return false;
    // Píxeles no triviales (descarta buffers vacíos o de relleno).
    final pixels = <int>{};
    for (var i = 0; i < 6144 && pixels.length < 8; i += 7) {
      pixels.add(s[i]);
    }
    if (pixels.length < 8) return false;
    // Coherencia vertical: en una imagen cada fila de píxeles se parece a la de
    // abajo (≤ 2 bits distintos). Medido: pantallas reales 0,61–0,71; datos
    // cifrados/comprimidos o código 0,18–0,31.
    var same = 0, total = 0;
    for (var y = 0; y < 191; y++) {
      for (var cx = 0; cx < 32; cx++) {
        final a = s[_pixelAddr(y, cx)], b = s[_pixelAddr(y + 1, cx)];
        if (a == 0 && b == 0) continue;
        total++;
        var diff = a ^ b, bits = 0;
        while (diff != 0) {
          bits += diff & 1;
          diff >>= 1;
        }
        if (bits <= 2) same++;
      }
    }
    return total > 0 && same / total >= 0.45;
  }

  static int _pixelAddr(int y, int cx) =>
      ((y & 0xC0) << 5) | ((y & 0x07) << 8) | ((y & 0x38) << 2) | cx;

  static Uint8List? _fromTap(Uint8List d) {
    Iterable<(Uint8List, bool)> blocks() sync* {
      var pos = 0;
      while (pos + 1 < d.length) {
        final len = d[pos] | (d[pos + 1] << 8);
        pos += 2;
        if (pos + len > d.length) return;
        yield (Uint8List.sublistView(d, pos, pos + len), true);
        pos += len;
      }
    }

    return _findScreenBlock(blocks());
  }

  static Uint8List? _fromTzx(Uint8List d) {
    if (d.length < 10 || String.fromCharCodes(d.sublist(0, 7)) != 'ZXTape!') return null;
    int le(int o, int n) {
      var v = 0;
      for (var i = n - 1; i >= 0; i--) {
        v = (v << 8) | d[o + i];
      }
      return v;
    }

    Iterable<(Uint8List, bool)> blocks() sync* {
      var p = 10;
      while (p < d.length) {
        final id = d[p++];
        int skip; // bytes hasta el siguiente bloque
        switch (id) {
          case 0x10: // estándar: pausa(2) len(2) datos
            final len = le(p + 2, 2);
            yield (Uint8List.sublistView(d, p + 4, p + 4 + len), true);
            skip = 4 + len;
          case 0x11: // turbo: 15 bytes de tiempos, len(3) en +15, datos en +18
            final len = le(p + 15, 3);
            yield (Uint8List.sublistView(d, p + 18, p + 18 + len), true);
            skip = 18 + len;
          case 0x14: // datos puros: sin semántica de header
            final len = le(p + 7, 3);
            yield (Uint8List.sublistView(d, p + 10, p + 10 + len), false);
            skip = 10 + len;
          case 0x12: skip = 4;
          case 0x13: skip = 1 + d[p] * 2;
          case 0x15: skip = 8 + le(p + 5, 3);
          case 0x18 || 0x19 || 0x2B: skip = 4 + le(p, 4);
          case 0x20 || 0x23 || 0x24: skip = 2;
          case 0x21 || 0x30: skip = 1 + d[p];
          case 0x22 || 0x25 || 0x27: skip = 0;
          case 0x26: skip = 2 + le(p, 2) * 2;
          case 0x28 || 0x32: skip = 2 + le(p, 2);
          case 0x2A: skip = 4;
          case 0x31: skip = 2 + d[p + 1];
          case 0x33: skip = 1 + d[p] * 3;
          case 0x35: skip = 20 + le(p + 16, 4);
          case 0x5A: skip = 9;
          default: return; // bloque desconocido: no se puede seguir
        }
        p += skip;
      }
    }

    return _findScreenBlock(blocks());
  }

  // --- Snapshots: pantalla desde la RAM ---------------------------------------

  static const _bank = 16384;

  /// Banco de la pantalla visible en un 128K: 7 si el bit 3 de $7FFD está activo.
  static int _screenBank(int port7ffd) => (port7ffd & 0x08) != 0 ? 7 : 5;

  static Uint8List? _fromSna(Uint8List d) {
    const header = 27;
    if (d.length == header + 3 * _bank) {
      return Uint8List.fromList(d.sublist(header, header + screenSize)); // 48K: $4000
    }
    // 128K: 48K (bancos 5, 2, paginado) + PC(2) 7FFD(1) TR-DOS(1) + resto de bancos.
    const tail = header + 3 * _bank + 4;
    if (d.length != tail + 5 * _bank && d.length != tail + 6 * _bank) return null;
    final port = d[header + 3 * _bank + 2];
    if (_screenBank(port) == 5) return Uint8List.fromList(d.sublist(header, header + screenSize));
    final paged = port & 7;
    if (paged == 7) {
      return Uint8List.fromList(d.sublist(header + 2 * _bank, header + 2 * _bank + screenSize));
    }
    var offset = tail;
    for (var bank = 0; bank < 7; bank++) {
      if (bank == 5 || bank == 2 || bank == paged) continue;
      offset += _bank; // bancos anteriores al 7 que vienen en el resto
    }
    return Uint8List.fromList(d.sublist(offset, offset + screenSize));
  }

  static Uint8List? _fromZ80(Uint8List d) {
    if (d.length < 30) return null;
    final pc = d[6] | (d[7] << 8);
    if (pc != 0) {
      // Versión 1: 48K, RAM ($4000-$FFFF) comprimida si el bit 5 del byte 12 está activo.
      final compressed = (d[12] & 0x20) != 0;
      final ram = compressed ? _z80Decompress(Uint8List.sublistView(d, 30), 3 * _bank) : d.sublist(30);
      return ram.length >= screenSize ? Uint8List.fromList(ram.sublist(0, screenSize)) : null;
    }
    // Versión 2/3: cabecera extra y páginas de 16K.
    final extraLen = d[30] | (d[31] << 8);
    final hw = d[34];
    final version3 = extraLen >= 54;
    // v2: 3-4 = 128K. v3: 0, 1 y 3 son 48K; el resto (128K, +2, +2A, +3, Pentagon…) pagina igual.
    final is128 = version3 ? !(hw == 0 || hw == 1 || hw == 3) : (hw == 3 || hw == 4);
    // Página con la pantalla: 48K → página 8 ($4000). 128K → banco 5 o 7 (página = banco + 3).
    final page = is128 ? _screenBank(d[35]) + 3 : 8;
    var p = 32 + extraLen;
    while (p + 3 <= d.length) {
      final len = d[p] | (d[p + 1] << 8);
      final pageNo = d[p + 2];
      p += 3;
      final raw = len == 0xFFFF;
      final size = raw ? _bank : len;
      if (pageNo == page) {
        final block = Uint8List.sublistView(d, p, p + size);
        final ram = raw ? block : _z80Decompress(block, _bank);
        return ram.length >= screenSize ? Uint8List.fromList(ram.sublist(0, screenSize)) : null;
      }
      p += size;
    }
    return null;
  }

  /// RLE del formato .z80: ED ED nn bb = nn veces el byte bb.
  static Uint8List _z80Decompress(Uint8List src, int maxOut) {
    final out = BytesBuilder(copy: false);
    var n = 0;
    var i = 0;
    final buf = Uint8List(maxOut);
    while (i < src.length && n < maxOut) {
      if (i + 3 < src.length && src[i] == 0xED && src[i + 1] == 0xED) {
        final count = src[i + 2], value = src[i + 3];
        for (var k = 0; k < count && n < maxOut; k++) {
          buf[n++] = value;
        }
        i += 4;
      } else {
        buf[n++] = src[i++];
      }
    }
    out.add(Uint8List.sublistView(buf, 0, n));
    return out.takeBytes();
  }

  static Uint8List? _fromSzx(Uint8List d) {
    if (d.length < 8 || String.fromCharCodes(d.sublist(0, 4)) != 'ZXST') return null;
    int le32(int o) => d[o] | (d[o + 1] << 8) | (d[o + 2] << 16) | (d[o + 3] << 24);
    var port7ffd = 0;
    final pages = <int, Uint8List>{};
    var p = 8;
    while (p + 8 <= d.length) {
      final id = String.fromCharCodes(d.sublist(p, p + 4));
      final size = le32(p + 4);
      final body = p + 8;
      if (body + size > d.length) break;
      if (id == 'SPCR' && size >= 2) port7ffd = d[body + 1];
      if (id == 'RAMP' && size >= 3) {
        final flags = d[body] | (d[body + 1] << 8);
        final page = d[body + 2];
        final data = Uint8List.sublistView(d, body + 3, body + size);
        pages[page] = (flags & 1) != 0
            ? Uint8List.fromList(const ZLibDecoder().decodeBytes(data))
            : Uint8List.fromList(data);
      }
      p = body + size;
    }
    // En 48K la pantalla también está en la página 5; en 128K puede ser la 7.
    final page = pages[_screenBank(port7ffd)] ?? pages[5];
    return page != null && page.length >= screenSize
        ? Uint8List.fromList(page.sublist(0, screenSize))
        : null;
  }

  // --- Render ------------------------------------------------------------------

  static const _normal = [
    0xFF000000, 0xFFCD0000, 0xFF0000CD, 0xFFCD00CD, // ABGR: negro, azul, rojo, magenta
    0xFF00CD00, 0xFFCDCD00, 0xFF00CDCD, 0xFFCDCDCD, //       verde, cian, amarillo, blanco
  ];
  static const _bright = [
    0xFF000000, 0xFFFF0000, 0xFF0000FF, 0xFFFF00FF,
    0xFF00FF00, 0xFFFFFF00, 0xFF00FFFF, 0xFFFFFFFF,
  ];

  static Future<ui.Image> _decode(Uint8List rgba) {
    final c = Completer<ui.Image>();
    ui.decodeImageFromPixels(rgba, 256, 192, ui.PixelFormat.rgba8888, c.complete);
    return c.future;
  }

  /// 256×192 RGBA (memoria little-endian: los valores de la paleta van como 0xAABBGGRR).
  static Future<ui.Image> _render(Uint8List screen) {
    final pixels = Uint32List(256 * 192);
    for (var y = 0; y < 192; y++) {
      final rowBase = ((y & 0xC0) << 5) | ((y & 0x07) << 8) | ((y & 0x38) << 2);
      for (var cx = 0; cx < 32; cx++) {
        final bits = screen[rowBase | cx];
        final attr = screen[6144 + (y >> 3) * 32 + cx];
        final pal = (attr & 0x40) != 0 ? _bright : _normal;
        final ink = pal[attr & 7], paper = pal[(attr >> 3) & 7];
        final o = y * 256 + cx * 8;
        for (var b = 0; b < 8; b++) {
          pixels[o + b] = (bits & (0x80 >> b)) != 0 ? ink : paper;
        }
      }
    }
    final c = Completer<ui.Image>();
    ui.decodeImageFromPixels(
        pixels.buffer.asUint8List(), 256, 192, ui.PixelFormat.rgba8888, c.complete);
    return c.future;
  }
}
