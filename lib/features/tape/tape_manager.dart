import 'package:flutter/material.dart';

import '../../core/l10n.dart';
import '../../core/tape/tape_controller.dart';
import '../../core/tape/tape_file.dart';
import '../../core/theme/easy_theme.dart';

/// Piezas del gestor de cintas comunes a Windows (panel) y Android (hoja inferior):
/// lista de bloques, barra de transporte y línea de estado. Ver doc/TAPE_MANAGER.md.

String tapeStatusText(AppLocalizations t, TapeStatus s) => switch (s) {
      TapeStatus.empty => t.tapeStatusEmpty,
      TapeStatus.stopped => t.tapeStatusStopped,
      TapeStatus.playing => t.tapeStatusPlaying,
      TapeStatus.paused => t.tapeStatusPaused,
      TapeStatus.end => t.tapeStatusEnd,
      TapeStatus.recording => t.tapeStatusRecording,
    };

/// "Playing · Block 3 of 34" (el bloque se cuenta desde 1, como en ZEsarUX).
String tapeStatusLine(AppLocalizations t, TapeController c) {
  final status = tapeStatusText(t, c.status);
  if (!c.hasList) return status;
  final block = (c.info.block + 1).clamp(1, c.total);
  return '$status · ${t.tapeBlockOf(block, c.total)}';
}

/// Lista de bloques: la fila de la posición de la cinta resaltada y a la vista.
/// [onSeek] mueve la cinta a esa fila (doble clic en escritorio, toque en móvil).
class TapeBlockList extends StatefulWidget {
  final TapeController controller;
  final bool doubleTapToSeek;
  final double fontSize;
  const TapeBlockList({super.key, required this.controller, this.doubleTapToSeek = true, this.fontSize = 16});

  @override
  State<TapeBlockList> createState() => _TapeBlockListState();
}

class _TapeBlockListState extends State<TapeBlockList> {
  final _scroll = ScrollController();
  int _shownRow = -1;

  double get _rowHeight => widget.fontSize * 3.4;

  @override
  void dispose() {
    _scroll.dispose();
    super.dispose();
  }

