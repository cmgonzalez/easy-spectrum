import 'dart:io';

import 'package:desktop_drop/desktop_drop.dart';
import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../core/l10n.dart';
import '../../core/storage/game_library.dart';
import '../../core/tape/tape_builder.dart';
import '../../core/tape/tape_file.dart';
import '../../core/tape/zx_basic.dart';
import '../../core/theme/easy_theme.dart';

/// Editor de cintas (gestor de cintas, fase 3): arma un .tap (o .tzx si hay bloques no
/// estándar) desde archivos: código, pantallas, BASIC, datos crudos, un cargador listo
/// (BASIC + CODE, pensado para PRISMA) o bloques de otra cinta. Reordenar, renombrar,
/// duplicar y borrar. Sin emulación. Común a Windows y Android.
class TapeEditorScreen extends StatefulWidget {
  /// Cinta a editar (null = nueva).
  final String? path;

  /// Antes de escribir [path]: el emulador puede tener abierta esa misma cinta (en Windows
  /// no se puede reemplazar un archivo abierto). Devuelve una función para reinsertarla.
  final Future<Future<void> Function()?> Function(String path)? beforeOverwrite;

  const TapeEditorScreen({super.key, this.path, this.beforeOverwrite});

  @override
  State<TapeEditorScreen> createState() => _TapeEditorScreenState();
}

class _TapeEditorScreenState extends State<TapeEditorScreen> {
  final List<TapeItem> _items = [];
  String? _path;
  bool _dirty = false;
  bool _dragging = false;

  static bool get _desktop => Platform.isWindows || Platform.isLinux || Platform.isMacOS;

  @override
  void initState() {
    super.initState();
    _path = widget.path;
    if (_path != null) _loadInitial(_path!);
  }

  Future<void> _loadInitial(String path) async {
    final tape = await TapeFile.load(path);
    if (!mounted || tape == null) return;
    setState(() => _items.addAll(TapeBuilder.fromTape(tape)));
  }

  void _change(void Function() f) => setState(() {
        f();
        _dirty = true;
      });

  // --- Archivos --------------------------------------------------------------

  static String _baseName(String path) => path.split(RegExp(r'[\\/]')).last;
  static String _stem(String path) {
    final n = _baseName(path);
    final dot = n.lastIndexOf('.');
    return dot <= 0 ? n : n.substring(0, dot);
  }

  static String _ext(String path) {
    final n = _baseName(path);
    final dot = n.lastIndexOf('.');
    return dot < 0 ? '' : n.substring(dot + 1).toLowerCase();
  }

  /// Un archivo del disco/selector: (nombre, bytes).
  Future<(String, Uint8List)?> _pickFile({List<String>? extensions}) async {
    final r = await FilePicker.platform.pickFiles(
      type: extensions == null ? FileType.any : FileType.custom,
      allowedExtensions: extensions,
      withData: !_desktop,
    );
    final f = r?.files.singleOrNull;
    if (f == null) return null;
    final bytes = f.bytes ?? (f.path != null ? await File(f.path!).readAsBytes() : null);
    return bytes == null ? null : (f.name, bytes);
  }

