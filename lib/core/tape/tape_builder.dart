import 'dart:typed_data';

import 'tape_file.dart';
import 'zx_basic.dart';

/// Un bloque del editor de cintas: estándar (flag + datos + checksum) o un bloque TZX
/// que no se puede expresar como .tap (turbo, tonos, control…), guardado tal cual.
class TapeItem {
  /// flag + datos + checksum.
  final Uint8List? payload;

  /// Bloque TZX completo (ID incluido).
  final Uint8List? raw;

  /// Pausa tras el bloque al exportar a .tzx (en .tap es la estándar del ROM).
  final int pauseMs;

  const TapeItem.standard(Uint8List this.payload, {this.pauseMs = 1000}) : raw = null;
  const TapeItem.raw(Uint8List this.raw)
      : payload = null,
        pauseMs = 0;

  bool get isStandard => payload != null;

  TapeBlock get block => isStandard
      ? TapeFile.describePayload(payload!)
      : TapeFile.parse(Uint8List.fromList([...TapeBuilder._tzxHeader, ...raw!]), tzx: true).blocks.first;

  String get description => block.description;

  /// Nombre editable (solo cabeceras).
  String? get name => block.isHeader ? block.name : null;
}

/// Arma cintas nuevas (.tap, o .tzx si hay bloques no estándar). Sin emulación.
class TapeBuilder {
  static const _tzxHeader = [0x5A, 0x58, 0x54, 0x61, 0x70, 0x65, 0x21, 0x1A, 1, 20]; // ZXTape! v1.20

  /// Tipos de cabecera del ROM.
  static const program = 0, numberArray = 1, charArray = 2, bytes = 3;

  /// flag + datos + checksum.
  static Uint8List standardBlock(int flag, List<int> data) {
    final out = Uint8List(data.length + 2);
    out[0] = flag;
    var x = flag;
    for (var i = 0; i < data.length; i++) {
      out[i + 1] = data[i];
      x ^= data[i];
    }
    out[out.length - 1] = x;
    return out;
  }

  /// Nombre de cabecera: 10 caracteres ASCII, rellenos con espacios.
  static List<int> nameBytes(String name) {
    final out = List<int>.filled(10, 0x20);
    final units = name.codeUnits;
    for (var i = 0; i < 10 && i < units.length; i++) {
      final c = units[i];
      out[i] = c == 0xA3 ? 0x60 : (c >= 32 && c < 127 ? c : 0x3F);
    }
    return out;
  }

  static Uint8List header(int type, String name, int length, int param1, int param2) =>
      standardBlock(0x00, [
        type,
        ...nameBytes(name),
        length & 0xff, length >> 8,
        param1 & 0xff, param1 >> 8,
        param2 & 0xff, param2 >> 8,
      ]);

  /// `Bytes: name CODE address,length` + datos.
  static List<TapeItem> code(String name, int address, List<int> data) {
    _checkLength(data.length);
    return [
      TapeItem.standard(header(bytes, name, data.length, address, 32768)),
      TapeItem.standard(standardBlock(0xff, data)),
    ];
  }

  /// Pantalla (6912 bytes en 16384).
  static List<TapeItem> screen(String name, List<int> data) {
    if (data.length != 6912) throw const FormatException('A SCREEN\$ must be 6912 bytes');
    return code(name, 16384, data);
  }

  /// Programa BASIC ya tokenizado; [autostart] = LINE (null = sin autoarranque).
  static List<TapeItem> basicProgram(String name, List<int> program, {int? autostart}) {
    _checkLength(program.length);
    return [
      TapeItem.standard(header(TapeBuilder.program, name, program.length, autostart ?? 32768, program.length)),
      TapeItem.standard(standardBlock(0xff, program)),
    ];
  }

  /// Programa BASIC en texto (.bas): se tokeniza y arranca en su primera línea.
  static List<TapeItem> basicText(String name, String source) {
    final prog = ZxBasic.tokenize(source);
    final first = prog.length >= 2 ? (prog[0] << 8) | prog[1] : null;
    return basicProgram(name, prog, autostart: first);
  }