  /// Autoscroll: solo si la fila actual quedó fuera de la vista.
  void _follow(int row) {
    if (row == _shownRow) return;
    _shownRow = row;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!_scroll.hasClients) return;
      final top = row * _rowHeight, bottom = top + _rowHeight;
      final view = _scroll.position;
      if (top < view.pixels) {
        _scroll.animateTo(top, duration: const Duration(milliseconds: 200), curve: Curves.easeOut);
      } else if (bottom > view.pixels + view.viewportDimension) {
        _scroll.animateTo((bottom - view.viewportDimension).clamp(0, view.maxScrollExtent),
            duration: const Duration(milliseconds: 200), curve: Curves.easeOut);
      }
    });
  }

  @override
  Widget build(BuildContext context) {
    final t = context.l10n;
    return ListenableBuilder(
      listenable: widget.controller,
      builder: (context, _) {
        final c = widget.controller;
        if (!c.hasTape) {
          return Center(child: Text(t.tapeStatusEmpty, style: const TextStyle(color: ZxColors.textDim, fontSize: 18)));
        }
        if (!c.hasList) {
          return Center(
              child: Text(t.tapeNoList,
                  textAlign: TextAlign.center, style: const TextStyle(color: ZxColors.textDim, fontSize: 18)));
        }
        final rows = c.rows;
        final current = c.info.atEnd ? -1 : c.currentRow;
        _follow(current < 0 ? rows.length - 1 : current);
        return ListView.builder(
          controller: _scroll,
          itemExtent: _rowHeight,
          itemCount: rows.length,
          itemBuilder: (context, r) => _row(c, rows[r], r, r == current, t),
        );
      },
    );
  }

  Widget _row(TapeController c, TapeRow row, int index, bool active, AppLocalizations t) {
    final blocks = [for (final i in row.blocks) c.tape!.blocks[i]];
    final bad = blocks.any((b) => b.checksumOk == false);
    final fs = widget.fontSize;
    void seek() => c.seekRow(index);
    return Material(
      color: active ? ZxColors.cyan.withValues(alpha: 0.22) : Colors.transparent,
      child: InkWell(
        onTap: widget.doubleTapToSeek ? null : seek,
        onDoubleTap: widget.doubleTapToSeek ? seek : null,
        child: Padding(
          padding: EdgeInsets.symmetric(horizontal: fs * 0.6),
          child: Row(
            children: [
              SizedBox(
                width: fs * 2.4,
                child: Text('${row.first + 1}',
                    style: TextStyle(fontSize: fs * 0.85, color: active ? ZxColors.cyan : ZxColors.textDim)),
              ),
              Icon(active ? Icons.play_arrow_rounded : _iconFor(blocks.first.kind),
                  size: fs * 1.3, color: active ? ZxColors.cyan : Colors.white70),
              SizedBox(width: fs * 0.5),
              Expanded(
                child: Column(
                  mainAxisAlignment: MainAxisAlignment.center,
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(row.title,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(fontSize: fs, color: Colors.white, fontWeight: active ? FontWeight.bold : null)),
                    if (row.detail != null)
                      Text(row.detail!,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: TextStyle(fontSize: fs * 0.8, color: ZxColors.textDim)),
                  ],
                ),
              ),
              if (bad)
                Tooltip(
                  message: t.tapeChecksumBad,
                  child: Icon(Icons.error_outline_rounded, size: fs * 1.2, color: ZxColors.red),
                ),
            ],
          ),
        ),
      ),
    );
  }

  static IconData _iconFor(TapeBlockKind k) => switch (k) {
        TapeBlockKind.program => Icons.code_rounded,
        TapeBlockKind.bytes || TapeBlockKind.numberArray || TapeBlockKind.charArray => Icons.memory_rounded,
        TapeBlockKind.data || TapeBlockKind.turbo || TapeBlockKind.pureData => Icons.storage_rounded,
        TapeBlockKind.pause => Icons.pause_rounded,
        TapeBlockKind.text || TapeBlockKind.info || TapeBlockKind.group => Icons.notes_rounded,
        _ => Icons.graphic_eq_rounded,
      };
}

/// ● ▶ ⏸ ■ ⏮ ⏭ ⏏. [onRecord] null = sin botón de grabar.
class TapeTransportBar extends StatelessWidget {
  final TapeController controller;
  final VoidCallback? onRecord;
  final VoidCallback? onEject;
  final VoidCallback? afterAction; // devolver el foco al Spectrum, etc.
  final double size;
  const TapeTransportBar({
    super.key,
    required this.controller,
    this.onRecord,
    this.onEject,
    this.afterAction,
    this.size = 28,
  });

  @override
  Widget build(BuildContext context) {
    final t = context.l10n;
    return ListenableBuilder(
      listenable: controller,
      builder: (context, _) {
        final c = controller;
        final has = c.hasTape, list = c.hasList;
        Widget b(IconData icon, String tip, VoidCallback? onTap, {Color? colour, bool active = false}) => IconButton(
              iconSize: size,
              tooltip: tip,
              color: colour ?? Colors.white,
              disabledColor: Colors.white24,
              isSelected: active,
              style: active
                  ? IconButton.styleFrom(backgroundColor: (colour ?? ZxColors.cyan).withValues(alpha: 0.2))
                  : null,
              onPressed: onTap == null
                  ? null
                  : () {
                      onTap();
                      afterAction?.call();
                    },
              icon: Icon(icon),
            );
        return Wrap(
          alignment: WrapAlignment.center,
          children: [
            if (onRecord != null)
              b(Icons.fiber_manual_record_rounded, t.tapeRecord, onRecord, colour: ZxColors.red, active: c.recording),
            b(Icons.play_arrow_rounded, t.tapePlay, has ? c.play : null, active: c.info.isPlaying),
            b(Icons.pause_rounded, t.tapePause, has ? c.pause : null, active: c.info.isPaused),
            b(Icons.stop_rounded, t.tapeStop, has ? c.stop : null),
            b(Icons.skip_previous_rounded, t.tapePrevBlock, list ? c.previous : null),
            b(Icons.skip_next_rounded, t.tapeNextBlock, list ? c.next : null),
            b(Icons.eject_rounded, t.tapeEject, has ? (onEject ?? c.eject) : null),
          ],
        );
      },
    );
  }
}