  void _error(Object e) {
    if (!mounted) return;
    final msg = e is FormatException ? e.message : '$e';
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(context.l10n.tapeBadFile(msg))));
  }

  /// Añade un archivo según su tipo (también al soltarlo sobre la lista).
  Future<void> _addFile(String name, Uint8List bytes) async {
    try {
      switch (_ext(name)) {
        case 'tap' || 'tzx':
          final tape = TapeFile.parse(bytes, tzx: _ext(name) == 'tzx');
          _change(() => _items.addAll(TapeBuilder.fromTape(tape)));
        case 'scr' when bytes.length == 6912:
          _change(() => _items.addAll(TapeBuilder.screen(_stem(name), bytes)));
        case 'bas' || 'txt':
          final items = await _basicDialog(name: _stem(name), source: String.fromCharCodes(bytes));
          if (items != null) _change(() => _items.addAll(items));
        default:
          final items = await _codeDialog(name: _stem(name), data: bytes);
          if (items != null) _change(() => _items.addAll(items));
      }
    } catch (e) {
      _error(e);
    }
  }

  Future<void> _add() async {
    final t = context.l10n;
    final choice = await showModalBottomSheet<String>(
      context: context,
      backgroundColor: ZxColors.bodyLight,
      builder: (ctx) => SafeArea(
        child: SingleChildScrollView(
          child: Column(mainAxisSize: MainAxisSize.min, children: [
            for (final (icon, label, value) in [
              (Icons.rocket_launch_rounded, t.tapeAddLoader, 'loader'),
              (Icons.memory_rounded, t.tapeAddCode, 'code'),
              (Icons.image_rounded, t.tapeAddScreen, 'screen'),
              (Icons.code_rounded, t.tapeAddBasic, 'basic'),
              (Icons.storage_rounded, t.tapeAddData, 'data'),
              (Icons.album_rounded, t.tapeAddFromTape, 'tape'),
            ])
              ListTile(
                minTileHeight: 64,
                leading: Icon(icon, size: 30),
                title: Text(label, style: const TextStyle(fontSize: 20)),
                onTap: () => Navigator.pop(ctx, value),
              ),
          ]),
        ),
      ),
    );
    try {
      switch (choice) {
        case 'loader':
          final items = await _loaderDialog();
          if (items != null) _change(() => _items.addAll(items));
        case 'code':
          final f = await _pickFile();
          if (f == null) return;
          final items = await _codeDialog(name: _stem(f.$1), data: f.$2);
          if (items != null) _change(() => _items.addAll(items));
        case 'screen':
          final f = await _pickFile(extensions: ['scr']);
          if (f == null) return;
          if (f.$2.length != 6912) throw const FormatException('A SCREEN\$ must be 6912 bytes');
          _change(() => _items.addAll(TapeBuilder.screen(_stem(f.$1), f.$2)));
        case 'basic':
          final items = await _basicDialog(name: 'program');
          if (items != null) _change(() => _items.addAll(items));
        case 'data':
          final f = await _pickFile();
          if (f == null) return;
          final flag = await _flagDialog();
          if (flag != null) _change(() => _items.add(TapeBuilder.rawData(f.$2, flag: flag)));
        case 'tape':
          final f = await _pickFile(extensions: ['tap', 'tzx']);
          if (f != null) await _addFile(f.$1, f.$2);
      }
    } catch (e) {
      _error(e);
    }
  }

  Future<void> _save() async {
    final t = context.l10n;
    if (_items.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(t.tapeEmpty)));
      return;
    }
    final tzx = TapeBuilder.needsTzx(_items);
    final data = tzx ? TapeBuilder.exportTzx(_items) : TapeBuilder.exportTap(_items);
    final ext = tzx ? 'tzx' : 'tap';
    var name = _path != null ? '${_stem(_path!)}.$ext' : 'tape.$ext';
    if (tzx) ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(t.tapeNeedsTzx)));
    try {
      if (_desktop) {
        final target = await FilePicker.platform.saveFile(
          dialogTitle: t.tapeSave,
          fileName: name,
          initialDirectory: _path != null ? File(_path!).parent.path : null,
          type: FileType.custom,
          allowedExtensions: [ext],
        );
        if (target == null) return;
        final out = target.toLowerCase().endsWith('.$ext') ? target : '$target.$ext';
        final reinsert = widget.beforeOverwrite == null ? null : await widget.beforeOverwrite!(out);
        await writeFileAtomic(out, data);
        await reinsert?.call();
        _path = out;
        name = _baseName(out);
      } else {
        // Android: al selector del sistema (SAF); "Añadir a Mis juegos" va aparte.
        final r = await FilePicker.platform.saveFile(dialogTitle: t.tapeSave, fileName: name, bytes: data);
        if (r == null) return;
      }
      if (!mounted) return;
      setState(() => _dirty = false);
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(t.tapeSaved(name))));
    } catch (e) {
      _error(e);
    }
  }

  Future<void> _addToLibrary() async {
    final t = context.l10n;
    if (_items.isEmpty) return;
    final tzx = TapeBuilder.needsTzx(_items);
    final data = tzx ? TapeBuilder.exportTzx(_items) : TapeBuilder.exportTap(_items);
    final first = _items.map((i) => i.name).whereType<String>().firstOrNull;
    final stem = _path != null ? _stem(_path!) : (first == null || first.isEmpty ? 'tape' : first);
    try {
      await GameLibrary.import('$stem.${tzx ? 'tzx' : 'tap'}', data);
      if (mounted) ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(t.tapeAdded)));
    } catch (e) {
      _error(e);
    }
  }

  Future<bool> _confirmLeave() async {
    if (!_dirty) return true;
    final t = context.l10n;
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        content: Text(t.tapeUnsaved, style: const TextStyle(fontSize: 18)),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx, false), child: Text(t.cancel)),
          TextButton(onPressed: () => Navigator.pop(ctx, true), child: Text(t.tapeDiscard)),
        ],
      ),
    );
    return ok ?? false;
  }

  // --- Diálogos --------------------------------------------------------------

  static int? _parseAddress(String s) {
    final v = s.trim().toLowerCase();
    final n = v.startsWith('0x')
        ? int.tryParse(v.substring(2), radix: 16)
        : v.startsWith('\$')
            ? int.tryParse(v.substring(1), radix: 16)
            : int.tryParse(v);
    return n != null && n >= 0 && n <= 65535 ? n : null;
  }

  Future<List<TapeItem>?> _codeDialog({required String name, required Uint8List data}) async {
    final t = context.l10n;
    final nameCtl = TextEditingController(text: _clip(name));
    final addrCtl = TextEditingController(text: '32768');
    return _formDialog(t.tapeAddCode, [
      _field(nameCtl, t.tapeBlockName, max: 10),
      _field(addrCtl, t.tapeLoadAddress),
    ], () {
      final a = _parseAddress(addrCtl.text);
      if (a == null) throw FormatException(t.tapeInvalidAddress);
      return TapeBuilder.code(nameCtl.text, a, data);
    });
  }

  Future<List<TapeItem>?> _basicDialog({required String name, String source = ''}) async {
    final t = context.l10n;
    final nameCtl = TextEditingController(text: _clip(name));
    final lineCtl = TextEditingController();
    final textCtl = TextEditingController(text: source);
    return _formDialog(t.tapeAddBasic, [
      _field(nameCtl, t.tapeBlockName, max: 10),
      _field(lineCtl, t.tapeAutostart),
      TextField(
        controller: textCtl,
        minLines: 6,
        maxLines: 12,
        style: const TextStyle(fontFamily: 'monospace', fontSize: 16),
        decoration: InputDecoration(labelText: t.tapeBasicText, border: const OutlineInputBorder()),
      ),
    ], () {
      final line = lineCtl.text.trim().isEmpty ? null : int.tryParse(lineCtl.text.trim());
      if (lineCtl.text.trim().isNotEmpty && (line == null || line > 9999)) {
        throw const FormatException('LINE 0-9999');
      }
      final items = line == null
          ? TapeBuilder.basicText(nameCtl.text, textCtl.text)
          : TapeBuilder.basicProgram(nameCtl.text, ZxBasic.tokenize(textCtl.text), autostart: line);
      return items;
    });
  }


  Future<List<TapeItem>?> _loaderDialog() async {
    final t = context.l10n;
    final code = await _pickFile();
    if (code == null || !mounted) return null;
    final nameCtl = TextEditingController(text: _clip(_stem(code.$1)));
    final addrCtl = TextEditingController(text: '32768');
    final runCtl = TextEditingController();
    Uint8List? screen;
    String? screenName;
    return _formDialog(t.tapeAddLoader, [
      _field(nameCtl, t.tapeBlockName, max: 10),
      _field(addrCtl, t.tapeLoadAddress),
      _field(runCtl, t.tapeRunAddress),
      StatefulBuilder(
        builder: (ctx, set) => OutlinedButton.icon(
          icon: const Icon(Icons.image_rounded),
          label: Text(screenName ?? t.tapeWithScreen),
          onPressed: () async {
            final f = await _pickFile(extensions: ['scr']);
            if (f == null) return;
            if (f.$2.length != 6912) {
              _error(const FormatException('A SCREEN\$ must be 6912 bytes'));
              return;
            }
            set(() {
              screen = f.$2;
              screenName = f.$1;
            });
          },
        ),
      ),
    ], () {
      final a = _parseAddress(addrCtl.text);
      final r = runCtl.text.trim().isEmpty ? a : _parseAddress(runCtl.text);
      if (a == null || r == null) throw FormatException(t.tapeInvalidAddress);
      return TapeBuilder.loader(name: nameCtl.text, address: a, run: r, code: code.$2, screen: screen);
    });
  }

  Future<int?> _flagDialog() async {
    final t = context.l10n;
    final ctl = TextEditingController(text: '255');
    final r = await _formDialog<int>(t.tapeAddData, [_field(ctl, t.tapeFlag)], () {
      final v = int.tryParse(ctl.text.trim());
      if (v == null || v < 0 || v > 255) throw const FormatException('Flag 0-255');
      return v;
    });
    return r;
  }

  Future<String?> _renameDialog(String current) async {
    final t = context.l10n;
    final ctl = TextEditingController(text: current);
    return _formDialog(t.tapeRename, [_field(ctl, t.tapeBlockName, max: 10)], () => ctl.text);
  }

  static String _clip(String s) => s.length > 10 ? s.substring(0, 10) : s;

  Widget _field(TextEditingController c, String label, {int? max}) => Padding(
        padding: const EdgeInsets.only(bottom: 12),
        child: TextField(
          controller: c,
          maxLength: max,
          inputFormatters: max == null ? null : [LengthLimitingTextInputFormatter(max)],
          style: const TextStyle(fontSize: 18),
          decoration: InputDecoration(labelText: label, border: const OutlineInputBorder()),
        ),
      );

  /// Diálogo con campos; [build] valida (lanza FormatException) y arma el resultado.
  Future<T?> _formDialog<T>(String title, List<Widget> fields, T Function() build) {
    final t = context.l10n;
    String? error;
    return showDialog<T>(
      context: context,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, set) => AlertDialog(
          title: Text(title),
          content: SizedBox(
            width: 460,
            child: SingleChildScrollView(
              child: Column(mainAxisSize: MainAxisSize.min, children: [
                ...fields,
                if (error != null) Text(error!, style: const TextStyle(color: ZxColors.red, fontSize: 16)),
              ]),
            ),
          ),
          actions: [
            TextButton(onPressed: () => Navigator.pop(ctx), child: Text(t.cancel)),
            TextButton(
              onPressed: () {
                try {
                  Navigator.pop(ctx, build());
                } on FormatException catch (e) {
                  set(() => error = e.message);
                }
              },
              child: Text(t.tapeAdd),
            ),
          ],
        ),
      ),
    );
  }

  // --- UI --------------------------------------------------------------------

  Future<void> _itemMenu(int i) async {
    final t = context.l10n;
    final item = _items[i];
    final choice = await showModalBottomSheet<String>(
      context: context,
      backgroundColor: ZxColors.bodyLight,
      builder: (ctx) => SafeArea(
        child: Column(mainAxisSize: MainAxisSize.min, children: [
          for (final (icon, label, value, enabled) in [
            (Icons.drive_file_rename_outline_rounded, t.tapeRename, 'rename', item.name != null),
            (Icons.copy_rounded, t.tapeDuplicate, 'dup', true),
            (Icons.arrow_upward_rounded, t.tapeMoveUp, 'up', i > 0),
            (Icons.arrow_downward_rounded, t.tapeMoveDown, 'down', i < _items.length - 1),
            (Icons.delete_rounded, t.delete, 'delete', true),
          ])
            ListTile(
              minTileHeight: 64,
              enabled: enabled,
              leading: Icon(icon, size: 30),
              title: Text(label, style: const TextStyle(fontSize: 20)),
              onTap: () => Navigator.pop(ctx, value),
            ),
        ]),
      ),
    );
    switch (choice) {
      case 'rename':
        final n = await _renameDialog(item.name ?? '');
        if (n != null) _change(() => _items[i] = TapeBuilder.rename(item, n));
      case 'dup':
        final copy = item.isStandard
            ? TapeItem.standard(Uint8List.fromList(item.payload!), pauseMs: item.pauseMs)
            : TapeItem.raw(Uint8List.fromList(item.raw!));
        _change(() => _items.insert(i + 1, copy));
      case 'up':
        _change(() => _items.insert(i - 1, _items.removeAt(i)));
      case 'down':
        _change(() => _items.insert(i + 1, _items.removeAt(i)));
      case 'delete':
        _change(() => _items.removeAt(i));
    }
  }

  @override
  Widget build(BuildContext context) {
    final t = context.l10n;
    final title = _path == null ? t.tapeNew : _baseName(_path!);
    Widget list = _items.isEmpty
        ? Center(
            child: Padding(
              padding: const EdgeInsets.all(24),
              child: Text(_desktop ? t.tapeDropHint : t.tapeEmpty,
                  textAlign: TextAlign.center, style: const TextStyle(fontSize: 18, color: ZxColors.textDim)),
            ),
          )
        : ReorderableListView.builder(
            itemCount: _items.length,
            // onReorderItem ya corrige el índice destino por el elemento quitado.
            onReorderItem: (a, b) => _change(() => _items.insert(b, _items.removeAt(a))),
            itemBuilder: (context, i) {
              final item = _items[i];
              final block = item.block;
              return ListTile(
                key: ObjectKey(item),
                minTileHeight: 64,
                leading: Text('${i + 1}', style: const TextStyle(fontSize: 16, color: ZxColors.textDim)),
                title: Text(block.description, style: const TextStyle(fontSize: 18)),
                subtitle: item.isStandard ? null : const Text('TZX', style: TextStyle(color: ZxColors.yellow)),
                trailing: Row(mainAxisSize: MainAxisSize.min, children: [
                  if (block.checksumOk == false)
                    Tooltip(message: t.tapeChecksumBad, child: const Icon(Icons.error_outline_rounded, color: ZxColors.red)),
                  IconButton(icon: const Icon(Icons.more_vert_rounded), onPressed: () => _itemMenu(i)),
                ]),
                onTap: () => _itemMenu(i),
              );
            },
          );
    if (_desktop) {
      list = DropTarget(
        onDragEntered: (_) => setState(() => _dragging = true),
        onDragExited: (_) => setState(() => _dragging = false),
        onDragDone: (d) async {
          setState(() => _dragging = false);
          for (final f in d.files) {
            await _addFile(f.name, await File(f.path).readAsBytes());
          }
        },
        child: Stack(fit: StackFit.expand, children: [
          list,
          if (_dragging)
            IgnorePointer(
              child: Container(
                decoration: BoxDecoration(border: Border.all(color: ZxColors.cyan, width: 4)),
                alignment: Alignment.center,
                child: Text(t.tapeDropHint, style: const TextStyle(fontSize: 22, color: ZxColors.cyan)),
              ),
            ),
        ]),
      );
    }
    return PopScope(
      canPop: !_dirty,
      onPopInvokedWithResult: (didPop, _) async {
        if (didPop) return;
        if (await _confirmLeave() && context.mounted) {
          _dirty = false;
          Navigator.pop(context);
        }
      },
      child: Scaffold(
        backgroundColor: ZxColors.body,
        appBar: AppBar(
          backgroundColor: ZxColors.body,
          title: Text('${t.tapeEditor} — $title', overflow: TextOverflow.ellipsis),
          actions: [
            if (!_desktop)
              IconButton(
                  tooltip: t.tapeAddToLibrary,
                  iconSize: 30,
                  icon: const Icon(Icons.library_add_rounded),
                  onPressed: _items.isEmpty ? null : _addToLibrary),
            IconButton(tooltip: t.tapeSave, iconSize: 30, icon: const Icon(Icons.save_rounded), onPressed: _save),
          ],
        ),
        floatingActionButton: FloatingActionButton.extended(
          onPressed: _add,
          icon: const Icon(Icons.add_rounded, size: 30),
          label: Text(t.tapeAddBlock, style: const TextStyle(fontSize: 18)),
        ),
        body: list,
      ),
    );
  }
}
