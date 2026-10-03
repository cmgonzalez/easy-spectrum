import 'dart:async';
import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter/scheduler.dart';
import 'package:flutter/services.dart';
import 'package:wakelock_plus/wakelock_plus.dart';

import '../../core/ads/ad_manager.dart';
import '../../core/l10n.dart';
import '../../core/emulator/zx_audio.dart';
import '../../core/emulator/zx_bridge.dart';
import '../../core/emulator/zx_types.dart';
import '../../core/pad_config.dart';
import '../../core/settings.dart';
import '../../core/video_mode.dart';
import '../../core/storage/game_info.dart';
import '../../core/storage/game_library.dart';
import '../../core/storage/game_thumbnail.dart';
import '../../core/tape/tape_controller.dart';
import '../../core/theme/easy_theme.dart';
import 'game_display.dart';
import 'console_parts.dart';
import 'console_view.dart';
import '../settings/settings_screen.dart';
import '../tape/tape_deck.dart';
import '../tape/tape_editor.dart';
import '../tape/tape_manager.dart';
import 'external_input.dart';
import 'joystick_pad.dart';
import 'mouse_pad.dart';
import 'zx_keyboard.dart';

class GameScreen extends StatefulWidget {
  /// Ruta del juego; vacía = arrancar en BASIC.
  final String mediaPath;
  const GameScreen({super.key, this.mediaPath = ''});

  // Para abrir un archivo recibido con un juego en marcha: la pantalla anterior
  // debe terminar su dispose (libera la máquina nativa) antes de crear otra.
  static Completer<void>? _alive;
  static bool get isOpen => _alive != null && !_alive!.isCompleted;
  static Future<void> whenClosed() => _alive?.future ?? Future.value();

  @override
  State<GameScreen> createState() => _GameScreenState();
}

