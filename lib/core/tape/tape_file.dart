import 'dart:io';
import 'dart:typed_data';

/// Cintas .tap / .tzx como lista de bloques (gestor de cintas, doc/TAPE_MANAGER.md).
///
/// La numeración de bloques es la MISMA que usa el bridge nativo (`scan_tap` / `scan_tzx`
/// en native/zx_bridge.cpp) para decir en qué bloque va la cinta: en .tap cada bloque con
/// su longitud; en .tzx cada bloque tras la cabecera de 10 bytes, incluidos los de texto,
/// pausa y control. Si se cambia una, cambiar la otra.

/// Qué es un bloque, para mostrarlo.
enum TapeBlockKind {
  program, // cabecera de programa BASIC
  numberArray,
  charArray,
  bytes, // cabecera de CODE (incluye SCREEN$)
  data, // bloque de datos estándar (con flag y checksum)
  turbo, // datos con tiempos propios (TZX 0x11)
  pureData, // TZX 0x14
  pureTone, // TZX 0x12
  pulses, // TZX 0x13
  directRecording, // TZX 0x15
  csw, // TZX 0x18
  generalized, // TZX 0x19
  pause, // TZX 0x20 (pausa 0 = parar la cinta)
  group, // TZX 0x21 / 0x22
  control, // saltos, bucles, llamadas, selección, "stop si 48K", nivel de señal
  text, // TZX 0x30 / 0x31
  info, // TZX 0x32 / 0x33 / 0x35 / 0x5A
  other, // TZX 0x4B y lo que no se reconoce
}

/// Un bloque de la cinta.
class TapeBlock {
  /// Posición en la cinta (0-based), la misma que da `zx_tape_info`.
  final int index;

  /// ID del bloque TZX (en .tap, 0x10: bloque estándar).
  final int id;
  final TapeBlockKind kind;

  /// Offset del bloque en el archivo y bytes que ocupa (cabecera de longitud / ID incluida).
  final int offset;
  final int size;

  /// Bloques estándar (TAP, TZX 0x10, 0x11 y 0x14 con datos): flag + datos + checksum.
  final Uint8List? payload;

  /// Cabecera estándar: nombre (10 caracteres sin espacios finales) y parámetros
  /// (LINE / dirección y longitud de los datos que siguen).
  final String? name;
  final int? dataLength;
  final int? param1;
  final int? param2;

  /// Pausa tras el bloque (ms) en TZX; texto de los bloques 0x30/0x31/0x21/0x32.
  final int? pauseMs;
  final String? text;

  const TapeBlock({
    required this.index,
    required this.id,
    required this.kind,
    required this.offset,
    required this.size,
    this.payload,
    this.name,
    this.dataLength,
    this.param1,
    this.param2,
    this.pauseMs,
    this.text,
  });

  bool get isHeader =>
      kind == TapeBlockKind.program ||
      kind == TapeBlockKind.numberArray ||
      kind == TapeBlockKind.charArray ||
      kind == TapeBlockKind.bytes;

  /// Lleva datos con flag y checksum (TAP, TZX 0x10/0x11).
  bool get isStandard => payload != null && (id == 0x10 || id == 0x11);

  int? get flag => payload == null || payload!.isEmpty ? null : payload![0];

  /// Bytes de datos sin flag ni checksum.
  int get contentLength => payload == null ? 0 : (payload!.length - 2).clamp(0, 1 << 30);

  /// Checksum correcto (XOR de flag + datos == último byte). null si no aplica.
  bool? get checksumOk {
    final p = payload;
    if (p == null || p.length < 2 || id == 0x14) return null;
    var x = 0;
    for (var i = 0; i < p.length - 1; i++) {
      x ^= p[i];
    }
    return x == p[p.length - 1];
  }

