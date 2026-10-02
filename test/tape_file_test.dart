import 'dart:typed_data';

import 'package:easyspectrum/core/tape/tape_builder.dart';
import 'package:easyspectrum/core/tape/tape_file.dart';
import 'package:easyspectrum/core/tape/zx_basic.dart';
import 'package:flutter_test/flutter_test.dart';

/// Cintas sintéticas (no hay .tap/.tzx de muestra en el repo). La TZX es la misma que se
/// usó para verificar el gancho nativo de posición (native/zx_tape.h): CLK avisó los
/// offsets 10, 17, 41, 44, 6963, 6968 y 6969 — el parser de Dart tiene que numerar igual.
Uint8List _block(int flag, List<int> data) => TapeBuilder.standardBlock(flag, data);

List<int> _tapEntry(Uint8List b) => [b.length & 0xff, b.length >> 8, ...b];

Uint8List _screenHeader() => TapeBuilder.header(TapeBuilder.bytes, 'screen', 6912, 16384, 32768);

Uint8List _sampleTap() => Uint8List.fromList([
      ..._tapEntry(_screenHeader()),
      ..._tapEntry(_block(0xff, List.generate(6912, (i) => i & 0xff))),
      ..._tapEntry(_screenHeader()),
      ..._tapEntry(_block(0xff, [1, 2, 3])),
    ]);

List<int> _b10(Uint8List payload, {int pause = 1000}) =>
    [0x10, pause & 0xff, pause >> 8, payload.length & 0xff, payload.length >> 8, ...payload];

Uint8List _sampleTzx() {
  final hdr = _screenHeader();
  final data = _block(0xff, List.generate(6912, (i) => i & 0xff));
  return Uint8List.fromList([
    ...'ZXTape!'.codeUnits, 0x1A, 1, 20,
    0x30, 5, ...'hello'.codeUnits, // texto
    ..._b10(hdr),
    0x20, 0xF4, 0x01, // pausa 500 ms
    ..._b10(data),
    0x21, 3, ...'abc'.codeUnits, // grupo
    0x22, // fin de grupo
    ..._b10(hdr),
  ]);
}

