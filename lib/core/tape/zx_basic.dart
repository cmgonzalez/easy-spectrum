import 'dart:math' as math;
import 'dart:typed_data';

/// Tokenizador de BASIC del ZX Spectrum 48K: texto ("10 PRINT \"HOLA\"") → bytes de
/// programa como los guarda el ROM (para meter un .bas en una cinta, y para el cargador
/// de [TapeBuilder.loader]).
///
/// Cada línea: número (2 bytes, big-endian), longitud (2 bytes, little-endian), cuerpo
/// tokenizado y 0x0D. Los números literales llevan su forma oculta de 5 bytes (0x0E + valor)
/// detrás de los dígitos, como hace el editor del Spectrum.
class ZxBasic {
  /// Palabras clave 0xA5-0xFF (sin SPECTRUM/PLAY, que son del 128K: en 48K serían
  /// identificadores normales).
  static const _keywords = <int, String>{
    0xA5: 'RND', 0xA6: 'INKEY\$', 0xA7: 'PI', 0xA8: 'FN', 0xA9: 'POINT', 0xAA: 'SCREEN\$',
    0xAB: 'ATTR', 0xAC: 'AT', 0xAD: 'TAB', 0xAE: 'VAL\$', 0xAF: 'CODE', 0xB0: 'VAL',
    0xB1: 'LEN', 0xB2: 'SIN', 0xB3: 'COS', 0xB4: 'TAN', 0xB5: 'ASN', 0xB6: 'ACS', 0xB7: 'ATN',
    0xB8: 'LN', 0xB9: 'EXP', 0xBA: 'INT', 0xBB: 'SQR', 0xBC: 'SGN', 0xBD: 'ABS', 0xBE: 'PEEK',
    0xBF: 'IN', 0xC0: 'USR', 0xC1: 'STR\$', 0xC2: 'CHR\$', 0xC3: 'NOT', 0xC4: 'BIN', 0xC5: 'OR',
    0xC6: 'AND', 0xC7: '<=', 0xC8: '>=', 0xC9: '<>', 0xCA: 'LINE', 0xCB: 'THEN', 0xCC: 'TO',
    0xCD: 'STEP', 0xCE: 'DEF FN', 0xCF: 'CAT', 0xD0: 'FORMAT', 0xD1: 'MOVE', 0xD2: 'ERASE',
    0xD3: 'OPEN #', 0xD4: 'CLOSE #', 0xD5: 'MERGE', 0xD6: 'VERIFY', 0xD7: 'BEEP', 0xD8: 'CIRCLE',
    0xD9: 'INK', 0xDA: 'PAPER', 0xDB: 'FLASH', 0xDC: 'BRIGHT', 0xDD: 'INVERSE', 0xDE: 'OVER',
    0xDF: 'OUT', 0xE0: 'LPRINT', 0xE1: 'LLIST', 0xE2: 'STOP', 0xE3: 'READ', 0xE4: 'DATA',
    0xE5: 'RESTORE', 0xE6: 'NEW', 0xE7: 'BORDER', 0xE8: 'CONTINUE', 0xE9: 'DIM', 0xEA: 'REM',
    0xEB: 'FOR', 0xEC: 'GO TO', 0xED: 'GO SUB', 0xEE: 'INPUT', 0xEF: 'LOAD', 0xF0: 'LIST',
    0xF1: 'LET', 0xF2: 'PAUSE', 0xF3: 'NEXT', 0xF4: 'POKE', 0xF5: 'PRINT', 0xF6: 'PLOT',
    0xF7: 'RUN', 0xF8: 'SAVE', 0xF9: 'RANDOMIZE', 0xFA: 'IF', 0xFB: 'CLS', 0xFC: 'DRAW',
    0xFD: 'CLEAR', 0xFE: 'RETURN', 0xFF: 'COPY',
  };

  /// Formas alternativas que se aceptan al escribir.
  static const _aliases = <String, int>{
    'GOTO': 0xEC, 'GOSUB': 0xED, 'RANDOMISE': 0xF9, 'DEFFN': 0xCE, 'OPEN#': 0xD3, 'CLOSE#': 0xD4,
  };

  static final List<MapEntry<String, int>> _table = () {
    final all = <MapEntry<String, int>>[
      for (final e in _keywords.entries) MapEntry(e.value, e.key),
      for (final e in _aliases.entries) MapEntry(e.key, e.value),
    ];
    all.sort((a, b) => b.key.length.compareTo(a.key.length)); // la más larga primero
    return all;
  }();

  static bool _isAlnum(int c) =>
      (c >= 0x30 && c <= 0x39) || (c >= 0x41 && c <= 0x5A) || (c >= 0x61 && c <= 0x7A);
  static bool _isAlpha(int c) => (c >= 0x41 && c <= 0x5A) || (c >= 0x61 && c <= 0x7A);
  static bool _isDigit(int c) => c >= 0x30 && c <= 0x39;