/// Icono de cinta + "Playing · Block 3 of 34" (+ bloques grabados).
class TapeStatusBar extends StatelessWidget {
  final TapeController controller;
  final double fontSize;
  const TapeStatusBar({super.key, required this.controller, this.fontSize = 16});

  @override
  Widget build(BuildContext context) {
    final t = context.l10n;
    return ListenableBuilder(
      listenable: controller,
      builder: (context, _) {
        final c = controller;
        final colour = switch (c.status) {
          TapeStatus.recording => ZxColors.red,
          TapeStatus.playing => ZxColors.green,
          TapeStatus.end => ZxColors.yellow,
          _ => ZxColors.textDim,
        };
        return Row(
          children: [
            Icon(Icons.album_rounded, size: fontSize * 1.4, color: colour),
            SizedBox(width: fontSize * 0.5),
            Expanded(
              child: Text(
                [
                  tapeStatusLine(t, c),
                  if (c.recording) t.tapeRecorded(c.recordedBlocks),
                ].join(' · '),
                overflow: TextOverflow.ellipsis,
                style: TextStyle(fontSize: fontSize, color: Colors.white),
              ),
            ),
          ],
        );
      },
    );
  }
}

/// Panel del gestor de cintas para Windows: se acopla a la derecha de la ventana.
class TapeManagerPanel extends StatelessWidget {
  static const width = 400.0;
  final TapeController controller;
  final bool quickLoad;
  final bool muteTape;
  final ValueChanged<bool> onQuickLoad;
  final ValueChanged<bool> onMuteTape;
  final VoidCallback onInsert;
  final VoidCallback onRecord;
  final VoidCallback onNewTape;
  final VoidCallback? onEditTape;
  final VoidCallback? onConvertToTap;
  final VoidCallback onClose;
  final VoidCallback afterAction;

  const TapeManagerPanel({
    super.key,
    required this.controller,
    required this.quickLoad,
    required this.muteTape,
    required this.onQuickLoad,
    required this.onMuteTape,
    required this.onInsert,
    required this.onRecord,
    required this.onNewTape,
    required this.onEditTape,
    required this.onConvertToTap,
    required this.onClose,
    required this.afterAction,
  });