void main() {
  group('TapeFile .tap', () {
    final tape = TapeFile.parse(_sampleTap(), tzx: false);

    test('bloques y offsets (los mismos que scan_tap y que avisa CLK)', () {
      expect(tape.blocks.map((b) => b.offset), [0, 21, 6937, 6958]);
      expect(tape.truncated, isFalse);
    });

    test('cabecera decodificada', () {
      final h = tape.blocks[0];
      expect(h.kind, TapeBlockKind.bytes);
      expect(h.name, 'screen');
      expect(h.param1, 16384);
      expect(h.dataLength, 6912);
      expect(h.description, 'Bytes: screen SCREEN\$');
      expect(h.checksumOk, isTrue);
      expect(tape.blocks[1].description, 'Normal Data Block (6912 bytes)');
    });

    test('filas: cabecera + datos emparejados solo si la longitud coincide', () {
      final rows = tape.rows();
      expect(rows.map((r) => r.blocks), [
        [0, 1],
        [2],
        [3],
      ]);
      expect(tape.rows(pair: false).length, 4);
      expect(TapeFile.rowOf(rows, 1), 0);
      expect(TapeFile.rowOf(rows, 3), 2);
    });

    test('checksum incorrecto', () {
      final bad = _sampleTap();
      bad[25] ^= 0xff; // un byte de datos del bloque 1
      expect(TapeFile.parse(bad, tzx: false).blocks[1].checksumOk, isFalse);
    });

    test('archivo cortado', () {
      final cut = Uint8List.sublistView(_sampleTap(), 0, 30);
      final t = TapeFile.parse(cut, tzx: false);
      expect(t.blocks.length, 1);
      expect(t.truncated, isTrue);
    });
  });

  group('TapeFile .tzx', () {
    final tape = TapeFile.parse(_sampleTzx(), tzx: true);

    test('offsets iguales a los que avisó CLK', () {
      expect(tape.blocks.map((b) => b.offset), [10, 17, 41, 44, 6963, 6968, 6969]);
    });

    test('tipos y textos', () {
      expect(tape.blocks.map((b) => b.kind), [
        TapeBlockKind.text,
        TapeBlockKind.bytes,
        TapeBlockKind.pause,
        TapeBlockKind.data,
        TapeBlockKind.group,
        TapeBlockKind.group,
        TapeBlockKind.bytes,
      ]);
      expect(tape.blocks[0].description, 'Text: hello');
      expect(tape.blocks[2].description, 'Pause (500 ms)');
      expect(tape.blocks[4].description, 'Group: abc');
    });

    test('bloques 0x11 / 0x12 / 0x13 / 0x14 / 0x32', () {
      final payload = _block(0xff, [9, 8, 7]);
      final d = Uint8List.fromList([
        ...'ZXTape!'.codeUnits, 0x1A, 1, 20,
        0x11, ...List.filled(12, 0), 8, 0x00, 0x00, payload.length, 0, 0, ...payload, // turbo
        0x12, 0x78, 0x08, 0x10, 0x00, // tono puro
        0x13, 2, 1, 0, 2, 0, // secuencia de pulsos
        0x14, 0, 0, 0, 0, 8, 0, 0, 2, 0, 0, 0xAA, 0x55, // datos puros
        0x32, 7, 0, 1, 0x00, 4, ...'Game'.codeUnits, // archive info
      ]);
      final t = TapeFile.parse(d, tzx: true);
      expect(t.truncated, isFalse);
      expect(t.blocks.map((b) => b.kind), [
        TapeBlockKind.turbo,
        TapeBlockKind.pureTone,
        TapeBlockKind.pulses,
        TapeBlockKind.pureData,
        TapeBlockKind.info,
      ]);
      expect(t.blocks[0].contentLength, 3);
      expect(t.blocks[4].description, 'Archive Info: Game');
      expect(t.convertibleToTap, isFalse);
    });

    test('ID desconocido corta la lista (CLK tampoco sigue)', () {
      final d = Uint8List.fromList([..._sampleTzx(), 0x99, 1, 2, 3]);
      final t = TapeFile.parse(d, tzx: true);
      expect(t.blocks.length, 7);
      expect(t.truncated, isTrue);
    });

    test('a .tap: solo los bloques estándar', () {
      expect(tape.convertibleToTap, isTrue);
      final tap = TapeFile.parse(tape.toTap()!, tzx: false);
      expect(tap.blocks.map((b) => b.description), [
        'Bytes: screen SCREEN\$',
        'Normal Data Block (6912 bytes)',
        'Bytes: screen SCREEN\$',
      ]);
    });
  });

  group('ZxBasic', () {
    test('números de 5 bytes', () {
      expect(ZxBasic.number5(10), [0, 0, 10, 0, 0]);
      expect(ZxBasic.number5(65535), [0, 0, 0xff, 0xff, 0]);
      expect(ZxBasic.number5(0.5), [0x80, 0, 0, 0, 0]);
      expect(ZxBasic.number5(1.5), [0x81, 0x40, 0, 0, 0]);
      expect(ZxBasic.number5(100000), [0x91, 0x43, 0x50, 0, 0]);
    });

    test('línea tokenizada como la guarda el ROM', () {
      // 10 PRINT 7*6
      expect(ZxBasic.encodeLine(10, 'PRINT 7*6'), [
        0, 10, 17, 0, //
        0xF5, 0x37, 0x0E, 0, 0, 7, 0, 0, //
        0x2A, 0x36, 0x0E, 0, 0, 6, 0, 0, //
        0x0D,
      ]);
    });

    test('palabras clave, cadenas, REM y nombres', () {
      final l = ZxBasic.encodeLine(1, 'go to 5: LET into=1: REM print "x"');
      final body = l.sublist(4);
      expect(body[0], 0xEC); // GO TO (minúsculas, alias)
      expect(body.contains(0xF1), isTrue); // LET
      expect(body.contains(0xBF), isFalse); // "into" no es IN + TO
      expect(body.contains(0xEA), isTrue); // REM
      expect(body.contains(0xF5), isFalse); // print tras REM queda literal
      final s = ZxBasic.encodeLine(1, 'PRINT "PRINT"').sublist(4);
      expect(s.where((c) => c == 0xF5).length, 1);
    });
  });

  group('TapeBuilder', () {
    test('código y vuelta por el parser', () {
      final items = TapeBuilder.code('game', 32768, [1, 2, 3, 4]);
      final tape = TapeFile.parse(TapeBuilder.exportTap(items), tzx: false);
      expect(tape.blocks[0].description, 'Bytes: game CODE 32768,4');
      expect(tape.blocks[1].checksumOk, isTrue);
      expect(tape.rows().length, 1);
    });

    test('cargador: BASIC con LINE 10 + CODE', () {
      final items = TapeBuilder.loader(name: 'prisma', address: 32768, code: List.filled(100, 0));
      final tape = TapeFile.parse(TapeBuilder.exportTap(items), tzx: false);
      expect(tape.blocks[0].description, 'Program: prisma LINE 10');
      expect(tape.blocks[2].description, 'Bytes: prisma CODE 32768,100');
      final prog = tape.blocks[1].payload!;
      expect(prog.contains(0xFD), isTrue); // CLEAR (32767 >= 24000)
      expect(prog.contains(0xEF), isTrue); // LOAD
      expect(prog.contains(0xC0), isTrue); // USR
      // Con ORG bajo (PRISMA 23584) no hay CLEAR.
      final low = TapeBuilder.loader(name: 'p', address: 23584, code: [0]);
      expect(low[1].payload!.contains(0xFD), isFalse);
    });

    test('renombrar recalcula el checksum', () {
      final r = TapeBuilder.rename(TapeBuilder.code('a', 0, [0])[0], 'nuevo');
      expect(r.name, 'nuevo');
      expect(r.block.checksumOk, isTrue);
    });

    test('bloques no estándar exigen .tzx', () {
      final tape = TapeFile.parse(_sampleTzx(), tzx: true);
      final items = TapeBuilder.fromTape(tape);
      expect(TapeBuilder.needsTzx(items), isTrue);
      final again = TapeFile.parse(TapeBuilder.exportTzx(items), tzx: true);
      expect(again.blocks.map((b) => b.kind), tape.blocks.map((b) => b.kind));
    });
  });
}
