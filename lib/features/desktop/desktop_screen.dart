import 'dart:io';
import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:archive/archive.dart';
import 'package:desktop_drop/desktop_drop.dart';
import 'package:file_picker/file_picker.dart';
import 'package:flutter/gestures.dart' show kMiddleMouseButton, kPrimaryButton, kSecondaryButton;
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
import '../../core/storage/game_library.dart';
import '../../core/tape/tape_controller.dart';
import '../../core/tape/tape_file.dart';
import '../../core/theme/easy_theme.dart';
import '../../core/video_mode.dart';
import '../about/about_screen.dart';
import '../game/game_display.dart';
import '../game/zx_keyboard.dart';
import '../tape/tape_editor.dart';
import '../tape/tape_manager.dart';
import 'desktop_app.dart';
import 'mouse_capture.dart';
import 'native_menu.dart';
import 'pc_keyboard.dart';
import 'toolbar.dart';

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
  static const _prefMouse = 'desktop_mouse';
  final _capture = MouseCapture();
  MouseType _mouse = MouseType.none;
  bool _mouseCaptured = false;
  static const _maxRecent = 10;
  static const _speeds = [0.5, 1.0, 2.0, 4.0];

  /// Archivos abiertos con el emulador ya en marcha (doble clic en el Explorador, PRISMA…):
  /// el runner de Windows los recibe de la nueva instancia y los manda aquí.
  static const _openArgs = MethodChannel('cl.easysoft.easyspectrum/open_args');

  final _zx = ZxBridge.instance;
  final _audio = ZxAudio();
  late final _tape = TapeController(_zx);
  bool _showTape = false; // panel del gestor de cintas
  double _tapeExtra = 0; // ancho que creció la ventana para el panel
  bool _audioMuted = false;
  late final _keyboard = PcKeyboard(_zx);
  late final Ticker _ticker;
  final _focus = FocusNode(debugLabel: 'spectrum');
  late final _menu = NativeMenuBar(onMenuLoop: (open) {
    if (open) _keyboard.releaseAll();
  });

  AppSettings _settings = AppSettings();
  List<String> _recent = [];
  String _media = ''; // archivo cargado (el .zip si vino en uno); vacío = BASIC
  ui.Image? _frame;
  bool _frameBusy = false;
  bool _paused = false;
  bool _turbo = false;
  bool _fullscreen = false;
  bool _dragging = false;
  bool _showKeyboard = false; // teclado del Spectrum en pantalla, para el ratón
  double _kbExtra = 0; // alto que la ventana creció para el teclado (0 = no se alargó)
  bool _kbFits = false; // la ventana creció lo suficiente: el teclado va a todo el ancho
  double _speed = 1;
  Duration _lastTick = Duration.zero;

  @override
  void initState() {
    super.initState();
    windowManager.addListener(this);
    _openArgs.setMethodCallHandler(_onOpenArgs);
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
    _mouse = MouseType.byName(p.getString(_prefMouse));
    _zx.mouseMode = _mouse.index;
    _audioMuted = !_settings.soundOn;
    _audio.setMuted(_audioMuted);
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

  Future<void> _onOpenArgs(MethodCall call) async {
    if (call.method != 'open' || !_zx.isRunning) return;
    final (file, model) = DesktopApp.parseArgs((call.arguments as List).cast<String>());
    if (model != null) _settings.model = model;
    if (file != null) {
      await _openPath(file);
    } else if (model != null) {
      await _reload();
    }
  }

  @override
  void dispose() {
    _openArgs.setMethodCallHandler(null);
    windowManager.removeListener(this);
    _capture.stop();
    _ticker.dispose();
    _tape.dispose();
    _audio.stop();
    _zx.dispose();
    _frame?.dispose();
    _focus.dispose();
    super.dispose();
  }

  @override
  void onWindowBlur() {
    _keyboard.releaseAll();
    _releaseMouse();
  }

  // --- Ratón (Kempston / AMX) ------------------------------------------------

  void _grabMouse() {
    _capture.pixelsPerStep = _pixelsPerStep();
    if (_capture.start(_zx.mouseMove)) setState(() => _mouseCaptured = true);
  }

  void _releaseMouse() {
    if (!_capture.active) return;
    _capture.stop();
    _zx.mouseButtons(0);
    if (mounted) setState(() => _mouseCaptured = false);
  }

  /// Píxeles de pantalla (físicos) por píxel del Spectrum visible, para la sensibilidad.
  double _pixelsPerStep() {
    final size = MediaQuery.sizeOf(context);
    final dpr = MediaQuery.devicePixelRatioOf(context);
    final visibleW = zxFbWidth - 2 * _settings.screenBorder.crop;
    final h = size.height * dpr, visibleH = zxFbHeight - 2 * _settings.screenBorder.crop;
    final byWidth = size.width * dpr / visibleW, byHeight = h / visibleH;
    return (byWidth < byHeight ? byWidth : byHeight).clamp(1.0, 12.0);
  }

  Future<void> _setMouse(MouseType m) async {
    _releaseMouse();
    setState(() => _mouse = m);
    _zx.mouseMode = m.index;
    final p = await SharedPreferences.getInstance();
    await p.setString(_prefMouse, m.name);
  }

  void _mousePointer(PointerEvent e) {
    if (_mouse == MouseType.none) return;
    if (!_capture.active) {
      if (e is PointerDownEvent && e.buttons == kPrimaryButton) _grabMouse();
      return;
    }
    var mask = 0;
    if (e.buttons & kPrimaryButton != 0) mask |= 1;
    if (e.buttons & kSecondaryButton != 0) mask |= 2;
    if (e.buttons & kMiddleMouseButton != 0) mask |= 4;
    _zx.mouseButtons(mask);
  }

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
    _zx.setGigascreen(_settings.gigascreen);
    await _tape.attach(path);
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
    _tape.poll();
    _applyMute();
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
      if (_ext(entry.name) == 'nex') {
        await GameLibrary.extractAssets(archive, entry, Directory(GameLibrary.assetsDirFor(out.path)));
      }
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

  Future<void> _setGigascreen(bool v) async {
    setState(() => _settings.gigascreen = v);
    _zx.setGigascreen(v);
    await _settings.save();
  }

  Future<void> _toggleMute() async {
    setState(() => _settings.soundOn = !_settings.soundOn);
    _applyMute();
    await _settings.save();
  }

  /// Sin sonido si está apagado, o mientras gira la cinta con "Silenciar la carga".
  void _applyMute() {
    final muted = !_settings.soundOn || (_settings.muteTape && _tape.info.isPlaying);
    if (muted == _audioMuted) return;
    _audioMuted = muted;
    _audio.setMuted(muted);
  }

  Future<void> _setMuteTape(bool v) async {
    setState(() => _settings.muteTape = v);
    _applyMute();
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
    // Con el teclado abierto y la ventana alargada, el teclado conserva su sitio.
    final c = _settings.screenBorder.crop;
    final bar = _fullscreen ? 0.0 : DesktopToolbar.height;
    final imgW = (zxFbWidth - 2 * c) * n.toDouble(), imgH = (zxFbHeight - 2 * c) * n.toDouble();
    if (_kbFits) _kbExtra = _kbHeight(imgW);
    final panel = _showTape ? TapeManagerPanel.width : 0.0;
    final want = Size(imgW + panel, imgH + bar + _kbExtra);
    await windowManager.setSize(Size(
      want.width + outer.width - content.width,
      want.height + outer.height - content.height,
    ));
    // El marco no es fijo: la barra de menús nativa pasa a dos líneas en una ventana
    // estrecha (y vuelve a una al ensancharla). Se mide de nuevo y se corrige lo que falte.
    for (var pass = 0; pass < 2; pass++) {
      await Future<void>.delayed(const Duration(milliseconds: 120));
      if (!mounted) return;
      final now = MediaQuery.sizeOf(context);
      final dw = want.width - now.width, dh = want.height - now.height;
      if (dw.abs() < 1 && dh.abs() < 1) break;
      final o = await windowManager.getSize();
      await windowManager.setSize(Size(o.width + dw, o.height + dh));
    }
  }

  /// Zoom actual de la imagen (1 = 100 %), o null si no es uno entero (ventana a mano).
  int? _currentZoom() {
    if (_fullscreen) return null;
    final content = MediaQuery.sizeOf(context);
    final c = _settings.screenBorder.crop;
    final w = content.width - (_showTape ? TapeManagerPanel.width : 0);
    final h = content.height - DesktopToolbar.height - (_showKeyboard ? _kbExtra : 0);
    final scale = math.min(w / (zxFbWidth - 2 * c), h / (zxFbHeight - 2 * c));
    final n = scale.round();
    return n >= 1 && (scale - n).abs() < 0.02 ? n : null;
  }

  // --- Teclado ---------------------------------------------------------------

  KeyEventResult _onKey(FocusNode node, KeyEvent e) {
    // Alt+Enter: pantalla completa (Alt solo es el fuego del joystick; se suelta antes).
    if (e.logicalKey == LogicalKeyboardKey.enter || e.logicalKey == LogicalKeyboardKey.numpadEnter) {
      if (HardwareKeyboard.instance.isAltPressed) {
        if (e is KeyDownEvent) {
          _keyboard.releaseAll();
          _setFullscreen(!_fullscreen);
        }
        return KeyEventResult.handled;
      }
    }
    if (e is KeyDownEvent) {
      final action = switch (e.logicalKey) {
        LogicalKeyboardKey.f2 => _reload,
        LogicalKeyboardKey.f3 => _pickFile,
        LogicalKeyboardKey.f4 => () async => _tape.rewind(),
        LogicalKeyboardKey.f5 => () async => _zx.reset(),
        LogicalKeyboardKey.f6 => () async => _toggleTape(),
        LogicalKeyboardKey.f7 => _toggleTapePanel,
        LogicalKeyboardKey.f8 || LogicalKeyboardKey.pause => () async => _setPaused(!_paused),
        LogicalKeyboardKey.f11 => () => _setFullscreen(!_fullscreen),
        LogicalKeyboardKey.f9 when _capture.active => () async => _releaseMouse(),
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

  /// Barra de menús nativa de Windows. Se describe entera en cada build; [NativeMenuBar]
  /// solo la reenvía si cambió.
  List<MenuEntry> _menus(AppLocalizations t) {
    final hasMedia = _media.isNotEmpty;
    // "&" marca la letra de Alt: en nombres de archivo se escapa.
    String esc(String s) => s.replaceAll('&', '&&');
    return [
      MenuEntry.submenu('&${t.menuFile}', [
        MenuEntry(t.openFile, shortcut: 'F3', onSelected: _pickFile),
        MenuEntry(t.reloadFile, shortcut: 'F2', onSelected: hasMedia ? _reload : null),
        MenuEntry.submenu(t.recentFiles, [
          for (final path in _recent) MenuEntry(esc(_baseName(path)), onSelected: () => _openPath(path)),
          if (_recent.isEmpty) MenuEntry(t.noRecentFiles),
        ]),
        const MenuEntry.separator(),
        MenuEntry(t.powerOnBasic, onSelected: () => _start('')),
        const MenuEntry.separator(),
        MenuEntry('${t.setDefaultApp}…', onSelected: () => _openArgs.invokeMethod('openDefaultApps')),
        MenuEntry(t.exit, shortcut: 'Alt+F4', onSelected: windowManager.close),
      ]),
      MenuEntry.submenu('&${t.machine}', [
        MenuEntry.submenu(t.model, [
          for (final m in ZxModel.values)
            MenuEntry(m.label,
                radio: true, checked: m == _settings.model, onSelected: () => _setModel(m)),
        ]),
        MenuEntry(t.reset, shortcut: 'F5', onSelected: _zx.reset),
        MenuEntry(t.pause, shortcut: 'F8', checked: _paused, onSelected: () => _setPaused(!_paused)),
        MenuEntry(t.sound, checked: _settings.soundOn, onSelected: _toggleMute),
        MenuEntry.submenu(t.speed, [
          for (final s in _speeds)
            MenuEntry('${(s * 100).round()} %',
                radio: true, checked: s == _speed, onSelected: () => _setSpeed(s)),
        ]),
        const MenuEntry.separator(),
        MenuEntry(t.quickLoad,
            checked: _settings.quickLoad, onSelected: () => _setQuickLoad(!_settings.quickLoad)),
        MenuEntry(_zx.tapePlaying ? t.stopTape : t.playTape,
            shortcut: 'F6', onSelected: hasMedia || _tape.hasTape ? _toggleTape : null),
        MenuEntry(t.tapeRewind, shortcut: 'F4', onSelected: _tape.hasList ? _tape.rewind : null),
        MenuEntry(t.tapeInsert, onSelected: _insertTape),
        MenuEntry(t.tapeEject, onSelected: _tape.hasTape ? _tape.eject : null),
        MenuEntry('${t.tapeManager}…', shortcut: 'F7', checked: _showTape, onSelected: _toggleTapePanel),
        MenuEntry('${t.tapeNew}…', onSelected: () => _openEditor(null)),
      ]),
      MenuEntry.submenu('&${t.screen}', [
        for (final m in VideoMode.values)
          MenuEntry(m.label(t),
              radio: true, checked: m == _settings.videoMode, onSelected: () => _setVideo(m)),
        const MenuEntry.separator(),
        MenuEntry('Gigascreen',
            checked: _settings.gigascreen, onSelected: () => _setGigascreen(!_settings.gigascreen)),
        const MenuEntry.separator(),
        MenuEntry.submenu(t.zoom, [
          for (final n in [1, 2, 3])
            MenuEntry('${n * 100} %', radio: true, checked: _currentZoom() == n, onSelected: () => _setScale(n)),
        ]),
        MenuEntry(t.fullscreen, shortcut: 'F11 / Alt+Enter', checked: _fullscreen, onSelected: () => _setFullscreen(true)),
      ]),
      MenuEntry.submenu('&${t.joystick}', [
        MenuEntry(t.arrowsAsCursors,
            radio: true, checked: _keyboard.joystick == null, onSelected: () => _setJoystick(null)),
        for (final j in JoyMapping.values)
          MenuEntry(j.label,
              radio: true, checked: _keyboard.joystick == j, onSelected: () => _setJoystick(j)),
        const MenuEntry.separator(),
        MenuEntry.submenu(t.mouse, [
          for (final m in MouseType.selectable)
            MenuEntry(m == MouseType.none ? t.mouseNone : m.label,
                radio: true, checked: _mouse == m, onSelected: () => _setMouse(m)),
        ]),
        const MenuEntry.separator(),
        MenuEntry('${t.keyMap}…', onSelected: _showKeyMap),
      ]),
      MenuEntry.submenu('&${t.menuHelp}', [
        MenuEntry('${t.keyMap}…', onSelected: _showKeyMap),
        MenuEntry(t.about, onSelected: _showAbout),
      ]),
    ];
  }

  void _toggleTape() {
    if (_tape.hasTape) {
      _tape.togglePlay();
    } else {
      _zx.tapePlaying = !_zx.tapePlaying;
    }
    setState(() {});
  }

  // --- Gestor de cintas (doc/TAPE_MANAGER.md) --------------------------------

  /// Abre o cierra el panel. La ventana se ensancha lo que mide (como con el teclado), así
  /// el juego no se reduce; maximizada o en pantalla completa, el juego cede el sitio.
  Future<void> _toggleTapePanel() async {
    final open = !_showTape;
    final canResize = !_fullscreen && !await windowManager.isMaximized();
    if (!mounted) return;
    if (open) {
      var grown = 0.0;
      if (canResize) {
        final view = View.of(context);
        final screenW = view.display.size.width / view.devicePixelRatio;
        final outer = await windowManager.getSize();
        final pos = await windowManager.getPosition();
        final newW = math.min(outer.width + TapeManagerPanel.width, screenW);
        grown = math.max(0.0, newW - outer.width);
        if (grown > 0) {
          await windowManager.setSize(Size(newW, outer.height));
          final x = math.max(0.0, math.min(pos.dx, screenW - newW));
          if (x != pos.dx) await windowManager.setPosition(Offset(x, pos.dy));
        }
        if (!mounted) return;
      }
      setState(() {
        _showTape = true;
        _tapeExtra = grown;
      });
    } else {
      final extra = _tapeExtra;
      setState(() {
        _showTape = false;
        _tapeExtra = 0;
      });
      if (extra > 0 && canResize) {
        final outer = await windowManager.getSize();
        await windowManager.setSize(Size(math.max(320, outer.width - extra), outer.height));
      }
    }
    _focus.requestFocus();
  }

  static bool _samePath(String? a, String? b) =>
      a != null && b != null && File(a).absolute.path.toLowerCase() == File(b).absolute.path.toLowerCase();

  /// Cambia de cinta sin reiniciar la máquina (multicargas, cintas de datos…).
  Future<void> _insertTape() async {
    final r = await FilePicker.platform.pickFiles(
      type: FileType.custom,
      allowedExtensions: ['tap', 'tzx', 'csw'],
    );
    final path = r?.files.singleOrNull?.path;
    if (path == null || !mounted) return;
    if (!await _tape.insert(path) && mounted) {
      _showError(context.l10n.loadFailed(context.l10n.errOpenFailed));
    }
    _focus.requestFocus();
  }

  /// ● alterna la grabación de los SAVE en un .tap aparte (no la cinta insertada: el core
  /// la tiene abierta).
  Future<void> _toggleRecord() async {
    final t = context.l10n;
    if (_tape.recording) {
      final blocks = _tape.recordedBlocks;
      final recorded = await _tape.stopRecording();
      if (!mounted || recorded == null) return;
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(
        content: Text(t.tapeRecorded(blocks)),
        action: SnackBarAction(label: t.tapeInsertRecorded, onPressed: () => _tape.insert(recorded)),
      ));
      _focus.requestFocus();
      return;
    }
    final target = await FilePicker.platform.saveFile(
      dialogTitle: t.tapeRecordTo,
      fileName: 'save.tap',
      type: FileType.custom,
      allowedExtensions: ['tap'],
    );
    if (target == null || !mounted) return;
    final out = target.toLowerCase().endsWith('.tap') ? target : '$target.tap';
    if (_samePath(out, _tape.path)) {
      _showError(t.tapeRecordSameFile);
      return;
    }
    _tape.startRecording(out);
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(t.tapeRecordHint)));
    _focus.requestFocus();
  }

  Future<void> _openEditor(String? path) async {
    _keyboard.releaseAll();
    await Navigator.push(
      context,
      MaterialPageRoute(builder: (_) => TapeEditorScreen(path: path, beforeOverwrite: _beforeOverwrite)),
    );
    await _tape.reload();
    _focus.requestFocus();
  }

  /// El editor va a escribir [path]: si es la cinta insertada, se expulsa (Windows no deja
  /// reemplazar un archivo abierto) y se reinserta después en el mismo bloque.
  Future<Future<void> Function()?> _beforeOverwrite(String path) async {
    if (!_samePath(path, _tape.path)) return null;
    final block = _tape.info.block;
    _tape.eject();
    return () async {
      if (await _tape.insert(path)) _tape.seekBlock(math.min(block, _tape.total));
    };
  }

  /// .tzx con solo bloques estándar → .tap (junto al original).
  Future<void> _convertToTap() async {
    final t = context.l10n;
    final tap = _tape.tape?.toTap();
    if (tap == null || _tape.path == null) {
      _showError(t.tapeNotConvertible);
      return;
    }
    final src = _tape.path!;
    final name = _baseName(src);
    final dot = name.lastIndexOf('.');
    final target = await FilePicker.platform.saveFile(
      dialogTitle: t.tapeConvertTap,
      fileName: '${dot > 0 ? name.substring(0, dot) : name}.tap',
      initialDirectory: File(src).parent.path,
      type: FileType.custom,
      allowedExtensions: ['tap'],
    );
    if (target == null || !mounted) return;
    final out = target.toLowerCase().endsWith('.tap') ? target : '$target.tap';
    await writeFileAtomic(out, tap);
    if (mounted) ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(t.tapeSaved(_baseName(out)))));
    _focus.requestFocus();
  }

  @override
  Widget build(BuildContext context) {
    final t = context.l10n;
    _menu
      ..set(_menus(t))
      ..setVisible(!_fullscreen);
    return Scaffold(
      backgroundColor: Colors.black,
      body: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          if (!_fullscreen)
            DesktopToolbar(items: [
              ToolItem('nuevo', t.powerOnBasic, onTap: () => _start('')),
              ToolItem('abrir', t.openFile, onTap: _pickFile),
              ToolItem('guardar', '${t.toolbarSave} (${t.comingSoon})'),
              null,
              ToolItem('tape', '${t.tapeManager} (F7)', active: _showTape, onTap: _toggleTapePanel),
              null,
              ToolItem('recargar', t.reset, onTap: () {
                _zx.reset();
                _focus.requestFocus();
              }),
              ToolItem(_paused ? 'play' : 'pause', t.pause, active: _paused, onTap: () {
                _setPaused(!_paused);
                _focus.requestFocus();
              }),
              ToolItem(_settings.soundOn ? 'volume' : 'mute', t.sound, active: !_settings.soundOn, onTap: () {
                _toggleMute();
                _focus.requestFocus();
              }),
              ToolItem('keyboard', t.showKeyboard, active: _showKeyboard, onTap: _toggleKeyboard),
            ]),
          Expanded(
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
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
                child: Column(
                  children: [
                    Expanded(
                      child: Stack(
                  fit: StackFit.expand,
                  children: [
                    Listener(
                  onPointerDown: _mousePointer,
                  onPointerUp: _mousePointer,
                  child: GestureDetector(
                  onTap: _focus.requestFocus,
                  onDoubleTap: _mouse == MouseType.none ? () => _setFullscreen(!_fullscreen) : null,
                  child: Stack(
                    fit: StackFit.expand,
                    children: [
                      GameDisplay(
                          frame: _frame,
                          turbo: _turbo,
                          mode: _settings.videoMode,
                          border: _settings.screenBorder),
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
                      if (_mouseCaptured)
                        Positioned(
                          left: 0,
                          right: 0,
                          bottom: 14,
                          child: Center(
                            child: Container(
                              padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 6),
                              decoration: BoxDecoration(
                                color: Colors.black.withValues(alpha: 0.65),
                                borderRadius: BorderRadius.circular(8),
                              ),
                              child: Text(t.mouseRelease,
                                  style: const TextStyle(fontSize: 16, color: ZxColors.cyan)),
                            ),
                          ),
                        ),
                    ],
                  ),
                ),
                ),
                  ],
                ),
                    ),
                    // Teclado bajo la imagen: el juego se reduce para dejarle sitio.
                    if (_showKeyboard)
                      LayoutBuilder(builder: (context, box) {
                        // Ventana alargada: el teclado va a todo el ancho; si no, se acota al alto.
                        final kbW = _kbFits
                            ? box.maxWidth
                            : math.min(box.maxWidth, MediaQuery.sizeOf(context).height * 0.42 * 1536 / 899);
                        return ColoredBox(
                          color: Colors.black,
                          child: Padding(
                            padding: const EdgeInsets.symmetric(vertical: 6),
                            child: Center(
                              child: SizedBox(
                                width: kbW,
                                height: kbW * 899 / 1536,
                                child: ZxKeyboard(
                                  haptics: false,
                                  onKey: (code, pressed) => _zx.setKey(code, pressed),
                                ),
                              ),
                            ),
                          ),
                        );
                      }),
                  ],
                ),
              ),
            ),
            ),
                if (_showTape)
                  TapeManagerPanel(
                    controller: _tape,
                    quickLoad: _settings.quickLoad,
                    muteTape: _settings.muteTape,
                    onQuickLoad: _setQuickLoad,
                    onMuteTape: _setMuteTape,
                    onInsert: _insertTape,
                    onRecord: _toggleRecord,
                    onNewTape: () => _openEditor(null),
                    onEditTape: _tape.hasList ? () => _openEditor(_tape.path) : null,
                    onConvertToTap: _convertToTap,
                    onClose: _toggleTapePanel,
                    afterAction: _focus.requestFocus,
                  ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  /// Alto del panel del teclado para un ancho dado (imagen 1536×899 + aire).
  double _kbHeight(double width) => width * 899 / 1536 + 12;

  /// Muestra u oculta el teclado bajo la imagen. La ventana se alarga lo que mide el
  /// teclado (y vuelve a su alto al cerrarlo), así el juego no se reduce; en pantalla
  /// completa o maximizada no hay dónde crecer y el juego cede el espacio.
  Future<void> _toggleKeyboard() async {
    final open = !_showKeyboard;
    _keyboard.releaseAll();
    _zx.clearKeys();
    final canResize = !_fullscreen && !await windowManager.isMaximized();
    if (!mounted) return;
    if (open) {
      final want = canResize ? _kbHeight(MediaQuery.sizeOf(context).width) : 0.0;
      var grown = 0.0;
      if (want > 0) {
        // La ventana crece hasta donde cabe en la pantalla (sube si hace falta); lo que
        // no quepa lo cede la imagen del juego.
        final view = View.of(context);
        final screenH = view.display.size.height / view.devicePixelRatio - 70; // barra de tareas
        final outer = await windowManager.getSize();
        final pos = await windowManager.getPosition();
        final newH = math.min(outer.height + want, screenH);
        grown = math.max(0.0, newH - outer.height);
        if (grown > 0) {
          await windowManager.setSize(Size(outer.width, newH));
          final y = math.max(0.0, math.min(pos.dy, screenH - newH));
          if (y != pos.dy) await windowManager.setPosition(Offset(pos.dx, y));
        }
        if (!mounted) return;
      }
      setState(() {
        _showKeyboard = true;
        _kbExtra = grown;
        _kbFits = want > 0 && grown >= want - 1;
      });
    } else {
      final extra = _kbExtra;
      setState(() {
        _showKeyboard = false;
        _kbExtra = 0;
        _kbFits = false;
      });
      if (extra > 0 && canResize) {
        final outer = await windowManager.getSize();
        await windowManager.setSize(Size(outer.width, math.max(240, outer.height - extra)));
      }
    }
    _focus.requestFocus();
  }
}
