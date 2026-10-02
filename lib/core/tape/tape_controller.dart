import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';

import '../emulator/zx_bridge.dart';
import 'tape_file.dart';

/// Estado y mandos de la cinta insertada (gestor de cintas, doc/TAPE_MANAGER.md). Común a
/// Windows (panel) y Android (cassette + hoja con la lista): la UI solo escucha y llama.
///
/// La posición la da el core (`zx_tape_info`): CLK avisa cada bloque cuando empieza a sonar,
/// también con la carga rápida. Moverse = recortar la cinta desde el bloque N y reinsertarla.
class TapeController extends ChangeNotifier {
  TapeController(this._zx);

  final ZxBridge _zx;

  /// Archivo insertado (null = sin cinta) y su lista de bloques (null en .csw).
  String? path;
  TapeFile? tape;
  ZxTapeInfo info = ZxTapeInfo.none;

  /// Una fila por cabecera + datos (como ZEsarUX) o un bloque por fila.
  bool pairBlocks = true;
  List<TapeRow> _rows = const [];
  List<TapeRow> get rows => _rows;

  /// Destino de la grabación (.tap); null = sin grabar.
  String? recordPath;
  int recordedBlocks = 0;
  Future<void> _writing = Future.value();

  /// Se llama con el nombre del bloque cuando la cinta pasa a otro (el LCD lo muestra).
  void Function(String description)? onBlockChanged;

  bool get hasTape => path != null && info.hasTape;
  bool get hasList => tape != null && tape!.blocks.isNotEmpty;
  bool get recording => recordPath != null;
  int get total => tape?.blocks.length ?? 0;

  /// Fila de la lista donde está la cinta.
  int get currentRow => TapeFile.rowOf(_rows, info.block);

  TapeStatus get status {
    if (recording) return TapeStatus.recording;
    if (!hasTape) return TapeStatus.empty;
    if (info.atEnd) return TapeStatus.end;
    if (info.isPlaying) return TapeStatus.playing;
    if (info.isPaused) return TapeStatus.paused;
    return TapeStatus.stopped;
  }

  /// Máquina nueva con [mediaPath] (vacío = BASIC): la cinta es la del archivo, si lo es.
  Future<void> attach(String mediaPath) async {
    final ext = mediaPath.split('.').last.toLowerCase();
    final isTape = ext == 'tap' || ext == 'tzx' || ext == 'csw';
    path = isTape ? mediaPath : null;
    tape = isTape ? await TapeFile.load(mediaPath) : null;
    if (recordPath != null) _zx.tapeRecord(true); // la máquina nueva empieza sin grabar
    info = _zx.tapeInfo();
    _rebuildRows();
    notifyListeners();
  }

  void _rebuildRows() => _rows = tape?.rows(pair: pairBlocks) ?? const [];

  void setPairBlocks(bool v) {
    pairBlocks = v;
    _rebuildRows();
    notifyListeners();
  }

  /// En cada tick del emulador.
  void poll() {
    final now = _zx.tapeInfo();
    if (now != info) {
      final blockChanged = now.block != info.block;
      info = now;
      if (blockChanged && tape != null && now.block < tape!.blocks.length) {
        onBlockChanged?.call(tape!.blocks[now.block].description);
      }
      notifyListeners();
    }
    if (recordPath != null) {
      final data = _zx.takeRecorded();
      if (data.isNotEmpty) _append(recordPath!, data);
    }
  }

  // --- Transporte ------------------------------------------------------------

  void play() {
    if (!hasTape) return;
    if (info.atEnd && hasList) _zx.tapeSeek(0); // al final: vuelve a empezar
    _zx.tapePause(false);
    _zx.tapePlaying = true;
    poll();
  }

  void pause() {
    if (!hasTape) return;
    _zx.tapePause(true);
    poll();
  }

  void togglePlay() => info.isPlaying ? pause() : play();

  /// Stop: pausa y vuelve al inicio del bloque (fila) actual.
  void stop() {
    if (!hasTape) return;
    _zx.tapePause(true);
    if (hasList && !info.atEnd) seekBlock(_rows.isEmpty ? 0 : _rows[currentRow].first);
    poll();
  }

  void rewind() => seekBlock(0);

  /// Fila anterior: si la cinta ya avanzó dentro de la actual, vuelve a su inicio.
  void previous() {
    if (!hasList || _rows.isEmpty) return;
    final r = currentRow;
    final atRowStart = info.block == _rows[r].first;
    seekBlock(_rows[atRowStart && r > 0 ? r - 1 : r].first);
  }

  void next() {
    if (!hasList || _rows.isEmpty) return;
    final r = currentRow;
    seekBlock(r + 1 < _rows.length ? _rows[r + 1].first : total);
  }

  void seekRow(int row) {
    if (row >= 0 && row < _rows.length) seekBlock(_rows[row].first);
  }

  void seekBlock(int block) {
    if (!hasList) return;
    _zx.tapeSeek(block);
    poll();
  }

  /// Cambia de cinta sin reiniciar la máquina.
  Future<bool> insert(String newPath) async {
    if (!_zx.tapeInsert(newPath)) return false;
    path = newPath;
    tape = await TapeFile.load(newPath);
    _rebuildRows();
    poll();
    notifyListeners();
    return true;
  }

  void eject() {
    _zx.tapeEject();
    path = null;
    tape = null;
    _rebuildRows();
    poll();
    notifyListeners();
  }

  /// Vuelve a leer la lista (la cinta se editó en disco). No toca la posición del core.
  Future<void> reload() async {
    if (path == null) return;
    tape = await TapeFile.load(path!);
    _rebuildRows();
    notifyListeners();
  }

  // --- Grabación (SAVE del ROM) ----------------------------------------------

  /// Empieza a grabar los SAVE en [target] (.tap): los bloques se añaden al final.
  /// [target] no puede ser la cinta insertada (el core la tiene abierta).
  void startRecording(String target) {
    recordPath = target;
    recordedBlocks = 0;
    _zx.takeRecorded(); // descartar restos de una grabación anterior
    _zx.tapeRecord(true);
    poll();
    notifyListeners();
  }

  /// Termina la grabación; devuelve el archivo grabado (null si no se grabó nada).
  Future<String?> stopRecording() async {
    final target = recordPath;
    if (target == null) return null;
    final rest = _zx.takeRecorded();
    if (rest.isNotEmpty) _append(target, rest);
    _zx.tapeRecord(false);
    recordPath = null;
    await _writing;
    poll();
    notifyListeners();
    return recordedBlocks > 0 ? target : null;
  }

  void _append(String target, Uint8List data) {
    var n = 0;
    for (var p = 0; p + 2 <= data.length; p += 2 + (data[p] | (data[p + 1] << 8))) {
      n++;
    }
    recordedBlocks += n;
    notifyListeners();
    _writing = _writing.then((_) async {
      final f = File(target);
      final old = await f.exists() ? await f.readAsBytes() : Uint8List(0);
      await writeFileAtomic(target, [...old, ...data]);
    }).catchError((Object e) {
      debugPrint('TapeController: no se pudo grabar en $target: $e');
    });
  }

  @override
  void dispose() {
    if (recordPath != null) _zx.tapeRecord(false);
    super.dispose();
  }
}

enum TapeStatus { empty, stopped, playing, paused, end, recording }
