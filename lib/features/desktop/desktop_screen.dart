import 'dart:io';
import 'dart:ui' as ui;

import 'package:archive/archive.dart';
import 'package:desktop_drop/desktop_drop.dart';
import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter/scheduler.dart';
import 'package:flutter/services.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:window_manager/window_manager.dart';

import '../../core/emulator/zx_audio.dart';
import '../../core/emulator/zx_bridge.dart';
import '../../core/emulator/zx_types.dart';
import '../../core/l10n.dart';
import '../../core/settings.dart';
import '../../core/theme/easy_theme.dart';
import '../../core/video_mode.dart';
import '../about/about_screen.dart';
import '../game/game_display.dart';
import 'pc_keyboard.dart';

/// Ventana del emulador en escritorio: salida del Spectrum a toda la ventana, barra de
/// menús y teclado físico. Los archivos se abren en su sitio (sin biblioteca): así una
/// herramienta externa puede recompilar el .tap y basta con "Recargar" (F2).
class DesktopScreen extends StatefulWidget {
  final String? initialFile;
  final ZxModel? initialModel;
  const DesktopScreen({super.key, this.initialFile, this.initialModel});

  @override
  State<DesktopScreen> createState() => _DesktopScreenState();
}

class _DesktopScreenState extends State<DesktopScreen>
    with SingleTickerProviderStateMixin, WindowListener {
  static const _prefJoystick = 'desktop_joystick';
  static const _prefRecent = 'desktop_recent';
  static const _maxRecent = 10;
  static const _speeds = [0.5, 1.0, 2.0, 4.0];

  final _zx = ZxBridge.instance;
  final _audio = ZxAudio();
  late final _keyboard = PcKeyboard(_zx);
  late final Ticker _ticker;
  final _focus = FocusNode(debugLabel: 'spectrum');
  final _menuKey = GlobalKey();

  AppSettings _settings = AppSettings();
  List<String> _recent = [];
  String _media = ''; // archivo cargado (el .zip si vino en uno); vacío = BASIC
  ui.Image? _frame;
  bool _frameBusy = false;
  bool _paused = false;
  bool _turbo = false;
  bool _fullscreen = false;
  bool _dragging = false;
  double _speed = 1;
  Duration _lastTick = Duration.zero;

  @override
  void initState() {
    super.initState();
    windowManager.addListener(this);
    _ticker = createTicker(_onTick);
    _boot();
  }

  Future<void> _boot() async {
    _settings = await AppSettings.load();
    if (widget.initialModel != null) _settings.model = widget.initialModel!;
    final p = await SharedPreferences.getInstance();
    final joy = p.getString(_prefJoystick);
    _keyboard.joystick = joy == 'none' ? null : JoyMapping.byName(joy) ?? JoyMapping.kempston;
    _recent = p.getStringList(_prefRecent) ?? [];
    await _audio.start();
    if (!mounted) return;
    final file = widget.initialFile;
    if (file != null) {
      await _openPath(file);
    } else {
      await _start('');
    }
    _ticker.start();
  }

  @override
  void dispose() {
    windowManager.removeListener(this);
    _ticker.dispose();
    _audio.stop();
    _zx.dispose();
    _frame?.dispose();
    _focus.dispose();
    super.dispose();
  }

  @override
  void onWindowBlur() => _keyboard.releaseAll();

  // --- Emulación -------------------------------------------------------------

  /// Arranca la máquina con [path] (ya descomprimido); [source] es lo que se muestra y
  /// se guarda en recientes. Si falla, avisa y queda en BASIC.
  Future<void> _start(String path, {String? source}) async {
    _keyboard.releaseAll();
    final err = await _zx.start(
      model: _settings.model,
      mediaPath: path,
      audioFreq: ZxAudio.sampleRate,
      quickLoad: _settings.quickLoad,
    );
    if (!mounted) return;
    if (err != null) {
      if (path.isNotEmpty) {
        await _start('');
        if (mounted) _showError(context.l10n.loadFailed(zxErrorText(context.l10n, err)));
      }
      return;
    }
    _zx.setSpeed(_speed);
    setState(() => _media = source ?? path);
    if (_media.isNotEmpty) await _addRecent(_media);
    await windowManager.setTitle(
        _media.isEmpty ? 'Easy Spectrum' : '${_baseName(_media)} — Easy Spectrum');
  }

  Future<void> _onTick(Duration now) async {
    if (_paused || !_zx.isRunning) {
      _lastTick = now;
      return;
    }
    var delta = (now - _lastTick).inMicroseconds / 1e6;
    _lastTick = now;
    if (delta <= 0 || delta > 0.5) {
      delta = 1 / 50;
    } else if (delta > 0.1) {
      delta = 0.1;
    }
    final frames = _zx.run(delta);
    _audio.feed(_zx);
    final turbo = _zx.turbo;
    if (turbo != _turbo) setState(() => _turbo = turbo);
    if (frames == 0 || _frameBusy) return;

    _frameBusy = true;
    try {
      final img = await _zx.frame();
      if (!mounted || img == null) {
        img?.dispose();
        return;
      }
      final old = _frame;
      setState(() => _frame = img);
      old?.dispose();
    } finally {
      _frameBusy = false;
    }
  }

  void _setPaused(bool p) {
    setState(() => _paused = p);
    _audio.setPaused(p);
    if (p) _keyboard.releaseAll();
  }

  // --- Archivos --------------------------------------------------------------

  static String _baseName(String path) => path.split(RegExp(r'[\\/]')).last;

  static String _ext(String path) {
    final name = _baseName(path);
    final dot = name.lastIndexOf('.');
    return dot < 0 ? '' : name.substring(dot + 1).toLowerCase();
  }

  Future<void> _pickFile() async {
    final r = await FilePicker.platform.pickFiles(
      type: FileType.custom,
      allowedExtensions: [...zxMediaExtensions, 'zip'],
    );
    final path = r?.files.singleOrNull?.path;
    if (path != null) await _openPath(path);
  }

  /// Abre un archivo del disco; un .zip se descomprime (el primer juego) a una carpeta temporal.
  Future<void> _openPath(String path) async {
    final t = context.l10n;
    if (!File(path).existsSync()) {
      _showError(t.loadFailed(t.errOpenFailed));
      setState(() => _recent.remove(path));
      await _saveRecent();
      if (!_zx.isRunning) await _start('');
      return;
    }
    var media = path;
    final ext = _ext(path);
    if (ext == 'zip') {
      final archive = ZipDecoder().decodeBytes(await File(path).readAsBytes());
      final entry = archive.files
          .where((f) => f.isFile && zxMediaExtensions.contains(_ext(f.name)))
          .firstOrNull;
      if (entry == null) {
        _showError(t.zipWithoutGame);
        if (!_zx.isRunning) await _start('');
        return;
      }
      final dir = Directory('${Directory.systemTemp.path}${Platform.pathSeparator}easy_spectrum');
      await dir.create(recursive: true);
      final out = File('${dir.path}${Platform.pathSeparator}${_baseName(entry.name)}');
      await out.writeAsBytes(entry.content, flush: true);
      media = out.path;
    } else if (!zxMediaExtensions.contains(ext)) {
      _showError(t.unsupportedFormat(ext));
      if (!_zx.isRunning) await _start('');
      return;
    }
    await _start(media, source: path);
  }

  Future<void> _reload() async {
    if (_media.isEmpty) {
      _zx.reset();
    } else {
      await _openPath(_media);
    }
  }

  Future<void> _addRecent(String path) async {
    _recent
      ..remove(path)
      ..insert(0, path);
    if (_recent.length > _maxRecent) _recent.removeRange(_maxRecent, _recent.length);
    await _saveRecent();
  }

  Future<void> _saveRecent() async {
    final p = await SharedPreferences.getInstance();
    await p.setStringList(_prefRecent, _recent);
  }

  void _showError(String message) {
    showDialog<void>(
      context: context,
      builder: (ctx) => AlertDialog(
        content: Text(message, style: const TextStyle(fontSize: 16)),
        actions: [TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('OK'))],
      ),
    ).then((_) => _focus.requestFocus());
  }

  // --- Ajustes ---------------------------------------------------------------

  Future<void> _setModel(ZxModel m) async {
    _settings.model = m;
    await _settings.save();
    await _reload();
  }

  Future<void> _setVideo(VideoMode m) async {
    setState(() => _settings.videoMode = m);
    await _settings.save();
  }

  Future<void> _setQuickLoad(bool v) async {
    setState(() => _settings.quickLoad = v);
    _zx.setQuickLoad(v);
    await _settings.save();
  }

  void _setSpeed(double s) {
    setState(() => _speed = s);
    _zx.setSpeed(s);
  }

  Future<void> _setJoystick(JoyMapping? j) async {
    _keyboard.releaseAll();
    setState(() => _keyboard.joystick = j);
    final p = await SharedPreferences.getInstance();
    await p.setString(_prefJoystick, j?.name ?? 'none');
  }

  Future<void> _setFullscreen(bool v) async {
    await windowManager.setFullScreen(v);
    setState(() => _fullscreen = v);
    _focus.requestFocus();
  }

  /// Ajusta la ventana para que la imagen (con borde) quede a escala ×[n].
  Future<void> _setScale(int n) async {
    if (_fullscreen) await _setFullscreen(false);
    if (!mounted) return;
    final content = MediaQuery.sizeOf(context);
    final outer = await windowManager.getSize();
    final menu = _menuKey.currentContext?.size?.height ?? 0;
    await windowManager.setSize(Size(
      zxFbWidth * n + outer.width - content.width,
      zxFbHeight * n + menu + outer.height - content.height,
    ));
  }

  // --- Teclado ---------------------------------------------------------------

  KeyEventResult _onKey(FocusNode node, KeyEvent e) {
    if (e is KeyDownEvent) {
      final action = switch (e.logicalKey) {
        LogicalKeyboardKey.f2 => _reload,
        LogicalKeyboardKey.f3 => _pickFile,
        LogicalKeyboardKey.f5 => () async => _zx.reset(),
        LogicalKeyboardKey.f6 => () async => setState(() => _zx.tapePlaying = !_zx.tapePlaying),
        LogicalKeyboardKey.f8 || LogicalKeyboardKey.pause => () async => _setPaused(!_paused),
        LogicalKeyboardKey.f11 => () => _setFullscreen(!_fullscreen),
        LogicalKeyboardKey.escape when _fullscreen => () => _setFullscreen(false),
        _ => null,
      };
      if (action != null) {
        action();
        return KeyEventResult.handled;
      }
    }
    return _keyboard.handle(e) ? KeyEventResult.handled : KeyEventResult.ignored;
  }

  // --- UI --------------------------------------------------------------------

  void _showKeyMap() {
    final t = context.l10n;
    showDialog<void>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(t.keyMap),
        content: Text(t.keyMapText, style: const TextStyle(fontSize: 16, height: 1.5)),
        actions: [TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('OK'))],
      ),
    ).then((_) => _focus.requestFocus());
  }

  Future<void> _showAbout() async {
    await Navigator.push(context, MaterialPageRoute(builder: (_) => const AboutScreen()));
    _focus.requestFocus();
  }

  Widget _menuBar(AppLocalizations t) {
    final hasMedia = _media.isNotEmpty;
    void refocus() => _focus.requestFocus();
    return MenuBar(
      key: _menuKey,
      style: const MenuStyle(
        backgroundColor: WidgetStatePropertyAll(ZxColors.body),
        elevation: WidgetStatePropertyAll(0),
      ),
      children: [
        SubmenuButton(
          onClose: refocus,
          menuChildren: [
            MenuItemButton(
              shortcut: const SingleActivator(LogicalKeyboardKey.f3),
              onPressed: _pickFile,
              child: Text(t.openFile),
            ),
            MenuItemButton(
              shortcut: const SingleActivator(LogicalKeyboardKey.f2),
              onPressed: hasMedia ? _reload : null,
              child: Text(t.reloadFile),
            ),
            SubmenuButton(
              menuChildren: [
                for (final path in _recent)
                  MenuItemButton(onPressed: () => _openPath(path), child: Text(_baseName(path))),
                if (_recent.isEmpty) MenuItemButton(child: Text(t.noRecentFiles)),
              ],
              child: Text(t.recentFiles),
            ),
            const Divider(height: 1),
            MenuItemButton(onPressed: () => _start(''), child: Text(t.powerOnBasic)),
            const Divider(height: 1),
            MenuItemButton(onPressed: windowManager.close, child: Text(t.exit)),
          ],
          child: Text(t.menuFile),
        ),
        SubmenuButton(
          onClose: refocus,
          menuChildren: [
            SubmenuButton(
              menuChildren: [
                for (final m in ZxModel.values)
                  RadioMenuButton<ZxModel>(
                    value: m,
                    groupValue: _settings.model,
                    onChanged: (v) => _setModel(v!),
                    child: Text(m.label),
                  ),
              ],
              child: Text(t.model),
            ),
            MenuItemButton(
              shortcut: const SingleActivator(LogicalKeyboardKey.f5),
              onPressed: _zx.reset,
              child: Text(t.reset),
            ),
            CheckboxMenuButton(
              value: _paused,
              shortcut: const SingleActivator(LogicalKeyboardKey.f8),
              onChanged: (v) => _setPaused(v ?? false),
              child: Text(t.pause),
            ),
            SubmenuButton(
              menuChildren: [
                for (final s in _speeds)
                  RadioMenuButton<double>(
                    value: s,
                    groupValue: _speed,
                    onChanged: (v) => _setSpeed(v!),
                    child: Text('${(s * 100).round()} %'),
                  ),
              ],
              child: Text(t.speed),
            ),
            const Divider(height: 1),
            CheckboxMenuButton(
              value: _settings.quickLoad,
              onChanged: (v) => _setQuickLoad(v ?? true),
              child: Text(t.quickLoad),
            ),
            MenuItemButton(
              shortcut: const SingleActivator(LogicalKeyboardKey.f6),
              onPressed: hasMedia ? () => setState(() => _zx.tapePlaying = !_zx.tapePlaying) : null,
              child: Text(_zx.tapePlaying ? t.stopTape : t.playTape),
            ),
          ],
          child: Text(t.machine),
        ),
        SubmenuButton(
          onClose: refocus,
          menuChildren: [
            for (final m in VideoMode.values)
              RadioMenuButton<VideoMode>(
                value: m,
                groupValue: _settings.videoMode,
                onChanged: (v) => _setVideo(v!),
                child: Text(m.label(t)),
              ),
            const Divider(height: 1),
            SubmenuButton(
              menuChildren: [
                for (final n in [1, 2, 3, 4])
                  MenuItemButton(onPressed: () => _setScale(n), child: Text('×$n')),
              ],
              child: Text(t.windowSize),
            ),
            CheckboxMenuButton(
              value: _fullscreen,
              shortcut: const SingleActivator(LogicalKeyboardKey.f11),
              onChanged: (v) => _setFullscreen(v ?? false),
              child: Text(t.fullscreen),
            ),
          ],
          child: Text(t.screen),
        ),
        SubmenuButton(
          onClose: refocus,
          menuChildren: [
            RadioMenuButton<JoyMapping?>(
              value: null,
              groupValue: _keyboard.joystick,
              onChanged: (_) => _setJoystick(null),
              child: Text(t.arrowsAsCursors),
            ),
            for (final j in JoyMapping.values)
              RadioMenuButton<JoyMapping?>(
                value: j,
                groupValue: _keyboard.joystick,
                onChanged: (_) => _setJoystick(j),
                child: Text(j.label),
              ),
            const Divider(height: 1),
            MenuItemButton(onPressed: _showKeyMap, child: Text('${t.keyMap}…')),
          ],
          child: Text(t.joystick),
        ),
        SubmenuButton(
          onClose: refocus,
          menuChildren: [
            MenuItemButton(onPressed: _showKeyMap, child: Text('${t.keyMap}…')),
            MenuItemButton(onPressed: _showAbout, child: Text(t.about)),
          ],
          child: Text(t.menuHelp),
        ),
      ],
    );
  }

  @override
  Widget build(BuildContext context) {
    final t = context.l10n;
    return Scaffold(
      backgroundColor: Colors.black,
      body: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          if (!_fullscreen) _menuBar(t),
          Expanded(
            child: DropTarget(
              onDragEntered: (_) => setState(() => _dragging = true),
              onDragExited: (_) => setState(() => _dragging = false),
              onDragDone: (d) {
                setState(() => _dragging = false);
                final f = d.files.firstOrNull;
                if (f != null) _openPath(f.path);
              },
              child: Focus(
                focusNode: _focus,
                autofocus: true,
                onKeyEvent: _onKey,
                child: GestureDetector(
                  onTap: _focus.requestFocus,
                  onDoubleTap: () => _setFullscreen(!_fullscreen),
                  child: Stack(
                    fit: StackFit.expand,
                    children: [
                      GameDisplay(frame: _frame, turbo: _turbo, mode: _settings.videoMode),
                      if (_paused)
                        const ColoredBox(
                          color: Colors.black54,
                          child: Center(
                            child: Icon(Icons.pause_circle_filled_rounded,
                                size: 96, color: Colors.white70),
                          ),
                        ),
                      if (_dragging)
                        Container(
                          decoration: BoxDecoration(
                            color: Colors.black54,
                            border: Border.all(color: ZxColors.cyan, width: 4),
                          ),
                          alignment: Alignment.center,
                          child: Text(t.dropHint,
                              style: const TextStyle(fontSize: 24, color: ZxColors.cyan)),
                        ),
                    ],
                  ),
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }
}
