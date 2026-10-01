import 'dart:io';
import 'dart:math' as math;
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
import '../../core/storage/game_library.dart';
import '../../core/theme/easy_theme.dart';
import '../../core/video_mode.dart';
import '../about/about_screen.dart';
import '../game/game_display.dart';
import '../game/zx_keyboard.dart';
import 'desktop_app.dart';
import 'native_menu.dart';
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

  /// Archivos abiertos con el emulador ya en marcha (doble clic en el Explorador, PRISMA…):
  /// el runner de Windows los recibe de la nueva instancia y los manda aquí.
  static const _openArgs = MethodChannel('cl.easysoft.easyspectrum/open_args');

  final _zx = ZxBridge.instance;
  final _audio = ZxAudio();
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
    _zx.setGigascreen(_settings.gigascreen);
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
    final imgW = (zxFbWidth - 2 * c) * n.toDouble(), imgH = (zxFbHeight - 2 * c) * n.toDouble();
    if (_kbFits) _kbExtra = _kbHeight(imgW);
    await windowManager.setSize(Size(
      imgW + outer.width - content.width,
      imgH + _kbExtra + outer.height - content.height,
    ));
  }

  // --- Teclado ---------------------------------------------------------------

  KeyEventResult _onKey(FocusNode node, KeyEvent e) {
    if (e is KeyDownEvent) {
      final action = switch (e.logicalKey) {
        LogicalKeyboardKey.f2 => _reload,
        LogicalKeyboardKey.f3 => _pickFile,
        LogicalKeyboardKey.f5 => () async => _zx.reset(),
        LogicalKeyboardKey.f6 => () async => _toggleTape(),
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
        MenuEntry.submenu(t.speed, [
          for (final s in _speeds)
            MenuEntry('${(s * 100).round()} %',
                radio: true, checked: s == _speed, onSelected: () => _setSpeed(s)),
        ]),
        const MenuEntry.separator(),
        MenuEntry(t.quickLoad,
            checked: _settings.quickLoad, onSelected: () => _setQuickLoad(!_settings.quickLoad)),
        MenuEntry(_zx.tapePlaying ? t.stopTape : t.playTape,
            shortcut: 'F6', onSelected: hasMedia ? _toggleTape : null),
      ]),
      MenuEntry.submenu('&${t.screen}', [
        for (final m in VideoMode.values)
          MenuEntry(m.label(t),
              radio: true, checked: m == _settings.videoMode, onSelected: () => _setVideo(m)),
        const MenuEntry.separator(),
        MenuEntry('Gigascreen',
            checked: _settings.gigascreen, onSelected: () => _setGigascreen(!_settings.gigascreen)),
        const MenuEntry.separator(),
        MenuEntry.submenu(t.windowSize, [
          for (final n in [1, 2, 3, 4]) MenuEntry('×$n', onSelected: () => _setScale(n)),
        ]),
        MenuEntry(t.fullscreen, shortcut: 'F11', checked: _fullscreen, onSelected: () => _setFullscreen(true)),
      ]),
      MenuEntry.submenu('&${t.joystick}', [
        MenuEntry(t.arrowsAsCursors,
            radio: true, checked: _keyboard.joystick == null, onSelected: () => _setJoystick(null)),
        for (final j in JoyMapping.values)
          MenuEntry(j.label,
              radio: true, checked: _keyboard.joystick == j, onSelected: () => _setJoystick(j)),
        const MenuEntry.separator(),
        MenuEntry('${t.keyMap}…', onSelected: _showKeyMap),
      ]),
      MenuEntry.submenu('&${t.menuHelp}', [
        MenuEntry('${t.keyMap}…', onSelected: _showKeyMap),
        MenuEntry(t.about, onSelected: _showAbout),
      ]),
    ];
  }

  void _toggleTape() => setState(() => _zx.tapePlaying = !_zx.tapePlaying);

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
                    GestureDetector(
                  onTap: _focus.requestFocus,
                  onDoubleTap: () => _setFullscreen(!_fullscreen),
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
                    ],
                  ),
                ),
                    // Fuera del GestureDetector: clics aquí no cuentan como doble clic.
                    Positioned(
                      right: 10,
                      bottom: 10,
                      child: Tooltip(
                        message: t.showKeyboard,
                        child: GestureDetector(
                          onTap: _toggleKeyboard,
                          child: MouseRegion(
                            cursor: SystemMouseCursors.click,
                            child: Opacity(
                              opacity: _showKeyboard ? 0.95 : 0.55,
                              child: Container(
                                width: 40,
                                height: 40,
                                decoration: BoxDecoration(
                                  shape: BoxShape.circle,
                                  color: const Color(0xFF2C2F33),
                                  border: Border.all(
                                      color: _showKeyboard ? ZxColors.cyan : Colors.white70, width: 2),
                                ),
                                child: const Icon(Icons.keyboard_rounded, size: 24, color: Colors.white),
                              ),
                            ),
                          ),
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