class _GameScreenState extends State<GameScreen>
    with SingleTickerProviderStateMixin, WidgetsBindingObserver {
  final _zx = ZxBridge.instance;
  final _alive = Completer<void>();
  late final Ticker _ticker;
  AppSettings _settings = AppSettings();
  PadConfig _pad = PadConfig(type: JoyMapping.kempston);

  ui.Image? _frame;
  bool _frameBusy = false;
  bool _started = false;
  bool _paused = false;
  bool _autoPaused = false;
  bool _exiting = false;
  bool _showKeyboard = false;
  // Tercer modo del área de controles: la grabadora de cassette (gestor de cintas).
  bool _showTapeDeck = false;
  // El cassette se mostró solo al cargar una cinta: vuelve al mando al terminar la carga.
  bool _autoDeck = false;
  bool _deckTapeSeen = false;
  double _deckClock = 0;
  bool _audioMuted = false;
  late final _tape = TapeController(_zx);
  bool _turbo = false;
  String? _error;

  Duration _lastTick = Duration.zero;

  // Miniatura automática para juegos cuyo archivo no trae pantalla (cinta cifrada,
  // .dsk…): se captura en cuanto termina la primera carga.
  bool _wantCapture = false;
  bool _capturing = false;
  bool _tapeSeen = false;
  double _captureClock = 0; // s reales desde que paró la cinta (o desde el inicio)
  double _shotClock = 0;
  Uint8List? _loadingShot; // última pantalla con color vista durante la carga
  int _joyMask = 0; // lo que se aplicó al core (táctil + externo)
  int _touchJoy = 0;
  int _extJoy = 0;
  final _focus = FocusNode();
  late final _external = ExternalInput(
    zx: _zx,
    pad: () => _pad,
    cursorsInsteadOfJoystick: widget.mediaPath.isEmpty,
    onJoystick: (m) {
      _extJoy = m;
      _applyJoystick();
    },
  );

  final _audio = ZxAudio();

  String get _title =>
      widget.mediaPath.isEmpty
          ? 'ZX Spectrum'
          : GameInfoService.cached(widget.mediaPath)?.title ?? GameLibrary.titleOf(widget.mediaPath);

  @override
  void initState() {
    super.initState();
    GameScreen._alive = _alive;
    WidgetsBinding.instance.addObserver(this);
    SystemChrome.setEnabledSystemUIMode(SystemUiMode.immersiveSticky);
    _ticker = createTicker(_onTick);
    _boot();
  }

  Future<void> _boot() async {
    _settings = await _loadSettings();
    _pad = await PadConfig.load(widget.mediaPath, _settings.joyMapping);
    if (widget.mediaPath.isNotEmpty) {
      // La ficha de ZXDB (si ya está) da título real y datos para el LCD.
      GameInfoService.load(widget.mediaPath).then((_) {
        if (mounted) setState(() {});
      });
    }
    _showKeyboard = widget.mediaPath.isEmpty || _settings.startWithKeyboard;
    if (_settings.keepScreenOn) WakelockPlus.enable();

    _zx.mouseMode = _pad.mouse.index;
    final err = await _zx.start(
      model: _settings.model,
      mediaPath: widget.mediaPath,
      audioFreq: ZxAudio.sampleRate,
      quickLoad: _settings.quickLoad,
    );
    if (!mounted) return;
    if (err != null) {
      setState(() => _error = err);
      return;
    }
    if (widget.mediaPath.isNotEmpty) {
      _wantCapture = await GameThumbnail.needsCapture(widget.mediaPath);
    }
    _zx.setGigascreen(_settings.gigascreen);
    await _tape.attach(widget.mediaPath);
    // El cassette ya no se abre solo al cargar una cinta: el juego arranca en el mando
    // (el cassette sigue disponible con el botón de modo).
    _audioMuted = !_settings.soundOn;
    _audio.setMuted(_audioMuted);
    await _audio.start();
    if (!mounted) return;
    setState(() => _started = true);
    _ticker.start();
  }

  /// Modelo real en marcha (un snapshot puede cambiar el elegido); vacío para la Next.
  String _modelLabel() {
    if (!_started) return '';
    final i = _zx.modelIndex;
    return i >= 0 && i < ZxModel.values.length ? ZxModel.values[i].label : '';
  }

  Future<AppSettings> _loadSettings() => AppSettings.loadForGame(widget.mediaPath);

  Future<void> _onTick(Duration now) async {
    if (_exiting || _paused || !_zx.isRunning) {
      _lastTick = now;
      return;
    }
    var delta = (now - _lastTick).inMicroseconds / 1e6;
    _lastTick = now;
    // Primer tick o vuelta de pausa: no intentar recuperar el tiempo perdido.
    // Ticks lentos (teléfono cargado) sí se recuperan, hasta 100 ms por tick:
    // descartarlos dejaría el juego en cámara lenta.
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
    if (_wantCapture) _checkCapture(delta);
    if (_autoDeck) _checkDeckReturn(delta);
    if (frames == 0 || _frameBusy) return;

    _frameBusy = true;
    try {
      final img = await _zx.frame();
      if (!mounted || _exiting || img == null) {
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

  /// Carga terminada = la cinta giró y lleva [_afterTape] s parada (los cargadores
  /// multiparte paran el motor un momento entre bloques). Sin cinta (.dsk, o .tap
  /// cargado al instante por el trap) se espera [_noTape]. Si al terminar la
  /// pantalla es pobre (créditos en blanco y negro) se usa la pantalla de carga,
  /// guardada cada segundo mientras gira la cinta. Si sale lisa, se reintenta.
  static const _afterTape = 2.0, _noTape = 15.0;

  void _checkCapture(double delta) {
    if (_capturing) return;
    if (_zx.tapePlaying) {
      _tapeSeen = true;
      _captureClock = 0;
      _shotClock += delta;
      if (_shotClock >= 1) {
        _shotClock = 0;
        final fb = _zx.framebuffer();
        if (fb != null && GameThumbnail.paperColours(fb) >= 3) _loadingShot = fb;
      }
      return;
    }
    _captureClock += delta;
    if (_captureClock < (_tapeSeen ? _afterTape : _noTape)) return;
    var fb = _zx.framebuffer();
    if (fb == null) return;
    if (_loadingShot != null && GameThumbnail.paperColours(fb) < 3) fb = _loadingShot!;
    _capturing = true;
    GameThumbnail.saveCaptureIfMissing(widget.mediaPath, fb).then((done) {
      _capturing = false;
      if (done) {
        _wantCapture = false;
        _loadingShot = null;
      } else {
        _captureClock -= _afterTape; // pantalla lisa: probar de nuevo en un rato
      }
    });
  }

  /// Fin de la carga (mismo criterio que la miniatura): el cassette que se abrió solo
  /// vuelve al mando.
  void _checkDeckReturn(double delta) {
    if (!_showTapeDeck) {
      _autoDeck = false;
      return;
    }
    // La carga "avanzó" si la cinta giró, pasó de bloque o llegó al final: un .tap con carga
    // rápida entra por el trap sin girar y no debe esperar el tiempo largo de "sin cinta".
    final progressed = _deckTapeSeen || _tape.info.block > 0 || _tape.info.atEnd;
    if (_tape.info.isPlaying && !_tape.info.atEnd) {
      _deckTapeSeen = true;
      _deckClock = 0;
      return;
    }
    _deckClock += delta;
    if (_deckClock < (progressed ? _afterTape : _noTape)) return;
    _autoDeck = false;
    setState(() => _showTapeDeck = false);
  }

  /// Sin sonido si está apagado, o mientras gira la cinta con "Silenciar la carga".
  void _applyMute() {
    final muted = !_settings.soundOn || (_settings.muteTape && _tape.info.isPlaying);
    if (muted == _audioMuted) return;
    _audioMuted = muted;
    _audio.setMuted(muted);
  }

  /// Letrero del LCD del mando: juego · año y editor · control · ENTER | ESPACIO.
  /// Con el cassette: bloque, nombre del bloque y estado.
  String _lcdText() {
    final t = context.l10n;
    if (_showTapeDeck) {
      final c = _tape;
      final block = c.hasList && c.info.block < c.total ? c.tape!.blocks[c.info.block].description : null;
      return [
        tapeStatusLine(t, c),
        if (block != null) block,
        if (c.recording) t.tapeRecorded(c.recordedBlocks),
      ].join('  ·  ').toUpperCase();
    }
    final info = widget.mediaPath.isEmpty ? null : GameInfoService.cached(widget.mediaPath);
    final extras = _pad.extraKeys;
    return [
      _title,
      if (info != null && info.subtitle.isNotEmpty) info.subtitle,
      if (info?.genre != null) info!.genre!,
      if (extras.isNotEmpty) '${t.extraButtons} ${extras.map(zxKeyLabel).join(' ')}',
      if (_pad.jumpButton != null) '${t.jumpButton} ${_pad.jumpButton! + 1}',
      if (_pad.selectKeys.isNotEmpty) 'SELECT/START ${_pad.selectKeys.map(zxKeyLabel).join(' ')}',
    ].join('  ·  ').toUpperCase();
  }

  /// Control activo para la franja del LCD: SINCLAIR1, KEMPSTON, CURSOR, MOUSE o las teclas propias.
  String _controlLabel() {
    if (_pad.mouse != MouseType.none) return 'MOUSE';
    return switch (_pad.type) {
      JoyMapping.keyboard => _pad.keys.map(zxKeyShort).join(' '),
      JoyMapping.sinclair1 => 'SINCLAIR1',
      JoyMapping.sinclair2 => 'SINCLAIR2',
      JoyMapping.kempston => 'KEMPSTON',
      JoyMapping.cursor => 'CURSOR',
    };
  }

  String _lcdModel() {
    final m = _modelLabel();
    return m.isEmpty ? _controlLabel() : '$m  ${_controlLabel()}';
  }

  // --- Entrada ---------------------------------------------------------------

  void _onKey(int code, bool pressed) => _zx.setKey(code, pressed);

  Widget _mousePad() => MousePad(
        onMove: _zx.mouseMove,
        onButton: (down) => _zx.mouseButtons(down ? 1 : 0),
        haptics: _settings.vibration,
      );

  void _onJoystick(int mask) {
    _touchJoy = mask;
    _applyJoystick();
  }

  void _applyJoystick() {
    final mask = _touchJoy | _extJoy;
    final keys = _pad.directionKeys;
    if (keys == null) {
      _zx.setJoystick(mask);
    } else {
      const bits = [ZxJoy.up, ZxJoy.down, ZxJoy.left, ZxJoy.right, ZxJoy.fire];
      final changed = mask ^ _joyMask;
      for (var i = 0; i < bits.length; i++) {
        if (changed & bits[i] != 0) _zx.setKey(keys[i], mask & bits[i] != 0);
      }
    }
    _joyMask = mask;
  }

  /// Suelta todo lo pulsado (al cambiar de controles o abrir un panel).
  void _releaseInputs() {
    _external.releaseAll();
    _zx.clearKeys();
    _extJoy = 0;
    _onJoystick(0);
  }

  /// Verde: mando → teclado → cassette → mando (en horizontal, sin cassette).
  void _toggleInput() => setState(() {
        _releaseInputs();
        _autoDeck = false;
        final landscape = MediaQuery.orientationOf(context) == Orientation.landscape;
        if (_showTapeDeck) {
          _showTapeDeck = false;
        } else if (_showKeyboard) {
          _showKeyboard = false;
          _showTapeDeck = !landscape;
        } else {
          _showKeyboard = true;
        }
      });

  /// Ícono del verde: el modo que viene. Volver al mando muestra un ratón si el control del
  /// juego es el ratón.
  IconData get _nextInputIcon {
    final landscape = MediaQuery.orientationOf(context) == Orientation.landscape;
    final pad = _pad.mouse != MouseType.none ? Icons.mouse_rounded : Icons.sports_esports_rounded;
    if (_showTapeDeck) return pad;
    if (_showKeyboard) return landscape ? pad : Icons.album_rounded;
    return Icons.keyboard_rounded;
  }

  // --- Cintas (doc/TAPE_MANAGER.md) ------------------------------------------

  void _openTapeSheet() {
    _releaseInputs();
    showTapeSheet(
      context,
      controller: _tape,
      onInsert: _insertTape,
      onRecord: _toggleRecord,
      onNewTape: () => _openTapeEditor(null),
      onEditTape: _tape.hasList ? () => _openTapeEditor(_tape.path) : null,
    );
  }

  /// Otra cinta sin reiniciar: se copia a Mis juegos (como al importar) y se inserta.
  Future<void> _insertTape() async {
    final t = context.l10n;
    final r = await FilePicker.platform.pickFiles(type: FileType.any, withData: true);
    final f = r?.files.singleOrNull;
    if (f == null || f.bytes == null) return;
    try {
      final path = await GameLibrary.import(f.name, f.bytes!);
      if (!await _tape.insert(path) && mounted) {
        ScaffoldMessenger.of(context)
            .showSnackBar(SnackBar(content: Text(t.loadFailed(t.errUnsupportedFormat))));
      }
    } catch (e) {
      if (mounted) ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(t.tapeBadFile('$e'))));
    }
  }

  /// ● REC: los SAVE del ROM se graban en una cinta nueva de Mis juegos.
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
      return;
    }
    _tape.startRecording(await GameLibrary.freePath('save.tap'));
    if (mounted) ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(t.tapeRecordHint)));
  }

  Future<void> _openTapeEditor(String? path) => _whilePaused(() async {
        await Navigator.push(context, MaterialPageRoute(builder: (_) => TapeEditorScreen(path: path)));
        await _tape.reload();
      });

  /// Botones de colores del mando.
  void _onPadAction(PadAction action) {
    switch (action) {
      case PadAction.pause:
        _setPaused(!_paused);
      case PadAction.config:
        _whilePaused(_openSettings);
      case PadAction.sound:
        _toggleSound();
      case PadAction.keyboard:
        _toggleInput();
      case PadAction.exit:
        _exit();
    }
  }

  /// Pausa el juego mientras dura [task] (si no lo estaba ya).
  Future<void> _whilePaused(Future<void> Function() task) async {
    _releaseInputs();
    final wasPaused = _paused;
    if (!wasPaused) _setPaused(true);
    await task();
    if (mounted && !wasPaused && !_exiting) _setPaused(false);
  }

  void _toggleSound() {
    setState(() => _settings.soundOn = !_settings.soundOn);
    _applyMute();
    _settings.save();
  }

  Future<void> _openSettings() async {
    await Navigator.push(context, MaterialPageRoute(
      builder: (_) => SettingsScreen(
        pad: _pad,
        padFallback: _settings.joyMapping,
        gamePath: widget.mediaPath,
        gameName: _title,
        onPadChanged: (c) {
          _pad = c;
          c.save(widget.mediaPath);
        },
      ),
    ));
    final s = await _loadSettings();
    // Sin configuración propia, el juego sigue el tipo de control de Ajustes.
    final pad = await PadConfig.load(widget.mediaPath, s.joyMapping);
    if (!mounted) return;
    s.keepScreenOn ? WakelockPlus.enable() : WakelockPlus.disable();
    SystemChrome.setEnabledSystemUIMode(SystemUiMode.immersiveSticky);
    _zx.setGigascreen(s.gigascreen);
    _audioMuted = !s.soundOn;
    _audio.setMuted(_audioMuted);
    _zx.mouseMode = pad.mouse.index;
    setState(() {
      _settings = s;
      _pad = pad;
    });
  }

  // --- Ciclo de vida ---------------------------------------------------------

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (_exiting || !_started) return;
    if (state == AppLifecycleState.resumed) {
      if (_autoPaused) {
        _autoPaused = false;
        _setPaused(false);
      }
    } else if (!_paused) {
      _autoPaused = true;
      _setPaused(true);
    }
  }

  void _setPaused(bool p) {
    setState(() => _paused = p);
    _audio.setPaused(p);
    if (p) {
      _zx.clearKeys();
    }
  }

  Future<void> _exit() async {
    if (_exiting) return;
    _exiting = true;
    _ticker.stop();
    // Juegos cuyo archivo no trae pantalla (cinta cifrada, .dsk…): la última
    // pantalla del emulador queda como miniatura en la biblioteca.
    final fb = _zx.framebuffer();
    if (fb != null && widget.mediaPath.isNotEmpty) {
      await GameThumbnail.saveCaptureIfMissing(widget.mediaPath, fb);
    }
    _audio.stop();
    _zx.dispose();
    AdManager.instance.showInterstitialThenDo(() {
      if (mounted) Navigator.of(context).pop();
    });
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    SystemChrome.setEnabledSystemUIMode(SystemUiMode.manual, overlays: SystemUiOverlay.values);
    WakelockPlus.disable();
    _focus.dispose();
    _ticker.dispose();
    _tape.dispose();
    _audio.stop();
    _zx.dispose();
    _frame?.dispose();
    _alive.complete();
    super.dispose();
  }

  // --- UI --------------------------------------------------------------------

  Future<void> _showMenu() async {
    final tape = _zx.tapePlaying;
    final t = context.l10n;
    // En horizontal no hay botones de colores: la configuración y el sonido van aquí.
    final landscape = MediaQuery.orientationOf(context) == Orientation.landscape;
    final choice = await showModalBottomSheet<String>(
      context: context,
      isScrollControlled: true,
      backgroundColor: ZxColors.bodyLight,
      builder: (ctx) => SafeArea(
        child: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            if (landscape) ...[
              _MenuTile(icon: Icons.settings_rounded, label: t.settings, value: 'config'),
              _MenuTile(
                  icon: _settings.soundOn ? Icons.volume_up_rounded : Icons.volume_off_rounded,
                  label: t.sound,
                  value: 'sound'),
            ],
            _MenuTile(icon: Icons.tv_rounded, label: t.videoMode, value: 'video'),
            _MenuTile(icon: Icons.restart_alt_rounded, label: t.reset, value: 'reset'),
            if (widget.mediaPath.isNotEmpty)
              _MenuTile(
                icon: tape ? Icons.stop_rounded : Icons.play_arrow_rounded,
                label: tape ? t.stopTape : t.playTape,
                value: 'tape',
              ),
            _MenuTile(icon: Icons.album_rounded, label: t.tapeManager, value: 'tapes'),
            _MenuTile(icon: Icons.exit_to_app_rounded, label: t.exitGame, value: 'exit'),
          ],
        ),
        ),
      ),
    );
    switch (choice) {
      case 'config':
        _whilePaused(_openSettings);
      case 'sound':
        _toggleSound();
      case 'video':
        _chooseVideo();
      case 'reset':
        _zx.reset();
      case 'tape':
        if (_tape.hasTape) {
          _tape.togglePlay();
        } else {
          _zx.tapePlaying = !tape;
        }
      case 'tapes':
        _openTapeSheet();
      case 'exit':
        _exit();
    }
  }

  /// Modo de video: se aplica al elegirlo (el juego sigue de fondo) y se guarda.
  Future<void> _chooseVideo() async {
    final t = context.l10n;
    final v = await showModalBottomSheet<VideoMode>(
      context: context,
      backgroundColor: ZxColors.bodyLight,
      builder: (ctx) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(20, 16, 20, 8),
              child: Text(t.videoMode, style: const TextStyle(fontSize: 22, fontWeight: FontWeight.bold)),
            ),
            for (final m in VideoMode.values)
              ListTile(
                minTileHeight: 64,
                leading: Icon(
                  m == _settings.videoMode ? Icons.radio_button_checked : Icons.radio_button_unchecked,
                  size: 28,
                  color: m == _settings.videoMode ? ZxColors.cyan : null,
                ),
                title: Text(m.label(t), style: const TextStyle(fontSize: 20)),
                onTap: () => Navigator.pop(ctx, m),
              ),
          ],
        ),
      ),
    );
    if (v == null || !mounted) return;
    setState(() => _settings.videoMode = v);
    await _settings.save();
  }

  /// Horizontal: el juego ocupa todo el alto y los controles van a los costados,
  /// translúcidos sobre él; el teclado es una capa translúcida que se alterna con
  /// el botón verde de arriba.
  Widget _landscape() {
    const fade = 0.62;
    return SafeArea(
      top: !_settings.fullScreen,
      child: LayoutBuilder(builder: (context, box) {
        final w = box.maxWidth, h = box.maxHeight;
        final kbW = math.min(w * 0.52, h * 0.45 * zxKeyboardCompactAspect);
        return Stack(
          fit: StackFit.expand,
          children: [
            Center(
              child: AspectRatio(
                aspectRatio: GameDisplay.aspectFor(_settings.screenBorder),
                child: Stack(
                  fit: StackFit.expand,
                  children: [
                    GameDisplay(
                        frame: _frame, turbo: _turbo, mode: _settings.videoMode, border: _settings.screenBorder),
                    if (_paused)
                      const ColoredBox(
                        color: Colors.black54,
                        child: Center(child: Icon(Icons.pause_circle_filled_rounded, size: 96, color: Colors.white70)),
                      ),
                  ],
                ),
              ),
            ),
            if (_pad.mouse != MouseType.none)
              Align(
                alignment: Alignment.bottomRight,
                child: Opacity(
                  opacity: fade,
                  child: SizedBox.square(dimension: math.min(h * 0.62, w * 0.28), child: _mousePad()),
                ),
              )
            else
            Opacity(
              opacity: fade,
              child: JoystickPad(
                landscape: true,
                onJoystick: _onJoystick,
                onKey: _onKey,
                extraKeys: _pad.extraKeys,
                selectKeys: _pad.selectKeys,
                jumpButton: _pad.jumpButton,
                jumpLabel: context.l10n.jump.toUpperCase(),
                haptics: _settings.vibration,
              ),
            ),
            if (_showKeyboard)
              Align(
                alignment: Alignment.bottomCenter,
                child: Opacity(
                  opacity: fade,
                  child: SizedBox(
                    width: kbW,
                    height: kbW / zxKeyboardCompactAspect,
                    child: ZxKeyboard(onKey: _onKey, haptics: _settings.vibration, compact: true),
                  ),
                ),
              ),
            Positioned(
              right: 12,
              top: 8,
              child: Opacity(
                opacity: fade,
                child: GestureDetector(
                  behavior: HitTestBehavior.opaque,
                  onTap: _toggleInput,
                  child: Container(
                    width: 60,
                    height: 60,
                    decoration: BoxDecoration(
                      shape: BoxShape.circle,
                      color: const Color(0xFF2C2F33),
                      border: Border.all(color: _showKeyboard ? ZxColors.cyan : Colors.white70, width: 3),
                    ),
                    child: Icon(_nextInputIcon, size: 34, color: Colors.white),
                  ),
                ),
              ),
            ),
            Positioned(
              top: 2,
              left: 4,
              child: Opacity(
                opacity: 0.7,
                child: Row(
                  children: [
                    IconButton(
                      color: Colors.white,
                      iconSize: 30,
                      icon: Icon(_paused ? Icons.play_arrow_rounded : Icons.pause_rounded),
                      onPressed: () => _setPaused(!_paused),
                    ),
                    IconButton(
                      color: Colors.white,
                      iconSize: 30,
                      icon: const Icon(Icons.more_vert_rounded),
                      onPressed: _showMenu,
                    ),
                  ],
                ),
              ),
            ),
          ],
        );
      }),
    );
  }

  @override
  Widget build(BuildContext context) {
    final landscape = MediaQuery.orientationOf(context) == Orientation.landscape;
    return PopScope(
      canPop: false,
      onPopInvokedWithResult: (didPop, _) {
        if (!didPop) _exit();
      },
      child: Scaffold(
        backgroundColor: Colors.black,
        body: Focus(
          focusNode: _focus,
          autofocus: true,
          onKeyEvent: (_, e) {
            if (_paused || !_started) return KeyEventResult.ignored;
            return _external.handle(e) ? KeyEventResult.handled : KeyEventResult.ignored;
          },
          child: landscape ? _landscape() : SafeArea(
          top: !_settings.fullScreen,
          child: Stack(
            children: [
          Column(
            children: [
              if (!_settings.fullScreen)
              _TopBar(
                title: _title,
                paused: _paused,
                onBack: _exit,
                onPause: () => _setPaused(!_paused),
                inputIcon: _nextInputIcon,
                onToggleInput: _toggleInput,
                onMenu: _showMenu,
              ),
              // Consola portátil: pantalla, LCD y botones de acción arriba (misma
              // posición con mando y con teclado) y los controles en el resto.
              Expanded(
                child: _error != null
                    ? _ErrorView(message: zxErrorText(context.l10n, _error!), onBack: () => Navigator.pop(context))
                    : ConsoleView(
                        rainbow: !_showKeyboard || _showTapeDeck,
                        fitWidth: _settings.fitWidth,
                        // Teclado: un poco más alto que su proporción (teclas más cómodas).
                        controlsAspect: _showKeyboard && !_showTapeDeck ? zxKeyboardCompactAspect / 1.2 : null,
                        screenAspect: GameDisplay.aspectFor(_settings.screenBorder),
                        screen: Stack(
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
                                  child: Icon(Icons.pause_circle_filled_rounded, size: 96, color: Colors.white70),
                                ),
                              ),
                          ],
                        ),
                        lcd: LcdPanel(
                          text: _lcdText(),
                          spaceLabel: context.l10n.space,
                          onKey: _onKey,
                          haptics: _settings.vibration,
                          modelLabel: _lcdModel(),
                          next: _zx.modelIndex == 6,
                          ulaplus: () => _zx.ulaplus,
                        ),
                        actions: ActionButtons(
                          onAction: _onPadAction,
                          keyboardMode: _showKeyboard,
                          inputIcon: _nextInputIcon,
                          soundOn: _settings.soundOn,
                          paused: _paused,
                          haptics: _settings.vibration,
                          light: _settings.buttonLight,
                        ),
                        controls: _showTapeDeck
                            ? TapeDeck(
                                controller: _tape,
                                onRecord: _toggleRecord,
                                onShowList: _openTapeSheet,
                                haptics: _settings.vibration,
                                title: _title,
                                machine: _modelLabel(),
                              )
                            : _showKeyboard
                            ? ZxKeyboard(onKey: _onKey, haptics: _settings.vibration, compact: true, stretch: true)
                            : _pad.mouse != MouseType.none
                                ? _mousePad()
                                : JoystickPad(
                                onJoystick: _onJoystick,
                                onKey: _onKey,
                                extraKeys: _pad.extraKeys,
                                selectKeys: _pad.selectKeys,
                                jumpButton: _pad.jumpButton,
                                jumpLabel: context.l10n.jump.toUpperCase(),
                                haptics: _settings.vibration,
                              ),
                      ),
              ),
            ],
          ),
          // Sin barra de título: pausa y menú ⋮ flotan arriba a la derecha (atrás y
          // teclado ya están en los botones de colores).
          if (_settings.fullScreen)
            Positioned(
              top: 2,
              right: 4,
              child: Opacity(
                opacity: 0.8,
                child: Row(
                  children: [
                    IconButton(
                      color: Colors.white,
                      iconSize: 28,
                      icon: Icon(_paused ? Icons.play_arrow_rounded : Icons.pause_rounded),
                      onPressed: () => _setPaused(!_paused),
                    ),
                    IconButton(
                      color: Colors.white,
                      iconSize: 28,
                      icon: const Icon(Icons.more_vert_rounded),
                      onPressed: _showMenu,
                    ),
                  ],
                ),
              ),
            ),
            ],
          ),
        ),
        ),
      ),
    );
  }
}