  /// Texto de la fila, como el Cassette Recorder de ZEsarUX/Fuse
  /// (`Program: Civtopia LINE 10`, `Bytes: screen CODE 16384,6912`…).
  String get description {
    switch (kind) {
      case TapeBlockKind.program:
        final line = param1 != null && param1! < 32768 ? ' LINE $param1' : '';
        return 'Program: ${name ?? ''}$line';
      case TapeBlockKind.numberArray:
        return 'Number array: ${name ?? ''}';
      case TapeBlockKind.charArray:
        return 'Character array: ${name ?? ''}';
      case TapeBlockKind.bytes:
        final screen = param1 == 16384 && dataLength == 6912;
        return 'Bytes: ${name ?? ''} ${screen ? 'SCREEN\$' : 'CODE $param1,$dataLength'}';
      case TapeBlockKind.data:
        final f = flag;
        final kindLabel = f == 0xff || f == null ? 'Normal' : 'Flag ${_hex(f)}';
        return '$kindLabel Data Block ($contentLength bytes)';
      case TapeBlockKind.turbo:
        return 'Turbo Data Block ($contentLength bytes)';
      case TapeBlockKind.pureData:
        return 'Pure Data Block (${payload?.length ?? 0} bytes)';
      case TapeBlockKind.pureTone:
        return 'Pure Tone';
      case TapeBlockKind.pulses:
        return 'Pulse Sequence';
      case TapeBlockKind.directRecording:
        return 'Direct Recording';
      case TapeBlockKind.csw:
        return 'CSW Recording';
      case TapeBlockKind.generalized:
        return 'Generalized Data';
      case TapeBlockKind.pause:
        return pauseMs == 0 ? 'Stop the Tape' : 'Pause ($pauseMs ms)';
      case TapeBlockKind.group:
        return id == 0x21 ? 'Group: ${text ?? ''}' : 'Group End';
      case TapeBlockKind.control:
        return switch (id) {
          0x23 => 'Jump',
          0x24 => 'Loop Start',
          0x25 => 'Loop End',
          0x26 => 'Call Sequence',
          0x27 => 'Return',
          0x28 => 'Select Block',
          0x2A => 'Stop the Tape if 48K',
          0x2B => 'Set Signal Level',
          _ => 'Control ${_hex(id)}',
        };
      case TapeBlockKind.text:
        return id == 0x31 ? 'Message: ${text ?? ''}' : 'Text: ${text ?? ''}';
      case TapeBlockKind.info:
        return switch (id) {
          0x32 => 'Archive Info${text == null || text!.isEmpty ? '' : ': $text'}',
          0x33 => 'Hardware Type',
          0x35 => 'Custom Info',
          _ => 'Glue',
        };
      case TapeBlockKind.other:
        return id == 0x4B ? 'Kansas City Block' : 'Block ${_hex(id)}';
    }
  }

  static String _hex(int v) => '0x${v.toRadixString(16).padLeft(2, '0').toUpperCase()}';
}

/// Una fila de la lista: una cabecera con su bloque de datos, o un bloque suelto.
class TapeRow {
  /// Índices de [TapeFile.blocks] (1 o 2).
  final List<int> blocks;
  final String title;

  /// Descripción del bloque de datos emparejado, si lo hay.
  final String? detail;
  const TapeRow(this.blocks, this.title, [this.detail]);

  int get first => blocks.first;
  bool contains(int block) => blocks.contains(block);
}

class TapeFile {
  final String? path;
  final bool tzx;
  final Uint8List bytes;
  final List<TapeBlock> blocks;

  /// El .tzx se cortó en un ID desconocido (CLK también se detiene ahí).
  final bool truncated;

  const TapeFile._(this.path, this.tzx, this.bytes, this.blocks, this.truncated);

  /// Tiene lista de bloques (no es .csw ni un snapshot).
  static bool hasBlockList(String path) {
    final ext = _ext(path);
    return ext == 'tap' || ext == 'tzx';
  }

  static Future<TapeFile?> load(String path) async {
    if (!hasBlockList(path)) return null;
    final f = File(path);
    if (!await f.exists()) return null;
    return parse(await f.readAsBytes(), tzx: _ext(path) == 'tzx', path: path);
  }

  /// Interpreta un .tap ([tzx] = false) o un .tzx. Nunca lanza: lo ilegible se corta.
  static TapeFile parse(Uint8List bytes, {required bool tzx, String? path}) {
    final blocks = <TapeBlock>[];
    var truncated = false;
    if (tzx) {
      truncated = _parseTzx(bytes, blocks);
    } else {
      var p = 0;
      while (p + 2 <= bytes.length) {
        final len = bytes[p] | (bytes[p + 1] << 8);
        if (p + 2 + len > bytes.length) {
          truncated = true;
          break;
        }
        blocks.add(_standard(blocks.length, 0x10, p, 2 + len, Uint8List.sublistView(bytes, p + 2, p + 2 + len)));
        p += 2 + len;
      }
    }
    return TapeFile._(path, tzx, bytes, blocks, truncated);
  }

  /// Bloque estándar suelto (flag + datos + checksum), para describirlo.
  static TapeBlock describePayload(Uint8List payload, {int index = 0}) =>
      _standard(index, 0x10, 0, payload.length + 2, payload);

