import 'package:flutter/foundation.dart';
import 'package:flutter_soloud/flutter_soloud.dart';

import 'zx_bridge.dart';

/// Salida de audio del emulador: stream PCM s16le estéreo de flutter_soloud que se
/// alimenta con lo que produce el core en cada tick.
class ZxAudio {
  static const sampleRate = 48000;

  AudioSource? _stream;
  SoundHandle? _handle;

  Future<void> start() async {
    try {
      if (!SoLoud.instance.isInitialized) await SoLoud.instance.init();
      _stream = SoLoud.instance.setBufferStream(
        maxBufferSizeDuration: const Duration(seconds: 10),
        sampleRate: sampleRate,
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

  /// Pasa al stream todo el audio pendiente del core (sin audio, igual lo vacía).
  void feed(ZxBridge zx) {
    final s = _stream;
    while (true) {
      final pcm = zx.drainAudio();
      if (pcm == null) break;
      if (s == null) continue;
      try {
        SoLoud.instance.addAudioDataStream(s, pcm);
      } catch (_) {
        break;
      }
    }
  }

  void setPaused(bool paused) {
    final h = _handle;
    if (h != null) SoLoud.instance.setPause(h, paused);
  }

  void stop() {
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
}