  @override
  Widget build(BuildContext context) {
    final t = context.l10n;
    Widget check(String label, bool value, ValueChanged<bool> onChanged) => InkWell(
          onTap: () {
            onChanged(!value);
            afterAction();
          },
          child: Row(mainAxisSize: MainAxisSize.min, children: [
            Checkbox(value: value, onChanged: (v) {
              onChanged(v ?? false);
              afterAction();
            }),
            Text(label, style: const TextStyle(fontSize: 14)),
            const SizedBox(width: 8),
          ]),
        );
    return Container(
      width: width,
      decoration: const BoxDecoration(
        color: Color(0xFF111214),
        border: Border(left: BorderSide(color: Colors.white12)),
      ),
      child: ListenableBuilder(
        listenable: controller,
        builder: (context, _) {
          final c = controller;
          final name = c.path?.split(RegExp(r'[\\/]')).last ?? t.tapeStatusEmpty;
          return Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              // Cabecera: nombre del archivo.
              Container(
                padding: const EdgeInsets.fromLTRB(12, 6, 4, 6),
                color: Colors.black,
                child: Row(children: [
                  const Icon(Icons.album_rounded, color: ZxColors.cyan),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Text(name,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(fontSize: 16, fontWeight: FontWeight.bold)),
                  ),
                  IconButton(tooltip: t.tapeInsert, icon: const Icon(Icons.folder_open_rounded), onPressed: onInsert),
                  IconButton(tooltip: t.exit, icon: const Icon(Icons.close_rounded), onPressed: onClose),
                ]),
              ),
              Wrap(children: [
                check(t.quickLoad, quickLoad, onQuickLoad),
                check(t.tapeMuteSound, muteTape, onMuteTape),
                check(t.tapePairBlocks, c.pairBlocks, c.setPairBlocks),
              ]),
              const Divider(height: 1),
              Expanded(child: TapeBlockList(controller: c)),
              const Divider(height: 1),
              TapeTransportBar(controller: c, onRecord: onRecord, afterAction: afterAction, size: 26),
              Padding(
                padding: const EdgeInsets.fromLTRB(12, 0, 12, 6),
                child: TapeStatusBar(controller: c, fontSize: 14),
              ),
              const Divider(height: 1),
              Padding(
                padding: const EdgeInsets.all(6),
                child: Wrap(
                  spacing: 6,
                  runSpacing: 6,
                  children: [
                    OutlinedButton.icon(
                        onPressed: onNewTape, icon: const Icon(Icons.add_rounded), label: Text(t.tapeNew)),
                    OutlinedButton.icon(
                        onPressed: onEditTape, icon: const Icon(Icons.edit_rounded), label: Text(t.tapeEdit)),
                    if (c.tape?.tzx ?? false)
                      OutlinedButton.icon(
                          onPressed: onConvertToTap,
                          icon: const Icon(Icons.transform_rounded),
                          label: Text(t.tapeConvertTap)),
                  ],
                ),
              ),
            ],
          );
        },
      ),
    );
  }
}

/// Hoja inferior de Android: estado, lista (tocar = mover la cinta ahí) y acciones.
Future<void> showTapeSheet(
  BuildContext context, {
  required TapeController controller,
  required VoidCallback onInsert,
  required VoidCallback onRecord,
  required VoidCallback onNewTape,
  VoidCallback? onEditTape,
}) {
  final t = context.l10n;
  return showModalBottomSheet<void>(
    context: context,
    isScrollControlled: true,
    backgroundColor: ZxColors.bodyLight,
    builder: (ctx) => SafeArea(
      child: SizedBox(
        height: MediaQuery.sizeOf(ctx).height * 0.75,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(20, 16, 20, 4),
              child: Text(t.tapeBlockList, style: const TextStyle(fontSize: 22, fontWeight: FontWeight.bold)),
            ),
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 4),
              child: TapeStatusBar(controller: controller, fontSize: 18),
            ),
            const Divider(height: 1),
            Expanded(child: TapeBlockList(controller: controller, doubleTapToSeek: false, fontSize: 18)),
            const Divider(height: 1),
            TapeTransportBar(controller: controller, onRecord: onRecord, size: 34),
            Padding(
              padding: const EdgeInsets.fromLTRB(12, 0, 12, 12),
              child: Wrap(
                spacing: 8,
                runSpacing: 8,
                alignment: WrapAlignment.center,
                children: [
                  _SheetButton(Icons.folder_open_rounded, t.tapeInsert, () {
                    Navigator.pop(ctx);
                    onInsert();
                  }),
                  _SheetButton(Icons.add_rounded, t.tapeNew, () {
                    Navigator.pop(ctx);
                    onNewTape();
                  }),
                  if (onEditTape != null)
                    _SheetButton(Icons.edit_rounded, t.tapeEdit, () {
                      Navigator.pop(ctx);
                      onEditTape();
                    }),
                ],
              ),
            ),
          ],
        ),
      ),
    ),
  );
}

class _SheetButton extends StatelessWidget {
  final IconData icon;
  final String label;
  final VoidCallback onTap;
  const _SheetButton(this.icon, this.label, this.onTap);

  @override
  Widget build(BuildContext context) => SizedBox(
        height: 64,
        child: OutlinedButton.icon(
          onPressed: onTap,
          icon: Icon(icon, size: 28),
          label: Text(label, style: const TextStyle(fontSize: 18)),
        ),
      );
}