  /// Bloque estándar: si es una cabecera (flag 0, 17 bytes + checksum) se decodifica.
  static TapeBlock _standard(int index, int id, int offset, int size, Uint8List payload,
      {int? pauseMs}) {
    if (payload.length == 19 && payload[0] == 0x00 && payload[1] <= 3) {
      final kind = const [
        TapeBlockKind.program,
        TapeBlockKind.numberArray,
        TapeBlockKind.charArray,
        TapeBlockKind.bytes,
      ][payload[1]];
      int w(int at) => payload[at] | (payload[at + 1] << 8);
      return TapeBlock(
        index: index,
        id: id,
        kind: kind,
        offset: offset,
        size: size,
        payload: payload,
        name: zxName(payload.sublist(2, 12)),
        dataLength: w(12),
        param1: w(14),
        param2: w(16),
        pauseMs: pauseMs,
      );
    }
    return TapeBlock(
      index: index,
      id: id,
      kind: id == 0x11 ? TapeBlockKind.turbo : TapeBlockKind.data,
      offset: offset,
      size: size,
      payload: payload,
      pauseMs: pauseMs,
    );
  }

  /// Nombre de 10 caracteres de una cabecera (sin espacios finales; no imprimibles = '?').
  static String zxName(List<int> raw) {
    final s = StringBuffer();
    for (final c in raw) {
      if (c == 0x60) {
        s.write('£');
      } else if (c == 0x7F) {
        s.write('©');
      } else {
        s.writeCharCode(c >= 32 && c < 127 ? c : 0x3F);
      }
    }
    return s.toString().trimRight();
  }

  /// Devuelve true si el archivo se cortó antes del final.
  static bool _parseTzx(Uint8List d, List<TapeBlock> out) {
    if (d.length < 10 || String.fromCharCodes(d.sublist(0, 7)) != 'ZXTape!' || d[7] != 0x1A) {
      return d.isNotEmpty;
    }
    int le(int at, int n) {
      var v = 0;
      for (var i = 0; i < n; i++) {
        if (at + i < d.length) v |= d[at + i] << (8 * i);
      }
      return v;
    }

    String str(int at, int n) {
      final end = (at + n).clamp(0, d.length);
      return String.fromCharCodes(d.sublist(at.clamp(0, end), end).map((c) => c >= 32 && c < 127 ? c : 0x20))
          .trim();
    }

    var p = 10;
    while (p < d.length) {
      final id = d[p];
      final b = p + 1;
      final int len;
      switch (id) {
        case 0x10:
          len = 4 + le(b + 2, 2);
        case 0x11:
          len = 18 + le(b + 15, 3);
        case 0x12:
          len = 4;
        case 0x13:
          len = 1 + le(b, 1) * 2;
        case 0x14:
          len = 10 + le(b + 7, 3);
        case 0x15:
          len = 8 + le(b + 5, 3);
        case 0x18 || 0x19 || 0x2B || 0x4B:
          len = 4 + le(b, 4);
        case 0x20 || 0x23 || 0x24:
          len = 2;
        case 0x21 || 0x30:
          len = 1 + le(b, 1);
        case 0x22 || 0x25 || 0x27:
          len = 0;
        case 0x26:
          len = 2 + le(b, 2) * 2;
        case 0x28 || 0x32:
          len = 2 + le(b, 2);
        case 0x2A:
          len = 4;
        case 0x31:
          len = 2 + le(b + 1, 1);
        case 0x33:
          len = 1 + le(b, 1) * 3;
        case 0x35:
          len = 20 + le(b + 16, 4);
        case 0x5A:
          len = 9;
        default:
          return true; // ID desconocido: CLK tampoco sigue
      }
      if (b + len > d.length) return true;
      final i = out.length, size = 1 + len;
      switch (id) {
        case 0x10:
          out.add(_standard(i, id, p, size, Uint8List.sublistView(d, b + 4, b + len), pauseMs: le(b, 2)));
        case 0x11:
          out.add(_standard(i, id, p, size, Uint8List.sublistView(d, b + 18, b + len), pauseMs: le(b + 13, 2)));
        case 0x14:
          out.add(TapeBlock(
              index: i,
              id: id,
              kind: TapeBlockKind.pureData,
              offset: p,
              size: size,
              payload: Uint8List.sublistView(d, b + 10, b + len),
              pauseMs: le(b + 5, 2)));
        case 0x20:
          out.add(TapeBlock(index: i, id: id, kind: TapeBlockKind.pause, offset: p, size: size, pauseMs: le(b, 2)));
        case 0x21:
          out.add(TapeBlock(
              index: i, id: id, kind: TapeBlockKind.group, offset: p, size: size, text: str(b + 1, d[b])));
        case 0x30:
          out.add(TapeBlock(
              index: i, id: id, kind: TapeBlockKind.text, offset: p, size: size, text: str(b + 1, d[b])));
        case 0x31:
          out.add(TapeBlock(
              index: i, id: id, kind: TapeBlockKind.text, offset: p, size: size, text: str(b + 2, d[b + 1])));
        case 0x32:
          out.add(TapeBlock(
              index: i, id: id, kind: TapeBlockKind.info, offset: p, size: size, text: _archiveTitle(d, b)));
        default:
          final kind = switch (id) {
            0x12 => TapeBlockKind.pureTone,
            0x13 => TapeBlockKind.pulses,
            0x15 => TapeBlockKind.directRecording,
            0x18 => TapeBlockKind.csw,
            0x19 => TapeBlockKind.generalized,
            0x22 => TapeBlockKind.group,
            0x23 || 0x24 || 0x25 || 0x26 || 0x27 || 0x28 || 0x2A || 0x2B => TapeBlockKind.control,
            0x33 || 0x35 || 0x5A => TapeBlockKind.info,
            _ => TapeBlockKind.other,
          };
          out.add(TapeBlock(index: i, id: id, kind: kind, offset: p, size: size));
      }
      p = b + len;
    }
    return false;
  }