  /// Bloque de datos crudo (flag 0xFF por defecto, sin cabecera).
  static TapeItem rawData(List<int> data, {int flag = 0xff}) {
    _checkLength(data.length);
    return TapeItem.standard(standardBlock(flag, data));
  }

  /// Cargador: BASIC `LOAD "" CODE` + el código + `RANDOMIZE USR`, opcionalmente con
  /// pantalla de carga. Pensado para PRISMA: de un .bin y su dirección a un .tap listo.
  ///
  ///   10 CLEAR VAL "addr-1": LOAD ""SCREEN$ : POKE VAL "23739",VAL "111":
  ///      LOAD ""CODE : RANDOMIZE USR VAL "run"
  ///
  /// El CLEAR solo se pone si el código queda por encima del BASIC (≥ 24000); el POKE
  /// (silenciar el "Bytes:" del siguiente LOAD) solo con pantalla.
  static List<TapeItem> loader({
    required String name,
    required int address,
    required List<int> code,
    int? run,
    List<int>? screen,
  }) {
    final entry = run ?? address;
    final parts = <String>[
      if (address - 1 >= 24000) 'CLEAR VAL "${address - 1}"',
      if (screen != null) 'LOAD ""SCREEN\$ ',
      if (screen != null) 'POKE VAL "23739",VAL "111"',
      'LOAD ""CODE ',
      'RANDOMIZE USR VAL "$entry"',
    ];
    final prog = ZxBasic.encodeLine(10, parts.join(':'));
    return [
      ...basicProgram(name, prog, autostart: 10),
      if (screen != null) ...TapeBuilder.screen(name, screen),
      ...TapeBuilder.code(name, address, code),
    ];
  }

  /// Bloques de una cinta existente (para editarla): los estándar como tales, el resto
  /// tal cual (solo .tzx).
  static List<TapeItem> fromTape(TapeFile tape) => [
        for (final b in tape.blocks)
          if (b.isStandard && b.id == 0x10)
            TapeItem.standard(Uint8List.fromList(b.payload!), pauseMs: b.pauseMs ?? 1000)
          else if (!tape.tzx && b.payload != null)
            TapeItem.standard(Uint8List.fromList(b.payload!))
          else
            TapeItem.raw(Uint8List.fromList(tape.bytes.sublist(b.offset, b.offset + b.size))),
      ];

  /// Cambia el nombre de una cabecera (recalcula el checksum). Otros bloques: igual.
  static TapeItem rename(TapeItem item, String name) {
    final p = item.payload;
    if (p == null || !item.block.isHeader) return item;
    final data = Uint8List.fromList(p.sublist(1, p.length - 1));
    data.setRange(1, 11, nameBytes(name));
    return TapeItem.standard(standardBlock(p[0], data), pauseMs: item.pauseMs);
  }

  /// Hace falta .tzx para guardar estos bloques.
  static bool needsTzx(List<TapeItem> items) => items.any((i) => !i.isStandard);

  static Uint8List exportTap(List<TapeItem> items) {
    if (needsTzx(items)) throw const FormatException('Non-standard blocks need a .tzx');
    final out = BytesBuilder(copy: false);
    for (final i in items) {
      final p = i.payload!;
      out.add([p.length & 0xff, p.length >> 8]);
      out.add(p);
    }
    return out.takeBytes();
  }

  static Uint8List exportTzx(List<TapeItem> items) {
    final out = BytesBuilder(copy: false)..add(_tzxHeader);
    for (final i in items) {
      if (i.isStandard) {
        final p = i.payload!;
        out.add([0x10, i.pauseMs & 0xff, i.pauseMs >> 8, p.length & 0xff, p.length >> 8]);
        out.add(p);
      } else {
        out.add(i.raw!);
      }
    }
    return out.takeBytes();
  }

  static void _checkLength(int n) {
    if (n > 65534) throw const FormatException('Block too long (max 65534 bytes)');
  }
}
