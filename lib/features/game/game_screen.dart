import 'dart:async';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/scheduler.dart';
import 'package:flutter/services.dart';
import 'package:flutter_soloud/flutter_soloud.dart';
import 'package:wakelock_plus/wakelock_plus.dart';

import '../../core/ads/ad_manager.dart';
import '../../core/l10n.dart';
import '../../core/emulator/zx_bridge.dart';
import '../../core/emulator/zx_types.dart';
import '../../core/settings.dart';
import '../../core/storage/game_library.dart';
import '../../core/storage/game_thumbnail.dart';
import '../../core/theme/easy_theme.dart';
import 'game_display.dart';
import 'joystick_pad.dart';
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
  static const _sampleRate = 48000;

  final _zx = ZxBridge.instance;
  final _alive = Completer<void>();
  late final Ticker _ticker;
  AppSettings _settings = AppSettings();

  ui.Image? _frame;
  bool _frameBusy = false;
  bool _started = false;
  bool _paused = false;
  bool _autoPaused = false;
  bool _exiting = false;
  bool _showKeyboard = false;
  bool _turbo = false;
  String? _error;

  Duration _lastTick = Duration.zero;
  int _joyMask = 0;

  AudioSource? _stream;
  SoundHandle? _handle;

  String get _title =>
      widget.mediaPath.isEmpty ? 'ZX Spectrum' : GameLibrary.titleOf(widget.mediaPath);

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
    _settings = await AppSettings.load();
    _showKeyboard = widget.mediaPath.isEmpty || _settings.startWithKeyboard;
    if (_settings.keepScreenOn) WakelockPlus.enable();

    final err = await _zx.start(
      model: _settings.model,
      mediaPath: widget.mediaPath,
      audioFreq: _sampleRate,
      quickLoad: _settings.quickLoad,
    );
    if (!mounted) return;
    if (err != null) {
      setState(() => _error = err);
      return;
    }
    await _initAudio();
    setState(() => _started = true);
    _ticker.start();
  }

  Future<void> _initAudio() async {
    try {
      if (!SoLoud.instance.isInitialized) await SoLoud.instance.init();
      _stream = SoLoud.instance.setBufferStream(
        maxBufferSizeDuration: const Duration(seconds: 10),
        sampleRate: _sampleRate,
        channels: Channels.stereo,
        format: BufferType.s16le,
        bufferingType: BufferingType.released,
        bufferingTimeNeeds: 0.08,
      );
      _handle = SoLoud.instance.play(_stream!);
    } catch (e) {
      debugPrint('Audio init error: $e');
    }
  }

  void _disposeAudio() {
    final h = _handle, s = _stream;
    _handle = null;
    _stream = null;
    if (h != null) {
      try {
        SoLoud.instance.stop(h);
      } catch (_) {}
    }
    if (s != null) {
      try {
        SoLoud.instance.setDataIsEnded(s);
        SoLoud.instance.disposeSource(s);
      } catch (_) {}
    }
  }

  void _feedAudio() {
    final s = _stream;
    while (true) {
      final pcm = _zx.drainAudio();
      if (pcm == null) break;
      if (s == null) continue; // sin audio: igual vaciar el buffer nativo
      try {
        SoLoud.instance.addAudioDataStream(s, pcm);
      } catch (_) {
        break;
      }
    }
  }

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
    _feedAudio();
    final turbo = _zx.turbo;
    if (turbo != _turbo) setState(() => _turbo = turbo);
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

  // --- Entrada ---------------------------------------------------------------

  void _onKey(int code, bool pressed) => _zx.setKey(code, pressed);

  void _onJoystick(int mask) {
    final keys = _settings.joyMapping.keys;
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
    final h = _handle;
    if (h != null) SoLoud.instance.setPause(h, p);
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
    _disposeAudio();
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
    _ticker.dispose();
    _disposeAudio();
    _zx.dispose();
    _frame?.dispose();
    _alive.complete();
    super.dispose();
  }

  // --- UI --------------------------------------------------------------------

  Future<void> _showMenu() async {
    final tape = _zx.tapePlaying;
    final t = context.l10n;
    final choice = await showModalBottomSheet<String>(
      context: context,
      backgroundColor: ZxColors.bodyLight,
      builder: (ctx) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            _MenuTile(icon: Icons.restart_alt_rounded, label: t.reset, value: 'reset'),
            if (widget.mediaPath.isNotEmpty)
              _MenuTile(
                icon: tape ? Icons.stop_rounded : Icons.play_arrow_rounded,
                label: tape ? t.stopTape : t.playTape,
                value: 'tape',
              ),
            _MenuTile(icon: Icons.exit_to_app_rounded, label: t.exitGame, value: 'exit'),
          ],
        ),
      ),
    );
    switch (choice) {
      case 'reset':
        _zx.reset();
      case 'tape':
        _zx.tapePlaying = !tape;
      case 'exit':
        _exit();
    }
  }

  @override
  Widget build(BuildContext context) {
    return PopScope(
      canPop: false,
      onPopInvokedWithResult: (didPop, _) {
        if (!didPop) _exit();
      },
      child: Scaffold(
        backgroundColor: Colors.black,
        body: SafeArea(
          child: Column(
            children: [
              _TopBar(
                title: _title,
                paused: _paused,
                keyboard: _showKeyboard,
                onBack: _exit,
                onPause: () => _setPaused(!_paused),
                onToggleInput: () => setState(() {
                  _zx.clearKeys();
                  _onJoystick(0);
                  _showKeyboard = !_showKeyboard;
                }),
                onMenu: _showMenu,
              ),
              Expanded(
                child: _error != null
                    ? _ErrorView(message: zxErrorText(context.l10n, _error!), onBack: () => Navigator.pop(context))
                    : Stack(
                        fit: StackFit.expand,
                        children: [
                          GameDisplay(frame: _frame, turbo: _turbo),
                          if (_paused)
                            const ColoredBox(
                              color: Colors.black54,
                              child: Center(
                                child: Icon(Icons.pause_circle_filled_rounded,
                                    size: 96, color: Colors.white70),
                              ),
                            ),
                        ],
                      ),
              ),
              // Los controles ocupan la altura del mando a todo el ancho (tope: media
              // pantalla); el teclado se estira a esa misma área, así la pantalla del
              // juego no se mueve al cambiar de uno a otro. La pantalla usa el resto.
              ConstrainedBox(
                constraints: BoxConstraints(maxHeight: MediaQuery.sizeOf(context).height * 0.5),
                child: AspectRatio(
                  aspectRatio: JoystickPad.aspectRatio,
                  child: _showKeyboard
                      ? ZxKeyboard(onKey: _onKey, haptics: _settings.vibration)
                      : JoystickPad(
                          onJoystick: _onJoystick,
                          onKey: _onKey,
                          haptics: _settings.vibration,
                        ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _TopBar extends StatelessWidget {
  final String title;
  final bool paused;
  final bool keyboard;
  final VoidCallback onBack;
  final VoidCallback onPause;
  final VoidCallback onToggleInput;
  final VoidCallback onMenu;

  const _TopBar({
    required this.title,
    required this.paused,
    required this.keyboard,
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
            icon: Icon(keyboard ? Icons.sports_esports_rounded : Icons.keyboard_rounded,
                size: iconSize),
            tooltip: keyboard ? t.showJoystick : t.showKeyboard,
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