  /// Título (texto 0x00) del bloque Archive Info, si lo trae.
  static String? _archiveTitle(Uint8List d, int b) {
    var p = b + 3;
    final n = d[b + 2];
    for (var i = 0; i < n && p + 2 <= d.length; i++) {
      final type = d[p], len = d[p + 1];
      if (type == 0x00) {
        final end = (p + 2 + len).clamp(0, d.length);
        return String.fromCharCodes(d.sublist(p + 2, end)).trim();
      }
      p += 2 + len;
    }
    return null;
  }

  /// Filas: cada cabecera estándar con el bloque de datos que la sigue (si su longitud
  /// coincide); el resto, sueltos. Con [pair] = false, un bloque por fila.
  List<TapeRow> rows({bool pair = true}) {
    final rows = <TapeRow>[];
    for (var i = 0; i < blocks.length; i++) {
      final b = blocks[i];
      if (pair && b.isHeader && i + 1 < blocks.length) {
        final next = blocks[i + 1];
        if (next.isStandard && !next.isHeader && next.contentLength == b.dataLength) {
          rows.add(TapeRow([i, i + 1], b.description, next.description));
          i++;
          continue;
        }
      }
      rows.add(TapeRow([i], b.description));
    }
    return rows;
  }

  /// Fila que contiene el bloque [block] (o la última si es el fin de cinta).
  static int rowOf(List<TapeRow> rows, int block) {
    for (var r = 0; r < rows.length; r++) {
      if (rows[r].contains(block)) return r;
      if (rows[r].first > block) return r == 0 ? 0 : r - 1;
    }
    return rows.isEmpty ? 0 : rows.length - 1;
  }

  /// Todos los bloques son estándar (o informativos): se puede convertir a .tap.
  bool get convertibleToTap =>
      blocks.isNotEmpty &&
      blocks.every((b) =>
          b.isStandard && b.id == 0x10 ||
          b.kind == TapeBlockKind.text ||
          b.kind == TapeBlockKind.info ||
          b.kind == TapeBlockKind.group ||
          b.kind == TapeBlockKind.pause && (b.pauseMs ?? 0) > 0) &&
      blocks.any((b) => b.isStandard);

  /// .tap equivalente (solo los bloques estándar), o null si hay bloques que no caben.
  Uint8List? toTap() {
    if (!tzx) return bytes;
    if (!convertibleToTap) return null;
    final out = BytesBuilder(copy: false);
    for (final b in blocks) {
      if (!b.isStandard) continue;
      final p = b.payload!;
      out.add([p.length & 0xff, p.length >> 8]);
      out.add(p);
    }
    return out.takeBytes();
  }

  static String _ext(String path) {
    final name = path.split(RegExp(r'[\\/]')).last;
    final dot = name.lastIndexOf('.');
    return dot < 0 ? '' : name.substring(dot + 1).toLowerCase();
  }
}

/// Escribe [data] en [path] sin dejar nunca el archivo a medias (temporal + renombrar),
/// como `GameLibrary.import`.
Future<void> writeFileAtomic(String path, List<int> data) async {
  final tmp = File('$path.part');
  await tmp.writeAsBytes(data, flush: true);
  await tmp.rename(path);
}