class _TopBar extends StatelessWidget {
  final String title;
  final bool paused;
  final IconData inputIcon;
  final VoidCallback onBack;
  final VoidCallback onPause;
  final VoidCallback onToggleInput;
  final VoidCallback onMenu;

  const _TopBar({
    required this.title,
    required this.paused,
    required this.inputIcon,
    required this.onBack,
    required this.onPause,
    required this.onToggleInput,
    required this.onMenu,
  });

  @override
  Widget build(BuildContext context) {
    const iconSize = 30.0;
    final t = context.l10n;
    return Container(
      color: ZxColors.body,
      height: 56,
      child: Row(
        children: [
          IconButton(
            icon: const Icon(Icons.arrow_back_rounded, size: iconSize),
            tooltip: t.exit,
            onPressed: onBack,
          ),
          Expanded(
            child: Text(title,
                style: const TextStyle(fontSize: 18, fontWeight: FontWeight.bold),
                overflow: TextOverflow.ellipsis),
          ),
          IconButton(
            icon: Icon(inputIcon, size: iconSize),
            onPressed: onToggleInput,
          ),
          IconButton(
            icon: Icon(paused ? Icons.play_arrow_rounded : Icons.pause_rounded, size: iconSize),
            tooltip: paused ? t.resume : t.pause,
            onPressed: onPause,
          ),
          IconButton(
            icon: const Icon(Icons.more_vert_rounded, size: iconSize),
            tooltip: t.menu,
            onPressed: onMenu,
          ),
        ],
      ),
    );
  }
}

class _MenuTile extends StatelessWidget {
  final IconData icon;
  final String label;
  final String value;
  const _MenuTile({required this.icon, required this.label, required this.value});

  @override
  Widget build(BuildContext context) {
    return ListTile(
      minTileHeight: 64,
      leading: Icon(icon, size: 30),
      title: Text(label, style: const TextStyle(fontSize: 20)),
      onTap: () => Navigator.pop(context, value),
    );
  }
}

class _ErrorView extends StatelessWidget {
  final String message;
  final VoidCallback onBack;
  const _ErrorView({required this.message, required this.onBack});

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.all(24),
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          const Icon(Icons.error_outline_rounded, size: 64, color: ZxColors.red),
          const SizedBox(height: 12),
          Text(context.l10n.loadFailed(message),
              textAlign: TextAlign.center, style: const TextStyle(fontSize: 18)),
          const SizedBox(height: 20),
          ElevatedButton(onPressed: onBack, child: Text(context.l10n.back)),
        ],
      ),
    );
  }
}