  /// Programa completo. Las líneas sin número o vacías se ignoran; error si un número
  /// de línea no es 0-9999.
  static Uint8List tokenize(String source) {
    final out = BytesBuilder(copy: false);
    for (final raw in source.split(RegExp(r'\r\n|\r|\n'))) {
      final line = raw.trim();
      if (line.isEmpty) continue;
      final m = RegExp(r'^(\d+)\s*(.*)$').firstMatch(line);
      if (m == null) continue;
      final number = int.parse(m.group(1)!);
      if (number > 9999) throw FormatException('Line number out of range: $number');
      out.add(encodeLine(number, m.group(2)!));
    }
    return out.takeBytes();
  }

  /// Una línea con su número.
  static Uint8List encodeLine(int number, String text) {
    final body = <int>[..._tokenizeBody(text), 0x0D];
    return Uint8List.fromList([number >> 8, number & 0xff, body.length & 0xff, body.length >> 8, ...body]);
  }

  static List<int> _tokenizeBody(String text) {
    final s = text.codeUnits;
    final out = <int>[];
    var i = 0;
    var inString = false, rem = false, afterBin = false;
    while (i < s.length) {
      final c = s[i];
      if (rem) {
        out.add(_char(c));
        i++;
        continue;
      }
      if (inString) {
        out.add(_char(c));
        if (c == 0x22) inString = false;
        i++;
        continue;
      }
      if (c == 0x22) {
        inString = true;
        out.add(c);
        i++;
        continue;
      }
      // Número literal (no dentro de un identificador): dígitos + forma oculta.
      final prev = i > 0 ? s[i - 1] : 0x20;
      if ((_isDigit(c) || (c == 0x2E && i + 1 < s.length && _isDigit(s[i + 1]))) && !_isAlnum(prev)) {
        final m = RegExp(afterBin ? r'[01]+' : r'(\d+\.?\d*|\.\d+)([eE][+-]?\d+)?').matchAsPrefix(text, i);
        if (m != null) {
          final lit = m.group(0)!;
          out.addAll(lit.codeUnits);
          final value = afterBin ? int.parse(lit, radix: 2).toDouble() : double.parse(lit);
          out
            ..add(0x0E)
            ..addAll(number5(value));
          i += lit.length;
          afterBin = false;
          continue;
        }
      }
      // Palabra clave.
      final token = _matchKeyword(text, i);
      if (token != null) {
        out.add(token.$1);
        i += token.$2;
        // El editor no guarda el espacio que sigue a una palabra clave.
        while (i < s.length && s[i] == 0x20) {
          i++;
        }
        if (token.$1 == 0xEA) rem = true;
        afterBin = token.$1 == 0xC4;
        continue;
      }
      if (c != 0x20) afterBin = false;
      out.add(_char(c));
      i++;
    }
    return out;
  }

  /// (token, caracteres consumidos) si en [i] empieza una palabra clave.
  static (int, int)? _matchKeyword(String text, int i) {
    final s = text.codeUnits;
    if (i > 0 && _isAlpha(s[i]) && _isAlnum(s[i - 1])) return null; // en medio de un nombre
    final upper = text.substring(i).toUpperCase();
    for (final e in _table) {
      final k = e.key;
      if (!upper.startsWith(k)) continue;
      final end = i + k.length;
      // Una palabra que termina en letra no puede seguir con letra o dígito (INTO ≠ IN TO).
      if (_isAlpha(k.codeUnitAt(k.length - 1)) && end < s.length && _isAlnum(s[end])) continue;
      return (e.value, k.length);
    }
    return null;
  }

  static int _char(int c) {
    if (c == 0xA3) return 0x60; // £
    if (c == 0xA9) return 0x7F; // ©
    return c < 128 ? c : 0x3F;
  }

  /// Forma de 5 bytes de un número del Spectrum: entero pequeño (0..65535) o coma flotante.
  static List<int> number5(double v) {
    if (v == v.truncateToDouble() && v.abs() <= 65535) {
      final n = v.abs().toInt();
      final value = v < 0 ? 65536 - n : n;
      return [0, v < 0 ? 0xFF : 0, value & 0xff, value >> 8, 0];
    }
    final neg = v < 0;
    var x = v.abs();
    var e = 0;
    while (x >= 1) {
      x /= 2;
      e++;
    }
    while (x < 0.5) {
      x *= 2;
      e--;
    }
    var m = (x * math.pow(2, 32)).round();
    if (m >= 0x100000000) {
      m >>= 1;
      e++;
    }
    final b = [e + 128, (m >> 24) & 0x7F, (m >> 16) & 0xff, (m >> 8) & 0xff, m & 0xff];
    if (neg) b[1] |= 0x80;
    return b;
  }
}
